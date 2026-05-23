#!/bin/zsh
# Mounts a configured rclone remote for DDump uploads.

set -euo pipefail

PATH="$HOME/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

APP_SUPPORT_DIR="$HOME/Library/Application Support/DDump"
CONFIG_FILE="$APP_SUPPORT_DIR/config.env"
DEFAULT_CONFIG_FILE="${0:A:h}/../config/config.env"
LOG_DIR="$APP_SUPPORT_DIR/logs"

# Defaults (overridden by config files)
GDRIVE_MOUNT_ENABLED="1"
GDRIVE_MOUNT_POINT="$HOME/GoogleDrive"
GDRIVE_REMOTE="combined:"
RCLONE_BIN="$HOME/bin/rclone"
LOG="$LOG_DIR/rclone-gdrive.log"

if [[ -f "$DEFAULT_CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$DEFAULT_CONFIG_FILE"
fi
if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
fi

mkdir -p "$LOG_DIR"
MOUNT="$GDRIVE_MOUNT_POINT"
REMOTE="$GDRIVE_REMOTE"

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

if mount | grep -q " on $MOUNT "; then
  echo "$(date)  stale mount found, force-unmounting" >> "$LOG"
  diskutil unmount force "$MOUNT" >/dev/null 2>&1 || true
  umount -f "$MOUNT" >/dev/null 2>&1 || true
  sleep 2
fi

if find "$MOUNT" -mindepth 1 -maxdepth 1 \
  ! -name ".DS_Store" \
  ! -name ".localized" \
  ! -name "Icon?" \
  -print -quit 2>/dev/null | grep -q .; then
  echo "$(date)  refusing to mount over non-empty $MOUNT; inspect local files first" >> "$LOG"
  exit 1
fi

echo "$(date)  starting rclone mount remote=$REMOTE mount=$MOUNT binary=$RCLONE" >> "$LOG"
exec "$RCLONE" mount "$REMOTE" "$MOUNT" \
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
