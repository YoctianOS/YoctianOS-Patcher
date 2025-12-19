#!/bin/bash

# Refuse root/sudo
if [ "$EUID" -eq 0 ] || [ -n "$SUDO_USER" ]; then
    echo "Do not run this script as root or with sudo."
    exit 1
fi

# Base directory
EDIT_BASE="./edit"

# Change to base directory
cd "$EDIT_BASE" || { echo "Directory $EDIT_BASE not found."; exit 1; }

# Include hidden files and avoid literal patterns when empty
shopt -s dotglob nullglob

# Collect .backup entries
backups=( *.backup )

# If none found, exit
if [ ${#backups[@]} -eq 0 ]; then
    echo "No files or directories ending with .backup found."
    exit 0
fi

# Show what will be restored
echo "Items found for restore:"
for b in "${backups[@]}"; do
    printf '  %s -> %s\n' "$b" "${b%.backup}"
done

# Confirmation
read -r -p "Are you sure you want to restore ${#backups[@]} item(s)? [y/N] " answer
case "$answer" in
    [yY]|[yY][eE][sS]) ;;
    *) echo "Operation cancelled."; exit 0 ;;
esac

# Perform restore: skip if destination exists
for src in "${backups[@]}"; do
    dest="${src%.backup}"

    if [ -e "$dest" ]; then
        echo "Skipping '$src' — destination already exists ('$dest')."
        continue
    fi

    if mv -- "$src" "$dest"; then
        echo "Restored: '$src' -> '$dest'"
    else
        echo "Failed to restore '$src'"
    fi
done

echo "Done."
