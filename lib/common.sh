#!/usr/bin/env bash
# common.sh — shared helpers for notes tasks
#
# This file contains require checks and manifest helpers used by all tasks.
# Specialized functionality lives in separate files:
#   - obfuscate.sh — Layer 1 filesystem rename operations
#   - suppress.sh  — status suppression (assume-unchanged + exclude)
#   - hooks.sh     — git hook installation

# Prefer the notes-specific caller dir to avoid inheriting stale generic
# caller context from another shiv-managed tool. Direct repo-local task runs
# fall back to the current working directory.
TARGET_DIR="${NOTES_CALLER_PWD:-.}"

NOTES_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NOTES_REPO_DIR="$(cd "$NOTES_LIB_DIR/.." && pwd)"
HOOKS_DIR="$NOTES_REPO_DIR/hooks"
source "$NOTES_LIB_DIR/readable-state.sh"

# ── Require checks ────────────────────────────────────────────

require_git() {
  if ! git -C "$TARGET_DIR" rev-parse --git-dir &>/dev/null; then
    echo "Error: not a git repository: $TARGET_DIR" >&2
    exit 1
  fi
}

require_rudi() {
  if ! command -v rudi &>/dev/null; then
    echo "Error: rudi not found. Install it: shiv install rudi" >&2
    exit 1
  fi
}

is_initialized() {
  [ -d "$TARGET_DIR/.git-crypt" ] || [ -d "$TARGET_DIR/.git/git-crypt" ]
}

# Return success when rudi reports TARGET_DIR is unlocked.
# On rudi/jq failure, return false so callers surface the real unlock error.
encryption_unlocked() {
  local unlocked
  unlocked=$(rudi status --json 2>/dev/null | jq -r '.unlocked' 2>/dev/null) || return 1
  [ "$unlocked" = "true" ]
}

require_initialized() {
  if ! is_initialized; then
    echo "Error: git-crypt not initialized. Run: notes setup" >&2
    exit 1
  fi
}

# ── Assume-unchanged manifest detection ────────────────────

# Check if notes/.manifest is marked assume-unchanged and if it differs from
# HEAD. This catches a state where `git pull` would fail because Git sees
# "local changes" to the manifest, but git status and notes changes both
# report clean (because assume-unchanged hides the difference).
#
# Usage: detect_assume_unchanged_manifest <notes_dir>
# Returns:
#   0 — manifest is assume-unchanged and worktree differs from HEAD (needs repair)
#   1 — manifest is assume-unchanged but worktree matches HEAD (safe to clear)
#   2 — manifest is NOT assume-unchanged (no problem)
#   3 — unable to determine (e.g. HEAD has no manifest yet)
#
# Side-effect: prints a diagnostic message to stderr when state is 0 or 1.
# Set NOTES_QUIET_MANIFEST_CHECK=1 to suppress diagnostic output.
detect_assume_unchanged_manifest() {
  local notes_dir="${1:?usage: detect_assume_unchanged_manifest <notes_dir>}"
  local manifest="$TARGET_DIR/$notes_dir/.manifest"

  [ -f "$manifest" ] || return 2

  # Check if assume-unchanged is set
  local assume_flag
  assume_flag=$(git -C "$TARGET_DIR" ls-files -v "$notes_dir/.manifest" 2>/dev/null | cut -c1)
  if [ "$assume_flag" != "h" ]; then
    return 2  # not assume-unchanged, no problem
  fi

  # Check if HEAD has the manifest
  if ! git -C "$TARGET_DIR" cat-file -e "HEAD:$notes_dir/.manifest" 2>/dev/null; then
    [ -z "${NOTES_QUIET_MANIFEST_CHECK:-}" ] && echo "Warning: $notes_dir/.manifest is assume-unchanged but HEAD has no manifest entry yet." >&2
    return 3
  fi

  # Compare worktree to HEAD
  local worktree_hash head_hash
  worktree_hash=$(git -C "$TARGET_DIR" hash-object "$manifest" 2>/dev/null) || return 3
  head_hash=$(git -C "$TARGET_DIR" rev-parse "HEAD:$notes_dir/.manifest" 2>/dev/null) || return 3

  if [ "$worktree_hash" = "$head_hash" ]; then
    # Worktree matches HEAD — safe to clear assume-unchanged
    [ -z "${NOTES_QUIET_MANIFEST_CHECK:-}" ] && echo "Warning: $notes_dir/.manifest is assume-unchanged (matches HEAD). Clear with: git update-index --no-assume-unchanged $notes_dir/.manifest" >&2
    return 1
  else
    # Worktree differs from HEAD — need manual repair
    [ -z "${NOTES_QUIET_MANIFEST_CHECK:-}" ] && echo "Warning: $notes_dir/.manifest is assume-unchanged and DIFFERS from HEAD." >&2
    [ -z "${NOTES_QUIET_MANIFEST_CHECK:-}" ] && echo "  Clear and stage: git update-index --no-assume-unchanged $notes_dir/.manifest && git add $notes_dir/.manifest" >&2
    return 0
  fi
}

# Clear assume-unchanged on notes/.manifest when it's safe (worktree matches HEAD).
# Usage: repair_assume_unchanged_manifest <notes_dir>
# Returns: 0 if cleared, 1 if not needed, 2 if cleared but content differs from HEAD.
repair_assume_unchanged_manifest() {
  local notes_dir="${1:?usage: repair_assume_unchanged_manifest <notes_dir>}"
  local manifest="$TARGET_DIR/$notes_dir/.manifest"

  local rc=0
  detect_assume_unchanged_manifest "$notes_dir" || rc=$?

  if [ "$rc" -eq 2 ] || [ "$rc" -eq 3 ]; then
    return 1  # not needed or can't determine
  fi

  git -C "$TARGET_DIR" update-index --no-assume-unchanged "$notes_dir/.manifest"
  echo "Cleared assume-unchanged on $notes_dir/.manifest" >&2

  if [ "$rc" -eq 0 ]; then
    return 2  # cleared but content differs from HEAD
  fi

  return 0
}

# ── Confirmation helpers ─────────────────────────────────────

is_truthy() {
  case "${1:-}" in
    true|1|yes|y) return 0 ;;
    *) return 1 ;;
  esac
}

confirm_destructive() {
  local message="$1"
  local tty_path="${NOTES_CONFIRM_TTY:-/dev/tty}"
  local answer=""

  if is_truthy "${usage_yes:-false}" || is_truthy "${NOTES_YES:-}" || is_truthy "${MISE_YES:-}"; then
    return 0
  fi

  if [ ! -c "$tty_path" ] || ! { : <"$tty_path"; } 2>/dev/null || ! { : >"$tty_path"; } 2>/dev/null; then
    echo "Error: confirmation required for destructive operation." >&2
    echo "$message" >&2
    echo "Re-run with --yes to confirm." >&2
    return 2
  fi

  if command -v gum >/dev/null 2>&1; then
    # A terminal device intentionally carries prompt input, output, and errors.
    # shellcheck disable=SC2094
    if gum confirm "$message" <"$tty_path" >"$tty_path" 2>"$tty_path"; then
      return 0
    fi
    echo "Aborted." >&2
    return 2
  fi

  { printf '%s [y/N] ' "$message" >"$tty_path"; } 2>/dev/null
  if ! IFS= read -r answer <"$tty_path"; then
    answer=""
  fi

  case "$answer" in
    y|Y|yes|YES) return 0 ;;
    *)
      echo "Aborted." >&2
      return 2
      ;;
  esac
}

# Argument helpers

# Parse mise's shell-quoted variadic argument string.
#
# Callers must snapshot this output before consuming it. A process substitution
# would hide xargs/printf failures behind the consumer loop's exit status.
# Usage: parse_variadic_args <raw-usage-value>
parse_variadic_args() {
  local raw="${1:-}" status=0
  [ -n "$raw" ] || return 0

  (
    set -o pipefail
    printf '%s' "$raw" | xargs printf '%s\n'
  ) || status=$?
  if [ "$status" -ne 0 ]; then
    echo "Error: failed to parse variadic arguments." >&2
    return "$status"
  fi
}

# Path helpers

# Resolve the notes directory path relative to the repo root.
# Handles macOS symlinks (/tmp → /private/tmp) by resolving real paths.
# Usage: resolve_notes_dir <abs_notes_dir>
# Sets: RESOLVED_REPO_ROOT, RESOLVED_NOTES_DIR (relative)
resolve_notes_dir() {
  local abs_notes_dir="$1"
  local repo_root
  repo_root=$(git -C "$abs_notes_dir" rev-parse --show-toplevel 2>/dev/null) || return

  # Resolve symlinks so path stripping works on macOS
  local real_notes real_root
  real_notes=$(cd "$abs_notes_dir" && pwd -P)
  real_root=$(cd "$repo_root" && pwd -P)

  RESOLVED_REPO_ROOT="$repo_root"
  RESOLVED_NOTES_DIR="${real_notes#"$real_root"/}"
}

# ── Manifest helpers ──────────────────────────────────────────
# Manifest format: <id>\t<name>
# All functions take the manifest path as first arg.

# Look up id by name. Prints id or nothing.
manifest_id_for_name() {
  local manifest="$1" name="$2"
  [ ! -f "$manifest" ] && return
  while IFS=$'\t' read -r id entry_name; do
    if [ "$entry_name" = "$name" ]; then
      printf '%s' "$id"
      return
    fi
  done < "$manifest"
}

# Check if an id exists in the manifest.
manifest_has_id() {
  local manifest="$1" id="$2"
  [ -f "$manifest" ] && grep -q "^${id}"$'\t' "$manifest"
}

# Look up name by id. Prints name or nothing.
manifest_name_for_id() {
  local manifest="$1" id="$2"
  [ ! -f "$manifest" ] && return
  grep "^${id}"$'\t' "$manifest" | cut -f2
}

# Validate explicit readable-note paths before selected-path classifiers inspect
# the filesystem. Corpus discovery never treats the manifest, obfuscated IDs,
# or paths reached through symlinks as readable-note candidates.
# Usage: validate_explicit_readable_note_paths <abs_notes_dir> <manifest> <relpath...>
validate_explicit_readable_note_paths() {
  local abs_notes_dir="${1:?usage: validate_explicit_readable_note_paths <abs_notes_dir> <manifest> <relpath...>}"
  local manifest="${2:?usage: validate_explicit_readable_note_paths <abs_notes_dir> <manifest> <relpath...>}"
  shift 2
  local unknown=() components=() relpath component current base
  require_readable_notes_state "$abs_notes_dir" || return

  for relpath in "$@"; do
    case "$relpath" in
      ""|/*|..|../*|*/../*|.|./*|*/./*|*/|.manifest)
        unknown+=("$relpath")
        continue
        ;;
    esac

    current="$abs_notes_dir"
    IFS='/' read -r -a components <<< "$relpath"
    for component in "${components[@]}"; do
      current="$current/$component"
      if [ -L "$current" ]; then
        unknown+=("$relpath")
        continue 2
      fi
    done

    base="${relpath##*/}"
    if manifest_has_id "$manifest" "$base"; then
      unknown+=("$relpath")
      continue
    fi
    if [ -f "$abs_notes_dir/$relpath" ] || [ -n "$(manifest_id_for_name "$manifest" "$relpath")" ]; then
      continue
    fi
    unknown+=("$relpath")
  done

  if [ ${#unknown[@]} -eq 0 ]; then
    return 0
  fi

  echo "Error: requested note path(s) are not known readable notes:" >&2
  for relpath in "${unknown[@]}"; do
    echo "  $relpath" >&2
  done
  return 1
}

# Detect double-tracking only for explicit readable paths. This retains the
# selected-path guard without enumerating unrelated tracked notes.
# Usage: detect_selected_double_tracked_notes <repo_root> <notes_dir_rel> <relpath...>
detect_selected_double_tracked_notes() {
  local repo_root="${1:?usage: detect_selected_double_tracked_notes <repo_root> <notes_dir_rel> <relpath...>}"
  local notes_dir_rel="${2:?usage: detect_selected_double_tracked_notes <repo_root> <notes_dir_rel> <relpath...>}"
  shift 2
  local selected=("$@") manifest="$repo_root/$notes_dir_rel/.manifest"
  [ -f "$manifest" ] || return 0
  [ ${#selected[@]} -gt 0 ] || return 0

  local workspace snapshot tracked_paths tracked_path
  workspace=$(mktemp -d) || return 1
  snapshot="$workspace/snapshot"
  tracked_paths="$workspace/tracked-paths"
  if ! git -C "$repo_root" ls-files -z -- "${selected[@]/#/$notes_dir_rel/}" > "$snapshot"; then
    rm -rf "$workspace"
    return 1
  fi
  while IFS= read -r -d '' tracked_path; do
    printf '%s\n' "$tracked_path"
  done < "$snapshot" > "$tracked_paths"

  local id relpath wanted
  while IFS=$'\t' read -r id relpath; do
    [ -n "$id" ] || continue
    wanted=false
    for candidate in "${selected[@]}"; do
      [ "$candidate" = "$relpath" ] && wanted=true && break
    done
    $wanted || continue
    if grep -Fxq "$notes_dir_rel/$relpath" "$tracked_paths"; then
      printf '%s\t%s\n' "$id" "$relpath"
    fi
  done < "$manifest"
  local rc=$?
  rm -rf "$workspace"
  return "$rc"
}

# Detect notes that are tracked both as readable names and as obfuscated IDs.
# This is the double-tracking bug from notes#51: a readable-named file got
# committed alongside its obfuscated hex counterpart, causing silent content
# drift on every subsequent commit.
#
# Outputs one line per double-tracked note: "<id>\t<relpath>"
# Usage: detect_double_tracked_notes <repo_root> <notes_dir_rel>
detect_double_tracked_notes() {
  local repo_root="${1:?usage: detect_double_tracked_notes <repo_root> <notes_dir_rel>}"
  local notes_dir_rel="${2:?usage: detect_double_tracked_notes <repo_root> <notes_dir_rel>}"
  local manifest="$repo_root/$notes_dir_rel/.manifest"
  local workspace snapshot tracked_paths tracked_path rc
  [ ! -f "$manifest" ] && return 0

  workspace=$(mktemp -d) || return 1
  snapshot="$workspace/snapshot"
  tracked_paths="$workspace/tracked-paths"
  if ! git -C "$repo_root" ls-files -z -- "$notes_dir_rel" > "$snapshot"; then
    rm -rf "$workspace"
    return 1
  fi

  # Git quotes backslashes, quotes, and control characters in line-delimited
  # output even with core.quotePath=false. Read its NUL-delimited snapshot and
  # normalize the manifest-representable paths without starting more processes.
  while IFS= read -r -d '' tracked_path; do
    printf '%s\n' "$tracked_path"
  done < "$snapshot" > "$tracked_paths"

  awk -F '\t' -v tracked_file="$tracked_paths" -v prefix="$notes_dir_rel/" '
    FILENAME == tracked_file { tracked[$0] = 1; next }
    $1 != "" && ((prefix $2) in tracked) { print $1 "\t" $2 }
  ' "$tracked_paths" "$manifest"
  rc=$?
  rm -rf "$workspace"
  return "$rc"
}
