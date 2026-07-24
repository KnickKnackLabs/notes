#!/usr/bin/env bash
# obfuscate.sh — Layer 1: Filesystem + Manifest operations
# Pure renames + manifest updates. No git staging, no suppression.

# Refuse to proceed if a filename's basename looks like an obfuscated id.
# An obfuscated id is 8 lowercase hex characters with no extension.
#
# Callers rely on `manifest_has_id` to detect "already obfuscated, skip." If
# the manifest is inconsistent (stale, lost entries, orphan blobs), that
# check can miss and the file would be re-obfuscated under a new random id,
# creating a duplicate blob and masking the underlying problem. Better to
# fail loudly and make the user investigate.
#
# Returns 0 (proceed) if the basename is a normal filename.
# Returns 1 (stop) and prints diagnostic to stderr if it looks obfuscated.
refuse_if_hex_basename() {
  local relpath="$1"
  local base
  base=$(basename "$relpath")
  if [[ "$base" =~ ^[a-f0-9]{8}$ ]]; then
    cat >&2 <<EOF
Error: refusing to obfuscate '$relpath' — basename looks like an obfuscated id.

  This indicates the manifest is inconsistent with the working tree. Possible
  causes:
    - Stale manifest that lost the mapping for an already-obfuscated file
    - Orphan obfuscated blob with no manifest entry
    - Readable file created with a hash-shaped name (unusual)

  Re-obfuscating would create a duplicate blob under a fresh random id and
  hide the underlying problem. Fix the manifest first, then retry.

  Diagnose with: notes status, notes changes
EOF
    return 1
  fi
  return 0
}

# Rename readable files to obfuscated IDs.
# Outputs "<relpath>\t<id>" per renamed file (for callers to stage).
# Usage: rename_to_obfuscated <notes_dir> [file...]
#   Without files: scans notes_dir for all non-obfuscated files.
#   With files: only processes the listed files (relative to notes_dir).
rename_to_obfuscated() {
  local notes_dir="$1"
  shift
  local scoped_files=("$@")
  local manifest="$notes_dir/.manifest"

  local to_rename=() to_restore=()
  local scoped_mode=false

  if [ ${#scoped_files[@]} -gt 0 ] && [ -n "${scoped_files[0]}" ]; then
    scoped_mode=true
    for relpath in "${scoped_files[@]}"; do
      [[ "$relpath" == ".manifest" ]] && continue
      [ ! -f "$notes_dir/$relpath" ] && continue

      local base
      base=$(basename "$relpath")
      if manifest_has_id "$manifest" "$base"; then
        continue  # already obfuscated
      fi

      # Refuse to obfuscate a file whose basename already looks like an
      # obfuscated id (8 hex chars, no extension). This only happens when
      # the manifest is inconsistent with the working tree — e.g., a stale
      # manifest lost the mapping for an already-obfuscated file, or an
      # orphan obfuscated blob exists without an entry. Re-obfuscating
      # would create a duplicate blob under a fresh random id and hide
      # the real problem (as happened on den/fold through April 2026).
      refuse_if_hex_basename "$relpath" || return 1

      local existing_id
      if ! existing_id=$(manifest_id_for_name "$manifest" "$relpath"); then
        existing_id=""
      fi
      if [ -n "$existing_id" ]; then
        to_restore+=("$relpath")
      else
        to_rename+=("$relpath")
      fi
    done
  else
    while IFS= read -r f; do
      [ ! -f "$f" ] && continue
      local relpath="${f#"$notes_dir"/}"
      [[ "$relpath" == ".manifest" ]] && continue

      local base
      base=$(basename "$f")
      if manifest_has_id "$manifest" "$base"; then
        continue
      fi

      refuse_if_hex_basename "$relpath" || return 1

      local existing_id
      if ! existing_id=$(manifest_id_for_name "$manifest" "$relpath"); then
        existing_id=""
      fi
      if [ -n "$existing_id" ]; then
        to_restore+=("$relpath")
      else
        to_rename+=("$relpath")
      fi
    done < <(find "$notes_dir" -type f | sort)
  fi

  if [ ${#to_rename[@]} -eq 0 ] && [ ${#to_restore[@]} -eq 0 ]; then
    return 2  # nothing to do (distinct from error)
  fi

  # Track new manifest entries
  local new_entries
  new_entries=$(mktemp) || { echo "Error: failed to create temp file" >&2; return 1; }

  # Restore files to their known IDs
  for relpath in ${to_restore[@]+"${to_restore[@]}"}; do
    local id
    if ! id=$(manifest_id_for_name "$manifest" "$relpath"); then
      id=""
    fi
    if ! mv "$notes_dir/$relpath" "$notes_dir/$id"; then
      echo "Error: failed to rename $relpath → $id" >&2
      rm -f "$new_entries"
      return 1
    fi
    printf '%s\t%s\n' "$relpath" "$id"
  done

  # Generate IDs and rename new files
  for relpath in ${to_rename[@]+"${to_rename[@]}"}; do
    local id
    id=$(openssl rand -hex 4)
    while manifest_has_id "$manifest" "$id" || \
          grep -q "^${id}"$'\t' "$new_entries" 2>/dev/null || \
          [ -f "$notes_dir/$id" ]; do
      id=$(openssl rand -hex 4)
    done

    printf '%s\t%s\n' "$id" "$relpath" >> "$new_entries"
    if ! mv "$notes_dir/$relpath" "$notes_dir/$id"; then
      echo "Error: failed to rename $relpath → $id" >&2
      rm -f "$new_entries"
      return 1
    fi
    printf '%s\t%s\n' "$relpath" "$id"
  done

  # Empty-directory cleanup is cosmetic and must not invalidate completed renames.
  if ! find "$notes_dir" -mindepth 1 -type d -empty -delete 2>/dev/null; then
    :
  fi

  # Scoped re-obfuscation of existing manifest entries should not rewrite the
  # manifest at all. Re-sorting a valid but differently-ordered manifest creates
  # an order-only dirty worktree after the pre-commit hook, because scoped
  # obfuscation intentionally does not stage unchanged manifest mappings.
  if $scoped_mode && [ ${#to_rename[@]} -eq 0 ]; then
    rm -f "$new_entries"
    return 0
  fi

  # Update manifest: merge existing + new entries, sorted by name.
  # An entry is live if either its obfuscated id or readable name is on disk.
  local merged
  merged=$(mktemp) || { echo "Error: failed to create temp file" >&2; rm -f "$new_entries"; return 1; }

  if [ -f "$manifest" ]; then
    while IFS=$'\t' read -r id name; do
      [ -z "$id" ] && continue
      if [ -f "$notes_dir/$id" ] || [ -f "$notes_dir/$name" ]; then
        printf '%s\t%s\n' "$id" "$name"
      fi
    done < "$manifest" > "$merged"
  fi

  cat "$new_entries" >> "$merged"
  # Sort to a temp file first, then mv — avoids truncating the manifest
  # if sort fails (sort > $manifest truncates before sort runs).
  local sorted
  sorted=$(mktemp) || { echo "Error: failed to create temp file" >&2; rm -f "$merged" "$new_entries"; return 1; }
  if ! sort -t$'\t' -k2 "$merged" > "$sorted"; then
    echo "Error: failed to sort manifest" >&2
    rm -f "$merged" "$new_entries" "$sorted"
    return 1
  fi
  mv -f "$sorted" "$manifest"
  rm -f "$merged" "$new_entries"
}

# Local state file recording the readable path and content hash last restored
# for each ID. This lets deobfuscation distinguish a clean generated readable
# file (safe to update/remove after pull/merge/checkout) from a locally-edited
# readable file (must preserve).
#
# Current row format: <id>\t<relpath>\t<tracked-hash>\t<raw-hash>
# Previous row format: <id>\t<relpath>\t<tracked-hash>
# Legacy row format:   <id>\t<tracked-hash>
_deobfuscation_state_file() {
  local notes_dir="$1"
  resolve_notes_dir "$notes_dir" || return 1
  printf '%s/.git/info/notes-obfuscation-state' "$RESOLVED_REPO_ROOT"
}

_deobfuscation_base_hash_for_id() {
  local notes_dir="$1" id="$2"
  local state
  state=$(_deobfuscation_state_file "$notes_dir") || return 0
  [ -f "$state" ] || return 0
  # Last entry wins. The state file is append-only (see
  # _record_deobfuscation_base_hashes); newer writes shadow older ones, and
  # concurrent writers can't corrupt each other the way a tmp+mv
  # read-modify-write would.
  awk -F '\t' -v wanted="$id" '
    $1 == wanted {
      if (NF >= 3) found=$3; else found=$2
    }
    END { if (found != "") print found }
  ' "$state"
}

_deobfuscation_readable_matches_base_ref() {
  local notes_dir="$1" id="$2" relpath="$3" base_ref="$4"
  [ -n "$base_ref" ] || return 1
  [ -f "$notes_dir/$relpath" ] || return 1

  resolve_notes_dir "$notes_dir" || return 1
  local repo_root="$RESOLVED_REPO_ROOT"
  local notes_rel="$RESOLVED_NOTES_DIR"
  local tmp
  tmp=$(mktemp) || return 1

  if ! git -C "$repo_root" cat-file --filters "$base_ref:$notes_rel/$id" > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi

  if cmp -s "$tmp" "$notes_dir/$relpath"; then
    rm -f "$tmp"
    return 0
  fi

  rm -f "$tmp"
  return 1
}

_calculate_deobfuscation_state_rows() {
  local notes_dir="$1"
  shift
  local ids=("$@")
  local manifest="$notes_dir/.manifest"
  [ -f "$manifest" ] || return 0
  [ ${#ids[@]} -gt 0 ] || return 0

  resolve_notes_dir "$notes_dir" || return 0
  local repo_root="$RESOLVED_REPO_ROOT"
  local notes_rel="$RESOLVED_NOTES_DIR"
  local workspace
  local tracked_paths=()
  workspace=$(mktemp -d) || return 1
  printf '%s\n' "${ids[@]}" > "$workspace/requested"
  : > "$workspace/records"
  : > "$workspace/raw-in"

  awk -F '\t' '
    FNR == NR { requested[$1] = 1; next }
    $1 in requested { print $1 "\t" $2 }
  ' "$workspace/requested" "$manifest" > "$workspace/candidates"

  local id relpath
  while IFS=$'\t' read -r id relpath; do
    [ -z "$id" ] && continue
    [ -f "$notes_dir/$relpath" ] || continue
    printf '%s\t%s\t%s/%s\n' "$id" "$relpath" "$notes_rel" "$id" >> "$workspace/records"
    printf '%s/%s\n' "$notes_rel" "$relpath" >> "$workspace/raw-in"
    tracked_paths+=("$notes_rel/$id")
  done < "$workspace/candidates"

  if [ ! -s "$workspace/records" ]; then
    rm -rf "$workspace"
    return 0
  fi

  if ! git -C "$repo_root" hash-object --no-filters --stdin-paths \
    < "$workspace/raw-in" > "$workspace/raw-out"; then
    rm -rf "$workspace"
    return 1
  fi
  if ! git -C "$repo_root" -c core.quotePath=false ls-files --stage -- \
    "${tracked_paths[@]}" > "$workspace/index-out"; then
    rm -rf "$workspace"
    return 1
  fi

  awk -F '\t' \
    -v index_file="$workspace/index-out" \
    -v records_file="$workspace/records" \
    -v raw_file="$workspace/raw-out" '
      FILENAME == index_file {
        split($1, metadata, " ")
        tracked[$2] = metadata[2]
        next
      }
      FILENAME == records_file {
        if ((getline raw < raw_file) <= 0) exit 1
        if ($3 in tracked && raw != "") {
          print $1 "\t" $2 "\t" tracked[$3] "\t" raw
        }
      }
    ' "$workspace/index-out" "$workspace/records" || {
      rm -rf "$workspace"
      return 1
    }

  rm -rf "$workspace"
}

_record_deobfuscation_base_hashes() {
  local notes_dir="$1"
  shift
  local state rows
  state=$(_deobfuscation_state_file "$notes_dir") || return 0
  rows=$(mktemp) || return 1

  if ! _calculate_deobfuscation_state_rows "$notes_dir" "$@" > "$rows"; then
    rm -f "$rows"
    return 1
  fi
  if [ ! -s "$rows" ]; then
    rm -f "$rows"
    return 0
  fi

  mkdir -p "$(dirname "$state")"
  touch "$state"

  # Append one complete row at a time. Each row stays below PIPE_BUF, preserving
  # the concurrent append contract while newer rows shadow older formats.
  local row
  while IFS= read -r row; do
    [ -n "$row" ] && printf '%s\n' "$row" >> "$state"
  done < "$rows"

  rm -f "$rows"
}

# Rename a single obfuscated ID back to its readable name.
# Returns: 0=renamed, 2=skipped (not found/no match),
#          3=dirty readable preserved, 1=error (mv failed).
_rename_one_to_readable() {
  local notes_dir="$1" manifest="$2" id="$3"
  local relpath
  relpath=$(manifest_name_for_id "$manifest" "$id")
  [ -z "$relpath" ] && return 2
  [ ! -f "$notes_dir/$id" ] && return 2

  local target_dir
  target_dir=$(dirname "$notes_dir/$relpath")
  [ ! -d "$target_dir" ] && mkdir -p "$target_dir"

  if [ -e "$notes_dir/$relpath" ] && ! cmp -s "$notes_dir/$id" "$notes_dir/$relpath"; then
    local current_hash base_hash state_file dirty_readable=false
    state_file=$(_deobfuscation_state_file "$notes_dir" 2>/dev/null) || state_file=""
    if ! current_hash=$(git -C "$notes_dir" hash-object -- "$notes_dir/$relpath" 2>/dev/null); then
      current_hash=""
    fi
    base_hash=$(_deobfuscation_base_hash_for_id "$notes_dir" "$id")

    # No state file (fresh clone or pre-safety upgrade) -> trust the readable
    # and let the rename proceed. Force-prompting on every file would train
    # users into --force-as-default, which is worse than the one-time window.
    if [ -n "$state_file" ] && [ -f "$state_file" ]; then
      if [ -n "$base_hash" ]; then
        [ "$current_hash" != "$base_hash" ] && dirty_readable=true
      elif ! _deobfuscation_readable_matches_base_ref \
        "$notes_dir" "$id" "$relpath" "${NOTES_DEOBFUSCATE_BASE_REF:-}"; then
        dirty_readable=true
      fi

      if $dirty_readable && [ "${NOTES_DEOBFUSCATE_FORCE:-false}" != "true" ]; then
        echo "Error: refusing to overwrite dirty readable note: $relpath" >&2
        echo "This may be a real local edit, or a cosmetic editor re-save (trailing-newline trim, BOM, line-ending change)." >&2
        echo "Run 'notes changes $relpath' to inspect; rerun with --force to overwrite intentionally." >&2
        return 3
      fi
    fi
  fi

  # Use -f only after the safety check above. Identical readable copies are
  # harmless; differing copies require explicit --force.
  if ! mv -f "$notes_dir/$id" "$notes_dir/$relpath"; then
    echo "Error: failed to rename $id → $relpath" >&2
    return 1
  fi
  printf '%s\t%s\n' "$id" "$relpath"
}

# Rename obfuscated IDs back to readable names.
# Outputs "<id>\t<relpath>" per renamed file.
# Returns 0 on success, 2 if nothing to do, 3 if dirty readables were
# preserved, 1 on hard error.
# Usage: rename_to_readable <notes_dir> [id...]
#   Without ids: deobfuscates all files listed in the manifest.
#   With ids: only deobfuscates the specified IDs.
rename_to_readable() {
  local notes_dir="$1"
  shift
  local scoped_ids=("$@")
  local manifest="$notes_dir/.manifest"
  local count=0 dirty_count=0

  [ ! -f "$manifest" ] && return 1

  # _rename_one_to_readable returns: 0=renamed, 2=skipped,
  # 3=dirty readable preserved, 1=hard error.
  if [ ${#scoped_ids[@]} -gt 0 ] && [ -n "${scoped_ids[0]}" ]; then
    for id in "${scoped_ids[@]}"; do
      local _rc
      _rename_one_to_readable "$notes_dir" "$manifest" "$id" && _rc=0 || _rc=$?
      case $_rc in
        0) count=$((count + 1)) ;;
        3) dirty_count=$((dirty_count + 1)) ;;
        1) return 1 ;;
      esac
    done
  else
    # The helper moves note files but does not modify the manifest being read.
    # shellcheck disable=SC2094
    while IFS=$'\t' read -r id relpath; do
      [ -z "$id" ] && continue
      local _rc
      _rename_one_to_readable "$notes_dir" "$manifest" "$id" && _rc=0 || _rc=$?
      case $_rc in
        0) count=$((count + 1)) ;;
        3) dirty_count=$((dirty_count + 1)) ;;
        1) return 1 ;;
      esac
    done < "$manifest"
  fi

  [ "$dirty_count" -gt 0 ] && return 3
  [ "$count" -eq 0 ] && return 2
  return 0
}
