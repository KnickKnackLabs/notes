#!/usr/bin/env bash
# encryption.sh — staged encrypted-path validation

# Verify that indexed blobs for encrypted paths are encrypted.
# The common path checks all paths in one git-crypt call. If that call reports
# plaintext or fails, inspect paths individually so diagnostics remain precise
# and unexpected backend failures remain fail closed.
# Usage: verify_encrypted_paths <path...>
verify_encrypted_paths() {
  local encrypted_paths=("$@")
  local batch_output batch_status=0 marker_status=0

  [ "${#encrypted_paths[@]}" -gt 0 ] || return 0

  if batch_output=$(git-crypt status -- "${encrypted_paths[@]}" 2>&1); then
    :
  else
    batch_status=$?
  fi

  # git-crypt reports plaintext paths in human output but still exits zero.
  # Use the same marker as the existing per-path contract only to select the
  # precise fallback; do not parse path names from batched output.
  grep -qi "not encrypted" <<< "$batch_output" || marker_status=$?
  case "$marker_status" in
    0) ;;
    1)
      [ "$batch_status" -eq 0 ] && return 0
      ;;
    *)
      echo "ERROR: could not interpret git-crypt inspection output" >&2
      [ -z "$batch_output" ] || printf '%s\n' "$batch_output" >&2
      return 1
      ;;
  esac

  local bad_files=()
  local file status_output status
  for file in "${encrypted_paths[@]}"; do
    status_output=""
    status=0
    marker_status=0
    if status_output=$(git-crypt status -- "$file" 2>&1); then
      :
    else
      status=$?
    fi

    grep -qi "not encrypted" <<< "$status_output" || marker_status=$?
    case "$marker_status" in
      0)
        bad_files+=("$file")
        ;;
      1)
        if [ "$status" -ne 0 ]; then
          echo "ERROR: git-crypt could not inspect staged encrypted path: $file" >&2
          [ -z "$status_output" ] || printf '%s\n' "$status_output" >&2
          return 1
        fi
        ;;
      *)
        echo "ERROR: could not interpret git-crypt inspection output for: $file" >&2
        [ -z "$status_output" ] || printf '%s\n' "$status_output" >&2
        return 1
        ;;
    esac
  done

  if [ "${#bad_files[@]}" -gt 0 ]; then
    echo "ERROR: Staged files should be encrypted but are plaintext:" >&2
    printf '  %s\n' "${bad_files[@]}" >&2
    echo "" >&2
    echo "Run 'notes unlock' if git-crypt is locked, then re-stage." >&2
    return 1
  fi

  # The batched command failed, but no individual path explained the failure.
  # Preserve fail-closed behavior rather than trusting an ambiguous result.
  echo "ERROR: git-crypt could not inspect staged encrypted paths" >&2
  [ -z "$batch_output" ] || printf '%s\n' "$batch_output" >&2
  return 1
}
