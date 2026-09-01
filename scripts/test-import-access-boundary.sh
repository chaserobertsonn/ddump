#!/bin/bash
set -euo pipefail

PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/ddump-import-gate.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

TEST_HOME="${TEST_ROOT}/home"
APP_SUPPORT="${TEST_HOME}/Library/Application Support/DDump"
mkdir -p "$APP_SUPPORT"
chmod 700 "$TEST_HOME" "$APP_SUPPORT"

cat >"${APP_SUPPORT}/config.env" <<'CONFIG'
PAID_ACCESS_ENFORCEMENT="1"
ENTITLEMENT_PUBLIC_KEYS=""
ENABLE_NOTIFICATIONS="0"
MACOS_NOTIFICATIONS_ENABLED="0"
DB_ENABLED="0"
CREATE_DAILY_FOLDER="0"
ENABLE_POST_EJECT_MOVE="0"
CONFIG
chmod 600 "${APP_SUPPORT}/config.env"

HOME="$TEST_HOME" /bin/bash "${PROJECT_DIR}/bin/ddump.sh"

STATUS_FILE="${APP_SUPPORT}/state/run_status.env"
LOG_FILE="${APP_SUPPORT}/logs/ddump.log"
grep -q '^phase="access_required"$' "$STATUS_FILE"
grep -q 'connected cards remain mounted and untouched' "$LOG_FILE"
if [[ -d "${APP_SUPPORT}/state/run.lock" ]]; then
  echo "FAIL: run lock was not released after denied new-import check." >&2
  exit 1
fi

gate_line="$(grep -n 'ddump_authorize_new_import' "${PROJECT_DIR}/bin/ddump.sh" | tail -1 | cut -d: -f1)"
volume_line="$(grep -n 'for queued_vol_path in /Volumes/' "${PROJECT_DIR}/bin/ddump.sh" | head -1 | cut -d: -f1)"
if [[ -z "$gate_line" || -z "$volume_line" || "$gate_line" -ge "$volume_line" ]]; then
  echo "FAIL: shared authorization gate must execute before volume discovery." >&2
  exit 1
fi

echo "PASS: direct helper invocation fails closed before card discovery"
