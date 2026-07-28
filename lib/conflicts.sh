#!/usr/bin/env bash
# conflicts.sh — Read-only helpers for encrypted/obfuscated note conflicts.

NOTES_CONFLICT_RESOLUTION_URL="https://github.com/ricon-family/fold/blob/main/notes/resolving-encrypted-notes-merge-conflicts.md"

_notes_conflict_guard_id() {
  local id="$1"
  case "$id" in
    ""|.|..|*/*)
      echo "Error: unsafe note id: $id" >&2
      return 1
      ;;
  esac
}

_notes_conflict_guard_readable_path() {
  local relpath="$1"
  case "$relpath" in
    ""|.|..|/*|../*|*/../*|*"/.."|*"//"*)
      echo "Error: unsafe manifest path: $relpath" >&2
      return 1
      ;;
  esac
}

notes_conflict_prepare_out_dir() {
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

  mkdir -p "$out_dir/conflicts"
}

_notes_conflict_stage_exists() {
  local repo_root="$1" stage="$2" git_path="$3"
  git -C "$repo_root" cat-file -e ":$stage:$git_path" 2>/dev/null
}

_notes_conflict_manifest_stage_to_file() {
  local repo_root="$1" notes_dir="$2" stage="$3" out="$4"
  local manifest_path="$notes_dir/.manifest"

  if _notes_conflict_stage_exists "$repo_root" "$stage" "$manifest_path"; then
    git -C "$repo_root" cat-file --filters ":$stage:$manifest_path" >> "$out" 2>/dev/null || return 1
    printf '\n' >> "$out"
  fi
}

_notes_conflict_lookup_readable_name() {
  local repo_root="$1" notes_dir="$2" id="$3"
  local candidates matches relpath count

  _notes_conflict_guard_id "$id" || return 1

  candidates=$(mktemp) || return 1
  matches=$(mktemp) || { rm -f "$candidates"; return 1; }
  : > "$candidates"
  : > "$matches"

  # Prefer the current index entry when present, then ours/theirs/base for a
  # conflicted manifest. This is enough to map stable obfuscated IDs while
  # still refusing ambiguous or unproven mappings.
  if ! _notes_conflict_manifest_stage_to_file "$repo_root" "$notes_dir" 0 "$candidates"; then :; fi
  if ! _notes_conflict_manifest_stage_to_file "$repo_root" "$notes_dir" 2 "$candidates"; then :; fi
  if ! _notes_conflict_manifest_stage_to_file "$repo_root" "$notes_dir" 3 "$candidates"; then :; fi
  if ! _notes_conflict_manifest_stage_to_file "$repo_root" "$notes_dir" 1 "$candidates"; then :; fi

  # Unsafe input unlinks temp files only while aborting; the open reader stays valid.
  # shellcheck disable=SC2094
  while IFS=$'\t' read -r entry_id entry_name _extra; do
    [ "$entry_id" = "$id" ] || continue
    if ! _notes_conflict_guard_readable_path "$entry_name"; then
      rm -f "$candidates" "$matches"
      return 1
    fi
    printf '%s\n' "$entry_name" >> "$matches"
  done < "$candidates"

  local sorted_matches
  sorted_matches=$(mktemp) || { rm -f "$candidates" "$matches"; return 1; }
  sort -u "$matches" > "$sorted_matches"
  mv -f "$sorted_matches" "$matches"
  if ! count=$(grep -c . "$matches" 2>/dev/null); then
    count=0
  fi
  case "$count" in
    0)
      rm -f "$candidates" "$matches"
      return 2
      ;;
    1)
      relpath=$(cat "$matches")
      rm -f "$candidates" "$matches"
      printf '%s' "$relpath"
      return 0
      ;;
    *)
      echo "Error: ambiguous manifest mapping for $notes_dir/$id" >&2
      cat "$matches" >&2
      rm -f "$candidates" "$matches"
      return 1
      ;;
  esac
}

notes_conflict_unmerged_paths() {
  local repo_root="$1" notes_dir="$2"
  local meta git_path relpath workspace rc=0

  workspace=$(mktemp -d) || return 1
  if ! git -C "$repo_root" ls-files -u -- "$notes_dir" \
    > "$workspace/unmerged" 2> "$workspace/git-error"; then
    cat "$workspace/git-error" >&2
    rm -rf "$workspace"
    return 1
  fi

  : > "$workspace/paths"
  while IFS=$'\t' read -r meta git_path; do
    [ -n "$git_path" ] || continue
    case "$git_path" in
      "$notes_dir/.manifest") continue ;;
      "$notes_dir"/*)
        relpath="${git_path#"$notes_dir/"}"
        [ -n "$relpath" ] || continue
        printf '%s\n' "$git_path" >> "$workspace/paths"
        ;;
    esac
  done < "$workspace/unmerged"

  if ! sort -u "$workspace/paths" > "$workspace/sorted"; then
    rm -rf "$workspace"
    return 1
  fi
  cat "$workspace/sorted" || rc=$?
  rm -rf "$workspace"
  return "$rc"
}

# Output one row per unmerged note-content path:
#   <id>\t<readable-name-or-empty>\t<git-path>
# The optional third argument may be "allow-unmapped" for status/reporting.
notes_conflict_records() {
  local repo_root="$1" notes_dir="$2" mode="${3:-strict}"
  local git_path id readable lookup_rc workspace rc=0

  workspace=$(mktemp -d) || return 1
  if ! notes_conflict_unmerged_paths "$repo_root" "$notes_dir" > "$workspace/paths"; then
    rm -rf "$workspace"
    return 1
  fi
  : > "$workspace/records"

  while IFS= read -r git_path; do
    [ -n "$git_path" ] || continue
    id="${git_path#"$notes_dir/"}"

    if ! _notes_conflict_guard_id "$id"; then
      if [ "$mode" = "allow-unmapped" ]; then
        printf '%s\t__NOTES_UNMAPPED__\t%s\n' "$id" "$git_path" >> "$workspace/records"
        continue
      fi
      echo "Error: unsupported unmerged note path: $git_path" >&2
      rm -rf "$workspace"
      return 1
    fi

    readable=""
    if readable=$(_notes_conflict_lookup_readable_name "$repo_root" "$notes_dir" "$id"); then
      :
    else
      lookup_rc=$?
      if [ "$mode" = "allow-unmapped" ]; then
        readable="__NOTES_UNMAPPED__"
      else
        if [ "$lookup_rc" -eq 2 ]; then
          echo "Error: missing manifest mapping for $git_path" >&2
        fi
        rm -rf "$workspace"
        return 1
      fi
    fi

    printf '%s\t%s\t%s\n' "$id" "$readable" "$git_path" >> "$workspace/records"
  done < "$workspace/paths"

  cat "$workspace/records" || rc=$?
  rm -rf "$workspace"
  return "$rc"
}

notes_conflict_require_three_stages() {
  local repo_root="$1" git_path="$2"
  local stage

  for stage in 1 2 3; do
    if ! _notes_conflict_stage_exists "$repo_root" "$stage" "$git_path"; then
      echo "Error: unsupported conflict shape for $git_path; expected base, ours, and theirs stages" >&2
      return 1
    fi
  done
}

_notes_conflict_file_has_gitcrypt_header() {
  local file="$1" sig
  sig=$(dd if="$file" bs=9 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')
  [ "$sig" = "004749544352595054" ]
}

notes_conflict_extract_stage() {
  local repo_root="$1" stage="$2" git_path="$3" dest="$4"
  local tmp

  tmp=$(mktemp) || return 1
  if ! git -C "$repo_root" cat-file --filters ":$stage:$git_path" > "$tmp" 2>/dev/null; then
    echo "Error: failed to extract stage $stage for $git_path" >&2
    rm -f "$tmp"
    return 1
  fi
  if _notes_conflict_file_has_gitcrypt_header "$tmp"; then
    echo "Error: git-crypt filters did not decrypt stage $stage for $git_path" >&2
    echo "Unlock the repo or reinstall notes hooks/filters before writing conflict artifacts." >&2
    rm -f "$tmp"
    return 1
  fi
  mv -f "$tmp" "$dest"
}

notes_conflict_write_artifacts() {
  local repo_root="$1" notes_dir="$2" out_dir="$3" records="$4"
  local id readable git_path conflict_dir

  notes_conflict_prepare_out_dir "$out_dir" || return 1

  while IFS=$'\t' read -r id readable git_path; do
    [ -n "$id" ] || continue
    [ -n "$readable" ] || { echo "Error: missing readable name for $git_path" >&2; return 1; }
    notes_conflict_require_three_stages "$repo_root" "$git_path" || return 1

    conflict_dir="$out_dir/conflicts/$readable"
    mkdir -p "$conflict_dir"
    notes_conflict_extract_stage "$repo_root" 1 "$git_path" "$conflict_dir/base.md" || return 1
    notes_conflict_extract_stage "$repo_root" 2 "$git_path" "$conflict_dir/ours.md" || return 1
    notes_conflict_extract_stage "$repo_root" 3 "$git_path" "$conflict_dir/theirs.md" || return 1
  done <<< "$records"
}

notes_conflict_print_next_steps() {
  local out_dir="$1"
  cat <<EOF

Artifacts written under: $out_dir/conflicts
Next steps:
  1. Compare base.md, ours.md, and theirs.md for each note.
  2. Write the resolved plaintext into the conflicted obfuscated note path.
  3. Stage that obfuscated path with git add after resolving it.
  4. Confirm git ls-files -u no longer lists the note path before committing.
See: $NOTES_CONFLICT_RESOLUTION_URL
EOF
}
