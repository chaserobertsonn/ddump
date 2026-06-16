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
#   DDUMP_CALENDAR_ICS_URL        override private ICS/webcal URL for tests/runs
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
APPLE_CACHE_FILE="${APP_SUPPORT_DIR}/state/calendar_events.tsv"
ICS_URL="${DDUMP_CALENDAR_ICS_URL:-${CALENDAR_ICS_URL:-}}"

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

emit_apple_cache_events() {
  local cache_file="${DDUMP_APPLE_CALENDAR_CACHE:-$APPLE_CACHE_FILE}"
  [[ -f "$cache_file" ]] || {
    echo "ERROR: Mac Calendar cache is missing. Open DDump > Settings > Calendar and refresh Mac Calendar events." >&2
    return 4
  }

  /usr/bin/awk -F '\t' -v date="$DATE" -v cal_filter="$CAL_NAME" '
    BEGIN { filter = tolower(cal_filter) }
    /^#/ || NF < 5 { next }
    {
      cal = $4
      title = $5
      if (filter != "" && index(tolower(cal), filter) == 0) next
      if ($3 == date) print $1 "\t" $2 "\t" title
    }
  ' "$cache_file"
}

emit_ics_events() {
  local url="$ICS_URL"
  [[ -n "$url" ]] || {
    echo "ERROR: calendar link is empty." >&2
    return 4
  }

  /usr/bin/python3 - "$DATE" "$url" "$DAY_WINDOW_HRS" <<'PY'
import datetime as dt
import sys
import urllib.request
from zoneinfo import ZoneInfo

target = dt.date.fromisoformat(sys.argv[1])
url = sys.argv[2]
day_window = int(sys.argv[3] or "1")
local_tz = dt.datetime.now().astimezone().tzinfo or ZoneInfo("UTC")

try:
    with urllib.request.urlopen(url, timeout=15) as response:
        raw = response.read().decode("utf-8", errors="replace")
except Exception as exc:
    print(f"ERROR: calendar link fetch failed: {exc}", file=sys.stderr)
    sys.exit(4)

if "BEGIN:VCALENDAR" not in raw:
    print("ERROR: calendar link did not return an ICS calendar.", file=sys.stderr)
    sys.exit(4)

unfolded = []
for line in raw.replace("\r\n", "\n").replace("\r", "\n").split("\n"):
    if line.startswith((" ", "\t")) and unfolded:
        unfolded[-1] += line[1:]
    else:
        unfolded.append(line)

def parse_dt(value: str):
    value = value.strip()
    if not value:
        return None
    if value.endswith("Z"):
        return dt.datetime.strptime(value, "%Y%m%dT%H%M%SZ").replace(tzinfo=dt.timezone.utc).astimezone(local_tz)
    if "T" in value:
        parsed = dt.datetime.strptime(value[:15], "%Y%m%dT%H%M%S")
        return parsed.replace(tzinfo=local_tz)
    parsed_date = dt.datetime.strptime(value[:8], "%Y%m%d").date()
    return dt.datetime.combine(parsed_date, dt.time.min, tzinfo=local_tz)

events = []
inside = False
current = {}
for line in unfolded:
    if line == "BEGIN:VEVENT":
        inside = True
        current = {}
        continue
    if line == "END:VEVENT" and inside:
        start = current.get("DTSTART")
        end = current.get("DTEND")
        title = current.get("SUMMARY", "Calendar Event").strip() or "Calendar Event"
        if start:
            start_dt = parse_dt(start)
            end_dt = parse_dt(end) if end else None
            if start_dt:
                if not end_dt or end_dt < start_dt:
                    end_dt = start_dt + dt.timedelta(hours=1)
                events.append((start_dt, end_dt, title.replace("\t", " ").replace("\n", " ")))
        inside = False
        current = {}
        continue
    if inside and ":" in line:
        name, value = line.split(":", 1)
        key = name.split(";", 1)[0].upper()
        if key in {"DTSTART", "DTEND", "SUMMARY"}:
            current[key] = value

window_start = dt.datetime.combine(target, dt.time.min, tzinfo=local_tz) - dt.timedelta(hours=day_window)
window_end = dt.datetime.combine(target + dt.timedelta(days=1), dt.time.min, tzinfo=local_tz) + dt.timedelta(hours=day_window)
for start, end, title in sorted(events, key=lambda item: item[0]):
    if end >= window_start and start <= window_end:
        print(f"{int(start.timestamp())}\t{int(end.timestamp())}\t{title}")
PY
}

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
  apple)
    emit_apple_cache_events
    ;;
  ics)
    emit_ics_events
    ;;
  *)
    echo "ERROR: unknown calendar provider: $PROVIDER" >&2
    exit 4
    ;;
esac
