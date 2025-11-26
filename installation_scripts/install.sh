#!/usr/bin/env bash
# Enhanced Pixarch installer with comprehensive logging and CLI options
#
# Features:
#  - --yes / -y           : non-interactive, accept all prompts
#  - --dry-run / -n       : preview actions (no changes)
#  - --verbose / -v       : verbose output (shows all commands)
#  - --quiet / -q         : minimal output (errors only)
#  - --log-file <path>    : write logs to file (default: /tmp/pixarch-install.log)
#  - --no-backup          : skip backing up existing configs
#  - --skip-i3            : skip i3 installation
#  - --skip-qtile         : skip qtile installation
#  - --skip-themes        : skip GRUB/SDDM theme installation
#  - --skip-browsel       : skip browsel (searxng/surf) installation
#  - --skip-security      : skip security tools installation
#  - --skip-aur           : skip all AUR packages
#  - -h, --help           : show this help
#
# Note: script should NOT be run as root. Dry-run will allow root but normal runs will exit if run as root.

set -euo pipefail
IFS=$'\n\t'

# ---------- Defaults for flags ----------
NONINTERACTIVE=false
DRY_RUN=false
VERBOSE=false
QUIET=false
LOG_FILE="/tmp/pixarch-install-$(date +%Y%m%d-%H%M%S).log"
NO_BACKUP=false
SKIP_I3=false
SKIP_QTILE=false
SKIP_THEMES=false
SKIP_BROWSEL=false
SKIP_SECURITY=false
SKIP_AUR=false

# Log levels
declare -A LOG_LEVELS=([ERROR]=0 [WARN]=1 [INFO]=2 [DEBUG]=3)
CURRENT_LOG_LEVEL=2  # INFO by default

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  -y, --yes              Non-interactive: accept all prompts
  -n, --dry-run          Dry run: print actions that would be taken (no changes)
  -v, --verbose          Verbose output (shows all commands)
  -q, --quiet            Minimal output (errors only)
  --log-file <path>      Write logs to file (default: /tmp/pixarch-install-TIMESTAMP.log)
  --no-backup            Skip backing up existing configs
  --skip-i3              Skip i3 installation
  --skip-qtile           Skip qtile installation
  --skip-themes          Skip GRUB/SDDM theme installation
  --skip-browsel         Skip browsel (searxng/surf) installation
  --skip-security        Skip security tools installation
  --skip-aur             Skip all AUR packages
  -h, --help             Show this help

Examples:
  $(basename "$0") --yes --verbose                    # Non-interactive with verbose output
  $(basename "$0") --dry-run --log-file install.log   # Preview with custom log file
  $(basename "$0") --skip-themes --skip-browsel       # Skip specific components

Log files are automatically created in /tmp unless specified otherwise.
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
    -v|--verbose)
      VERBOSE=true
      CURRENT_LOG_LEVEL=3
      shift
      ;;
    -q|--quiet)
      QUIET=true
      CURRENT_LOG_LEVEL=0
      shift
      ;;
    --log-file)
      LOG_FILE="$2"
      shift 2
      ;;
    --no-backup)
      NO_BACKUP=true
      shift
      ;;
    --skip-i3)
      SKIP_I3=true
      shift
      ;;
    --skip-qtile)
      SKIP_QTILE=true
      shift
      ;;
    --skip-themes)
      SKIP_THEMES=true
      shift
      ;;
    --skip-browsel)
      SKIP_BROWSEL=true
      shift
      ;;
    --skip-security)
      SKIP_SECURITY=true
      shift
      ;;
    --skip-aur)
      SKIP_AUR=true
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

# Statistics tracking
TOTAL_STEPS=0
CURRENT_STEP=0
PACKAGES_INSTALLED=0
PACKAGES_SKIPPED=0
CONFIGS_LINKED=0
ERRORS_ENCOUNTERED=0

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

# Enhanced logging with levels and timestamps
log() {
  local level="${1:-INFO}"
  shift
  local message="$*"
  local timestamp
  timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
  
  # Check if we should print this log level
  local level_val="${LOG_LEVELS[$level]:-2}"
  if [ "$level_val" -gt "$CURRENT_LOG_LEVEL" ]; then
    return 0
  fi
  
  # Format with color for terminal
  local color_code=""
  local reset="\033[0m"
  case "$level" in
    ERROR)   color_code="\033[0;31m" ;;  # Red
    WARN)    color_code="\033[0;33m" ;;  # Yellow
    INFO)    color_code="\033[0;32m" ;;  # Green
    DEBUG)   color_code="\033[0;36m" ;;  # Cyan
  esac
  
  local formatted_msg="[${timestamp}] [${level}] ${message}"
  
  # Print to terminal if not quiet
  if [ "$QUIET" != true ] || [ "$level" = "ERROR" ]; then
    echo -e "${color_code}${formatted_msg}${reset}"
  fi
  
  # Always write to log file
  echo "$formatted_msg" >> "$LOG_FILE"
}

log_info() { log INFO "$@"; }
log_warn() { log WARN "$@"; }
log_error() { log ERROR "$@"; ((ERRORS_ENCOUNTERED++)); }
log_debug() { log DEBUG "$@"; }

step_start() {
  ((CURRENT_STEP++))
  log_info "Step $CURRENT_STEP/$TOTAL_STEPS: $*"
}

command_exists() { command -v "$1" >/dev/null 2>&1; }

# Run a command, but if DRY_RUN is true just print what would run.
# Usage: run_cmd echo hello OR run_cmd sudo pacman -S ...
run_cmd() {
  if [ "$VERBOSE" = true ]; then
    log_debug "Executing: $*"
  fi
  
  if [ "$DRY_RUN" = true ]; then
    log_info "DRY-RUN: $*"
    return 0
  fi
  
  # Execute and capture both stdout and stderr
  local output
  local exit_code
  if output=$("$@" 2>&1); then
    exit_code=0
    if [ "$VERBOSE" = true ] && [ -n "$output" ]; then
      log_debug "Output: $output"
    fi
  else
    exit_code=$?
    log_error "Command failed (exit $exit_code): $*"
    if [ -n "$output" ]; then
      log_error "Error output: $output"
    fi
    return $exit_code
  fi
  return 0
}

# Ask yes/no. In non-interactive mode, auto-accept; in dry-run mode, do not accept (preview only).
ask_yes_no() {
  local prompt="$1"
  if [ "$NONINTERACTIVE" = true ]; then
    log_info "Non-interactive: auto-accepting: $prompt"
    return 0
  fi
  if [ "$DRY_RUN" = true ]; then
    log_info "DRY-RUN: would prompt: $prompt (treating as 'no' for preview)"
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
  
  # Check if source exists
  if [ ! -e "$src" ]; then
    log_warn "Source does not exist: $src (skipping link)"
    return 1
  fi
  
  # If destination exists and is the same, skip
  if [ -L "$dest" ] && [ "$(readlink -f "$dest")" = "$(readlink -f "$src")" ]; then
    log_info "Already linked: $dest -> $src"
    ((CONFIGS_LINKED++))
    return 0
  fi
  
  # Backup if needed
  if [ "$NO_BACKUP" != true ] && { [ -e "$dest" ] || [ -L "$dest" ]; }; then
    local backup="${dest}.bak.$(date +%Y%m%d-%H%M%S)"
    log_info "Backing up existing $dest -> $backup"
    if [ "$DRY_RUN" = true ]; then
      log_debug "DRY-RUN: mv -f \"$dest\" \"$backup\""
    else
      if ! mv -f "$dest" "$backup" 2>/dev/null; then
        log_error "Failed to backup $dest"
        return 1
      fi
    fi
  fi
  
  # Create symlink
  if [ "$DRY_RUN" = true ]; then
    log_debug "DRY-RUN: ln -sfn \"$src\" \"$dest\""
  else
    if ! ln -sfn "$src" "$dest" 2>/dev/null; then
      log_error "Failed to create symlink: $dest -> $src"
      return 1
    fi
  fi
  
  log_info "Linked: $dest -> $src"
  ((CONFIGS_LINKED++))
  return 0
}

run_sudo_pacman() {
  local pkgs=("$@")
  local to_install=()
  
  # Check which packages are already installed
  for pkg in "${pkgs[@]}"; do
    if pacman -Q "$pkg" &>/dev/null; then
      log_debug "Package already installed: $pkg"
      ((PACKAGES_SKIPPED++))
    else
      to_install+=("$pkg")
    fi
  done
  
  if [ ${#to_install[@]} -eq 0 ]; then
    log_info "All packages already installed"
    return 0
  fi
  
  log_info "Installing ${#to_install[@]} packages: ${to_install[*]}"
  if run_cmd sudo pacman -Syu --needed --noconfirm "${to_install[@]}"; then
    ((PACKAGES_INSTALLED+=${#to_install[@]}))
    return 0
  else
    log_error "Failed to install packages"
    return 1
  fi
}

install_yay_if_missing() {
  if command_exists yay; then
    log_info "yay already installed at $(command -v yay)"
    return 0
  fi
  
  log_info "Installing yay into $AUR_DIR/yay"
  if [ "$DRY_RUN" = true ]; then
    log_debug "DRY-RUN: mkdir -p \"$AUR_DIR\" && git clone https://aur.archlinux.org/yay.git \"$AUR_DIR/yay\" && cd \"$AUR_DIR/yay\" && makepkg -si --noconfirm"
    return 0
  fi
  
  mkdir -p "$AUR_DIR" || { log_error "Failed to create AUR directory"; return 1; }
  pushd "$AUR_DIR" >/dev/null || return 1
  
  if [ ! -d yay ]; then
    if ! git clone https://aur.archlinux.org/yay.git yay; then
      log_error "Failed to clone yay repository"
      popd >/dev/null
      return 1
    fi
  fi
  
  cd yay || { popd >/dev/null; return 1; }
  
  # makepkg must be run as regular user
  if makepkg -si --noconfirm; then
    log_info "yay installed successfully"
    ((PACKAGES_INSTALLED++))
    popd >/dev/null
    return 0
  else
    log_error "Failed to build/install yay"
    popd >/dev/null
    return 1
  fi
}

# ---------- Safety checks ----------
if [ "$DRY_RUN" != true ] && [ "$(id -u)" -eq 0 ]; then
  echo "This script should NOT be run as root. Run as your regular user; the script uses sudo for required root actions."
  exit 1
fi

# Initialize log file
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
echo "=== Pixarch Installation Log ===" > "$LOG_FILE"
echo "Started at: $(date '+%Y-%m-%d %H:%M:%S')" >> "$LOG_FILE"
echo "User: $USER" >> "$LOG_FILE"
echo "Home: $HOME_DIR" >> "$LOG_FILE"
echo "Dotfiles: $DOTDIR" >> "$LOG_FILE"
echo "Flags: NONINTERACTIVE=$NONINTERACTIVE DRY_RUN=$DRY_RUN VERBOSE=$VERBOSE QUIET=$QUIET" >> "$LOG_FILE"
echo "======================================" >> "$LOG_FILE"

log_info "Pixarch installer starting..."
log_info "Log file: $LOG_FILE"

# Validate environment
if [ ! -d "$DOTDIR" ]; then
  log_error "Dotfiles directory not found: $DOTDIR"
  exit 1
fi

if [ ! -d "$HOME_DIR" ]; then
  log_error "Home directory not found: $HOME_DIR"
  exit 1
fi

# Check for required commands
REQUIRED_CMDS=(pacman sudo git)
for cmd in "${REQUIRED_CMDS[@]}"; do
  if ! command_exists "$cmd"; then
    log_error "Required command not found: $cmd"
    exit 1
  fi
done

mkdir -p "$TMPDIR" "$AUR_DIR"

log_info "DOTDIR=$DOTDIR"
log_info "Home=$HOME_DIR"
log_info "AUR=$AUR_DIR"

# Calculate total steps for progress tracking
TOTAL_STEPS=10
if [ "$SKIP_I3" != true ]; then ((TOTAL_STEPS++)); fi
if [ "$SKIP_QTILE" != true ]; then ((TOTAL_STEPS++)); fi
if [ "$SKIP_THEMES" != true ]; then ((TOTAL_STEPS++)); fi
if [ "$SKIP_BROWSEL" != true ]; then ((TOTAL_STEPS++)); fi
if [ "$SKIP_SECURITY" != true ]; then ((TOTAL_STEPS++)); fi

log_info "Total steps to execute: $TOTAL_STEPS"

# ---------- Main flow ----------
step_start "Installing core packages via pacman"
run_sudo_pacman "${PACMAN_PKGS[@]}"

step_start "Setting up XDG user directories"
if command_exists xdg-user-dirs-update; then
  if [ "$DRY_RUN" = true ]; then
    log_debug "DRY-RUN: xdg-user-dirs-update"
  else
    if xdg-user-dirs-update; then
      log_info "XDG user directories configured"
    else
      log_warn "xdg-user-dirs-update failed"
    fi
  fi
fi

# Install yay + some AUR fonts
if [ "$SKIP_AUR" != true ]; then
  step_start "Installing yay and AUR packages"
  install_yay_if_missing
  if command_exists yay; then
    if run_cmd yay -S --noconfirm --needed ttf-monocraft; then
      ((PACKAGES_INSTALLED++))
      if [ "$DRY_RUN" = true ]; then
        log_debug "DRY-RUN: fc-cache -fv"
      else
        if fc-cache -fv >/dev/null 2>&1; then
          log_info "Font cache updated"
        else
          log_warn "Font cache update failed"
        fi
      fi
    else
      log_warn "Failed to install AUR fonts"
    fi
  fi
else
  log_info "Skipping AUR packages (--skip-aur)"
fi

# Optionally install i3
if [ "$SKIP_I3" != true ]; then
  step_start "Installing i3 window manager"
  if ask_yes_no "Install i3 (i3-wm) and link i3 flavour from dotfiles?"; then
    if run_cmd sudo pacman -S --noconfirm --needed i3-wm; then
      ((PACKAGES_INSTALLED++))
      backup_and_link "$DOTDIR/flavours/i3" "${HOME_DIR}/.config/i3"
    else
      log_error "Failed to install i3"
    fi
  else
    log_info "Skipping i3 (user declined)"
  fi
else
  log_info "Skipping i3 (--skip-i3)"
fi

# Optionally install qtile
if [ "$SKIP_QTILE" != true ]; then
  step_start "Installing qtile window manager"
  if ask_yes_no "Install qtile and link qtile flavour from dotfiles?"; then
    if run_cmd sudo pacman -S --noconfirm --needed qtile; then
      ((PACKAGES_INSTALLED++))
      backup_and_link "$DOTDIR/flavours/qtile" "${HOME_DIR}/.config/qtile"
    else
      log_error "Failed to install qtile"
    fi
  else
    log_info "Skipping qtile (user declined)"
  fi
else
  log_info "Skipping qtile (--skip-qtile)"
fi

# Link common configs (backing up any existing)
step_start "Linking configuration files"
mkdir -p "${HOME_DIR}/.config"
backup_and_link "$DOTDIR/config/alacritty" "${HOME_DIR}/.config/alacritty"
backup_and_link "$DOTDIR/config/lf" "${HOME_DIR}/.config/lf"
backup_and_link "$DOTDIR/config/picom" "${HOME_DIR}/.config/picom"
backup_and_link "$DOTDIR/config/polybar" "${HOME_DIR}/.config/polybar"
backup_and_link "$DOTDIR/config/rofi" "${HOME_DIR}/.config/rofi"
backup_and_link "$DOTDIR/config/rofi-power-menu" "${HOME_DIR}/.config/rofi-power-menu"
backup_and_link "$DOTDIR/config/vim" "${HOME_DIR}/.config/vim"

# Optionally install themes (requires sudo)
if [ "$SKIP_THEMES" != true ]; then
  step_start "Installing GRUB and SDDM themes"
  if ask_yes_no "Copy GRUB theme and SDDM theme to system locations and update config? (requires sudo)"; then
    if [ -d "$DOTDIR/boot/grub/grubel" ]; then
      if run_cmd sudo cp -r "$DOTDIR/boot/grub/grubel" /boot/grub/; then
        log_info "GRUB theme copied"
        if [ "$DRY_RUN" = true ]; then
          log_debug 'DRY-RUN: sudo sed -i '\''s|#GRUB_THEME=.*|GRUB_THEME="/boot/grub/grubel/theme.txt"|'\'' /etc/default/grub'
          log_debug "DRY-RUN: sudo grub-mkconfig -o /boot/grub/grub.cfg"
        else
          if sudo sed -i 's|#GRUB_THEME=.*|GRUB_THEME="/boot/grub/grubel/theme.txt"|' /etc/default/grub 2>/dev/null; then
            log_info "GRUB config updated"
            if sudo grub-mkconfig -o /boot/grub/grub.cfg 2>/dev/null; then
              log_info "GRUB configuration regenerated"
            else
              log_warn "grub-mkconfig failed"
            fi
          else
            log_warn "Failed to update GRUB config"
          fi
        fi
      else
        log_error "Failed to copy GRUB theme"
      fi
    fi
    
    if [ -d "$DOTDIR/boot/sddm/themes/pixarch_sddm" ]; then
      if run_cmd sudo cp -r "$DOTDIR/boot/sddm/themes/pixarch_sddm" /usr/share/sddm/themes/; then
        log_info "SDDM theme copied"
        if [ -f "$DOTDIR/installation_scripts/theme.conf" ]; then
          run_cmd sudo cp "$DOTDIR/installation_scripts/theme.conf" /etc/sddm.conf
        fi
        if run_cmd sudo systemctl enable --now sddm; then
          log_info "SDDM enabled and started"
        else
          log_warn "Failed to enable sddm service"
        fi
      else
        log_error "Failed to copy SDDM theme"
      fi
    fi
  else
    log_info "Skipping themes (user declined)"
  fi
else
  log_info "Skipping themes (--skip-themes)"
fi

# Optionally install browsel (searxng + surf patched for local engine)
if [ "$SKIP_BROWSEL" != true ]; then
  step_start "Installing browsel (searxng + surf)"
  if ask_yes_no "Install searxng and surf (browsel) from AUR and apply local patches?"; then
    if ! command_exists yay; then
      log_info "yay not found; installing yay first"
      install_yay_if_missing
    fi
    
    if command_exists yay; then
      pushd "$AUR_DIR" >/dev/null || { log_error "Failed to cd to $AUR_DIR"; }
      
      # searxng-git
      log_info "Building searxng-git..."
      if [ -d searxng-git ]; then rm -rf searxng-git; fi
      if run_cmd yay -G searxng-git; then
        if [ -d searxng-git ]; then
          pushd searxng-git >/dev/null || { log_error "Failed to cd to searxng-git"; popd >/dev/null; }
          if [ -f "$DOTDIR/applications/browsel/searxng.patch" ]; then
            if [ "$DRY_RUN" = true ]; then
              log_debug "DRY-RUN: patch PKGBUILD with $DOTDIR/applications/browsel/searxng.patch"
            else
              if patch -p0 < "$DOTDIR/applications/browsel/searxng.patch" 2>/dev/null; then
                log_info "searxng patch applied"
              else
                log_warn "searxng patch failed"
              fi
            fi
          fi
          if [ "$DRY_RUN" = true ]; then
            log_debug "DRY-RUN: makepkg -si"
          else
            if makepkg -si --noconfirm 2>/dev/null; then
              log_info "searxng-git installed"
              ((PACKAGES_INSTALLED++))
            else
              log_error "makepkg searxng failed"
            fi
          fi
          popd >/dev/null
        fi
      else
        log_error "Failed to get searxng-git from AUR"
      fi

      # surf-git
      log_info "Building surf-git..."
      if [ -d surf-git ]; then rm -rf surf-git; fi
      if run_cmd yay -G surf-git; then
        if [ -d surf-git ]; then
          pushd surf-git >/dev/null || { log_error "Failed to cd to surf-git"; popd >/dev/null; }
          if [ -f "$DOTDIR/applications/browsel/surf.patch" ]; then
            if [ "$DRY_RUN" = true ]; then
              log_debug "DRY-RUN: patch PKGBUILD with $DOTDIR/applications/browsel/surf.patch"
            else
              if patch -p0 < "$DOTDIR/applications/browsel/surf.patch" 2>/dev/null; then
                log_info "surf patch applied"
              else
                log_warn "surf patch failed"
              fi
            fi
          fi
          if [ "$DRY_RUN" = true ]; then
            log_debug "DRY-RUN: makepkg -si"
          else
            if makepkg -si --noconfirm 2>/dev/null; then
              log_info "surf-git installed"
              ((PACKAGES_INSTALLED++))
            else
              log_error "makepkg surf failed"
            fi
          fi
          popd >/dev/null
        fi
      else
        log_error "Failed to get surf-git from AUR"
      fi
      
      popd >/dev/null
    fi
  else
    log_info "Skipping browsel (user declined)"
  fi
else
  log_info "Skipping browsel (--skip-browsel)"
fi

# Optional security tools
if [ "$SKIP_SECURITY" != true ]; then
  step_start "Installing security tools"
  if ask_yes_no "Install ClamAV and UFW via installation script?"; then
    if [ -f "$DOTDIR/installation_scripts/security.sh" ]; then
      if [ "$DRY_RUN" = true ]; then
        log_debug "DRY-RUN: bash \"$DOTDIR/installation_scripts/security.sh\""
      else
        if bash "$DOTDIR/installation_scripts/security.sh"; then
          log_info "Security tools installed"
        else
          log_error "security.sh failed"
        fi
      fi
    else
      log_warn "security.sh not found in $DOTDIR/installation_scripts"
    fi
  else
    log_info "Skipping security tools (user declined)"
  fi
else
  log_info "Skipping security tools (--skip-security)"
fi

# ---------- Final Summary ----------
echo ""
log_info "==================== Installation Summary ===================="
log_info "Packages installed: $PACKAGES_INSTALLED"
log_info "Packages skipped (already installed): $PACKAGES_SKIPPED"
log_info "Configs linked: $CONFIGS_LINKED"
log_info "Errors encountered: $ERRORS_ENCOUNTERED"
log_info "Log file: $LOG_FILE"
if [ "$NO_BACKUP" != true ]; then
  log_info "Backup files created with .bak.<timestamp> extension"
fi
log_info "=============================================================="

if [ "$ERRORS_ENCOUNTERED" -gt 0 ]; then
  log_warn "Installation completed with $ERRORS_ENCOUNTERED error(s). Review log for details."
  exit 1
else
  log_info "Installation completed successfully!"
  exit 0
fi
