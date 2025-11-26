#!/usr/bin/env bash
# Improved Pixarch installer with:
#  - --yes / -y     : non-interactive, accept all prompts
#  - --dry-run / -n : preview actions (no changes)
#  - -h / --help    : usage
#
# Note: script should NOT be run as root. Dry-run will allow root but normal runs will exit if run as root.

set -euo pipefail
IFS=$'\n\t'

# Defaults for flags
NONINTERACTIVE=false
DRY_RUN=false

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  -y, --yes        Non-interactive: accept all prompts
  -n, --dry-run    Dry run: print actions that would be taken (no changes)
  -h, --help       Show this help
EOF
}

# parse args
while [ $# -gt 0 ]; do
  case "$1" in
    -y|--yes)
      NONINTERACTIVE=true
      shift
      ;;
    -n|--dry-run)
      DRY_RUN=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --) shift; break ;;
    -*)
      echo "Unknown option: $1"
      usage
      exit 1
      ;;
    *) break ;;
  esac
done

# ---------- Configuration ----------
DOTDIR="$(realpath "$(dirname "${BASH_SOURCE[0]}")/..")"    # parent of installation_scripts
HOME_DIR="${HOME:-/home/$USER}"
AUR_DIR="${HOME_DIR}/code/aur"
TMPDIR="/tmp/pixarch-install-$$"
LOG_PREFIX="[pixarch-install]"

PACMAN_PKGS=(go vim htop firefox xorg-server xorg-xinit xorg-xrdb xorg-xprop \
  rofi exa pavucontrol tmux pamixer fzf xdg-user-dirs plank sddm lf \
  feh git openssh alacritty picom polybar dash xss-lock dialog dex)
# AUR_PKGS defined for reference; actual AUR installs are explicit below
AUR_PKGS=(ttf-monocraft searxng-git surf-git)

# ---------- Helpers ----------
cleanup() {
  rm -rf "$TMPDIR"
}
trap cleanup EXIT

log() { printf '%s %s\n' "$LOG_PREFIX" "$*"; }

command_exists() { command -v "$1" >/dev/null 2>&1; }

# Run a command, but if DRY_RUN is true just print what would run.
# Usage: run_cmd echo hello OR run_cmd sudo pacman -S ...
run_cmd() {
  if [ "$DRY_RUN" = true ]; then
    log "DRY-RUN: $*"
    return 0
  fi
  "$@"
}

# Ask yes/no. In non-interactive mode, auto-accept; in dry-run mode, do not accept (preview only).
ask_yes_no() {
  local prompt="$1"
  if [ "$NONINTERACTIVE" = true ]; then
    log "Non-interactive: auto-accepting: $prompt"
    return 0
  fi
  if [ "$DRY_RUN" = true ]; then
    log "DRY-RUN: would prompt: $prompt (treating as 'no' for preview)"
    return 1
  fi

  if command_exists dialog; then
    dialog --stdout --yesno "$prompt" 7 60 && return 0 || return 1
  else
    local ans
    read -r -p "$prompt [y/N]: " ans
    case "$ans" in [Yy]*) return 0 ;; *) return 1 ;; esac
  fi
}

backup_and_link() {
  local src="$1"
  local dest="$2"
  if [ -e "$dest" ] || [ -L "$dest" ]; then
    log "Backing up existing $dest -> ${dest}.bak"
    if [ "$DRY_RUN" = true ]; then
      log "DRY-RUN: mv -f \"$dest\" \"${dest}.bak\""
    else
      mv -f "$dest" "${dest}.bak"
    fi
  fi
  if [ "$DRY_RUN" = true ]; then
    log "DRY-RUN: ln -sfn \"$src\" \"$dest\""
  else
    ln -sfn "$src" "$dest"
  fi
  log "Linked $src -> $dest"
}

run_sudo_pacman() {
  local pkgs=("$@")
  log "Installing packages: ${pkgs[*]}"
  run_cmd sudo pacman -Syu --needed --noconfirm "${pkgs[@]}"
}

install_yay_if_missing() {
  if command_exists yay; then
    log "yay already installed"
    return
  fi
  log "Installing yay into $AUR_DIR/yay"
  if [ "$DRY_RUN" = true ]; then
    log "DRY-RUN: mkdir -p \"$AUR_DIR\" && git clone https://aur.archlinux.org/yay.git \"$AUR_DIR/yay\" && cd \"$AUR_DIR/yay\" && makepkg -si --noconfirm"
    return
  fi
  mkdir -p "$AUR_DIR"
  pushd "$AUR_DIR" >/dev/null
  if [ ! -d yay ]; then
    git clone https://aur.archlinux.org/yay.git yay
  fi
  cd yay
  # makepkg must be run as regular user
  makepkg -si --noconfirm
  popd >/dev/null
}

# ---------- Safety checks ----------
if [ "$DRY_RUN" != true ] && [ "$(id -u)" -eq 0 ]; then
  echo "This script should NOT be run as root. Run as your regular user; the script uses sudo for required root actions."
  exit 1
fi

if [ "$DRY_RUN" = true ]; then
  log "DRY-RUN: mkdir -p \"$TMPDIR\" \"$AUR_DIR\""
else
  mkdir -p "$TMPDIR" "$AUR_DIR"
fi

log "DOTDIR=$DOTDIR"
log "Home=$HOME_DIR"
log "NONINTERACTIVE=$NONINTERACTIVE DRY_RUN=$DRY_RUN"

# ---------- Main flow ----------
log "Starting package installation (pacman)"
run_sudo_pacman "${PACMAN_PKGS[@]}"

log "Ensuring xdg user dirs"
if command_exists xdg-user-dirs-update; then
  if [ "$DRY_RUN" = true ]; then
    log "DRY-RUN: xdg-user-dirs-update"
  else
    xdg-user-dirs-update
  fi
fi

# Install yay + some AUR fonts
log "Install yay and fonts from AUR"
install_yay_if_missing
if command_exists yay; then
  run_cmd yay -S --noconfirm --needed ttf-monocraft
  if [ "$DRY_RUN" = true ]; then
    log "DRY-RUN: fc-cache -fv"
  else
    fc-cache -fv
  fi
fi

# Optionally install i3
if ask_yes_no "Install i3 (i3-wm) and link i3 flavour from dotfiles?"; then
  run_cmd sudo pacman -S --noconfirm --needed i3-wm
  backup_and_link "$DOTDIR/flavours/i3" "${HOME_DIR}/.config/i3"
else
  log "Skipping i3"
fi

# Optionally install qtile
if ask_yes_no "Install qtile and link qtile flavour from dotfiles?"; then
  run_cmd sudo pacman -S --noconfirm --needed qtile
  backup_and_link "$DOTDIR/flavours/qtile" "${HOME_DIR}/.config/qtile"
else
  log "Skipping qtile"
fi

# Link common configs (backing up any existing)
log "Linking config files"
if [ "$DRY_RUN" = true ]; then
  log "DRY-RUN: mkdir -p \"${HOME_DIR}/.config\""
else
  mkdir -p "${HOME_DIR}/.config"
fi
backup_and_link "$DOTDIR/config/alacritty" "${HOME_DIR}/.config/alacritty"
backup_and_link "$DOTDIR/config/lf" "${HOME_DIR}/.config/lf"
backup_and_link "$DOTDIR/config/picom" "${HOME_DIR}/.config/picom"
backup_and_link "$DOTDIR/config/polybar" "${HOME_DIR}/.config/polybar"
backup_and_link "$DOTDIR/config/rofi" "${HOME_DIR}/.config/rofi"
backup_and_link "$DOTDIR/config/rofi-power-menu" "${HOME_DIR}/.config/rofi-power-menu"
backup_and_link "$DOTDIR/config/vim" "${HOME_DIR}/.config/vim"

# Optionally install themes (requires sudo)
if ask_yes_no "Copy GRUB theme and SDDM theme to system locations and update config? (requires sudo)"; then
  if [ -d "$DOTDIR/boot/grub/grubel" ]; then
    run_cmd sudo cp -r "$DOTDIR/boot/grub/grubel" /boot/grub/
    if [ "$DRY_RUN" = true ]; then
      log 'DRY-RUN: sudo sed -i '\''s|#GRUB_THEME=.*|GRUB_THEME="/boot/grub/grubel/theme.txt"|'\'' /etc/default/grub'
      log "DRY-RUN: sudo grub-mkconfig -o /boot/grub/grub.cfg"
    else
      sudo sed -i 's|#GRUB_THEME=.*|GRUB_THEME="/boot/grub/grubel/theme.txt"|' /etc/default/grub || true
      sudo grub-mkconfig -o /boot/grub/grub.cfg || log "grub-mkconfig failed"
    fi
  fi
  if [ -d "$DOTDIR/boot/sddm/themes/pixarch_sddm" ]; then
    run_cmd sudo cp -r "$DOTDIR/boot/sddm/themes/pixarch_sddm" /usr/share/sddm/themes/
    if [ -f "$DOTDIR/installation_scripts/theme.conf" ]; then
      run_cmd sudo cp "$DOTDIR/installation_scripts/theme.conf" /etc/sddm.conf
    fi
    if [ "$DRY_RUN" = true ]; then
      log "DRY-RUN: sudo systemctl enable --now sddm"
    else
      sudo systemctl enable --now sddm || log "Failed enabling sddm"
    fi
  fi
else
  log "Skipping theme installation"
fi

# Optionally install browsel (searxng + surf patched for local engine)
if ask_yes_no "Install searxng and surf (browsel) from AUR and apply local patches?"; then
  if ! command_exists yay; then
    log "yay not found; installing yay first"
    install_yay_if_missing
  fi
  pushd "$AUR_DIR" >/dev/null
  # searxng-git
  if [ -d searxng-git ]; then rm -rf searxng-git; fi
  run_cmd yay -G searxng-git
  if [ -d searxng-git ]; then
    pushd searxng-git >/dev/null
    if [ -f "$DOTDIR/applications/browsel/searxng.patch" ]; then
      if [ "$DRY_RUN" = true ]; then
        log "DRY-RUN: patch PKGBUILD with $DOTDIR/applications/browsel/searxng.patch"
      else
        patch -p0 < "$DOTDIR/applications/browsel/searxng.patch" || log "searxng patch failed"
      fi
    fi
    if [ "$DRY_RUN" = true ]; then
      log "DRY-RUN: makepkg -si"
    else
      makepkg -si --noconfirm || log "makepkg searxng failed"
    fi
    popd >/dev/null
  fi

  # surf-git
  if [ -d surf-git ]; then rm -rf surf-git; fi
  run_cmd yay -G surf-git
  if [ -d surf-git ]; then
    pushd surf-git >/dev/null
    if [ -f "$DOTDIR/applications/browsel/surf.patch" ]; then
      if [ "$DRY_RUN" = true ]; then
        log "DRY-RUN: patch PKGBUILD with $DOTDIR/applications/browsel/surf.patch"
      else
        patch -p0 < "$DOTDIR/applications/browsel/surf.patch" || log "surf patch failed"
      fi
    fi
    if [ "$DRY_RUN" = true ]; then
      log "DRY-RUN: makepkg -si"
    else
      makepkg -si --noconfirm || log "makepkg surf failed"
    fi
    popd >/dev/null
  fi
  popd >/dev/null
else
  log "Skipping browsel installation"
fi

# Optional security tools
if ask_yes_no "Install ClamAV and UFW via installation script?"; then
  if [ -f "$DOTDIR/installation_scripts/security.sh" ]; then
    if [ "$DRY_RUN" = true ]; then
      log "DRY-RUN: bash \"$DOTDIR/installation_scripts/security.sh\""
    else
      bash "$DOTDIR/installation_scripts/security.sh"
    fi
  else
    log "security.sh not found in $DOTDIR/installation_scripts"
  fi
else
  log "Skipping security tools"
fi

log "Installation complete. Review log and any .bak files in your home for previous configs."
