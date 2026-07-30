#!/usr/bin/env bats

load test_helper

commit_tracked_plaintext_notes() {
  mkdir -p "$TARGET_DIR/notes"
  printf '# Existing alpha\n' > "$TARGET_DIR/notes/alpha.md"
  printf '# Existing beta\n' > "$TARGET_DIR/notes/beta.md"
  git -C "$TARGET_DIR" add notes
  git -C "$TARGET_DIR" commit -q -m "add plaintext notes"
}

setup_locked_rudi_overlay() {
  LOCKED_RUDI_BIN="$BATS_TEST_TMPDIR/locked-rudi-bin"
  mkdir -p "$LOCKED_RUDI_BIN"
  cat > "$LOCKED_RUDI_BIN/rudi" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  status)
    printf '{"unlocked":false}\n'
    ;;
  unlock)
    if [ -n "$(git -C "${RUDI_CALLER_PWD:?}" status --porcelain)" ]; then
      echo "unlock saw dirty worktree" >&2
      exit 73
    fi
    touch "$RUDI_CALLER_PWD/.unlock-ran-clean"
    ;;
  assign)
    printf '%-40s filter=git-crypt diff=git-crypt\n' "$2" \
      >> "$RUDI_CALLER_PWD/.gitattributes"
    ;;
  *)
    echo "unexpected rudi command: $*" >&2
    exit 99
    ;;
esac
SH
  chmod +x "$LOCKED_RUDI_BIN/rudi"
}

setup_failing_encrypted_note_enumeration_overlay() {
  FAILING_FIND_BIN="$BATS_TEST_TMPDIR/failing-encrypted-note-find"
  local real_find
  real_find=$(command -v find)
  mkdir -p "$FAILING_FIND_BIN"
  cat > "$FAILING_FIND_BIN/find" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "$NOTES_CALLER_PWD/notes" ] && [[ " $* " == *" -print0 "* ]]; then
  echo "encrypted note enumeration failed" >&2
  exit 73
fi
exec "$REAL_FIND" "$@"
SH
  chmod +x "$FAILING_FIND_BIN/find"
  export REAL_FIND="$real_find"
}

@test "is_initialized returns false on fresh repo" {
  run is_initialized
  [ "$status" -ne 0 ]
}

@test "is_initialized returns true after git crypt init" {
  git -C "$TARGET_DIR" crypt init
  run is_initialized
  [ "$status" -eq 0 ]
}

@test "require_git fails on non-git directory" {
  export NOTES_CALLER_PWD="$BATS_TEST_TMPDIR/not-a-repo"
  mkdir -p "$NOTES_CALLER_PWD"
  source "$REPO_DIR/lib/common.sh"
  run require_git
  [ "$status" -ne 0 ]
  [[ "$output" == *"not a git repository"* ]]
}

@test "require_initialized fails when not initialized" {
  run require_initialized
  [ "$status" -ne 0 ]
  [[ "$output" == *"not initialized"* ]]
}

@test "setup writes .gitattributes with default pattern" {
  run notes setup --yes
  [ "$status" -eq 0 ]

  [ -f "$TARGET_DIR/.gitattributes" ]
  grep -q "notes/\*\*" "$TARGET_DIR/.gitattributes"
  grep -q "git-crypt" "$TARGET_DIR/.gitattributes"
}

@test "setup is idempotent" {
  notes setup --yes

  run notes setup --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"git-crypt already initialized — updating auxiliary files..."* ]]
  [[ "$output" == *"Requested encrypted patterns already configured"* ]]
}

@test "setup rerun does not classify locked managed blobs as plaintext" {
  mkdir -p "$TARGET_DIR/.git/git-crypt" "$TARGET_DIR/notes"
  printf '\0GITCRYPT\0aaa00001\talpha.md\n' > "$TARGET_DIR/notes/.manifest"
  printf '\0GITCRYPT\0encrypted alpha\n' > "$TARGET_DIR/notes/aaa00001"
  git -C "$TARGET_DIR" add notes
  printf 'notes/** filter=git-crypt diff=git-crypt\n' > "$TARGET_DIR/.gitattributes"
  git -C "$TARGET_DIR" add .gitattributes
  git -C "$TARGET_DIR" commit -q -m "add locked managed notes"

  run notes setup --yes

  [ "$status" -eq 0 ]
  [[ "$output" != *"tracked plaintext note(s)"* ]]
  [[ "$output" == *"This repo already has encrypted notes."* ]]
}

@test "setup adds notes pattern when other git-crypt patterns already exist" {
  git -C "$TARGET_DIR" crypt init
  echo ".modules/manifest filter=git-crypt diff=git-crypt" > "$TARGET_DIR/.gitattributes"

  run notes setup --yes
  [ "$status" -eq 0 ]

  grep -Eq "^\.modules/manifest[[:space:]]+filter=git-crypt" "$TARGET_DIR/.gitattributes"
  grep -Eq "^notes/\*\*[[:space:]]+filter=git-crypt" "$TARGET_DIR/.gitattributes"
}

@test "setup treats disabled filter attribute as missing encrypted pattern" {
  git -C "$TARGET_DIR" crypt init
  echo "notes/** -filter=git-crypt diff=git-crypt" > "$TARGET_DIR/.gitattributes"

  run notes setup --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"Configuring encrypted patterns"* ]]

  grep -Eq "^notes/\*\*[[:space:]]+filter=git-crypt" "$TARGET_DIR/.gitattributes"
}

@test "setup with custom patterns writes them to .gitattributes" {
  run notes setup --yes --pattern "agents/*/Zettels/**" --pattern "notes/private/**"
  [ "$status" -eq 0 ]

  grep -Eq "^agents/\*/Zettels/\*\*[[:space:]]+filter=git-crypt" "$TARGET_DIR/.gitattributes"
  grep -Eq "^notes/private/\*\*[[:space:]]+filter=git-crypt" "$TARGET_DIR/.gitattributes"
}

@test "setup refuses dirty tracked plaintext onboarding before mutation" {
  commit_tracked_plaintext_notes
  printf '# Local edit\n' >> "$TARGET_DIR/notes/alpha.md"

  run notes setup --yes

  [ "$status" -ne 0 ]
  [[ "$output" == *"requires a clean worktree"* ]]
  [ ! -d "$TARGET_DIR/.git/git-crypt" ]
  [ ! -f "$TARGET_DIR/.gitattributes" ]
  [ ! -f "$TARGET_DIR/notes/.manifest" ]
}

@test "setup refuses sparse tracked plaintext onboarding before mutation" {
  commit_tracked_plaintext_notes
  git -C "$TARGET_DIR" sparse-checkout init --no-cone
  git -C "$TARGET_DIR" sparse-checkout set --no-cone \
    '/*' '!/*/' '/notes/alpha.md'
  [ -f "$TARGET_DIR/notes/alpha.md" ]
  [ ! -e "$TARGET_DIR/notes/beta.md" ]

  run notes setup --yes

  [ "$status" -ne 0 ]
  [[ "$output" == *"not available as a regular worktree file"* ]]
  [[ "$output" == *"expand or disable sparse checkout"* ]]
  [ ! -d "$TARGET_DIR/.git/git-crypt" ]
  [ ! -f "$TARGET_DIR/.gitattributes" ]
  [ ! -f "$TARGET_DIR/notes/.manifest" ]
}

@test "setup --unlock unlocks existing repo before setup mutation" {
  commit_tracked_plaintext_notes
  mkdir -p "$TARGET_DIR/.git/git-crypt"
  setup_locked_rudi_overlay

  PATH="$LOCKED_RUDI_BIN:$PATH" run notes setup --yes --unlock

  [ "$status" -eq 0 ]
  [ -f "$TARGET_DIR/.unlock-ran-clean" ]
  grep -Eq "^notes/\*\*[[:space:]]+filter=git-crypt" "$TARGET_DIR/.gitattributes"
}

@test "setup with custom dir writes manifest and default encrypted pattern there" {
  run notes setup --yes --dir private-notes
  [ "$status" -eq 0 ]

  [ -f "$TARGET_DIR/private-notes/.manifest" ]
  [ ! -f "$TARGET_DIR/notes/.manifest" ]
  grep -Eq "^private-notes/\*\*[[:space:]]+filter=git-crypt" "$TARGET_DIR/.gitattributes"
  grep -qF "private-notes/.manifest merge=manifest" "$TARGET_DIR/.gitattributes"
  grep -q "private-notes" "$TARGET_DIR/.git/hooks/pre-commit.d/obfuscation"
}

@test "setup installs pre-commit hooks" {
  notes setup --yes

  # Dispatcher
  [ -x "$TARGET_DIR/.git/hooks/pre-commit" ]
  grep -q "Generic hook dispatcher" "$TARGET_DIR/.git/hooks/pre-commit"

  # Individual hooks
  [ -x "$TARGET_DIR/.git/hooks/pre-commit.d/encryption" ]
  grep -q "git-crypt" "$TARGET_DIR/.git/hooks/pre-commit.d/encryption"
  grep -qF "NOTES_TOOL_ROOT=\"$REPO_DIR\"" \
    "$TARGET_DIR/.git/hooks/pre-commit.d/encryption"
  grep -qF 'source "$NOTES_TOOL_ROOT/lib/encryption.sh"' \
    "$TARGET_DIR/.git/hooks/pre-commit.d/encryption"
  [ -x "$TARGET_DIR/.git/hooks/pre-commit.d/obfuscation" ]
  grep -q "manifest" "$TARGET_DIR/.git/hooks/pre-commit.d/obfuscation"
}

@test "setup without keys does not add gpg users" {
  notes setup --yes

  # .git-crypt/keys/default/0/ only exists after first add-gpg-user
  [ ! -d "$TARGET_DIR/.git-crypt/keys/default/0" ]
}

@test "setup refuses without confirmation before mutation" {
  run without_confirmation "$BATS_TEST_TMPDIR/missing-tty" notes setup

  [ "$status" -eq 2 ]
  [[ "$output" == *"confirmation required"* ]]
  [[ "$output" == *"Re-run with --yes"* ]]
  [ ! -d "$TARGET_DIR/.git/git-crypt" ]
  [ ! -d "$TARGET_DIR/.git-crypt" ]
  [ ! -f "$TARGET_DIR/.gitattributes" ]
  [ ! -f "$TARGET_DIR/notes/.manifest" ]
}

# --- verify tests ---
# These use a temporary GPG keyring with a test key

generate_test_key() {
  local homedir="$1"
  gpg --homedir "$homedir" --batch --passphrase '' --quick-gen-key \
    "test-user <test@example.com>" default default never 2>/dev/null
  gpg --homedir "$homedir" --batch --with-colons --list-keys 2>/dev/null \
    | awk -F: '/^fpr/{print $10; exit}'
}

@test "verify succeeds with matching key and fingerprint" {
  local keyhome="$BATS_TEST_TMPDIR/gpghome"
  mkdir -p "$keyhome"
  chmod 700 "$keyhome"

  local fpr
  fpr=$(generate_test_key "$keyhome")
  [ -n "$fpr" ]

  local keyfile="$BATS_TEST_TMPDIR/test.pub.asc"
  gpg --homedir "$keyhome" --batch --armor --export "$fpr" > "$keyfile"

  run notes verify -- --gpg-key "$fpr" --key-file "$keyfile"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Verified"* ]]
  [[ "$output" == *"matches the claimed fingerprint"* ]]
}

@test "verify fails with mismatched fingerprint" {
  local keyhome="$BATS_TEST_TMPDIR/gpghome"
  mkdir -p "$keyhome"
  chmod 700 "$keyhome"

  local fpr
  fpr=$(generate_test_key "$keyhome")

  local keyfile="$BATS_TEST_TMPDIR/test.pub.asc"
  gpg --homedir "$keyhome" --batch --armor --export "$fpr" > "$keyfile"

  run notes verify -- --gpg-key "0000000000000000000000000000000000000000" --key-file "$keyfile"
  [ "$status" -ne 0 ]
  [[ "$output" == *"MISMATCH"* ]]
}

@test "verify reads from stdin with --key-file -" {
  local keyhome="$BATS_TEST_TMPDIR/gpghome"
  mkdir -p "$keyhome"
  chmod 700 "$keyhome"

  local fpr
  fpr=$(generate_test_key "$keyhome")

  run bash -c "gpg --homedir '$keyhome' --batch --armor --export '$fpr' | notes verify -- --gpg-key '$fpr' --key-file -"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Verified"* ]]
}

@test "setup creates empty .manifest for obfuscation bootstrap" {
  notes setup --yes

  [ -f "$TARGET_DIR/notes/.manifest" ]
  [ ! -s "$TARGET_DIR/notes/.manifest" ]  # empty
}

@test "setup does not overwrite existing .manifest" {
  mkdir -p "$TARGET_DIR/notes"
  printf 'aaa00001\texisting.md\n' > "$TARGET_DIR/notes/.manifest"

  notes setup --yes

  [ -f "$TARGET_DIR/notes/.manifest" ]
  grep -q "existing.md" "$TARGET_DIR/notes/.manifest"
}

@test "setup and stage forward-encrypt tracked plaintext notes" {
  commit_tracked_plaintext_notes

  run notes setup --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"Preparing 2 tracked plaintext note(s)"* ]]
  [[ "$output" == *"notes stage --all"* ]]

  git -C "$TARGET_DIR" add .gitattributes
  run notes stage --all
  [ "$status" -eq 0 ]
  [[ "$output" == *"staged: alpha.md"* ]]
  [[ "$output" == *"staged: beta.md"* ]]

  git -C "$TARGET_DIR" show :notes/alpha.md > "$BATS_TEST_TMPDIR/staged-alpha"
  grep -a -q "GITCRYPT" "$BATS_TEST_TMPDIR/staged-alpha"

  git -C "$TARGET_DIR" commit -q -m "onboard encrypted notes"

  local alpha_id
  alpha_id=$(manifest_id_for_name "$TARGET_DIR/notes/.manifest" "alpha.md")
  [ -n "$alpha_id" ]
  ! git -C "$TARGET_DIR" ls-files --error-unmatch notes/alpha.md >/dev/null 2>&1
  git -C "$TARGET_DIR" ls-files --error-unmatch "notes/$alpha_id" >/dev/null

  run notes verify-blobs --ref HEAD --strict
  [ "$status" -eq 0 ]
  run git -C "$TARGET_DIR" show HEAD~1:notes/alpha.md
  [ "$output" = "# Existing alpha" ]
}

@test "setup onboards plaintext notes beside existing encrypted infrastructure" {
  local fpr="1111111111111111111111111111111111111111"

  run notes setup --yes --pattern ".modules/manifest"
  [ "$status" -eq 0 ]
  rm -f "$TARGET_DIR/notes/.manifest"
  mkdir -p "$TARGET_DIR/.git-crypt/keys/default/0"
  printf 'existing resident key record\n' \
    > "$TARGET_DIR/.git-crypt/keys/default/0/$fpr.gpg"

  mkdir -p "$TARGET_DIR/.modules" "$TARGET_DIR/notes"
  printf 'fold = main\n' > "$TARGET_DIR/.modules/manifest"
  printf '# Existing home note\n' > "$TARGET_DIR/notes/home.md"
  git -C "$TARGET_DIR" add .gitattributes .git-crypt .modules/manifest notes/home.md
  git -C "$TARGET_DIR" commit -q --no-verify -m "add existing home state"

  run notes setup --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"Preparing 1 tracked plaintext note(s)"* ]]

  git -C "$TARGET_DIR" add .gitattributes
  run notes stage --all
  [ "$status" -eq 0 ]
  [[ "$output" == *"staged: home.md"* ]]
  git -C "$TARGET_DIR" commit -q -m "onboard home notes"

  run notes verify-blobs --ref HEAD --strict
  [ "$status" -eq 0 ]
  run git -C "$TARGET_DIR" show HEAD~1:notes/home.md
  [ "$output" = "# Existing home note" ]
}

# --- setup next-steps ---

@test "setup shows unlock hint when repo has encrypted notes" {
  notes setup --yes
  mkdir -p "$TARGET_DIR/notes"
  echo -e "---\ntitle: Test\n---" > "$TARGET_DIR/notes/test.md"
  git -C "$TARGET_DIR" add -A
  git -C "$TARGET_DIR" commit -q -m "add note"

  # Simulate encrypted notes by writing a GITCRYPT header
  printf '\x00GITCRYPT\x00' > "$TARGET_DIR/notes/test.md"

  run notes setup --yes
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "notes unlock"
  echo "$output" | grep -q "already has encrypted notes"
}

@test "setup shows unlock hint even when first file is plaintext" {
  notes setup --yes
  mkdir -p "$TARGET_DIR/notes/archive"
  # Plaintext file at top level
  echo "readme" > "$TARGET_DIR/notes/README.md"
  # Encrypted file in subdirectory
  printf '\x00GITCRYPT\x00' > "$TARGET_DIR/notes/archive/secret.md"
  git -C "$TARGET_DIR" add -A
  git -C "$TARGET_DIR" commit -q -m "add notes"

  run notes setup --yes
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "notes unlock"
  echo "$output" | grep -q "already has encrypted notes"
}

@test "setup fails when existing encrypted notes cannot be enumerated" {
  setup_failing_encrypted_note_enumeration_overlay

  PATH="$FAILING_FIND_BIN:$PATH" run notes setup --yes

  [ "$status" -eq 73 ]
  [[ "$output" == *"failed to inspect existing encrypted notes"* ]]
  [[ "$output" != *"Done! Next steps"* ]]
}

@test "setup shows standard next steps on fresh repo" {
  run notes setup --yes
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Commit the setup"
  # Should NOT mention unlock
  ! echo "$output" | grep -q "already has encrypted notes"
}

@test "setup --unlock runs unlock after setup" {
  # Fresh setup already owns the key, so --unlock should no-op cleanly; see #42.
  run notes setup --yes --unlock
  echo "$output" | grep -q "Installed hooks"
  echo "$output" | grep -q "Unlocking"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Already unlocked."
}

@test "unlock warns when required pre-commit hooks are missing" {
  notes setup --yes
  rm -rf "$TARGET_DIR/.git/hooks/pre-commit" \
    "$TARGET_DIR/.git/hooks/pre-commit.d"

  run notes unlock

  [ "$status" -eq 0 ]
  [[ "$output" == *"pre-commit hooks are missing or stale"* ]]
  [[ "$output" == *"notes install-hooks --yes"* ]]
}

@test "unlock warns when a required pre-commit hook is stale" {
  notes setup --yes
  printf '\n# stale\n' >> "$TARGET_DIR/.git/hooks/pre-commit.d/obfuscation"

  run notes unlock

  [ "$status" -eq 0 ]
  [[ "$output" == *"pre-commit hooks are missing or stale"* ]]
}
