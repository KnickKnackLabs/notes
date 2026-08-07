#!/usr/bin/env bats

load test_helper
bats_require_minimum_version 1.5.0

setup() {
  export NOTES_CALLER_PWD="$BATS_TEST_TMPDIR"
  mock_dir="$BATS_TEST_TMPDIR/mock-bin"
  codebase_log="$BATS_TEST_TMPDIR/codebase.log"
  readme_log="$BATS_TEST_TMPDIR/readme.log"
  mkdir -p "$mock_dir"
  export codebase_log readme_log

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

  cat > "$mock_dir/readme" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$readme_log"
printf '%s\n' "${MOCK_README_OUTPUT:-README is current}"
exit "${MOCK_README_STATUS:-0}"
SH

  chmod +x "$mock_dir/codebase" "$mock_dir/readme"

  export CODEBASE_COMMAND="$mock_dir/codebase"
  export README_COMMAND="$mock_dir/readme"
  export GUM_COMMAND="$mock_dir/missing-gum"
  unset MOCK_LINT_OUTPUT MOCK_LINT_STATUS MOCK_HOOK_STATUS
  unset MOCK_README_OUTPUT MOCK_README_STATUS
}

@test "doctor passes with green lints and treats the local hook as optional" {
  run notes doctor

  [ "$status" -eq 0 ]
  [[ "$output" == *"✓ README - README.md matches README.tsx"* ]]
  [[ "$output" == *"✓ codebase - configured convention lints pass"* ]]
  [[ "$output" == *"! pre-commit - optional local hook missing"* ]]
  grep -Fx "build --check" "$readme_log"
  grep -Fx "lint $REPO_DIR" "$codebase_log"
  grep -Fx "pre-commit --check" "$codebase_log"
}

@test "doctor reports stale generated README output" {
  export MOCK_README_STATUS=1
  export MOCK_README_OUTPUT="README.md differs from generated output"

  run notes doctor

  [ "$status" -eq 1 ]
  [[ "$output" == *"✗ README - README.md is stale; run readme build"* ]]
  [[ "$output" == *"README failed output:README.md differs from generated output"* ]]
}

@test "doctor reports configured lint failures with their output" {
  export MOCK_LINT_STATUS=1
  export MOCK_LINT_OUTPUT="lint failed at example.sh:7"

  run notes doctor

  [ "$status" -eq 1 ]
  [[ "$output" == *"✗ codebase - configured convention lints failed"* ]]
  [[ "$output" == *"codebase failed output:lint failed at example.sh:7"* ]]
}

@test "doctor fails clearly when the README generator is unavailable" {
  export README_COMMAND="$mock_dir/missing-readme"

  run notes doctor

  [ "$status" -eq 1 ]
  [[ "$output" == *"✗ README - readme command not found; run mise install"* ]]
}

@test "doctor fails clearly when the declared checker is unavailable" {
  export CODEBASE_COMMAND="$mock_dir/missing-codebase"

  run notes doctor

  [ "$status" -eq 1 ]
  [[ "$output" == *"✗ codebase - codebase command not found; run mise install"* ]]
  [[ "$output" == *"! pre-commit - codebase unavailable; hook check skipped"* ]]
}
