#!/bin/bash
set -euo pipefail

PATH="/usr/bin:/bin:/usr/sbin:/sbin"

STATUS_FILE="${1:-}"
CONTROL_DIR="${2:-}"
LOCK_DIR="${3:-}"

if [[ -z "$STATUS_FILE" || -z "$CONTROL_DIR" || -z "$LOCK_DIR" ]]; then
  echo "Usage: $(basename "$0") <status-file> <control-dir> <lock-dir>"
  exit 1
fi

PAUSE_FLAG="${CONTROL_DIR}/pause.flag"
VIEW_ONLY_FLAG="${CONTROL_DIR}/view_only.flag"
STOP_FLAG="${CONTROL_DIR}/stop_after_file.flag"
KEEP_MOUNTED_FLAG="${CONTROL_DIR}/keep_mounted.flag"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETTINGS_SCRIPT="${SCRIPT_DIR}/ddump-settings.sh"
DEBUG_SCRIPT="${SCRIPT_DIR}/ddump-debug-snapshot.sh"
APP_SUPPORT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DIAG_DIR="${APP_SUPPORT_DIR}/logs/diagnostics"

draw_bar() {
  local processed="$1"
  local total="$2"
  local width=40
  local filled=0
  if [[ "$total" =~ ^[0-9]+$ && "$total" -gt 0 && "$processed" =~ ^[0-9]+$ ]]; then
    filled=$(( processed * width / total ))
  fi
  (( filled < 0 )) && filled=0
  (( filled > width )) && filled=$width
  local empty=$(( width - filled ))
  printf '['
  printf '%*s' "$filled" '' | tr ' ' '#'
  printf '%*s' "$empty" '' | tr ' ' '-'
  printf ']'
}

read_status() {
  local key="$1"
  if [[ ! -f "$STATUS_FILE" ]]; then
    printf ''
    return
  fi
  local line
  line="$(/usr/bin/grep -E "^${key}=" "$STATUS_FILE" | /usr/bin/tail -n 1 || true)"
  line="${line#*=}"
  line="${line#\"}"
  line="${line%\"}"
  printf '%s' "$line"
}

format_eta() {
  local seconds="$1"
  if ! [[ "$seconds" =~ ^[0-9]+$ ]]; then
    printf -- '--'
    return
  fi
  if [[ "$seconds" -le 0 ]]; then
    printf '0s'
    return
  fi
  local h=$(( seconds / 3600 ))
  local m=$(( (seconds % 3600) / 60 ))
  local s=$(( seconds % 60 ))
  if [[ "$h" -gt 0 ]]; then
    printf '%dh %02dm' "$h" "$m"
  elif [[ "$m" -gt 0 ]]; then
    printf '%dm %02ds' "$m" "$s"
  else
    printf '%ds' "$s"
  fi
}

debug_notice=""

while true; do
  phase="$(read_status phase)"
  message="$(read_status message)"
  volume="$(read_status volume)"
  processed="$(read_status processed)"
  total="$(read_status total)"
  imported="$(read_status imported)"
  skipped="$(read_status skipped)"
  failed="$(read_status failed)"
  startup_cause="$(read_status startup_cause)"
  startup_volume="$(read_status startup_volume)"
  startup_path="$(read_status startup_path)"
  startup_uuid="$(read_status startup_uuid)"
  started_epoch="$(read_status started_epoch)"
  updated_at="$(read_status updated_at)"
  percent="0"
  eta="--"
  if [[ "$total" =~ ^[0-9]+$ && "$total" -gt 0 && "$processed" =~ ^[0-9]+$ ]]; then
    percent=$(( processed * 100 / total ))
    (( percent > 100 )) && percent=100
    if [[ "$processed" -gt 0 && "$started_epoch" =~ ^[0-9]+$ ]]; then
      now="$(/bin/date '+%s')"
      elapsed=$(( now - started_epoch ))
      (( elapsed < 1 )) && elapsed=1
      est_total=$(( elapsed * total / processed ))
      remaining=$(( est_total - elapsed ))
      (( remaining < 0 )) && remaining=0
      eta="$(format_eta "$remaining")"
    fi
  fi

  clear
  echo "DDump Monitor"
  echo ""
  echo "Startup Cause: ${startup_cause:--}"
  if [[ -n "$startup_volume" ]]; then
    echo "Startup Volume: ${startup_volume}"
  fi
  if [[ -n "$startup_path" ]]; then
    echo "Startup Path: ${startup_path}"
  fi
  if [[ -n "$startup_uuid" ]]; then
    echo "Startup UUID: ${startup_uuid}"
  fi
  echo ""
  echo "Phase: ${phase:-starting}"
  echo "Volume: ${volume:--}"
  echo "Updated: ${updated_at:--}"
  echo ""
  draw_bar "${processed:-0}" "${total:-0}"
  echo " ${processed:-0}/${total:-0} (${percent}%)"
  echo "ETA: ${eta}"
  echo ""
  echo "Imported: ${imported:-0}"
  echo "Skipped:  ${skipped:-0}"
  echo "Failed:   ${failed:-0}"
  echo ""
  echo "${message:-Waiting for status...}"
  echo ""
  if [[ -f "$KEEP_MOUNTED_FLAG" ]]; then
    keep_state="ON (card will stay mounted)"
  else
    keep_state="OFF (card will auto-eject on success)"
  fi
  echo "Keep Mounted: ${keep_state}"
  if [[ -f "$VIEW_ONLY_FLAG" ]]; then
    echo "View Only: ON (new automatic imports are blocked)"
  else
    echo "View Only: OFF"
  fi
  if [[ -n "$debug_notice" ]]; then
    echo "Debug: ${debug_notice}"
  fi
  echo "Controls: [p]ause  [r]esume  [s]top-after-current-file  [k]eep-mounted  [e]ject-when-done  [o]pen-settings  [d]ebug  [q]uit monitor"

  if [[ ! -d "$LOCK_DIR" && ( "$phase" == "complete" || "$phase" == "stopped" ) ]]; then
    echo ""
    echo "Run ended. Press q to close this monitor window."
  fi

  key=''
  if IFS= read -rsn1 -t 1 key; then
    case "$key" in
      p|P)
        /bin/mkdir -p "$CONTROL_DIR"
        /usr/bin/touch "$PAUSE_FLAG"
        ;;
      r|R)
        /bin/rm -f "$PAUSE_FLAG"
        ;;
      s|S)
        /bin/mkdir -p "$CONTROL_DIR"
        /usr/bin/touch "$STOP_FLAG"
        ;;
      k|K)
        /bin/mkdir -p "$CONTROL_DIR"
        /usr/bin/touch "$KEEP_MOUNTED_FLAG"
        ;;
      e|E)
        /bin/rm -f "$KEEP_MOUNTED_FLAG"
        ;;
      o|O)
        if [[ -x "$SETTINGS_SCRIPT" ]]; then
          /bin/bash "$SETTINGS_SCRIPT" >/dev/null 2>&1 &
        fi
        ;;
      d|D)
        if [[ -x "$DEBUG_SCRIPT" ]]; then
          /bin/bash "$DEBUG_SCRIPT" >/dev/null 2>&1 &
          latest_debug="$(/bin/ls -1t "${DIAG_DIR}"/ddump-debug-*.txt 2>/dev/null | /usr/bin/head -n 1 || true)"
          if [[ -n "$latest_debug" ]]; then
            debug_notice="$latest_debug"
          else
            debug_notice="snapshot requested"
          fi
        else
          debug_notice="script missing"
        fi
        ;;
      q|Q)
        exit 0
        ;;
    esac
  fi

done
