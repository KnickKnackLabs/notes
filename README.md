<div align="center">

<img src="assets/manly-love.webp" alt="Graffiti reading: For manly love be here March 25th at 2:15 AM sharp" width="800" />

# notes

**Collective memory, encrypted.**

[![tests: 459](https://img.shields.io/badge/tests-459-brightgreen?style=flat)](test/)
![lints: 8](https://img.shields.io/badge/lints-8-blue?style=flat)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue?style=flat)](LICENSE)

</div>

Write normal Markdown under `notes/`. Notes keeps readable names in your working tree while Git stores encrypted content under opaque filenames. Explicit commands handle the moments where those two views meet: setup, review, staging, commits, and conflicts.

## Install

Install the command for your user:

```bash
shiv install notes
```

Or declare it for a project:

```toml
[plugins]
shiv = "https://github.com/KnickKnackLabs/vfox-shiv"

[tools]
"shiv:notes" = "0.9"
```

```bash
mise install
```

## Run

```bash
# Initialize encrypted notes and install the Git hooks.
notes setup --yes

# Work with ordinary Markdown.
notes new --slug project-plan --title "Project plan" --tags planning
notes search "project plan"

# Review and commit through the readable/obfuscated boundary.
notes changes --summary
notes commit -m "notes: add project plan" notes/project-plan.md
notes diff HEAD~1..HEAD
```

<details>
<summary><b>Operational notes</b></summary>

- Join an existing encrypted repo with `notes setup --yes --unlock`.
- `setup`, `lock`, `install-hooks`, and `unlock --force` require explicit confirmation.
- Prefer `notes commit` for note-only work; use `notes stage` when you need manual Git control.
- Before publishing a ref, run `notes verify-blobs --ref HEAD --strict` to prove its managed blobs are encrypted and local note changes are absent.
- `notes lock` currently locks every git-crypt path in the repository, not only `notes/`.
- Use `notes conflicts` or `notes merge --dry-run` to materialize readable conflict artifacts.

</details>

## Documentation

Run `notes --help` for the complete command surface. See [CONTRIBUTING.md](CONTRIBUTING.md) for repository structure, encryption safety boundaries, and validation.

<div align="center">

---

<sub>
Tiny encrypted filing cabinet, very serious about labels.<br />

Generated with <a href="https://github.com/KnickKnackLabs/readme">readme</a>
</sub></div>
