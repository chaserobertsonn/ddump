#!/bin/bash
# DDump calendar lookup helper.
#
# Emits calendar events for a given date as TSV:
#
#   <start_epoch>\t<end_epoch>\t<event_title>
#
# Public app setup happens from DDump's Calendar settings wizard; users should
# not need to run Terminal commands. Google Calendar uses DDump's bundled
# read-only OAuth helper.
#
# Usage:
#   ddump-calendar-lookup.sh --date YYYY-MM-DD [--calendar "Name"]
#
# Configurable via env:
#   DDUMP_CALENDAR_NAME           default calendar name (blank = primary)
#   DDUMP_CALENDAR_DAY_WINDOW     extend window by N hours each side (default 1)
#   GOOGLE_CALENDAR_CLIENT_ID     Google desktop OAuth client ID

set -euo pipefail

PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

APP_SUPPORT_DIR="${HOME}/Library/Application Support/DDump"
CONFIG_FILE="${APP_SUPPORT_DIR}/config.env"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
fi

DATE=""
CAL_NAME="${DDUMP_CALENDAR_NAME:-}"
DAY_WINDOW_HRS="${DDUMP_CALENDAR_DAY_WINDOW:-1}"
PROVIDER="${DDUMP_CALENDAR_PROVIDER:-${CALENDAR_PROVIDER:-google}}"
CLIENT_ID="${GOOGLE_CALENDAR_CLIENT_ID:-570098546449-737pvkselaqtncp2e6kdmhkf55eemche.apps.googleusercontent.com}"
CLIENT_SECRET="${GOOGLE_CALENDAR_CLIENT_SECRET:-}"

while [[ "${1:-}" ]]; do
  case "$1" in
    --date) DATE="$2"; shift 2 ;;
    --calendar) CAL_NAME="$2"; shift 2 ;;
    --help|-h)
      echo "Usage: $(basename "$0") --date YYYY-MM-DD [--calendar \"Calendar Name\"]"
      exit 0
      ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$DATE" ]]; then
  echo "ERROR: --date is required (YYYY-MM-DD)" >&2
  exit 2
fi

case "$PROVIDER" in
  google)
    helper="${SCRIPT_DIR}/ddump-google-calendar.py"
    if [[ ! -x "$helper" ]]; then
      echo "ERROR: bundled Google Calendar helper is missing: $helper" >&2
      exit 3
    fi
    args=(--client-id "$CLIENT_ID" --client-secret "$CLIENT_SECRET" events --date "$DATE" --day-window "$DAY_WINDOW_HRS")
    if [[ -n "$CAL_NAME" ]]; then
      args+=(--calendar "$CAL_NAME")
    fi
    "$helper" "${args[@]}"
    ;;
  none|"")
    echo "ERROR: calendar provider is not connected." >&2
    exit 4
    ;;
  apple|ics)
    echo "ERROR: ${PROVIDER} calendar lookup backend is not implemented yet. Use Google Calendar for calendar naming." >&2
    exit 4
    ;;
  *)
    echo "ERROR: unknown calendar provider: $PROVIDER" >&2
    exit 4
    ;;
esac
