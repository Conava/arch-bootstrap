#!/usr/bin/env bash
# bootstrap.sh – light wrapper that clones repo + launches archsetup
set -euo pipefail

REPO_URL="https://github.com/Conava/arch-bootstrap.git"
TARGET="$HOME/.arch-bootstrap"

echo "[bootstrap] cloning $REPO_URL ..."
if [[ -d $TARGET ]]; then
  echo "[bootstrap] repo already present – pulling latest"
  git -C "$TARGET" pull --ff-only
else
  git clone --depth=1 "$REPO_URL" "$TARGET"
fi

cd "$TARGET"
exec bash ./archsetup.sh "$@"
