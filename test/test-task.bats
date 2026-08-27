#!/usr/bin/env bats

load test_helper
bats_require_minimum_version 1.5.0

setup() {
  export NOTES_CALLER_PWD="$BATS_TEST_TMPDIR"
}

write_passing_test() {
  local path="$1" name="$2"
  mkdir -p "$(dirname "$path")"
  local test_keyword='@test'
  printf '%s\n' \
    '#!/usr/bin/env bats' \
    "$test_keyword \"$name\" {" \
    '  true' \
    '}' > "$path"
}

@test "options-only calls use the configured Notes test directory" {
  run notes test --jobs 1 --filter '^hosted validation covers Linux and macOS$'

  [ "$status" -eq 0 ]
  [[ "$output" == *'1..1'* ]]
  [[ "$output" == *'ok 1 hosted validation covers Linux and macOS'* ]]
}

@test "an explicit BATS target takes precedence over the configured default" {
  local target="$BATS_TEST_TMPDIR/explicit.bats"
  write_passing_test "$target" 'explicit target only'

  run notes test --jobs 1 "$target"

  [ "$status" -eq 0 ]
  [[ "$output" == *'1..1'* ]]
  [[ "$output" == *'ok 1 explicit target only'* ]]
}

@test "relative BATS targets resolve from the repository root" {
  run notes test --jobs 1 test/ci.bats \
    --filter '^hosted validation covers Linux and macOS$'

  [ "$status" -eq 0 ]
  [[ "$output" == *'1..1'* ]]
  [[ "$output" == *'ok 1 hosted validation covers Linux and macOS'* ]]
}

@test "whitespace-bearing explicit BATS targets remain one argument" {
  local target="$BATS_TEST_TMPDIR/explicit target/passing test.bats"
  write_passing_test "$target" 'whitespace target'

  run notes test --jobs 2 "$target"

  [ "$status" -eq 0 ]
  [[ "$output" == *'1..1'* ]]
  [[ "$output" == *'ok 1 whitespace target'* ]]
}

@test "default test task runs the complete BATS and Python suites" {
  local mock_dir="$BATS_TEST_TMPDIR/mock-bin"
  local bats_log="$BATS_TEST_TMPDIR/bats.log"
  local uv_log="$BATS_TEST_TMPDIR/uv.log"
  mkdir -p "$mock_dir"

  cat > "$mock_dir/bats" <<'SH'
#!/usr/bin/env bash
printf 'target=%s\n' "$BATS_DEFAULT_TEST_TARGET"
printf 'within=%s\n' "$BATS_NO_PARALLELIZE_WITHIN_FILE"
printf 'arg=%s\n' "$@"
SH
  cat > "$mock_dir/uv" <<'SH'
#!/usr/bin/env bash
printf 'arg=%s\n' "$@"
SH
  chmod +x "$mock_dir/bats" "$mock_dir/uv"

  BATS_COMMAND="$mock_dir/bats" UV_COMMAND="$mock_dir/uv" \
    run notes test

  [ "$status" -eq 0 ]
  [[ "$output" == *"target=$REPO_DIR/test"* ]]
  [[ "$output" == *'within=true'* ]]
  [[ "$output" == *"arg=$REPO_DIR/test/python"* ]]
}

@test "an explicit Python target runs only pytest" {
  run notes test test/python/test_audit.py

  [ "$status" -eq 0 ]
  [[ "$output" == *'9 passed'* ]]
}

@test "public Notes test path runs separate BATS files concurrently" {
  local probe_dir="$BATS_TEST_TMPDIR/across-file-probe"
  export PROBE_DIR="$BATS_TEST_TMPDIR/across-file-barrier"
  mkdir -p "$probe_dir" "$PROBE_DIR"
  local test_keyword='@test'

  for side in one two; do
    other=one
    [ "$side" = one ] && other=two
    cat > "$probe_dir/$side.bats" <<BATS
#!/usr/bin/env bats
$test_keyword "$side worker observes $other worker" {
  touch "\$PROBE_DIR/$side"
  for _ in {1..50}; do
    [ ! -e "\$PROBE_DIR/$other" ] || return 0
    sleep 0.05
  done
  false
}
BATS
  done

  run notes test "$probe_dir"

  [ "$status" -eq 0 ]
}

@test "public Notes test path keeps tests within one BATS file serial" {
  local target="$BATS_TEST_TMPDIR/within-file.bats"
  export PROBE_DIR="$BATS_TEST_TMPDIR/within-file-barrier"
  mkdir -p "$PROBE_DIR"
  local test_keyword='@test'

  cat > "$target" <<BATS
#!/usr/bin/env bats
$test_keyword "first test runs alone" {
  touch "\$PROBE_DIR/one"
  sleep 0.2
  [ ! -e "\$PROBE_DIR/two" ]
  rm "\$PROBE_DIR/one"
}
$test_keyword "second test runs alone" {
  touch "\$PROBE_DIR/two"
  sleep 0.2
  [ ! -e "\$PROBE_DIR/one" ]
  rm "\$PROBE_DIR/two"
}
BATS

  run notes test "$target"

  [ "$status" -eq 0 ]
}
