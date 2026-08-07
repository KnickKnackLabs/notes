#!/usr/bin/env bats

load test_helper

setup() {
  export NOTES_CALLER_PWD="$BATS_TEST_TMPDIR"
  mkdir -p "$NOTES_CALLER_PWD/notes"
}

@test "search finds matching body text" {
  notes new --slug alpha --title "Alpha Note" --tags "testing" --body "Dispatch the follow-up packet."
  notes new --slug beta --title "Beta Note" --tags "testing" --body "Nothing relevant here."

  run notes search dispatch --json
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c "import sys, json; data = json.load(sys.stdin); assert len(data) == 1; assert data[0]['title'] == 'Alpha Note'; assert data[0]['matches'][0].startswith('body:')"
}

@test "search finds matching frontmatter" {
  cat > "$NOTES_CALLER_PWD/notes/skill.md" <<'EOF'
---
title: Parallel Follow-up
type: skill
status: candidate
tags: [skill, workflow]
created: 2026-01-01
updated: 2026-01-02
---

# Parallel Follow-up
EOF

  run notes search candidate --json
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c "import sys, json; data = json.load(sys.stdin); assert len(data) == 1; assert data[0]['status'] == 'candidate'; assert any(m.startswith('status:') for m in data[0]['matches'])"
}

@test "search --type filters results" {
  cat > "$NOTES_CALLER_PWD/notes/skill.md" <<'EOF'
---
title: Skill Note
type: skill
status: candidate
tags: [skill]
created: 2026-01-01
updated: 2026-01-03
---

# Skill Note
Reusable workflow instructions.
EOF
  cat > "$NOTES_CALLER_PWD/notes/pattern.md" <<'EOF'
---
title: Pattern Note
type: pattern
status: candidate
tags: [pattern]
created: 2026-01-01
updated: 2026-01-04
---

# Pattern Note
Reusable workflow instructions.
EOF

  run notes search workflow --json --type skill
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c "import sys, json; data = json.load(sys.stdin); assert len(data) == 1; assert data[0]['title'] == 'Skill Note'"
}

@test "search --limit bounds output" {
  notes new --slug one --title "One" --tags "testing" --updated "2026-01-01" --body "same needle"
  notes new --slug two --title "Two" --tags "testing" --updated "2026-01-02" --body "same needle"

  run notes search needle --json --limit 1
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c "import sys, json; data = json.load(sys.stdin); assert len(data) == 1; assert data[0]['title'] == 'Two'"
}

@test "search empty match reports no notes" {
  notes new --slug alpha --title "Alpha Note" --tags "testing" --body "Useful body text"

  run notes search absent
  [ "$status" -eq 0 ]
  [[ "$output" == *"No notes found matching: absent"* ]]
}

@test "search falls back to sanitized TSV when gum table fails" {
  python3 <<'PY'
import os
from pathlib import Path

notes_dir = Path(os.environ["NOTES_CALLER_PWD"]) / "notes"
(notes_dir / "unusual.md").write_text(
    "---\n"
    'title: "Tab\tTitle"\n'
    "type: note\n"
    "status: active\n"
    "tags: [test]\n"
    "created: 2026-01-01\n"
    "updated: 2026-01-02\n"
    "---\n\n"
    "# Tab\tTitle\n"
    "Body with\ta\ttab\ttoo.\n",
    encoding="utf-8",
)
PY
  make_failing_gum

  run notes search Tab

  [ "$status" -eq 0 ]
  [ -s "$GUM_LOG" ]
  [[ "$output" == *$'Title\tType\tStatus\tUpdated\tMatches'* ]]
  [[ "$output" == *"Tab Title"* ]]
  [[ "$output" == *"# Tab Title"* ]]
  [[ "$output" != *"partial gum output"* ]]
}
