#!/usr/bin/env bash
# archsetup.sh  –  reproducible Arch / Chaotic-AUR / Flatpak deployer
# Author: Conava (Marlon Kranz; dev@marlonkranz.com)  License: MIT
set -euo pipefail
IFS=$'\n\t'

## ---------- CONFIG ---------------------------------------------------------
CFG_DIR="$(dirname "$0")/config"
PACMAN_LIST="$CFG_DIR/pacman.txt"
AUR_LIST="$CFG_DIR/aur.txt"
FLATPAK_LIST="$CFG_DIR/flatpak.txt"
THEME_JSON="$CFG_DIR/themes.json"
DOTFILES_URL="$(< "$(dirname "$0")/dotfiles_repo.txt")"

AUR_HELPER=${AUR_HELPER:-paru}   # default helper (yay supported too)
MENU=${MENU:-false}              # set MENU=true for interactive fzf/dialog
## ---------------------------------------------------------------------------

# ---------- helpers ---------------------------------------------------------
die(){ echo "Error: $*" >&2; exit 1; }
info(){ echo -e "\\e[1;34m[INFO]\\e[0m $*"; }
run(){ echo -e "\\e[1;32m[CMD ]\\e[0m $*"; "$@"; }
need_root(){ (( EUID )) && die "re-run with sudo/root for this step."; }

# ---------- repo setup ------------------------------------------------------
setup_aur_helper() {
  info "Installing chosen AUR helper: $AUR_HELPER"
  if ! command -v "$AUR_HELPER" &>/dev/null ; then
    need_root
    pacman -Sy --needed --noconfirm git base-devel
    tmp=$(mktemp -d)
    git -C "$tmp" clone --depth=1 "https://aur.archlinux.org/${AUR_HELPER}-bin.git"
    run bash -c "cd $tmp/${AUR_HELPER}-bin && makepkg -si --noconfirm"
    rm -rf "$tmp"
  fi
}

enable_chaotic_aur() {
  info "Enabling Chaotic-AUR repository"
  local KEY="3056513887B78AEB"   # upstream master key  :contentReference[oaicite:0]{index=0}
  sudo pacman-key --recv-key "$KEY" --keyserver keyserver.ubuntu.com
  sudo pacman-key --lsign-key "$KEY"
  sudo pacman -U --noconfirm \
    'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-keyring.pkg.tar.zst' \
    'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-mirrorlist.pkg.tar.zst'   :contentReference[oaicite:1]{index=1}
  if ! grep -q '^\[chaotic-aur\]' /etc/pacman.conf; then
    echo -e '\n[chaotic-aur]\nInclude = /etc/pacman.d/chaotic-mirrorlist' | \
      sudo tee -a /etc/pacman.conf
  fi
}

enable_flatpak() {
  info "Installing Flatpak + Flathub"
  sudo pacman -Syu --needed --noconfirm flatpak
  flatpak remote-add --if-not-exists flathub \
    https://flathub.org/repo/flathub.flatpakrepo   :contentReference[oaicite:2]{index=2}
}

# ---------- package install -------------------------------------------------
install_packages() {
  info "Installing pacman packages..."
  [[ -f $PACMAN_LIST ]] && sudo pacman -Syu --needed --noconfirm $(grep -Ev '^\s*#' "$PACMAN_LIST")

  info "Installing AUR packages with $AUR_HELPER..."
  [[ -f $AUR_LIST ]] && "$AUR_HELPER" -S --needed --noconfirm $(grep -Ev '^\s*#' "$AUR_LIST")

  info "Installing Flatpak packages..."
  while read -r app; do
      [[ -z $app || $app == \#* ]] && continue
      flatpak install -y flathub "$app"
  done < "$FLATPAK_LIST"
}

# ---------- theme install ---------------------------------------------------
install_themes() {
  info "Installing third-party themes..."
  jq -r '.themes[]|@base64' "$THEME_JSON" | while read -r row; do
    _jq(){ echo "$row" | base64 -d | jq -r "$1"; }
    name=$(_jq '.name'); category=$(_jq '.category')
    git_url=$(_jq '.git'); dest=$(_jq '.dest')
    info "→ $name ($category)"
    [[ -d /tmp/theme-$name ]] && rm -rf /tmp/theme-$name
    git clone --depth=1 "$git_url" "/tmp/theme-$name"
    sudo mkdir -p "$dest"
    sudo cp -r "/tmp/theme-$name/$(_jq '.subdir // "."')"/* "$dest/"
  done
}

# ---------- dotfiles --------------------------------------------------------
apply_dotfiles() {
  info "Applying dotfiles with chezmoi"
  if ! command -v chezmoi &>/dev/null ; then
    sudo pacman -S --needed --noconfirm chezmoi
  fi
  chezmoi init --apply "$DOTFILES_URL"   :contentReference[oaicite:3]{index=3}
}

# ---------- services --------------------------------------------------------
enable_services() {
  info "Enabling OneDrive (user service)"
  if ! command -v onedrive &>/dev/null ; then
    "$AUR_HELPER" -S --needed --noconfirm onedrive-abraunegg
  fi
  systemctl --user enable --now onedrive   :contentReference[oaicite:4]{index=4}
}

# ---------- update lists ----------------------------------------------------
update_package_lists() {
  info "Updating package list files..."
  pacman -Qqe > "$PACMAN_LIST"
  pacman -Qqm > "$AUR_LIST"
  flatpak list --app --columns=application | tail -n +1 > "$FLATPAK_LIST"  # skip header
  git add "$PACMAN_LIST" "$AUR_LIST" "$FLATPAK_LIST"
  git commit -m "Update package lists ($(date +%F))" && git push
  info "Package lists pushed."
}

# ---------- CLI -------------------------------------------------------------
usage(){
cat <<EOF
Usage: $0 [flags]

Flags:
  --all           Run every step (repos, packages, themes, dotfiles, services)
  --repos         Only set up paru/yay, Chaotic-AUR, Flatpak
  --packages      Only install packages
  --themes        Only install themes
  --dotfiles      Only apply dotfiles
  --services      Only enable services
  --update-lists  Refresh package list files & push
  --menu          Launch interactive menu (requires fzf or dialog)
  -h|--help       Show this help
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
  case $choice in
    All) main --all ;;
    Repos) main --repos ;;
    Packages) main --packages ;;
    Themes) main --themes ;;
    Dotfiles) main --dotfiles ;;
    Services) main --services ;;
    Update-lists) main --update-lists ;;
    *) exit 0 ;;
  esac
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
  # Comment out any step you dont need
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
