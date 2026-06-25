#!/usr/bin/env bash
# Gemma 4 target + gemma4_assistant MTP draft with TurboQuant KV (turbo3 by default).
#
# One script for all Gemma 4 MTP compose files (gemma / gemma12b / gemma31b).
# Switch models by setting env vars; the script auto-detects HF_REPO and uses
# llama-server's built-in -hf downloader (common/download.cpp) for download +
# resume, falling back to caller-staged MAIN_GGUF/DRAFT_GGUF paths on disk.
#
# Variables:
#   HF_REPO              owner/repo:tag for the main model
#   HF_DRAFT_REPO        owner/repo:file.gguf for the assistant MTP draft
#   MAIN_GGUF            /path/to/main.gguf  (used when HF_REPO is unset)
#   DRAFT_GGUF           /path/to/draft.gguf (used when HF_DRAFT_REPO is unset)
#   CTX, NGL, NGL_DRAFT, CTK, CTV, CTKD, CTVD, FA, TEMP, PARALLEL, SLOT_SAVE_PATH, ...
#   SPEC=mtp (default) | off  (off disables MTP, runs baseline)
#   DRAFT_BLOCK_SIZE, DRAFT_MAX, DRAFT_MIN  (MTP tuning)
#   VERIFY_ASSISTANT_GGUF=0  (skip the verify-gemma4-assistant-gguf.py check)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SERVER="${LLAMA_SERVER:-${ROOT}/build/bin/llama-server}"
HF_REPO="${HF_REPO:-}"
HF_DRAFT_REPO="${HF_DRAFT_REPO:-}"
# Caller-staged paths (used when HF_REPO is empty)
MAIN="${MAIN_GGUF:-${ROOT}/.scratch/gemma-4-26b-a4b/gemma-4-26B-A4B-it-UD-Q4_K_XL.gguf}"
DRAFT="${DRAFT_GGUF:-${ROOT}/.scratch/gemma-assistant-mtp.gguf}"

VERIFY_ASSISTANT_GGUF="${VERIFY_ASSISTANT_GGUF:-1}"

CTX="${CTX:-16384}"
NGL="${NGL:-99}"
NGL_DRAFT="${NGL_DRAFT:-99}"
CTK="${CTK:-turbo3}"
CTV="${CTV:-turbo3}"
CTKD="${CTKD:-turbo3}"
CTVD="${CTVD:-turbo3}"
HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-8080}"
FA="${FA:-on}"

# SPEC=mtp (default) | off — off disables MTP, runs baseline.
SPEC="${SPEC:-mtp}"

# TEMP=0 forces greedy sampling on the target so MTP draft acceptance can be
# compared against an upper bound (no sampler divergence).
TEMP="${TEMP:-}"

ENABLE_METRICS="${ENABLE_METRICS:-1}"
ENABLE_SLOTS="${ENABLE_SLOTS:-1}"
SLOT_SAVE_PATH="${SLOT_SAVE_PATH:-}"  # dir for persisted KV caches; enables /slots?action=save|restore
LOG_TIMESTAMPS="${LOG_TIMESTAMPS:-1}"
LOG_PREFIX="${LOG_PREFIX:-1}"
NO_WARMUP="${NO_WARMUP:-0}"

if [[ ! -f "$SERVER" ]]; then
  echo "error: missing ${SERVER} (build with: cmake --build build --target llama-server)" >&2
  exit 1
fi

# Two modes:
#   1) HF_REPO set    -> server downloads with -hf/-hfd; no need to verify local files.
#   2) HF_REPO unset  -> expect MAIN_GGUF/DRAFT_GGUF to point at staged files on disk.
USE_HF="no"
if [[ -n "$HF_REPO" ]]; then
  USE_HF="yes"
  if [[ "$SPEC" == "mtp" ]]; then
    # If HF_DRAFT_REPO ends in .gguf, llama-server's find_best_model uses
    # a quant-substring regex that fails on full filenames. Fall back to
    # the staged DRAFT_GGUF file in that case (the user has it cached).
    if [[ "$HF_DRAFT_REPO" == *.gguf && -n "$DRAFT" && -f "$DRAFT" ]]; then
      USE_HF_DRAFT="no"  # use local --mtp-head instead
    elif [[ -n "$HF_DRAFT_REPO" ]]; then
      USE_HF_DRAFT="yes"
    else
      USE_HF_DRAFT="no"
    fi
  fi
else
  if [[ ! -f "$MAIN" ]]; then
    echo "error: main GGUF not found: ${MAIN}" >&2
    echo "  hint: either set HF_REPO=owner/repo:tag (server downloads), or stage a file at the path above" >&2
    exit 1
  fi
  if [[ "$SPEC" == "mtp" && -n "$DRAFT" && ! -f "$DRAFT" ]]; then
    echo "error: draft (assistant) GGUF not found: ${DRAFT}" >&2
    echo "  hint: download the assistant MTP head, e.g.:" >&2
    echo "         hf download AtomicChat/gemma-4-26B-A4B-it-assistant-GGUF" >&2
    echo "  hint: or convert from the original repo (embedding dim 1024, not 2816):" >&2
    echo "         PYTHONPATH=\${ROOT}/gguf-py python3 \${ROOT}/convert_hf_to_gguf.py <assistant_repo> --outfile <draft.gguf> --outtype f16" >&2
    exit 1
  fi
fi

# Verify the staged draft (if any) in either mode — only when we're using a
# local file as the draft. Skip when the server handles the download.
if [[ "$SPEC" == "mtp" && "${USE_HF_DRAFT:-yes}" == "no" \
      && -n "$DRAFT" && -f "$DRAFT" && "$VERIFY_ASSISTANT_GGUF" != "0" ]]; then
  if ! python3 "${ROOT}/scripts/verify-gemma4-assistant-gguf.py" "$DRAFT"; then
    echo "error: assistant GGUF verification failed" >&2
    exit 1
  fi
fi

PARALLEL="${PARALLEL:-1}"
KV_UNIFIED="${KV_UNIFIED:-0}"  # Gemma 4 MTP: keep KV cache per-slot by default

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
else
  ARGS=(-m "$MAIN" "${ARGS[@]}")
fi

[[ "$KV_UNIFIED" != "0" ]] && ARGS+=(--kv-unified)

# Initialize USE_HF_DRAFT for the SPEC != mtp case (unused there but referenced
# in the verify block).
: "${USE_HF_DRAFT:=no}"

if [[ "$SPEC" == "mtp" ]]; then
  # Three draft-source modes for MTP:
  #   1) USE_HF_DRAFT=yes  -> server downloads via -hfd (resumable)
  #   2) DRAFT_GGUF + file -> use --mtp-head on the local path
  #   3) neither           -> error
  if [[ "${USE_HF_DRAFT:-yes}" == "yes" ]]; then
    ARGS+=(
      -hfd "$HF_DRAFT_REPO"
      --spec-type mtp
      --draft-block-size "${DRAFT_BLOCK_SIZE:-3}"
      --draft-max "${DRAFT_MAX:-16}"
      --draft-min "${DRAFT_MIN:-0}"
    )
  elif [[ -n "$DRAFT" && -f "$DRAFT" ]]; then
    ARGS+=(
      --mtp-head "$DRAFT"
      --spec-type mtp
      --draft-block-size "${DRAFT_BLOCK_SIZE:-3}"
      --draft-max "${DRAFT_MAX:-16}"
      --draft-min "${DRAFT_MIN:-0}"
    )
  else
    echo "error: SPEC=mtp but no draft source: set HF_DRAFT_REPO=owner/repo[:tag] (server downloads), or DRAFT_GGUF=/path/to/draft.gguf" >&2
    exit 1
  fi
else
  echo "info: speculative decoding disabled (SPEC=${SPEC}); running baseline" >&2
fi

if [[ -n "$TEMP" ]]; then
  ARGS+=(--temp "$TEMP")
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
  if [[ "$SPEC" == "mtp" ]]; then
    if [[ "${USE_HF_DRAFT:-yes}" == "yes" ]]; then
      echo "info: hfd    = $HF_DRAFT_REPO" >&2
    elif [[ -n "$DRAFT" && -f "$DRAFT" ]]; then
      echo "info: draft  = $DRAFT (local staged file)" >&2
    fi
  fi
else
  echo "info: mode   = -m (caller-staged)" >&2
  echo "info: main   = $MAIN" >&2
  [[ "$SPEC" == "mtp" && -n "$DRAFT" && -f "$DRAFT" ]] && echo "info: draft  = $DRAFT" >&2
fi
exec "$SERVER" "${ARGS[@]}" "$@"
