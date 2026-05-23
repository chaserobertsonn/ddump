#!/bin/zsh
# Mounts a configured rclone remote for DDump uploads.

set -euo pipefail

PATH="$HOME/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

APP_SUPPORT_DIR="$HOME/Library/Application Support/DDump"
CONFIG_FILE="$APP_SUPPORT_DIR/config.env"
DEFAULT_CONFIG_FILE="${0:A:h}/../config/config.env"
LOG_DIR="$APP_SUPPORT_DIR/logs"
STATE_DIR="$APP_SUPPORT_DIR/state"

# Defaults (overridden by config files)
GDRIVE_MOUNT_ENABLED="1"
GDRIVE_MOUNT_POINT="$HOME/GoogleDrive"
GDRIVE_REMOTE="combined:"
RCLONE_BIN="$HOME/bin/rclone"
RCLONE_MOUNT_COMMAND="auto"
LOG="$LOG_DIR/rclone-gdrive.log"

expand_user_path() {
  local raw="$1"
  # Config values written from the app may contain escaped $HOME;
  # normalize both "$HOME/..." and "~/..." forms.
  raw="${raw/#\\\$HOME/$HOME}"
  raw="${raw/#\$HOME/$HOME}"
  raw="${raw/#\~/$HOME}"
  printf '%s' "$raw"
}

if [[ -f "$DEFAULT_CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$DEFAULT_CONFIG_FILE"
fi
if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
fi

mkdir -p "$LOG_DIR"
mkdir -p "$STATE_DIR"
GDRIVE_MOUNT_POINT="$(expand_user_path "${GDRIVE_MOUNT_POINT:-$HOME/GoogleDrive}")"
RCLONE_BIN="$(expand_user_path "${RCLONE_BIN:-$HOME/bin/rclone}")"
MOUNT="$GDRIVE_MOUNT_POINT"
REMOTE="$GDRIVE_REMOTE"
LOCK_DIR="$STATE_DIR/rclone-mount.lock"
LOCK_PID_FILE="$LOCK_DIR/pid"

if ! /bin/mkdir "$LOCK_DIR" >/dev/null 2>&1; then
  stale_lock=0
  lock_pid="$(/bin/cat "$LOCK_PID_FILE" 2>/dev/null || true)"
  if [[ -z "${lock_pid}" ]]; then
    stale_lock=1
  elif ! [[ "${lock_pid}" =~ ^[0-9]+$ ]]; then
    stale_lock=1
  elif ! /bin/kill -0 "$lock_pid" >/dev/null 2>&1; then
    stale_lock=1
  fi

  if (( stale_lock == 0 )); then
    lock_mtime="$(/usr/bin/stat -f '%m' "$LOCK_DIR" 2>/dev/null || echo 0)"
    now_epoch="$(date +%s)"
    if [[ "$lock_mtime" =~ ^[0-9]+$ ]] && (( now_epoch - lock_mtime > 120 )); then
      stale_lock=1
    fi
  fi

  if (( stale_lock == 1 )); then
    /bin/rm -f "$LOCK_PID_FILE" >/dev/null 2>&1 || true
    /bin/rmdir "$LOCK_DIR" >/dev/null 2>&1 || true
  fi

  if ! /bin/mkdir "$LOCK_DIR" >/dev/null 2>&1; then
    echo "$(date)  mount skipped: another mount attempt is already in progress" >> "$LOG"
    exit 0
  fi
fi
/bin/echo "$$" > "$LOCK_PID_FILE"
cleanup_lock() {
  /bin/rm -f "$LOCK_PID_FILE" >/dev/null 2>&1 || true
  /bin/rmdir "$LOCK_DIR" >/dev/null 2>&1 || true
}
trap cleanup_lock EXIT

if [[ "${GDRIVE_MOUNT_ENABLED:-1}" != "1" ]]; then
  echo "$(date)  mount skipped: GDRIVE_MOUNT_ENABLED=${GDRIVE_MOUNT_ENABLED}" >> "$LOG"
  exit 0
fi

if [[ -z "$MOUNT" || -z "$REMOTE" ]]; then
  echo "$(date)  mount skipped: missing GDRIVE_MOUNT_POINT or GDRIVE_REMOTE" >> "$LOG"
  exit 1
fi

if [[ -n "${RCLONE_BIN:-}" && -x "$RCLONE_BIN" ]]; then
  RCLONE="$RCLONE_BIN"
elif command -v rclone >/dev/null 2>&1; then
  RCLONE="$(command -v rclone)"
else
  echo "$(date)  mount failed: rclone binary not found (set RCLONE_BIN)." >> "$LOG"
  exit 1
fi

mkdir -p "$MOUNT"

MOUNT_COMMAND="${RCLONE_MOUNT_COMMAND:-auto}"
if [[ "$MOUNT_COMMAND" == "auto" || -z "$MOUNT_COMMAND" ]]; then
  # Probing the subcommand directly is more reliable than parsing `rclone help`
  # output, which can include formatting/escape sequences.
  if "$RCLONE" nfsmount --help >/dev/null 2>&1; then
    MOUNT_COMMAND="nfsmount"
  else
    MOUNT_COMMAND="mount"
  fi
fi

if [[ "$MOUNT_COMMAND" != "mount" && "$MOUNT_COMMAND" != "nfsmount" ]]; then
  echo "$(date)  mount failed: invalid RCLONE_MOUNT_COMMAND=${MOUNT_COMMAND} (expected auto|mount|nfsmount)" >> "$LOG"
  exit 1
fi

if mount | grep -q " on $MOUNT "; then
  echo "$(date)  stale mount found, force-unmounting" >> "$LOG"
  diskutil unmount force "$MOUNT" >/dev/null 2>&1 || true
  umount -f "$MOUNT" >/dev/null 2>&1 || true
  sleep 2
fi

# If an older mount process is still pinned to this mountpoint, clear it first.
stale_pids="$(/usr/bin/pgrep -f "rclone (mount|nfsmount).* ${MOUNT}" 2>/dev/null || true)"
if [[ -n "${stale_pids}" ]]; then
  echo "$(date)  stale rclone process(es) found for $MOUNT: ${stale_pids}" >> "$LOG"
  /bin/kill -TERM ${stale_pids} >/dev/null 2>&1 || true
  /bin/sleep 2
  /bin/kill -KILL ${stale_pids} >/dev/null 2>&1 || true
  diskutil unmount force "$MOUNT" >/dev/null 2>&1 || true
  umount -f "$MOUNT" >/dev/null 2>&1 || true
  sleep 1
fi

if find "$MOUNT" -mindepth 1 -maxdepth 1 \
  ! -name ".DS_Store" \
  ! -name ".localized" \
  ! -name "Icon?" \
  -print -quit 2>/dev/null | grep -q .; then
  echo "$(date)  refusing to mount over non-empty $MOUNT; inspect local files first" >> "$LOG"
  exit 1
fi

echo "$(date)  starting rclone ${MOUNT_COMMAND} remote=$REMOTE mount=$MOUNT binary=$RCLONE" >> "$LOG"
exec "$RCLONE" "$MOUNT_COMMAND" "$REMOTE" "$MOUNT" \
  --vfs-cache-mode writes \
  --vfs-cache-max-size 8G \
  --vfs-cache-max-age 6h \
  --vfs-read-chunk-size 8M \
  --vfs-read-chunk-size-limit 64M \
  --dir-cache-time 15m \
  --poll-interval 5m \
  --buffer-size 8M \
  --transfers 2 \
  --checkers 4 \
  --drive-chunk-size 16M \
  --drive-acknowledge-abuse \
  --volname "GoogleDrive" \
  --noapplexattr \
  --noappledouble \
  --exclude ".DS_Store" \
  --exclude "._*" \
  --exclude ".Spotlight-V100/**" \
  --exclude ".Trashes/**" \
  --exclude ".fseventsd/**" \
  --exclude ".TemporaryItems/**" \
  --exclude ".AppleDouble/**" \
  --exclude ".AppleDB/**" \
  --rc \
  --rc-addr 127.0.0.1:5572 \
  --log-file "$LOG" \
  --log-level NOTICE
