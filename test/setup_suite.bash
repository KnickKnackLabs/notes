setup_suite() {
  REPO_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export REPO_DIR

  # Load this repo's declared tools even when a developer invokes BATS
  # directly. Preserve BATS' own libexec path across mise's PATH rebuild.
  local bats_libexec="${BATS_LIBEXEC:-}"
  eval "$(cd "$REPO_DIR" && mise env)"
  if [ -n "$bats_libexec" ]; then
    export PATH="$bats_libexec:$PATH"
  fi

  # Agent sessions inject signing policy while clean CI has no author identity.
  # Give every fixture one deterministic unsigned command-scope identity.
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
