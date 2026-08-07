#!/usr/bin/env bats

load test_helper

setup() {
  export NOTES_CALLER_PWD="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$NOTES_CALLER_PWD/notes"
}

@test "read returns a plain note unchanged" {
  local note="$NOTES_CALLER_PWD/notes/plain.md"
  local actual="$BATS_TEST_TMPDIR/actual.md"
  cat > "$note" <<'EOF'
# Plain note

Visible body.
EOF

  notes read plain > "$actual"

  cmp "$note" "$actual"
}

@test "read strips only frontmatter and preserves the remaining source" {
  local note="$NOTES_CALLER_PWD/notes/frontmatter.md"
  local expected="$BATS_TEST_TMPDIR/expected.md"
  local actual="$BATS_TEST_TMPDIR/actual.md"
  cat > "$expected" <<'EOF'
# Frontmatter note

Visible body.

<!-- NOTE-BANKNOTE-BEGIN name=maintenance
Keep this proposed tail block byte-for-byte.
NOTE-BANKNOTE-END -->
EOF
  {
    cat <<'EOF'
---
title: Frontmatter note
tags: [testing, read]
---
EOF
    cat "$expected"
  } > "$note"

  notes read frontmatter > "$actual"

  cmp "$expected" "$actual"
}

@test "read --with-frontmatter preserves the exact source" {
  local note="$NOTES_CALLER_PWD/notes/styled.md"
  local actual="$BATS_TEST_TMPDIR/actual.md"
  cat > "$note" <<'EOF'
---
# Keep this comment.
title: "Quoted: title"
tags: ["one", 'two']
---
# Styled note
EOF

  notes read styled --with-frontmatter > "$actual"

  cmp "$note" "$actual"
}

@test "read --json exposes parsed frontmatter and body" {
  local json="$BATS_TEST_TMPDIR/read.json"
  cat > "$NOTES_CALLER_PWD/notes/json.md" <<'EOF'
---
title: JSON note
tags:
  - testing
---
# JSON note
EOF

  notes read json --json > "$json"

  JSON_PATH="$json" python3 <<'PY'
import json
import os
from pathlib import Path

payload = json.loads(Path(os.environ["JSON_PATH"]).read_text(encoding="utf-8"))
assert payload["frontmatter"] == {"title": "JSON note", "tags": ["testing"]}
assert payload["frontmatter_present"] is True
assert payload["body"] == "# JSON note\n"
assert payload["diagnostics"] == []
PY
}

@test "read resolves absolute paths and a custom notes directory" {
  local custom="$NOTES_CALLER_PWD/journal"
  mkdir -p "$custom"
  printf '%s\n' "absolute body" > "$custom/entry.md"

  run notes read "$custom/entry.md"
  [ "$status" -eq 0 ]
  [ "$output" = "absolute body" ]

  run notes read entry --dir journal
  [ "$status" -eq 0 ]
  [ "$output" = "absolute body" ]
}

@test "read reports a missing note" {
  run notes read nonexistent

  [ "$status" -ne 0 ]
  [[ "$output" == "Error: note not found: nonexistent"* ]]
}

@test "read rejects non-UTF-8 note content" {
  printf '\xff\n' > "$NOTES_CALLER_PWD/notes/binary.md"

  run notes read binary

  [ "$status" -ne 0 ]
  [[ "$output" == "Error: note is not valid UTF-8:"* ]]
  [[ "$output" == *"notes/binary.md"* ]]
}

@test "read fails closed when managed notes are locked" {
  git -C "$NOTES_CALLER_PWD" init -q
  printf 'notes/** filter=git-crypt diff=git-crypt\n' > "$NOTES_CALLER_PWD/.gitattributes"
  printf '\x00GITCRYPT\x00locked' > "$NOTES_CALLER_PWD/notes/.manifest"
  printf '%s\n' "unreadable" > "$NOTES_CALLER_PWD/notes/locked.md"

  run notes read locked

  [ "$status" -ne 0 ]
  [[ "$output" == *"git-crypt is locked"* ]]
  [[ "$output" == *"notes unlock"* ]]
  [[ "$output" != *"unreadable"* ]]
}
