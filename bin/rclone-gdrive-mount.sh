#!/bin/zsh
# Mounts Google Drive at ~/GoogleDrive via macFUSE.
# Low-memory profile intended for DDump uploads and occasional Finder checks.

PATH=$HOME/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin
MOUNT="$HOME/GoogleDrive"
LOG="$HOME/Library/Logs/rclone-gdrive.log"

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

echo "$(date)  starting rclone mount (macFUSE, low-memory profile)" >> "$LOG"
exec "$HOME/bin/rclone" mount combined: "$MOUNT" \
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
