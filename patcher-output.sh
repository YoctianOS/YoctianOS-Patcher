#!/usr/bin/env bash
set -euo pipefail

# Refuse root/sudo
if [ "$(id -u)" -eq 0 ] || [ -n "${SUDO_USER:-}" ]; then
  echo "Do not run this script as root or with sudo."
  exit 1
fi

# Base directories
GIT_BASE="./git"
EDIT_BASE="./edit"
OUTPUT_BASE="./output"
MARK_OUT="##edit-out##"

# Basic checks
for d in "$GIT_BASE" "$EDIT_BASE"; do
  if [ ! -d "$d" ]; then
    echo "Directory $d does not exist: $d"
    exit 1
  fi
done

# If no file under EDIT_BASE contains MARK_OUT, exit early
if ! grep -rF --binary-files=text -q "$MARK_OUT" "$EDIT_BASE" 2>/dev/null; then
  echo "No occurrences of '$MARK_OUT' found under $EDIT_BASE — nothing to do."
  exit 0
fi

mkdir -p "$OUTPUT_BASE"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

# sanitize a relative path into a safe filename
sanitize() {
  printf '%s' "$1" | sed 's#[/ ]#_#g'
}

# helper: is text file (heuristic)
is_text_file() {
  local f="$1"
  if command -v file >/dev/null 2>&1; then
    file -b --mime "$f" 2>/dev/null | grep -qE 'text|empty' && return 0 || return 1
  fi
  grep -Iq . "$f" 2>/dev/null && return 0 || return 1
}

# helper: is README (case-insensitive, matches names starting with "readme")
is_readme() {
  local p="$1"
  local base
  base="$(basename "$p")"
  shopt -s nocasematch
  if [[ "$base" == readme* ]]; then
    shopt -u nocasematch
    return 0
  fi
  shopt -u nocasematch
  return 1
}

echo "Found at least one '$MARK_OUT' under $EDIT_BASE — starting patch export (edit -> git)..."
echo "GIT_BASE: $GIT_BASE"
echo "EDIT_BASE: $EDIT_BASE"
echo "OUTPUT_BASE: $OUTPUT_BASE"
echo

# Loop through all projects inside EDIT_BASE
for project in "$EDIT_BASE"/*; do
  [ -d "$project" ] || continue
  project_name=$(basename "$project")

  # Skip top-level .git directory if present
  if [ "$project_name" = ".git" ]; then
    echo "Skipping top-level .git in $EDIT_BASE"
    continue
  fi

  # Skip projects that are backups or have a sibling .backup directory
  if [[ "$project_name" == *.backup ]]; then
    echo "Skipping project '$project_name' because it is a .backup directory."
    continue
  fi
  if [ -d "$EDIT_BASE/${project_name}.backup" ]; then
    echo "Skipping project '$project_name' because sibling '${project_name}.backup' exists."
    continue
  fi

  GIT_DIR="$GIT_BASE/$project_name"
  EDIT_DIR="$EDIT_BASE/$project_name"
  OUTPUT_DIR="$OUTPUT_BASE/$project_name"

  if [ ! -d "$GIT_DIR" ]; then
    echo "No original repo found for $project_name, skipping."
    continue
  fi

  mkdir -p "$OUTPUT_DIR"
  echo "Processing project: $project_name"

  # Walk through all files in EDIT_DIR safely, excluding any .git directories at any depth
  while IFS= read -r -d '' edit_file; do
    rel_path="${edit_file#$EDIT_DIR/}"

    # Always skip README files in edit (preserve them)
    if is_readme "$rel_path"; then
      echo "Skipping README in edit: $project_name/$rel_path"
      continue
    fi

    repo_file="$GIT_DIR/$rel_path"

    # If repo file does not exist -> create add patch (apply on git will add file)
    if [ ! -f "$repo_file" ]; then
      if ! is_text_file "$edit_file"; then
        echo "SKIP binary-only-in-edit: $project_name/$rel_path"
        continue
      fi
      patch_name="$(sanitize "$rel_path").patch"
      mkdir -p "$(dirname "$OUTPUT_DIR/$patch_name")"
      diff -u --label "a/$rel_path" --label "b/$rel_path" -- /dev/null "$edit_file" > "$OUTPUT_DIR/$patch_name"
      echo "Patch (add) created: $OUTPUT_DIR/$patch_name"
      continue
    fi

    # Both exist: build processed target where lines exactly MARK_OUT in edit are replaced by git lines
    if [ -f "$repo_file" ] && [ -f "$edit_file" ]; then
      if ! is_text_file "$repo_file" || ! is_text_file "$edit_file"; then
        echo "SKIP (binary): $project_name/$rel_path"
        continue
      fi

      proc="$TMPDIR/processed_$(sanitize "$project_name")_$(sanitize "$rel_path")"
      mkdir -p "$(dirname "$proc")"

      # Build processed target:
      # - if edit line trimmed == MARK_OUT -> use git line (preserve git)
      # - else -> use edit line (apply edit)
      awk -v OUT="$MARK_OUT" -v G="$repo_file" -v E="$edit_file" '
        BEGIN {
          m = 0
          while ((getline line < G) > 0) { m++; g[m] = line }
          close(G)
          n = 0
          while ((getline line < E) > 0) { n++; e[n] = line }
          close(E)
          max = (m > n ? m : n)
          for (i = 1; i <= max; i++) {
            el = (i in e) ? e[i] : ""
            gl = (i in g) ? g[i] : ""
            sub(/\r$/, "", el)
            sub(/\r$/, "", gl)
            t = el
            sub(/^[ \t]+/, "", t)
            sub(/[ \t]+$/, "", t)
            if (t == OUT) {
              print gl
            } else {
              print el
            }
          }
        }
      ' > "$proc"

      # ensure proc was written
      if [ ! -s "$proc" ]; then
        echo "ERROR: processed file is empty for $project_name/$rel_path — skipping"
        continue
      fi

      # create patch: IMPORTANT order is git -> processed_target (apply on git to update it)
      if ! cmp -s -- "$repo_file" "$proc"; then
        patch_name="$(sanitize "$rel_path").patch"
        mkdir -p "$(dirname "$OUTPUT_DIR/$patch_name")"
        diff -u --label "a/$rel_path" --label "b/$rel_path" -- "$repo_file" "$proc" > "$OUTPUT_DIR/$patch_name"
        echo "Patch (git <- edit) created: $OUTPUT_DIR/$patch_name"
      else
        echo "No change for $project_name/$rel_path"
      fi
    fi

  # exclude any .git directories at any depth
  done < <(find "$EDIT_DIR" -name .git -prune -o -type f -print0)

  echo "Finished project: $project_name"
  echo
done

# Detect files present in git but missing in edit and create delete patches
echo "Scanning for files present in git but missing in edit (will create delete patches)..."
for project in "$GIT_BASE"/*; do
  [ -d "$project" ] || continue
  project_name=$(basename "$project")

  # Skip top-level .git directory if present
  if [ "$project_name" = ".git" ]; then
    echo "Skipping top-level .git in $GIT_BASE"
    continue
  fi

  GIT_DIR="$GIT_BASE/$project_name"
  EDIT_DIR="$EDIT_BASE/$project_name"
  OUTPUT_DIR="$OUTPUT_BASE/$project_name"
  mkdir -p "$OUTPUT_DIR"

  # exclude .git directories when scanning git tree
  while IFS= read -r -d '' git_file; do
    rel_path="${git_file#$GIT_DIR/}"

    # Always skip README files in git when creating delete patches
    if is_readme "$rel_path"; then
      echo "Skipping README in git (no delete patch): $project_name/$rel_path"
      continue
    fi

    edit_file="$EDIT_DIR/$rel_path"
    if [ ! -f "$edit_file" ]; then
      if ! is_text_file "$git_file"; then
        echo "SKIP binary-only-in-git: $project_name/$rel_path"
        continue
      fi
      patch_name="$(sanitize "$rel_path").patch"
      mkdir -p "$(dirname "$OUTPUT_DIR/$patch_name")"
      diff -u --label "a/$rel_path" --label "b/$rel_path" -- "$git_file" /dev/null > "$OUTPUT_DIR/$patch_name"
      echo "Patch (delete) created: $OUTPUT_DIR/$patch_name"
    fi
  done < <(find "$GIT_DIR" -name .git -prune -o -type f -print0)
done

echo "All differences exported as .patch files in $OUTPUT_BASE"
