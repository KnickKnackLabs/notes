#!/usr/bin/env bats

# Tests for Layer 1 rename functions in lib/obfuscate.sh:
#   - rename_to_obfuscated
#   - rename_to_readable

load test_helper

setup() {
  export NOTES_CALLER_PWD="$BATS_TEST_TMPDIR"
  source "$REPO_DIR/lib/common.sh"
  source "$REPO_DIR/lib/obfuscate.sh"

  mkdir -p "$NOTES_CALLER_PWD/notes"
  echo "# Alpha" > "$NOTES_CALLER_PWD/notes/alpha.md"
  echo "# Beta" > "$NOTES_CALLER_PWD/notes/beta.md"
  echo "# Gamma" > "$NOTES_CALLER_PWD/notes/gamma.txt"

  MANIFEST="$NOTES_CALLER_PWD/notes/.manifest"
}

# ── rename_to_obfuscated ─────────────────────────────────────

@test "rename_to_obfuscated renames all files and creates manifest" {
  rename_to_obfuscated "$NOTES_CALLER_PWD/notes" > /dev/null

  # Original files should be gone
  [ ! -f "$NOTES_CALLER_PWD/notes/alpha.md" ]
  [ ! -f "$NOTES_CALLER_PWD/notes/beta.md" ]
  [ ! -f "$NOTES_CALLER_PWD/notes/gamma.txt" ]

  # Manifest should have 3 entries
  [ -f "$MANIFEST" ]
  [ "$(wc -l < "$MANIFEST" | tr -d ' ')" -eq 3 ]
}

@test "rename_to_obfuscated generates 8-char hex IDs" {
  rename_to_obfuscated "$NOTES_CALLER_PWD/notes" > /dev/null

  while IFS=$'\t' read -r id name; do
    [[ "$id" =~ ^[0-9a-f]{8}$ ]]
  done < "$MANIFEST"
}

@test "rename_to_obfuscated preserves file content" {
  rename_to_obfuscated "$NOTES_CALLER_PWD/notes" > /dev/null

  local id
  id=$(manifest_id_for_name "$MANIFEST" "alpha.md")
  [[ "$(cat "$NOTES_CALLER_PWD/notes/$id")" == *"# Alpha"* ]]
}

@test "rename_to_obfuscated outputs relpath-tab-id per file" {
  local output
  output=$(rename_to_obfuscated "$NOTES_CALLER_PWD/notes")

  # Should have 3 lines
  [ "$(echo "$output" | wc -l | tr -d ' ')" -eq 3 ]

  # Each line should be relpath\tid
  while IFS=$'\t' read -r relpath id; do
    [ -n "$relpath" ]
    [[ "$id" =~ ^[0-9a-f]{8}$ ]]
  done <<< "$output"
}

@test "rename_to_obfuscated returns 2 when nothing to do" {
  rename_to_obfuscated "$NOTES_CALLER_PWD/notes" > /dev/null
  run rename_to_obfuscated "$NOTES_CALLER_PWD/notes"
  [ "$status" -eq 2 ]
}

@test "rename_to_obfuscated skips .manifest" {
  rename_to_obfuscated "$NOTES_CALLER_PWD/notes" > /dev/null
  ! grep -q ".manifest" "$MANIFEST"
}

@test "rename_to_obfuscated scoped: only renames specified files" {
  rename_to_obfuscated "$NOTES_CALLER_PWD/notes" "alpha.md" > /dev/null

  [ ! -f "$NOTES_CALLER_PWD/notes/alpha.md" ]
  [ -f "$NOTES_CALLER_PWD/notes/beta.md" ]
  [ -f "$NOTES_CALLER_PWD/notes/gamma.txt" ]
}

@test "rename_to_obfuscated scoped: preserves existing manifest entries" {
  # First obfuscate all
  rename_to_obfuscated "$NOTES_CALLER_PWD/notes" > /dev/null
  [ "$(wc -l < "$MANIFEST" | tr -d ' ')" -eq 3 ]

  local beta_id gamma_id
  beta_id=$(manifest_id_for_name "$MANIFEST" "beta.md")
  gamma_id=$(manifest_id_for_name "$MANIFEST" "gamma.txt")

  # Deobfuscate all
  rename_to_readable "$NOTES_CALLER_PWD/notes" > /dev/null

  # Scoped obfuscate just alpha
  rename_to_obfuscated "$NOTES_CALLER_PWD/notes" "alpha.md" > /dev/null

  # Manifest still has all 3 entries with stable IDs
  [ "$(wc -l < "$MANIFEST" | tr -d ' ')" -eq 3 ]
  [ "$(manifest_id_for_name "$MANIFEST" "beta.md")" = "$beta_id" ]
  [ "$(manifest_id_for_name "$MANIFEST" "gamma.txt")" = "$gamma_id" ]
}

@test "rename_to_obfuscated restores known IDs after deobfuscation" {
  rename_to_obfuscated "$NOTES_CALLER_PWD/notes" > /dev/null
  local alpha_id
  alpha_id=$(manifest_id_for_name "$MANIFEST" "alpha.md")

  rename_to_readable "$NOTES_CALLER_PWD/notes" > /dev/null
  rename_to_obfuscated "$NOTES_CALLER_PWD/notes" > /dev/null

  # Same ID reused
  [ "$(manifest_id_for_name "$MANIFEST" "alpha.md")" = "$alpha_id" ]
  [ -f "$NOTES_CALLER_PWD/notes/$alpha_id" ]
}

@test "rename_to_obfuscated flattens subdirectories" {
  mkdir -p "$NOTES_CALLER_PWD/notes/sub"
  echo "# Deep" > "$NOTES_CALLER_PWD/notes/sub/deep.md"

  rename_to_obfuscated "$NOTES_CALLER_PWD/notes" > /dev/null

  [ ! -d "$NOTES_CALLER_PWD/notes/sub" ]
  grep -q "sub/deep.md" "$MANIFEST"
}

@test "rename_to_obfuscated removes stale manifest entries during rename" {
  rename_to_obfuscated "$NOTES_CALLER_PWD/notes" > /dev/null
  [ "$(wc -l < "$MANIFEST" | tr -d ' ')" -eq 3 ]

  # Delete alpha's obfuscated file and add a new file
  local alpha_id
  alpha_id=$(manifest_id_for_name "$MANIFEST" "alpha.md")
  rm "$NOTES_CALLER_PWD/notes/$alpha_id"
  echo "# Delta" > "$NOTES_CALLER_PWD/notes/delta.md"

  # Re-obfuscate — the new file triggers a pass, stale alpha gets dropped
  rename_to_obfuscated "$NOTES_CALLER_PWD/notes" > /dev/null
  [ "$(wc -l < "$MANIFEST" | tr -d ' ')" -eq 3 ]  # beta, gamma, delta
  ! grep -q "alpha.md" "$MANIFEST"
  grep -q "delta.md" "$MANIFEST"
}

@test "rename_to_obfuscated does not touch git index" {
  git -C "$NOTES_CALLER_PWD" init -q
  git -C "$NOTES_CALLER_PWD" add -A
  git -C "$NOTES_CALLER_PWD" commit -q -m "init"

  rename_to_obfuscated "$NOTES_CALLER_PWD/notes" > /dev/null

  # Index should not have obfuscated names staged
  local staged
  staged=$(git -C "$NOTES_CALLER_PWD" diff --cached --name-only)
  [ -z "$staged" ]
}

# ── rename_to_readable ───────────────────────────────────────

@test "rename_to_readable restores all files" {
  rename_to_obfuscated "$NOTES_CALLER_PWD/notes" > /dev/null
  rename_to_readable "$NOTES_CALLER_PWD/notes" > /dev/null

  [ -f "$NOTES_CALLER_PWD/notes/alpha.md" ]
  [ -f "$NOTES_CALLER_PWD/notes/beta.md" ]
  [ -f "$NOTES_CALLER_PWD/notes/gamma.txt" ]
}

@test "rename_to_readable preserves content" {
  rename_to_obfuscated "$NOTES_CALLER_PWD/notes" > /dev/null
  rename_to_readable "$NOTES_CALLER_PWD/notes" > /dev/null

  [[ "$(cat "$NOTES_CALLER_PWD/notes/alpha.md")" == *"# Alpha"* ]]
}

@test "rename_to_readable outputs id-tab-relpath per file" {
  rename_to_obfuscated "$NOTES_CALLER_PWD/notes" > /dev/null
  local output
  output=$(rename_to_readable "$NOTES_CALLER_PWD/notes")

  [ "$(echo "$output" | wc -l | tr -d ' ')" -eq 3 ]

  while IFS=$'\t' read -r id relpath; do
    [[ "$id" =~ ^[0-9a-f]{8}$ ]]
    [ -n "$relpath" ]
  done <<< "$output"
}

@test "rename_to_readable returns 2 when nothing to do" {
  rename_to_obfuscated "$NOTES_CALLER_PWD/notes" > /dev/null
  rename_to_readable "$NOTES_CALLER_PWD/notes" > /dev/null

  run rename_to_readable "$NOTES_CALLER_PWD/notes"
  [ "$status" -eq 2 ]
}

@test "rename_to_readable returns 1 without manifest" {
  run rename_to_readable "$NOTES_CALLER_PWD/notes"
  [ "$status" -eq 1 ]
}

@test "rename_to_readable scoped: only deobfuscates specified IDs" {
  rename_to_obfuscated "$NOTES_CALLER_PWD/notes" > /dev/null

  local alpha_id beta_id
  alpha_id=$(manifest_id_for_name "$MANIFEST" "alpha.md")
  beta_id=$(manifest_id_for_name "$MANIFEST" "beta.md")

  rename_to_readable "$NOTES_CALLER_PWD/notes" "$alpha_id" > /dev/null

  [ -f "$NOTES_CALLER_PWD/notes/alpha.md" ]
  [ -f "$NOTES_CALLER_PWD/notes/$beta_id" ]
  [ ! -f "$NOTES_CALLER_PWD/notes/beta.md" ]
}

@test "rename_to_readable recreates subdirectories" {
  mkdir -p "$NOTES_CALLER_PWD/notes/sub"
  echo "# Deep" > "$NOTES_CALLER_PWD/notes/sub/deep.md"

  rename_to_obfuscated "$NOTES_CALLER_PWD/notes" > /dev/null
  [ ! -d "$NOTES_CALLER_PWD/notes/sub" ]

  rename_to_readable "$NOTES_CALLER_PWD/notes" > /dev/null
  [ -f "$NOTES_CALLER_PWD/notes/sub/deep.md" ]
}

@test "rename_to_readable derives nested target directories without dirname" {
  mkdir -p "$NOTES_CALLER_PWD/notes/sub"
  echo "# Deep" > "$NOTES_CALLER_PWD/notes/sub/deep.md"
  rename_to_obfuscated "$NOTES_CALLER_PWD/notes" > /dev/null

  local mock_bin blocked_log
  mock_bin="$BATS_TEST_TMPDIR/dirname-guard-bin"
  blocked_log="$BATS_TEST_TMPDIR/dirname-blocked"
  mkdir -p "$mock_bin"
  cat > "$mock_bin/dirname" <<'BASH'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$BLOCKED_COMMAND_LOG"
exit 97
BASH
  chmod +x "$mock_bin/dirname"

  PATH="$mock_bin:$PATH" BLOCKED_COMMAND_LOG="$blocked_log" \
    run rename_to_readable "$NOTES_CALLER_PWD/notes"

  [ "$status" -eq 0 ]
  [ -f "$NOTES_CALLER_PWD/notes/sub/deep.md" ]
  [ ! -e "$blocked_log" ]
}

@test "rename_to_readable preserves manifest" {
  rename_to_obfuscated "$NOTES_CALLER_PWD/notes" > /dev/null
  local manifest_before
  manifest_before=$(cat "$MANIFEST")

  rename_to_readable "$NOTES_CALLER_PWD/notes" > /dev/null

  [ "$(cat "$MANIFEST")" = "$manifest_before" ]
}

@test "rename_to_readable does not touch git index" {
  git -C "$NOTES_CALLER_PWD" init -q
  rename_to_obfuscated "$NOTES_CALLER_PWD/notes" > /dev/null
  git -C "$NOTES_CALLER_PWD" add -A
  git -C "$NOTES_CALLER_PWD" commit -q -m "obfuscated"

  rename_to_readable "$NOTES_CALLER_PWD/notes" > /dev/null

  # Index should not have renames staged
  local staged
  staged=$(git -C "$NOTES_CALLER_PWD" diff --cached --name-only)
  [ -z "$staged" ]
}

# ── Round-trip ────────────────────────────────────────────────

@test "round-trip obfuscate→deobfuscate preserves all content" {
  rename_to_obfuscated "$NOTES_CALLER_PWD/notes" > /dev/null
  rename_to_readable "$NOTES_CALLER_PWD/notes" > /dev/null

  [[ "$(cat "$NOTES_CALLER_PWD/notes/alpha.md")" == *"# Alpha"* ]]
  [[ "$(cat "$NOTES_CALLER_PWD/notes/beta.md")" == *"# Beta"* ]]
  [[ "$(cat "$NOTES_CALLER_PWD/notes/gamma.txt")" == *"# Gamma"* ]]
}

@test "round-trip preserves stable IDs" {
  rename_to_obfuscated "$NOTES_CALLER_PWD/notes" > /dev/null
  local manifest_first
  manifest_first=$(cat "$MANIFEST")

  rename_to_readable "$NOTES_CALLER_PWD/notes" > /dev/null
  rename_to_obfuscated "$NOTES_CALLER_PWD/notes" > /dev/null

  [ "$(cat "$MANIFEST")" = "$manifest_first" ]
}

@test "multiple round-trips are stable" {
  rename_to_obfuscated "$NOTES_CALLER_PWD/notes" > /dev/null
  local manifest_first
  manifest_first=$(cat "$MANIFEST")

  for i in 1 2 3; do
    rename_to_readable "$NOTES_CALLER_PWD/notes" > /dev/null
    rename_to_obfuscated "$NOTES_CALLER_PWD/notes" > /dev/null
  done

  [ "$(cat "$MANIFEST")" = "$manifest_first" ]
}
