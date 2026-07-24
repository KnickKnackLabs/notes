#!/usr/bin/env bats

load test_helper

setup() {
  export NOTES_CALLER_PWD="$BATS_TEST_TMPDIR"
  mkdir -p "$NOTES_CALLER_PWD/notes"
}

@test "new creates note with frontmatter" {
  run notes new -- --slug alpha --title "Alpha Note" --tags "testing"
  [ "$status" -eq 0 ]

  run notes list -- --json
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c "import sys, json; d = json.load(sys.stdin); assert d[0]['title'] == 'Alpha Note'"
}

@test "new sets tags and dates" {
  notes new -- --slug beta --title "Beta" --tags "a, b" --created "2026-01-01" --updated "2026-03-20"

  run notes parse beta
  [ "$status" -eq 0 ]
  PARSED_NOTE="$output" python3 - <<'PY'
import json
import os

frontmatter = json.loads(os.environ["PARSED_NOTE"])["frontmatter"]
assert frontmatter["tags"] == ["a", "b"]
assert frontmatter["created"] == "2026-01-01"
assert frontmatter["updated"] == "2026-03-20"
PY
}

@test "new appends body text" {
  notes new -- --slug with-body --title "Body Note" --body "Some content here."

  run notes parse with-body
  [ "$status" -eq 0 ]
  PARSED_NOTE="$output" python3 - <<'PY'
import json
import os

assert "Some content here." in json.loads(os.environ["PARSED_NOTE"])["body"]
PY
}

@test "new fails if note already exists" {
  notes new -- --slug existing --title "First"

  run notes new -- --slug existing --title "Second"
  [ "$status" -ne 0 ]
  [[ "$output" == *"already exists"* ]]
}

@test "new defaults dates to today" {
  notes new -- --slug today-note --title "Today"
  today=$(date +%Y-%m-%d)

  run notes parse today-note
  [ "$status" -eq 0 ]
  PARSED_NOTE="$output" TODAY="$today" python3 - <<'PY'
import json
import os

assert json.loads(os.environ["PARSED_NOTE"])["frontmatter"]["created"] == os.environ["TODAY"]
PY
}
