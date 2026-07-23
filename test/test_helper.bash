# BATS loads helpers while discovering tests, before setup_suite runs. Derive
# the repo root here so shared libraries can be sourced during discovery;
# setup_suite owns the expensive tool environment and fixture Git identity.
REPO_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
export REPO_DIR

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
