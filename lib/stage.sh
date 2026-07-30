#!/usr/bin/env bash
# stage.sh — Git index mutations for readable note staging

# Restore one tracked path to the exact index entry present before staging.
restore_tracked_note_index() {
  local repo="$1" readable_path="$2" mode="$3" blob="$4"
  if ! git -C "$repo" update-index --cacheinfo \
      "$mode" "$blob" "$readable_path"; then
    echo "Error: failed to restore index entry after staging refusal: $readable_path" >&2
    return 1
  fi
}

# Stage one readable note. Existing tracked plaintext paths are renormalized so
# a newly-added clean filter replaces their unchanged plaintext index blobs.
# Restore the prior entry if post-staging ciphertext verification refuses it.
stage_readable_note() {
  local repo="$1" notes_dir="$2" relpath="$3"
  local readable_path="$notes_dir/$relpath"
  local tracked_readable=false
  local original_entry original_metadata original_mode original_blob original_stage

  if git -C "$repo" ls-files --error-unmatch -- "$readable_path" >/dev/null 2>&1; then
    tracked_readable=true
    original_entry=$(git -C "$repo" ls-files --stage -- "$readable_path") || return 1
    original_metadata="${original_entry%%$'\t'*}"
    read -r original_mode original_blob original_stage <<< "$original_metadata"
    if [ "$original_stage" != "0" ] || [ -z "$original_blob" ]; then
      echo "Error: tracked readable note has no ordinary index entry: $relpath" >&2
      return 1
    fi
    git -C "$repo" add -f --renormalize -- "$readable_path"
  else
    git -C "$repo" add -f -- "$readable_path"
  fi

  local index_blob head_blob="" blob_state blob_status=0
  if ! index_blob=$(git -C "$repo" rev-parse ":$readable_path" 2>/dev/null); then
    echo "Error: staging did not create an index entry for: $relpath" >&2
    if $tracked_readable; then
      restore_tracked_note_index \
        "$repo" "$readable_path" "$original_mode" "$original_blob" || return 1
    fi
    return 1
  fi
  if git -C "$repo" cat-file -e "HEAD:$readable_path" 2>/dev/null; then
    head_blob=$(git -C "$repo" rev-parse "HEAD:$readable_path")
  fi
  if $tracked_readable && [ -n "$head_blob" ] && [ "$index_blob" = "$head_blob" ]; then
    echo "Error: staging produced no index change for tracked readable note: $relpath" >&2
    echo "Ensure setup configured an active encryption filter, then retry." >&2
    restore_tracked_note_index \
      "$repo" "$readable_path" "$original_mode" "$original_blob" || return 1
    return 1
  fi

  if $tracked_readable; then
    blob_state=$(git_blob_encryption_state "$repo" ":$readable_path") \
      || blob_status=$?
    if [ "$blob_status" -ne 0 ]; then
      echo "Error: failed to inspect staged note blob: $relpath" >&2
      restore_tracked_note_index \
        "$repo" "$readable_path" "$original_mode" "$original_blob" || return 1
      return "$blob_status"
    fi
    if [ "$blob_state" != "encrypted" ]; then
      echo "Error: staged tracked readable note is not git-crypt encrypted: $relpath" >&2
      echo "Ensure setup configured an active encryption filter, then retry." >&2
      restore_tracked_note_index \
        "$repo" "$readable_path" "$original_mode" "$original_blob" || return 1
      return 1
    fi
  fi

  echo "  staged: $relpath"
}

# Remove one deleted note's indexed ID and stage its manifest repair. Preserve
# the working manifest if staging the repair fails.
stage_deleted_note() {
  local repo="$1" notes_dir="$2" manifest="$3" relpath="$4"
  local id tmp_manifest manifest_backup

  id=$(manifest_id_for_name "$manifest" "$relpath")
  [ -n "$id" ] || return 0

  if git -C "$repo" ls-files --error-unmatch -- "$notes_dir/$id" >/dev/null 2>&1; then
    git -C "$repo" rm --cached --quiet "$notes_dir/$id"
  fi

  tmp_manifest=$(mktemp) || return 1
  manifest_backup=$(mktemp) || {
    rm -f "$tmp_manifest"
    return 1
  }
  cp "$manifest" "$manifest_backup"
  awk -F '\t' -v path="$relpath" '$2 != path { print $0 }' \
    "$manifest" > "$tmp_manifest"
  mv -f "$tmp_manifest" "$manifest"

  if ! git -C "$repo" add -f "$notes_dir/.manifest"; then
    mv -f "$manifest_backup" "$manifest"
    return 1
  fi

  rm -f "$manifest_backup"
  echo "  staged (delete): $relpath"
}
