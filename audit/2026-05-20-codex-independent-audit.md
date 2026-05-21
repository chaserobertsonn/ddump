# DDump v2 Independent Audit - 2026-05-20

Scope: source audit of `~/DFP-Coding/dump/`, focused on stability, speed, feature gaps, and dangerous edge cases. I could not verify the live Mac state from this Linux server session because the Mac-only paths under `~/Library/...` and `~/bin/rclone-gdrive-mount.sh` are not present here.

Definitions used below:

- Manifest: DDump's history file, `imported_manifest.tsv`, used to decide whether a file was already imported.
- Fast-seen index: DDump's shortcut file, `fast_seen.tsv`, used to skip hashing when the same card path, size, and modified time were already seen.
- Rebucket: DDump's step that moves copied files out of camera folders like `100EOSR7/` into user-facing folders like `Cluster 1 09:00-09:42/`.
- Mount: a cloud folder made to look like a local Finder folder. Here, rclone plus macFUSE makes Google Drive appear at `~/GoogleDrive`.
- VFS cache: rclone's local disk buffer that makes cloud files behave more like normal local files.

## Executive Summary

The main architecture is workable, but I would not call DDump ready for unattended daily use until two correctness fixes land:

1. Fix resumability before anything else. `bin/ddump.sh` records copied files in the manifest immediately at lines 1652-1655, but rebucketing only happens later at line 1758. If the run stops or crashes between those points, the next run skips those files and leaves them stranded in staging.
2. Fix `lookback` mode or hide it. `bin/ddump.sh` uses `find -newermt` at line 778, which is not normal macOS `find` syntax. Because the command is followed by `|| true`, this can silently create an empty candidate list.

For mount stability, keep the macFUSE rclone mount for Finder use, but consider making DDump uploads use direct `rclone copy` later. rclone's own docs say `sync/copy` can use retries more naturally than a mounted filesystem, while mounts need VFS caching to compensate. For Chase's Finder workflow, `--vfs-cache-mode full` is defensible. For pure upload-only DDump writes, `writes` mode or direct `rclone copy` is cleaner.

For speed, default `VERIFY_COPY_HASH=0` and keep size verification on. The pre-copy SHA-256 hash is still needed for global duplicate detection, but the post-copy SHA-256 hash is the avoidable third read of large video files. Keep hash verification as a "paranoid mode," not the default.

## Verification Performed

- Read the audit prompt, `SCOPE.md`, `config/config.env`, `bin/ddump.sh`, `bin/ddump-notify.sh`, `bin/ddump-cluster.sh`, `bin/ddump-calendar-lookup.sh`, `bin/install.sh`, and `app/DDumpApp.swift`.
- Ran `bash -n` against the main shell scripts: passed.
- Checked source ownership and permissions: all source files are owned by `chase:chase`; no source file under `dump/` is root-owned or world-writable.
- `shellcheck` is not installed in this session, so I could not run shell static analysis.
- `swiftc` is not installed in this Linux session, so I could not typecheck the Swift app here.
- Could not verify live Mac launch agents, current rclone mount, live config, or logs because those paths are not available from this server session.

Sources checked for rclone recommendations:

- Official rclone mount docs: https://rclone.org/commands/rclone_mount/
- Official rclone Google Drive/shared drive docs: https://rclone.org/drive/
- Official rclone WebDAV serving docs: https://rclone.org/commands/rclone_serve_webdav/

## Stability Findings

### 1. Resumability gap strands copied files in staging

Evidence:

- `bin/ddump.sh:1652-1656` records the import and fast-seen key immediately after local copy verification.
- `bin/ddump.sh:1752-1759` only rebuckets after the volume loop completes with `failed_copy=0`.
- `bin/ddump.sh:1561-1564` sets `run_stopped=1` when the user stops after a file.
- `bin/ddump.sh:1729-1730` allows eject on stopped runs only when the eject-now flag exists, but `bin/ddump.sh:1752` still skips rebucket/post-move whenever `failed_copy != 0`; stopped runs avoid this block because the code path does not explicitly recover partially copied files.

Impact:

Files copied before a stop, eject, crash, or killed process can stay in `~/Temp/YYYY-MM-DD-dump/<camera folder>/`. On reinsertion, DDump can skip them because the manifest/fast-seen records already exist.

Recommended fix:

Add a durable pending-import queue. The queue is just a small state file saying, "these copied files still need rebucket/post-move." On startup, process pending queues before scanning cards. Do not delete the queue until rebucket and post-move have been attempted.

Drop-in shape for `bin/ddump.sh`:

```bash
PENDING_DIR="${STATE_DIR}/pending"
mkdir -p "$PENDING_DIR"

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
  /usr/bin/printf '%s\t%s\n' "$dest_dir" "$copied_file" >>"$pending_file"
}

recover_pending_imports() {
  local pending_file dest_dir copied_file imported_list queue_file
  for pending_file in "$PENDING_DIR"/*.tsv; do
    [[ -s "$pending_file" ]] || continue

    dest_dir=""
    imported_list="$(/usr/bin/mktemp "${STATE_DIR}/recover-imported.${run_id}.XXXXXX")"
    queue_file="$(/usr/bin/mktemp "${STATE_DIR}/recover-queue.${run_id}.XXXXXX")"

    while IFS=$'\t' read -r row_dest row_file || [[ -n "$row_dest$row_file" ]]; do
      [[ -n "$row_dest" && -n "$row_file" ]] || continue
      [[ -f "$row_file" ]] || continue
      dest_dir="$row_dest"
      /bin/echo "$row_file" >>"$imported_list"
    done <"$pending_file"

    if [[ -n "$dest_dir" && -s "$imported_list" ]]; then
      log "Recovering pending staged files from ${pending_file}"
      rebucket_imported_files "$imported_list" "$dest_dir" "$queue_file"
      if move_queued_paths_to_post_target "$queue_file" "pending recovery"; then
        /bin/rm -f "$pending_file"
      else
        log "Pending recovery incomplete; keeping ${pending_file} for next run."
      fi
    else
      /bin/rm -f "$pending_file"
    fi

    /bin/rm -f "$imported_list" "$queue_file"
  done
}
```

Wire it like this:

```bash
# After folder-naming helpers are defined and before scanning /Volumes/*:
recover_pending_imports

# After post_move_queue_file/imported_files_file are created:
pending_key="$(pending_key_for_volume "$uuid" "$vol_name")"
pending_imports_file="${PENDING_DIR}/${pending_key}.tsv"

# After successful copy verification, before or right after record_import:
record_pending_import "$pending_imports_file" "$dest_dir" "$out_path"
/bin/echo "$out_path" >>"$imported_files_file"

# Only after rebucket + post-move attempt succeeds:
/bin/rm -f "$pending_imports_file"
```

This is the minimum reliable pattern. It is a two-phase workflow: first make the local copy durable, then make the bucket/upload step durable, then clear the pending state.

### 2. `find -newermt` makes lookback mode unsafe on macOS

Evidence:

- `bin/ddump.sh:773-783` implements candidate discovery.
- `bin/ddump.sh:778` uses `/usr/bin/find "$source_root" -type f -newermt "-${LOOKBACK_HOURS} hours"`.

Impact:

`-newermt` is common on GNU/Linux, but not normal macOS/BSD `find`. On the Mac, selecting "Only last N hours" in the UI can produce no files, and `|| true` hides the failure.

Recommended replacement:

```bash
find_candidates() {
  local source_root="$1"
  local out_file="$2"

  case "$CANDIDATE_MODE" in
    all)
      /usr/bin/find "$source_root" -type f -print0 >"$out_file" || true
      ;;
    lookback)
      local hours
      hours="$(sanitize_positive_int "${LOOKBACK_HOURS:-24}" "24")"
      # macOS/BSD find uses -mtime in days, not hours. Use Perl for exact hour cutoff.
      /usr/bin/find "$source_root" -type f -print0 2>/dev/null \
        | /usr/bin/perl -0ne 'BEGIN { $cutoff = time - (shift @ARGV) * 3600 } chomp; print $_, "\0" if -f $_ && (stat($_))[9] >= $cutoff' "$hours" \
        >"$out_file" || true
      ;;
    *)
      log "Invalid CANDIDATE_MODE='${CANDIDATE_MODE}'. Expected 'all' or 'lookback'. Falling back to 'all'."
      /usr/bin/find "$source_root" -type f -print0 >"$out_file" || true
      ;;
  esac
}
```

If you do not want Perl, use `touch -t` to create a cutoff file and BSD `find -newer cutofffile`.

### 3. Rebucket failures can kill the whole script mid-cleanup

Evidence:

- `bin/ddump.sh:1369` creates a bucket folder without checking failure.
- `bin/ddump.sh:1383` runs `/bin/mv "$src_path" "$target"` without an `if`; under `set -e`, one move failure exits the whole script.
- `bin/ddump.sh:1387` replaces the post-move queue only after all moves finish.

Impact:

A single bad filename, permission problem, or transient filesystem problem can leave files half moved and the queue incomplete. The script may exit before final status, digest, cleanup, or notification.

Recommended change:

Make rebucket best-effort per file, count failures, and leave failed files in the pending queue from finding 1.

```bash
local rebucket_failed=0

if ! /bin/mkdir -p "$bucket_dir"; then
  log "Rebucket failed: cannot create bucket dir ${bucket_dir}"
  rebucket_failed=$((rebucket_failed + 1))
  continue
fi

if /bin/mv "$src_path" "$target"; then
  /bin/echo "$bucket_dir" >>"$bucket_set"
else
  log "Rebucket failed: ${src_path} -> ${target}"
  rebucket_failed=$((rebucket_failed + 1))
fi

# After the loop:
if [[ "$rebucket_failed" -gt 0 ]]; then
  log "Rebucket completed with ${rebucket_failed} failed file move(s)."
  return 1
fi
```

### 4. `--allow-non-empty` is convenient but dangerous as a normal mount flag

Evidence:

- The audit prompt's mount command includes `--allow-non-empty`.

Impact:

If `~/GoogleDrive` contains real local files because a previous mount failed or someone accidentally copied files there while unmounted, `--allow-non-empty` allows rclone to mount over those files. They become hidden under the mount. That can create confusion about whether files are local-only or truly in Google Drive.

Recommended change:

Do not use `--allow-non-empty` as the default. In the mount script, explicitly inspect the mountpoint and abort if it has unexpected local contents.

```bash
MOUNTPOINT="$HOME/GoogleDrive"
mkdir -p "$MOUNTPOINT"

if /sbin/mount | /usr/bin/grep -q " on ${MOUNTPOINT} "; then
  /sbin/umount "$MOUNTPOINT" 2>/dev/null || /usr/sbin/diskutil unmount force "$MOUNTPOINT" || exit 1
fi

if /usr/bin/find "$MOUNTPOINT" -mindepth 1 -maxdepth 1 \
  ! -name '.DS_Store' ! -name '.localized' -print -quit | /usr/bin/grep -q .; then
  echo "Refusing to mount over non-empty ${MOUNTPOINT}; inspect local files first." >&2
  exit 1
fi

exec "$HOME/bin/rclone" mount combined: "$MOUNTPOINT" \
  --vfs-cache-mode full \
  --cache-dir "$HOME/Library/Caches/rclone-google-drive" \
  --volname "GoogleDrive" \
  --noapplexattr \
  --noappledouble
```

### 5. Source config writing is not shell-safe for unusual characters

Evidence:

- `app/DDumpApp.swift:59-78` writes `KEY="value"` directly.
- `bin/ddump.sh:214-221` later sources those files as shell code.

Impact:

If a setting value contains a double quote, backslash, dollar sign, or backtick, the config file can become invalid shell or unexpectedly expand when sourced. This is most likely with custom folder names, Slack URLs, or calendar names copied from somewhere else.

Recommended Swift replacement:

```swift
func shellDoubleQuoted(_ value: String) -> String {
  var out = ""
  for ch in value {
    switch ch {
    case "\\": out += "\\\\"
    case "\"": out += "\\\""
    case "$": out += "\\$"
    case "`": out += "\\`"
    case "\n": out += " "
    default: out.append(ch)
    }
  }
  return "\"\(out)\""
}

// In writeShellConfig:
lines[i] = "\(key)=\(shellDoubleQuoted(value))"
// And when appending:
lines.append("\(key)=\(shellDoubleQuoted(value))")
```

### 6. Calendar auth check can freeze the app

Evidence:

- `app/DDumpApp.swift:744-758` runs `gcalcli list` synchronously and waits with `task.waitUntilExit()`.

Impact:

If `gcalcli` hangs, prompts OAuth, or waits on network, the settings sheet can freeze.

Recommended change:

Run it asynchronously with a short timeout. The "Authorize" button should open Terminal with instructions instead of running `gcalcli list` inside the app process.

### 7. Native Settings scene is still present despite the sheet workaround

Evidence:

- The reliable sheet is at `app/DDumpApp.swift:317-320`.
- A SwiftUI `Settings { ... }` scene still exists at `app/DDumpApp.swift:937-939`.
- The comment at `app/DDumpApp.swift:934-935` says SwiftUI auto-binds Cmd+, even though the audit prompt says that path was unreliable on this Mac.

Impact:

The toolbar button may open the reliable sheet, but app-menu Settings/Cmd+, can still route through the unreliable native Settings scene. This can reintroduce the exact behavior the workaround was meant to avoid.

Recommended change:

Remove the `Settings { ... }` scene until it is deliberately fixed, or add an app-level command that toggles the same `showingSettings` sheet. Do not leave two competing settings paths.

## Mount Stability Recommendations

### macFUSE vs separate mounts

Keep macFUSE. Do not go back to `rclone nfsmount`; the prompt says it already failed under real Finder load.

For `combine` vs separate mounts:

- Keep the combined mount if Chase actively wants `MyDrive`, `Densley`, and `Kaizen` in one Finder tree.
- For DDump's production upload path, prefer the narrowest stable target. If DDump only writes to Densley, a dedicated `dfp:` mount at `~/GoogleDrive-Densley` reduces root-listing overhead and isolates failures from MyDrive/Kaizen.
- Do not create three mounts just for neatness. More mounts means more launch agent state, more cache directories, and more failure surfaces.

Official rclone docs show shared drives can be exposed through aliases and a `combine` remote, so the current shape is legitimate. The tradeoff is operational simplicity versus isolation.

### Current rclone flags

The current flags are mostly sensible for Finder plus large photo/video workflows:

- `--vfs-cache-mode full`: good for Finder stability and previews. Official docs say `writes` and `full` support normal filesystem operations; `full` also buffers reads.
- `--vfs-cache-max-size 30G`: acceptable but tight if Chase imports 50GB of video and then previews files in Finder. Consider 75-100GB if local disk has room.
- `--transfers 8` and `--checkers 16`: reasonable for Google Drive, but if Drive throttles or Finder feels laggy, try `--transfers 4 --checkers 8`.
- `--drive-chunk-size 64M`: reasonable for large uploads.
- Add an explicit `--cache-dir "$HOME/Library/Caches/rclone-google-drive"`. Official docs warn not to share the same VFS cache between overlapping remotes.

For DDump specifically, the most reliable upload path is eventually direct `rclone copy`/`rclone move`, not copying into a mount. Official rclone docs explicitly note that `sync/copy` handles cloud retry behavior better than a mounted filesystem. Keep the mount for Finder; consider direct rclone for DDump upload once the core correctness bugs are fixed.

### Plan B for macFUSE deprecation

Best fallback order:

1. `rclone serve webdav combined:` bound to localhost, mounted through macOS's built-in WebDAV client. This avoids macFUSE but is usually slower and less Finder-native.
2. Direct `rclone copy`/`move` for DDump uploads, with no Finder mount dependency. This solves DDump even if Finder browsing remains less nice.
3. A normal SMB share from a local helper machine is not attractive here because the data still has to reach Google Drive; it adds another moving part.
4. Do not return to `rclone nfsmount` for Chase's daily Finder workflow because it already produced connection-interrupted alerts.

## Speed Findings

### 1. Post-copy SHA-256 should default off

Evidence:

- `config/config.env:173-174` defaults both `VERIFY_COPIED_FILES` and `VERIFY_COPY_HASH` to `1`.
- `bin/ddump.sh:1598-1599` hashes the source file before copy.
- `bin/ddump.sh:596-603` hashes the destination file after copy when `VERIFY_COPY_HASH=1`.
- `bin/ddump.sh:1636-1650` verifies every copied file.

Impact:

A new file is read once for source hash, once for copy, and once again for destination hash. Large MP4/MOV files pay heavily for the third read.

Recommended default:

```bash
VERIFY_COPIED_FILES="1"
VERIFY_COPY_HASH="0"
```

Keep size verification on. Offer `VERIFY_COPY_HASH=1` as a paranoid mode for bad cards, suspect readers, or one-off validation.

### 2. The existing fast-seen index is already the safe mtime+size fast path

Evidence:

- `bin/ddump.sh:1144-1151` checks UUID, source root, relative path, file size, and mtime.
- `bin/ddump.sh:1586-1596` skips hashing/copying when that fast-seen key exists.

Recommendation:

Do not add a broad "trust mtime+size if any manifest entry matches" mode. That would be too collision-prone across cards and cameras. The current same-card/same-path/same-size/same-mtime key is the right risk boundary.

If you want this configurable, expose it honestly:

```bash
FAST_SEEN_TRUST_MODE="same_card_path"  # off | same_card_path
```

Avoid a global `size+mtime` trust mode.

### 3. `--vfs-cache-mode writes` is faster for upload-only, but not necessarily for Finder

Official rclone docs say `writes` buffers write-only/read-write files to disk and supports normal filesystem operations; `full` additionally buffers reads. For DDump's upload-only writes, `writes` is enough. For Chase organizing in Finder, `full` is safer because previews and metadata reads can reuse cache.

Recommendation:

- Keep `full` on the Finder mount for now.
- If DDump remains mount-based, test `writes` only after the real-card import path is stable.
- Better long-term: DDump uploads through direct `rclone copy`, while Finder keeps the `full` mount.

## Feature Implementations

### 1. Calendar bucketing

Current evidence:

- `bin/ddump.sh:1329-1332` logs that calendar is not wired and falls back.
- `bin/ddump-calendar-lookup.sh:63-74` emits `start_epoch end_epoch title` rows.
- `bin/ddump-cluster.sh:55-80` already has the EXIF/mtime capture-time logic, but it does not emit per-file epoch directly.

Recommended helper functions for `bin/ddump.sh`:

```bash
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
    || /bin/date -d "@$epoch" '+%Y-%m-%d' 2>/dev/null
}

compute_buckets_calendar() {
  local dest_dir="$1"
  local padding_min
  padding_min="$(sanitize_positive_int "${CALENDAR_EVENT_PADDING_MIN:-15}" "15")"

  local calendar_script="${APP_SUPPORT_DIR}/bin/ddump-calendar-lookup.sh"
  [[ -x "$calendar_script" ]] || return 1

  local imported_list file_times dates_file events_file matched_tsv unmatched_list fallback_tsv
  imported_list="$(/usr/bin/mktemp "${STATE_DIR}/calendar-imported.${run_id}.XXXXXX")"
  file_times="$(/usr/bin/mktemp "${STATE_DIR}/calendar-times.${run_id}.XXXXXX")"
  dates_file="$(/usr/bin/mktemp "${STATE_DIR}/calendar-dates.${run_id}.XXXXXX")"
  events_file="$(/usr/bin/mktemp "${STATE_DIR}/calendar-events.${run_id}.XXXXXX")"
  matched_tsv="$(/usr/bin/mktemp "${STATE_DIR}/calendar-matched.${run_id}.XXXXXX")"
  unmatched_list="$(/usr/bin/mktemp "${STATE_DIR}/calendar-unmatched.${run_id}.XXXXXX")"
  fallback_tsv="$(/usr/bin/mktemp "${STATE_DIR}/calendar-fallback.${run_id}.XXXXXX")"

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
    [[ -n "$ymd" ]] || { /bin/echo "$f" >>"$unmatched_list"; continue; }
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

  if [[ ! -s "$events_file" ]]; then
    compute_buckets_cluster "$dest_dir" <"$imported_list"
    rm -f "$imported_list" "$file_times" "$dates_file" "$events_file" "$matched_tsv" "$unmatched_list" "$fallback_tsv"
    return 0
  fi

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

  if [[ -s "$unmatched_list" ]]; then
    case "${FOLDER_NAMING_FALLBACK:-cluster}" in
      sequential) compute_buckets_sequential "$dest_dir" <"$unmatched_list" >"$fallback_tsv" ;;
      custom) compute_buckets_custom "$dest_dir" <"$unmatched_list" >"$fallback_tsv" || compute_buckets_cluster "$dest_dir" <"$unmatched_list" >"$fallback_tsv" ;;
      camera) : >"$fallback_tsv" ;;
      cluster|*) compute_buckets_cluster "$dest_dir" <"$unmatched_list" >"$fallback_tsv" ;;
    esac
  fi

  cat "$matched_tsv" "$fallback_tsv"
  rm -f "$imported_list" "$file_times" "$dates_file" "$events_file" "$matched_tsv" "$unmatched_list" "$fallback_tsv"
}
```

Wire it into `rebucket_imported_files`:

```bash
calendar)
  compute_buckets_calendar "$dest_dir" <"$imported_list" >"$bucket_tsv" || primary_ok=0
  ;;
```

One improvement to `bin/ddump-calendar-lookup.sh`: handle all-day events. If `s_time` or `e_time` is blank, treat the event as `00:00` to `23:59` local time before converting to epochs.

### 2. Resumability

Implement the durable pending queue from stability finding 1. That is the clean fix. Do not rely on a best-effort cleanup scan of `~/Temp`; state needs to be explicit so DDump knows exactly which files it owns.

Required behavior after the fix:

- Stop after this file: copied files are rebucketed/uploaded on this run or the next run.
- Crash after copy: next launch sees pending files and recovers them before scanning cards.
- Post-move blocked because Google Drive is unavailable: pending queue stays and retries next run.
- Already-imported files are not silently stranded.

### 3. Slack completion notification

Add config keys to `config/config.env` and `bin/install.sh`:

```bash
SLACK_WEBHOOK_URL=""
SLACK_NOTIFY_ON_COMPLETE="0"
SLACK_NOTIFY_ON_ERROR="1"
```

Add functions to `bin/ddump.sh`:

```bash
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  printf '%s' "$s"
}

slack_notify() {
  local text="$1"
  local webhook="${SLACK_WEBHOOK_URL:-}"
  [[ -n "$webhook" ]] || return 0

  local escaped payload
  escaped="$(json_escape "$text")"
  payload="{\"text\":\"${escaped}\"}"

  if ! /usr/bin/curl -fsS -m 10 \
    -H 'Content-Type: application/json' \
    --data "$payload" \
    "$webhook" >/dev/null 2>&1; then
    log "Slack notification failed."
    return 1
  fi
}
```

Plug it in at the end of `bin/ddump.sh`, right after `summary_message` is built at line 1790:

```bash
if [[ "${SLACK_NOTIFY_ON_COMPLETE:-0}" == "1" ]]; then
  slack_notify "DDump complete: ${summary_message}" || true
elif [[ "${SLACK_NOTIFY_ON_ERROR:-1}" == "1" && "$summary_errors_total" -gt 0 ]]; then
  slack_notify "DDump needs attention: ${summary_message}" || true
fi
```

Do not put the Slack URL in logs. Treat it like a password because anyone with the URL can post into that Slack channel.

## Dangerous Edge Cases

### 1. Bucket-name sanitation is too narrow

Evidence:

- `bin/ddump.sh:1367` only replaces `/` and `:`.

Impact:

Calendar titles can contain newlines, tabs, leading/trailing spaces, emoji, very long names, or reserved names like `.` / `..`. Most of these are allowed in some places but create bad Finder/Drive behavior.

Recommended helper:

```bash
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

  # Keep under a conservative Finder-safe length.
  printf '%.180s' "$cleaned"
}
```

Replace line 1367 with:

```bash
bucket_name="$(sanitize_bucket_name "$bucket_name")"
```

### 2. Post-move merge can hide partial upload failures

Evidence:

- `bin/ddump.sh:485-499` merges into an existing destination folder with `rsync -a`, then deletes the source folder with `rm -rf` if rsync exits successfully.

Impact:

`rsync -a` to a cloud-backed mount can report success once data is accepted by the local VFS cache, not necessarily once Google Drive has fully committed it. This is another reason direct `rclone copy` is better for DDump uploads.

Recommended short-term change:

After `rsync -a`, verify file counts and byte counts before deleting source.

Recommended long-term change:

Use direct `rclone copy`/`rclone move` for DDump post-move, with rclone logs and retries, and keep the Finder mount separate.

### 3. `count_recent_photos_on_volume` is approximate

Evidence:

- `bin/ddump.sh:129-130` uses `-mtime -$(( recent_hours / 24 + 1 ))`.

Impact:

For `PHOTO_RECENCY_HOURS=24`, this counts files from roughly the last two days. This only affects notification wording, not import correctness.

Recommended change:

Use the same exact-hour Perl cutoff pattern as the lookback fix.

### 4. Install output is stale about terminal-notifier action buttons

Evidence:

- `bin/install.sh:161-171` still says terminal-notifier enables button notifications.
- `bin/ddump-notify.sh:42-52` intentionally forces osascript for all notification modes.

Impact:

Not a runtime bug, but it misleads the next person maintaining the app.

Recommended change:

Update install output to say plain notifications use osascript, and action prompts intentionally use AppleScript dialogs because `terminal-notifier -actions` can hang.

### 5. Source permissions look safe; live permissions were not verified

Evidence:

- Source tree under `~/DFP-Coding/dump/` is owned by `chase:chase` and not world-writable.
- The live Mac paths were unavailable from this session.

Recommendation:

On the Mac, run:

```bash
find "$HOME/Library/Application Support/DDump" "$HOME/Applications/DDump.app" "$HOME/bin/rclone-gdrive-mount.sh" \
  -maxdepth 3 -printf '%M %u:%g %p\n'
```

If macOS `find` lacks `-printf`, use:

```bash
stat -f '%Sp %Su:%Sg %N' "$HOME/Library/Application Support/DDump" "$HOME/Applications/DDump.app" "$HOME/bin/rclone-gdrive-mount.sh"
```

## Recommended Order Of Work

1. Fix the durable pending-import queue.
2. Fix or hide lookback mode.
3. Change default post-copy hash verification to off, while keeping size verification on.
4. Add calendar bucketing.
5. Harden bucket-name sanitation and rebucket error handling.
6. Add Slack notifications.
7. Revisit direct `rclone copy` for post-move after the above is stable.
8. Only after real-card testing, decide whether the combined mount is stable enough or DDump should use a dedicated Densley mount/direct remote.

## Summary

DDump is close, but the current source still has one serious correctness bug: copied files can be marked imported before they are rebucketed/uploaded, so interrupted runs can strand files in staging forever. The second actionable bug is `lookback` mode using Linux-only `find -newermt` on a Mac app. The mount setup is directionally right for Finder if macFUSE remains available, but DDump's own upload step would be more reliable long-term through direct `rclone copy`/`move`. Calendar bucketing can be added cleanly with per-file capture epochs plus gcalcli event windows. Slack notifications are straightforward, but the webhook URL must be treated like a password. Do not go live for daily unattended use until resumability is fixed and tested with a real card interruption/reinsert cycle.
