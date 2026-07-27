#!/usr/bin/env bash
# obfuscate.sh — Layer 1: Filesystem + Manifest operations
# Pure renames + manifest updates. No git staging, no suppression.

# Refuse to proceed if a filename's basename looks like an obfuscated id.
# An obfuscated id is 8 lowercase hex characters with no extension.
#
# The corpus planner uses manifest IDs to detect "already obfuscated, skip."
# If the manifest is inconsistent (stale, lost entries, orphan blobs), that
# check can miss and the file would be re-obfuscated under a new random id,
# creating a duplicate blob and masking the underlying problem. Better to
# fail loudly and make the user investigate.
#
# Returns 0 (proceed) if the basename is a normal filename.
# Returns 1 (stop) and prints diagnostic to stderr if it looks obfuscated.
refuse_if_hex_basename() {
  local relpath="$1"
  local base
  base="${relpath##*/}"
  if [[ "$base" =~ ^[a-f0-9]{8}$ ]]; then
    cat >&2 <<EOF
Error: refusing to obfuscate '$relpath' — basename looks like an obfuscated id.

  This indicates the manifest is inconsistent with the working tree. Possible
  causes:
    - Stale manifest that lost the mapping for an already-obfuscated file
    - Orphan obfuscated blob with no manifest entry
    - Readable file created with a hash-shaped name (unusual)

  Re-obfuscating would create a duplicate blob under a fresh random id and
  hide the underlying problem. Fix the manifest first, then retry.

  Diagnose with: notes status, notes changes
EOF
    return 1
  fi
  return 0
}

# Build a corpus-level obfuscation plan.
# Output rows are "<kind>\t<id-or-dash>\t<relpath>", where kind is
# "known" for an existing manifest mapping or "new" for a new readable name.
# Already-obfuscated IDs are omitted. The full plan is checked for orphan
# hash-shaped names before any caller mutates the working tree.
# Usage: build_obfuscation_plan <notes_dir> <plan_file> [file...]
build_obfuscation_plan() {
  local notes_dir="$1" plan_file="$2"
  shift 2
  local scoped_files=("$@")
  local manifest="$notes_dir/.manifest"
  local workspace candidates manifest_input

  workspace=$(mktemp -d) || {
    echo "Error: failed to create obfuscation workspace" >&2
    return 1
  }
  candidates="$workspace/candidates"
  : > "$candidates"

  if [ ${#scoped_files[@]} -gt 0 ] && [ -n "${scoped_files[0]}" ]; then
    local relpath
    for relpath in "${scoped_files[@]}"; do
      [[ "$relpath" == ".manifest" ]] && continue
      [ -f "$notes_dir/$relpath" ] || continue
      printf '%s\n' "$relpath" >> "$candidates"
    done
  else
    local file relpath
    while IFS= read -r file; do
      [ -f "$file" ] || continue
      relpath="${file#"$notes_dir"/}"
      [[ "$relpath" == ".manifest" ]] && continue
      printf '%s\n' "$relpath" >> "$candidates"
    done < <(find "$notes_dir" -type f | sort)
  fi

  manifest_input="$manifest"
  if [ ! -f "$manifest_input" ]; then
    manifest_input="$workspace/manifest"
    : > "$manifest_input"
  fi

  if ! awk -F '\t' -v OFS='\t' -v candidates="$candidates" '
    FILENAME != candidates {
      if ($1 != "") {
        if (($1 in id_names) && id_names[$1] != $2) duplicate_ids[$1] = 1
        id_names[$1] = $2
        ids[$1] = 1
        if (!($2 in names)) names[$2] = $1
      }
      next
    }
    {
      relpath = $0
      if (relpath == "" || seen[relpath]++) next
      count = split(relpath, parts, "/")
      base = parts[count]
      if (base in ids) next
      if (base ~ /^[a-f0-9]{8}$/) {
        print "invalid", "-", relpath
      } else if (relpath in names) {
        if (names[relpath] in duplicate_ids) {
          print "collision", names[relpath], relpath
        } else {
          print "known", names[relpath], relpath
        }
      } else {
        print "new", "-", relpath
      }
    }
  ' "$manifest_input" "$candidates" > "$plan_file"; then
    rm -rf "$workspace"
    return 1
  fi

  local kind id
  while IFS=$'\t' read -r kind id relpath; do
    if [ "$kind" = "invalid" ]; then
      rm -rf "$workspace"
      refuse_if_hex_basename "$relpath"
      return 1
    fi
    if [ "$kind" = "collision" ]; then
      rm -rf "$workspace"
      echo "Error: manifest ID '$id' maps to multiple readable paths" >&2
      return 1
    fi
    if [ "$kind" = "known" ] && [ -e "$notes_dir/$id" ]; then
      rm -rf "$workspace"
      echo "Error: refusing to overwrite existing obfuscated path: $id" >&2
      return 1
    fi
  done < "$plan_file"

  rm -rf "$workspace"
}

# Apply a precomputed obfuscation plan.
# Outputs "<relpath>\t<id>" per renamed file for callers to stage.
# Usage: apply_obfuscation_plan <notes_dir> <plan_file> <scoped_mode>
apply_obfuscation_plan() {
  local notes_dir="$1" plan_file="$2" scoped_mode="$3"
  local manifest="$notes_dir/.manifest"
  local new_entries kind id relpath new_count=0

  [ -s "$plan_file" ] || return 2

  new_entries=$(mktemp) || {
    echo "Error: failed to create temp file" >&2
    return 1
  }

  while IFS=$'\t' read -r kind id relpath; do
    [ "$kind" = "known" ] || continue
    if ! mv "$notes_dir/$relpath" "$notes_dir/$id"; then
      echo "Error: failed to rename $relpath → $id" >&2
      rm -f "$new_entries"
      return 1
    fi
    printf '%s\t%s\n' "$relpath" "$id"
  done < "$plan_file"

  while IFS=$'\t' read -r kind id relpath; do
    [ "$kind" = "new" ] || continue
    id=$(openssl rand -hex 4)
    while manifest_has_id "$manifest" "$id" || \
          grep -q "^${id}"$'\t' "$new_entries" 2>/dev/null || \
          [ -f "$notes_dir/$id" ]; do
      id=$(openssl rand -hex 4)
    done

    printf '%s\t%s\n' "$id" "$relpath" >> "$new_entries"
    if ! mv "$notes_dir/$relpath" "$notes_dir/$id"; then
      echo "Error: failed to rename $relpath → $id" >&2
      rm -f "$new_entries"
      return 1
    fi
    printf '%s\t%s\n' "$relpath" "$id"
    new_count=$((new_count + 1))
  done < "$plan_file"

  # Empty-directory cleanup is cosmetic and must not invalidate completed renames.
  if ! find "$notes_dir" -mindepth 1 -type d -empty -delete 2>/dev/null; then
    :
  fi

  # Scoped re-obfuscation of existing manifest entries should not rewrite the
  # manifest at all. Re-sorting a valid but differently-ordered manifest creates
  # an order-only dirty worktree after the pre-commit hook, because scoped
  # obfuscation intentionally does not stage unchanged manifest mappings.
  if $scoped_mode && [ "$new_count" -eq 0 ]; then
    rm -f "$new_entries"
    return 0
  fi

  # Update manifest: merge existing + new entries, sorted by name.
  # An entry is live if either its obfuscated id or readable name is on disk.
  local merged
  merged=$(mktemp) || {
    echo "Error: failed to create temp file" >&2
    rm -f "$new_entries"
    return 1
  }

  if [ -f "$manifest" ]; then
    while IFS=$'\t' read -r id relpath; do
      [ -z "$id" ] && continue
      if [ -f "$notes_dir/$id" ] || [ -f "$notes_dir/$relpath" ]; then
        printf '%s\t%s\n' "$id" "$relpath"
      fi
    done < "$manifest" > "$merged"
  fi

  cat "$new_entries" >> "$merged"
  # Sort to a temp file first, then mv — avoids truncating the manifest
  # if sort fails (sort > $manifest truncates before sort runs).
  local sorted
  sorted=$(mktemp) || {
    echo "Error: failed to create temp file" >&2
    rm -f "$merged" "$new_entries"
    return 1
  }
  if ! sort -t$'\t' -k2 "$merged" > "$sorted"; then
    echo "Error: failed to sort manifest" >&2
    rm -f "$merged" "$new_entries" "$sorted"
    return 1
  fi
  mv -f "$sorted" "$manifest"
  rm -f "$merged" "$new_entries"
}

# Rename readable files to obfuscated IDs.
# Outputs "<relpath>\t<id>" per renamed file (for callers to stage).
# Usage: rename_to_obfuscated <notes_dir> [file...]
#   Without files: scans notes_dir for all non-obfuscated files.
#   With files: only processes the listed files (relative to notes_dir).
rename_to_obfuscated() {
  local notes_dir="$1"
  shift
  local scoped_mode=false plan rc
  [ "$#" -gt 0 ] && [ -n "${1:-}" ] && scoped_mode=true

  plan=$(mktemp) || {
    echo "Error: failed to create temp file" >&2
    return 1
  }
  if ! build_obfuscation_plan "$notes_dir" "$plan" "$@"; then
    rm -f "$plan"
    return 1
  fi

  apply_obfuscation_plan "$notes_dir" "$plan" "$scoped_mode" && rc=0 || rc=$?
  rm -f "$plan"
  return "$rc"
}

# Local state file recording the readable path and content hash last restored
# for each ID. This lets deobfuscation distinguish a clean generated readable
# file (safe to update/remove after pull/merge/checkout) from a locally-edited
# readable file (must preserve).
#
# Current row format: <id>\t<relpath>\t<tracked-hash>\t<raw-hash>
# Previous row format: <id>\t<relpath>\t<tracked-hash>
# Legacy row format:   <id>\t<tracked-hash>
_deobfuscation_state_file() {
  local notes_dir="$1"
  resolve_notes_dir "$notes_dir" || return 1
  printf '%s/.git/info/notes-obfuscation-state' "$RESOLVED_REPO_ROOT"
}

_deobfuscation_base_hash_for_id() {
  local notes_dir="$1" id="$2"
  local state
  state=$(_deobfuscation_state_file "$notes_dir") || return 0
  [ -f "$state" ] || return 0
  # Last entry wins. The state file is append-only (see
  # _record_deobfuscation_base_hashes); newer writes shadow older ones, and
  # concurrent writers can't corrupt each other the way a tmp+mv
  # read-modify-write would.
  awk -F '\t' -v wanted="$id" '
    $1 == wanted {
      if (NF >= 3) found=$3; else found=$2
    }
    END { if (found != "") print found }
  ' "$state"
}

_deobfuscation_base_raw_hash_for_id() {
  local notes_dir="$1" id="$2"
  local state
  state=$(_deobfuscation_state_file "$notes_dir") || return 0
  [ -f "$state" ] || return 0
  awk -F '\t' -v wanted="$id" '
    $1 == wanted { found = (NF >= 4 ? $4 : "") }
    END { if (found != "") print found }
  ' "$state"
}

_deobfuscation_readable_matches_base_ref() {
  local notes_dir="$1" id="$2" relpath="$3" base_ref="$4"
  [ -n "$base_ref" ] || return 1
  [ -f "$notes_dir/$relpath" ] || return 1

  resolve_notes_dir "$notes_dir" || return 1
  local repo_root="$RESOLVED_REPO_ROOT"
  local notes_rel="$RESOLVED_NOTES_DIR"
  local tmp
  tmp=$(mktemp) || return 1

  if ! git -C "$repo_root" cat-file --filters "$base_ref:$notes_rel/$id" > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi

  if cmp -s "$tmp" "$notes_dir/$relpath"; then
    rm -f "$tmp"
    return 0
  fi

  rm -f "$tmp"
  return 1
}

_calculate_deobfuscation_state_rows() {
  local notes_dir="$1"
  shift
  local ids=("$@")
  local manifest="$notes_dir/.manifest"
  [ -f "$manifest" ] || return 0
  [ ${#ids[@]} -gt 0 ] || return 0

  resolve_notes_dir "$notes_dir" || return 0
  local repo_root="$RESOLVED_REPO_ROOT"
  local notes_rel="$RESOLVED_NOTES_DIR"
  local workspace
  local tracked_paths=()
  workspace=$(mktemp -d) || return 1
  printf '%s\n' "${ids[@]}" > "$workspace/requested"
  : > "$workspace/records"
  : > "$workspace/raw-in"

  awk -F '\t' '
    FNR == NR { requested[$1] = 1; next }
    $1 in requested { print $1 "\t" $2 }
  ' "$workspace/requested" "$manifest" > "$workspace/candidates"

  local id relpath
  while IFS=$'\t' read -r id relpath; do
    [ -z "$id" ] && continue
    [ -f "$notes_dir/$relpath" ] || continue
    printf '%s\t%s\t%s/%s\n' "$id" "$relpath" "$notes_rel" "$id" >> "$workspace/records"
    printf '%s/%s\n' "$notes_rel" "$relpath" >> "$workspace/raw-in"
    tracked_paths+=("$notes_rel/$id")
  done < "$workspace/candidates"

  if [ ! -s "$workspace/records" ]; then
    rm -rf "$workspace"
    return 0
  fi

  if ! git -C "$repo_root" hash-object --no-filters --stdin-paths \
    < "$workspace/raw-in" > "$workspace/raw-out"; then
    rm -rf "$workspace"
    return 1
  fi
  if ! git -C "$repo_root" -c core.quotePath=false ls-files --stage -- \
    "${tracked_paths[@]}" > "$workspace/index-out"; then
    rm -rf "$workspace"
    return 1
  fi

  awk -F '\t' \
    -v index_file="$workspace/index-out" \
    -v records_file="$workspace/records" \
    -v raw_file="$workspace/raw-out" '
      FILENAME == index_file {
        split($1, metadata, " ")
        tracked[$2] = metadata[2]
        next
      }
      FILENAME == records_file {
        if ((getline raw < raw_file) <= 0) exit 1
        if ($3 in tracked && raw != "") {
          print $1 "\t" $2 "\t" tracked[$3] "\t" raw
        }
      }
    ' "$workspace/index-out" "$workspace/records" || {
      rm -rf "$workspace"
      return 1
    }

  rm -rf "$workspace"
}

_record_deobfuscation_base_hashes() {
  local notes_dir="$1"
  shift
  local state rows
  state=$(_deobfuscation_state_file "$notes_dir") || return 0
  rows=$(mktemp) || return 1

  if ! _calculate_deobfuscation_state_rows "$notes_dir" "$@" > "$rows"; then
    rm -f "$rows"
    return 1
  fi
  if [ ! -s "$rows" ]; then
    rm -f "$rows"
    return 0
  fi

  mkdir -p "$(dirname "$state")"
  touch "$state"

  # Append one complete row at a time. Each row stays below PIPE_BUF, preserving
  # the concurrent append contract while newer rows shadow older formats.
  local row
  while IFS= read -r row; do
    [ -n "$row" ] && printf '%s\n' "$row" >> "$state"
  done < "$rows"

  rm -f "$rows"
}

# Rename a single obfuscated ID back to its readable name.
# Returns: 0=renamed, 2=skipped (not found/no match),
#          3=dirty readable preserved, 1=error (mv failed).
_rename_one_to_readable() {
  local notes_dir="$1" manifest="$2" id="$3" relpath="${4:-}"
  [ ! -f "$notes_dir/$id" ] && return 2
  if [ -z "$relpath" ]; then
    relpath=$(manifest_name_for_id "$manifest" "$id")
    [ -z "$relpath" ] && return 2
  fi

  local target_dir
  target_dir=$(dirname "$notes_dir/$relpath")
  [ ! -d "$target_dir" ] && mkdir -p "$target_dir"

  if [ -e "$notes_dir/$relpath" ] && ! cmp -s "$notes_dir/$id" "$notes_dir/$relpath"; then
    local current_hash base_hash base_raw_hash state_file dirty_readable=false
    state_file=$(_deobfuscation_state_file "$notes_dir" 2>/dev/null) || state_file=""
    base_raw_hash=$(_deobfuscation_base_raw_hash_for_id "$notes_dir" "$id")
    if [ -n "$base_raw_hash" ]; then
      base_hash="$base_raw_hash"
      if ! current_hash=$(git -C "$notes_dir" hash-object --no-filters -- "$notes_dir/$relpath" 2>/dev/null); then
        current_hash=""
      fi
    else
      base_hash=$(_deobfuscation_base_hash_for_id "$notes_dir" "$id")
      if ! current_hash=$(git -C "$notes_dir" hash-object -- "$notes_dir/$relpath" 2>/dev/null); then
        current_hash=""
      fi
    fi

    # No state file (fresh clone or pre-safety upgrade) -> trust the readable
    # and let the rename proceed. Force-prompting on every file would train
    # users into --force-as-default, which is worse than the one-time window.
    if [ -n "$state_file" ] && [ -f "$state_file" ]; then
      if [ -n "$base_hash" ]; then
        [ "$current_hash" != "$base_hash" ] && dirty_readable=true
      elif ! _deobfuscation_readable_matches_base_ref \
        "$notes_dir" "$id" "$relpath" "${NOTES_DEOBFUSCATE_BASE_REF:-}"; then
        dirty_readable=true
      fi

      if $dirty_readable && [ "${NOTES_DEOBFUSCATE_FORCE:-false}" != "true" ]; then
        echo "Error: refusing to overwrite dirty readable note: $relpath" >&2
        echo "This may be a real local edit, or a cosmetic editor re-save (trailing-newline trim, BOM, line-ending change)." >&2
        echo "Run 'notes changes $relpath' to inspect; rerun with --force to overwrite intentionally." >&2
        return 3
      fi
    fi
  fi

  # Use -f only after the safety check above. Identical readable copies are
  # harmless; differing copies require explicit --force.
  if ! mv -f "$notes_dir/$id" "$notes_dir/$relpath"; then
    echo "Error: failed to rename $id → $relpath" >&2
    return 1
  fi
  printf '%s\t%s\n' "$id" "$relpath"
}

# Rename obfuscated IDs back to readable names.
# Outputs "<id>\t<relpath>" per renamed file.
# Returns 0 on success, 2 if nothing to do, 3 if dirty readables were
# preserved, 1 on hard error.
# Usage: rename_to_readable <notes_dir> [id...]
#   Without ids: deobfuscates all files listed in the manifest.
#   With ids: only deobfuscates the specified IDs.
rename_to_readable() {
  local notes_dir="$1"
  shift
  local scoped_ids=("$@")
  local manifest="$notes_dir/.manifest"
  local count=0 dirty_count=0

  [ ! -f "$manifest" ] && return 1

  # _rename_one_to_readable returns: 0=renamed, 2=skipped,
  # 3=dirty readable preserved, 1=hard error.
  if [ ${#scoped_ids[@]} -gt 0 ] && [ -n "${scoped_ids[0]}" ]; then
    for id in "${scoped_ids[@]}"; do
      local _rc
      _rename_one_to_readable "$notes_dir" "$manifest" "$id" && _rc=0 || _rc=$?
      case $_rc in
        0) count=$((count + 1)) ;;
        3) dirty_count=$((dirty_count + 1)) ;;
        1) return 1 ;;
      esac
    done
  else
    # The helper moves note files but does not modify the manifest being read.
    # shellcheck disable=SC2094
    while IFS=$'\t' read -r id relpath; do
      [ -z "$id" ] && continue
      local _rc
      _rename_one_to_readable "$notes_dir" "$manifest" "$id" "$relpath" && _rc=0 || _rc=$?
      case $_rc in
        0) count=$((count + 1)) ;;
        3) dirty_count=$((dirty_count + 1)) ;;
        1) return 1 ;;
      esac
    done < "$manifest"
  fi

  [ "$dirty_count" -gt 0 ] && return 3
  [ "$count" -eq 0 ] && return 2
  return 0
}
