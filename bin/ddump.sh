#!/bin/bash
set -euo pipefail

PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_SUPPORT_DIR="${HOME}/Library/Application Support/DDump"
STATE_DIR="${APP_SUPPORT_DIR}/state"
LOG_DIR="${APP_SUPPORT_DIR}/logs"
REPORT_DIR="${APP_SUPPORT_DIR}/reports"
DEFAULT_CONFIG_PATH="${SCRIPT_DIR}/../config/config.env"
USER_CONFIG_PATH="${APP_SUPPORT_DIR}/config.env"

mkdir -p "$STATE_DIR" "$LOG_DIR" "$REPORT_DIR"

LOG_FILE="${LOG_DIR}/ddump.log"
LOCK_DIR="${STATE_DIR}/run.lock"
RUN_LOCK_PID_FILE="${LOCK_DIR}/pid"

log() {
  local msg="$1"
  /bin/echo "$(/bin/date '+%Y-%m-%d %H:%M:%S') ${msg}" | /usr/bin/tee -a "$LOG_FILE" >/dev/null
}

notify() {
  local title="$1"
  local msg="$2"
  local kind="${3:-info}"   # info | warn | done
  local event_key="${4:-general}"
  if [[ "$event_key" != "general" ]] && [[ "$(macos_notify_enabled "$event_key")" != "1" ]]; then
    return
  fi
  if [[ "${USE_NOTIFICATIONS:-1}" != "1" ]]; then
    # Legacy mode: fall back to old toggle.
    if [[ "${ENABLE_NOTIFICATIONS:-0}" != "1" ]]; then
      return
    fi
    /usr/bin/osascript -e "tell application id \"com.ddump.app\" to display notification \"${msg//\"/\\\"}\" with title \"${title//\"/\\\"}\"" >/dev/null 2>&1 \
      || /usr/bin/osascript -e "display notification \"${msg//\"/\\\"}\" with title \"${title//\"/\\\"}\"" >/dev/null 2>&1 \
      || true
    return
  fi
  local notify_script="${APP_SUPPORT_DIR}/bin/ddump-notify.sh"
  if [[ -x "$notify_script" ]]; then
    DDUMP_NOTIFIER_TIMEOUT="${NOTIFICATION_TIMEOUT_SECONDS:-60}" \
      DDUMP_NOTIFIER_SENDER="com.ddump.app" \
      DDUMP_NOTIFIER_APP_ID="com.ddump.app" \
      /bin/bash "$notify_script" "$kind" "$title" "$msg" >/dev/null 2>&1 || true
  else
    /usr/bin/osascript -e "tell application id \"com.ddump.app\" to display notification \"${msg//\"/\\\"}\" with title \"${title//\"/\\\"}\"" >/dev/null 2>&1 \
      || /usr/bin/osascript -e "display notification \"${msg//\"/\\\"}\" with title \"${title//\"/\\\"}\"" >/dev/null 2>&1 \
      || true
  fi
}

macos_notify_enabled() {
  local event_key="$1"
  case "$event_key" in
    staging_started) printf '%s' "${MACOS_NOTIFY_STAGING_STARTED:-1}" ;;
    card_ejected) printf '%s' "${MACOS_NOTIFY_CARD_EJECTED:-1}" ;;
    upload_started) printf '%s' "${MACOS_NOTIFY_UPLOAD_STARTED:-1}" ;;
    upload_complete) printf '%s' "${MACOS_NOTIFY_UPLOAD_COMPLETE:-1}" ;;
    mount_failed) printf '%s' "${MACOS_NOTIFY_MOUNT_FAILED:-0}" ;;
    card_almost_full) printf '%s' "${MACOS_NOTIFY_CARD_ALMOST_FULL:-1}" ;;
    integrity_warning) printf '%s' "${MACOS_NOTIFY_INTEGRITY_WARNING:-1}" ;;
    pending_recovery_missing) printf '%s' "${MACOS_NOTIFY_PENDING_RECOVERY_MISSING:-1}" ;;
    *) printf '1' ;;
  esac
}

notify_ask() {
  # Returns the clicked-button text on stdout (or empty string).
  local title="$1"
  local msg="$2"
  shift 2
  local notify_script="${APP_SUPPORT_DIR}/bin/ddump-notify.sh"
  if [[ -x "$notify_script" ]]; then
    DDUMP_NOTIFIER_TIMEOUT="${NOTIFICATION_TIMEOUT_SECONDS:-60}" \
      /bin/bash "$notify_script" ask "$title" "$msg" "$@" 2>/dev/null || true
  else
    printf ''
  fi
}

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/}"
  s="${s//$'\t'/ }"
  printf '%s' "$s"
}

slack_notify() {
  local text="$1"
  local webhook="${SLACK_WEBHOOK_URL:-}"
  [[ -n "$webhook" ]] || return 0

  local payload
  payload="{\"text\":\"$(json_escape "$text")\"}"
  if ! /usr/bin/curl -fsS -m 10 \
    -H 'Content-Type: application/json' \
    --data "$payload" \
    "$webhook" >/dev/null 2>&1; then
    log "Slack notification failed."
    return 1
  fi
}

ntfy_notify() {
  local event_key="$1"
  local title="$2"
  local text="$3"
  shift 3
  if [[ "$event_key" == "mount_failed" ]]; then
    log "Suppressing mount_failed ntfy; DDump no longer uses managed Google Drive mounts."
    return 0
  fi
  local topic="${NTFY_TOPIC:-}"
  [[ -n "$topic" ]] || return 0

  local enabled_key=""
  local template_key=""
  case "$event_key" in
    staging_started) enabled_key="${NTFY_NOTIFY_STAGING_STARTED:-0}"; template_key="NTFY_TEMPLATE_STAGING_STARTED" ;;
    card_ejected) enabled_key="${NTFY_NOTIFY_CARD_EJECTED:-1}"; template_key="NTFY_TEMPLATE_CARD_EJECTED" ;;
    upload_started) enabled_key="${NTFY_NOTIFY_UPLOAD_STARTED:-0}"; template_key="NTFY_TEMPLATE_UPLOAD_STARTED" ;;
    upload_complete) enabled_key="${NTFY_NOTIFY_UPLOAD_COMPLETE:-1}"; template_key="NTFY_TEMPLATE_UPLOAD_COMPLETE" ;;
    mount_failed) enabled_key="${NTFY_NOTIFY_MOUNT_FAILED:-0}"; template_key="NTFY_TEMPLATE_MOUNT_FAILED" ;;
    card_almost_full) enabled_key="${NTFY_NOTIFY_CARD_ALMOST_FULL:-1}"; template_key="NTFY_TEMPLATE_CARD_ALMOST_FULL" ;;
    integrity_warning) enabled_key="${NTFY_NOTIFY_INTEGRITY_WARNING:-1}"; template_key="NTFY_TEMPLATE_INTEGRITY_WARNING" ;;
    pending_recovery_missing) enabled_key="${NTFY_NOTIFY_PENDING_RECOVERY_MISSING:-1}"; template_key="NTFY_TEMPLATE_PENDING_RECOVERY_MISSING" ;;
    *) enabled_key="0" ;;
  esac
  [[ "$enabled_key" == "1" ]] || return 0

  local template="${!template_key:-}"
  if [[ -n "$template" ]]; then
    text="$(render_notification_template "$template" "title=$title" "event=$event_key" "message=$text" "$@")"
  fi

  local sender_host
  sender_host="$(/usr/sbin/scutil --get ComputerName 2>/dev/null || /bin/hostname 2>/dev/null || printf 'unknown-mac')"
  local body
  body="$(printf '%s\n%s\n%s\nsource=%s' "$title" "$event_key" "$text" "$sender_host")"
  if ! /usr/bin/curl -fsS -m 10 \
    -H "Title: ${title}" \
    -H "Tags: camera" \
    -H "X-DDump-Source: ${sender_host}" \
    --data-binary "$body" \
    "https://ntfy.sh/${topic}" >/dev/null 2>&1; then
    log "ntfy notification failed for event=${event_key} topic=${topic}"
    return 1
  fi
}

render_notification_template() {
  local rendered="$1"
  shift
  local pair key value
  for pair in "$@"; do
    key="${pair%%=*}"
    value="${pair#*=}"
    rendered="${rendered//\{$key\}/$value}"
  done
  printf '%s' "$rendered"
}

notification_dedupe_allows() {
  local event_key="$1"
  local fingerprint="$2"
  local cooldown_hours="${NOTIFICATION_DEDUPE_HOURS:-12}"
  if ! [[ "$cooldown_hours" =~ ^[0-9]+$ ]]; then
    cooldown_hours="12"
  fi
  local cooldown_seconds=$((cooldown_hours * 3600))
  local digest marker_dir marker now mtime
  digest="$(printf '%s' "${event_key}:${fingerprint}" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')"
  marker_dir="${STATE_DIR}/notification_dedupe"
  marker="${marker_dir}/${event_key}.${digest}.sent"
  /bin/mkdir -p "$marker_dir"
  now="$(/bin/date '+%s')"
  if [[ -f "$marker" ]]; then
    mtime="$(/usr/bin/stat -f '%m' "$marker" 2>/dev/null || echo 0)"
    if [[ "$mtime" =~ ^[0-9]+$ ]] && (( now - mtime < cooldown_seconds )); then
      return 1
    fi
  fi
  /usr/bin/touch "$marker"
  return 0
}

is_trusted_name_prefix() {
  local vol_name="$1"
  local raw_list="${TRUSTED_NAME_PREFIXES:-}"
  [[ -n "$raw_list" ]] || return 1
  local item
  IFS=',' read -r -a _prefix_list <<<"$raw_list"
  for item in "${_prefix_list[@]}"; do
    item="$(trim "$item")"
    [[ -n "$item" ]] || continue
    if [[ "$vol_name" == "${item}"* ]]; then
      return 0
    fi
  done
  return 1
}

volume_has_photos() {
  # Quick scan: does the volume contain at least one file matching PHOTO_FILE_EXTENSIONS?
  # Caps at 4 dirs deep, bails on first match.
  local vol_path="$1"
  local raw_list="${PHOTO_FILE_EXTENSIONS:-}"
  [[ -n "$raw_list" ]] || return 1

  local find_args=()
  local item
  IFS=',' read -r -a _ext_list <<<"$raw_list"
  local first=1
  find_args+=(\( )
  for item in "${_ext_list[@]}"; do
    item="$(trim "$item")"
    [[ -n "$item" ]] || continue
    item="${item#.}"
    if [[ "$first" -eq 0 ]]; then
      find_args+=(-o)
    fi
    find_args+=(-iname "*.${item}")
    first=0
  done
  find_args+=(\) )

  local hit
  hit="$(/usr/bin/find "$vol_path" -maxdepth 4 -type f "${find_args[@]}" -print -quit 2>/dev/null)"
  [[ -n "$hit" ]]
}

photo_find_name_args() {
  local raw_list="${PHOTO_FILE_EXTENSIONS:-}"
  [[ -n "$raw_list" ]] || return 1

  local item first=1
  IFS=',' read -r -a _ext_list <<<"$raw_list"
  printf '%s\0' '('
  for item in "${_ext_list[@]}"; do
    item="$(trim "$item")"
    [[ -n "$item" ]] || continue
    item="${item#.}"
    if [[ "$first" -eq 0 ]]; then
      printf '%s\0' '-o'
    fi
    printf '%s\0%s\0' '-iname' "*.${item}"
    first=0
  done
  printf '%s\0' ')'
}

camera_card_media_sample_count() {
  local vol_path="$1"
  local max_depth limit count
  max_depth="$(sanitize_positive_int "${CAMERA_CARD_SCAN_MAX_DEPTH:-6}" "6")"
  limit="$(sanitize_positive_int "${CAMERA_CARD_MIN_MEDIA_FILES:-3}" "3")"
  [[ "$limit" -lt 1 ]] && limit=1

  local find_args=()
  local token
  while IFS= read -r -d '' token; do
    find_args+=("$token")
  done < <(photo_find_name_args)

  count="$(/usr/bin/find "$vol_path" -maxdepth "$max_depth" -type f "${find_args[@]}" -print 2>/dev/null \
    | /usr/bin/head -n "$limit" \
    | /usr/bin/wc -l \
    | /usr/bin/awk '{print $1}')"
  printf '%s' "${count:-0}"
}

volume_has_camera_hint_dir() {
  local vol_path="$1"
  local raw_list="${CAMERA_CARD_HINT_DIRS:-}"
  [[ -n "$raw_list" ]] || return 1

  local item hint_base
  IFS=',' read -r -a _hint_list <<<"$raw_list"
  for item in "${_hint_list[@]}"; do
    item="$(trim "$item")"
    [[ -n "$item" ]] || continue
    if [[ -d "${vol_path}/${item}" ]]; then
      return 0
    fi
    hint_base="$(
      /usr/bin/find "$vol_path" -maxdepth 4 -type d -name "$item" -print -quit 2>/dev/null || true
    )"
    if [[ -n "$hint_base" ]]; then
      return 0
    fi
  done
  return 1
}

camera_card_media_sample_count_under() {
  local root_path="$1"
  local max_depth limit count
  [[ -d "$root_path" ]] || { printf '0'; return; }
  max_depth="$(sanitize_positive_int "${CAMERA_CARD_SCAN_MAX_DEPTH:-6}" "6")"
  limit="$(sanitize_positive_int "${CAMERA_CARD_MIN_MEDIA_FILES:-3}" "3")"
  [[ "$limit" -lt 1 ]] && limit=1

  local find_args=()
  local token
  while IFS= read -r -d '' token; do
    find_args+=("$token")
  done < <(photo_find_name_args)

  count="$(/usr/bin/find "$root_path" -maxdepth "$max_depth" -type f "${find_args[@]}" -print 2>/dev/null \
    | /usr/bin/head -n "$limit" \
    | /usr/bin/wc -l \
    | /usr/bin/awk '{print $1}')"
  printf '%s' "${count:-0}"
}

volume_has_installer_shape() {
  local vol_path="$1"
  local hit
  hit="$(/usr/bin/find "$vol_path" -maxdepth 2 \( \
      -name '*.app' -o \
      -name '*.pkg' -o \
      -name '*.mpkg' -o \
      -name '*.dmg' -o \
      -name '.background' -o \
      -name 'Applications' \
    \) -print -quit 2>/dev/null || true)"
  [[ -n "$hit" ]]
}

volume_looks_like_camera_card() {
  local vol_path="$1"
  local mode="${CAMERA_CARD_DETECTION_MODE:-smart}"
  local min_media media_count dcim_media_count has_hint=0 has_installer=0

  if [[ "$mode" == "off" || "$mode" == "photos" ]]; then
    volume_has_photos "$vol_path"
    return
  fi

  if volume_has_camera_hint_dir "$vol_path"; then
    has_hint=1
  fi
  if [[ "${CAMERA_CARD_REJECT_INSTALLER_SHAPES:-1}" == "1" ]] && volume_has_installer_shape "$vol_path"; then
    has_installer=1
  fi

  min_media="$(sanitize_positive_int "${CAMERA_CARD_MIN_MEDIA_FILES:-3}" "3")"
  [[ "$min_media" -lt 1 ]] && min_media=1
  media_count="$(camera_card_media_sample_count "$vol_path")"
  [[ "$media_count" =~ ^[0-9]+$ ]] || media_count=0
  dcim_media_count="$(camera_card_media_sample_count_under "${vol_path}/DCIM")"
  [[ "$dcim_media_count" =~ ^[0-9]+$ ]] || dcim_media_count=0

  if [[ "$has_installer" -eq 1 && "$has_hint" -ne 1 ]]; then
    return 1
  fi
  if [[ "$dcim_media_count" -ge "$min_media" ]]; then
    return 0
  fi
  if [[ "$has_hint" -eq 1 && "$media_count" -ge 1 ]]; then
    return 0
  fi
  if [[ "$media_count" -ge "$min_media" ]]; then
    return 0
  fi
  return 1
}

count_recent_photos_on_volume() {
  # Returns: "<total>\t<recent>" — number of photo files, and number modified within PHOTO_RECENCY_HOURS.
  local vol_path="$1"
  local recent_hours="${PHOTO_RECENCY_HOURS:-24}"
  local raw_list="${PHOTO_FILE_EXTENSIONS:-}"
  [[ -n "$raw_list" ]] || { printf '0\t0'; return; }

  local find_args=()
  local item
  IFS=',' read -r -a _ext_list <<<"$raw_list"
  local first=1
  find_args+=(\( )
  for item in "${_ext_list[@]}"; do
    item="$(trim "$item")"
    [[ -n "$item" ]] || continue
    item="${item#.}"
    if [[ "$first" -eq 0 ]]; then
      find_args+=(-o)
    fi
    find_args+=(-iname "*.${item}")
    first=0
  done
  find_args+=(\) )

  local total recent hours
  hours="$(sanitize_positive_int "$recent_hours" "24")"
  total="$(/usr/bin/find "$vol_path" -maxdepth 6 -type f "${find_args[@]}" 2>/dev/null | /usr/bin/wc -l | /usr/bin/awk '{print $1}')"
  recent="$(/usr/bin/find "$vol_path" -maxdepth 6 -type f "${find_args[@]}" -print0 2>/dev/null \
    | /usr/bin/perl -0ne 'BEGIN { $hours = shift @ARGV; $cutoff = time - ($hours * 3600); $count = 0 } chomp; $count++ if -f $_ && (stat($_))[9] >= $cutoff; END { print $count }' "$hours")"
  printf '%s\t%s\n' "$total" "$recent"
}

trim() {
  local s="$1"
  s="${s#${s%%[![:space:]]*}}"
  s="${s%${s##*[![:space:]]}}"
  printf '%s' "$s"
}

acquire_run_lock() {
  if /bin/mkdir "$LOCK_DIR" 2>/dev/null; then
    /bin/echo "$$" >"$RUN_LOCK_PID_FILE"
    return 0
  fi

  local existing_pid=""
  if [[ -f "$RUN_LOCK_PID_FILE" ]]; then
    existing_pid="$(/bin/cat "$RUN_LOCK_PID_FILE" 2>/dev/null || true)"
  fi
  if [[ "$existing_pid" =~ ^[0-9]+$ ]] && /bin/kill -0 "$existing_pid" >/dev/null 2>&1; then
    log "Another run is in progress (pid ${existing_pid}); exiting."
    exit 0
  fi

  local now lock_mtime lock_age
  now="$(/bin/date '+%s')"
  lock_mtime="$(/usr/bin/stat -f '%m' "$LOCK_DIR" 2>/dev/null || echo 0)"
  lock_age=$((now - lock_mtime))
  if [[ "$lock_age" -lt 900 ]]; then
    log "Run lock exists without a live owner but is recent (${lock_age}s old); exiting."
    exit 0
  fi

  log "Removing stale run lock (${lock_age}s old, previous pid: ${existing_pid:-none})."
  /bin/rm -f "$RUN_LOCK_PID_FILE" 2>/dev/null || true
  /bin/rmdir "$LOCK_DIR" 2>/dev/null || true
  if ! /bin/mkdir "$LOCK_DIR" 2>/dev/null; then
    log "Another run acquired the lock; exiting."
    exit 0
  fi
  /bin/echo "$$" >"$RUN_LOCK_PID_FILE"
}

release_run_lock() {
  local owner_pid=""
  if [[ -f "$RUN_LOCK_PID_FILE" ]]; then
    owner_pid="$(/bin/cat "$RUN_LOCK_PID_FILE" 2>/dev/null || true)"
  fi
  if [[ "$owner_pid" == "$$" ]]; then
    /bin/rm -f "$RUN_LOCK_PID_FILE" 2>/dev/null || true
    /bin/rmdir "$LOCK_DIR" 2>/dev/null || true
  fi
}

acquire_run_lock
cleanup() {
  stop_finderserver_timer_guard 2>/dev/null || true
  /bin/rm -f "${PAUSE_FLAG:-}" "${STOP_AFTER_FILE_FLAG:-}" "${KEEP_MOUNTED_FLAG:-}" "${EJECT_NOW_FLAG:-}" 2>/dev/null || true
  release_run_lock
}
trap cleanup EXIT

# Defaults (overridden by config.env then user config.env)
DEST_ROOT="$HOME/Temp"
DUMP_FALLBACK_ROOT="$HOME/Temp/DDump"
LOOKBACK_HOURS="24"
CANDIDATE_MODE="lookback"
SOURCE_SUBDIR="DCIM"
TRUSTED_NAME_PREFIXES=""
PROMPT_TO_REMEMBER_UNKNOWN="1"
PROMPT_FOR_UNKNOWN_CARD_ACTION="1"
SKIP_INTERNAL_VOLUMES="1"
IGNORE_VOLUME_NAMES="Macintosh HD,Recovery"
IGNORE_NO_UUID_VOLUMES="1"
PROMPT_FOR_SOURCE_FOLDERS_ON_NEW_DRIVE="0"
OPEN_APP_ON_CARD_INSERT="1"
CREATE_DAILY_FOLDER="1"
DAILY_FOLDER_FORMAT="%Y-%m-%d-ddump"
EJECT_ON_SUCCESS="1"
PROMPT_NO_EJECT_ON_START="0"
EJECT_TIMEOUT_SECONDS="20"
EJECT_GRACE_SECONDS="60"
ENABLE_NOTIFICATIONS="0"
USE_NOTIFICATIONS="1"
NOTIFICATION_TIMEOUT_SECONDS="60"
SHOW_PROGRESS_WINDOW="0"
SHOW_RUN_SUMMARY_DIALOG="0"
SUMMARY_DIALOG_TIMEOUT_SECONDS="20"
VERIFY_COPIED_FILES="1"
VERIFY_COPY_HASH="0"
POST_MOVE_REQUIRE_READY="1"
MIN_FREE_SPACE_GB="100"
MISSED_REPORT_MAX_ROWS="5000"
WRITE_DAILY_DIGEST="1"
UPLOAD_RECEIPTS_ENABLED="1"
DB_ENABLED="0"
DB_FILE="${STATE_DIR}/ddump.sqlite3"
HASH_BEFORE_COPY="0"
UPLOAD_RETRY_MINUTES="3,10,60,240"
FILE_EXTENSIONS=""
MANIFEST_RETENTION_DAYS="0"
USE_FAST_SEEN_INDEX="1"
SOURCE_SUBDIR_FALLBACK_ON_EMPTY_SELECTION="1"
REQUIRE_PHOTOS_OR_TRUSTED="1"
PHOTO_FILE_EXTENSIONS="jpg,jpeg,heic,heif,cr2,cr3,nef,arw,raf,dng,rw2,orf,pef,srw,tif,tiff,mp4,mov,m4v,avi,mts,m2ts,3gp,3gpp,insv,insp,gpr,srt,lrf,braw,mxf,crm,r3d,ari,arri,cine"
VIDEO_FILE_EXTENSIONS="mp4,mov,m4v,avi,mts,m2ts,3gp,3gpp,insv,gpr,braw,mxf,crm,r3d,ari,arri,cine"
PHOTO_RECENCY_HOURS="24"
CAMERA_CARD_DETECTION_MODE="smart"
CAMERA_CARD_MIN_MEDIA_FILES="3"
CAMERA_CARD_SCAN_MAX_DEPTH="10"
CAMERA_CARD_HINT_DIRS="DCIM,PRIVATE,M4ROOT,CLIP,XDROOT,AVCHD,MP_ROOT,CANONMSC,DJI,DJI_*,PANORAMA"
CAMERA_CARD_REJECT_INSTALLER_SHAPES="1"
CLOUD_UPLOADS_ENABLED="0"
ENABLE_POST_EJECT_MOVE="1"
POST_MOVE_ROOT=""
POST_MOVE_ROOTS=""
POST_MOVE_FALLBACK_ROOT=""
POST_MOVE_YEAR_FORMAT="%Y"
POST_MOVE_MONTH_FORMAT="%Y.%m"
POST_MOVE_DAY_FORMAT="%Y.%m.%d"
FOLDER_NAMING_STRATEGY="sequential"
FOLDER_NAMING_FALLBACK="cluster"
REBUCKET_PRESERVE_SOURCE_FOLDERS="0"
FOLDER_NAME_TEMPLATE="{smart_camera} - {shoot} - {date_ymd}"
SMART_CAMERA_LABEL_MODE="smart"
FILE_RENAME_ENABLED="0"
FILE_NAME_TEMPLATE="{filename}"
DEFAULT_SHOOT_NAME=""
SMART_SAMPLE_PATH=""
SMART_ASSIGN_EXISTING_FOLDERS="0"
SPLIT_PHOTO_VIDEO="0"
FOLDER_NAME_SEQUENTIAL_PREFIX="Shoot-"
FOLDER_NAME_CUSTOM_VALUES=""
FOLDER_NAME_UNCATEGORIZED="Uncategorized"
CLUSTER_GAP_MINUTES="30"
CLUSTER_FOLDER_TEMPLATE="Cluster {n} {start}-{end}"
CLUSTER_GROUPING_ENABLED="1"
CLUSTER_ATTACH_MINUTES="120"
CALENDAR_NAME=""
CALENDAR_EVENT_PADDING_MIN="15"
TRUSTED_UUID_FILE="${STATE_DIR}/trusted_uuids.txt"
MANIFEST_FILE="${STATE_DIR}/imported_manifest.tsv"
RUN_HISTORY_FILE="${STATE_DIR}/run_history.tsv"
SOURCE_ROOTS_FILE="${STATE_DIR}/source_roots.tsv"
BLOCKED_UUID_FILE="${STATE_DIR}/blocked_uuids.txt"
CARD_POLICY_FILE="${STATE_DIR}/card_policy.tsv"
FAST_SEEN_FILE="${STATE_DIR}/fast_seen.tsv"
SHOOT_CLUSTER_MAP_FILE="${STATE_DIR}/shoot_cluster_map.tsv"
PENDING_DIR="${STATE_DIR}/pending_uploads"
STATUS_FILE="${STATE_DIR}/run_status.env"
LAST_SKIPPED_VOLUME_FILE="${STATE_DIR}/last_skipped_volume.env"
CONTROL_DIR="${STATE_DIR}/control"
PAUSE_FLAG="${CONTROL_DIR}/pause.flag"
STOP_AFTER_FILE_FLAG="${CONTROL_DIR}/stop_after_file.flag"
KEEP_MOUNTED_FLAG="${CONTROL_DIR}/keep_mounted.flag"
EJECT_NOW_FLAG="${CONTROL_DIR}/eject_now.flag"
MANUAL_SHOOT_NAME_FILE="${CONTROL_DIR}/manual_shoot_name.txt"
MANUAL_SELECTION_FILE="${DDUMP_MANUAL_SELECTION_FILE:-}"
MANUAL_SELECTION_POLICY_FILE="${CONTROL_DIR}/manual_import_policy.txt"
MANUAL_SELECTION_SAFETY_GB="${DDUMP_MANUAL_SELECTION_SAFETY_GB:-2}"
FINDERSERVER_BIN="${HOME}/.local/bin/finderserver"
FINDERSERVER_TIMER_CHECK_SECONDS="300"
FINDERSERVER_TIMER_MIN_SECONDS="300"
FINDERSERVER_GUARD_PID_FILE="${STATE_DIR}/finderserver-guard.pid"
GDRIVE_MOUNT_ENABLED="0"
GDRIVE_DIRECT_UPLOAD="0"
GDRIVE_MOUNT_POINT="${HOME}/GoogleDrive"
GDRIVE_REMOTE="combined:"
RCLONE_BIN="${HOME}/bin/rclone"
RCLONE_FILE_TIMEOUT_SECONDS="180"
RCLONE_BATCH_TIMEOUT_SECONDS="3600"
RCLONE_DRIVE_CHUNK_SIZE="8M"
RCLONE_TPS_LIMIT="2"
RCLONE_TPS_BURST="2"
GDRIVE_MOUNT_LABEL="com.ddump.rclone-gdrive"
GDRIVE_MOUNT_RETRY_SECONDS="15,30,60,180"
GDRIVE_MOUNT_WAIT_SECONDS="30"
GOOGLE_DRIVE_DESKTOP_ENABLED="1"
GOOGLE_DRIVE_DESKTOP_RESTART_ON_FAILURE="1"
GOOGLE_DRIVE_DESKTOP_RESTART_DELAY_SECONDS="5"
GOOGLE_DRIVE_DESKTOP_APP_NAME="Google Drive"
GOOGLE_DRIVE_DESKTOP_APP_PATH="/Applications/Google Drive.app"
AUTO_LAUNCH_SYNC_APPS="1"
SYNC_APP_READY_WAIT_SECONDS="8"
NTFY_TOPIC=""
NTFY_NOTIFY_STAGING_STARTED="0"
NTFY_NOTIFY_CARD_EJECTED="1"
NTFY_NOTIFY_UPLOAD_STARTED="0"
NTFY_NOTIFY_UPLOAD_COMPLETE="1"
NTFY_NOTIFY_MOUNT_FAILED="0"
NTFY_NOTIFY_CARD_ALMOST_FULL="1"
NTFY_NOTIFY_INTEGRITY_WARNING="1"
NTFY_NOTIFY_PENDING_RECOVERY_MISSING="1"
MACOS_NOTIFY_STAGING_STARTED="1"
MACOS_NOTIFY_CARD_EJECTED="1"
MACOS_NOTIFY_UPLOAD_STARTED="1"
MACOS_NOTIFY_UPLOAD_COMPLETE="1"
MACOS_NOTIFY_MOUNT_FAILED="0"
MACOS_NOTIFY_CARD_ALMOST_FULL="1"
MACOS_NOTIFY_INTEGRITY_WARNING="1"
MACOS_NOTIFY_PENDING_RECOVERY_MISSING="1"
NTFY_TEMPLATE_STAGING_STARTED="{message}"
NTFY_TEMPLATE_CARD_EJECTED="{message}"
NTFY_TEMPLATE_UPLOAD_STARTED="{message}"
NTFY_TEMPLATE_UPLOAD_COMPLETE="{message}"
NTFY_TEMPLATE_MOUNT_FAILED="{message}"
NTFY_TEMPLATE_CARD_ALMOST_FULL="{message}"
NTFY_TEMPLATE_INTEGRITY_WARNING="{message}"
NTFY_TEMPLATE_PENDING_RECOVERY_MISSING="{import_time} import is missing {missing_count} of {total_count} items. Please reinsert the same card to retry."
CARD_ALMOST_FULL_ALERT_ENABLED="1"
APP_COLOR_SCHEME="system"

if [[ -f "$DEFAULT_CONFIG_PATH" ]]; then
  # shellcheck disable=SC1090
  source "$DEFAULT_CONFIG_PATH"
fi

if [[ -f "$USER_CONFIG_PATH" ]]; then
  # shellcheck disable=SC1090
  source "$USER_CONFIG_PATH"
fi

manual_selection_active=0
if [[ -n "$MANUAL_SELECTION_FILE" ]]; then
  if [[ -f "$MANUAL_SELECTION_FILE" ]]; then
    manual_selection_active=1
    log "Manual selection mode enabled via DDUMP_MANUAL_SELECTION_FILE=${MANUAL_SELECTION_FILE}"
  else
    log "Manual selection file not found: ${MANUAL_SELECTION_FILE} (continuing with normal scan mode)"
    MANUAL_SELECTION_FILE=""
  fi
fi

mkdir -p "$(dirname "$TRUSTED_UUID_FILE")" "$(dirname "$MANIFEST_FILE")"
[[ -f "$TRUSTED_UUID_FILE" ]] || : > "$TRUSTED_UUID_FILE"
[[ -f "$MANIFEST_FILE" ]] || : > "$MANIFEST_FILE"
[[ -f "$RUN_HISTORY_FILE" ]] || : > "$RUN_HISTORY_FILE"
[[ -f "$SOURCE_ROOTS_FILE" ]] || : > "$SOURCE_ROOTS_FILE"
[[ -f "$BLOCKED_UUID_FILE" ]] || : > "$BLOCKED_UUID_FILE"
[[ -f "$CARD_POLICY_FILE" ]] || : > "$CARD_POLICY_FILE"
[[ -f "$FAST_SEEN_FILE" ]] || : > "$FAST_SEEN_FILE"
[[ -f "$SHOOT_CLUSTER_MAP_FILE" ]] || : > "$SHOOT_CLUSTER_MAP_FILE"
mkdir -p "$CONTROL_DIR" "$PENDING_DIR"
/bin/rm -f "$PAUSE_FLAG" "$STOP_AFTER_FILE_FLAG" "$KEEP_MOUNTED_FLAG" "$EJECT_NOW_FLAG" "$STATUS_FILE"

sql_quote() {
  local s="${1:-}"
  s="${s//\'/\'\'}"
  printf "'%s'" "$s"
}

db_available() {
  [[ "${DB_ENABLED:-1}" == "1" ]] && command -v sqlite3 >/dev/null 2>&1
}

db_exec() {
  db_available || return 0
  /usr/bin/sqlite3 "$DB_FILE" "PRAGMA busy_timeout=5000; $*" 2>>"$LOG_FILE" || {
    log "SQLite statement failed; continuing with text-file fallback."
    return 1
  }
}

db_init() {
  db_available || return 0
  /bin/mkdir -p "$(dirname "$DB_FILE")"
  /usr/bin/sqlite3 "$DB_FILE" <<'SQL' 2>>"$LOG_FILE" || {
PRAGMA journal_mode=WAL;
PRAGMA synchronous=NORMAL;
PRAGMA busy_timeout=5000;
CREATE TABLE IF NOT EXISTS import_runs (
  run_id TEXT PRIMARY KEY,
  started_at TEXT NOT NULL,
  completed_at TEXT,
  status TEXT NOT NULL DEFAULT 'running',
  volume_count INTEGER NOT NULL DEFAULT 0,
  imported_count INTEGER NOT NULL DEFAULT 0,
  skipped_count INTEGER NOT NULL DEFAULT 0,
  error_count INTEGER NOT NULL DEFAULT 0,
  summary TEXT
);
CREATE TABLE IF NOT EXISTS media_files (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  source_uuid TEXT,
  volume_name TEXT,
  source_root_rel TEXT,
  rel_path TEXT NOT NULL,
  source_path TEXT,
  source_size INTEGER,
  source_mtime INTEGER,
  local_path TEXT,
  fingerprint TEXT,
  status TEXT NOT NULL,
  last_error TEXT,
  first_seen_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  last_run_id TEXT,
  UNIQUE(source_uuid, source_root_rel, rel_path, source_size, source_mtime)
);
CREATE INDEX IF NOT EXISTS idx_media_status ON media_files(status);
CREATE INDEX IF NOT EXISTS idx_media_source ON media_files(source_uuid, source_root_rel, rel_path);
CREATE TABLE IF NOT EXISTS upload_jobs (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  local_path TEXT NOT NULL UNIQUE,
  target_dir TEXT,
  status TEXT NOT NULL,
  attempts INTEGER NOT NULL DEFAULT 0,
  next_retry_epoch INTEGER NOT NULL DEFAULT 0,
  last_error TEXT,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  last_run_id TEXT
);
CREATE INDEX IF NOT EXISTS idx_upload_status_retry ON upload_jobs(status, next_retry_epoch);
SQL
    log "SQLite initialization failed; continuing with text-file fallback."
    return 0
  }
}

db_init

run_started_epoch="$(/bin/date '+%s')"
run_timestamp="$(/bin/date '+%Y-%m-%d %H:%M:%S')"
run_id="$(/bin/date '+%Y%m%d-%H%M%S')"
daily_digest_file="${REPORT_DIR}/daily-digest-$(/bin/date '+%Y-%m-%d').md"
missed_report_file="${REPORT_DIR}/missed-files-${run_id}.tsv"
/usr/bin/printf 'timestamp\tvolume\treason\tpath\tdetail\n' >"$missed_report_file"
db_exec "INSERT OR REPLACE INTO import_runs (run_id, started_at, status) VALUES ($(sql_quote "$run_id"), $(sql_quote "$run_timestamp"), 'running');" >/dev/null || true

summary_skipped_existing_total=0
summary_skipped_extension_total=0
summary_copy_fail_total=0
summary_verify_fail_total=0
summary_kept_mounted_total=0
summary_kept_mounted_volumes=""
summary_post_move_blocked_total=0
summary_post_move_fail_total=0
summary_errors_total=0
summary_upload_incomplete_total=0

last_dest_dir=""
COPY_VERIFY_FAILURE_REASON=""
COPY_VERIFY_FAILURE_DETAIL=""
move_last_status="none"
move_last_detail=""
move_last_target=""
missed_report_rows=0
missed_report_truncated=0
pending_recovery_touched=0
ddump_started_gdrive_mount=0
current_status_phase="starting"
current_status_message=""
current_status_volume=""
current_status_total="0"
current_status_processed="0"
current_status_imported="0"
current_status_skipped="0"
current_status_failed="0"
current_upload_total="0"
current_upload_done="0"
current_upload_failed="0"
current_upload_percent=""
current_upload_speed=""
current_upload_eta=""
current_upload_target=""
current_upload_item=""
current_upload_last_error=""
current_card_ejected="0"
current_eject_status="pending"
startup_cause="launchd StartOnMount event"
startup_volume=""
startup_path=""
startup_uuid=""

status_escape() {
  local raw="$1"
  raw="${raw//\\/\\\\}"
  raw="${raw//$'\n'/ }"
  raw="${raw//\"/\\\"}"
  printf '%s' "$raw"
}

write_status() {
  local status_file_tmp
  status_file_tmp="$(/usr/bin/mktemp "${STATE_DIR}/status.${run_id}.XXXXXX")"
  {
    /bin/echo "run_id=\"$(status_escape "$run_id")\""
    /bin/echo "phase=\"$(status_escape "$current_status_phase")\""
    /bin/echo "message=\"$(status_escape "$current_status_message")\""
    /bin/echo "volume=\"$(status_escape "$current_status_volume")\""
    /bin/echo "dest_dir=\"$(status_escape "$last_dest_dir")\""
    /bin/echo "total=\"$(status_escape "$current_status_total")\""
    /bin/echo "processed=\"$(status_escape "$current_status_processed")\""
    /bin/echo "imported=\"$(status_escape "$current_status_imported")\""
    /bin/echo "skipped=\"$(status_escape "$current_status_skipped")\""
    /bin/echo "failed=\"$(status_escape "$current_status_failed")\""
    /bin/echo "upload_total=\"$(status_escape "$current_upload_total")\""
    /bin/echo "upload_done=\"$(status_escape "$current_upload_done")\""
    /bin/echo "upload_failed=\"$(status_escape "$current_upload_failed")\""
    /bin/echo "upload_percent=\"$(status_escape "$current_upload_percent")\""
    /bin/echo "upload_speed=\"$(status_escape "$current_upload_speed")\""
    /bin/echo "upload_eta=\"$(status_escape "$current_upload_eta")\""
    /bin/echo "upload_target=\"$(status_escape "$current_upload_target")\""
    /bin/echo "upload_item=\"$(status_escape "$current_upload_item")\""
    /bin/echo "upload_last_error=\"$(status_escape "$current_upload_last_error")\""
    /bin/echo "card_ejected=\"$(status_escape "$current_card_ejected")\""
    /bin/echo "eject_status=\"$(status_escape "$current_eject_status")\""
    /bin/echo "startup_cause=\"$(status_escape "$startup_cause")\""
    /bin/echo "startup_volume=\"$(status_escape "$startup_volume")\""
    /bin/echo "startup_path=\"$(status_escape "$startup_path")\""
    /bin/echo "startup_uuid=\"$(status_escape "$startup_uuid")\""
    /bin/echo "summary_errors=\"$(status_escape "$summary_errors_total")\""
    /bin/echo "started_at=\"$(status_escape "$run_timestamp")\""
    /bin/echo "started_epoch=\"$(status_escape "$run_started_epoch")\""
    /bin/echo "updated_at=\"$(/bin/date '+%Y-%m-%d %H:%M:%S')\""
  } >"$status_file_tmp"
  /bin/mv "$status_file_tmp" "$STATUS_FILE"
}

record_skipped_volume() {
  local volume_name="$1"
  local volume_path="$2"
  local uuid="$3"
  local reason="$4"
  local detail="$5"
  local hint="$6"
  local skipped_tmp
  skipped_tmp="$(/usr/bin/mktemp "${STATE_DIR}/skipped-volume.${run_id}.XXXXXX")"
  {
    /bin/echo "run_id=\"$(status_escape "$run_id")\""
    /bin/echo "timestamp=\"$(/bin/date '+%Y-%m-%d %H:%M:%S')\""
    /bin/echo "epoch=\"$(/bin/date '+%s')\""
    /bin/echo "volume=\"$(status_escape "$volume_name")\""
    /bin/echo "path=\"$(status_escape "$volume_path")\""
    /bin/echo "uuid=\"$(status_escape "$uuid")\""
    /bin/echo "reason=\"$(status_escape "$reason")\""
    /bin/echo "detail=\"$(status_escape "$detail")\""
    /bin/echo "hint=\"$(status_escape "$hint")\""
  } >"$skipped_tmp"
  /bin/mv "$skipped_tmp" "$LAST_SKIPPED_VOLUME_FILE"
}

set_status_phase() {
  local phase="$1"
  local message="${2:-}"
  current_status_phase="$phase"
  current_status_message="$message"
  write_status
}

set_upload_status() {
  current_status_phase="uploading"
  current_status_message="${1:-Uploading to cloud destination.}"
  current_upload_target="${2:-$current_upload_target}"
  current_upload_item="${3:-$current_upload_item}"
  current_upload_done="${4:-$current_upload_done}"
  current_upload_failed="${5:-$current_upload_failed}"
  current_upload_total="${6:-$current_upload_total}"
  current_upload_percent="${7:-$current_upload_percent}"
  current_upload_speed="${8:-$current_upload_speed}"
  current_upload_eta="${9:-$current_upload_eta}"
  write_status
}

set_eject_status() {
  current_eject_status="${1:-pending}"
  if [[ "$current_eject_status" == "ejected" ]]; then
    current_card_ejected="1"
  else
    current_card_ejected="0"
  fi
  write_status
}

update_upload_status_from_rclone_log() {
  local target="$1"
  local item="$2"
  local done="$3"
  local failed="$4"
  local total="$5"
  local stats_line error_line percent speed eta xfr_done xfr_total message

  stats_line="$(/usr/bin/tail -n 160 "$LOG_FILE" 2>/dev/null | /usr/bin/grep 'INFO  : .*ETA .*xfr#' | /usr/bin/tail -n 1 || true)"
  error_line="$(/usr/bin/tail -n 80 "$LOG_FILE" 2>/dev/null | /usr/bin/grep 'ERROR :' | /usr/bin/tail -n 1 || true)"

  if [[ -n "$stats_line" ]]; then
    percent="$(printf '%s' "$stats_line" | /usr/bin/sed -nE 's/.* ([0-9]+)%, .*/\1/p')"
    speed="$(printf '%s' "$stats_line" | /usr/bin/sed -nE 's/.* [0-9]+%, ([^,]+), ETA .*/\1/p')"
    eta="$(printf '%s' "$stats_line" | /usr/bin/sed -nE 's/.* ETA ([^ ]+) \(xfr#[0-9]+\/[0-9]+\).*/\1/p')"
    xfr_done="$(printf '%s' "$stats_line" | /usr/bin/sed -nE 's/.*\(xfr#([0-9]+)\/([0-9]+)\).*/\1/p')"
    xfr_total="$(printf '%s' "$stats_line" | /usr/bin/sed -nE 's/.*\(xfr#([0-9]+)\/([0-9]+)\).*/\2/p')"
    [[ -n "$xfr_done" ]] && done="$xfr_done"
    [[ -n "$xfr_total" ]] && total="$xfr_total"
  fi

  if [[ -n "$error_line" ]]; then
    current_upload_last_error="$(printf '%s' "$error_line" | /usr/bin/sed -E 's/^.*ERROR : //; s/[[:space:]]+/ /g' | /usr/bin/cut -c1-220)"
  fi

  if [[ -n "$current_upload_last_error" && -z "$stats_line" ]]; then
    message="Uploading to ${target}; retrying after network/cloud error."
  else
    message="Uploading to ${target}."
  fi
  set_upload_status "$message" "$target" "$item" "$done" "$failed" "$total" "$percent" "$speed" "$eta"
}

start_progress_window() {
  [[ "$SHOW_PROGRESS_WINDOW" == "1" ]] || return 0
  local monitor_script="${APP_SUPPORT_DIR}/bin/ddump-monitor.sh"
  [[ -x "$monitor_script" ]] || return 0
  local monitor_cmd
  monitor_cmd="/bin/bash \"$monitor_script\" \"$STATUS_FILE\" \"$CONTROL_DIR\" \"$LOCK_DIR\""
  /usr/bin/osascript <<OSA >/dev/null 2>&1 || true
tell application "Terminal"
  activate
  do script "$(printf '%s' "$monitor_cmd" | sed 's/\\/\\\\/g; s/"/\\"/g')"
end tell
OSA
}

progress_window_started=0
set_startup_cause() {
  local cause="${1:-}"
  local vol="${2:-}"
  local path="${3:-}"
  local uuid="${4:-}"
  [[ -n "$cause" ]] && startup_cause="$cause"
  startup_volume="$vol"
  startup_path="$path"
  startup_uuid="$uuid"
  write_status
}

start_progress_window_if_needed() {
  local cause="${1:-}"
  local vol="${2:-}"
  local path="${3:-}"
  local uuid="${4:-}"
  if [[ -n "$cause" || -n "$vol" || -n "$path" || -n "$uuid" ]]; then
    set_startup_cause "$cause" "$vol" "$path" "$uuid"
  fi
  if [[ "$progress_window_started" != "1" ]]; then
    log "Opening monitor window: cause='${startup_cause}', volume='${startup_volume}', path='${startup_path}', uuid='${startup_uuid:-none}'"
    start_progress_window
    progress_window_started=1
  fi
}

prune_manifest() {
  local retention_days="$1"
  if ! [[ "$retention_days" =~ ^[0-9]+$ ]]; then
    log "Invalid MANIFEST_RETENTION_DAYS value: ${retention_days}. Skipping prune."
    return
  fi

  if [[ "$retention_days" -eq 0 ]]; then
    log "Manifest prune disabled (MANIFEST_RETENTION_DAYS=0)."
    return
  fi

  local cutoff_epoch
  cutoff_epoch=$(( $(/bin/date '+%s') - (retention_days * 86400) ))

  local backup_file
  backup_file="${MANIFEST_FILE}.bak"
  /bin/cp "$MANIFEST_FILE" "$backup_file" 2>/dev/null || true

  local temp_pruned_file
  temp_pruned_file="$(/usr/bin/mktemp "${STATE_DIR}/manifest.pruned.XXXXXX")"

  local total=0
  local kept=0
  local removed=0
  local parse_failed=0
  local line fingerprint source_file dest_file ts ts_epoch
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" ]] || continue
    total=$((total + 1))
    IFS=$'\t' read -r fingerprint source_file dest_file ts <<<"$line"
    if [[ -z "$fingerprint" || -z "$ts" ]]; then
      /bin/echo "$line" >>"$temp_pruned_file"
      kept=$((kept + 1))
      continue
    fi

    ts_epoch="$(/bin/date -j -f '%Y-%m-%d %H:%M:%S' "$ts" '+%s' 2>/dev/null || /bin/echo 0)"
    if [[ "$ts_epoch" -eq 0 ]]; then
      parse_failed=$((parse_failed + 1))
      /bin/echo "$line" >>"$temp_pruned_file"
      kept=$((kept + 1))
    elif [[ "$ts_epoch" -ge "$cutoff_epoch" ]]; then
      /bin/echo "$line" >>"$temp_pruned_file"
      kept=$((kept + 1))
    else
      removed=$((removed + 1))
    fi
  done <"$MANIFEST_FILE"

  /bin/mv "$temp_pruned_file" "$MANIFEST_FILE"
  log "Manifest prune complete: total=${total}, kept=${kept}, removed=${removed}, parse_failed=${parse_failed}, retention_days=${retention_days}."
}

effective_dump_root() {
  local root fallback
  root="${DEST_ROOT:-}"
  fallback="${DUMP_FALLBACK_ROOT:-}"
  if [[ -n "$fallback" ]]; then
    if [[ -z "$root" ]]; then
      root="$fallback"
    elif [[ ! -d "$root" ]]; then
      log "Dump folder unavailable, trying fallback: ${root} -> ${fallback}"
      root="$fallback"
    elif [[ ! -w "$root" ]]; then
      log "Dump folder not writable, trying fallback: ${root} -> ${fallback}"
      root="$fallback"
    fi
  fi
  printf '%s' "$root"
}

DEST_ROOT="$(effective_dump_root)"
if [[ ! -d "$DEST_ROOT" ]]; then
  if /bin/mkdir -p "$DEST_ROOT"; then
    log "Created dump folder: $DEST_ROOT"
  else
    log "Dump folder is unavailable: $DEST_ROOT"
    notify "DDump" "Dump folder unavailable: $DEST_ROOT"
    exit 1
  fi
fi

infer_smart_root_from_sample_path() {
  # Pulls the root before the date ladder from a real path like:
  # .../1 - Photo/2026/2026.05/2026.05.19/Shoot Name
  local sample="${SMART_SAMPLE_PATH:-}"
  [[ -n "$sample" ]] || return 1
  if [[ "$sample" =~ ^(.+)/[0-9]{4}/[0-9]{4}\.[0-9]{2}/[0-9]{4}\.[0-9]{2}\.[0-9]{2}(/.*)?$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

effective_post_move_root() {
  if [[ "${FOLDER_NAMING_STRATEGY:-sequential}" == "smart" ]]; then
    local smart_root
    if smart_root="$(infer_smart_root_from_sample_path)"; then
      printf '%s' "$smart_root"
      return 0
    fi
  fi
  local root fallback
  root="${POST_MOVE_ROOT:-}"
  fallback="${POST_MOVE_FALLBACK_ROOT:-}"
  if [[ -n "$root" && ! -d "$root" ]]; then
    ensure_sync_provider_path_available "$root" || true
  fi
  if [[ -n "$fallback" ]]; then
    if [[ -z "$root" ]]; then
      log "Backup Folder is empty; using fallback Backup Folder: ${fallback}"
      root="$fallback"
    elif path_uses_gdrive_mount "$root" && ! direct_cloud_upload_enabled_for_root "$root" && ! gdrive_mount_active; then
      log "Backup Folder mount unavailable, using fallback: ${root} -> ${fallback}"
      root="$fallback"
    elif [[ ! -d "$root" ]]; then
      log "Backup Folder unavailable, using fallback: ${root} -> ${fallback}"
      root="$fallback"
    elif [[ ! -w "$root" ]]; then
      log "Backup Folder not writable, using fallback: ${root} -> ${fallback}"
      root="$fallback"
    fi
  fi
  root="$(normalize_post_move_root "$root")"
  printf '%s' "$root"
}

effective_video_post_move_root() {
  [[ "${FOLDER_NAMING_STRATEGY:-sequential}" == "smart" ]] || return 1
  [[ "${SPLIT_PHOTO_VIDEO:-0}" == "1" ]] || return 1

  local photo_root
  if ! photo_root="$(infer_smart_root_from_sample_path)"; then
    return 1
  fi

  case "$photo_root" in
    *"/1 — Photo"*) printf '%s' "${photo_root%"/1 — Photo"}/2 — Video"; return 0 ;;
    *"/1 - Photo"*) printf '%s' "${photo_root%"/1 - Photo"}/2 - Video"; return 0 ;;
    *"/Photo"*) printf '%s' "${photo_root%"/Photo"}/Video"; return 0 ;;
  esac
  return 1
}

build_post_move_target_dir() {
  local root
  root="$(effective_post_move_root)"
  [[ -n "$root" ]] || return 1
  build_post_move_target_dir_for_root "$root"
}

build_post_move_target_dir_for_root() {
  local root="$1"
  [[ -n "$root" ]] || return 1
  local year month day
  year="$(/bin/date +"$POST_MOVE_YEAR_FORMAT")"
  month="$(/bin/date +"$POST_MOVE_MONTH_FORMAT")"
  day="$(/bin/date +"$POST_MOVE_DAY_FORMAT")"
  printf '%s/%s/%s/%s' "$root" "$year" "$month" "$day"
}

build_video_post_move_target_dir() {
  local root
  if ! root="$(effective_video_post_move_root)"; then
    return 1
  fi
  local year month day
  year="$(/bin/date +"$POST_MOVE_YEAR_FORMAT")"
  month="$(/bin/date +"$POST_MOVE_MONTH_FORMAT")"
  day="$(/bin/date +"$POST_MOVE_DAY_FORMAT")"
  printf '%s/%s/%s/%s' "$root" "$year" "$month" "$day"
}

collect_post_move_roots() {
  local primary extras item
  primary="$(effective_post_move_root)"
  [[ -n "$primary" ]] && /bin/echo "$primary"
  extras="${POST_MOVE_ROOTS:-}"
  [[ -n "$extras" ]] || return 0
  IFS=',' read -r -a _extra_roots <<<"$extras"
  for item in "${_extra_roots[@]}"; do
    item="$(trim "$item")"
    [[ -n "$item" ]] || continue
    item="$(normalize_post_move_root "$item")"
    [[ "$item" == "$primary" ]] && continue
    /bin/echo "$item"
  done
}

path_uses_gdrive_mount() {
  local path="$1"
  [[ "${GDRIVE_MOUNT_ENABLED:-0}" == "1" ]] || return 1
  [[ "${GDRIVE_DIRECT_UPLOAD:-1}" != "1" ]] || return 1
  path_is_gdrive_path "$path"
}

expand_config_path() {
  local raw="$1"
  case "$raw" in
    "\$HOME"/*) raw="${HOME}/${raw#"\$HOME"/}" ;;
    "\${HOME}"/*) raw="${HOME}/${raw#"\${HOME}"/}" ;;
    "~"/*) raw="${HOME}/${raw#"~"/}" ;;
  esac
  printf '%s' "$raw"
}

path_is_gdrive_path() {
  local path="$1"
  local gdrive
  gdrive="$(expand_config_path "${GDRIVE_MOUNT_POINT:-${HOME}/GoogleDrive}")"
  gdrive="${gdrive%/}"
  case "$path" in
    "$gdrive"|"$gdrive"/*) return 0 ;;
    *) return 1 ;;
  esac
}

path_is_google_drive_desktop_path() {
  local path="$1"
  local expanded cloud_root legacy_root
  expanded="$(expand_config_path "$path")"
  cloud_root="${HOME}/Library/CloudStorage/GoogleDrive"
  legacy_root="${HOME}/GoogleDrive"
  case "$expanded" in
    "$cloud_root"|"$cloud_root"-*|"$cloud_root"/*|"$cloud_root"-*/*) return 0 ;;
    "$legacy_root"|"$legacy_root"/*) return 0 ;;
    *) return 1 ;;
  esac
}

sync_provider_app_for_path() {
  local path="$1"
  local expanded
  expanded="$(expand_config_path "$path")"
  case "$expanded" in
    "$HOME"/Library/CloudStorage/GoogleDrive*|"$HOME"/GoogleDrive|"$HOME"/GoogleDrive/*) printf 'Google Drive' ;;
    "$HOME"/Library/CloudStorage/Dropbox*|"$HOME"/Dropbox|"$HOME"/Dropbox/*) printf 'Dropbox' ;;
    "$HOME"/Library/CloudStorage/OneDrive*|"$HOME"/OneDrive*|"$HOME"/OneDrive*/*) printf 'OneDrive' ;;
    "$HOME"/Library/CloudStorage/Box*|"$HOME"/Box|"$HOME"/Box/*) printf 'Box' ;;
    "$HOME"/pCloud\ Drive|"$HOME"/pCloud\ Drive/*|/Volumes/pCloud\ Drive|/Volumes/pCloud\ Drive/*) printf 'pCloud Drive' ;;
    *) return 1 ;;
  esac
}

launch_sync_provider_for_path() {
  local path="$1"
  local app_name
  [[ "${AUTO_LAUNCH_SYNC_APPS:-1}" == "1" ]] || return 1
  app_name="$(sync_provider_app_for_path "$path")" || return 1
  if /usr/bin/open -a "$app_name" >/dev/null 2>&1; then
    log "Launched ${app_name} for Backup Folder: ${path}"
    return 0
  fi
  log "Could not launch ${app_name} for Backup Folder: ${path}"
  return 1
}

wait_for_sync_provider_path() {
  local path="$1"
  local wait_seconds elapsed
  wait_seconds="$(sanitize_positive_int "${SYNC_APP_READY_WAIT_SECONDS:-8}" "8")"
  elapsed=0
  while (( elapsed <= wait_seconds )); do
    [[ -d "$path" ]] && return 0
    /bin/sleep 1
    elapsed=$((elapsed + 1))
  done
  return 1
}

ensure_sync_provider_path_available() {
  local path="$1"
  [[ -n "$path" ]] || return 1
  [[ -d "$path" ]] && return 0

  if launch_sync_provider_for_path "$path"; then
    wait_for_sync_provider_path "$path" && return 0
  fi
  return 1
}

google_drive_desktop_cloud_root() {
  local root
  if [[ -d "${HOME}/Library/CloudStorage/GoogleDrive" ]]; then
    printf '%s\n' "${HOME}/Library/CloudStorage/GoogleDrive"
    return 0
  fi

  for root in "${HOME}"/Library/CloudStorage/GoogleDrive-*; do
    [[ -d "$root" ]] || continue
    printf '%s\n' "$root"
    return 0
  done

  return 1
}

google_drive_desktop_join_legacy_rel() {
  local cloud_root="$1"
  local rel="$2"
  rel="${rel#/}"
  if [[ -z "$rel" ]]; then
    printf '%s\n' "$cloud_root"
    return 0
  fi

  local first rest candidate
  first="${rel%%/*}"
  if [[ "$rel" == */* ]]; then
    rest="${rel#*/}"
  else
    rest=""
  fi

  for candidate in \
    "${cloud_root}/${rel}" \
    "${cloud_root}/Shared drives/${rel}" \
    "${cloud_root}/My Drive/${rel}"; do
    if [[ -e "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  for candidate in "${cloud_root}/Shared drives/${first}"*; do
    [[ -d "$candidate" ]] || continue
    if [[ -z "$rest" ]]; then
      printf '%s\n' "$candidate"
    else
      printf '%s/%s\n' "$candidate" "$rest"
    fi
    return 0
  done

  if [[ -d "${cloud_root}/My Drive/${first}" ]]; then
    if [[ -z "$rest" ]]; then
      printf '%s\n' "${cloud_root}/My Drive/${first}"
    else
      printf '%s/%s\n' "${cloud_root}/My Drive/${first}" "$rest"
    fi
    return 0
  fi

  printf '%s/%s\n' "${cloud_root}/My Drive" "$rel"
}

normalize_post_move_root() {
  local raw="$1"
  [[ -n "$raw" ]] || return 0

  local expanded legacy rel cloud_root normalized
  expanded="$(expand_config_path "$raw")"
  legacy="${HOME}/GoogleDrive"

  if [[ "${GDRIVE_DIRECT_UPLOAD:-0}" != "1" ]]; then
    case "$expanded" in
      "$legacy") rel="" ;;
      "$legacy"/*) rel="${expanded#"$legacy"/}" ;;
      *) printf '%s\n' "$raw"; return 0 ;;
    esac

    if cloud_root="$(google_drive_desktop_cloud_root)"; then
      normalized="$(google_drive_desktop_join_legacy_rel "$cloud_root" "$rel")"
      if [[ -n "$normalized" ]]; then
        printf '%s\n' "$normalized"
        return 0
      fi
    fi
  fi

  printf '%s\n' "$raw"
}

google_drive_desktop_running() {
  /usr/bin/pgrep -f 'Google Drive\.app/Contents/MacOS/Google Drive|/Applications/Google Drive\.app' >/dev/null 2>&1 \
    || /usr/bin/pgrep -f 'Google Drive/Contents/MacOS/Google Drive|drivefs' >/dev/null 2>&1
}

launch_google_drive_desktop() {
  local app_name app_path
  app_name="${GOOGLE_DRIVE_DESKTOP_APP_NAME:-Google Drive}"
  app_path="$(expand_config_path "${GOOGLE_DRIVE_DESKTOP_APP_PATH:-/Applications/Google Drive.app}")"
  if /usr/bin/open -a "$app_name" >/dev/null 2>&1; then
    log "Launched Google Drive Desktop with open -a '${app_name}'."
    return 0
  fi
  if [[ -d "$app_path" ]] && /usr/bin/open "$app_path" >/dev/null 2>&1; then
    log "Launched Google Drive Desktop from ${app_path}."
    return 0
  fi
  log "Google Drive Desktop launch failed; app not found or macOS refused launch."
  return 1
}

restart_google_drive_desktop() {
  local delay
  delay="$(sanitize_positive_int "${GOOGLE_DRIVE_DESKTOP_RESTART_DELAY_SECONDS:-5}" "5")"
  log "Restarting Google Drive Desktop after destination check failed."
  /usr/bin/osascript -e 'tell application "Google Drive" to quit' >/dev/null 2>&1 || true
  /bin/sleep 2
  /usr/bin/pkill -TERM -f 'Google Drive\.app/Contents/MacOS/Google Drive|/Applications/Google Drive\.app|drivefs' >/dev/null 2>&1 || true
  /bin/sleep "$delay"
  if google_drive_desktop_running; then
    /usr/bin/pkill -KILL -f 'Google Drive\.app/Contents/MacOS/Google Drive|/Applications/Google Drive\.app|drivefs' >/dev/null 2>&1 || true
    /bin/sleep 1
  fi
  launch_google_drive_desktop
}

google_drive_desktop_path_responsive() {
  local path="$1"
  /usr/bin/python3 - "$path" <<'PY' >/dev/null 2>&1
import os
import signal
import sys

path = sys.argv[1]

def timeout(_signum, _frame):
    raise TimeoutError("Google Drive folder probe timed out")

signal.signal(signal.SIGALRM, timeout)
signal.alarm(8)
try:
    os.makedirs(path, exist_ok=True)
    test = os.path.join(path, ".ddump-drive-probe")
    with open(test, "w", encoding="utf-8") as handle:
        handle.write("ok\n")
    os.remove(test)
finally:
    signal.alarm(0)
PY
}

ensure_google_drive_desktop_ready_for_path() {
  local path="$1"
  path_is_google_drive_desktop_path "$path" || return 0
  [[ "${GOOGLE_DRIVE_DESKTOP_ENABLED:-1}" == "1" ]] || return 0

  if ! google_drive_desktop_running; then
    log "Google Drive Desktop is not running; launching it for ${path}."
    launch_google_drive_desktop || return 1
    /bin/sleep 5
  fi

  if google_drive_desktop_path_responsive "$path"; then
    return 0
  fi

  log "Google Drive Desktop path is not responsive: ${path}"
  [[ "${GOOGLE_DRIVE_DESKTOP_RESTART_ON_FAILURE:-1}" == "1" ]] || return 1
  restart_google_drive_desktop || return 1
  /bin/sleep 5
  google_drive_desktop_path_responsive "$path"
}

direct_cloud_upload_enabled_for_root() {
  [[ "${CLOUD_UPLOADS_ENABLED:-0}" == "1" ]] || return 1
  [[ "${GDRIVE_DIRECT_UPLOAD:-1}" == "1" ]] || return 1
  path_is_gdrive_path "$1"
}

rclone_binary() {
  local configured
  configured="$(expand_config_path "${RCLONE_BIN:-${HOME}/bin/rclone}")"
  if [[ -x "$configured" ]]; then
    printf '%s\n' "$configured"
    return 0
  fi
  if command -v rclone >/dev/null 2>&1; then
    command -v rclone
    return 0
  fi
  if [[ -x "/opt/homebrew/bin/rclone" ]]; then
    printf '%s\n' "/opt/homebrew/bin/rclone"
    return 0
  fi
  if [[ -x "/usr/local/bin/rclone" ]]; then
    printf '%s\n' "/usr/local/bin/rclone"
    return 0
  fi
  return 1
}

rclone_remote_base() {
  local remote
  remote="$(trim "${GDRIVE_REMOTE:-combined:}")"
  [[ -n "$remote" ]] || remote="combined:"
  if [[ "$remote" != *:* ]]; then
    remote="${remote}:"
  fi
  printf '%s\n' "$remote"
}

rclone_remote_join() {
  local base="$1"
  local rel="$2"
  rel="${rel#/}"
  if [[ -z "$rel" ]]; then
    printf '%s\n' "$base"
  elif [[ "$base" == *: ]]; then
    printf '%s%s\n' "$base" "$rel"
  else
    printf '%s/%s\n' "${base%/}" "$rel"
  fi
}

gdrive_local_path_to_remote_path() {
  local path="$1"
  local gdrive rel remote
  gdrive="$(expand_config_path "${GDRIVE_MOUNT_POINT:-${HOME}/GoogleDrive}")"
  gdrive="${gdrive%/}"
  case "$path" in
    "$gdrive") rel="" ;;
    "$gdrive"/*) rel="${path#"$gdrive"/}" ;;
    *) return 1 ;;
  esac
  remote="$(rclone_remote_base)"
  rclone_remote_join "$remote" "$rel"
}

rclone_copy_path_to_remote_target() {
  local src_path="$1"
  local remote_target_dir="$2"
  local rclone_bin base_name remote_dest
  if ! rclone_bin="$(rclone_binary)"; then
    log "Direct cloud upload failed: rclone not found."
    return 1
  fi
  base_name="$(basename "$src_path")"
  remote_dest="$(rclone_remote_join "$remote_target_dir" "$base_name")"

  if [[ -d "$src_path" ]]; then
    rclone_copy_directory_to_remote_target "$rclone_bin" "$src_path" "$remote_dest"
  else
    rclone_copyto_with_watchdog "$rclone_bin" "$src_path" "$remote_dest"
  fi
}

rclone_copyto_with_watchdog() {
  local rclone_bin="$1"
  local src_file="$2"
  local remote_dest="$3"
  local timeout chunk pid elapsed rc item_name
  timeout="$(sanitize_positive_int "${RCLONE_FILE_TIMEOUT_SECONDS:-180}" "180")"
  if [[ "$timeout" -lt 30 ]]; then
    timeout=30
  fi
  chunk="${RCLONE_DRIVE_CHUNK_SIZE:-8M}"
  item_name="$(basename "$src_file")"
  update_upload_status_from_rclone_log "$remote_dest" "$item_name" "$current_upload_done" "$current_upload_failed" "$current_upload_total"

  "$rclone_bin" copyto "$src_file" "$remote_dest" \
    --exclude '.DS_Store' --exclude '._*' \
    --drive-chunk-size "$chunk" \
    --tpslimit "${RCLONE_TPS_LIMIT:-2}" --tpslimit-burst "${RCLONE_TPS_BURST:-2}" \
    --multi-thread-streams 0 \
    --contimeout 10s --timeout 30s --retries 2 --low-level-retries 3 --retries-sleep 3s \
    --stats 0 --log-level ERROR >>"$LOG_FILE" 2>&1 &
  pid="$!"
  elapsed=0
  while /bin/kill -0 "$pid" >/dev/null 2>&1; do
    if [[ "$elapsed" -ge "$timeout" ]]; then
      log "Direct rclone upload timed out after ${timeout}s: ${src_file} -> ${remote_dest}"
      /bin/kill -TERM "$pid" >/dev/null 2>&1 || true
      /bin/sleep 3
      /bin/kill -KILL "$pid" >/dev/null 2>&1 || true
      wait "$pid" >/dev/null 2>&1 || true
      return 124
    fi
    /bin/sleep 1
    elapsed=$((elapsed + 1))
    if (( elapsed % 5 == 0 )); then
      update_upload_status_from_rclone_log "$remote_dest" "$item_name" "$current_upload_done" "$current_upload_failed" "$current_upload_total"
    fi
  done
  if wait "$pid"; then
    update_upload_status_from_rclone_log "$remote_dest" "$item_name" "$current_upload_done" "$current_upload_failed" "$current_upload_total"
    return 0
  else
    rc="$?"
  fi
  log "Direct rclone upload failed with exit ${rc}: ${src_file} -> ${remote_dest}"
  current_upload_last_error="rclone copy failed with exit ${rc}"
  update_upload_status_from_rclone_log "$remote_dest" "$item_name" "$current_upload_done" "$current_upload_failed" "$current_upload_total"
  return "$rc"
}

rclone_copy_directory_to_remote_target() {
  local rclone_bin="$1"
  local src_dir="$2"
  local remote_dest_dir="$3"
  local timeout chunk pid elapsed rc item_name
  timeout="$(sanitize_positive_int "${RCLONE_BATCH_TIMEOUT_SECONDS:-3600}" "3600")"
  if [[ "$timeout" -lt 300 ]]; then
    timeout=300
  fi
  chunk="${RCLONE_DRIVE_CHUNK_SIZE:-8M}"
  item_name="$(basename "$src_dir")"
  update_upload_status_from_rclone_log "$remote_dest_dir" "$item_name" "$current_upload_done" "$current_upload_failed" "$current_upload_total"

  "$rclone_bin" copy "$src_dir" "$remote_dest_dir" \
    --exclude '.DS_Store' --exclude '._*' \
    --transfers 1 --checkers 1 \
    --drive-chunk-size "$chunk" \
    --tpslimit "${RCLONE_TPS_LIMIT:-2}" --tpslimit-burst "${RCLONE_TPS_BURST:-2}" \
    --multi-thread-streams 0 \
    --contimeout 10s --timeout 30s --retries 10 --low-level-retries 6 --retries-sleep 15s \
    --stats 30s --stats-one-line --log-level INFO >>"$LOG_FILE" 2>&1 &
  pid="$!"
  elapsed=0
  while /bin/kill -0 "$pid" >/dev/null 2>&1; do
    if [[ "$elapsed" -ge "$timeout" ]]; then
      log "Direct rclone bucket upload timed out after ${timeout}s: ${src_dir} -> ${remote_dest_dir}"
      /bin/kill -TERM "$pid" >/dev/null 2>&1 || true
      /bin/sleep 3
      /bin/kill -KILL "$pid" >/dev/null 2>&1 || true
      wait "$pid" >/dev/null 2>&1 || true
      return 124
    fi
    /bin/sleep 1
    elapsed=$((elapsed + 1))
    if (( elapsed % 5 == 0 )); then
      update_upload_status_from_rclone_log "$remote_dest_dir" "$item_name" "$current_upload_done" "$current_upload_failed" "$current_upload_total"
    fi
  done
  if wait "$pid"; then
    update_upload_status_from_rclone_log "$remote_dest_dir" "$item_name" "$current_upload_done" "$current_upload_failed" "$current_upload_total"
    return 0
  else
    rc="$?"
  fi
  log "Direct rclone bucket upload failed with exit ${rc}: ${src_dir} -> ${remote_dest_dir}"
  current_upload_last_error="rclone copy failed with exit ${rc}"
  update_upload_status_from_rclone_log "$remote_dest_dir" "$item_name" "$current_upload_done" "$current_upload_failed" "$current_upload_total"
  return "$rc"
}

gdrive_mount_active() {
  local mount_dir="${GDRIVE_MOUNT_POINT:-${HOME}/GoogleDrive}"
  /sbin/mount | /usr/bin/grep -q " on ${mount_dir} " || return 1
  /bin/ls -1 "$mount_dir" >/dev/null 2>&1 &
  local probe_pid="$!"
  local elapsed=0
  while /bin/kill -0 "$probe_pid" >/dev/null 2>&1; do
    if [[ "$elapsed" -ge 8 ]]; then
      /bin/kill -TERM "$probe_pid" >/dev/null 2>&1 || true
      /bin/sleep 1
      /bin/kill -KILL "$probe_pid" >/dev/null 2>&1 || true
      wait "$probe_pid" >/dev/null 2>&1 || true
      return 1
    fi
    /bin/sleep 1
    elapsed=$((elapsed + 1))
  done
  wait "$probe_pid" >/dev/null 2>&1
}

gdrive_mount_present() {
  local mount_dir="${GDRIVE_MOUNT_POINT:-${HOME}/GoogleDrive}"
  /sbin/mount | /usr/bin/grep -q " on ${mount_dir} "
}

gdrive_mount_process_pid() {
  local mount_dir="${GDRIVE_MOUNT_POINT:-${HOME}/GoogleDrive}"
  /usr/bin/pgrep -f "rclone (mount|nfsmount).* ${mount_dir}" 2>/dev/null | /usr/bin/head -n 1
}

gdrive_mount_process_age_seconds() {
  local pid
  pid="$(gdrive_mount_process_pid)"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  /bin/ps -o etimes= -p "$pid" 2>/dev/null | /usr/bin/awk '{print $1}'
}

gdrive_mount_plist_path() {
  local label="${GDRIVE_MOUNT_LABEL:-com.ddump.rclone-gdrive}"
  printf '%s/Library/LaunchAgents/%s.plist' "$HOME" "$label"
}

sanitize_retry_schedule_csv() {
  local raw="${1:-15,30,60,180}"
  local cleaned=""
  local part=""
  IFS=',' read -r -a _retry_parts <<<"$raw"
  for part in "${_retry_parts[@]}"; do
    part="$(trim "$part")"
    [[ "$part" =~ ^[0-9]+$ ]] || continue
    if [[ -z "$cleaned" ]]; then
      cleaned="$part"
    else
      cleaned="${cleaned},${part}"
    fi
  done
  if [[ -z "$cleaned" ]]; then
    cleaned="15,30,60,180"
  fi
  printf '%s' "$cleaned"
}

ddump_ui_app_running() {
  /usr/bin/pgrep -f '/DDump.app/Contents/MacOS/DDump' >/dev/null 2>&1
}

finderserver_available() {
  if [[ -x "$FINDERSERVER_BIN" ]]; then
    return 0
  fi
  command -v finderserver >/dev/null 2>&1
}

run_finderserver() {
  local subcmd="${1:-status}"
  if [[ -x "$FINDERSERVER_BIN" ]]; then
    "$FINDERSERVER_BIN" "$subcmd"
    return $?
  fi
  if command -v finderserver >/dev/null 2>&1; then
    finderserver "$subcmd"
    return $?
  fi
  return 127
}

finderserver_timer_remaining_seconds() {
  local status_out remaining
  if ! status_out="$(run_finderserver status 2>/dev/null || true)"; then
    return 1
  fi
  if [[ "$status_out" =~ auto-off\ timer:\ ([0-9]+)s\ remaining ]]; then
    remaining="${BASH_REMATCH[1]}"
    printf '%s' "$remaining"
    return 0
  fi
  if [[ "$status_out" =~ auto-off\ timer:\ due\ now ]]; then
    printf '0'
    return 0
  fi
  return 1
}

refresh_finderserver_timer_if_low() {
  finderserver_available || return 0
  local min_left now_left
  min_left="$(sanitize_positive_int "${FINDERSERVER_TIMER_MIN_SECONDS:-300}" "300")"
  if ! now_left="$(finderserver_timer_remaining_seconds 2>/dev/null || true)"; then
    return 0
  fi
  if [[ "$now_left" =~ ^[0-9]+$ ]] && [[ "$now_left" -le "$min_left" ]]; then
    if run_finderserver on >/dev/null 2>&1; then
      log "Refreshed finderserver timer during upload (remaining=${now_left}s)."
    else
      log "Failed to refresh finderserver timer during upload."
    fi
  fi
}

start_finderserver_timer_guard() {
  finderserver_available || return 0
  local check_every min_left
  check_every="$(sanitize_positive_int "${FINDERSERVER_TIMER_CHECK_SECONDS:-300}" "300")"
  min_left="$(sanitize_positive_int "${FINDERSERVER_TIMER_MIN_SECONDS:-300}" "300")"
  if [[ "$check_every" -lt 30 ]]; then
    check_every=30
  fi
  if [[ "$min_left" -lt 60 ]]; then
    min_left=60
  fi

  if [[ -f "$FINDERSERVER_GUARD_PID_FILE" ]]; then
    local existing_pid
    existing_pid="$(cat "$FINDERSERVER_GUARD_PID_FILE" 2>/dev/null || true)"
    if [[ "$existing_pid" =~ ^[0-9]+$ ]] && kill -0 "$existing_pid" 2>/dev/null; then
      return 0
    fi
    /bin/rm -f "$FINDERSERVER_GUARD_PID_FILE"
  fi

  (
    while true; do
      /bin/sleep "$check_every"
      local status_out remaining
      status_out="$(run_finderserver status 2>/dev/null || true)"
      if [[ "$status_out" =~ auto-off\ timer:\ ([0-9]+)s\ remaining ]]; then
        remaining="${BASH_REMATCH[1]}"
      elif [[ "$status_out" =~ auto-off\ timer:\ due\ now ]]; then
        remaining="0"
      else
        continue
      fi
      if [[ "$remaining" =~ ^[0-9]+$ ]] && [[ "$remaining" -le "$min_left" ]]; then
        run_finderserver on >/dev/null 2>&1 || true
      fi
    done
  ) >/dev/null 2>&1 &
  /bin/echo "$!" >"$FINDERSERVER_GUARD_PID_FILE"
}

stop_finderserver_timer_guard() {
  [[ -f "$FINDERSERVER_GUARD_PID_FILE" ]] || return 0
  local guard_pid
  guard_pid="$(cat "$FINDERSERVER_GUARD_PID_FILE" 2>/dev/null || true)"
  if [[ "$guard_pid" =~ ^[0-9]+$ ]]; then
    kill "$guard_pid" >/dev/null 2>&1 || true
  fi
  /bin/rm -f "$FINDERSERVER_GUARD_PID_FILE"
}

ensure_gdrive_mount_for_post_move() {
  local target_root="$1"
  path_uses_gdrive_mount "$target_root" || return 0
  if [[ "${GDRIVE_DIRECT_UPLOAD:-1}" == "1" ]]; then
    move_last_status="ready"
    move_last_detail="Direct cloud upload mode is enabled; mount is not required."
    return 0
  fi
  gdrive_mount_active && return 0
  if [[ "${GDRIVE_MOUNT_ENABLED:-1}" != "1" ]]; then
    move_last_status="blocked"
    move_last_detail="Cloud mount disabled (GDRIVE_MOUNT_ENABLED=0)"
    return 1
  fi

  local uid plist label mount_dir wait_seconds retry_csv mount_proc_age
  uid="$(/usr/bin/id -u)"
  plist="$(gdrive_mount_plist_path)"
  label="${GDRIVE_MOUNT_LABEL:-com.ddump.rclone-gdrive}"
  mount_dir="${GDRIVE_MOUNT_POINT:-${HOME}/GoogleDrive}"
  wait_seconds="$(sanitize_positive_int "${GDRIVE_MOUNT_WAIT_SECONDS:-30}" "30")"
  if [[ "$wait_seconds" -lt 10 ]]; then
    wait_seconds=10
  fi
  retry_csv="$(sanitize_retry_schedule_csv "${GDRIVE_MOUNT_RETRY_SECONDS:-15,30,60,180}")"
  if [[ ! -f "$plist" ]]; then
    move_last_status="blocked"
    move_last_detail="Google Drive mount agent missing: ${plist}"
    log "Suppressing mount_failed notification; DDump no longer uses managed Google Drive mounts: ${move_last_detail}"
    return 1
  fi

  /bin/mkdir -p "$mount_dir"

  local attempt=1
  local sleep_seconds
  local -a retry_steps=()
  IFS=',' read -r -a retry_steps <<<"$retry_csv"

  while true; do
    if finderserver_available; then
      if ! run_finderserver on >/dev/null 2>&1; then
        log "finderserver on failed; falling back to launchctl mount start."
      fi
    fi

    mount_proc_age="$(gdrive_mount_process_age_seconds 2>/dev/null || true)"
    if gdrive_mount_present || [[ "$mount_proc_age" =~ ^[0-9]+$ ]]; then
      if [[ "$mount_proc_age" =~ ^[0-9]+$ && "$mount_proc_age" -lt 180 ]]; then
        log "Google Drive mount process is starting (${mount_proc_age}s old); waiting instead of restarting."
      elif [[ "$attempt" -le 2 ]]; then
        log "Google Drive mount is present but not ready; waiting before force restart."
      else
        /bin/launchctl bootstrap "gui/${uid}" "$plist" >/dev/null 2>&1 || true
        /bin/launchctl kickstart -k "gui/${uid}/${label}" >/dev/null 2>&1 || true
        ddump_started_gdrive_mount=1
      fi
    else
      /bin/launchctl bootstrap "gui/${uid}" "$plist" >/dev/null 2>&1 || true
      /bin/launchctl kickstart -k "gui/${uid}/${label}" >/dev/null 2>&1 || true
      ddump_started_gdrive_mount=1
    fi

    local i
    for ((i = 1; i <= wait_seconds; i++)); do
      if gdrive_mount_active; then
        refresh_finderserver_timer_if_low
        start_finderserver_timer_guard
        if [[ "$attempt" -gt 1 ]]; then
          log "Google Drive mount became ready on retry attempt ${attempt}."
        fi
        return 0
      fi
      /bin/sleep 1
    done

    if [[ "${#retry_steps[@]}" -eq 0 ]]; then
      break
    fi
    sleep_seconds="${retry_steps[0]}"
    retry_steps=("${retry_steps[@]:1}")
    if [[ "$sleep_seconds" =~ ^[0-9]+$ ]] && [[ "$sleep_seconds" -gt 0 ]]; then
      log "Google Drive mount not ready after attempt ${attempt}; retrying in ${sleep_seconds}s."
      /bin/sleep "$sleep_seconds"
    else
      break
    fi
    attempt=$((attempt + 1))
  done

  move_last_status="blocked"
  move_last_detail="Google Drive mount did not become ready after retries (${GDRIVE_MOUNT_RETRY_SECONDS:-15,30,60,180})"
  log "Suppressing mount_failed notification; DDump no longer uses managed Google Drive mounts: ${move_last_detail}"
  return 1
}

stop_gdrive_mount_if_started() {
  [[ "${ddump_started_gdrive_mount:-0}" == "1" ]] || return 0
  stop_finderserver_timer_guard
  if ddump_ui_app_running; then
    log "Leaving Google Drive mounted while DDump app is open; idle watcher will unmount after app closes."
    return 0
  fi
  local uid label mount_dir
  uid="$(/usr/bin/id -u)"
  label="${GDRIVE_MOUNT_LABEL:-com.ddump.rclone-gdrive}"
  mount_dir="${GDRIVE_MOUNT_POINT:-${HOME}/GoogleDrive}"

  if gdrive_mount_active; then
    if /sbin/umount -f "$mount_dir" >/dev/null 2>&1 || /usr/sbin/diskutil unmount force "$mount_dir" >/dev/null 2>&1; then
      /bin/launchctl bootout "gui/${uid}/${label}" >/dev/null 2>&1 || true
      log "Stopped Google Drive rclone mount started by DDump."
    else
      log "Google Drive rclone mount was started by DDump but is still busy; leaving it mounted."
    fi
  else
    /bin/launchctl bootout "gui/${uid}/${label}" >/dev/null 2>&1 || true
  fi
}

queue_path_unique() {
  local queue_file="$1"
  local path="$2"
  [[ -n "$path" ]] || return
  if ! /usr/bin/grep -Fxq "$path" "$queue_file" 2>/dev/null; then
    /bin/echo "$path" >>"$queue_file"
  fi
}

path_content_stats() {
  # Prints "file_count<TAB>byte_count" for payload files. Finder metadata files
  # are intentionally ignored because DDump excludes them from post-move copies.
  local root="$1"
  if [[ -f "$root" ]]; then
    local size
    size="$(/usr/bin/stat -f '%z' "$root" 2>/dev/null || /usr/bin/stat -c '%s' "$root" 2>/dev/null || /bin/echo 0)"
    /usr/bin/printf '1\t%s\n' "$size"
    return
  fi

  if [[ ! -d "$root" ]]; then
    /usr/bin/printf '0\t0\n'
    return
  fi

  /usr/bin/find "$root" -type f ! -name '.DS_Store' ! -name '._*' -exec /usr/bin/stat -f '%z' {} \; 2>/dev/null \
    | /usr/bin/awk 'BEGIN { count = 0; bytes = 0 } { count += 1; bytes += $1 } END { printf "%d\t%d\n", count, bytes }'
}

copy_path_to_post_target() {
  local src_path="$1"
  local dest_path="$2"

  if [[ -d "$src_path" ]]; then
    if ! /bin/mkdir -p "$dest_path"; then
      return 1
    fi
    /usr/bin/rsync -rlt --exclude '.DS_Store' --exclude '._*' "$src_path"/ "$dest_path"/ || return 1
  else
    if ! /bin/mkdir -p "$(dirname "$dest_path")"; then
      return 1
    fi
    /usr/bin/rsync -lt --exclude '.DS_Store' --exclude '._*' "$src_path" "$dest_path" || return 1
  fi

  local src_stats dest_stats
  src_stats="$(path_content_stats "$src_path")"
  dest_stats="$(path_content_stats "$dest_path")"
  [[ "$src_stats" == "$dest_stats" ]]
}

copy_path_to_post_target_with_drive_retry() {
  local src_path="$1"
  local dest_path="$2"
  local target_dir="$3"

  if copy_path_to_post_target "$src_path" "$dest_path"; then
    return 0
  fi

  if path_is_google_drive_desktop_path "$target_dir" \
    && ! path_uses_gdrive_mount "$target_dir" \
    && [[ "${GOOGLE_DRIVE_DESKTOP_ENABLED:-1}" == "1" ]] \
    && [[ "${GOOGLE_DRIVE_DESKTOP_RESTART_ON_FAILURE:-1}" == "1" ]]; then
    log "Post-move copy failed for Google Drive Desktop destination; restarting app before one retry: ${dest_path}"
    if ensure_google_drive_desktop_ready_for_path "$target_dir"; then
      copy_path_to_post_target "$src_path" "$dest_path"
      return "$?"
    fi
  fi

  return 1
}

queue_entry_already_uploaded() {
  local src_path="$1"
  local target_dir="$2"
  local base_name dest_path src_stats dest_stats
  [[ -e "$src_path" ]] || return 1
  [[ -d "$target_dir" ]] || return 1
  base_name="$(basename "$src_path")"
  dest_path="${target_dir}/${base_name}"
  [[ -e "$dest_path" ]] || return 1
  src_stats="$(path_content_stats "$src_path")"
  dest_stats="$(path_content_stats "$dest_path")"
  [[ "$src_stats" == "$dest_stats" ]]
}

is_video_file() {
  local path="$1"
  local ext="${path##*.}"
  ext="$(printf '%s' "$ext" | /usr/bin/tr '[:upper:]' '[:lower:]')"
  local item
  IFS=',' read -r -a _video_ext_list <<<"${VIDEO_FILE_EXTENSIONS:-mp4,mov,m4v}"
  for item in "${_video_ext_list[@]}"; do
    item="$(trim "$item")"
    item="${item#.}"
    if [[ "$ext" == "$item" ]]; then
      return 0
    fi
  done
  return 1
}

file_size_bytes() {
  /usr/bin/stat -f '%z' "$1" 2>/dev/null || /usr/bin/stat -c '%s' "$1" 2>/dev/null || /bin/echo 0
}

copy_bucket_split_photo_video() {
  local src_dir="$1"
  local photo_dest="$2"
  local video_dest="$3"
  local file_list
  file_list="$(/usr/bin/mktemp "${STATE_DIR}/split-files.${run_id}.XXXXXX")"
  /usr/bin/find "$src_dir" -type f ! -name '.DS_Store' ! -name '._*' -print0 >"$file_list"

  local file rel dest dest_dir failed_count total_count src_size dest_size
  failed_count=0
  total_count=0
  while IFS= read -r -d '' file; do
    total_count=$((total_count + 1))
    rel="${file#"$src_dir"/}"
    if is_video_file "$file"; then
      dest="${video_dest}/${rel}"
    else
      dest="${photo_dest}/${rel}"
    fi
    dest_dir="$(dirname "$dest")"
    if ! /bin/mkdir -p "$dest_dir"; then
      failed_count=$((failed_count + 1))
      continue
    fi
    if /usr/bin/rsync -lt "$file" "$dest"; then
      src_size="$(file_size_bytes "$file")"
      dest_size="$(file_size_bytes "$dest")"
      if [[ "$src_size" != "$dest_size" ]]; then
        failed_count=$((failed_count + 1))
        log "Split copy size mismatch: ${file} -> ${dest}"
      fi
    else
      failed_count=$((failed_count + 1))
      log "Split copy failed: ${file} -> ${dest}"
    fi
  done <"$file_list"
  /bin/rm -f "$file_list"

  [[ "$total_count" -gt 0 && "$failed_count" -eq 0 ]]
}

rclone_copy_bucket_split_photo_video_remote() {
  local src_dir="$1"
  local photo_remote_dest="$2"
  local video_remote_dest="$3"
  local rclone_bin file_list
  if ! rclone_bin="$(rclone_binary)"; then
    log "Direct split cloud upload failed: rclone not found."
    return 1
  fi

  file_list="$(/usr/bin/mktemp "${STATE_DIR}/split-remote-files.${run_id}.XXXXXX")"
  /usr/bin/find "$src_dir" -type f ! -name '.DS_Store' ! -name '._*' -print0 >"$file_list"

  local file rel rel_dir remote_base remote_dest failed_count total_count
  failed_count=0
  total_count=0
  while IFS= read -r -d '' file; do
    total_count=$((total_count + 1))
    rel="${file#"$src_dir"/}"
    rel_dir="$(dirname "$rel")"
    if is_video_file "$file"; then
      remote_base="$video_remote_dest"
    else
      remote_base="$photo_remote_dest"
    fi
    if [[ "$rel_dir" == "." ]]; then
      remote_dest="$(rclone_remote_join "$remote_base" "$(basename "$rel")")"
    else
      remote_dest="$(rclone_remote_join "$remote_base" "$rel")"
    fi
    if ! rclone_copyto_with_watchdog "$rclone_bin" "$file" "$remote_dest"; then
      failed_count=$((failed_count + 1))
      log "Direct split cloud upload failed: ${file} -> ${remote_dest}"
    fi
  done <"$file_list"
  /bin/rm -f "$file_list"

  [[ "$total_count" -gt 0 && "$failed_count" -eq 0 ]]
}

move_queued_paths_to_post_target() {
  local queue_file="$1"
  local vol_name="$2"
  move_last_status="none"
  move_last_detail=""
  move_last_target=""

  if [[ "$ENABLE_POST_EJECT_MOVE" != "1" ]]; then
    move_last_status="disabled"
    move_last_detail="post-move disabled"
    return 1
  fi

  if [[ ! -s "$queue_file" ]]; then
    move_last_status="empty"
    move_last_detail="nothing queued"
    return 0
  fi

  local split_video_enabled video_target_dir
  split_video_enabled=0
  video_target_dir=""
  if [[ "${SPLIT_PHOTO_VIDEO:-0}" == "1" ]] && video_target_dir="$(build_video_post_move_target_dir)"; then
    split_video_enabled=1
  fi

  local roots_file
  roots_file="$(/usr/bin/mktemp "${STATE_DIR}/post-roots.${run_id}.XXXXXX")"
  collect_post_move_roots | /usr/bin/sort -u >"$roots_file"
  if [[ ! -s "$roots_file" ]]; then
    move_last_status="blocked"
    move_last_detail="no destination roots configured"
    log "Post-move blocked for ${vol_name}: ${move_last_detail}"
    notify "DDump" "${vol_name}: post-move blocked (${move_last_detail})."
    /bin/rm -f "$roots_file"
    return 1
  fi

	  local overall_copied=0
	  local overall_failed=0
	  local destination_count=0
	  local target_list=""
	  local primary_target=""
  local queue_total
  queue_total="$(/usr/bin/awk 'NF { count++ } END { print count + 0 }' "$queue_file" 2>/dev/null || echo 0)"
  local root target_dir display_target direct_cloud remote_target_dir remote_video_target_dir copied_count failed_count src_path base_name dest_path
  while IFS= read -r root || [[ -n "$root" ]]; do
    [[ -n "$root" ]] || continue
    destination_count=$((destination_count + 1))
    target_dir="$(build_post_move_target_dir_for_root "$root")"
    display_target="$target_dir"
    direct_cloud=0
    remote_target_dir=""
    remote_video_target_dir=""
    if direct_cloud_upload_enabled_for_root "$root"; then
      if remote_target_dir="$(gdrive_local_path_to_remote_path "$target_dir")"; then
        direct_cloud=1
        display_target="$remote_target_dir"
        if [[ "$split_video_enabled" == "1" && -n "$video_target_dir" ]]; then
          remote_video_target_dir="$(gdrive_local_path_to_remote_path "$video_target_dir" 2>/dev/null || true)"
        fi
      else
        overall_failed=$((overall_failed + 1))
        log "Post-move blocked for ${vol_name}: cannot map ${target_dir} to ${GDRIVE_REMOTE:-combined:}"
        continue
      fi
    fi
    if [[ -z "$primary_target" ]]; then
      primary_target="$display_target"
    fi
	    if [[ -z "$target_list" ]]; then
	      target_list="$display_target"
	    else
	      target_list="${target_list}, ${display_target}"
	    fi
	    current_upload_total="$queue_total"
	    current_upload_done="$overall_copied"
	    current_upload_failed="$overall_failed"
	    current_upload_target="$display_target"
	    set_upload_status "Uploading to ${display_target}." "$display_target" "" "$overall_copied" "$overall_failed" "$queue_total" "" "" ""

	    if [[ "$direct_cloud" == "1" ]]; then
      if ! rclone_binary >/dev/null 2>&1; then
        overall_failed=$((overall_failed + 1))
        move_last_detail="rclone not found for direct cloud upload"
        log "Post-move blocked for ${vol_name}: ${move_last_detail}"
        continue
      fi
      log "Post-transfer using direct rclone upload for ${vol_name}: target=${remote_target_dir}"
    else
      if ! ensure_gdrive_mount_for_post_move "$root"; then
        overall_failed=$((overall_failed + 1))
        log "Post-move blocked for ${vol_name}: ${move_last_detail}"
        notify "DDump" "${vol_name}: post-move blocked (${move_last_detail})."
        continue
      fi

      if ! path_uses_gdrive_mount "$root" && ! ensure_google_drive_desktop_ready_for_path "$root"; then
        overall_failed=$((overall_failed + 1))
        move_last_detail="Google Drive Desktop folder unavailable after restart"
        log "Post-move blocked for ${vol_name}: ${move_last_detail}: ${root}"
        notify "DDump" "${vol_name}: post-move blocked (${move_last_detail})."
        ntfy_notify "integrity_warning" "DDump: Backup Folder unavailable" "${vol_name}: Backup Folder is unavailable: ${root}"
        continue
      fi

      if [[ ! -d "$root" ]] && ! ensure_sync_provider_path_available "$root"; then
        overall_failed=$((overall_failed + 1))
        move_last_detail="Backup Folder unavailable"
        log "Post-move blocked for ${vol_name}: ${move_last_detail}: ${root}"
        notify "DDump" "${vol_name}: Backup Folder unavailable." warn "integrity_warning"
        ntfy_notify "integrity_warning" "DDump: Backup Folder unavailable" "${vol_name}: Backup Folder is unavailable: ${root}"
        continue
      fi

      if [[ ! -d "$root" ]]; then
        if ! /bin/mkdir -p "$root"; then
          overall_failed=$((overall_failed + 1))
          log "Post-move blocked for ${vol_name}: cannot create destination root ${root}"
          continue
        fi
      fi
      if [[ ! -w "$root" ]]; then
        overall_failed=$((overall_failed + 1))
        log "Post-move blocked for ${vol_name}: destination root not writable ${root}"
        continue
      fi

      if ! /bin/mkdir -p "$target_dir"; then
        overall_failed=$((overall_failed + 1))
        log "Post-move blocked for ${vol_name}: cannot create target dir ${target_dir}"
        continue
      fi
      if ! check_directory_write_probe "$target_dir"; then
        log "Post-move preflight write probe failed for ${vol_name}; continuing anyway: ${target_dir}"
      fi
    fi

    copied_count=0
    failed_count=0
    while IFS= read -r src_path || [[ -n "$src_path" ]]; do
      [[ -n "$src_path" ]] || continue
      [[ -e "$src_path" ]] || continue

      base_name="$(basename "$src_path")"
      if [[ "$direct_cloud" == "1" ]]; then
        dest_path="$(rclone_remote_join "$remote_target_dir" "$base_name")"
        set_upload_status "Uploading ${base_name} to ${remote_target_dir}." "$remote_target_dir" "$base_name" "$overall_copied" "$overall_failed" "$queue_total" "" "" ""
        db_upsert_upload_job "$src_path" "$remote_target_dir" "uploading" "0" "0" ""
        db_mark_media_status_by_local_prefix "$src_path" "upload_pending" ""
        if [[ "$split_video_enabled" == "1" && -d "$src_path" && -n "$remote_video_target_dir" ]]; then
          if rclone_copy_bucket_split_photo_video_remote "$src_path" "$dest_path" "$(rclone_remote_join "$remote_video_target_dir" "$base_name")"; then
            db_update_upload_job_status "$src_path" "uploaded" "0" "0" ""
            db_mark_media_status_by_local_prefix "$src_path" "uploaded" ""
            copied_count=$((copied_count + 1))
            overall_copied=$((overall_copied + 1))
            set_upload_status "Uploaded ${base_name}; continuing cloud upload." "$remote_target_dir" "$base_name" "$overall_copied" "$overall_failed" "$queue_total" "$current_upload_percent" "$current_upload_speed" "$current_upload_eta"
          else
            failed_count=$((failed_count + 1))
            overall_failed=$((overall_failed + 1))
            db_update_upload_job_status "$src_path" "failed" "0" "0" "direct rclone split upload failed"
            db_mark_media_status_by_local_prefix "$src_path" "organized" "direct rclone split upload failed"
            log "Post-move direct rclone split upload failed: ${src_path} -> ${remote_target_dir}"
            set_upload_status "Upload failed for ${base_name}; continuing." "$remote_target_dir" "$base_name" "$overall_copied" "$overall_failed" "$queue_total" "$current_upload_percent" "$current_upload_speed" "$current_upload_eta"
          fi
        elif rclone_copy_path_to_remote_target "$src_path" "$remote_target_dir"; then
          db_update_upload_job_status "$src_path" "uploaded" "0" "0" ""
          db_mark_media_status_by_local_prefix "$src_path" "uploaded" ""
          copied_count=$((copied_count + 1))
          overall_copied=$((overall_copied + 1))
          set_upload_status "Uploaded ${base_name}; continuing cloud upload." "$remote_target_dir" "$base_name" "$overall_copied" "$overall_failed" "$queue_total" "$current_upload_percent" "$current_upload_speed" "$current_upload_eta"
        else
          failed_count=$((failed_count + 1))
          overall_failed=$((overall_failed + 1))
          db_update_upload_job_status "$src_path" "failed" "0" "0" "direct rclone upload failed"
          db_mark_media_status_by_local_prefix "$src_path" "organized" "direct rclone upload failed"
          log "Post-move direct rclone upload failed: ${src_path} -> ${dest_path}"
          set_upload_status "Upload failed for ${base_name}; continuing." "$remote_target_dir" "$base_name" "$overall_copied" "$overall_failed" "$queue_total" "$current_upload_percent" "$current_upload_speed" "$current_upload_eta"
        fi
        continue
      fi

      dest_path="${target_dir}/${base_name}"
      db_upsert_upload_job "$src_path" "$target_dir" "uploading" "0" "0" ""
      db_mark_media_status_by_local_prefix "$src_path" "upload_pending" ""

      if [[ "$split_video_enabled" != "1" ]] && queue_entry_already_uploaded "$src_path" "$target_dir"; then
        db_update_upload_job_status "$src_path" "uploaded" "0" "0" "already complete on destination"
        db_mark_media_status_by_local_prefix "$src_path" "uploaded" ""
        copied_count=$((copied_count + 1))
        continue
      fi

      if [[ "$split_video_enabled" == "1" && -d "$src_path" ]]; then
        if copy_bucket_split_photo_video "$src_path" "$dest_path" "${video_target_dir}/${base_name}"; then
          db_update_upload_job_status "$src_path" "uploaded" "0" "0" ""
          db_mark_media_status_by_local_prefix "$src_path" "uploaded" ""
          copied_count=$((copied_count + 1))
        else
          failed_count=$((failed_count + 1))
          db_update_upload_job_status "$src_path" "failed" "0" "0" "photo/video split copy failed"
          db_mark_media_status_by_local_prefix "$src_path" "organized" "photo/video split copy failed"
          log "Post-move failed (photo/video split): ${src_path} -> ${target_dir}"
        fi
        continue
      fi

      if [[ -e "$dest_path" ]]; then
        if [[ -d "$src_path" && -d "$dest_path" ]]; then
          if copy_path_to_post_target_with_drive_retry "$src_path" "$dest_path" "$target_dir"; then
            db_update_upload_job_status "$src_path" "uploaded" "0" "0" ""
            db_mark_media_status_by_local_prefix "$src_path" "uploaded" ""
            copied_count=$((copied_count + 1))
          elif queue_entry_already_uploaded "$src_path" "$target_dir"; then
            db_update_upload_job_status "$src_path" "uploaded" "0" "0" "verified after retry"
            db_mark_media_status_by_local_prefix "$src_path" "uploaded" ""
            copied_count=$((copied_count + 1))
          else
            failed_count=$((failed_count + 1))
            db_update_upload_job_status "$src_path" "failed" "0" "0" "merge copy failed"
            db_mark_media_status_by_local_prefix "$src_path" "organized" "merge copy failed"
            log "Post-move failed (merge): ${src_path} -> ${dest_path}"
          fi
        else
          failed_count=$((failed_count + 1))
          db_update_upload_job_status "$src_path" "failed" "0" "0" "destination exists and cannot merge"
          db_mark_media_status_by_local_prefix "$src_path" "organized" "destination exists and cannot merge"
          log "Post-move skipped due to existing destination: ${dest_path}"
        fi
        continue
      fi

      if copy_path_to_post_target_with_drive_retry "$src_path" "$dest_path" "$target_dir"; then
        db_update_upload_job_status "$src_path" "uploaded" "0" "0" ""
        db_mark_media_status_by_local_prefix "$src_path" "uploaded" ""
        copied_count=$((copied_count + 1))
      elif queue_entry_already_uploaded "$src_path" "$target_dir"; then
        db_update_upload_job_status "$src_path" "uploaded" "0" "0" "verified after retry"
        db_mark_media_status_by_local_prefix "$src_path" "uploaded" ""
        copied_count=$((copied_count + 1))
      else
        failed_count=$((failed_count + 1))
        db_update_upload_job_status "$src_path" "failed" "0" "0" "copy to destination failed"
        db_mark_media_status_by_local_prefix "$src_path" "organized" "copy to destination failed"
        log "Post-move failed: ${src_path} -> ${dest_path}"
      fi
    done <"$queue_file"

    if [[ "$direct_cloud" != "1" ]]; then
      overall_copied=$((overall_copied + copied_count))
      overall_failed=$((overall_failed + failed_count))
      set_upload_status "Copied ${copied_count} item(s) to ${display_target}." "$display_target" "" "$overall_copied" "$overall_failed" "$queue_total" "" "" ""
    fi
    log "Post-transfer destination result for ${vol_name}: target=${display_target}, copied=${copied_count}, failed=${failed_count}"
  done <"$roots_file"
  /bin/rm -f "$roots_file"

  move_last_target="$primary_target"
  if [[ "$overall_failed" -eq 0 ]]; then
    log "Post-transfer complete for ${vol_name}: copied=${overall_copied}, destinations=${destination_count}, targets=${target_list}"
    notify "DDump" "${vol_name}: copied ${overall_copied} item(s) to ${destination_count} destination(s) (staging kept)."
    move_last_status="success"
    move_last_detail="copied=${overall_copied}, destinations=${destination_count}, targets=${target_list}"
    return 0
  fi

  log "Post-transfer partial for ${vol_name}: copied=${overall_copied}, failed=${overall_failed}, destinations=${destination_count}, targets=${target_list}"
  notify "DDump" "${vol_name}: destination copy had ${overall_failed} error(s)."
  move_last_status="partial"
  move_last_detail="copied=${overall_copied}, failed=${overall_failed}, destinations=${destination_count}, targets=${target_list}"
  return 1
}

set_status_phase "starting" "Preparing import run."
prune_manifest "$MANIFEST_RETENTION_DAYS"

sanitize_eject_grace_seconds() {
  local grace="${EJECT_GRACE_SECONDS:-60}"
  if ! [[ "$grace" =~ ^[0-9]+$ ]]; then
    grace="60"
  fi
  if [[ "$grace" -lt 60 ]]; then
    grace="60"
  fi
  printf '%s' "$grace"
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

sum_candidate_sizes_bytes() {
  local candidate_file="$1"
  local total_bytes=0
  local src_file file_size
  while IFS= read -r -d '' src_file; do
    [[ -f "$src_file" ]] || continue
    file_size="$(/usr/bin/stat -f '%z' "$src_file" 2>/dev/null || /bin/echo 0)"
    if [[ "$file_size" =~ ^[0-9]+$ ]]; then
      total_bytes=$(( total_bytes + file_size ))
    fi
  done <"$candidate_file"
  printf '%s' "$total_bytes"
}

manual_required_kb_for_candidates() {
  local candidate_file="$1"
  local total_bytes safety_gb safety_bytes required_bytes
  total_bytes="$(sum_candidate_sizes_bytes "$candidate_file")"
  if ! [[ "$total_bytes" =~ ^[0-9]+$ ]] || [[ "$total_bytes" -le 0 ]]; then
    return 1
  fi
  safety_gb="$(sanitize_positive_int "${MANUAL_SELECTION_SAFETY_GB:-2}" "2")"
  safety_bytes=$(( safety_gb * 1024 * 1024 * 1024 ))
  required_bytes=$(( total_bytes + safety_bytes ))
  printf '%s' $(( (required_bytes + 1023) / 1024 ))
}

manual_import_policy() {
  local raw
  raw="$(/bin/cat "$MANUAL_SELECTION_POLICY_FILE" 2>/dev/null | /usr/bin/head -n 1 | /usr/bin/tr -d '\r' || true)"
  case "$raw" in
    trust|once) printf '%s' "$raw" ;;
    *) printf 'once' ;;
  esac
}

manual_selection_mentions_volume() {
  local vol_path="$1"
  [[ -n "$MANUAL_SELECTION_FILE" ]] || return 1
  [[ -f "$MANUAL_SELECTION_FILE" ]] || return 1

  local selected_path normalized_path
  while IFS= read -r selected_path || [[ -n "$selected_path" ]]; do
    selected_path="$(trim "$selected_path")"
    [[ -n "$selected_path" ]] || continue
    normalized_path="${selected_path%/}"
    [[ -n "$normalized_path" ]] || continue
    if [[ "$normalized_path" == "$vol_path" || "$normalized_path" == "${vol_path}/"* ]]; then
      return 0
    fi
  done <"$MANUAL_SELECTION_FILE"
  return 1
}

build_manual_candidates_for_volume() {
  local vol_name="$1"
  local vol_path="$2"
  local out_file="$3"
  [[ -n "$MANUAL_SELECTION_FILE" ]] || return 1
  [[ -f "$MANUAL_SELECTION_FILE" ]] || return 1

  : >"$out_file"
  local selected_path normalized_path had_candidates
  had_candidates=1
  while IFS= read -r selected_path || [[ -n "$selected_path" ]]; do
    selected_path="$(trim "$selected_path")"
    [[ -n "$selected_path" ]] || continue
    normalized_path="${selected_path%/}"
    [[ -n "$normalized_path" ]] || continue

    if [[ "$normalized_path" != "$vol_path" && "$normalized_path" != "${vol_path}/"* ]]; then
      continue
    fi

    if [[ -d "$normalized_path" ]]; then
      local scan_file
      scan_file="$(/usr/bin/mktemp "${STATE_DIR}/manual-scan.${vol_name//[^A-Za-z0-9._-]/_}.XXXXXX")"
      find_candidates "$normalized_path" "$scan_file"
      if [[ -s "$scan_file" ]]; then
        /bin/cat "$scan_file" >>"$out_file"
        had_candidates=0
      fi
      /bin/rm -f "$scan_file"
      continue
    fi

    if [[ -f "$normalized_path" ]]; then
      if has_allowed_extension "$normalized_path" "$PHOTO_FILE_EXTENSIONS"; then
        /usr/bin/printf '%s\0' "$normalized_path" >>"$out_file"
        had_candidates=0
      fi
      continue
    fi
  done <"$MANUAL_SELECTION_FILE"

  if [[ "$had_candidates" -ne 0 ]]; then
    log "Manual selection had no paths for ${vol_name}."
    return 1
  fi

  if [[ -s "$out_file" ]]; then
    local dedup_file
    dedup_file="$(/usr/bin/mktemp "${STATE_DIR}/manual-candidates-dedup.${vol_name//[^A-Za-z0-9._-]/_}.XXXXXX")"
    /usr/bin/perl -0ne 'chomp; next if $seen{$_}++; print $_, "\0";' "$out_file" >"$dedup_file" 2>/dev/null || true
    /bin/mv "$dedup_file" "$out_file"
  fi

  return 0
}

check_staging_space_ready() {
  local dest_root="$1"
  local required_kb_override="${2:-}"
  local required_label_override="${3:-}"
  local min_gb
  min_gb="$(sanitize_positive_int "${MIN_FREE_SPACE_GB:-100}" "100")"
  local min_kb required_kb required_label free_kb
  free_kb="$(/bin/df -Pk "$dest_root" 2>/dev/null | /usr/bin/awk 'NR == 2 { print $4 }')"
  if ! [[ "$free_kb" =~ ^[0-9]+$ ]]; then
    log "Could not determine free space for ${dest_root}."
    notify "DDump" "Could not check local free space for import." warn
    return 1
  fi

  min_kb=$(( min_gb * 1024 * 1024 ))
  required_kb="$min_kb"
  required_label="${min_gb}GB required"

  if [[ "$required_kb_override" =~ ^[0-9]+$ ]] && [[ "$required_kb_override" -gt 0 ]]; then
    if [[ "$required_kb" -eq 0 || "$required_kb_override" -lt "$required_kb" ]]; then
      required_kb="$required_kb_override"
      if [[ -n "$required_label_override" ]]; then
        required_label="$required_label_override"
      else
        required_label="$(( (required_kb + 1048575) / 1048576 ))GB required"
      fi
    fi
  fi

  if [[ "$required_kb" -eq 0 ]]; then
    return 0
  fi

  if [[ "$free_kb" -lt "$required_kb" ]]; then
    log "Staging disk too full: dest=${dest_root}, free_kb=${free_kb}, required_kb=${required_kb}"
    notify "DDump" "Not enough local free space for safe import (${required_label})." warn
    return 1
  fi
  return 0
}

bytes_to_human() {
  local bytes="$1"
  if ! [[ "$bytes" =~ ^[0-9]+$ ]]; then
    printf '0B'
    return
  fi
  /usr/bin/awk -v b="$bytes" '
    function fmt(v, u) { if (v >= 100) return sprintf("%.0f%s", v, u); if (v >= 10) return sprintf("%.1f%s", v, u); return sprintf("%.2f%s", v, u); }
    BEGIN {
      if (b >= 1099511627776) { print fmt(b/1099511627776.0, "TB"); exit }
      if (b >= 1073741824)    { print fmt(b/1073741824.0, "GB"); exit }
      if (b >= 1048576)       { print fmt(b/1048576.0, "MB"); exit }
      if (b >= 1024)          { print fmt(b/1024.0, "KB"); exit }
      print b "B"
    }'
}

check_card_almost_full_after_import() {
  local vol_path="$1"
  local vol_name="$2"
  local imported_bytes="$3"

  [[ "${CARD_ALMOST_FULL_ALERT_ENABLED:-1}" == "1" ]] || return 0
  [[ "$imported_bytes" =~ ^[0-9]+$ ]] || return 0
  [[ "$imported_bytes" -gt 0 ]] || return 0
  [[ -d "$vol_path" ]] || return 0

  local free_kb free_bytes imported_human free_human
  free_kb="$(/bin/df -Pk "$vol_path" 2>/dev/null | /usr/bin/awk 'NR == 2 { print $4 }')"
  if ! [[ "$free_kb" =~ ^[0-9]+$ ]]; then
    return 0
  fi
  free_bytes=$((free_kb * 1024))
  if [[ "$free_bytes" -lt "$imported_bytes" ]]; then
    imported_human="$(bytes_to_human "$imported_bytes")"
    free_human="$(bytes_to_human "$free_bytes")"
    log "Card almost full warning: ${vol_name}, free=${free_human}, last_import=${imported_human}"
    notify "DDump" "⚠️ ${vol_name}: only ${free_human} free. Last import was ${imported_human}; another shoot this size likely needs format/card swap." warn "card_almost_full"
    ntfy_notify "card_almost_full" "DDump: card almost full" "${vol_name}: free ${free_human}, last import ${imported_human}. Another similar shoot may require format/card swap."
  fi
}

record_missed_file() {
  local vol_name="$1"
  local reason="$2"
  local path="$3"
  local detail="${4:-}"

  local max_rows
  max_rows="$(sanitize_positive_int "${MISSED_REPORT_MAX_ROWS:-5000}" "5000")"
  if [[ "$missed_report_rows" -ge "$max_rows" ]]; then
    if [[ "$missed_report_truncated" -eq 0 ]]; then
      /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' "$run_timestamp" "$vol_name" "truncated" "-" "missed report row cap reached (${max_rows})" >>"$missed_report_file"
      missed_report_truncated=1
    fi
    return
  fi

  /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' "$run_timestamp" "$vol_name" "$reason" "$path" "$detail" >>"$missed_report_file"
  missed_report_rows=$((missed_report_rows + 1))
}

verify_copied_file() {
  local src_file="$1"
  local dest_file="$2"
  local expected_size="$3"
  local expected_hash="$4"

  COPY_VERIFY_FAILURE_REASON=""
  COPY_VERIFY_FAILURE_DETAIL=""

  if [[ "$VERIFY_COPIED_FILES" != "1" ]]; then
    return 0
  fi

  if [[ ! -f "$dest_file" ]]; then
    COPY_VERIFY_FAILURE_REASON="verify_missing_dest"
    COPY_VERIFY_FAILURE_DETAIL="destination file missing after copy"
    return 1
  fi

  local dest_size
  dest_size="$(/usr/bin/stat -f '%z' "$dest_file" 2>/dev/null || /bin/echo -1)"
  if [[ "$dest_size" != "$expected_size" ]]; then
    COPY_VERIFY_FAILURE_REASON="verify_size_mismatch"
    COPY_VERIFY_FAILURE_DETAIL="expected_size=${expected_size}, dest_size=${dest_size}"
    return 1
  fi

  if [[ "$VERIFY_COPY_HASH" == "1" ]]; then
    local dest_hash
    dest_hash="$(/usr/bin/shasum -a 256 "$dest_file" | /usr/bin/awk '{print $1}')"
    if [[ "$dest_hash" != "$expected_hash" ]]; then
      COPY_VERIFY_FAILURE_REASON="verify_hash_mismatch"
      COPY_VERIFY_FAILURE_DETAIL="expected_hash=${expected_hash}, dest_hash=${dest_hash}"
      return 1
    fi
  fi

  return 0
}

check_post_move_ready() {
  if [[ "$ENABLE_POST_EJECT_MOVE" != "1" ]]; then
    move_last_status="disabled"
    move_last_detail="post-move disabled"
    return 1
  fi

  if [[ "$POST_MOVE_REQUIRE_READY" != "1" ]]; then
    move_last_status="ready"
    move_last_detail="ready check bypassed"
    return 0
  fi

  local ready_root
  ready_root="$(effective_post_move_root)"

  if [[ -z "$ready_root" ]]; then
    move_last_status="blocked"
    move_last_detail="post-move root empty"
    return 1
  fi

  if direct_cloud_upload_enabled_for_root "$ready_root"; then
    if ! rclone_binary >/dev/null 2>&1; then
      move_last_status="blocked"
      move_last_detail="rclone not found for direct cloud upload"
      return 1
    fi
    if ! gdrive_local_path_to_remote_path "$(build_post_move_target_dir_for_root "$ready_root")" >/dev/null 2>&1; then
      move_last_status="blocked"
      move_last_detail="cannot map Google Drive destination to rclone remote"
      return 1
    fi
    move_last_status="ready"
    move_last_detail="direct rclone upload ready"
    return 0
  fi

  if path_uses_gdrive_mount "$ready_root" && ! gdrive_mount_active; then
    move_last_status="blocked"
    move_last_detail="Google Drive mount not active"
    return 1
  fi

  if [[ ! -d "$ready_root" ]]; then
    move_last_status="blocked"
    move_last_detail="post-move root missing: $ready_root"
    return 1
  fi

  if [[ ! -w "$ready_root" ]]; then
    move_last_status="blocked"
    move_last_detail="post-move root not writable: $ready_root"
    return 1
  fi

  move_last_status="ready"
  move_last_detail="post-move root reachable"
  return 0
}

check_directory_write_probe() {
  local dir="$1"
  local probe_file_hidden probe_file_plain
  [[ -n "$dir" && -d "$dir" ]] || return 1

  probe_file_hidden="${dir}/.ddump-write-test-${run_id}-$$"
  probe_file_plain="${dir}/ddump-write-test-${run_id}-$$"
  if /usr/bin/touch "$probe_file_hidden" 2>/dev/null; then
    /bin/rm -f "$probe_file_hidden" 2>/dev/null || true
    return 0
  fi

  # Some sync providers reject hidden probe files from background processes.
  if /usr/bin/touch "$probe_file_plain" 2>/dev/null; then
    /bin/rm -f "$probe_file_plain" 2>/dev/null || true
    return 0
  fi
  return 1
}

show_run_summary_dialog() {
  local message="$1"
  local open_path="$2"
  [[ "$SHOW_RUN_SUMMARY_DIALOG" == "1" ]] || return 0

  local timeout
  timeout="$(sanitize_positive_int "${SUMMARY_DIALOG_TIMEOUT_SECONDS:-20}" "20")"
  if [[ "$timeout" -lt 5 ]]; then
    timeout="5"
  fi

  SUMMARY_MSG="$message" SUMMARY_OPEN_PATH="$open_path" SUMMARY_TIMEOUT="$timeout" /usr/bin/osascript <<'OSA' >/dev/null 2>&1 || true
set summaryMsg to system attribute "SUMMARY_MSG"
set openPath to system attribute "SUMMARY_OPEN_PATH"
set timeoutRaw to system attribute "SUMMARY_TIMEOUT"
set timeoutSeconds to 20

try
  set timeoutSeconds to timeoutRaw as integer
on error
  set timeoutSeconds to 20
end try

set d to display dialog summaryMsg buttons {"Open Folder", "OK"} default button "OK" with title "DDump" giving up after timeoutSeconds
if button returned of d is "Open Folder" and openPath is not "" then
  do shell script "/usr/bin/open " & quoted form of openPath
end if
OSA
}

write_daily_digest() {
  local digest_file="$1"
  local summary_message="$2"
  local kept_msg="$3"
  local post_move_msg="$4"
  local error_msg="$5"
  local missed_report_line

  should_write_daily_digest || return 0
  missed_report_line="${missed_report_file:-none}"
  if [[ "$missed_report_line" != "none" && ! -f "$missed_report_line" ]]; then
    missed_report_line="none"
  fi

  {
    /bin/echo "## ${run_timestamp} (run ${run_id})"
    /bin/echo ""
    /bin/echo "${summary_message}"
    /bin/echo ""
    /bin/echo "- missed report: ${missed_report_line}"
    /bin/echo "- kept mounted events: ${kept_msg}"
    /bin/echo "- post-move status: ${post_move_msg}"
    /bin/echo "- errors: ${error_msg}"
    /bin/echo ""
    /bin/echo "Recent run history:"
    /bin/echo '```'
    /usr/bin/tail -n 8 "$RUN_HISTORY_FILE"
    /bin/echo '```'
    /bin/echo ""
  } >>"$digest_file"
}

should_write_daily_digest() {
  [[ "$WRITE_DAILY_DIGEST" == "1" ]] || return 1
  [[ "${processed_volume_count:-0}" -gt 0 ]] && return 0
  [[ "${pending_recovery_touched:-0}" -gt 0 ]] && return 0
  [[ "${summary_errors_total:-0}" -gt 0 ]] && return 0
  [[ "${summary_kept_mounted_total:-0}" -gt 0 ]] && return 0
  [[ "${summary_post_move_blocked_total:-0}" -gt 0 ]] && return 0
  [[ "${summary_post_move_fail_total:-0}" -gt 0 ]] && return 0
  return 1
}

finalize_empty_missed_report() {
  if [[ "${missed_report_rows:-0}" -eq 0 && "${missed_report_truncated:-0}" -eq 0 && -f "$missed_report_file" ]]; then
    /bin/rm -f "$missed_report_file"
    missed_report_file=""
  fi
}

write_upload_receipt() {
  local vol_name="$1"
  local receipt_status="$2"
  local target_dir="$3"
  local queue_file="$4"

  [[ "${UPLOAD_RECEIPTS_ENABLED:-1}" == "1" ]] || return 0
  local receipt_file="${REPORT_DIR}/upload-receipt-${run_id}-$(pending_key_for_volume "$vol_name" "$vol_name").md"
  {
    /bin/echo "# DDump Upload Receipt"
    /bin/echo ""
    /bin/echo "- run: ${run_id}"
    /bin/echo "- time: $(/bin/date '+%Y-%m-%d %H:%M:%S')"
    /bin/echo "- card: ${vol_name}"
    /bin/echo "- status: ${receipt_status}"
    /bin/echo "- destination: ${target_dir}"
	    /bin/echo "- detail: ${move_last_detail:-}"
	    /bin/echo ""
	    /bin/echo "## Folders"
	    local src_path base_name dest_path video_dest_path stats receipt_video_target
	    if [[ "$target_dir" != /* && "$target_dir" == *:* ]]; then
	      while IFS= read -r src_path || [[ -n "$src_path" ]]; do
	        [[ -n "$src_path" ]] || continue
	        base_name="$(basename "$src_path")"
	        dest_path="$(rclone_remote_join "$target_dir" "$base_name")"
	        if [[ -e "$src_path" ]]; then
	          stats="$(path_content_stats "$src_path")"
	          /usr/bin/printf -- '- uploaded: %s\t%s\n' "$dest_path" "$stats"
	        else
	          /usr/bin/printf -- '- uploaded: %s\n' "$dest_path"
	        fi
	      done <"$queue_file"
	    else
	      receipt_video_target=""
	      if [[ "${SPLIT_PHOTO_VIDEO:-0}" == "1" ]]; then
	        receipt_video_target="$(build_video_post_move_target_dir 2>/dev/null || true)"
	      fi
	      while IFS= read -r src_path || [[ -n "$src_path" ]]; do
	        [[ -n "$src_path" ]] || continue
	        base_name="$(basename "$src_path")"
	        dest_path="${target_dir}/${base_name}"
	        video_dest_path="${receipt_video_target}/${base_name}"
	        if [[ -e "$dest_path" ]]; then
	          stats="$(path_content_stats "$dest_path")"
	          /usr/bin/printf -- '- %s\t%s\n' "$dest_path" "$stats"
	        elif [[ -n "$receipt_video_target" && -e "$video_dest_path" ]]; then
	          stats="$(path_content_stats "$video_dest_path")"
	          /usr/bin/printf -- '- %s\t%s\n' "$video_dest_path" "$stats"
	        elif [[ -e "$src_path" ]]; then
	          stats="$(path_content_stats "$src_path")"
	          /usr/bin/printf -- '- pending: %s\t%s\n' "$src_path" "$stats"
	        else
	          /usr/bin/printf -- '- missing after attempt: %s\n' "$src_path"
	        fi
	      done <"$queue_file"
	    fi
  } >"$receipt_file"
  log "Wrote upload receipt: ${receipt_file}"
}

start_no_eject_prompt() {
  local vol_name="$1"
  local hold_file="$2"

  [[ "$EJECT_ON_SUCCESS" == "1" ]] || return 0
  [[ "$PROMPT_NO_EJECT_ON_START" == "1" ]] || return 0

  local grace
  grace="$(sanitize_eject_grace_seconds)"
  /bin/rm -f "$hold_file"

  (
    KEEP_FILE="$hold_file" VOL_NAME="$vol_name" GRACE_SECONDS="$grace" /usr/bin/osascript <<'OSA'
set keepFile to system attribute "KEEP_FILE"
set volName to system attribute "VOL_NAME"
set graceRaw to system attribute "GRACE_SECONDS"
set graceSeconds to 60

try
  set graceSeconds to graceRaw as integer
on error
  set graceSeconds to 60
end try

set promptText to "DDump started importing '" & volName & "'.\n\nClick 'Do Not Eject' within " & graceSeconds & " seconds to keep the card mounted after import finishes."
set dialogResult to display dialog promptText buttons {"Do Not Eject"} default button "Do Not Eject" with title "DDump" giving up after graceSeconds

if button returned of dialogResult is "Do Not Eject" then
  do shell script "/bin/echo 1 > " & quoted form of keepFile
end if
OSA
  ) >/dev/null 2>&1 || true
}

keep_mounted_requested() {
  local hold_file="${1:-}"
  if [[ -f "$KEEP_MOUNTED_FLAG" ]]; then
    return 0
  fi
  if [[ -n "$hold_file" && -f "$hold_file" ]]; then
    return 0
  fi
  return 1
}

wait_for_min_eject_grace() {
  # If the user pressed "Eject after this file", skip the grace wait entirely.
  if [[ -f "$EJECT_NOW_FLAG" ]]; then
    return
  fi
  local started_epoch="$1"
  local grace
  grace="$(sanitize_eject_grace_seconds)"
  local now elapsed remaining
  now="$(/bin/date '+%s')"
  elapsed=$(( now - started_epoch ))
  remaining=$(( grace - elapsed ))
  if [[ "$remaining" -gt 0 ]]; then
    # Wake up early if the user presses "Eject after this file" mid-wait.
    while [[ "$remaining" -gt 0 ]]; do
      [[ -f "$EJECT_NOW_FLAG" ]] && return
      /bin/sleep 1
      remaining=$(( remaining - 1 ))
    done
  fi
}

diskutil_eject_with_timeout() {
  local vol_path="$1"
  local vol_name="$2"
  local timeout
  timeout="$(sanitize_positive_int "${EJECT_TIMEOUT_SECONDS:-20}" "20")"
  if [[ "$timeout" -lt 5 ]]; then
    timeout=5
  fi

  /usr/sbin/diskutil eject "$vol_path" >/dev/null 2>&1 &
  local eject_pid="$!"
  local elapsed=0
  while /bin/kill -0 "$eject_pid" >/dev/null 2>&1; do
    if [[ "$elapsed" -ge "$timeout" ]]; then
      /bin/kill -TERM "$eject_pid" >/dev/null 2>&1 || true
      /bin/sleep 1
      /bin/kill -KILL "$eject_pid" >/dev/null 2>&1 || true
      wait "$eject_pid" >/dev/null 2>&1 || true
      log "Eject timed out after ${timeout}s for ${vol_name}; continuing with upload."
      return 124
    fi
    /bin/sleep 1
    elapsed=$((elapsed + 1))
  done
  wait "$eject_pid" >/dev/null 2>&1
}

activate_ddump_app_for_card() {
  [[ "${OPEN_APP_ON_CARD_INSERT:-1}" == "1" ]] || return 0
  if [[ -d "$HOME/Applications/DDump.app" ]]; then
    /usr/bin/open "$HOME/Applications/DDump.app" >/dev/null 2>&1 &
  else
    /usr/bin/open -b "com.ddump.app" >/dev/null 2>&1 &
  fi
}

find_candidates() {
  local source_root="$1"
  local out_file="$2"
  local hours
  hours="$(sanitize_positive_int "${LOOKBACK_HOURS:-24}" "24")"
  if [[ "${CANDIDATE_MODE:-lookback}" != "lookback" ]]; then
    log "CANDIDATE_MODE='${CANDIDATE_MODE}' overridden to lookback for safety."
  fi
  /usr/bin/find "$source_root" -type f -print0 2>/dev/null \
    | /usr/bin/perl -0ne 'BEGIN { $hours = shift @ARGV; $cutoff = time - ($hours * 3600) } chomp; print $_, "\0" if -f $_ && (stat($_))[9] >= $cutoff' "$hours" \
    >"$out_file" || true
}

has_allowed_extension() {
  local file="$1"
  local ext_list="$2"

  if [[ -z "$ext_list" ]]; then
    ext_list="${PHOTO_FILE_EXTENSIONS:-}"
  fi

  if [[ -z "$ext_list" ]]; then
    return 0
  fi

  local ext="${file##*.}"
  ext="$(printf '%s' "$ext" | /usr/bin/tr '[:upper:]' '[:lower:]')"

  IFS=',' read -r -a allowed <<<"$ext_list"
  for raw in "${allowed[@]}"; do
    local candidate
    candidate="$(trim "$raw")"
    candidate="${candidate#.}"
    candidate="$(printf '%s' "$candidate" | /usr/bin/tr '[:upper:]' '[:lower:]')"
    if [[ -n "$candidate" && "$ext" == "$candidate" ]]; then
      return 0
    fi
  done

  return 1
}

is_ignored_source_file() {
  local file="$1"
  local base
  base="$(basename "$file")"
  case "$base" in
    .DS_Store|._*|fseventsd-uuid|.metadata_never_index|.VolumeIcon.icns)
      return 0
      ;;
  esac
  case "$file" in
    */.fseventsd/*|*/.Spotlight-V100/*|*/.Trashes/*|*/.TemporaryItems/*|*/.DocumentRevisions-V100/*)
      return 0
      ;;
  esac
  return 1
}

staging_memory_has_candidate() {
  # Staging folder is the default memory mode when DB is disabled.
  # Check the expected relative path first, then a same-name+size fallback
  # anywhere under the staging day folder (covers post-rebucket paths).
  local dest_dir="$1"
  local rel_path="$2"
  local file_size="$3"
  [[ -d "$dest_dir" ]] || return 1
  [[ -n "$rel_path" ]] || return 1

  local safe_rel_path expected_path expected_size base_name hit
  safe_rel_path="${rel_path//:/_}"
  expected_path="${dest_dir}/${safe_rel_path}"
  if [[ -f "$expected_path" ]]; then
    expected_size="$(file_size_bytes "$expected_path")"
    if [[ "$expected_size" == "$file_size" ]]; then
      return 0
    fi
  fi

  base_name="$(basename "$safe_rel_path")"
  hit="$(/usr/bin/find "$dest_dir" -type f -name "$base_name" -size "${file_size}c" -print -quit 2>/dev/null || true)"
  [[ -n "$hit" ]]
}

get_volume_uuid() {
  local vol_path="$1"
  local uuid

  uuid="$(/usr/sbin/diskutil info "$vol_path" 2>/dev/null | /usr/bin/awk -F': *' '/Volume UUID/ {print $2; exit}')"
  uuid="$(trim "$uuid")"
  printf '%s' "$uuid"
}

is_internal_volume() {
  local vol_path="$1"
  local internal_flag location
  internal_flag="$(/usr/sbin/diskutil info "$vol_path" 2>/dev/null | /usr/bin/awk -F': *' '/^ *Internal/ {print $2; exit}' | /usr/bin/xargs)"
  location="$(/usr/sbin/diskutil info "$vol_path" 2>/dev/null | /usr/bin/awk -F': *' '/Device Location/ {print $2; exit}' | /usr/bin/xargs)"
  [[ "$internal_flag" == "Yes" || "$location" == "Internal" ]]
}

is_uuid_trusted() {
  local uuid="$1"
  [[ -n "$uuid" ]] || return 1
  /usr/bin/grep -Fxq "$uuid" "$TRUSTED_UUID_FILE"
}

remember_uuid() {
  local uuid="$1"
  [[ -n "$uuid" ]] || return 1
  if ! is_uuid_trusted "$uuid"; then
    /bin/echo "$uuid" >>"$TRUSTED_UUID_FILE"
  fi
}

prompt_to_trust_volume() {
  local vol_name="$1"
  local uuid="$2"

  [[ "$PROMPT_TO_REMEMBER_UNKNOWN" == "1" ]] || return 1
  [[ -n "$uuid" ]] || return 1

  local response
  response="$(notify_ask "Trust this card?" "DDump found ${vol_name}. Remember it for future imports?" "Trust" "Not now")"

  if [[ "$response" == "Trust" ]]; then
    remember_uuid "$uuid"
    notify "DDump" "Trusted card saved: ${vol_name}" done
    return 0
  fi

  return 1
}

is_ignored_volume_name() {
  local vol_name="$1"
  local raw_list="${IGNORE_VOLUME_NAMES:-}"
  [[ -n "$raw_list" ]] || return 1

  local item
  IFS=',' read -r -a _ignored_list <<<"$raw_list"
  for item in "${_ignored_list[@]}"; do
    item="$(trim "$item")"
    [[ -n "$item" ]] || continue
    if [[ "$vol_name" == "$item" ]]; then
      return 0
    fi
  done

  return 1
}

is_uuid_blocked() {
  local uuid="$1"
  [[ -n "$uuid" ]] || return 1
  /usr/bin/grep -Fxq "$uuid" "$BLOCKED_UUID_FILE"
}

remember_uuid_blocked() {
  local uuid="$1"
  [[ -n "$uuid" ]] || return 1
  if ! is_uuid_blocked "$uuid"; then
    /bin/echo "$uuid" >>"$BLOCKED_UUID_FILE"
  fi
}

get_card_policy_mode() {
  local uuid="$1"
  [[ -n "$uuid" ]] || return 1
  /usr/bin/awk -F'\t' -v u="$uuid" '$1 == u { mode = $2 } END { if (mode != "") print mode }' "$CARD_POLICY_FILE"
}

set_card_policy_mode() {
  local uuid="$1"
  local mode="$2"
  [[ -n "$uuid" ]] || return 1
  [[ -n "$mode" ]] || return 1
  local tmp_file
  tmp_file="$(/usr/bin/mktemp "${STATE_DIR}/card-policy.XXXXXX")"
  /usr/bin/awk -F'\t' -v u="$uuid" '$1 != u { print }' "$CARD_POLICY_FILE" >"$tmp_file"
  /usr/bin/printf '%s\t%s\t%s\n' "$uuid" "$mode" "$(/bin/date '+%Y-%m-%d %H:%M:%S')" >>"$tmp_file"
  /bin/mv "$tmp_file" "$CARD_POLICY_FILE"
}

prompt_for_unknown_card_action() {
  local vol_name="$1"
  local uuid="$2"
  local photo_total="${3:-0}"
  local photo_recent="${4:-0}"

  [[ "$PROMPT_FOR_UNKNOWN_CARD_ACTION" == "1" ]] || return 1
  [[ -n "$uuid" ]] || return 1

  local title="📷 Card detected"
  local msg
  if [[ "$photo_total" =~ ^[0-9]+$ && "$photo_total" -gt 0 ]]; then
    msg="${vol_name} — ${photo_total} photo file(s)"
    if [[ "$photo_recent" =~ ^[0-9]+$ && "$photo_recent" -gt 0 ]]; then
      msg="${msg}, ${photo_recent} from the last ${PHOTO_RECENCY_HOURS:-24}h"
    fi
    msg="${msg}. Import?"
  else
    msg="${vol_name}. Import?"
  fi

  local action
  action="$(notify_ask "$title" "$msg" "Trust" "Just this time" "Skip" "Never")"

  case "$action" in
    "Trust")
      remember_uuid "$uuid"
      set_card_policy_mode "$uuid" "remember"
      notify "DDump" "Trusted card saved: ${vol_name}" done
      return 0
      ;;
    "Just this time")
      # Don't remember the UUID; let the run proceed but skip the trust persistence.
      notify "DDump" "Importing once: ${vol_name}" info
      return 0
      ;;
    "Never")
      remember_uuid_blocked "$uuid"
      notify "DDump" "${vol_name}: this card is now blocked." info
      return 2
      ;;
    "Skip"|"")
      return 1
      ;;
    *)
      return 1
      ;;
  esac
}

normalize_source_root_rel_path() {
  local rel_path="$1"
  rel_path="$(trim "$rel_path")"
  rel_path="${rel_path%/}"
  if [[ -z "$rel_path" || "$rel_path" == "." || "$rel_path" == "/" ]]; then
    printf '.'
    return
  fi
  rel_path="${rel_path#/}"
  printf '%s' "$rel_path"
}

source_root_saved_for_uuid() {
  local uuid="$1"
  local rel_path="$2"
  /usr/bin/awk -F'\t' -v u="$uuid" -v p="$rel_path" '$1 == u && $2 == p { found = 1; exit } END { exit(found ? 0 : 1) }' "$SOURCE_ROOTS_FILE"
}

remember_source_root_for_uuid() {
  local uuid="$1"
  local rel_path="$2"
  [[ -n "$uuid" ]] || return 1
  rel_path="$(normalize_source_root_rel_path "$rel_path")"
  if ! source_root_saved_for_uuid "$uuid" "$rel_path"; then
    /usr/bin/printf '%s\t%s\t%s\n' "$uuid" "$rel_path" "$(/bin/date '+%Y-%m-%d %H:%M:%S')" >>"$SOURCE_ROOTS_FILE"
  fi
}

load_source_roots_for_uuid() {
  local uuid="$1"
  local vol_path="$2"
  local out_file="$3"
  [[ -n "$uuid" ]] || return 1

  local found_any=1
  local saved_uuid saved_rel saved_at abs_path normalized_rel
  while IFS=$'\t' read -r saved_uuid saved_rel saved_at; do
    [[ "$saved_uuid" == "$uuid" ]] || continue
    normalized_rel="$(normalize_source_root_rel_path "$saved_rel")"
    if [[ "$normalized_rel" == "." ]]; then
      abs_path="$vol_path"
    else
      abs_path="${vol_path}/${normalized_rel}"
    fi

    if [[ -d "$abs_path" ]]; then
      queue_path_unique "$out_file" "$abs_path"
      found_any=0
    else
      log "Saved source folder missing on ${vol_path}: ${abs_path}"
    fi
  done <"$SOURCE_ROOTS_FILE"

  return "$found_any"
}

prompt_to_choose_source_roots() {
  local vol_name="$1"
  local vol_path="$2"
  local uuid="$3"
  local out_file="$4"
  local save_mode="${5:-1}"

  [[ "$PROMPT_FOR_SOURCE_FOLDERS_ON_NEW_DRIVE" == "1" ]] || return 1

  local picked_paths
  picked_paths="$(VOL_NAME="$vol_name" VOL_PATH="$vol_path" /usr/bin/osascript <<'OSA' 2>/dev/null || true
set volName to system attribute "VOL_NAME"
set volPath to system attribute "VOL_PATH"
set promptText to "New card detected: '" & volName & "'. Select one or more folders to import."
set defaultAlias to POSIX file volPath as alias

try
  set pickedFolders to choose folder with prompt promptText default location defaultAlias with multiple selections allowed
on error number -128
  return "__CANCELLED__"
end try

if pickedFolders is {} then
  return "__CANCELLED__"
end if

set pickedPaths to {}
repeat with pickedFolder in pickedFolders
  set end of pickedPaths to POSIX path of pickedFolder
end repeat

set text item delimiters of AppleScript to linefeed
return pickedPaths as text
OSA
)"

  if [[ "$picked_paths" == "__CANCELLED__" ]]; then
    log "Folder selection canceled for ${vol_name}."
    return 1
  fi

  local had_valid=1
  local selected_path rel_path normalized_rel abs_path
  while IFS= read -r selected_path || [[ -n "$selected_path" ]]; do
    selected_path="$(trim "$selected_path")"
    [[ -n "$selected_path" ]] || continue
    selected_path="${selected_path%/}"
    if [[ -z "$selected_path" ]]; then
      continue
    fi

    if [[ "$selected_path" == "$vol_path" ]]; then
      rel_path="."
    elif [[ "$selected_path" == "${vol_path}/"* ]]; then
      rel_path="${selected_path#"${vol_path}/"}"
    else
      log "Ignoring selected folder outside volume ${vol_name}: ${selected_path}"
      continue
    fi

    normalized_rel="$(normalize_source_root_rel_path "$rel_path")"
    if [[ "$normalized_rel" == "." ]]; then
      abs_path="$vol_path"
    else
      abs_path="${vol_path}/${normalized_rel}"
    fi

    if [[ ! -d "$abs_path" ]]; then
      log "Ignoring selected folder that does not exist on ${vol_name}: ${abs_path}"
      continue
    fi

    queue_path_unique "$out_file" "$abs_path"
    if [[ "$save_mode" == "1" && -n "$uuid" ]]; then
      remember_source_root_for_uuid "$uuid" "$normalized_rel"
    fi
    had_valid=0
  done <<<"$picked_paths"

  if [[ "$had_valid" -ne 0 ]]; then
    log "No valid source folders selected for ${vol_name}."
    return 1
  fi

  if [[ "$save_mode" == "1" ]]; then
    notify "DDump" "Saved source folder selections for ${vol_name}."
  fi
  return 0
}

resolve_source_roots_for_volume() {
  local vol_name="$1"
  local vol_path="$2"
  local uuid="$3"
  local out_file="$4"

  : >"$out_file"

  if [[ "${PROMPT_FOR_SOURCE_FOLDERS_ON_NEW_DRIVE:-0}" != "1" ]]; then
    queue_path_unique "$out_file" "$vol_path"
    log "Scanning entire card for ${vol_name}; folder chooser is disabled."
    return 0
  fi

  local policy_mode
  policy_mode="$(get_card_policy_mode "$uuid" 2>/dev/null || true)"
  if [[ -z "$policy_mode" ]]; then
    policy_mode="remember"
  fi

  if [[ "$policy_mode" == "ask_every_time" ]]; then
    prompt_to_choose_source_roots "$vol_name" "$vol_path" "$uuid" "$out_file" "0" || true
  else
    load_source_roots_for_uuid "$uuid" "$vol_path" "$out_file" || true
    if [[ ! -s "$out_file" ]]; then
      prompt_to_choose_source_roots "$vol_name" "$vol_path" "$uuid" "$out_file" "1" || true
    fi
  fi

  if [[ ! -s "$out_file" && "$SOURCE_SUBDIR_FALLBACK_ON_EMPTY_SELECTION" == "1" ]]; then
    local fallback_root="${vol_path}/${SOURCE_SUBDIR}"
    if [[ -d "$fallback_root" ]]; then
      queue_path_unique "$out_file" "$fallback_root"
      if [[ -n "$uuid" ]]; then
        remember_source_root_for_uuid "$uuid" "$SOURCE_SUBDIR"
      fi
      log "Using default source folder for ${vol_name}: ${fallback_root}"
    fi
  fi

  [[ -s "$out_file" ]]
}

fast_seen_key_exists() {
  local uuid="$1"
  local root_rel="$2"
  local rel_path="$3"
  local file_size="$4"
  local file_mtime="$5"
  /usr/bin/awk -F'\t' -v u="$uuid" -v r="$root_rel" -v p="$rel_path" -v s="$file_size" -v m="$file_mtime" '$1 == u && $2 == r && $3 == p && $4 == s && $5 == m { found = 1; exit } END { exit(found ? 0 : 1) }' "$FAST_SEEN_FILE"
}

record_fast_seen_key() {
  local uuid="$1"
  local root_rel="$2"
  local rel_path="$3"
  local file_size="$4"
  local file_mtime="$5"
  local fingerprint="$6"
  /usr/bin/printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$uuid" "$root_rel" "$rel_path" "$file_size" "$file_mtime" "$fingerprint" "$(/bin/date '+%Y-%m-%d %H:%M:%S')" >>"$FAST_SEEN_FILE"
}

count_candidates_in_file() {
  local candidate_file="$1"
  /usr/bin/tr -cd '\0' <"$candidate_file" | /usr/bin/wc -c | /usr/bin/awk '{print $1}'
}

db_has_needs_reinsert_for_uuid() {
  local uuid="$1"
  db_available || return 1
  local count
  count="$(/usr/bin/sqlite3 "$DB_FILE" "PRAGMA busy_timeout=5000; SELECT COUNT(*) FROM media_files WHERE source_uuid=$(sql_quote "$uuid") AND status='needs_reinsert';" 2>>"$LOG_FILE" || /bin/echo 0)"
  [[ "${count:-0}" -gt 0 ]]
}

prioritize_needs_reinsert_candidates() {
  local uuid="$1"
  local source_root_rel="$2"
  local candidate_file="$3"
  db_available || return 0
  [[ -n "$uuid" ]] || return 0
  [[ -s "$candidate_file" ]] || return 0

  local needs_file priority_file normal_file merged_file
  needs_file="$(/usr/bin/mktemp "${STATE_DIR}/needs-reinsert.${run_id}.XXXXXX")"
  priority_file="$(/usr/bin/mktemp "${STATE_DIR}/priority-first.${run_id}.XXXXXX")"
  normal_file="$(/usr/bin/mktemp "${STATE_DIR}/priority-rest.${run_id}.XXXXXX")"
  merged_file="$(/usr/bin/mktemp "${STATE_DIR}/priority-merged.${run_id}.XXXXXX")"

  /usr/bin/sqlite3 "$DB_FILE" "PRAGMA busy_timeout=5000; SELECT source_path FROM media_files WHERE source_uuid=$(sql_quote "$uuid") AND source_root_rel=$(sql_quote "$source_root_rel") AND status='needs_reinsert' AND source_path IS NOT NULL ORDER BY updated_at ASC;" >"$needs_file" 2>>"$LOG_FILE" || true

  if [[ ! -s "$needs_file" ]]; then
    /bin/rm -f "$needs_file" "$priority_file" "$normal_file" "$merged_file"
    return 0
  fi

  DDUMP_NEEDS_REINSERT_LIST="$needs_file" \
    /usr/bin/perl -0ne '
      BEGIN {
        my $list = $ENV{"DDUMP_NEEDS_REINSERT_LIST"} // "";
        if ($list ne "" && open(my $fh, "<", $list)) {
          while (my $line = <$fh>) {
            chomp $line;
            $need{$line} = 1 if $line ne "";
          }
          close $fh;
        }
      }
      chomp;
      next if $_ eq "";
      if ($need{$_}) {
        print $_, "\0";
      }
    ' "$candidate_file" >"$priority_file"

  DDUMP_NEEDS_REINSERT_LIST="$needs_file" \
    /usr/bin/perl -0ne '
      BEGIN {
        my $list = $ENV{"DDUMP_NEEDS_REINSERT_LIST"} // "";
        if ($list ne "" && open(my $fh, "<", $list)) {
          while (my $line = <$fh>) {
            chomp $line;
            $need{$line} = 1 if $line ne "";
          }
          close $fh;
        }
      }
      chomp;
      next if $_ eq "";
      if (!$need{$_}) {
        print $_, "\0";
      }
    ' "$candidate_file" >"$normal_file"

  cat "$priority_file" "$normal_file" >"$merged_file"
  /bin/mv "$merged_file" "$candidate_file"
  /bin/rm -f "$needs_file" "$priority_file" "$normal_file"
}

wait_if_paused_or_stop_requested() {
  while [[ -f "$PAUSE_FLAG" ]]; do
    set_status_phase "paused" "Paused. Press 'r' in monitor window to resume."
    /bin/sleep 1
  done

  if [[ -f "$STOP_AFTER_FILE_FLAG" ]]; then
    return 1
  fi
  return 0
}

already_imported() {
  local fingerprint="$1"
  /usr/bin/grep -Fq "${fingerprint}"$'\t' "$MANIFEST_FILE"
}

record_import() {
  local fingerprint="$1"
  local source_file="$2"
  local dest_file="$3"
  /usr/bin/printf '%s\t%s\t%s\t%s\n' "$fingerprint" "$source_file" "$dest_file" "$(/bin/date '+%Y-%m-%d %H:%M:%S')" >>"$MANIFEST_FILE"
}

db_upsert_candidate_file() {
  local uuid="$1"
  local vol_name="$2"
  local root_rel="$3"
  local rel_path="$4"
  local source_file="$5"
  local file_size="$6"
  local file_mtime="$7"
  db_exec "INSERT INTO media_files (source_uuid, volume_name, source_root_rel, rel_path, source_path, source_size, source_mtime, status, last_run_id)
VALUES ($(sql_quote "$uuid"), $(sql_quote "$vol_name"), $(sql_quote "$root_rel"), $(sql_quote "$rel_path"), $(sql_quote "$source_file"), $file_size, $file_mtime, 'candidate', $(sql_quote "$run_id"))
ON CONFLICT(source_uuid, source_root_rel, rel_path, source_size, source_mtime)
DO UPDATE SET source_path=excluded.source_path, volume_name=excluded.volume_name, updated_at=CURRENT_TIMESTAMP, last_run_id=excluded.last_run_id;" >/dev/null || true
}

db_update_file_status() {
  local uuid="$1"
  local root_rel="$2"
  local rel_path="$3"
  local file_size="$4"
  local file_mtime="$5"
  local status="$6"
  local local_path="${7:-}"
  local fingerprint="${8:-}"
  local error="${9:-}"
  db_exec "UPDATE media_files
SET status=$(sql_quote "$status"), local_path=$(sql_quote "$local_path"), fingerprint=$(sql_quote "$fingerprint"), last_error=$(sql_quote "$error"), updated_at=CURRENT_TIMESTAMP, last_run_id=$(sql_quote "$run_id")
WHERE source_uuid=$(sql_quote "$uuid") AND source_root_rel=$(sql_quote "$root_rel") AND rel_path=$(sql_quote "$rel_path") AND source_size=$file_size AND source_mtime=$file_mtime;" >/dev/null || true
}

db_file_has_local_copy() {
  local uuid="$1"
  local root_rel="$2"
  local rel_path="$3"
  local file_size="$4"
  local file_mtime="$5"
  db_available || return 1
  local count
  count="$(/usr/bin/sqlite3 -batch -noheader "$DB_FILE" "SELECT COUNT(*) FROM media_files WHERE source_uuid=$(sql_quote "$uuid") AND source_root_rel=$(sql_quote "$root_rel") AND rel_path=$(sql_quote "$rel_path") AND source_size=$file_size AND source_mtime=$file_mtime AND status IN ('copied','organized','upload_pending','uploaded');" 2>>"$LOG_FILE" || echo 0)"
  [[ "${count:-0}" -gt 0 ]]
}

db_file_retry_needed() {
  local uuid="$1"
  local root_rel="$2"
  local rel_path="$3"
  local file_size="$4"
  local file_mtime="$5"
  db_available || return 1
  local count
  count="$(/usr/bin/sqlite3 -batch -noheader "$DB_FILE" "SELECT COUNT(*) FROM media_files WHERE source_uuid=$(sql_quote "$uuid") AND source_root_rel=$(sql_quote "$root_rel") AND rel_path=$(sql_quote "$rel_path") AND source_size=$file_size AND source_mtime=$file_mtime AND status IN ('copy_failed','verify_failed','needs_reinsert');" 2>>"$LOG_FILE" || echo 0)"
  [[ "${count:-0}" -gt 0 ]]
}

db_upsert_upload_job() {
  local local_path="$1"
  local target_dir="$2"
  local status="${3:-pending}"
  local attempts="${4:-0}"
  local next_retry="${5:-0}"
  local error="${6:-}"
  db_exec "INSERT INTO upload_jobs (local_path, target_dir, status, attempts, next_retry_epoch, last_error, last_run_id)
VALUES ($(sql_quote "$local_path"), $(sql_quote "$target_dir"), $(sql_quote "$status"), $attempts, $next_retry, $(sql_quote "$error"), $(sql_quote "$run_id"))
ON CONFLICT(local_path)
DO UPDATE SET target_dir=excluded.target_dir, status=excluded.status, attempts=excluded.attempts, next_retry_epoch=excluded.next_retry_epoch, last_error=excluded.last_error, updated_at=CURRENT_TIMESTAMP, last_run_id=excluded.last_run_id;" >/dev/null || true
}

db_update_upload_job_status() {
  local local_path="$1"
  local status="$2"
  local attempts="${3:-0}"
  local next_retry="${4:-0}"
  local error="${5:-}"
  db_exec "UPDATE upload_jobs SET status=$(sql_quote "$status"), attempts=$attempts, next_retry_epoch=$next_retry, last_error=$(sql_quote "$error"), updated_at=CURRENT_TIMESTAMP, last_run_id=$(sql_quote "$run_id") WHERE local_path=$(sql_quote "$local_path");" >/dev/null || true
}

db_mark_media_needs_reinsert_by_local_path() {
  local local_path="$1"
  local error="${2:-local staged file missing}"
  db_exec "UPDATE media_files SET status='needs_reinsert', last_error=$(sql_quote "$error"), updated_at=CURRENT_TIMESTAMP, last_run_id=$(sql_quote "$run_id") WHERE local_path=$(sql_quote "$local_path");" >/dev/null || true
}

db_move_media_local_path() {
  local old_path="$1"
  local new_path="$2"
  db_exec "UPDATE media_files
SET local_path=$(sql_quote "$new_path"), status='organized', updated_at=CURRENT_TIMESTAMP, last_run_id=$(sql_quote "$run_id")
WHERE local_path=$(sql_quote "$old_path");" >/dev/null || true
}

db_mark_media_status_by_local_prefix() {
  local base_path="$1"
  local status="$2"
  local err="${3:-}"
  db_exec "UPDATE media_files
SET status=$(sql_quote "$status"), last_error=$(sql_quote "$err"), updated_at=CURRENT_TIMESTAMP, last_run_id=$(sql_quote "$run_id")
WHERE local_path=$(sql_quote "$base_path") OR local_path LIKE $(sql_quote "${base_path}/%");" >/dev/null || true
}

db_incomplete_count_for_volume_run() {
  local uuid="$1"
  db_available || { printf '0'; return 0; }
  /usr/bin/sqlite3 "$DB_FILE" "PRAGMA busy_timeout=5000;
SELECT COUNT(*) FROM media_files
WHERE source_uuid=$(sql_quote "$uuid")
  AND last_run_id=$(sql_quote "$run_id")
  AND status NOT IN ('uploaded','legacy_seen','skipped_duplicate','skipped_extension');" 2>>"$LOG_FILE" || /bin/echo 0
}

db_mark_incomplete_volume_run_needs_reinsert() {
  local uuid="$1"
  local reason="${2:-upload verification incomplete}"
  db_exec "UPDATE media_files
SET status='needs_reinsert', last_error=$(sql_quote "$reason"), updated_at=CURRENT_TIMESTAMP, last_run_id=$(sql_quote "$run_id")
WHERE source_uuid=$(sql_quote "$uuid")
  AND last_run_id=$(sql_quote "$run_id")
  AND status IN ('candidate','copy_failed','verify_failed','copied','organized','upload_pending');" >/dev/null || true
}

verify_volume_upload_completeness() {
  local uuid="$1"
  local vol_name="$2"

  [[ -n "$uuid" ]] || return 0

  if [[ "$ENABLE_POST_EJECT_MOVE" != "1" ]]; then
    return 0
  fi

  local incomplete_count
  incomplete_count="$(db_incomplete_count_for_volume_run "$uuid" 2>/dev/null || /bin/echo 0)"
  incomplete_count="${incomplete_count:-0}"
  if ! [[ "$incomplete_count" =~ ^[0-9]+$ ]]; then
    incomplete_count=0
  fi

  if [[ "$incomplete_count" -gt 0 ]]; then
    db_mark_incomplete_volume_run_needs_reinsert "$uuid" "not confirmed on upload destination; reinsert card for recovery"
    summary_errors_total=$((summary_errors_total + 1))
    summary_upload_incomplete_total=$((summary_upload_incomplete_total + incomplete_count))
    log "Upload completeness check failed for ${vol_name}: ${incomplete_count} file(s) not confirmed on destination."
    local urgency_label
    if [[ "$incomplete_count" -ge 50 ]]; then
      urgency_label="HIGH"
    elif [[ "$incomplete_count" -ge 10 ]]; then
      urgency_label="MEDIUM"
    else
      urgency_label="LOW"
    fi
    notify "DDump" "⚠️ ${vol_name}: ${incomplete_count} file(s) not confirmed on server. Urgency ${urgency_label}. Reinsert card to recover missing files." warn
    return 1
  fi

  log "Upload completeness check passed for ${vol_name}: all SQLite-tracked files confirmed."
  return 0
}

# ----- Folder-naming strategy helpers ----------------------------------------
# After files are imported under their camera folder names, we re-organize
# them into "bucket" folders that reflect the user's chosen strategy
# (sequential, custom, cluster, calendar). The strategy decides the bucket
# *name*; the rebucket step does the actual file moves.

iso_to_epoch() {
  local iso="$1"
  /bin/date -j -f '%Y-%m-%dT%H:%M:%S' "$iso" '+%s' 2>/dev/null \
    || /bin/date -d "$iso" '+%s' 2>/dev/null \
    || true
}

resolve_sequential_bucket_for_cluster() {
  local dest_dir="$1"
  local prefix="$2"
  local start_epoch="$3"
  local end_epoch="$4"
  local attach_min attach_sec day map_file tmp_file found bucket min_start max_end
  attach_min="$(sanitize_positive_int "${CLUSTER_ATTACH_MINUTES:-120}" "120")"
  attach_sec=$((attach_min * 60))
  day="$(epoch_date_ymd "$start_epoch")"
  map_file="$SHOOT_CLUSTER_MAP_FILE"
  [[ -n "$day" ]] || { printf '%s%s' "$prefix" "$(next_sequential_number "$dest_dir" "$prefix")"; return 0; }

  tmp_file="$(mktemp "${STATE_DIR}/cluster-map.${run_id}.XXXXXX")"
  found=0
  bucket=""
  : >"$tmp_file"

  while IFS=$'\t' read -r row_day row_bucket row_start row_end || [[ -n "$row_day$row_bucket$row_start$row_end" ]]; do
    [[ -n "$row_day" && -n "$row_bucket" && "$row_start" =~ ^[0-9]+$ && "$row_end" =~ ^[0-9]+$ ]] || continue
    if [[ "$row_day" == "$day" ]] && (( start_epoch <= row_end + attach_sec )) && (( end_epoch >= row_start - attach_sec )); then
      found=1
      bucket="$row_bucket"
      if (( start_epoch < row_start )); then min_start="$start_epoch"; else min_start="$row_start"; fi
      if (( end_epoch > row_end )); then max_end="$end_epoch"; else max_end="$row_end"; fi
      /usr/bin/printf '%s\t%s\t%s\t%s\n' "$row_day" "$row_bucket" "$min_start" "$max_end" >>"$tmp_file"
    else
      /usr/bin/printf '%s\t%s\t%s\t%s\n' "$row_day" "$row_bucket" "$row_start" "$row_end" >>"$tmp_file"
    fi
  done <"$map_file"

  if [[ "$found" -eq 0 ]]; then
    bucket="${prefix}$(next_sequential_number "$dest_dir" "$prefix")"
    /usr/bin/printf '%s\t%s\t%s\t%s\n' "$day" "$bucket" "$start_epoch" "$end_epoch" >>"$tmp_file"
  fi

  /bin/mv "$tmp_file" "$map_file"
  printf '%s' "$bucket"
}

next_sequential_number() {
  local dest_dir="$1"
  local prefix="$2"
  local max=0
  if [[ -d "$dest_dir" ]]; then
    local entry base n
    for entry in "$dest_dir"/${prefix}*; do
      [[ -d "$entry" ]] || continue
      base="$(basename "$entry")"
      n="${base#${prefix}}"
      if [[ "$n" =~ ^[0-9]+$ && "$n" -gt "$max" ]]; then
        max="$n"
      fi
    done
  fi
  printf '%s' "$(( max + 1 ))"
}

compute_buckets_sequential() {
  # stdin: list of imported file paths (newline-separated)
  # stdout: file_path<TAB>bucket_name
  local dest_dir="$1"
  local prefix="${FOLDER_NAME_SEQUENTIAL_PREFIX:-Shoot-}"

  if [[ "${CLUSTER_GROUPING_ENABLED:-1}" != "1" ]]; then
    local n bucket f
    n="$(next_sequential_number "$dest_dir" "$prefix")"
    bucket="${prefix}${n}"
    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      printf '%s\t%s\n' "$f" "$bucket"
    done
    return 0
  fi

  local cluster_script imported_list cluster_out file_path cid cstart_iso cend_iso
  local cstart_epoch cend_epoch bucket
  cluster_script="${APP_SUPPORT_DIR}/bin/ddump-cluster.sh"
  imported_list="$(mktemp)"
  cluster_out="$(mktemp)"
  cat >"$imported_list"

  if [[ ! -x "$cluster_script" ]]; then
    local n fallback_bucket f
    n="$(next_sequential_number "$dest_dir" "$prefix")"
    fallback_bucket="${prefix}${n}"
    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      printf '%s\t%s\n' "$f" "$fallback_bucket"
    done <"$imported_list"
    rm -f "$imported_list" "$cluster_out"
    return 0
  fi

  /bin/bash "$cluster_script" --gap-minutes "${CLUSTER_GAP_MINUTES:-45}" <"$imported_list" >"$cluster_out"
  while IFS=$'\t' read -r file_path cid cstart_iso cend_iso; do
    [[ -n "$file_path" ]] || continue
    if [[ "$cid" == "unknown" || -z "$cstart_iso" || -z "$cend_iso" ]]; then
      bucket="${FOLDER_NAME_UNCATEGORIZED:-Uncategorized}"
      printf '%s\t%s\n' "$file_path" "$bucket"
      continue
    fi
    cstart_epoch="$(iso_to_epoch "$cstart_iso")"
    cend_epoch="$(iso_to_epoch "$cend_iso")"
    if [[ ! "$cstart_epoch" =~ ^[0-9]+$ || ! "$cend_epoch" =~ ^[0-9]+$ ]]; then
      bucket="${prefix}$(next_sequential_number "$dest_dir" "$prefix")"
      printf '%s\t%s\n' "$file_path" "$bucket"
      continue
    fi
    bucket="$(resolve_sequential_bucket_for_cluster "$dest_dir" "$prefix" "$cstart_epoch" "$cend_epoch")"
    printf '%s\t%s\n' "$file_path" "$bucket"
  done <"$cluster_out"

  rm -f "$imported_list" "$cluster_out"
}

compute_buckets_custom() {
  local dest_dir="$1"
  local raw_list="${FOLDER_NAME_CUSTOM_VALUES:-}"
  [[ -n "$raw_list" ]] || return 1
  local item bucket=""
  IFS=',' read -r -a _custom_list <<<"$raw_list"
  for item in "${_custom_list[@]}"; do
    item="$(trim "$item")"
    [[ -n "$item" ]] || continue
    if [[ ! -d "${dest_dir}/${item}" ]]; then
      bucket="$item"
      break
    fi
  done
  [[ -n "$bucket" ]] || return 1
  local f
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    printf '%s\t%s\n' "$f" "$bucket"
  done
}

compute_buckets_cluster() {
  local dest_dir="$1"
  local gap_min="${CLUSTER_GAP_MINUTES:-45}"
  local tmpl="$CLUSTER_FOLDER_TEMPLATE"
  if [[ -z "$tmpl" ]]; then
    tmpl="Cluster {n} {start}-{end}"
  fi
  local cluster_script="${APP_SUPPORT_DIR}/bin/ddump-cluster.sh"

  local imported_list
  imported_list="$(mktemp)"
  cat >"$imported_list"

  if [[ ! -x "$cluster_script" ]]; then
    local hh
    hh="$(/bin/date '+%H:%M')"
    local f
    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      printf '%s\tDump %s\n' "$f" "$hh"
    done <"$imported_list"
    rm -f "$imported_list"
    return 0
  fi

  local cluster_out
  cluster_out="$(mktemp)"
  /bin/bash "$cluster_script" --gap-minutes "$gap_min" <"$imported_list" >"$cluster_out"

  local file_path cid cstart_iso cend_iso bucket start_hm end_hm
  while IFS=$'\t' read -r file_path cid cstart_iso cend_iso; do
    [[ -z "$file_path" ]] && continue
    if [[ "$cid" == "unknown" || -z "$cstart_iso" ]]; then
      bucket="${FOLDER_NAME_UNCATEGORIZED:-Uncategorized}"
    else
      start_hm="${cstart_iso:11:5}"
      end_hm="${cend_iso:11:5}"
      bucket="$(replace_naming_token "$tmpl" "n" "$cid")"
      bucket="$(replace_naming_token "$bucket" "start" "$start_hm")"
      bucket="$(replace_naming_token "$bucket" "end" "$end_hm")"
    fi
    printf '%s\t%s\n' "$file_path" "$bucket"
  done <"$cluster_out"

  rm -f "$imported_list" "$cluster_out"
}

existing_smart_bucket_for_index() {
  local index="$1"
  [[ "${SMART_ASSIGN_EXISTING_FOLDERS:-0}" == "1" ]] || return 1

  local target_dir
  if ! target_dir="$(build_post_move_target_dir)"; then
    return 1
  fi
  [[ -d "$target_dir" ]] || return 1

  /usr/bin/find "$target_dir" -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null \
    | /usr/bin/sort \
    | /usr/bin/awk -v n="$index" 'NR == n { sub(/^.*\//, "", $0); print; exit }'
}

compute_buckets_smart() {
  # Smart mode keeps the cluster grouping, but if today's final Drive date
  # folder already has named shoot folders, cluster 1 maps to the first folder,
  # cluster 2 to the second, etc. This lets DDump land in existing shoot folders
  # without hard-coding daily dates.
  local dest_dir="$1"
  local gap_min="${CLUSTER_GAP_MINUTES:-45}"
  local tmpl="$CLUSTER_FOLDER_TEMPLATE"
  [[ -n "$tmpl" ]] || tmpl="Cluster {n} {start}-{end}"

  local cluster_script="${APP_SUPPORT_DIR}/bin/ddump-cluster.sh"
  local imported_list cluster_out
  imported_list="$(mktemp)"
  cat >"$imported_list"

  if [[ ! -x "$cluster_script" ]]; then
    compute_buckets_cluster "$dest_dir" <"$imported_list"
    rm -f "$imported_list"
    return 0
  fi

  cluster_out="$(mktemp)"
  /bin/bash "$cluster_script" --gap-minutes "$gap_min" <"$imported_list" >"$cluster_out"

  local cid_file
  cid_file="$(mktemp)"
  /usr/bin/awk -F '\t' '$2 != "" && $2 != "unknown" { print $2 }' "$cluster_out" | /usr/bin/sort -n -u >"$cid_file"

  local file_path cid cstart_iso cend_iso bucket start_hm end_hm smart_bucket cluster_index
  while IFS=$'\t' read -r file_path cid cstart_iso cend_iso; do
    [[ -z "$file_path" ]] && continue
    if [[ "$cid" == "unknown" || -z "$cstart_iso" ]]; then
      bucket="${FOLDER_NAME_UNCATEGORIZED:-Uncategorized}"
    else
      cluster_index="$(/usr/bin/awk -v id="$cid" '$0 == id { print NR; exit }' "$cid_file")"
      smart_bucket=""
      if [[ -n "$cluster_index" ]]; then
        smart_bucket="$(existing_smart_bucket_for_index "$cluster_index" || true)"
      fi
      if [[ -n "$smart_bucket" ]]; then
        bucket="$smart_bucket"
      else
        start_hm="${cstart_iso:11:5}"
        end_hm="${cend_iso:11:5}"
        bucket="$(replace_naming_token "$tmpl" "n" "$cid")"
        bucket="$(replace_naming_token "$bucket" "start" "$start_hm")"
        bucket="$(replace_naming_token "$bucket" "end" "$end_hm")"
      fi
    fi
    printf '%s\t%s\n' "$file_path" "$bucket"
  done <"$cluster_out"

  rm -f "$imported_list" "$cluster_out" "$cid_file"
}

detected_cluster_count_for_imported_list() {
  local imported_list="$1"
  local cluster_script="${APP_SUPPORT_DIR}/bin/ddump-cluster.sh"
  [[ -s "$imported_list" ]] || { printf '0'; return 0; }
  [[ -x "$cluster_script" ]] || { printf '1'; return 0; }

  local cluster_out count
  cluster_out="$(mktemp "${STATE_DIR}/cluster-count.${run_id}.XXXXXX")"
  /bin/bash "$cluster_script" --gap-minutes "${CLUSTER_GAP_MINUTES:-30}" <"$imported_list" >"$cluster_out" || {
    rm -f "$cluster_out"
    printf '1'
    return 0
  }
  count="$(/usr/bin/awk -F '\t' '$2 != "" && $2 != "unknown" { seen[$2]=1 } END { for (id in seen) n++; print n+0 }' "$cluster_out")"
  rm -f "$cluster_out"
  [[ "$count" =~ ^[0-9]+$ && "$count" -gt 0 ]] || count="1"
  printf '%s' "$count"
}

file_capture_epoch() {
  local src_file="$1"
  local epoch=""

  if command -v exiftool >/dev/null 2>&1; then
    epoch="$(exiftool -s3 -d '%s' -DateTimeOriginal -CreateDate "$src_file" 2>/dev/null \
      | /usr/bin/grep -m1 -E '^[0-9]+$' || true)"
  fi

  if [[ -z "$epoch" ]]; then
    epoch="$(/usr/bin/stat -f '%m' "$src_file" 2>/dev/null || /usr/bin/stat -c '%Y' "$src_file" 2>/dev/null || true)"
  fi

  [[ "$epoch" =~ ^[0-9]+$ ]] && printf '%s' "$epoch"
}

metadata_field() {
  local src_file="$1"
  local tag="$2"
  local value=""
  if command -v exiftool >/dev/null 2>&1; then
    value="$(exiftool -s3 "-${tag}" "$src_file" 2>/dev/null | /usr/bin/head -n 1 || true)"
  fi
  value="$(trim "$value")"
  printf '%s' "$value"
}

squash_name_spaces() {
  /usr/bin/sed -E 's/[[:space:]]+/ /g; s/^ +//; s/ +$//'
}

simplify_camera_make() {
  local make="$1"
  make="$(printf '%s' "$make" | squash_name_spaces)"
  local lower
  lower="$(printf '%s' "$make" | /usr/bin/tr '[:upper:]' '[:lower:]')"
  case "$lower" in
    *canon*) printf 'Canon' ;;
    *sony*) printf 'Sony' ;;
    *nikon*) printf 'Nikon' ;;
    *fujifilm*|*fuji*) printf 'Fuji' ;;
    *panasonic*|*lumix*) printf 'Panasonic' ;;
    *olympus*|*om\ digital*|*om-system*|*om\ system*) printf 'OM System' ;;
    *dji*) printf 'DJI' ;;
    *gopro*) printf 'GoPro' ;;
    *leica*) printf 'Leica' ;;
    *hasselblad*) printf 'Hasselblad' ;;
    "") printf '' ;;
    *) printf '%s' "$make" ;;
  esac
}

simplify_camera_model() {
  local make="$1"
  local model="$2"
  local brand="$3"
  local short
  short="$(printf '%s' "$model" | squash_name_spaces)"
  short="${short#"$make"}"
  short="${short#"$brand"}"
  short="$(printf '%s' "$short" | squash_name_spaces)"

  short="${short#Canon EOS }"
  short="${short#EOS }"
  short="${short#ILCE-}"
  short="${short#NIKON }"
  short="${short#Nikon }"
  short="${short#FUJIFILM }"
  short="${short#LUMIX }"
  short="${short#Panasonic }"
  short="${short#DJI }"

  case "$short" in
    "") short="$model" ;;
    ILCE-7SM3|7SM3) short="a7S III" ;;
    ILCE-7M4|7M4) short="a7 IV" ;;
    ILCE-7RM5|7RM5) short="a7R V" ;;
    ILCE-1|1) short="a1" ;;
    FC7303|FC3582|FC3411|FC3170) short="Mavic" ;;
  esac

  printf '%s' "$short" | squash_name_spaces
}

smart_camera_label_for_file() {
  local src_file="$1"
  local mode="${SMART_CAMERA_LABEL_MODE:-smart}"
  local make model brand model_short label
  make="$(metadata_field "$src_file" "Make")"
  model="$(metadata_field "$src_file" "Model")"
  brand="$(simplify_camera_make "$make")"
  model_short="$(simplify_camera_model "$make" "$model" "$brand")"

  case "$mode" in
    brand) label="$brand" ;;
    full) label="$(printf '%s %s' "$brand" "$model_short" | squash_name_spaces)" ;;
    model) label="$model_short" ;;
    smart|*)
      if [[ -n "$brand" ]]; then
        label="$brand"
      elif [[ -n "$model_short" ]]; then
        label="$model_short"
      else
        label="Camera"
      fi
      ;;
  esac

  if [[ -z "$label" || "$label" == " " ]]; then
    label="Camera"
  fi
  printf '%s' "$label"
}

epoch_date_ymd() {
  local epoch="$1"
  /bin/date -r "$epoch" '+%Y-%m-%d' 2>/dev/null \
    || /bin/date -d "@$epoch" '+%Y-%m-%d' 2>/dev/null \
    || true
}

epoch_strftime() {
  local epoch="$1"
  local fmt="$2"
  /bin/date -r "$epoch" "$fmt" 2>/dev/null \
    || /bin/date -d "@$epoch" "$fmt" 2>/dev/null \
    || true
}

template_sequence_value() {
  local seq="$1"
  local width="$2"
  /usr/bin/printf "%0${width}d" "$seq" 2>/dev/null || printf '%s' "$seq"
}

replace_naming_token() {
  local text="$1"
  local token="$2"
  local value="$3"
  local pattern="\\{${token}\\}"
  printf '%s' "${text//$pattern/$value}"
}

render_naming_template() {
  local template="$1"
  local src_file="$2"
  local shoot_name="${3:-}"
  local cluster_name="${4:-}"
  local seq="${5:-1}"
  local total="${6:-1}"
  local smart_camera_override="${7:-}"
  if [[ -z "$shoot_name" || "$shoot_name" == "${FOLDER_NAME_UNCATEGORIZED:-Uncategorized}" || "$shoot_name" == Cluster* ]]; then
    local default_shoot
    default_shoot="$(trim "${DEFAULT_SHOOT_NAME:-}")"
    [[ -n "$default_shoot" ]] && shoot_name="$default_shoot"
  fi

  local base filename ext parent folder epoch year month day date_ymd date_short date_slash time_hms hour minute second
  base="$(basename "$src_file")"
  ext="${base##*.}"
  if [[ "$base" == "$ext" ]]; then ext=""; fi
  filename="${base%.*}"
  if [[ -z "$filename" ]]; then filename="$base"; fi
  parent="$(dirname "$src_file")"
  folder="$(basename "$parent")"
  epoch="$(file_capture_epoch "$src_file")"
  if [[ "$epoch" =~ ^[0-9]+$ ]]; then
    year="$(epoch_strftime "$epoch" '+%Y')"
    month="$(epoch_strftime "$epoch" '+%m')"
    day="$(epoch_strftime "$epoch" '+%d')"
    date_ymd="$(epoch_strftime "$epoch" '+%Y%m%d')"
    date_short="$(epoch_strftime "$epoch" '+%y%m%d')"
    date_slash="$(epoch_strftime "$epoch" '+%m-%d-%y')"
    time_hms="$(epoch_strftime "$epoch" '+%H%M%S')"
    hour="$(epoch_strftime "$epoch" '+%H')"
    minute="$(epoch_strftime "$epoch" '+%M')"
    second="$(epoch_strftime "$epoch" '+%S')"
  else
    year="$(/bin/date '+%Y')"
    month="$(/bin/date '+%m')"
    day="$(/bin/date '+%d')"
    date_ymd="$(/bin/date '+%Y%m%d')"
    date_short="$(/bin/date '+%y%m%d')"
    date_slash="$(/bin/date '+%m-%d-%y')"
    time_hms="$(/bin/date '+%H%M%S')"
    hour="$(/bin/date '+%H')"
    minute="$(/bin/date '+%M')"
    second="$(/bin/date '+%S')"
  fi

  local make model brand model_short smart_camera lens serial artist software iso focal exposure gps dimensions camera_type title out
  make="$(metadata_field "$src_file" "Make")"
  model="$(metadata_field "$src_file" "Model")"
  brand="$(simplify_camera_make "$make")"
  model_short="$(simplify_camera_model "$make" "$model" "$brand")"
  smart_camera="$(smart_camera_label_for_file "$src_file")"
  [[ -n "$smart_camera_override" ]] && smart_camera="$smart_camera_override"
  lens="$(metadata_field "$src_file" "LensModel")"
  [[ -n "$lens" ]] || lens="$(metadata_field "$src_file" "Lens")"
  serial="$(metadata_field "$src_file" "SerialNumber")"
  artist="$(metadata_field "$src_file" "Artist")"
  software="$(metadata_field "$src_file" "Software")"
  iso="$(metadata_field "$src_file" "ISO")"
  focal="$(metadata_field "$src_file" "FocalLength")"
  exposure="$(metadata_field "$src_file" "ExposureTime")"
  gps="$(metadata_field "$src_file" "GPSPosition")"
  dimensions="$(metadata_field "$src_file" "ImageSize")"
  title="$(metadata_field "$src_file" "Title")"
  camera_type="$smart_camera"

  out="$template"
  out="$(replace_naming_token "$out" "smart_camera" "$smart_camera")"
  out="$(replace_naming_token "$out" "camera_type" "$camera_type")"
  out="$(replace_naming_token "$out" "camera_brand" "$brand")"
  out="$(replace_naming_token "$out" "camera_make" "$make")"
  out="$(replace_naming_token "$out" "camera_model" "$model")"
  out="$(replace_naming_token "$out" "camera_model_short" "$model_short")"
  out="$(replace_naming_token "$out" "calendar_event" "$shoot_name")"
  out="$(replace_naming_token "$out" "shoot" "$shoot_name")"
  out="$(replace_naming_token "$out" "cluster" "$cluster_name")"
  out="$(replace_naming_token "$out" "date_ymd" "$date_ymd")"
  out="$(replace_naming_token "$out" "date_yymmdd" "$date_short")"
  out="$(replace_naming_token "$out" "date" "$date_slash")"
  out="$(replace_naming_token "$out" "year" "$year")"
  out="$(replace_naming_token "$out" "month" "$month")"
  out="$(replace_naming_token "$out" "day" "$day")"
  out="$(replace_naming_token "$out" "time" "$time_hms")"
  out="$(replace_naming_token "$out" "hour" "$hour")"
  out="$(replace_naming_token "$out" "minute" "$minute")"
  out="$(replace_naming_token "$out" "second" "$second")"
  out="$(replace_naming_token "$out" "folder" "$folder")"
  out="$(replace_naming_token "$out" "parent_folder" "$folder")"
  out="$(replace_naming_token "$out" "filename" "$filename")"
  out="$(replace_naming_token "$out" "original_filename" "$filename")"
  out="$(replace_naming_token "$out" "basename" "$filename")"
  out="$(replace_naming_token "$out" "ext" "$ext")"
  out="$(replace_naming_token "$out" "extension" "$ext")"
  out="$(replace_naming_token "$out" "sequence_2" "$(template_sequence_value "$seq" 2)")"
  out="$(replace_naming_token "$out" "sequence_3" "$(template_sequence_value "$seq" 3)")"
  out="$(replace_naming_token "$out" "sequence_4" "$(template_sequence_value "$seq" 4)")"
  out="$(replace_naming_token "$out" "sequence_5" "$(template_sequence_value "$seq" 5)")"
  out="$(replace_naming_token "$out" "sequence" "$seq")"
  out="$(replace_naming_token "$out" "image_number" "$seq")"
  out="$(replace_naming_token "$out" "total" "$total")"
  out="$(replace_naming_token "$out" "lens" "$lens")"
  out="$(replace_naming_token "$out" "serial" "$serial")"
  out="$(replace_naming_token "$out" "artist" "$artist")"
  out="$(replace_naming_token "$out" "software" "$software")"
  out="$(replace_naming_token "$out" "iso" "$iso")"
  out="$(replace_naming_token "$out" "focal_length" "$focal")"
  out="$(replace_naming_token "$out" "exposure" "$exposure")"
  out="$(replace_naming_token "$out" "gps" "$gps")"
  out="$(replace_naming_token "$out" "dimensions" "$dimensions")"
  out="$(replace_naming_token "$out" "title" "$title")"
  out="$(printf '%s' "$out" | /usr/bin/sed -E 's/[[:space:]]*-[[:space:]]*/ - /g; s/( - )+$/ /; s/^( - )+//; s/[[:space:]]+/ /g; s/^ +//; s/ +$//')"
  [[ -n "$out" ]] || out="${FOLDER_NAME_UNCATEGORIZED:-Uncategorized}"
  printf '%s' "$out"
}

compute_buckets_camera() {
  local dest_dir="$1"
  local f parent bucket
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    parent="$(dirname "$f")"
    bucket="$(basename "$parent")"
    if [[ -z "$bucket" || "$parent" == "$dest_dir" ]]; then
      bucket="${FOLDER_NAME_UNCATEGORIZED:-Uncategorized}"
    fi
    printf '%s\t%s\n' "$f" "$bucket"
  done
}

build_smart_camera_label_map() {
  local bucket_tsv="$1"
  local label_tsv="$2"
  local camera_tsv file_path base_bucket make model brand model_short full serial
  camera_tsv="$(mktemp "${STATE_DIR}/template-camera.${run_id}.XXXXXX")"

  while IFS=$'\t' read -r file_path base_bucket || [[ -n "$file_path$base_bucket" ]]; do
    [[ -n "$file_path" ]] || continue
    make="$(metadata_field "$file_path" "Make")"
    model="$(metadata_field "$file_path" "Model")"
    brand="$(simplify_camera_make "$make")"
    model_short="$(simplify_camera_model "$make" "$model" "$brand")"
    full="$(printf '%s %s' "$brand" "$model_short" | squash_name_spaces)"
    [[ -n "$full" ]] || full="${brand:-Camera}"
    serial="$(metadata_field "$file_path" "SerialNumber")"
    printf '%s\t%s\t%s\t%s\t%s\n' "$file_path" "$base_bucket" "${brand:-Camera}" "$full" "$serial" >>"$camera_tsv"
  done <"$bucket_tsv"

  /usr/bin/awk -F '\t' '
    {
      file[NR]=$1; bucket[NR]=$2; brand[NR]=$3; full[NR]=$4; serial[NR]=$5
      b=$2; br=$3; fu=$4; se=$5
      if (!(b SUBSEP br in seen_brand)) { seen_brand[b SUBSEP br]=1; brand_count[b]++ }
      if (!(b SUBSEP br SUBSEP fu in seen_model)) { seen_model[b SUBSEP br SUBSEP fu]=1; model_count[b SUBSEP br]++ }
      if (se != "" && !(b SUBSEP fu SUBSEP se in seen_serial)) {
        seen_serial[b SUBSEP fu SUBSEP se]=1
        serial_count[b SUBSEP fu]++
        serial_index[b SUBSEP fu SUBSEP se]=serial_count[b SUBSEP fu]
      }
    }
    END {
      for (i=1; i<=NR; i++) {
        label=brand[i]
        if (brand_count[bucket[i]] > 1) {
          label=brand[i]
        } else if (model_count[bucket[i] SUBSEP brand[i]] > 1) {
          label=full[i]
        } else if (serial[i] != "" && serial_count[bucket[i] SUBSEP full[i]] > 1) {
          label=full[i] " " serial_index[bucket[i] SUBSEP full[i] SUBSEP serial[i]]
        }
        if (label == "") { label="Camera" }
        print file[i] "\t" label
      }
    }
  ' "$camera_tsv" >"$label_tsv"

  rm -f "$camera_tsv"
}

smart_camera_label_from_map() {
  local label_tsv="$1"
  local file_path="$2"
  [[ -f "$label_tsv" ]] || return 0
  /usr/bin/awk -F '\t' -v f="$file_path" '$1 == f { print $2; exit }' "$label_tsv"
}

compute_buckets_template() {
  local dest_dir="$1"
  local template="${FOLDER_NAME_TEMPLATE:-}"
  [[ -n "$template" ]] || template="{smart_camera} - {shoot} - {date_ymd}"
  local imported_list base_tsv label_tsv file_path base_bucket bucket smart_label
  imported_list="$(mktemp "${STATE_DIR}/template-imported.${run_id}.XXXXXX")"
  base_tsv="$(mktemp "${STATE_DIR}/template-base.${run_id}.XXXXXX")"
  label_tsv="$(mktemp "${STATE_DIR}/template-label.${run_id}.XXXXXX")"
  cat >"$imported_list"

  if [[ "${CALENDAR_PROVIDER:-none}" != "none" ]] && compute_buckets_calendar "$dest_dir" <"$imported_list" >"$base_tsv"; then
    :
  else
    local fallback="${FOLDER_NAMING_FALLBACK:-cluster}"
    [[ "$fallback" == "template" ]] && fallback="cluster"
    compute_buckets_with_fallback "$fallback" "$dest_dir" <"$imported_list" >"$base_tsv"
  fi

  build_smart_camera_label_map "$base_tsv" "$label_tsv"

  while IFS=$'\t' read -r file_path base_bucket || [[ -n "$file_path$base_bucket" ]]; do
    [[ -n "$file_path" ]] || continue
    smart_label="$(smart_camera_label_from_map "$label_tsv" "$file_path")"
    bucket="$(render_naming_template "$template" "$file_path" "$base_bucket" "$base_bucket" "1" "1" "$smart_label")"
    printf '%s\t%s\n' "$file_path" "$bucket"
  done <"$base_tsv"

  rm -f "$imported_list" "$base_tsv" "$label_tsv"
}

compute_buckets_with_fallback() {
  local fallback="$1"
  local dest_dir="$2"
  case "$fallback" in
    sequential) compute_buckets_sequential "$dest_dir" ;;
    custom) compute_buckets_custom "$dest_dir" || compute_buckets_sequential "$dest_dir" ;;
    camera) compute_buckets_camera "$dest_dir" ;;
    cluster) compute_buckets_cluster "$dest_dir" ;;
    template) compute_buckets_template "$dest_dir" ;;
    *) compute_buckets_sequential "$dest_dir" ;;
  esac
}

compute_buckets_calendar() {
  local dest_dir="$1"
  local padding_min
  padding_min="$(sanitize_positive_int "${CALENDAR_EVENT_PADDING_MIN:-15}" "15")"

  local calendar_script="${APP_SUPPORT_DIR}/bin/ddump-calendar-lookup.sh"
  [[ -x "$calendar_script" ]] || return 1

  local cluster_script="${APP_SUPPORT_DIR}/bin/ddump-cluster.sh"
  [[ -x "$cluster_script" ]] || return 1

  local imported_list cluster_out cluster_times dates_file events_file matched_tsv unmatched_list fallback_tsv
  imported_list="$(mktemp "${STATE_DIR}/calendar-imported.${run_id}.XXXXXX")"
  cluster_out="$(mktemp "${STATE_DIR}/calendar-clusters.${run_id}.XXXXXX")"
  cluster_times="$(mktemp "${STATE_DIR}/calendar-cluster-times.${run_id}.XXXXXX")"
  dates_file="$(mktemp "${STATE_DIR}/calendar-dates.${run_id}.XXXXXX")"
  events_file="$(mktemp "${STATE_DIR}/calendar-events.${run_id}.XXXXXX")"
  matched_tsv="$(mktemp "${STATE_DIR}/calendar-matched.${run_id}.XXXXXX")"
  unmatched_list="$(mktemp "${STATE_DIR}/calendar-unmatched.${run_id}.XXXXXX")"
  fallback_tsv="$(mktemp "${STATE_DIR}/calendar-fallback.${run_id}.XXXXXX")"
  cat >"$imported_list"

  /bin/bash "$cluster_script" --gap-minutes "${CLUSTER_GAP_MINUTES:-30}" <"$imported_list" >"$cluster_out"

  local f cid cstart_iso cend_iso cstart_epoch cend_epoch ymd end_ymd
  while IFS=$'\t' read -r f cid cstart_iso cend_iso || [[ -n "$f$cid$cstart_iso$cend_iso" ]]; do
    [[ -f "$f" ]] || continue
    if [[ "$cid" == "unknown" || -z "$cstart_iso" || -z "$cend_iso" ]]; then
      /bin/echo "$f" >>"$unmatched_list"
      continue
    fi
    cstart_epoch="$(iso_to_epoch "$cstart_iso")"
    cend_epoch="$(iso_to_epoch "$cend_iso")"
    if [[ ! "$cstart_epoch" =~ ^[0-9]+$ || ! "$cend_epoch" =~ ^[0-9]+$ ]]; then
      /bin/echo "$f" >>"$unmatched_list"
      continue
    fi
    ymd="$(epoch_date_ymd "$cstart_epoch")"
    if [[ -z "$ymd" ]]; then
      /bin/echo "$f" >>"$unmatched_list"
      continue
    fi
    /usr/bin/printf '%s\t%s\t%s\t%s\n' "$f" "$cid" "$cstart_epoch" "$cend_epoch" >>"$cluster_times"
    /bin/echo "$ymd" >>"$dates_file"
    end_ymd="$(epoch_date_ymd "$cend_epoch")"
    if [[ -n "$end_ymd" && "$end_ymd" != "$ymd" ]]; then
      /bin/echo "$end_ymd" >>"$dates_file"
    fi
  done <"$cluster_out"

  if [[ ! -s "$cluster_times" ]]; then
    rm -f "$imported_list" "$cluster_out" "$cluster_times" "$dates_file" "$events_file" "$matched_tsv" "$unmatched_list" "$fallback_tsv"
    return 1
  fi

  /usr/bin/sort -u "$dates_file" | while IFS= read -r ymd; do
    [[ -n "$ymd" ]] || continue
    DDUMP_CALENDAR_NAME="${CALENDAR_NAME:-}" /bin/bash "$calendar_script" --date "$ymd" 2>/dev/null || true
  done >"$events_file"

  if [[ -s "$events_file" ]]; then
    /usr/bin/awk -F'\t' -v OFS='\t' -v pad="$((padding_min * 60))" \
      -v unmatched="$unmatched_list" '
        NR == FNR {
          n++
          start[n] = $1 - pad
          end[n] = $2 + pad
          title[n] = $3
          next
        }
        {
          path = $1
          cluster_start = $3
          cluster_end = $4
          best = ""
          best_overlap = 0
          if (cluster_end < cluster_start) {
            tmp = cluster_start
            cluster_start = cluster_end
            cluster_end = tmp
          }
          for (i = 1; i <= n; i++) {
            overlap_start = cluster_start > start[i] ? cluster_start : start[i]
            overlap_end = cluster_end < end[i] ? cluster_end : end[i]
            overlap = overlap_end - overlap_start
            if (overlap >= 0) {
              overlap += 1
              if (overlap > best_overlap) {
                best = title[i]
                best_overlap = overlap
              }
            }
          }
          if (best != "") {
            print path, best
          } else {
            print path >> unmatched
          }
        }
      ' "$events_file" "$cluster_times" >"$matched_tsv"
  fi

  if [[ -s "$unmatched_list" ]]; then
    compute_buckets_with_fallback "${FOLDER_NAMING_FALLBACK:-cluster}" "$dest_dir" <"$unmatched_list" >"$fallback_tsv"
  fi

  if [[ ! -s "$matched_tsv" && ! -s "$fallback_tsv" ]]; then
    compute_buckets_cluster "$dest_dir" <"$imported_list"
  else
    cat "$matched_tsv" "$fallback_tsv"
  fi

  rm -f "$imported_list" "$cluster_out" "$cluster_times" "$dates_file" "$events_file" "$matched_tsv" "$unmatched_list" "$fallback_tsv"
}

sanitize_bucket_name() {
  local raw="$1"
  local cleaned
  cleaned="$(printf '%s' "$raw" \
    | /usr/bin/tr '/:' '__' \
    | /usr/bin/tr '\t\r\n' '   ' \
    | /usr/bin/sed -E 's/[[:cntrl:]]/_/g; s/^ +//; s/ +$//; s/  +/ /g')"

  case "$cleaned" in
    ""|"."|"..") cleaned="${FOLDER_NAME_UNCATEGORIZED:-Uncategorized}" ;;
  esac

  printf '%.180s' "$cleaned"
}

render_file_name_for_rebucket() {
  local src_path="$1"
  local bucket_name="$2"
  local seq="$3"
  local total="$4"
  local smart_camera_override="${5:-}"
  local template="${FILE_NAME_TEMPLATE:-}"
  [[ -n "$template" ]] || template="{filename}"
  local base ext rendered stem
  base="$(basename "$src_path")"
  ext="${base##*.}"
  if [[ "$base" == "$ext" ]]; then ext=""; fi
  rendered="$(render_naming_template "$template" "$src_path" "$bucket_name" "$bucket_name" "$seq" "$total" "$smart_camera_override")"
  rendered="$(sanitize_bucket_name "$rendered")"
  if [[ -n "$ext" ]]; then
    case "$(printf '%s' "$rendered" | /usr/bin/tr '[:upper:]' '[:lower:]')" in
      *."$(printf '%s' "$ext" | /usr/bin/tr '[:upper:]' '[:lower:]')") stem="${rendered%.*}" ;;
      *) stem="$rendered" ;;
    esac
    printf '%s.%s' "$stem" "$ext"
  else
    printf '%s' "$rendered"
  fi
}

manual_shoot_name_override() {
  [[ -f "$MANUAL_SHOOT_NAME_FILE" ]] || return 1
  local raw
  raw="$(/usr/bin/head -n 1 "$MANUAL_SHOOT_NAME_FILE" 2>/dev/null || true)"
  raw="$(trim "$raw")"
  [[ -n "$raw" ]] || return 1
  printf '%s' "$raw"
}

consume_manual_shoot_name_override() {
  /bin/rm -f "$MANUAL_SHOOT_NAME_FILE" 2>/dev/null || true
}

compute_buckets_manual_override() {
  local bucket
  if ! bucket="$(manual_shoot_name_override)"; then
    return 1
  fi
  local f
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    printf '%s\t%s\n' "$f" "$bucket"
  done
  return 0
}

rebucket_relative_path() {
  local src_path="$1"
  local dest_dir="$2"
  local rel

  case "$src_path" in
    "$dest_dir"/*) rel="${src_path#"$dest_dir"/}" ;;
    *) rel="$(basename "$src_path")" ;;
  esac

  rel="${rel#/}"
  case "$rel" in
    ""|.*|*/../*|../*|*/..) rel="$(basename "$src_path")" ;;
  esac

  printf '%s' "$rel"
}

rebucket_imported_files() {
  # Re-organize already-imported files in dest_dir into bucket folders per
  # FOLDER_NAMING_STRATEGY. Rewrites the post-move queue with the new bucket
  # folder paths. No-op for "camera" strategy.
  local imported_list="$1"
  local dest_dir="$2"
  local queue_file="$3"
  local strategy="${FOLDER_NAMING_STRATEGY:-sequential}"
  local fallback="${FOLDER_NAMING_FALLBACK:-sequential}"

  [[ -s "$imported_list" ]] || return 0
  if [[ "$strategy" == "camera" ]]; then
    return 0
  fi

  local bucket_tsv
  bucket_tsv="$(mktemp "${STATE_DIR}/buckets.${run_id}.XXXXXX")"

  local primary_ok=1
  local manual_bucket manual_cluster_count f
  manual_bucket="$(manual_shoot_name_override || true)"
  if [[ -n "$manual_bucket" ]]; then
    manual_cluster_count="$(detected_cluster_count_for_imported_list "$imported_list")"
    consume_manual_shoot_name_override
  fi

  if [[ -n "$manual_bucket" && "${manual_cluster_count:-1}" -le 1 ]]; then
    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      printf '%s\t%s\n' "$f" "$manual_bucket"
    done <"$imported_list" >"$bucket_tsv"
    log "Using one-shot manual shoot name override: ${manual_bucket}."
  else
    if [[ -n "$manual_bucket" ]]; then
      log "Ignored one-shot manual shoot name '${manual_bucket}' because ${manual_cluster_count} capture-time clusters were detected."
    fi
    case "$strategy" in
      sequential)
        compute_buckets_sequential "$dest_dir" <"$imported_list" >"$bucket_tsv"
        ;;
      custom)
        compute_buckets_custom "$dest_dir" <"$imported_list" >"$bucket_tsv" || primary_ok=0
        ;;
      cluster)
        compute_buckets_cluster "$dest_dir" <"$imported_list" >"$bucket_tsv"
        ;;
      smart)
        if infer_smart_root_from_sample_path >/dev/null; then
          compute_buckets_smart "$dest_dir" <"$imported_list" >"$bucket_tsv"
        else
          log "FOLDER_NAMING_STRATEGY=smart needs SMART_SAMPLE_PATH with /YYYY/YYYY.MM/YYYY.MM.DD/; using fallback '$fallback'."
          primary_ok=0
        fi
        ;;
      calendar)
        compute_buckets_calendar "$dest_dir" <"$imported_list" >"$bucket_tsv" || primary_ok=0
        ;;
      template)
        compute_buckets_template "$dest_dir" <"$imported_list" >"$bucket_tsv" || primary_ok=0
        ;;
      *)
        log "Unknown FOLDER_NAMING_STRATEGY='$strategy'; keeping camera folders."
        rm -f "$bucket_tsv"
        return 0
        ;;
    esac
  fi

  if [[ "$primary_ok" -eq 0 ]]; then
    compute_buckets_with_fallback "$fallback" "$dest_dir" <"$imported_list" >"$bucket_tsv"
  fi

  if [[ ! -s "$bucket_tsv" ]]; then
    rm -f "$bucket_tsv"
    return 0
  fi

  : > "$queue_file"
  local bucket_set camera_label_tsv
  bucket_set="$(mktemp)"
  camera_label_tsv="$(mktemp "${STATE_DIR}/rebucket-camera-labels.${run_id}.XXXXXX")"
  if [[ "${FILE_RENAME_ENABLED:-0}" == "1" ]]; then
    build_smart_camera_label_map "$bucket_tsv" "$camera_label_tsv"
  fi

  local src_path bucket_name bucket_dir base output_base rel rel_dir target stem ext n rebucket_failed seq total_count smart_label
  rebucket_failed=0
  seq=0
  total_count="$(/usr/bin/wc -l <"$bucket_tsv" | /usr/bin/awk '{print $1}')"
  [[ "$total_count" =~ ^[0-9]+$ ]] || total_count=0
  while IFS=$'\t' read -r src_path bucket_name; do
    [[ -z "$src_path" || -z "$bucket_name" ]] && continue
    [[ -f "$src_path" ]] || continue
    seq=$((seq + 1))

    bucket_name="$(sanitize_bucket_name "$bucket_name")"
    bucket_dir="${dest_dir}/${bucket_name}"
    if ! /bin/mkdir -p "$bucket_dir"; then
      log "Rebucket failed: cannot create bucket dir ${bucket_dir}"
      rebucket_failed=$((rebucket_failed + 1))
      continue
    fi

    base="$(basename "$src_path")"
    output_base="$base"
    if [[ "${FILE_RENAME_ENABLED:-0}" == "1" ]]; then
      smart_label="$(smart_camera_label_from_map "$camera_label_tsv" "$src_path")"
      output_base="$(render_file_name_for_rebucket "$src_path" "$bucket_name" "$seq" "$total_count" "$smart_label")"
    fi
    if [[ "${REBUCKET_PRESERVE_SOURCE_FOLDERS:-0}" == "1" ]]; then
      rel="$(rebucket_relative_path "$src_path" "$dest_dir")"
      case "$rel" in
        "$bucket_name"/*) rel="${rel#"$bucket_name"/}" ;;
      esac
      rel_dir="$(dirname "$rel")"
      rel="${rel_dir}/${output_base}"
      [[ "$rel_dir" == "." ]] && rel="$output_base"
      if [[ "$rel_dir" != "." ]]; then
        if ! /bin/mkdir -p "${bucket_dir}/${rel_dir}"; then
          log "Rebucket failed: cannot create preserved folder ${bucket_dir}/${rel_dir}"
          rebucket_failed=$((rebucket_failed + 1))
          continue
        fi
      fi
      target="${bucket_dir}/${rel}"
    else
      target="${bucket_dir}/${output_base}"
    fi
    if [[ -e "$target" ]]; then
      stem="${output_base%.*}"
      ext="${output_base##*.}"
      if [[ "$stem" == "$ext" ]]; then
        stem="$output_base"
        ext=""
      fi
      n=1
      while [[ -e "$(dirname "$target")/${stem}-${n}${ext:+.${ext}}" ]]; do
        n=$((n + 1))
      done
      target="$(dirname "$target")/${stem}-${n}${ext:+.${ext}}"
    fi

    if /bin/mv "$src_path" "$target"; then
      db_move_media_local_path "$src_path" "$target"
      /bin/echo "$bucket_dir" >> "$bucket_set"
    else
      log "Rebucket failed: ${src_path} -> ${target}"
      rebucket_failed=$((rebucket_failed + 1))
    fi
  done <"$bucket_tsv"

  /usr/bin/sort -u "$bucket_set" > "$queue_file"

  # Clean up now-empty camera folders left behind by the moves.
  /usr/bin/find "$dest_dir" -mindepth 1 -maxdepth 1 -type d -empty -delete 2>/dev/null || true

  rm -f "$bucket_tsv" "$bucket_set" "$camera_label_tsv"
  if [[ "$rebucket_failed" -gt 0 ]]; then
    return 1
  fi
  return 0
}

pending_key_for_volume() {
  local uuid="$1"
  local vol_name="$2"
  local key="${uuid:-$vol_name}"
  key="${key//[^A-Za-z0-9._-]/_}"
  printf '%s' "$key"
}

record_pending_import() {
  local pending_file="$1"
  local dest_dir="$2"
  local copied_file="$3"
  /bin/mkdir -p "$(dirname "$pending_file")"
  /usr/bin/printf 'raw\t%s\t%s\t0\t0\n' "$dest_dir" "$copied_file" >>"$pending_file"
}

record_pending_queue() {
  local pending_file="$1"
  local dest_dir="$2"
  local queue_file="$3"
  local queued_path
  /bin/mkdir -p "$(dirname "$pending_file")"
  : >"$pending_file"
  while IFS= read -r queued_path || [[ -n "$queued_path" ]]; do
    [[ -n "$queued_path" && -e "$queued_path" ]] || continue
    /usr/bin/printf 'queued\t%s\t%s\t0\t0\n' "$dest_dir" "$queued_path" >>"$pending_file"
    db_upsert_upload_job "$queued_path" "$dest_dir" "pending" "0" "0" ""
  done <"$queue_file"
}

retry_delay_minutes_for_attempt() {
  local attempt="$1"
  local raw="${UPLOAD_RETRY_MINUTES:-3,10,60,240}"
  local item index=1 last="240"
  IFS=',' read -r -a _retry_minutes <<<"$raw"
  for item in "${_retry_minutes[@]}"; do
    item="$(trim "$item")"
    [[ "$item" =~ ^[0-9]+$ ]] || continue
    last="$item"
    if [[ "$index" -eq "$attempt" ]]; then
      printf '%s' "$item"
      return
    fi
    index=$((index + 1))
  done
  printf '%s' "$last"
}

bump_pending_retry() {
  local pending_file="$1"
  local error_detail="${2:-upload failed}"
  [[ -f "$pending_file" ]] || return 0
  local tmp_file now row_mode row_dest row_file row_attempts row_next new_attempts delay_min next_epoch
  tmp_file="$(/usr/bin/mktemp "${STATE_DIR}/pending-retry.${run_id}.XXXXXX")"
  now="$(/bin/date '+%s')"
  while IFS=$'\t' read -r row_mode row_dest row_file row_attempts row_next || [[ -n "$row_mode$row_dest$row_file" ]]; do
    if [[ -z "$row_file" ]]; then
      row_file="$row_dest"
      row_dest="$row_mode"
      row_mode="raw"
    fi
    [[ -n "$row_dest" && -n "$row_file" ]] || continue
    [[ "$row_attempts" =~ ^[0-9]+$ ]] || row_attempts=0
    new_attempts=$((row_attempts + 1))
    delay_min="$(retry_delay_minutes_for_attempt "$new_attempts")"
    next_epoch=$((now + delay_min * 60))
    /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' "$row_mode" "$row_dest" "$row_file" "$new_attempts" "$next_epoch" >>"$tmp_file"
    db_update_upload_job_status "$row_file" "retry_wait" "$new_attempts" "$next_epoch" "$error_detail"
  done <"$pending_file"
  if [[ -s "$tmp_file" ]]; then
    /bin/mv "$tmp_file" "$pending_file"
  else
    /bin/rm -f "$tmp_file"
  fi
}

pending_file_contains_source_path() {
  local source_path="$1"
  local pending_file row_mode row_dest row_file
  for pending_file in "$PENDING_DIR"/pending.*.tsv; do
    [[ -f "$pending_file" ]] || continue
    while IFS=$'\t' read -r row_mode row_dest row_file _ || [[ -n "$row_mode$row_dest$row_file" ]]; do
      if [[ -z "$row_file" ]]; then
        row_file="$row_dest"
      fi
      [[ "$row_file" == "$source_path" ]] && return 0
    done <"$pending_file"
  done
  return 1
}

uuid_has_pending_recovery_file() {
  local uuid="$1"
  local pending_file base_name
  [[ -n "$uuid" ]] || return 1
  for pending_file in "$PENDING_DIR"/pending.*.tsv; do
    [[ -f "$pending_file" ]] || continue
    base_name="$(basename "$pending_file")"
    case "$base_name" in
      "pending.${uuid}."*) return 0 ;;
    esac
  done
  return 1
}

pending_import_label() {
  local human
  human="$(pending_import_time_label "$1")"
  if [[ -n "$human" ]]; then
    printf 'Import from %s' "$human"
  else
    printf 'Pending import'
  fi
}

pending_import_time_label() {
  local pending_file="$1"
  local base stamp human
  base="$(basename "$pending_file")"
  stamp="$(printf '%s' "$base" | /usr/bin/sed -n 's/^pending\.[^.]*\.\([0-9]\{8\}-[0-9]\{6\}\)\.tsv$/\1/p')"
  if [[ -n "$stamp" ]]; then
    human="$(/bin/date -j -f '%Y%m%d-%H%M%S' "$stamp" '+%-m/%-d %-I:%M%p' 2>/dev/null | /usr/bin/tr '[:upper:]' '[:lower:]' || true)"
    if [[ -n "$human" ]]; then
      printf '%s' "$human"
      return
    fi
  fi
  /usr/bin/stat -f '%Sm' -t '%-m/%-d %-I:%M%p' "$pending_file" 2>/dev/null | /usr/bin/tr '[:upper:]' '[:lower:]' || true
}

append_limited_list_item() {
  local current="$1"
  local item="$2"
  if [[ -z "$current" ]]; then
    printf '%s' "$item"
  else
    printf '%s, %s' "$current" "$item"
  fi
}

missing_pending_recovery_message() {
  local pending_file="$1"
  local missing_count="$2"
  local pending_count="$3"
  local examples="$4"
  local roots="$5"
  local label where
  label="$(pending_import_label "$pending_file")"
  where=""
  if [[ -n "$roots" ]]; then
    where=" Missing from: ${roots}."
  fi
  if [[ -n "$examples" ]]; then
    printf '%s is missing %s of %s staged item(s). Examples: %s.%s Reinsert the original card or restore the staging folder so DDump can retry.' \
      "$label" "$missing_count" "$pending_count" "$examples" "$where"
  else
    printf '%s is missing %s of %s staged item(s).%s Reinsert the original card or restore the staging folder so DDump can retry.' \
      "$label" "$missing_count" "$pending_count" "$where"
  fi
}

uuid_has_unfinished_media_rows() {
  local uuid="$1"
  db_available || return 1
  [[ -n "$uuid" ]] || return 1
  local count
  count="$(/usr/bin/sqlite3 -batch -noheader "$DB_FILE" "SELECT COUNT(*) FROM media_files WHERE source_uuid=$(sql_quote "$uuid") AND status IN ('copy_failed','verify_failed','copied','organized','upload_pending','needs_reinsert');" 2>>"$LOG_FILE" || echo 0)"
  [[ "${count:-0}" -gt 0 ]]
}

should_force_recopy_for_uuid() {
  local uuid="$1"
  [[ -n "$uuid" ]] || return 1
  if uuid_has_pending_recovery_file "$uuid"; then
    return 0
  fi
  if uuid_has_unfinished_media_rows "$uuid"; then
    return 0
  fi
  return 1
}

seed_pending_from_db_incomplete() {
  db_available || return 0

  local resume_file seeded_count
  resume_file="$(/usr/bin/mktemp "${PENDING_DIR}/pending.resume-db.${run_id}.XXXXXX.tsv")"
  seeded_count=0

  {
    /usr/bin/sqlite3 -separator $'\t' "$DB_FILE" \
      "SELECT COALESCE(target_dir,''), COALESCE(local_path,''), status, COALESCE(attempts,0), COALESCE(next_retry_epoch,0) FROM upload_jobs WHERE status IN ('pending','retry_wait','failed','uploading','needs_reinsert') ORDER BY updated_at ASC;" \
      2>>"$LOG_FILE" \
      | while IFS=$'\t' read -r row_dest row_file row_status row_attempts row_next || [[ -n "$row_dest$row_file$row_status" ]]; do
          [[ -n "$row_dest" && -n "$row_file" ]] || continue
          if pending_file_contains_source_path "$row_file"; then
            continue
          fi
          if [[ ! -e "$row_file" ]]; then
            db_update_upload_job_status "$row_file" "needs_reinsert" "${row_attempts:-0}" "${row_next:-0}" "local staged file missing"
            db_mark_media_needs_reinsert_by_local_path "$row_file" "local staged file missing before resume"
            continue
          fi
          /usr/bin/printf 'queued\t%s\t%s\t%s\t%s\n' "$row_dest" "$row_file" "${row_attempts:-0}" "${row_next:-0}" >>"$resume_file"
        done
  } || true

  if [[ -s "$resume_file" ]]; then
    seeded_count="$(/usr/bin/wc -l <"$resume_file" | /usr/bin/awk '{print $1}')"
    log "Seeded ${seeded_count} pending upload row(s) from SQLite recovery."
    pending_recovery_touched=1
  else
    /bin/rm -f "$resume_file"
  fi
}

recover_pending_imports() {
  local pending_file
  for pending_file in "$PENDING_DIR"/pending.*.tsv; do
    [[ -e "$pending_file" ]] || continue
    if [[ ! -s "$pending_file" ]]; then
      /bin/rm -f "$pending_file"
      continue
    fi

    local imported_list queue_file dest_dir row_dest row_file queued_mode pending_row_count missing_row_count not_due
    local row_root recovery_msg
    local missing_examples missing_example_count missing_roots missing_root_count
    local max_pending_attempts
    imported_list="$(/usr/bin/mktemp "${STATE_DIR}/recover-imported.${run_id}.XXXXXX")"
    queue_file="$(/usr/bin/mktemp "${STATE_DIR}/recover-queue.${run_id}.XXXXXX")"
    dest_dir=""
    queued_mode=0
    pending_row_count=0
    missing_row_count=0
    not_due=0
    missing_examples=""
    missing_example_count=0
    missing_roots=""
    missing_root_count=0
    max_pending_attempts=0

    local row_mode row_attempts row_next now_epoch
    now_epoch="$(/bin/date '+%s')"
    while IFS=$'\t' read -r row_mode row_dest row_file row_attempts row_next || [[ -n "$row_mode$row_dest$row_file" ]]; do
      if [[ -z "$row_file" ]]; then
        # Backward-compatible read for older two-column pending files.
        row_file="$row_dest"
        row_dest="$row_mode"
        row_mode="raw"
      fi
      [[ -n "$row_dest" && -n "$row_file" ]] || continue
      pending_row_count=$((pending_row_count + 1))
      [[ "$row_attempts" =~ ^[0-9]+$ ]] || row_attempts=0
      if [[ "$row_attempts" -gt "$max_pending_attempts" ]]; then
        max_pending_attempts="$row_attempts"
      fi
      if [[ "$row_next" =~ ^[0-9]+$ && "$row_next" -gt "$now_epoch" ]]; then
        not_due=1
        continue
      fi
      if [[ ! -e "$row_file" ]]; then
        missing_row_count=$((missing_row_count + 1))
        if [[ "$missing_example_count" -lt 4 ]]; then
          missing_examples="$(append_limited_list_item "$missing_examples" "$(basename "$row_file")")"
          missing_example_count=$((missing_example_count + 1))
        fi
        row_root="$(dirname "$row_file")"
        if [[ "$missing_root_count" -lt 2 ]] && [[ ", ${missing_roots}, " != *", ${row_root}, "* ]]; then
          missing_roots="$(append_limited_list_item "$missing_roots" "$row_root")"
          missing_root_count=$((missing_root_count + 1))
        fi
        db_update_upload_job_status "$row_file" "needs_reinsert" "${row_attempts:-0}" "${row_next:-0}" "local staged file missing"
        db_mark_media_needs_reinsert_by_local_path "$row_file" "local staged file missing before upload"
        continue
      fi
      if [[ -z "$dest_dir" ]]; then
        dest_dir="$row_dest"
      elif [[ "$dest_dir" != "$row_dest" ]]; then
        log "Pending recovery skipped row with mixed dest_dir: ${row_file}"
        continue
      fi
      if [[ "$row_mode" == "queued" ]]; then
        queued_mode=1
        queue_path_unique "$queue_file" "$row_file"
      else
        /bin/echo "$row_file" >>"$imported_list"
      fi
    done <"$pending_file"

    if [[ "$not_due" -eq 1 && ! -s "$queue_file" && ! -s "$imported_list" ]]; then
      /bin/rm -f "$imported_list" "$queue_file"
      continue
    fi
    pending_recovery_touched=1

    if [[ -z "$dest_dir" ]] || { [[ "$queued_mode" -ne 1 ]] && [[ ! -s "$imported_list" ]]; }; then
      if [[ "$pending_row_count" -gt 0 && "$missing_row_count" -gt 0 ]]; then
        recovery_msg="$(missing_pending_recovery_message "$pending_file" "$missing_row_count" "$pending_row_count" "$missing_examples" "$missing_roots")"
        log "Pending recovery cannot continue because staged files are missing: ${recovery_msg} Pending file: ${pending_file}"
        if [[ "$max_pending_attempts" -eq 0 ]] && notification_dedupe_allows "pending_recovery_missing" "$recovery_msg"; then
          notify "DDump" "$recovery_msg" warn "pending_recovery_missing"
          ntfy_notify "pending_recovery_missing" "DDump: recovery needs card" "$recovery_msg" \
            "import=$(pending_import_label "$pending_file")" \
            "import_time=$(pending_import_time_label "$pending_file")" \
            "missing_count=$missing_row_count" \
            "total_count=$pending_row_count" \
            "examples=$missing_examples" \
            "roots=$missing_roots"
        else
          log "Pending recovery missing-staging notification already sent or deduped for ${pending_file}; suppressing repeat alert."
        fi
        bump_pending_retry "$pending_file" "local staged file missing; card/staging restore needed"
      else
        log "Pending recovery had no existing files; clearing ${pending_file}."
        /bin/rm -f "$pending_file"
      fi
      /bin/rm -f "$imported_list" "$queue_file"
      continue
    fi

	    log "Recovering pending staged files: ${pending_file}"
	    set_status_phase "recovering" "Recovering pending upload batch."
	    if [[ "$queued_mode" -eq 1 ]] \
	       || rebucket_imported_files "$imported_list" "$dest_dir" "$queue_file"; then
	      if [[ "$queued_mode" -ne 1 && -s "$queue_file" ]]; then
	        record_pending_queue "$pending_file" "$dest_dir" "$queue_file"
	      fi
	    else
	      log "Pending recovery rebucket failed; keeping ${pending_file} for next run."
      summary_errors_total=$((summary_errors_total + 1))
      bump_pending_retry "$pending_file" "rebucket failed"
      /bin/rm -f "$imported_list" "$queue_file"
      continue
    fi

    if [[ ! -s "$queue_file" ]]; then
      log "Pending recovery has no queued upload items after rebucket; leaving ${pending_file} unchanged."
    elif move_queued_paths_to_post_target "$queue_file" "pending recovery" && [[ "$move_last_status" == "success" ]]; then
      if [[ -n "$move_last_target" ]]; then
        write_upload_receipt "pending recovery" "success" "$move_last_target" "$queue_file"
      fi
      log "Pending recovery complete: ${pending_file}"
      while IFS= read -r queued_path || [[ -n "$queued_path" ]]; do
        [[ -n "$queued_path" ]] || continue
        db_update_upload_job_status "$queued_path" "uploaded" "0" "0" ""
      done <"$queue_file"
      /bin/rm -f "$pending_file"
    else
      if [[ -n "$move_last_target" ]]; then
        write_upload_receipt "pending recovery" "partial" "$move_last_target" "$queue_file"
      fi
      log "Pending recovery incomplete; keeping ${pending_file} for next run."
      summary_errors_total=$((summary_errors_total + 1))
      bump_pending_retry "$pending_file" "${move_last_detail:-upload failed}"
    fi

    /bin/rm -f "$imported_list" "$queue_file"
  done
}

# ----- end folder-naming helpers ---------------------------------------------

set_status_phase "starting" "Checking incomplete sessions before new card import."
seed_pending_from_db_incomplete
recover_pending_imports

run_day_folder=""
if [[ "$CREATE_DAILY_FOLDER" == "1" ]]; then
  run_day_folder="$(/bin/date +"$DAILY_FOLDER_FORMAT")"
fi

processed_volume_count=0
imported_file_count_total=0
run_stopped=0
no_candidate_volume_count=0
no_candidate_volume_names=""
upload_complete_volume_count=0
upload_complete_file_count=0
upload_complete_targets=""

for vol_path in /Volumes/*; do
  [[ "$run_stopped" == "1" ]] && break
  [[ -d "$vol_path" ]] || continue

  vol_name="$(basename "$vol_path")"
  if is_ignored_volume_name "$vol_name"; then
    log "Skipping ignored volume name: ${vol_name}"
    continue
  fi
  current_status_volume="$vol_name"
  set_status_phase "scanning" "Checking card ${vol_name}."

  uuid="$(get_volume_uuid "$vol_path")"
  if [[ "$IGNORE_NO_UUID_VOLUMES" == "1" && -z "$uuid" ]]; then
    log "Skipping volume with no UUID: ${vol_name} (${vol_path})"
    continue
  fi
  if is_uuid_blocked "$uuid"; then
    log "Skipping blocked volume: ${vol_name} (UUID: ${uuid:-none})"
    continue
  fi
  # Internal-volume skip: applies ONLY if the volume has no photo files. macOS sometimes
  # reports SD cards from USB-C readers as "Internal" — we don't want to silent-skip a
  # real photo card just because diskutil mislabels its location.
  if [[ "$SKIP_INTERNAL_VOLUMES" == "1" ]] && ! is_trusted_name_prefix "$vol_name" \
       && is_internal_volume "$vol_path" && ! is_uuid_trusted "$uuid" \
       && ! volume_looks_like_camera_card "$vol_path"; then
    log "Skipping internal volume that does not look like a camera card: ${vol_name}"
    continue
  fi

  # Silent-skip volumes that don't look like camera media: not trusted by UUID,
  # not name-prefixed, and lacking camera-card shape. Prevents popup/notification
  # on DMG installers, app mounts, update volumes, etc.
  vol_has_photos=0
  if volume_looks_like_camera_card "$vol_path"; then
    vol_has_photos=1
  fi
  manual_selection_mentions_this_volume=0
  if [[ "$manual_selection_active" == "1" ]] && manual_selection_mentions_volume "$vol_path"; then
    manual_selection_mentions_this_volume=1
    vol_has_photos=1
  fi

  if [[ "$REQUIRE_PHOTOS_OR_TRUSTED" == "1" \
        && "$vol_has_photos" -ne 1 ]] \
     && ! is_trusted_name_prefix "$vol_name" \
     && ! is_uuid_trusted "$uuid"; then
    log "Silently skipping non-camera volume: ${vol_name} (not trusted, no name prefix, no camera-card media shape)"
    record_skipped_volume \
      "$vol_name" \
      "$vol_path" \
      "$uuid" \
      "not_camera_shape" \
      "DDump saw ${vol_name}, but it was not trusted and did not look enough like a camera card." \
      "Open DDump, set the scan window if needed, then use Manual import and choose the card itself. You can trust it once or forever."
    set_status_phase "idle" "Saw ${vol_name}, but it did not look like a camera card."
    continue
  fi

  # Volume passed the photo-shape filter. Capture quick stats for the user notification.
  vol_photo_total=0
  vol_photo_recent=0
  if [[ "$vol_has_photos" -eq 1 ]]; then
    IFS=$'\t' read -r vol_photo_total vol_photo_recent < <(count_recent_photos_on_volume "$vol_path") || true
  fi

  # Open the legacy Terminal monitor only if explicitly enabled. Notifications-by-default mode skips this.
  if [[ "${USE_NOTIFICATIONS:-1}" != "1" ]]; then
    start_progress_window_if_needed "non-internal mounted volume detected" "$vol_name" "$vol_path" "$uuid"
  else
    set_startup_cause "non-internal mounted volume detected" "$vol_name" "$vol_path" "$uuid"
  fi

  trusted="0"

  if [[ "$manual_selection_mentions_this_volume" == "1" ]]; then
    trusted="1"
    if [[ "$(manual_import_policy)" == "trust" && -n "$uuid" ]]; then
      remember_uuid "$uuid"
      set_card_policy_mode "$uuid" "remember"
      log "Manual import trusted ${vol_name} forever (UUID: ${uuid})."
    else
      log "Manual import trusted ${vol_name} for this run only."
    fi
  elif is_trusted_name_prefix "$vol_name"; then
    trusted="1"
  elif is_uuid_trusted "$uuid"; then
    trusted="1"
  elif prompt_for_unknown_card_action "$vol_name" "$uuid" "$vol_photo_total" "$vol_photo_recent"; then
    trusted="1"
  elif [[ "$?" -eq 2 ]]; then
    log "Volume blocked by user choice: ${vol_name} (UUID: ${uuid:-none})"
    continue
  elif prompt_to_trust_volume "$vol_name" "$uuid"; then
    trusted="1"
  fi


  if [[ "$trusted" != "1" ]]; then
    log "Skipping untrusted volume: ${vol_name} (UUID: ${uuid:-none})"
    continue
  fi

  reinsert_priority_notice_sent=0
  if [[ -n "$uuid" ]] && db_has_needs_reinsert_for_uuid "$uuid"; then
    reinsert_priority_notice_sent=1
    notify "DDump" "${vol_name}: recovering previously missing files first, then new files." info
    log "Volume ${vol_name} has files marked needs_reinsert; prioritizing those first."
  fi
  force_recopy_for_uuid=0
  if [[ -n "$uuid" ]] && should_force_recopy_for_uuid "$uuid"; then
    force_recopy_for_uuid=1
    log "Volume ${vol_name}: forcing re-copy from card because unfinished recovery exists for UUID ${uuid}."
  fi

  manual_selection_for_volume=0
  manual_candidates_file=""
  source_roots_file=""
  staging_required_kb=""
  staging_required_label=""
  if [[ "$manual_selection_active" == "1" ]]; then
    manual_candidates_file="$(/usr/bin/mktemp "${STATE_DIR}/manual-candidates.${vol_name//[^A-Za-z0-9._-]/_}.XXXXXX")"
    if build_manual_candidates_for_volume "$vol_name" "$vol_path" "$manual_candidates_file"; then
      manual_selection_for_volume=1
      source_roots_file="$(/usr/bin/mktemp "${STATE_DIR}/source-roots.${vol_name//[^A-Za-z0-9._-]/_}.XXXXXX")"
      /bin/echo "$vol_path" >"$source_roots_file"
      if manual_required="$(manual_required_kb_for_candidates "$manual_candidates_file" 2>/dev/null)"; then
        staging_required_kb="$manual_required"
        staging_required_label="selected files + ${MANUAL_SELECTION_SAFETY_GB:-2}GB safety"
      fi
      log "Manual selection active for ${vol_name}; only selected files/folders will be imported."
    else
      /bin/rm -f "$manual_candidates_file"
      continue
    fi
  else
    source_roots_file="$(/usr/bin/mktemp "${STATE_DIR}/source-roots.${vol_name//[^A-Za-z0-9._-]/_}.XXXXXX")"
    if ! resolve_source_roots_for_volume "$vol_name" "$vol_path" "$uuid" "$source_roots_file"; then
      log "Skipping trusted volume ${vol_name}: no source folders configured."
      notify "DDump" "${vol_name}: no source folders selected, skipped."
      /bin/rm -f "$source_roots_file"
      continue
    fi
  fi

  processed_volume_count=$((processed_volume_count + 1))
  activate_ddump_app_for_card
  volume_started_epoch="$(/bin/date '+%s')"
  no_eject_hold_file="${STATE_DIR}/hold-eject.${vol_name//[^A-Za-z0-9._-]/_}.flag"
  start_no_eject_prompt "$vol_name" "$no_eject_hold_file" &

  dest_dir="$DEST_ROOT"
  if [[ -n "$run_day_folder" ]]; then
    dest_dir="${DEST_ROOT}/${run_day_folder}"
  fi
  /bin/mkdir -p "$dest_dir"
  last_dest_dir="$dest_dir"
  if [[ "$ENABLE_POST_EJECT_MOVE" == "1" ]]; then
    preflight_move_root="$(effective_post_move_root)"
    if path_uses_gdrive_mount "$preflight_move_root" && ! direct_cloud_upload_enabled_for_root "$preflight_move_root"; then
      if ! ensure_gdrive_mount_for_post_move "$preflight_move_root"; then
        log "Preflight mount check failed for ${vol_name}: ${move_last_detail}. Continuing with staging import."
      else
        log "Preflight mount check passed for ${vol_name}."
      fi
    fi
  fi
  if [[ "$manual_selection_for_volume" == "1" ]]; then
    if ! check_staging_space_ready "$dest_dir" "$staging_required_kb" "$staging_required_label"; then
      summary_errors_total=$((summary_errors_total + 1))
      /bin/rm -f "$manual_candidates_file"
      /bin/rm -f "$source_roots_file"
      /bin/rm -f "$no_eject_hold_file"
      continue
    fi
  fi

  imported_this_volume=0
  imported_bytes_this_volume=0
  skipped_existing_this_volume=0
  skipped_extension_this_volume=0
  failed_copy=0
  has_candidates_this_volume=0
  total_candidates_this_volume=0
  processed_candidates_this_volume=0
  post_move_queue_file="$(/usr/bin/mktemp "${STATE_DIR}/move-queue.${vol_name//[^A-Za-z0-9._-]/_}.XXXXXX")"
  imported_files_file="$(/usr/bin/mktemp "${STATE_DIR}/imported.${vol_name//[^A-Za-z0-9._-]/_}.XXXXXX")"
  pending_imports_file="${PENDING_DIR}/pending.$(pending_key_for_volume "$uuid" "$vol_name").${run_id}.tsv"

  # Tell the user something is happening right now.
  if [[ "$manual_selection_for_volume" == "1" ]]; then
    notify "DDump" "📷 ${vol_name}: importing manual selection..." info "staging_started"
    ntfy_notify "staging_started" "DDump: staging started" "${vol_name}: manual-selection staging started."
  elif [[ "$vol_photo_total" =~ ^[0-9]+$ && "$vol_photo_total" -gt 0 ]]; then
    notify "DDump" "📷 ${vol_name}: scanning ${vol_photo_total} files (${vol_photo_recent} from last ${PHOTO_RECENCY_HOURS:-24}h)..." info "staging_started"
    ntfy_notify "staging_started" "DDump: staging started" "${vol_name}: staging started (detected ${vol_photo_total} files)."
  else
    notify "DDump" "📷 ${vol_name}: scanning..." info "staging_started"
    ntfy_notify "staging_started" "DDump: staging started" "${vol_name}: staging started."
  fi

  while IFS= read -r source_root || [[ -n "$source_root" ]]; do
    [[ "$run_stopped" == "1" ]] && break
    source_root="$(trim "$source_root")"
    [[ -n "$source_root" ]] || continue
    [[ -d "$source_root" ]] || continue
    source_root_rel="${source_root#"${vol_path}/"}"
    if [[ "$source_root" == "$vol_path" ]]; then
      source_root_rel="."
    fi

    temp_candidates_file=""
    if [[ "$manual_selection_for_volume" == "1" ]]; then
      temp_candidates_file="$manual_candidates_file"
    else
      temp_candidates_file="$(/usr/bin/mktemp "${STATE_DIR}/candidates.${vol_name//[^A-Za-z0-9._-]/_}.XXXXXX")"
      find_candidates "$source_root" "$temp_candidates_file"
      prioritize_needs_reinsert_candidates "$uuid" "$source_root_rel" "$temp_candidates_file"
    fi

    if [[ ! -s "$temp_candidates_file" ]]; then
      if [[ "$manual_selection_for_volume" != "1" ]]; then
        /bin/rm -f "$temp_candidates_file"
      fi
      continue
    fi

    if [[ "$manual_selection_for_volume" != "1" ]]; then
      root_required_kb=""
      if root_required_kb="$(manual_required_kb_for_candidates "$temp_candidates_file" 2>/dev/null)"; then
        if ! check_staging_space_ready "$dest_dir" "$root_required_kb" "lookback candidate files + ${MANUAL_SELECTION_SAFETY_GB:-2}GB safety"; then
          summary_errors_total=$((summary_errors_total + 1))
          /bin/rm -f "$temp_candidates_file"
          continue
        fi
      fi
    fi

    has_candidates_this_volume=1
    candidate_count_this_root="$(count_candidates_in_file "$temp_candidates_file")"
    if [[ "$candidate_count_this_root" =~ ^[0-9]+$ ]]; then
      total_candidates_this_volume=$((total_candidates_this_volume + candidate_count_this_root))
    fi
    current_status_total="$total_candidates_this_volume"
    current_status_processed="$processed_candidates_this_volume"
    current_status_imported="$imported_this_volume"
    current_status_skipped="$skipped_existing_this_volume"
    current_status_failed="$failed_copy"
    set_status_phase "importing" "Importing from ${vol_name}."

    while IFS= read -r -d '' src_file; do
      if ! wait_if_paused_or_stop_requested; then
        run_stopped=1
        set_status_phase "stopping" "Stop requested. Finishing current file and ending."
        break
      fi
      if [[ "$current_status_phase" != "importing" ]]; then
        set_status_phase "importing" "Importing from ${vol_name}."
      fi

      if is_ignored_source_file "$src_file"; then
        skipped_extension_this_volume=$((skipped_extension_this_volume + 1))
        record_missed_file "$vol_name" "skipped_system_file" "$src_file" "ignored macOS metadata file"
        processed_candidates_this_volume=$((processed_candidates_this_volume + 1))
        current_status_processed="$processed_candidates_this_volume"
        current_status_imported="$imported_this_volume"
        current_status_skipped="$skipped_existing_this_volume"
        current_status_failed="$failed_copy"
        write_status
        continue
      fi

      file_size="$(/usr/bin/stat -f '%z' "$src_file")"
      file_mtime="$(/usr/bin/stat -f '%m' "$src_file")"
      rel_path="${src_file#"${source_root}/"}"
      safe_rel_path="${rel_path//:/_}"
      out_path="${dest_dir}/${safe_rel_path}"
      db_upsert_candidate_file "$uuid" "$vol_name" "$source_root_rel" "$rel_path" "$src_file" "$file_size" "$file_mtime"

      if ! has_allowed_extension "$src_file" "$FILE_EXTENSIONS"; then
        skipped_extension_this_volume=$((skipped_extension_this_volume + 1))
        record_missed_file "$vol_name" "skipped_extension" "$src_file" "extension filtered by FILE_EXTENSIONS"
        db_update_file_status "$uuid" "$source_root_rel" "$rel_path" "$file_size" "$file_mtime" "skipped_extension" "" "" "extension filtered by FILE_EXTENSIONS"
        processed_candidates_this_volume=$((processed_candidates_this_volume + 1))
        current_status_processed="$processed_candidates_this_volume"
        current_status_imported="$imported_this_volume"
        current_status_skipped="$skipped_existing_this_volume"
        current_status_failed="$failed_copy"
        write_status
        continue
      fi

      if [[ "$force_recopy_for_uuid" != "1" ]] \
         && [[ -n "$uuid" ]] \
         && db_file_has_local_copy "$uuid" "$source_root_rel" "$rel_path" "$file_size" "$file_mtime"; then
        skipped_existing_this_volume=$((skipped_existing_this_volume + 1))
        record_missed_file "$vol_name" "skipped_db_local_copy" "$src_file" "sqlite status already copied/upload pending/uploaded"
        processed_candidates_this_volume=$((processed_candidates_this_volume + 1))
        current_status_processed="$processed_candidates_this_volume"
        current_status_imported="$imported_this_volume"
        current_status_skipped="$skipped_existing_this_volume"
        current_status_failed="$failed_copy"
        write_status
        continue
      fi

      if [[ "$force_recopy_for_uuid" != "1" ]] && [[ "${DB_ENABLED:-0}" != "1" ]]; then
        if staging_memory_has_candidate "$dest_dir" "$rel_path" "$file_size"; then
          skipped_existing_this_volume=$((skipped_existing_this_volume + 1))
          record_missed_file "$vol_name" "skipped_staging_memory" "$src_file" "matched existing file in staging memory"
          processed_candidates_this_volume=$((processed_candidates_this_volume + 1))
          current_status_processed="$processed_candidates_this_volume"
          current_status_imported="$imported_this_volume"
          current_status_skipped="$skipped_existing_this_volume"
          current_status_failed="$failed_copy"
          write_status
          continue
        fi
      fi

      if [[ "$force_recopy_for_uuid" != "1" ]] \
         && [[ "${DB_ENABLED:-0}" == "1" ]] \
         && [[ "$USE_FAST_SEEN_INDEX" == "1" && -n "$uuid" ]] \
         && fast_seen_key_exists "$uuid" "$source_root_rel" "$rel_path" "$file_size" "$file_mtime" \
         && ! db_file_retry_needed "$uuid" "$source_root_rel" "$rel_path" "$file_size" "$file_mtime"; then
        skipped_existing_this_volume=$((skipped_existing_this_volume + 1))
        record_missed_file "$vol_name" "skipped_seen" "$src_file" "matched card-path-size-mtime"
        db_update_file_status "$uuid" "$source_root_rel" "$rel_path" "$file_size" "$file_mtime" "legacy_seen" "" "" "skipped by legacy fast-seen index"
        processed_candidates_this_volume=$((processed_candidates_this_volume + 1))
        current_status_processed="$processed_candidates_this_volume"
        current_status_imported="$imported_this_volume"
        current_status_skipped="$skipped_existing_this_volume"
        current_status_failed="$failed_copy"
        write_status
        continue
      fi

      file_hash=""
      if [[ "${HASH_BEFORE_COPY:-0}" == "1" || "${VERIFY_COPY_HASH:-0}" == "1" ]]; then
        file_hash="$(/usr/bin/shasum -a 256 "$src_file" | /usr/bin/awk '{print $1}')"
        fingerprint="${file_size}:${file_hash}"
      else
        fingerprint="quick:${uuid}:${source_root_rel}:${rel_path}:${file_size}:${file_mtime}"
      fi

      if [[ "${HASH_BEFORE_COPY:-0}" == "1" ]] && already_imported "$fingerprint"; then
        skipped_existing_this_volume=$((skipped_existing_this_volume + 1))
        record_missed_file "$vol_name" "skipped_duplicate" "$src_file" "fingerprint=${fingerprint}"
        if [[ "$USE_FAST_SEEN_INDEX" == "1" && -n "$uuid" ]]; then
          record_fast_seen_key "$uuid" "$source_root_rel" "$rel_path" "$file_size" "$file_mtime" "$fingerprint"
        fi
        db_update_file_status "$uuid" "$source_root_rel" "$rel_path" "$file_size" "$file_mtime" "skipped_duplicate" "" "$fingerprint" "already imported by fingerprint"
        processed_candidates_this_volume=$((processed_candidates_this_volume + 1))
        current_status_processed="$processed_candidates_this_volume"
        current_status_imported="$imported_this_volume"
        current_status_skipped="$skipped_existing_this_volume"
        current_status_failed="$failed_copy"
        write_status
        continue
      fi

      /bin/mkdir -p "$(dirname "$out_path")"

      if ! /usr/bin/ditto "$src_file" "$out_path"; then
        failed_copy=1
        summary_copy_fail_total=$((summary_copy_fail_total + 1))
        summary_errors_total=$((summary_errors_total + 1))
        log "Copy failed: ${src_file}"
        record_missed_file "$vol_name" "copy_failed" "$src_file" "ditto failed"
        db_update_file_status "$uuid" "$source_root_rel" "$rel_path" "$file_size" "$file_mtime" "copy_failed" "" "$fingerprint" "ditto failed"
        processed_candidates_this_volume=$((processed_candidates_this_volume + 1))
        current_status_processed="$processed_candidates_this_volume"
        current_status_imported="$imported_this_volume"
        current_status_skipped="$skipped_existing_this_volume"
        current_status_failed="$failed_copy"
        write_status
        continue
      fi

      if ! verify_copied_file "$src_file" "$out_path" "$file_size" "$file_hash"; then
        failed_copy=1
        summary_verify_fail_total=$((summary_verify_fail_total + 1))
        summary_errors_total=$((summary_errors_total + 1))
        /bin/rm -f "$out_path" 2>/dev/null || true
        log "Copy verify failed: ${src_file} -> ${out_path} (${COPY_VERIFY_FAILURE_REASON}) ${COPY_VERIFY_FAILURE_DETAIL}"
        record_missed_file "$vol_name" "$COPY_VERIFY_FAILURE_REASON" "$src_file" "$COPY_VERIFY_FAILURE_DETAIL"
        db_update_file_status "$uuid" "$source_root_rel" "$rel_path" "$file_size" "$file_mtime" "verify_failed" "$out_path" "$fingerprint" "${COPY_VERIFY_FAILURE_REASON}: ${COPY_VERIFY_FAILURE_DETAIL}"
        processed_candidates_this_volume=$((processed_candidates_this_volume + 1))
        current_status_processed="$processed_candidates_this_volume"
        current_status_imported="$imported_this_volume"
        current_status_skipped="$skipped_existing_this_volume"
        current_status_failed="$failed_copy"
        write_status
        continue
      fi

      record_import "$fingerprint" "$src_file" "$out_path"
      db_update_file_status "$uuid" "$source_root_rel" "$rel_path" "$file_size" "$file_mtime" "copied" "$out_path" "$fingerprint" ""
      if [[ "$USE_FAST_SEEN_INDEX" == "1" && -n "$uuid" ]]; then
        record_fast_seen_key "$uuid" "$source_root_rel" "$rel_path" "$file_size" "$file_mtime" "$fingerprint"
      fi
      record_pending_import "$pending_imports_file" "$dest_dir" "$out_path"
      /bin/echo "$out_path" >>"$imported_files_file"
      rel_to_dest="${out_path#"${dest_dir}/"}"
      top_component="${rel_to_dest%%/*}"
      if [[ "$top_component" == "$rel_to_dest" ]]; then
        queue_path_unique "$post_move_queue_file" "$out_path"
      else
        queue_path_unique "$post_move_queue_file" "${dest_dir}/${top_component}"
      fi
      imported_this_volume=$((imported_this_volume + 1))
      imported_bytes_this_volume=$((imported_bytes_this_volume + file_size))
      processed_candidates_this_volume=$((processed_candidates_this_volume + 1))
      current_status_processed="$processed_candidates_this_volume"
      current_status_imported="$imported_this_volume"
      current_status_skipped="$skipped_existing_this_volume"
      current_status_failed="$failed_copy"
      write_status
    done <"$temp_candidates_file"

    if [[ "$manual_selection_for_volume" != "1" ]]; then
      /bin/rm -f "$temp_candidates_file"
    else
      break
    fi
  done <"$source_roots_file"

  if [[ "$has_candidates_this_volume" -ne 1 ]]; then
    /usr/bin/printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$run_timestamp" "$vol_name" "$uuid" "0" "0" "0" "success" >>"$RUN_HISTORY_FILE"
    no_candidate_volume_count=$((no_candidate_volume_count + 1))
    if [[ -z "$no_candidate_volume_names" ]]; then
      no_candidate_volume_names="$vol_name"
    else
      no_candidate_volume_names="${no_candidate_volume_names}, ${vol_name}"
    fi
    if [[ "$manual_selection_for_volume" == "1" ]]; then
      log "No candidate files matched manual selection on ${vol_name}."
    elif [[ "$CANDIDATE_MODE" == "lookback" ]]; then
      log "No candidate files in last ${LOOKBACK_HOURS}h on ${vol_name} (selected folders)."
    else
      log "No candidate files on ${vol_name} (selected folders)."
    fi
    ejected_msg="card left mounted."
    if [[ "$EJECT_ON_SUCCESS" == "1" ]]; then
      wait_for_min_eject_grace "$volume_started_epoch"
      if keep_mounted_requested "$no_eject_hold_file"; then
        ejected_msg="card kept mounted."
        log "User requested no eject for ${vol_name}; leaving mounted."
        summary_kept_mounted_total=$((summary_kept_mounted_total + 1))
        if [[ -z "$summary_kept_mounted_volumes" ]]; then
          summary_kept_mounted_volumes="$vol_name"
        else
          summary_kept_mounted_volumes="${summary_kept_mounted_volumes}, ${vol_name}"
        fi
      elif diskutil_eject_with_timeout "$vol_path" "$vol_name"; then
        log "Ejected volume: ${vol_name}"
        ejected_msg="card ejected."
        ntfy_notify "card_ejected" "DDump: card ejected" "${vol_name}: card ejected after no-new-files check."
      else
        log "Failed to eject volume: ${vol_name}; leaving mounted."
        ejected_msg="could not eject card."
        summary_errors_total=$((summary_errors_total + 1))
      fi
    fi
    notify "DDump" "${vol_name}: no new files, ${ejected_msg}" info "card_ejected"
    /bin/rm -f "$manual_candidates_file"
    /bin/rm -f "$post_move_queue_file"
    /bin/rm -f "$imported_files_file"
    /bin/rm -f "$source_roots_file"
    /bin/rm -f "$no_eject_hold_file"
    continue
  fi

  summary_skipped_existing_total=$((summary_skipped_existing_total + skipped_existing_this_volume))
  summary_skipped_extension_total=$((summary_skipped_extension_total + skipped_extension_this_volume))

  imported_file_count_total=$((imported_file_count_total + imported_this_volume))

  status="success"
  if [[ "$failed_copy" == "1" ]]; then
    status="partial"
  fi

  log "Volume ${vol_name}: imported=${imported_this_volume}, skipped_known=${skipped_existing_this_volume}, skipped_ext=${skipped_extension_this_volume}, copy_status=${status}"

  did_eject_msg="not requested."
  # Eject when: success + (run completed normally OR user explicitly requested "Eject Now").
  # The eject_now flag is set by the UI button; it overrides the "stopped mid-run" abort.
  if [[ "$EJECT_ON_SUCCESS" == "1" && "$failed_copy" == "0" ]] \
     && { [[ "$run_stopped" == "0" ]] || [[ -f "$EJECT_NOW_FLAG" ]]; }; then
    wait_for_min_eject_grace "$volume_started_epoch"
    if keep_mounted_requested "$no_eject_hold_file"; then
      log "User requested no eject for ${vol_name}; leaving mounted."
      did_eject_msg="kept mounted."
      set_eject_status "kept"
      summary_kept_mounted_total=$((summary_kept_mounted_total + 1))
      if [[ -z "$summary_kept_mounted_volumes" ]]; then
        summary_kept_mounted_volumes="$vol_name"
      else
        summary_kept_mounted_volumes="${summary_kept_mounted_volumes}, ${vol_name}"
      fi
    elif diskutil_eject_with_timeout "$vol_path" "$vol_name"; then
      log "Ejected volume: ${vol_name}"
      did_eject_msg="card ejected."
      set_eject_status "ejected"
      ntfy_notify "card_ejected" "DDump: card ejected" "${vol_name}: card ejected after import."
    else
      log "Failed to eject volume: ${vol_name}; continuing with upload."
      did_eject_msg="could not eject card."
      set_eject_status "failed"
      summary_errors_total=$((summary_errors_total + 1))
    fi
  else
    set_eject_status "skipped"
  fi

  if [[ "$failed_copy" == "0" ]]; then
    # Re-organize imported files into bucket folders per FOLDER_NAMING_STRATEGY,
    # then queue the bucket folders for post-move.
    if [[ "$imported_this_volume" -gt 0 ]]; then
      notify "DDump" "📂 ${vol_name}: copy done (${imported_this_volume} files). Uploading to Drive..." info "upload_started"
      ntfy_notify "upload_started" "DDump: upload started" "${vol_name}: upload started for ${imported_this_volume} file(s)."
    fi
    rebucket_ok=1
    if ! rebucket_imported_files "$imported_files_file" "$dest_dir" "$post_move_queue_file"; then
      rebucket_ok=0
      status="partial"
      summary_errors_total=$((summary_errors_total + 1))
      bump_pending_retry "$pending_imports_file" "folder organization failed"
      notify "DDump" "⚠️ ${vol_name}: folder organization had errors; upload deferred." warn
    elif [[ -s "$post_move_queue_file" ]]; then
      record_pending_queue "$pending_imports_file" "$dest_dir" "$post_move_queue_file"
    fi

    if [[ "$rebucket_ok" == "1" && ! -s "$post_move_queue_file" ]]; then
      log "No post-transfer upload queued for ${vol_name}; skipping upload-complete notification."
    elif [[ "$rebucket_ok" == "1" ]] && move_queued_paths_to_post_target "$post_move_queue_file" "$vol_name" && [[ "$move_last_status" == "success" ]]; then
      # Where did the files land?
      friendly_target="$move_last_target"
      if [[ -z "$friendly_target" ]]; then
        friendly_target="$(effective_post_move_root)"
      fi
      write_upload_receipt "$vol_name" "success" "$friendly_target" "$post_move_queue_file"
      if path_uses_gdrive_mount "$friendly_target"; then
        friendly_target_short="${friendly_target#${GDRIVE_MOUNT_POINT%/}/}"
      else
        friendly_target_short="$friendly_target"
      fi
      /bin/rm -f "$pending_imports_file"
      notify "DDump" "✅ ${vol_name}: ${imported_this_volume} files uploaded to ${friendly_target_short}" done "upload_complete"
      upload_complete_volume_count=$((upload_complete_volume_count + 1))
      upload_complete_file_count=$((upload_complete_file_count + imported_this_volume))
      if [[ -z "$upload_complete_targets" ]]; then
        upload_complete_targets="$friendly_target_short"
      elif [[ "$upload_complete_targets" != *"$friendly_target_short"* ]]; then
        upload_complete_targets="${upload_complete_targets}; ${friendly_target_short}"
      fi
    else
      status="partial"
      if [[ "$rebucket_ok" == "1" ]]; then
        if [[ "$move_last_status" == "blocked" ]]; then
          summary_post_move_blocked_total=$((summary_post_move_blocked_total + 1))
        else
          summary_post_move_fail_total=$((summary_post_move_fail_total + 1))
        fi
        if [[ -n "$move_last_target" && -s "$post_move_queue_file" ]]; then
          write_upload_receipt "$vol_name" "partial" "$move_last_target" "$post_move_queue_file"
        fi
        bump_pending_retry "$pending_imports_file" "${move_last_detail:-upload failed}"
        summary_errors_total=$((summary_errors_total + 1))
        notify "DDump" "⚠️ ${vol_name}: upload to Drive failed (${move_last_detail})" warn
      fi
    fi
  else
    status="partial"
    notify "DDump" "⚠️ ${vol_name}: import had errors, card not ejected." warn
  fi
  if [[ "$failed_copy" == "0" && "$status" == "success" && "$imported_this_volume" -gt 0 ]]; then
    if ! verify_volume_upload_completeness "$uuid" "$vol_name"; then
      status="partial"
    fi
  fi
  /usr/bin/printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$run_timestamp" "$vol_name" "$uuid" "$imported_this_volume" "$skipped_existing_this_volume" "$skipped_extension_this_volume" "$status" >>"$RUN_HISTORY_FILE"
  log "Volume ${vol_name}: final_status=${status}, imported=${imported_this_volume}, skipped_known=${skipped_existing_this_volume}, skipped_ext=${skipped_extension_this_volume}, post_move=${move_last_status:-none}"
  check_card_almost_full_after_import "$vol_path" "$vol_name" "$imported_bytes_this_volume"
  if [[ -f "$pending_imports_file" && ! -s "$pending_imports_file" ]]; then
    /bin/rm -f "$pending_imports_file"
  fi
  /bin/rm -f "$manual_candidates_file"
  /bin/rm -f "$post_move_queue_file"
  /bin/rm -f "$imported_files_file"
  /bin/rm -f "$source_roots_file"
  /bin/rm -f "$no_eject_hold_file"
done

if [[ "$processed_volume_count" -eq 0 ]]; then
  log "No trusted SD card volumes found."
fi

summary_message="Run complete. volumes=${processed_volume_count}, imported=${imported_file_count_total}, skipped_duplicate=${summary_skipped_existing_total}, skipped_extension=${summary_skipped_extension_total}, copy_fail=${summary_copy_fail_total}, verify_fail=${summary_verify_fail_total}, upload_incomplete=${summary_upload_incomplete_total}, kept_mounted=${summary_kept_mounted_total}, post_move_blocked=${summary_post_move_blocked_total}, post_move_fail=${summary_post_move_fail_total}, errors=${summary_errors_total}"
log "$summary_message"
if [[ "$upload_complete_volume_count" -gt 0 && "$summary_errors_total" -eq 0 && "$run_stopped" != "1" ]]; then
  ntfy_notify "upload_complete" "DDump: dump complete" "${upload_complete_volume_count} card(s), ${upload_complete_file_count} file(s) copied to Backup Folder. ${upload_complete_targets}"
fi
if [[ "$processed_volume_count" -gt 0 && "$no_candidate_volume_count" -gt 0 ]]; then
  log "Volumes with no candidate files: ${no_candidate_volume_names}"
  if [[ "$imported_file_count_total" -eq 0 ]]; then
    ntfy_notify "integrity_warning" "DDump: no new files copied" "DDump checked ${processed_volume_count} card volume(s), but found no files in the scan window. Volumes: ${no_candidate_volume_names}."
  fi
fi
if [[ "$summary_copy_fail_total" -gt 0 || "$summary_verify_fail_total" -gt 0 ]]; then
  ntfy_notify "integrity_warning" "DDump: integrity warning" "Run finished with copy/verify issues. copy_fail=${summary_copy_fail_total}, verify_fail=${summary_verify_fail_total}."
fi
if [[ "${SLACK_NOTIFY_ON_COMPLETE:-0}" == "1" ]]; then
  slack_notify "DDump complete: ${summary_message}" || true
elif [[ "${SLACK_NOTIFY_ON_ERROR:-1}" == "1" && "$summary_errors_total" -gt 0 ]]; then
  slack_notify "DDump needs attention: ${summary_message}" || true
fi
run_status_for_db="success"
if [[ "$summary_errors_total" -gt 0 || "$run_stopped" == "1" ]]; then
  run_status_for_db="partial"
fi
db_exec "UPDATE import_runs SET completed_at=$(sql_quote "$(/bin/date '+%Y-%m-%d %H:%M:%S')"), status=$(sql_quote "$run_status_for_db"), volume_count=$processed_volume_count, imported_count=$imported_file_count_total, skipped_count=$summary_skipped_existing_total, error_count=$summary_errors_total, summary=$(sql_quote "$summary_message") WHERE run_id=$(sql_quote "$run_id");" >/dev/null || true
if [[ "$run_stopped" == "1" ]]; then
  set_status_phase "stopped" "$summary_message"
else
  set_status_phase "complete" "$summary_message"
fi

summary_open_path="$last_dest_dir"
if [[ -z "$summary_open_path" ]]; then
  summary_open_path="$DEST_ROOT"
fi
show_run_summary_dialog "$summary_message" "$summary_open_path"
kept_mounted_msg="${summary_kept_mounted_total}"
if [[ -n "$summary_kept_mounted_volumes" ]]; then
  kept_mounted_msg="${kept_mounted_msg} (${summary_kept_mounted_volumes})"
fi
finalize_empty_missed_report
write_daily_digest "$daily_digest_file" "$summary_message" "$kept_mounted_msg" "blocked=${summary_post_move_blocked_total}, failed=${summary_post_move_fail_total}" "$summary_errors_total"
stop_gdrive_mount_if_started
exit 0
