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

# Core obfuscation, planning, staging, and path-safety behavior

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


@test "scoped new mapping stages canonical order without unrelated manifest edits" {
  # Select a later-sorting mapping in the index, then leave another mapping
  # only in the working manifest.
  printf '22222222\tgamma.txt\n' > "$NOTES_CALLER_PWD/notes/.manifest"
  git -C "$NOTES_CALLER_PWD" add -f notes/.manifest
  printf '33333333\tbeta.md\n' >> "$NOTES_CALLER_PWD/notes/.manifest"

  notes obfuscate alpha.md

  local staged_manifest staged_names working_manifest
  staged_manifest=$(git -C "$NOTES_CALLER_PWD" show :notes/.manifest)
  staged_names=$(printf '%s\n' "$staged_manifest" | cut -f2)
  working_manifest=$(cat "$NOTES_CALLER_PWD/notes/.manifest")
  [ "$staged_names" = $'alpha.md\ngamma.txt' ]
  [[ "$staged_manifest" != *$'\tbeta.md'* ]]
  [[ "$working_manifest" == *$'\talpha.md'* ]]
  [[ "$working_manifest" == *$'33333333\tbeta.md'* ]]

  # After committing and removing the intentionally unstaged mapping, no
  # order-only manifest difference remains.
  git -C "$NOTES_CALLER_PWD" commit -q --no-verify -m "scoped obfuscation"
  grep -v $'33333333\tbeta.md' "$NOTES_CALLER_PWD/notes/.manifest" \
    > "$NOTES_CALLER_PWD/notes/.manifest.filtered"
  mv "$NOTES_CALLER_PWD/notes/.manifest.filtered" \
    "$NOTES_CALLER_PWD/notes/.manifest"
  git -C "$NOTES_CALLER_PWD" diff --quiet -- notes/.manifest
}


@test "obfuscate refuses to overwrite an existing known-ID destination" {
  notes obfuscate
  local alpha_id
  alpha_id=$(grep $'\talpha\.md$' "$NOTES_CALLER_PWD/notes/.manifest" | cut -f1)
  git -C "$NOTES_CALLER_PWD" commit -q --no-verify -m "obfuscated"

  # Simulate an interrupted or stale state containing both representations.
  printf 'dirty readable content\n' > "$NOTES_CALLER_PWD/notes/alpha.md"
  local obfuscated_before
  obfuscated_before=$(cat "$NOTES_CALLER_PWD/notes/$alpha_id")

  run notes obfuscate alpha.md

  [ "$status" -ne 0 ]
  [[ "$output" == *"refusing to overwrite existing obfuscated path: $alpha_id"* ]]
  [ "$(cat "$NOTES_CALLER_PWD/notes/$alpha_id")" = "$obfuscated_before" ]
  [ "$(cat "$NOTES_CALLER_PWD/notes/alpha.md")" = "dirty readable content" ]
}


@test "obfuscate refuses to replace a dangling known-ID symlink" {
  notes obfuscate
  local alpha_id
  alpha_id=$(grep $'\talpha\.md$' "$NOTES_CALLER_PWD/notes/.manifest" | cut -f1)
  rm "$NOTES_CALLER_PWD/notes/$alpha_id"
  printf 'readable content\n' > "$NOTES_CALLER_PWD/notes/alpha.md"
  ln -s missing-target "$NOTES_CALLER_PWD/notes/$alpha_id"

  run notes obfuscate alpha.md

  [ "$status" -ne 0 ]
  [[ "$output" == *"refusing to overwrite existing obfuscated path: $alpha_id"* ]]
  [ -L "$NOTES_CALLER_PWD/notes/$alpha_id" ]
  [ "$(readlink "$NOTES_CALLER_PWD/notes/$alpha_id")" = "missing-target" ]
  [ "$(cat "$NOTES_CALLER_PWD/notes/alpha.md")" = "readable content" ]
}


@test "obfuscate refuses a manifest ID shared by planned readable paths" {
  notes obfuscate
  local alpha_id
  alpha_id=$(grep $'\talpha\.md$' "$NOTES_CALLER_PWD/notes/.manifest" | cut -f1)
  notes deobfuscate
  printf '%s\tbeta.md\n' "$alpha_id" >> "$NOTES_CALLER_PWD/notes/.manifest"

  run notes obfuscate alpha.md beta.md

  [ "$status" -ne 0 ]
  [[ "$output" == *"manifest ID '$alpha_id' maps to multiple readable paths"* ]]
  [ -f "$NOTES_CALLER_PWD/notes/alpha.md" ]
  [ -f "$NOTES_CALLER_PWD/notes/beta.md" ]
}


@test "full obfuscate batches Fold-scale known-entry classification and staging" {
  local count=535 i=1 id name mock_bin command real_command call_log
  rm -rf "$NOTES_CALLER_PWD/notes"
  mkdir -p "$NOTES_CALLER_PWD/notes"

  while [ "$i" -le "$count" ]; do
    id=$(printf '%08x' "$i")
    name=$(printf 'note-%03d.md' "$i")
    printf '%s\t%s\n' "$id" "$name" >> "$NOTES_CALLER_PWD/notes/.manifest"
    printf '# Note %d\n' "$i" > "$NOTES_CALLER_PWD/notes/$id"
    i=$((i + 1))
  done
  git -C "$NOTES_CALLER_PWD" add -A
  git -C "$NOTES_CALLER_PWD" commit -q --no-verify -m "obfuscated corpus"

  while IFS=$'\t' read -r id name; do
    mv "$NOTES_CALLER_PWD/notes/$id" "$NOTES_CALLER_PWD/notes/$name"
  done < "$NOTES_CALLER_PWD/notes/.manifest"

  mock_bin="$BATS_TEST_TMPDIR/obfuscate-count-bin"
  call_log="$BATS_TEST_TMPDIR/obfuscate-calls"
  mkdir -p "$mock_bin"
  : > "$call_log"
  for command in git grep basename awk; do
    real_command=$(command -v "$command")
    if [ "$command" = "git" ]; then
      cat > "$mock_bin/$command" <<SH
#!/usr/bin/env bash
printf 'git\\t%s\\n' "\$*" >> "\$OBFUSCATE_CALL_LOG"
exec '$real_command' "\$@"
SH
    else
      cat > "$mock_bin/$command" <<SH
#!/usr/bin/env bash
printf '%s\\n' '$command' >> "\$OBFUSCATE_CALL_LOG"
exec '$real_command' "\$@"
SH
    fi
    chmod +x "$mock_bin/$command"
  done

  PATH="$mock_bin:$PATH" OBFUSCATE_CALL_LOG="$call_log" run notes obfuscate

  local awk_calls grep_calls basename_calls add_calls rm_calls
  awk_calls=$(grep -c '^awk$' "$call_log" || true)
  grep_calls=$(grep -c '^grep$' "$call_log" || true)
  basename_calls=$(grep -c '^basename$' "$call_log" || true)
  add_calls=$(grep -c $'^git\t.* add --sparse -- notes/' "$call_log" || true)
  rm_calls=$(grep -c $'^git\t.* rm --cached --quiet --ignore-unmatch -- notes/' "$call_log" || true)
  [ "$status" -eq 0 ]
  [[ "$output" == *"Obfuscated 535 file(s)"* ]]
  # At most one corpus planner plus one existing full-suppression index stream.
  [ "$awk_calls" -le 2 ]
  [ "$grep_calls" -eq 0 ]
  [ "$basename_calls" -eq 0 ]
  [ "$add_calls" -eq 1 ]
  [ "$rm_calls" -eq 1 ]
}


@test "scoped obfuscate reads the indexed manifest once and batches staging" {
  local mock_bin command real_command call_log
  notes obfuscate
  git -C "$NOTES_CALLER_PWD" commit -q --no-verify -m "obfuscated"
  notes deobfuscate

  mock_bin="$BATS_TEST_TMPDIR/scoped-obfuscate-count-bin"
  call_log="$BATS_TEST_TMPDIR/scoped-obfuscate-calls"
  mkdir -p "$mock_bin"
  : > "$call_log"
  real_command=$(command -v git)
  cat > "$mock_bin/git" <<SH
#!/usr/bin/env bash
printf 'git\\t%s\\n' "\$*" >> "\$OBFUSCATE_CALL_LOG"
exec '$real_command' "\$@"
SH
  chmod +x "$mock_bin/git"

  PATH="$mock_bin:$PATH" OBFUSCATE_CALL_LOG="$call_log" run \
    notes obfuscate alpha.md beta.md

  [ "$status" -eq 0 ]
  [ "$(grep -c $'^git\t.* cat-file --filters :notes/.manifest$' "$call_log" || true)" -eq 1 ]
  [ "$(grep -c $'^git\t.* add --sparse -- notes/' "$call_log" || true)" -eq 1 ]
  [ "$(grep -c $'^git\t.* rm --cached --quiet --ignore-unmatch -- notes/' "$call_log" || true)" -eq 1 ]
}


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

@test "obfuscate fails before mutation when corpus enumeration fails" {
  local mock_bin="$BATS_TEST_TMPDIR/failing-find-bin"
  mkdir -p "$mock_bin"
  cat > "$mock_bin/find" <<'SH'
#!/usr/bin/env bash
exit 73
SH
  chmod +x "$mock_bin/find"

  PATH="$mock_bin:$PATH" run notes obfuscate

  [ "$status" -ne 0 ]
  [[ "$output" == *"failed to enumerate readable note candidates"* ]]
  [ -f "$NOTES_CALLER_PWD/notes/alpha.md" ]
  [ -f "$NOTES_CALLER_PWD/notes/beta.md" ]
  [ ! -f "$NOTES_CALLER_PWD/notes/.manifest" ]
}

@test "obfuscate fails instead of widening an unparsed file scope" {
  local mock_bin="$BATS_TEST_TMPDIR/failing-xargs-bin"
  make_failing_xargs_overlay "$mock_bin"

  PATH="$mock_bin:$PATH" run notes obfuscate alpha.md

  [ "$status" -eq 73 ]
  [[ "$output" == *"failed to parse variadic arguments"* ]]
  [ -f "$NOTES_CALLER_PWD/notes/alpha.md" ]
  [ -f "$NOTES_CALLER_PWD/notes/beta.md" ]
  [ ! -f "$NOTES_CALLER_PWD/notes/.manifest" ]
}
