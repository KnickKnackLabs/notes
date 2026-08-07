#!/usr/bin/env bats

load test_helper
bats_require_minimum_version 1.5.0

setup() {
  workflow="$REPO_DIR/.github/workflows/test.yml"
}

@test "hosted validation covers Linux and macOS" {
  grep -Fq 'os: [ubuntu-latest, macos-latest]' "$workflow"
  grep -Fq 'runs-on: ${{ matrix.os }}' "$workflow"
}

@test "hosted tests provision git-crypt through Notes' declared owner" {
  install_line=$(grep -nF 'run: rudi install' "$workflow" | cut -d: -f1)
  test_line=$(grep -nF 'run: mise run test' "$workflow" | cut -d: -f1)

  [ -n "$install_line" ]
  [ -n "$test_line" ]
  [ "$install_line" -lt "$test_line" ]
}

@test "hosted whitespace validation checks committed content" {
  grep -Fq 'run: git diff --check "$(git hash-object -t tree /dev/null)" HEAD --' "$workflow"
  ! grep -Eq 'run: git diff --check[[:space:]]*$' "$workflow"
}

@test "hosted validation runs the repository's configured convention lints" {
  grep -Fq 'run: codebase lint "$PWD"' "$workflow"
}
