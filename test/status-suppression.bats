#!/usr/bin/env bats

# Readable-note Git status suppression tests.

load test_helper
load changes_test_helper

# ── exclude management ────────────────────────────────────────

@test "set_status_suppression adds exclude entries" {
  local repo_root
  repo_root=$(git -C "$NOTES_CALLER_PWD" rev-parse --show-toplevel)
  local exclude="$repo_root/.git/info/exclude"

  # Suppression was already set in setup
  [ -f "$exclude" ]
  grep -q "notes/alpha.md" "$exclude"
  grep -q "notes/beta.md" "$exclude"
  grep -q "# BEGIN notes-obfuscation" "$exclude"
  grep -q "# END notes-obfuscation" "$exclude"
}

@test "set_status_suppression gives clean git status" {
  # After setup, git status should be clean
  run git -C "$NOTES_CALLER_PWD" status --porcelain
  [ -z "$output" ]
}

@test "clear_status_suppression removes exclude entries" {
  clear_status_suppression "$NOTES_CALLER_PWD/notes"

  local repo_root
  repo_root=$(git -C "$NOTES_CALLER_PWD" rev-parse --show-toplevel)
  local exclude="$repo_root/.git/info/exclude"

  # Managed block should be gone
  if [ -f "$exclude" ]; then
    ! grep -q "notes/alpha.md" "$exclude"
    ! grep -q "# BEGIN notes-obfuscation" "$exclude"
  fi
}

@test "exclude preserves non-managed content" {
  local repo_root
  repo_root=$(git -C "$NOTES_CALLER_PWD" rev-parse --show-toplevel)
  local exclude="$repo_root/.git/info/exclude"

  # Add custom content before the managed block
  local tmp
  tmp=$(mktemp)
  echo "# My custom excludes" > "$tmp"
  echo "build/" >> "$tmp"
  if [ -f "$exclude" ]; then
    cat "$exclude" >> "$tmp"
  fi
  mv "$tmp" "$exclude"

  # Re-run suppression (should preserve custom content)
  clear_status_suppression "$NOTES_CALLER_PWD/notes"
  set_status_suppression "$NOTES_CALLER_PWD/notes"

  grep -q "# My custom excludes" "$exclude"
  grep -q "build/" "$exclude"
  grep -q "notes/alpha.md" "$exclude"
}

@test "scoped set_status_suppression adds only specified entries" {
  # Clear all first
  clear_status_suppression "$NOTES_CALLER_PWD/notes"

  local alpha_id
  alpha_id=$(manifest_id_for_name "$MANIFEST" "alpha.md")

  # Set suppression for just alpha
  set_status_suppression "$NOTES_CALLER_PWD/notes" "$alpha_id"

  local repo_root
  repo_root=$(git -C "$NOTES_CALLER_PWD" rev-parse --show-toplevel)
  local exclude="$repo_root/.git/info/exclude"

  grep -q "notes/alpha.md" "$exclude"
  ! grep -q "notes/beta.md" "$exclude"
}

@test "scoped clear_status_suppression removes only specified entries" {
  local alpha_id
  alpha_id=$(manifest_id_for_name "$MANIFEST" "alpha.md")

  # Clear just alpha
  clear_status_suppression "$NOTES_CALLER_PWD/notes" "$alpha_id"

  local repo_root
  repo_root=$(git -C "$NOTES_CALLER_PWD" rev-parse --show-toplevel)
  local exclude="$repo_root/.git/info/exclude"

  ! grep -q "notes/alpha.md" "$exclude"
  grep -q "notes/beta.md" "$exclude"
}

@test "clear_status_suppression clears skip-worktree on managed opaque paths" {
  local alpha_id
  alpha_id=$(manifest_id_for_name "$MANIFEST" "alpha.md")
  git -C "$NOTES_CALLER_PWD" update-index \
    --no-assume-unchanged "notes/$alpha_id"
  git -C "$NOTES_CALLER_PWD" update-index \
    --skip-worktree "notes/$alpha_id"

  run git -C "$NOTES_CALLER_PWD" ls-files -v "notes/$alpha_id"
  [[ "$output" == S* ]]

  clear_status_suppression "$NOTES_CALLER_PWD/notes" "$alpha_id"

  run git -C "$NOTES_CALLER_PWD" ls-files -v "notes/$alpha_id"
  [[ "$output" != S* ]]
}

@test "status suppression helpers tolerate empty scope under nounset" {
  run bash -c '
    set -euo pipefail
    source "$1/lib/common.sh"
    source "$1/lib/suppress.sh"
    set_status_suppression "$2/notes"
    clear_status_suppression "$2/notes"
  ' _ "$REPO_DIR" "$NOTES_CALLER_PWD"

  [ "$status" -eq 0 ]
}

@test "notes suppress-refresh rebuilds stale exclude entries" {
  local repo_root exclude
  repo_root=$(git -C "$NOTES_CALLER_PWD" rev-parse --show-toplevel)
  exclude="$repo_root/.git/info/exclude"

  cat > "$exclude" <<EOF
# custom keep
$EXCLUDE_BEGIN
notes/alpha.md
$EXCLUDE_END
EOF

  run notes suppress-refresh
  [ "$status" -eq 0 ]
  [[ "$output" == *"Status suppression rebuilt"* ]]
  grep -q "# custom keep" "$exclude"
  grep -q "notes/alpha.md" "$exclude"
  grep -q "notes/beta.md" "$exclude"

  run git -C "$NOTES_CALLER_PWD" status --porcelain
  [ -z "$output" ]
}

@test "notes suppress-refresh clears stale assume-unchanged IDs from deobfuscation state" {
  mkdir -p "$NOTES_CALLER_PWD/.git/info"
  printf 'stale old id\n' > "$NOTES_CALLER_PWD/notes/deadbeef"
  git -C "$NOTES_CALLER_PWD" add notes/deadbeef
  git -C "$NOTES_CALLER_PWD" commit -q -m "add stale old id"
  git -C "$NOTES_CALLER_PWD" update-index --assume-unchanged notes/deadbeef
  printf 'deadbeef\told.md\t012345\n' > "$NOTES_CALLER_PWD/.git/info/notes-obfuscation-state"

  run git -C "$NOTES_CALLER_PWD" ls-files -v notes/deadbeef
  [ "$status" -eq 0 ]
  [[ "$output" == h* ]]

  run notes suppress-refresh
  [ "$status" -eq 0 ]

  run git -C "$NOTES_CALLER_PWD" ls-files -v notes/deadbeef
  [ "$status" -eq 0 ]
  [[ "$output" == H* ]]
}
