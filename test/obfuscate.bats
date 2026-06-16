#!/usr/bin/env bats

load test_helper

setup() {
  export NOTES_CALLER_PWD="$BATS_TEST_TMPDIR"
  mkdir -p "$NOTES_CALLER_PWD/notes"

  # Create test notes
  echo -e "---\ntitle: Alpha\ntags: [test]\n---\n# Alpha" > "$NOTES_CALLER_PWD/notes/alpha.md"
  echo -e "---\ntitle: Beta\ntags: [test]\n---\n# Beta" > "$NOTES_CALLER_PWD/notes/beta.md"
  echo -e "---\ntitle: Gamma\ntags: [test]\n---\n# Gamma" > "$NOTES_CALLER_PWD/notes/gamma.txt"

  # git init and commit so git mv works
  git -C "$NOTES_CALLER_PWD" init -q
  git -C "$NOTES_CALLER_PWD" add -A
  git -C "$NOTES_CALLER_PWD" commit -q -m "init"
}

# --- Core obfuscation ---

@test "obfuscate renames files to hex IDs" {
  run notes obfuscate
  [ "$status" -eq 0 ]
  [[ "$output" == *"Obfuscated 3 file(s)"* ]]

  # Original files should be gone
  [ ! -f "$NOTES_CALLER_PWD/notes/alpha.md" ]
  [ ! -f "$NOTES_CALLER_PWD/notes/beta.md" ]
  [ ! -f "$NOTES_CALLER_PWD/notes/gamma.txt" ]

  # Manifest should exist with 3 entries
  [ -f "$NOTES_CALLER_PWD/notes/.manifest" ]
  [ "$(wc -l < "$NOTES_CALLER_PWD/notes/.manifest" | tr -d ' ')" -eq 3 ]
}

@test "obfuscate creates extensionless files" {
  notes obfuscate

  for f in "$NOTES_CALLER_PWD/notes/"*; do
    [ ! -f "$f" ] && continue
    base=$(basename "$f")
    [[ "$base" != *.* ]]
  done
}

@test "obfuscate generates 8-char hex IDs" {
  notes obfuscate

  while IFS=$'\t' read -r id name; do
    [[ "$id" =~ ^[0-9a-f]{8}$ ]]
  done < "$NOTES_CALLER_PWD/notes/.manifest"
}

@test "obfuscate preserves file content" {
  notes obfuscate

  id=$(grep "alpha.md" "$NOTES_CALLER_PWD/notes/.manifest" | cut -f1)
  [[ "$(cat "$NOTES_CALLER_PWD/notes/$id")" == *"# Alpha"* ]]
}

@test "obfuscate is idempotent" {
  notes obfuscate

  manifest_before=$(cat "$NOTES_CALLER_PWD/notes/.manifest")
  files_before=$(ls "$NOTES_CALLER_PWD/notes/" | sort)

  run notes obfuscate
  [ "$status" -eq 0 ]
  [[ "$output" == *"Nothing to obfuscate"* ]]

  [ "$(cat "$NOTES_CALLER_PWD/notes/.manifest")" = "$manifest_before" ]
  [ "$(ls "$NOTES_CALLER_PWD/notes/" | sort)" = "$files_before" ]
}

@test "obfuscate dry-run shows plan without renaming" {
  run notes obfuscate --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"alpha.md"* ]]

  [ -f "$NOTES_CALLER_PWD/notes/alpha.md" ]
  [ ! -f "$NOTES_CALLER_PWD/notes/.manifest" ]
}

@test "scoped obfuscate dry-run shows existing manifest ID for readable file" {
  notes obfuscate
  alpha_id=$(grep $'\talpha\.md$' "$NOTES_CALLER_PWD/notes/.manifest" | cut -f1)

  notes deobfuscate

  run notes obfuscate --dry-run alpha.md
  [ "$status" -eq 0 ]
  [[ "$output" == *"alpha.md → $alpha_id"* ]]
  [[ "$output" != *"alpha.md → (will be assigned)"* ]]

  [ -f "$NOTES_CALLER_PWD/notes/alpha.md" ]
  [ ! -f "$NOTES_CALLER_PWD/notes/$alpha_id" ]
}

@test "scoped obfuscate dry-run skips already-obfuscated IDs" {
  notes obfuscate
  alpha_id=$(grep $'\talpha\.md$' "$NOTES_CALLER_PWD/notes/.manifest" | cut -f1)

  run notes obfuscate --dry-run "$alpha_id"
  [ "$status" -eq 0 ]
  [[ "$output" != *"$alpha_id"* ]]
  [[ "$output" != *"will be assigned"* ]]

  [ -f "$NOTES_CALLER_PWD/notes/$alpha_id" ]
}

@test "obfuscate handles new files added after initial obfuscation" {
  notes obfuscate

  echo -e "---\ntitle: Delta\n---\n# Delta" > "$NOTES_CALLER_PWD/notes/delta.md"
  git -C "$NOTES_CALLER_PWD" add -A
  git -C "$NOTES_CALLER_PWD" commit -q -m "add delta"

  run notes obfuscate
  [ "$status" -eq 0 ]
  [[ "$output" == *"delta.md"* ]]
  [[ "$output" == *"Obfuscated 1 file(s)"* ]]

  [ "$(wc -l < "$NOTES_CALLER_PWD/notes/.manifest" | tr -d ' ')" -eq 4 ]
  [ ! -f "$NOTES_CALLER_PWD/notes/delta.md" ]
}

# --- Scoped obfuscation from deobfuscated state ---
#
# Regression: scoped `notes obfuscate <file>` used to rebuild the manifest by
# checking which obfuscated IDs exist on disk. In the deobfuscated working
# tree, only the just-obfuscated file's ID is on disk — the rest are readable
# names — so the manifest got truncated to one entry, losing all other
# mappings. The staleness check must treat an entry as live if *either* its
# obfuscated id or its readable name is on disk.

@test "scoped obfuscate from deobfuscated state preserves manifest entries" {
  notes obfuscate
  [ "$(wc -l < "$NOTES_CALLER_PWD/notes/.manifest" | tr -d ' ')" -eq 3 ]
  beta_id=$(grep $'\tbeta\.md$' "$NOTES_CALLER_PWD/notes/.manifest" | cut -f1)
  gamma_id=$(grep $'\tgamma\.txt$' "$NOTES_CALLER_PWD/notes/.manifest" | cut -f1)

  # Drop to deobfuscated state — all files at readable names, none at IDs.
  notes deobfuscate

  # Scoped obfuscate of just one file (simulates the pre-commit hook path).
  run notes obfuscate alpha.md
  [ "$status" -eq 0 ]

  # Manifest must still have all three entries, and beta/gamma must keep their
  # original IDs (stable across the scoped op).
  [ "$(wc -l < "$NOTES_CALLER_PWD/notes/.manifest" | tr -d ' ')" -eq 3 ]
  grep -q $'\talpha\.md$' "$NOTES_CALLER_PWD/notes/.manifest"
  grep -q "^${beta_id}"$'\t''beta\.md$' "$NOTES_CALLER_PWD/notes/.manifest"
  grep -q "^${gamma_id}"$'\t''gamma\.txt$' "$NOTES_CALLER_PWD/notes/.manifest"

  # beta and gamma stay on disk under readable names (scoped op must not touch
  # them).
  [ -f "$NOTES_CALLER_PWD/notes/beta.md" ]
  [ -f "$NOTES_CALLER_PWD/notes/gamma.txt" ]
}

@test "full obfuscate from fully-deobfuscated state preserves manifest entries" {
  notes obfuscate
  [ "$(wc -l < "$NOTES_CALLER_PWD/notes/.manifest" | tr -d ' ')" -eq 3 ]
  alpha_id=$(grep $'\talpha\.md$' "$NOTES_CALLER_PWD/notes/.manifest" | cut -f1)

  notes deobfuscate
  # Full obfuscate with no args — should find all three readable files and
  # restore them to their known IDs without dropping manifest entries.
  run notes obfuscate
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$NOTES_CALLER_PWD/notes/.manifest" | tr -d ' ')" -eq 3 ]
  [ -f "$NOTES_CALLER_PWD/notes/$alpha_id" ]
}

# --- Stale manifest cleanup ---

@test "obfuscate removes stale entries for deleted files" {
  notes obfuscate
  [ "$(wc -l < "$NOTES_CALLER_PWD/notes/.manifest" | tr -d ' ')" -eq 3 ]

  # Delete a file while deobfuscated
  notes deobfuscate
  rm "$NOTES_CALLER_PWD/notes/alpha.md"

  notes obfuscate

  # Manifest should have 2 entries, not 3
  [ "$(wc -l < "$NOTES_CALLER_PWD/notes/.manifest" | tr -d ' ')" -eq 2 ]
  ! grep -q "alpha.md" "$NOTES_CALLER_PWD/notes/.manifest"
}

@test "obfuscate handles renamed files as delete + new" {
  notes obfuscate
  alpha_id=$(grep "alpha.md" "$NOTES_CALLER_PWD/notes/.manifest" | cut -f1)

  notes deobfuscate
  mv "$NOTES_CALLER_PWD/notes/alpha.md" "$NOTES_CALLER_PWD/notes/alpha-v2.md"

  notes obfuscate

  # Old entry gone, new entry present
  ! grep -q "alpha.md" "$NOTES_CALLER_PWD/notes/.manifest"
  grep -q "alpha-v2.md" "$NOTES_CALLER_PWD/notes/.manifest"

  # New file gets a different ID (old one freed)
  new_id=$(grep "alpha-v2.md" "$NOTES_CALLER_PWD/notes/.manifest" | cut -f1)
  [ -f "$NOTES_CALLER_PWD/notes/$new_id" ]
}

# --- Same filename in different subdirectories ---

@test "obfuscate handles same filename in different subdirectories" {
  mkdir -p "$NOTES_CALLER_PWD/notes/a" "$NOTES_CALLER_PWD/notes/b"
  echo -e "---\ntitle: Foo A\n---" > "$NOTES_CALLER_PWD/notes/a/foo.md"
  echo -e "---\ntitle: Foo B\n---" > "$NOTES_CALLER_PWD/notes/b/foo.md"
  git -C "$NOTES_CALLER_PWD" add -A
  git -C "$NOTES_CALLER_PWD" commit -q -m "add same-name files in subdirs"

  notes obfuscate

  # Both should be in manifest with different IDs
  grep -q "a/foo.md" "$NOTES_CALLER_PWD/notes/.manifest"
  grep -q "b/foo.md" "$NOTES_CALLER_PWD/notes/.manifest"

  id_a=$(grep "a/foo.md" "$NOTES_CALLER_PWD/notes/.manifest" | cut -f1)
  id_b=$(grep "b/foo.md" "$NOTES_CALLER_PWD/notes/.manifest" | cut -f1)
  [ "$id_a" != "$id_b" ]

  # Both files exist in notes root
  [ -f "$NOTES_CALLER_PWD/notes/$id_a" ]
  [ -f "$NOTES_CALLER_PWD/notes/$id_b" ]

  # Subdirectories should be gone
  [ ! -d "$NOTES_CALLER_PWD/notes/a" ]
  [ ! -d "$NOTES_CALLER_PWD/notes/b" ]

  # Content preserved
  [[ "$(cat "$NOTES_CALLER_PWD/notes/$id_a")" == *"Foo A"* ]]
  [[ "$(cat "$NOTES_CALLER_PWD/notes/$id_b")" == *"Foo B"* ]]
}

# --- Stable IDs across cycles ---

@test "obfuscate reuses IDs from preserved manifest" {
  notes obfuscate
  manifest_first=$(cat "$NOTES_CALLER_PWD/notes/.manifest")

  notes deobfuscate
  notes obfuscate

  manifest_second=$(cat "$NOTES_CALLER_PWD/notes/.manifest")
  [ "$manifest_first" = "$manifest_second" ]

  # Verify files are actually obfuscated, not just manifest match
  [ ! -f "$NOTES_CALLER_PWD/notes/alpha.md" ]
  [ ! -f "$NOTES_CALLER_PWD/notes/beta.md" ]
  [ ! -f "$NOTES_CALLER_PWD/notes/gamma.txt" ]
}

@test "obfuscate after deobfuscate renames files to their known IDs" {
  notes obfuscate
  alpha_id=$(grep "alpha.md" "$NOTES_CALLER_PWD/notes/.manifest" | cut -f1)

  notes deobfuscate
  [ -f "$NOTES_CALLER_PWD/notes/alpha.md" ]
  [ ! -f "$NOTES_CALLER_PWD/notes/$alpha_id" ]

  notes obfuscate
  [ ! -f "$NOTES_CALLER_PWD/notes/alpha.md" ]
  [ -f "$NOTES_CALLER_PWD/notes/$alpha_id" ]

  # Content survived the round-trip
  [[ "$(cat "$NOTES_CALLER_PWD/notes/$alpha_id")" == *"# Alpha"* ]]
}

# --- Flatten + recurse ---

@test "obfuscate flattens subdirectory files into notes root" {
  mkdir -p "$NOTES_CALLER_PWD/notes/sub"
  echo -e "---\ntitle: Deep\n---\n# Deep" > "$NOTES_CALLER_PWD/notes/sub/deep.md"
  git -C "$NOTES_CALLER_PWD" add -A
  git -C "$NOTES_CALLER_PWD" commit -q -m "add subdir note"

  notes obfuscate

  # Subdirectory should be gone (emptied and cleaned up)
  [ ! -d "$NOTES_CALLER_PWD/notes/sub" ]

  # Manifest should have relative path
  grep -q "sub/deep.md" "$NOTES_CALLER_PWD/notes/.manifest"

  # All files should be in notes root
  while IFS=$'\t' read -r id name; do
    [ -f "$NOTES_CALLER_PWD/notes/$id" ]
  done < "$NOTES_CALLER_PWD/notes/.manifest"
}

@test "obfuscate flattens nested subdirectories" {
  mkdir -p "$NOTES_CALLER_PWD/notes/a/b/c"
  echo -e "---\ntitle: Nested\n---" > "$NOTES_CALLER_PWD/notes/a/b/c/nested.md"
  git -C "$NOTES_CALLER_PWD" add -A
  git -C "$NOTES_CALLER_PWD" commit -q -m "add nested note"

  notes obfuscate

  [ ! -d "$NOTES_CALLER_PWD/notes/a" ]
  grep -q "a/b/c/nested.md" "$NOTES_CALLER_PWD/notes/.manifest"
}

# --- Deobfuscate ---

@test "deobfuscate restores original filenames" {
  notes obfuscate
  run notes deobfuscate
  [ "$status" -eq 0 ]
  [[ "$output" == *"Restored 3 file(s)"* ]]

  [ -f "$NOTES_CALLER_PWD/notes/alpha.md" ]
  [ -f "$NOTES_CALLER_PWD/notes/beta.md" ]
  [ -f "$NOTES_CALLER_PWD/notes/gamma.txt" ]
}

@test "deobfuscate preserves manifest for stable IDs" {
  notes obfuscate
  notes deobfuscate

  [ -f "$NOTES_CALLER_PWD/notes/.manifest" ]
}

@test "deobfuscate recreates subdirectories" {
  mkdir -p "$NOTES_CALLER_PWD/notes/sub"
  echo -e "---\ntitle: Deep\n---\n# Deep" > "$NOTES_CALLER_PWD/notes/sub/deep.md"
  git -C "$NOTES_CALLER_PWD" add -A
  git -C "$NOTES_CALLER_PWD" commit -q -m "add subdir note"

  notes obfuscate
  [ ! -d "$NOTES_CALLER_PWD/notes/sub" ]

  notes deobfuscate
  [ -f "$NOTES_CALLER_PWD/notes/sub/deep.md" ]
  [[ "$(cat "$NOTES_CALLER_PWD/notes/sub/deep.md")" == *"# Deep"* ]]
}

@test "deobfuscate preserves file content" {
  notes obfuscate
  notes deobfuscate

  [[ "$(cat "$NOTES_CALLER_PWD/notes/alpha.md")" == *"# Alpha"* ]]
  [[ "$(cat "$NOTES_CALLER_PWD/notes/gamma.txt")" == *"# Gamma"* ]]
}

@test "deobfuscate fails without manifest" {
  run notes deobfuscate
  [ "$status" -ne 0 ]
  [[ "$output" == *"no manifest found"* ]]
}

@test "deobfuscate dry-run shows plan without renaming" {
  notes obfuscate
  id=$(grep "alpha.md" "$NOTES_CALLER_PWD/notes/.manifest" | cut -f1)

  run notes deobfuscate -- --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"alpha.md"* ]]

  [ -f "$NOTES_CALLER_PWD/notes/$id" ]
}

@test "deobfuscate ignores inherited usage_files without explicit IDs" {
  notes obfuscate
  local alpha_id beta_id gamma_id
  alpha_id=$(grep "alpha.md" "$NOTES_CALLER_PWD/notes/.manifest" | cut -f1)
  beta_id=$(grep "beta.md" "$NOTES_CALLER_PWD/notes/.manifest" | cut -f1)
  gamma_id=$(grep "gamma.txt" "$NOTES_CALLER_PWD/notes/.manifest" | cut -f1)

  usage_files="$alpha_id" run notes deobfuscate -- --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"$alpha_id → alpha.md"* ]]
  [[ "$output" == *"$beta_id → beta.md"* ]]
  [[ "$output" == *"$gamma_id → gamma.txt"* ]]
}

@test "round-trip preserves all content and metadata" {
  notes obfuscate
  notes deobfuscate

  run farts get title "$NOTES_CALLER_PWD/notes/alpha.md"
  [ "$output" = "Alpha" ]

  run farts get title "$NOTES_CALLER_PWD/notes/beta.md"
  [ "$output" = "Beta" ]
}

# --- Pre-commit hook ---

# --- Hook installation ---

@test "install-hooks no-ops for uninitialized plain notes directories" {
  run notes install-hooks --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"No notes manifest found"* ]]
  [[ "$output" == *"notes setup --yes"* ]]

  [ ! -e "$NOTES_CALLER_PWD/.gitattributes" ]
  [ ! -e "$NOTES_CALLER_PWD/.git/hooks/pre-commit" ]
  [ ! -d "$NOTES_CALLER_PWD/.git/hooks/pre-commit.d" ]
  [ -z "$(git -C "$NOTES_CALLER_PWD" config --get merge.manifest.driver || true)" ]
}

@test "install-hooks refuses without confirmation in headless context" {
  notes obfuscate

  run without_confirmation "$BATS_TEST_TMPDIR/missing-tty" notes install-hooks

  [ "$status" -eq 2 ]
  [[ "$output" == *"confirmation required"* ]]
  [[ "$output" == *"Re-run with --yes"* ]]

  # Hooks should not be installed
  [ ! -x "$NOTES_CALLER_PWD/.git/hooks/pre-commit" ]
  [ ! -d "$NOTES_CALLER_PWD/.git/hooks/pre-commit.d" ]
}

@test "install-hooks --yes proceeds with hook installation" {
  notes obfuscate

  run notes install-hooks --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"Installed hooks"* ]]

  # Verify hooks were actually installed
  [ -x "$NOTES_CALLER_PWD/.git/hooks/pre-commit" ]
  grep -q "Generic hook dispatcher" "$NOTES_CALLER_PWD/.git/hooks/pre-commit"
}

@test "install-hooks installs pre-commit hooks" {
  notes obfuscate
  notes install-hooks --yes

  [ -x "$NOTES_CALLER_PWD/.git/hooks/pre-commit" ]
  grep -q "Generic hook dispatcher" "$NOTES_CALLER_PWD/.git/hooks/pre-commit"
  [ -x "$NOTES_CALLER_PWD/.git/hooks/pre-commit.d/encryption" ]
  grep -q "git-crypt status" "$NOTES_CALLER_PWD/.git/hooks/pre-commit.d/encryption"
  [ -x "$NOTES_CALLER_PWD/.git/hooks/pre-commit.d/obfuscation" ]
  grep -q "manifest" "$NOTES_CALLER_PWD/.git/hooks/pre-commit.d/obfuscation"
}

@test "encryption pre-commit hook rejects plaintext staged encrypted blobs" {
  if ! command -v git-crypt >/dev/null; then
    skip "git-crypt not installed"
  fi

  ( cd "$NOTES_CALLER_PWD" && git-crypt init >/dev/null 2>&1 ) || skip "git-crypt init failed"
  echo "notes/** filter=git-crypt diff=git-crypt" > "$NOTES_CALLER_PWD/.gitattributes"
  git -C "$NOTES_CALLER_PWD" add .gitattributes
  git -C "$NOTES_CALLER_PWD" commit -q --no-verify -m "enable encryption"

  notes install-hooks --yes

  local blob
  blob=$(printf 'aaa00001\talpha.md\n' | git -C "$NOTES_CALLER_PWD" hash-object -w --stdin)
  git -C "$NOTES_CALLER_PWD" update-index --add --cacheinfo 100644 "$blob" notes/.manifest

  run git -C "$NOTES_CALLER_PWD" commit -m "force plaintext manifest"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Staged files should be encrypted but are plaintext"* ]]
  [[ "$output" == *"notes/.manifest"* ]]
}

@test "deobfuscate does not install hooks" {
  notes obfuscate
  git -C "$NOTES_CALLER_PWD" add -A
  git -C "$NOTES_CALLER_PWD" commit -q --no-verify -m "obfuscate"

  notes deobfuscate

  [ ! -d "$NOTES_CALLER_PWD/.git/hooks/pre-commit.d" ]
}

@test "deobfuscate dry-run does not install hook" {
  notes obfuscate
  git -C "$NOTES_CALLER_PWD" add -A
  git -C "$NOTES_CALLER_PWD" commit -q --no-verify -m "obfuscate"

  notes deobfuscate -- --dry-run

  [ ! -d "$NOTES_CALLER_PWD/.git/hooks/pre-commit.d" ]
}

@test "dispatcher runs all hooks in pre-commit.d" {
  # Set up dispatcher with two hooks — one passes, one would fail
  mkdir -p "$NOTES_CALLER_PWD/.git/hooks/pre-commit.d"
  cat > "$NOTES_CALLER_PWD/.git/hooks/pre-commit" <<'EOF'
#!/usr/bin/env bash
set -eo pipefail
HOOK_DIR="$(dirname "$0")/pre-commit.d"
for hook in "$HOOK_DIR"/*; do
  [ -x "$hook" ] && "$hook" || exit $?
done
EOF
  chmod +x "$NOTES_CALLER_PWD/.git/hooks/pre-commit"

  # Hook that passes
  echo '#!/usr/bin/env bash' > "$NOTES_CALLER_PWD/.git/hooks/pre-commit.d/pass"
  echo 'exit 0' >> "$NOTES_CALLER_PWD/.git/hooks/pre-commit.d/pass"
  chmod +x "$NOTES_CALLER_PWD/.git/hooks/pre-commit.d/pass"

  # Hook that fails
  echo '#!/usr/bin/env bash' > "$NOTES_CALLER_PWD/.git/hooks/pre-commit.d/fail"
  echo 'echo "blocked" >&2; exit 1' >> "$NOTES_CALLER_PWD/.git/hooks/pre-commit.d/fail"
  chmod +x "$NOTES_CALLER_PWD/.git/hooks/pre-commit.d/fail"

  echo "test" > "$NOTES_CALLER_PWD/notes/test-file.md"
  git -C "$NOTES_CALLER_PWD" add notes/test-file.md

  run git -C "$NOTES_CALLER_PWD" commit -m "should fail"
  [ "$status" -ne 0 ]
  [[ "$output" == *"blocked"* ]]
}

# --- Pre-commit hook behavior ---

# These tests exercise the pre-commit hook directly. Auto-obfuscate is the
# default hook mode; using `git commit` during setup would fire the hook and
# obfuscate files behind the test's back, leaving nothing for the explicit
# `notes obfuscate` step to do. Use --no-verify on setup commits to keep the
# tests in control of when obfuscation happens.

@test "pre-commit hook rejects un-obfuscated files in guard mode" {
  notes setup --yes
  git -C "$NOTES_CALLER_PWD" add -A
  git -C "$NOTES_CALLER_PWD" commit --no-verify -q -m "setup"

  notes obfuscate
  git -C "$NOTES_CALLER_PWD" add -A
  git -C "$NOTES_CALLER_PWD" commit --no-verify -q -m "obfuscated"

  echo -e "---\ntitle: Sneaky\n---\n# Sneaky" > "$NOTES_CALLER_PWD/notes/sneaky.md"
  git -C "$NOTES_CALLER_PWD" add notes/sneaky.md

  NOTES_OBFUSCATE_HOOK=guard run git -C "$NOTES_CALLER_PWD" commit -m "should fail"
  [ "$status" -ne 0 ]
  [[ "$output" == *"non-obfuscated filenames"* ]]
  [[ "$output" == *"sneaky.md"* ]]
}

@test "pre-commit hook allows obfuscated files" {
  notes setup --yes
  git -C "$NOTES_CALLER_PWD" add -A
  git -C "$NOTES_CALLER_PWD" commit --no-verify -q -m "setup"

  notes obfuscate
  git -C "$NOTES_CALLER_PWD" add -A

  run git -C "$NOTES_CALLER_PWD" commit -m "should succeed"
  [ "$status" -eq 0 ]
}

@test "pre-commit hook rejects staged renames in guard mode" {
  notes setup --yes
  git -C "$NOTES_CALLER_PWD" add -A
  git -C "$NOTES_CALLER_PWD" commit --no-verify -q -m "setup"

  notes obfuscate
  git -C "$NOTES_CALLER_PWD" add -A
  git -C "$NOTES_CALLER_PWD" commit --no-verify -q -m "obfuscated"

  # After committing the obfuscated state, the post-commit hook
  # deobfuscates the working tree and adds readable names to
  # .git/info/exclude (clean-status mechanism from notes#43). A plain
  # `git add notes/` now no-ops. To simulate someone trying to stage a
  # deobfuscated rename anyway, we force-add the readable name.
  git -C "$NOTES_CALLER_PWD" add -f notes/alpha.md

  # The hook should reject this in guard mode
  NOTES_OBFUSCATE_HOOK=guard run git -C "$NOTES_CALLER_PWD" commit -m "should fail"
  [ "$status" -ne 0 ]
  [[ "$output" == *"non-obfuscated filenames"* ]]
  [[ "$output" == *"alpha.md"* ]]
}

@test "pre-commit hook auto-obfuscates by default" {
  # Obfuscate and commit the obfuscated state
  notes obfuscate
  git -C "$NOTES_CALLER_PWD" add -A
  git -C "$NOTES_CALLER_PWD" commit -q --no-verify -m "obfuscated"

  # Deobfuscate + install hooks explicitly
  notes deobfuscate
  notes install-hooks --yes

  # Add a new deobfuscated file + stage everything
  echo -e "---\ntitle: Sneaky\n---\n# Sneaky" > "$NOTES_CALLER_PWD/notes/sneaky.md"
  git -C "$NOTES_CALLER_PWD" add -A

  # Should succeed — hook auto-obfuscates before commit
  run git -C "$NOTES_CALLER_PWD" commit -m "should succeed"
  [ "$status" -eq 0 ]

  # The committed tree should have obfuscated filenames
  # (post-commit hook deobfuscates the working tree, so check git not disk)
  local committed_files
  committed_files=$(git -C "$NOTES_CALLER_PWD" show --name-only --format='' HEAD -- notes/)
  ! echo "$committed_files" | grep -q "alpha.md"
  ! echo "$committed_files" | grep -q "sneaky.md"

  # Manifest should have all entries
  grep -q "sneaky.md" "$NOTES_CALLER_PWD/notes/.manifest"
  grep -q "alpha.md" "$NOTES_CALLER_PWD/notes/.manifest"
}

@test "installed hooks run notes from installer, not PATH" {
  notes obfuscate
  git -C "$NOTES_CALLER_PWD" add -A
  git -C "$NOTES_CALLER_PWD" commit -q --no-verify -m "obfuscated"

  notes deobfuscate
  notes install-hooks --yes
  git -C "$NOTES_CALLER_PWD" add .gitattributes
  git -C "$NOTES_CALLER_PWD" commit -q --no-verify -m "install hook attributes"

  local fake_bin
  fake_bin="$BATS_TEST_TMPDIR/fake-bin"
  mkdir -p "$fake_bin"
  cat > "$fake_bin/notes" <<'EOT'
#!/usr/bin/env bash
echo "fake notes invoked: $*" >&2
exit 99
EOT
  chmod +x "$fake_bin/notes"

  echo "change" >> "$NOTES_CALLER_PWD/notes/alpha.md"
  git -C "$NOTES_CALLER_PWD" add -f notes/alpha.md

  run bash -c 'unset -f notes; PATH="$1:$PATH" git -C "$2" commit -m "edit alpha"' _ "$fake_bin" "$NOTES_CALLER_PWD"
  [ "$status" -eq 0 ]
  [[ "$output" != *"fake notes invoked"* ]]
}

# --- Post-commit hook ---

@test "install-hooks installs post-commit deobfuscation hook" {
  notes obfuscate
  notes install-hooks --yes

  [ -x "$NOTES_CALLER_PWD/.git/hooks/post-commit" ]
  grep -q "Generic hook dispatcher" "$NOTES_CALLER_PWD/.git/hooks/post-commit"
  [ -x "$NOTES_CALLER_PWD/.git/hooks/post-commit.d/deobfuscation" ]
  grep -q "manifest" "$NOTES_CALLER_PWD/.git/hooks/post-commit.d/deobfuscation"
}

@test "post-commit hook deobfuscates working tree after commit" {
  # Obfuscate and commit initial state
  notes obfuscate
  git -C "$NOTES_CALLER_PWD" add -A
  git -C "$NOTES_CALLER_PWD" commit -q --no-verify -m "obfuscated"

  # Deobfuscate + install hooks explicitly
  notes deobfuscate
  notes install-hooks --yes

  # Add a new file and commit — hooks should handle the round-trip
  echo -e "---\ntitle: New Note\n---\n# New" > "$NOTES_CALLER_PWD/notes/new-note.md"
  git -C "$NOTES_CALLER_PWD" add notes/new-note.md
  git -C "$NOTES_CALLER_PWD" commit -m "add new note"

  # Working tree should have readable filenames (post-commit deobfuscated)
  [ -f "$NOTES_CALLER_PWD/notes/alpha.md" ]
  [ -f "$NOTES_CALLER_PWD/notes/beta.md" ]
  [ -f "$NOTES_CALLER_PWD/notes/gamma.txt" ]
  [ -f "$NOTES_CALLER_PWD/notes/new-note.md" ]

  # Committed tree should have obfuscated filenames
  local committed_files
  committed_files=$(git -C "$NOTES_CALLER_PWD" show --name-only --format='' HEAD -- notes/)
  ! echo "$committed_files" | grep -q "alpha.md"
  ! echo "$committed_files" | grep -q "new-note.md"
}

@test "post-commit hook preserves file content after round-trip" {
  notes obfuscate
  git -C "$NOTES_CALLER_PWD" add -A
  git -C "$NOTES_CALLER_PWD" commit -q --no-verify -m "obfuscated"

  notes deobfuscate
  notes install-hooks --yes

  echo -e "---\ntitle: Fresh\n---\n# Fresh content" > "$NOTES_CALLER_PWD/notes/fresh.md"
  git -C "$NOTES_CALLER_PWD" add notes/fresh.md
  git -C "$NOTES_CALLER_PWD" commit -m "add fresh"

  # Content should survive the obfuscate→deobfuscate round-trip
  [[ "$(cat "$NOTES_CALLER_PWD/notes/alpha.md")" == *"# Alpha"* ]]
  [[ "$(cat "$NOTES_CALLER_PWD/notes/fresh.md")" == *"# Fresh content"* ]]
}

@test "post-commit hook is no-op when files are not obfuscated" {
  # Install hooks — no manifest exists, so hooks should be no-ops
  notes install-hooks --yes

  # Commit should succeed even though post-commit hook exists
  echo "change" >> "$NOTES_CALLER_PWD/notes/alpha.md"
  git -C "$NOTES_CALLER_PWD" add -A
  run git -C "$NOTES_CALLER_PWD" commit -m "should work fine"
  [ "$status" -eq 0 ]
}

# --- Bash 3.2 compatibility ---

@test "obfuscate works without associative arrays (bash 3.2)" {
  # Verify no declare -A in task scripts or hook templates
  ! grep -q 'declare -A' "$REPO_DIR/.mise/tasks/obfuscate"
  ! grep -q 'declare -A' "$REPO_DIR/.mise/tasks/deobfuscate"
  ! grep -q 'declare -A' "$REPO_DIR/hooks/obfuscation.template"
  ! grep -q 'declare -A' "$REPO_DIR/hooks/post-commit-deobfuscate.template"
}

@test "obfuscate succeeds with single file" {
  # Minimal case — catches set -e failures in manifest lookups
  rm "$NOTES_CALLER_PWD/notes/beta.md" "$NOTES_CALLER_PWD/notes/gamma.txt"
  git -C "$NOTES_CALLER_PWD" add -A
  git -C "$NOTES_CALLER_PWD" commit -q -m "remove extras"

  run notes obfuscate
  [ "$status" -eq 0 ]
  [[ "$output" == *"Obfuscated 1 file(s)"* ]]
}

@test "pre-commit hook allows commits when no manifest exists" {
  notes setup --yes
  git -C "$NOTES_CALLER_PWD" add -A
  git -C "$NOTES_CALLER_PWD" commit -q -m "setup"

  echo -e "---\ntitle: Normal\n---" > "$NOTES_CALLER_PWD/notes/normal.md"
  git -C "$NOTES_CALLER_PWD" add notes/normal.md

  run git -C "$NOTES_CALLER_PWD" commit -m "should succeed"
  [ "$status" -eq 0 ]
}

# --- deobfuscate never stages ---

@test "deobfuscate restores names without staging" {
  notes obfuscate
  git -C "$NOTES_CALLER_PWD" add -A
  git -C "$NOTES_CALLER_PWD" commit -q --no-verify -m "obfuscated"

  notes deobfuscate

  # Working tree has readable names
  [ -f "$NOTES_CALLER_PWD/notes/alpha.md" ]
  [ -f "$NOTES_CALLER_PWD/notes/beta.md" ]

  # Index is clean (no staged changes)
  local staged
  staged=$(git -C "$NOTES_CALLER_PWD" diff --cached --name-status)
  [ -z "$staged" ]
}

@test "obfuscate works when working tree is deobfuscated but index has obfuscated names" {
  # This is the state after deobfuscate
  notes obfuscate
  git -C "$NOTES_CALLER_PWD" add -A
  git -C "$NOTES_CALLER_PWD" commit -q --no-verify -m "obfuscated"
  notes deobfuscate

  # Now obfuscate should restore obfuscated names and stage them
  run notes obfuscate
  [ "$status" -eq 0 ]

  # All files should be obfuscated on disk
  [ ! -f "$NOTES_CALLER_PWD/notes/alpha.md" ]
  [ ! -f "$NOTES_CALLER_PWD/notes/beta.md" ]

  # Manifest entries should use the same IDs (stable)
  local id_alpha id_beta
  id_alpha=$(grep 'alpha.md' "$NOTES_CALLER_PWD/notes/.manifest" | cut -f1)
  id_beta=$(grep 'beta.md' "$NOTES_CALLER_PWD/notes/.manifest" | cut -f1)
  [ -f "$NOTES_CALLER_PWD/notes/$id_alpha" ]
  [ -f "$NOTES_CALLER_PWD/notes/$id_beta" ]
}

@test "full commit cycle: deobfuscated working tree stays clean" {
  # Set up obfuscated repo with hooks
  notes obfuscate
  git -C "$NOTES_CALLER_PWD" add -A
  git -C "$NOTES_CALLER_PWD" commit -q --no-verify -m "obfuscated"
  notes deobfuscate
  notes install-hooks --yes

  # Edit a file and commit via hooks
  echo "edited" >> "$NOTES_CALLER_PWD/notes/alpha.md"
  notes stage alpha.md
  run git -C "$NOTES_CALLER_PWD" commit -m "edit alpha"
  [ "$status" -eq 0 ]

  # Committed tree should have obfuscated names
  local committed_files
  committed_files=$(git -C "$NOTES_CALLER_PWD" show --name-only --format='' HEAD -- notes/)
  ! echo "$committed_files" | grep -q "alpha.md"

  # Working tree should have readable names (post-commit deobfuscated)
  [ -f "$NOTES_CALLER_PWD/notes/alpha.md" ]
  [[ "$(cat "$NOTES_CALLER_PWD/notes/alpha.md")" == *"edited"* ]]

  # Index should be clean
  local staged
  staged=$(git -C "$NOTES_CALLER_PWD" diff --cached --name-status)
  [ -z "$staged" ]
}

@test "post-commit hook preserves valid manifest order during scoped obfuscation" {
  notes obfuscate

  local alpha_id beta_id gamma_id
  alpha_id=$(grep $'\talpha\.md$' "$NOTES_CALLER_PWD/notes/.manifest" | cut -f1)
  beta_id=$(grep $'\tbeta\.md$' "$NOTES_CALLER_PWD/notes/.manifest" | cut -f1)
  gamma_id=$(grep $'\tgamma\.txt$' "$NOTES_CALLER_PWD/notes/.manifest" | cut -f1)

  # Simulate a historical valid manifest whose order differs from the current
  # name sort. Scoped pre-commit obfuscation should not create an order-only
  # dirty worktree by normalizing unrelated manifest order.
  printf '%s\tgamma.txt\n%s\talpha.md\n%s\tbeta.md\n' \
    "$gamma_id" "$alpha_id" "$beta_id" > "$NOTES_CALLER_PWD/notes/.manifest"
  git -C "$NOTES_CALLER_PWD" add -A
  git -C "$NOTES_CALLER_PWD" commit -q --no-verify -m "obfuscated unsorted manifest"

  notes deobfuscate
  notes install-hooks --yes
  git -C "$NOTES_CALLER_PWD" add .gitattributes
  git -C "$NOTES_CALLER_PWD" commit -q --no-verify -m "install hook attributes"
  [ -z "$(git -C "$NOTES_CALLER_PWD" status --short)" ]

  echo "edited" >> "$NOTES_CALLER_PWD/notes/alpha.md"
  notes stage alpha.md
  run git -C "$NOTES_CALLER_PWD" commit -m "edit alpha"
  [ "$status" -eq 0 ]

  [ -z "$(git -C "$NOTES_CALLER_PWD" status --short)" ]
}

# --- Post-merge hook ---

@test "install-hooks installs post-merge deobfuscation hook" {
  notes obfuscate
  notes install-hooks --yes

  [ -x "$NOTES_CALLER_PWD/.git/hooks/post-merge" ]
  grep -q "Generic hook dispatcher" "$NOTES_CALLER_PWD/.git/hooks/post-merge"
  [ -x "$NOTES_CALLER_PWD/.git/hooks/post-merge.d/deobfuscation" ]
  grep -q "manifest" "$NOTES_CALLER_PWD/.git/hooks/post-merge.d/deobfuscation"
  grep -q "NOTES_DEOBFUSCATE_BASE_REF=ORIG_HEAD" "$NOTES_CALLER_PWD/.git/hooks/post-merge.d/deobfuscation"
}

# --- Scoped obfuscation (variadic args) ---

@test "obfuscate with args only processes specified files" {
  notes obfuscate alpha.md beta.md

  # Specified files should be obfuscated
  [ ! -f "$NOTES_CALLER_PWD/notes/alpha.md" ]
  [ ! -f "$NOTES_CALLER_PWD/notes/beta.md" ]

  # Unspecified file should remain
  [ -f "$NOTES_CALLER_PWD/notes/gamma.txt" ]

  # Manifest should have entries for obfuscated files
  grep -q "alpha.md" "$NOTES_CALLER_PWD/notes/.manifest"
  grep -q "beta.md" "$NOTES_CALLER_PWD/notes/.manifest"
}

@test "obfuscate with args handles notes-dir prefix" {
  notes obfuscate notes/alpha.md

  [ ! -f "$NOTES_CALLER_PWD/notes/alpha.md" ]
  [ -f "$NOTES_CALLER_PWD/notes/beta.md" ]
  [ -f "$NOTES_CALLER_PWD/notes/gamma.txt" ]
}

@test "obfuscate with args re-obfuscates known files" {
  # First obfuscate all, then deobfuscate
  notes obfuscate
  git -C "$NOTES_CALLER_PWD" add -A
  git -C "$NOTES_CALLER_PWD" commit -q --no-verify -m "obfuscated"
  notes deobfuscate

  # Re-obfuscate only one file
  notes obfuscate alpha.md

  # alpha should be obfuscated, others still readable
  [ ! -f "$NOTES_CALLER_PWD/notes/alpha.md" ]
  [ -f "$NOTES_CALLER_PWD/notes/beta.md" ]
  [ -f "$NOTES_CALLER_PWD/notes/gamma.txt" ]

  # ID should be stable (same as manifest)
  local id_alpha
  id_alpha=$(grep 'alpha.md' "$NOTES_CALLER_PWD/notes/.manifest" | cut -f1)
  [ -f "$NOTES_CALLER_PWD/notes/$id_alpha" ]
}

@test "deobfuscate with args only processes specified IDs" {
  notes obfuscate

  local id_alpha
  id_alpha=$(grep 'alpha.md' "$NOTES_CALLER_PWD/notes/.manifest" | cut -f1)

  notes deobfuscate "$id_alpha"

  # alpha should be restored
  [ -f "$NOTES_CALLER_PWD/notes/alpha.md" ]

  # Others should remain obfuscated
  local id_beta
  id_beta=$(grep 'beta.md' "$NOTES_CALLER_PWD/notes/.manifest" | cut -f1)
  [ -f "$NOTES_CALLER_PWD/notes/$id_beta" ]
}

@test "deobfuscate with args warns on unknown ID" {
  notes obfuscate

  run notes deobfuscate nonexistent123
  [ "$status" -eq 0 ]
  [[ "$output" == *"Nothing to deobfuscate"* ]] || [[ "$output" == *"Warning: unknown"* ]]
}

@test "deobfuscate scoped sets assume-unchanged only on deobfuscated IDs" {
  notes obfuscate
  git -C "$NOTES_CALLER_PWD" add -A
  git -C "$NOTES_CALLER_PWD" commit -q --no-verify -m "obfuscated"

  local alpha_id beta_id
  alpha_id=$(grep "alpha.md" "$NOTES_CALLER_PWD/notes/.manifest" | cut -f1)
  beta_id=$(grep "beta.md" "$NOTES_CALLER_PWD/notes/.manifest" | cut -f1)

  # Deobfuscate only alpha
  notes deobfuscate "$alpha_id"

  # alpha's obfuscated ID should be assume-unchanged
  run git -C "$NOTES_CALLER_PWD" ls-files -v "notes/$alpha_id"
  [[ "$output" == h* ]]

  # beta's obfuscated ID should NOT be assume-unchanged (still tracked normally)
  run git -C "$NOTES_CALLER_PWD" ls-files -v "notes/$beta_id"
  [[ "$output" == H* ]]
}

@test "pre-commit hook only obfuscates staged files" {
  # Set up: obfuscate, commit, then deobfuscate + install hooks
  notes obfuscate
  git -C "$NOTES_CALLER_PWD" add -A
  git -C "$NOTES_CALLER_PWD" commit -q --no-verify -m "obfuscated"
  notes deobfuscate
  notes install-hooks --yes
  # Working tree: readable names. Index: obfuscated names matching HEAD.

  # Edit one file, stage only that one
  echo "change" >> "$NOTES_CALLER_PWD/notes/alpha.md"
  git -C "$NOTES_CALLER_PWD" add -f notes/alpha.md

  # Capture stderr from commit (hooks print rename operations there)
  local stderr_log="$BATS_TEST_TMPDIR/commit-stderr"
  git -C "$NOTES_CALLER_PWD" commit -m "edit one file" 2>"$stderr_log"

  cat "$stderr_log" >&2

  # Count how many files the pre-commit hook obfuscated
  local obfuscated_count
  obfuscated_count=$(sed -n 's/.*Auto-obfuscating \([0-9]*\) file.*/\1/p' "$stderr_log")
  echo "auto-obfuscated: ${obfuscated_count:-none}" >&2

  # Should obfuscate exactly 1 file (the staged one)
  [ -n "$obfuscated_count" ]
  [ "$obfuscated_count" -eq 1 ]
}

@test "deobfuscate trusts existing readable when no state file (upgrade/fresh-clone path)" {
  # Regression: notes#59 finding 1. Before this fix, the first deobfuscate
  # after upgrading to the dirty-protection version would refuse every
  # readable that differs from its obfuscated source -- because no state
  # file existed yet, so every base_hash lookup returned empty, which the
  # check treated as dirty. That forced users straight to --force on first
  # run, training them to bypass the protection forever.
  notes obfuscate
  local alpha_id
  alpha_id=$(grep "alpha.md" "$NOTES_CALLER_PWD/notes/.manifest" | cut -f1)
  [ -f "$NOTES_CALLER_PWD/notes/$alpha_id" ]

  # Simulate a pre-fix clone: a stale readable on disk, no state file.
  echo "stale readable from before the upgrade" > "$NOTES_CALLER_PWD/notes/alpha.md"
  rm -f "$NOTES_CALLER_PWD/.git/info/notes-obfuscation-state"

  run notes deobfuscate
  [ "$status" -eq 0 ]
  # The readable was overwritten with the obfuscated content (the protection
  # is opt-in only after the state file exists; on the upgrade run we trust
  # the existing readable so users don't get force-prompted on every file).
  [[ "$(cat "$NOTES_CALLER_PWD/notes/alpha.md")" == *"# Alpha"* ]]
  # And the very next deobfuscate is now protected -- the state file got
  # written on this run.
  [ -f "$NOTES_CALLER_PWD/.git/info/notes-obfuscation-state" ]
  grep -q "^${alpha_id}"$'\t' "$NOTES_CALLER_PWD/.git/info/notes-obfuscation-state"
}

@test "deobfuscate refuses dirty readable note with recorded base hash" {
  notes obfuscate
  local alpha_id
  alpha_id=$(grep "alpha.md" "$NOTES_CALLER_PWD/notes/.manifest" | cut -f1)
  git -C "$NOTES_CALLER_PWD" add -A notes
  git -C "$NOTES_CALLER_PWD" commit -q -m "obfuscate"

  notes deobfuscate
  echo "local edit" >> "$NOTES_CALLER_PWD/notes/alpha.md"

  # Simulate unlock/pull restoring the obfuscated source while the readable
  # file still exists with local edits.
  git -C "$NOTES_CALLER_PWD" update-index --no-assume-unchanged "notes/$alpha_id" 2>/dev/null || true
  git -C "$NOTES_CALLER_PWD" checkout -- "notes/$alpha_id"

  run notes deobfuscate
  [ "$status" -ne 0 ]
  [[ "$output" == *"refusing to overwrite dirty readable note"* ]]
  [[ "$(cat "$NOTES_CALLER_PWD/notes/alpha.md")" == *"local edit"* ]]
  [ -f "$NOTES_CALLER_PWD/notes/$alpha_id" ]
}

@test "deobfuscate refreshes clean stale readable when state row is missing but base ref matches" {
  notes obfuscate
  local alpha_id base_ref state
  alpha_id=$(grep "alpha.md" "$NOTES_CALLER_PWD/notes/.manifest" | cut -f1)
  git -C "$NOTES_CALLER_PWD" add -A notes
  git -C "$NOTES_CALLER_PWD" commit -q -m "obfuscate v1"
  base_ref=$(git -C "$NOTES_CALLER_PWD" rev-parse HEAD)

  notes deobfuscate
  state="$NOTES_CALLER_PWD/.git/info/notes-obfuscation-state"
  [ -f "$state" ]

  echo "# Alpha v2" > "$NOTES_CALLER_PWD/notes/alpha.md"
  notes obfuscate alpha.md
  git -C "$NOTES_CALLER_PWD" commit -q -m "obfuscate v2"

  # Simulate a partial/old state file after pull: alpha.md is still the clean
  # pre-merge readable, the new obfuscated source is present, but alpha's state
  # row is missing. ORIG_HEAD/base-ref should prove the readable is safe to
  # refresh instead of treating it as a local edit.
  git -C "$NOTES_CALLER_PWD" cat-file --filters "$base_ref:notes/$alpha_id" > "$NOTES_CALLER_PWD/notes/alpha.md"
  grep -v "^${alpha_id}"$'\t' "$state" > "$state.tmp"
  mv "$state.tmp" "$state"

  NOTES_DEOBFUSCATE_BASE_REF="$base_ref" run notes deobfuscate
  [ "$status" -eq 0 ]
  [[ "$(cat "$NOTES_CALLER_PWD/notes/alpha.md")" == *"# Alpha v2"* ]]
  [ ! -f "$NOTES_CALLER_PWD/notes/$alpha_id" ]
  grep -q "^${alpha_id}"$'\t' "$state"
}

@test "deobfuscate --force intentionally overwrites dirty readable note" {
  notes obfuscate
  local alpha_id
  alpha_id=$(grep "alpha.md" "$NOTES_CALLER_PWD/notes/.manifest" | cut -f1)
  [ -f "$NOTES_CALLER_PWD/notes/$alpha_id" ]

  echo "local edit" > "$NOTES_CALLER_PWD/notes/alpha.md"

  run notes deobfuscate -- --force
  [ "$status" -eq 0 ]

  [ -f "$NOTES_CALLER_PWD/notes/alpha.md" ]
  [[ "$(cat "$NOTES_CALLER_PWD/notes/alpha.md")" == *"# Alpha"* ]]
  [[ "$(cat "$NOTES_CALLER_PWD/notes/alpha.md")" != *"local edit"* ]]
}

@test "deobfuscate ignores inherited usage_force without explicit --force" {
  notes obfuscate
  local alpha_id
  alpha_id=$(grep "alpha.md" "$NOTES_CALLER_PWD/notes/.manifest" | cut -f1)
  git -C "$NOTES_CALLER_PWD" add -A notes
  git -C "$NOTES_CALLER_PWD" commit -q -m "obfuscate"

  notes deobfuscate
  echo "local edit" >> "$NOTES_CALLER_PWD/notes/alpha.md"
  git -C "$NOTES_CALLER_PWD" update-index --no-assume-unchanged "notes/$alpha_id" 2>/dev/null || true
  git -C "$NOTES_CALLER_PWD" checkout -- "notes/$alpha_id"

  usage_force=true run notes deobfuscate
  [ "$status" -ne 0 ]
  [[ "$output" == *"refusing to overwrite dirty readable note"* ]]
  [[ "$(cat "$NOTES_CALLER_PWD/notes/alpha.md")" == *"local edit"* ]]
}

@test "deobfuscate allows identical readable note copy" {
  notes obfuscate
  local alpha_id
  alpha_id=$(grep "alpha.md" "$NOTES_CALLER_PWD/notes/.manifest" | cut -f1)
  [ -f "$NOTES_CALLER_PWD/notes/$alpha_id" ]

  cp "$NOTES_CALLER_PWD/notes/$alpha_id" "$NOTES_CALLER_PWD/notes/alpha.md"

  run notes deobfuscate
  [ "$status" -eq 0 ]
  [ -f "$NOTES_CALLER_PWD/notes/alpha.md" ]
  [[ "$(cat "$NOTES_CALLER_PWD/notes/alpha.md")" == *"# Alpha"* ]]
}

@test "deobfuscate records state for files renamed before mid-batch refusal" {
  # Regression: notes#59 finding 2. rename_to_readable aborts on the first
  # dirty file in a batch, but files renamed *before* that point are already
  # moved on disk. Pre-fix, the deobfuscate task exit'd on rc != 0 before
  # recording state, so those successfully-renamed files had no recorded base
  # hash -- and the next post-pull update of any of them would be refused
  # without --force, even though the user did nothing wrong.
  notes obfuscate
  local alpha_id beta_id
  alpha_id=$(grep "alpha.md" "$NOTES_CALLER_PWD/notes/.manifest" | cut -f1)
  beta_id=$(grep "beta.md"  "$NOTES_CALLER_PWD/notes/.manifest" | cut -f1)
  git -C "$NOTES_CALLER_PWD" add -A notes
  git -C "$NOTES_CALLER_PWD" commit -q -m "obfuscate"

  # Establish state-file invariant for both files.
  notes deobfuscate
  local state="$NOTES_CALLER_PWD/.git/info/notes-obfuscation-state"
  [ -f "$state" ]

  # Snapshot the count of rows for alpha_id BEFORE the partial-failure run.
  # Pre-fix the task exit'd before re-recording, so this count would not
  # change after the partial-failure run; post-fix it must increment.
  # (Asserting a row simply *exists* would not catch the regression -- the
  # row from this first deobfuscate is already present either way.)
  local alpha_rows_before
  alpha_rows_before=$(grep -c "^${alpha_id}"$'\t' "$state" || true)
  [ "$alpha_rows_before" -eq 1 ]

  # Dirty beta and restore the obfuscated source for both, simulating a pull
  # that brings back the obfuscated form alongside the dirty readable.
  echo "local edit on beta" > "$NOTES_CALLER_PWD/notes/beta.md"
  git -C "$NOTES_CALLER_PWD" update-index --no-assume-unchanged "notes/$alpha_id" "notes/$beta_id" 2>/dev/null || true
  git -C "$NOTES_CALLER_PWD" checkout -- "notes/$alpha_id" "notes/$beta_id"
  # Now alpha.md is up-to-date but the obfuscated source has been re-restored;
  # beta has a dirty readable that should refuse.

  # Remove the alpha readable so the rename re-creates it from scratch (cmp -s
  # mismatch triggers the rename path); beta refuses on the dirty check.
  rm -f "$NOTES_CALLER_PWD/notes/alpha.md"

  run notes deobfuscate
  [ "$status" -ne 0 ]
  [[ "$output" == *"refusing to overwrite dirty readable note"* ]]
  # Alpha was renamed despite beta's failure...
  [ -f "$NOTES_CALLER_PWD/notes/alpha.md" ]
  # ...and the state file recorded its base hash again (the actual regression
  # under test). Pre-fix the task exit'd before _record_deobfuscation_base_hashes
  # was called, so alpha_rows_after == alpha_rows_before. Post-fix the recording
  # runs even on partial failure, so the row count strictly increases.
  local alpha_rows_after
  alpha_rows_after=$(grep -c "^${alpha_id}"$'\t' "$state" || true)
  [ "$alpha_rows_after" -gt "$alpha_rows_before" ]
}

@test "deobfuscation state file is append-only and last-entry-wins" {
  # Regression: notes#59 finding 3. The state file is now append-only to
  # avoid a tmp+mv read-modify-write race when two deobfuscate processes
  # interleave. Two invariants we test here:
  #   (a) re-recording an id appends a new row instead of rewriting the file
  #   (b) the lookup semantic takes the *last* matching row, so newer writes
  #       shadow older ones (which is what makes append-only safe).
  notes obfuscate
  local alpha_id
  alpha_id=$(grep "alpha.md" "$NOTES_CALLER_PWD/notes/.manifest" | cut -f1)
  git -C "$NOTES_CALLER_PWD" add -A notes
  git -C "$NOTES_CALLER_PWD" commit -q -m "obfuscate"

  notes deobfuscate
  local state="$NOTES_CALLER_PWD/.git/info/notes-obfuscation-state"
  [ -f "$state" ]

  local rows_before alpha_rows_before
  rows_before=$(wc -l < "$state" | tr -d ' ')
  alpha_rows_before=$(grep -c "^${alpha_id}"$'\t' "$state" || true)
  [ "$alpha_rows_before" -eq 1 ]

  # Drive another deobfuscate cycle: dirty the readable, restore the
  # obfuscated source from the commit (simulating a pull), then force.
  # Pre-fix this rewrote the state file (rows_after == rows_before);
  # post-fix it appends (rows_after > rows_before).
  echo "local edit" >> "$NOTES_CALLER_PWD/notes/alpha.md"
  git -C "$NOTES_CALLER_PWD" update-index --no-assume-unchanged "notes/$alpha_id" 2>/dev/null || true
  git -C "$NOTES_CALLER_PWD" checkout -- "notes/$alpha_id"
  notes deobfuscate -- --force

  local rows_after alpha_rows_after
  rows_after=$(wc -l < "$state" | tr -d ' ')
  alpha_rows_after=$(grep -c "^${alpha_id}"$'\t' "$state" || true)
  [ "$rows_after" -gt "$rows_before" ]
  [ "$alpha_rows_after" -gt "$alpha_rows_before" ]

  # Last-entry-wins lookup: inject a stale row at the end and confirm the
  # awk "last match" semantic the helper uses returns the stale one (i.e.
  # whatever was written most recently wins). This is the property that
  # makes append-only safe under concurrent writes.
  local stale_hash="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
  printf '%s\t%s\n' "$alpha_id" "$stale_hash" >> "$state"

  # Pin the contract on the helper, not its implementation -- a future
  # rewrite of _deobfuscation_base_hash_for_id (different awk, perl, etc.)
  # that silently broke last-entry-wins would then fail this test.
  local last
  last=$(_deobfuscation_base_hash_for_id "$NOTES_CALLER_PWD/notes" "$alpha_id")
  [ "$last" = "$stale_hash" ]
}

# ── Refuse re-obfuscation of already-hex-named files ──────────

@test "obfuscate refuses files whose basename is an 8-hex id" {
  # Simulate the broken state we saw on den/fold through April 2026:
  # an obfuscated file exists on disk, but the manifest has lost its entry.
  # Without this guard, `notes obfuscate` would treat the hex file as
  # unobfuscated, generate a fresh random id, and create a duplicate blob.
  mkdir -p "$NOTES_CALLER_PWD/notes"
  echo "---
title: orphan" > "$NOTES_CALLER_PWD/notes/deadbeef"
  # No manifest entry for deadbeef — simulates the lost-mapping case

  run notes obfuscate "deadbeef"
  [ "$status" -ne 0 ]
  [[ "$output" == *"refusing to obfuscate"* ]]
  [[ "$output" == *"deadbeef"* ]]

  # File must not have been renamed
  [ -f "$NOTES_CALLER_PWD/notes/deadbeef" ]
}

@test "obfuscate refuses hex-named file in full scan mode" {
  # Same guard, but via unscoped `notes obfuscate` (scans all files)
  mkdir -p "$NOTES_CALLER_PWD/notes"
  cat > "$NOTES_CALLER_PWD/notes/alpha.md" <<EOT
---
title: Alpha
---
alpha
EOT
  echo "orphan" > "$NOTES_CALLER_PWD/notes/cafebabe"

  run notes obfuscate
  [ "$status" -ne 0 ]
  [[ "$output" == *"refusing to obfuscate"* ]]
  [[ "$output" == *"cafebabe"* ]]

  # alpha.md also shouldn't have been renamed (the guard aborts the operation)
  [ -f "$NOTES_CALLER_PWD/notes/alpha.md" ]
}

@test "obfuscate allows files with hex prefix but non-hex tail" {
  # Don't false-positive on names that happen to start with hex
  mkdir -p "$NOTES_CALLER_PWD/notes"
  cat > "$NOTES_CALLER_PWD/notes/abc123xy.md" <<EOT
---
title: abc
---
content
EOT

  run notes obfuscate
  [ "$status" -eq 0 ]
  # File was renamed to a real hex id (manifest has entry)
  [ -f "$NOTES_CALLER_PWD/notes/.manifest" ]
  grep -q "abc123xy.md" "$NOTES_CALLER_PWD/notes/.manifest"
}

@test "obfuscate allows files whose basename is hex but has an extension" {
  # `deadbeef.md` is a valid readable filename; guard only fires on bare 8-hex
  mkdir -p "$NOTES_CALLER_PWD/notes"
  cat > "$NOTES_CALLER_PWD/notes/deadbeef.md" <<EOT
---
title: Dead Beef
---
content
EOT

  run notes obfuscate
  [ "$status" -eq 0 ]
  grep -q "deadbeef.md" "$NOTES_CALLER_PWD/notes/.manifest"
}

@test "obfuscate refuses hex-named file in a subdirectory" {
  # The guard uses basename(), so nested paths must still be caught.
  mkdir -p "$NOTES_CALLER_PWD/notes/sub"
  echo "orphan" > "$NOTES_CALLER_PWD/notes/sub/cafebabe"

  run notes obfuscate "sub/cafebabe"
  [ "$status" -ne 0 ]
  [[ "$output" == *"refusing to obfuscate"* ]]
  [[ "$output" == *"cafebabe"* ]]

  # File must not have been renamed
  [ -f "$NOTES_CALLER_PWD/notes/sub/cafebabe" ]
}

@test "obfuscate hex guard: uppercase basename behavior" {
  # The guard regex is lowercase-only ([a-f0-9]). On a case-insensitive
  # filesystem (macOS APFS default, NTFS), 'DEADBEEF' and 'deadbeef' collide
  # — the guard won't fire because uppercase doesn't match, even though
  # the file on disk is the same as an obfuscated lowercase name.
  # On a case-sensitive filesystem, they're truly different files and the
  # uppercase one is just a regular filename.
  #
  # This test documents the contract: the guard fires only on lowercase
  # hex. If the ID generator ever produces uppercase, or if we want to
  # catch the case-insensitive-FS collision, the regex must change.
  mkdir -p "$NOTES_CALLER_PWD/notes"
  echo "uppercase" > "$NOTES_CALLER_PWD/notes/DEADBEEF"
  # No .md extension; basename is 8 chars of uppercase hex
  # Note: the note has no title in frontmatter, which is fine — we're testing
  # the guard path, not frontmatter parsing.
  cat > "$NOTES_CALLER_PWD/notes/DEADBEEF" <<'EOT'
---
title: deadbeef
---
content
EOT

  run notes obfuscate "DEADBEEF"
  # Current behavior: uppercase passes through — guard doesn't fire, file
  # gets a fresh random obfuscated ID.
  [ "$status" -eq 0 ]
  # The original uppercase file is renamed (disappeared)
  [ ! -f "$NOTES_CALLER_PWD/notes/DEADBEEF" ]
  # A new obfuscated entry exists in the manifest
  grep -q "DEADBEEF" "$NOTES_CALLER_PWD/notes/.manifest" || fail "expected manifest entry for DEADBEEF"
}

@test "obfuscate hex guard: 7-char and 9-char hex pass through" {
  # The guard is {8}, not {7,} or {8,}. Files whose basenames are hex but
  # the wrong length are treated as normal readable filenames. This locks
  # in the boundary in case anyone 'improves' the regex without thinking.
  mkdir -p "$NOTES_CALLER_PWD/notes"
  cat > "$NOTES_CALLER_PWD/notes/abcdef0" <<'EOT'
---
title: seven-char
---
EOT
  cat > "$NOTES_CALLER_PWD/notes/abcdef012" <<'EOT'
---
title: nine-char
---
EOT

  run notes obfuscate
  [ "$status" -eq 0 ]
  # Both files got renamed to obfuscated IDs (guard didn't fire)
  [ ! -f "$NOTES_CALLER_PWD/notes/abcdef0" ]
  [ ! -f "$NOTES_CALLER_PWD/notes/abcdef012" ]
  grep -q "abcdef0$" "$NOTES_CALLER_PWD/notes/.manifest" || fail "expected 7-char entry in manifest"
  grep -q "abcdef012$" "$NOTES_CALLER_PWD/notes/.manifest" || fail "expected 9-char entry in manifest"
}

@test "obfuscate hex guard: multiple hex-named orphans in full-scan mode (first-hit-only)" {
  # If several hex-named files exist, the guard fires on the first and
  # aborts the entire rename_to_obfuscated call. This documents that
  # behavior: the error message only names ONE of the orphans — the user
  # must iterate. If that changes (e.g., we collect all violations before
  # failing), this test will notice.
  mkdir -p "$NOTES_CALLER_PWD/notes"
  echo "orphan1" > "$NOTES_CALLER_PWD/notes/deadbeef"
  echo "orphan2" > "$NOTES_CALLER_PWD/notes/cafebabe"
  cat > "$NOTES_CALLER_PWD/notes/real.md" <<'EOT'
---
title: real
---
EOT

  run notes obfuscate
  [ "$status" -ne 0 ]
  [[ "$output" == *"refusing to obfuscate"* ]]
  # At least one of the two orphans is named in the error
  if [[ "$output" != *"deadbeef"* ]] && [[ "$output" != *"cafebabe"* ]]; then
    fail "expected at least one orphan name in error: $output"
  fi
  # Neither orphan was renamed — the operation aborted
  [ -f "$NOTES_CALLER_PWD/notes/deadbeef" ]
  [ -f "$NOTES_CALLER_PWD/notes/cafebabe" ]
  # And real.md wasn't obfuscated either (fail-fast = no partial state)
  [ -f "$NOTES_CALLER_PWD/notes/real.md" ]
}
