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

# Deobfuscation, dirty-readable safety, and suppression behavior

@test "deobfuscate restores original filenames" {
  notes obfuscate
  run notes deobfuscate
  [ "$status" -eq 0 ]
  [[ "$output" == *"Restored 3 file(s)"* ]]

  [ -f "$NOTES_CALLER_PWD/notes/alpha.md" ]
  [ -f "$NOTES_CALLER_PWD/notes/beta.md" ]
  [ -f "$NOTES_CALLER_PWD/notes/gamma.txt" ]
}


@test "full deobfuscation skips manifest lookup processes for absent IDs" {
  local i=1 id name restored_id="" counter_bin command real_command
  rm -rf "$NOTES_CALLER_PWD/notes"
  mkdir -p "$NOTES_CALLER_PWD/notes"

  while [ "$i" -le 42 ]; do
    id=$(printf '%08d' "$i")
    name=$(printf 'note-%02d.md' "$i")
    printf '%s\t%s\n' "$id" "$name" >> "$NOTES_CALLER_PWD/notes/.manifest"
    if [ "$i" -eq 17 ]; then
      restored_id="$id"
      printf '# Restored\n' > "$NOTES_CALLER_PWD/notes/$id"
    fi
    i=$((i + 1))
  done

  counter_bin="$BATS_TEST_TMPDIR/lookup-counter-bin"
  mkdir -p "$counter_bin"
  for command in grep cut; do
    real_command=$(command -v "$command")
    cat > "$counter_bin/$command" <<SH
#!/usr/bin/env bash
printf '1\\n' >> '$BATS_TEST_TMPDIR/$command.calls'
exec '$real_command' "\$@"
SH
    chmod +x "$counter_bin/$command"
  done

  PATH="$counter_bin:$PATH" run rename_to_readable "$NOTES_CALLER_PWD/notes"

  [ "$status" -eq 0 ]
  [[ "$output" == *"$restored_id"*$'\t'"note-17.md"* ]]
  [ -f "$NOTES_CALLER_PWD/notes/note-17.md" ]
  [ ! -e "$BATS_TEST_TMPDIR/grep.calls" ]
  [ ! -e "$BATS_TEST_TMPDIR/cut.calls" ]
}


@test "deobfuscate preserves manifest for stable IDs" {
  notes obfuscate
  notes deobfuscate

  [ -f "$NOTES_CALLER_PWD/notes/.manifest" ]
}


@test "deobfuscate recreates subdirectories" {
  mkdir -p "$NOTES_CALLER_PWD/notes/sub"
  echo -e "---\ntitle: Deep\n---\n# Deep" > "$NOTES_CALLER_PWD/notes/sub/deep.md"
  git -C "$NOTES_CALLER_PWD" add -A
  git -C "$NOTES_CALLER_PWD" commit -q -m "add subdir note"

  notes obfuscate
  [ ! -d "$NOTES_CALLER_PWD/notes/sub" ]

  notes deobfuscate
  [ -f "$NOTES_CALLER_PWD/notes/sub/deep.md" ]
  [[ "$(cat "$NOTES_CALLER_PWD/notes/sub/deep.md")" == *"# Deep"* ]]
}


@test "deobfuscate preserves file content" {
  notes obfuscate
  notes deobfuscate

  [[ "$(cat "$NOTES_CALLER_PWD/notes/alpha.md")" == *"# Alpha"* ]]
  [[ "$(cat "$NOTES_CALLER_PWD/notes/gamma.txt")" == *"# Gamma"* ]]
}


@test "deobfuscate fails without manifest" {
  run notes deobfuscate
  [ "$status" -ne 0 ]
  [[ "$output" == *"no manifest found"* ]]
}


@test "deobfuscate dry-run shows plan without renaming" {
  notes obfuscate
  id=$(grep "alpha.md" "$NOTES_CALLER_PWD/notes/.manifest" | cut -f1)

  run notes deobfuscate -- --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"alpha.md"* ]]

  [ -f "$NOTES_CALLER_PWD/notes/$id" ]
}


@test "deobfuscate ignores inherited usage_files without explicit IDs" {
  notes obfuscate
  local alpha_id beta_id gamma_id
  alpha_id=$(grep "alpha.md" "$NOTES_CALLER_PWD/notes/.manifest" | cut -f1)
  beta_id=$(grep "beta.md" "$NOTES_CALLER_PWD/notes/.manifest" | cut -f1)
  gamma_id=$(grep "gamma.txt" "$NOTES_CALLER_PWD/notes/.manifest" | cut -f1)

  usage_files="$alpha_id" run notes deobfuscate -- --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"$alpha_id → alpha.md"* ]]
  [[ "$output" == *"$beta_id → beta.md"* ]]
  [[ "$output" == *"$gamma_id → gamma.txt"* ]]
}


@test "round-trip preserves all content and metadata" {
  local alpha_before beta_before gamma_before
  alpha_before=$(git -C "$NOTES_CALLER_PWD" hash-object notes/alpha.md)
  beta_before=$(git -C "$NOTES_CALLER_PWD" hash-object notes/beta.md)
  gamma_before=$(git -C "$NOTES_CALLER_PWD" hash-object notes/gamma.txt)

  notes obfuscate
  notes deobfuscate

  [ "$(git -C "$NOTES_CALLER_PWD" hash-object notes/alpha.md)" = "$alpha_before" ]
  [ "$(git -C "$NOTES_CALLER_PWD" hash-object notes/beta.md)" = "$beta_before" ]
  [ "$(git -C "$NOTES_CALLER_PWD" hash-object notes/gamma.txt)" = "$gamma_before" ]
}


@test "deobfuscate does not install hooks" {
  notes obfuscate
  git -C "$NOTES_CALLER_PWD" add -A
  git -C "$NOTES_CALLER_PWD" commit -q --no-verify -m "obfuscate"

  notes deobfuscate

  [ ! -d "$NOTES_CALLER_PWD/.git/hooks/pre-commit.d" ]
}


@test "deobfuscate dry-run does not install hook" {
  notes obfuscate
  git -C "$NOTES_CALLER_PWD" add -A
  git -C "$NOTES_CALLER_PWD" commit -q --no-verify -m "obfuscate"

  notes deobfuscate -- --dry-run

  [ ! -d "$NOTES_CALLER_PWD/.git/hooks/pre-commit.d" ]
}


@test "deobfuscate restores names without staging" {
  notes obfuscate
  git -C "$NOTES_CALLER_PWD" add -A
  git -C "$NOTES_CALLER_PWD" commit -q --no-verify -m "obfuscated"

  notes deobfuscate

  # Working tree has readable names
  [ -f "$NOTES_CALLER_PWD/notes/alpha.md" ]
  [ -f "$NOTES_CALLER_PWD/notes/beta.md" ]

  # Index is clean (no staged changes)
  local staged
  staged=$(git -C "$NOTES_CALLER_PWD" diff --cached --name-status)
  [ -z "$staged" ]
}


@test "deobfuscate with args only processes specified IDs" {
  notes obfuscate

  local id_alpha
  id_alpha=$(grep 'alpha.md' "$NOTES_CALLER_PWD/notes/.manifest" | cut -f1)

  notes deobfuscate "$id_alpha"

  # alpha should be restored
  [ -f "$NOTES_CALLER_PWD/notes/alpha.md" ]

  # Others should remain obfuscated
  local id_beta
  id_beta=$(grep 'beta.md' "$NOTES_CALLER_PWD/notes/.manifest" | cut -f1)
  [ -f "$NOTES_CALLER_PWD/notes/$id_beta" ]
}


@test "scoped deobfuscate derives an ID without calling basename" {
  notes obfuscate

  local alpha_id mock_bin real_basename blocked_log
  alpha_id=$(grep 'alpha.md' "$NOTES_CALLER_PWD/notes/.manifest" | cut -f1)
  mock_bin="$BATS_TEST_TMPDIR/basename-guard-bin"
  blocked_log="$BATS_TEST_TMPDIR/basename-blocked"
  real_basename=$(command -v basename)
  mkdir -p "$mock_bin"
  cat > "$mock_bin/basename" <<'BASH'
#!/usr/bin/env bash
if [ "$#" -eq 1 ] && [ "$1" = "$BLOCKED_BASENAME_ARG" ]; then
  printf '%s\n' "$1" > "$BLOCKED_COMMAND_LOG"
  exit 97
fi
exec "$REAL_BASENAME" "$@"
BASH
  chmod +x "$mock_bin/basename"

  PATH="$mock_bin:$PATH" \
    BLOCKED_BASENAME_ARG="$alpha_id" \
    BLOCKED_COMMAND_LOG="$blocked_log" \
    REAL_BASENAME="$real_basename" \
    run notes deobfuscate "notes/$alpha_id"

  [ "$status" -eq 0 ]
  [ -f "$NOTES_CALLER_PWD/notes/alpha.md" ]
  [ ! -e "$blocked_log" ]
}


@test "scoped deobfuscate keeps a trailing-slash path scoped" {
  notes obfuscate

  local alpha_id beta_id
  alpha_id=$(grep 'alpha.md' "$NOTES_CALLER_PWD/notes/.manifest" | cut -f1)
  beta_id=$(grep 'beta.md' "$NOTES_CALLER_PWD/notes/.manifest" | cut -f1)

  notes deobfuscate "notes/$alpha_id/"

  [ -f "$NOTES_CALLER_PWD/notes/alpha.md" ]
  [ -f "$NOTES_CALLER_PWD/notes/$beta_id" ]
  [ ! -f "$NOTES_CALLER_PWD/notes/beta.md" ]
}


@test "deobfuscate with args warns on unknown ID" {
  notes obfuscate

  run notes deobfuscate nonexistent123
  [ "$status" -eq 0 ]
  [[ "$output" == *"Nothing to deobfuscate"* ]] || [[ "$output" == *"Warning: unknown"* ]]
}


@test "deobfuscate scoped sets assume-unchanged only on deobfuscated IDs" {
  notes obfuscate
  git -C "$NOTES_CALLER_PWD" add -A
  git -C "$NOTES_CALLER_PWD" commit -q --no-verify -m "obfuscated"

  local alpha_id beta_id
  alpha_id=$(grep "alpha.md" "$NOTES_CALLER_PWD/notes/.manifest" | cut -f1)
  beta_id=$(grep "beta.md" "$NOTES_CALLER_PWD/notes/.manifest" | cut -f1)

  # Deobfuscate only alpha
  notes deobfuscate "$alpha_id"

  # alpha's obfuscated ID should be assume-unchanged
  run git -C "$NOTES_CALLER_PWD" ls-files -v "notes/$alpha_id"
  [[ "$output" == h* ]]

  # beta's obfuscated ID should NOT be assume-unchanged (still tracked normally)
  run git -C "$NOTES_CALLER_PWD" ls-files -v "notes/$beta_id"
  [[ "$output" == H* ]]
}


@test "deobfuscate trusts existing readable when no state file (upgrade/fresh-clone path)" {
  # Regression: notes#59 finding 1. Before this fix, the first deobfuscate
  # after upgrading to the dirty-protection version would refuse every
  # readable that differs from its obfuscated source -- because no state
  # file existed yet, so every base_hash lookup returned empty, which the
  # check treated as dirty. That forced users straight to --force on first
  # run, training them to bypass the protection forever.
  notes obfuscate
  local alpha_id
  alpha_id=$(grep "alpha.md" "$NOTES_CALLER_PWD/notes/.manifest" | cut -f1)
  [ -f "$NOTES_CALLER_PWD/notes/$alpha_id" ]

  # Simulate a pre-fix clone: a stale readable on disk, no state file.
  echo "stale readable from before the upgrade" > "$NOTES_CALLER_PWD/notes/alpha.md"
  rm -f "$NOTES_CALLER_PWD/.git/info/notes-obfuscation-state"

  run notes deobfuscate
  [ "$status" -eq 0 ]
  # The readable was overwritten with the obfuscated content (the protection
  # is opt-in only after the state file exists; on the upgrade run we trust
  # the existing readable so users don't get force-prompted on every file).
  [[ "$(cat "$NOTES_CALLER_PWD/notes/alpha.md")" == *"# Alpha"* ]]
  # And the very next deobfuscate is now protected -- the state file got
  # written on this run.
  [ -f "$NOTES_CALLER_PWD/.git/info/notes-obfuscation-state" ]
  grep -q "^${alpha_id}"$'\t' "$NOTES_CALLER_PWD/.git/info/notes-obfuscation-state"
}


@test "deobfuscate refuses dirty readable note with recorded base hash" {
  notes obfuscate
  local alpha_id
  alpha_id=$(grep "alpha.md" "$NOTES_CALLER_PWD/notes/.manifest" | cut -f1)
  git -C "$NOTES_CALLER_PWD" add -A notes
  git -C "$NOTES_CALLER_PWD" commit -q -m "obfuscate"

  notes deobfuscate
  echo "local edit" >> "$NOTES_CALLER_PWD/notes/alpha.md"

  # Simulate unlock/pull restoring the obfuscated source while the readable
  # file still exists with local edits.
  git -C "$NOTES_CALLER_PWD" update-index --no-assume-unchanged "notes/$alpha_id" 2>/dev/null || true
  git -C "$NOTES_CALLER_PWD" checkout -- "notes/$alpha_id"

  run notes deobfuscate
  [ "$status" -ne 0 ]
  [[ "$output" == *"refusing to overwrite dirty readable note"* ]]
  [[ "$(cat "$NOTES_CALLER_PWD/notes/alpha.md")" == *"local edit"* ]]
  [ -f "$NOTES_CALLER_PWD/notes/$alpha_id" ]
}


@test "deobfuscate accepts clean readable when tracked and readable filters differ" {
  git -C "$NOTES_CALLER_PWD" config filter.prefix.clean "sed 's/^/clean:/'"
  git -C "$NOTES_CALLER_PWD" config filter.prefix.smudge cat
  printf 'notes/???????? filter=prefix\n' > "$NOTES_CALLER_PWD/.gitattributes"

  notes obfuscate
  local beta_id
  beta_id=$(grep "beta.md" "$NOTES_CALLER_PWD/notes/.manifest" | cut -f1)
  git -C "$NOTES_CALLER_PWD" add -A
  git -C "$NOTES_CALLER_PWD" commit -q -m "obfuscate with tracked-path filter"
  notes deobfuscate

  # Simulate checkout restoring the filtered obfuscated source while the clean
  # generated readable remains on disk.
  git -C "$NOTES_CALLER_PWD" update-index --no-assume-unchanged "notes/$beta_id"
  git -C "$NOTES_CALLER_PWD" checkout -- "notes/$beta_id"

  run notes deobfuscate
  [ "$status" -eq 0 ]
  [[ "$output" != *"refusing to overwrite dirty readable note"* ]]
  [[ "$(cat "$NOTES_CALLER_PWD/notes/beta.md")" == clean:* ]]
}


@test "deobfuscate refreshes clean stale readable when state row is missing but base ref matches" {
  notes obfuscate
  local alpha_id base_ref state
  alpha_id=$(grep "alpha.md" "$NOTES_CALLER_PWD/notes/.manifest" | cut -f1)
  git -C "$NOTES_CALLER_PWD" add -A notes
  git -C "$NOTES_CALLER_PWD" commit -q -m "obfuscate v1"
  base_ref=$(git -C "$NOTES_CALLER_PWD" rev-parse HEAD)

  notes deobfuscate
  state="$NOTES_CALLER_PWD/.git/info/notes-obfuscation-state"
  [ -f "$state" ]

  echo "# Alpha v2" > "$NOTES_CALLER_PWD/notes/alpha.md"
  notes obfuscate alpha.md
  git -C "$NOTES_CALLER_PWD" commit -q -m "obfuscate v2"

  # Simulate a partial/old state file after pull: alpha.md is still the clean
  # pre-merge readable, the new obfuscated source is present, but alpha's state
  # row is missing. ORIG_HEAD/base-ref should prove the readable is safe to
  # refresh instead of treating it as a local edit.
  git -C "$NOTES_CALLER_PWD" cat-file --filters "$base_ref:notes/$alpha_id" > "$NOTES_CALLER_PWD/notes/alpha.md"
  grep -v "^${alpha_id}"$'\t' "$state" > "$state.tmp"
  mv "$state.tmp" "$state"

  NOTES_DEOBFUSCATE_BASE_REF="$base_ref" run notes deobfuscate
  [ "$status" -eq 0 ]
  [[ "$(cat "$NOTES_CALLER_PWD/notes/alpha.md")" == *"# Alpha v2"* ]]
  [ ! -f "$NOTES_CALLER_PWD/notes/$alpha_id" ]
  grep -q "^${alpha_id}"$'\t' "$state"
}


@test "deobfuscate --force intentionally overwrites dirty readable note" {
  notes obfuscate
  local alpha_id
  alpha_id=$(grep "alpha.md" "$NOTES_CALLER_PWD/notes/.manifest" | cut -f1)
  [ -f "$NOTES_CALLER_PWD/notes/$alpha_id" ]

  echo "local edit" > "$NOTES_CALLER_PWD/notes/alpha.md"

  run notes deobfuscate -- --force
  [ "$status" -eq 0 ]

  [ -f "$NOTES_CALLER_PWD/notes/alpha.md" ]
  [[ "$(cat "$NOTES_CALLER_PWD/notes/alpha.md")" == *"# Alpha"* ]]
  [[ "$(cat "$NOTES_CALLER_PWD/notes/alpha.md")" != *"local edit"* ]]
}


@test "deobfuscate ignores inherited usage_force without explicit --force" {
  notes obfuscate
  local alpha_id
  alpha_id=$(grep "alpha.md" "$NOTES_CALLER_PWD/notes/.manifest" | cut -f1)
  git -C "$NOTES_CALLER_PWD" add -A notes
  git -C "$NOTES_CALLER_PWD" commit -q -m "obfuscate"

  notes deobfuscate
  echo "local edit" >> "$NOTES_CALLER_PWD/notes/alpha.md"
  git -C "$NOTES_CALLER_PWD" update-index --no-assume-unchanged "notes/$alpha_id" 2>/dev/null || true
  git -C "$NOTES_CALLER_PWD" checkout -- "notes/$alpha_id"

  usage_force=true run notes deobfuscate
  [ "$status" -ne 0 ]
  [[ "$output" == *"refusing to overwrite dirty readable note"* ]]
  [[ "$(cat "$NOTES_CALLER_PWD/notes/alpha.md")" == *"local edit"* ]]
}


@test "deobfuscate reports suppression index failures" {
  notes obfuscate
  git -C "$NOTES_CALLER_PWD" add -A notes
  git -C "$NOTES_CALLER_PWD" commit -q -m "obfuscate"

  local mock_bin="$BATS_TEST_TMPDIR/failing-index-bin"
  local real_git
  real_git=$(command -v git)
  mkdir -p "$mock_bin"
  cat > "$mock_bin/git" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GIT_MOCK_LOG"
for arg in "$@"; do
  if [ "$arg" = "update-index" ]; then
    exit 73
  fi
done
exec "$REAL_GIT" "$@"
SH
  chmod +x "$mock_bin/git"

  export PATH="$mock_bin:$PATH"
  export REAL_GIT="$real_git"
  export GIT_MOCK_LOG="$BATS_TEST_TMPDIR/git-mock.log"
  run notes deobfuscate

  grep -Fq "update-index" "$GIT_MOCK_LOG"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Warning: failed to rebuild status suppression"* ]]
}


@test "deobfuscate batches full suppression index updates" {
  notes obfuscate
  git -C "$NOTES_CALLER_PWD" add -A notes
  git -C "$NOTES_CALLER_PWD" commit -q -m "obfuscate"
  notes deobfuscate
  notes obfuscate

  local mock_bin="$BATS_TEST_TMPDIR/mock-bin"
  local count_file="$BATS_TEST_TMPDIR/update-index-count"
  local real_git
  real_git=$(command -v git)
  mkdir -p "$mock_bin"
  cat > "$mock_bin/git" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  if [ "$arg" = "update-index" ]; then
    printf '.\n' >> "$GIT_UPDATE_INDEX_COUNT"
    break
  fi
done
exec "$REAL_GIT" "$@"
SH
  chmod +x "$mock_bin/git"
  : > "$count_file"

  PATH="$mock_bin:$PATH" REAL_GIT="$real_git" GIT_UPDATE_INDEX_COUNT="$count_file" notes deobfuscate

  # One batch clears IDs recorded in state and one sets all manifest IDs.
  [ "$(wc -l < "$count_file" | tr -d ' ')" -eq 2 ]

  local id relpath
  while IFS=$'\t' read -r id relpath; do
    run git -C "$NOTES_CALLER_PWD" ls-files -v "notes/$id"
    [[ "$output" == h* ]]
  done < "$NOTES_CALLER_PWD/notes/.manifest"
}


@test "deobfuscate suppresses indexed IDs under a non-ASCII notes directory" {
  local notes_dir="nøtes"
  mv "$NOTES_CALLER_PWD/notes" "$NOTES_CALLER_PWD/$notes_dir"
  git -C "$NOTES_CALLER_PWD" add -A
  git -C "$NOTES_CALLER_PWD" commit -q -m "use non-ASCII notes directory"

  notes obfuscate --dir "$notes_dir"
  git -C "$NOTES_CALLER_PWD" commit -q -m "obfuscate custom directory"
  notes deobfuscate --dir "$notes_dir"

  local id relpath
  while IFS=$'\t' read -r id relpath; do
    run git -C "$NOTES_CALLER_PWD" ls-files -v "$notes_dir/$id"
    [[ "$output" == h* ]]
  done < "$NOTES_CALLER_PWD/$notes_dir/.manifest"
}


@test "deobfuscate clears stale indexed IDs when state also names missing IDs" {
  notes obfuscate
  git -C "$NOTES_CALLER_PWD" add -A notes
  git -C "$NOTES_CALLER_PWD" commit -q -m "obfuscate"
  notes deobfuscate

  local alpha_id state
  alpha_id=$(grep $'\talpha\.md$' "$NOTES_CALLER_PWD/notes/.manifest" | cut -f1)
  state="$NOTES_CALLER_PWD/.git/info/notes-obfuscation-state"

  # Simulate an upstream deletion plus an older state row whose ID is no
  # longer in the index. The stale alpha ID is still indexed and suppressed.
  grep -v "^${alpha_id}"$'\t' "$NOTES_CALLER_PWD/notes/.manifest" > "$NOTES_CALLER_PWD/notes/.manifest.tmp"
  mv "$NOTES_CALLER_PWD/notes/.manifest.tmp" "$NOTES_CALLER_PWD/notes/.manifest"
  printf 'deadbeef\tmissing.md\tmissing-hash\n' >> "$state"

  notes deobfuscate

  run git -C "$NOTES_CALLER_PWD" ls-files -v "notes/$alpha_id"
  [[ "$output" == H* ]]
  [ ! -f "$NOTES_CALLER_PWD/notes/alpha.md" ]
}


@test "deobfuscate allows identical readable note copy" {
  notes obfuscate
  local alpha_id
  alpha_id=$(grep "alpha.md" "$NOTES_CALLER_PWD/notes/.manifest" | cut -f1)
  [ -f "$NOTES_CALLER_PWD/notes/$alpha_id" ]

  cp "$NOTES_CALLER_PWD/notes/$alpha_id" "$NOTES_CALLER_PWD/notes/alpha.md"

  run notes deobfuscate
  [ "$status" -eq 0 ]
  [ -f "$NOTES_CALLER_PWD/notes/alpha.md" ]
  [[ "$(cat "$NOTES_CALLER_PWD/notes/alpha.md")" == *"# Alpha"* ]]
}


@test "deobfuscate records state for files renamed before mid-batch refusal" {
  # Regression: notes#59 finding 2. rename_to_readable aborts on the first
  # dirty file in a batch, but files renamed *before* that point are already
  # moved on disk. Pre-fix, the deobfuscate task exit'd on rc != 0 before
  # recording state, so those successfully-renamed files had no recorded base
  # hash -- and the next post-pull update of any of them would be refused
  # without --force, even though the user did nothing wrong.
  notes obfuscate
  local alpha_id beta_id
  alpha_id=$(grep "alpha.md" "$NOTES_CALLER_PWD/notes/.manifest" | cut -f1)
  beta_id=$(grep "beta.md"  "$NOTES_CALLER_PWD/notes/.manifest" | cut -f1)
  git -C "$NOTES_CALLER_PWD" add -A notes
  git -C "$NOTES_CALLER_PWD" commit -q -m "obfuscate"

  # Establish state-file invariant for both files.
  notes deobfuscate
  local state="$NOTES_CALLER_PWD/.git/info/notes-obfuscation-state"
  [ -f "$state" ]

  # Snapshot the count of rows for alpha_id BEFORE the partial-failure run.
  # Pre-fix the task exit'd before re-recording, so this count would not
  # change after the partial-failure run; post-fix it must increment.
  # (Asserting a row simply *exists* would not catch the regression -- the
  # row from this first deobfuscate is already present either way.)
  local alpha_rows_before
  alpha_rows_before=$(grep -c "^${alpha_id}"$'\t' "$state" || true)
  [ "$alpha_rows_before" -eq 1 ]

  # Dirty beta and restore the obfuscated source for both, simulating a pull
  # that brings back the obfuscated form alongside the dirty readable.
  echo "local edit on beta" > "$NOTES_CALLER_PWD/notes/beta.md"
  git -C "$NOTES_CALLER_PWD" update-index --no-assume-unchanged "notes/$alpha_id" "notes/$beta_id" 2>/dev/null || true
  git -C "$NOTES_CALLER_PWD" checkout -- "notes/$alpha_id" "notes/$beta_id"
  # Now alpha.md is up-to-date but the obfuscated source has been re-restored;
  # beta has a dirty readable that should refuse.

  # Remove the alpha readable so the rename re-creates it from scratch (cmp -s
  # mismatch triggers the rename path); beta refuses on the dirty check.
  rm -f "$NOTES_CALLER_PWD/notes/alpha.md"

  run notes deobfuscate
  [ "$status" -ne 0 ]
  [[ "$output" == *"refusing to overwrite dirty readable note"* ]]
  # Alpha was renamed despite beta's failure...
  [ -f "$NOTES_CALLER_PWD/notes/alpha.md" ]
  # ...and the state file recorded its base hash again (the actual regression
  # under test). Pre-fix the task exit'd before _record_deobfuscation_base_hashes
  # was called, so alpha_rows_after == alpha_rows_before. Post-fix the recording
  # runs even on partial failure, so the row count strictly increases.
  local alpha_rows_after
  alpha_rows_after=$(grep -c "^${alpha_id}"$'\t' "$state" || true)
  [ "$alpha_rows_after" -gt "$alpha_rows_before" ]
}


@test "deobfuscation state file is append-only and last-entry-wins" {
  # Regression: notes#59 finding 3. The state file is now append-only to
  # avoid a tmp+mv read-modify-write race when two deobfuscate processes
  # interleave. Two invariants we test here:
  #   (a) re-recording an id appends a new row instead of rewriting the file
  #   (b) the lookup semantic takes the *last* matching row, so newer writes
  #       shadow older ones (which is what makes append-only safe).
  notes obfuscate
  local alpha_id
  alpha_id=$(grep "alpha.md" "$NOTES_CALLER_PWD/notes/.manifest" | cut -f1)
  git -C "$NOTES_CALLER_PWD" add -A notes
  git -C "$NOTES_CALLER_PWD" commit -q -m "obfuscate"

  notes deobfuscate
  local state="$NOTES_CALLER_PWD/.git/info/notes-obfuscation-state"
  [ -f "$state" ]

  local rows_before alpha_rows_before
  rows_before=$(wc -l < "$state" | tr -d ' ')
  alpha_rows_before=$(grep -c "^${alpha_id}"$'\t' "$state" || true)
  [ "$alpha_rows_before" -eq 1 ]

  # Drive another deobfuscate cycle: dirty the readable, restore the
  # obfuscated source from the commit (simulating a pull), then force.
  # Pre-fix this rewrote the state file (rows_after == rows_before);
  # post-fix it appends (rows_after > rows_before).
  echo "local edit" >> "$NOTES_CALLER_PWD/notes/alpha.md"
  git -C "$NOTES_CALLER_PWD" update-index --no-assume-unchanged "notes/$alpha_id" 2>/dev/null || true
  git -C "$NOTES_CALLER_PWD" checkout -- "notes/$alpha_id"
  notes deobfuscate -- --force

  local rows_after alpha_rows_after
  rows_after=$(wc -l < "$state" | tr -d ' ')
  alpha_rows_after=$(grep -c "^${alpha_id}"$'\t' "$state" || true)
  [ "$rows_after" -gt "$rows_before" ]
  [ "$alpha_rows_after" -gt "$alpha_rows_before" ]

  # Last-entry-wins lookup: inject a stale row at the end and confirm the
  # awk "last match" semantic the helper uses returns the stale one (i.e.
  # whatever was written most recently wins). This is the property that
  # makes append-only safe under concurrent writes.
  local stale_hash="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
  printf '%s\t%s\n' "$alpha_id" "$stale_hash" >> "$state"

  # Pin the contract on the helper, not its implementation -- a future
  # rewrite of _deobfuscation_base_hash_for_id (different awk, perl, etc.)
  # that silently broke last-entry-wins would then fail this test.
  local last
  last=$(_deobfuscation_base_hash_for_id "$NOTES_CALLER_PWD/notes" "$alpha_id")
  [ "$last" = "$stale_hash" ]
}
