#!/bin/bash
set -euo pipefail

PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
umask 022

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
APP_VERSION="${DDUMP_VERSION:-0.3.18}"
MACOS_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.0}"
RELEASE_MODE="${DDUMP_RELEASE_MODE:-0}"
SIGN_IDENTITY="${DDUMP_SIGN_IDENTITY:-}"
NOTARY_PROFILE="${DDUMP_NOTARY_PROFILE:-}"
DIST_DIR="${PROJECT_DIR}/dist"
ROOT_DIR="${DIST_DIR}/dmg-root"
PAYLOAD_DIR="${DIST_DIR}/installer-payload"
INSTALLER_APP="${ROOT_DIR}/Install DDump.app"
APP_NOTARY_ARCHIVE="${DIST_DIR}/DDump-${APP_VERSION}-notary.zip"
APP_NOTARY_RESULT="${DIST_DIR}/app-notarization-result.json"
APP_NOTARY_LOG="${DIST_DIR}/app-notarization-log.json"
DMG_NOTARY_RESULT="${DIST_DIR}/dmg-notarization-result.json"
DMG_NOTARY_LOG="${DIST_DIR}/dmg-notarization-log.json"
release_complete=0

if [[ ! "$APP_VERSION" =~ ^[0-9A-Za-z._-]+$ ]]; then
  echo "DDUMP_VERSION contains unsupported filename characters." >&2
  exit 1
fi

case "$RELEASE_MODE" in
  0)
    DMG_PATH="${DIST_DIR}/DDump-${APP_VERSION}-unsigned.dmg"
    ;;
  1)
    DMG_PATH="${DIST_DIR}/DDump-${APP_VERSION}.dmg"
    if [[ -z "$SIGN_IDENTITY" || "$SIGN_IDENTITY" != "Developer ID Application:"* ]]; then
      echo "Public packaging requires DDUMP_SIGN_IDENTITY set to a Developer ID Application identity." >&2
      exit 1
    fi
    if [[ -z "$NOTARY_PROFILE" ]]; then
      echo "Public packaging requires DDUMP_NOTARY_PROFILE set to a notarytool keychain profile." >&2
      exit 1
    fi
    ;;
  *)
    echo "DDUMP_RELEASE_MODE must be 0 (local unsigned test) or 1 (signed public release)." >&2
    exit 1
    ;;
esac

cleanup_failed_release() {
  /bin/rm -f -- "$APP_NOTARY_ARCHIVE"
  if [[ "$RELEASE_MODE" == "1" && "$release_complete" != "1" && -f "$DMG_PATH" ]]; then
    /bin/rm -f -- "$DMG_PATH"
    echo "Removed incomplete public artifact ${DMG_PATH}." >&2
  fi
}
trap cleanup_failed_release EXIT

for tool in xcrun swiftc lipo hdiutil codesign ditto; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "${tool} is required to package DDump." >&2
    exit 1
  fi
done

if [[ "$RELEASE_MODE" == "1" ]]; then
  "${SCRIPT_DIR}/public-readiness-check.sh"
fi

"${SCRIPT_DIR}/build-app.sh"

app_archs="$(lipo -archs "${DIST_DIR}/DDump.app/Contents/MacOS/DDump")"
if [[ " $app_archs " != *" arm64 "* || " $app_archs " != *" x86_64 "* ]]; then
  if [[ "$RELEASE_MODE" == "1" ]]; then
    echo "Public packaging requires a universal arm64 + x86_64 DDump binary; found: ${app_archs}." >&2
    exit 1
  fi
  echo "Warning: local build is not universal; found: ${app_archs}." >&2
fi

if [[ "$RELEASE_MODE" == "1" ]]; then
  /usr/bin/codesign \
    --force \
    --options runtime \
    --timestamp \
    --sign "$SIGN_IDENTITY" \
    "${DIST_DIR}/DDump.app"
  /usr/bin/codesign --verify --deep --strict --verbose=2 "${DIST_DIR}/DDump.app"

  /bin/rm -f "$APP_NOTARY_ARCHIVE" "$APP_NOTARY_RESULT" "$APP_NOTARY_LOG"
  /usr/bin/ditto -c -k --keepParent "${DIST_DIR}/DDump.app" "$APP_NOTARY_ARCHIVE"
  xcrun notarytool submit "$APP_NOTARY_ARCHIVE" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait \
    --output-format json >"$APP_NOTARY_RESULT"
  app_submission_id="$(/usr/bin/plutil -extract id raw -o - "$APP_NOTARY_RESULT")"
  app_submission_status="$(/usr/bin/plutil -extract status raw -o - "$APP_NOTARY_RESULT")"
  if [[ -z "$app_submission_id" || "$app_submission_status" != "Accepted" ]]; then
    echo "DDump.app notarization was not accepted. See ${APP_NOTARY_RESULT}." >&2
    exit 1
  fi
  xcrun notarytool log "$app_submission_id" \
    --keychain-profile "$NOTARY_PROFILE" \
    "$APP_NOTARY_LOG"
  xcrun stapler staple "${DIST_DIR}/DDump.app"
  xcrun stapler validate "${DIST_DIR}/DDump.app"
  /usr/sbin/spctl --assess --type execute --verbose=4 "${DIST_DIR}/DDump.app"
  /bin/rm -f "$APP_NOTARY_ARCHIVE"
fi

# The signed installer app replaces the old downloaded .command file. It runs
# the existing per-user installer without Terminal and keeps the payload sealed
# inside the app's signed Resources directory.
rm -rf "$ROOT_DIR" "$PAYLOAD_DIR" "$DMG_PATH" "$DMG_NOTARY_RESULT" "$DMG_NOTARY_LOG"
mkdir -p "$ROOT_DIR" "${PAYLOAD_DIR}/bin" "${PAYLOAD_DIR}/config" "${PAYLOAD_DIR}/app"

cp -R "${PROJECT_DIR}/bin/." "${PAYLOAD_DIR}/bin/"
cp -R "${PROJECT_DIR}/config/." "${PAYLOAD_DIR}/config/"
cp "${PROJECT_DIR}/app/DDumpApp.swift" "${PAYLOAD_DIR}/app/DDumpApp.swift"
cp -R "${PROJECT_DIR}/app/Assets" "${PAYLOAD_DIR}/app/Assets"
cp -R "${DIST_DIR}/DDump.app" "${PAYLOAD_DIR}/app/DDump.app"
cp "${PROJECT_DIR}/README.md" "${PAYLOAD_DIR}/README.md"
cp "${PROJECT_DIR}/LICENSE" "${PAYLOAD_DIR}/LICENSE"

mkdir -p "${INSTALLER_APP}/Contents/MacOS" "${INSTALLER_APP}/Contents/Resources"
cp -R "$PAYLOAD_DIR" "${INSTALLER_APP}/Contents/Resources/Payload"
cp "${PROJECT_DIR}/app/Assets/AppIcon.icns" "${INSTALLER_APP}/Contents/Resources/AppIcon.icns"
if [[ "$RELEASE_MODE" == "1" ]]; then
  : >"${INSTALLER_APP}/Contents/Resources/PublicRelease"
fi

cat >"${INSTALLER_APP}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>Install DDump</string>
  <key>CFBundleDisplayName</key>
  <string>Install DDump</string>
  <key>NSHumanReadableCopyright</key>
  <string>Copyright © 2026 Chase Robertson</string>
  <key>CFBundleIdentifier</key>
  <string>com.ddump.app.installer</string>
  <key>CFBundleVersion</key>
  <string>${APP_VERSION}</string>
  <key>CFBundleShortVersionString</key>
  <string>${APP_VERSION}</string>
  <key>CFBundleExecutable</key>
  <string>InstallDDump</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>LSMinimumSystemVersion</key>
  <string>${MACOS_DEPLOYMENT_TARGET}</string>
</dict>
</plist>
PLIST

MACOS_SDK="$(xcrun --sdk macosx --show-sdk-path)"
BUILD_TMP="${DIST_DIR}/installer-swift-build"
rm -rf "$BUILD_TMP"
mkdir -p "$BUILD_TMP" /private/tmp/ddump-clang-cache

build_installer_slice() {
  local arch="$1"
  local out="$2"
  CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/private/tmp/ddump-clang-cache}" \
    swiftc \
      -sdk "$MACOS_SDK" \
      -target "${arch}-apple-macosx${MACOS_DEPLOYMENT_TARGET}" \
      -o "$out" \
      "${SCRIPT_DIR}/DDumpInstaller.swift"
}

build_installer_slice arm64 "${BUILD_TMP}/InstallDDump-arm64"
build_installer_slice x86_64 "${BUILD_TMP}/InstallDDump-x86_64"
lipo -create \
  "${BUILD_TMP}/InstallDDump-arm64" \
  "${BUILD_TMP}/InstallDDump-x86_64" \
  -output "${INSTALLER_APP}/Contents/MacOS/InstallDDump"
chmod +x "${INSTALLER_APP}/Contents/MacOS/InstallDDump"

if [[ "$RELEASE_MODE" == "1" ]]; then
  /usr/bin/codesign \
    --force \
    --options runtime \
    --timestamp \
    --sign "$SIGN_IDENTITY" \
    "$INSTALLER_APP"
  /usr/bin/codesign --verify --deep --strict --verbose=2 "$INSTALLER_APP"
fi

cat >"${ROOT_DIR}/README_FIRST.txt" <<TXT
DDump ${APP_VERSION}

1. Double-click "Install DDump".
2. Approve the install inside the installer app.
3. DDump opens from ~/Applications when installation finishes.

Cloud uploads are optional. Turn them on in Settings > Cloud if you want syncing.
TXT

hdiutil create \
  -volname "DDump ${APP_VERSION}" \
  -srcfolder "$ROOT_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

if [[ "$RELEASE_MODE" == "1" ]]; then
  /usr/bin/codesign \
    --force \
    --timestamp \
    --sign "$SIGN_IDENTITY" \
    "$DMG_PATH"
  /usr/bin/codesign --verify --strict --verbose=2 "$DMG_PATH"

  xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait \
    --output-format json >"$DMG_NOTARY_RESULT"

  submission_id="$(/usr/bin/plutil -extract id raw -o - "$DMG_NOTARY_RESULT")"
  submission_status="$(/usr/bin/plutil -extract status raw -o - "$DMG_NOTARY_RESULT")"
  if [[ -z "$submission_id" || "$submission_status" != "Accepted" ]]; then
    echo "DMG notarization was not accepted. See ${DMG_NOTARY_RESULT}." >&2
    exit 1
  fi
  xcrun notarytool log "$submission_id" \
    --keychain-profile "$NOTARY_PROFILE" \
    "$DMG_NOTARY_LOG"
  xcrun stapler staple "$DMG_PATH"
  xcrun stapler validate "$DMG_PATH"
  /usr/sbin/spctl --assess --type open \
    --context context:primary-signature \
    --verbose=4 \
    "$DMG_PATH"
  release_complete=1
  echo "Signed, notarized, stapled, and verified ${DMG_PATH}"
else
  echo "Packaged local unsigned test build ${DMG_PATH}"
  echo "This artifact is not for public distribution."
fi
