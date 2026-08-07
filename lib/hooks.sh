#!/usr/bin/env bash
# hooks.sh — Git hook installation helpers

HOOKS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS_REPO_DIR="$(cd "$HOOKS_LIB_DIR/.." && pwd)"
HOOKS_DIR="$HOOKS_REPO_DIR/hooks"

_hook_template_value() {
  printf '%s' "$1" | sed 's/[&|\\]/\\&/g'
}

_render_notes_hook_template() {
  local template="${1:?usage: _render_notes_hook_template <template> <notes-dir> [mise-bin]}"
  local notes_dir="${2:?usage: _render_notes_hook_template <template> <notes-dir> [mise-bin]}"
  local mise_bin="${3:-}"
  if [ -z "$mise_bin" ]; then
    mise_bin=$(command -v mise) || {
      echo "Error: mise not found; cannot install notes hooks" >&2
      return 1
    }
  fi

  sed \
    -e "s|__NOTES_DIR__|$(_hook_template_value "$notes_dir")|g" \
    -e "s|__NOTES_TOOL_ROOT__|$(_hook_template_value "$HOOKS_REPO_DIR")|g" \
    -e "s|__MISE_BIN__|$(_hook_template_value "$mise_bin")|g" \
    "$template"
}

_active_git_hooks_dir() {
  local repo_root hooks_dir
  repo_root=$(git -C "$TARGET_DIR" rev-parse --show-toplevel) || return 1
  hooks_dir=$(git -C "$TARGET_DIR" rev-parse --git-path hooks) || return 1
  case "$hooks_dir" in
    /*) printf '%s\n' "$hooks_dir" ;;
    *) printf '%s/%s\n' "$repo_root" "$hooks_dir" ;;
  esac
}

# Ensure the exact Notes dispatcher is installed in Git's active hooks path.
# Usage: ensure_hook_dispatcher <pre-commit|post-commit|post-merge|post-checkout>
ensure_hook_dispatcher() {
  local hook_type="${1:?usage: ensure_hook_dispatcher <pre-commit|post-commit|post-merge|post-checkout>}"
  local hooks_dir
  hooks_dir=$(_active_git_hooks_dir) || return 1
  local dispatcher="$hooks_dir/$hook_type"

  mkdir -p "$hooks_dir/${hook_type}.d"

  if ! cmp -s "$HOOKS_DIR/dispatcher" "$dispatcher"; then
    cp "$HOOKS_DIR/dispatcher" "$dispatcher"
    chmod +x "$dispatcher"
  fi
}

# Install the encryption pre-commit check.
# Render the source package path so the hook uses the exact Notes version that
# installed it rather than whichever `notes` command appears first on PATH.
install_encryption_hook() {
  ensure_hook_dispatcher pre-commit
  local hooks_dir
  hooks_dir=$(_active_git_hooks_dir) || return 1
  local target="$hooks_dir/pre-commit.d/encryption"
  _render_notes_hook_template "$HOOKS_DIR/encryption.template" "." > "$target"
  chmod +x "$target"
}

# Install the obfuscation pre-commit check.
# Bakes in the notes directory path from the template.
install_obfuscation_hook() {
  local notes_dir="${1:-notes}"
  ensure_hook_dispatcher pre-commit
  local hooks_dir
  hooks_dir=$(_active_git_hooks_dir) || return 1
  local target="$hooks_dir/pre-commit.d/obfuscation"
  _render_notes_hook_template "$HOOKS_DIR/obfuscation.template" "$notes_dir" > "$target"
  chmod +x "$target"
}

# Install the double-tracking pre-commit guard.
# Refuses commits while a readable note and its obfuscated counterpart are
# both tracked in the index. See KnickKnackLabs/notes#51.
install_double_tracking_hook() {
  local notes_dir="${1:-notes}"
  ensure_hook_dispatcher pre-commit
  local hooks_dir
  hooks_dir=$(_active_git_hooks_dir) || return 1
  # Name sorts after `obfuscation` so the auto-obfuscation hook can fix a
  # naively-staged readable before this guard runs.
  local target="$hooks_dir/pre-commit.d/verify-double-tracking"
  _render_notes_hook_template "$HOOKS_DIR/verify-double-tracking.template" "$notes_dir" > "$target"
  chmod +x "$target"
}

_installed_hook_matches() {
  local template="${1:?usage: _installed_hook_matches <template> <notes-dir> <installed-hook> [mise-bin]}"
  local notes_dir="${2:?usage: _installed_hook_matches <template> <notes-dir> <installed-hook> [mise-bin]}"
  local installed="${3:?usage: _installed_hook_matches <template> <notes-dir> <installed-hook> [mise-bin]}"
  local mise_bin="${4:-}"
  local expected

  [ -x "$installed" ] || return 1
  expected=$(mktemp) || return 1
  if ! _render_notes_hook_template \
    "$template" "$notes_dir" "$mise_bin" > "$expected"; then
    rm -f "$expected"
    return 1
  fi
  if cmp -s "$expected" "$installed"; then
    rm -f "$expected"
    return 0
  fi
  rm -f "$expected"
  return 1
}

required_pre_commit_hooks_ready() {
  local notes_dir="${1:-notes}"
  local hooks_dir
  hooks_dir=$(_active_git_hooks_dir) || return 1
  local dispatcher="$hooks_dir/pre-commit"
  local fragments="$hooks_dir/pre-commit.d"
  local obfuscation_hook="$fragments/obfuscation"
  local installed_mise_bin

  [ -x "$dispatcher" ] || return 1
  cmp -s "$HOOKS_DIR/dispatcher" "$dispatcher" || return 1
  [ -x "$obfuscation_hook" ] || return 1
  installed_mise_bin=$(sed -n 's/^MISE_BIN="\(.*\)"$/\1/p' \
    "$obfuscation_hook")
  [ -n "$installed_mise_bin" ] || return 1
  [ -x "$installed_mise_bin" ] || return 1
  _installed_hook_matches \
    "$HOOKS_DIR/encryption.template" "." "$fragments/encryption" \
    "$installed_mise_bin" || return 1
  _installed_hook_matches \
    "$HOOKS_DIR/obfuscation.template" "$notes_dir" "$obfuscation_hook" \
    "$installed_mise_bin" || return 1
  _installed_hook_matches \
    "$HOOKS_DIR/verify-double-tracking.template" "$notes_dir" \
    "$fragments/verify-double-tracking" "$installed_mise_bin" || return 1
}

# Install the manifest merge driver.
# Configures git to use our custom merge driver for .manifest files.
install_manifest_merge_driver() {
  local notes_dir="${1:-notes}"
  local gitattributes="$TARGET_DIR/.gitattributes"

  # Resolve the driver through the stable notes shim instead of pinning setup to
  # one installed package path. The task wrapper handles git's relative paths.
  git -C "$TARGET_DIR" config merge.manifest.name "Union merge driver for notes manifest"
  git -C "$TARGET_DIR" config merge.manifest.driver "notes merge-driver %O %A %B"

  # Add .gitattributes entry if not already present
  local pattern="$notes_dir/.manifest merge=manifest"
  if ! grep -qF "$pattern" "$gitattributes" 2>/dev/null; then
    echo "$pattern" >> "$gitattributes"
  fi
}

# Install deobfuscation hooks.
# After a commit obfuscates filenames, post-commit restores readable names.
# After a merge/pull updates obfuscated files, post-merge refreshes readable names.
# After a branch checkout changes the manifest, post-checkout reconciles stale names.
install_deobfuscation_hook() {
  local notes_dir="${1:-notes}"
  local hooks_dir
  hooks_dir=$(_active_git_hooks_dir) || return 1
  local commit_template="$HOOKS_DIR/post-commit-deobfuscate.template"
  local merge_template="$HOOKS_DIR/post-merge-deobfuscate.template"
  local checkout_template="$HOOKS_DIR/post-checkout-deobfuscate.template"

  # Install for post-commit (deobfuscate after committing)
  ensure_hook_dispatcher post-commit
  local target="$hooks_dir/post-commit.d/deobfuscation"
  _render_notes_hook_template "$commit_template" "$notes_dir" > "$target"
  chmod +x "$target"

  # Install for post-merge (deobfuscate after pulling)
  ensure_hook_dispatcher post-merge
  local merge_target="$hooks_dir/post-merge.d/deobfuscation"
  _render_notes_hook_template "$merge_template" "$notes_dir" > "$merge_target"
  chmod +x "$merge_target"

  # Install for post-checkout (deobfuscate after branch checkout)
  ensure_hook_dispatcher post-checkout
  local checkout_target="$hooks_dir/post-checkout.d/deobfuscation"
  _render_notes_hook_template "$checkout_template" "$notes_dir" > "$checkout_target"
  chmod +x "$checkout_target"
}
