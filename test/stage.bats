#!/usr/bin/env bats

# Readable-note staging and stale-path reconciliation tests.

load test_helper
load changes_test_helper

setup() {
  setup_changes_fixture
  export TARGET_DIR="$NOTES_CALLER_PWD"
  install_encryption_hook
  install_obfuscation_hook
  install_double_tracking_hook
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

@test "notes stage refuses missing required hooks before index mutation" {
  rm -rf "$NOTES_CALLER_PWD/.git/hooks/pre-commit" \
    "$NOTES_CALLER_PWD/.git/hooks/pre-commit.d"
  echo "# Alpha modified" > "$NOTES_CALLER_PWD/notes/alpha.md"

  run notes stage alpha.md

  [ "$status" -ne 0 ]
  [[ "$output" == *"pre-commit hooks are missing or stale"* ]]
  [[ "$output" == *"notes install-hooks --yes"* ]]
  run git -C "$NOTES_CALLER_PWD" diff --cached --name-only
  [ -z "$output" ]
}

@test "notes stage refuses stale required hooks before index mutation" {
  printf '\n# stale\n' >> \
    "$NOTES_CALLER_PWD/.git/hooks/pre-commit.d/encryption"
  echo "# Alpha modified" > "$NOTES_CALLER_PWD/notes/alpha.md"

  run notes stage alpha.md

  [ "$status" -ne 0 ]
  [[ "$output" == *"pre-commit hooks are missing or stale"* ]]
  run git -C "$NOTES_CALLER_PWD" diff --cached --name-only
  [ -z "$output" ]
}

@test "notes stage refuses a dispatcher that does not run required fragments" {
  cat > "$NOTES_CALLER_PWD/.git/hooks/pre-commit" <<'HOOK'
#!/usr/bin/env bash
# Looks compatible by mentioning pre-commit.d, but executes nothing.
exit 0
HOOK
  chmod +x "$NOTES_CALLER_PWD/.git/hooks/pre-commit"
  echo "# Alpha modified" > "$NOTES_CALLER_PWD/notes/alpha.md"

  run notes stage alpha.md

  [ "$status" -ne 0 ]
  [[ "$output" == *"pre-commit hooks are missing or stale"* ]]
  run git -C "$NOTES_CALLER_PWD" diff --cached --name-only
  [ -z "$output" ]

  notes install-hooks --yes
  run notes stage alpha.md
  [ "$status" -eq 0 ]
  git -C "$NOTES_CALLER_PWD" commit -q -m "repaired dispatcher"
  run git -C "$NOTES_CALLER_PWD" show --name-only --format= HEAD
  [[ "$output" != *"notes/alpha.md"* ]]
}

@test "notes stage checks and repairs the active core.hooksPath" {
  git -C "$NOTES_CALLER_PWD" config core.hooksPath .active-hooks
  echo "# Alpha modified" > "$NOTES_CALLER_PWD/notes/alpha.md"

  run notes stage alpha.md

  [ "$status" -ne 0 ]
  [[ "$output" == *"pre-commit hooks are missing or stale"* ]]
  run git -C "$NOTES_CALLER_PWD" diff --cached --name-only
  [ -z "$output" ]

  notes install-hooks --yes
  [ -x "$NOTES_CALLER_PWD/.active-hooks/pre-commit" ]
  run notes stage alpha.md
  [ "$status" -eq 0 ]
  git -C "$NOTES_CALLER_PWD" commit -q -m "active hooks path"
  run git -C "$NOTES_CALLER_PWD" show --name-only --format= HEAD
  [[ "$output" != *"notes/alpha.md"* ]]
}

@test "notes stage dry-run remains available without required hooks" {
  rm -rf "$NOTES_CALLER_PWD/.git/hooks/pre-commit" \
    "$NOTES_CALLER_PWD/.git/hooks/pre-commit.d"
  echo "# Alpha modified" > "$NOTES_CALLER_PWD/notes/alpha.md"

  run notes stage alpha.md --dry-run

  [ "$status" -eq 0 ]
  [[ "$output" == *"Would stage:"* ]]
  run git -C "$NOTES_CALLER_PWD" diff --cached --name-only
  [ -z "$output" ]
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
