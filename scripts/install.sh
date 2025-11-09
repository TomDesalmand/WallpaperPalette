#!/usr/bin/env bash
# Install WallpaperPalette:
# - Copies the app bundle to /Applications or ~/Applications
# - Optionally enables LaunchAgent for "launch at login"
# - Optionally opens the app after install
#
# Usage:
#   WallpaperPalette/scripts/install.sh [--app /path/to/WallpaperPalette.app]
#                                       [--dir /Applications|~/Applications|<path>] [--user]
#                                       [--login|--no-login] [--open]
#                                       [-f|--force] [-y|--yes]
#                                       [--label com.example.WallpaperPalette]
#                                       [--bundle-id com.example.WallpaperPalette]
#                                       [--name WallpaperPalette]
#
# Examples:
#   WallpaperPalette/scripts/install.sh --login --open
#   WallpaperPalette/scripts/install.sh --user --app dist/WallpaperPalette.app --login
#   APP_NAME="WallpaperPalette" BUNDLE_ID="com.me.WallpaperPalette" LAUNCH_AT_LOGIN=1 WallpaperPalette/scripts/install.sh
#
# Notes:
# - If installing to /Applications requires privileges, you'll be prompted to use sudo.
# - For "launch at login", a user LaunchAgent plist is written to ~/Library/LaunchAgents.

set -euo pipefail

# ---------- Defaults (overridable via args/env) ----------
APP_NAME="${APP_NAME:-WallpaperPalette}"
BUNDLE_ID="${BUNDLE_ID:-com.example.${APP_NAME}}"
LAUNCH_LABEL="${LAUNCH_LABEL:-${BUNDLE_ID}}"

APP_SOURCE="${APP_SOURCE:-}"        # Overrides source app path. Otherwise inferred from repo dist folder.
INSTALL_DIR_DEFAULT="/Applications" # Default target directory
INSTALL_DIR="${INSTALL_DIR:-${INSTALL_DIR_DEFAULT}}"
INSTALL_USER="${INSTALL_USER:-0}"   # 1 to install to ~/Applications
FORCE="${FORCE:-0}"                 # 1 to overwrite existing app at target
YES="${YES:-0}"                     # 1 to skip confirmation prompts
LAUNCH_AT_LOGIN="${LAUNCH_AT_LOGIN:-0}"
OPEN_AFTER_INSTALL="${OPEN_AFTER_INSTALL:-0}"

# ---------- Paths ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Derived / computed later:
TARGET_APP=""

PLIST_DIR="${HOME}/Library/LaunchAgents"
PLIST_FILE="${PLIST_DIR}/${LAUNCH_LABEL}.plist"
LOG_OUT="${HOME}/Library/Logs/${APP_NAME}.out.log"
LOG_ERR="${HOME}/Library/Logs/${APP_NAME}.err.log"

# ---------- Helpers ----------
log() { printf "\033[1;34m[install]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[warn]\033[0m %s\n" "$*"; }
err() { printf "\033[1;31m[err ]\033[0m %s\n" "$*" >&2; }
die() { err "$*"; exit 1; }

usage() {
  cat <<USAGE
Install ${APP_NAME}

Options:
  --app PATH            Source .app bundle to install (default: dist/${APP_NAME}.app if present)
  --dir PATH            Install target directory (default: ${INSTALL_DIR_DEFAULT})
  --user                Install to ~/Applications (equivalent to --dir "\$HOME/Applications")
  --login               Enable launch at login via LaunchAgent
  --no-login            Do not enable launch at login (default)
  --open                Open the app after install
  -f, --force           Overwrite any existing app at the target path
  -y, --yes             Do not prompt for confirmation
  --label LABEL         LaunchAgent label (default: ${LAUNCH_LABEL})
  --bundle-id ID        Bundle identifier (default: ${BUNDLE_ID})
  --name NAME           App name (default: ${APP_NAME})
  -h, --help            Show this help

Environment variables (alternative to flags):
  APP_NAME, BUNDLE_ID, LAUNCH_LABEL, APP_SOURCE, INSTALL_DIR, INSTALL_USER=1,
  FORCE=1, YES=1, LAUNCH_AT_LOGIN=1, OPEN_AFTER_INSTALL=1
USAGE
}

confirm() {
  local prompt="${1:-Proceed?} [y/N] "
  if [[ "${YES}" == "1" ]]; then
    return 0
  fi
  read -r -p "${prompt}" reply || true
  case "${reply}" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

require() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required tool '$1'"
}

abs_path() {
  local p="$1"
  if [[ "$p" == ~* ]]; then
    eval echo "$p"
  else
    echo "$p"
  fi
}

enable_login_item() {
  local APP_PATH="$1"
  mkdir -p "${PLIST_DIR}"
  cat > "${PLIST_FILE}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LAUNCH_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${APP_PATH}/Contents/MacOS/${APP_NAME}</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>${LOG_OUT}</string>
  <key>StandardErrorPath</key>
  <string>${LOG_ERR}</string>
</dict>
</plist>
PLIST
  # Reload it
  launchctl unload -w "${PLIST_FILE}" >/dev/null 2>&1 || true
  launchctl load -w "${PLIST_FILE}"
  log "Enabled launch at login via LaunchAgent: ${PLIST_FILE}"
}

remove_existing_target() {
  local path="$1"
  if [[ ! -e "${path}" ]]; then
    return
  fi
  if [[ "${FORCE}" != "1" ]]; then
    if ! confirm "Target exists at ${path}. Overwrite?"; then
      die "Install canceled."
    fi
  fi
  log "Removing existing: ${path}"
  if rm -rf "${path}" 2>/dev/null; then
    return
  fi
  warn "Failed to remove ${path} without privileges."
  if [[ -t 1 ]]; then
    if confirm "Use sudo to remove ${path}?"; then
      require sudo
      sudo rm -rf "${path}" || die "sudo removal failed"
    else
      die "Install canceled."
    fi
  else
    die "Non-interactive shell; insufficient permissions to remove existing target: ${path}"
  fi
}

copy_app() {
  local src="$1"
  local dst="$2"
  require ditto
  log "Copying app -> ${dst}"
  if ditto "${src}" "${dst}" 2>/dev/null; then
    return
  fi
  warn "Copy failed without privileges to ${dst}."
  if [[ -t 1 ]]; then
    if confirm "Use sudo to copy to ${dst}?"; then
      require sudo
      sudo ditto "${src}" "${dst}"
    else
      die "Install canceled."
    fi
  else
    die "Non-interactive shell; insufficient permissions to copy to: ${dst}"
  fi
}

# ---------- Parse args ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) APP_SOURCE="${2:-}"; shift 2 ;;
    --dir) INSTALL_DIR="${2:-}"; shift 2 ;;
    --user) INSTALL_USER=1; shift ;;
    --login) LAUNCH_AT_LOGIN=1; shift ;;
    --no-login) LAUNCH_AT_LOGIN=0; shift ;;
    --open) OPEN_AFTER_INSTALL=1; shift ;;
    -f|--force) FORCE=1; shift ;;
    -y|--yes) YES=1; shift ;;
    --label) LAUNCH_LABEL="${2:-}"; shift 2 ;;
    --bundle-id) BUNDLE_ID="${2:-}"; shift 2 ;;
    --name) APP_NAME="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) warn "Unknown option: $1"; shift ;;
  esac
done

# If --user was set, override INSTALL_DIR
if [[ "${INSTALL_USER}" == "1" ]]; then
  INSTALL_DIR="${HOME}/Applications"
fi

# Normalize install dir
INSTALL_DIR="$(abs_path "${INSTALL_DIR}")"
TARGET_APP="${INSTALL_DIR}/${APP_NAME}.app"

# Determine source app
if [[ -z "${APP_SOURCE}" ]]; then
  # Prefer dist build from repo
  if [[ -d "${ROOT_DIR}/dist/${APP_NAME}.app" ]]; then
    APP_SOURCE="${ROOT_DIR}/dist/${APP_NAME}.app"
  else
    die "No source app specified and dist/${APP_NAME}.app not found. Provide --app /path/to/${APP_NAME}.app"
  fi
fi
APP_SOURCE="$(abs_path "${APP_SOURCE}")"

[[ -d "${APP_SOURCE}" ]] || die "Source app not found: ${APP_SOURCE}"

# Summary
echo "Install plan:"
echo " - Source: ${APP_SOURCE}"
echo " - Target: ${TARGET_APP}"
if [[ "${LAUNCH_AT_LOGIN}" == "1" ]]; then
  echo " - Launch at login: ENABLED (label: ${LAUNCH_LABEL})"
else
  echo " - Launch at login: disabled"
fi

if ! confirm "Proceed with install?"; then
  log "Aborted."
  exit 0
fi

# Ensure target directory exists
if [[ ! -d "${INSTALL_DIR}" ]]; then
  log "Creating target directory: ${INSTALL_DIR}"
  if mkdir -p "${INSTALL_DIR}" 2>/dev/null; then
    :
  else
    warn "Failed to create ${INSTALL_DIR} without privileges."
    if [[ -t 1 ]]; then
      if confirm "Use sudo to create ${INSTALL_DIR}?"; then
        require sudo
        sudo mkdir -p "${INSTALL_DIR}"
      else
        die "Install canceled."
      fi
    else
      die "Non-interactive shell; insufficient permissions to create: ${INSTALL_DIR}"
    fi
  fi
fi

# Remove existing target if present
remove_existing_target "${TARGET_APP}"

# Copy the app
copy_app "${APP_SOURCE}" "${TARGET_APP}"

# Enable login at startup if requested
if [[ "${LAUNCH_AT_LOGIN}" == "1" ]]; then
  enable_login_item "${TARGET_APP}"
fi

# Optionally open app
if [[ "${OPEN_AFTER_INSTALL}" == "1" ]]; then
  if command -v open >/dev/null 2>&1; then
    log "Opening ${TARGET_APP}"
    open "${TARGET_APP}"
  else
    warn "'open' command not found; cannot launch app automatically."
  fi
fi

log "Install complete."
echo "Installed to: ${TARGET_APP}"
if [[ "${LAUNCH_AT_LOGIN}" == "1" ]]; then
  echo "Launch at login enabled via: ${PLIST_FILE}"
fi
echo "Tip:"
echo " - To uninstall: WallpaperPalette/scripts/uninstall.sh --app \"${TARGET_APP}\""
echo " - If macOS warns about an unidentified developer, right-click the app and choose 'Open' the first time."
