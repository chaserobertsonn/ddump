#!/bin/bash
set -euo pipefail

PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

LABEL="com.ddump"
NETWORK_WATCH_LABEL="com.ddump.network-watch"
CLOUD_IDLE_WATCH_LABEL="com.ddump.cloud-idle-watch"
DEFAULT_MOUNT_LABEL="com.ddump.rclone-gdrive"
OLD_MOUNT_LABEL="com.ddump.rclone-gdrive.legacy"
LEGACY_CHASE_MOUNT_LABEL="com.chase.rclone-gdrive"
APP_VERSION="${DDUMP_VERSION:-0.3.18}"
APP_BUILD="${DDUMP_BUILD:-$APP_VERSION}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

APP_SUPPORT_DIR="${HOME}/Library/Application Support/DDump"
BIN_DIR="${APP_SUPPORT_DIR}/bin"
STATE_DIR="${APP_SUPPORT_DIR}/state"
LOG_DIR="${APP_SUPPORT_DIR}/logs"
USER_CONFIG="${APP_SUPPORT_DIR}/config.env"
DEFAULT_CONFIG="${PROJECT_DIR}/config/config.env"
APP_BUNDLE="${HOME}/Applications/DDump.app"
PREBUILT_APP_BUNDLE="${PROJECT_DIR}/app/DDump.app"
MACOS_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.0}"
APP_SWIFT_SOURCES=("${PROJECT_DIR}/app/"*.swift "${PROJECT_DIR}/app/PaidLaunch/"*.swift)

if [[ -z "${DEVELOPER_DIR:-}" && -d "/Applications/Xcode.app/Contents/Developer" ]]; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi
SWIFTC="$(xcrun --find swiftc 2>/dev/null || command -v swiftc || true)"
MACOS_SDK="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"

LAUNCH_AGENT_DIR="${HOME}/Library/LaunchAgents"
PLIST_PATH="${LAUNCH_AGENT_DIR}/${LABEL}.plist"
OLD_MOUNT_PLIST_PATH="${LAUNCH_AGENT_DIR}/${OLD_MOUNT_LABEL}.plist"

uid="$(id -u)"

mkdir -p "$BIN_DIR" "$STATE_DIR" "$LOG_DIR" "$LAUNCH_AGENT_DIR"

# ---------------------------------------------------------------------------
# Copy scripts
# ---------------------------------------------------------------------------
for s in ddump.sh ddump-trust.sh ddump-monitor.sh ddump-control.sh \
         ddump-settings.sh ddump-debug-snapshot.sh \
         ddump-notify.sh ddump-cluster.sh ddump-calendar-lookup.sh \
         ddump-google-calendar.py \
         ddump-access-policy.sh rclone-gdrive-mount.sh ddump-network-watch.sh ddump-cloud-idle-watch.sh; do
  if [[ -f "${PROJECT_DIR}/bin/${s}" ]]; then
    cp "${PROJECT_DIR}/bin/${s}" "${BIN_DIR}/${s}"
    chmod +x "${BIN_DIR}/${s}"
  fi
done

# ---------------------------------------------------------------------------
# Install the Swift UI app. Packaged DMGs include a prebuilt universal app so
# friends do not need Xcode or Command Line Tools just to install DDump.
# ---------------------------------------------------------------------------
if [[ -d "$PREBUILT_APP_BUNDLE" ]]; then
  rm -rf "$APP_BUNDLE"
  mkdir -p "$(dirname "$APP_BUNDLE")"
  cp -R "$PREBUILT_APP_BUNDLE" "$APP_BUNDLE"
  /usr/bin/touch "$APP_BUNDLE"
  echo "Installed Mac app: ${APP_BUNDLE}"
elif [[ -f "${PROJECT_DIR}/app/DDumpApp.swift" ]]; then
  if [[ -n "$SWIFTC" ]]; then
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
  <key>NSHumanReadableCopyright</key>
  <string>Copyright © 2026 Chase Robertson</string>
  <key>CFBundleIdentifier</key>
  <string>com.ddump.app</string>
  <key>CFBundleVersion</key>
  <string>${APP_BUILD}</string>
  <key>CFBundleShortVersionString</key>
  <string>${APP_VERSION}</string>
  <key>CFBundleExecutable</key>
  <string>DDump</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIconName</key>
  <string>AppIcon</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>NSCalendarsFullAccessUsageDescription</key>
  <string>DDump uses calendar events to name shoot folders and resolve photo clusters between scheduled shoots.</string>
  <key>NSCalendarsUsageDescription</key>
  <string>DDump uses calendar events to name shoot folders and resolve photo clusters between scheduled shoots.</string>
</dict>
</plist>
PLIST
    if [[ -f "${PROJECT_DIR}/app/Assets/AppIcon.icns" ]]; then
      cp "${PROJECT_DIR}/app/Assets/AppIcon.icns" "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"
    fi
    if [[ -f "${PROJECT_DIR}/app/PrivacyInfo.xcprivacy" ]]; then
      cp "${PROJECT_DIR}/app/PrivacyInfo.xcprivacy" "${APP_BUNDLE}/Contents/Resources/PrivacyInfo.xcprivacy"
    fi
    if [[ -d "${PROJECT_DIR}/app/Assets/Fonts" ]]; then
      mkdir -p "${APP_BUNDLE}/Contents/Resources/Fonts"
      cp "${PROJECT_DIR}/app/Assets/Fonts"/*.otf "${APP_BUNDLE}/Contents/Resources/Fonts/" 2>/dev/null || true
      cp "${PROJECT_DIR}/app/Assets/Fonts/OFL.txt" "${APP_BUNDLE}/Contents/Resources/Fonts/OFL.txt"
    fi
    for asset in logo-icon.png logo-icon-512.png logo-mark.svg; do
      if [[ -f "${PROJECT_DIR}/app/Assets/${asset}" ]]; then
        cp "${PROJECT_DIR}/app/Assets/${asset}" "${APP_BUNDLE}/Contents/Resources/${asset}"
      fi
    done
    mkdir -p /private/tmp/ddump-clang-cache
    BUILD_TMP="$(mktemp -d "${TMPDIR:-/tmp}/ddump-swift-build.XXXXXX")"
    build_slice() {
      local arch="$1"
      local out="$2"
      local sdk_args=()
      if [[ -n "$MACOS_SDK" ]]; then
        sdk_args=(-sdk "$MACOS_SDK")
      fi
      CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/private/tmp/ddump-clang-cache}" \
        "$SWIFTC" -parse-as-library \
          "${sdk_args[@]}" \
          -target "${arch}-apple-macosx${MACOS_DEPLOYMENT_TARGET}" \
          -o "$out" \
          "${APP_SWIFT_SOURCES[@]}"
    }
    if build_slice "$(uname -m)" "${APP_BUNDLE}/Contents/MacOS/DDump"; then
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

# ---------------------------------------------------------------------------
# User config — keep existing, add missing keys, migrate renamed keys
# ---------------------------------------------------------------------------
fresh_config=0
if [[ ! -f "$USER_CONFIG" ]]; then
  fresh_config=1
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

append_csv_key_values() {
  local key="$1"
  local raw_values="$2"
  local current next changed
  current="$(config_value "$key" "")"
  changed=0
  IFS=',' read -r -a _append_values <<<"$raw_values"
  for next in "${_append_values[@]}"; do
    next="$(printf '%s' "$next" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ -n "$next" ]] || continue
    if [[ ",${current}," != *",${next},"* ]]; then
      if [[ -n "$current" ]]; then
        current="${current},${next}"
      else
        current="$next"
      fi
      changed=1
    fi
  done
  if [[ "$changed" == "1" ]]; then
    set_config_key "$key" "\"${current}\""
    echo "Updated ${key}: added ${raw_values}"
  fi
}

set_config_key() {
  local key="$1"
  local value="$2"
  if grep -q "^${key}=" "$USER_CONFIG"; then
    /usr/bin/sed -i '' "s|^${key}=.*|${key}=${value}|" "$USER_CONFIG"
  else
    /bin/echo "${key}=${value}" >>"$USER_CONFIG"
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

config_value() {
  local key="$1"
  local fallback="${2:-}"
  /usr/bin/awk -F= -v k="$key" -v fallback="$fallback" '
    $1 == k { v=$2 }
    END {
      gsub(/^"|"$/, "", v)
      if (v == "") v=fallback
      print v
    }
  ' "$USER_CONFIG"
}

preserve_existing_direct_cloud_upload() {
  if grep -q '^CLOUD_UPLOADS_ENABLED=' "$USER_CONFIG"; then
    return
  fi
  local mount_enabled direct_upload post_move_root
  mount_enabled="$(config_value 'GDRIVE_MOUNT_ENABLED' '0')"
  direct_upload="$(config_value 'GDRIVE_DIRECT_UPLOAD' '0')"
  post_move_root="$(config_value 'POST_MOVE_ROOT' '')"
  if [[ "$mount_enabled" == "1" && "$direct_upload" == "1" && "$post_move_root" == *'GoogleDrive'* ]]; then
    /bin/echo 'CLOUD_UPLOADS_ENABLED="1"' >>"$USER_CONFIG"
    /usr/bin/sed -i '' 's|^GDRIVE_MOUNT_ENABLED=.*|GDRIVE_MOUNT_ENABLED="0"|' "$USER_CONFIG"
    echo "Migrated direct cloud uploads: CLOUD_UPLOADS_ENABLED=1, managed mount disabled."
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
add_missing_key 'PROMPT_FOR_SOURCE_FOLDERS_ON_NEW_DRIVE' '"0"' "Advanced: prompt for folder selection the first time a trusted card UUID is seen; default scans the whole card within the lookback window."
replace_key_if_exact 'PROMPT_FOR_SOURCE_FOLDERS_ON_NEW_DRIVE' '1' '0'
add_missing_key 'DUMP_FALLBACK_ROOT' '"$HOME/Temp/DDump"' "Fallback dump folder when the configured dump folder is unavailable."
add_missing_key 'OPEN_APP_ON_CARD_INSERT' '"1"' "Bring DDump forward when a trusted card starts processing."
add_missing_key 'PROMPT_FOR_UNKNOWN_CARD_ACTION' '"1"'
add_missing_key 'SKIP_INTERNAL_VOLUMES' '"1"'
add_missing_key 'IGNORE_VOLUME_NAMES' '"Macintosh HD,Recovery,DDump,DDump *"'
replace_key_if_exact 'IGNORE_VOLUME_NAMES' 'Macintosh HD,Recovery' 'Macintosh HD,Recovery,DDump,DDump *'
append_csv_key_values 'IGNORE_VOLUME_NAMES' 'DDump,DDump *'
add_missing_key 'IGNORE_NO_UUID_VOLUMES' '"1"'
add_missing_key 'CAMERA_CARD_DETECTION_MODE' '"smart"' "Smart unknown-volume detection: skip installer/update volumes unless they look like camera cards."
add_missing_key 'CAMERA_CARD_MIN_MEDIA_FILES' '"3"'
add_missing_key 'CAMERA_CARD_SCAN_MAX_DEPTH' '"10"'
replace_key_if_exact 'CAMERA_CARD_SCAN_MAX_DEPTH' '6' '10'
add_missing_key 'CAMERA_CARD_HINT_DIRS' '"DCIM,PRIVATE,M4ROOT,CLIP,XDROOT,AVCHD,MP_ROOT,CANONMSC"'
add_missing_key 'CAMERA_CARD_REJECT_INSTALLER_SHAPES' '"1"'
add_missing_key 'CAMERA_CARD_WAIT_FOR_STABLE_INVENTORY' '"1"' "Wait for cameras and drones to expose media before classifying the volume."
replace_key_if_exact 'CAMERA_CARD_WAIT_FOR_STABLE_INVENTORY' '0' '1'
add_missing_key 'CAMERA_CARD_STABLE_SCAN_INTERVAL_SECONDS' '"1"'
replace_key_if_exact 'CAMERA_CARD_STABLE_SCAN_INTERVAL_SECONDS' '2' '1'
add_missing_key 'CAMERA_CARD_STABLE_SCAN_QUIET_SECONDS' '"5"'
add_missing_key 'CAMERA_CARD_STABLE_SCAN_MAX_WAIT_SECONDS' '"120"'
replace_key_if_exact 'CAMERA_CARD_STABLE_SCAN_MAX_WAIT_SECONDS' '30' '120'
add_missing_key 'PROMPT_NO_EJECT_ON_START' '"0"'
add_missing_key 'EJECT_TIMEOUT_SECONDS' '"20"' "Maximum seconds to wait for macOS card eject before continuing with upload."
add_missing_key 'SOURCE_SUBDIR_FALLBACK_ON_EMPTY_SELECTION' '"1"'
add_missing_key 'USE_FAST_SEEN_INDEX' '"1"'
add_missing_key 'DUMP_MEMORY_SCOPE' '"global"' "Exact duplicate protection across every dated folder under the Dump Folder."
add_missing_key 'MIN_FREE_SPACE_GB' '"5"' "Minimum local staging free space required before import; 0 disables."
replace_key_if_exact 'MIN_FREE_SPACE_GB' '100' '5'
add_missing_key 'FINDERSERVER_BIN' '"$HOME/.local/bin/finderserver"' "Helper command for starting/refreshing shared Finder mounts."
add_missing_key 'FINDERSERVER_TIMER_CHECK_SECONDS' '"300"' "During upload, check timer this often."
add_missing_key 'FINDERSERVER_TIMER_MIN_SECONDS' '"300"' "If timer is at/below this value, refresh it."
preserve_existing_direct_cloud_upload
add_missing_key 'CLOUD_UPLOADS_ENABLED' '"0"' "Enable cloud uploads. Google Drive Desktop local-folder copy is used by default; rclone is an advanced fallback."
add_missing_key 'ENABLE_POST_EJECT_MOVE' '"1"' "Copy staged files to the configured destination after local copy/eject. Staging is kept as the backup."
add_missing_key 'GDRIVE_MOUNT_ENABLED' '"0"' "Advanced: enable DDump-managed Finder mount automation instead of direct rclone uploads."
add_missing_key 'GDRIVE_DIRECT_UPLOAD' '"0"' "Advanced: upload Google Drive destinations directly with rclone copy instead of using the local Google Drive Desktop folder."
add_missing_key 'GDRIVE_MOUNT_POINT' '"$HOME/GoogleDrive"' "Mounted cloud folder path used for uploads."
add_missing_key 'GDRIVE_REMOTE' '"combined:"' "rclone remote/path mounted by DDump."
add_missing_key 'RCLONE_BIN' '"$HOME/bin/rclone"' "rclone binary path (fallback: command -v rclone)."
add_missing_key 'RCLONE_CACHE_DIR' '"$HOME/Library/Application Support/DDump/cache/rclone"' "DDump-owned rclone VFS cache directory."
add_missing_key 'RCLONE_MOUNT_COMMAND' '"auto"' "Mount command: auto (prefer macFUSE-backed rclone mount when available), mount, or nfsmount."
add_missing_key 'RCLONE_FILE_TIMEOUT_SECONDS' '"180"' "Maximum seconds to allow one direct rclone file upload before retrying later."
add_missing_key 'RCLONE_BATCH_TIMEOUT_SECONDS' '"3600"' "Maximum seconds to allow one direct rclone bucket upload before retrying later."
add_missing_key 'RCLONE_DRIVE_CHUNK_SIZE' '"8M"' "Google Drive upload chunk size for direct rclone uploads."
add_missing_key 'RCLONE_TPS_LIMIT' '"2"' "Maximum rclone HTTP transactions per second during direct cloud uploads."
add_missing_key 'RCLONE_TPS_BURST' '"2"' "Burst size for rclone HTTP transaction throttling."
add_missing_key 'GDRIVE_MOUNT_LABEL' '"com.ddump.rclone-gdrive"' "LaunchAgent label for DDump's mount helper."
add_missing_key 'GDRIVE_MOUNT_RETRY_SECONDS' '"15,30,60,180"' "Mount retry backoff schedule in seconds."
add_missing_key 'GDRIVE_MOUNT_WAIT_SECONDS' '"30"' "How long each mount attempt waits for readiness."
add_missing_key 'GDRIVE_ACTION_TIMEOUT_SECONDS' '"180"' "Maximum seconds DDump waits for a mount action before timing out."
add_missing_key 'CLOUD_IDLE_UNMOUNT_SECONDS' '"180"' "Unmount cloud drive after this many idle seconds without the DDump app or an active transfer."
add_missing_key 'PREVENT_FINDER_NETWORK_METADATA' '"1"' "Prevent Finder .DS_Store metadata writes from poisoning the combined rclone mount."
add_missing_key 'GOOGLE_DRIVE_DESKTOP_ENABLED' '"1"' "Allow DDump to launch Google Drive Desktop for local Drive-folder destinations."
add_missing_key 'GOOGLE_DRIVE_DESKTOP_RESTART_ON_FAILURE' '"1"' "Restart Google Drive Desktop once if a local Drive-folder destination is unavailable or frozen."
add_missing_key 'GOOGLE_DRIVE_DESKTOP_RESTART_DELAY_SECONDS' '"5"' "Seconds to wait between force-quitting Google Drive Desktop and relaunching it."
add_missing_key 'GOOGLE_DRIVE_DESKTOP_APP_NAME' '"Google Drive"' "macOS application name for Google Drive Desktop."
add_missing_key 'GOOGLE_DRIVE_DESKTOP_APP_PATH' '"/Applications/Google Drive.app"' "Fallback app path for Google Drive Desktop."
add_missing_key 'AUTO_LAUNCH_SYNC_APPS' '"1"' "Open Google Drive, Dropbox, Box, OneDrive, or pCloud when a Backup Folder needs that sync app."
add_missing_key 'SYNC_APP_READY_WAIT_SECONDS' '"8"' "Seconds to wait for a launched sync app to make its folder available."
replace_key_if_exact 'GDRIVE_MOUNT_RETRY_SECONDS' '5,15,60,180,360,600' '15,30,60,180'

if [[ "$(config_value 'CLOUD_UPLOADS_ENABLED' '0')" == "1" ]] \
  && [[ "$(config_value 'ENABLE_POST_EJECT_MOVE' '1')" != "1" ]]; then
  set_config_key 'ENABLE_POST_EJECT_MOVE' '"1"'
  echo "Re-enabled ENABLE_POST_EJECT_MOVE because cloud uploads are enabled."
fi

if [[ "$(config_value 'CLOUD_UPLOADS_ENABLED' '0')" == "1" ]] \
  && [[ "$(config_value 'GOOGLE_DRIVE_DESKTOP_ENABLED' '1')" == "1" ]] \
  && [[ "$(config_value 'GDRIVE_DIRECT_UPLOAD' '0')" == "1" ]]; then
  set_config_key 'GDRIVE_DIRECT_UPLOAD' '"0"'
  echo "Switched Google Drive uploads to local Google Drive Desktop copy mode; staging remains the backup."
fi

# v2 keys (new)
add_missing_key 'TRUSTED_NAME_PREFIXES' '""' "Volume name prefixes that auto-trust (comma-separated)."
add_missing_key 'REQUIRE_PHOTOS_OR_TRUSTED' '"1"' "Silent-skip non-photo volumes (no photo files, no trust)."
add_missing_key 'PHOTO_FILE_EXTENSIONS' '"jpg,jpeg,heic,heif,cr2,cr3,nef,arw,raf,dng,rw2,orf,pef,srw,tif,tiff,mp4,mov,m4v,avi,mts,m2ts,3gp,3gpp,insv,insp,gpr,braw,mxf,crm,r3d,ari,arri,cine"' "File extensions that count as photos for detection."
add_missing_key 'VIDEO_FILE_EXTENSIONS' '"mp4,mov,m4v,avi,mts,m2ts,3gp,3gpp,insv,gpr,braw,mxf,crm,r3d,ari,arri,cine"' "Extensions treated as video when SPLIT_PHOTO_VIDEO is enabled."
replace_key_if_exact 'PHOTO_FILE_EXTENSIONS' 'jpg,jpeg,heic,heif,cr2,cr3,nef,arw,raf,dng,rw2,orf,pef,srw,tif,tiff,mp4,mov,m4v,avi,mts,m2ts,3gp,3gpp,insv,insp,gpr' 'jpg,jpeg,heic,heif,cr2,cr3,nef,arw,raf,dng,rw2,orf,pef,srw,tif,tiff,mp4,mov,m4v,avi,mts,m2ts,3gp,3gpp,insv,insp,gpr,braw,mxf,crm,r3d,ari,arri,cine'
replace_key_if_exact 'VIDEO_FILE_EXTENSIONS' 'mp4,mov,m4v,avi,mts,m2ts,3gp,3gpp,insv,gpr' 'mp4,mov,m4v,avi,mts,m2ts,3gp,3gpp,insv,gpr,braw,mxf,crm,r3d,ari,arri,cine'
add_missing_key 'CAMERA_CARD_HINT_DIRS' '"DCIM,PRIVATE,M4ROOT,CLIP,XDROOT,AVCHD,MP_ROOT,CANONMSC,DJI,DJI_*,PANORAMA"' "Directory names that make a volume look like a camera card."
replace_key_if_exact 'CAMERA_CARD_HINT_DIRS' 'DCIM,PRIVATE,M4ROOT,CLIP,XDROOT,AVCHD,MP_ROOT,CANONMSC' 'DCIM,PRIVATE,M4ROOT,CLIP,XDROOT,AVCHD,MP_ROOT,CANONMSC,DJI,DJI_*,PANORAMA'
append_csv_key_values 'PHOTO_FILE_EXTENSIONS' 'dng,mp4,mov,m4v,srt,lrf'
append_csv_key_values 'VIDEO_FILE_EXTENSIONS' 'mp4,mov,m4v'
append_csv_key_values 'CAMERA_CARD_HINT_DIRS' 'DJI,DJI_*,PANORAMA'
add_missing_key 'PHOTO_RECENCY_HOURS' '"24"'
add_missing_key 'CANDIDATE_MODE' '"lookback"' "Import candidate scan mode: lookback keeps the scan limited to recent files."
add_missing_key 'LOOKBACK_HOURS' '"24"' "When CANDIDATE_MODE=lookback, only files newer than this many hours are considered."
add_missing_key 'USE_NOTIFICATIONS' '"1"' "Native macOS notifications instead of Terminal monitor."
add_missing_key 'BUG_REPORT_EMAIL' '"donna@densleyfilmandphoto.com"' "Email address used by the Send Bug Report button."
add_missing_key 'NOTIFICATION_TIMEOUT_SECONDS' '"60"'
add_missing_key 'FOLDER_NAMING_STRATEGY' '"sequential"' "How to name shoot folders: template | smart | calendar | sequential | custom | camera."
add_missing_key 'FOLDER_NAMING_FALLBACK' '"cluster"'
add_missing_key 'REBUCKET_PRESERVE_SOURCE_FOLDERS' '"0"' "Keep destination shoot folders flat; set 1 to preserve camera/source folder paths inside buckets."
add_missing_key 'FOLDER_NAME_TEMPLATE' '"{smart_camera} - {shoot} - {date_ymd}"' "Template strategy folder name; supports EXIF, calendar, date, sequence, and camera tokens."
add_missing_key 'SMART_CAMERA_LABEL_MODE' '"smart"' "Smart camera token mode: smart | brand | model | full."
add_missing_key 'FILE_RENAME_ENABLED' '"0"' "Optional filename replacement during folder rebucketing."
add_missing_key 'FILE_NAME_TEMPLATE' '"{filename}"' "Filename template. Extension is preserved automatically."
add_missing_key 'DEFAULT_SHOOT_NAME' '""' "Optional offline/default shoot label used when calendar naming has no event."
add_missing_key 'SMART_SAMPLE_PATH' '""' "Real shoot folder path used by smart naming to infer the daily Drive structure."
add_missing_key 'SMART_ASSIGN_EXISTING_FOLDERS' '"0"' "Advanced smart naming: map clusters into existing folders under today's Drive date folder."
replace_key_if_exact 'SMART_ASSIGN_EXISTING_FOLDERS' '1' '0'
add_missing_key 'SPLIT_PHOTO_VIDEO' '"0"' "Optional smart-mode split: videos go to the sibling 2 — Video date ladder."
add_missing_key 'FOLDER_NAME_SEQUENTIAL_PREFIX' '"Shoot-"'
add_missing_key 'FOLDER_NAME_CUSTOM_VALUES' '""'
add_missing_key 'FOLDER_NAME_UNCATEGORIZED' '"Uncategorized"'
add_missing_key 'CLUSTER_GAP_MINUTES' '"30"'
add_missing_key 'CLUSTER_FOLDER_TEMPLATE' '"Cluster {n} {start}-{end}"'
add_missing_key 'CLUSTER_GROUPING_ENABLED' '"1"' "When enabled, nearby capture times group together before naming."
add_missing_key 'CLUSTER_ATTACH_MINUTES' '"120"' "Across cards, reuse same-day shoot bucket when cluster is within this window."
add_missing_key 'CALENDAR_PROVIDER' '"apple"' "Calendar source for naming: none | google | apple | ics."
add_missing_key 'CALENDAR_AUTH_STATUS' '"not_authorized"' "Calendar wizard connection state."
add_missing_key 'GOOGLE_CALENDAR_CLIENT_ID' '"570098546449-737pvkselaqtncp2e6kdmhkf55eemche.apps.googleusercontent.com"' "Google Calendar desktop OAuth client ID for read-only calendar setup."
add_missing_key 'GOOGLE_CALENDAR_CLIENT_SECRET' '""' "Google Calendar desktop OAuth client secret. Desktop secrets are bundled/public identifiers, not user passwords."
add_missing_key 'CALENDAR_ICS_URL' '""' "Private ICS/webcal URL when CALENDAR_PROVIDER=ics."
add_missing_key 'CALENDAR_NAME' '""'
add_missing_key 'CALENDAR_IDS' '""' "Comma-separated Mac Calendar identifiers selected for shoot naming."
add_missing_key 'CALENDAR_EVENT_PADDING_MIN' '"15"'
add_missing_key 'CALENDAR_AMBIGUITY_PROMPTS_ENABLED' '"1"' "Ask about capture-time clusters outside scheduled calendar events."
add_missing_key 'POST_MOVE_ROOTS' '""' "Optional comma-separated list of additional final destinations."
add_missing_key 'POST_MOVE_FALLBACK_ROOT' '""' "Fallback destination when primary root is unavailable."
add_missing_key 'POST_MOVE_DATE_MODE' '"smart"' "Backup Folder layout: smart creates YYYY/YYYY.MM/YYYY.MM.DD under the chosen root; fixed copies directly into the chosen root."
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
add_missing_key 'NTFY_TOPIC' '""' "Optional ntfy topic for push alerts."
add_missing_key 'NTFY_NOTIFY_STAGING_STARTED' '"0"'
add_missing_key 'NTFY_NOTIFY_CARD_EJECTED' '"1"'
add_missing_key 'NTFY_NOTIFY_UPLOAD_STARTED' '"0"'
add_missing_key 'NTFY_NOTIFY_UPLOAD_COMPLETE' '"1"'
add_missing_key 'NTFY_NOTIFY_MOUNT_FAILED' '"0"'
add_missing_key 'NTFY_NOTIFY_CARD_ALMOST_FULL' '"1"'
add_missing_key 'NTFY_NOTIFY_INTEGRITY_WARNING' '"1"'
add_missing_key 'NTFY_NOTIFY_PENDING_RECOVERY_MISSING' '"1"'
add_missing_key 'MACOS_NOTIFY_STAGING_STARTED' '"1"'
add_missing_key 'MACOS_NOTIFICATIONS_ENABLED' '"1"' "Master switch for macOS notifications."
add_missing_key 'MACOS_NOTIFY_CARD_EJECTED' '"1"'
add_missing_key 'MACOS_NOTIFY_UPLOAD_STARTED' '"1"'
add_missing_key 'MACOS_NOTIFY_UPLOAD_COMPLETE' '"1"'
add_missing_key 'MACOS_NOTIFY_MOUNT_FAILED' '"0"'
add_missing_key 'MACOS_NOTIFY_CARD_ALMOST_FULL' '"1"'
add_missing_key 'MACOS_NOTIFY_INTEGRITY_WARNING' '"1"'
add_missing_key 'MACOS_NOTIFY_PENDING_RECOVERY_MISSING' '"1"'
add_missing_key 'NTFY_TEMPLATE_STAGING_STARTED' '"{message}"'
add_missing_key 'NTFY_TEMPLATE_CARD_EJECTED' '"{message}"'
add_missing_key 'NTFY_TEMPLATE_UPLOAD_STARTED' '"{message}"'
add_missing_key 'NTFY_TEMPLATE_UPLOAD_COMPLETE' '"{message}"'
add_missing_key 'NTFY_TEMPLATE_MOUNT_FAILED' '"{message}"'
add_missing_key 'NTFY_TEMPLATE_CARD_ALMOST_FULL' '"{message}"'
add_missing_key 'NTFY_TEMPLATE_INTEGRITY_WARNING' '"{message}"'
add_missing_key 'NTFY_TEMPLATE_PENDING_RECOVERY_MISSING' '"{import_time} import is missing {missing_count} of {total_count} items. Please reinsert the same card to retry."'
add_missing_key 'CARD_ALMOST_FULL_ALERT_ENABLED' '"1"' "Warn when free card space is below the size of the most recent import from that card."
add_missing_key 'NETWORK_RESUME_ENABLED' '"1"' "When internet reconnects and pending uploads exist, automatically trigger a retry run."
add_missing_key 'NETWORK_RESUME_CHECK_SECONDS' '"20"' "Network watcher poll interval."
add_missing_key 'NETWORK_RESUME_COOLDOWN_SECONDS' '"120"' "Minimum seconds between reconnect-triggered retry runs."
add_missing_key 'APP_COLOR_SCHEME' '"system"' "App appearance: system | light | dark."
if [[ "$fresh_config" == "1" ]]; then
  add_missing_key 'ONBOARDING_COMPLETED' '"0"' "First-run setup wizard completion flag."
else
  add_missing_key 'ONBOARDING_COMPLETED' '"1"' "First-run setup wizard completion flag."
  replace_key_if_exact 'ONBOARDING_COMPLETED' '0' '1'
fi
add_missing_key 'UPDATE_CHECKS_ENABLED' '"0"' "Enable public-release update checks."
add_missing_key 'AUTO_UPDATES_ENABLED' '"0"' "Automatically download signed Sparkle updates in migration-and-later builds; legacy builds open the bounded GitHub migration page."
add_missing_key 'UPDATE_CHECK_FREQUENCY' '"weekly"' "Update check cadence: startup | weekly | monthly."
add_missing_key 'UPDATE_GITHUB_REPO' '"chaserobertsonn/ddump"' "GitHub owner/repo used for release update checks."
add_missing_key 'BETA_UPDATES_OPT_IN' '"0"' "Explicit per-Mac beta update opt-in; eligibility is also required."
add_missing_key 'PAID_ACCESS_ENFORCEMENT' '"0"' "Production-disabled new-import entitlement enforcement."
add_missing_key 'ENTITLEMENT_PUBLIC_KEYS' '""' "Public entitlement verification keys as key-id:base64url entries."
add_missing_key 'ENTITLEMENT_MINIMUM_ISSUED_AT' '"0"' "Anti-rollback floor for signed entitlement issue time."
add_missing_key 'ENTITLEMENT_ISSUER' '"https://api.ddump.app"'
add_missing_key 'ENTITLEMENT_AUDIENCE' '"com.ddump.app"'
add_missing_key 'ENTITLEMENT_ENVIRONMENT' '"test"'
add_missing_key 'ENTITLEMENT_PRODUCT_IDS' '"ddump_test_monthly,ddump_test_annual"'
add_missing_key 'WINDOW_RESTORE_MODE' '"remember"' "Main window behavior: remember | compact | large."

normalize_escaped_home_path 'RCLONE_BIN'
normalize_escaped_home_path 'FINDERSERVER_BIN'
normalize_escaped_home_path 'DB_FILE'

if grep -q '^VERIFY_COPY_HASH="1"$' "$USER_CONFIG"; then
  /usr/bin/sed -i '' 's/^VERIFY_COPY_HASH="1"$/VERIFY_COPY_HASH="0"/' "$USER_CONFIG"
  echo "Updated VERIFY_COPY_HASH to 0 (size verification remains enabled; full hash verify is optional)."
fi

if grep -q '^REBUCKET_PRESERVE_SOURCE_FOLDERS="1"$' "$USER_CONFIG"; then
  /usr/bin/sed -i '' 's/^REBUCKET_PRESERVE_SOURCE_FOLDERS="1"$/REBUCKET_PRESERVE_SOURCE_FOLDERS="0"/' "$USER_CONFIG"
  echo "Updated REBUCKET_PRESERVE_SOURCE_FOLDERS to 0 so destination shoot folders do not nest DCIM/camera folders."
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
  /usr/bin/sed -i '' 's/^CANDIDATE_MODE="all"$/CANDIDATE_MODE="today"/' "$USER_CONFIG"
  echo "Updated CANDIDATE_MODE from \"all\" to \"lookback\" (recent-file import only)."
fi

if grep -q '^DB_ENABLED="1"$' "$USER_CONFIG"; then
  /usr/bin/sed -i '' 's/^DB_ENABLED="1"$/DB_ENABLED="0"/' "$USER_CONFIG"
  echo "Updated DB_ENABLED to 0 (staging-folder memory is now the default; SQLite remains optional beta)."
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
echo "  DDump queues normal alerts through the Mac app when available."
echo "  Action prompts can still use AppleScript dialogs when a direct user choice is required."
if command -v exiftool >/dev/null 2>&1; then
  echo "  ✓ exiftool installed — EXIF capture time used for clustering"
else
  echo "  ⚠ exiftool not found; cluster strategy falls back to file mtime"
  echo "    brew install exiftool"
fi
if command -v python3 >/dev/null 2>&1; then
  echo "  ✓ python3 detected — bundled Google Calendar OAuth helper can run"
else
  echo "  ⚠ python3 not found; Google Calendar OAuth helper cannot run on this Mac"
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
LEGACY_CHASE_MOUNT_PLIST_PATH="${LAUNCH_AGENT_DIR}/${LEGACY_CHASE_MOUNT_LABEL}.plist"
NETWORK_WATCH_PLIST_PATH="${LAUNCH_AGENT_DIR}/${NETWORK_WATCH_LABEL}.plist"
CLOUD_IDLE_WATCH_PLIST_PATH="${LAUNCH_AGENT_DIR}/${CLOUD_IDLE_WATCH_LABEL}.plist"

mount_enabled="$(config_value 'GDRIVE_MOUNT_ENABLED' '0')"
direct_upload="$(config_value 'GDRIVE_DIRECT_UPLOAD' '0')"

if [[ "$mount_enabled" == "1" && "$direct_upload" != "1" ]]; then
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

  # Compatibility mount agent for older DDump installs.
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
else
  launchctl bootout "gui/${uid}" "$MOUNT_PLIST_PATH" >/dev/null 2>&1 || true
  launchctl bootout "gui/${uid}" "$COMPAT_MOUNT_PLIST_PATH" >/dev/null 2>&1 || true
  launchctl bootout "gui/${uid}" "$LEGACY_CHASE_MOUNT_PLIST_PATH" >/dev/null 2>&1 || true
  launchctl bootout "gui/${uid}/${mount_label}" >/dev/null 2>&1 || true
  launchctl bootout "gui/${uid}/${OLD_MOUNT_LABEL}" >/dev/null 2>&1 || true
  launchctl bootout "gui/${uid}/${LEGACY_CHASE_MOUNT_LABEL}" >/dev/null 2>&1 || true
  /bin/rm -f "$MOUNT_PLIST_PATH" "$COMPAT_MOUNT_PLIST_PATH" "$LEGACY_CHASE_MOUNT_PLIST_PATH"
  echo "Skipped cloud mount LaunchAgents (direct upload mode or mount disabled)."
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

# ---------------------------------------------------------------------------
# Cloud idle unmount watcher (avoid long-lived stale rclone mounts)
# ---------------------------------------------------------------------------
if [[ "$mount_enabled" == "1" && "$direct_upload" != "1" ]]; then
  cat >"$CLOUD_IDLE_WATCH_PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${CLOUD_IDLE_WATCH_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${BIN_DIR}/ddump-cloud-idle-watch.sh</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>StartInterval</key>
  <integer>60</integer>
  <key>StandardOutPath</key>
  <string>${LOG_DIR}/cloud-idle-watch.stdout.log</string>
  <key>StandardErrorPath</key>
  <string>${LOG_DIR}/cloud-idle-watch.stderr.log</string>
  <key>ThrottleInterval</key>
  <integer>30</integer>
</dict>
</plist>
PLIST

  launchctl bootout "gui/${uid}" "$CLOUD_IDLE_WATCH_PLIST_PATH" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/${uid}" "$CLOUD_IDLE_WATCH_PLIST_PATH" >/dev/null 2>&1 || true
else
  launchctl bootout "gui/${uid}" "$CLOUD_IDLE_WATCH_PLIST_PATH" >/dev/null 2>&1 || true
  launchctl bootout "gui/${uid}/${CLOUD_IDLE_WATCH_LABEL}" >/dev/null 2>&1 || true
  /bin/rm -f "$CLOUD_IDLE_WATCH_PLIST_PATH"
  echo "Skipped cloud idle watcher (direct upload mode or mount disabled)."
fi

echo ""
echo "Installed DDump launch agent."
echo "Main script: ${BIN_DIR}/ddump.sh"
echo "Notifier:    ${BIN_DIR}/ddump-notify.sh"
echo "Cluster:     ${BIN_DIR}/ddump-cluster.sh"
echo "Calendar:    ${BIN_DIR}/ddump-calendar-lookup.sh"
echo "Config:      ${USER_CONFIG}"
echo "Mac app:     ${APP_BUNDLE}"
echo "LaunchAgent: ${PLIST_PATH}"
if [[ "$mount_enabled" == "1" && "$direct_upload" != "1" ]]; then
  echo "Mount agent: ${MOUNT_PLIST_PATH}"
  if [[ "$mount_label" != "$OLD_MOUNT_LABEL" ]]; then
    echo "Compat mount: ${COMPAT_MOUNT_PLIST_PATH}"
  fi
else
  echo "Mount agent: disabled (direct upload mode)"
fi
echo "Net watcher: ${NETWORK_WATCH_PLIST_PATH}"
if [[ "$mount_enabled" == "1" && "$direct_upload" != "1" ]]; then
  echo "Cloud idle:  ${CLOUD_IDLE_WATCH_PLIST_PATH}"
else
  echo "Cloud idle:  disabled (direct upload mode)"
fi
echo "Log file:    ${LOG_DIR}/ddump.log"
