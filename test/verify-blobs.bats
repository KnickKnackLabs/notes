#!/usr/bin/env bats

# Tests for verify-blobs: verify committed encrypted note blobs in a ref.
#
# git-crypt magic format: \x00 G I T C R Y P T \x00 (10 bytes total)
# Tests simulate encrypted blobs with printf '\x00GITCRYPT\x00'.
# We use the default setup from test_helper (git repo at NOTES_CALLER_PWD).

load test_helper

setup_failing_ref_tree_enumeration_overlay() {
  FAILING_GIT_BIN="$BATS_TEST_TMPDIR/failing-ref-tree-git"
  local real_git
  real_git=$(command -v git)
  mkdir -p "$FAILING_GIT_BIN"
  cat > "$FAILING_GIT_BIN/git" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" ls-tree -r -z --name-only HEAD -- notes/ ")
    echo "ref tree enumeration failed" >&2
    exit 73
    ;;
esac
exec "$REAL_GIT" "$@"
SH
  chmod +x "$FAILING_GIT_BIN/git"
  export REAL_GIT="$real_git"
}

@test "verify-blobs: all encrypted blobs pass" {
  mkdir -p "$NOTES_CALLER_PWD/notes"
  printf '\x00GITCRYPT\x00aaa00001\talpha.md\n' > "$NOTES_CALLER_PWD/notes/.manifest"
  printf '\x00GITCRYPT\x00encrypted alpha content' > "$NOTES_CALLER_PWD/notes/aaa00001"
  git -C "$NOTES_CALLER_PWD" add -A
  git -C "$NOTES_CALLER_PWD" commit -q -m "all encrypted"

  run notes verify-blobs
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "OK"
}

@test "verify-blobs: fails when ref tree enumeration fails" {
  mkdir -p "$NOTES_CALLER_PWD/notes"
  printf '\x00GITCRYPT\x00aaa00001\talpha.md\n' > "$NOTES_CALLER_PWD/notes/.manifest"
  printf '\x00GITCRYPT\x00encrypted alpha content' > "$NOTES_CALLER_PWD/notes/aaa00001"
  git -C "$NOTES_CALLER_PWD" add -A
  git -C "$NOTES_CALLER_PWD" commit -q -m "all encrypted"
  setup_failing_ref_tree_enumeration_overlay

  PATH="$FAILING_GIT_BIN:$PATH" run notes verify-blobs

  [ "$status" -eq 73 ]
  [[ "$output" == *"failed to enumerate note blobs"* ]]
}

@test "verify-blobs: large encrypted blob passes" {
  mkdir -p "$NOTES_CALLER_PWD/notes"
  printf '\x00GITCRYPT\x00aaa00001\talpha.md\n' > "$NOTES_CALLER_PWD/notes/.manifest"
  printf '\x00GITCRYPT\x00' > "$NOTES_CALLER_PWD/notes/aaa00001"
  dd if=/dev/zero bs=1024 count=128 2>/dev/null >> "$NOTES_CALLER_PWD/notes/aaa00001"
  git -C "$NOTES_CALLER_PWD" add -A
  git -C "$NOTES_CALLER_PWD" commit -q -m "large encrypted blob"

  run notes verify-blobs
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "OK"
}

@test "verify-blobs: plaintext manifest fails" {
  mkdir -p "$NOTES_CALLER_PWD/notes"
  echo -e "aaa00001\talpha.md" > "$NOTES_CALLER_PWD/notes/.manifest"
  printf '\x00GITCRYPT\x00encrypted alpha' > "$NOTES_CALLER_PWD/notes/aaa00001"
  git -C "$NOTES_CALLER_PWD" add -A
  git -C "$NOTES_CALLER_PWD" commit -q -m "plaintext manifest"

  run notes verify-blobs
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "not encrypted"
  echo "$output" | grep -q ".manifest"
}

@test "verify-blobs: false magic string without exact header fails" {
  mkdir -p "$NOTES_CALLER_PWD/notes"
  printf 'xxGITCRYPTaaa00001\talpha.md\n' > "$NOTES_CALLER_PWD/notes/.manifest"
  printf 'xxGITCRYPTplaintext-ish alpha' > "$NOTES_CALLER_PWD/notes/aaa00001"
  git -C "$NOTES_CALLER_PWD" add -A
  git -C "$NOTES_CALLER_PWD" commit -q -m "false magic"

  run notes verify-blobs
  [ "$status" -eq 1 ]
  echo "$output" | grep -q ".manifest"
  echo "$output" | grep -q "aaa00001"
}

@test "verify-blobs: mixed encryption fails and names plaintext path" {
  mkdir -p "$NOTES_CALLER_PWD/notes"
  printf '\x00GITCRYPT\x00aaa00001\talpha.md\nbbb00002\tbeta.md\n' \
    > "$NOTES_CALLER_PWD/notes/.manifest"
  printf '\x00GITCRYPT\x00encrypted alpha' > "$NOTES_CALLER_PWD/notes/aaa00001"
  echo "PLAINTEXT beta content" > "$NOTES_CALLER_PWD/notes/bbb00002"
  git -C "$NOTES_CALLER_PWD" add -A
  git -C "$NOTES_CALLER_PWD" commit -q -m "mixed encryption"

  run notes verify-blobs
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "bbb00002"
  echo "$output" | grep -q "not encrypted"
}

@test "verify-blobs: tracked readable note fails" {
  mkdir -p "$NOTES_CALLER_PWD/notes"
  printf '\x00GITCRYPT\x00aaa00001\talpha.md\n' > "$NOTES_CALLER_PWD/notes/.manifest"
  printf '\x00GITCRYPT\x00encrypted alpha' > "$NOTES_CALLER_PWD/notes/aaa00001"
  echo "readable note" > "$NOTES_CALLER_PWD/notes/status.md"
  git -C "$NOTES_CALLER_PWD" add -A
  git -C "$NOTES_CALLER_PWD" commit -q -m "tracked readable"

  run notes verify-blobs
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "tracked readable note"
  echo "$output" | grep -q "status.md"
}

@test "verify-blobs: works against a ref without checkout" {
  mkdir -p "$NOTES_CALLER_PWD/notes"
  printf '\x00GITCRYPT\x00aaa00001\talpha.md\n' > "$NOTES_CALLER_PWD/notes/.manifest"
  printf '\x00GITCRYPT\x00encrypted alpha' > "$NOTES_CALLER_PWD/notes/aaa00001"
  git -C "$NOTES_CALLER_PWD" add -A
  git -C "$NOTES_CALLER_PWD" commit -q -m "base"

  # Save the clean state as a branch ref
  git -C "$NOTES_CALLER_PWD" branch before-plaintext

  # Now add a plaintext blob on top (rewinding later)
  printf '\x00GITCRYPT\x00bbb00002\tbeta.md\n' >> "$NOTES_CALLER_PWD/notes/.manifest"
  printf '\x00GITCRYPT\x00encrypted' > "$NOTES_CALLER_PWD/notes/bbb00002"
  echo "PLAINTEXT" > "$NOTES_CALLER_PWD/notes/ccc00003"
  git -C "$NOTES_CALLER_PWD" add -A
  git -C "$NOTES_CALLER_PWD" commit -q -m "plaintext added"
  git -C "$NOTES_CALLER_PWD" reset --hard HEAD~1 2>/dev/null

  # HEAD is clean but before-plaintext ref has an extra plaintext blob
  run notes verify-blobs --ref before-plaintext
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "OK"
}

@test "verify-blobs: nonexistent ref fails" {
  run notes verify-blobs --ref nonexistent
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "does not exist"
}

@test "verify-blobs: no notes directory fails" {
  echo "no notes here" > "$NOTES_CALLER_PWD/readme.md"
  git -C "$NOTES_CALLER_PWD" add -A
  git -C "$NOTES_CALLER_PWD" commit -q -m "no notes"

  run notes verify-blobs
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "not found"
}

# ── Edge: --dir flag works ──────────────────────────────────

@test "verify-blobs: --dir flag verifies custom notes path" {
  mkdir -p "$NOTES_CALLER_PWD/mynotes"
  printf '\x00GITCRYPT\x00c001\tnote.md\n' > "$NOTES_CALLER_PWD/mynotes/.manifest"
  printf '\x00GITCRYPT\x00encrypted' > "$NOTES_CALLER_PWD/mynotes/c001"
  git -C "$NOTES_CALLER_PWD" add -A
  git -C "$NOTES_CALLER_PWD" commit -q -m "custom dir"

  run notes verify-blobs --dir mynotes
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "OK"
}

@test "verify-blobs: --dir handles notes path with spaces" {
  mkdir -p "$NOTES_CALLER_PWD/my notes"
  printf '\x00GITCRYPT\x00c001\tnote.md\n' > "$NOTES_CALLER_PWD/my notes/.manifest"
  printf '\x00GITCRYPT\x00encrypted' > "$NOTES_CALLER_PWD/my notes/c001"
  git -C "$NOTES_CALLER_PWD" add -A
  git -C "$NOTES_CALLER_PWD" commit -q -m "space dir"

  run notes verify-blobs --dir "my notes"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "OK"
}

@test "verify-blobs: empty notes directory with no manifest fails" {
  mkdir -p "$NOTES_CALLER_PWD/notes"
  # An empty .manifest file has no git-crypt magic bytes
  touch "$NOTES_CALLER_PWD/notes/.manifest"
  git -C "$NOTES_CALLER_PWD" add -A
  git -C "$NOTES_CALLER_PWD" commit -q -m "empty notes"

  run notes verify-blobs
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "not encrypted"
}

@test "verify-blobs: checks notes in subdirectories" {
  mkdir -p "$NOTES_CALLER_PWD/notes/subdir"
  printf '\x00GITCRYPT\x00a001\troot.md\nb002\tsubdir/nested.md\n' \
    > "$NOTES_CALLER_PWD/notes/.manifest"
  printf '\x00GITCRYPT\x00encrypted root' > "$NOTES_CALLER_PWD/notes/a001"
  printf '\x00GITCRYPT\x00encrypted nested' > "$NOTES_CALLER_PWD/notes/b002"
  git -C "$NOTES_CALLER_PWD" add -A
  git -C "$NOTES_CALLER_PWD" commit -q -m "nested notes"

  run notes verify-blobs
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "OK"
}

@test "verify-blobs: detects unencrypted note in subdirectory" {
  mkdir -p "$NOTES_CALLER_PWD/notes/subdir"
  printf '\x00GITCRYPT\x00a001\troot.md\nb002\tsubdir/nested.md\n' \
    > "$NOTES_CALLER_PWD/notes/.manifest"
  printf '\x00GITCRYPT\x00encrypted root' > "$NOTES_CALLER_PWD/notes/a001"
  echo "PLAINTEXT nested" > "$NOTES_CALLER_PWD/notes/b002"
  git -C "$NOTES_CALLER_PWD" add -A
  git -C "$NOTES_CALLER_PWD" commit -q -m "nested plaintext"

  run notes verify-blobs
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "b002"
  echo "$output" | grep -q "not encrypted"
}

@test "verify-blobs: --strict fails on dirty working tree" {
  mkdir -p "$NOTES_CALLER_PWD/notes"
  # Commit encrypted blobs
  printf '\x00GITCRYPT\x00a001\tnote.md\n' > "$NOTES_CALLER_PWD/notes/.manifest"
  printf '\x00GITCRYPT\x00encrypted' > "$NOTES_CALLER_PWD/notes/a001"
  git -C "$NOTES_CALLER_PWD" add -A
  git -C "$NOTES_CALLER_PWD" commit -q -m "base"

  # Simulate unlocked state: replace manifest with readable version on disk
  echo -e "a001\tnote.md" > "$NOTES_CALLER_PWD/notes/.manifest"
  # Create a new file not in the manifest so notes changes detects it
  echo "untracked new file" > "$NOTES_CALLER_PWD/notes/untracked.md"

  run notes verify-blobs --strict
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "strict"
}

@test "verify-blobs: --strict checks custom notes dir" {
  mkdir -p "$NOTES_CALLER_PWD/mynotes"
  printf '\x00GITCRYPT\x00a001\tnote.md\n' > "$NOTES_CALLER_PWD/mynotes/.manifest"
  printf '\x00GITCRYPT\x00encrypted' > "$NOTES_CALLER_PWD/mynotes/a001"
  git -C "$NOTES_CALLER_PWD" add -A
  git -C "$NOTES_CALLER_PWD" commit -q -m "base"

  echo -e "a001\tnote.md" > "$NOTES_CALLER_PWD/mynotes/.manifest"
  echo "dirty custom note" > "$NOTES_CALLER_PWD/mynotes/dirty.md"

  run notes verify-blobs --dir mynotes --strict
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "dirty.md"
}

@test "verify-blobs: --strict passes on clean working tree" {
  mkdir -p "$NOTES_CALLER_PWD/notes"
  # Commit encrypted blobs
  printf '\x00GITCRYPT\x00a001\tnote.md\n' > "$NOTES_CALLER_PWD/notes/.manifest"
  printf '\x00GITCRYPT\x00encrypted' > "$NOTES_CALLER_PWD/notes/a001"
  git -C "$NOTES_CALLER_PWD" add -A
  git -C "$NOTES_CALLER_PWD" commit -q -m "base"

  # Simulate unlocked state: replace manifest with readable version on disk
  echo -e "a001\tnote.md" > "$NOTES_CALLER_PWD/notes/.manifest"
  # No extra files; working tree has the same tracked content as HEAD

  run notes verify-blobs --strict
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "OK"
}
