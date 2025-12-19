#!/bin/bash

# Refuse root/sudo
if [ "$EUID" -eq 0 ] || [ -n "$SUDO_USER" ]; then
    echo "Do not run this script as root or with sudo."
    exit 1
fi

EDIT_BASE="./edit"

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  -h, --help       Show this help and exit.
  -f, --force      Force restore: overwrite existing destinations with backup (no merging).
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

cd "$EDIT_BASE" || { echo "Directory $EDIT_BASE not found."; exit 1; }
shopt -s dotglob nullglob

backups=( *.backup )
if [ ${#backups[@]} -eq 0 ]; then
    echo "No files or directories ending with .backup found."
    exit 0
fi

echo "Items found for restore:"
for b in "${backups[@]}"; do
    printf '  %s -> %s\n' "$b" "${b%.backup}"
done

read -r -p "Are you sure you want to restore ${#backups[@]} item(s)? [y/N] " answer
case "$answer" in
    [yY]|[yY][eE][sS]) ;;
    *) echo "Operation cancelled."; exit 0 ;;
esac

for src in "${backups[@]}"; do
    dest="${src%.backup}"

    if [ -e "$dest" ]; then
        if $FORCE; then
            # Remove destination entirely, then copy backup back
            if rm -rf -- "$dest"; then
                if cp -a -- "$src" "$dest"; then
                    echo "Forced restore: replaced '$dest' with '$src'"
                else
                    echo "Failed to force restore '$src'"
                fi
            else
                echo "Failed to remove existing destination '$dest'; skipping '$src'."
            fi
        else
            echo "Skipping '$src' — destination already exists ('$dest')."
        fi
    else
        # Normal restore: rename/move backup back to original
        if mv -- "$src" "$dest"; then
            echo "Restored: '$src' -> '$dest'"
        else
            echo "Failed to restore '$src'"
        fi
    fi
done

echo "Done."
