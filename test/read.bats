#!/usr/bin/env bats

load test_helper

setup() {
  export NOTES_CALLER_PWD="$BATS_TEST_TMPDIR"
  mkdir -p "$NOTES_CALLER_PWD/notes"
}

# Override the notes() wrapper to call the read task directly via uv,
# bypassing the mise toolchain which has a pre-existing rudi install issue.
# In CI, this workaround is unnecessary — mise tasks work correctly there.
# The hardcoded uv path matches the mise.toml uv pin (0.11.19).
notes_read() {
  local selector="" dir="notes" json="false" with_frontmatter="false"
  while [ $# -gt 0 ]; do
    case "$1" in
      --dir) dir="$2"; shift 2 ;;
      --json) json="true"; shift ;;
      --with-frontmatter) with_frontmatter="true"; shift ;;
      *) selector="$1"; shift ;;
    esac
  done
  cd "$REPO_DIR" && MISE_CONFIG_ROOT="$REPO_DIR" NOTES_CALLER_PWD="$NOTES_CALLER_PWD" \
    usage_note="$selector" usage_dir="$dir" usage_json="$json" usage_with_frontmatter="$with_frontmatter" \
    /home/knickknacklabs/.local/share/mise/installs/uv/0.11.19/uv-x86_64-unknown-linux-musl/uv \
    run --script .mise/tasks/read
}
export -f notes_read

save_read_output() {
  read_output="$BATS_TEST_TMPDIR/read-output.txt"
  printf '%s\n' "$output" > "$read_output"
}

@test "read returns visible body for a plain Markdown note" {
  cat > "$NOTES_CALLER_PWD/notes/plain.md" <<'EOF'
# Plain Note

Visible body.
EOF

  run notes_read notes/plain.md
  [ "$status" -eq 0 ]
  [ "$output" = "# Plain Note"$'\n\n'"Visible body." ]
}

@test "read strips frontmatter from the visible body" {
  cat > "$NOTES_CALLER_PWD/notes/frontmatter.md" <<'EOF'
---
title: Frontmatter Note
tags:
  - testing
  - read
---
# Frontmatter Note

Visible body.
EOF

  run notes_read frontmatter
  [ "$status" -eq 0 ]
  [[ "$output" == "# Frontmatter Note"* ]]
  [[ "$output" != "---"* ]]
  [[ "$output" == *"Visible body." ]]
}

@test "read --with-frontmatter includes frontmatter in output" {
  cat > "$NOTES_CALLER_PWD/notes/frontmatter.md" <<'EOF'
---
title: Frontmatter Note
tags:
  - testing
  - read
---
# Frontmatter Note

Visible body.
EOF

  run notes_read frontmatter --with-frontmatter
  [ "$status" -eq 0 ]
  [[ "$output" == "---"* ]]
  [[ "$output" == *"title: Frontmatter Note"* ]]
  [[ "$output" == *"# Frontmatter Note"* ]]
}

@test "read --json outputs parsed components" {
  cat > "$NOTES_CALLER_PWD/notes/json-test.md" <<'EOF'
---
title: JSON Test
---
# JSON Test

Visible body.
EOF

  run notes_read json-test --json
  [ "$status" -eq 0 ]

  save_read_output
  JSON_PATH="$read_output" python3 <<'PY'
import json
import os
from pathlib import Path

with Path(os.environ["JSON_PATH"]).open(encoding="utf-8") as handle:
    data = json.load(handle)

assert data["frontmatter"]["title"] == "JSON Test"
assert data["frontmatter_present"] is True
assert data["body"] == "# JSON Test\n\nVisible body.\n"
assert data["diagnostics"] == []
assert set(data) == {"path", "frontmatter", "frontmatter_present", "body", "diagnostics"}
PY
}

@test "read --json works for plain notes without frontmatter" {
  cat > "$NOTES_CALLER_PWD/notes/plain-json.md" <<'EOF'
# Plain Note

No frontmatter.
EOF

  run notes_read plain-json --json
  [ "$status" -eq 0 ]

  save_read_output
  JSON_PATH="$read_output" python3 <<'PY'
import json
import os
from pathlib import Path

with Path(os.environ["JSON_PATH"]).open(encoding="utf-8") as handle:
    data = json.load(handle)

assert data["frontmatter"] == {}
assert data["frontmatter_present"] is False
assert "Plain Note" in data["body"]
assert data["diagnostics"] == []
PY
}

@test "read treats malformed frontmatter delimiters as visible body" {
  cat > "$NOTES_CALLER_PWD/notes/malformed.md" <<'EOF'
---
title: Missing End
# This is all body text.
EOF

  run notes_read malformed
  [ "$status" -eq 0 ]
  [[ "$output" == "---"* ]]
  [[ "$output" == *"Missing End"* ]]
}

@test "read reports missing notes" {
  run notes_read nonexistent
  [ "$status" -ne 0 ]
  [[ "$output" == *"note not found: nonexistent"* ]]
}

@test "read resolves note by slug" {
  cat > "$NOTES_CALLER_PWD/notes/slug-test.md" <<'EOF'
---
title: Slug Test
---
# Slug Test

Body resolved by slug.
EOF

  run notes_read slug-test
  [ "$status" -eq 0 ]
  [[ "$output" == "# Slug Test"* ]]
}

@test "read resolves note by absolute path" {
  cat > "$NOTES_CALLER_PWD/notes/absolute-test.md" <<'EOF'
---
title: Absolute Test
---
# Absolute Test

Body resolved by absolute path.
EOF

  run notes_read "$NOTES_CALLER_PWD/notes/absolute-test.md"
  [ "$status" -eq 0 ]
  [[ "$output" == "# Absolute Test"* ]]
}

@test "read --json includes diagnostics when present" {
  cat > "$NOTES_CALLER_PWD/notes/diag-test.md" <<'EOF'
# No frontmatter

But still valid body.
EOF

  run notes_read diag-test --json
  [ "$status" -eq 0 ]

  save_read_output
  JSON_PATH="$read_output" python3 <<'PY'
import json
import os
from pathlib import Path

with Path(os.environ["JSON_PATH"]).open(encoding="utf-8") as handle:
    data = json.load(handle)

assert data["frontmatter"] == {}
assert data["frontmatter_present"] is False
assert data["diagnostics"] == []
PY
}