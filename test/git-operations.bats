#!/usr/bin/env bats

# Tests for git operations (pull, rebase, merge) with obfuscated notes.
# Each test creates a "remote" bare repo and a "local" clone to simulate
# real multi-user / multi-machine workflows.

load test_helper

assert_gitcrypt_blob() {
  local repo="$1" ref_path="$2"
  local header
  header=$(git -C "$repo" cat-file -p "$ref_path" | dd bs=1 skip=1 count=8 2>/dev/null)
  [ "$header" = "GITCRYPT" ] || fail "expected encrypted blob at $ref_path"
}

# The installed config resolves via the notes shim. The test harness uses the
# in-tree script so git can exercise the same merge logic without an installed
# package shim.
_use_local_merge_driver() {
  git -C "$1" config merge.manifest.driver \
    "bash $REPO_DIR/lib/manifest-merge-driver.sh %O %A %B"
}

# Override default setup — we need a remote + local pair, not a single repo.
setup() {
  source "$REPO_DIR/lib/common.sh"

  # Create a bare "remote" repo
  export REMOTE="$BATS_TEST_TMPDIR/remote.git"
  git init -q --bare -b main "$REMOTE"

  # Create the "origin" working copy (simulates another machine / agent)
  export ORIGIN="$BATS_TEST_TMPDIR/origin"
  git clone -q "$REMOTE" "$ORIGIN"
  git -C "$ORIGIN" config user.email "test@test.com"
  git -C "$ORIGIN" config user.name "Test"

  # Create initial notes, obfuscate, commit, push
  mkdir -p "$ORIGIN/notes"
  echo -e "---\ntitle: Alpha\n---\n# Alpha" > "$ORIGIN/notes/alpha.md"
  echo -e "---\ntitle: Beta\n---\n# Beta" > "$ORIGIN/notes/beta.md"
  git -C "$ORIGIN" add -A
  git -C "$ORIGIN" commit -q -m "initial notes"

  export NOTES_CALLER_PWD="$ORIGIN"
  notes obfuscate
  git -C "$ORIGIN" commit -q -m "obfuscate"

  # Install hooks on origin too (both sides need them)
  notes install-hooks --yes
  notes deobfuscate

  git -C "$ORIGIN" push -q

  # Clone to "local" (simulates your working copy)
  export LOCAL="$BATS_TEST_TMPDIR/local"
  git clone -q "$REMOTE" "$LOCAL"
  git -C "$LOCAL" config user.email "test@test.com"
  git -C "$LOCAL" config user.name "Test"

  # Deobfuscate + install hooks (including merge driver) on local
  export NOTES_CALLER_PWD="$LOCAL"
  notes deobfuscate
  notes install-hooks --yes
  _use_local_merge_driver "$LOCAL"
}

# ── Pull ──────────────────────────────────────────────────────

@test "pull: new note from remote appears deobfuscated locally" {
  # Origin adds a new note (hooks auto-obfuscate on commit)
  echo -e "---\ntitle: Gamma\n---\n# Gamma" > "$ORIGIN/notes/gamma.md"
  NOTES_CALLER_PWD="$ORIGIN" notes stage gamma.md
  git -C "$ORIGIN" commit -q -m "add gamma"
  git -C "$ORIGIN" push -q

  # Local pulls — post-merge hook deobfuscates
  git -C "$LOCAL" pull -q

  [ -f "$LOCAL/notes/gamma.md" ]
  [[ "$(cat "$LOCAL/notes/gamma.md")" == *"# Gamma"* ]]
  grep -q "gamma.md" "$LOCAL/notes/.manifest"
}

@test "pull: remote edit to existing note is visible locally" {
  # Origin edits alpha (readable on disk, hooks handle obfuscation)
  echo "Updated content" >> "$ORIGIN/notes/alpha.md"
  NOTES_CALLER_PWD="$ORIGIN" notes stage alpha.md
  git -C "$ORIGIN" commit -q -m "edit alpha"
  git -C "$ORIGIN" push -q

  # Local: re-obfuscate before pull so readable files don't conflict
  NOTES_CALLER_PWD="$LOCAL" notes obfuscate
  git -C "$LOCAL" checkout -- .
  git -C "$LOCAL" pull -q

  # Deobfuscate to see the updated content
  NOTES_CALLER_PWD="$LOCAL" notes deobfuscate
  [ -f "$LOCAL/notes/alpha.md" ]
  [[ "$(cat "$LOCAL/notes/alpha.md")" == *"Updated content"* ]]
}

@test "pull: new note doesn't conflict with unrelated local readable files" {
  # Local has deobfuscated alpha.md and beta.md (untracked)
  [ -f "$LOCAL/notes/alpha.md" ]
  [ -f "$LOCAL/notes/beta.md" ]

  # Origin adds a completely new note and pushes
  echo -e "---\ntitle: Delta\n---\n# Delta" > "$ORIGIN/notes/delta.md"
  NOTES_CALLER_PWD="$ORIGIN" notes stage delta.md
  git -C "$ORIGIN" commit -q -m "add delta"
  git -C "$ORIGIN" push -q

  # Pull succeeds — new obfuscated ID doesn't clash with untracked readable names
  run git -C "$LOCAL" pull -q
  [ "$status" -eq 0 ]

  # Post-merge hook deobfuscates the new note
  [ -f "$LOCAL/notes/delta.md" ]
  # Existing notes still present
  [ -f "$LOCAL/notes/alpha.md" ]
}

@test "pull: remote edit to existing note works even with readable files on disk" {
  # Origin edits alpha and pushes (hooks auto-obfuscate)
  echo "origin change" >> "$ORIGIN/notes/alpha.md"
  NOTES_CALLER_PWD="$ORIGIN" notes stage alpha.md
  git -C "$ORIGIN" commit -q -m "edit alpha"
  git -C "$ORIGIN" push -q

  # Local has deobfuscated alpha.md on disk (untracked).
  # Pull works because git only tracks the obfuscated IDs — readable
  # names are untracked and don't conflict with obfuscated path changes.
  [ -f "$LOCAL/notes/alpha.md" ]
  run git -C "$LOCAL" pull -q
  [ "$status" -eq 0 ]

  # Post-merge hook deobfuscates — local alpha.md now has the update.
  # But the old untracked alpha.md is still on disk... the post-merge
  # hook overwrites it because deobfuscate uses mv from the obfuscated ID.
  [[ "$(cat "$LOCAL/notes/alpha.md")" == *"origin change"* ]]
}

@test "pull: dirty readable does not block safe remote updates later in manifest" {
  local alpha_id beta_id
  alpha_id=$(grep "alpha.md" "$LOCAL/notes/.manifest" | cut -f1)
  beta_id=$(grep "beta.md" "$LOCAL/notes/.manifest" | cut -f1)

  # Origin edits both notes and pushes. Manifest order is alpha, then beta.
  echo "origin alpha change" >> "$ORIGIN/notes/alpha.md"
  echo "origin beta change" >> "$ORIGIN/notes/beta.md"
  NOTES_CALLER_PWD="$ORIGIN" notes stage alpha.md beta.md
  git -C "$ORIGIN" commit -q -m "edit alpha and beta"
  git -C "$ORIGIN" push -q

  # Local has a real edit to alpha.md. The post-merge hook must preserve it,
  # but that dirty alpha should not leave the unrelated beta readable stale.
  echo "local alpha edit" >> "$LOCAL/notes/alpha.md"
  run git -C "$LOCAL" pull -q
  [ "$status" -eq 0 ]

  [[ "$(cat "$LOCAL/notes/alpha.md")" == *"local alpha edit"* ]]
  [[ "$(cat "$LOCAL/notes/alpha.md")" != *"origin alpha change"* ]]
  [ -f "$LOCAL/notes/$alpha_id" ]

  [[ "$(cat "$LOCAL/notes/beta.md")" == *"origin beta change"* ]]
  [ ! -f "$LOCAL/notes/$beta_id" ]

  [[ "$output" == *"refusing to overwrite dirty readable note: alpha.md"* ]]
  [[ "$output" == *"git completed, but notes deobfuscation is incomplete"* ]]
  [[ "$output" == *"post-merge hook failed"* ]]

  NOTES_CALLER_PWD="$LOCAL" run notes status
  [ "$status" -eq 0 ]
  [[ "$output" == *"Incomplete deobfuscation"* ]]
  [[ "$output" == *"alpha.md"* ]]

  NOTES_CALLER_PWD="$LOCAL" run notes stage alpha.md
  [ "$status" -ne 0 ]
  [[ "$output" == *"incomplete deobfuscation"* ]]
  [[ "$output" == *"notes changes alpha.md"* ]]
}

# ── Checkout ──────────────────────────────────────────────────

@test "checkout: post-checkout hook reconciles deleted readable note" {
  local beta_id
  beta_id=$(grep "beta.md" "$LOCAL/notes/.manifest" | cut -f1)
  [ -f "$LOCAL/notes/beta.md" ]

  git -C "$LOCAL" checkout -q -b delete-beta
  git -C "$LOCAL" update-index --no-assume-unchanged "notes/$beta_id" 2>/dev/null || true
  git -C "$LOCAL" rm -q --cached "notes/$beta_id"
  grep -v $'\tbeta.md$' "$LOCAL/notes/.manifest" > "$LOCAL/notes/.manifest.tmp"
  mv "$LOCAL/notes/.manifest.tmp" "$LOCAL/notes/.manifest"
  git -C "$LOCAL" add notes/.manifest
  git -C "$LOCAL" commit -q --no-verify -m "delete beta"
  [ ! -f "$LOCAL/notes/beta.md" ]

  git -C "$LOCAL" checkout -q main
  [ -f "$LOCAL/notes/beta.md" ]

  git -C "$LOCAL" checkout -q delete-beta
  [ ! -f "$LOCAL/notes/beta.md" ]
  ! grep -q "notes/beta.md" "$LOCAL/.git/info/exclude"

  NOTES_CALLER_PWD="$LOCAL" run notes changes --summary
  [ "$status" -eq 0 ]
  [[ "$output" == *"No changes."* ]]
}

# ── Merge ─────────────────────────────────────────────────────

@test "merge: concurrent note additions auto-merge via manifest driver" {
  # With the manifest merge driver installed, concurrent additions to
  # .manifest are union-merged automatically.
  NOTES_CALLER_PWD="$LOCAL" notes obfuscate
  git -C "$LOCAL" checkout -- .

  # Branch: add a note
  git -C "$LOCAL" checkout -q -b feature
  echo -e "---\ntitle: Feature Note\n---\n# Feature" > "$LOCAL/notes/feature.md"
  NOTES_CALLER_PWD="$LOCAL" notes obfuscate
  git -C "$LOCAL" commit -q --no-verify -m "add feature note"

  # Main: add a different note
  git -C "$LOCAL" checkout -q main
  echo -e "---\ntitle: Main Note\n---\n# Main" > "$LOCAL/notes/main-note.md"
  NOTES_CALLER_PWD="$LOCAL" notes obfuscate
  git -C "$LOCAL" commit -q --no-verify -m "add main note"

  # Merge succeeds — driver union-merges the manifest
  run git -C "$LOCAL" merge feature --no-edit
  [ "$status" -eq 0 ]

  # Manifest has all entries (alpha, beta, feature, main-note)
  [ "$(wc -l < "$LOCAL/notes/.manifest" | tr -d ' ')" -eq 4 ]
  grep -q "feature.md" "$LOCAL/notes/.manifest"
  grep -q "main-note.md" "$LOCAL/notes/.manifest"
}

@test "merge: single-branch addition merges cleanly" {
  # When only one branch adds notes and the other doesn't touch
  # the manifest, merge succeeds.
  NOTES_CALLER_PWD="$LOCAL" notes obfuscate
  git -C "$LOCAL" checkout -- .

  # Branch: add a note
  git -C "$LOCAL" checkout -q -b feature
  echo -e "---\ntitle: Feature\n---\n# Feature" > "$LOCAL/notes/feature.md"
  NOTES_CALLER_PWD="$LOCAL" notes obfuscate
  git -C "$LOCAL" commit -q --no-verify -m "add feature"

  # Main: add a non-notes file (no manifest change)
  git -C "$LOCAL" checkout -q main
  echo "readme" > "$LOCAL/README.md"
  git -C "$LOCAL" add README.md
  git -C "$LOCAL" commit -q --no-verify -m "add readme"

  # Merge succeeds
  run git -C "$LOCAL" merge feature -q --no-edit
  [ "$status" -eq 0 ]

  NOTES_CALLER_PWD="$LOCAL" notes deobfuscate
  [ -f "$LOCAL/notes/feature.md" ]
}

@test "merge: conflicting edits to same obfuscated file" {
  alpha_id=$(grep "alpha.md" "$LOCAL/notes/.manifest" | cut -f1)

  # Re-obfuscate for clean branch operations
  NOTES_CALLER_PWD="$LOCAL" notes obfuscate
  git -C "$LOCAL" checkout -- .

  # Create a branch, edit alpha's obfuscated file directly
  git -C "$LOCAL" checkout -q -b branch-a
  echo "branch-a edit" >> "$LOCAL/notes/$alpha_id"
  git -C "$LOCAL" add "notes/$alpha_id"
  git -C "$LOCAL" commit -q --no-verify -m "branch-a edits alpha"

  # Post-commit deobfuscates; return to obfuscated state for this low-level
  # conflict test before switching branches.
  NOTES_CALLER_PWD="$LOCAL" notes obfuscate

  # Back to main, edit alpha differently
  git -C "$LOCAL" checkout -q main
  echo "main edit" >> "$LOCAL/notes/$alpha_id"
  git -C "$LOCAL" add "notes/$alpha_id"
  git -C "$LOCAL" commit -q --no-verify -m "main edits alpha"

  # Merge should conflict
  run git -C "$LOCAL" merge branch-a --no-edit
  [ "$status" -ne 0 ]
  [[ "$(cat "$LOCAL/notes/$alpha_id")" == *"<<<<<<"* ]]
}

# ── Rebase ────────────────────────────────────────────────────

@test "rebase: works when only feature branch adds notes" {
  # Rebase succeeds when main doesn't touch the manifest
  NOTES_CALLER_PWD="$LOCAL" notes obfuscate
  git -C "$LOCAL" checkout -- .

  # Create a branch with a new note
  git -C "$LOCAL" checkout -q -b feature
  echo -e "---\ntitle: Feature\n---\n# Feature" > "$LOCAL/notes/feature.md"
  NOTES_CALLER_PWD="$LOCAL" notes obfuscate
  git -C "$LOCAL" commit -q --no-verify -m "add feature"

  # Main: non-notes change
  git -C "$LOCAL" checkout -q main
  echo "readme" > "$LOCAL/README.md"
  git -C "$LOCAL" add README.md
  git -C "$LOCAL" commit -q --no-verify -m "add readme"

  # Rebase feature onto main
  git -C "$LOCAL" checkout -q feature
  run git -C "$LOCAL" rebase main
  [ "$status" -eq 0 ]

  NOTES_CALLER_PWD="$LOCAL" notes deobfuscate
  [ -f "$LOCAL/notes/feature.md" ]
}

@test "rebase: concurrent note additions auto-merge via manifest driver" {
  # With the merge driver, concurrent manifest changes are union-merged.
  NOTES_CALLER_PWD="$LOCAL" notes obfuscate
  git -C "$LOCAL" checkout -- .

  # Feature branch: add a note
  git -C "$LOCAL" checkout -q -b feature
  echo -e "---\ntitle: Feature\n---\n# Feature" > "$LOCAL/notes/feature.md"
  NOTES_CALLER_PWD="$LOCAL" notes obfuscate
  git -C "$LOCAL" commit -q --no-verify -m "add feature"

  # Main: add a different note
  git -C "$LOCAL" checkout -q main
  echo -e "---\ntitle: Other\n---\n# Other" > "$LOCAL/notes/other.md"
  NOTES_CALLER_PWD="$LOCAL" notes obfuscate
  git -C "$LOCAL" commit -q --no-verify -m "add other"

  # Rebase succeeds — driver union-merges the manifest
  git -C "$LOCAL" checkout -q feature
  run git -C "$LOCAL" rebase main
  [ "$status" -eq 0 ]

  # Manifest has all entries
  grep -q "feature.md" "$LOCAL/notes/.manifest"
  grep -q "other.md" "$LOCAL/notes/.manifest"
}

@test "rebase: git-crypt manifest stays encrypted in rebased commit" {
  if ! command -v git-crypt >/dev/null; then
    skip "git-crypt not installed"
  fi

  local repo="$BATS_TEST_TMPDIR/crypt-rebase"
  mkdir -p "$repo/notes"
  git -C "$repo" init -q -b main
  git -C "$repo" config user.email "test@test.com"
  git -C "$repo" config user.name "Test"
  ( cd "$repo" && git-crypt init >/dev/null 2>&1 ) || skip "git-crypt init failed"

  cat > "$repo/.gitattributes" <<'EOT'
notes/** filter=git-crypt diff=git-crypt
notes/.manifest merge=manifest
EOT
  cat > "$repo/notes/.manifest" <<'EOT'
aaa00001	alpha.md
EOT
  echo "alpha" > "$repo/notes/aaa00001"
  git -C "$repo" add .gitattributes notes/.manifest notes/aaa00001
  git -C "$repo" commit -q -m "init"

  NOTES_CALLER_PWD="$repo" notes install-hooks --yes >/dev/null
  _use_local_merge_driver "$repo"

  git -C "$repo" switch -q -c feature
  cat > "$repo/notes/.manifest" <<'EOT'
aaa00001	alpha.md
bbb00001	beta.md
EOT
  echo "beta" > "$repo/notes/bbb00001"
  git -C "$repo" add notes/.manifest notes/bbb00001
  git -C "$repo" commit -q --no-verify -m "feature manifest"

  git -C "$repo" switch -q main
  cat > "$repo/notes/.manifest" <<'EOT'
aaa00001	alpha.md
ccc00001	gamma.md
EOT
  echo "gamma" > "$repo/notes/ccc00001"
  git -C "$repo" add notes/.manifest notes/ccc00001
  git -C "$repo" commit -q --no-verify -m "main manifest"

  git -C "$repo" switch -q feature
  run git -C "$repo" rebase main
  [ "$status" -eq 0 ]

  assert_gitcrypt_blob "$repo" "HEAD:notes/.manifest"
  grep -qF "beta.md" "$repo/notes/.manifest"
  grep -qF "gamma.md" "$repo/notes/.manifest"
  [ -z "$(git -C "$repo" status --short)" ]

  local merged_plain="$BATS_TEST_TMPDIR/crypt-rebase-merged"
  git -C "$repo" cat-file -p HEAD:notes/.manifest | (cd "$repo" && git-crypt smudge) > "$merged_plain"
  grep -qF "beta.md" "$merged_plain"
  grep -qF "gamma.md" "$merged_plain"
}
