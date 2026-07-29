#!/usr/bin/env bats

# Change detection tests.

load test_helper
load changes_test_helper

setup_failing_find_overlay() {
  FAILING_FIND_BIN="$BATS_TEST_TMPDIR/failing-find-bin"
  mkdir -p "$FAILING_FIND_BIN"
  cat > "$FAILING_FIND_BIN/find" <<'SH'
#!/usr/bin/env bash
exit 73
SH
  chmod +x "$FAILING_FIND_BIN/find"
}

setup_failing_tracked_path_inspection_overlay() {
  FAILING_GIT_BIN="$BATS_TEST_TMPDIR/failing-git-bin"
  local real_git
  real_git=$(command -v git)
  mkdir -p "$FAILING_GIT_BIN"
  cat > "$FAILING_GIT_BIN/git" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" ls-files -z -- notes ") exit 73 ;;
esac
exec "$REAL_GIT" "$@"
SH
  chmod +x "$FAILING_GIT_BIN/git"
  export REAL_GIT="$real_git"
}

setup_failing_content_comparison_overlay() {
  FAILING_CMP_BIN="$BATS_TEST_TMPDIR/failing-cmp-bin"
  mkdir -p "$FAILING_CMP_BIN"
  cat > "$FAILING_CMP_BIN/cmp" <<'SH'
#!/usr/bin/env bash
echo "content comparison failed" >&2
exit 73
SH
  chmod +x "$FAILING_CMP_BIN/cmp"
}

# ── detect_changes ────────────────────────────────────────────

@test "notes changes refuses locked encrypted content before classifying paths" {
  printf 'notes/** filter=git-crypt diff=git-crypt\n' > "$NOTES_CALLER_PWD/.gitattributes"
  printf '\0GITCRYPT\0encrypted manifest bytes\n' > "$MANIFEST"
  printf '\0GITCRYPT\0encrypted note bytes\n' > "$NOTES_CALLER_PWD/notes/aaaaaaaa"

  run notes changes --summary
  [ "$status" -ne 0 ]
  [[ "$output" == *"git-crypt is locked"* ]]
  [[ "$output" == *"notes unlock"* ]]
  [[ "$output" != *"aaaaaaaa"* ]]

  # A keyless clone can report initialized=false even though the encrypted
  # manifest is present and unreadable.
  run notes changes
  [ "$status" -ne 0 ]
  [[ "$output" == *"git-crypt is locked"* ]]
  [[ "$output" != *"aaaaaaaa"* ]]
}

@test "notes changes preserves clean output when encryption is unlocked" {
  printf 'notes/** filter=git-crypt diff=git-crypt\n' > "$NOTES_CALLER_PWD/.gitattributes"

  run notes changes --summary

  [ "$status" -eq 0 ]
  [ "$output" = "No changes." ]
}

@test "detect_changes: no changes when files match HEAD" {
  run detect_changes "$NOTES_CALLER_PWD/notes"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "detect_changes: missing manifest remains a clean result" {
  rm -f "$NOTES_CALLER_PWD/notes/.manifest"

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

@test "notes changes propagates diff execution failures" {
  echo "# Alpha modified" > "$NOTES_CALLER_PWD/notes/alpha.md"

  local mock_bin="$BATS_TEST_TMPDIR/mock-diff-bin"
  mkdir -p "$mock_bin"
  cat > "$mock_bin/diff" <<'SH'
#!/usr/bin/env bash
exit 73
SH
  chmod +x "$mock_bin/diff"

  PATH="$mock_bin:$PATH" run notes changes

  [ "$status" -eq 73 ]
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

@test "detect_changes: handles many notes without per-note membership processes" {
  local delete_id
  add_clean_numbered_notes 40

  printf '# Note 10 edited\n' > "$NOTES_CALLER_PWD/notes/note-10.md"
  printf '# New\n' > "$NOTES_CALLER_PWD/notes/new.md"
  rm "$NOTES_CALLER_PWD/notes/note-20.md"
  delete_id=$(manifest_id_for_name "$MANIFEST" "note-20.md")
  rm -f "$NOTES_CALLER_PWD/notes/$delete_id"
  setup_membership_process_counters

  run run_with_process_counters detect_changes "$NOTES_CALLER_PWD/notes"
  [ "$status" -eq 0 ]
  [[ "$output" == *"modified"*"note-10.md"* ]]
  [[ "$output" == *"deleted"*"note-20.md"* ]]
  [[ "$output" == *"new"*"new.md"* ]]
  [[ "$output" != *"note-30.md"* ]]
  [ ! -e "$NOTES_PROCESS_COUNTER_DIR/grep.calls" ]
  [ ! -e "$NOTES_PROCESS_COUNTER_DIR/basename.calls" ]
}

@test "detect_stale_readable_notes: current notes do not launch membership processes" {
  add_clean_numbered_notes 40
  setup_membership_process_counters

  run run_with_process_counters detect_stale_readable_notes "$NOTES_CALLER_PWD/notes"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$NOTES_PROCESS_COUNTER_DIR/grep.calls" ]
  [ ! -e "$NOTES_PROCESS_COUNTER_DIR/basename.calls" ]
}

@test "detect_changes: trusted raw baselines avoid per-note clean filters" {
  local delete_id state
  add_clean_numbered_notes 40
  setup_clean_filter_counter
  record_deobfuscation_state_for_manifest

  state="$NOTES_CALLER_PWD/.git/info/notes-obfuscation-state"
  awk -F '\t' 'NF != 4 { exit 1 }' "$state"
  rm -f "$CLEAN_FILTER_CALLS"

  printf '# Note 10 edited\n' > "$NOTES_CALLER_PWD/notes/note-10.md"
  delete_id=$(manifest_id_for_name "$MANIFEST" "note-20.md")
  rm "$NOTES_CALLER_PWD/notes/note-20.md"
  rm -f "$NOTES_CALLER_PWD/notes/$delete_id"

  run detect_changes "$NOTES_CALLER_PWD/notes"
  [ "$status" -eq 0 ]
  [[ "$output" == *"modified"*"note-10.md"* ]]
  [[ "$output" == *"deleted"*"note-20.md"* ]]
  [ "$(clean_filter_call_count)" -eq 0 ]
}

@test "detect_changes: stale raw baseline safely falls back then refreshes" {
  local alpha_id
  setup_clean_filter_counter
  record_deobfuscation_state_for_manifest
  alpha_id=$(manifest_id_for_name "$MANIFEST" "alpha.md")

  clear_status_suppression "$NOTES_CALLER_PWD/notes"
  rename_to_obfuscated "$NOTES_CALLER_PWD/notes" > /dev/null
  printf '# Alpha upstream\n' > "$NOTES_CALLER_PWD/notes/$alpha_id"
  git -C "$NOTES_CALLER_PWD" add -f "notes/$alpha_id"
  git -C "$NOTES_CALLER_PWD" commit -q -m "update alpha upstream"
  rename_to_readable "$NOTES_CALLER_PWD/notes" > /dev/null
  rm -f "$CLEAN_FILTER_CALLS"

  run detect_changes "$NOTES_CALLER_PWD/notes"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(clean_filter_call_count)" -eq 1 ]

  record_deobfuscation_state_for_manifest
  rm -f "$CLEAN_FILTER_CALLS"
  run detect_changes "$NOTES_CALLER_PWD/notes"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(clean_filter_call_count)" -eq 0 ]
}

@test "detect_changes: staged baseline still compares against old HEAD" {
  local alpha_id
  setup_clean_filter_counter
  record_deobfuscation_state_for_manifest
  alpha_id=$(manifest_id_for_name "$MANIFEST" "alpha.md")

  clear_status_suppression "$NOTES_CALLER_PWD/notes"
  rename_to_obfuscated "$NOTES_CALLER_PWD/notes" > /dev/null
  printf '# Alpha staged\n' > "$NOTES_CALLER_PWD/notes/$alpha_id"
  git -C "$NOTES_CALLER_PWD" add -f "notes/$alpha_id"
  rename_to_readable "$NOTES_CALLER_PWD/notes" > /dev/null
  record_deobfuscation_state_for_manifest
  rm -f "$CLEAN_FILTER_CALLS"

  run detect_changes "$NOTES_CALLER_PWD/notes"
  [ "$status" -eq 0 ]
  [[ "$output" == *"modified"*"alpha.md"* ]]
  [ "$(clean_filter_call_count)" -eq 1 ]
}

@test "detect_changes: legacy state safely falls back to clean filters" {
  local state
  setup_clean_filter_counter
  record_deobfuscation_state_for_manifest
  state="$NOTES_CALLER_PWD/.git/info/notes-obfuscation-state"
  cut -f1-3 "$state" > "$state.legacy"
  mv "$state.legacy" "$state"
  rm -f "$CLEAN_FILTER_CALLS"

  run detect_changes "$NOTES_CALLER_PWD/notes"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(clean_filter_call_count)" -eq 2 ]
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

@test "detect_changes fails atomically when corpus enumeration fails" {
  echo "# Alpha modified" > "$NOTES_CALLER_PWD/notes/alpha.md"
  setup_failing_find_overlay

  PATH="$FAILING_FIND_BIN:$PATH" run detect_changes "$NOTES_CALLER_PWD/notes"

  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "working-tree commands propagate change detection failure" {
  setup_failing_find_overlay

  PATH="$FAILING_FIND_BIN:$PATH" run notes changes --summary
  [ "$status" -ne 0 ]
  [[ "$output" == *"failed to inspect note changes"* ]]

  PATH="$FAILING_FIND_BIN:$PATH" run notes diff
  [ "$status" -ne 0 ]
  [[ "$output" == *"failed to inspect note changes"* ]]

  PATH="$FAILING_FIND_BIN:$PATH" run notes stage alpha.md
  [ "$status" -ne 0 ]
  [[ "$output" == *"failed to inspect note changes"* ]]

  PATH="$FAILING_FIND_BIN:$PATH" run notes status --json
  [ "$status" -ne 0 ]
  [[ "$output" == *"failed to inspect note changes"* ]]
}

@test "safety consumers propagate double-tracked path inspection failure" {
  setup_failing_tracked_path_inspection_overlay
  printf '# Alpha modified\n' > "$NOTES_CALLER_PWD/notes/alpha.md"

  PATH="$FAILING_GIT_BIN:$PATH" run notes stage alpha.md
  [ "$status" -ne 0 ]
  [[ "$output" == *"failed to inspect double-tracked note paths"* ]]
  run git -C "$NOTES_CALLER_PWD" diff --cached --name-only
  [ -z "$output" ]

  PATH="$FAILING_GIT_BIN:$PATH" run notes status --json
  [ "$status" -ne 0 ]
  [[ "$output" == *"failed to inspect double-tracked note paths"* ]]
}

@test "safety consumers propagate dual-present content inspection failure" {
  local alpha_id
  alpha_id=$(manifest_id_for_name "$MANIFEST" "alpha.md")
  cp "$NOTES_CALLER_PWD/notes/alpha.md" "$NOTES_CALLER_PWD/notes/$alpha_id"
  printf '# Alpha modified\n' > "$NOTES_CALLER_PWD/notes/alpha.md"
  setup_failing_content_comparison_overlay

  PATH="$FAILING_CMP_BIN:$PATH" run notes stage alpha.md
  [ "$status" -eq 73 ]
  [[ "$output" == *"failed to inspect dual-present note paths"* ]]
  run git -C "$NOTES_CALLER_PWD" diff --cached --name-only
  [ -z "$output" ]

  PATH="$FAILING_CMP_BIN:$PATH" run notes status --json
  [ "$status" -eq 73 ]
  [[ "$output" == *"failed to inspect dual-present note paths"* ]]
}

@test "notes changes fails instead of widening an unparsed file scope" {
  local mock_bin="$BATS_TEST_TMPDIR/failing-xargs-bin"
  make_failing_xargs_overlay "$mock_bin"

  PATH="$mock_bin:$PATH" run notes changes alpha.md

  [ "$status" -eq 73 ]
  [[ "$output" == *"failed to parse variadic arguments"* ]]
}
