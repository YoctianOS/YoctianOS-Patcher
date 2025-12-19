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

echo "Found at least one '$MARK_OUT' under $EDIT_BASE — starting patch export (edit -> git)..."
echo "GIT_BASE: $GIT_BASE"
echo "EDIT_BASE: $EDIT_BASE"
echo "OUTPUT_BASE: $OUTPUT_BASE"
echo

# Loop through all projects inside EDIT_BASE
for project in "$EDIT_BASE"/*; do
  [ -d "$project" ] || continue
  project_name=$(basename "$project")

  # Skip backups
  [[ "$project_name" == *.backup ]] && { echo "Skipping backup '$project_name'"; continue; }
  [ -d "$EDIT_BASE/${project_name}.backup" ] && { echo "Skipping '$project_name' (sibling backup exists)"; continue; }

  GIT_DIR="$GIT_BASE/$project_name"
  EDIT_DIR="$EDIT_BASE/$project_name"
  OUTPUT_DIR="$OUTPUT_BASE/$project_name"

  [ -d "$GIT_DIR" ] || { echo "No original repo for $project_name, skipping."; continue; }

  mkdir -p "$OUTPUT_DIR"
  echo "Processing project: $project_name"

  while IFS= read -r -d '' edit_file; do
    rel_path="${edit_file#$EDIT_DIR/}"
    repo_file="$GIT_DIR/$rel_path"

    if [ ! -f "$repo_file" ]; then
      if ! is_text_file "$edit_file"; then
        echo "SKIP binary-only-in-edit: $project_name/$rel_path"
        continue
      fi
      patch_name="$(sanitize "$rel_path").patch"
      mkdir -p "$(dirname "$OUTPUT_DIR/$patch_name")"
      # diff returns 1 when files differ; neutralize to avoid set -e abort
      diff -u --label "a/$rel_path" --label "b/$rel_path" -- /dev/null "$edit_file" > "$OUTPUT_DIR/$patch_name" || true
      echo "Patch (add) created: $OUTPUT_DIR/$patch_name"
      continue
    fi

    if ! is_text_file "$repo_file" || ! is_text_file "$edit_file"; then
      echo "SKIP (binary): $project_name/$rel_path"
      continue
    fi

    proc="$TMPDIR/processed_$(sanitize "$project_name")_$(sanitize "$rel_path")"
    mkdir -p "$(dirname "$proc")"

    awk -v OUT="$MARK_OUT" -v G="$repo_file" -v E="$edit_file" '
      BEGIN {
        m = 0; while ((getline line < G) > 0) { m++; g[m] = line } close(G)
        n = 0; while ((getline line < E) > 0) { n++; e[n] = line } close(E)
        max = (m > n ? m : n)
        for (i = 1; i <= max; i++) {
          el = (i in e) ? e[i] : ""
          gl = (i in g) ? g[i] : ""
          sub(/\r$/, "", el); sub(/\r$/, "", gl)
          t = el; sub(/^[ \t]+/, "", t); sub(/[ \t]+$/, "", t)
          if (t == OUT) { print gl } else { print el }
        }
      }
    ' > "$proc"

    [ -s "$proc" ] || { echo "ERROR: processed file empty for $project_name/$rel_path"; continue; }

    if ! cmp -s -- "$repo_file" "$proc"; then
      patch_name="$(sanitize "$rel_path").patch"
      mkdir -p "$(dirname "$OUTPUT_DIR/$patch_name")"
      # diff returns 1 when files differ; neutralize to avoid set -e abort
      diff -u --label "a/$rel_path" --label "b/$rel_path" -- "$repo_file" "$proc" > "$OUTPUT_DIR/$patch_name" || true
      echo "Patch (git <- edit) created: $OUTPUT_DIR/$patch_name"
    else
      echo "No change for $project_name/$rel_path"
    fi
  done < <(find "$EDIT_DIR" -type f -print0)

  echo "Finished project: $project_name"
  echo
done

echo "Scanning for files present in git but missing in edit (will create delete patches only if MARK_OUT present)..."
for project in "$GIT_BASE"/*; do
  [ -d "$project" ] || continue
  project_name=$(basename "$project")

  GIT_DIR="$GIT_BASE/$project_name"
  EDIT_DIR="$EDIT_BASE/$project_name"
  OUTPUT_DIR="$OUTPUT_BASE/$project_name"
  mkdir -p "$OUTPUT_DIR"

  while IFS= read -r -d '' git_file; do
    rel_path="${git_file#$GIT_DIR/}"
    edit_file="$EDIT_DIR/$rel_path"
    if [ ! -f "$edit_file" ]; then
      if grep -qF -- "$MARK_OUT" "$git_file" 2>/dev/null; then
        if ! is_text_file "$git_file"; then
          echo "SKIP binary-only-in-git: $project_name/$rel_path"
          continue
        fi
        patch_name="$(sanitize "$rel_path").patch"
        mkdir -p "$(dirname "$OUTPUT_DIR/$patch_name")"
        # diff returns 1 when files differ; neutralize to avoid set -e abort
        diff -u --label "a/$rel_path" --label "b/$rel_path" -- "$git_file" /dev/null > "$OUTPUT_DIR/$patch_name" || true
        echo "Patch (delete) created: $OUTPUT_DIR/$patch_name"
      else
        echo "Skipping delete patch for $project_name/$rel_path (no $MARK_OUT in git file)"
      fi
    fi
  done < <(find "$GIT_DIR" -type f -print0)
done

echo "All differences exported as .patch files in $OUTPUT_BASE"
