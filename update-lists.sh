#!/usr/bin/env bash
# update-lists.sh — snapshot *explicit* packages only
# Usage: ./update-lists.sh [--push]

set -euo pipefail
IFS=$'\n\t'

CFG_DIR="$(dirname "$0")/config"
PACMAN_LIST="$CFG_DIR/pacman.txt"   # repo / Chaotic packages
AUR_LIST="$CFG_DIR/aur.txt"         # AUR / foreign packages
FLATPAK_LIST="$CFG_DIR/flatpak.txt" # Flatpak apps (runtimes excluded)

mkdir -p "$CFG_DIR"

echo "[pacman] exporting explicit native packages → $PACMAN_LIST"
pacman -Qqen | sort > "$PACMAN_LIST"
      # -Q   query
      # -q   quiet (names only)
      # -e   explicitly installed (not pulled as dep)
      # -n   native (official or Chaotic repo)

echo "[aur]    exporting explicit foreign packages → $AUR_LIST"
pacman -Qqem | sort > "$AUR_LIST"
      # -m   foreign (built from PKGBUILD / AUR)

echo "[flatpak] exporting installed applications → $FLATPAK_LIST"
flatpak list --app --columns=application | sort > "$FLATPAK_LIST"
      # --app  skips runtimes and extensions

printf "  %-20s %d\n" "pacman packages:"  "$(wc -l < "$PACMAN_LIST")"
printf "  %-20s %d\n" "AUR packages:"     "$(wc -l < "$AUR_LIST")"
printf "  %-20s %d\n" "Flatpak apps:"     "$(wc -l < "$FLATPAK_LIST")"

if [[ ${1:-} == "--push" ]]; then
  git add "$PACMAN_LIST" "$AUR_LIST" "$FLATPAK_LIST"
  git commit -m "update: explicit package lists $(date +%F)"
  git push
  echo "[git] lists committed & pushed."
fi
