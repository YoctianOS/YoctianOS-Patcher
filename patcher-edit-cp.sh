#!/bin/bash

# Refuse root/sudo
if [ "$EUID" -eq 0 ] || [ -n "$SUDO_USER" ]; then
    echo "Do not run this script as root or with sudo."
    exit 1
fi

# Base directory
EDIT_BASE="./edit"
MARK_OUT="##edit-out##"

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

    # If destination already exists, skip moving
    if [ -e "$dest" ]; then
        echo "Skipping '$src' — backup already exists ('$dest')"
        continue
    fi

    if [ -f "$src" ]; then
        # Check if file contains at least one MARK_OUT
        if grep -qF "$MARK_OUT" "$src"; then
            if mv -- "$src" "$dest"; then
                echo "Moved '$src' -> '$dest'"
            else
                echo "Failed to move '$src'"
            fi
        else
            echo "Refused '$src' — no $MARK_OUT found"
        fi
    else
        # For directories, just move
        if mv -- "$src" "$dest"; then
            echo "Moved directory '$src' -> '$dest'"
        else
            echo "Failed to move directory '$src'"
        fi
    fi
done

echo "Done"
