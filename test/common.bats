#!/usr/bin/env bats

# Tests for manifest helpers in lib/common.sh:
#   - manifest_id_for_name, manifest_has_id, manifest_name_for_id

load test_helper

setup() {
  export NOTES_CALLER_PWD="$BATS_TEST_TMPDIR"
  source "$REPO_DIR/lib/common.sh"

  mkdir -p "$NOTES_CALLER_PWD/notes"
  MANIFEST="$NOTES_CALLER_PWD/notes/.manifest"
}

# ── Caller directory contract ────────────────────────────────

@test "NOTES_CALLER_PWD takes precedence over inherited CALLER_PWD" {
  local right="$BATS_TEST_TMPDIR/right-repo"
  local wrong="$BATS_TEST_TMPDIR/wrong-repo"
  mkdir -p "$right/notes" "$wrong/notes"

  cat > "$right/notes/right.md" <<'EOF'
---
title: Right Repo
tags: []
---
EOF
  cat > "$wrong/notes/wrong.md" <<'EOF'
---
title: Wrong Repo
tags: []
---
EOF

  export NOTES_CALLER_PWD="$right"
  export CALLER_PWD="$wrong"
  run notes list --json
  unset CALLER_PWD

  [ "$status" -eq 0 ]
  [[ "$output" == *"Right Repo"* ]]
  [[ "$output" != *"Wrong Repo"* ]]
}

@test "generic CALLER_PWD is ignored to avoid stale caller context" {
  local stale="$BATS_TEST_TMPDIR/stale-repo"
  mkdir -p "$stale/notes"
  cat > "$stale/notes/stale.md" <<'EOF'
---
title: Stale Repo
tags: []
---
EOF

  unset NOTES_CALLER_PWD
  run bash -c 'cd "$REPO_DIR" && CALLER_PWD="$1" mise run -q list --json' _ "$stale"

  [ "$status" -ne 0 ]
  [[ "$output" == *"notes directory not found"* ]]
  [[ "$output" != *"Stale Repo"* ]]
}

@test "test harness supplies deterministic Git identity without ambient config" {
  run git config --get user.name
  [ "$status" -eq 0 ]
  [ "$output" = "Notes tests" ]

  run git config --get user.email
  [ "$status" -eq 0 ]
  [ "$output" = "notes-tests@example.invalid" ]
}

# ── Confirmation helpers ─────────────────────────────────────

@test "confirm_destructive accepts --yes flag" {
  export usage_yes=true
  run confirm_destructive "Danger?"
  unset usage_yes
  [ "$status" -eq 0 ]
}

@test "confirm_destructive accepts NOTES_YES" {
  export NOTES_YES=1
  run confirm_destructive "Danger?"
  unset NOTES_YES
  [ "$status" -eq 0 ]
}

@test "confirm_destructive accepts MISE_YES" {
  export MISE_YES=yes
  run confirm_destructive "Danger?"
  unset MISE_YES
  [ "$status" -eq 0 ]
}

@test "confirm_destructive requires exact truthy env approval" {
  unset usage_yes MISE_YES
  export NOTES_YES=TRUE
  export NOTES_CONFIRM_TTY="$BATS_TEST_TMPDIR/missing-tty"
  run confirm_destructive "Danger?"
  unset NOTES_YES NOTES_CONFIRM_TTY
  [ "$status" -eq 2 ]
}

@test "confirm_destructive refuses without tty or bypass" {
  unset usage_yes NOTES_YES MISE_YES
  export NOTES_CONFIRM_TTY="$BATS_TEST_TMPDIR/missing-tty"
  run confirm_destructive "Danger?"
  unset NOTES_CONFIRM_TTY
  [ "$status" -eq 2 ]
  [[ "$output" == *"confirmation required"* ]]
  [[ "$output" == *"Re-run with --yes"* ]]
}

# ── Manifest helpers ──────────────────────────────────────────

@test "manifest_id_for_name returns id for known name" {
  printf 'abc12345\talpha.md\n' > "$MANIFEST"
  run manifest_id_for_name "$MANIFEST" "alpha.md"
  [ "$status" -eq 0 ]
  [ "$output" = "abc12345" ]
}

@test "manifest_id_for_name returns nothing for unknown name" {
  printf 'abc12345\talpha.md\n' > "$MANIFEST"
  run manifest_id_for_name "$MANIFEST" "unknown.md"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "manifest_id_for_name returns nothing when manifest missing" {
  run manifest_id_for_name "$MANIFEST" "alpha.md"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "manifest_id_for_name does not match partial names" {
  printf 'abc12345\talpha.md\ndef67890\talpha.md.bak\n' > "$MANIFEST"
  run manifest_id_for_name "$MANIFEST" "alpha.md"
  [ "$output" = "abc12345" ]
}

@test "manifest_has_id succeeds for known id" {
  printf 'abc12345\talpha.md\n' > "$MANIFEST"
  manifest_has_id "$MANIFEST" "abc12345"
}

@test "manifest_has_id fails for unknown id" {
  printf 'abc12345\talpha.md\n' > "$MANIFEST"
  ! manifest_has_id "$MANIFEST" "ffffffff"
}

@test "manifest_has_id fails when manifest missing" {
  ! manifest_has_id "$MANIFEST" "abc12345"
}

@test "manifest_has_id does not match partial ids" {
  printf 'abc12345\talpha.md\n' > "$MANIFEST"
  ! manifest_has_id "$MANIFEST" "abc1234"
}

@test "manifest_name_for_id returns name for known id" {
  printf 'abc12345\talpha.md\n' > "$MANIFEST"
  run manifest_name_for_id "$MANIFEST" "abc12345"
  [ "$status" -eq 0 ]
  [ "$output" = "alpha.md" ]
}

@test "manifest_name_for_id returns nothing for unknown id" {
  printf 'abc12345\talpha.md\n' > "$MANIFEST"
  run manifest_name_for_id "$MANIFEST" "ffffffff"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "detect_double_tracked_notes inspects tracked paths in one Git process" {
  local i=1 id name real_git counter_bin calls
  git -C "$NOTES_CALLER_PWD" init -q

  while [ "$i" -le 42 ]; do
    id=$(printf '%08d' "$i")
    name=$(printf 'note-%02d.md' "$i")
    printf '%s\t%s\n' "$id" "$name" >> "$MANIFEST"
    printf '# Note %02d\n' "$i" > "$NOTES_CALLER_PWD/notes/$id"
    i=$((i + 1))
  done
  git -C "$NOTES_CALLER_PWD" add notes
  git -C "$NOTES_CALLER_PWD" commit -q -m "obfuscated notes"
  printf '# Tracked readable\n' > "$NOTES_CALLER_PWD/notes/note-17.md"
  git -C "$NOTES_CALLER_PWD" add -f notes/note-17.md

  counter_bin="$BATS_TEST_TMPDIR/counter-bin"
  calls="$BATS_TEST_TMPDIR/git.calls"
  real_git=$(command -v git)
  mkdir -p "$counter_bin"
  cat > "$counter_bin/git" <<SH
#!/usr/bin/env bash
printf '1\\n' >> '$calls'
exec '$real_git' "\$@"
SH
  chmod +x "$counter_bin/git"

  PATH="$counter_bin:$PATH" run detect_double_tracked_notes "$NOTES_CALLER_PWD" notes

  [ "$status" -eq 0 ]
  [ "$output" = $'00000017\tnote-17.md' ]
  [ "$(wc -l < "$calls" | tr -d ' ')" -eq 1 ]
}
