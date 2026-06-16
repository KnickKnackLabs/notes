#!/usr/bin/env bats

load test_helper

# --- Text output ---

@test "status shows encryption state" {
  run notes status
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Encryption:"
}

@test "status shows not_initialized when no git-crypt" {
  run notes status
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "not_initialized"
}

@test "status shows encryption unlocked after setup" {
  notes setup --yes
  run notes status
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "unlocked"
}

@test "status shows obfuscation state" {
  run notes status
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Obfuscation:"
}

@test "status shows obfuscation none when no manifest" {
  run notes status
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "none"
}

@test "status shows obfuscation state after obfuscate" {
  notes setup --yes
  mkdir -p "$TARGET_DIR/notes"
  echo -e "---\ntitle: Test\n---\n# Test" > "$TARGET_DIR/notes/test-note.md"
  git -C "$TARGET_DIR" add -A
  git -C "$TARGET_DIR" commit -q -m "add note"
  notes obfuscate

  run notes status
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "obfuscated"
  echo "$output" | grep -q "1 notes"
}

@test "status reports incomplete deobfuscation for dual-present differing pair" {
  mkdir -p "$TARGET_DIR/notes"
  printf 'aaaaaaaa\talpha.md\n' > "$TARGET_DIR/notes/.manifest"
  echo "# Alpha local edit" > "$TARGET_DIR/notes/alpha.md"
  echo "# Alpha incoming upstream" > "$TARGET_DIR/notes/aaaaaaaa"

  run notes status
  [ "$status" -eq 0 ]
  [[ "$output" == *"Incomplete deobfuscation"* ]]
  [[ "$output" == *"alpha.md"* ]]
  [[ "$output" == *"notes/aaaaaaaa"* ]]
}

@test "status reports double-tracked notes when readable path is tracked in index" {
  mkdir -p "$TARGET_DIR/notes"
  git -C "$TARGET_DIR" init -q
  printf 'aaaaaaaa\talpha.md\n' > "$TARGET_DIR/notes/.manifest"
  echo "# Alpha tracked" > "$TARGET_DIR/notes/alpha.md"
  echo "# Alpha obfuscated" > "$TARGET_DIR/notes/aaaaaaaa"
  git -C "$TARGET_DIR" add -A
  git -C "$TARGET_DIR" commit -q -m "init"

  # Simulate the double-tracking bug: readable name committed alongside hex
  # (In the test repo, both are committed via `add -A` above. This matches the
  # real-world state where readable + hex both exist in the index.)

  run notes status
  [ "$status" -eq 0 ]
  [[ "$output" == *"DOUBLE-TRACKED NOTES"* ]]
  [[ "$output" == *"alpha.md"* ]]
  [[ "$output" == *"notes/aaaaaaaa"* ]]
}

@test "status does not report double-tracked when only obfuscated is tracked" {
  mkdir -p "$TARGET_DIR/notes"
  git -C "$TARGET_DIR" init -q
  printf 'aaaaaaaa\talpha.md\n' > "$TARGET_DIR/notes/.manifest"
  echo "# Alpha obfuscated" > "$TARGET_DIR/notes/aaaaaaaa"
  git -C "$TARGET_DIR" add -A
  git -C "$TARGET_DIR" commit -q -m "init"

  # Readable is on disk but not tracked
  echo "# Alpha readable" > "$TARGET_DIR/notes/alpha.md"

  run notes status
  [ "$status" -eq 0 ]
  [[ "$output" != *"DOUBLE-TRACKED NOTES"* ]]
}

# --- JSON output ---

@test "status --json outputs valid JSON" {
  run notes status -- --json
  [ "$status" -eq 0 ]
  echo "$output" | jq empty
}

@test "status --json has encryption and obfuscation fields" {
  run notes status -- --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.encryption.status'
  echo "$output" | jq -e '.obfuscation.status'
}

@test "status --json shows not_initialized when no git-crypt" {
  run notes status -- --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.encryption.status == "not_initialized"'
  echo "$output" | jq -e '.encryption.unlocked == false'
}

@test "status --json shows unlocked after setup" {
  notes setup --yes
  run notes status -- --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.encryption.status == "unlocked"'
  echo "$output" | jq -e '.encryption.unlocked == true'
}

@test "status --json shows obfuscation none when no manifest" {
  run notes status -- --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.obfuscation.status == "none"'
  echo "$output" | jq -e '.obfuscation.notes == 0'
}

@test "status --json shows note count after obfuscate" {
  notes setup --yes
  mkdir -p "$TARGET_DIR/notes"
  echo -e "---\ntitle: Alpha\n---\n# Alpha" > "$TARGET_DIR/notes/alpha.md"
  echo -e "---\ntitle: Beta\n---\n# Beta" > "$TARGET_DIR/notes/beta.md"
  git -C "$TARGET_DIR" add -A
  git -C "$TARGET_DIR" commit -q -m "add notes"
  notes obfuscate

  run notes status -- --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.obfuscation.status == "obfuscated"'
  echo "$output" | jq -e '.obfuscation.notes == 2'
}

@test "status handles locked repo gracefully" {
  # Integration test — needs real git-crypt lock, blocked on notes#39.
  skip "needs notes#39 (clean git status via exclude management)"
}

@test "status --json reports unknown obfuscation when locked" {
  # Needs rudi lock, which needs a clean tree — blocked on notes#39.
  # Expected contract: .obfuscation.status == "unknown", .obfuscation.notes == null
  skip "needs notes#39 (clean git status via exclude management)"
}

@test "status text reports locked with unlock hint" {
  # Needs rudi lock — blocked on notes#39.
  # Expected: output contains "locked" and "notes unlock"
  skip "needs notes#39 (clean git status via exclude management)"
}

@test "status --json shows deobfuscated after deobfuscate" {
  notes setup --yes
  mkdir -p "$TARGET_DIR/notes"
  echo -e "---\ntitle: Test\n---\n# Test" > "$TARGET_DIR/notes/test-note.md"
  git -C "$TARGET_DIR" add -A
  git -C "$TARGET_DIR" commit -q -m "add note"
  notes obfuscate
  notes deobfuscate

  run notes status -- --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.obfuscation.status == "deobfuscated"'
}
