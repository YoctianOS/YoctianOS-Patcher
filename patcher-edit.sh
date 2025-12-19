#!/usr/bin/env bash
set -euo pipefail

# CONFIG
EDIT_ROOT="./edit"
MARK_IN="##edit-in##"
MARK_OUT="##edit-out##"
MARK_SEL_START="##+edit-in+##"
MARK_SEL_END="##-edit-in-##"

# Safety: refuse root
if [ "$(id -u)" -eq 0 ] || [ -n "${SUDO_USER:-}" ]; then
  echo "Refusing to run as root or via sudo."
  exit 1
fi

[ -d "$EDIT_ROOT" ] || { echo "Error: $EDIT_ROOT does not exist."; exit 1; }

# canonical root
EDIT_ROOT_REAL="$(realpath "$EDIT_ROOT")"

# 1) Find files that contain any IN marker and files that contain MARK_OUT (binary-safe, NUL-separated)
mapfile -d '' FILES_WITH_IN < <(grep -rF --binary-files=text -lZ -e "$MARK_IN" -e "$MARK_SEL_START" -e "$MARK_SEL_END" "$EDIT_ROOT_REAL" 2>/dev/null || true)
mapfile -d '' FILES_WITH_OUT < <(grep -rF --binary-files=text -lZ "$MARK_OUT" "$EDIT_ROOT_REAL" 2>/dev/null || true)

# Build union of files to consider (those with IN or OUT)
declare -A CANDIDATES=()
for f in "${FILES_WITH_IN[@]}"; do [ -n "$f" ] && CANDIDATES["$f"]=1; done
for f in "${FILES_WITH_OUT[@]}"; do [ -n "$f" ] && CANDIDATES["$f"]=1; done

# If no candidate files, remove everything under EDIT_ROOT (but keep EDIT_ROOT itself)
if [ "${#CANDIDATES[@]}" -eq 0 ]; then
  echo "No files contain $MARK_IN or $MARK_OUT or selection markers — removing all contents under $EDIT_ROOT_REAL"
  find "$EDIT_ROOT_REAL" -mindepth 1 -print0 | xargs -0 -r rm -rf --
  echo "Done."
  exit 0
fi

# Build a set to remember which files originally had both markers (any IN variant and OUT)
declare -A HAD_BOTH=()
for f in "${!CANDIDATES[@]}"; do
  if ( grep -qF -- "$MARK_OUT" "$f" 2>/dev/null ) && \
     ( grep -qF -- "$MARK_IN" "$f" 2>/dev/null || grep -qF -- "$MARK_SEL_START" "$f" 2>/dev/null || grep -qF -- "$MARK_SEL_END" "$f" 2>/dev/null ); then
    HAD_BOTH["$(realpath "$f")"]=1
  fi
done

# 2) Rewrite files that contained any IN marker (basic or selection)
REWRITTEN_FILES=()
for f in "${FILES_WITH_IN[@]}"; do
  [ -n "$f" ] || continue

  # --- Validation pass: ensure selection markers are balanced, ordered, non-nested,
  # and that no basic MARK_IN appears inside a selection.
  if grep -qF -- "$MARK_SEL_START" "$f" 2>/dev/null || grep -qF -- "$MARK_SEL_END" "$f" 2>/dev/null; then
    awk -v SSTART="$MARK_SEL_START" -v SEND="$MARK_SEL_END" -v IN="$MARK_IN" '
      BEGIN { in_sel = 0; startc = 0; endc = 0 }
      {
        line = $0
        if (index(line, SSTART)) {
          startc++
          if (in_sel) {
            print "ERROR: nested selection start on line " NR > "/dev/stderr"
            exit 2
          }
          in_sel = 1
        }
        if (index(line, SEND)) {
          endc++
          if (!in_sel) {
            print "ERROR: selection end before start on line " NR > "/dev/stderr"
            exit 3
          }
          in_sel = 0
        }
        if (in_sel && index(line, IN)) {
          print "ERROR: basic marker " IN " found inside selection on line " NR > "/dev/stderr"
          exit 4
        }
      }
      END {
        if (startc != endc) {
          print "ERROR: unmatched selection markers (start=" startc " end=" endc ")" > "/dev/stderr"
          exit 5
        }
      }
    ' "$f" || { echo "ERROR: validation failed for $f"; exit 1; }
  fi

  tmp="$(mktemp "${f}.tmp.XXXXXX")" || { echo "mktemp failed for $f"; continue; }

  # AWK rewrite:
  # - Remove selection markers literally (no regex interpretation).
  # - Preserve content between selection markers (selection content kept).
  # - Remove basic MARK_IN from its line and keep that line.
  # - All other lines become MARK_OUT.
  awk -v IN="$MARK_IN" -v SSTART="$MARK_SEL_START" -v SEND="$MARK_SEL_END" -v OUT="$MARK_OUT" '
    function remove_literal(hay, needle,    pos, before, after, nlen) {
      pos = index(hay, needle)
      if (pos == 0) return hay
      nlen = length(needle)
      before = (pos>1) ? substr(hay,1,pos-1) : ""
      after = substr(hay,pos + nlen)
      return before after
    }
    BEGIN { in_sel = 0 }
    {
      line = $0
      # If line contains selection start
      if (index(line, SSTART)) {
        # remove the literal marker
        line = remove_literal(line, SSTART)
        print line
        in_sel = 1
        next
      }
      # If line contains selection end
      if (index(line, SEND)) {
        line = remove_literal(line, SEND)
        print line
        in_sel = 0
        next
      }
      if (in_sel) {
        print line
      } else if (index(line, IN)) {
        # remove the basic marker literally
        line = remove_literal(line, IN)
        print line
      } else {
        print OUT
      }
    }
  ' "$f" > "$tmp" || { rm -f "$tmp"; echo "WRITE FAIL: $f"; continue; }

  if stat_out=$(stat -c "%a %u %g" "$f" 2>/dev/null); then
    perms=$(echo "$stat_out" | awk '{print $1}'); uid=$(echo "$stat_out" | awk '{print $2}'); gid=$(echo "$stat_out" | awk '{print $3}')
  else
    perms="644"; uid=""; gid=""
  fi

  mv "$tmp" "$f"
  chmod "$perms" "$f" 2>/dev/null || true
  if [ -n "$uid" ] && [ -n "$gid" ]; then chown "$uid:$gid" "$f" 2>/dev/null || true; fi

  echo "REWRITTEN: $f"
  REWRITTEN_FILES+=("$f")
done

# 3) Decide which rewritten files to keep
declare -A KEEP_FILE
declare -A KEEP_DIR

for f in "${REWRITTEN_FILES[@]}"; do
  [ -n "$f" ] || continue
  fr="$(realpath "$f")"

  if [ -n "${HAD_BOTH["$fr"]+x}" ]; then
    KEEP_FILE["$fr"]=1
    echo "KEPT (had both markers): $f"
    dir="$(dirname "$fr")"
    while true; do
      KEEP_DIR["$dir"]=1
      [ "$dir" = "$EDIT_ROOT_REAL" ] && break
      dir="$(dirname "$dir")"
    done
    continue
  fi

  if awk -v OUT="$MARK_OUT" '
      {
        s=$0
        sub(/^[ \t]+/, "", s)
        sub(/[ \t]+$/, "", s)
        if (s != OUT && s != "") { found=1; exit }
      }
      END { exit !found }
    ' "$f"; then
    KEEP_FILE["$fr"]=1
    echo "KEPT (has useful content): $f"
    dir="$(dirname "$fr")"
    while true; do
      KEEP_DIR["$dir"]=1
      [ "$dir" = "$EDIT_ROOT_REAL" ] && break
      dir="$(dirname "$dir")"
    done
  else
    rm -f "$f" && echo "DELETED (only MARK_OUT): $f" || echo "FAILED DELETE (only MARK_OUT): $f"
  fi
done

# 4) Keep files that originally had MARK_OUT but were not rewritten
for f in "${FILES_WITH_OUT[@]}"; do
  [ -n "$f" ] || continue
  fr="$(realpath "$f")"
  if [ -n "${KEEP_FILE["$fr"]+x}" ]; then
    continue
  fi
  if grep -qF -- "$MARK_OUT" "$f" 2>/dev/null; then
    KEEP_FILE["$fr"]=1
    echo "KEPT (originally had MARK_OUT): $f"
    dir="$(dirname "$fr")"
    while true; do
      KEEP_DIR["$dir"]=1
      [ "$dir" = "$EDIT_ROOT_REAL" ] && break
      dir="$(dirname "$dir")"
    done
  fi
done

# 4.5) Always keep ONLY the top-level README.txt (./edit/README.txt), not subfolders
if [ -f "$EDIT_ROOT_REAL/README.txt" ]; then
  rfile="$EDIT_ROOT_REAL/README.txt"
  rreal="$(realpath "$rfile")"
  KEEP_FILE["$rreal"]=1
  echo "KEPT (top-level README.txt): $rfile"
  KEEP_DIR["$EDIT_ROOT_REAL"]=1
fi

# 5) Delete all files under EDIT_ROOT that are NOT in KEEP_FILE
while IFS= read -r -d '' file; do
  file_real="$(realpath "$file")"
  if [ -z "${KEEP_FILE["$file_real"]+x}" ]; then
    rm -f "$file" && echo "DELETED FILE: $file" || echo "FAILED DELETE FILE: $file"
  else
    echo "KEPT FILE: $file"
  fi
done < <(find "$EDIT_ROOT_REAL" -type f -print0)

# 6) Remove directories bottom-up that are NOT in KEEP_DIR
mapfile -t DIRS < <(find "$EDIT_ROOT_REAL" -type d -print0 | awk 'BEGIN{RS="\0"}{print length($0) "\t" $0}' | sort -rn | cut -f2-)

for dir in "${DIRS[@]}"; do
  dir_real="$(realpath "$dir")"
  if [ "$dir_real" = "$EDIT_ROOT_REAL" ]; then
    continue
  fi
  if [ -n "${KEEP_DIR["$dir_real"]+x}" ]; then
    echo "KEPT DIR: $dir"
    continue
  fi
  rm -rf "$dir" && echo "REMOVED DIR: $dir" || echo "FAILED REMOVE DIR: $dir"
done

echo "Done! Files that contained $MARK_OUT are preserved."
