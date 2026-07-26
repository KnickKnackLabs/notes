#!/usr/bin/env bats

# Tests for readable note diffs across refs and PR refs.

load test_helper

setup() {
  export NOTES_CALLER_PWD="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$NOTES_CALLER_PWD/notes"
  git -C "$NOTES_CALLER_PWD" init -q
  git -C "$NOTES_CALLER_PWD" config user.name "Test"
  git -C "$NOTES_CALLER_PWD" config user.email "test@test.com"

  echo "# Alpha" > "$NOTES_CALLER_PWD/notes/alpha.md"
  echo "# Beta" > "$NOTES_CALLER_PWD/notes/beta.md"
  rename_to_obfuscated "$NOTES_CALLER_PWD/notes" > /dev/null
  git -C "$NOTES_CALLER_PWD" add -A
  git -C "$NOTES_CALLER_PWD" commit -q -m "initial"
  git -C "$NOTES_CALLER_PWD" branch -M main
}

commit_readable_update() {
  local message="$1"
  rename_to_obfuscated "$NOTES_CALLER_PWD/notes" > /dev/null
  git -C "$NOTES_CALLER_PWD" add -A
  git -C "$NOTES_CALLER_PWD" commit -q -m "$message"
}

@test "notes diff with refs shows readable paths and content" {
  rename_to_readable "$NOTES_CALLER_PWD/notes" > /dev/null
  echo "# Alpha v2" > "$NOTES_CALLER_PWD/notes/alpha.md"
  echo "# Gamma" > "$NOTES_CALLER_PWD/notes/gamma.md"
  commit_readable_update "update notes"

  run notes diff HEAD~1 HEAD
  [ "$status" -eq 0 ]
  [[ "$output" == *"diff --git a/notes/alpha.md b/notes/alpha.md"* ]]
  [[ "$output" == *"-# Alpha"* ]]
  [[ "$output" == *"+# Alpha v2"* ]]
  [[ "$output" == *"diff --git a/notes/gamma.md b/notes/gamma.md"* ]]
  [[ "$output" == *"+# Gamma"* ]]
  [[ "$output" != *".manifest"* ]]
}

@test "notes diff parses range syntax" {
  rename_to_readable "$NOTES_CALLER_PWD/notes" > /dev/null
  echo "# Beta v2" > "$NOTES_CALLER_PWD/notes/beta.md"
  commit_readable_update "edit beta"

  run notes diff HEAD~1..HEAD
  [ "$status" -eq 0 ]
  [[ "$output" == *"diff --git a/notes/beta.md b/notes/beta.md"* ]]
  [[ "$output" == *"+# Beta v2"* ]]
}

@test "notes diff triple-dot uses merge-base" {
  git -C "$NOTES_CALLER_PWD" checkout -q -b feature
  rename_to_readable "$NOTES_CALLER_PWD/notes" > /dev/null
  echo "# Alpha feature" > "$NOTES_CALLER_PWD/notes/alpha.md"
  commit_readable_update "edit alpha on feature"

  git -C "$NOTES_CALLER_PWD" checkout -q main
  rename_to_readable "$NOTES_CALLER_PWD/notes" > /dev/null
  echo "# Beta main" > "$NOTES_CALLER_PWD/notes/beta.md"
  commit_readable_update "edit beta on main"

  run notes diff main...feature
  [ "$status" -eq 0 ]
  [[ "$output" == *"diff --git a/notes/alpha.md b/notes/alpha.md"* ]]
  [[ "$output" == *"+# Alpha feature"* ]]
  [[ "$output" != *"beta.md"* ]]
}

@test "notes diff --out writes readable review artifacts" {
  local out_dir
  out_dir="$BATS_TEST_TMPDIR/readable-review"

  rename_to_readable "$NOTES_CALLER_PWD/notes" > /dev/null
  echo "# Alpha v2" > "$NOTES_CALLER_PWD/notes/alpha.md"
  commit_readable_update "edit alpha"

  run notes diff --out "$out_dir" HEAD~1 HEAD
  [ "$status" -eq 0 ]
  [ -f "$out_dir/base/notes/alpha.md" ]
  [ -f "$out_dir/head/notes/alpha.md" ]
  [ -f "$out_dir/readable.patch" ]
  grep -q "# Alpha" "$out_dir/base/notes/alpha.md"
  grep -q "# Alpha v2" "$out_dir/head/notes/alpha.md"
  grep -q "diff --git a/notes/alpha.md b/notes/alpha.md" "$out_dir/readable.patch"
  [ ! -e "$out_dir/base/notes/beta.md" ]
  [ ! -e "$out_dir/head/notes/beta.md" ]
  [[ "$output" == *"Wrote changed-note base artifacts: $out_dir/base"* ]]
  [[ "$output" == *"Wrote changed-note head artifacts: $out_dir/head"* ]]
  [[ "$output" == *"Wrote readable patch: $out_dir/readable.patch"* ]]
}

@test "notes diff materializes manifest-only readable renames" {
  local manifest next_manifest out_dir
  manifest="$NOTES_CALLER_PWD/notes/.manifest"
  next_manifest="$BATS_TEST_TMPDIR/renamed.manifest"
  out_dir="$BATS_TEST_TMPDIR/renamed-review"

  awk -F '\t' 'BEGIN { OFS = "\t" } $2 == "alpha.md" { $2 = "renamed/alpha.md" } { print }' \
    "$manifest" > "$next_manifest"
  mv "$next_manifest" "$manifest"
  git -C "$NOTES_CALLER_PWD" add notes/.manifest
  git -C "$NOTES_CALLER_PWD" commit -q -m "rename alpha in manifest"

  run notes diff --out "$out_dir" HEAD~1 HEAD

  [ "$status" -eq 0 ]
  [ -f "$out_dir/base/notes/alpha.md" ]
  [ -f "$out_dir/head/notes/renamed/alpha.md" ]
  grep -q "# Alpha" "$out_dir/base/notes/alpha.md"
  grep -q "# Alpha" "$out_dir/head/notes/renamed/alpha.md"
  grep -q "notes/alpha.md" "$out_dir/readable.patch"
  grep -q "notes/renamed/alpha.md" "$out_dir/readable.patch"
}

@test "notes diff preserves manifest aliases when one readable path is removed" {
  local alpha_id manifest next_manifest out_dir
  manifest="$NOTES_CALLER_PWD/notes/.manifest"
  alpha_id=$(awk -F '\t' '$2 == "alpha.md" { print $1 }' "$manifest")
  next_manifest="$BATS_TEST_TMPDIR/aliased.manifest"
  out_dir="$BATS_TEST_TMPDIR/alias-review"

  printf '%s\talias-alpha.md\n' "$alpha_id" >> "$manifest"
  git -C "$NOTES_CALLER_PWD" add notes/.manifest
  git -C "$NOTES_CALLER_PWD" commit -q -m "alias alpha in manifest"

  awk -F '\t' '$2 != "alpha.md" { print }' "$manifest" > "$next_manifest"
  mv "$next_manifest" "$manifest"
  git -C "$NOTES_CALLER_PWD" add notes/.manifest
  git -C "$NOTES_CALLER_PWD" commit -q -m "remove original alpha path"

  run notes diff --out "$out_dir" HEAD~1 HEAD

  [ "$status" -eq 0 ]
  [ -f "$out_dir/base/notes/alpha.md" ]
  [ -f "$out_dir/base/notes/alias-alpha.md" ]
  [ ! -e "$out_dir/head/notes/alpha.md" ]
  [ -f "$out_dir/head/notes/alias-alpha.md" ]
  grep -q "deleted file mode" "$out_dir/readable.patch"
  grep -q "a/notes/alpha.md" "$out_dir/readable.patch"
  ! grep -q "a/notes/alias-alpha.md" "$out_dir/readable.patch"
}

@test "notes diff includes unchanged IDs that collide on a changed readable path" {
  local alpha_id beta_id manifest next_manifest out_dir
  manifest="$NOTES_CALLER_PWD/notes/.manifest"
  alpha_id=$(awk -F '\t' '$2 == "alpha.md" { print $1 }' "$manifest")
  beta_id=$(awk -F '\t' '$2 == "beta.md" { print $1 }' "$manifest")
  next_manifest="$BATS_TEST_TMPDIR/colliding.manifest"
  out_dir="$BATS_TEST_TMPDIR/collision-review"

  {
    printf '%s\tbeta.md\n' "$alpha_id"
    printf '%s\tbeta.md\n' "$beta_id"
  } > "$next_manifest"
  mv "$next_manifest" "$manifest"
  git -C "$NOTES_CALLER_PWD" add notes/.manifest
  git -C "$NOTES_CALLER_PWD" commit -q -m "collide readable paths"

  run notes diff --out "$out_dir" HEAD~1 HEAD

  [ "$status" -eq 0 ]
  [ -f "$out_dir/base/notes/alpha.md" ]
  grep -q "# Beta" "$out_dir/base/notes/beta.md"
  [ ! -e "$out_dir/head/notes/alpha.md" ]
  grep -q "# Beta" "$out_dir/head/notes/beta.md"
  grep -q "a/notes/alpha.md" "$out_dir/readable.patch"
  ! grep -q "a/notes/beta.md" "$out_dir/readable.patch"
}

@test "notes diff rejects readable file and directory path collisions" {
  local alpha_id beta_id manifest next_manifest
  manifest="$NOTES_CALLER_PWD/notes/.manifest"
  alpha_id=$(awk -F '\t' '$2 == "alpha.md" { print $1 }' "$manifest")
  beta_id=$(awk -F '\t' '$2 == "beta.md" { print $1 }' "$manifest")
  next_manifest="$BATS_TEST_TMPDIR/prefix-colliding.manifest"

  {
    printf '%s\tshared\n' "$alpha_id"
    printf '%s\tshared/child.md\n' "$beta_id"
  } > "$next_manifest"
  mv "$next_manifest" "$manifest"
  git -C "$NOTES_CALLER_PWD" add notes/.manifest
  git -C "$NOTES_CALLER_PWD" commit -q -m "create readable path prefix collision"

  echo "# Beta changed" > "$NOTES_CALLER_PWD/notes/$beta_id"
  git -C "$NOTES_CALLER_PWD" add "notes/$beta_id"
  git -C "$NOTES_CALLER_PWD" commit -q -m "edit colliding note"

  run notes diff HEAD~1 HEAD

  [ "$status" -ne 0 ]
  [[ "$output" == *"readable path is both a file and directory: shared"* ]]
  [[ "$output" != *"# Beta changed"* ]]
}

@test "ref diff Git process count does not grow with unchanged notes" {
  local i real_git counter_bin calls git_call_count
  rename_to_readable "$NOTES_CALLER_PWD/notes" > /dev/null
  i=1
  while [ "$i" -le 50 ]; do
    printf '# Unchanged %02d\n' "$i" > "$NOTES_CALLER_PWD/notes/unchanged-$i.md"
    i=$((i + 1))
  done
  commit_readable_update "add unchanged scale"

  rename_to_readable "$NOTES_CALLER_PWD/notes" > /dev/null
  echo "# Alpha changed" > "$NOTES_CALLER_PWD/notes/alpha.md"
  commit_readable_update "edit one note"

  real_git=$(command -v git)
  counter_bin="$BATS_TEST_TMPDIR/counter-bin"
  calls="$BATS_TEST_TMPDIR/git.calls"
  mkdir -p "$counter_bin"
  cat > "$counter_bin/git" <<SH
#!/usr/bin/env bash
printf '1\\n' >> '$calls'
exec '$real_git' "\$@"
SH
  chmod +x "$counter_bin/git"

  PATH="$counter_bin:$PATH" run notes diff HEAD~1 HEAD

  [ "$status" -eq 0 ]
  [[ "$output" == *"diff --git a/notes/alpha.md b/notes/alpha.md"* ]]
  git_call_count=$(wc -l < "$calls" | tr -d ' ')
  [ "$git_call_count" -le 30 ]
}

@test "notes diff --out refuses symlink destinations" {
  local out_target out_link
  out_target="$BATS_TEST_TMPDIR/out-target"
  out_link="$BATS_TEST_TMPDIR/out-link"
  mkdir -p "$out_target"
  echo "keep" > "$out_target/existing.txt"
  ln -s "$out_target" "$out_link"

  rename_to_readable "$NOTES_CALLER_PWD/notes" > /dev/null
  echo "# Alpha v2" > "$NOTES_CALLER_PWD/notes/alpha.md"
  commit_readable_update "edit alpha"

  run notes diff --out "$out_link" HEAD~1 HEAD
  [ "$status" -ne 0 ]
  [[ "$output" == *"Error: --out path must not be a symlink"* ]]
  [ ! -e "$out_target/readable.patch" ]
  [ ! -e "$out_target/base" ]
  [ ! -e "$out_target/head" ]
}

@test "notes diff errors when a ref has manifest-unmapped note files" {
  echo "orphan content" > "$NOTES_CALLER_PWD/notes/deadbeef"
  git -C "$NOTES_CALLER_PWD" add notes/deadbeef
  git -C "$NOTES_CALLER_PWD" commit -q -m "add unmapped note blob"

  run notes diff HEAD~1 HEAD
  [ "$status" -ne 0 ]
  [[ "$output" == *"not listed in notes/.manifest"* ]]
  [[ "$output" != *"deadbeef"* ]]
  [[ "$output" != *"orphan content"* ]]
}

@test "notes diff errors when a ref has note files but no manifest" {
  local repo
  repo="$BATS_TEST_TMPDIR/no-manifest-repo"
  export NOTES_CALLER_PWD="$repo"
  mkdir -p "$repo/notes"
  git -C "$repo" init -q
  git -C "$repo" config user.name "Test"
  git -C "$repo" config user.email "test@test.com"
  echo "plain content" > "$repo/notes/plain.md"
  git -C "$repo" add notes/plain.md
  git -C "$repo" commit -q -m "plain note without manifest"

  run notes diff HEAD HEAD
  [ "$status" -ne 0 ]
  [[ "$output" == *"but no notes/.manifest"* ]]
  [[ "$output" != *"plain.md"* ]]
  [[ "$output" != *"plain content"* ]]
}

@test "notes diff rejects refs that are not tree-ish" {
  run notes diff does-not-exist HEAD
  [ "$status" -ne 0 ]
  [[ "$output" == *"Error: not a tree-ish ref: does-not-exist"* ]]
}

@test "notes diff without refs shows working-tree readable diff" {
  rename_to_readable "$NOTES_CALLER_PWD/notes" > /dev/null
  echo "# Alpha local" > "$NOTES_CALLER_PWD/notes/alpha.md"

  run notes diff
  [ "$status" -eq 0 ]
  [[ "$output" == *"=== alpha.md (modified) ==="* ]]
  [[ "$output" == *"-# Alpha"* ]]
  [[ "$output" == *"+# Alpha local"* ]]
}

@test "notes diff --pr fetches PR refs without checking them out" {
  local origin fake_gh
  origin="$BATS_TEST_TMPDIR/origin.git"
  git init --bare -q "$origin"
  git -C "$NOTES_CALLER_PWD" remote add origin "$origin"
  git -C "$NOTES_CALLER_PWD" push -q origin main:refs/heads/main

  git -C "$NOTES_CALLER_PWD" checkout -q -b pr-branch
  rename_to_readable "$NOTES_CALLER_PWD/notes" > /dev/null
  echo "# Alpha from PR" > "$NOTES_CALLER_PWD/notes/alpha.md"
  commit_readable_update "edit alpha on pr"
  git -C "$NOTES_CALLER_PWD" push -q origin HEAD:refs/pull/1/head
  git -C "$NOTES_CALLER_PWD" checkout -q main

  fake_gh="$BATS_TEST_TMPDIR/gh"
  cat > "$fake_gh" <<'SH'
#!/usr/bin/env bash
printf 'main\n'
SH
  chmod +x "$fake_gh"
  export GH="$fake_gh"

  run notes diff --pr 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"diff --git a/notes/alpha.md b/notes/alpha.md"* ]]
  [[ "$output" == *"+# Alpha from PR"* ]]
  [ "$(git -C "$NOTES_CALLER_PWD" branch --show-current)" = "main" ]
  [ -z "$(git -C "$NOTES_CALLER_PWD" for-each-ref refs/notes-diff)" ]
}
