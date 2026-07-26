#!/usr/bin/env bash
# diff.sh — Materialize readable note trees from refs and diff them.

_guard_manifest_path() {
  local kind="$1" value="$2"

  if [ "$kind" = "id" ]; then
    case "$value" in
      ""|.|..|*/*)
        echo "Error: unsafe manifest $kind: $value" >&2
        return 1
        ;;
    esac
    return 0
  fi

  case "$value" in
    ""|.|..|/*|../*|*/../*|*"/.."|*"//"*)
      echo "Error: unsafe manifest $kind: $value" >&2
      return 1
      ;;
  esac
}

# Build and validate one ref's readable-name index without materializing note blobs.
_prepare_readable_notes_ref_index() {
  local repo_root="$1" notes_dir="$2" ref="$3" manifest_out="$4"
  local tree_paths tree_ids raw_manifest validated_manifest missing_manifest unmapped_file
  tree_paths=$(mktemp) || return 1
  tree_ids=$(mktemp) || { rm -f "$tree_paths"; return 1; }
  raw_manifest=$(mktemp) || { rm -f "$tree_paths" "$tree_ids"; return 1; }
  validated_manifest=$(mktemp) || { rm -f "$tree_paths" "$tree_ids" "$raw_manifest"; return 1; }
  missing_manifest=$(mktemp) || { rm -f "$tree_paths" "$tree_ids" "$raw_manifest" "$validated_manifest"; return 1; }
  unmapped_file=$(mktemp) || {
    rm -f "$tree_paths" "$tree_ids" "$raw_manifest" "$validated_manifest" "$missing_manifest"
    return 1
  }
  : > "$manifest_out"

  if ! git -C "$repo_root" cat-file -e "$ref^{tree}" 2>/dev/null; then
    echo "Error: not a tree-ish ref: $ref" >&2
    rm -f "$tree_paths" "$tree_ids" "$raw_manifest" "$validated_manifest" "$missing_manifest" "$unmapped_file"
    return 1
  fi
  if ! git -C "$repo_root" ls-tree -r -z --name-only "$ref" -- "$notes_dir" > "$tree_paths"; then
    rm -f "$tree_paths" "$tree_ids" "$raw_manifest" "$validated_manifest" "$missing_manifest" "$unmapped_file"
    return 1
  fi

  local tree_path relpath has_manifest=false
  while IFS= read -r -d '' tree_path; do
    relpath="${tree_path#"$notes_dir/"}"
    if [ "$relpath" = ".manifest" ]; then
      has_manifest=true
    else
      printf '%s\n' "$relpath" >> "$tree_ids"
    fi
  done < "$tree_paths"

  if ! $has_manifest; then
    local tree_count=0
    while IFS= read -r relpath; do
      [ -z "$relpath" ] && continue
      tree_count=$((tree_count + 1))
    done < "$tree_ids"
    rm -f "$tree_paths" "$tree_ids" "$raw_manifest" "$validated_manifest" "$missing_manifest" "$unmapped_file"
    if [ "$tree_count" -gt 0 ]; then
      echo "Error: $ref has $tree_count note file(s) but no $notes_dir/.manifest" >&2
      return 1
    fi
    return 0
  fi

  if ! git -C "$repo_root" cat-file --filters "$ref:$notes_dir/.manifest" > "$raw_manifest"; then
    rm -f "$tree_paths" "$tree_ids" "$raw_manifest" "$validated_manifest" "$missing_manifest" "$unmapped_file"
    return 1
  fi

  local id manifest_valid=true
  while IFS=$'\t' read -r id relpath; do
    [ -z "$id" ] && continue
    if ! _guard_manifest_path "id" "$id" || ! _guard_manifest_path "path" "$relpath"; then
      manifest_valid=false
      break
    fi
    printf '%s\t%s\n' "$id" "$relpath" >> "$validated_manifest"
  done < "$raw_manifest"
  if ! $manifest_valid; then
    rm -f "$tree_paths" "$tree_ids" "$raw_manifest" "$validated_manifest" "$missing_manifest" "$unmapped_file"
    return 1
  fi

  awk -F '\t' \
    -v valid="$manifest_out" \
    -v missing="$missing_manifest" \
    -v unmapped="$unmapped_file" '
      FILENAME == ARGV[1] { tree[$0] = 1; next }
      {
        mapped[$1] = 1
        if ($1 in tree) print $0 > valid
        else print $0 > missing
      }
      END {
        count = 0
        for (id in tree) if (!(id in mapped)) count++
        print count > unmapped
      }
    ' "$tree_ids" "$validated_manifest"

  while IFS=$'\t' read -r id relpath; do
    [ -z "$id" ] && continue
    echo "Warning: $ref manifest maps $id to $relpath, but $notes_dir/$id is missing" >&2
  done < "$missing_manifest"

  local unmapped_count=0
  IFS= read -r unmapped_count < "$unmapped_file" || unmapped_count=0
  rm -f "$tree_paths" "$tree_ids" "$raw_manifest" "$validated_manifest" "$missing_manifest" "$unmapped_file"
  if [ "$unmapped_count" -gt 0 ]; then
    echo "Error: $ref has $unmapped_count note file(s) not listed in $notes_dir/.manifest" >&2
    return 1
  fi
}

_changed_note_ids_between_refs() {
  local repo_root="$1" notes_dir="$2" base_ref="$3" head_ref="$4"
  local base_manifest="$5" head_manifest="$6" out="$7"
  local changed_paths candidates
  changed_paths=$(mktemp) || return 1
  candidates=$(mktemp) || { rm -f "$changed_paths"; return 1; }

  if ! git -C "$repo_root" diff --name-only -z "$base_ref" "$head_ref" -- "$notes_dir" > "$changed_paths"; then
    rm -f "$changed_paths" "$candidates"
    return 1
  fi

  local path id
  while IFS= read -r -d '' path; do
    id="${path#"$notes_dir/"}"
    case "$id" in
      .manifest|*/*) continue ;;
    esac
    [ -n "$id" ] && printf '%s\n' "$id" >> "$candidates"
  done < "$changed_paths"

  awk -F '\t' '
    function manifest_path(row) {
      return substr(row, index(row, FS) + 1)
    }
    FILENAME == ARGV[1] { selected_id[$1] = 1; next }
    FILENAME == ARGV[2] {
      path = manifest_path($0)
      base_row[$0] = 1
      row_id[$0] = $1
      base_path[path] = 1
      base_order[path, ++base_count[path]] = $1
      edge_id[++edge_count] = $1
      edge_path[edge_count] = path
      next
    }
    {
      path = manifest_path($0)
      head_row[$0] = 1
      row_id[$0] = $1
      head_path[path] = 1
      head_order[path, ++head_count[path]] = $1
      edge_id[++edge_count] = $1
      edge_path[edge_count] = path
    }
    END {
      for (row in base_row) if (!(row in head_row)) selected_id[row_id[row]] = 1
      for (row in head_row) if (!(row in base_row)) selected_id[row_id[row]] = 1

      # Exact row sets do not capture order. When IDs collide on one readable
      # path, their manifest order decides which blob materialization leaves
      # behind. Select every ID on paths whose order changed.
      for (path in base_path) compared_path[path] = 1
      for (path in head_path) compared_path[path] = 1
      for (path in compared_path) {
        order_changed = (base_count[path] != head_count[path])
        count = base_count[path] > head_count[path] ? base_count[path] : head_count[path]
        for (i = 1; !order_changed && i <= count; i++) {
          if (base_order[path, i] != head_order[path, i]) order_changed = 1
        }
        if (order_changed) {
          for (i = 1; i <= base_count[path]; i++) selected_id[base_order[path, i]] = 1
          for (i = 1; i <= head_count[path]; i++) selected_id[head_order[path, i]] = 1
        }
      }

      # A malformed or merge-produced manifest can alias one ID to multiple
      # paths, or multiple IDs to one path. Pull in the entire affected
      # ID/path component so selection preserves full-tree diff semantics.
      do {
        expanded = 0
        for (i = 1; i <= edge_count; i++) {
          if ((edge_id[i] in selected_id) || (edge_path[i] in selected_path)) {
            if (!(edge_id[i] in selected_id)) {
              selected_id[edge_id[i]] = 1
              expanded = 1
            }
            if (!(edge_path[i] in selected_path)) {
              selected_path[edge_path[i]] = 1
              expanded = 1
            }
          }
        }
      } while (expanded)

      for (id in selected_id) print id
    }
  ' "$candidates" "$base_manifest" "$head_manifest" > "$out"

  LC_ALL=C sort -u -o "$out" "$out"
  rm -f "$changed_paths" "$candidates"
}

_materialize_selected_notes_ref() {
  local repo_root="$1" notes_dir="$2" ref="$3" manifest="$4" ids="$5" dest="$6"
  local selected
  selected=$(mktemp) || return 1
  mkdir -p "$dest/$notes_dir"

  awk -F '\t' '
    FILENAME == ARGV[1] { wanted[$1] = 1; next }
    $1 in wanted { print }
  ' "$ids" "$manifest" > "$selected"

  local id relpath output_path output_parent materialize_ok=true
  while IFS=$'\t' read -r id relpath; do
    [ -z "$id" ] && continue
    output_path="$dest/$notes_dir/$relpath"
    output_parent="${output_path%/*}"
    mkdir -p "$output_parent"
    if ! git -C "$repo_root" cat-file --filters "$ref:$notes_dir/$id" > "$output_path"; then
      materialize_ok=false
      break
    fi
  done < "$selected"

  rm -f "$selected"
  $materialize_ok
}

# Validate both refs and materialize only notes that affect their readable diff.
materialize_changed_readable_notes_refs() {
  local repo_root="${1:?usage: materialize_changed_readable_notes_refs <repo_root> <notes_dir> <base_ref> <head_ref> <base_dest> <head_dest>}"
  local notes_dir="${2:?usage: materialize_changed_readable_notes_refs <repo_root> <notes_dir> <base_ref> <head_ref> <base_dest> <head_dest>}"
  local base_ref="${3:?usage: materialize_changed_readable_notes_refs <repo_root> <notes_dir> <base_ref> <head_ref> <base_dest> <head_dest>}"
  local head_ref="${4:?usage: materialize_changed_readable_notes_refs <repo_root> <notes_dir> <base_ref> <head_ref> <base_dest> <head_dest>}"
  local base_dest="${5:?usage: materialize_changed_readable_notes_refs <repo_root> <notes_dir> <base_ref> <head_ref> <base_dest> <head_dest>}"
  local head_dest="${6:?usage: materialize_changed_readable_notes_refs <repo_root> <notes_dir> <base_ref> <head_ref> <base_dest> <head_dest>}"
  local base_manifest head_manifest changed_ids
  base_manifest=$(mktemp) || return 1
  head_manifest=$(mktemp) || { rm -f "$base_manifest"; return 1; }
  changed_ids=$(mktemp) || { rm -f "$base_manifest" "$head_manifest"; return 1; }

  if ! _prepare_readable_notes_ref_index "$repo_root" "$notes_dir" "$base_ref" "$base_manifest" ||
     ! _prepare_readable_notes_ref_index "$repo_root" "$notes_dir" "$head_ref" "$head_manifest" ||
     ! _changed_note_ids_between_refs "$repo_root" "$notes_dir" "$base_ref" "$head_ref" "$base_manifest" "$head_manifest" "$changed_ids" ||
     ! _materialize_selected_notes_ref "$repo_root" "$notes_dir" "$base_ref" "$base_manifest" "$changed_ids" "$base_dest" ||
     ! _materialize_selected_notes_ref "$repo_root" "$notes_dir" "$head_ref" "$head_manifest" "$changed_ids" "$head_dest"; then
    rm -f "$base_manifest" "$head_manifest" "$changed_ids"
    return 1
  fi

  rm -f "$base_manifest" "$head_manifest" "$changed_ids"
}

_copy_tree_contents() {
  local src="$1" dest="$2"
  mkdir -p "$dest"
  (cd "$src" && tar -cf - .) | (cd "$dest" && tar -xf -)
}

_clear_tree_contents_except_git() {
  local dir="$1"
  find "$dir" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
}

# Generate a stable git-style patch from two readable trees.
# Usage: generate_readable_notes_patch <base_tree> <head_tree> <patch_file>
generate_readable_notes_patch() {
  local base_tree="${1:?usage: generate_readable_notes_patch <base_tree> <head_tree> <patch_file>}"
  local head_tree="${2:?usage: generate_readable_notes_patch <base_tree> <head_tree> <patch_file>}"
  local patch_file="${3:?usage: generate_readable_notes_patch <base_tree> <head_tree> <patch_file>}"
  local work
  work=$(mktemp -d) || return 1

  git -C "$work" init -q
  _copy_tree_contents "$base_tree" "$work"
  git -C "$work" add -A
  git -C "$work" \
    -c user.name="notes diff" \
    -c user.email="notes-diff@example.invalid" \
    commit -q --allow-empty -m "readable base"

  _clear_tree_contents_except_git "$work"
  _copy_tree_contents "$head_tree" "$work"
  git -C "$work" add -A
  git -C "$work" diff --cached --no-ext-diff --src-prefix=a/ --dst-prefix=b/ -- . > "$patch_file"

  rm -rf "$work"
}

_prepare_diff_workspace() {
  local out_dir="$1"
  if [ -L "$out_dir" ]; then
    echo "Error: --out path must not be a symlink: $out_dir" >&2
    return 1
  fi
  if [ -e "$out_dir" ] && [ ! -d "$out_dir" ]; then
    echo "Error: --out path exists and is not a directory: $out_dir" >&2
    return 1
  fi
  if [ -e "$out_dir" ] && [ -n "$(find "$out_dir" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]; then
    echo "Error: --out directory already exists and is not empty: $out_dir" >&2
    return 1
  fi
  mkdir -p "$out_dir/base" "$out_dir/head"
}
