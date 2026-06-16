#!/usr/bin/env bash
# hooks.sh — Git hook installation helpers

HOOKS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS_REPO_DIR="$(cd "$HOOKS_LIB_DIR/.." && pwd)"

_hook_template_value() {
  printf '%s' "$1" | sed 's/[&|\\]/\\&/g'
}

_render_notes_hook_template() {
  local template="${1:?usage: _render_notes_hook_template <template> <notes-dir>}"
  local notes_dir="${2:?usage: _render_notes_hook_template <template> <notes-dir>}"
  local mise_bin
  mise_bin=$(command -v mise) || {
    echo "Error: mise not found; cannot install notes hooks" >&2
    return 1
  }

  sed \
    -e "s|__NOTES_DIR__|$(_hook_template_value "$notes_dir")|g" \
    -e "s|__NOTES_TOOL_ROOT__|$(_hook_template_value "$HOOKS_REPO_DIR")|g" \
    -e "s|__MISE_BIN__|$(_hook_template_value "$mise_bin")|g" \
    "$template"
}

# Ensure a hook dispatcher is installed for the given hook type.
# Usage: ensure_hook_dispatcher <pre-commit|post-commit|post-merge|post-checkout>
ensure_hook_dispatcher() {
  local hook_type="${1:?usage: ensure_hook_dispatcher <pre-commit|post-commit|post-merge|post-checkout>}"
  local hooks_dir="$TARGET_DIR/.git/hooks"
  local dispatcher="$hooks_dir/$hook_type"

  mkdir -p "$hooks_dir/${hook_type}.d"

  # Only install if the dispatcher isn't already in place
  if ! grep -q "${hook_type}.d" "$dispatcher" 2>/dev/null; then
    cp "$HOOKS_DIR/dispatcher" "$dispatcher"
    chmod +x "$dispatcher"
  fi
}

# Install the encryption pre-commit check.
install_encryption_hook() {
  ensure_hook_dispatcher pre-commit
  local target="$TARGET_DIR/.git/hooks/pre-commit.d/encryption"
  cp "$HOOKS_DIR/encryption" "$target"
  chmod +x "$target"
}

# Install the obfuscation pre-commit check.
# Bakes in the notes directory path from the template.
install_obfuscation_hook() {
  local notes_dir="${1:-notes}"
  ensure_hook_dispatcher pre-commit
  local target="$TARGET_DIR/.git/hooks/pre-commit.d/obfuscation"
  _render_notes_hook_template "$HOOKS_DIR/obfuscation.template" "$notes_dir" > "$target"
  chmod +x "$target"
}

# Install the double-tracking pre-commit guard.
# Refuses commits while a readable note and its obfuscated counterpart are
# both tracked in the index. See KnickKnackLabs/notes#51.
install_double_tracking_hook() {
  local notes_dir="${1:-notes}"
  ensure_hook_dispatcher pre-commit
  # Name sorts after `obfuscation` so the auto-obfuscation hook can fix a
  # naively-staged readable before this guard runs.
  local target="$TARGET_DIR/.git/hooks/pre-commit.d/verify-double-tracking"
  _render_notes_hook_template "$HOOKS_DIR/verify-double-tracking.template" "$notes_dir" > "$target"
  chmod +x "$target"
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
  local commit_template="$HOOKS_DIR/post-commit-deobfuscate.template"
  local merge_template="$HOOKS_DIR/post-merge-deobfuscate.template"
  local checkout_template="$HOOKS_DIR/post-checkout-deobfuscate.template"

  # Install for post-commit (deobfuscate after committing)
  ensure_hook_dispatcher post-commit
  local target="$TARGET_DIR/.git/hooks/post-commit.d/deobfuscation"
  _render_notes_hook_template "$commit_template" "$notes_dir" > "$target"
  chmod +x "$target"

  # Install for post-merge (deobfuscate after pulling)
  ensure_hook_dispatcher post-merge
  local merge_target="$TARGET_DIR/.git/hooks/post-merge.d/deobfuscation"
  _render_notes_hook_template "$merge_template" "$notes_dir" > "$merge_target"
  chmod +x "$merge_target"

  # Install for post-checkout (deobfuscate after branch checkout)
  ensure_hook_dispatcher post-checkout
  local checkout_target="$TARGET_DIR/.git/hooks/post-checkout.d/deobfuscation"
  _render_notes_hook_template "$checkout_template" "$notes_dir" > "$checkout_target"
  chmod +x "$checkout_target"
}
