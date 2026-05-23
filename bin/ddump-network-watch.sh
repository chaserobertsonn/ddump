#!/bin/bash
set -euo pipefail

PATH="/usr/bin:/bin:/usr/sbin:/sbin"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_SUPPORT_DIR="${HOME}/Library/Application Support/DDump"
STATE_DIR="${APP_SUPPORT_DIR}/state"
LOG_DIR="${APP_SUPPORT_DIR}/logs"
DEFAULT_CONFIG_PATH="${SCRIPT_DIR}/../config/config.env"
USER_CONFIG_PATH="${APP_SUPPORT_DIR}/config.env"
MAIN_SCRIPT="${APP_SUPPORT_DIR}/bin/ddump.sh"
LOG_FILE="${LOG_DIR}/ddump-network-watch.log"
PENDING_DIR="${STATE_DIR}/pending_uploads"

NETWORK_RESUME_ENABLED="1"
NETWORK_RESUME_CHECK_SECONDS="20"
NETWORK_RESUME_COOLDOWN_SECONDS="120"

if [[ -f "$DEFAULT_CONFIG_PATH" ]]; then
  # shellcheck disable=SC1090
  source "$DEFAULT_CONFIG_PATH"
fi
if [[ -f "$USER_CONFIG_PATH" ]]; then
  # shellcheck disable=SC1090
  source "$USER_CONFIG_PATH"
fi

mkdir -p "$STATE_DIR" "$LOG_DIR" "$PENDING_DIR"

log() {
  local msg="$1"
  /bin/echo "$(/bin/date '+%Y-%m-%d %H:%M:%S') ${msg}" >>"$LOG_FILE"
}

sanitize_positive_int() {
  local raw="$1"
  local fallback="$2"
  if ! [[ "$raw" =~ ^[0-9]+$ ]]; then
    printf '%s' "$fallback"
    return
  fi
  printf '%s' "$raw"
}

network_online() {
  /usr/sbin/scutil -r 1.1.1.1 2>/dev/null | /usr/bin/grep -q "Reachable"
}

pending_uploads_exist() {
  local f
  for f in "$PENDING_DIR"/pending.*.tsv; do
    [[ -s "$f" ]] && return 0
  done
  return 1
}

trigger_retry() {
  [[ -x "$MAIN_SCRIPT" ]] || return 1
  /bin/bash "$MAIN_SCRIPT" >/dev/null 2>&1 &
  return 0
}

check_seconds="$(sanitize_positive_int "${NETWORK_RESUME_CHECK_SECONDS:-20}" "20")"
if [[ "$check_seconds" -lt 5 ]]; then
  check_seconds=5
fi
cooldown_seconds="$(sanitize_positive_int "${NETWORK_RESUME_COOLDOWN_SECONDS:-120}" "120")"
if [[ "$cooldown_seconds" -lt 30 ]]; then
  cooldown_seconds=30
fi

prev_online=0
if network_online; then
  prev_online=1
fi
last_trigger_epoch=0

log "Network watcher started (enabled=${NETWORK_RESUME_ENABLED:-1}, interval=${check_seconds}s, cooldown=${cooldown_seconds}s)."

while true; do
  if [[ "${NETWORK_RESUME_ENABLED:-1}" != "1" ]]; then
    /bin/sleep "$check_seconds"
    continue
  fi

  current_online=0
  if network_online; then
    current_online=1
  fi

  if [[ "$current_online" -eq 1 && "$prev_online" -eq 0 ]]; then
    if pending_uploads_exist; then
      now_epoch="$(/bin/date '+%s')"
      if [[ $((now_epoch - last_trigger_epoch)) -ge "$cooldown_seconds" ]]; then
        if trigger_retry; then
          last_trigger_epoch="$now_epoch"
          log "Internet reconnected; pending uploads detected. Triggered ddump retry."
        else
          log "Internet reconnected; retry trigger failed (main script missing)."
        fi
      fi
    else
      log "Internet reconnected; no pending uploads found."
    fi
  fi

  prev_online="$current_online"
  /bin/sleep "$check_seconds"
done
