#!/bin/bash

# Refuse root/sudo
if [ "$EUID" -eq 0 ] || [ -n "$SUDO_USER" ]; then
    echo "Do not run this script as root or with sudo."
    exit 1
fi

# Script
cd ./local || exit 1

for item in *; do
    # Skip README.txt
    if [ "$item" = "README.txt" ]; then
        echo "Skipping $item"
        continue
    fi
    cp -r "$item" ../edit/
done

echo "Done!"
