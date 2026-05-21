#!/bin/bash
# DDump calendar lookup helper.
#
# Queries Google Calendar via `gcalcli` and emits events for a given date as TSV:
#
#   <start_epoch>\t<end_epoch>\t<event_title>
#
# Requires gcalcli to be installed and authenticated:
#   brew install gcalcli
#   gcalcli list                  # first run prompts OAuth in browser
#
# Usage:
#   ddump-calendar-lookup.sh --date YYYY-MM-DD [--calendar "Name"]
#
# Configurable via env:
#   DDUMP_CALENDAR_NAME           default calendar name (blank = primary)
#   DDUMP_CALENDAR_DAY_WINDOW     extend window by N hours each side (default 1)

set -euo pipefail

PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

DATE=""
CAL_NAME="${DDUMP_CALENDAR_NAME:-}"
DAY_WINDOW_HRS="${DDUMP_CALENDAR_DAY_WINDOW:-1}"

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

if ! command -v gcalcli >/dev/null 2>&1; then
  echo "ERROR: gcalcli not installed. Run: brew install gcalcli" >&2
  exit 3
fi

# Build the window. gcalcli's --tsv lists events in [start, end).
start_date="$(date -j -v-${DAY_WINDOW_HRS}H -f '%Y-%m-%d %H:%M:%S' "${DATE} 00:00:00" '+%Y-%m-%d %H:%M:%S' 2>/dev/null \
              || date -d "${DATE} 00:00:00 -${DAY_WINDOW_HRS} hour" '+%Y-%m-%d %H:%M:%S' 2>/dev/null \
              || echo "${DATE} 00:00:00")"
end_date="$(date -j -v+${DAY_WINDOW_HRS}H -f '%Y-%m-%d %H:%M:%S' "${DATE} 23:59:59" '+%Y-%m-%d %H:%M:%S' 2>/dev/null \
            || date -d "${DATE} 23:59:59 +${DAY_WINDOW_HRS} hour" '+%Y-%m-%d %H:%M:%S' 2>/dev/null \
            || echo "${DATE} 23:59:59")"

cal_args=()
if [[ -n "$CAL_NAME" ]]; then
  cal_args+=(--calendar "$CAL_NAME")
fi

# gcalcli --tsv output columns: start_date, start_time, end_date, end_time, title, [link]
gcalcli "${cal_args[@]}" agenda "$start_date" "$end_date" --tsv 2>/dev/null \
| while IFS=$'\t' read -r s_date s_time e_date e_time title rest; do
    [[ -z "$s_date" ]] && continue
    if [[ -z "$s_time" ]]; then
      s_time="00:00"
    fi
    if [[ -z "$e_time" ]]; then
      e_time="23:59"
    fi
    if [[ -z "$e_date" ]]; then
      e_date="$s_date"
    fi
    s_epoch="$(date -j -f '%Y-%m-%d %H:%M' "${s_date} ${s_time}" '+%s' 2>/dev/null \
               || date -d "${s_date} ${s_time}" '+%s' 2>/dev/null \
               || true)"
    e_epoch="$(date -j -f '%Y-%m-%d %H:%M' "${e_date} ${e_time}" '+%s' 2>/dev/null \
               || date -d "${e_date} ${e_time}" '+%s' 2>/dev/null \
               || true)"
    if [[ -n "$s_epoch" && -n "$e_epoch" ]]; then
      printf '%s\t%s\t%s\n' "$s_epoch" "$e_epoch" "$title"
    fi
  done
