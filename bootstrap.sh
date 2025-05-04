#!/usr/bin/env bash
# bootstrap.sh – light wrapper that clones repo + launches archsetup
set -euo pipefail
IFS=$'\n\t'

REPO_URL="https://github.com/Conava/arch-bootstrap.git"
TARGET="$HOME/.arch-bootstrap"

info(){ echo -e "\e[1;34m[bootstrap]\e[0m $*"; }
die(){ echo -e "\e[1;31m[bootstrap ERROR]\e[0m $*" >&2; exit 1; }

# 1. ensure git is installed
if ! command -v git &>/dev/null; then
  info "git not found → installing via pacman"
  sudo pacman -Sy --needed --noconfirm git
fi

# 2. clone or update
info "Using target directory: $TARGET"
if [[ -d "$TARGET/.git" ]]; then
  info "Repo already present → pulling latest"
  git -C "$TARGET" pull --ff-only \
    || die "Failed to pull latest changes"
else
  info "Cloning $REPO_URL into $TARGET"
  git clone --depth=1 "$REPO_URL" "$TARGET" \
    || die "Failed to clone repo"
fi

# 3. make sure archsetup.sh is executable
chmod +x "$TARGET/archsetup.sh"

# 4. jump into repo and exec the setup script
cd "$TARGET"
info "Launching archsetup…"
exec bash ./archsetup.sh "$@"
