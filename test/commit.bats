#!/usr/bin/env bats

# Readable-note commit and full-lifecycle tests.

load test_helper
load changes_test_helper

# ── commit wrapper ───────────────────────────────────────────

@test "notes commit post-check batches readable-path inspection" {
  add_clean_numbered_notes 40
  notes install-hooks --yes >/dev/null
  printf '# changed\n' >> "$NOTES_CALLER_PWD/notes/alpha.md"
  setup_git_argument_counter

  run run_with_process_counters notes commit -m "update alpha" alpha.md

  [ "$status" -eq 0 ]
  [ "$(grep -c ' ls-files ' "$NOTES_PROCESS_COUNTER_DIR/git.args" || true)" -le 3 ]
}

@test "notes commit: explicit file commits modified note and leaves clean readable tree" {
  notes install-hooks --yes

  echo "# Alpha v2" > "$NOTES_CALLER_PWD/notes/alpha.md"

  run notes commit -m "update alpha" alpha.md
  [ "$status" -eq 0 ]
  [[ "$output" == *"Committed note changes"* ]]
  [[ "$output" == *"Notes changes: clean"* ]]

  [ "$(git -C "$NOTES_CALLER_PWD" log -1 --format=%s)" = "update alpha" ]
  [ -f "$NOTES_CALLER_PWD/notes/alpha.md" ]
  [[ "$(cat "$NOTES_CALLER_PWD/notes/alpha.md")" == *"Alpha v2"* ]]

  local committed_files
  committed_files=$(git -C "$NOTES_CALLER_PWD" show --name-only --format='' HEAD -- notes/)
  ! echo "$committed_files" | grep -q "alpha.md"

  run detect_changes "$NOTES_CALLER_PWD/notes"
  [ -z "$output" ]

  run git -C "$NOTES_CALLER_PWD" diff --cached --name-only
  [ -z "$output" ]

  run git -C "$NOTES_CALLER_PWD" ls-files notes/alpha.md
  [ -z "$output" ]
}

@test "notes commit --all commits modified new and deleted notes" {
  notes install-hooks --yes

  echo "# Alpha v2" > "$NOTES_CALLER_PWD/notes/alpha.md"
  echo "# Gamma" > "$NOTES_CALLER_PWD/notes/gamma.md"
  rm "$NOTES_CALLER_PWD/notes/beta.md"

  run notes commit --all -m "update all notes"
  [ "$status" -eq 0 ]
  [[ "$output" == *"staged: alpha.md"* ]]
  [[ "$output" == *"staged: gamma.md"* ]]
  [[ "$output" == *"staged (delete): beta.md"* ]]
  [[ "$output" == *"Notes changes: clean"* ]]

  [ -f "$NOTES_CALLER_PWD/notes/alpha.md" ]
  [ -f "$NOTES_CALLER_PWD/notes/gamma.md" ]
  [ ! -f "$NOTES_CALLER_PWD/notes/beta.md" ]
  ! grep -q "beta.md" "$MANIFEST"
  grep -q "gamma.md" "$MANIFEST"

  run detect_changes "$NOTES_CALLER_PWD/notes"
  [ -z "$output" ]
}

@test "notes commit: path-limited commit leaves unrelated dirty notes uncommitted" {
  notes install-hooks --yes

  local alpha_id beta_id
  alpha_id=$(manifest_id_for_name "$MANIFEST" "alpha.md")
  beta_id=$(manifest_id_for_name "$MANIFEST" "beta.md")

  echo "# Alpha v2" > "$NOTES_CALLER_PWD/notes/alpha.md"
  echo "# Beta v2" > "$NOTES_CALLER_PWD/notes/beta.md"

  run notes commit -m "update alpha only" alpha.md
  [ "$status" -eq 0 ]
  [[ "$output" == *"Remaining note changes"* ]]
  [[ "$output" == *"modified: beta.md"* ]]
  [[ "$output" != *"modified: alpha.md"* ]]

  git -C "$NOTES_CALLER_PWD" cat-file --filters "HEAD:notes/$alpha_id" | grep -q "Alpha v2"
  git -C "$NOTES_CALLER_PWD" cat-file --filters "HEAD:notes/$beta_id" | grep -q "# Beta"
  ! git -C "$NOTES_CALLER_PWD" cat-file --filters "HEAD:notes/$beta_id" | grep -q "Beta v2"

  run detect_changes "$NOTES_CALLER_PWD/notes"
  [[ "$output" == *"modified"*"beta.md"* ]]
  [[ "$output" != *"alpha.md"* ]]
}

@test "notes commit --dry-run shows staged plan without staging or committing" {
  local before
  before=$(git -C "$NOTES_CALLER_PWD" rev-parse HEAD)
  echo "# Alpha v2" > "$NOTES_CALLER_PWD/notes/alpha.md"

  run notes commit --dry-run -m "update alpha" alpha.md
  [ "$status" -eq 0 ]
  [[ "$output" == *"Would stage:"* ]]
  [[ "$output" == *"alpha.md"* ]]
  [[ "$output" == *"Would commit with message: update alpha"* ]]
  [ "$(git -C "$NOTES_CALLER_PWD" rev-parse HEAD)" = "$before" ]

  run git -C "$NOTES_CALLER_PWD" diff --cached --name-only
  [ -z "$output" ]
}

@test "notes commit: no args requires explicit scope" {
  notes install-hooks --yes
  local before
  before=$(git -C "$NOTES_CALLER_PWD" rev-parse HEAD)
  echo "# Alpha v2" > "$NOTES_CALLER_PWD/notes/alpha.md"

  run notes commit -m "missing scope"
  [ "$status" -ne 0 ]
  [[ "$output" == *"provide note paths or --all"* ]]
  [ "$(git -C "$NOTES_CALLER_PWD" rev-parse HEAD)" = "$before" ]

  run git -C "$NOTES_CALLER_PWD" diff --cached --name-only
  [ -z "$output" ]
}

@test "notes commit: explicit unknown path fails instead of silently committing nothing" {
  notes install-hooks --yes
  local before
  before=$(git -C "$NOTES_CALLER_PWD" rev-parse HEAD)
  echo "# Alpha v2" > "$NOTES_CALLER_PWD/notes/alpha.md"

  run notes commit -m "typo" alhpa.md
  [ "$status" -ne 0 ]
  [[ "$output" == *"requested note path"* ]]
  [[ "$output" == *"alhpa.md"* ]]
  [ "$(git -C "$NOTES_CALLER_PWD" rev-parse HEAD)" = "$before" ]

  run git -C "$NOTES_CALLER_PWD" diff --cached --name-only
  [ -z "$output" ]
}

@test "notes commit: path traversal argument fails instead of silently committing nothing" {
  notes install-hooks --yes
  local before
  before=$(git -C "$NOTES_CALLER_PWD" rev-parse HEAD)
  echo "# Alpha v2" > "$NOTES_CALLER_PWD/notes/alpha.md"
  echo "readme" > "$NOTES_CALLER_PWD/README.md"

  run notes commit -m "traversal" ../README.md
  [ "$status" -ne 0 ]
  [[ "$output" == *"requested note path"* ]]
  [[ "$output" == *"../README.md"* ]]
  [ "$(git -C "$NOTES_CALLER_PWD" rev-parse HEAD)" = "$before" ]

  run git -C "$NOTES_CALLER_PWD" diff --cached --name-only
  [ -z "$output" ]
}

@test "notes commit: refuses pre-staged changes before staging notes" {
  notes install-hooks --yes
  local before
  before=$(git -C "$NOTES_CALLER_PWD" rev-parse HEAD)
  echo "readme" > "$NOTES_CALLER_PWD/README.md"
  git -C "$NOTES_CALLER_PWD" add README.md
  echo "# Alpha v2" > "$NOTES_CALLER_PWD/notes/alpha.md"

  run notes commit --all -m "should refuse"
  [ "$status" -ne 0 ]
  [[ "$output" == *"staged changes already exist"* ]]
  [[ "$output" == *"README.md"* ]]
  [ "$(git -C "$NOTES_CALLER_PWD" rev-parse HEAD)" = "$before" ]

  run git -C "$NOTES_CALLER_PWD" diff --cached --name-only
  [ "$output" = "README.md" ]
}

@test "notes commit: detects non-note paths added by another pre-commit hook" {
  notes install-hooks --yes
  mkdir -p "$NOTES_CALLER_PWD/.git/hooks/pre-commit.d"
  cat > "$NOTES_CALLER_PWD/.git/hooks/pre-commit.d/zz-stage-generated" <<'HOOK'
#!/usr/bin/env bash
set -euo pipefail
printf 'generated by hook\n' > hook-generated.txt
git add hook-generated.txt
HOOK
  chmod +x "$NOTES_CALLER_PWD/.git/hooks/pre-commit.d/zz-stage-generated"
  echo "# Alpha v2" > "$NOTES_CALLER_PWD/notes/alpha.md"

  run notes commit -m "update alpha" alpha.md
  [ "$status" -ne 0 ]
  [[ "$output" == *"included non-note path"* ]]
  [[ "$output" == *"hook-generated.txt"* ]]

  run git -C "$NOTES_CALLER_PWD" show --name-only --format= HEAD
  [[ "$output" == *"hook-generated.txt"* ]]
}

@test "notes commit: refuses missing hooks before staging or committing" {
  local before
  before=$(git -C "$NOTES_CALLER_PWD" rev-parse HEAD)
  echo "# Alpha v2" > "$NOTES_CALLER_PWD/notes/alpha.md"

  run notes commit -m "update alpha" alpha.md
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires installed obfuscation/deobfuscation hooks"* ]]
  [[ "$output" == *"notes install-hooks"* ]]
  [ "$(git -C "$NOTES_CALLER_PWD" rev-parse HEAD)" = "$before" ]

  run git -C "$NOTES_CALLER_PWD" diff --cached --name-only
  [ -z "$output" ]
}

# ── full lifecycle ────────────────────────────────────────────

@test "full cycle: edit → stage → commit → clean status" {
  # Install hooks so post-commit deobfuscates
  source "$REPO_DIR/lib/hooks.sh"
  install_obfuscation_hook
  install_deobfuscation_hook

  # Verify clean status before edit
  run git -C "$NOTES_CALLER_PWD" status --porcelain
  [ -z "$output" ]

  # Edit a note
  echo "# Alpha v2" > "$NOTES_CALLER_PWD/notes/alpha.md"

  # git status should still be clean (exclude hides the change)
  run git -C "$NOTES_CALLER_PWD" status --porcelain
  [ -z "$output" ]

  # But detect_changes should see it
  run detect_changes "$NOTES_CALLER_PWD/notes"
  [[ "$output" == *"modified"*"alpha.md"* ]]

  # Stage via notes stage
  notes stage alpha.md

  # Commit — hooks handle obfuscation + deobfuscation
  git -C "$NOTES_CALLER_PWD" commit -q -m "update alpha"

  # After commit, files should be deobfuscated
  [ -f "$NOTES_CALLER_PWD/notes/alpha.md" ]
  [[ "$(cat "$NOTES_CALLER_PWD/notes/alpha.md")" == *"Alpha v2"* ]]

  # Status should be clean again
  run git -C "$NOTES_CALLER_PWD" status --porcelain
  [ -z "$output" ]

  # No changes detected
  run detect_changes "$NOTES_CALLER_PWD/notes"
  [ -z "$output" ]
}
