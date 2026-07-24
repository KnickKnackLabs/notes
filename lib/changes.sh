#!/usr/bin/env bash
# changes.sh — Detect changed notes by comparing deobfuscated files against HEAD
#
# In the deobfuscated state, readable files on disk don't match what git tracks
# (obfuscated IDs in the index). This library compares readable content against
# committed content to detect modifications, additions, and deletions.

# Detect manifest entries where both the obfuscated ID and readable path exist
# on disk with different content. This is the dangerous state left behind when
# post-merge/post-rebase deobfuscation preserves a dirty readable note while the
# incoming obfuscated source remains present.
#
# Outputs one line per conflict: "<id>\t<readable_name>"
# Usage: detect_dual_present_conflicts <abs_notes_dir>
detect_dual_present_conflicts() {
  local abs_notes_dir="${1:?usage: detect_dual_present_conflicts <abs_notes_dir>}"
  local manifest="$abs_notes_dir/.manifest"
  [ ! -f "$manifest" ] && return 0

  while IFS=$'\t' read -r id relpath; do
    [ -z "$id" ] && continue
    [ -f "$abs_notes_dir/$id" ] || continue
    [ -f "$abs_notes_dir/$relpath" ] || continue
    cmp -s "$abs_notes_dir/$id" "$abs_notes_dir/$relpath" && continue
    printf '%s\t%s\n' "$id" "$relpath"
  done < "$manifest"
}

# Detect changed notes relative to HEAD.
# Outputs one line per change: "<status>\t<readable_name>"
# Status values: modified, new, deleted
# Usage: detect_changes <abs_notes_dir>
detect_changes() {
  local abs_notes_dir="${1:?usage: detect_changes <abs_notes_dir>}"
  local manifest="$abs_notes_dir/.manifest"
  [ ! -f "$manifest" ] && return

  resolve_notes_dir "$abs_notes_dir" || return
  local repo_root="$RESOLVED_REPO_ROOT"
  local notes_dir="$RESOLVED_NOTES_DIR"

  local tmp_dir head_in head_out disk_in disk_out manifest_ids manifest_names stale_readables all_files
  local tracked_attr_in readable_attr_in tracked_attr_out readable_attr_out
  tmp_dir=$(mktemp -d) || return
  head_in="$tmp_dir/head-in"
  head_out="$tmp_dir/head-out"
  disk_in="$tmp_dir/disk-in"
  disk_out="$tmp_dir/disk-out"
  manifest_ids="$tmp_dir/manifest-ids"
  manifest_names="$tmp_dir/manifest-names"
  stale_readables="$tmp_dir/stale-readables"
  all_files="$tmp_dir/all-files"
  tracked_attr_in="$tmp_dir/tracked-attr-in"
  readable_attr_in="$tmp_dir/readable-attr-in"
  tracked_attr_out="$tmp_dir/tracked-attr-out"
  readable_attr_out="$tmp_dir/readable-attr-out"
  : > "$head_in"
  : > "$disk_in"
  : > "$manifest_ids"
  : > "$manifest_names"
  : > "$stale_readables"
  : > "$all_files"
  : > "$tracked_attr_in"
  : > "$readable_attr_in"

  while IFS=$'\t' read -r id relpath; do
    [ -z "$id" ] && continue
    printf 'HEAD:%s/%s\n' "$notes_dir" "$id" >> "$head_in"
    printf '%s\n' "$id" >> "$manifest_ids"
    printf '%s\n' "$relpath" >> "$manifest_names"

    if [ -f "$abs_notes_dir/$relpath" ]; then
      printf '%s/%s\n' "$notes_dir" "$relpath" >> "$disk_in"
      printf '%s/%s\n' "$notes_dir" "$id" >> "$tracked_attr_in"
      printf '%s/%s\n' "$notes_dir" "$relpath" >> "$readable_attr_in"
    fi
  done < "$manifest"

  if declare -F detect_stale_readable_notes >/dev/null 2>&1; then
    # Stale-state discovery is advisory during change classification.
    if ! detect_stale_readable_notes "$abs_notes_dir" 2>/dev/null \
      | while IFS=$'\t' read -r _stale_state stale_relpath; do
          [ -n "$stale_relpath" ] && printf '%s\n' "$stale_relpath"
        done > "$stale_readables"; then
      :
    fi
  fi

  git -C "$repo_root" cat-file --batch-check='%(objectname)' < "$head_in" > "$head_out" 2>/dev/null || {
    rm -rf "$tmp_dir"
    return
  }

  local use_batch_hash=true
  if [ -s "$disk_in" ]; then
    # `hash-object --stdin-paths` hashes each readable file using attributes for
    # that readable path. The old per-file implementation hashes readable bytes
    # as the tracked obfuscated path (`--path=$notes_dir/$id`). Preserve that
    # behavior by batching only when clean-filter-relevant attributes match.
    if git -C "$repo_root" check-attr --stdin \
      filter text eol ident working-tree-encoding \
      < "$tracked_attr_in" > "$tracked_attr_out.raw" 2>/dev/null; then
      sed 's/^[^:]*: //' "$tracked_attr_out.raw" > "$tracked_attr_out"
    else
      use_batch_hash=false
    fi
    if git -C "$repo_root" check-attr --stdin \
      filter text eol ident working-tree-encoding \
      < "$readable_attr_in" > "$readable_attr_out.raw" 2>/dev/null; then
      sed 's/^[^:]*: //' "$readable_attr_out.raw" > "$readable_attr_out"
    else
      use_batch_hash=false
    fi
    if $use_batch_hash && cmp -s "$tracked_attr_out" "$readable_attr_out"; then
      git -C "$repo_root" hash-object --stdin-paths < "$disk_in" > "$disk_out" 2>/dev/null || {
        rm -rf "$tmp_dir"
        return
      }
    else
      use_batch_hash=false
      : > "$disk_out"
    fi
  else
    : > "$disk_out"
  fi

  exec 3< "$head_out"
  exec 4< "$disk_out"
  while IFS=$'\t' read -r id relpath; do
    [ -z "$id" ] && continue

    local readable_file="$abs_notes_dir/$relpath"
    local head_hash head_exists=true
    IFS= read -r head_hash <&3 || head_hash=""
    case "$head_hash" in
      *" missing") head_exists=false ;;
    esac

    if [ -f "$readable_file" ]; then
      # File exists on disk — check if it's new or modified.
      if ! $head_exists; then
        printf 'new\t%s\n' "$relpath"
        if $use_batch_hash; then
          if ! IFS= read -r _disk_hash <&4; then
            _disk_hash=""
          fi
        fi
        continue
      fi

      local disk_hash
      if $use_batch_hash; then
        IFS= read -r disk_hash <&4 || disk_hash=""
      else
        disk_hash=$(git -C "$repo_root" hash-object --path="$notes_dir/$id" "$readable_file" 2>/dev/null) || continue
      fi
      if [ "$head_hash" != "$disk_hash" ]; then
        printf 'modified\t%s\n' "$relpath"
      fi
    else
      # Readable name not on disk — check if obfuscated form exists. If neither
      # exists and HEAD has the obfuscated blob, the note was deleted. If the
      # obfuscated form exists on disk, the file isn't deobfuscated — skip.
      if [ ! -f "$abs_notes_dir/$id" ] && $head_exists; then
        printf 'deleted\t%s\n' "$relpath"
      fi
    fi
  done < "$manifest"
  exec 3<&-
  exec 4<&-

  # Classify files not represented by the current manifest in one set pass.
  # Per-file grep and basename processes dominate this path at repository scale.
  if ! find "$abs_notes_dir" -type f | sort > "$all_files"; then
    rm -rf "$tmp_dir"
    return
  fi
  awk \
    -v ids_file="$manifest_ids" \
    -v names_file="$manifest_names" \
    -v stale_file="$stale_readables" \
    -v files_file="$all_files" \
    -v root="$abs_notes_dir/" '
      FILENAME == ids_file   { ids[$0] = 1; next }
      FILENAME == names_file { names[$0] = 1; next }
      FILENAME == stale_file { stale[$0] = 1; next }
      FILENAME == files_file {
        relpath = substr($0, length(root) + 1)
        if (relpath == ".manifest") next

        count = split(relpath, parts, "/")
        base = parts[count]
        if (base in ids || relpath in names) next

        if (relpath in stale) {
          print "stale-readable\t" relpath
        } else {
          print "new\t" relpath
        }
      }
    ' "$manifest_ids" "$manifest_names" "$stale_readables" "$all_files"

  rm -rf "$tmp_dir"
}

# Print ordinary diff output while preserving genuine diff execution failures.
_emit_notes_diff() {
  local status
  if diff "$@"; then
    return 0
  else
    status=$?
  fi

  case "$status" in
    1) return 0 ;; # differences found
    *) return "$status" ;;
  esac
}

# Show diffs for changed notes.
# Usage: show_diffs <abs_notes_dir> [file...]
#   Without files: diffs all changed notes
#   With files: diffs only the specified notes (readable names, relative to notes dir)
show_diffs() {
  local abs_notes_dir="${1:?usage: show_diffs <abs_notes_dir>}"
  shift
  local filter_files=("$@")
  local manifest="$abs_notes_dir/.manifest"
  [ ! -f "$manifest" ] && return

  resolve_notes_dir "$abs_notes_dir" || return
  local repo_root="$RESOLVED_REPO_ROOT"
  local notes_dir="$RESOLVED_NOTES_DIR"

  local changes
  changes=$(detect_changes "$abs_notes_dir") || return
  [ -z "$changes" ] && return

  while IFS=$'\t' read -r status relpath; do
    # Apply file filter if specified
    if [ ${#filter_files[@]} -gt 0 ] && [ -n "${filter_files[0]}" ]; then
      local match=false
      for f in "${filter_files[@]}"; do
        if [ "$f" = "$relpath" ]; then
          match=true
          break
        fi
      done
      $match || continue
    fi

    local readable_file="$abs_notes_dir/$relpath"
    local id
    id=$(manifest_id_for_name "$manifest" "$relpath")
    local git_path="$notes_dir/$id"

    case "$status" in
      modified)
        echo "=== $relpath (modified) ==="
        # Use cat-file --filters to get decrypted content (handles git-crypt)
        local tmp
        tmp=$(mktemp) || continue
        git -C "$repo_root" cat-file --filters "HEAD:$git_path" > "$tmp" 2>/dev/null
        _emit_notes_diff -u --label "a/$relpath" --label "b/$relpath" "$tmp" "$readable_file"
        rm -f "$tmp"
        echo ""
        ;;
      new)
        echo "=== $relpath (new) ==="
        _emit_notes_diff -u --label /dev/null --label "b/$relpath" /dev/null "$readable_file"
        echo ""
        ;;
      deleted)
        echo "=== $relpath (deleted) ==="
        local tmp
        tmp=$(mktemp) || continue
        git -C "$repo_root" cat-file --filters "HEAD:$git_path" > "$tmp" 2>/dev/null
        _emit_notes_diff -u --label "a/$relpath" --label /dev/null "$tmp" /dev/null
        rm -f "$tmp"
        echo ""
        ;;
      stale-readable)
        echo "=== $relpath (stale readable) ==="
        echo "This readable note belonged to a previous manifest state. Run 'notes deobfuscate' to remove or quarantine it before staging."
        echo ""
        ;;
    esac
  done <<< "$changes"
}
