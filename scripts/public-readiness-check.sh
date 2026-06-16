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
git diff --check
echo "ok"

echo
echo "== Build =="
MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.0}" ./scripts/build-app.sh
echo "ok"

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
  grep -E '^(ONBOARDING_COMPLETED|CLOUD_UPLOADS_ENABLED|GDRIVE_MOUNT_ENABLED|GDRIVE_DIRECT_UPLOAD|CALENDAR_PROVIDER|NTFY_NOTIFY_MOUNT_FAILED|MACOS_NOTIFY_MOUNT_FAILED|REBUCKET_PRESERVE_SOURCE_FOLDERS|UPDATE_CHECKS_ENABLED|AUTO_UPDATES_ENABLED)=' "$USER_CONFIG" || true
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
  if [[ -f "$USER_CONFIG" ]]; then
    value="$(awk -F= -v k="$key" '$1 == k { v=$2 } END { gsub(/^"|"$/, "", v); print v }' "$USER_CONFIG")"
  fi
  if [[ "$value" == "$expected" ]]; then
    echo "ok: ${key}=${expected}"
  else
    echo "warn: ${key} is '${value:-missing}', expected '${expected}' for public-test baseline"
    fail=1
  fi
}

expect_config "ONBOARDING_COMPLETED" "1"
expect_config "GDRIVE_MOUNT_ENABLED" "0"
expect_config "NTFY_NOTIFY_MOUNT_FAILED" "0"
expect_config "MACOS_NOTIFY_MOUNT_FAILED" "0"
expect_config "REBUCKET_PRESERVE_SOURCE_FOLDERS" "0"

if launchctl print "gui/${uid}/com.ddump.rclone-gdrive" >/dev/null 2>&1; then
  echo "warn: managed cloud mount agent is loaded; public-test baseline should use synced-folder/direct handoff"
  fail=1
fi

if [[ "$fail" == "0" ]]; then
  echo
  echo "Public-readiness check passed."
else
  echo
  echo "Public-readiness check completed with warnings."
fi

