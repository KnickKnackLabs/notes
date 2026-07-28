#!/usr/bin/env bats

# Tests for readable artifacts from unresolved encrypted/obfuscated note conflicts.

load test_helper

setup() {
  export NOTES_CALLER_PWD="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$NOTES_CALLER_PWD/notes"
  git -C "$NOTES_CALLER_PWD" init -q
  git -C "$NOTES_CALLER_PWD" config user.name "Test"
  git -C "$NOTES_CALLER_PWD" config user.email "test@test.com"
}

commit_all() {
  local message="$1"
  git -C "$NOTES_CALLER_PWD" add -A
  git -C "$NOTES_CALLER_PWD" commit -q -m "$message"
}

create_conflicted_note_repo() {
  printf 'aaaaaaaa\talpha.md\n' > "$NOTES_CALLER_PWD/notes/.manifest"
  printf '# Alpha\nbase\n' > "$NOTES_CALLER_PWD/notes/aaaaaaaa"
  commit_all "base note"
  git -C "$NOTES_CALLER_PWD" branch -M main

  git -C "$NOTES_CALLER_PWD" checkout -q -b feature
  printf '# Alpha\nfeature\n' > "$NOTES_CALLER_PWD/notes/aaaaaaaa"
  commit_all "feature edit"

  git -C "$NOTES_CALLER_PWD" checkout -q main
  printf '# Alpha\nmain\n' > "$NOTES_CALLER_PWD/notes/aaaaaaaa"
  commit_all "main edit"

  run git -C "$NOTES_CALLER_PWD" merge feature
  [ "$status" -ne 0 ]
  [ "$(git -C "$NOTES_CALLER_PWD" ls-files -u -- notes/aaaaaaaa | wc -l | tr -d ' ')" -eq 3 ]
}

create_conflicted_gitcrypt_header_repo() {
  printf 'aaaaaaaa\talpha.md\n' > "$NOTES_CALLER_PWD/notes/.manifest"
  printf '\0GITCRYPT base\n' > "$NOTES_CALLER_PWD/notes/aaaaaaaa"
  commit_all "base encrypted-looking note"
  git -C "$NOTES_CALLER_PWD" branch -M main

  git -C "$NOTES_CALLER_PWD" checkout -q -b feature
  printf '\0GITCRYPT feature\n' > "$NOTES_CALLER_PWD/notes/aaaaaaaa"
  commit_all "feature encrypted-looking edit"

  git -C "$NOTES_CALLER_PWD" checkout -q main
  printf '\0GITCRYPT main\n' > "$NOTES_CALLER_PWD/notes/aaaaaaaa"
  commit_all "main encrypted-looking edit"

  run git -C "$NOTES_CALLER_PWD" merge feature
  [ "$status" -ne 0 ]
}

@test "notes conflicts writes readable base ours theirs artifacts" {
  create_conflicted_note_repo
  local out_dir="$BATS_TEST_TMPDIR/conflict-artifacts"

  run notes conflicts --out "$out_dir"

  [ "$status" -eq 0 ]
  [[ "$output" == *"Unmerged note content conflicts: 1"* ]]
  [[ "$output" == *"alpha.md (notes/aaaaaaaa)"* ]]
  [ -f "$out_dir/conflicts/alpha.md/base.md" ]
  [ -f "$out_dir/conflicts/alpha.md/ours.md" ]
  [ -f "$out_dir/conflicts/alpha.md/theirs.md" ]
  grep -q '^base$' "$out_dir/conflicts/alpha.md/base.md"
  grep -q '^main$' "$out_dir/conflicts/alpha.md/ours.md"
  grep -q '^feature$' "$out_dir/conflicts/alpha.md/theirs.md"
}

@test "notes conflicts leaves conflicted index and worktree unchanged" {
  create_conflicted_note_repo
  local out_dir="$BATS_TEST_TMPDIR/conflict-artifacts"
  local index_before worktree_before index_after worktree_after
  index_before=$(git -C "$NOTES_CALLER_PWD" ls-files -u)
  worktree_before=$(cat "$NOTES_CALLER_PWD/notes/aaaaaaaa")

  run notes conflicts --out "$out_dir"

  [ "$status" -eq 0 ]
  index_after=$(git -C "$NOTES_CALLER_PWD" ls-files -u)
  worktree_after=$(cat "$NOTES_CALLER_PWD/notes/aaaaaaaa")
  [ "$index_after" = "$index_before" ]
  [ "$worktree_after" = "$worktree_before" ]
}

@test "notes conflicts reports no note content conflicts" {
  printf 'aaaaaaaa\talpha.md\n' > "$NOTES_CALLER_PWD/notes/.manifest"
  printf '# Alpha\n' > "$NOTES_CALLER_PWD/notes/aaaaaaaa"
  commit_all "base note"
  local out_dir="$BATS_TEST_TMPDIR/no-conflicts-out"

  run notes conflicts --out "$out_dir"

  [ "$status" -eq 0 ]
  [[ "$output" == *"No note content conflicts."* ]]
  [ ! -e "$out_dir" ]
}

@test "notes conflicts refuses symlink output directory" {
  create_conflicted_note_repo
  local out_target="$BATS_TEST_TMPDIR/out-target"
  local out_link="$BATS_TEST_TMPDIR/out-link"
  mkdir -p "$out_target"
  ln -s "$out_target" "$out_link"

  run notes conflicts --out "$out_link"

  [ "$status" -ne 0 ]
  [[ "$output" == *"Error: --out path must not be a symlink"* ]]
  [ -z "$(find "$out_target" -mindepth 1 -print -quit)" ]
}

@test "notes conflicts refuses encrypted stages that filters did not decrypt" {
  create_conflicted_gitcrypt_header_repo
  local out_dir="$BATS_TEST_TMPDIR/locked-out"

  run notes conflicts --out "$out_dir"

  [ "$status" -ne 0 ]
  [[ "$output" == *"Error: git-crypt filters did not decrypt stage"* ]]
  [ ! -f "$out_dir/conflicts/alpha.md/base.md" ]
}

@test "notes conflicts refuses unsafe manifest paths" {
  printf 'aaaaaaaa\t../alpha.md\n' > "$NOTES_CALLER_PWD/notes/.manifest"
  printf '# Alpha\nbase\n' > "$NOTES_CALLER_PWD/notes/aaaaaaaa"
  commit_all "base unsafe path"
  git -C "$NOTES_CALLER_PWD" branch -M main

  git -C "$NOTES_CALLER_PWD" checkout -q -b feature
  printf '# Alpha\nfeature\n' > "$NOTES_CALLER_PWD/notes/aaaaaaaa"
  commit_all "feature unsafe path"

  git -C "$NOTES_CALLER_PWD" checkout -q main
  printf '# Alpha\nmain\n' > "$NOTES_CALLER_PWD/notes/aaaaaaaa"
  commit_all "main unsafe path"
  run git -C "$NOTES_CALLER_PWD" merge feature
  [ "$status" -ne 0 ]

  run notes conflicts --out "$BATS_TEST_TMPDIR/unsafe-out"

  [ "$status" -ne 0 ]
  [[ "$output" == *"Error: unsafe manifest path: ../alpha.md"* ]]
}

@test "notes conflicts refuses unmapped obfuscated conflict" {
  printf 'aaaaaaaa\talpha.md\n' > "$NOTES_CALLER_PWD/notes/.manifest"
  printf '# Orphan\nbase\n' > "$NOTES_CALLER_PWD/notes/bbbbbbbb"
  commit_all "base orphan"
  git -C "$NOTES_CALLER_PWD" branch -M main

  git -C "$NOTES_CALLER_PWD" checkout -q -b feature
  printf '# Orphan\nfeature\n' > "$NOTES_CALLER_PWD/notes/bbbbbbbb"
  commit_all "feature orphan"

  git -C "$NOTES_CALLER_PWD" checkout -q main
  printf '# Orphan\nmain\n' > "$NOTES_CALLER_PWD/notes/bbbbbbbb"
  commit_all "main orphan"
  run git -C "$NOTES_CALLER_PWD" merge feature
  [ "$status" -ne 0 ]

  local out_dir="$BATS_TEST_TMPDIR/unmapped-out"
  run notes conflicts --out "$out_dir"

  [ "$status" -ne 0 ]
  [[ "$output" == *"Error: missing manifest mapping for notes/bbbbbbbb"* ]]
  [ ! -e "$out_dir/conflicts" ]
}

@test "notes conflicts ignores manifest-only conflicts" {
  printf 'aaaaaaaa\talpha.md\n' > "$NOTES_CALLER_PWD/notes/.manifest"
  printf '# Alpha\n' > "$NOTES_CALLER_PWD/notes/aaaaaaaa"
  commit_all "base note"
  git -C "$NOTES_CALLER_PWD" branch -M main

  git -C "$NOTES_CALLER_PWD" checkout -q -b feature
  printf 'aaaaaaaa\talpha.md\nbbbbbbbb\tbeta.md\n' > "$NOTES_CALLER_PWD/notes/.manifest"
  commit_all "feature manifest edit"

  git -C "$NOTES_CALLER_PWD" checkout -q main
  printf 'aaaaaaaa\talpha.md\ncccccccc\tgamma.md\n' > "$NOTES_CALLER_PWD/notes/.manifest"
  commit_all "main manifest edit"
  run git -C "$NOTES_CALLER_PWD" merge feature
  [ "$status" -ne 0 ]

  run notes conflicts

  [ "$status" -eq 0 ]
  [[ "$output" == *"No note content conflicts."* ]]
}

@test "notes merge --dry-run delegates to readable conflict artifacts" {
  create_conflicted_note_repo
  local out_dir="$BATS_TEST_TMPDIR/merge-dry-run-artifacts"

  run notes merge --dry-run --out "$out_dir"

  [ "$status" -eq 0 ]
  [[ "$output" == *"Unmerged note content conflicts: 1"* ]]
  [ -f "$out_dir/conflicts/alpha.md/base.md" ]
  grep -q '^main$' "$out_dir/conflicts/alpha.md/ours.md"
  grep -q '^feature$' "$out_dir/conflicts/alpha.md/theirs.md"
}

@test "notes merge refuses apply mode for the first slice" {
  create_conflicted_note_repo

  run notes merge

  [ "$status" -ne 0 ]
  [[ "$output" == *"Error: notes merge currently only supports --dry-run."* ]]
}

@test "notes status reports unmerged note content conflicts" {
  create_conflicted_note_repo

  run notes status

  [ "$status" -eq 0 ]
  [[ "$output" == *"Unmerged note content conflicts: 1"* ]]
  [[ "$output" == *"alpha.md (notes/aaaaaaaa)"* ]]
  [[ "$output" == *"notes conflicts --out"* ]]
}

@test "notes status still reports conflicts with unsafe manifest mappings" {
  printf 'aaaaaaaa\t../alpha.md\n' > "$NOTES_CALLER_PWD/notes/.manifest"
  printf '# Alpha\nbase\n' > "$NOTES_CALLER_PWD/notes/aaaaaaaa"
  commit_all "base unsafe path"
  git -C "$NOTES_CALLER_PWD" branch -M main

  git -C "$NOTES_CALLER_PWD" checkout -q -b feature
  printf '# Alpha\nfeature\n' > "$NOTES_CALLER_PWD/notes/aaaaaaaa"
  commit_all "feature unsafe path"

  git -C "$NOTES_CALLER_PWD" checkout -q main
  printf '# Alpha\nmain\n' > "$NOTES_CALLER_PWD/notes/aaaaaaaa"
  commit_all "main unsafe path"
  run git -C "$NOTES_CALLER_PWD" merge feature
  [ "$status" -ne 0 ]

  run notes status

  [ "$status" -eq 0 ]
  [[ "$output" == *"Unmerged note content conflicts: 1"* ]]
  [[ "$output" == *"notes/aaaaaaaa (readable name unavailable)"* ]]
}

@test "notes status still reports conflicts with ambiguous manifest mappings" {
  printf 'aaaaaaaa\talpha.md\naaaaaaaa\tbeta.md\n' > "$NOTES_CALLER_PWD/notes/.manifest"
  printf '# Alpha\nbase\n' > "$NOTES_CALLER_PWD/notes/aaaaaaaa"
  commit_all "base ambiguous path"
  git -C "$NOTES_CALLER_PWD" branch -M main

  git -C "$NOTES_CALLER_PWD" checkout -q -b feature
  printf '# Alpha\nfeature\n' > "$NOTES_CALLER_PWD/notes/aaaaaaaa"
  commit_all "feature ambiguous path"

  git -C "$NOTES_CALLER_PWD" checkout -q main
  printf '# Alpha\nmain\n' > "$NOTES_CALLER_PWD/notes/aaaaaaaa"
  commit_all "main ambiguous path"
  run git -C "$NOTES_CALLER_PWD" merge feature
  [ "$status" -ne 0 ]

  run notes status --json

  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.unmerged_content_conflicts.conflicts == 1'
}

@test "notes status --json counts unmerged note content conflicts" {
  create_conflicted_note_repo

  run notes status --json

  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.unmerged_content_conflicts.conflicts == 1'
}

@test "conflict commands propagate unmerged-path inspection failure" {
  local mock_bin="$BATS_TEST_TMPDIR/failing-conflict-git-bin"
  local real_git
  real_git=$(command -v git)
  mkdir -p "$mock_bin"
  cat > "$mock_bin/git" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" ls-files -u "*)
    printf '%s\n' "unmerged path inspection failed" >&2
    exit 73
    ;;
esac
exec "$REAL_GIT" "$@"
SH
  chmod +x "$mock_bin/git"

  PATH="$mock_bin:$PATH" REAL_GIT="$real_git" \
    run notes conflicts --out "$BATS_TEST_TMPDIR/conflict-output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unmerged path inspection failed"* ]]

  PATH="$mock_bin:$PATH" REAL_GIT="$real_git" run notes status --json
  [ "$status" -ne 0 ]
  [[ "$output" == *"failed to inspect unmerged note conflicts"* ]]
}
