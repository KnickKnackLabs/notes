#!/usr/bin/env bats

# Tests for notes changes detection and the changes/stage commands.

load test_helper

setup() {
  export NOTES_CALLER_PWD="$BATS_TEST_TMPDIR"
  source "$REPO_DIR/lib/common.sh"
  source "$REPO_DIR/lib/obfuscate.sh"
  source "$REPO_DIR/lib/suppress.sh"
  source "$REPO_DIR/lib/changes.sh"

  # Create a git repo with obfuscated notes
  git -C "$NOTES_CALLER_PWD" init -q
  git -C "$NOTES_CALLER_PWD" config user.name "Test"
  git -C "$NOTES_CALLER_PWD" config user.email "test@test.com"

  mkdir -p "$NOTES_CALLER_PWD/notes"
  echo "# Alpha" > "$NOTES_CALLER_PWD/notes/alpha.md"
  echo "# Beta" > "$NOTES_CALLER_PWD/notes/beta.md"

  MANIFEST="$NOTES_CALLER_PWD/notes/.manifest"

  # Obfuscate, commit, then deobfuscate (simulates normal state)
  rename_to_obfuscated "$NOTES_CALLER_PWD/notes" > /dev/null
  git -C "$NOTES_CALLER_PWD" add -A
  git -C "$NOTES_CALLER_PWD" commit -q -m "initial"
  rename_to_readable "$NOTES_CALLER_PWD/notes" > /dev/null
  set_status_suppression "$NOTES_CALLER_PWD/notes"
}

record_deobfuscation_state_for_manifest() {
  local ids=()
  while IFS=$'\t' read -r id relpath; do
    [ -z "$id" ] && continue
    ids+=("$id")
  done < "$MANIFEST"
  _record_deobfuscation_base_hashes "$NOTES_CALLER_PWD/notes" "${ids[@]}"
}

delete_manifest_entry_from_head() {
  local relpath="$1"
  local id
  id=$(manifest_id_for_name "$MANIFEST" "$relpath")
  [ -n "$id" ]

  git -C "$NOTES_CALLER_PWD" update-index --no-assume-unchanged "notes/$id" 2>/dev/null || true
  git -C "$NOTES_CALLER_PWD" rm -q --cached "notes/$id"
  awk -F '\t' -v path="$relpath" '$2 != path { print }' "$MANIFEST" > "$MANIFEST.tmp"
  mv "$MANIFEST.tmp" "$MANIFEST"
  git -C "$NOTES_CALLER_PWD" add notes/.manifest
  git -C "$NOTES_CALLER_PWD" commit -q -m "delete $relpath"

  printf '%s' "$id"
}

rename_manifest_entry_in_head() {
  local old_relpath="$1" new_relpath="$2"
  local id
  id=$(manifest_id_for_name "$MANIFEST" "$old_relpath")
  [ -n "$id" ]

  awk -F '\t' -v old="$old_relpath" -v new="$new_relpath" 'BEGIN { OFS="\t" } $2 == old { $2 = new } { print }' "$MANIFEST" > "$MANIFEST.tmp"
  mv "$MANIFEST.tmp" "$MANIFEST"
  git -C "$NOTES_CALLER_PWD" add notes/.manifest
  git -C "$NOTES_CALLER_PWD" commit -q -m "rename $old_relpath"

  printf '%s' "$id"
}

# ── detect_changes ────────────────────────────────────────────

@test "detect_changes: no changes when files match HEAD" {
  run detect_changes "$NOTES_CALLER_PWD/notes"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "detect_changes: detects modified file" {
  echo "# Alpha modified" > "$NOTES_CALLER_PWD/notes/alpha.md"

  run detect_changes "$NOTES_CALLER_PWD/notes"
  [ "$status" -eq 0 ]
  [[ "$output" == *"modified"*"alpha.md"* ]]
  # Beta should not appear
  [[ "$output" != *"beta.md"* ]]
}

@test "detect_changes: detects new file not in manifest" {
  echo "# Gamma" > "$NOTES_CALLER_PWD/notes/gamma.md"

  run detect_changes "$NOTES_CALLER_PWD/notes"
  [ "$status" -eq 0 ]
  [[ "$output" == *"new"*"gamma.md"* ]]
}

@test "detect_changes: detects new file in manifest but not in HEAD" {
  echo "# Gamma" > "$NOTES_CALLER_PWD/notes/gamma.md"
  # Manifest entry exists but file was never committed
  printf 'cccccccc\tgamma.md\n' >> "$MANIFEST"

  run detect_changes "$NOTES_CALLER_PWD/notes"
  [ "$status" -eq 0 ]
  [[ "$output" == *"new"*"gamma.md"* ]]
}

@test "detect_changes: detects deleted file" {
  # Remove the readable file and the obfuscated file
  rm "$NOTES_CALLER_PWD/notes/alpha.md"
  local alpha_id
  alpha_id=$(manifest_id_for_name "$MANIFEST" "alpha.md")
  # The obfuscated file shouldn't exist (we're in deobfuscated state)
  # but make sure it's gone
  rm -f "$NOTES_CALLER_PWD/notes/$alpha_id"

  run detect_changes "$NOTES_CALLER_PWD/notes"
  [ "$status" -eq 0 ]
  [[ "$output" == *"deleted"*"alpha.md"* ]]
}

@test "detect_changes: multiple changes detected" {
  echo "# Alpha modified" > "$NOTES_CALLER_PWD/notes/alpha.md"
  echo "# Gamma" > "$NOTES_CALLER_PWD/notes/gamma.md"

  run detect_changes "$NOTES_CALLER_PWD/notes"
  [ "$status" -eq 0 ]
  [[ "$output" == *"modified"*"alpha.md"* ]]
  [[ "$output" == *"new"*"gamma.md"* ]]
}

@test "detect_changes: unchanged files not reported" {
  # Make no changes
  run detect_changes "$NOTES_CALLER_PWD/notes"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "detect_changes: handles many notes with mixed changes" {
  local i name delete_id

  i=1
  while [ "$i" -le 40 ]; do
    name=$(printf 'note-%02d.md' "$i")
    printf '# Note %02d\n' "$i" > "$NOTES_CALLER_PWD/notes/$name"
    i=$((i + 1))
  done

  rename_to_obfuscated "$NOTES_CALLER_PWD/notes" > /dev/null
  git -C "$NOTES_CALLER_PWD" add -A
  git -C "$NOTES_CALLER_PWD" commit -q -m "add many notes"
  rename_to_readable "$NOTES_CALLER_PWD/notes" > /dev/null
  set_status_suppression "$NOTES_CALLER_PWD/notes"

  printf '# Note 10 edited\n' > "$NOTES_CALLER_PWD/notes/note-10.md"
  printf '# New\n' > "$NOTES_CALLER_PWD/notes/new.md"
  rm "$NOTES_CALLER_PWD/notes/note-20.md"
  delete_id=$(manifest_id_for_name "$MANIFEST" "note-20.md")
  rm -f "$NOTES_CALLER_PWD/notes/$delete_id"

  run detect_changes "$NOTES_CALLER_PWD/notes"
  [ "$status" -eq 0 ]
  [[ "$output" == *"modified"*"note-10.md"* ]]
  [[ "$output" == *"deleted"*"note-20.md"* ]]
  [[ "$output" == *"new"*"new.md"* ]]
  [[ "$output" != *"note-30.md"* ]]
}

@test "detect_changes: preserves tracked-path filter semantics when attrs differ" {
  local repo
  repo="$BATS_TEST_TMPDIR/path-attrs-repo"
  mkdir -p "$repo/notes"
  git -C "$repo" init -q
  git -C "$repo" config user.name "Test"
  git -C "$repo" config user.email "test@test.com"
  git -C "$repo" config filter.prefix.clean "sed 's/^/clean:/'"
  printf 'notes/???????? filter=prefix\n' > "$repo/.gitattributes"
  echo "# Alpha" > "$repo/notes/alpha.md"
  echo "# Beta" > "$repo/notes/beta.md"

  rename_to_obfuscated "$repo/notes" > /dev/null
  git -C "$repo" add -A
  git -C "$repo" commit -q -m "initial with path-specific attrs"
  rename_to_readable "$repo/notes" > /dev/null
  set_status_suppression "$repo/notes"

  run detect_changes "$repo/notes"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  printf '# Alpha edited\n' > "$repo/notes/alpha.md"
  run detect_changes "$repo/notes"
  [ "$status" -eq 0 ]
  [[ "$output" == *"modified"*"alpha.md"* ]]
}

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

# ── stage via git add -f ─────────────────────────────────────

@test "git add -f works despite exclude" {
  echo "# Alpha modified" > "$NOTES_CALLER_PWD/notes/alpha.md"

  # Normal git add should fail (file is excluded)
  git -C "$NOTES_CALLER_PWD" add "$NOTES_CALLER_PWD/notes/alpha.md" 2>/dev/null || true
  run git -C "$NOTES_CALLER_PWD" diff --cached --name-only
  [[ "$output" != *"alpha.md"* ]]

  # Force add should work
  git -C "$NOTES_CALLER_PWD" add -f "$NOTES_CALLER_PWD/notes/alpha.md"
  run git -C "$NOTES_CALLER_PWD" diff --cached --name-only
  [[ "$output" == *"alpha.md"* ]]
}

@test "notes stage: no args requires explicit scope" {
  echo "# Alpha modified" > "$NOTES_CALLER_PWD/notes/alpha.md"
  echo "# Gamma" > "$NOTES_CALLER_PWD/notes/gamma.md"

  run notes stage
  [ "$status" -ne 0 ]
  [[ "$output" == *"provide note paths or --all"* ]]

  run git -C "$NOTES_CALLER_PWD" diff --cached --name-only
  [ -z "$output" ]
}

@test "notes stage: no args ignores inherited usage_files and still requires scope" {
  echo "# Alpha modified" > "$NOTES_CALLER_PWD/notes/alpha.md"

  usage_files="gamma.md" run notes stage
  [ "$status" -ne 0 ]
  [[ "$output" == *"provide note paths or --all"* ]]

  run git -C "$NOTES_CALLER_PWD" diff --cached --name-only
  [ -z "$output" ]
}

@test "notes stage --all stages modified and new notes" {
  echo "# Alpha modified" > "$NOTES_CALLER_PWD/notes/alpha.md"
  echo "# Gamma" > "$NOTES_CALLER_PWD/notes/gamma.md"

  run notes stage --all
  [ "$status" -eq 0 ]
  [[ "$output" == *"staged: alpha.md"* ]]
  [[ "$output" == *"staged: gamma.md"* ]]

  run git -C "$NOTES_CALLER_PWD" diff --cached --name-only
  [[ "$output" == *"notes/alpha.md"* ]]
  [[ "$output" == *"notes/gamma.md"* ]]
}

@test "notes stage: explicit file stages a new note" {
  echo "# Gamma" > "$NOTES_CALLER_PWD/notes/gamma.md"

  run notes stage gamma.md
  [ "$status" -eq 0 ]
  [[ "$output" == *"staged: gamma.md"* ]]

  run git -C "$NOTES_CALLER_PWD" diff --cached --name-only
  [[ "$output" == *"notes/gamma.md"* ]]
}

@test "notes stage: explicit unknown path fails instead of silently selecting nothing" {
  echo "# Alpha modified" > "$NOTES_CALLER_PWD/notes/alpha.md"

  run notes stage alhpa.md
  [ "$status" -ne 0 ]
  [[ "$output" == *"requested note path"* ]]
  [[ "$output" == *"alhpa.md"* ]]

  run git -C "$NOTES_CALLER_PWD" diff --cached --name-only
  [ -z "$output" ]
}

@test "notes stage: path traversal argument fails instead of selecting nothing" {
  echo "# Alpha modified" > "$NOTES_CALLER_PWD/notes/alpha.md"
  echo "readme" > "$NOTES_CALLER_PWD/README.md"

  run notes stage ../README.md
  [ "$status" -ne 0 ]
  [[ "$output" == *"requested note path"* ]]
  [[ "$output" == *"../README.md"* ]]

  run git -C "$NOTES_CALLER_PWD" diff --cached --name-only
  [ -z "$output" ]
}

@test "notes stage --dry-run: deleted note leaves manifest and index untouched" {
  local manifest_before
  manifest_before=$(cat "$MANIFEST")
  rm "$NOTES_CALLER_PWD/notes/alpha.md"

  run notes stage --all --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Would stage:"* ]]
  [[ "$output" == *"alpha.md"* ]]
  [ "$(cat "$MANIFEST")" = "$manifest_before" ]

  run git -C "$NOTES_CALLER_PWD" diff --cached --name-only
  [ -z "$output" ]
}

@test "notes stage: deleted note does not mutate manifest when index removal fails" {
  local manifest_before
  manifest_before=$(cat "$MANIFEST")
  rm "$NOTES_CALLER_PWD/notes/alpha.md"
  touch "$NOTES_CALLER_PWD/.git/index.lock"

  run notes stage --all
  rm -f "$NOTES_CALLER_PWD/.git/index.lock"

  [ "$status" -ne 0 ]
  [ "$(cat "$MANIFEST")" = "$manifest_before" ]

  run git -C "$NOTES_CALLER_PWD" diff --cached --name-only
  [ -z "$output" ]
}

@test "notes stage: deleted note rolls back manifest when manifest staging fails" {
  local alpha_id manifest_before real_git
  alpha_id=$(manifest_id_for_name "$MANIFEST" "alpha.md")
  manifest_before=$(cat "$MANIFEST")
  real_git=$(command -v git)
  rm "$NOTES_CALLER_PWD/notes/alpha.md"

  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/git" <<SH
#!/usr/bin/env bash
if [ "\$1" = "-C" ] && [ "\$3" = "add" ] && [ "\$4" = "-f" ] && [ "\$5" = "notes/.manifest" ]; then
  echo "simulated manifest add failure" >&2
  exit 99
fi
exec "$real_git" "\$@"
SH
  chmod +x "$BATS_TEST_TMPDIR/bin/git"

  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run notes stage --all
  [ "$status" -ne 0 ]
  [ "$(cat "$MANIFEST")" = "$manifest_before" ]

  run git -C "$NOTES_CALLER_PWD" diff --cached --name-status
  [[ "$output" == *$'D\tnotes/'"$alpha_id"* ]]
  [[ "$output" != *$'M\tnotes/.manifest'* ]]

  run notes stage --all
  [ "$status" -eq 0 ]
  run git -C "$NOTES_CALLER_PWD" diff --cached --name-status
  [[ "$output" == *$'D\tnotes/'"$alpha_id"* ]]
  [[ "$output" == *$'M\tnotes/.manifest'* ]]
}

@test "notes stage: deleted note stages manifest update in same commit" {
  source "$REPO_DIR/lib/hooks.sh"
  install_obfuscation_hook
  install_deobfuscation_hook

  local alpha_id
  alpha_id=$(manifest_id_for_name "$MANIFEST" "alpha.md")
  rm "$NOTES_CALLER_PWD/notes/alpha.md"

  run notes stage --all
  [ "$status" -eq 0 ]
  [[ "$output" == *"staged (delete): alpha.md"* ]]

  run git -C "$NOTES_CALLER_PWD" diff --cached --name-status
  [[ "$output" == *$'D\tnotes/'"$alpha_id"* ]]
  [[ "$output" == *$'M\tnotes/.manifest'* ]]

  git -C "$NOTES_CALLER_PWD" commit -q -m "delete alpha"

  run git -C "$NOTES_CALLER_PWD" status --porcelain
  [ -z "$output" ]

  run git -C "$NOTES_CALLER_PWD" cat-file --filters HEAD:notes/.manifest
  [[ "$output" != *"alpha.md"* ]]
  [[ "$output" == *"beta.md"* ]]
}

@test "notes stage: refuses dual-present differing readable and obfuscated pair" {
  local alpha_id
  alpha_id=$(manifest_id_for_name "$MANIFEST" "alpha.md")

  echo "# Alpha local edit" > "$NOTES_CALLER_PWD/notes/alpha.md"
  echo "# Alpha incoming upstream" > "$NOTES_CALLER_PWD/notes/$alpha_id"

  run notes stage alpha.md
  [ "$status" -ne 0 ]
  [[ "$output" == *"incomplete deobfuscation"* ]]
  [[ "$output" == *"alpha.md"* ]]
  [[ "$output" == *"notes deobfuscate"* ]]
  [[ "$output" == *"notes changes alpha.md"* ]]

  run git -C "$NOTES_CALLER_PWD" diff --cached --name-only
  [[ "$output" != *"notes/alpha.md"* ]]
}

@test "notes stage: refuses double-tracked notes (readable + obfuscated both in index)" {
  local alpha_id
  alpha_id=$(manifest_id_for_name "$MANIFEST" "alpha.md")

  # Simulate the double-tracking bug from notes#51: both readable and hex tracked.
  # Use identical content so the dual-present conflict check does not fire first.
  echo "# Alpha obfuscated" > "$NOTES_CALLER_PWD/notes/alpha.md"
  echo "# Alpha obfuscated" > "$NOTES_CALLER_PWD/notes/$alpha_id"
  git -C "$NOTES_CALLER_PWD" add -f "notes/alpha.md"

  run notes stage alpha.md
  [ "$status" -ne 0 ]
  [[ "$output" == *"double-tracked"* ]]
  [[ "$output" == *"alpha.md"* ]]
  [[ "$output" == *"notes#51"* ]]
}

@test "notes stage: does not refuse when readable is only on disk, not tracked" {
  local alpha_id
  alpha_id=$(manifest_id_for_name "$MANIFEST" "alpha.md")

  # Normal deobfuscated state: readable on disk, hex tracked in index
  echo "# Alpha v2" > "$NOTES_CALLER_PWD/notes/alpha.md"

  run notes stage alpha.md
  [ "$status" -eq 0 ]
  [[ "$output" == *"staged: alpha.md"* ]]
}

@test "notes stage --all refuses stale readable files left from another branch" {
  local repo="$BATS_TEST_TMPDIR/branch-repo"
  mkdir -p "$repo/notes"
  git -C "$repo" init -q -b main
  git -C "$repo" config user.name "Test"
  git -C "$repo" config user.email "test@test.com"

  echo "# Alpha" > "$repo/notes/alpha.md"
  rename_to_obfuscated "$repo/notes" > /dev/null
  git -C "$repo" add -A
  git -C "$repo" commit -q -m "add alpha"
  rename_to_readable "$repo/notes" > /dev/null
  set_status_suppression "$repo/notes"

  git -C "$repo" branch feature

  echo "# Beta" > "$repo/notes/beta.md"
  rename_to_obfuscated "$repo/notes" > /dev/null
  git -C "$repo" add -A
  git -C "$repo" commit -q -m "add beta on main"
  rename_to_readable "$repo/notes" > /dev/null
  set_status_suppression "$repo/notes"

  git -C "$repo" checkout -q feature
  [ -f "$repo/notes/beta.md" ]
  echo "alpha edit" >> "$repo/notes/alpha.md"

  NOTES_CALLER_PWD="$repo" run notes changes --summary
  [ "$status" -eq 0 ]
  [[ "$output" == *"stale-readable: beta.md"* ]]
  [[ "$output" != *"new:       beta.md"* ]]

  NOTES_CALLER_PWD="$repo" run notes stage --all
  [ "$status" -ne 0 ]
  [[ "$output" == *"stale readable note"* ]]
  [[ "$output" == *"beta.md"* ]]

  run git -C "$repo" diff --cached --name-only
  [[ "$output" != *"notes/alpha.md"* ]]
  [[ "$output" != *"notes/beta.md"* ]]
}

@test "notes changes: stale readable is not reported as a new note" {
  record_deobfuscation_state_for_manifest
  delete_manifest_entry_from_head "beta.md" > /dev/null

  run notes changes --summary
  [ "$status" -eq 0 ]
  [[ "$output" == *"stale-readable: beta.md"* ]]
  [[ "$output" != *"new:       beta.md"* ]]
}

@test "notes stage: refuses explicit stale readable note" {
  record_deobfuscation_state_for_manifest
  delete_manifest_entry_from_head "beta.md" > /dev/null

  run notes stage beta.md
  [ "$status" -ne 0 ]
  [[ "$output" == *"stale readable note"* ]]
  [[ "$output" == *"beta.md"* ]]

  run git -C "$NOTES_CALLER_PWD" diff --cached --name-only
  [[ "$output" != *"notes/beta.md"* ]]
}

@test "deobfuscate removes clean stale readable after manifest deletion" {
  record_deobfuscation_state_for_manifest
  delete_manifest_entry_from_head "beta.md" > /dev/null

  run notes deobfuscate
  [ "$status" -eq 0 ]
  [[ "$output" == *"removed stale readable: beta.md"* ]]
  [ ! -f "$NOTES_CALLER_PWD/notes/beta.md" ]
  ! grep -q "notes/beta.md" "$NOTES_CALLER_PWD/.git/info/exclude"

  run notes changes --summary
  [ "$status" -eq 0 ]
  [[ "$output" == *"No changes."* ]]
}

@test "deobfuscate removes clean stale readable with legacy id-hash state" {
  local beta_id beta_hash state
  beta_id=$(manifest_id_for_name "$MANIFEST" "beta.md")
  beta_hash=$(git -C "$NOTES_CALLER_PWD" hash-object -- "$NOTES_CALLER_PWD/notes/beta.md")
  state="$NOTES_CALLER_PWD/.git/info/notes-obfuscation-state"
  mkdir -p "$(dirname "$state")"
  printf '%s\t%s\n' "$beta_id" "$beta_hash" > "$state"

  delete_manifest_entry_from_head "beta.md" > /dev/null

  run notes deobfuscate
  [ "$status" -eq 0 ]
  [[ "$output" == *"removed stale readable: beta.md"* ]]
  [ ! -f "$NOTES_CALLER_PWD/notes/beta.md" ]

  run notes changes --summary
  [ "$status" -eq 0 ]
  [[ "$output" == *"No changes."* ]]
}

@test "deobfuscate quarantines dirty stale readable after manifest deletion" {
  record_deobfuscation_state_for_manifest
  echo "local edit" >> "$NOTES_CALLER_PWD/notes/beta.md"
  delete_manifest_entry_from_head "beta.md" > /dev/null

  run notes deobfuscate
  [ "$status" -eq 0 ]
  [[ "$output" == *"quarantined stale readable note: beta.md"* ]]
  [ ! -f "$NOTES_CALLER_PWD/notes/beta.md" ]
  [ -f "$NOTES_CALLER_PWD/.git/info/notes-stale-readable/beta.md" ]
  [[ "$(cat "$NOTES_CALLER_PWD/.git/info/notes-stale-readable/beta.md")" == *"local edit"* ]]
  ! grep -q "notes/beta.md" "$NOTES_CALLER_PWD/.git/info/exclude"

  run notes changes --summary
  [ "$status" -eq 0 ]
  [[ "$output" == *"No changes."* ]]
}

@test "deobfuscate reconciles stale old path when manifest renames a note" {
  record_deobfuscation_state_for_manifest
  local beta_id
  beta_id=$(rename_manifest_entry_in_head "beta.md" "renamed-beta.md")
  git -C "$NOTES_CALLER_PWD" update-index --no-assume-unchanged "notes/$beta_id" 2>/dev/null || true
  git -C "$NOTES_CALLER_PWD" checkout -- "notes/$beta_id"

  run notes deobfuscate
  [ "$status" -eq 0 ]
  [[ "$output" == *"removed stale readable: beta.md"* ]]
  [ ! -f "$NOTES_CALLER_PWD/notes/beta.md" ]
  [ -f "$NOTES_CALLER_PWD/notes/renamed-beta.md" ]
  [[ "$(cat "$NOTES_CALLER_PWD/notes/renamed-beta.md")" == *"# Beta"* ]]
  ! grep -q "notes/beta.md" "$NOTES_CALLER_PWD/.git/info/exclude"
  grep -q "notes/renamed-beta.md" "$NOTES_CALLER_PWD/.git/info/exclude"

  run notes changes --summary
  [ "$status" -eq 0 ]
  [[ "$output" == *"No changes."* ]]
}

@test "notes stage: path-limited stage does not leak unselected new manifest entry through pre-commit hook" {
  source "$REPO_DIR/lib/hooks.sh"
  install_obfuscation_hook
  install_deobfuscation_hook

  echo "# Gamma" > "$NOTES_CALLER_PWD/notes/gamma.md"
  printf 'cccccccc\tgamma.md\n' >> "$MANIFEST"
  echo "# Alpha modified" > "$NOTES_CALLER_PWD/notes/alpha.md"

  run notes stage alpha.md
  [ "$status" -eq 0 ]
  [[ "$output" == *"staged: alpha.md"* ]]
  [[ "$output" != *"gamma.md"* ]]

  git -C "$NOTES_CALLER_PWD" commit -q -m "update alpha"

  run git -C "$NOTES_CALLER_PWD" cat-file --filters HEAD:notes/.manifest
  [[ "$output" == *"alpha.md"* ]]
  [[ "$output" != *"gamma.md"* ]]

  run git -C "$NOTES_CALLER_PWD" show --name-only --format= HEAD
  [[ "$output" != *"gamma"* ]]
}

# ── commit wrapper ───────────────────────────────────────────

@test "notes commit: explicit file commits modified note and leaves clean readable tree" {
  notes install-hooks

  echo "# Alpha v2" > "$NOTES_CALLER_PWD/notes/alpha.md"

  run notes commit -m "update alpha" alpha.md
  [ "$status" -eq 0 ]
  [[ "$output" == *"Committed note changes"* ]]
  [[ "$output" == *"Notes changes: clean"* ]]

  [ "$(git -C "$NOTES_CALLER_PWD" log -1 --format=%s)" = "update alpha" ]
  [ -f "$NOTES_CALLER_PWD/notes/alpha.md" ]
  [[ "$(cat "$NOTES_CALLER_PWD/notes/alpha.md")" == *"Alpha v2"* ]]

  local committed_files
  committed_files=$(git -C "$NOTES_CALLER_PWD" show --name-only --format='' HEAD -- notes/)
  ! echo "$committed_files" | grep -q "alpha.md"

  run detect_changes "$NOTES_CALLER_PWD/notes"
  [ -z "$output" ]

  run git -C "$NOTES_CALLER_PWD" diff --cached --name-only
  [ -z "$output" ]

  run git -C "$NOTES_CALLER_PWD" ls-files notes/alpha.md
  [ -z "$output" ]
}

@test "notes commit --all commits modified new and deleted notes" {
  notes install-hooks

  echo "# Alpha v2" > "$NOTES_CALLER_PWD/notes/alpha.md"
  echo "# Gamma" > "$NOTES_CALLER_PWD/notes/gamma.md"
  rm "$NOTES_CALLER_PWD/notes/beta.md"

  run notes commit --all -m "update all notes"
  [ "$status" -eq 0 ]
  [[ "$output" == *"staged: alpha.md"* ]]
  [[ "$output" == *"staged: gamma.md"* ]]
  [[ "$output" == *"staged (delete): beta.md"* ]]
  [[ "$output" == *"Notes changes: clean"* ]]

  [ -f "$NOTES_CALLER_PWD/notes/alpha.md" ]
  [ -f "$NOTES_CALLER_PWD/notes/gamma.md" ]
  [ ! -f "$NOTES_CALLER_PWD/notes/beta.md" ]
  ! grep -q "beta.md" "$MANIFEST"
  grep -q "gamma.md" "$MANIFEST"

  run detect_changes "$NOTES_CALLER_PWD/notes"
  [ -z "$output" ]
}

@test "notes commit: path-limited commit leaves unrelated dirty notes uncommitted" {
  notes install-hooks

  local alpha_id beta_id
  alpha_id=$(manifest_id_for_name "$MANIFEST" "alpha.md")
  beta_id=$(manifest_id_for_name "$MANIFEST" "beta.md")

  echo "# Alpha v2" > "$NOTES_CALLER_PWD/notes/alpha.md"
  echo "# Beta v2" > "$NOTES_CALLER_PWD/notes/beta.md"

  run notes commit -m "update alpha only" alpha.md
  [ "$status" -eq 0 ]
  [[ "$output" == *"Remaining note changes"* ]]
  [[ "$output" == *"modified: beta.md"* ]]
  [[ "$output" != *"modified: alpha.md"* ]]

  git -C "$NOTES_CALLER_PWD" cat-file --filters "HEAD:notes/$alpha_id" | grep -q "Alpha v2"
  git -C "$NOTES_CALLER_PWD" cat-file --filters "HEAD:notes/$beta_id" | grep -q "# Beta"
  ! git -C "$NOTES_CALLER_PWD" cat-file --filters "HEAD:notes/$beta_id" | grep -q "Beta v2"

  run detect_changes "$NOTES_CALLER_PWD/notes"
  [[ "$output" == *"modified"*"beta.md"* ]]
  [[ "$output" != *"alpha.md"* ]]
}

@test "notes commit --dry-run shows staged plan without staging or committing" {
  local before
  before=$(git -C "$NOTES_CALLER_PWD" rev-parse HEAD)
  echo "# Alpha v2" > "$NOTES_CALLER_PWD/notes/alpha.md"

  run notes commit --dry-run -m "update alpha" alpha.md
  [ "$status" -eq 0 ]
  [[ "$output" == *"Would stage:"* ]]
  [[ "$output" == *"alpha.md"* ]]
  [[ "$output" == *"Would commit with message: update alpha"* ]]
  [ "$(git -C "$NOTES_CALLER_PWD" rev-parse HEAD)" = "$before" ]

  run git -C "$NOTES_CALLER_PWD" diff --cached --name-only
  [ -z "$output" ]
}

@test "notes commit: no args requires explicit scope" {
  notes install-hooks
  local before
  before=$(git -C "$NOTES_CALLER_PWD" rev-parse HEAD)
  echo "# Alpha v2" > "$NOTES_CALLER_PWD/notes/alpha.md"

  run notes commit -m "missing scope"
  [ "$status" -ne 0 ]
  [[ "$output" == *"provide note paths or --all"* ]]
  [ "$(git -C "$NOTES_CALLER_PWD" rev-parse HEAD)" = "$before" ]

  run git -C "$NOTES_CALLER_PWD" diff --cached --name-only
  [ -z "$output" ]
}

@test "notes commit: explicit unknown path fails instead of silently committing nothing" {
  notes install-hooks
  local before
  before=$(git -C "$NOTES_CALLER_PWD" rev-parse HEAD)
  echo "# Alpha v2" > "$NOTES_CALLER_PWD/notes/alpha.md"

  run notes commit -m "typo" alhpa.md
  [ "$status" -ne 0 ]
  [[ "$output" == *"requested note path"* ]]
  [[ "$output" == *"alhpa.md"* ]]
  [ "$(git -C "$NOTES_CALLER_PWD" rev-parse HEAD)" = "$before" ]

  run git -C "$NOTES_CALLER_PWD" diff --cached --name-only
  [ -z "$output" ]
}

@test "notes commit: path traversal argument fails instead of silently committing nothing" {
  notes install-hooks
  local before
  before=$(git -C "$NOTES_CALLER_PWD" rev-parse HEAD)
  echo "# Alpha v2" > "$NOTES_CALLER_PWD/notes/alpha.md"
  echo "readme" > "$NOTES_CALLER_PWD/README.md"

  run notes commit -m "traversal" ../README.md
  [ "$status" -ne 0 ]
  [[ "$output" == *"requested note path"* ]]
  [[ "$output" == *"../README.md"* ]]
  [ "$(git -C "$NOTES_CALLER_PWD" rev-parse HEAD)" = "$before" ]

  run git -C "$NOTES_CALLER_PWD" diff --cached --name-only
  [ -z "$output" ]
}

@test "notes commit: refuses pre-staged changes before staging notes" {
  notes install-hooks
  local before
  before=$(git -C "$NOTES_CALLER_PWD" rev-parse HEAD)
  echo "readme" > "$NOTES_CALLER_PWD/README.md"
  git -C "$NOTES_CALLER_PWD" add README.md
  echo "# Alpha v2" > "$NOTES_CALLER_PWD/notes/alpha.md"

  run notes commit --all -m "should refuse"
  [ "$status" -ne 0 ]
  [[ "$output" == *"staged changes already exist"* ]]
  [[ "$output" == *"README.md"* ]]
  [ "$(git -C "$NOTES_CALLER_PWD" rev-parse HEAD)" = "$before" ]

  run git -C "$NOTES_CALLER_PWD" diff --cached --name-only
  [ "$output" = "README.md" ]
}

@test "notes commit: detects non-note paths added by another pre-commit hook" {
  notes install-hooks
  mkdir -p "$NOTES_CALLER_PWD/.git/hooks/pre-commit.d"
  cat > "$NOTES_CALLER_PWD/.git/hooks/pre-commit.d/zz-stage-generated" <<'HOOK'
#!/usr/bin/env bash
set -euo pipefail
printf 'generated by hook\n' > hook-generated.txt
git add hook-generated.txt
HOOK
  chmod +x "$NOTES_CALLER_PWD/.git/hooks/pre-commit.d/zz-stage-generated"
  echo "# Alpha v2" > "$NOTES_CALLER_PWD/notes/alpha.md"

  run notes commit -m "update alpha" alpha.md
  [ "$status" -ne 0 ]
  [[ "$output" == *"included non-note path"* ]]
  [[ "$output" == *"hook-generated.txt"* ]]

  run git -C "$NOTES_CALLER_PWD" show --name-only --format= HEAD
  [[ "$output" == *"hook-generated.txt"* ]]
}

@test "notes commit: refuses missing hooks before staging or committing" {
  local before
  before=$(git -C "$NOTES_CALLER_PWD" rev-parse HEAD)
  echo "# Alpha v2" > "$NOTES_CALLER_PWD/notes/alpha.md"

  run notes commit -m "update alpha" alpha.md
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires installed obfuscation/deobfuscation hooks"* ]]
  [[ "$output" == *"notes install-hooks"* ]]
  [ "$(git -C "$NOTES_CALLER_PWD" rev-parse HEAD)" = "$before" ]

  run git -C "$NOTES_CALLER_PWD" diff --cached --name-only
  [ -z "$output" ]
}

# ── full lifecycle ────────────────────────────────────────────

@test "full cycle: edit → stage → commit → clean status" {
  # Install hooks so post-commit deobfuscates
  source "$REPO_DIR/lib/hooks.sh"
  install_obfuscation_hook
  install_deobfuscation_hook

  # Verify clean status before edit
  run git -C "$NOTES_CALLER_PWD" status --porcelain
  [ -z "$output" ]

  # Edit a note
  echo "# Alpha v2" > "$NOTES_CALLER_PWD/notes/alpha.md"

  # git status should still be clean (exclude hides the change)
  run git -C "$NOTES_CALLER_PWD" status --porcelain
  [ -z "$output" ]

  # But detect_changes should see it
  run detect_changes "$NOTES_CALLER_PWD/notes"
  [[ "$output" == *"modified"*"alpha.md"* ]]

  # Stage via notes stage
  notes stage alpha.md

  # Commit — hooks handle obfuscation + deobfuscation
  git -C "$NOTES_CALLER_PWD" commit -q -m "update alpha"

  # After commit, files should be deobfuscated
  [ -f "$NOTES_CALLER_PWD/notes/alpha.md" ]
  [[ "$(cat "$NOTES_CALLER_PWD/notes/alpha.md")" == *"Alpha v2"* ]]

  # Status should be clean again
  run git -C "$NOTES_CALLER_PWD" status --porcelain
  [ -z "$output" ]

  # No changes detected
  run detect_changes "$NOTES_CALLER_PWD/notes"
  [ -z "$output" ]
}
