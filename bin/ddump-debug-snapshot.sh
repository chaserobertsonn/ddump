#!/bin/bash
set -euo pipefail

PATH="/usr/bin:/bin:/usr/sbin:/sbin"

APP_SUPPORT_DIR="${HOME}/Library/Application Support/DDump"
LOG_DIR="${APP_SUPPORT_DIR}/logs"
STATE_DIR="${APP_SUPPORT_DIR}/state"
CONFIG_FILE="${APP_SUPPORT_DIR}/config.env"
STATUS_FILE="${STATE_DIR}/run_status.env"
OUT_DIR="${LOG_DIR}/diagnostics"
STAMP="$(/bin/date '+%Y%m%d-%H%M%S')"
OUT_FILE="${OUT_DIR}/ddump-debug-${STAMP}.txt"

/bin/mkdir -p "$OUT_DIR"

{
  echo "DDump Debug Snapshot"
  echo "Generated: $(/bin/date '+%Y-%m-%d %H:%M:%S %Z')"
  echo ""

  echo "=== Config (core toggles) ==="
  if [[ -f "$CONFIG_FILE" ]]; then
    /usr/bin/egrep '^(TRUSTED_NAME_PREFIX|AUTO_TRUST_PREFIX|PROMPT_FOR_UNKNOWN_CARD_ACTION|SKIP_INTERNAL_VOLUMES|IGNORE_VOLUME_NAMES|IGNORE_NO_UUID_VOLUMES|SHOW_PROGRESS_WINDOW|PROMPT_NO_EJECT_ON_START|EJECT_ON_SUCCESS|MANIFEST_RETENTION_DAYS)=' "$CONFIG_FILE" || true
  else
    echo "Missing: $CONFIG_FILE"
  fi
  echo ""

  echo "=== /Volumes ==="
  /bin/ls -la /Volumes || true
  echo ""

  echo "=== Volume Details ==="
  for vol in /Volumes/*; do
    [[ -d "$vol" ]] || continue
    name="$(/usr/bin/basename "$vol")"
    uuid="$(/usr/sbin/diskutil info "$vol" 2>/dev/null | /usr/bin/awk -F': *' '/Volume UUID/ {print $2; exit}' | /usr/bin/xargs)"
    internal="$(/usr/sbin/diskutil info "$vol" 2>/dev/null | /usr/bin/awk -F': *' '/^ *Internal/ {print $2; exit}' | /usr/bin/xargs)"
    location="$(/usr/sbin/diskutil info "$vol" 2>/dev/null | /usr/bin/awk -F': *' '/Device Location/ {print $2; exit}' | /usr/bin/xargs)"
    protocol="$(/usr/sbin/diskutil info "$vol" 2>/dev/null | /usr/bin/awk -F': *' '/Protocol/ {print $2; exit}' | /usr/bin/xargs)"
    mount_point="$(/usr/sbin/diskutil info "$vol" 2>/dev/null | /usr/bin/awk -F': *' '/Mount Point/ {print $2; exit}' | /usr/bin/xargs)"
    echo "${name} | path=${vol} | uuid=${uuid:-none} | internal=${internal:-unknown} | location=${location:-unknown} | protocol=${protocol:-unknown} | mount=${mount_point:-unknown}"
  done
  echo ""

  echo "=== Trusted UUIDs ==="
  /bin/cat "${STATE_DIR}/trusted_uuids.txt" 2>/dev/null || true
  echo ""

  echo "=== Blocked UUIDs ==="
  /bin/cat "${STATE_DIR}/blocked_uuids.txt" 2>/dev/null || true
  echo ""

  echo "=== Current Status File ==="
  /bin/cat "$STATUS_FILE" 2>/dev/null || true
  echo ""

  echo "=== Last 160 DDump Log Lines ==="
  /usr/bin/tail -n 160 "${LOG_DIR}/ddump.log" 2>/dev/null || true
  echo ""

  echo "=== Last 80 launchd.err.log Lines ==="
  /usr/bin/tail -n 80 "${LOG_DIR}/launchd.err.log" 2>/dev/null || true
} >"$OUT_FILE"

echo "DDump debug snapshot saved:"
echo "$OUT_FILE"
echo ""
echo "Last 40 lines:"
/usr/bin/tail -n 40 "$OUT_FILE"
