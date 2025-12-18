#!/bin/bash

# Refuse root/sudo
if [ "$EUID" -eq 0 ] || [ -n "$SUDO_USER" ]; then
    echo "Do not run this script as root or with sudo."
    exit 1
fi

# Base directories
GIT_BASE="./git"
EDIT_BASE="./edit"

GIT_REPO="https://github.com/dw-0/kiauh.git"

# Script
cd $GIT_BASE
git clone $GIT_REPO
cd ..
cd $EDIT_BASE
git clone $GIT_REPO

echo "Done"
