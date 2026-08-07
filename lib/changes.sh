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
  local comparison_status
  [ ! -f "$manifest" ] && return 0

  while IFS=$'\t' read -r id relpath; do
    [ -z "$id" ] && continue
    [ -f "$abs_notes_dir/$id" ] || continue
    [ -f "$abs_notes_dir/$relpath" ] || continue
    comparison_status=0
    cmp -s "$abs_notes_dir/$id" "$abs_notes_dir/$relpath" || comparison_status=$?
    case "$comparison_status" in
      0) continue ;;
      1) printf '%s\t%s\n' "$id" "$relpath" ;;
      *) return "$comparison_status" ;;
    esac
  done < "$manifest"
}

_prepare_change_detection_workspace() {
  local abs_notes_dir="$1" repo_root="$2" notes_dir="$3" workspace="$4"
  local manifest="$abs_notes_dir/.manifest"
  local id relpath state_file=""

  : > "$workspace/head-in"
  : > "$workspace/raw-in"
  : > "$workspace/manifest-ids"
  : > "$workspace/manifest-names"

  while IFS=$'\t' read -r id relpath; do
    [ -z "$id" ] && continue
    printf 'HEAD:%s/%s\n' "$notes_dir" "$id" >> "$workspace/head-in"
    printf '%s\n' "$id" >> "$workspace/manifest-ids"
    printf '%s\n' "$relpath" >> "$workspace/manifest-names"

    if [ -f "$abs_notes_dir/$relpath" ]; then
      printf '%s/%s\n' "$notes_dir" "$relpath" >> "$workspace/raw-in"
    fi
  done < "$manifest"

  if declare -F detect_stale_readable_notes >/dev/null 2>&1; then
    # Stale-state discovery is advisory during change classification.
    if ! detect_stale_readable_notes "$abs_notes_dir" 2>/dev/null \
      | while IFS=$'\t' read -r _stale_state stale_relpath; do
          [ -n "$stale_relpath" ] && printf '%s\n' "$stale_relpath"
        done > "$workspace/stale-readables"; then
      :
    fi
  else
    : > "$workspace/stale-readables"
  fi

  git -C "$repo_root" cat-file --batch-check='%(objectname)' \
    < "$workspace/head-in" > "$workspace/head-out" 2>/dev/null || return 1
  if [ -s "$workspace/raw-in" ]; then
    git -C "$repo_root" hash-object --no-filters --stdin-paths \
      < "$workspace/raw-in" > "$workspace/raw-out" 2>/dev/null || return 1
  else
    : > "$workspace/raw-out"
  fi

  if declare -F _deobfuscation_state_file >/dev/null 2>&1; then
    state_file=$(_deobfuscation_state_file "$abs_notes_dir" 2>/dev/null) || state_file=""
  fi
  if [ -n "$state_file" ] && [ -f "$state_file" ]; then
    awk -F '\t' '
      FNR == NR {
        if (NF >= 4) {
          path[$1] = $2
          tracked[$1] = $3
          raw[$1] = $4
        } else {
          delete path[$1]
          delete tracked[$1]
          delete raw[$1]
        }
        next
      }
      {
        if ($1 in path && path[$1] == $2) {
          print tracked[$1] "|" raw[$1]
        } else {
          print "|"
        }
      }
    ' "$state_file" "$manifest" > "$workspace/state-aligned"
  else
    awk '$1 != "" { print "|" }' "$manifest" > "$workspace/state-aligned"
  fi
}

_classify_manifest_changes() {
  local abs_notes_dir="$1" notes_dir="$2" workspace="$3"
  local manifest="$abs_notes_dir/.manifest"
  local id relpath readable_file head_hash head_exists state_pair state_tracked state_raw raw_hash

  : > "$workspace/fallback-in"
  : > "$workspace/fallback-meta"
  : > "$workspace/tracked-attr-in"
  : > "$workspace/readable-attr-in"

  exec 3< "$workspace/head-out"
  exec 4< "$workspace/raw-out"
  exec 5< "$workspace/state-aligned"
  while IFS=$'\t' read -r id relpath; do
    [ -z "$id" ] && continue

    readable_file="$abs_notes_dir/$relpath"
    head_exists=true
    IFS= read -r head_hash <&3 || head_hash=""
    IFS= read -r state_pair <&5 || state_pair="|"
    state_tracked="${state_pair%%|*}"
    state_raw="${state_pair#*|}"
    case "$head_hash" in
      *" missing") head_exists=false ;;
    esac

    if [ -f "$readable_file" ]; then
      IFS= read -r raw_hash <&4 || raw_hash=""

      if ! $head_exists; then
        printf 'new\t%s\n' "$relpath" >> "$workspace/detected"
      elif [ -n "$state_raw" ] && [ "$state_tracked" = "$head_hash" ]; then
        [ "$state_raw" != "$raw_hash" ] && printf 'modified\t%s\n' "$relpath" >> "$workspace/detected"
      else
        printf '%s/%s\n' "$notes_dir" "$relpath" >> "$workspace/fallback-in"
        printf '%s\t%s\t%s\n' "$id" "$relpath" "$head_hash" >> "$workspace/fallback-meta"
        printf '%s/%s\n' "$notes_dir" "$id" >> "$workspace/tracked-attr-in"
        printf '%s/%s\n' "$notes_dir" "$relpath" >> "$workspace/readable-attr-in"
      fi
    elif [ ! -f "$abs_notes_dir/$id" ] && $head_exists; then
      # If the obfuscated form still exists, the note simply is not deobfuscated.
      printf 'deleted\t%s\n' "$relpath" >> "$workspace/detected"
    fi
  done < "$manifest"
  exec 3<&-
  exec 4<&-
  exec 5<&-
}

_classify_fallback_changes() {
  local repo_root="$1" notes_dir="$2" abs_notes_dir="$3" workspace="$4"
  [ -s "$workspace/fallback-in" ] || return 0

  local use_batch_hash=true
  local id relpath head_hash disk_hash
  # Preserve tracked-path filter semantics for legacy, missing, or stale
  # state rows. Current four-field rows bypass filters through raw hashes.
  if git -C "$repo_root" check-attr --stdin \
    filter text eol ident working-tree-encoding \
    < "$workspace/tracked-attr-in" > "$workspace/tracked-attr-out.raw" 2>/dev/null; then
    sed 's/^[^:]*: //' "$workspace/tracked-attr-out.raw" > "$workspace/tracked-attr-out"
  else
    use_batch_hash=false
  fi
  if git -C "$repo_root" check-attr --stdin \
    filter text eol ident working-tree-encoding \
    < "$workspace/readable-attr-in" > "$workspace/readable-attr-out.raw" 2>/dev/null; then
    sed 's/^[^:]*: //' "$workspace/readable-attr-out.raw" > "$workspace/readable-attr-out"
  else
    use_batch_hash=false
  fi

  if $use_batch_hash && cmp -s "$workspace/tracked-attr-out" "$workspace/readable-attr-out"; then
    git -C "$repo_root" hash-object --stdin-paths \
      < "$workspace/fallback-in" > "$workspace/fallback-out" 2>/dev/null || return 1

    exec 6< "$workspace/fallback-out"
    while IFS=$'\t' read -r id relpath head_hash; do
      IFS= read -r disk_hash <&6 || disk_hash=""
      [ "$head_hash" != "$disk_hash" ] && printf 'modified\t%s\n' "$relpath" >> "$workspace/detected"
    done < "$workspace/fallback-meta"
    exec 6<&-
  else
    while IFS=$'\t' read -r id relpath head_hash; do
      if ! disk_hash=$(git -C "$repo_root" hash-object \
        --path="$notes_dir/$id" "$abs_notes_dir/$relpath" 2>/dev/null); then
        return 1
      fi
      [ "$head_hash" != "$disk_hash" ] && printf 'modified\t%s\n' "$relpath" >> "$workspace/detected"
    done < "$workspace/fallback-meta"
  fi

  return 0
}

_classify_unmanaged_files() {
  local abs_notes_dir="$1" workspace="$2"

  find "$abs_notes_dir" -type f > "$workspace/all-files-unsorted" || return 1
  sort "$workspace/all-files-unsorted" > "$workspace/all-files" || return 1
  awk \
    -v ids_file="$workspace/manifest-ids" \
    -v names_file="$workspace/manifest-names" \
    -v stale_file="$workspace/stale-readables" \
    -v files_file="$workspace/all-files" \
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
    ' "$workspace/manifest-ids" "$workspace/manifest-names" \
      "$workspace/stale-readables" "$workspace/all-files"
}

# Detect changed notes relative to HEAD.
# Outputs one line per change: "<status>\t<readable_name>"
# Status values: modified, new, deleted
# Usage: detect_changes <abs_notes_dir>
detect_changes() {
  local abs_notes_dir="${1:?usage: detect_changes <abs_notes_dir>}"
  local manifest="$abs_notes_dir/.manifest"
  [ ! -f "$manifest" ] && return 0

  resolve_notes_dir "$abs_notes_dir" || return
  local repo_root="$RESOLVED_REPO_ROOT"
  local notes_dir="$RESOLVED_NOTES_DIR"
  require_readable_notes_state "$abs_notes_dir" || return
  local workspace rc=0
  workspace=$(mktemp -d) || return
  : > "$workspace/detected"

  if _prepare_change_detection_workspace "$abs_notes_dir" "$repo_root" "$notes_dir" "$workspace"; then
    :
  else
    rc=$?
    rm -rf "$workspace"
    return "$rc"
  fi
  if _classify_manifest_changes "$abs_notes_dir" "$notes_dir" "$workspace"; then
    :
  else
    rc=$?
    rm -rf "$workspace"
    return "$rc"
  fi
  if _classify_fallback_changes "$repo_root" "$notes_dir" "$abs_notes_dir" "$workspace"; then
    :
  else
    rc=$?
    rm -rf "$workspace"
    return "$rc"
  fi
  if _classify_unmanaged_files "$abs_notes_dir" "$workspace" > "$workspace/unmanaged"; then
    :
  else
    rc=$?
    rm -rf "$workspace"
    return "$rc"
  fi
  if ! cat "$workspace/unmanaged" >> "$workspace/detected"; then
    rm -rf "$workspace"
    return 1
  fi

  cat "$workspace/detected" || rc=$?
  rm -rf "$workspace"
  return "$rc"
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
