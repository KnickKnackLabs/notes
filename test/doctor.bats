#!/usr/bin/env bats

load test_helper
bats_require_minimum_version 1.5.0

setup() {
  export NOTES_CALLER_PWD="$BATS_TEST_TMPDIR"
  mock_dir="$BATS_TEST_TMPDIR/mock-bin"
  codebase_log="$BATS_TEST_TMPDIR/codebase.log"
  mkdir -p "$mock_dir"
  export codebase_log

  cat > "$mock_dir/codebase" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$codebase_log"
case "$1" in
  lint)
    printf '%s\n' "${MOCK_LINT_OUTPUT:-configured lints pass}"
    exit "${MOCK_LINT_STATUS:-0}"
    ;;
  pre-commit)
    exit "${MOCK_HOOK_STATUS:-1}"
    ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$mock_dir/codebase"

  export CODEBASE_COMMAND="$mock_dir/codebase"
  export GUM_COMMAND="$mock_dir/missing-gum"
  unset MOCK_LINT_OUTPUT MOCK_LINT_STATUS MOCK_HOOK_STATUS
}

@test "doctor passes with green lints and treats the local hook as optional" {
  run notes doctor

  [ "$status" -eq 0 ]
  [[ "$output" == *"✓ codebase - configured convention lints pass"* ]]
  [[ "$output" == *"! pre-commit - optional local hook missing"* ]]
  grep -Fx "lint $REPO_DIR" "$codebase_log"
  grep -Fx "pre-commit --check" "$codebase_log"
}

@test "doctor reports configured lint failures with their output" {
  export MOCK_LINT_STATUS=1
  export MOCK_LINT_OUTPUT="lint failed at example.sh:7"

  run notes doctor

  [ "$status" -eq 1 ]
  [[ "$output" == *"✗ codebase - configured convention lints failed"* ]]
  [[ "$output" == *"codebase failed output:lint failed at example.sh:7"* ]]
}

@test "doctor fails clearly when the declared checker is unavailable" {
  export CODEBASE_COMMAND="$mock_dir/missing-codebase"

  run notes doctor

  [ "$status" -eq 1 ]
  [[ "$output" == *"✗ codebase - codebase command not found; run mise install"* ]]
  [[ "$output" == *"! pre-commit - codebase unavailable; hook check skipped"* ]]
}
