#!/usr/bin/env bash
# manifest-merge-driver.sh — custom git merge driver for .manifest files
#
# Git calls this with: %O %A %B (ancestor, ours, theirs)
# The driver must write the merged result to %A and exit 0 on success,
# non-zero on conflict.
#
# Manifest format: <id>\t<name>, sorted by name, one entry per line.
#
# Strategy: union merge — all unique entries from both sides are kept.
# Deletions are respected (entry in ancestor + one side, missing from other).
#
# When both sides independently add the same filename with different random
# IDs (common when two branches create the same note), we prefer ours.
# A true conflict is when the ancestor had an entry and both sides changed
# its ID differently (which shouldn't happen in normal operation).
#
# Bash 3.2 compatible (no associative arrays).
#
# Known limitation: pure renames (same ID, different name across branches)
# could result in two names pointing to one ID. In practice this doesn't
# happen because rename = delete old + create new with new ID under the
# current obfuscate logic. If rename-in-place is ever added, this driver
# should detect the "two names → one ID" case.
set -euo pipefail

ANCESTOR="$1"  # %O — common ancestor
OURS="$2"      # %A — current branch (merge result goes here)
THEIRS="$3"    # %B — branch being merged

# Temp files for lookups
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Git invokes merge drivers with index content, which for git-crypt-tracked
# files is the encrypted ciphertext (starting with the 10-byte header
# "\0GITCRYPT\0"). We need plaintext to merge.
#
# If the file is encrypted, decrypt it through git-crypt's smudge filter. If
# smudge fails (repo locked, git-crypt not installed), this is a hard error
# — we exit non-zero with a diagnostic. The calling `set -euo pipefail` will
# abort the driver, which leaves `ours` unchanged. That's the right
# behavior: git then surfaces a merge conflict on the manifest, and the
# user is forced to investigate rather than silently accepting a corrupted
# merged manifest.
is_gitcrypt_file() {
  local src="$1"
  [ -s "$src" ] || return 1
  # git-crypt files begin with the 10-byte header \0 G I T C R Y P T \0.
  # Bash strings can't hold the leading \0 (it terminates the string), so
  # read bytes 2-9 and check they spell "GITCRYPT". Files shorter than 9
  # bytes safely fall through — `dd` returns < 8 bytes, the header won't
  # match, and we treat it as plaintext.
  local header
  header=$(dd if="$src" bs=1 skip=1 count=8 2>/dev/null)
  [ "$header" = "GITCRYPT" ]
}

decrypt_if_needed() {
  local src="$1" dst="$2"
  if [ ! -s "$src" ]; then
    : > "$dst"
    return 0
  fi
  if is_gitcrypt_file "$src"; then
    if ! git-crypt smudge < "$src" > "$dst" 2>/dev/null; then
      echo "manifest-merge-driver: git-crypt smudge failed on $src — is the repo unlocked?" >&2
      echo "manifest-merge-driver: aborting merge to avoid producing a corrupt manifest." >&2
      return 1
    fi
  else
    cp "$src" "$dst"
  fi
}

write_success_result() {
  local plaintext="$1"
  if is_gitcrypt_file "$ANCESTOR" || is_gitcrypt_file "$OURS" || is_gitcrypt_file "$THEIRS"; then
    if ! git-crypt clean < "$plaintext" > "$OURS" 2>/dev/null; then
      echo "manifest-merge-driver: git-crypt clean failed — is this a git-crypt repo?" >&2
      echo "manifest-merge-driver: aborting merge to avoid committing a plaintext manifest." >&2
      return 1
    fi
  else
    cp "$plaintext" "$OURS"
  fi
}

# Normalize: decrypt if encrypted, strip blank lines, sort by name.
# Uses $WORK (bound in the outer scope) for temp files so cleanup is tied
# to the outer trap.
normalize() {
  local src="$1" plaintext
  plaintext=$(mktemp "$WORK/plain.XXXXXX")
  decrypt_if_needed "$src" "$plaintext" || return 1
  awk 'NF' "$plaintext" 2>/dev/null | sort -t$'\t' -k2
}

normalize "$ANCESTOR" > "$WORK/anc"
normalize "$OURS"     > "$WORK/ours"
normalize "$THEIRS"   > "$WORK/theirs"

# Look up id for a name in a file. Prints id or nothing.
# Uses read loop instead of grep to avoid regex metachar issues in filenames.
id_for_name() {
  local file="$1" name="$2"
  [ ! -f "$file" ] && return 0
  while IFS=$'\t' read -r id entry_name; do
    if [ "$entry_name" = "$name" ]; then
      printf '%s' "$id"
      return
    fi
  done < "$file"
}

# Collect all unique names across all three files
cut -f2 "$WORK/anc" "$WORK/ours" "$WORK/theirs" 2>/dev/null | sort -u > "$WORK/all_names"

# Merge
has_conflict=false
> "$WORK/merged"
> "$WORK/conflicts"

while IFS= read -r name; do
  [ -z "$name" ] && continue

  a_id=$(id_for_name "$WORK/anc" "$name")
  o_id=$(id_for_name "$WORK/ours" "$name")
  t_id=$(id_for_name "$WORK/theirs" "$name")

  if [ -n "$o_id" ] && [ -n "$t_id" ]; then
    if [ "$o_id" = "$t_id" ]; then
      # Both agree
      printf '%s\t%s\n' "$o_id" "$name" >> "$WORK/merged"
    elif [ -z "$a_id" ]; then
      # Both sides independently added the same name with different IDs.
      # This happens when two branches create the same note — each gets
      # a random ID. Prefer ours. The theirs obfuscated file will be
      # orphaned but harmless (no manifest entry pointing to it).
      printf '%s\t%s\n' "$o_id" "$name" >> "$WORK/merged"
    elif [ "$o_id" = "$a_id" ]; then
      # Ours unchanged from ancestor, theirs updated — accept theirs
      printf '%s\t%s\n' "$t_id" "$name" >> "$WORK/merged"
    elif [ "$t_id" = "$a_id" ]; then
      # Theirs unchanged from ancestor, ours updated — accept ours
      printf '%s\t%s\n' "$o_id" "$name" >> "$WORK/merged"
    else
      # Both sides changed the ID differently — true conflict
      has_conflict=true
      {
        echo "<<<<<<< ours"
        printf '%s\t%s\n' "$o_id" "$name"
        echo "======="
        printf '%s\t%s\n' "$t_id" "$name"
        echo ">>>>>>> theirs"
      } >> "$WORK/conflicts"
    fi
  elif [ -n "$o_id" ] && [ -z "$t_id" ]; then
    if [ -n "$a_id" ]; then
      : # Was in ancestor, deleted by theirs — accept deletion
    else
      # New in ours only
      printf '%s\t%s\n' "$o_id" "$name" >> "$WORK/merged"
    fi
  elif [ -z "$o_id" ] && [ -n "$t_id" ]; then
    if [ -n "$a_id" ]; then
      : # Was in ancestor, deleted by ours — accept deletion
    else
      # New in theirs only
      printf '%s\t%s\n' "$t_id" "$name" >> "$WORK/merged"
    fi
  fi
done < "$WORK/all_names"

# Write result to OURS (git expects the merge result there). On successful
# git-crypt-backed merges, write encrypted output because rebase/custom-driver
# paths can commit %A directly without running the clean filter again.
sort -t$'\t' -k2 "$WORK/merged" > "$WORK/result"

if [ "$has_conflict" = true ]; then
  cp "$WORK/result" "$OURS"
  cat "$WORK/conflicts" >> "$OURS"
  exit 1
else
  write_success_result "$WORK/result"
  exit 0
fi
