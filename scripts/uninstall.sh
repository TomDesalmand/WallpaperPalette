#!/usr/bin/env bash
# Uninstall WallpaperPalette:
# - Disables and removes LaunchAgent
# - Kills running process
# - Removes the app bundle (from /Applications, ~/Applications, or a provided path)
# - Removes logs (optional)
#
# Usage:
#   scripts/uninstall.sh [--app /path/to/WallpaperPalette.app] [-y|--yes] [--keep-logs]
#                        [--label com.example.WallpaperPalette] [--bundle-id com.example.WallpaperPalette]
#                        [--name WallpaperPalette]
#
# Examples:
#   scripts/uninstall.sh
#   scripts/uninstall.sh --app "/Applications/WallpaperPalette.app" -y
#   APP_NAME="WallpaperPalette" BUNDLE_ID="com.me.WallpaperPalette" scripts/uninstall.sh

set -euo pipefail

# ---------- Defaults (overridable via args/env) ----------
APP_NAME="${APP_NAME:-WallpaperPalette}"
BUNDLE_ID="${BUNDLE_ID:-com.example.${APP_NAME}}"
LAUNCH_LABEL="${LAUNCH_LABEL:-${BUNDLE_ID}}"
KEEP_LOGS="${KEEP_LOGS:-0}"
YES="${YES:-0}"
APP_PATH="${APP_PATH:-}"

# ---------- Paths ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

PLIST_FILE="${HOME}/Library/LaunchAgents/${LAUNCH_LABEL}.plist"
LOG_OUT="${HOME}/Library/Logs/${APP_NAME}.out.log"
LOG_ERR="${HOME}/Library/Logs/${APP_NAME}.err.log"

# ---------- Helpers ----------
log() { printf "\033[1;34m[uninstall]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[warn]\033[0m %s\n" "$*"; }
err() { printf "\033[1;31m[err ]\033[0m %s\n" "$*" >&2; }
die() { err "$*"; exit 1; }

usage() {
  cat <<USAGE
Uninstall ${APP_NAME}

Options:
  --app PATH            Path to the app bundle to remove (e.g. /Applications/${APP_NAME}.app)
  -y, --yes             Do not prompt for confirmation
  --keep-logs           Keep logs in ~/Library/Logs (default: remove)
  --label LABEL         LaunchAgent label (default: ${LAUNCH_LABEL})
  --bundle-id ID        Bundle identifier (default: ${BUNDLE_ID})
  --name NAME           App name (default: ${APP_NAME})
  -h, --help            Show this help

Environment variables (alternative to flags):
  APP_NAME, BUNDLE_ID, LAUNCH_LABEL, APP_PATH, KEEP_LOGS=1, YES=1
USAGE
}

confirm() {
  local prompt="${1:-Are you sure?} [y/N] "
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

path_exists() {
  [[ -e "$1" ]]
}

find_app_path() {
  # Priority:
  # 1. Provided APP_PATH
  # 2. /Applications/APP_NAME.app
  # 3. ~/Applications/APP_NAME.app
  # 4. Repo dist/APP_NAME.app (convenience if running from source)
  if [[ -n "${APP_PATH}" && -d "${APP_PATH}" ]]; then
    echo "${APP_PATH}"
    return
  fi
  local p1="/Applications/${APP_NAME}.app"
  local p2="${HOME}/Applications/${APP_NAME}.app"
  local p3="${ROOT_DIR}/dist/${APP_NAME}.app"
  if [[ -d "${p1}" ]]; then echo "${p1}"; return; fi
  if [[ -d "${p2}" ]]; then echo "${p2}"; return; fi
  if [[ -d "${p3}" ]]; then echo "${p3}"; return; fi
  echo ""
}

unload_launch_agent() {
  if [[ -f "${PLIST_FILE}" ]]; then
    log "Unloading LaunchAgent: ${PLIST_FILE}"
    launchctl unload -w "${PLIST_FILE}" >/dev/null 2>&1 || warn "Failed to unload LaunchAgent (it may not be loaded)"
    log "Removing LaunchAgent file"
    rm -f "${PLIST_FILE}" || warn "Unable to remove ${PLIST_FILE}"
  else
    log "No LaunchAgent found at ${PLIST_FILE}"
  fi
}

kill_running_process() {
  # Attempt to stop any running process named exactly APP_NAME
  log "Stopping any running ${APP_NAME} processes"
  if command -v pkill >/dev/null 2>&1; then
    pkill -x "${APP_NAME}" >/dev/null 2>&1 || true
    # Give it a moment
    sleep 0.5
    # Force kill if still running
    pkill -9 -x "${APP_NAME}" >/dev/null 2>&1 || true
  elif command -v killall >/dev/null 2>&1; then
    killall "${APP_NAME}" >/dev/null 2>&1 || true
    sleep 0.5
    killall -9 "${APP_NAME}" >/dev/null 2>&1 || true
  else
    warn "Neither pkill nor killall found; skipping process termination"
  fi
}

remove_app_bundle() {
  local app_path="$1"
  if [[ -z "${app_path}" ]]; then
    warn "No app bundle found to remove."
    return
  fi
  if [[ ! -d "${app_path}" ]]; then
    warn "App bundle not found at: ${app_path}"
    return
  fi
  if [[ "${app_path}" != *.app ]]; then
    warn "Refusing to remove non-.app path: ${app_path}"
    return
  fi
  log "Removing app: ${app_path}"
  if rm -rf "${app_path}" 2>/dev/null; then
    log "Removed ${app_path}"
  else
    warn "Failed to remove ${app_path} without privileges."
    if [[ -t 1 ]]; then
      if confirm "Use sudo to remove ${app_path}?"; then
        require sudo
        sudo rm -rf "${app_path}" || warn "sudo removal failed"
      fi
    else
      warn "Non-interactive shell; re-run with sufficient permissions to remove: ${app_path}"
    fi
  fi
}

remove_logs() {
  if [[ "${KEEP_LOGS}" == "1" ]]; then
    log "Keeping logs (requested)"
    return
  fi
  log "Removing logs (if present)"
  rm -f "${LOG_OUT}" "${LOG_ERR}" 2>/dev/null || true
}

# ---------- Parse args ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) APP_PATH="${2:-}"; shift 2 ;;
    -y|--yes) YES=1; shift ;;
    --keep-logs) KEEP_LOGS=1; shift ;;
    --label) LAUNCH_LABEL="${2:-}"; PLIST_FILE="${HOME}/Library/LaunchAgents/${LAUNCH_LABEL}.plist"; shift 2 ;;
    --bundle-id) BUNDLE_ID="${2:-}"; shift 2 ;;
    --name) APP_NAME="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) warn "Unknown option: $1"; shift ;;
  esac
done

# If BUNDLE_ID changed, and LAUNCH_LABEL wasn't explicitly overridden, keep default LAUNCH_LABEL=BUNDLE_ID.
if [[ "${LAUNCH_LABEL}" == "com.example.${APP_NAME}" && "${BUNDLE_ID}" != "com.example.${APP_NAME}" ]]; then
  LAUNCH_LABEL="${BUNDLE_ID}"
  PLIST_FILE="${HOME}/Library/LaunchAgents/${LAUNCH_LABEL}.plist"
fi

# Recompute logs path if APP_NAME changed via args
LOG_OUT="${HOME}/Library/Logs/${APP_NAME}.out.log"
LOG_ERR="${HOME}/Library/Logs/${APP_NAME}.err.log"

# ---------- Summary and confirmation ----------
FOUND_APP="$(find_app_path)"
TARGET_APP="${APP_PATH:-${FOUND_APP}}"

echo "This will:"
echo " - Unload and remove LaunchAgent: ${PLIST_FILE}"
echo " - Kill running '${APP_NAME}' processes"
if [[ -n "${TARGET_APP}" ]]; then
  echo " - Remove app bundle: ${TARGET_APP}"
else
  echo " - Remove app bundle: (none found)"
fi
if [[ "${KEEP_LOGS}" == "1" ]]; then
  echo " - Keep logs in: ${LOG_OUT}, ${LOG_ERR}"
else
  echo " - Remove logs in: ${LOG_OUT}, ${LOG_ERR}"
fi

if ! confirm "Proceed with uninstall?"; then
  log "Aborted."
  exit 0
fi

# ---------- Execute ----------
unload_launch_agent
kill_running_process
remove_app_bundle "${TARGET_APP}"
remove_logs

log "Uninstall complete."
