#!/bin/bash
set -euo pipefail

PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
APP_VERSION="${DDUMP_VERSION:-0.3.3}"
MACOS_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.0}"
DIST_DIR="${PROJECT_DIR}/dist"
APP_BUNDLE="${DIST_DIR}/DDump.app"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "swiftc is required to build DDump.app." >&2
  exit 1
fi

rm -rf "$APP_BUNDLE"
mkdir -p "${APP_BUNDLE}/Contents/MacOS" "${APP_BUNDLE}/Contents/Resources"

cat >"${APP_BUNDLE}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>DDump</string>
  <key>CFBundleDisplayName</key>
  <string>DDump</string>
  <key>CFBundleIdentifier</key>
  <string>com.ddump.app</string>
  <key>CFBundleVersion</key>
  <string>${APP_VERSION}</string>
  <key>CFBundleShortVersionString</key>
  <string>${APP_VERSION}</string>
  <key>CFBundleExecutable</key>
  <string>DDump</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIconName</key>
  <string>AppIcon</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>NSCalendarsFullAccessUsageDescription</key>
  <string>DDump uses calendar events to name shoot folders and resolve photo clusters between scheduled shoots.</string>
  <key>NSCalendarsUsageDescription</key>
  <string>DDump uses calendar events to name shoot folders and resolve photo clusters between scheduled shoots.</string>
</dict>
</plist>
PLIST

if [[ -f "${PROJECT_DIR}/app/Assets/AppIcon.icns" ]]; then
  cp "${PROJECT_DIR}/app/Assets/AppIcon.icns" "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"
  cp "${PROJECT_DIR}/app/Assets/AppIcon.icns" "${APP_BUNDLE}/Contents/Resources/DefaultAppIcon.icns"
fi

if [[ -d "${PROJECT_DIR}/app/Assets/Fonts" ]]; then
  mkdir -p "${APP_BUNDLE}/Contents/Resources/Fonts"
  cp "${PROJECT_DIR}/app/Assets/Fonts"/*.otf "${APP_BUNDLE}/Contents/Resources/Fonts/" 2>/dev/null || true
fi

for asset in logo-icon.png logo-icon-512.png logo-mark.svg; do
  if [[ -f "${PROJECT_DIR}/app/Assets/${asset}" ]]; then
    cp "${PROJECT_DIR}/app/Assets/${asset}" "${APP_BUNDLE}/Contents/Resources/${asset}"
  fi
done

mkdir -p /private/tmp/ddump-clang-cache
BUILD_TMP="${DIST_DIR}/swift-build"
rm -rf "$BUILD_TMP"
mkdir -p "$BUILD_TMP"

build_slice() {
  local arch="$1"
  local out="$2"
  CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/private/tmp/ddump-clang-cache}" \
    swiftc -parse-as-library \
      -target "${arch}-apple-macos${MACOS_DEPLOYMENT_TARGET}" \
      -o "$out" \
      "${PROJECT_DIR}/app/DDumpApp.swift"
}

if build_slice arm64 "${BUILD_TMP}/DDump-arm64" && build_slice x86_64 "${BUILD_TMP}/DDump-x86_64"; then
  lipo -create "${BUILD_TMP}/DDump-arm64" "${BUILD_TMP}/DDump-x86_64" -output "${APP_BUNDLE}/Contents/MacOS/DDump"
  echo "Built universal app binary for macOS ${MACOS_DEPLOYMENT_TARGET}+"
else
  host_arch="$(uname -m)"
  echo "Warning: universal build failed; building host architecture ${host_arch} only." >&2
  build_slice "$host_arch" "${APP_BUNDLE}/Contents/MacOS/DDump"
fi

chmod +x "${APP_BUNDLE}/Contents/MacOS/DDump"
/usr/bin/touch "$APP_BUNDLE"
echo "Built ${APP_BUNDLE}"
