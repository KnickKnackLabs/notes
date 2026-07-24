# Derive the repo root from BATS, not MISE_CONFIG_ROOT. Agent sessions can
# inherit a stale MISE_CONFIG_ROOT from the launcher repo.
REPO_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
export REPO_DIR

# Load this repo's declared tools even when a developer runs `bats test/foo.bats`
# directly instead of going through `mise run test`.
eval "$(cd "$REPO_DIR" && mise env)"

# Agent sessions inject command-scope git config so real workspace commits are
# signed, while clean CI has no author identity at all. Tests should exercise
# Git behavior without depending on either ambient state. Give every fixture a
# deterministic unsigned identity at the same command scope.
_disable_git_signing_for_tests() {
  local name _value
  unset GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS
  while IFS='=' read -r name _value; do
    case "$name" in
      GIT_CONFIG_KEY_*|GIT_CONFIG_VALUE_*) unset "$name" ;;
    esac
  done < <(env)

  export GIT_CONFIG_COUNT=4
  export GIT_CONFIG_KEY_0=commit.gpgsign
  export GIT_CONFIG_VALUE_0=false
  export GIT_CONFIG_KEY_1=tag.gpgsign
  export GIT_CONFIG_VALUE_1=false
  export GIT_CONFIG_KEY_2=user.name
  export GIT_CONFIG_VALUE_2="Notes tests"
  export GIT_CONFIG_KEY_3=user.email
  export GIT_CONFIG_VALUE_3=notes-tests@example.invalid
}
_disable_git_signing_for_tests

# Source lib files at file-load time, not inside setup(). Most .bats files in
# this suite override setup() to set their own NOTES_CALLER_PWD/fixtures, which
# shadows the helper's setup() and silently drops the lib sources. Sourcing
# at top level makes the helper functions available in every test body
# regardless of which setup wins.
source "$REPO_DIR/lib/common.sh"
source "$REPO_DIR/lib/obfuscate.sh"
source "$REPO_DIR/lib/suppress.sh"
source "$REPO_DIR/lib/hooks.sh"

# notes() wrapper — calls tasks via mise, just like real usage
# Exported so subshells (e.g. bash -c pipes) can use it too.
notes() {
  if [ -z "${NOTES_CALLER_PWD:-}" ]; then
    echo "NOTES_CALLER_PWD not set" >&2
    return 1
  fi
  cd "$REPO_DIR" && NOTES_CALLER_PWD="$NOTES_CALLER_PWD" mise run -q "$@"
}
export -f notes

without_confirmation() (
  local tty_path="$1"
  shift
  export usage_yes=true
  unset NOTES_YES MISE_YES
  export NOTES_CONFIRM_TTY="$tty_path"
  "$@"
)
export -f without_confirmation

# rudi() wrapper — calls rudi against the same target repo.
rudi() {
  if [ -z "${NOTES_CALLER_PWD:-}" ]; then
    echo "NOTES_CALLER_PWD not set" >&2
    return 1
  fi
  RUDI_CALLER_PWD="$NOTES_CALLER_PWD" command rudi "$@"
}
export -f rudi

setup() {
  export TARGET_DIR="$BATS_TEST_TMPDIR/test-repo"
  mkdir -p "$TARGET_DIR"
  git -C "$TARGET_DIR" init -q
  export NOTES_CALLER_PWD="$TARGET_DIR"
}
