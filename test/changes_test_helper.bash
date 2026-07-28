setup_changes_fixture() {
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

setup() {
  setup_changes_fixture
}

add_clean_numbered_notes() {
  local count="$1"
  local i=1 name
  while [ "$i" -le "$count" ]; do
    name=$(printf 'note-%02d.md' "$i")
    printf '# Note %02d\n' "$i" > "$NOTES_CALLER_PWD/notes/$name"
    i=$((i + 1))
  done

  rename_to_obfuscated "$NOTES_CALLER_PWD/notes" > /dev/null
  git -C "$NOTES_CALLER_PWD" add -A
  git -C "$NOTES_CALLER_PWD" commit -q -m "add many notes"
  rename_to_readable "$NOTES_CALLER_PWD/notes" > /dev/null
  set_status_suppression "$NOTES_CALLER_PWD/notes"
}

install_process_counter() {
  local command="$1"
  local real_command
  real_command=$(command -v "$command")
  cat > "$PROCESS_COUNTER_BIN/$command" <<SH
#!/usr/bin/env bash
printf '1\\n' >> "\${NOTES_PROCESS_COUNTER_DIR:?}/$command.calls"
exec '$real_command' "\$@"
SH
  chmod +x "$PROCESS_COUNTER_BIN/$command"
}

setup_membership_process_counters() {
  PROCESS_COUNTER_BIN="$BATS_TEST_TMPDIR/process-counter-bin"
  NOTES_PROCESS_COUNTER_DIR="$BATS_TEST_TMPDIR/process-counter-results"
  mkdir -p "$PROCESS_COUNTER_BIN" "$NOTES_PROCESS_COUNTER_DIR"
  export NOTES_PROCESS_COUNTER_DIR
  install_process_counter grep
  install_process_counter basename
}

run_with_process_counters() {
  local function_name="$1"
  shift
  PATH="$PROCESS_COUNTER_BIN:$PATH"
  "$function_name" "$@"
}

setup_git_argument_counter() {
  local real_git
  PROCESS_COUNTER_BIN="$BATS_TEST_TMPDIR/git-counter-bin"
  NOTES_PROCESS_COUNTER_DIR="$BATS_TEST_TMPDIR/git-counter-results"
  real_git=$(command -v git)
  mkdir -p "$PROCESS_COUNTER_BIN" "$NOTES_PROCESS_COUNTER_DIR"
  export NOTES_PROCESS_COUNTER_DIR
  cat > "$PROCESS_COUNTER_BIN/git" <<SH
#!/usr/bin/env bash
printf '%s\\n' "\$*" >> "\${NOTES_PROCESS_COUNTER_DIR:?}/git.args"
exec '$real_git' "\$@"
SH
  chmod +x "$PROCESS_COUNTER_BIN/git"
}

setup_clean_filter_counter() {
  CLEAN_FILTER_CALLS="$BATS_TEST_TMPDIR/clean-filter.calls"
  CLEAN_FILTER="$BATS_TEST_TMPDIR/counting-clean-filter"
  export CLEAN_FILTER_CALLS
  cat > "$CLEAN_FILTER" <<'BASH'
#!/usr/bin/env bash
printf '1\n' >> "${CLEAN_FILTER_CALLS:?}"
cat
BASH
  chmod +x "$CLEAN_FILTER"
  git -C "$NOTES_CALLER_PWD" config filter.notes-test.clean "$CLEAN_FILTER"
  git -C "$NOTES_CALLER_PWD" config filter.notes-test.smudge cat
  git -C "$NOTES_CALLER_PWD" config filter.notes-test.required true
  printf 'notes/** filter=notes-test\n' > "$NOTES_CALLER_PWD/.gitattributes"
  git -C "$NOTES_CALLER_PWD" add .gitattributes
  git -C "$NOTES_CALLER_PWD" commit -q -m "add counting clean filter"
}

clean_filter_call_count() {
  if [ -f "$CLEAN_FILTER_CALLS" ]; then
    wc -l < "$CLEAN_FILTER_CALLS" | tr -d ' '
  else
    printf '0\n'
  fi
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

  if ! git -C "$NOTES_CALLER_PWD" update-index --no-assume-unchanged "notes/$id" 2>/dev/null; then
    : # The fixture ID may not currently be marked assume-unchanged.
  fi
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
