#!/usr/bin/env bats

load test_helper

setup() {
  export NOTES_CALLER_PWD="$BATS_TEST_TMPDIR"
  mkdir -p "$NOTES_CALLER_PWD/notes"
}

@test "list shows notes with frontmatter" {
  notes new -- --slug alpha --title "Alpha Note" --tags "testing" --updated "2026-03-14"

  run notes list
  [ "$status" -eq 0 ]
  [[ "$output" == *"Alpha Note"* ]]
}

@test "list skips files without frontmatter" {
  notes new -- --slug real --title "Real Note" --tags "test" --updated "2026-03-14"
  echo "# No frontmatter" > "$NOTES_CALLER_PWD/notes/plain.md"

  run notes list
  [ "$status" -eq 0 ]
  [[ "$output" == *"Real Note"* ]]
  [[ "$output" != *"plain"* ]]
}

@test "list --json outputs valid JSON" {
  notes new -- --slug beta --title "Beta Note" --tags "guide, testing" --updated "2026-03-15"

  run notes list -- --json
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c "import sys, json; data = json.load(sys.stdin); assert len(data) == 1; assert data[0]['title'] == 'Beta Note'"
}

@test "list --json includes tags as array" {
  notes new -- --slug multi --title "Multi Tag" --tags "alpha, beta, gamma" --updated "2026-03-15"

  run notes list -- --json
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c "import sys, json; data = json.load(sys.stdin); assert data[0]['tags'] == ['alpha', 'beta', 'gamma']"
}

@test "list falls back to TSV when gum is unavailable" {
  notes new -- --slug alpha --title "Alpha Note" --tags "testing" --updated "2026-03-14"
  export GUM="$BATS_TEST_TMPDIR/missing-gum"

  run notes list

  [ "$status" -eq 0 ]
  [[ "$output" == *$'Title\tType\tStatus\tTags\tUpdated'* ]]
  [[ "$output" == *$'Alpha Note\t'* ]]
  [[ "$output" == *$'testing\t2026-03-14'* ]]
}

@test "list --json bypasses gum presentation" {
  notes new -- --slug beta --title "Beta Note" --tags "testing" --updated "2026-03-15"
  make_failing_gum

  run notes list -- --json

  [ "$status" -eq 0 ]
  [ ! -e "$GUM_LOG" ]
  echo "$output" | python3 -c "import sys, json; assert json.load(sys.stdin)[0]['title'] == 'Beta Note'"
}

@test "list --recent limits output" {
  notes new -- --slug old --title "Old Note" --tags "test" --updated "2026-03-10"
  notes new -- --slug mid --title "Mid Note" --tags "test" --updated "2026-03-15"
  notes new -- --slug new --title "New Note" --tags "test" --updated "2026-03-20"

  run notes list -- --json --recent 2
  [ "$status" -eq 0 ]
  count=$(echo "$output" | python3 -c "import sys, json; print(len(json.load(sys.stdin)))")
  [ "$count" -eq 2 ]
}

@test "list --recent returns most recent first" {
  notes new -- --slug old --title "Old Note" --tags "test" --updated "2026-03-10"
  notes new -- --slug new --title "New Note" --tags "test" --updated "2026-03-20"

  run notes list -- --json --recent 1
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c "import sys, json; assert json.load(sys.stdin)[0]['title'] == 'New Note'"
}

@test "list --tag filters by tag" {
  notes new -- --slug guide-a --title "Guide A" --tags "guide" --updated "2026-03-14"
  notes new -- --slug ref-b --title "Ref B" --tags "reference" --updated "2026-03-14"

  run notes list -- --json --tag guide
  [ "$status" -eq 0 ]
  count=$(echo "$output" | python3 -c "import sys, json; print(len(json.load(sys.stdin)))")
  [ "$count" -eq 1 ]
  echo "$output" | python3 -c "import sys, json; assert json.load(sys.stdin)[0]['title'] == 'Guide A'"
}

@test "list --json parses block-list tags" {
  cat > "$NOTES_CALLER_PWD/notes/block-tags.md" <<'EOF'
---
title: Block Tag Note
tags:
  - guide
  - testing
created: 2026-01-01
updated: 2026-01-02
---

# Block Tag Note
EOF

  run notes list -- --json
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c "import sys, json; assert json.load(sys.stdin)[0]['tags'] == ['guide', 'testing']"
}

@test "list --tag matches block-list tags" {
  cat > "$NOTES_CALLER_PWD/notes/block-tags.md" <<'EOF'
---
title: Block Tag Note
tags:
  - guide
  - testing
created: 2026-01-01
updated: 2026-01-02
---

# Block Tag Note
EOF

  run notes list -- --json --tag guide
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c "import sys, json; data = json.load(sys.stdin); assert len(data) == 1; assert data[0]['title'] == 'Block Tag Note'"
}

@test "list --type filters by frontmatter type" {
  cat > "$NOTES_CALLER_PWD/notes/skill.md" <<'EOF'
---
title: Skill Note
type: skill
status: candidate
tags: [skill, testing]
created: 2026-01-01
updated: 2026-01-03
---

# Skill Note
EOF
  notes new --slug pattern --title "Pattern Note" --tags "testing" --updated "2026-01-04"

  run notes list --json --type skill
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c "import sys, json; data = json.load(sys.stdin); assert len(data) == 1; assert data[0]['title'] == 'Skill Note'; assert data[0]['type'] == 'skill'"
}

@test "list --status filters by frontmatter status" {
  cat > "$NOTES_CALLER_PWD/notes/candidate.md" <<'EOF'
---
title: Candidate Note
type: skill
status: candidate
tags: [skill]
created: 2026-01-01
updated: 2026-01-03
---

# Candidate Note
EOF
  cat > "$NOTES_CALLER_PWD/notes/accepted.md" <<'EOF'
---
title: Accepted Note
type: skill
status: accepted
tags: [skill]
created: 2026-01-01
updated: 2026-01-04
---

# Accepted Note
EOF

  run notes list --json --status candidate
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c "import sys, json; data = json.load(sys.stdin); assert len(data) == 1; assert data[0]['title'] == 'Candidate Note'; assert data[0]['status'] == 'candidate'"
}

@test "list empty directory shows no notes" {
  run notes list
  [ "$status" -eq 0 ]
  [[ "$output" == *"No notes found"* ]]
}

@test "list --json empty directory returns empty array" {
  run notes list -- --json
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c "import sys, json; assert json.load(sys.stdin) == []"
}
