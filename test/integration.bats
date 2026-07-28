#!/usr/bin/env bats
# Integration tests for the encryption workflow: setup → add-user → lock → unlock → status

load test_helper

# Override setup/teardown for GPG isolation
setup() {
  # Short temp path — gpg-agent Unix socket has 104-char limit on macOS
  export TEST_DIR=$(mktemp -d /tmp/notes-test.XXXXXX)

  export TARGET_DIR="$TEST_DIR/repo"
  mkdir -p "$TARGET_DIR"
  git -C "$TARGET_DIR" init -q -b main
  git -C "$TARGET_DIR" config user.email "test@notes.local"
  git -C "$TARGET_DIR" config user.name "notes-test"
  git -C "$TARGET_DIR" config commit.gpgsign false

  export NOTES_CALLER_PWD="$TARGET_DIR"
  source "$REPO_DIR/lib/common.sh"

  # Isolated GPG home
  export GNUPGHOME="$TEST_DIR/gpg"
  mkdir -p "$GNUPGHOME"
  chmod 700 "$GNUPGHOME"
}

teardown() {
  gpgconf --homedir "$GNUPGHOME" --kill gpg-agent 2>/dev/null || true
  rm -rf "$TEST_DIR"
}

generate_test_key() {
  local homedir="$1"
  gpg --homedir "$homedir" --batch --passphrase '' --quick-gen-key \
    "test-user <test@notes.local>" default default never 2>/dev/null
  gpg --homedir "$homedir" --batch --with-colons --list-keys 2>/dev/null \
    | awk -F: '/^fpr/{print $10; exit}'
}

# --- add-user ---

@test "add-user adds collaborator via rudi" {
  notes setup --yes

  local fpr
  fpr=$(generate_test_key "$GNUPGHOME")
  [ -n "$fpr" ]

  run notes add-user -- --gpg-key "$fpr"
  [ "$status" -eq 0 ]

  # Key file should exist in .git-crypt
  [ -f "$TARGET_DIR/.git-crypt/keys/default/0/$fpr.gpg" ]
}

@test "setup parses variadic configuration before mutation" {
  local mock_bin="$BATS_TEST_TMPDIR/failing-xargs-bin"
  make_failing_xargs_overlay "$mock_bin"

  PATH="$mock_bin:$PATH" run notes setup --yes --pattern 'notes/**'

  [ "$status" -eq 73 ]
  [[ "$output" == *"failed to parse variadic arguments"* ]]
  [ ! -e "$TARGET_DIR/.git-crypt" ]
  [ ! -e "$TARGET_DIR/.gitattributes" ]
}

# --- lock / unlock round-trip ---

@test "lock and unlock round-trip preserves file content" {
  notes setup --yes

  local fpr
  fpr=$(generate_test_key "$GNUPGHOME")
  notes add-user -- --gpg-key "$fpr"

  # Commit a file in the encrypted path
  mkdir -p "$TARGET_DIR/notes"
  echo "secret content" > "$TARGET_DIR/notes/secret.md"
  git -C "$TARGET_DIR" add .
  git -C "$TARGET_DIR" commit -q -m "Add encrypted note"

  local state="$TARGET_DIR/.git/info/notes-obfuscation-state"
  [ -f "$state" ]
  awk -F '\t' 'NF >= 4 && $4 != "" { found=1 } END { exit !found }' "$state"

  # Lock
  run notes lock --yes
  [ "$status" -eq 0 ]

  # Neither plaintext nor its raw content hashes remain after locking.
  ! grep -q "secret content" "$TARGET_DIR/notes/secret.md" 2>/dev/null
  [ ! -e "$state" ]

  # Unlock
  run notes unlock
  [ "$status" -eq 0 ]

  # File should be readable again
  grep -q "secret content" "$TARGET_DIR/notes/secret.md"
}

@test "lock removes plaintext hashes before invoking rudi" {
  notes setup --yes

  local fpr
  fpr=$(generate_test_key "$GNUPGHOME")
  notes add-user -- --gpg-key "$fpr"

  mkdir -p "$TARGET_DIR/notes"
  echo "secret content" > "$TARGET_DIR/notes/secret.md"
  git -C "$TARGET_DIR" add .
  git -C "$TARGET_DIR" commit -q -m "Add encrypted note"

  local state="$TARGET_DIR/.git/info/notes-obfuscation-state"
  local fake_bin="$BATS_TEST_TMPDIR/fake-lock-bin"
  local lock_log="$BATS_TEST_TMPDIR/rudi-lock.log"
  [ -f "$state" ]
  mkdir -p "$fake_bin"

  cat > "$fake_bin/rudi" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[ "${1:-}" = "lock" ] || exit 64
[ ! -e "${RUDI_STATE_FILE:?RUDI_STATE_FILE not set}" ] || exit 74
: > "${RUDI_LOCK_LOG:?RUDI_LOCK_LOG not set}"
exit 73
SH
  chmod +x "$fake_bin/rudi"
  export RUDI_STATE_FILE="$state"
  export RUDI_LOCK_LOG="$lock_log"

  PATH="$fake_bin:$PATH" run notes lock --yes
  [ "$status" -eq 73 ]
  [ -f "$lock_log" ]
  [ ! -e "$state" ]
}

@test "unlock no-ops when already unlocked, even with a dirty tree (#42)" {
  notes setup --yes

  local fpr
  fpr=$(generate_test_key "$GNUPGHOME")
  notes add-user -- --gpg-key "$fpr"

  # Tracked dirty readable file reproduces git-crypt's unlock guard; see #42.
  mkdir -p "$TARGET_DIR/notes"
  echo "original" > "$TARGET_DIR/notes/secret.md"
  git -C "$TARGET_DIR" add notes/secret.md
  git -C "$TARGET_DIR" commit -q --no-verify -m "Add readable note"
  echo "local edit" >> "$TARGET_DIR/notes/secret.md"

  [ -n "$(git -C "$TARGET_DIR" status --porcelain)" ]

  run notes unlock
  [ "$status" -eq 0 ]
  [[ "$output" == *"Already unlocked."* ]]

  # Local edit survives the no-op.
  grep -q "local edit" "$TARGET_DIR/notes/secret.md"
}

@test "lock refuses without confirmation before staging or obfuscating" {
  notes setup --yes

  local fpr
  fpr=$(generate_test_key "$GNUPGHOME")
  notes add-user -- --gpg-key "$fpr"

  mkdir -p "$TARGET_DIR/notes"
  echo "plain note" > "$TARGET_DIR/notes/plain.md"
  git -C "$TARGET_DIR" add .
  git -C "$TARGET_DIR" commit -q --no-verify -m "Add encrypted note"

  run without_confirmation "$TEST_DIR/missing-tty" notes lock

  [ "$status" -eq 2 ]
  [[ "$output" == *"confirmation required"* ]]
  [[ "$output" == *"Re-run with --yes"* ]]
  [ -f "$TARGET_DIR/notes/plain.md" ]
  grep -q "plain note" "$TARGET_DIR/notes/plain.md"
  ! grep -q "plain.md" "$TARGET_DIR/notes/.manifest"
  [ -z "$(git -C "$TARGET_DIR" diff --cached --name-only)" ]
}

@test "unlock --force refuses without confirmation for dirty readable overwrite" {
  notes setup --yes

  local fpr
  fpr=$(generate_test_key "$GNUPGHOME")
  notes add-user -- --gpg-key "$fpr"

  # Create, obfuscate, commit, then deobfuscate — unlock without --force is clean
  mkdir -p "$TARGET_DIR/notes"
  echo "secret content" > "$TARGET_DIR/notes/secret.md"
  git -C "$TARGET_DIR" add .
  git -C "$TARGET_DIR" commit -q --no-verify -m "Add encrypted note"

  run without_confirmation "$TEST_DIR/missing-tty" notes unlock --force

  [ "$status" -eq 2 ]
  [[ "$output" == *"confirmation required"* ]]
  [[ "$output" == *"Re-run with --yes"* ]]
}

@test "unlock --force refuses before running rudi unlock when locked" {
  local repo fake_bin log
  repo="$BATS_TEST_TMPDIR/locked-force-repo"
  fake_bin="$BATS_TEST_TMPDIR/fake-bin"
  log="$BATS_TEST_TMPDIR/rudi-unlock.log"
  mkdir -p "$repo/notes" "$repo/.git-crypt" "$fake_bin"
  git -C "$repo" init -q
  git -C "$repo" config user.name "Test"
  git -C "$repo" config user.email "test@test.com"
  printf 'aaa00001\talpha.md\n' > "$repo/notes/.manifest"
  printf 'encrypted-ish\n' > "$repo/notes/aaa00001"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m "init"

  cat > "$fake_bin/rudi" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  status)
    if [ "${2:-}" = "--json" ]; then
      printf '{"initialized":true,"unlocked":false}\n'
      exit 0
    fi
    printf 'locked\n'
    ;;
  unlock)
    : > "${RUDI_UNLOCK_LOG:?RUDI_UNLOCK_LOG not set}"
    printf 'fake rudi unlock ran\n'
    ;;
  *)
    printf 'fake rudi: unsupported command: %s\n' "$*" >&2
    exit 1
    ;;
esac
SH
  chmod +x "$fake_bin/rudi"

  run bash -c '
    set -euo pipefail
    export NOTES_CALLER_PWD="$1"
    export PATH="$2:$PATH"
    export RUDI_UNLOCK_LOG="$3"
    without_confirmation "$4" notes unlock --force
  ' _ "$repo" "$fake_bin" "$log" "$TEST_DIR/missing-tty"

  [ "$status" -eq 2 ]
  [[ "$output" == *"confirmation required"* ]]
  [ ! -e "$log" ]
}

@test "unlock --force --yes proceeds with deobfuscation" {
  notes setup --yes

  local fpr
  fpr=$(generate_test_key "$GNUPGHOME")
  notes add-user -- --gpg-key "$fpr"

  mkdir -p "$TARGET_DIR/notes"
  echo "secret content" > "$TARGET_DIR/notes/secret.md"
  git -C "$TARGET_DIR" add .
  git -C "$TARGET_DIR" commit -q --no-verify -m "Add encrypted note"

  run notes unlock --force --yes
  [ "$status" -eq 0 ]
  # Should have deobfuscated (file still readable after unlock)
  grep -q "secret content" "$TARGET_DIR/notes/secret.md"
}

# --- status ---

@test "status shows encryption info" {
  notes setup --yes

  local fpr
  fpr=$(generate_test_key "$GNUPGHOME")
  notes add-user -- --gpg-key "$fpr"

  run notes status
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

# --- end-to-end ---

@test "full workflow: setup → add-user → commit → lock → unlock → verify" {
  # 1. Setup with default pattern
  run notes setup --yes
  [ "$status" -eq 0 ]
  [ -f "$TARGET_DIR/.gitattributes" ]

  # 2. Add a collaborator
  local fpr
  fpr=$(generate_test_key "$GNUPGHOME")
  notes add-user -- --gpg-key "$fpr"
  [ -f "$TARGET_DIR/.git-crypt/keys/default/0/$fpr.gpg" ]

  # 3. Commit encrypted files
  mkdir -p "$TARGET_DIR/notes"
  echo "top secret" > "$TARGET_DIR/notes/classified.md"
  echo "also secret" > "$TARGET_DIR/notes/private.md"
  echo "not encrypted" > "$TARGET_DIR/public.md"
  git -C "$TARGET_DIR" add .
  git -C "$TARGET_DIR" commit -q -m "Add files"

  # 4. Lock
  notes lock --yes
  ! grep -q "top secret" "$TARGET_DIR/notes/classified.md" 2>/dev/null
  ! grep -q "also secret" "$TARGET_DIR/notes/private.md" 2>/dev/null
  # Public file should be unaffected
  grep -q "not encrypted" "$TARGET_DIR/public.md"

  # 5. Unlock
  notes unlock
  grep -q "top secret" "$TARGET_DIR/notes/classified.md"
  grep -q "also secret" "$TARGET_DIR/notes/private.md"

  # 6. Verify the key
  local keyfile="$TEST_DIR/test.pub.asc"
  gpg --homedir "$GNUPGHOME" --batch --armor --export "$fpr" > "$keyfile"
  run notes verify -- --gpg-key "$fpr" --key-file "$keyfile"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Verified"* ]]
}

# --- lock/unlock + obfuscation chaining ---

setup_encrypted_repo_with_obfuscation() {
  notes setup --yes

  local fpr
  fpr=$(generate_test_key "$GNUPGHOME")
  notes add-user -- --gpg-key "$fpr"

  mkdir -p "$TARGET_DIR/notes"
  echo "alpha content" > "$TARGET_DIR/notes/alpha.md"
  echo "beta content" > "$TARGET_DIR/notes/beta.md"
  git -C "$TARGET_DIR" add .
  git -C "$TARGET_DIR" commit -q -m "Add notes"

  # Obfuscate to create the manifest
  notes obfuscate
  git -C "$TARGET_DIR" add .
  git -C "$TARGET_DIR" commit -q -m "Obfuscate"

  # Deobfuscate so we're in working state
  notes deobfuscate
  git -C "$TARGET_DIR" add .
  git -C "$TARGET_DIR" commit -q --no-verify -m "Deobfuscate for working"
}

# TODO: lock tests skip — deobfuscated working tree is "dirty" to git-crypt lock.
# Needs rudi --force support or a clean-status obfuscation design.
# See notes#31, BULLETIN.md design thread.
@test "lock obfuscates filenames before locking" {
  skip "git-crypt lock rejects deobfuscated working tree (needs rudi --force)"
  setup_encrypted_repo_with_obfuscation

  # Files should be deobfuscated before lock
  [ -f "$TARGET_DIR/notes/alpha.md" ]
  [ -f "$TARGET_DIR/notes/beta.md" ]

  notes lock --yes

  # Files should be obfuscated (hex IDs, not readable names)
  [ ! -f "$TARGET_DIR/notes/alpha.md" ]
  [ ! -f "$TARGET_DIR/notes/beta.md" ]

  # Manifest should still exist (also encrypted, but file present)
  [ -f "$TARGET_DIR/notes/.manifest" ]
}

@test "unlock deobfuscates filenames after unlocking" {
  skip "git-crypt lock rejects deobfuscated working tree (needs rudi --force)"
  setup_encrypted_repo_with_obfuscation

  notes lock --yes
  # Files are obfuscated + encrypted
  [ ! -f "$TARGET_DIR/notes/alpha.md" ]

  notes unlock

  # Files should be back to readable names
  [ -f "$TARGET_DIR/notes/alpha.md" ]
  [ -f "$TARGET_DIR/notes/beta.md" ]
  grep -q "alpha content" "$TARGET_DIR/notes/alpha.md"
  grep -q "beta content" "$TARGET_DIR/notes/beta.md"
}

@test "lock → unlock round-trip preserves content with obfuscation" {
  skip "git-crypt lock rejects deobfuscated working tree (needs rudi --force)"
  setup_encrypted_repo_with_obfuscation

  notes lock --yes
  notes unlock

  grep -q "alpha content" "$TARGET_DIR/notes/alpha.md"
  grep -q "beta content" "$TARGET_DIR/notes/beta.md"
}

@test "unlock without manifest does not attempt deobfuscation" {
  # Plain encrypted repo, no obfuscation
  notes setup --yes

  local fpr
  fpr=$(generate_test_key "$GNUPGHOME")
  notes add-user -- --gpg-key "$fpr"

  mkdir -p "$TARGET_DIR/notes"
  echo "plain note" > "$TARGET_DIR/notes/plain.md"
  git -C "$TARGET_DIR" add .
  git -C "$TARGET_DIR" commit -q -m "Add note"

  notes lock --yes
  run notes unlock
  [ "$status" -eq 0 ]

  # File should be readable with original name
  [ -f "$TARGET_DIR/notes/plain.md" ]
  grep -q "plain note" "$TARGET_DIR/notes/plain.md"
}

@test "lock obfuscates when setup-created manifest exists" {
  notes setup --yes

  local fpr
  fpr=$(generate_test_key "$GNUPGHOME")
  notes add-user -- --gpg-key "$fpr"

  mkdir -p "$TARGET_DIR/notes"
  echo "plain note" > "$TARGET_DIR/notes/plain.md"
  git -C "$TARGET_DIR" add .
  git -C "$TARGET_DIR" commit -q -m "Add note"

  # Capture the manifest entry while unlocked; lock encrypts .manifest too.
  local id
  id=$(awk '$2 == "plain.md" { print $1 }' "$TARGET_DIR/notes/.manifest")
  [ -n "$id" ]

  run notes lock --yes
  [ "$status" -eq 0 ]

  # setup creates .manifest, so lock should keep the committed obfuscated shape.
  [ ! -f "$TARGET_DIR/notes/plain.md" ]
  [ -f "$TARGET_DIR/notes/$id" ]
}

# --- encryption pre-commit hook (#49) ---
# The hook is invoked by git with cwd = repo root; replicate that.
run_encryption_hook() {
  run bash -c "cd '$TARGET_DIR' && bash .git/hooks/pre-commit.d/encryption"
}

@test "encryption hook passes when no encrypted-pattern file is staged (#49)" {
  notes setup --yes
  local fpr
  fpr=$(generate_test_key "$GNUPGHOME")
  notes add-user -- --gpg-key "$fpr"

  # A file outside any encrypted pattern — the common commit that touches no notes.
  echo "public" > "$TARGET_DIR/README.md"
  git -C "$TARGET_DIR" add README.md

  run_encryption_hook
  [ "$status" -eq 0 ]
}

@test "encryption hook blocks plaintext staged under an encrypted path (#49)" {
  notes setup --yes
  local fpr
  fpr=$(generate_test_key "$GNUPGHOME")
  notes add-user -- --gpg-key "$fpr"

  # Inject a plaintext blob into the index for an encrypted path, bypassing the
  # git-crypt clean filter — simulates staging while git-crypt is locked.
  mkdir -p "$TARGET_DIR/notes"
  printf 'PLAINTEXT-LEAK\n' > "$TARGET_DIR/notes/leak.md"
  local blob
  blob=$(printf 'PLAINTEXT-LEAK\n' | git -C "$TARGET_DIR" hash-object -w --stdin)
  git -C "$TARGET_DIR" update-index --add --cacheinfo 100644 "$blob" notes/leak.md

  run_encryption_hook
  [ "$status" -eq 1 ]
  [[ "$output" == *"should be encrypted but are plaintext"* ]]
  [[ "$output" == *"notes/leak.md"* ]]
}

@test "encryption hook uses staged attributes when checking staged plaintext (#49)" {
  notes setup --yes
  local fpr
  fpr=$(generate_test_key "$GNUPGHOME")
  notes add-user -- --gpg-key "$fpr"

  # The commit snapshot can differ from the worktree. If the hook consults
  # worktree attributes, it can miss a staged encryption rule and allow a
  # plaintext blob into an encrypted path.
  printf 'notes/** filter=git-crypt diff=git-crypt\n' > "$TARGET_DIR/.gitattributes"
  git -C "$TARGET_DIR" add .gitattributes
  printf '# worktree attributes intentionally differ from the index\n' > "$TARGET_DIR/.gitattributes"

  mkdir -p "$TARGET_DIR/notes"
  printf 'PLAINTEXT-LEAK\n' > "$TARGET_DIR/notes/leak.md"
  local blob
  blob=$(printf 'PLAINTEXT-LEAK\n' | git -C "$TARGET_DIR" hash-object -w --stdin)
  git -C "$TARGET_DIR" update-index --add --cacheinfo 100644 "$blob" notes/leak.md

  run_encryption_hook
  [ "$status" -eq 1 ]
  [[ "$output" == *"should be encrypted but are plaintext"* ]]
  [[ "$output" == *"notes/leak.md"* ]]
}

@test "encryption hook blocks plaintext renamed into an encrypted path (#49)" {
  notes setup --yes
  local fpr
  fpr=$(generate_test_key "$GNUPGHOME")
  notes add-user -- --gpg-key "$fpr"

  printf 'PLAINTEXT-LEAK\n' > "$TARGET_DIR/public.md"
  git -C "$TARGET_DIR" add .
  git -C "$TARGET_DIR" commit -q --no-verify -m "baseline public file"

  # With rename detection enabled, git diff classifies this as R rather than A.
  # The hook must still inspect the destination path before committing it under
  # the encrypted pattern.
  git -C "$TARGET_DIR" config diff.renames true
  git -C "$TARGET_DIR" mv public.md notes/leak.md

  run_encryption_hook
  [ "$status" -eq 1 ]
  [[ "$output" == *"should be encrypted but are plaintext"* ]]
  [[ "$output" == *"notes/leak.md"* ]]
}

@test "encryption hook passes when an encrypted-path file is properly encrypted (#49)" {
  notes setup --yes
  local fpr
  fpr=$(generate_test_key "$GNUPGHOME")
  notes add-user -- --gpg-key "$fpr"

  # Staged while unlocked: the clean filter encrypts the blob, so the hook is happy.
  mkdir -p "$TARGET_DIR/notes"
  echo "secret" > "$TARGET_DIR/notes/ok.md"
  git -C "$TARGET_DIR" add notes/ok.md

  run_encryption_hook
  [ "$status" -eq 0 ]
}

@test "encryption hook checks multiple valid staged paths in one git-crypt call (#49)" {
  notes setup --yes
  local fpr
  fpr=$(generate_test_key "$GNUPGHOME")
  notes add-user -- --gpg-key "$fpr"

  mkdir -p "$TARGET_DIR/notes"
  printf '%s\n' "first secret" > "$TARGET_DIR/notes/first.md"
  printf '%s\n' "second secret" > "$TARGET_DIR/notes/second.md"
  git -C "$TARGET_DIR" add notes/first.md notes/second.md

  local mock_bin="$BATS_TEST_TMPDIR/counting-git-crypt-bin"
  local calls="$BATS_TEST_TMPDIR/git-crypt-calls"
  export GIT_CRYPT_CALLS="$calls"
  mkdir -p "$mock_bin"
  cat > "$mock_bin/git-crypt" <<'SH'
#!/usr/bin/env bash
printf 'call\n' >> "$GIT_CRYPT_CALLS"
PATH="${PATH#*:}" exec git-crypt "$@"
SH
  chmod +x "$mock_bin/git-crypt"
  export PATH="$mock_bin:$PATH"

  run_encryption_hook
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$calls" | tr -d ' ')" -eq 1 ]
}

@test "encryption hook fails closed when staged-path inspection fails (#49)" {
  notes setup --yes

  printf '%s\n' "public" > "$TARGET_DIR/public.md"
  git -C "$TARGET_DIR" add public.md

  local mock_bin="$BATS_TEST_TMPDIR/failing-encryption-diff-bin"
  local real_git
  real_git=$(command -v git)
  mkdir -p "$mock_bin"
  cat > "$mock_bin/git" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "diff" ]; then
  printf '%s\n' "staged inspection failed" >&2
  exit 73
fi
exec "$REAL_GIT" "$@"
SH
  chmod +x "$mock_bin/git"
  export PATH="$mock_bin:$PATH"
  export REAL_GIT="$real_git"

  run_encryption_hook
  [ "$status" -eq 1 ]
  [[ "$output" == *"staged inspection failed"* ]]
  [[ "$output" == *"Could not inspect staged paths for encryption"* ]]
}

@test "encryption hook fails closed when staged-attribute inspection fails (#49)" {
  notes setup --yes

  mkdir -p "$TARGET_DIR/notes"
  printf '%s\n' "secret" > "$TARGET_DIR/notes/secret.md"
  git -C "$TARGET_DIR" add notes/secret.md

  local mock_bin="$BATS_TEST_TMPDIR/failing-encryption-attr-bin"
  local real_git
  real_git=$(command -v git)
  mkdir -p "$mock_bin"
  cat > "$mock_bin/git" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "check-attr" ]; then
  printf '%s\n' "attribute inspection failed" >&2
  exit 74
fi
exec "$REAL_GIT" "$@"
SH
  chmod +x "$mock_bin/git"
  export PATH="$mock_bin:$PATH"
  export REAL_GIT="$real_git"

  run_encryption_hook
  [ "$status" -eq 1 ]
  [[ "$output" == *"attribute inspection failed"* ]]
  [[ "$output" == *"Could not inspect staged encryption attributes"* ]]
}


@test "encryption hook falls back per path after a batched plaintext result (#49)" {
  notes setup --yes
  local fpr
  fpr=$(generate_test_key "$GNUPGHOME")
  notes add-user -- --gpg-key "$fpr"

  mkdir -p "$TARGET_DIR/notes"
  local file blob
  for file in first.md second.md; do
    blob=$(printf 'PLAINTEXT-LEAK\n' | git -C "$TARGET_DIR" hash-object -w --stdin)
    git -C "$TARGET_DIR" update-index --add --cacheinfo \
      100644 "$blob" "notes/$file"
  done

  local mock_bin="$BATS_TEST_TMPDIR/fallback-git-crypt-bin"
  local calls="$BATS_TEST_TMPDIR/git-crypt-fallback-calls"
  export GIT_CRYPT_CALLS="$calls"
  mkdir -p "$mock_bin"
  cat > "$mock_bin/git-crypt" <<'SH'
#!/usr/bin/env bash
printf 'call\n' >> "$GIT_CRYPT_CALLS"
PATH="${PATH#*:}" exec git-crypt "$@"
SH
  chmod +x "$mock_bin/git-crypt"
  export PATH="$mock_bin:$PATH"

  run_encryption_hook
  [ "$status" -eq 1 ]
  [[ "$output" == *"notes/first.md"* ]]
  [[ "$output" == *"notes/second.md"* ]]
  [ "$(wc -l < "$calls" | tr -d ' ')" -eq 3 ]
}

@test "encryption hook fails closed when git-crypt cannot inspect a staged path (#49)" {
  notes setup --yes
  local fpr
  fpr=$(generate_test_key "$GNUPGHOME")
  notes add-user -- --gpg-key "$fpr"

  mkdir -p "$TARGET_DIR/notes"
  echo "secret" > "$TARGET_DIR/notes/ok.md"
  git -C "$TARGET_DIR" add notes/ok.md

  local mock_bin="$BATS_TEST_TMPDIR/mock-git-crypt-bin"
  mkdir -p "$mock_bin"
  cat > "$mock_bin/git-crypt" <<'SH'
#!/usr/bin/env bash
echo "backend inspection failed" >&2
exit 73
SH
  chmod +x "$mock_bin/git-crypt"
  export PATH="$mock_bin:$PATH"

  run_encryption_hook
  [ "$status" -eq 1 ]
  [[ "$output" == *"could not inspect staged encrypted path: notes/ok.md"* ]]
  [[ "$output" == *"backend inspection failed"* ]]
}

# --- double-tracking pre-commit hook (#51) ---
run_double_tracking_hook() {
  run bash -c "cd '$TARGET_DIR' && bash .git/hooks/pre-commit.d/verify-double-tracking"
}

@test "double-tracking hook passes when no manifest exists (#51)" {
  notes setup --yes
  # Fresh repo with .manifest absent: nothing to compare against.
  rm -f "$TARGET_DIR/notes/.manifest"

  run_double_tracking_hook
  [ "$status" -eq 0 ]
}

@test "double-tracking hook passes when only obfuscated paths are tracked (#51)" {
  notes setup --yes
  printf 'aaaaaaaa\talpha.md\n' > "$TARGET_DIR/notes/.manifest"
  echo "# Alpha" > "$TARGET_DIR/notes/aaaaaaaa"
  git -C "$TARGET_DIR" add -A
  git -C "$TARGET_DIR" commit -q --no-verify -m "init"

  run_double_tracking_hook
  [ "$status" -eq 0 ]
}

@test "double-tracking hook blocks commit when readable + obfuscated both tracked (#51)" {
  notes setup --yes
  printf 'aaaaaaaa\talpha.md\n' > "$TARGET_DIR/notes/.manifest"
  echo "# Alpha readable" > "$TARGET_DIR/notes/alpha.md"
  echo "# Alpha obfuscated" > "$TARGET_DIR/notes/aaaaaaaa"
  # Force-add the readable past the local exclude rules to simulate the bug.
  git -C "$TARGET_DIR" add -f notes/alpha.md
  git -C "$TARGET_DIR" add notes/.manifest notes/aaaaaaaa
  git -C "$TARGET_DIR" commit -q --no-verify -m "double-tracked baseline"

  run_double_tracking_hook
  [ "$status" -eq 1 ]
  [[ "$output" == *"double-tracked"* ]]
  [[ "$output" == *"notes/alpha.md"* ]]
  [[ "$output" == *"notes/aaaaaaaa"* ]]
  [[ "$output" == *"git rm --cached"* ]]
}

@test "double-tracking hook is installed by setup (#51)" {
  notes setup --yes
  [ -x "$TARGET_DIR/.git/hooks/pre-commit.d/verify-double-tracking" ]
  grep -q "double-tracked notes detected" "$TARGET_DIR/.git/hooks/pre-commit.d/verify-double-tracking"
}

@test "pre-commit dispatcher lets obfuscation fix staged readable before double-tracking check (#51)" {
  notes setup --yes
  local fpr
  fpr=$(generate_test_key "$GNUPGHOME")
  notes add-user -- --gpg-key "$fpr"

  mkdir -p "$TARGET_DIR/notes"
  printf '# Alpha\n' > "$TARGET_DIR/notes/alpha.md"
  git -C "$TARGET_DIR" add notes/alpha.md

  run git -C "$TARGET_DIR" commit -m "add alpha"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Auto-obfuscating 1 file(s)"* ]]
  [[ "$output" != *"double-tracked notes detected"* ]]

  local id
  id=$(awk '$2 == "alpha.md" { print $1 }' "$TARGET_DIR/notes/.manifest")
  [ -n "$id" ]
  git -C "$TARGET_DIR" cat-file -e "HEAD:notes/$id"
  git -C "$TARGET_DIR" cat-file -e "HEAD:notes/.manifest"
  ! git -C "$TARGET_DIR" cat-file -e "HEAD:notes/alpha.md" 2>/dev/null
}
