#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_SUPPORT="${HOME}/Library/Application Support/DDump"
USER_CONFIG="${APP_SUPPORT}/config.env"
APP_BUNDLE="${HOME}/Applications/DDump.app"

cd "$ROOT"

echo "== DDump public-readiness check =="

echo
echo "== Syntax =="
bash -n bin/ddump.sh bin/install.sh bin/ddump-calendar-lookup.sh bin/ddump-notify.sh
bash -n scripts/build-app.sh scripts/package-dmg.sh
git diff --check
grep -q 'DDUMP_RELEASE_MODE' scripts/package-dmg.sh
grep -q 'Developer ID Application:' scripts/package-dmg.sh
grep -q 'notarytool submit' scripts/package-dmg.sh
[[ "$(grep -c 'notarytool submit' scripts/package-dmg.sh)" -ge 2 ]]
grep -q 'stapler validate' scripts/package-dmg.sh
grep -q 'spctl --assess' scripts/package-dmg.sh
grep -q 'Install DDump.app' scripts/package-dmg.sh
grep -q 'PublicRelease' scripts/package-dmg.sh
grep -q 'Gatekeeper did not accept the installed app' scripts/DDumpInstaller.swift
grep -q '<string>3B52.1</string>' app/PrivacyInfo.xcprivacy
grep -q '<string>E174.1</string>' app/PrivacyInfo.xcprivacy
grep -q '<string>85F4.1</string>' app/PrivacyInfo.xcprivacy
grep -q 'SIL OPEN FONT LICENSE Version 1.1' app/Assets/Fonts/OFL.txt
grep -q 'Resources/Fonts/OFL.txt' scripts/build-app.sh
if grep -q 'Install DDump.command' scripts/package-dmg.sh; then
  echo "public installer regression: Terminal .command path returned" >&2
  exit 1
fi
if grep -q 'Contents/Resources/AppIcon.icns' app/DDumpApp.swift; then
  echo "public signature regression: app code modifies its sealed icon resource" >&2
  exit 1
fi
if /usr/bin/grep -ERq 'Install DDump\.command|Open Anyway' README.md SECURITY.md docs marketing.md; then
  echo "public documentation regression: unsigned installer instructions remain" >&2
  exit 1
fi
echo "ok"

echo
echo "== Delayed-mount regression guard =="
grep -q '^wait_for_camera_card_inventory()' bin/ddump.sh
grep -q '^camera_card_media_sample_count()' bin/ddump.sh
grep -q '^volume_has_camera_structure()' bin/ddump.sh
grep -q '^CAMERA_CARD_WAIT_FOR_STABLE_INVENTORY=' config/config.env
grep -q "add_missing_key 'CAMERA_CARD_WAIT_FOR_STABLE_INVENTORY'" bin/install.sh
wait_line="$(grep -n 'wait_for_camera_card_inventory "\$vol_name" "\$vol_path"' bin/ddump.sh | head -1 | cut -d: -f1)"
detection_line="$(grep -n 'volume_looks_like_camera_card "\$vol_path"' bin/ddump.sh | tail -1 | cut -d: -f1)"
[[ -n "$wait_line" && -n "$detection_line" && "$wait_line" -lt "$detection_line" ]]
echo "ok"

echo
echo "== Build =="
if [[ "${DDUMP_SKIP_MAC_BUILD:-0}" == "1" ]]; then
  echo "skipped by DDUMP_SKIP_MAC_BUILD (static checks only)"
else
  MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.0}" ./scripts/build-app.sh
  echo "ok"
fi

echo
echo "== Installed app =="
if [[ -d "$APP_BUNDLE" ]]; then
  /usr/bin/du -sh "$APP_BUNDLE"
  /usr/bin/shasum -a 256 "$APP_BUNDLE/Contents/MacOS/DDump"
else
  echo "not installed at $APP_BUNDLE"
fi

echo
echo "== Current user config =="
if [[ -f "$USER_CONFIG" ]]; then
  grep -E '^(ONBOARDING_COMPLETED|CLOUD_UPLOADS_ENABLED|GDRIVE_MOUNT_ENABLED|GDRIVE_DIRECT_UPLOAD|CALENDAR_PROVIDER|NTFY_NOTIFY_MOUNT_FAILED|MACOS_NOTIFICATIONS_ENABLED|MACOS_NOTIFY_MOUNT_FAILED|REBUCKET_PRESERVE_SOURCE_FOLDERS|UPDATE_CHECKS_ENABLED|AUTO_UPDATES_ENABLED)=' "$USER_CONFIG" || true
else
  echo "missing user config: $USER_CONFIG"
fi

echo
echo "== LaunchAgents =="
uid="$(id -u)"
for label in com.ddump com.ddump.network-watch com.ddump.rclone-gdrive com.ddump.rclone-gdrive.legacy com.ddump.cloud-idle-watch; do
  if launchctl print "gui/${uid}/${label}" >/dev/null 2>&1; then
    echo "${label}: loaded"
  else
    echo "${label}: not loaded"
  fi
done

echo
echo "== Public default expectations =="
fail=0
expect_config() {
  local key="$1" expected="$2"
  local value=""
  value="$(awk -F= -v k="$key" '$1 == k { v=$2 } END { gsub(/^"|"$/, "", v); print v }' config/config.env)"
  if [[ "$value" == "$expected" ]]; then
    echo "ok: ${key}=${expected}"
  else
    echo "error: shipped ${key} is '${value:-missing}', expected '${expected}'"
    fail=1
  fi
}

expect_config "ONBOARDING_COMPLETED" "0"
expect_config "GDRIVE_MOUNT_ENABLED" "0"
expect_config "NTFY_NOTIFY_MOUNT_FAILED" "0"
expect_config "MACOS_NOTIFICATIONS_ENABLED" "1"
expect_config "MACOS_NOTIFY_MOUNT_FAILED" "0"
expect_config "REBUCKET_PRESERVE_SOURCE_FOLDERS" "0"

if launchctl print "gui/${uid}/com.ddump.rclone-gdrive" >/dev/null 2>&1; then
  echo "note: this developer account currently has the optional managed cloud mount agent loaded"
fi

if [[ "$fail" == "0" ]]; then
  echo
  echo "Public-readiness check passed."
else
  echo
  echo "Public-readiness check failed."
  exit 1
fi
