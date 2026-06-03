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
GDRIVE_MOUNT_ENABLED="0"
GDRIVE_DIRECT_UPLOAD="1"
GDRIVE_MOUNT_POINT="$HOME/GoogleDrive"
GDRIVE_REMOTE="combined:"
RCLONE_BIN="$HOME/bin/rclone"
RCLONE_MOUNT_COMMAND="auto"
RCLONE_CACHE_DIR="$APP_SUPPORT_DIR/cache/rclone"
PREVENT_FINDER_NETWORK_METADATA="1"
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
RCLONE_CACHE_DIR="$(expand_user_path "${RCLONE_CACHE_DIR:-$APP_SUPPORT_DIR/cache/rclone}")"
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

if [[ "${GDRIVE_DIRECT_UPLOAD:-1}" == "1" ]]; then
  echo "$(date)  mount skipped: GDRIVE_DIRECT_UPLOAD=1" >> "$LOG"
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
mkdir -p "$RCLONE_CACHE_DIR"

if [[ "${PREVENT_FINDER_NETWORK_METADATA:-1}" == "1" ]]; then
  /usr/bin/defaults write com.apple.desktopservices DSDontWriteNetworkStores -bool TRUE >/dev/null 2>&1 || true
fi

run_with_timeout() {
  local seconds="$1"
  shift
  "$@" >/dev/null 2>&1 &
  local pid="$!"
  local elapsed=0
  while /bin/kill -0 "$pid" >/dev/null 2>&1; do
    if (( elapsed >= seconds )); then
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

mount_entry_exists() {
  /sbin/mount | /usr/bin/grep -q " on $MOUNT "
}

mount_responds() {
  mount_entry_exists || return 1
  run_with_timeout 8 /bin/ls -1 "$MOUNT"
}

rclone_mount_pid() {
  /usr/bin/pgrep -f "rclone (mount|nfsmount).* ${MOUNT}" 2>/dev/null | /usr/bin/head -n 1
}

rclone_mount_age_seconds() {
  local pid
  pid="$(rclone_mount_pid)"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  /bin/ps -o etimes= -p "$pid" 2>/dev/null | /usr/bin/awk '{print $1}'
}

macfuse_available() {
  [[ -d "/Library/Filesystems/macfuse.fs" || -d "/Library/Filesystems/osxfuse.fs" ]]
}

metadata_cache_poison_present() {
  local cache_root
  for cache_root in "$HOME/Library/Caches/rclone" "$RCLONE_CACHE_DIR"; do
    [[ -d "$cache_root" ]] || continue
    if /usr/bin/find "$cache_root/vfs/combined" "$cache_root/vfsMeta/combined" \
      -maxdepth 1 \( -name ".DS_Store" -o -name "._*" \) -print -quit 2>/dev/null | /usr/bin/grep -q .; then
      return 0
    fi
  done
  return 1
}

purge_metadata_cache_poison() {
  local cache_root
  for cache_root in "$HOME/Library/Caches/rclone" "$RCLONE_CACHE_DIR"; do
    [[ -d "$cache_root" ]] || continue
    /usr/bin/find "$cache_root/vfs/combined" "$cache_root/vfsMeta/combined" \
      -maxdepth 1 \( -name ".DS_Store" -o -name "._*" \) -delete 2>/dev/null || true
  done
}

force_unmount_mountpoint() {
  run_with_timeout 10 /sbin/umount -f "$MOUNT" || true
  run_with_timeout 10 /usr/sbin/diskutil unmount force "$MOUNT" || true
}

MOUNT_COMMAND="${RCLONE_MOUNT_COMMAND:-auto}"
if [[ "$MOUNT_COMMAND" == "auto" || -z "$MOUNT_COMMAND" ]]; then
  # Probing the subcommand directly is more reliable than parsing `rclone help`
  # output, which can include formatting/escape sequences.
  if macfuse_available && "$RCLONE" mount --help >/dev/null 2>&1; then
    MOUNT_COMMAND="mount"
  elif "$RCLONE" nfsmount --help >/dev/null 2>&1; then
    MOUNT_COMMAND="nfsmount"
    echo "$(date)  macFUSE not found; falling back to rclone nfsmount" >> "$LOG"
  else
    MOUNT_COMMAND="mount"
  fi
fi

if [[ "$MOUNT_COMMAND" != "mount" && "$MOUNT_COMMAND" != "nfsmount" ]]; then
  echo "$(date)  mount failed: invalid RCLONE_MOUNT_COMMAND=${MOUNT_COMMAND} (expected auto|mount|nfsmount)" >> "$LOG"
  exit 1
fi

# If a healthy mount already exists, keep it and exit cleanly.
if mount_entry_exists; then
  if /usr/bin/pgrep -f "rclone (mount|nfsmount).* ${MOUNT}" >/dev/null 2>&1 && mount_responds && ! metadata_cache_poison_present; then
    echo "$(date)  mount already active at $MOUNT; leaving existing session in place" >> "$LOG"
    exit 0
  fi
  if metadata_cache_poison_present; then
    echo "$(date)  Finder metadata cache poison found, restarting $MOUNT" >> "$LOG"
  elif mount_age="$(rclone_mount_age_seconds 2>/dev/null || true)" && [[ "$mount_age" =~ ^[0-9]+$ && "$mount_age" -lt 180 ]]; then
    echo "$(date)  mount process is still starting (${mount_age}s old); leaving existing session in place" >> "$LOG"
    exit 0
  else
    echo "$(date)  stale/unresponsive mount found, force-unmounting $MOUNT" >> "$LOG"
  fi
  force_unmount_mountpoint
  sleep 2
fi

# If an older mount process is still pinned to this mountpoint, clear it first.
stale_pids="$(/usr/bin/pgrep -f "rclone (mount|nfsmount).* ${MOUNT}" 2>/dev/null || true)"
if [[ -n "${stale_pids}" ]]; then
  echo "$(date)  stale rclone process(es) found for $MOUNT: ${stale_pids}" >> "$LOG"
  /bin/kill -TERM ${stale_pids} >/dev/null 2>&1 || true
  /bin/sleep 2
  /bin/kill -KILL ${stale_pids} >/dev/null 2>&1 || true
  force_unmount_mountpoint
  sleep 1
fi

purge_metadata_cache_poison

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
  --cache-dir "$RCLONE_CACHE_DIR" \
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
  --log-file "$LOG" \
  --log-level NOTICE
