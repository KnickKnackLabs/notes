#!/usr/bin/env bats

load test_helper

@test "is_initialized returns false on fresh repo" {
  run is_initialized
  [ "$status" -ne 0 ]
}

@test "is_initialized returns false after bare git crypt init (no users yet)" {
  git -C "$TARGET_DIR" crypt init
  run is_initialized
  [ "$status" -ne 0 ]
}

@test "require_git fails on non-git directory" {
  export CALLER_PWD="$BATS_TEST_TMPDIR/not-a-repo"
  mkdir -p "$CALLER_PWD"
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
  export CALLER_PWD="$TARGET_DIR"
  run "$REPO_DIR/.mise/tasks/encrypt/setup"
  [ "$status" -eq 0 ]

  [ -f "$TARGET_DIR/.gitattributes" ]
  grep -q "notes/\*\*" "$TARGET_DIR/.gitattributes"
  grep -q "git-crypt" "$TARGET_DIR/.gitattributes"
}

@test "setup is idempotent" {
  export CALLER_PWD="$TARGET_DIR"
  "$REPO_DIR/.mise/tasks/encrypt/setup"

  run "$REPO_DIR/.mise/tasks/encrypt/setup"
  [ "$status" -eq 0 ]
  [[ "$output" == *"git-crypt already initialized — updating auxiliary files..."* ]]
}

@test "setup with custom patterns writes them to .gitattributes" {
  export CALLER_PWD="$TARGET_DIR"
  export usage_pattern="agents/*/Zettels/**
notes/private/**"
  run "$REPO_DIR/.mise/tasks/encrypt/setup"
  [ "$status" -eq 0 ]

  grep -q "agents/\*/Zettels/\*\*" "$TARGET_DIR/.gitattributes"
  grep -q "notes/private/\*\*" "$TARGET_DIR/.gitattributes"
}

@test "setup installs pre-commit hook" {
  export CALLER_PWD="$TARGET_DIR"
  "$REPO_DIR/.mise/tasks/encrypt/setup"

  [ -x "$TARGET_DIR/.git/hooks/pre-commit" ]
  grep -q "git-crypt" "$TARGET_DIR/.git/hooks/pre-commit"
}

@test "setup without keys does not create COLLABORATORS" {
  export CALLER_PWD="$TARGET_DIR"
  "$REPO_DIR/.mise/tasks/encrypt/setup"

  # .git-crypt/keys/default/0/ only exists after first add-gpg-user
  [ ! -d "$TARGET_DIR/.git-crypt/keys/default/0" ]
}

# --- verify tests ---
# These use a temporary GPG keyring with a test key

generate_test_key() {
  # Generate a throwaway GPG key in a temp homedir, return fingerprint
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

  # Export to a file
  local keyfile="$BATS_TEST_TMPDIR/test.pub.asc"
  gpg --homedir "$keyhome" --batch --armor --export "$fpr" > "$keyfile"

  export usage_gpg_key="$fpr"
  export usage_key_file="$keyfile"
  run "$REPO_DIR/.mise/tasks/encrypt/verify"
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

  # Use a bogus fingerprint
  export usage_gpg_key="0000000000000000000000000000000000000000"
  export usage_key_file="$keyfile"
  run "$REPO_DIR/.mise/tasks/encrypt/verify"
  [ "$status" -ne 0 ]
  [[ "$output" == *"MISMATCH"* ]]
}

@test "verify reads from stdin with --key-file -" {
  local keyhome="$BATS_TEST_TMPDIR/gpghome"
  mkdir -p "$keyhome"
  chmod 700 "$keyhome"

  local fpr
  fpr=$(generate_test_key "$keyhome")

  export usage_gpg_key="$fpr"
  export usage_key_file="-"
  run bash -c "gpg --homedir '$keyhome' --batch --armor --export '$fpr' | '$REPO_DIR/.mise/tasks/encrypt/verify'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Verified"* ]]
}
