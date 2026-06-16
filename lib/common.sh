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

# ── Path helpers ────────────────────────────────────────────

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
  [ ! -f "$manifest" ] && return 0

  while IFS=$'\t' read -r id relpath; do
    [ -z "$id" ] && continue
    # If the readable path is tracked in git's index, it's double-tracked.
    if git -C "$repo_root" ls-files --error-unmatch -- "$notes_dir_rel/$relpath" >/dev/null 2>&1; then
      printf '%s\t%s\n' "$id" "$relpath"
    fi
  done < "$manifest"
}
