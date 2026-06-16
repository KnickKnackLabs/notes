#!/usr/bin/env bash
# suppress.sh — Status suppression for deobfuscated working trees
#
# After deobfuscation, the working tree has readable names but the index
# has obfuscated names. Two sources of noise in `git status`:
#   1. Obfuscated IDs appear as "deleted" (file missing from disk)
#   2. Readable names appear as "untracked" (not in the index)
#
# We suppress both:
#   - `assume-unchanged` on obfuscated paths → hides "deleted" noise
#   - `.git/info/exclude` entries for readable names → hides "untracked" noise
#
# Because exclude also blocks `git add`, users commit notes via `notes commit`
# or stage them explicitly via `notes stage`; both use `git add -f` to bypass
# exclude. See notes#39.

# Managed block markers in .git/info/exclude
EXCLUDE_BEGIN="# BEGIN notes-obfuscation"
EXCLUDE_END="# END notes-obfuscation"

# Add readable names to .git/info/exclude.
# Usage: add_exclude_entries <abs_notes_dir> [id...]
#   Without IDs: adds all manifest entries (full mode)
#   With IDs: adds only the readable names for the specified IDs (scoped mode)
add_exclude_entries() {
  local abs_notes_dir="${1:?usage: add_exclude_entries <abs_notes_dir>}"
  shift
  local scoped_ids=("$@")
  local manifest="$abs_notes_dir/.manifest"
  [ ! -f "$manifest" ] && return

  resolve_notes_dir "$abs_notes_dir" || return
  local repo_root="$RESOLVED_REPO_ROOT"
  local notes_dir="$RESOLVED_NOTES_DIR"
  local exclude_file="$repo_root/.git/info/exclude"

  # Ensure the info directory exists
  mkdir -p "$(dirname "$exclude_file")"

  # Collect entries to add
  local entries=()
  if [ ${#scoped_ids[@]} -gt 0 ] && [ -n "${scoped_ids[0]}" ]; then
    for id in "${scoped_ids[@]}"; do
      local relpath
      relpath=$(manifest_name_for_id "$manifest" "$id")
      [ -n "$relpath" ] && entries+=("$notes_dir/$relpath")
    done
  else
    while IFS=$'\t' read -r id relpath; do
      [ -z "$id" ] && continue
      entries+=("$notes_dir/$relpath")
    done < "$manifest"
  fi

  [ ${#entries[@]} -eq 0 ] && return

  # Read existing managed entries (if any)
  local existing=()
  if [ -f "$exclude_file" ]; then
    local in_block=false
    while IFS= read -r line; do
      if [ "$line" = "$EXCLUDE_BEGIN" ]; then
        in_block=true
        continue
      fi
      if [ "$line" = "$EXCLUDE_END" ]; then
        in_block=false
        continue
      fi
      if $in_block && [ -n "$line" ]; then
        existing+=("$line")
      fi
    done < "$exclude_file"
  fi

  # Merge: add new entries that aren't already present
  local merged=()
  for e in ${existing[@]+"${existing[@]}"}; do
    merged+=("$e")
  done
  for entry in "${entries[@]}"; do
    local found=false
    for e in ${existing[@]+"${existing[@]}"}; do
      if [ "$e" = "$entry" ]; then
        found=true
        break
      fi
    done
    if ! $found; then
      merged+=("$entry")
    fi
  done

  # Rewrite the exclude file: preserve non-managed content, replace managed block
  _rewrite_exclude_block "$exclude_file" "${merged[@]}"
}

# Remove readable names from .git/info/exclude.
# Usage: remove_exclude_entries <abs_notes_dir> [id...]
#   Without IDs: removes the entire managed block (full mode)
#   With IDs: removes only the readable names for the specified IDs (scoped mode)
remove_exclude_entries() {
  local abs_notes_dir="${1:?usage: remove_exclude_entries <abs_notes_dir>}"
  shift
  local scoped_ids=("$@")
  local manifest="$abs_notes_dir/.manifest"
  [ ! -f "$manifest" ] && return

  resolve_notes_dir "$abs_notes_dir" || return
  local repo_root="$RESOLVED_REPO_ROOT"
  local notes_dir="$RESOLVED_NOTES_DIR"
  local exclude_file="$repo_root/.git/info/exclude"

  [ ! -f "$exclude_file" ] && return

  if [ ${#scoped_ids[@]} -gt 0 ] && [ -n "${scoped_ids[0]}" ]; then
    # Scoped: collect paths to remove, keep the rest
    local to_remove=()
    for id in "${scoped_ids[@]}"; do
      local relpath
      relpath=$(manifest_name_for_id "$manifest" "$id")
      [ -n "$relpath" ] && to_remove+=("$notes_dir/$relpath")
    done

    # Read existing managed entries, filter out the ones to remove
    local remaining=()
    local in_block=false
    while IFS= read -r line; do
      if [ "$line" = "$EXCLUDE_BEGIN" ]; then
        in_block=true
        continue
      fi
      if [ "$line" = "$EXCLUDE_END" ]; then
        in_block=false
        continue
      fi
      if $in_block && [ -n "$line" ]; then
        local should_remove=false
        for r in "${to_remove[@]}"; do
          if [ "$line" = "$r" ]; then
            should_remove=true
            break
          fi
        done
        if ! $should_remove; then
          remaining+=("$line")
        fi
      fi
    done < "$exclude_file"

    _rewrite_exclude_block "$exclude_file" ${remaining[@]+"${remaining[@]}"}
  else
    # Full mode: remove the entire managed block
    _rewrite_exclude_block "$exclude_file"
  fi
}

# Rewrite .git/info/exclude: preserve non-managed content, replace managed block.
# Usage: _rewrite_exclude_block <exclude_file> [entries...]
#   With entries: writes a BEGIN/END block containing them
#   Without entries: removes the managed block entirely
_rewrite_exclude_block() {
  local exclude_file="$1"
  shift
  local entries=("$@")

  local tmp
  tmp=$(mktemp) || return

  # Copy non-managed content
  if [ -f "$exclude_file" ]; then
    local in_block=false
    while IFS= read -r line; do
      if [ "$line" = "$EXCLUDE_BEGIN" ]; then
        in_block=true
        continue
      fi
      if [ "$line" = "$EXCLUDE_END" ]; then
        in_block=false
        continue
      fi
      if ! $in_block; then
        printf '%s\n' "$line" >> "$tmp"
      fi
    done < "$exclude_file"
  fi

  # Append managed block if there are entries
  if [ ${#entries[@]} -gt 0 ] && [ -n "${entries[0]}" ]; then
    printf '%s\n' "$EXCLUDE_BEGIN" >> "$tmp"
    for entry in "${entries[@]}"; do
      printf '%s\n' "$entry" >> "$tmp"
    done
    printf '%s\n' "$EXCLUDE_END" >> "$tmp"
  fi

  mv -f "$tmp" "$exclude_file"
}

# Set assume-unchanged on obfuscated paths + add exclude entries for readable names.
# Call after deobfuscating.
# Usage: set_status_suppression <abs_notes_dir> [id...]
#   Without IDs: sets flags for all entries in the manifest (full mode)
#   With IDs: sets flags for the specified IDs only (scoped mode)
set_status_suppression() {
  local abs_notes_dir="${1:?usage: set_status_suppression <abs_notes_dir>}"
  shift
  local scoped_ids=("$@")
  local manifest="$abs_notes_dir/.manifest"
  [ ! -f "$manifest" ] && return

  resolve_notes_dir "$abs_notes_dir" || return
  local repo_root="$RESOLVED_REPO_ROOT"
  local notes_dir="$RESOLVED_NOTES_DIR"

  # Set assume-unchanged flags
  if [ ${#scoped_ids[@]} -gt 0 ] && [ -n "${scoped_ids[0]}" ]; then
    for id in "${scoped_ids[@]}"; do
      git -C "$repo_root" update-index --assume-unchanged "$notes_dir/$id" 2>/dev/null || true
    done
  else
    while IFS=$'\t' read -r id relpath; do
      [ -z "$id" ] && continue
      git -C "$repo_root" update-index --assume-unchanged "$notes_dir/$id" 2>/dev/null || true
    done < "$manifest"
  fi

  # Add exclude entries for readable names
  add_exclude_entries "$abs_notes_dir" ${scoped_ids[@]+"${scoped_ids[@]}"}
}

# Clear assume-unchanged flags + remove exclude entries for readable names.
# Call before obfuscating.
# Usage: clear_status_suppression <abs_notes_dir> [id...]
#   Without IDs: clears all flags (full mode)
#   With IDs: clears only the specified IDs (scoped mode)
clear_status_suppression() {
  local abs_notes_dir="${1:?usage: clear_status_suppression <abs_notes_dir>}"
  shift
  local scoped_ids=("$@")
  local manifest="$abs_notes_dir/.manifest"
  [ ! -f "$manifest" ] && return

  resolve_notes_dir "$abs_notes_dir" || return
  local repo_root="$RESOLVED_REPO_ROOT"
  local notes_dir="$RESOLVED_NOTES_DIR"

  # Clear assume-unchanged flags
  if [ ${#scoped_ids[@]} -gt 0 ] && [ -n "${scoped_ids[0]}" ]; then
    for id in "${scoped_ids[@]}"; do
      git -C "$repo_root" update-index --no-assume-unchanged "$notes_dir/$id" 2>/dev/null || true
    done
  else
    while IFS=$'\t' read -r id relpath; do
      [ -z "$id" ] && continue
      git -C "$repo_root" update-index --no-assume-unchanged "$notes_dir/$id" 2>/dev/null || true
    done < "$manifest"
  fi

  # Remove exclude entries for readable names
  remove_exclude_entries "$abs_notes_dir" ${scoped_ids[@]+"${scoped_ids[@]}"}
}

_note_relpath_is_safe() {
  local relpath="$1"
  case "$relpath" in
    ""|/*|.|..|../*|*/../*|.manifest) return 1 ;;
  esac
  return 0
}

# Print readable relpaths from notes' managed .git/info/exclude block.
# Output: <relpath>
_managed_exclude_readable_relpaths() {
  local abs_notes_dir="${1:?usage: _managed_exclude_readable_relpaths <abs_notes_dir>}"
  resolve_notes_dir "$abs_notes_dir" || return
  local repo_root="$RESOLVED_REPO_ROOT"
  local notes_dir="$RESOLVED_NOTES_DIR"
  local exclude_file="$repo_root/.git/info/exclude"

  [ -f "$exclude_file" ] || return 0

  local in_block=false line relpath
  while IFS= read -r line; do
    if [ "$line" = "$EXCLUDE_BEGIN" ]; then
      in_block=true
      continue
    fi
    if [ "$line" = "$EXCLUDE_END" ]; then
      in_block=false
      continue
    fi
    $in_block || continue
    [ -n "$line" ] || continue

    case "$line" in
      "$notes_dir"/*) relpath="${line#"$notes_dir"/}" ;;
      *) continue ;;
    esac
    _note_relpath_is_safe "$relpath" || continue
    printf '%s\n' "$relpath"
  done < "$exclude_file"
}

# Detect generated readable files that belonged to a previous manifest state but
# are no longer current. These files are dangerous because the managed exclude
# block can hide them from git while `notes changes` would otherwise present
# them as intentional new notes.
#
# Output: <clean|dirty>\t<relpath>
#   clean: content matches a known generated readable hash and may be removed
#   dirty: content differs or cannot be proven generated and must be preserved
#          outside notes/ before staging proceeds
#
# Requires _deobfuscation_state_file from obfuscate.sh when state exists.
detect_stale_readable_notes() {
  local abs_notes_dir="${1:?usage: detect_stale_readable_notes <abs_notes_dir>}"
  local manifest="$abs_notes_dir/.manifest"
  [ -f "$manifest" ] || return 0

  resolve_notes_dir "$abs_notes_dir" || return
  local repo_root="$RESOLVED_REPO_ROOT"

  local tmp_dir current_names candidates state_hashes state state_candidates
  tmp_dir=$(mktemp -d) || return 1
  current_names="$tmp_dir/current-names"
  candidates="$tmp_dir/candidates"
  state_hashes="$tmp_dir/state-hashes"
  state_candidates="$tmp_dir/state-candidates"
  : > "$current_names"
  : > "$candidates"
  : > "$state_hashes"
  : > "$state_candidates"

  while IFS=$'\t' read -r id relpath; do
    [ -z "$id" ] && continue
    printf '%s\n' "$relpath" >> "$current_names"
  done < "$manifest"

  state=""
  if declare -F _deobfuscation_state_file >/dev/null 2>&1; then
    state=$(_deobfuscation_state_file "$abs_notes_dir" 2>/dev/null || true)
  fi

  if [ -n "$state" ] && [ -f "$state" ]; then
    awk -F '\t' '
      NF >= 3 && $2 != "" && $3 != "" { latest[$2]=$3 }
      END { for (path in latest) print path "\t" latest[path] }
    ' "$state" | sort > "$state_candidates"
    cat "$state_candidates" >> "$candidates"

    awk -F '\t' '
      NF >= 3 && $3 != "" { print $3; next }
      NF >= 2 && $2 != "" { print $2 }
    ' "$state" | sort -u > "$state_hashes"
  fi

  while IFS= read -r relpath; do
    [ -n "$relpath" ] || continue
    printf '%s\t\n' "$relpath" >> "$candidates"
  done < <(_managed_exclude_readable_relpaths "$abs_notes_dir")

  if [ ! -s "$candidates" ]; then
    rm -rf "$tmp_dir"
    return 0
  fi

  local relpaths relpath file known_hash current_hash state_label
  relpaths="$tmp_dir/relpaths"
  cut -f1 "$candidates" | sort -u > "$relpaths"

  while IFS= read -r relpath; do
    [ -n "$relpath" ] || continue
    _note_relpath_is_safe "$relpath" || continue
    grep -Fxq "$relpath" "$current_names" && continue

    file="$abs_notes_dir/$relpath"
    [ -f "$file" ] || continue

    known_hash=$(awk -F '\t' -v wanted="$relpath" '$1 == wanted && $2 != "" { found=$2 } END { print found }' "$candidates")
    current_hash=$(git -C "$repo_root" hash-object -- "$file" 2>/dev/null) || continue

    state_label="dirty"
    if [ -n "$known_hash" ] && [ "$current_hash" = "$known_hash" ]; then
      state_label="clean"
    elif [ -s "$state_hashes" ] && grep -Fxq "$current_hash" "$state_hashes"; then
      # Compatibility with legacy state rows (<id>\t<hash>) that did not record
      # readable paths. The managed exclude proves this path was notes-managed;
      # a matching generated-content hash proves it is safe to remove.
      state_label="clean"
    fi

    printf '%s\t%s\n' "$state_label" "$relpath"
  done < "$relpaths"

  rm -rf "$tmp_dir"
}

_stale_readable_quarantine_path() {
  local repo_root="$1" relpath="$2"
  local base="$repo_root/.git/info/notes-stale-readable/$relpath"
  local dest="$base"
  local i=1

  while [ -e "$dest" ]; do
    dest="$base.$i"
    i=$((i + 1))
  done

  printf '%s' "$dest"
}

# Reconcile stale readable files left behind by note deletion/rename. Clean
# generated readables are removed; dirty/unproven readables are moved out of
# notes/ so they cannot be accidentally staged as new notes.
#
# Output: <removed|quarantined>\t<relpath>[\t<quarantine-path>]
reconcile_stale_readable_notes() {
  local abs_notes_dir="${1:?usage: reconcile_stale_readable_notes <abs_notes_dir>}"
  local manifest="$abs_notes_dir/.manifest"
  [ -f "$manifest" ] || return 0

  resolve_notes_dir "$abs_notes_dir" || return
  local repo_root="$RESOLVED_REPO_ROOT"

  local stale relpath state_label file dest
  stale=$(detect_stale_readable_notes "$abs_notes_dir") || return 1
  [ -n "$stale" ] || return 0

  while IFS=$'\t' read -r state_label relpath; do
    [ -n "$state_label" ] || continue
    _note_relpath_is_safe "$relpath" || continue
    file="$abs_notes_dir/$relpath"
    [ -f "$file" ] || continue

    case "$state_label" in
      clean)
        rm -f "$file" || return 1
        printf 'removed\t%s\n' "$relpath"
        ;;
      dirty)
        dest=$(_stale_readable_quarantine_path "$repo_root" "$relpath")
        mkdir -p "$(dirname "$dest")" || return 1
        mv "$file" "$dest" || return 1
        printf 'quarantined\t%s\t%s\n' "$relpath" "$dest"
        ;;
    esac
  done <<< "$stale"

  find "$abs_notes_dir" -mindepth 1 -type d -empty -delete 2>/dev/null || true
}

# Rebuild all derived git-status suppression from the current manifest. Unlike
# set_status_suppression, this intentionally drops stale managed exclude entries
# and clears assume-unchanged for IDs known from previous deobfuscation state.
rebuild_status_suppression() {
  local abs_notes_dir="${1:?usage: rebuild_status_suppression <abs_notes_dir>}"
  local manifest="$abs_notes_dir/.manifest"
  [ -f "$manifest" ] || return 0

  resolve_notes_dir "$abs_notes_dir" || return
  local repo_root="$RESOLVED_REPO_ROOT"
  local notes_dir="$RESOLVED_NOTES_DIR"
  local exclude_file="$repo_root/.git/info/exclude"
  local state=""

  if declare -F _deobfuscation_state_file >/dev/null 2>&1; then
    state=$(_deobfuscation_state_file "$abs_notes_dir" 2>/dev/null || true)
  fi
  if [ -n "$state" ] && [ -f "$state" ]; then
    while IFS= read -r id; do
      [ -n "$id" ] || continue
      git -C "$repo_root" update-index --no-assume-unchanged "$notes_dir/$id" 2>/dev/null || true
    done < <(awk -F '\t' '$1 != "" { print $1 }' "$state" | sort -u)
  fi

  mkdir -p "$(dirname "$exclude_file")"
  _rewrite_exclude_block "$exclude_file"
  set_status_suppression "$abs_notes_dir"
}
