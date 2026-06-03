#!/bin/bash
set -euo pipefail

PATH="$HOME/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

APP_SUPPORT_DIR="$HOME/Library/Application Support/DDump"
CONFIG_FILE="$APP_SUPPORT_DIR/config.env"
LOG_DIR="$APP_SUPPORT_DIR/logs"
STATE_DIR="$APP_SUPPORT_DIR/state"
CONTROL_DIR="$STATE_DIR/control"
KEEPALIVE_FILE="$CONTROL_DIR/app_cloud_keepalive.touch"
RUN_LOCK_DIR="$STATE_DIR/run.lock"
CLOUD_MOUNT_LOCK_DIR="$STATE_DIR/cloud-mount-start.lock"
RCLONE_MOUNT_LOCK_DIR="$STATE_DIR/rclone-mount.lock"
LOG="$LOG_DIR/rclone-gdrive.log"

GDRIVE_MOUNT_ENABLED="0"
GDRIVE_DIRECT_UPLOAD="1"
GDRIVE_MOUNT_POINT="$HOME/GoogleDrive"
GDRIVE_MOUNT_LABEL="com.ddump.rclone-gdrive"
CLOUD_IDLE_UNMOUNT_SECONDS="180"

expand_user_path() {
  local raw="$1"
  raw="${raw/#\\\$HOME/$HOME}"
  raw="${raw/#\$HOME/$HOME}"
  raw="${raw/#\~/$HOME}"
  printf '%s' "$raw"
}

if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
fi

mkdir -p "$LOG_DIR" "$CONTROL_DIR"
[[ "${GDRIVE_MOUNT_ENABLED:-0}" == "1" ]] || exit 0
[[ "${GDRIVE_DIRECT_UPLOAD:-1}" != "1" ]] || exit 0

MOUNT="$(expand_user_path "${GDRIVE_MOUNT_POINT:-$HOME/GoogleDrive}")"
LABEL="${GDRIVE_MOUNT_LABEL:-com.ddump.rclone-gdrive}"
IDLE_SECONDS="${CLOUD_IDLE_UNMOUNT_SECONDS:-180}"
if ! [[ "$IDLE_SECONDS" =~ ^[0-9]+$ ]] || [[ "$IDLE_SECONDS" -lt 60 ]]; then
  IDLE_SECONDS="180"
fi

mount_entry_exists() {
  /sbin/mount | /usr/bin/grep -q " on ${MOUNT} "
}

lock_active() {
  local lock_dir="$1"
  local pid_file="${lock_dir}/pid"
  local pid=""
  [[ -d "$lock_dir" ]] || return 1
  pid="$(/bin/cat "$pid_file" 2>/dev/null || true)"
  if [[ "$pid" =~ ^[0-9]+$ ]] && /bin/kill -0 "$pid" >/dev/null 2>&1; then
    return 0
  fi
  /bin/rm -f "$pid_file" >/dev/null 2>&1 || true
  /bin/rmdir "$lock_dir" >/dev/null 2>&1 || true
  return 1
}

run_active() {
  if lock_active "$RUN_LOCK_DIR"; then
    return 0
  fi
  if lock_active "$CLOUD_MOUNT_LOCK_DIR" || lock_active "$RCLONE_MOUNT_LOCK_DIR"; then
    return 0
  fi
  /usr/bin/pgrep -f "${APP_SUPPORT_DIR}/bin/ddump.sh" >/dev/null 2>&1
}

app_recently_alive() {
  [[ -f "$KEEPALIVE_FILE" ]] || return 1
  local mtime now
  mtime="$(/usr/bin/stat -f '%m' "$KEEPALIVE_FILE" 2>/dev/null || echo 0)"
  now="$(/bin/date '+%s')"
  [[ "$mtime" =~ ^[0-9]+$ ]] || return 1
  (( now - mtime < IDLE_SECONDS ))
}

unmount_with_timeout() {
  "$@" >/dev/null 2>&1 &
  local pid="$!"
  local elapsed=0
  while /bin/kill -0 "$pid" >/dev/null 2>&1; do
    if (( elapsed >= 10 )); then
      /bin/kill -TERM "$pid" >/dev/null 2>&1 || true
      /bin/sleep 1
      /bin/kill -KILL "$pid" >/dev/null 2>&1 || true
      /bin/wait "$pid" >/dev/null 2>&1 || true
      return 124
    fi
    /bin/sleep 1
    elapsed=$((elapsed + 1))
  done
  /bin/wait "$pid" >/dev/null 2>&1
}

active_run=0
if run_active; then
  active_run=1
fi

mount_entry_exists || exit 0
[[ "$active_run" == "1" ]] && exit 0
app_recently_alive && exit 0

uid="$(/usr/bin/id -u)"
echo "$(date)  idle watcher unmounting ${MOUNT} after ${IDLE_SECONDS}s without DDump keepalive" >> "$LOG"
/bin/launchctl bootout "gui/${uid}/${LABEL}" >/dev/null 2>&1 || true
stale_pids="$(/usr/bin/pgrep -f "rclone (mount|nfsmount).* ${MOUNT}" 2>/dev/null || true)"
if [[ -n "$stale_pids" ]]; then
  /bin/kill -TERM $stale_pids >/dev/null 2>&1 || true
  /bin/sleep 1
  /bin/kill -KILL $stale_pids >/dev/null 2>&1 || true
fi
unmount_with_timeout /sbin/umount -f "$MOUNT" || true
unmount_with_timeout /usr/sbin/diskutil unmount force "$MOUNT" || true
