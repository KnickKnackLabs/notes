# Contributing to notes

`notes` is a mise-backed CLI for encrypted Markdown repositories. Changes often
cross Git, git-crypt, filename obfuscation, and local status-suppression
boundaries, so preserve those contracts while keeping the command surface
simple.

## Structure

```text
notes/
├── .github/workflows/ # Hosted macOS and Linux validation
├── .mise/tasks/       # Public CLI commands and task-local orchestration
├── hooks/             # Installed Git hook components and templates
├── lib/               # Shared Bash and Python domain logic
├── test/              # BATS behavior and integration tests
├── test/python/       # Focused Python tests
├── mise.toml          # Tools, settings, and convention lint configuration
└── README.md          # User-facing command and workflow reference
```

Task scripts may use `$MISE_CONFIG_ROOT`. Shared libraries must locate their
own files from `BASH_SOURCE`, and tests derive the repository from
`$BATS_TEST_DIRNAME`; an agent shell can inherit an unrelated
`MISE_CONFIG_ROOT` from its launcher.

## Local setup

```bash
mise trust
mise install
mise run doctor
mise run test
```

The optional local convention hook is clone-local. Install it when useful:

```bash
codebase pre-commit
```

## Tests

Tests call Notes through `mise run` so they exercise Usage parsing, declared
tools, and the package-scoped `NOTES_CALLER_PWD` contract.

```bash
mise run test                       # BATS and Python suites
mise run test changes               # test/changes.bats and matching Python test, if present
mise run test --filter suppression  # filter BATS test names
mise run test test/python/test_audit.py
```

Notes intentionally uses eight BATS workers, including within-file
parallelism. Several suites contain many independent Git fixtures, so the
starter template's four-job files-only default is materially slower here.
Keep mutable fixtures under `$BATS_TEST_TMPDIR`; do not introduce shared test
repositories, fixed temporary paths, or ambient signing dependencies.

## Encryption and Git safety

Use throwaway repositories for tests. Never run setup, lock, obfuscation, hook,
or commit tests against a real notes checkout. Keep commits and tags in test
fixtures unsigned so an ambient agent signing policy cannot affect behavior.

Changes to readable/obfuscated reconciliation must cover interrupted or stale
states, custom notes directories, spaces and non-ASCII paths where relevant,
and the Git index flags that hide readable working copies. A faster path is not
correct if one stale entry can prevent valid entries from being reconciled.

## Validation

Before opening or updating a PR, run the checks that prove the touched surface:

```bash
mise run doctor
mise run test
codebase lint "$PWD"
git diff --check
```

Use focused tests during iteration and the complete suite once the change shape
is stable. Pull requests and main run the same suite and configured lints on
macOS and Linux. Notes currently has no release step in ordinary contribution
work; merging and tagging require separate maintainer authority.
