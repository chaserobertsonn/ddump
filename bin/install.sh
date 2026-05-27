#!/bin/bash
set -euo pipefail

PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

LABEL="com.ddump"
NETWORK_WATCH_LABEL="com.ddump.network-watch"
OLD_LABEL="com.dfp.dump"
DEFAULT_MOUNT_LABEL="com.ddump.rclone-gdrive"
OLD_MOUNT_LABEL="com.chase.rclone-gdrive"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

APP_SUPPORT_DIR="${HOME}/Library/Application Support/DDump"
OLD_APP_SUPPORT_DIR="${HOME}/Library/Application Support/DFPDump"
BIN_DIR="${APP_SUPPORT_DIR}/bin"
STATE_DIR="${APP_SUPPORT_DIR}/state"
LOG_DIR="${APP_SUPPORT_DIR}/logs"
USER_CONFIG="${APP_SUPPORT_DIR}/config.env"
DEFAULT_CONFIG="${PROJECT_DIR}/config/config.env"
APP_BUNDLE="${HOME}/Applications/DDump.app"

LAUNCH_AGENT_DIR="${HOME}/Library/LaunchAgents"
PLIST_PATH="${LAUNCH_AGENT_DIR}/${LABEL}.plist"
OLD_PLIST_PATH="${LAUNCH_AGENT_DIR}/${OLD_LABEL}.plist"
OLD_MOUNT_PLIST_PATH="${LAUNCH_AGENT_DIR}/${OLD_MOUNT_LABEL}.plist"

uid="$(id -u)"

# ---------------------------------------------------------------------------
# Migration: DFPDump → DDump
# ---------------------------------------------------------------------------
if [[ -d "$OLD_APP_SUPPORT_DIR" && ! -d "$APP_SUPPORT_DIR" ]]; then
  echo "Migrating $OLD_APP_SUPPORT_DIR → $APP_SUPPORT_DIR"
  # Stop the old launch agent first (best effort)
  launchctl bootout "gui/${uid}/${OLD_LABEL}" >/dev/null 2>&1 || true
  # Rename the directory, preserving all state files (trusted UUIDs, manifest, etc.)
  mv "$OLD_APP_SUPPORT_DIR" "$APP_SUPPORT_DIR"
elif [[ -d "$OLD_APP_SUPPORT_DIR" && -d "$APP_SUPPORT_DIR" ]]; then
  echo "Note: both $OLD_APP_SUPPORT_DIR and $APP_SUPPORT_DIR exist."
  echo "      Leaving them alone — please reconcile manually."
fi

# Bootout the old LaunchAgent and remove its plist if present
if [[ -f "$OLD_PLIST_PATH" ]]; then
  echo "Removing stale LaunchAgent: $OLD_LABEL"
  launchctl bootout "gui/${uid}" "$OLD_PLIST_PATH" >/dev/null 2>&1 || true
  rm -f "$OLD_PLIST_PATH"
fi

mkdir -p "$BIN_DIR" "$STATE_DIR" "$LOG_DIR" "$LAUNCH_AGENT_DIR"

# ---------------------------------------------------------------------------
# Copy scripts
# ---------------------------------------------------------------------------
for s in ddump.sh ddump-trust.sh ddump-monitor.sh ddump-control.sh \
         ddump-settings.sh ddump-debug-snapshot.sh \
         ddump-notify.sh ddump-cluster.sh ddump-calendar-lookup.sh \
         rclone-gdrive-mount.sh ddump-network-watch.sh; do
  if [[ -f "${PROJECT_DIR}/bin/${s}" ]]; then
    cp "${PROJECT_DIR}/bin/${s}" "${BIN_DIR}/${s}"
    chmod +x "${BIN_DIR}/${s}"
  fi
done

# ---------------------------------------------------------------------------
# Build/install the optional Swift UI app
# ---------------------------------------------------------------------------
if [[ -f "${PROJECT_DIR}/app/DDumpApp.swift" ]]; then
  if command -v swiftc >/dev/null 2>&1; then
    mkdir -p "${APP_BUNDLE}/Contents/MacOS" "${APP_BUNDLE}/Contents/Resources"
    cat >"${APP_BUNDLE}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>DDump</string>
  <key>CFBundleDisplayName</key>
  <string>DDump</string>
  <key>CFBundleIdentifier</key>
  <string>com.ddump.app</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>CFBundleShortVersionString</key>
  <string>0.2</string>
  <key>CFBundleExecutable</key>
  <string>DDump</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIconName</key>
  <string>AppIcon</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
</dict>
</plist>
PLIST
    if [[ -f "${PROJECT_DIR}/app/Assets/AppIcon.icns" ]]; then
      cp "${PROJECT_DIR}/app/Assets/AppIcon.icns" "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"
      cp "${PROJECT_DIR}/app/Assets/AppIcon.icns" "${APP_BUNDLE}/Contents/Resources/DefaultAppIcon.icns"
    fi
    if [[ -d "${PROJECT_DIR}/app/Assets/Fonts" ]]; then
      mkdir -p "${APP_BUNDLE}/Contents/Resources/Fonts"
      cp "${PROJECT_DIR}/app/Assets/Fonts"/*.otf "${APP_BUNDLE}/Contents/Resources/Fonts/" 2>/dev/null || true
    fi
    for asset in logo-icon.png logo-icon-512.png logo-mark.svg; do
      if [[ -f "${PROJECT_DIR}/app/Assets/${asset}" ]]; then
        cp "${PROJECT_DIR}/app/Assets/${asset}" "${APP_BUNDLE}/Contents/Resources/${asset}"
      fi
    done
    if swiftc -parse-as-library -o "${APP_BUNDLE}/Contents/MacOS/DDump" "${PROJECT_DIR}/app/DDumpApp.swift"; then
      chmod +x "${APP_BUNDLE}/Contents/MacOS/DDump"
      /usr/bin/touch "$APP_BUNDLE"
      echo "Installed Mac app: ${APP_BUNDLE}"
    else
      echo "Warning: Swift app build failed; scripts and LaunchAgent are still installed."
    fi
  else
    echo "Note: swiftc not found; skipping Mac app build."
  fi
fi

# Remove legacy script names that are no longer used (don't leave stale copies).
for legacy in dfp-dump.sh dfp-dump-trust.sh dfp-dump-monitor.sh dfp-dump-control.sh \
              dfp-dump-settings.sh dfp-dump-debug-snapshot.sh; do
  rm -f "${BIN_DIR}/${legacy}"
done

# ---------------------------------------------------------------------------
# User config — keep existing, add missing keys, migrate renamed keys
# ---------------------------------------------------------------------------
if [[ ! -f "$USER_CONFIG" ]]; then
  cp "$DEFAULT_CONFIG" "$USER_CONFIG"
  echo "Created user config: $USER_CONFIG"
else
  echo "Keeping existing config: $USER_CONFIG (will migrate keys as needed)"
fi

migrate_key() {
  # Rename old_key → new_key in user config, preserving the value. Idempotent.
  local old_key="$1"
  local new_key="$2"
  if grep -q "^${old_key}=" "$USER_CONFIG" && ! grep -q "^${new_key}=" "$USER_CONFIG"; then
    /usr/bin/sed -i '' "s|^${old_key}=|${new_key}=|" "$USER_CONFIG"
    echo "Migrated config key: ${old_key} → ${new_key}"
  elif grep -q "^${old_key}=" "$USER_CONFIG" && grep -q "^${new_key}=" "$USER_CONFIG"; then
    # Both keys present: delete the old one
    /usr/bin/sed -i '' "/^${old_key}=/d" "$USER_CONFIG"
    echo "Removed stale config key (new one already set): ${old_key}"
  fi
}

add_missing_key() {
  # Ensure a key exists in user config with the given default value.
  local key="$1"
  local default_value="$2"
  local comment="${3:-}"
  if ! grep -q "^${key}=" "$USER_CONFIG"; then
    if [[ -n "$comment" ]]; then
      /bin/echo "" >>"$USER_CONFIG"
      /bin/echo "# ${comment}" >>"$USER_CONFIG"
    fi
    /bin/echo "${key}=${default_value}" >>"$USER_CONFIG"
    echo "Added ${key} to user config."
  fi
}

replace_key_if_exact() {
  # If a key currently matches old_value exactly, replace it with new_value.
  local key="$1"
  local old_value="$2"
  local new_value="$3"
  local current
  current="$(/usr/bin/awk -F= -v k="$key" '$1 == k { v=$2 } END { gsub(/^"|"$/, "", v); print v }' "$USER_CONFIG")"
  if [[ "$current" == "$old_value" ]]; then
    /usr/bin/sed -i '' "s|^${key}=.*|${key}=\"${new_value}\"|" "$USER_CONFIG"
    echo "Updated ${key} default: ${old_value} → ${new_value}"
  fi
}

normalize_escaped_home_path() {
  # Convert a literal "\$HOME/..." in config values back to "$HOME/..."
  # so shell scripts can expand it at runtime.
  local key="$1"
  local tmp changed line
  tmp="$(mktemp)"
  changed=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == ${key}"=\"\\\$HOME/"* ]]; then
      line="${line/${key}=\"\\\$HOME\//${key}=\"\$HOME/}"
      changed=1
    fi
    printf '%s\n' "$line" >> "$tmp"
  done < "$USER_CONFIG"
  if [[ "$changed" == "1" ]]; then
    mv "$tmp" "$USER_CONFIG"
    echo "Normalized escaped home path in ${key}."
  else
    rm -f "$tmp"
  fi
}

# v1 → v2 key renames
migrate_key "TRUSTED_NAME_PREFIX" "TRUSTED_NAME_PREFIXES"
migrate_key "REQUIRE_DCIM_OR_TRUSTED" "REQUIRE_PHOTOS_OR_TRUSTED"

# Drop deprecated keys
if grep -q '^AUTO_TRUST_PREFIX=' "$USER_CONFIG"; then
  /usr/bin/sed -i '' '/^AUTO_TRUST_PREFIX=/d' "$USER_CONFIG"
  echo "Removed deprecated config key: AUTO_TRUST_PREFIX (TRUSTED_NAME_PREFIXES is now the single source)"
fi

# v1 keys that still apply
add_missing_key 'PROMPT_FOR_SOURCE_FOLDERS_ON_NEW_DRIVE' '"1"' "Prompt for folder selection the first time a trusted card UUID is seen."
add_missing_key 'PROMPT_FOR_UNKNOWN_CARD_ACTION' '"1"'
add_missing_key 'SKIP_INTERNAL_VOLUMES' '"1"'
add_missing_key 'IGNORE_VOLUME_NAMES' '"Macintosh HD,Recovery"'
add_missing_key 'IGNORE_NO_UUID_VOLUMES' '"1"'
add_missing_key 'PROMPT_NO_EJECT_ON_START' '"0"'
add_missing_key 'SOURCE_SUBDIR_FALLBACK_ON_EMPTY_SELECTION' '"1"'
add_missing_key 'USE_FAST_SEEN_INDEX' '"1"'
add_missing_key 'MIN_FREE_SPACE_GB' '"100"' "Minimum local staging free space required before import; 0 disables."
add_missing_key 'FINDERSERVER_BIN' '"$HOME/.local/bin/finderserver"' "Helper command for starting/refreshing shared Finder mounts."
add_missing_key 'FINDERSERVER_TIMER_CHECK_SECONDS' '"300"' "During upload, check timer this often."
add_missing_key 'FINDERSERVER_TIMER_MIN_SECONDS' '"300"' "If timer is at/below this value, refresh it."
add_missing_key 'GDRIVE_MOUNT_ENABLED' '"1"' "Enable DDump-managed rclone mount automation."
add_missing_key 'GDRIVE_MOUNT_POINT' '"$HOME/GoogleDrive"' "Mounted cloud folder path used for uploads."
add_missing_key 'GDRIVE_REMOTE' '"combined:"' "rclone remote/path mounted by DDump."
add_missing_key 'RCLONE_BIN' '"$HOME/bin/rclone"' "rclone binary path (fallback: command -v rclone)."
add_missing_key 'RCLONE_MOUNT_COMMAND' '"auto"' "Mount command: auto (prefer nfsmount), mount, or nfsmount."
add_missing_key 'GDRIVE_MOUNT_LABEL' '"com.ddump.rclone-gdrive"' "LaunchAgent label for DDump's mount helper."
add_missing_key 'GDRIVE_MOUNT_RETRY_SECONDS' '"15,30,60,180"' "Mount retry backoff schedule in seconds."
add_missing_key 'GDRIVE_MOUNT_WAIT_SECONDS' '"30"' "How long each mount attempt waits for readiness."
add_missing_key 'GDRIVE_ACTION_TIMEOUT_SECONDS' '"180"' "Maximum seconds DDump waits for a mount action before timing out."
replace_key_if_exact 'GDRIVE_MOUNT_RETRY_SECONDS' '5,15,60,180,360,600' '15,30,60,180'

# v2 keys (new)
add_missing_key 'TRUSTED_NAME_PREFIXES' '"DFP_"' "Volume name prefixes that auto-trust (comma-separated)."
add_missing_key 'REQUIRE_PHOTOS_OR_TRUSTED' '"1"' "Silent-skip non-photo volumes (no photo files, no trust)."
add_missing_key 'PHOTO_FILE_EXTENSIONS' '"jpg,jpeg,heic,heif,cr2,cr3,nef,arw,raf,dng,rw2,orf,pef,srw,tif,tiff,mp4,mov,m4v,avi,mts,m2ts,3gp,3gpp,insv,insp,gpr"' "File extensions that count as photos for detection."
add_missing_key 'VIDEO_FILE_EXTENSIONS' '"mp4,mov,m4v,avi,mts,m2ts,3gp,3gpp,insv,gpr"' "Extensions treated as video when SPLIT_PHOTO_VIDEO is enabled."
add_missing_key 'PHOTO_RECENCY_HOURS' '"24"'
add_missing_key 'CANDIDATE_MODE' '"lookback"' "Import candidate scan mode: lookback keeps the scan limited to recent files."
add_missing_key 'LOOKBACK_HOURS' '"24"' "When CANDIDATE_MODE=lookback, only files newer than this many hours are considered."
add_missing_key 'USE_NOTIFICATIONS' '"1"' "Native macOS notifications instead of Terminal monitor."
add_missing_key 'NOTIFICATION_TIMEOUT_SECONDS' '"60"'
add_missing_key 'FOLDER_NAMING_STRATEGY' '"sequential"' "How to name shoot folders: smart | calendar | sequential | custom | camera."
add_missing_key 'FOLDER_NAMING_FALLBACK' '"sequential"'
add_missing_key 'SMART_SAMPLE_PATH' '""' "Real shoot folder path used by smart naming to infer the daily Drive structure."
add_missing_key 'SMART_ASSIGN_EXISTING_FOLDERS' '"1"' "Smart naming maps clusters into existing folders under today's Drive date folder."
add_missing_key 'SPLIT_PHOTO_VIDEO' '"0"' "Optional smart-mode split: videos go to the sibling 2 — Video date ladder."
add_missing_key 'FOLDER_NAME_SEQUENTIAL_PREFIX' '"Shoot-"'
add_missing_key 'FOLDER_NAME_CUSTOM_VALUES' '""'
add_missing_key 'FOLDER_NAME_UNCATEGORIZED' '"Uncategorized"'
add_missing_key 'CLUSTER_GAP_MINUTES' '"45"'
add_missing_key 'CLUSTER_FOLDER_TEMPLATE' '"Cluster {n} {start}-{end}"'
add_missing_key 'CLUSTER_GROUPING_ENABLED' '"1"' "When enabled, nearby capture times group together before naming."
add_missing_key 'CLUSTER_ATTACH_MINUTES' '"120"' "Across cards, reuse same-day shoot bucket when cluster is within this window."
add_missing_key 'CALENDAR_NAME' '""'
add_missing_key 'CALENDAR_EVENT_PADDING_MIN' '"15"'
add_missing_key 'POST_MOVE_ROOTS' '""' "Optional comma-separated list of additional final destinations."
add_missing_key 'POST_MOVE_FALLBACK_ROOT' '""' "Fallback destination when primary root is unavailable."
add_missing_key 'VERIFY_COPY_HASH' '"0"' "Optional post-copy SHA-256 verification. Off by default for speed; size verification remains on."
add_missing_key 'UPLOAD_RECEIPTS_ENABLED' '"1"' "Write a small receipt file after each upload attempt."
add_missing_key 'DB_ENABLED' '"0"' "Use SQLite database memory for runs, files, and upload jobs (beta)."
add_missing_key 'DB_FILE' '"$HOME/Library/Application Support/DDump/state/ddump.sqlite3"' "SQLite database path."
add_missing_key 'HASH_BEFORE_COPY' '"0"' "Keep SD dumps fast: do not hash card files before local copy."
add_missing_key 'UPLOAD_RETRY_MINUTES' '"3,10,60,240"' "Pending upload retry delays in minutes."
add_missing_key 'SAFE_CLEANUP_DAYS' '"7"' "Mac app cleanup only offers staging folders older than this many days."
add_missing_key 'SLACK_WEBHOOK_URL' '""' "Optional Slack incoming-webhook URL for admin-only run notifications."
add_missing_key 'SLACK_NOTIFY_ON_COMPLETE' '"0"'
add_missing_key 'SLACK_NOTIFY_ON_ERROR' '"1"'
add_missing_key 'NTFY_TOPIC' '"dfp-chase-scheduler"' "Optional ntfy topic for push alerts."
add_missing_key 'NTFY_NOTIFY_STAGING_STARTED' '"0"'
add_missing_key 'NTFY_NOTIFY_CARD_EJECTED' '"1"'
add_missing_key 'NTFY_NOTIFY_UPLOAD_STARTED' '"0"'
add_missing_key 'NTFY_NOTIFY_UPLOAD_COMPLETE' '"1"'
add_missing_key 'NTFY_NOTIFY_MOUNT_FAILED' '"1"'
add_missing_key 'NTFY_NOTIFY_CARD_ALMOST_FULL' '"1"'
add_missing_key 'NTFY_NOTIFY_INTEGRITY_WARNING' '"1"'
add_missing_key 'CARD_ALMOST_FULL_ALERT_ENABLED' '"1"' "Warn when free card space is below the size of the most recent import from that card."
add_missing_key 'NETWORK_RESUME_ENABLED' '"1"' "When internet reconnects and pending uploads exist, automatically trigger a retry run."
add_missing_key 'NETWORK_RESUME_CHECK_SECONDS' '"20"' "Network watcher poll interval."
add_missing_key 'NETWORK_RESUME_COOLDOWN_SECONDS' '"120"' "Minimum seconds between reconnect-triggered retry runs."
add_missing_key 'APP_COLOR_SCHEME' '"system"' "App appearance: system | light | dark."
add_missing_key 'APP_ICON_DEFAULT_LIGHT' '""' "Stored icon preset ID used when app appearance is light."
add_missing_key 'APP_ICON_DEFAULT_DARK' '""' "Stored icon preset ID used when app appearance is dark."

normalize_escaped_home_path 'RCLONE_BIN'
normalize_escaped_home_path 'FINDERSERVER_BIN'
normalize_escaped_home_path 'DB_FILE'

if grep -q '^VERIFY_COPY_HASH="1"$' "$USER_CONFIG"; then
  /usr/bin/sed -i '' 's/^VERIFY_COPY_HASH="1"$/VERIFY_COPY_HASH="0"/' "$USER_CONFIG"
  echo "Updated VERIFY_COPY_HASH to 0 (size verification remains enabled; full hash verify is optional)."
fi

if grep -q '^DAILY_FOLDER_FORMAT="%Y-%m-%d-dump"$' "$USER_CONFIG"; then
  /usr/bin/sed -i '' 's/^DAILY_FOLDER_FORMAT="%Y-%m-%d-dump"$/DAILY_FOLDER_FORMAT="%Y-%m-%d-ddump"/' "$USER_CONFIG"
  echo "Updated DAILY_FOLDER_FORMAT to use -ddump suffix."
fi

if grep -q '^FOLDER_NAME_SEQUENTIAL_PREFIX="Dump "$' "$USER_CONFIG"; then
  /usr/bin/sed -i '' 's/^FOLDER_NAME_SEQUENTIAL_PREFIX="Dump "$/FOLDER_NAME_SEQUENTIAL_PREFIX="Shoot-"/' "$USER_CONFIG"
  echo "Updated FOLDER_NAME_SEQUENTIAL_PREFIX from \"Dump \" to \"Shoot-\"."
fi

if grep -q '^CANDIDATE_MODE="all"$' "$USER_CONFIG"; then
  /usr/bin/sed -i '' 's/^CANDIDATE_MODE="all"$/CANDIDATE_MODE="lookback"/' "$USER_CONFIG"
  echo "Updated CANDIDATE_MODE from \"all\" to \"lookback\" (recent-file import only)."
fi

if grep -q '^DB_ENABLED="1"$' "$USER_CONFIG"; then
  /usr/bin/sed -i '' 's/^DB_ENABLED="1"$/DB_ENABLED="0"/' "$USER_CONFIG"
  echo "Updated DB_ENABLED to 0 (staging-folder memory is now the default; SQLite remains optional beta)."
fi

if grep -q '^GDRIVE_MOUNT_LABEL="com.chase.rclone-gdrive"$' "$USER_CONFIG"; then
  /usr/bin/sed -i '' 's/^GDRIVE_MOUNT_LABEL="com.chase.rclone-gdrive"$/GDRIVE_MOUNT_LABEL="com.ddump.rclone-gdrive"/' "$USER_CONFIG"
  echo "Updated GDRIVE_MOUNT_LABEL to com.ddump.rclone-gdrive."
fi

# Default-off legacy UI
if grep -q '^SHOW_PROGRESS_WINDOW="1"' "$USER_CONFIG"; then
  /usr/bin/sed -i '' 's|^SHOW_PROGRESS_WINDOW="1"|SHOW_PROGRESS_WINDOW="0"|' "$USER_CONFIG"
  echo "Updated SHOW_PROGRESS_WINDOW to 0 (notifications are the new primary UI)."
fi
add_missing_key 'SHOW_PROGRESS_WINDOW' '"0"'
add_missing_key 'SHOW_RUN_SUMMARY_DIALOG' '"0"'
add_missing_key 'ENABLE_NOTIFICATIONS' '"0"'

# v1 cleanup quirks (preserved from old install.sh)
if grep -q '^MANIFEST_RETENTION_DAYS="7"$' "$USER_CONFIG"; then
  /usr/bin/sed -i '' 's/^MANIFEST_RETENTION_DAYS="7"$/MANIFEST_RETENTION_DAYS="0"/' "$USER_CONFIG"
  echo "Updated MANIFEST_RETENTION_DAYS from 7 to 0 (prevents old-file reimports)."
fi

# ---------------------------------------------------------------------------
# Optional dependency check
# ---------------------------------------------------------------------------
echo ""
echo "=== Notification helper detection ==="
echo "  DDump currently uses AppleScript notifications/dialogs."
echo "  This avoids terminal-notifier action-button hangs when macOS notification permission is missing."
if command -v exiftool >/dev/null 2>&1; then
  echo "  ✓ exiftool installed — EXIF capture time used for clustering"
else
  echo "  ⚠ exiftool not found; cluster strategy falls back to file mtime"
  echo "    brew install exiftool"
fi
if command -v gcalcli >/dev/null 2>&1; then
  echo "  ✓ gcalcli installed — calendar strategy ready"
else
  echo "  ⓘ gcalcli not installed; needed only for FOLDER_NAMING_STRATEGY=calendar"
  echo "    brew install gcalcli && gcalcli list"
fi

# ---------------------------------------------------------------------------
# LaunchAgent
# ---------------------------------------------------------------------------
cat >"$PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${BIN_DIR}/ddump.sh</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>StartOnMount</key>
  <true/>
  <key>StartInterval</key>
  <integer>180</integer>
  <key>StandardOutPath</key>
  <string>${LOG_DIR}/launchd.out.log</string>
  <key>StandardErrorPath</key>
  <string>${LOG_DIR}/launchd.err.log</string>
</dict>
</plist>
PLIST

launchctl bootout "gui/${uid}" "$PLIST_PATH" >/dev/null 2>&1 || true
launchctl bootstrap "gui/${uid}" "$PLIST_PATH"
launchctl kickstart -k "gui/${uid}/${LABEL}" >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# Cloud mount LaunchAgent (packaged with DDump)
# ---------------------------------------------------------------------------
mount_label="$(/usr/bin/awk -F= '$1 == "GDRIVE_MOUNT_LABEL" { v=$2 } END { gsub(/^"|"$/, "", v); print v }' "$USER_CONFIG")"
if [[ -z "$mount_label" ]]; then
  mount_label="$DEFAULT_MOUNT_LABEL"
fi
MOUNT_PLIST_PATH="${LAUNCH_AGENT_DIR}/${mount_label}.plist"
COMPAT_MOUNT_PLIST_PATH="${LAUNCH_AGENT_DIR}/${OLD_MOUNT_LABEL}.plist"
NETWORK_WATCH_PLIST_PATH="${LAUNCH_AGENT_DIR}/${NETWORK_WATCH_LABEL}.plist"

cat >"$MOUNT_PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${mount_label}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/zsh</string>
    <string>${BIN_DIR}/rclone-gdrive-mount.sh</string>
  </array>
  <key>RunAtLoad</key>
  <false/>
  <key>KeepAlive</key>
  <false/>
  <key>StandardOutPath</key>
  <string>${LOG_DIR}/rclone-gdrive.stdout.log</string>
  <key>StandardErrorPath</key>
  <string>${LOG_DIR}/rclone-gdrive.stderr.log</string>
  <key>ThrottleInterval</key>
  <integer>30</integer>
</dict>
</plist>
PLIST

launchctl bootout "gui/${uid}" "$MOUNT_PLIST_PATH" >/dev/null 2>&1 || true
launchctl bootstrap "gui/${uid}" "$MOUNT_PLIST_PATH" >/dev/null 2>&1 || true

# Compatibility mount agent for finderserver (it still references com.chase.rclone-gdrive).
if [[ "$mount_label" != "$OLD_MOUNT_LABEL" ]]; then
  cat >"$COMPAT_MOUNT_PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${OLD_MOUNT_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/zsh</string>
    <string>${BIN_DIR}/rclone-gdrive-mount.sh</string>
  </array>
  <key>RunAtLoad</key>
  <false/>
  <key>KeepAlive</key>
  <false/>
  <key>StandardOutPath</key>
  <string>${LOG_DIR}/rclone-gdrive.stdout.log</string>
  <key>StandardErrorPath</key>
  <string>${LOG_DIR}/rclone-gdrive.stderr.log</string>
  <key>ThrottleInterval</key>
  <integer>30</integer>
</dict>
</plist>
PLIST
  launchctl bootout "gui/${uid}" "$COMPAT_MOUNT_PLIST_PATH" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/${uid}" "$COMPAT_MOUNT_PLIST_PATH" >/dev/null 2>&1 || true
fi

# ---------------------------------------------------------------------------
# Network reconnect watcher (retry pending uploads when internet returns)
# ---------------------------------------------------------------------------
cat >"$NETWORK_WATCH_PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${NETWORK_WATCH_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${BIN_DIR}/ddump-network-watch.sh</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>${LOG_DIR}/network-watch.stdout.log</string>
  <key>StandardErrorPath</key>
  <string>${LOG_DIR}/network-watch.stderr.log</string>
  <key>ThrottleInterval</key>
  <integer>30</integer>
</dict>
</plist>
PLIST

launchctl bootout "gui/${uid}" "$NETWORK_WATCH_PLIST_PATH" >/dev/null 2>&1 || true
launchctl bootstrap "gui/${uid}" "$NETWORK_WATCH_PLIST_PATH" >/dev/null 2>&1 || true

echo ""
echo "Installed DDump launch agent."
echo "Main script: ${BIN_DIR}/ddump.sh"
echo "Notifier:    ${BIN_DIR}/ddump-notify.sh"
echo "Cluster:     ${BIN_DIR}/ddump-cluster.sh"
echo "Calendar:    ${BIN_DIR}/ddump-calendar-lookup.sh"
echo "Config:      ${USER_CONFIG}"
echo "Mac app:     ${APP_BUNDLE}"
echo "LaunchAgent: ${PLIST_PATH}"
echo "Mount agent: ${MOUNT_PLIST_PATH}"
if [[ "$mount_label" != "$OLD_MOUNT_LABEL" ]]; then
  echo "Compat mount: ${COMPAT_MOUNT_PLIST_PATH}"
fi
echo "Net watcher: ${NETWORK_WATCH_PLIST_PATH}"
echo "Log file:    ${LOG_DIR}/ddump.log"
