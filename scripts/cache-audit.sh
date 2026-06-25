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
#   scripts/cache-audit.sh                       # audit default caches
#   scripts/cache-audit.sh --hf /p --llama /p    # override cache paths
#   scripts/cache-audit.sh --no-remote           # skip huggingface.co checks
#   scripts/cache-audit.sh --json                # machine-readable output
#   scripts/cache-audit.sh --wide                # don't truncate REPO column
#   scripts/cache-audit.sh --prune-partial       # delete *.incomplete/*.lock
#   scripts/cache-audit.sh --prune               # delete old snapshots
#   scripts/cache-audit.sh --remove-empty        # delete every repo with 0 GGUFs
#   scripts/cache-audit.sh --remove owner/name   # delete a specific repo (repeatable)
#   scripts/cache-audit.sh --prune --prune-partial --remove-empty --yes   # unattended
#
set -uo pipefail

# --- defaults -----------------------------------------------------------------
HF_CACHE="${HF_HUB_CACHE:-${HF_HOME:-/root/.cache/huggingface}}"
LLAMA_CACHE="${LLAMA_CACHE:-/root/.cache/llama.cpp}"
REMOTE=1
JSON=0
VERBOSE=0
PRUNE=0
PRUNE_PARTIAL=0
REMOVE_EMPTY=0
YES=0
WIDE=0
declare -a REMOVE_REPOS=()

# --- args ---------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --hf)            HF_CACHE="$2"; shift 2 ;;
    --llama)         LLAMA_CACHE="$2"; shift 2 ;;
    --no-remote)     REMOTE=0; shift ;;
    --json)          JSON=1; shift ;;
    --prune)         PRUNE=1; shift ;;
    --prune-partial) PRUNE_PARTIAL=1; shift ;;
    --remove-empty)  REMOVE_EMPTY=1; shift ;;
    --remove)        REMOVE_REPOS+=("$2"); shift 2 ;;
    --wide)          WIDE=1; shift ;;
    -y|--yes)        YES=1; shift ;;
    -v|--verbose)    VERBOSE=1; shift ;;
    -h|--help)
      sed -n '2,30p' "$0"; exit 0 ;;
    *)
      echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

# Helper used by --prune: prompt for confirmation unless --yes.
confirm() {
  local prompt=$1
  if [[ $YES -eq 1 ]]; then return 0; fi
  local ans
  read -r -p "$prompt [y/N] " ans </dev/tty
  [[ $ans =~ ^[Yy]([Ee][Ss])?$ ]]
}

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
  # Pick a REPO column width that fits every cached name (min 30, max 100).
  # --wide disables the fixed width entirely so the full name is always shown.
  REPO_W=30
  if [[ $WIDE -eq 0 ]]; then
    while IFS= read -r d; do
      [[ -z $d ]] && continue
      # d is "models--<owner>--<name>"; reconstruct "<owner>/<name>"
      n=${d#models--}; n=${n//--//}
      REPO_W=$(( REPO_W > ${#n} ? REPO_W : ${#n} ))
    done < <(find "$HF_CACHE/hub" -mindepth 1 -maxdepth 1 -type d -name 'models--*' 2>/dev/null)
    (( REPO_W > 100 )) && REPO_W=100
    (( REPO_W < 30 ))  && REPO_W=30
  fi
  hr
  printf '%-12s  %-'"$REPO_W"'s  %-10s  %-19s\n' "STATUS" "REPO" "GGUFs" "BLOB SIZE"
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
    if [[ $WIDE -eq 1 ]]; then
      printf '%-12s  %s  %-10s  %s\n' \
        "$status" "$repo" "$gguf_count" "$(bytes "$total_gguf_bytes")"
    else
      printf '%-12s  %-'"$REPO_W"'s  %-10s  %s\n' \
        "$status" "$repo" "$gguf_count" "$(bytes "$total_gguf_bytes")"
    fi
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
# --- remove specific repos ----------------------------------------------------
# Usage: --remove owner/name   (repeatable)
#         --remove-empty       (every repo that has 0 GGUFs and no partials)
# Converts "owner/name" to the on-disk directory "models--owner--name",
# shows what's about to be deleted, prompts unless --yes, then rm -rf's it.
remove_repo() {
  local spec=$1
  local dir_name="models--${spec//\//--}"
  local repo_dir="$HF_CACHE/hub/$dir_name"

  # Prefix-tolerant lookup: if the literal name isn't on disk, look for any
  # models--<owner>--<name>* directory whose suffix matches what the user
  # typed (handles terminals that truncate the display of long repo names).
  if [[ ! -d $repo_dir ]]; then
    local owner=${spec%%/*} name=${spec#*/}
    if [[ -n $owner && -n $name && $owner != $spec ]]; then
      local matches=( "$HF_CACHE"/hub/models--${owner}--${name}* )
      # filter to actual directories only (glob may pass literal if no match)
      local real_matches=()
      for m in "${matches[@]}"; do
        [[ -d $m ]] && real_matches+=("$m")
      done
      if [[ ${#real_matches[@]} -eq 1 ]]; then
        repo_dir=${real_matches[0]}
        dir_name=$(basename "$repo_dir")
        echo "  (matched by prefix → $dir_name)"
      elif [[ ${#real_matches[@]} -gt 1 ]]; then
        echo "  [skip] $spec — ambiguous prefix, ${#real_matches[@]} candidates:" >&2
        printf '    %s\n' "${real_matches[@]}" >&2
        return 1
      fi
    fi
    if [[ ! -d $repo_dir ]]; then
      echo "  [skip] $spec — not present at $repo_dir" >&2
      echo "         (cached repos start with: $HF_CACHE/hub/models--<owner>--<name>)" >&2
      return 1
    fi
  fi

  # summary
  local size; size=$(du -sb "$repo_dir" 2>/dev/null | awk '{print $1}')
  local ggufs; ggufs=$(find "$repo_dir/snapshots" -type l -name '*.gguf' 2>/dev/null | wc -l)
  local revs; revs=$(find "$repo_dir/snapshots" -mindepth 1 -maxdepth 1 -type d 2>/dev/null \
                     | xargs -n1 basename 2>/dev/null | tr '\n' ' ')

  echo "About to remove: $spec"
  echo "  path    : $repo_dir"
  echo "  size    : $(bytes "$size")"
  echo "  ggufs   : $ggufs"
  [[ -n $revs ]] && echo "  revs    : $revs"

  if ! confirm "  confirm deletion?"; then
    echo "  [kept] $spec"
    return 0
  fi

  rm -rf -- "$repo_dir"
  echo "  [removed] $spec (freed ~$(bytes "$size"))"
}

if [[ $REMOVE_EMPTY -eq 1 && $HF_HAS -eq 1 ]]; then
  hr
  echo "Removing empty repos (no GGUFs, no partial downloads)..."
  for repo_dir in "$HF_CACHE"/hub/models--*; do
    [[ -d $repo_dir ]] || continue
    ggufs=$(find "$repo_dir/snapshots" -type l -name '*.gguf' 2>/dev/null | wc -l)
    partial=$(find "$repo_dir/blobs" -type f \( -name '*.incomplete' -o -name '*.lock' \) 2>/dev/null | wc -l)
    if [[ $ggufs -eq 0 && $partial -eq 0 ]]; then
      dir=$(basename "$repo_dir"); spec="${dir#models--}"; spec="${spec//--//}"
      remove_repo "$spec"
    fi
  done
fi

for spec in "${REMOVE_REPOS[@]:-}"; do
  [[ -z $spec ]] && continue
  hr
  remove_repo "$spec"
done

hr
# --- prune actions ------------------------------------------------------------
if [[ $PRUNE_PARTIAL -eq 1 && $HF_HAS -eq 1 ]]; then
  hr
  echo "Pruning partial downloads (*.incomplete, *.lock)..."
  freed=0
  while IFS= read -r -d '' f; do
    sz=$(stat -c %s "$f" 2>/dev/null || stat -f %z "$f" 2>/dev/null || echo 0)
    freed=$(( freed + sz ))
    if confirm "  delete $(basename "$(dirname "$f")")/$(basename "$f") ($(bytes "$sz"))?"; then
      rm -f -- "$f"
    fi
  done < <(find "$HF_CACHE/hub" -type f \( -name '*.incomplete' -o -name '*.lock' \) -print0 2>/dev/null)
  echo "Freed ~$(bytes "$freed") of partial data."
fi

if [[ $PRUNE -eq 1 && $HF_HAS -eq 1 ]]; then
  hr
  echo "Pruning older snapshots (keeps the newest revision per repo)..."
  freed=0
  for repo_dir in "$HF_CACHE"/hub/models--*; do
    [[ -d $repo_dir/snapshots ]] || continue
    revs=( "$repo_dir"/snapshots/*/ )
    [[ ${#revs[@]} -le 1 ]] && continue
    sorted=( $(ls -1dt "${revs[@]}" 2>/dev/null) )
    keep=${sorted[0]}
    for r in "${sorted[@]:1}"; do
      rev=$(basename "$r")
      sz=$(du -sb "$r" 2>/dev/null | awk '{print $1}')
      freed=$(( freed + sz ))
      if confirm "  delete $rev ($(bytes "$sz")) under $(basename "$repo_dir")?"; then
        # Remove the snapshot directory and its symlinks; blobs are shared
        # via refcount so they stay as long as the surviving snapshot uses
        # them. Truly orphaned blobs would need a follow-up `find ... -links 1`
        # pass — left to the operator.
        rm -rf -- "$r"
      fi
    done
  done
  echo "Freed ~$(bytes "$freed") of snapshot references."
  echo "Note: blobs are content-addressed; truly orphaned blobs can be removed with:"
  echo "  find $HF_CACHE/hub -type f ! -links 1 -path '*/blobs/*' -prune -o \\"
  echo "         -type l -path '*/snapshots/*' -prune -o \\"
  echo "         -type f -path '*/blobs/*' -print | while read -r f; do"
  echo "    [ \$(stat -c %h \"\$f\") -le 1 ] && rm -f -- \"\$f\""
  echo "  done"
fi

if [[ $JSON -eq 0 ]]; then
  hr
  echo "Cleanup commands (pure bash — no 'hf' CLI required):"
  echo "  # delete all partial downloads:"
  echo "  find $HF_CACHE/hub -type f \\( -name '*.incomplete' -o -name '*.lock' \\) -delete"
  echo
  echo "  # delete a specific snapshot revision (example: abc1234):"
  echo "  rm -rf $HF_CACHE/hub/models--<owner>--<name>/snapshots/<OLD_REV>"
  echo
  echo "  # remove blob files no longer referenced by any snapshot:"
  echo "  find $HF_CACHE/hub/models--* -type f -path '*/blobs/*' ! -links 1 -delete"
  echo
  echo "Or let this script do it:"echo "  $0 --wide                        # show full repo names (no truncation)"  echo "  $0 --prune-partial"
echo "  $0 --prune                       # keeps newest snapshot per repo"
echo "  $0 --remove-empty                # drops every repo with 0 GGUFs"
echo "  $0 --remove owner/name           # drops a specific repo (repeatable)"
echo "  $0 --remove-empty --prune --prune-partial --yes    # unattended"
fi