#!/usr/bin/env bash
# Build a standalone macOS .app bundle for WallpaperPalette without using Xcode
# Produces: dist/WallpaperPalette.app

set -euo pipefail

# --------------------------
# Configuration (override via env vars)
# --------------------------
APP_NAME="${APP_NAME:-WallpaperPalette}"
BUNDLE_ID="${BUNDLE_ID:-com.example.${APP_NAME}}"
VERSION="${VERSION:-}"
BUILD_NUMBER="${BUILD_NUMBER:-}"
DEPLOYMENT_TARGET="${DEPLOYMENT_TARGET:-12.0}" # macOS 12 by default
UNIVERSAL="${UNIVERSAL:-0}"                     # 1 to build a universal (arm64+x86_64) binary
PACKAGE_ZIP="${PACKAGE_ZIP:-1}"                 # 1 to produce a .zip artifact
PACKAGE_DMG="${PACKAGE_DMG:-1}"                 # 1 to produce a .dmg artifact
ZIP_NAME="${ZIP_NAME:-${APP_NAME}.zip}"
DMG_NAME="${DMG_NAME:-${APP_NAME}.dmg}"
DMG_VOLNAME="${DMG_VOLNAME:-${APP_NAME}}"


# --------------------------
# Paths
# --------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SRC_DIR="${ROOT_DIR}/sources"
DIST_DIR="${ROOT_DIR}/dist"
BUILD_DIR="${ROOT_DIR}/build"
APP_DIR="${DIST_DIR}/${APP_NAME}.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
PLIST_PATH="${CONTENTS_DIR}/Info.plist"
PKGINFO_PATH="${CONTENTS_DIR}/PkgInfo"

MAIN_SWIFT="${SRC_DIR}/main.swift"
ALL_SWIFT=("${SRC_DIR}"/*.swift)

# Optional icon (copy if exists)
CANDIDATE_ICNS_1="${SRC_DIR}/${APP_NAME}.icns"
CANDIDATE_ICNS_2="${ROOT_DIR}/${APP_NAME}.icns"
ICNS_PATH=""

# --------------------------
# Helpers
# --------------------------
log() { printf "\033[1;34m[build]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[warn]\033[0m %s\n" "$*"; }
err() { printf "\033[1;31m[err ]\033[0m %s\n" "$*" >&2; }
die() { err "$*"; exit 1; }

require() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required tool '$1'. Please install Xcode Command Line Tools."
}

# --------------------------
# Pre-flight checks
# --------------------------
require swiftc
if command -v xcrun >/dev/null 2>&1; then
  SDK_PATH="$(xcrun --show-sdk-path --sdk macosx)"
else
  warn "xcrun not found. Proceeding without explicit -sdk flag (swiftc will use defaults)."
  SDK_PATH=""
fi

[[ -f "${MAIN_SWIFT}" ]] || die "Missing file: ${MAIN_SWIFT}"
if [[ "${#ALL_SWIFT[@]}" -eq 0 ]]; then
  die "No Swift sources found in ${SRC_DIR}"
fi

if [[ -z "${VERSION}" ]]; then
  if command -v git >/dev/null 2>&1 && git -C "${ROOT_DIR}" rev-parse >/dev/null 2>&1; then
    VERSION="$(git -C "${ROOT_DIR}" describe --tags --always --dirty 2>/dev/null || true)"
    VERSION="${VERSION:-1.0.0}"
  else
    VERSION="1.0.0"
  fi
fi
if [[ -z "${BUILD_NUMBER}" ]]; then
  BUILD_NUMBER="$(date +%Y%m%d%H%M%S)"
fi

if [[ -f "${CANDIDATE_ICNS_1}" ]]; then
  ICNS_PATH="${CANDIDATE_ICNS_1}"
elif [[ -f "${CANDIDATE_ICNS_2}" ]]; then
  ICNS_PATH="${CANDIDATE_ICNS_2}"
fi

# --------------------------
# Prepare directories
# --------------------------
log "Preparing directories..."
rm -rf "${APP_DIR}"
mkdir -p "${DIST_DIR}" "${BUILD_DIR}" "${MACOS_DIR}" "${RESOURCES_DIR}"

# --------------------------
# Compile
# --------------------------
SWIFT_FLAGS=(
  -O
  -whole-module-optimization

  -swift-version 5
  -DRELEASE
)

LINK_FLAGS=(
  -framework AppKit
  -framework Foundation
)

if [[ -n "${SDK_PATH}" ]]; then
  SWIFT_FLAGS+=(-sdk "${SDK_PATH}")
fi

BIN_NAME="${APP_NAME}"
BIN_PATH="${MACOS_DIR}/${BIN_NAME}"

compile_arch() {
  local arch="$1"
  local out="$2"
  log "Compiling (${arch}) -> ${out}"
  swiftc "${SWIFT_FLAGS[@]}" -target "${arch}-apple-macosx${DEPLOYMENT_TARGET}" \
    "${ALL_SWIFT[@]}" \
    "${LINK_FLAGS[@]}" \
    -o "${out}"
}

if [[ "${UNIVERSAL}" == "1" ]]; then
  require lipo
  TMP_ARM64="${BUILD_DIR}/${APP_NAME}-arm64"
  TMP_X64="${BUILD_DIR}/${APP_NAME}-x86_64"
  compile_arch "arm64" "${TMP_ARM64}"
  compile_arch "x86_64" "${TMP_X64}"
  log "Creating universal binary..."
  lipo -create -output "${BIN_PATH}" "${TMP_ARM64}" "${TMP_X64}"
else
  # Build for host arch
  HOST_ARCH="$(uname -m)"
  case "${HOST_ARCH}" in
    arm64|aarch64) TARGET_ARCH="arm64" ;;
    x86_64|amd64)  TARGET_ARCH="x86_64" ;;
    *) warn "Unknown host arch '${HOST_ARCH}', defaulting to native build w/o -target"; TARGET_ARCH="";;
  esac

  if [[ -n "${TARGET_ARCH}" ]]; then
    compile_arch "${TARGET_ARCH}" "${BIN_PATH}"
  else
    log "Compiling (native)..."
    swiftc "${SWIFT_FLAGS[@]}" \
      "${ALL_SWIFT[@]}" \
      "${LINK_FLAGS[@]}" \
      -o "${BIN_PATH}"
  fi
fi

# --------------------------
# Info.plist
# --------------------------
log "Creating Info.plist..."
cat > "${PLIST_PATH}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple Computer//DTD PLIST 1.0//EN"
 "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>${APP_NAME}</string>

  <key>CFBundleDisplayName</key>
  <string>${APP_NAME}</string>

  <key>CFBundleIdentifier</key>
  <string>${BUNDLE_ID}</string>

  <key>CFBundleExecutable</key>
  <string>${APP_NAME}</string>

  <key>CFBundlePackageType</key>
  <string>APPL</string>

  <key>CFBundleShortVersionString</key>
  <string>${VERSION}</string>

  <key>CFBundleVersion</key>
  <string>${BUILD_NUMBER}</string>

  <key>LSMinimumSystemVersion</key>
  <string>${DEPLOYMENT_TARGET}</string>

  <!-- Hide dock icon but allow notifications/UI as needed -->
  <key>LSUIElement</key>
  <true/>

  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

# --------------------------
# PkgInfo
# --------------------------
echo -n "APPL????" > "${PKGINFO_PATH}"

# --------------------------
# Resources (icon)
# --------------------------
if [[ -n "${ICNS_PATH}" ]]; then
  log "Copying app icon: ${ICNS_PATH}"
  cp "${ICNS_PATH}" "${RESOURCES_DIR}/AppIcon.icns"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon.icns" "${PLIST_PATH}" >/dev/null 2>&1 || true
else
  log "No .icns found at:"
  log "  - ${CANDIDATE_ICNS_1}"
  log "  - ${CANDIDATE_ICNS_2}"
  log "Generating placeholder app icon from vector drawing..."
  require sips
  require iconutil

  GEN_DIR="${BUILD_DIR}/gen_icon"
  ICONSET_DIR="${GEN_DIR}/AppIcon.iconset"
  BASE_PNG="${GEN_DIR}/AppIcon_1024.png"
  ICON_SWIFT="${GEN_DIR}/gen_icon.swift"
  ICON_TOOL="${GEN_DIR}/gen_icon_tool"

  rm -rf "${GEN_DIR}"
  mkdir -p "${ICONSET_DIR}"

  cat > "${ICON_SWIFT}" <<'SWIFT'
import AppKit
import Foundation

let size = NSSize(width: 1024, height: 1024)
let img = NSImage(size: size)
img.lockFocus()

NSColor.clear.setFill()
NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()

NSColor.black.set() // template-style alpha-only drawing

// Palette outline
let rect = NSRect(x: 112, y: 160, width: 800, height: 640)
let outline = NSBezierPath(roundedRect: rect, xRadius: 280, yRadius: 280)
outline.lineWidth = 28
outline.stroke()

// Thumb hole (ring)
let hole = NSBezierPath(ovalIn: NSRect(x: rect.maxX - 190, y: rect.minY + 200, width: 110, height: 110))
hole.lineWidth = 24
hole.stroke()

// Swatches
func dot(_ x: CGFloat, _ y: CGFloat, r: CGFloat = 24) {
    let d = NSBezierPath(ovalIn: NSRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
    d.fill()
}
dot(rect.minX + 260, rect.midY + 110)
dot(rect.minX + 220, rect.midY - 10)
dot(rect.minX + 340, rect.midY - 40)
dot(rect.minX + 420, rect.midY + 20)

// Brush stroke
let brush = NSBezierPath()
brush.lineWidth = 26
brush.move(to: NSPoint(x: rect.minX + 470, y: rect.maxY - 70))
brush.line(to: NSPoint(x: rect.maxX - 60, y: rect.maxY - 220))
brush.stroke()

img.unlockFocus()

let dest = CommandLine.arguments[1]
if let tiff = img.tiffRepresentation,
   let rep = NSBitmapImageRep(data: tiff),
   let png = rep.representation(using: .png, properties: [:]) {
    try png.write(to: URL(fileURLWithPath: dest))
    exit(0)
} else {
    fputs("Failed to render icon\n", stderr)
    exit(1)
}
SWIFT

  swiftc -O -framework AppKit -framework Foundation "${ICON_SWIFT}" -o "${ICON_TOOL}"
  "${ICON_TOOL}" "${BASE_PNG}"

  # Generate iconset PNGs
  sips -z 16 16   "${BASE_PNG}" --out "${ICONSET_DIR}/icon_16x16.png" >/dev/null
  sips -z 32 32   "${BASE_PNG}" --out "${ICONSET_DIR}/icon_16x16@2x.png" >/dev/null
  sips -z 32 32   "${BASE_PNG}" --out "${ICONSET_DIR}/icon_32x32.png" >/dev/null
  sips -z 64 64   "${BASE_PNG}" --out "${ICONSET_DIR}/icon_32x32@2x.png" >/dev/null
  sips -z 128 128 "${BASE_PNG}" --out "${ICONSET_DIR}/icon_128x128.png" >/dev/null
  sips -z 256 256 "${BASE_PNG}" --out "${ICONSET_DIR}/icon_128x128@2x.png" >/dev/null
  sips -z 256 256 "${BASE_PNG}" --out "${ICONSET_DIR}/icon_256x256.png" >/dev/null
  sips -z 512 512 "${BASE_PNG}" --out "${ICONSET_DIR}/icon_256x256@2x.png" >/dev/null
  sips -z 512 512 "${BASE_PNG}" --out "${ICONSET_DIR}/icon_512x512.png" >/dev/null
  cp "${BASE_PNG}" "${ICONSET_DIR}/icon_512x512@2x.png"

  # Convert to .icns and link in Info.plist
  iconutil -c icns "${ICONSET_DIR}" -o "${RESOURCES_DIR}/AppIcon.icns"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon.icns" "${PLIST_PATH}" >/dev/null 2>&1 || true
fi

# --------------------------
# Codesign (ad-hoc)
# --------------------------
if command -v codesign >/dev/null 2>&1; then
  log "Ad-hoc signing app..."
  codesign --force --sign - --timestamp=none "${APP_DIR}" || warn "codesign failed; the app may still run locally."
else
  warn "codesign not found; skipping code signing."
fi

# --------------------------
# Packaging (ZIP/DMG)
# --------------------------
if [[ "${PACKAGE_ZIP}" == "1" ]]; then
  require ditto
  ZIP_PATH="${DIST_DIR}/${ZIP_NAME}"
  log "Creating ZIP: ${ZIP_PATH}"
  rm -f "${ZIP_PATH}"
  ditto -c -k --sequesterRsrc --keepParent "${APP_DIR}" "${ZIP_PATH}"
fi

if [[ "${PACKAGE_DMG}" == "1" ]]; then
  require hdiutil
  STAGE_DIR="${BUILD_DIR}/dmg_stage"
  rm -rf "${STAGE_DIR}"
  mkdir -p "${STAGE_DIR}"
  cp -R "${APP_DIR}" "${STAGE_DIR}/"
  ln -sf /Applications "${STAGE_DIR}/Applications"
  DMG_PATH="${DIST_DIR}/${DMG_NAME}"
  log "Creating DMG: ${DMG_PATH}"
  hdiutil create -volname "${DMG_VOLNAME}" -srcfolder "${STAGE_DIR}" -ov -fs HFS+ "${DMG_PATH}" >/dev/null
fi



# --------------------------
# Summary
# --------------------------
log "Built app at: ${APP_DIR}"
if [[ "${PACKAGE_ZIP}" == "1" ]]; then
  echo "ZIP: ${DIST_DIR}/${ZIP_NAME}"
fi
if [[ "${PACKAGE_DMG}" == "1" ]]; then
  echo "DMG: ${DIST_DIR}/${DMG_NAME}"
fi
