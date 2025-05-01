#!/usr/bin/env bash
# archsetup.sh – reproducible Arch / Chaotic-AUR / Flatpak deployer
# Author: Conava (Marlon Kranz)  • License: MIT
set -euo pipefail
IFS=$'\n\t'

## ---------- CONFIG ---------------------------------------------------------
CFG_DIR="$(dirname "$0")/config"
PACMAN_LIST="$CFG_DIR/pacman.txt"
AUR_LIST="$CFG_DIR/aur.txt"
FLATPAK_LIST="$CFG_DIR/flatpak.txt"
THEME_JSON="$CFG_DIR/themes.json"
DOTFILES_URL="$(< "$(dirname "$0")/dotfiles_repo.txt")"

AUR_HELPER=${AUR_HELPER:-paru}   # or yay
MENU=${MENU:-false}              # MENU=true → fzf/whiptail UI
## ---------------------------------------------------------------------------

die(){ echo "Error: $*" >&2; exit 1; }
info(){ echo -e "\e[1;34m[INFO]\e[0m $*"; }
need_root(){ (( EUID )) && die "re-run with sudo/root for this step."; }

# ---------- repo setup ------------------------------------------------------
setup_aur_helper() {
  info "Installing AUR helper: $AUR_HELPER"

  # skip if already present
  if command -v "$AUR_HELPER" &>/dev/null; then
    info "$AUR_HELPER already installed – skipping"
    return
  fi

  # 1. prerequisites
  sudo pacman -Sy --needed --noconfirm git base-devel

  # 2. build and install the *-bin package from AUR
  tmp=$(mktemp -d)
  git clone --depth=1 "https://aur.archlinux.org/${AUR_HELPER}-bin.git" \
            "$tmp/${AUR_HELPER}-bin"

  (
    cd "$tmp/${AUR_HELPER}-bin"
    # makepkg will prompt sudo internally when it reaches the install step
    makepkg -si --noconfirm
  )

  # 3. clean up
  rm -rf "$tmp"
}



enable_chaotic_aur() {
  info "Adding Chaotic-AUR repo"
  local KEY="3056513887B78AEB"
  sudo pacman-key --recv-key "$KEY" --keyserver keyserver.ubuntu.com
  sudo pacman-key --lsign-key "$KEY"
  sudo pacman -U --noconfirm \
       'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-keyring.pkg.tar.zst' \
       'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-mirrorlist.pkg.tar.zst'
  grep -q '^\[chaotic-aur\]' /etc/pacman.conf ||
    echo -e '\n[chaotic-aur]\nInclude = /etc/pacman.d/chaotic-mirrorlist' |
    sudo tee -a /etc/pacman.conf >/dev/null
}

enable_flatpak() {
  info "Installing Flatpak + Flathub"
  sudo pacman -Syu --needed --noconfirm flatpak
  flatpak remote-add --if-not-exists flathub \
    https://flathub.org/repo/flathub.flatpakrepo
}

# ---------- package install -------------------------------------------------
install_packages() {
  info "Installing pacman packages..."
  [[ -f $PACMAN_LIST ]] &&
    sudo pacman -Syu --needed --noconfirm $(grep -Ev '^\s*#' "$PACMAN_LIST")

  info "Installing AUR packages with $AUR_HELPER..."
  [[ -f $AUR_LIST ]] &&
    "$AUR_HELPER" -S --needed --noconfirm $(grep -Ev '^\s*#' "$AUR_LIST")

  info "Installing Flatpak apps..."
  [[ -f $FLATPAK_LIST ]] &&
    xargs -r -a "$FLATPAK_LIST" flatpak install -y flathub
}

# ---------- theme install ---------------------------------------------------
install_themes() {
  info "Cloning & copying themes..."
  jq -r '.themes[]|@base64' "$THEME_JSON" | while read -r row; do
    _jq(){ echo "$row" | base64 -d | jq -r "$1"; }
    name=$(_jq '.name'); dest=$(_jq '.dest'); git_url=$(_jq '.git')
    subdir=$(_jq '.subdir // "."')
    info "→ $name"
    tmp="/tmp/theme-$name"
    rm -rf "$tmp"
    git clone --depth=1 "$git_url" "$tmp"
    sudo mkdir -p "$dest"
    sudo cp -r "$tmp/$subdir"/* "$dest/"
  done
}

# ---------- dotfiles --------------------------------------------------------
apply_dotfiles() {
  info "Applying dotfiles via chezmoi"
  command -v chezmoi &>/dev/null || sudo pacman -S --needed --noconfirm chezmoi
  chezmoi init --apply "$DOTFILES_URL"
}

# ---------- services --------------------------------------------------------
enable_services() {
  info "Enabling OneDrive (user service)"
  command -v onedrive &>/dev/null || "$AUR_HELPER" -S --needed --noconfirm onedrive-abraunegg
  systemctl --user enable --now onedrive
}

# ---------- update lists ----------------------------------------------------
update_package_lists() {
  info "Saving explicit package lists..."
  pacman -Qqen | sort >  "$PACMAN_LIST"     # native, explicit
  pacman -Qqem | sort >  "$AUR_LIST"        # foreign, explicit
  flatpak list --app --columns=application | sort > "$FLATPAK_LIST"
  git add "$PACMAN_LIST" "$AUR_LIST" "$FLATPAK_LIST"
  git commit -m "update: explicit package lists $(date +%F)" && git push
  info "Lists pushed to repo."
}

# ---------- CLI -------------------------------------------------------------
usage(){
cat <<EOF
Usage: $0 [flags]
  --all            Run every step
  --repos          Setup AUR helper, Chaotic-AUR, Flatpak
  --packages       Install packages (pacman/AUR/Flatpak)
  --themes         Sync themes
  --dotfiles       Apply dotfiles
  --services       Enable background services
  --update-lists   Refresh package-list files & push
  --menu           Interactive menu (fzf or dialog)
  -h,--help        Show this help
EOF
}

run_menu(){
  local choice
  if command -v fzf >/dev/null; then
    choice=$(printf "All\nRepos\nPackages\nThemes\nDotfiles\nServices\nUpdate-lists\nQuit" | fzf)
  else
    whiptail --menu "Select action" 20 70 8 \
      a "All" r "Repos" p "Packages" t "Themes" d "Dotfiles" s "Services" u "Update-lists" q Quit 2> /tmp/choice || return
    choice=$(< /tmp/choice); rm -f /tmp/choice
  fi
  [[ $choice == Quit || -z $choice ]] && return
  main --${choice,,}         # lowercase flag
}

main(){
  local DO_ALL=false
  while [[ $# -gt 0 ]]; do
    case $1 in
      --all)          DO_ALL=true ;;
      --repos)        setup_aur_helper; enable_chaotic_aur; enable_flatpak ;;
      --packages)     install_packages ;;
      --themes)       install_themes ;;
      --dotfiles)     apply_dotfiles ;;
      --services)     enable_services ;;
      --update-lists) update_package_lists ;;
      --menu)         run_menu; return ;;
      -h|--help)      usage; return ;;
      *)              die "Unknown flag $1" ;;
    esac
    shift
  done

  if $DO_ALL; then
    setup_aur_helper
    enable_chaotic_aur
    enable_flatpak
    install_packages
    install_themes
    apply_dotfiles
    enable_services
  fi
}

[[ $# -eq 0 && $MENU == true ]] && run_menu || main "$@"
