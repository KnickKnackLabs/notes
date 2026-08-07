#!/usr/bin/env bats
# Tests for assume-unchanged manifest detection and notes pull
load test_helper

setup() {
  export TARGET_DIR="$BATS_TEST_TMPDIR/test-repo"
  mkdir -p "$TARGET_DIR"
  git -C "$TARGET_DIR" init -q
  git -C "$TARGET_DIR" config user.email "test@example.com"
  git -C "$TARGET_DIR" config user.name "test"
  git -C "$TARGET_DIR" config commit.gpgsign false
  git -C "$TARGET_DIR" config tag.gpgsign false
  export NOTES_CALLER_PWD="$TARGET_DIR"

  mkdir -p "$TARGET_DIR/notes"
}

COMMON_SRC="source '$REPO_DIR/lib/common.sh'"

# --- detect_assume_unchanged_manifest ---

@test "detect returns 2 when manifest is not assume-unchanged" {
  echo -e "abc12345\talpha.md" > "$TARGET_DIR/notes/.manifest"
  git -C "$TARGET_DIR" add notes/.manifest
  git -C "$TARGET_DIR" commit -q -m "init"

  run bash -c "${COMMON_SRC}; NOTES_QUIET_MANIFEST_CHECK=1 detect_assume_unchanged_manifest 'notes'"
  [ "$status" -eq 2 ]
}

@test "detect returns 1 when assume-unchanged but matches HEAD" {
  echo -e "abc12345\talpha.md" > "$TARGET_DIR/notes/.manifest"
  git -C "$TARGET_DIR" add notes/.manifest
  git -C "$TARGET_DIR" commit -q -m "init"
  git -C "$TARGET_DIR" update-index --assume-unchanged notes/.manifest

  run bash -c "${COMMON_SRC}; NOTES_QUIET_MANIFEST_CHECK=1 detect_assume_unchanged_manifest 'notes'"
  [ "$status" -eq 1 ]
}

@test "detect returns 0 when assume-unchanged and differs from HEAD" {
  echo -e "abc12345\talpha.md" > "$TARGET_DIR/notes/.manifest"
  git -C "$TARGET_DIR" add notes/.manifest
  git -C "$TARGET_DIR" commit -q -m "init"
  git -C "$TARGET_DIR" update-index --assume-unchanged notes/.manifest
  echo -e "abc12345\talpha.md\ndef67890\tbeta.md" > "$TARGET_DIR/notes/.manifest"

  run bash -c "${COMMON_SRC}; NOTES_QUIET_MANIFEST_CHECK=1 detect_assume_unchanged_manifest 'notes'"
  [ "$status" -eq 0 ]
}

@test "detect returns 2 when no manifest exists" {
  run bash -c "${COMMON_SRC}; NOTES_QUIET_MANIFEST_CHECK=1 detect_assume_unchanged_manifest 'notes'"
  [ "$status" -eq 2 ]
}

# --- repair_assume_unchanged_manifest ---

@test "repair clears assume-unchanged when safe" {
  echo -e "abc12345\talpha.md" > "$TARGET_DIR/notes/.manifest"
  git -C "$TARGET_DIR" add notes/.manifest
  git -C "$TARGET_DIR" commit -q -m "init"
  git -C "$TARGET_DIR" update-index --assume-unchanged notes/.manifest

  run bash -c "${COMMON_SRC}; TARGET_DIR='$TARGET_DIR'; repair_assume_unchanged_manifest 'notes'"
  [ "$status" -eq 0 ]
  flag=$(git -C "$TARGET_DIR" ls-files -v notes/.manifest | cut -c1)
  [ "$flag" = "H" ]
}

@test "repair returns 2 when content differs from HEAD" {
  echo -e "abc12345\talpha.md" > "$TARGET_DIR/notes/.manifest"
  git -C "$TARGET_DIR" add notes/.manifest
  git -C "$TARGET_DIR" commit -q -m "init"
  git -C "$TARGET_DIR" update-index --assume-unchanged notes/.manifest
  echo -e "abc12345\talpha.md\ndef67890\tbeta.md" > "$TARGET_DIR/notes/.manifest"

  run bash -c "${COMMON_SRC}; TARGET_DIR='$TARGET_DIR'; repair_assume_unchanged_manifest 'notes'"
  [ "$status" -eq 2 ]
  flag=$(git -C "$TARGET_DIR" ls-files -v notes/.manifest | cut -c1)
  [ "$flag" = "H" ]
}

@test "repair returns 1 when not assume-unchanged (no-op)" {
  echo -e "abc12345\talpha.md" > "$TARGET_DIR/notes/.manifest"
  git -C "$TARGET_DIR" add notes/.manifest
  git -C "$TARGET_DIR" commit -q -m "init"

  run bash -c "${COMMON_SRC}; TARGET_DIR='$TARGET_DIR'; repair_assume_unchanged_manifest 'notes'"
  [ "$status" -eq 1 ]
}

@test "repair handles clean assume-unchanged manifest under set -e" {
  echo -e "abc12345\talpha.md" > "$TARGET_DIR/notes/.manifest"
  git -C "$TARGET_DIR" add notes/.manifest
  git -C "$TARGET_DIR" commit -q -m "init"
  git -C "$TARGET_DIR" update-index --assume-unchanged notes/.manifest

  run bash -c "set -euo pipefail; ${COMMON_SRC}; TARGET_DIR='$TARGET_DIR'; repair_assume_unchanged_manifest 'notes'"
  [ "$status" -eq 0 ]
  flag=$(git -C "$TARGET_DIR" ls-files -v notes/.manifest | cut -c1)
  [ "$flag" = "H" ]
}

# --- notes status with assume-unchanged manifest ---

@test "status shows assume-unchanged warning when diverged from HEAD" {
  echo -e "abc12345\talpha.md" > "$TARGET_DIR/notes/.manifest"
  git -C "$TARGET_DIR" add notes/.manifest
  git -C "$TARGET_DIR" commit -q -m "init"
  git -C "$TARGET_DIR" update-index --assume-unchanged notes/.manifest
  echo -e "abc12345\talpha.md\ndef67890\tbeta.md" > "$TARGET_DIR/notes/.manifest"

  run bash -c "
    source '$REPO_DIR/lib/common.sh'
    source '$REPO_DIR/lib/obfuscate.sh'
    source '$REPO_DIR/lib/suppress.sh'
    source '$REPO_DIR/lib/changes.sh'
    source '$REPO_DIR/lib/conflicts.sh'
    TARGET_DIR='$TARGET_DIR'
    NOTES_DIR='notes'
    cd \"\$TARGET_DIR\"
    detect_assume_unchanged_manifest \"\$NOTES_DIR\" >/dev/null 2>&1
    rc=\$?
    if [ \"\$rc\" -eq 0 ]; then
      echo '⚠️  Manifest warning: notes/.manifest is assume-unchanged and differs from HEAD.'
    elif [ \"\$rc\" -eq 1 ]; then
      echo 'ℹ️  Manifest note: notes/.manifest is assume-unchanged (matches HEAD).'
    fi
  "
  echo "$output" | grep -q "Manifest warning"
  echo "$output" | grep -q "differs from HEAD"
}

@test "status shows assume-unchanged note when matches HEAD" {
  echo -e "abc12345\talpha.md" > "$TARGET_DIR/notes/.manifest"
  git -C "$TARGET_DIR" add notes/.manifest
  git -C "$TARGET_DIR" commit -q -m "init"
  git -C "$TARGET_DIR" update-index --assume-unchanged notes/.manifest

  run bash -c "
    source '$REPO_DIR/lib/common.sh'
    TARGET_DIR='$TARGET_DIR'
    NOTES_DIR='notes'
    cd \"\$TARGET_DIR\"
    detect_assume_unchanged_manifest \"\$NOTES_DIR\" >/dev/null 2>&1
    rc=\$?
    if [ \"\$rc\" -eq 0 ]; then
      echo '⚠️  Manifest warning: notes/.manifest is assume-unchanged and differs from HEAD.'
    elif [ \"\$rc\" -eq 1 ]; then
      echo 'ℹ️  Manifest note: notes/.manifest is assume-unchanged (matches HEAD).'
    fi
  "
  echo "$output" | grep -q "Manifest note"
  echo "$output" | grep -q "matches HEAD"
}

# --- notes changes --summary (assume-unchanged detection) ---

@test "changes --summary warns about assume-unchanged manifest" {
  echo -e "abc12345\talpha.md" > "$TARGET_DIR/notes/.manifest"
  git -C "$TARGET_DIR" add notes/.manifest
  git -C "$TARGET_DIR" commit -q -m "init"
  git -C "$TARGET_DIR" update-index --assume-unchanged notes/.manifest

  run bash -c "
    source '$REPO_DIR/lib/common.sh'
    source '$REPO_DIR/lib/changes.sh'
    source '$REPO_DIR/lib/obfuscate.sh'
    source '$REPO_DIR/lib/suppress.sh'
    NOTES_QUIET_MANIFEST_CHECK=1
    TARGET_DIR='$TARGET_DIR'
    notes_dir='notes'
    abs_notes_dir='$TARGET_DIR/notes'
    changes=\$(detect_changes \"\$abs_notes_dir\" 2>/dev/null) || true
    if [ -z \"\$changes\" ]; then
      echo 'No changes.'
      detect_assume_unchanged_manifest \"\$notes_dir\"
      rc=\$?
      if [ \"\$rc\" -eq 1 ]; then
        echo 'Note: notes/.manifest is assume-unchanged (matches HEAD).'
      fi
    fi
  "
  echo "$output" | grep -q "No changes"
  echo "$output" | grep -q "assume-unchanged"
}

@test "changes --summary handles clean assume-unchanged manifest through real task" {
  echo -e "abc12345\talpha.md" > "$TARGET_DIR/notes/.manifest"
  echo "alpha" > "$TARGET_DIR/notes/abc12345"
  git -C "$TARGET_DIR" add notes/.manifest notes/abc12345
  git -C "$TARGET_DIR" commit -q -m "init"
  git -C "$TARGET_DIR" update-index --assume-unchanged notes/.manifest

  run notes changes --summary
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "No changes"
  echo "$output" | grep -q "assume-unchanged (matches HEAD)"
}

@test "status handles clean assume-unchanged manifest through real task" {
  echo -e "abc12345\talpha.md" > "$TARGET_DIR/notes/.manifest"
  echo "alpha" > "$TARGET_DIR/notes/abc12345"
  git -C "$TARGET_DIR" add notes/.manifest notes/abc12345
  git -C "$TARGET_DIR" commit -q -m "init"
  git -C "$TARGET_DIR" update-index --assume-unchanged notes/.manifest

  run notes status
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Manifest note"
  echo "$output" | grep -q "assume-unchanged (matches HEAD)"
}

# --- notes pull ---

@test "pull clears assume-unchanged before git pull attempt" {
  echo -e "abc12345\talpha.md" > "$TARGET_DIR/notes/.manifest"
  git -C "$TARGET_DIR" add notes/.manifest
  git -C "$TARGET_DIR" commit -q -m "init"
  git -C "$TARGET_DIR" update-index --assume-unchanged notes/.manifest

  run bash -c "
    source '$REPO_DIR/lib/common.sh'
    source '$REPO_DIR/lib/obfuscate.sh'
    source '$REPO_DIR/lib/suppress.sh'
    TARGET_DIR='$TARGET_DIR'
    NOTES_QUIET_MANIFEST_CHECK=1
    notes_dir='notes'
    abs_notes_dir='$TARGET_DIR/notes'
    manifest=\"\$abs_notes_dir/.manifest\"
    if [ -f \"\$manifest\" ]; then
      detect_assume_unchanged_manifest \"\$notes_dir\"
      manifest_rc=\$?
      if [ \"\$manifest_rc\" -eq 1 ]; then
        echo 'Manifest is assume-unchanged but matches HEAD — clearing flag...'
        git -C \"\$TARGET_DIR\" update-index --no-assume-unchanged \"\$notes_dir/.manifest\"
        echo 'Cleared assume-unchanged on notes/.manifest'
      fi
    fi
  "
  echo "$output" | grep -q "Cleared"
  flag=$(git -C "$TARGET_DIR" ls-files -v notes/.manifest | cut -c1)
  [ "$flag" = "H" ]
}

@test "pull fails with clear message when manifest diverged from HEAD" {
  echo -e "abc12345\talpha.md" > "$TARGET_DIR/notes/.manifest"
  git -C "$TARGET_DIR" add notes/.manifest
  git -C "$TARGET_DIR" commit -q -m "init"
  git -C "$TARGET_DIR" update-index --assume-unchanged notes/.manifest
  echo -e "abc12345\talpha.md\ndef67890\tbeta.md" > "$TARGET_DIR/notes/.manifest"

  run bash -c "
    source '$REPO_DIR/lib/common.sh'
    TARGET_DIR='$TARGET_DIR'
    NOTES_QUIET_MANIFEST_CHECK=1
    notes_dir='notes'
    detect_assume_unchanged_manifest \"\$notes_dir\"
    manifest_rc=\$?
    if [ \"\$manifest_rc\" -eq 0 ]; then
      echo 'Error: notes/.manifest is assume-unchanged and DIFFERS from HEAD.' >&2
      exit 1
    fi
  "
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "DIFFERS"
}

@test "pull clears clean assume-unchanged manifest through real task" {
  local remote
  remote="$BATS_TEST_TMPDIR/origin.git"
  git init -q --bare "$remote"

  echo -e "abc12345\talpha.md" > "$TARGET_DIR/notes/.manifest"
  echo "alpha" > "$TARGET_DIR/notes/abc12345"
  git -C "$TARGET_DIR" add notes/.manifest notes/abc12345
  git -C "$TARGET_DIR" commit -q -m "init"
  git -C "$TARGET_DIR" remote add origin "$remote"
  git -C "$TARGET_DIR" push -q -u origin HEAD
  git -C "$TARGET_DIR" update-index --assume-unchanged notes/.manifest

  run notes pull
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Cleared assume-unchanged"
  echo "$output" | grep -q "Pull complete"
  flag=$(git -C "$TARGET_DIR" ls-files -v notes/.manifest | cut -c1)
  [ "$flag" = "H" ]
}

@test "pull reports the original git pull exit status" {
  echo -e "abc12345\talpha.md" > "$TARGET_DIR/notes/.manifest"
  echo "alpha" > "$TARGET_DIR/notes/abc12345"
  git -C "$TARGET_DIR" add notes/.manifest notes/abc12345
  git -C "$TARGET_DIR" commit -q -m "init"

  run notes pull
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "Error: git pull failed (exit"
  ! echo "$output" | grep -q "Error: git pull failed (exit 0)"
}
