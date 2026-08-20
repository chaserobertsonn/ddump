#!/bin/bash
set -euo pipefail

PATH="/usr/bin:/bin:/usr/sbin:/sbin"

APP_SUPPORT_DIR="${HOME}/Library/Application Support/DDump"
STATE_DIR="${APP_SUPPORT_DIR}/state"
CONTROL_DIR="${STATE_DIR}/control"
PAUSE_FLAG="${CONTROL_DIR}/pause.flag"
VIEW_ONLY_FLAG="${CONTROL_DIR}/view_only.flag"
STOP_FLAG="${CONTROL_DIR}/stop_after_file.flag"
KEEP_MOUNTED_FLAG="${CONTROL_DIR}/keep_mounted.flag"
LOCK_DIR="${STATE_DIR}/run.lock"
SETTINGS_SCRIPT="${APP_SUPPORT_DIR}/bin/ddump-settings.sh"
DEBUG_SCRIPT="${APP_SUPPORT_DIR}/bin/ddump-debug-snapshot.sh"

usage() {
  cat <<USAGE
Usage: $(basename "$0") <pause|resume|view-only|auto-import|stop|keep-mounted|eject-when-done|settings|debug|status>
USAGE
}

cmd="${1:-}"
if [[ -z "$cmd" ]]; then
  usage
  exit 1
fi

/bin/mkdir -p "$CONTROL_DIR"

case "$cmd" in
  pause)
    /usr/bin/touch "$PAUSE_FLAG"
    echo "DDump paused (it will pause before the next file starts)."
    ;;
  resume)
    /bin/rm -f "$PAUSE_FLAG"
    echo "DDump resumed."
    ;;
  view-only)
    /usr/bin/touch "$VIEW_ONLY_FLAG"
    echo "View Only is on. Newly connected cards and drives will stay untouched and mounted."
    ;;
  auto-import)
    /bin/rm -f "$VIEW_ONLY_FLAG"
    echo "View Only is off. Automatic card import is enabled."
    ;;
  stop)
    /usr/bin/touch "$STOP_FLAG"
    echo "DDump will stop after the current file completes."
    ;;
  keep-mounted)
    /usr/bin/touch "$KEEP_MOUNTED_FLAG"
    echo "DDump will keep the current card mounted after import."
    ;;
  eject-when-done)
    /bin/rm -f "$KEEP_MOUNTED_FLAG"
    echo "DDump will eject card after import success."
    ;;
  settings)
    if [[ -x "$SETTINGS_SCRIPT" ]]; then
      /bin/bash "$SETTINGS_SCRIPT"
    else
      echo "Settings script not found: $SETTINGS_SCRIPT"
      exit 1
    fi
    ;;
  debug)
    if [[ -x "$DEBUG_SCRIPT" ]]; then
      /bin/bash "$DEBUG_SCRIPT"
    else
      echo "Debug script not found: $DEBUG_SCRIPT"
      exit 1
    fi
    ;;
  status)
    if [[ -d "$LOCK_DIR" ]]; then
      echo "Run status: active"
    else
      echo "Run status: idle"
    fi
    if [[ -f "$PAUSE_FLAG" ]]; then
      echo "Pause flag: on"
    else
      echo "Pause flag: off"
    fi
    if [[ -f "$VIEW_ONLY_FLAG" ]]; then
      echo "View Only: on (automatic imports blocked)"
    else
      echo "View Only: off"
    fi
    if [[ -f "$STOP_FLAG" ]]; then
      echo "Stop flag: on"
    else
      echo "Stop flag: off"
    fi
    if [[ -f "$KEEP_MOUNTED_FLAG" ]]; then
      echo "Keep-mounted flag: on"
    else
      echo "Keep-mounted flag: off"
    fi
    ;;
  *)
    usage
    exit 1
    ;;
esac
