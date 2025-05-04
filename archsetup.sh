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
DOTFILES_URL="$CFG_DIR/dotfiles_repo.txt"

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
  local PKG_FILE="$CFG_DIR/packages.txt"
  info "Installing all packages via $AUR_HELPER from $PKG_FILE…"

  # 1. Pacman/AUR section
  if [[ -f $PKG_FILE ]]; then
    mapfile -t pkgs < <(grep -Ev '^\s*(#|$)' "$PKG_FILE")
    if ((${#pkgs[@]})); then
      info "→ ${#pkgs[@]} total PKGBUILD targets"
      echo "    ${pkgs[*]}"

      info "↻ Syncing pacman DB…"
      sudo pacman -Sy || die "Failed to sync pacman DB"

      info "↪ Installing via $AUR_HELPER (pacman + AUR)…"
      if ! "$AUR_HELPER" -S --needed --noconfirm "${pkgs[@]}"; then
        die "One or more pacman/AUR installs failed—check output above"
      fi
      info "✅ Pacman & AUR installs done"
    else
      info "packages.txt is empty → skipping pacman/AUR step"
    fi
  else
    info "No packages.txt at $PKG_FILE → skipping pacman/AUR"
  fi

  # 2. Flatpak section
  info "Installing Flatpak apps…"
  if [[ -f $FLATPAK_LIST ]]; then
    mapfile -t flatpaks < <(grep -Ev '^\s*(#|$)' "$FLATPAK_LIST")
    if ((${#flatpaks[@]})); then
      info "→ ${#flatpaks[@]} apps to flatpak-install"
      echo "    ${flatpaks[*]}"

      # ensure flathub remote exists
      flatpak remote-info flathub &>/dev/null \
        || die "Flathub remote not found—run enable_flatpak first"

      if ! flatpak install -y --noninteractive flathub "${flatpaks[@]}"; then
        info "⚠️ Some Flatpak apps failed or were skipped"
      else
        info "✅ Flatpak installs done"
      fi
    else
      info "No entries in flatpak.txt → skipping Flatpak step"
    fi
  else
    info "No flatpak.txt at $FLATPAK_LIST → skipping Flatpak"
  fi

  return 0
}


# ---------- theme install ---------------------------------------------------
install_themes() {
for cmd in git jq; do
  if ! command -v "$cmd" &>/dev/null; then
    info "$cmd not found → installing via pacman"
    sudo pacman -Sy --needed --noconfirm "$cmd" \
      || die "Failed to install $cmd"
  fi
done
  info "Cloning themes into ~/.themes/<category>/…"

  THEMES_DIR="$HOME/.themes"
  jq -c '.themes[]' "$THEME_JSON" | while read -r entry; do
    git_url=$(jq -r '.git' <<<"$entry")
    category=$(jq -r '.category' <<<"$entry")
    # derive a folder name from the repo URL
    name=$(basename "$git_url" .git)
    dest="$THEMES_DIR/$category/$name"

    info "→ [$category] $name"
    (
      set -e
      mkdir -p "$(dirname "$dest")"
      # skip if already cloned
      if [[ -d $dest/.git ]]; then
        info "   • Already exists, pulling updates…"
        git -C "$dest" pull --ff-only
      else
        git clone --depth=1 "$git_url" "$dest"
      fi
    ) || {
      info "⚠️  Failed to clone '$name', skipping."
    }
    info "Themes cloned, please manually install from ~./themes"
  done
}

# ---------- zsh plugins --------------------------------------------------------
install_zsh_plugins() {
  info "Installing Oh-My-Zsh plugins…"
  # default $ZSH_CUSTOM or fallback
  local ZSH_CUSTOM="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"
  local plugins=(
    zsh-users/zsh-autosuggestions
    zsh-users/zsh-syntax-highlighting
  )

  sudo pacman -S --needed --noconfirm fzf  # ensure fzf is present

  mkdir -p "$ZSH_CUSTOM/plugins"
  for repo in "${plugins[@]}"; do
    local name=${repo##*/}           # e.g. "zsh-autosuggestions"
    local dest="$ZSH_CUSTOM/plugins/$name"

    if [[ -d $dest/.git ]]; then
      info "→ $name already installed, pulling updates…"
      git -C "$dest" pull --ff-only
    else
      info "→ Cloning $name…"
      git clone --depth=1 "https://github.com/$repo.git" "$dest"
    fi
  done

  info "Oh-My-Zsh plugins done ✔️"
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

  info "Enabling system services, path units & timers…"
  # List all units you want enabled/started
  local units=(
    grub-btrfs-snapper.path
    sddm.service
    NetworkManager.service
    snapper-boot.timer
    snapper-cleanup.timer
    snapper-timeline.timer
  )

  # Enable & start them atomically
  sudo systemctl enable --now "${units[@]}"

  info "All listed services/timers have been enabled."
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
      --zsh-plugins)  install_zsh_plugins ;;
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
    install_zsh_plugins
    enable_services
  fi
}

[[ $# -eq 0 && $MENU == true ]] && run_menu || main "$@"
