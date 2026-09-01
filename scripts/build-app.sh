#!/bin/bash
set -euo pipefail

PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
APP_VERSION="${DDUMP_VERSION:-0.3.18}"
APP_BUILD="${DDUMP_BUILD:-$APP_VERSION}"
MACOS_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.0}"
SPARKLE_ENABLED="${DDUMP_SPARKLE_ENABLED:-0}"
HELPER_MIGRATION_ENABLED="${DDUMP_HELPER_MIGRATION_ENABLED:-$SPARKLE_ENABLED}"
SPARKLE_PUBLIC_ED_KEY="${DDUMP_SPARKLE_PUBLIC_ED_KEY:-}"
UPDATE_CHANNEL="${DDUMP_UPDATE_CHANNEL:-stable}"
STABLE_FEED_URL="${DDUMP_STABLE_FEED_URL:-https://updates.ddump.app/stable/appcast.xml}"
BETA_FEED_URL="${DDUMP_BETA_FEED_URL:-https://updates.ddump.app/beta/appcast.xml}"
PAID_LAUNCH_ENABLED="${DDUMP_PAID_LAUNCH_ENABLED:-0}"
PAID_ENVIRONMENT="${DDUMP_PAID_ENVIRONMENT:-test}"
PAID_BUILD_FLAVOR="${DDUMP_PAID_BUILD_FLAVOR:-debug}"
SUPABASE_URL="${DDUMP_SUPABASE_URL:-}"
SUPABASE_PUBLISHABLE_KEY="${DDUMP_SUPABASE_PUBLISHABLE_KEY:-}"
ENTITLEMENT_ISSUER="${DDUMP_ENTITLEMENT_ISSUER:-https://api.ddump.app}"
ENTITLEMENT_AUDIENCE="${DDUMP_ENTITLEMENT_AUDIENCE:-com.ddump.app}"
ENTITLEMENT_PUBLIC_KEYS="${DDUMP_ENTITLEMENT_PUBLIC_KEYS:-}"
CHECK_EMAIL_URL="${DDUMP_CHECK_EMAIL_URL:-https://ddump.app/account/check-email}"
DIST_DIR="${PROJECT_DIR}/dist"
APP_BUNDLE="${DIST_DIR}/DDump.app"

if [[ "$SPARKLE_ENABLED" == "1" ]]; then
  SPARKLE_ENABLED_PLIST="<true/>"
else
  SPARKLE_ENABLED_PLIST="<false/>"
fi
if [[ "$HELPER_MIGRATION_ENABLED" == "1" ]]; then
  HELPER_MIGRATION_ENABLED_PLIST="<true/>"
else
  HELPER_MIGRATION_ENABLED_PLIST="<false/>"
fi
if [[ "$PAID_LAUNCH_ENABLED" == "1" ]]; then
  PAID_LAUNCH_ENABLED_PLIST="<true/>"
else
  PAID_LAUNCH_ENABLED_PLIST="<false/>"
fi

if [[ -z "${DEVELOPER_DIR:-}" && -d "/Applications/Xcode.app/Contents/Developer" ]]; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

SWIFTC="$(xcrun --find swiftc 2>/dev/null || command -v swiftc || true)"
if [[ -z "$SWIFTC" ]]; then
  echo "swiftc is required to build DDump.app." >&2
  exit 1
fi
MACOS_SDK="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
APP_SWIFT_SOURCES=("${PROJECT_DIR}/app/"*.swift "${PROJECT_DIR}/app/PaidLaunch/"*.swift)
SPARKLE_ROOT="$("${SCRIPT_DIR}/fetch-sparkle.sh")"
SPARKLE_FRAMEWORK="${SPARKLE_ROOT}/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"

rm -rf "$APP_BUNDLE"
mkdir -p "${APP_BUNDLE}/Contents/MacOS" "${APP_BUNDLE}/Contents/Resources" "${APP_BUNDLE}/Contents/Frameworks"
/usr/bin/ditto "$SPARKLE_FRAMEWORK" "${APP_BUNDLE}/Contents/Frameworks/Sparkle.framework"

cat >"${APP_BUNDLE}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>DDump</string>
  <key>CFBundleDisplayName</key>
  <string>DDump</string>
  <key>NSHumanReadableCopyright</key>
  <string>Copyright © 2026 Chase Robertson</string>
  <key>CFBundleIdentifier</key>
  <string>com.ddump.app</string>
  <key>CFBundleVersion</key>
  <string>${APP_BUILD}</string>
  <key>CFBundleShortVersionString</key>
  <string>${APP_VERSION}</string>
  <key>CFBundleExecutable</key>
  <string>DDump</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIconName</key>
  <string>AppIcon</string>
  <key>LSMinimumSystemVersion</key>
  <string>${MACOS_DEPLOYMENT_TARGET}</string>
  <key>SUFeedURL</key>
  <string>${STABLE_FEED_URL}</string>
  <key>SUPublicEDKey</key>
  <string>${SPARKLE_PUBLIC_ED_KEY}</string>
  <key>SUEnableAutomaticChecks</key>
  <false/>
  <key>SUAllowsAutomaticUpdates</key>
  <true/>
  <key>SUAutomaticallyUpdate</key>
  <false/>
  <key>SUEnableSystemProfiling</key>
  <false/>
  <key>SURequireSignedFeed</key>
  <true/>
  <key>SUVerifyUpdateBeforeExtraction</key>
  <true/>
  <key>DDumpSparkleEnabled</key>
  ${SPARKLE_ENABLED_PLIST}
  <key>DDumpHelperMigrationEnabled</key>
  ${HELPER_MIGRATION_ENABLED_PLIST}
  <key>DDumpUpdateChannel</key>
  <string>${UPDATE_CHANNEL}</string>
  <key>DDumpStableFeedURL</key>
  <string>${STABLE_FEED_URL}</string>
  <key>DDumpBetaFeedURL</key>
  <string>${BETA_FEED_URL}</string>
  <key>DDumpPaidLaunchEnabled</key>
  ${PAID_LAUNCH_ENABLED_PLIST}
  <key>DDumpPaidEnvironment</key>
  <string>${PAID_ENVIRONMENT}</string>
  <key>DDumpPaidBuildFlavor</key>
  <string>${PAID_BUILD_FLAVOR}</string>
  <key>DDumpSupabaseURL</key>
  <string>${SUPABASE_URL}</string>
  <key>DDumpSupabasePublishableKey</key>
  <string>${SUPABASE_PUBLISHABLE_KEY}</string>
  <key>DDumpEntitlementIssuer</key>
  <string>${ENTITLEMENT_ISSUER}</string>
  <key>DDumpEntitlementAudience</key>
  <string>${ENTITLEMENT_AUDIENCE}</string>
  <key>DDumpEntitlementPublicKeys</key>
  <string>${ENTITLEMENT_PUBLIC_KEYS}</string>
  <key>DDumpCheckEmailURL</key>
  <string>${CHECK_EMAIL_URL}</string>
  <key>DDumpAuthCallbackScheme</key>
  <string>ddump</string>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key>
      <string>com.ddump.app.auth</string>
      <key>CFBundleURLSchemes</key>
      <array><string>ddump</string></array>
    </dict>
  </array>
  <key>NSCalendarsFullAccessUsageDescription</key>
  <string>DDump uses calendar events to name shoot folders and resolve photo clusters between scheduled shoots.</string>
  <key>NSCalendarsUsageDescription</key>
  <string>DDump uses calendar events to name shoot folders and resolve photo clusters between scheduled shoots.</string>
</dict>
</plist>
PLIST

if [[ -f "${PROJECT_DIR}/app/Assets/AppIcon.icns" ]]; then
  cp "${PROJECT_DIR}/app/Assets/AppIcon.icns" "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"
fi

if [[ -f "${PROJECT_DIR}/app/PrivacyInfo.xcprivacy" ]]; then
  cp "${PROJECT_DIR}/app/PrivacyInfo.xcprivacy" "${APP_BUNDLE}/Contents/Resources/PrivacyInfo.xcprivacy"
fi

if [[ -d "${PROJECT_DIR}/app/Assets/Fonts" ]]; then
  mkdir -p "${APP_BUNDLE}/Contents/Resources/Fonts"
  cp "${PROJECT_DIR}/app/Assets/Fonts"/*.otf "${APP_BUNDLE}/Contents/Resources/Fonts/" 2>/dev/null || true
  cp "${PROJECT_DIR}/app/Assets/Fonts/OFL.txt" "${APP_BUNDLE}/Contents/Resources/Fonts/OFL.txt"
fi

for asset in logo-icon.png logo-icon-512.png logo-mark.svg; do
  if [[ -f "${PROJECT_DIR}/app/Assets/${asset}" ]]; then
    cp "${PROJECT_DIR}/app/Assets/${asset}" "${APP_BUNDLE}/Contents/Resources/${asset}"
  fi
done

"${SCRIPT_DIR}/prepare-helper-payload.sh" \
  "${APP_BUNDLE}/Contents/Resources/HelperPayload/current" \
  "$APP_VERSION" >/dev/null

mkdir -p /private/tmp/ddump-clang-cache
BUILD_TMP="${DIST_DIR}/swift-build"
rm -rf "$BUILD_TMP"
mkdir -p "$BUILD_TMP"

build_slice() {
  local arch="$1"
  local out="$2"
  local sdk_args=()
  if [[ -n "$MACOS_SDK" ]]; then
    sdk_args=(-sdk "$MACOS_SDK")
  fi
  CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/private/tmp/ddump-clang-cache}" \
    "$SWIFTC" -parse-as-library \
      "${sdk_args[@]}" \
      -target "${arch}-apple-macosx${MACOS_DEPLOYMENT_TARGET}" \
      -F "$(dirname "$SPARKLE_FRAMEWORK")" \
      -framework Sparkle \
      -Xlinker -rpath \
      -Xlinker @executable_path/../Frameworks \
      -o "$out" \
      "${APP_SWIFT_SOURCES[@]}"
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

mkdir -p "${APP_BUNDLE}/Contents/Resources/Helpers"
build_access_gate_slice() {
  local arch="$1"
  local out="$2"
  local sdk_args=()
  if [[ -n "$MACOS_SDK" ]]; then
    sdk_args=(-sdk "$MACOS_SDK")
  fi
  CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/private/tmp/ddump-clang-cache}" \
    "$SWIFTC" \
      "${sdk_args[@]}" \
      -target "${arch}-apple-macosx${MACOS_DEPLOYMENT_TARGET}" \
      -o "$out" \
      "${PROJECT_DIR}/helpers/DDumpAccessGateCore.swift" \
      "${PROJECT_DIR}/helpers/DDumpAccessGateMain.swift"
}

build_access_gate_slice arm64 "${BUILD_TMP}/DDumpAccessGate-arm64"
build_access_gate_slice x86_64 "${BUILD_TMP}/DDumpAccessGate-x86_64"
lipo -create \
  "${BUILD_TMP}/DDumpAccessGate-arm64" \
  "${BUILD_TMP}/DDumpAccessGate-x86_64" \
  -output "${APP_BUNDLE}/Contents/Resources/Helpers/DDumpAccessGate"
chmod +x "${APP_BUNDLE}/Contents/Resources/Helpers/DDumpAccessGate"

/usr/bin/touch "$APP_BUNDLE"
echo "Built ${APP_BUNDLE}"
