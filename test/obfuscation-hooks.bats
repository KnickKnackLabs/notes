#!/usr/bin/env bats

load test_helper

setup() {
  export NOTES_CALLER_PWD="$BATS_TEST_TMPDIR"
  mkdir -p "$NOTES_CALLER_PWD/notes"

  # Create test notes
  echo -e "---\ntitle: Alpha\ntags: [test]\n---\n# Alpha" > "$NOTES_CALLER_PWD/notes/alpha.md"
  echo -e "---\ntitle: Beta\ntags: [test]\n---\n# Beta" > "$NOTES_CALLER_PWD/notes/beta.md"
  echo -e "---\ntitle: Gamma\ntags: [test]\n---\n# Gamma" > "$NOTES_CALLER_PWD/notes/gamma.txt"

  # git init and commit so git mv works
  git -C "$NOTES_CALLER_PWD" init -q
  git -C "$NOTES_CALLER_PWD" add -A
  git -C "$NOTES_CALLER_PWD" commit -q -m "init"
}

# Obfuscation hook installation and commit-cycle behavior

@test "install-hooks no-ops for uninitialized plain notes directories" {
  run notes install-hooks --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"No notes manifest found"* ]]
  [[ "$output" == *"notes setup --yes"* ]]

  [ ! -e "$NOTES_CALLER_PWD/.gitattributes" ]
  [ ! -e "$NOTES_CALLER_PWD/.git/hooks/pre-commit" ]
  [ ! -d "$NOTES_CALLER_PWD/.git/hooks/pre-commit.d" ]
  [ -z "$(git -C "$NOTES_CALLER_PWD" config --get merge.manifest.driver || true)" ]
}


@test "install-hooks refuses without confirmation in headless context" {
  notes obfuscate

  run without_confirmation "$BATS_TEST_TMPDIR/missing-tty" notes install-hooks

  [ "$status" -eq 2 ]
  [[ "$output" == *"confirmation required"* ]]
  [[ "$output" == *"Re-run with --yes"* ]]

  # Hooks should not be installed
  [ ! -x "$NOTES_CALLER_PWD/.git/hooks/pre-commit" ]
  [ ! -d "$NOTES_CALLER_PWD/.git/hooks/pre-commit.d" ]
}


@test "install-hooks --yes proceeds with hook installation" {
  notes obfuscate

  run notes install-hooks --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"Installed hooks"* ]]

  # Verify hooks were actually installed
  [ -x "$NOTES_CALLER_PWD/.git/hooks/pre-commit" ]
  grep -q "Generic hook dispatcher" "$NOTES_CALLER_PWD/.git/hooks/pre-commit"
}


@test "install-hooks installs pre-commit hooks" {
  notes obfuscate
  notes install-hooks --yes

  [ -x "$NOTES_CALLER_PWD/.git/hooks/pre-commit" ]
  grep -q "Generic hook dispatcher" "$NOTES_CALLER_PWD/.git/hooks/pre-commit"
  [ -x "$NOTES_CALLER_PWD/.git/hooks/pre-commit.d/encryption" ]
  grep -q "git-crypt status" "$NOTES_CALLER_PWD/.git/hooks/pre-commit.d/encryption"
  [ -x "$NOTES_CALLER_PWD/.git/hooks/pre-commit.d/obfuscation" ]
  grep -q "manifest" "$NOTES_CALLER_PWD/.git/hooks/pre-commit.d/obfuscation"
}


@test "encryption pre-commit hook rejects plaintext staged encrypted blobs" {
  if ! command -v git-crypt >/dev/null; then
    skip "git-crypt not installed"
  fi

  ( cd "$NOTES_CALLER_PWD" && git-crypt init >/dev/null 2>&1 ) || skip "git-crypt init failed"
  echo "notes/** filter=git-crypt diff=git-crypt" > "$NOTES_CALLER_PWD/.gitattributes"
  git -C "$NOTES_CALLER_PWD" add .gitattributes
  git -C "$NOTES_CALLER_PWD" commit -q --no-verify -m "enable encryption"

  notes install-hooks --yes

  local blob
  blob=$(printf 'aaa00001\talpha.md\n' | git -C "$NOTES_CALLER_PWD" hash-object -w --stdin)
  git -C "$NOTES_CALLER_PWD" update-index --add --cacheinfo 100644 "$blob" notes/.manifest

  run git -C "$NOTES_CALLER_PWD" commit -m "force plaintext manifest"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Staged files should be encrypted but are plaintext"* ]]
  [[ "$output" == *"notes/.manifest"* ]]
}


@test "dispatcher runs all hooks in pre-commit.d" {
  # Set up dispatcher with two hooks — one passes, one would fail
  mkdir -p "$NOTES_CALLER_PWD/.git/hooks/pre-commit.d"
  cat > "$NOTES_CALLER_PWD/.git/hooks/pre-commit" <<'EOF'
#!/usr/bin/env bash
set -eo pipefail
HOOK_DIR="$(dirname "$0")/pre-commit.d"
for hook in "$HOOK_DIR"/*; do
  [ -x "$hook" ] && "$hook" || exit $?
done
EOF
  chmod +x "$NOTES_CALLER_PWD/.git/hooks/pre-commit"

  # Hook that passes
  echo '#!/usr/bin/env bash' > "$NOTES_CALLER_PWD/.git/hooks/pre-commit.d/pass"
  echo 'exit 0' >> "$NOTES_CALLER_PWD/.git/hooks/pre-commit.d/pass"
  chmod +x "$NOTES_CALLER_PWD/.git/hooks/pre-commit.d/pass"

  # Hook that fails
  echo '#!/usr/bin/env bash' > "$NOTES_CALLER_PWD/.git/hooks/pre-commit.d/fail"
  echo 'echo "blocked" >&2; exit 1' >> "$NOTES_CALLER_PWD/.git/hooks/pre-commit.d/fail"
  chmod +x "$NOTES_CALLER_PWD/.git/hooks/pre-commit.d/fail"

  echo "test" > "$NOTES_CALLER_PWD/notes/test-file.md"
  git -C "$NOTES_CALLER_PWD" add notes/test-file.md

  run git -C "$NOTES_CALLER_PWD" commit -m "should fail"
  [ "$status" -ne 0 ]
  [[ "$output" == *"blocked"* ]]
}


@test "pre-commit hook rejects un-obfuscated files in guard mode" {
  notes setup --yes
  git -C "$NOTES_CALLER_PWD" add -A
  git -C "$NOTES_CALLER_PWD" commit --no-verify -q -m "setup"

  notes obfuscate
  git -C "$NOTES_CALLER_PWD" add -A
  git -C "$NOTES_CALLER_PWD" commit --no-verify -q -m "obfuscated"

  echo -e "---\ntitle: Sneaky\n---\n# Sneaky" > "$NOTES_CALLER_PWD/notes/sneaky.md"
  git -C "$NOTES_CALLER_PWD" add notes/sneaky.md

  NOTES_OBFUSCATE_HOOK=guard run git -C "$NOTES_CALLER_PWD" commit -m "should fail"
  [ "$status" -ne 0 ]
  [[ "$output" == *"non-obfuscated filenames"* ]]
  [[ "$output" == *"sneaky.md"* ]]
}


@test "pre-commit hook allows obfuscated files" {
  notes setup --yes
  git -C "$NOTES_CALLER_PWD" add -A
  git -C "$NOTES_CALLER_PWD" commit --no-verify -q -m "setup"

  notes obfuscate
  git -C "$NOTES_CALLER_PWD" add -A

  run git -C "$NOTES_CALLER_PWD" commit -m "should succeed"
  [ "$status" -eq 0 ]
}


@test "pre-commit hook rejects staged renames in guard mode" {
  notes setup --yes
  git -C "$NOTES_CALLER_PWD" add -A
  git -C "$NOTES_CALLER_PWD" commit --no-verify -q -m "setup"

  notes obfuscate
  git -C "$NOTES_CALLER_PWD" add -A
  git -C "$NOTES_CALLER_PWD" commit --no-verify -q -m "obfuscated"

  # After committing the obfuscated state, the post-commit hook
  # deobfuscates the working tree and adds readable names to
  # .git/info/exclude (clean-status mechanism from notes#43). A plain
  # `git add notes/` now no-ops. To simulate someone trying to stage a
  # deobfuscated rename anyway, we force-add the readable name.
  git -C "$NOTES_CALLER_PWD" add -f notes/alpha.md

  # The hook should reject this in guard mode
  NOTES_OBFUSCATE_HOOK=guard run git -C "$NOTES_CALLER_PWD" commit -m "should fail"
  [ "$status" -ne 0 ]
  [[ "$output" == *"non-obfuscated filenames"* ]]
  [[ "$output" == *"alpha.md"* ]]
}


@test "pre-commit hook auto-obfuscates by default" {
  # Obfuscate and commit the obfuscated state
  notes obfuscate
  git -C "$NOTES_CALLER_PWD" add -A
  git -C "$NOTES_CALLER_PWD" commit -q --no-verify -m "obfuscated"

  # Deobfuscate + install hooks explicitly
  notes deobfuscate
  notes install-hooks --yes

  # Add a new deobfuscated file + stage everything
  echo -e "---\ntitle: Sneaky\n---\n# Sneaky" > "$NOTES_CALLER_PWD/notes/sneaky.md"
  git -C "$NOTES_CALLER_PWD" add -A

  # Should succeed — hook auto-obfuscates before commit
  run git -C "$NOTES_CALLER_PWD" commit -m "should succeed"
  [ "$status" -eq 0 ]

  # The committed tree should have obfuscated filenames
  # (post-commit hook deobfuscates the working tree, so check git not disk)
  local committed_files
  committed_files=$(git -C "$NOTES_CALLER_PWD" show --name-only --format='' HEAD -- notes/)
  ! echo "$committed_files" | grep -q "alpha.md"
  ! echo "$committed_files" | grep -q "sneaky.md"

  # Manifest should have all entries
  grep -q "sneaky.md" "$NOTES_CALLER_PWD/notes/.manifest"
  grep -q "alpha.md" "$NOTES_CALLER_PWD/notes/.manifest"
}


@test "installed hooks run notes from installer, not PATH" {
  notes obfuscate
  git -C "$NOTES_CALLER_PWD" add -A
  git -C "$NOTES_CALLER_PWD" commit -q --no-verify -m "obfuscated"

  notes deobfuscate
  notes install-hooks --yes
  git -C "$NOTES_CALLER_PWD" add .gitattributes
  git -C "$NOTES_CALLER_PWD" commit -q --no-verify -m "install hook attributes"

  local fake_bin
  fake_bin="$BATS_TEST_TMPDIR/fake-bin"
  mkdir -p "$fake_bin"
  cat > "$fake_bin/notes" <<'EOT'
#!/usr/bin/env bash
echo "fake notes invoked: $*" >&2
exit 99
EOT
  chmod +x "$fake_bin/notes"

  echo "change" >> "$NOTES_CALLER_PWD/notes/alpha.md"
  git -C "$NOTES_CALLER_PWD" add -f notes/alpha.md

  run bash -c 'unset -f notes; PATH="$1:$PATH" git -C "$2" commit -m "edit alpha"' _ "$fake_bin" "$NOTES_CALLER_PWD"
  [ "$status" -eq 0 ]
  [[ "$output" != *"fake notes invoked"* ]]
}


@test "install-hooks installs post-commit deobfuscation hook" {
  notes obfuscate
  notes install-hooks --yes

  [ -x "$NOTES_CALLER_PWD/.git/hooks/post-commit" ]
  grep -q "Generic hook dispatcher" "$NOTES_CALLER_PWD/.git/hooks/post-commit"
  [ -x "$NOTES_CALLER_PWD/.git/hooks/post-commit.d/deobfuscation" ]
  grep -q "manifest" "$NOTES_CALLER_PWD/.git/hooks/post-commit.d/deobfuscation"
}


@test "post-commit hook deobfuscates working tree after commit" {
  # Obfuscate and commit initial state
  notes obfuscate
  git -C "$NOTES_CALLER_PWD" add -A
  git -C "$NOTES_CALLER_PWD" commit -q --no-verify -m "obfuscated"

  # Deobfuscate + install hooks explicitly
  notes deobfuscate
  notes install-hooks --yes

  # Add a new file and commit — hooks should handle the round-trip
  echo -e "---\ntitle: New Note\n---\n# New" > "$NOTES_CALLER_PWD/notes/new-note.md"
  git -C "$NOTES_CALLER_PWD" add notes/new-note.md
  git -C "$NOTES_CALLER_PWD" commit -m "add new note"

  # Working tree should have readable filenames (post-commit deobfuscated)
  [ -f "$NOTES_CALLER_PWD/notes/alpha.md" ]
  [ -f "$NOTES_CALLER_PWD/notes/beta.md" ]
  [ -f "$NOTES_CALLER_PWD/notes/gamma.txt" ]
  [ -f "$NOTES_CALLER_PWD/notes/new-note.md" ]

  # Committed tree should have obfuscated filenames
  local committed_files
  committed_files=$(git -C "$NOTES_CALLER_PWD" show --name-only --format='' HEAD -- notes/)
  ! echo "$committed_files" | grep -q "alpha.md"
  ! echo "$committed_files" | grep -q "new-note.md"
}


@test "post-commit hook preserves file content after round-trip" {
  notes obfuscate
  git -C "$NOTES_CALLER_PWD" add -A
  git -C "$NOTES_CALLER_PWD" commit -q --no-verify -m "obfuscated"

  notes deobfuscate
  notes install-hooks --yes

  echo -e "---\ntitle: Fresh\n---\n# Fresh content" > "$NOTES_CALLER_PWD/notes/fresh.md"
  git -C "$NOTES_CALLER_PWD" add notes/fresh.md
  git -C "$NOTES_CALLER_PWD" commit -m "add fresh"

  # Content should survive the obfuscate→deobfuscate round-trip
  [[ "$(cat "$NOTES_CALLER_PWD/notes/alpha.md")" == *"# Alpha"* ]]
  [[ "$(cat "$NOTES_CALLER_PWD/notes/fresh.md")" == *"# Fresh content"* ]]
}


@test "post-commit hook is no-op when files are not obfuscated" {
  # Install hooks — no manifest exists, so hooks should be no-ops
  notes install-hooks --yes

  # Commit should succeed even though post-commit hook exists
  echo "change" >> "$NOTES_CALLER_PWD/notes/alpha.md"
  git -C "$NOTES_CALLER_PWD" add -A
  run git -C "$NOTES_CALLER_PWD" commit -m "should work fine"
  [ "$status" -eq 0 ]
}


@test "pre-commit hook allows commits when no manifest exists" {
  notes setup --yes
  git -C "$NOTES_CALLER_PWD" add -A
  git -C "$NOTES_CALLER_PWD" commit -q -m "setup"

  echo -e "---\ntitle: Normal\n---" > "$NOTES_CALLER_PWD/notes/normal.md"
  git -C "$NOTES_CALLER_PWD" add notes/normal.md

  run git -C "$NOTES_CALLER_PWD" commit -m "should succeed"
  [ "$status" -eq 0 ]
}


@test "full commit cycle: deobfuscated working tree stays clean" {
  # Set up obfuscated repo with hooks
  notes obfuscate
  git -C "$NOTES_CALLER_PWD" add -A
  git -C "$NOTES_CALLER_PWD" commit -q --no-verify -m "obfuscated"
  notes deobfuscate
  notes install-hooks --yes

  # Edit a file and commit via hooks
  echo "edited" >> "$NOTES_CALLER_PWD/notes/alpha.md"
  notes stage alpha.md
  run git -C "$NOTES_CALLER_PWD" commit -m "edit alpha"
  [ "$status" -eq 0 ]

  # Committed tree should have obfuscated names
  local committed_files
  committed_files=$(git -C "$NOTES_CALLER_PWD" show --name-only --format='' HEAD -- notes/)
  ! echo "$committed_files" | grep -q "alpha.md"

  # Working tree should have readable names (post-commit deobfuscated)
  [ -f "$NOTES_CALLER_PWD/notes/alpha.md" ]
  [[ "$(cat "$NOTES_CALLER_PWD/notes/alpha.md")" == *"edited"* ]]

  # Index should be clean
  local staged
  staged=$(git -C "$NOTES_CALLER_PWD" diff --cached --name-status)
  [ -z "$staged" ]
}


@test "post-commit hook preserves valid manifest order during scoped obfuscation" {
  notes obfuscate

  local alpha_id beta_id gamma_id
  alpha_id=$(grep $'\talpha\.md$' "$NOTES_CALLER_PWD/notes/.manifest" | cut -f1)
  beta_id=$(grep $'\tbeta\.md$' "$NOTES_CALLER_PWD/notes/.manifest" | cut -f1)
  gamma_id=$(grep $'\tgamma\.txt$' "$NOTES_CALLER_PWD/notes/.manifest" | cut -f1)

  # Simulate a historical valid manifest whose order differs from the current
  # name sort. Scoped pre-commit obfuscation should not create an order-only
  # dirty worktree by normalizing unrelated manifest order.
  printf '%s\tgamma.txt\n%s\talpha.md\n%s\tbeta.md\n' \
    "$gamma_id" "$alpha_id" "$beta_id" > "$NOTES_CALLER_PWD/notes/.manifest"
  git -C "$NOTES_CALLER_PWD" add -A
  git -C "$NOTES_CALLER_PWD" commit -q --no-verify -m "obfuscated unsorted manifest"

  notes deobfuscate
  notes install-hooks --yes
  git -C "$NOTES_CALLER_PWD" add .gitattributes
  git -C "$NOTES_CALLER_PWD" commit -q --no-verify -m "install hook attributes"
  [ -z "$(git -C "$NOTES_CALLER_PWD" status --short)" ]

  echo "edited" >> "$NOTES_CALLER_PWD/notes/alpha.md"
  notes stage alpha.md
  run git -C "$NOTES_CALLER_PWD" commit -m "edit alpha"
  [ "$status" -eq 0 ]

  [ -z "$(git -C "$NOTES_CALLER_PWD" status --short)" ]
}


@test "install-hooks installs post-merge deobfuscation hook" {
  notes obfuscate
  notes install-hooks --yes

  [ -x "$NOTES_CALLER_PWD/.git/hooks/post-merge" ]
  grep -q "Generic hook dispatcher" "$NOTES_CALLER_PWD/.git/hooks/post-merge"
  [ -x "$NOTES_CALLER_PWD/.git/hooks/post-merge.d/deobfuscation" ]
  grep -q "manifest" "$NOTES_CALLER_PWD/.git/hooks/post-merge.d/deobfuscation"
  grep -q "NOTES_DEOBFUSCATE_BASE_REF=ORIG_HEAD" "$NOTES_CALLER_PWD/.git/hooks/post-merge.d/deobfuscation"
}


@test "pre-commit hook only obfuscates staged files" {
  # Set up: obfuscate, commit, then deobfuscate + install hooks
  notes obfuscate
  git -C "$NOTES_CALLER_PWD" add -A
  git -C "$NOTES_CALLER_PWD" commit -q --no-verify -m "obfuscated"
  notes deobfuscate
  notes install-hooks --yes
  # Working tree: readable names. Index: obfuscated names matching HEAD.

  # Edit one file, stage only that one
  echo "change" >> "$NOTES_CALLER_PWD/notes/alpha.md"
  git -C "$NOTES_CALLER_PWD" add -f notes/alpha.md

  # Capture stderr from commit (hooks print rename operations there)
  local stderr_log="$BATS_TEST_TMPDIR/commit-stderr"
  git -C "$NOTES_CALLER_PWD" commit -m "edit one file" 2>"$stderr_log"

  cat "$stderr_log" >&2

  # Count how many files the pre-commit hook obfuscated
  local obfuscated_count
  obfuscated_count=$(sed -n 's/.*Auto-obfuscating \([0-9]*\) file.*/\1/p' "$stderr_log")
  echo "auto-obfuscated: ${obfuscated_count:-none}" >&2

  # Should obfuscate exactly 1 file (the staged one)
  [ -n "$obfuscated_count" ]
  [ "$obfuscated_count" -eq 1 ]
}
