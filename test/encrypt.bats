#!/usr/bin/env bats

load test_helper

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
