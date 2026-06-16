# notes

**Collective memory, encrypted.**

`notes` is a small CLI for keeping Markdown notes in a Git repo while protecting the private parts with `git-crypt`. It handles the boring-but-dangerous edges around encryption setup, collaborator keys, filename obfuscation, and staging files that Git would otherwise hide from you.

The shape is intentionally simple: write normal Markdown in `notes/`, let the tool keep encrypted filenames safe for GitHub, and use explicit commands when crossing encryption boundaries.

## Quick start

```sh
# One-time setup in a Git repo. This mutates encryption config and hooks.
notes setup --yes

# Add a note with YAML frontmatter.
notes new --slug project-plan --title "Project plan" --tags planning

# See note metadata, search notes, and show one note.
notes list
notes search "workflow"
notes show project-plan

# Parse convention-aware components without changing raw Markdown reads.
notes parse notes/project-plan.md

# Check encryption + obfuscation state.
notes status

# Commit changed notes through notes' obfuscation/exclude rules.
notes commit -m "notes: update project plan" notes/project-plan.md
```

For an existing encrypted repo:

```sh
notes setup --yes --unlock
notes status
```

## Daily workflow

```sh
# Show note changes against HEAD.
notes changes
notes changes --summary

# Query notes by metadata or content.
notes list --type skill
notes search "review capacity" --tag workflow
notes show project-plan --json
notes parse notes/project-plan.md

# Show readable diffs for local changes, refs, or PRs.
notes diff
notes diff main...HEAD
notes diff --pr 109 --out /tmp/notes-109-review

# Inspect unresolved encrypted-note merge conflicts without resolving them.
notes conflicts --out /tmp/notes-conflicts
notes merge --dry-run --out /tmp/notes-conflicts

# Commit changed notes. Scope is explicit: pass paths or --all.
notes commit -m "notes: update project plan" notes/project-plan.md
notes commit --all -m "notes: update garden"

# Low-level staging remains available when you need manual Git control.
notes stage notes/new-note.md
notes stage --all

# Re-encrypt local files before handoff or archival.
notes lock --yes

# Decrypt again when you need to work locally.
notes unlock
```

`setup`, `lock`, `install-hooks`, and `unlock --force` require confirmation because they mutate repository encryption or hook state. In automation, pass `--yes` explicitly.

## What notes manages

- **Encryption setup** — initializes `git-crypt` through `rudi`, configures `.gitattributes`, and installs hooks.
- **Collaborator access** — adds GPG keys to the repo's encrypted key material.
- **Filename obfuscation** — stores notes with opaque filenames in Git while restoring readable names locally.
- **Manifest merging** — uses a custom merge driver for `notes/.manifest` so concurrent note additions can merge cleanly.
- **Safe commits/staging** — commits or stages notes despite local exclude/assume-unchanged rules used for readable working copies.
- **Readable review diffs** — materializes obfuscated note refs/PRs as readable Markdown and emits a normal patch.
- **Readable conflict artifacts** — detects unmerged encrypted/obfuscated note content and writes base/ours/theirs Markdown files for manual resolution.
- **Convention-aware parsing** — `notes parse <file>` returns JSON components for frontmatter and body without changing raw Markdown compatibility.
- **Wikilink graph telemetry** — `notes audit` reports inbound/outbound link counts per note and surfaces broken `[[targets]]`. Generic; layered analyses (e.g. pattern maturity) consume the `--json` output.

## Important gotchas

- `notes lock` currently re-encrypts **all git-crypt files in the repo**, not just `notes/` files. This is a `rudi` limitation tracked separately.
- Prefer `notes commit` for note-only commits. Use `notes stage <path>` or `notes stage --all` only when you need manual Git control; readable note names are intentionally excluded locally.
- After pulling shared note repos, inspect `notes status` and `notes changes --summary` before committing follow-up changes.
- `notes unlock` / `notes deobfuscate` reconcile stale readable files left by upstream note deletion or rename. Clean generated stale files are removed; dirty or unproven stale files are moved to `.git/info/notes-stale-readable/` so they cannot be accidentally staged as new notes.
- `notes parse` is a parser/query foundation for existing Markdown/frontmatter conventions. Raw Markdown reads remain valid; future conventions should settle separately before they become parser output.

## Development

```sh
gh repo clone KnickKnackLabs/notes
cd notes
mise trust
mise install
mise run test
```

The test suite is BATS-based. Target a subset with:

```sh
mise run test test/encrypt.bats test/integration.bats
```

Tiny encrypted filing cabinet, very serious about labels.
