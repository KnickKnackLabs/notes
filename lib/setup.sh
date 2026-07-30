#!/usr/bin/env bash
# setup.sh — repository setup inspection and configuration

# Write tracked readable note paths as NUL-delimited repo-relative paths.
# Manifest-owned root IDs are the normal managed state and are omitted.
# Usage: write_tracked_readable_notes <repo> <notes-dir> <output>
write_tracked_readable_notes() {
  local repo="$1" notes_dir="$2" output="$3"
  local manifest="$repo/$notes_dir/.manifest"
  local tracked_snapshot tracked_path relpath blob_state blob_status
  local inspection_status=0

  tracked_snapshot=$(mktemp) || return 1
  if ! git -C "$repo" ls-files -z -- "$notes_dir" > "$tracked_snapshot"; then
    rm -f "$tracked_snapshot"
    return 1
  fi

  : > "$output"
  while IFS= read -r -d '' tracked_path; do
    relpath="${tracked_path#"$notes_dir"/}"
    [ "$relpath" = ".manifest" ] && continue

    blob_state=""
    blob_status=0
    blob_state=$(git_blob_encryption_state "$repo" ":$tracked_path") \
      || blob_status=$?
    if [ "$blob_status" -ne 0 ]; then
      echo "Error: failed to inspect indexed note blob: $tracked_path" >&2
      inspection_status=$blob_status
      break
    fi
    [ "$blob_state" = "encrypted" ] && continue

    case "$relpath" in
      */*) ;;
      *)
        if [ "$relpath" != "$tracked_path" ] \
            && [ -f "$manifest" ] \
            && awk -F '\t' -v id="$relpath" \
              '$1 == id { found = 1 } END { exit(found ? 0 : 1) }' "$manifest"; then
          continue
        fi
        ;;
    esac

    printf '%s\0' "$tracked_path" >> "$output"
  done < "$tracked_snapshot"

  rm -f "$tracked_snapshot"
  return "$inspection_status"
}

tracked_readable_note_count() {
  local snapshot="$1" count=0 _path
  while IFS= read -r -d '' _path; do
    count=$((count + 1))
  done < "$snapshot"
  printf '%s\n' "$count"
}

# A tracked-plaintext migration must begin clean, and an existing locked repo
# must unlock before setup changes .gitattributes.
require_tracked_plaintext_setup_ready() {
  local repo="$1" tracked_count="$2" initialized="$3" unlock_requested="$4"
  local status_snapshot

  [ "$tracked_count" -gt 0 ] || return 0

  status_snapshot=$(mktemp) || return 1
  if ! git -C "$repo" status --porcelain > "$status_snapshot"; then
    rm -f "$status_snapshot"
    echo "Error: failed to inspect worktree before tracked plaintext onboarding." >&2
    return 1
  fi
  if [ -s "$status_snapshot" ]; then
    rm -f "$status_snapshot"
    echo "Error: tracked plaintext note onboarding requires a clean worktree." >&2
    echo "Commit or preserve current changes, then rerun notes setup." >&2
    return 1
  fi
  rm -f "$status_snapshot"

  if $initialized && ! encryption_unlocked && ! $unlock_requested; then
    echo "Error: tracked plaintext note onboarding requires git-crypt to be unlocked before setup changes the worktree." >&2
    echo "Rerun with: notes setup --yes --unlock" >&2
    return 1
  fi
}

setup_gitattributes_has_encrypted_pattern() {
  local gitattributes="$1" pattern="$2"
  awk -v pattern="$pattern" '
    $1 == pattern {
      for (i = 2; i <= NF; i++) {
        if ($i == "filter=git-crypt") found = 1
      }
    }
    END { exit(found ? 0 : 1) }
  ' "$gitattributes" 2>/dev/null
}

# Configure requested patterns and preserve rudi's disabled-attribute repair.
# Usage: configure_setup_encrypted_patterns <repo> <pattern...>
configure_setup_encrypted_patterns() {
  local repo="$1"
  shift
  local gitattributes="$repo/.gitattributes"
  local pattern
  local missing_patterns=()

  for pattern in "$@"; do
    [ -z "$pattern" ] && continue
    if ! setup_gitattributes_has_encrypted_pattern "$gitattributes" "$pattern"; then
      missing_patterns+=("$pattern")
    fi
  done

  if [ ${#missing_patterns[@]} -eq 0 ]; then
    echo ""
    echo "  Requested encrypted patterns already configured"
    return 0
  fi

  echo ""
  echo "Configuring encrypted patterns..."
  for pattern in "${missing_patterns[@]}"; do
    (cd "$repo" && rudi assign "$pattern")
    if ! setup_gitattributes_has_encrypted_pattern "$gitattributes" "$pattern"; then
      # rudi can treat a disabled existing assignment as already configured.
      printf '%-40s filter=git-crypt diff=git-crypt\n' "$pattern" >> "$gitattributes"  # codebase:ignore
    fi
  done
  echo "  Updated .gitattributes"
}

# Print true when a file under the notes directory has a git-crypt header,
# otherwise false. Inspection failures preserve the backend exit status.
notes_tree_encryption_state() {
  local notes_dir="$1" snapshot file find_status=0 found=false
  if [ ! -d "$notes_dir" ]; then
    printf 'false\n'
    return 0
  fi

  snapshot=$(mktemp) || return 1
  find "$notes_dir" -type f ! -name .manifest -print0 > "$snapshot" || find_status=$?
  if [ "$find_status" -ne 0 ]; then
    rm -f "$snapshot"
    return "$find_status"
  fi

  while IFS= read -r -d '' file; do
    if head -c 10 "$file" 2>/dev/null | grep -q "GITCRYPT"; then
      found=true
      break
    fi
  done < "$snapshot"

  rm -f "$snapshot"
  printf '%s\n' "$found"
}
