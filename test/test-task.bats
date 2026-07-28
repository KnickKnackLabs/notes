#!/usr/bin/env bats

load test_helper
bats_require_minimum_version 1.5.0

setup() {
  export NOTES_CALLER_PWD="$BATS_TEST_TMPDIR"
  mock_dir="$BATS_TEST_TMPDIR/mock-bin"
  bats_log="$BATS_TEST_TMPDIR/bats.log"
  uv_log="$BATS_TEST_TMPDIR/uv.log"
  mkdir -p "$mock_dir"
  export bats_log uv_log

  cat > "$mock_dir/bats" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
for argument in "$@"; do
  printf 'arg=%s\n' "$argument"
done > "$bats_log"
SH

  cat > "$mock_dir/uv" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
for argument in "$@"; do
  printf 'arg=%s\n' "$argument"
done > "$uv_log"
SH

  cat > "$mock_dir/rush" <<'SH'
#!/usr/bin/env bash
exit 0
SH

  chmod +x "$mock_dir/bats" "$mock_dir/uv" "$mock_dir/rush"
  export BATS_COMMAND="$mock_dir/bats"
  export UV_COMMAND="$mock_dir/uv"
  export RUSH_COMMAND="$mock_dir/rush"
  unset BATS_NUMBER_OF_PARALLEL_JOBS BATS_PARALLEL_BINARY_NAME
}

arg_count() {
  local log="$1"
  local expected="$2"
  awk -F= -v expected="$expected" \
    '$1 == "arg" && substr($0, 5) == expected { count++ } END { print count + 0 }' \
    "$log"
}

logged_arguments() {
  sed -n 's/^arg=//p' "$1"
}

@test "test task preserves Notes' eight-worker across-file default" {
  run notes test changes

  [ "$status" -eq 0 ]
  [[ "$output" == *"8 jobs across files"* ]]
  [ "$(arg_count "$bats_log" --jobs)" -eq 1 ]
  [ "$(arg_count "$bats_log" 8)" -eq 1 ]
  [ "$(arg_count "$bats_log" --parallel-binary-name)" -eq 1 ]
  [ "$(arg_count "$bats_log" "$mock_dir/rush")" -eq 1 ]
  [ "$(arg_count "$bats_log" --no-parallelize-within-files)" -eq 1 ]
  [ "$(arg_count "$bats_log" "$REPO_DIR/test/changes.bats")" -eq 1 ]
  [ ! -e "$uv_log" ]
}

@test "default test task runs the complete BATS and Python suites" {
  run notes test

  [ "$status" -eq 0 ]
  [ "$(arg_count "$bats_log" "$REPO_DIR/test/")" -eq 1 ]
  [ "$(logged_arguments "$uv_log")" = "$(printf '%s\n' \
    run --with pytest pytest "$REPO_DIR/test/python")" ]
}

@test "bare suite name runs matching BATS and Python tests" {
  run notes test audit

  [ "$status" -eq 0 ]
  [ "$(arg_count "$bats_log" "$REPO_DIR/test/audit.bats")" -eq 1 ]
  [ "$(arg_count "$uv_log" "$REPO_DIR/test/python/test_audit.py")" -eq 1 ]
}

@test "explicit Python target does not start BATS" {
  run notes test test/python/test_audit.py

  [ "$status" -eq 0 ]
  [ ! -e "$bats_log" ]
  [ "$(arg_count "$uv_log" test/python/test_audit.py)" -eq 1 ]
}

@test "Python-only runs ignore irrelevant BATS parallelism state" {
  export BATS_NUMBER_OF_PARALLEL_JOBS=invalid
  export RUSH_COMMAND="$mock_dir/missing-rush"

  run notes test test/python/test_audit.py

  [ "$status" -eq 0 ]
  [ ! -e "$bats_log" ]
  [ "$(arg_count "$uv_log" test/python/test_audit.py)" -eq 1 ]
}

@test "BATS option values that look like Python paths stay BATS option values" {
  run notes test --filter test/python/test_audit.py

  [ "$status" -eq 0 ]
  [ "$(logged_arguments "$bats_log")" = "$(printf '%s\n' \
    --jobs 8 \
    --no-parallelize-within-files \
    --parallel-binary-name "$mock_dir/rush" \
    --filter test/python/test_audit.py \
    "$REPO_DIR/test/")" ]
  [ ! -e "$uv_log" ]
}

@test "explicit jobs override is forwarded once" {
  run notes test --jobs 3 changes

  [ "$status" -eq 0 ]
  [[ "$output" == *"3 jobs across files"* ]]
  [ "$(arg_count "$bats_log" --jobs)" -eq 1 ]
  [ "$(arg_count "$bats_log" 3)" -eq 1 ]
  [ "$(arg_count "$bats_log" 8)" -eq 0 ]
}

@test "serial override does not require Rush" {
  export RUSH_COMMAND="$mock_dir/missing-rush"

  run notes test --jobs 1 changes

  [ "$status" -eq 0 ]
  [[ "$output" == *"BATS parallelism: serial"* ]]
  [ "$(arg_count "$bats_log" --parallel-binary-name)" -eq 0 ]
}

@test "missing selected BATS executable fails before running either suite" {
  export BATS_COMMAND="$mock_dir/missing-bats"

  run -127 notes test

  [ "$status" -eq 127 ]
  [[ "$output" == *"BATS executable '$mock_dir/missing-bats' is unavailable"* ]]
  [ ! -e "$bats_log" ]
  [ ! -e "$uv_log" ]
}

@test "test task propagates variadic parser failure" {
  local failing_xargs_bin="$BATS_TEST_TMPDIR/failing-xargs-bin"
  make_failing_xargs_overlay "$failing_xargs_bin"

  PATH="$failing_xargs_bin:$PATH" run notes test changes

  [ "$status" -eq 73 ]
  [[ "$output" == *"failed to parse variadic arguments"* ]]
  [ ! -e "$bats_log" ]
  [ ! -e "$uv_log" ]
}
