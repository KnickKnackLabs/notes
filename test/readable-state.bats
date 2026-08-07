#!/usr/bin/env bats

load test_helper
source "$REPO_DIR/lib/changes.sh"

setup() {
  export NOTES_CALLER_PWD="$BATS_TEST_TMPDIR/locked-repo"
  git -C "$BATS_TEST_TMPDIR" init -q -b main locked-repo
  git -C "$NOTES_CALLER_PWD" config user.name "Notes tests"
  git -C "$NOTES_CALLER_PWD" config user.email "notes-tests@example.invalid"
  git -C "$NOTES_CALLER_PWD" config filter.git-crypt.clean cat
  git -C "$NOTES_CALLER_PWD" config filter.git-crypt.smudge cat
  mkdir -p "$NOTES_CALLER_PWD/notes"
  printf 'notes/** filter=git-crypt diff=git-crypt\n' > "$NOTES_CALLER_PWD/.gitattributes"
  printf '\0GITCRYPT\0encrypted manifest bytes\n' > "$NOTES_CALLER_PWD/notes/.manifest"
  printf '\0GITCRYPT\0encrypted note bytes\n' > "$NOTES_CALLER_PWD/notes/aaaaaaaa"
  git -C "$NOTES_CALLER_PWD" add .gitattributes notes/.manifest notes/aaaaaaaa
  git -C "$NOTES_CALLER_PWD" commit -q -m "locked fixture"
}

assert_locked_failure() {
  [ "$status" -ne 0 ]
  [[ "$output" == *"git-crypt is locked"* ]]
  [[ "$output" == *"notes unlock"* ]]
  [[ "$output" != *"aaaaaaaa"* ]]
}

@test "readable-state classifies encrypted and plaintext managed manifests" {
  run "$REPO_DIR/lib/readable-state.sh" probe "$NOTES_CALLER_PWD/notes"
  [ "$status" -eq 0 ]
  [ "$output" = "locked" ]

  printf 'aaaaaaaa\talpha.md\n' > "$NOTES_CALLER_PWD/notes/.manifest"
  run "$REPO_DIR/lib/readable-state.sh" probe "$NOTES_CALLER_PWD/notes"
  [ "$status" -eq 0 ]
  [ "$output" = "readable" ]

  printf '\0GITCRYPT\0encrypted manifest bytes\n' > "$NOTES_CALLER_PWD/notes/.manifest"
  printf 'notes/** -filter\n' > "$NOTES_CALLER_PWD/.gitattributes"
  run "$REPO_DIR/lib/readable-state.sh" probe "$NOTES_CALLER_PWD/notes"
  [ "$status" -eq 0 ]
  [ "$output" = "readable" ]
}

@test "readable-state fails closed when an encrypted manifest cannot be inspected" {
  local failing_bin="$BATS_TEST_TMPDIR/failing-bin"
  mkdir -p "$failing_bin"
  cat > "$failing_bin/od" <<'SH'
#!/usr/bin/env bash
exit 73
SH
  chmod +x "$failing_bin/od"

  PATH="$failing_bin:$PATH" run "$REPO_DIR/lib/readable-state.sh" probe "$NOTES_CALLER_PWD/notes"
  [ "$status" -eq 2 ]
  [[ "$output" == *"failed to inspect encrypted manifest header"* ]]
}

@test "shared readable-state boundaries cannot be bypassed by direct consumers" {
  local plan="$BATS_TEST_TMPDIR/obfuscation-plan"

  run detect_changes "$NOTES_CALLER_PWD/notes"
  assert_locked_failure

  run build_obfuscation_plan "$NOTES_CALLER_PWD/notes" "$plan"
  assert_locked_failure
  [ ! -e "$plan" ]

  run rename_to_readable "$NOTES_CALLER_PWD/notes"
  assert_locked_failure

  run rebuild_status_suppression "$NOTES_CALLER_PWD/notes"
  assert_locked_failure
}

@test "read-only note consumers refuse locked content without exposing opaque paths" {
  while IFS= read -r invocation; do
    [ -n "$invocation" ] || continue
    # shellcheck disable=SC2086
    run notes $invocation
    assert_locked_failure
  done <<'EOF'
changes --summary
diff
list --json
search orientation --json
audit --json
show aaaaaaaa
parse notes/aaaaaaaa
conflicts
merge --dry-run
EOF
}

@test "mutating note consumers refuse locked content without changing index or worktree" {
  local before_status before_index invocation
  before_status=$(git -C "$NOTES_CALLER_PWD" status --porcelain=v1 -uall)
  before_index=$(git -C "$NOTES_CALLER_PWD" write-tree)

  while IFS= read -r invocation; do
    [ -n "$invocation" ] || continue
    # shellcheck disable=SC2086
    run notes $invocation
    assert_locked_failure
    [ "$(git -C "$NOTES_CALLER_PWD" status --porcelain=v1 -uall)" = "$before_status" ]
    [ "$(git -C "$NOTES_CALLER_PWD" write-tree)" = "$before_index" ]
  done <<'EOF'
stage --all
commit --all -m locked
new --slug locked --title Locked
obfuscate
deobfuscate
suppress-refresh
EOF

  [ ! -e "$NOTES_CALLER_PWD/notes/locked.md" ]
}

@test "pull remains available while locked and skips readable reconciliation" {
  local remote="$BATS_TEST_TMPDIR/remote.git"
  git init -q --bare "$remote"
  git -C "$NOTES_CALLER_PWD" remote add origin "$remote"
  git -C "$NOTES_CALLER_PWD" push -q -u origin main

  run notes pull

  [ "$status" -eq 0 ]
  [[ "$output" == *"Notes are locked; skipping readable manifest checks and reconciliation."* ]]
  [[ "$output" == *"Pull complete."* ]]
  [ -z "$(git -C "$NOTES_CALLER_PWD" status --porcelain=v1 -uall)" ]
}
