#!/usr/bin/env bash
# readable-state.sh — classify whether managed note content is readable

_GIT_CRYPT_HEADER_HEX="00474954435259505400"

# Print "readable" or "locked" for a notes directory.
# Missing/non-Git/plaintext note directories remain readable so their owning
# commands can preserve their existing validation and initialization behavior.
notes_readable_state() {
  local notes_dir="${1:?usage: notes_readable_state <notes_dir>}"
  local abs_notes_dir repo_root rel_notes_dir manifest attr filter header

  if [ ! -d "$notes_dir" ]; then
    printf '%s\n' "readable"
    return 0
  fi
  if ! abs_notes_dir=$(cd "$notes_dir" 2>/dev/null && pwd -P); then
    echo "Error: failed to resolve notes directory: $notes_dir" >&2
    return 2
  fi
  if ! repo_root=$(git -C "$abs_notes_dir" rev-parse --show-toplevel 2>/dev/null); then
    printf '%s\n' "readable"
    return 0
  fi

  case "$abs_notes_dir" in
    "$repo_root"/*) rel_notes_dir=${abs_notes_dir#"$repo_root"/} ;;
    *)
      echo "Error: notes directory is outside its Git repository: $abs_notes_dir" >&2
      return 2
      ;;
  esac

  manifest="$abs_notes_dir/.manifest"
  if [ ! -f "$manifest" ]; then
    printf '%s\n' "readable"
    return 0
  fi

  if ! attr=$(git -C "$repo_root" check-attr filter -- "$rel_notes_dir/.manifest"); then
    echo "Error: failed to inspect encryption attributes for $rel_notes_dir/.manifest" >&2
    return 2
  fi
  filter=${attr##*: }
  if [ "$filter" != "git-crypt" ]; then
    printf '%s\n' "readable"
    return 0
  fi

  if ! header=$(LC_ALL=C od -An -tx1 -N10 "$manifest" 2>/dev/null); then
    echo "Error: failed to inspect encrypted manifest header: $manifest" >&2
    return 2
  fi
  header=$(printf '%s' "$header" | tr -d '[:space:]')

  if [ "$header" = "$_GIT_CRYPT_HEADER_HEX" ]; then
    printf '%s\n' "locked"
  else
    printf '%s\n' "readable"
  fi
}

require_readable_notes_state() {
  local notes_dir="${1:?usage: require_readable_notes_state <notes_dir>}"
  local state status=0

  state=$(notes_readable_state "$notes_dir") || status=$?
  if [ "$status" -ne 0 ]; then
    return "$status"
  fi
  if [ "$state" = "locked" ]; then
    echo "Error: git-crypt is locked. Run 'notes unlock' first." >&2
    return 1
  fi
}

_readable_state_main() {
  local command="${1:-}"
  local notes_dir="${2:-}"

  case "$command" in
    probe)
      [ -n "$notes_dir" ] || { echo "usage: readable-state.sh probe <notes-dir>" >&2; return 64; }
      notes_readable_state "$notes_dir"
      ;;
    require)
      [ -n "$notes_dir" ] || { echo "usage: readable-state.sh require <notes-dir>" >&2; return 64; }
      require_readable_notes_state "$notes_dir"
      ;;
    *)
      echo "usage: readable-state.sh <probe|require> <notes-dir>" >&2
      return 64
      ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -uo pipefail
  _readable_state_main "$@"
fi
