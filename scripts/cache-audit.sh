#!/usr/bin/env bash
#
# cache-audit.sh — Inspect local model caches for llama.cpp / HF setups.
#
# Reports:
#   - GGUF models currently cached (size, mtime)
#   - Incomplete / in-progress downloads (blobs with no final symlink,
#     .incomplete files, lockfiles)
#   - Older local snapshots superseded by newer ones in the same repo
#   - Remote updates: compares each cached repo's latest commit against HEAD
#     of its default branch on huggingface.co
#
# Designed to run inside the container where HF_HUB_CACHE (default
# /root/.cache/huggingface) and LLAMA_CACHE (default /root/.cache/llama.cpp)
# are mounted — paths match docker-compose.gemma31b.yml.
#
# Usage:
#   scripts/cache-audit.sh                # audit default caches
#   scripts/cache-audit.sh --hf /path/to/hf --llama /path/to/llama.cpp
#   scripts/cache-audit.sh --no-remote    # skip huggingface.co checks
#   scripts/cache-audit.sh --json         # machine-readable output
#
set -uo pipefail

# --- defaults -----------------------------------------------------------------
HF_CACHE="${HF_HUB_CACHE:-${HF_HOME:-/root/.cache/huggingface}}"
LLAMA_CACHE="${LLAMA_CACHE:-/root/.cache/llama.cpp}"
REMOTE=1
JSON=0
VERBOSE=0

# --- args ---------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --hf)        HF_CACHE="$2"; shift 2 ;;
    --llama)     LLAMA_CACHE="$2"; shift 2 ;;
    --no-remote) REMOTE=0; shift ;;
    --json)      JSON=1; shift ;;
    -v|--verbose) VERBOSE=1; shift ;;
    -h|--help)
      sed -n '2,30p' "$0"; exit 0 ;;
    *)
      echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

# --- helpers ------------------------------------------------------------------
hr() { printf '%s\n' "------------------------------------------------------------"; }
bytes() {
  # human-readable bytes: 1234 -> 1.2K, 1234567 -> 1.2M
  awk 'function fmt(n,   u, i) {
    u[0]="B"; u[1]="K"; u[2]="M"; u[3]="G"; u[4]="T";
    i = int(n > 0 ? log(n)/log(1024) : 0);
    if (i > 4) i = 4;
    printf "%.1f%s", n / (1024^i), u[i];
  } { fmt($1) }' <<< "$1"
}

has_cmd() { command -v "$1" >/dev/null 2>&1; }

json_escape() {
  # minimal escape for JSON strings
  local s=${1//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

# Collect "<size> <path>" pairs via `du` when available, else `stat`.
dir_size() {
  local p=$1
  if [[ -d $p ]]; then
    du -sb "$p" 2>/dev/null | awk '{print $1}'
  elif [[ -f $p ]]; then
    stat -c %s "$p" 2>/dev/null || stat -f %z "$p" 2>/dev/null
  else
    echo 0
  fi
}

# --- scan HF cache ------------------------------------------------------------
echo "HuggingFace hub cache: $HF_CACHE"
if [[ ! -d $HF_CACHE/hub ]]; then
  echo "  (not found)" >&2
  HF_HAS=0
else
  HF_HAS=1
fi

if [[ $HF_HAS -eq 1 ]]; then
  hr
  printf '%-12s  %-50s  %-10s  %-19s\n' "STATUS" "REPO" "GGUFs" "BLOB SIZE"
  hr
fi

declare -a JSON_REPOS=()
declare -a JSON_PARTIAL=()
declare -a JSON_OLD_SNAPSHOTS=()
declare -a JSON_UPDATES=()

# Iterate each repo: .../hub/models--<owner>--<name>
for repo_dir in "$HF_CACHE"/hub/models--*; do
  [[ -d $repo_dir ]] || continue
  dir=$(basename "$repo_dir")
  # models--<owner>--<name>
  stripped=${dir#models--}
  repo="${stripped//--//}"   # owner/name

  # 1) blobs: <sha> = real file; .incomplete = partial; .lock = downloading
  blob_bytes=$(du -sb "$repo_dir/blobs" 2>/dev/null | awk '{print $1}')
  complete_bytes=$(du -sb --exclude='*.incomplete' --exclude='*.lock' \
                    "$repo_dir/blobs" 2>/dev/null | awk '{print $1}')
  partial_bytes=$(( ${blob_bytes:-0} - ${complete_bytes:-0} ))

  # 2) snapshots/<rev>/<file> -> ../blobs/<sha>
  gguf_count=$(find "$repo_dir/snapshots" -type l -name '*.gguf' 2>/dev/null | wc -l)
  total_gguf_bytes=0
  while IFS= read -r link; do
    [[ -z $link ]] && continue
    target=$(readlink -f "$link" 2>/dev/null) || continue
    sz=$(stat -c %s "$target" 2>/dev/null || stat -f %z "$target" 2>/dev/null || echo 0)
    total_gguf_bytes=$(( total_gguf_bytes + sz ))
  done < <(find "$repo_dir/snapshots" -type l -name '*.gguf' 2>/dev/null)

  # 3) incomplete / locked downloads?
  partial_files=()
  while IFS= read -r -d '' f; do
    partial_files+=("$f")
  done < <(find "$repo_dir/blobs" -type f \( -name '*.incomplete' -o -name '*.lock' \) -print0 2>/dev/null)

  status="ok"
  [[ ${#partial_files[@]} -gt 0 ]] && status="partial"
  [[ $gguf_count -eq 0 && ${#partial_files[@]} -eq 0 ]] && status="empty"

  if [[ $JSON -eq 1 ]]; then
    JSON_REPOS+=("{\"repo\":\"$(json_escape "$repo")\",\"ggufs\":$gguf_count,\"bytes\":$total_gguf_bytes,\"status\":\"$status\",\"partial_files\":${#partial_files[@]}}")
  else
    printf '%-12s  %-50s  %-10s  %s\n' \
      "$status" "${repo:0:50}" "$gguf_count" "$(bytes "$total_gguf_bytes")"
  fi

  if [[ ${#partial_files[@]} -gt 0 ]]; then
    if [[ $JSON -eq 1 ]]; then
      pf_json=$(printf '"%s",' "${partial_files[@]}")
      JSON_PARTIAL+=("{\"repo\":\"$(json_escape "$repo")\",\"files\":[${pf_json%,}]}")
    else
      echo "    partial downloads:"
      printf '      %s (%s)\n' "${partial_files[@]}" | head -10
    fi
  fi
done

# --- older snapshots superseded by newer ones ---------------------------------
if [[ $HF_HAS -eq 1 ]]; then
  hr
  echo "Older snapshots (multiple revisions for same repo):"
  found_old=0
  for repo_dir in "$HF_CACHE"/hub/models--*; do
    [[ -d $repo_dir/snapshots ]] || continue
    revs=("$repo_dir"/snapshots/*/)
    [[ ${#revs[@]} -le 1 ]] && continue
    found_old=1
    # sort by mtime, newest first; mark non-latest as older
    sorted=( $(ls -1dt "${revs[@]}" 2>/dev/null) )
    latest=${sorted[0]}
    for r in "${sorted[@]:1}"; do
      rev=$(basename "$r")
      size=$(dir_size "$r")
      when=$(stat -c %y "$r" 2>/dev/null | cut -d. -f1)
      if [[ $JSON -eq 1 ]]; then
        repo=$(basename "$repo_dir"); repo="${repo#models--}"; repo="${repo//--//}"
        JSON_OLD_SNAPSHOTS+=("{\"repo\":\"$(json_escape "$repo")\",\"snapshot\":\"$rev\",\"bytes\":$size,\"mtime\":\"$when\"}")
      else
        echo "  $repo_dir  rev=$rev  $(bytes "$size")  ($when)"
      fi
    done
  done
  [[ $found_old -eq 0 ]] && echo "  (none)"
fi

# --- remote newer-version check ----------------------------------------------
if [[ $REMOTE -eq 1 && $HF_HAS -eq 1 && $JSON -eq 0 ]]; then
  if ! has_cmd curl; then
    echo "(skipping remote check: curl not available)" >&2
  else
    hr
    echo "Remote updates (local snapshot SHA vs. default branch on huggingface.co):"
    for repo_dir in "$HF_CACHE"/hub/models--*; do
      [[ -d $repo_dir/snapshots ]] || continue
      dir=$(basename "$repo_dir"); repo="${dir#models--}"; repo="${repo//--//}"

      # local latest snapshot = the one whose blobs resolve successfully
      latest_rev=""
      latest_when=0
      for snap in "$repo_dir"/snapshots/*/; do
        [[ -d $snap ]] || continue
        if find "$snap" -type l -name '*.gguf' -print -quit 2>/dev/null | grep -q .; then
          ts=$(stat -c %Y "$snap" 2>/dev/null || echo 0)
          if (( ts > latest_when )); then
            latest_when=$ts; latest_rev=$(basename "$snap")
          fi
        fi
      done
      [[ -z $latest_rev ]] && continue

      remote_sha=$(curl -fsSL --max-time 10 \
        "https://huggingface.co/api/models/${repo}" 2>/dev/null \
        | grep -oE '"sha"[[:space:]]*:[[:space:]]*"[0-9a-f]{7,40}"' \
        | head -1 | grep -oE '[0-9a-f]{7,40}')

      if [[ -z $remote_sha ]]; then
        echo "  $repo  local=$latest_rev  remote=? (offline or not a model repo)"
      elif [[ ${remote_sha:0:7} == ${latest_rev:0:7} || $latest_rev == $remote_sha ]]; then
        echo "  $repo  up-to-date ($latest_rev)"
      else
        echo "  $repo  LOCAL=$latest_rev  REMOTE=$remote_sha  <-- UPDATE AVAILABLE"
        JSON_UPDATES+=("{\"repo\":\"$(json_escape "$repo")\",\"local\":\"$latest_rev\",\"remote\":\"$remote_sha\"}")
      fi
    done
  fi
fi

# --- llama.cpp cache (KV slots, downloaded models outside HF hub) -------------
hr
echo "llama.cpp cache: $LLAMA_CACHE"
if [[ ! -d $LLAMA_CACHE ]]; then
  echo "  (not found)"
else
  find "$LLAMA_CACHE" -maxdepth 2 -mindepth 1 -printf '%-12s  %p\n' \
    \( -type d -o -type f \) 2>/dev/null \
    | awk '{
        sz=$1; $1=""; sub(/^ /,"");
        printf "%-12s  %s\n", sz, $0
      }' \
    | while read -r line; do
        size=$(echo "$line" | awk '{print $1}')
        rest=$(echo "$line" | cut -d' ' -f2-)
        printf '  %-10s  %s\n' "$(bytes "$size")" "$rest"
      done
fi

# --- json output --------------------------------------------------------------
if [[ $JSON -eq 1 ]]; then
  printf '{"huggingface_cache":"%s","llama_cache":"%s","repos":[' \
    "$(json_escape "$HF_CACHE")" "$(json_escape "$LLAMA_CACHE")"
  ( IFS=,; printf '%s' "${JSON_REPOS[*]}" )
  printf '],"partial_downloads":['
  ( IFS=,; printf '%s' "${JSON_PARTIAL[*]:-}" )
  printf '],"older_snapshots":['
  ( IFS=,; printf '%s' "${JSON_OLD_SNAPSHOTS[*]:-}" )
  printf '],"remote_updates":['
  ( IFS=,; printf '%s' "${JSON_UPDATES[*]:-}" )
  printf ']}\n'
fi

hr
echo "Tip: clean partial downloads with:"
echo "  find $HF_CACHE/hub -name '*.incomplete' -delete"
echo "Tip: prune old snapshots with:"
echo "  hf cache delete --revision <OLD_REV> <repo>"