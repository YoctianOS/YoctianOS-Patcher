#!/bin/bash

# Refuse root/sudo
if [ "$EUID" -eq 0 ] || [ -n "$SUDO_USER" ]; then
    echo "Do not run this script as root or with sudo."
    exit 1
fi

# Base directory
EDIT_BASE="./edit"

# Go to base directory
cd "$EDIT_BASE" || { echo "Directory $EDIT_BASE not found"; exit 1; }

# Include hidden files; if no match, nullglob prevents literal pattern
shopt -s dotglob nullglob

# Loop through entries in the directory
for src in *; do
    # Skip entries that already end with .backup
    if [[ "$src" == *.backup ]]; then
        continue
    fi

    # Skip README.txt (case-insensitive)
    if [[ "${src,,}" == "readme.txt" ]]; then
        echo "Skipping README: '$src'"
        continue
    fi

    dest="${src}.backup"

    # If destination already exists, skip copying
    if [ -e "$dest" ]; then
        echo "Skipping '$src' — backup already exists ('$dest')"
        continue
    fi

    # Copy preserving attributes; handle files and directories
    if cp -a -- "$src" "$dest"; then
        echo "Backed up '$src' -> '$dest'"
    else
        echo "Failed to back up '$src'"
    fi
done

echo "Done"
