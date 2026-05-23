#!/bin/bash
set -euo pipefail

PATH="/usr/bin:/bin:/usr/sbin:/sbin"

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

log() {
  local msg="$1"
  /bin/echo "$(/bin/date '+%Y-%m-%d %H:%M:%S') ${msg}" | /usr/bin/tee -a "$LOG_FILE" >/dev/null
}

notify() {
  local title="$1"
  local msg="$2"
  local kind="${3:-info}"   # info | warn | done
  if [[ "${USE_NOTIFICATIONS:-1}" != "1" ]]; then
    # Legacy mode: fall back to old toggle.
    if [[ "${ENABLE_NOTIFICATIONS:-0}" != "1" ]]; then
      return
    fi
    /usr/bin/osascript -e "display notification \"${msg//\"/\\\"}\" with title \"${title//\"/\\\"}\"" >/dev/null 2>&1 || true
    return
  fi
  local notify_script="${APP_SUPPORT_DIR}/bin/ddump-notify.sh"
  if [[ -x "$notify_script" ]]; then
    DDUMP_NOTIFIER_TIMEOUT="${NOTIFICATION_TIMEOUT_SECONDS:-60}" \
      /bin/bash "$notify_script" "$kind" "$title" "$msg" >/dev/null 2>&1 || true
  else
    /usr/bin/osascript -e "display notification \"${msg//\"/\\\"}\" with title \"${title//\"/\\\"}\"" >/dev/null 2>&1 || true
  fi
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
  local topic="${NTFY_TOPIC:-}"
  [[ -n "$topic" ]] || return 0

  local enabled_key=""
  case "$event_key" in
    staging_started) enabled_key="${NTFY_NOTIFY_STAGING_STARTED:-0}" ;;
    card_ejected) enabled_key="${NTFY_NOTIFY_CARD_EJECTED:-1}" ;;
    upload_started) enabled_key="${NTFY_NOTIFY_UPLOAD_STARTED:-0}" ;;
    upload_complete) enabled_key="${NTFY_NOTIFY_UPLOAD_COMPLETE:-1}" ;;
    *) enabled_key="0" ;;
  esac
  [[ "$enabled_key" == "1" ]] || return 0

  local body
  body="$(printf '%s\n%s\n%s' "$title" "$event_key" "$text")"
  if ! /usr/bin/curl -fsS -m 10 \
    -H "Title: ${title}" \
    -H "Tags: camera" \
    --data-binary "$body" \
    "https://ntfy.sh/${topic}" >/dev/null 2>&1; then
    log "ntfy notification failed for event=${event_key} topic=${topic}"
    return 1
  fi
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

if ! /bin/mkdir "$LOCK_DIR" 2>/dev/null; then
  log "Another run is in progress; exiting."
  exit 0
fi
cleanup() {
  stop_finderserver_timer_guard 2>/dev/null || true
  /bin/rm -f "${PAUSE_FLAG:-}" "${STOP_AFTER_FILE_FLAG:-}" "${KEEP_MOUNTED_FLAG:-}" "${EJECT_NOW_FLAG:-}" 2>/dev/null || true
  /bin/rmdir "$LOCK_DIR" 2>/dev/null || true
}
trap cleanup EXIT

# Defaults (overridden by config.env then user config.env)
DEST_ROOT="$HOME/Temp"
LOOKBACK_HOURS="24"
CANDIDATE_MODE="lookback"
SOURCE_SUBDIR="DCIM"
TRUSTED_NAME_PREFIXES="DFP_"
PROMPT_TO_REMEMBER_UNKNOWN="1"
PROMPT_FOR_UNKNOWN_CARD_ACTION="1"
SKIP_INTERNAL_VOLUMES="1"
IGNORE_VOLUME_NAMES="Macintosh HD,Recovery"
IGNORE_NO_UUID_VOLUMES="1"
PROMPT_FOR_SOURCE_FOLDERS_ON_NEW_DRIVE="1"
CREATE_DAILY_FOLDER="1"
DAILY_FOLDER_FORMAT="%Y-%m-%d-ddump"
EJECT_ON_SUCCESS="1"
PROMPT_NO_EJECT_ON_START="0"
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
DB_ENABLED="1"
DB_FILE="${STATE_DIR}/ddump.sqlite3"
HASH_BEFORE_COPY="0"
UPLOAD_RETRY_MINUTES="3,10,60,240"
FILE_EXTENSIONS=""
MANIFEST_RETENTION_DAYS="0"
USE_FAST_SEEN_INDEX="1"
SOURCE_SUBDIR_FALLBACK_ON_EMPTY_SELECTION="1"
REQUIRE_PHOTOS_OR_TRUSTED="1"
PHOTO_FILE_EXTENSIONS="jpg,jpeg,heic,heif,cr2,cr3,nef,arw,raf,dng,rw2,orf,pef,srw,tif,tiff,mp4,mov,m4v,avi,mts,m2ts,3gp,3gpp,insv,insp,gpr"
VIDEO_FILE_EXTENSIONS="mp4,mov,m4v,avi,mts,m2ts,3gp,3gpp,insv,gpr"
PHOTO_RECENCY_HOURS="24"
ENABLE_POST_EJECT_MOVE="1"
POST_MOVE_ROOT=""
POST_MOVE_YEAR_FORMAT="%Y"
POST_MOVE_MONTH_FORMAT="%Y.%m"
POST_MOVE_DAY_FORMAT="%Y.%m.%d"
FOLDER_NAMING_STRATEGY="cluster"
FOLDER_NAMING_FALLBACK="cluster"
SMART_SAMPLE_PATH=""
SMART_ASSIGN_EXISTING_FOLDERS="1"
SPLIT_PHOTO_VIDEO="0"
FOLDER_NAME_SEQUENTIAL_PREFIX="DDump "
FOLDER_NAME_CUSTOM_VALUES=""
FOLDER_NAME_UNCATEGORIZED="Uncategorized"
CLUSTER_GAP_MINUTES="45"
CLUSTER_FOLDER_TEMPLATE="Cluster {n} {start}-{end}"
CALENDAR_NAME=""
CALENDAR_EVENT_PADDING_MIN="15"
TRUSTED_UUID_FILE="${STATE_DIR}/trusted_uuids.txt"
MANIFEST_FILE="${STATE_DIR}/imported_manifest.tsv"
RUN_HISTORY_FILE="${STATE_DIR}/run_history.tsv"
SOURCE_ROOTS_FILE="${STATE_DIR}/source_roots.tsv"
BLOCKED_UUID_FILE="${STATE_DIR}/blocked_uuids.txt"
CARD_POLICY_FILE="${STATE_DIR}/card_policy.tsv"
FAST_SEEN_FILE="${STATE_DIR}/fast_seen.tsv"
PENDING_DIR="${STATE_DIR}/pending_uploads"
STATUS_FILE="${STATE_DIR}/run_status.env"
CONTROL_DIR="${STATE_DIR}/control"
PAUSE_FLAG="${CONTROL_DIR}/pause.flag"
STOP_AFTER_FILE_FLAG="${CONTROL_DIR}/stop_after_file.flag"
KEEP_MOUNTED_FLAG="${CONTROL_DIR}/keep_mounted.flag"
EJECT_NOW_FLAG="${CONTROL_DIR}/eject_now.flag"
MANUAL_SELECTION_FILE="${DDUMP_MANUAL_SELECTION_FILE:-}"
MANUAL_SELECTION_SAFETY_GB="${DDUMP_MANUAL_SELECTION_SAFETY_GB:-2}"
FINDERSERVER_BIN="${HOME}/.local/bin/finderserver"
FINDERSERVER_TIMER_CHECK_SECONDS="300"
FINDERSERVER_TIMER_MIN_SECONDS="300"
FINDERSERVER_GUARD_PID_FILE="${STATE_DIR}/finderserver-guard.pid"
NTFY_TOPIC="dfp-chase-scheduler"
NTFY_NOTIFY_STAGING_STARTED="0"
NTFY_NOTIFY_CARD_EJECTED="1"
NTFY_NOTIFY_UPLOAD_STARTED="0"
NTFY_NOTIFY_UPLOAD_COMPLETE="1"

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

set_status_phase() {
  local phase="$1"
  local message="${2:-}"
  current_status_phase="$phase"
  current_status_message="$message"
  write_status
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

if [[ ! -d "$DEST_ROOT" ]]; then
  if /bin/mkdir -p "$DEST_ROOT"; then
    log "Created destination root: $DEST_ROOT"
  else
    log "Destination root is unavailable: $DEST_ROOT"
    notify "DDump" "Destination folder unavailable: $DEST_ROOT"
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
  if [[ "${FOLDER_NAMING_STRATEGY:-cluster}" == "smart" ]]; then
    local smart_root
    if smart_root="$(infer_smart_root_from_sample_path)"; then
      printf '%s' "$smart_root"
      return 0
    fi
  fi
  printf '%s' "$POST_MOVE_ROOT"
}

effective_video_post_move_root() {
  [[ "${FOLDER_NAMING_STRATEGY:-cluster}" == "smart" ]] || return 1
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

path_uses_gdrive_mount() {
  local path="$1"
  local gdrive="${HOME}/GoogleDrive"
  case "$path" in
    "$gdrive"|"$gdrive"/*) return 0 ;;
    *) return 1 ;;
  esac
}

gdrive_mount_active() {
  /sbin/mount | /usr/bin/grep -q " on ${HOME}/GoogleDrive "
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
  gdrive_mount_active && return 0

  local uid plist label mount_dir
  uid="$(/usr/bin/id -u)"
  plist="${HOME}/Library/LaunchAgents/com.chase.rclone-gdrive.plist"
  label="com.chase.rclone-gdrive"
  mount_dir="${HOME}/GoogleDrive"
  if [[ ! -f "$plist" ]]; then
    move_last_status="blocked"
    move_last_detail="Google Drive mount agent missing: ${plist}"
    return 1
  fi

  /bin/mkdir -p "$mount_dir"

  if finderserver_available; then
    if ! run_finderserver on >/dev/null 2>&1; then
      log "finderserver on failed; falling back to launchctl mount start."
    fi
  fi
  /bin/launchctl bootstrap "gui/${uid}" "$plist" >/dev/null 2>&1 || true
  /bin/launchctl kickstart -k "gui/${uid}/${label}" >/dev/null 2>&1 || true
  ddump_started_gdrive_mount=1

  local i
  for i in {1..30}; do
    if gdrive_mount_active; then
      refresh_finderserver_timer_if_low
      start_finderserver_timer_guard
      return 0
    fi
    /bin/sleep 1
  done

  move_last_status="blocked"
  move_last_detail="Google Drive mount did not become ready"
  return 1
}

stop_gdrive_mount_if_started() {
  [[ "${ddump_started_gdrive_mount:-0}" == "1" ]] || return 0
  stop_finderserver_timer_guard
  local uid label mount_dir
  uid="$(/usr/bin/id -u)"
  label="com.chase.rclone-gdrive"
  mount_dir="${HOME}/GoogleDrive"

  if gdrive_mount_active; then
    if /usr/sbin/diskutil unmount "$mount_dir" >/dev/null 2>&1; then
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

move_queued_paths_to_post_target() {
  local queue_file="$1"
  local vol_name="$2"
  move_last_status="none"
  move_last_detail=""
  move_last_target=""

  if [[ "$ENABLE_POST_EJECT_MOVE" != "1" ]]; then
    move_last_status="disabled"
    move_last_detail="post-move disabled"
    return 0
  fi

  if [[ ! -s "$queue_file" ]]; then
    move_last_status="empty"
    move_last_detail="nothing queued"
    return 0
  fi

  if ! ensure_gdrive_mount_for_post_move "$(effective_post_move_root)"; then
    log "Post-move blocked for ${vol_name}: ${move_last_detail}"
    notify "DDump" "${vol_name}: post-move blocked (${move_last_detail})."
    return 1
  fi

  if ! check_post_move_ready; then
    move_last_target="$(effective_post_move_root)"
    log "Post-move blocked for ${vol_name}: ${move_last_detail}"
    notify "DDump" "${vol_name}: post-move blocked (${move_last_detail})."
    return 1
  fi

  local target_dir video_target_dir split_video_enabled
  target_dir="$(build_post_move_target_dir)"
  split_video_enabled=0
  video_target_dir=""
  if [[ "${SPLIT_PHOTO_VIDEO:-0}" == "1" ]] && video_target_dir="$(build_video_post_move_target_dir)"; then
    split_video_enabled=1
  fi
  move_last_target="$target_dir"
  if ! /bin/mkdir -p "$target_dir"; then
    move_last_status="failed"
    move_last_detail="cannot create target dir: ${target_dir}"
    log "Post-move blocked for ${vol_name}: ${move_last_detail}"
    notify "DDump" "${vol_name}: post-move blocked (target unavailable)."
    return 1
  fi
  if ! check_directory_write_probe "$target_dir"; then
    move_last_status="blocked"
    move_last_detail="target dir not writable: ${target_dir}"
    log "Post-move blocked for ${vol_name}: ${move_last_detail}"
    notify "DDump" "${vol_name}: post-move blocked (target not writable)."
    return 1
  fi

  local moved_count=0
  local failed_count=0
  local src_path base_name dest_path
  while IFS= read -r src_path || [[ -n "$src_path" ]]; do
    [[ -n "$src_path" ]] || continue
    [[ -e "$src_path" ]] || continue

    base_name="$(basename "$src_path")"
    dest_path="${target_dir}/${base_name}"
    db_upsert_upload_job "$src_path" "$target_dir" "uploading" "0" "0" ""
    db_mark_media_status_by_local_prefix "$src_path" "upload_pending" ""

    if [[ "$split_video_enabled" != "1" ]] && queue_entry_already_uploaded "$src_path" "$target_dir"; then
      /bin/rm -rf "$src_path"
      db_update_upload_job_status "$src_path" "uploaded" "0" "0" "already complete on destination"
      db_mark_media_status_by_local_prefix "$src_path" "uploaded" ""
      moved_count=$((moved_count + 1))
      continue
    fi

    if [[ "$split_video_enabled" == "1" && -d "$src_path" ]]; then
      if copy_bucket_split_photo_video "$src_path" "$dest_path" "${video_target_dir}/${base_name}"; then
        /bin/rm -rf "$src_path"
        db_update_upload_job_status "$src_path" "uploaded" "0" "0" ""
        db_mark_media_status_by_local_prefix "$src_path" "uploaded" ""
        moved_count=$((moved_count + 1))
      else
        failed_count=$((failed_count + 1))
        db_update_upload_job_status "$src_path" "failed" "0" "0" "photo/video split copy failed"
        db_mark_media_status_by_local_prefix "$src_path" "organized" "photo/video split copy failed"
        log "Post-move failed (photo/video split): ${src_path}"
      fi
      continue
    fi

    if [[ -e "$dest_path" ]]; then
      # Merge into existing folder/file destination to avoid clobbering.
      if [[ -d "$src_path" && -d "$dest_path" ]]; then
        if copy_path_to_post_target "$src_path" "$dest_path"; then
          /bin/rm -rf "$src_path"
          db_update_upload_job_status "$src_path" "uploaded" "0" "0" ""
          db_mark_media_status_by_local_prefix "$src_path" "uploaded" ""
          moved_count=$((moved_count + 1))
        elif queue_entry_already_uploaded "$src_path" "$target_dir"; then
          /bin/rm -rf "$src_path"
          db_update_upload_job_status "$src_path" "uploaded" "0" "0" "verified after retry"
          db_mark_media_status_by_local_prefix "$src_path" "uploaded" ""
          moved_count=$((moved_count + 1))
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

    if copy_path_to_post_target "$src_path" "$dest_path"; then
      /bin/rm -rf "$src_path"
      db_update_upload_job_status "$src_path" "uploaded" "0" "0" ""
      db_mark_media_status_by_local_prefix "$src_path" "uploaded" ""
      moved_count=$((moved_count + 1))
    elif queue_entry_already_uploaded "$src_path" "$target_dir"; then
      /bin/rm -rf "$src_path"
      db_update_upload_job_status "$src_path" "uploaded" "0" "0" "verified after retry"
      db_mark_media_status_by_local_prefix "$src_path" "uploaded" ""
      moved_count=$((moved_count + 1))
    else
      failed_count=$((failed_count + 1))
      db_update_upload_job_status "$src_path" "failed" "0" "0" "copy to destination failed"
      db_mark_media_status_by_local_prefix "$src_path" "organized" "copy to destination failed"
      log "Post-move failed: ${src_path} -> ${dest_path}"
    fi
  done <"$queue_file"

  if [[ "$failed_count" -eq 0 ]]; then
    log "Post-move complete for ${vol_name}: moved=${moved_count}, target=${target_dir}"
    notify "DDump" "${vol_name}: moved ${moved_count} folder(s) to Google Drive."
    move_last_status="success"
    move_last_detail="moved=${moved_count}"
    return 0
  fi

  log "Post-move partial for ${vol_name}: moved=${moved_count}, failed=${failed_count}, target=${target_dir}"
  notify "DDump" "${vol_name}: post-move had ${failed_count} error(s)."
  move_last_status="partial"
  move_last_detail="moved=${moved_count}, failed=${failed_count}"
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
      /usr/bin/find "$normalized_path" -type f -print0 >>"$out_file" 2>/dev/null || true
      had_candidates=0
      continue
    fi

    if [[ -f "$normalized_path" ]]; then
      /usr/bin/printf '%s\0' "$normalized_path" >>"$out_file"
      had_candidates=0
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
  local probe_file
  [[ -n "$dir" && -d "$dir" ]] || return 1

  probe_file="${dir}/.ddump-write-test-${run_id}-$$"
  if /usr/bin/touch "$probe_file" 2>/dev/null; then
    /bin/rm -f "$probe_file" 2>/dev/null || true
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
  count="$(/usr/bin/sqlite3 "$DB_FILE" "PRAGMA busy_timeout=5000; SELECT COUNT(*) FROM media_files WHERE source_uuid=$(sql_quote "$uuid") AND source_root_rel=$(sql_quote "$root_rel") AND rel_path=$(sql_quote "$rel_path") AND source_size=$file_size AND source_mtime=$file_mtime AND status IN ('copied','organized','upload_pending','uploaded');" 2>>"$LOG_FILE" || echo 0)"
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
  count="$(/usr/bin/sqlite3 "$DB_FILE" "PRAGMA busy_timeout=5000; SELECT COUNT(*) FROM media_files WHERE source_uuid=$(sql_quote "$uuid") AND source_root_rel=$(sql_quote "$root_rel") AND rel_path=$(sql_quote "$rel_path") AND source_size=$file_size AND source_mtime=$file_mtime AND status IN ('copy_failed','verify_failed','needs_reinsert');" 2>>"$LOG_FILE" || echo 0)"
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
    log "Upload completeness check failed for ${vol_name}: ${incomplete_count} file(s) not confirmed on destination."
    notify "DDump" "⚠️ ${vol_name}: ${incomplete_count} file(s) not confirmed on server. Reinsert card to recover missing files." warn
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
  local prefix="${FOLDER_NAME_SEQUENTIAL_PREFIX:-Dump }"
  local n
  n="$(next_sequential_number "$dest_dir" "$prefix")"
  local bucket="${prefix}${n}"
  local f
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    printf '%s\t%s\n' "$f" "$bucket"
  done
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
      bucket="${tmpl//\{n\}/$cid}"
      bucket="${bucket//\{start\}/$start_hm}"
      bucket="${bucket//\{end\}/$end_hm}"
    fi
    printf '%s\t%s\n' "$file_path" "$bucket"
  done <"$cluster_out"

  rm -f "$imported_list" "$cluster_out"
}

existing_smart_bucket_for_index() {
  local index="$1"
  [[ "${SMART_ASSIGN_EXISTING_FOLDERS:-1}" == "1" ]] || return 1

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
  # cluster 2 to the second, etc. This lets DDump land in real Densley shoot
  # folders without hard-coding daily dates.
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
        bucket="${tmpl//\{n\}/$cid}"
        bucket="${bucket//\{start\}/$start_hm}"
        bucket="${bucket//\{end\}/$end_hm}"
      fi
    fi
    printf '%s\t%s\n' "$file_path" "$bucket"
  done <"$cluster_out"

  rm -f "$imported_list" "$cluster_out" "$cid_file"
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

epoch_date_ymd() {
  local epoch="$1"
  /bin/date -r "$epoch" '+%Y-%m-%d' 2>/dev/null \
    || /bin/date -d "@$epoch" '+%Y-%m-%d' 2>/dev/null \
    || true
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

compute_buckets_with_fallback() {
  local fallback="$1"
  local dest_dir="$2"
  case "$fallback" in
    sequential) compute_buckets_sequential "$dest_dir" ;;
    custom) compute_buckets_custom "$dest_dir" || compute_buckets_cluster "$dest_dir" ;;
    camera) compute_buckets_camera "$dest_dir" ;;
    cluster|*) compute_buckets_cluster "$dest_dir" ;;
  esac
}

compute_buckets_calendar() {
  local dest_dir="$1"
  local padding_min
  padding_min="$(sanitize_positive_int "${CALENDAR_EVENT_PADDING_MIN:-15}" "15")"

  local calendar_script="${APP_SUPPORT_DIR}/bin/ddump-calendar-lookup.sh"
  [[ -x "$calendar_script" ]] || return 1

  local imported_list file_times dates_file events_file matched_tsv unmatched_list fallback_tsv
  imported_list="$(mktemp "${STATE_DIR}/calendar-imported.${run_id}.XXXXXX")"
  file_times="$(mktemp "${STATE_DIR}/calendar-times.${run_id}.XXXXXX")"
  dates_file="$(mktemp "${STATE_DIR}/calendar-dates.${run_id}.XXXXXX")"
  events_file="$(mktemp "${STATE_DIR}/calendar-events.${run_id}.XXXXXX")"
  matched_tsv="$(mktemp "${STATE_DIR}/calendar-matched.${run_id}.XXXXXX")"
  unmatched_list="$(mktemp "${STATE_DIR}/calendar-unmatched.${run_id}.XXXXXX")"
  fallback_tsv="$(mktemp "${STATE_DIR}/calendar-fallback.${run_id}.XXXXXX")"
  cat >"$imported_list"

  local f epoch ymd
  while IFS= read -r f || [[ -n "$f" ]]; do
    [[ -f "$f" ]] || continue
    epoch="$(file_capture_epoch "$f")"
    if [[ -z "$epoch" ]]; then
      /bin/echo "$f" >>"$unmatched_list"
      continue
    fi
    ymd="$(epoch_date_ymd "$epoch")"
    if [[ -z "$ymd" ]]; then
      /bin/echo "$f" >>"$unmatched_list"
      continue
    fi
    /usr/bin/printf '%s\t%s\n' "$epoch" "$f" >>"$file_times"
    /bin/echo "$ymd" >>"$dates_file"
  done <"$imported_list"

  if [[ ! -s "$file_times" ]]; then
    rm -f "$imported_list" "$file_times" "$dates_file" "$events_file" "$matched_tsv" "$unmatched_list" "$fallback_tsv"
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
          epoch = $1
          path = $2
          best = ""
          best_span = 999999999
          for (i = 1; i <= n; i++) {
            if (epoch >= start[i] && epoch <= end[i]) {
              span = end[i] - start[i]
              if (span < best_span) {
                best = title[i]
                best_span = span
              }
            }
          }
          if (best != "") {
            print path, best
          } else {
            print path >> unmatched
          }
        }
      ' "$events_file" "$file_times" >"$matched_tsv"
  fi

  if [[ -s "$unmatched_list" ]]; then
    compute_buckets_with_fallback "${FOLDER_NAMING_FALLBACK:-cluster}" "$dest_dir" <"$unmatched_list" >"$fallback_tsv"
  fi

  if [[ ! -s "$matched_tsv" && ! -s "$fallback_tsv" ]]; then
    compute_buckets_cluster "$dest_dir" <"$imported_list"
  else
    cat "$matched_tsv" "$fallback_tsv"
  fi

  rm -f "$imported_list" "$file_times" "$dates_file" "$events_file" "$matched_tsv" "$unmatched_list" "$fallback_tsv"
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

rebucket_imported_files() {
  # Re-organize already-imported files in dest_dir into bucket folders per
  # FOLDER_NAMING_STRATEGY. Rewrites the post-move queue with the new bucket
  # folder paths. No-op for "camera" strategy.
  local imported_list="$1"
  local dest_dir="$2"
  local queue_file="$3"
  local strategy="${FOLDER_NAMING_STRATEGY:-cluster}"
  local fallback="${FOLDER_NAMING_FALLBACK:-cluster}"

  [[ -s "$imported_list" ]] || return 0
  if [[ "$strategy" == "camera" ]]; then
    return 0
  fi

  local bucket_tsv
  bucket_tsv="$(mktemp "${STATE_DIR}/buckets.${run_id}.XXXXXX")"

  local primary_ok=1
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
    *)
      log "Unknown FOLDER_NAMING_STRATEGY='$strategy'; keeping camera folders."
      rm -f "$bucket_tsv"
      return 0
      ;;
  esac

  if [[ "$primary_ok" -eq 0 ]]; then
    compute_buckets_with_fallback "$fallback" "$dest_dir" <"$imported_list" >"$bucket_tsv"
  fi

  if [[ ! -s "$bucket_tsv" ]]; then
    rm -f "$bucket_tsv"
    return 0
  fi

  : > "$queue_file"
  local bucket_set
  bucket_set="$(mktemp)"

  local src_path bucket_name bucket_dir base target stem ext n rebucket_failed
  rebucket_failed=0
  while IFS=$'\t' read -r src_path bucket_name; do
    [[ -z "$src_path" || -z "$bucket_name" ]] && continue
    [[ -f "$src_path" ]] || continue

    bucket_name="$(sanitize_bucket_name "$bucket_name")"
    bucket_dir="${dest_dir}/${bucket_name}"
    if ! /bin/mkdir -p "$bucket_dir"; then
      log "Rebucket failed: cannot create bucket dir ${bucket_dir}"
      rebucket_failed=$((rebucket_failed + 1))
      continue
    fi

    base="$(basename "$src_path")"
    target="${bucket_dir}/${base}"
    if [[ -e "$target" ]]; then
      stem="${base%.*}"
      ext="${base##*.}"
      n=1
      while [[ -e "${bucket_dir}/${stem}-${n}.${ext}" ]]; do
        n=$((n + 1))
      done
      target="${bucket_dir}/${stem}-${n}.${ext}"
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

  rm -f "$bucket_tsv" "$bucket_set"
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

recover_pending_imports() {
  local pending_file
  for pending_file in "$PENDING_DIR"/pending.*.tsv; do
    [[ -e "$pending_file" ]] || continue
    if [[ ! -s "$pending_file" ]]; then
      /bin/rm -f "$pending_file"
      continue
    fi

    local imported_list queue_file dest_dir row_dest row_file queued_mode pending_row_count missing_row_count not_due
    imported_list="$(/usr/bin/mktemp "${STATE_DIR}/recover-imported.${run_id}.XXXXXX")"
    queue_file="$(/usr/bin/mktemp "${STATE_DIR}/recover-queue.${run_id}.XXXXXX")"
    dest_dir=""
    queued_mode=0
    pending_row_count=0
    missing_row_count=0
    not_due=0

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
      if [[ "$row_next" =~ ^[0-9]+$ && "$row_next" -gt "$now_epoch" ]]; then
        not_due=1
        continue
      fi
      if [[ ! -e "$row_file" ]]; then
        missing_row_count=$((missing_row_count + 1))
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
        log "Pending recovery cannot continue because staged files are missing; reinsert the card if those files were not uploaded: ${pending_file}"
        notify "DDump" "Pending import files are missing. Reinsert the card so DDump can retry." warn
        bump_pending_retry "$pending_file" "local staged file missing; card reinsert needed"
      else
        log "Pending recovery had no existing files; clearing ${pending_file}."
        /bin/rm -f "$pending_file"
      fi
      /bin/rm -f "$imported_list" "$queue_file"
      continue
    fi

    log "Recovering pending staged files: ${pending_file}"
    if [[ "$queued_mode" -eq 1 ]] \
       || rebucket_imported_files "$imported_list" "$dest_dir" "$queue_file"; then
      :
    else
      log "Pending recovery rebucket failed; keeping ${pending_file} for next run."
      summary_errors_total=$((summary_errors_total + 1))
      bump_pending_retry "$pending_file" "rebucket failed"
      /bin/rm -f "$imported_list" "$queue_file"
      continue
    fi

    if move_queued_paths_to_post_target "$queue_file" "pending recovery"; then
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

recover_pending_imports

run_day_folder=""
if [[ "$CREATE_DAILY_FOLDER" == "1" ]]; then
  run_day_folder="$(/bin/date +"$DAILY_FOLDER_FORMAT")"
fi

processed_volume_count=0
imported_file_count_total=0
run_stopped=0

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
       && ! volume_has_photos "$vol_path"; then
    log "Skipping internal volume with no photos: ${vol_name}"
    continue
  fi

  # Silent-skip volumes that don't look like photo media: no photo files in the
  # first few directories, not trusted by UUID, and not name-prefixed. Prevents
  # popup/notification on every DMG installer, app mount, etc.
  vol_has_photos=0
  if volume_has_photos "$vol_path"; then
    vol_has_photos=1
  fi

  if [[ "$REQUIRE_PHOTOS_OR_TRUSTED" == "1" \
        && "$vol_has_photos" -ne 1 ]] \
     && ! is_trusted_name_prefix "$vol_name" \
     && ! is_uuid_trusted "$uuid"; then
    log "Silently skipping non-photo volume: ${vol_name} (no photo files, not trusted, no name prefix)"
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

  if is_trusted_name_prefix "$vol_name"; then
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
  volume_started_epoch="$(/bin/date '+%s')"
  no_eject_hold_file="${STATE_DIR}/hold-eject.${vol_name//[^A-Za-z0-9._-]/_}.flag"
  start_no_eject_prompt "$vol_name" "$no_eject_hold_file" &

  dest_dir="$DEST_ROOT"
  if [[ -n "$run_day_folder" ]]; then
    dest_dir="${DEST_ROOT}/${run_day_folder}"
  fi
  /bin/mkdir -p "$dest_dir"
  last_dest_dir="$dest_dir"
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
    notify "DDump" "📷 ${vol_name}: importing manual selection..." info
    ntfy_notify "staging_started" "DDump: staging started" "${vol_name}: manual-selection staging started."
  elif [[ "$vol_photo_total" =~ ^[0-9]+$ && "$vol_photo_total" -gt 0 ]]; then
    notify "DDump" "📷 ${vol_name}: scanning ${vol_photo_total} files (${vol_photo_recent} from last ${PHOTO_RECENCY_HOURS:-24}h)..." info
    ntfy_notify "staging_started" "DDump: staging started" "${vol_name}: staging started (detected ${vol_photo_total} files)."
  else
    notify "DDump" "📷 ${vol_name}: scanning..." info
    ntfy_notify "staging_started" "DDump: staging started" "${vol_name}: staging started."
  fi

  # Open the DDump app so the user sees a live progress window.
  if [[ -d "$HOME/Applications/DDump.app" ]]; then
    /usr/bin/open -g "$HOME/Applications/DDump.app" >/dev/null 2>&1 &
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

      file_size="$(/usr/bin/stat -f '%z' "$src_file")"
      file_mtime="$(/usr/bin/stat -f '%m' "$src_file")"
      rel_path="${src_file#"${source_root}/"}"
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

      if [[ -n "$uuid" ]] && db_file_has_local_copy "$uuid" "$source_root_rel" "$rel_path" "$file_size" "$file_mtime"; then
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

      if [[ "$USE_FAST_SEEN_INDEX" == "1" && -n "$uuid" ]] \
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

      safe_rel_path="${rel_path//:/_}"
      out_path="${dest_dir}/${safe_rel_path}"

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
      elif /usr/sbin/diskutil eject "$vol_path" >/dev/null 2>&1; then
        log "Ejected volume: ${vol_name}"
        ejected_msg="card ejected."
        ntfy_notify "card_ejected" "DDump: card ejected" "${vol_name}: card ejected after no-new-files check."
      else
        log "Failed to eject volume: ${vol_name}"
        ejected_msg="could not eject card."
        summary_errors_total=$((summary_errors_total + 1))
      fi
    fi
    notify "DDump" "${vol_name}: no new files, ${ejected_msg}" info
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
      summary_kept_mounted_total=$((summary_kept_mounted_total + 1))
      if [[ -z "$summary_kept_mounted_volumes" ]]; then
        summary_kept_mounted_volumes="$vol_name"
      else
        summary_kept_mounted_volumes="${summary_kept_mounted_volumes}, ${vol_name}"
      fi
    elif /usr/sbin/diskutil eject "$vol_path" >/dev/null 2>&1; then
      log "Ejected volume: ${vol_name}"
      did_eject_msg="card ejected."
      ntfy_notify "card_ejected" "DDump: card ejected" "${vol_name}: card ejected after import."
    else
      log "Failed to eject volume: ${vol_name}"
      failed_copy=1
      did_eject_msg="could not eject card."
      summary_errors_total=$((summary_errors_total + 1))
    fi
  fi

  if [[ "$failed_copy" == "0" ]]; then
    # Re-organize imported files into bucket folders per FOLDER_NAMING_STRATEGY,
    # then queue the bucket folders for post-move.
    if [[ "$imported_this_volume" -gt 0 ]]; then
      notify "DDump" "📂 ${vol_name}: copy done (${imported_this_volume} files). Uploading to Drive..." info
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

    if [[ "$rebucket_ok" == "1" ]] && move_queued_paths_to_post_target "$post_move_queue_file" "$vol_name"; then
      # Where did the files land?
      friendly_target="$move_last_target"
      if [[ -z "$friendly_target" ]]; then
        friendly_target="$(effective_post_move_root)"
      fi
      write_upload_receipt "$vol_name" "success" "$friendly_target" "$post_move_queue_file"
      friendly_target_short="${friendly_target##*/GoogleDrive/}"
      /bin/rm -f "$pending_imports_file"
      notify "DDump" "✅ ${vol_name}: ${imported_this_volume} files uploaded to ${friendly_target_short}" done
      ntfy_notify "upload_complete" "DDump: upload complete" "${vol_name}: uploaded ${imported_this_volume} file(s) to ${friendly_target_short}."
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

summary_message="Run complete. volumes=${processed_volume_count}, imported=${imported_file_count_total}, skipped_duplicate=${summary_skipped_existing_total}, skipped_extension=${summary_skipped_extension_total}, copy_fail=${summary_copy_fail_total}, verify_fail=${summary_verify_fail_total}, kept_mounted=${summary_kept_mounted_total}, post_move_blocked=${summary_post_move_blocked_total}, post_move_fail=${summary_post_move_fail_total}, errors=${summary_errors_total}"
log "$summary_message"
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
