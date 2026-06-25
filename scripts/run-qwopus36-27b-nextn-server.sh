#!/usr/bin/env bash
# Qwen3.6 27B target + NextN draft (second load, same GGUF, override_arch) on llama-server.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SERVER="${LLAMA_SERVER:-${ROOT}/build/bin/llama-server}"
HF_REPO="${HF_REPO:-}"        # if set, server downloads + resumes via -hf
HF_DRAFT_REPO="${HF_DRAFT_REPO:-$HF_REPO}"
MAIN="${MAIN_GGUF:-${ROOT}/.scratch/qwen3-6-27b/qwen3-6-27b-q8_0.gguf}"
DRAFT="${DRAFT_GGUF:-$MAIN}"

VERIFY_GGUF="${VERIFY_NEXTN_GGUF:-1}"

CTX="${CTX:-32768}"
NGL="${NGL:-99}"
NGL_DRAFT="${NGL_DRAFT:-99}"
CTK="${CTK:-turbo3}"
CTV="${CTV:-turbo3}"
CTKD="${CTKD:-turbo3}"
CTVD="${CTVD:-turbo3}"
HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-8080}"
FA="${FA:-on}"
SPEC="${SPEC:-nextn}"

ENABLE_METRICS="${ENABLE_METRICS:-1}"
ENABLE_SLOTS="${ENABLE_SLOTS:-1}"
SLOT_SAVE_PATH="${SLOT_SAVE_PATH:-}"  # dir for persisted KV caches; enables /slots?action=save|restore
LOG_TIMESTAMPS="${LOG_TIMESTAMPS:-1}"
LOG_PREFIX="${LOG_PREFIX:-1}"
NO_WARMUP="${NO_WARMUP:-0}"

if [[ ! -f "$SERVER" ]]; then
  echo "error: missing ${SERVER}" >&2
  exit 1
fi

USE_HF="no"
if [[ -n "$HF_REPO" ]]; then
  USE_HF="yes"
else
  if [[ ! -f "$MAIN" ]]; then
    echo "error: main GGUF not found: ${MAIN}" >&2
    echo "  hint: either set HF_REPO=owner/repo:tag (server downloads), or stage a file at the path above" >&2
    exit 1
  fi
  if [[ "$SPEC" == "nextn" ]]; then
    if [[ ! -f "$DRAFT" ]]; then
      echo "error: draft path not found: ${DRAFT}" >&2
      exit 1
    fi
    if [[ "$VERIFY_GGUF" != "0" ]]; then
      python3 "${ROOT}/scripts/verify-qwen36-nextn-gguf.py" "$MAIN" || exit 1
    fi
  fi
fi

PARALLEL="${PARALLEL:-1}"
KV_UNIFIED="${KV_UNIFIED:-1}"

ARGS=(
  -c "$CTX"
  -ngl "$NGL"
  -ngld "$NGL_DRAFT"
  -ctk "$CTK"
  -ctv "$CTV"
  -ctkd "$CTKD"
  -ctvd "$CTVD"
  -fa "$FA"
  --host "$HOST"
  --port "$PORT"
  --parallel "$PARALLEL"
  -np "$PARALLEL"
  --cont-batching
)

if [[ "$USE_HF" == "yes" ]]; then
  ARGS+=(-hf "$HF_REPO")
  [[ -n "$HF_DRAFT_REPO" && "$HF_DRAFT_REPO" != "$HF_REPO" ]] && ARGS+=(-hfd "$HF_DRAFT_REPO") || ARGS+=(-hfd "$HF_REPO")
else
  ARGS=(-m "$MAIN" "${ARGS[@]}")
fi

[[ "$KV_UNIFIED" != "0" ]] && ARGS+=(--kv-unified)

if [[ "$SPEC" == "nextn" ]]; then
  if [[ "$USE_HF" == "yes" ]]; then
    ARGS+=(
      --spec-type nextn
      --draft-max "${DRAFT_MAX:-16}"
      --draft-min "${DRAFT_MIN:-0}"
    )
  else
    ARGS+=(
      -md "$DRAFT"
      --spec-type nextn
      --draft-max "${DRAFT_MAX:-16}"
      --draft-min "${DRAFT_MIN:-0}"
    )
  fi
else
  echo "info: speculative decoding disabled (SPEC=${SPEC}); running baseline" >&2
fi

[[ "$ENABLE_METRICS"  != "0" ]] && ARGS+=(--metrics)
[[ "$ENABLE_SLOTS"    != "0" ]] && ARGS+=(--slots)

if [[ -n "$SLOT_SAVE_PATH" ]]; then
  SLOT_SAVE_PATH="${SLOT_SAVE_PATH%/}/"   # server does filepath = slot_save_path + filename, so needs trailing slash
  mkdir -p "$SLOT_SAVE_PATH"
  ARGS+=(--slot-save-path "$SLOT_SAVE_PATH")
fi

[[ "$LOG_TIMESTAMPS"  != "0" ]] && ARGS+=(--log-timestamps)
[[ "$LOG_PREFIX"      != "0" ]] && ARGS+=(--log-prefix)
[[ "$NO_WARMUP"       != "0" ]] && ARGS+=(--no-warmup)

echo "info: SPEC=${SPEC} CTX=${CTX} NGL=${NGL} FA=${FA} CTK=${CTK} CTKD=${CTKD}" >&2
if [[ "$USE_HF" == "yes" ]]; then
  echo "info: mode   = -hf (server downloads with built-in resume)" >&2
  echo "info: hf     = $HF_REPO" >&2
  echo "info: hfd    = $HF_DRAFT_REPO" >&2
else
  echo "info: mode   = -m (caller-staged)" >&2
  echo "info: main   = $MAIN" >&2
  echo "info: draft  = $DRAFT" >&2
fi
exec "$SERVER" "${ARGS[@]}" "$@"
