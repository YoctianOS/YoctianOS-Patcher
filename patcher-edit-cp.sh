#!/bin/bash

# Refuse root/sudo
if [ "$EUID" -eq 0 ] || [ -n "$SUDO_USER" ]; then
    echo "Do not run this script as root or with sudo."
    exit 1
fi

EDIT_BASE="./edit"
MARK_OUT="##edit-out##"

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  -h, --help       Show this help and exit.
  -f, --force      Force copy: replace existing *.backup targets with source (no nesting).
EOF
}

FORCE=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        -f|--force) FORCE=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1"; usage; exit 1 ;;
    esac
done

cd "$EDIT_BASE" || { echo "Directory $EDIT_BASE not found"; exit 1; }
shopt -s dotglob nullglob

has_mark_out() {
    local p="$1"
    if [ -f "$p" ]; then
        grep -qF -- "$MARK_OUT" "$p" 2>/dev/null
    elif [ -d "$p" ]; then
        grep -rF --binary-files=text -q -- "$MARK_OUT" "$p" 2>/dev/null
    else
        return 1
    fi
}

# Collect candidates
targets=()
for src in *; do
    [[ "$src" == *.backup ]] && continue
    [[ "${src,,}" == "readme.txt" ]] && continue
    targets+=("$src")
done

if [ ${#targets[@]} -eq 0 ]; then
    echo "No eligible files or directories found."
    exit 0
fi

echo "The following items will be processed:"
for t in "${targets[@]}"; do
    echo "  $t -> ${t}.backup"
done

# Confirmation prompt
read -r -p "Proceed with ${#targets[@]} item(s)? [y/N] " answer
case "$answer" in
    [yY]|[yY][eE][sS]) ;;
    *) echo "Operation cancelled."; exit 0 ;;
esac

# Process each target
for src in "${targets[@]}"; do
    dest="${src}.backup"

    if $FORCE; then
        if [ -e "$dest" ]; then
            if ! rm -rf -- "$dest"; then
                echo "Failed to remove existing backup '$dest'"; continue
            fi
        fi
        if cp -a -- "$src" "$dest"; then
            echo "Forced copy '$src' -> '$dest'"
        else
            echo "Failed to force copy '$src'"
        fi
        continue
    fi

    if [ -e "$dest" ]; then
        echo "Skipping '$src' — backup already exists ('$dest')"
        continue
    fi

    if has_mark_out "$src"; then
        if mv -- "$src" "$dest"; then
            echo "Moved '$src' -> '$dest'"
        else
            echo "Failed to move '$src'"
        fi
    else
        echo "Refused '$src' — no $MARK_OUT found"
    fi
done

echo "Done"
