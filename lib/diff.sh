#!/usr/bin/env bash
# diff.sh — Materialize readable note trees from refs and diff them.

_ref_has_path() {
  local repo_root="$1" ref="$2" path="$3"
  git -C "$repo_root" cat-file -e "$ref:$path" 2>/dev/null
}

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

_materialize_manifest_for_ref() {
  local repo_root="$1" notes_dir="$2" ref="$3" out="$4"
  : > "$out"

  if ! _ref_has_path "$repo_root" "$ref" "$notes_dir/.manifest"; then
    return 0
  fi

  git -C "$repo_root" cat-file --filters "$ref:$notes_dir/.manifest" > "$out"
}

# Materialize a ref's obfuscated notes into readable filenames under dest.
# Usage: materialize_readable_notes_ref <repo_root> <notes_dir> <ref> <dest>
materialize_readable_notes_ref() {
  local repo_root="${1:?usage: materialize_readable_notes_ref <repo_root> <notes_dir> <ref> <dest>}"
  local notes_dir="${2:?usage: materialize_readable_notes_ref <repo_root> <notes_dir> <ref> <dest>}"
  local ref="${3:?usage: materialize_readable_notes_ref <repo_root> <notes_dir> <ref> <dest>}"
  local dest="${4:?usage: materialize_readable_notes_ref <repo_root> <notes_dir> <ref> <dest>}"
  local manifest
  manifest=$(mktemp) || return 1

  if ! git -C "$repo_root" cat-file -e "$ref^{tree}" 2>/dev/null; then
    echo "Error: not a tree-ish ref: $ref" >&2
    rm -f "$manifest"
    return 1
  fi

  mkdir -p "$dest/$notes_dir"
  local has_manifest=false
  if _ref_has_path "$repo_root" "$ref" "$notes_dir/.manifest"; then
    has_manifest=true
  fi
  if ! _materialize_manifest_for_ref "$repo_root" "$notes_dir" "$ref" "$manifest"; then
    rm -f "$manifest"
    return 1
  fi

  local manifest_ids
  manifest_ids=$(mktemp) || { rm -f "$manifest"; return 1; }
  while IFS=$'\t' read -r id relpath; do
    [ -z "$id" ] && continue
    _guard_manifest_path "id" "$id" || { rm -f "$manifest" "$manifest_ids"; return 1; }
    _guard_manifest_path "path" "$relpath" || { rm -f "$manifest" "$manifest_ids"; return 1; }
    printf '%s\n' "$id" >> "$manifest_ids"

    if ! _ref_has_path "$repo_root" "$ref" "$notes_dir/$id"; then
      echo "Warning: $ref manifest maps $id to $relpath, but $notes_dir/$id is missing" >&2
      continue
    fi

    mkdir -p "$(dirname "$dest/$notes_dir/$relpath")"
    if ! git -C "$repo_root" cat-file --filters "$ref:$notes_dir/$id" > "$dest/$notes_dir/$relpath"; then
      rm -f "$manifest" "$manifest_ids"
      return 1
    fi
  done < "$manifest"

  local tree_path relpath unmapped_count=0
  while IFS= read -r -d '' tree_path; do
    relpath="${tree_path#"$notes_dir/"}"
    [ "$relpath" = ".manifest" ] && continue
    if ! $has_manifest || ! grep -Fxq -- "$relpath" "$manifest_ids"; then
      unmapped_count=$((unmapped_count + 1))
    fi
  done < <(
    if ! git -C "$repo_root" ls-tree -r -z --name-only "$ref" -- "$notes_dir" 2>/dev/null; then
      :
    fi
  )

  rm -f "$manifest" "$manifest_ids"
  if [ "$unmapped_count" -gt 0 ]; then
    if $has_manifest; then
      echo "Error: $ref has $unmapped_count note file(s) not listed in $notes_dir/.manifest" >&2
    else
      echo "Error: $ref has $unmapped_count note file(s) but no $notes_dir/.manifest" >&2
    fi
    return 1
  fi
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
