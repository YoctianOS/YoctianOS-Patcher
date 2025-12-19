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

# Memory stored inside current directory
MEM_DIR="./.git_memory"
MEM_FILE="$MEM_DIR/repos.txt"

# Ensure directories exist
mkdir -p "$GIT_BASE" "$EDIT_BASE" "$MEM_DIR"
touch "$MEM_FILE"

# Helpers
sanitize() { printf '%s' "$1" | sed 's#[/:@]#_#g'; }

valid_git_url() {
  local url="$1"
  if [[ "$url" =~ ^https?:// ]] || [[ "$url" =~ ^git@ ]] || [[ "$url" =~ ^ssh:// ]]; then
    return 0
  fi
  return 1
}

list_repos() {
  if [ ! -s "$MEM_FILE" ]; then
    echo "(memory is empty)"
    return
  fi
  nl -w2 -s'. ' "$MEM_FILE"
}

add_repo() {
  read -r -p "Enter Git repo URL to add: " url
  url="${url## }"
  url="${url%% }"
  if [ -z "$url" ]; then
    echo "Empty input, aborting."
    return
  fi
  if ! valid_git_url "$url"; then
    read -r -p "URL doesn't look like a git URL. Add anyway? [y/N] " ans
    case "$ans" in [yY]|[yY][eE][sS]) ;; *) echo "Not added."; return ;; esac
  fi
  if grep -Fxq "$url" "$MEM_FILE"; then
    echo "Already in memory."
    return
  fi
  echo "$url" >> "$MEM_FILE"
  echo "Added."
}

remove_repo() {
  list_repos
  read -r -p "Enter line number to remove (or empty to cancel): " idx
  if [ -z "$idx" ]; then
    echo "Cancelled."
    return
  fi
  if ! [[ "$idx" =~ ^[0-9]+$ ]]; then
    echo "Invalid number."
    return
  fi
  if ! sed -n "${idx}p" "$MEM_FILE" >/dev/null 2>&1; then
    echo "No such line."
    return
  fi
  sed -i "${idx}d" "$MEM_FILE"
  echo "Removed."
}

clear_memory() {
  read -r -p "Are you sure you want to clear all saved repos? [y/N] " ans
  case "$ans" in [yY]|[yY][eE][sS]) > "$MEM_FILE"; echo "Memory cleared." ;; *) echo "Cancelled." ;; esac
}

clone_repo_to_dirs() {
  local url="$1"
  local name
  name=$(basename -s .git "$url")
  if [ -z "$name" ]; then
    name=$(sanitize "$url")
  fi

  # clone into GIT_BASE if not exists
  if [ -d "$GIT_BASE/$name/.git" ]; then
    echo "Skip: $GIT_BASE/$name already exists."
  else
    echo "Cloning into $GIT_BASE/$name ..."
    git -c advice.detachedHead=false clone -- "$url" "$GIT_BASE/$name" || { echo "Clone failed for $url"; }
  fi

  # clone into EDIT_BASE if not exists
  if [ -d "$EDIT_BASE/$name/.git" ]; then
    echo "Skip: $EDIT_BASE/$name already exists."
  else
    echo "Cloning into $EDIT_BASE/$name ..."
    git -c advice.detachedHead=false clone -- "$url" "$EDIT_BASE/$name" || { echo "Clone failed for $url"; }
  fi
}

clone_all() {
  if [ ! -s "$MEM_FILE" ]; then
    echo "Memory empty — nothing to clone."
    return
  fi
  while IFS= read -r url; do
    [ -z "$url" ] && continue
    echo
    echo "=== Processing: $url ==="
    clone_repo_to_dirs "$url"
  done < "$MEM_FILE"
  echo
  echo "All done."
}

clone_one_interactive() {
  list_repos
  read -r -p "Enter line number to clone (or empty to cancel): " idx
  if [ -z "$idx" ]; then
    echo "Cancelled."
    return
  fi
  if ! [[ "$idx" =~ ^[0-9]+$ ]]; then
    echo "Invalid number."
    return
  fi
  url=$(sed -n "${idx}p" "$MEM_FILE" || true)
  if [ -z "$url" ]; then
    echo "No such entry."
    return
  fi
  clone_repo_to_dirs "$url"
}

# Interactive menu
while true; do
  cat <<'MENU'

Git memory manager stored in ./.git_memory — choose an action:
  1) List saved repos
  2) Add a repo to memory
  3) Remove a repo from memory
  4) Clone one saved repo into ./git and ./edit
  5) Clone all saved repos
  6) Clear memory
  7) Exit

MENU
  read -r -p "Select [1-7]: " choice
  case "${choice:-}" in
    1) list_repos ;;
    2) add_repo ;;
    3) remove_repo ;;
    4) clone_one_interactive ;;
    5) clone_all ;;
    6) clear_memory ;;
    7) echo "Bye."; exit 0 ;;
    *) echo "Invalid choice." ;;
  esac
done

