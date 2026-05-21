# DDump Mac-Side Audit - 2026-05-20

Scope: read-only live audit over SSH to Chase's MacBook Pro. This checks what is actually running on the Mac, not just what the server-side source says.

Jargon used below:

- LaunchAgent: a macOS background job definition. In plain English, this is how macOS knows to start DDump on card mount and keep rclone running.
- Mount: a cloud folder made to appear as a local Finder folder. Here, rclone plus macFUSE makes Google Drive appear at `~/GoogleDrive`.
- rclone: the tool doing Google Drive access.
- macFUSE: the Mac filesystem bridge that lets rclone show Google Drive as a Finder folder.
- VFS cache: rclone's local disk buffer. It temporarily stores cloud files so Finder operations behave more like normal local files.
- Manifest: DDump's import history file. If a file is in the manifest, DDump treats it as already imported.

## Executive Summary

The Mac is currently running the new macFUSE rclone mount, and DDump's installed scripts match the server source. The live system is not healthy enough for real daily use yet.

Critical findings:

1. DDump copied real card files locally, then failed to upload them to the rclone-mounted Google Drive folder. There are now 51 GB and 1,323 files stranded at `~/Temp/2026-05-19-dump`.
2. The laptop has only about 49 GB free, so another large import can hit "No space left on device" again.
3. DDump logged the Red-card runs as `success` in `run_history.tsv` even though post-move failed later. That makes the run history misleading.
4. `exiftool` is not installed, so cluster grouping is using file modified times, not actual camera capture times.
5. The rclone mount currently works, but the logs show prior NFS restarts, `.DS_Store` upload retry loops, and a Google Drive API quota warning. The mount should be treated as still under test.

Do not switch `POST_MOVE_ROOT` to the production Densley path until the post-move failure is fixed and the stranded 51 GB is either safely uploaded or intentionally cleaned up.

## Live State Verified

Mac identity:

- Hostname: `MacBookPro.home`
- User: `chaserobertson`
- macOS: `26.5`, build `25F71`
- Architecture: `arm64`

DDump LaunchAgent:

- `com.ddump` is loaded at `/Users/chaserobertson/Library/LaunchAgents/com.ddump.plist`.
- State at audit time: not running. This is normal between card-mount events.
- It has `RunAtLoad=true` and `StartOnMount=true`.
- Last exit code: `0`.
- Run count: `27`.

rclone LaunchAgent:

- `com.chase.rclone-gdrive` is loaded at `/Users/chaserobertson/Library/LaunchAgents/com.chase.rclone-gdrive.plist`.
- State at audit time: running.
- PID at audit time: `70076`.
- Run count: `3`.
- Previous exit code: `143`, which means it was terminated and restarted.

Google Drive mount:

- Current mount line: `combined: on /Users/chaserobertson/GoogleDrive (macfuse, nodev, nosuid, synchronous, mounted by chaserobertson)`.
- Root folders visible: `Densley`, `Kaizen`, `MyDrive`.
- rclone remote-control stats showed no queued uploads and no errored files at audit time.
- VFS cache path: `/Users/chaserobertson/Library/Caches/rclone/vfs/combined`.
- VFS cache size at audit time: about 3.3 GB.

Versions:

- Official `~/bin/rclone`: `v1.74.1`, Go tags include `cmount`.
- Homebrew `/opt/homebrew/bin/rclone`: `v1.74.1`, Go tags show `none`.
- macFUSE kernel extension loaded: `io.macfuse.filesystems.macfuse.25 (5.1.3)`.

Installed source parity:

- Installed `ddump.sh`, `ddump-cluster.sh`, `ddump-calendar-lookup.sh`, and `ddump-notify.sh` match the server workspace copies by SHA-256 checksum.
- Shell syntax check passed for installed DDump scripts.

Dependencies:

- `exiftool`: missing.
- `gcalcli`: missing.
- `terminal-notifier`: missing.
- `alerter`: missing.
- `osascript`: present.
- `swiftc`: present.
- `iconutil`: present.

Permissions:

- DDump app support folder, scripts, state folder, config, launch agents, rclone script, rclone binary, `~/GoogleDrive`, and `~/Temp` are owned by `chaserobertson:staff`.
- No world-writable files were found under `~/Library/Application Support/DDump`.

## Findings

### 1. Real post-move failure left 51 GB stranded locally

Evidence:

- `~/Library/Application Support/DDump/logs/ddump.log` shows the Red card imported 824 files, then every post-move failed at `2026-05-19 21:49:48-21:49:49`.
- The same log shows a second Red-card run imported 324 more files, then post-move failed again at `2026-05-19 23:25:18`.
- The error in `launchd.err.log` is `Operation not permitted` while macOS `mv` was trying to copy local folders into the rclone mount.
- `~/Temp/2026-05-19-dump` now contains 1,323 files and uses 51 GB.
- The rclone target folder only contains older test folders: `100CANON/` and `Cluster 1 15_00-15_05/`; it does not contain the failed Red-card cluster folders.

Impact:

DDump did the expensive local copy work but did not upload the files. Because the files were recorded in the manifest before post-move, reinserting the card is likely to skip them instead of retrying upload cleanly.

Recommended fix:

Stop using plain `/bin/mv` for local-folder-to-rclone-mount post-move. On macOS, `mv` across filesystems becomes a metadata-preserving copy, and that is what failed with `Operation not permitted`.

Safer short-term change in `move_queued_paths_to_post_target`:

```bash
copy_tree_to_post_target() {
  local src_path="$1"
  local dest_path="$2"

  if [[ -d "$src_path" ]]; then
    /usr/bin/rsync -rlt --human-readable --protect-args \
      --exclude '.DS_Store' --exclude '._*' \
      "$src_path"/ "$dest_path"/
  else
    /usr/bin/rsync -lt --human-readable --protect-args \
      --exclude '.DS_Store' --exclude '._*' \
      "$src_path" "$dest_path"
  fi
}
```

Only remove the source after the copy succeeds and a basic file count/byte count check passes.

Better long-term change:

Use direct `rclone copy` or `rclone move` for DDump's post-move step instead of writing through the Finder mount. Keep the mount for Finder browsing and manual organizing.

### 2. Laptop disk is too full for the current workflow

Evidence:

- `df -h` showed the Mac data volume at 389 GiB used with 49 GiB available.
- `~/Temp/2026-05-19-dump` alone is 51 GB.
- Older logs in `launchd.err.log` show many `No space left on device` copy failures on May 14 and May 15.

Impact:

DDump stages to local disk first. With only about 49 GB free, a normal photo/video day can fill the disk before upload completes, causing partial imports.

Recommended fix:

Before any further real-card testing, either:

1. Safely upload or move the stranded `~/Temp/2026-05-19-dump` folder, then delete it only after confirming the files landed in Drive.
2. Temporarily point `DEST_ROOT` to a larger local/external disk.
3. Add a preflight free-space check to DDump so it refuses to start if free space is below a safe threshold.

Config/code shape:

```bash
MIN_FREE_SPACE_GB="100"

check_staging_space_ready() {
  local free_kb min_kb
  free_kb="$(/bin/df -Pk "$DEST_ROOT" | /usr/bin/awk 'NR==2 {print $4}')"
  min_kb=$(( ${MIN_FREE_SPACE_GB:-100} * 1024 * 1024 ))
  if [[ "$free_kb" -lt "$min_kb" ]]; then
    log "Staging disk too full: free_kb=${free_kb}, required_kb=${min_kb}"
    notify "DDump" "Not enough local free space for safe import."
    return 1
  fi
}
```

Run that before scanning/copying a card.

### 3. Run history says `success` even when upload failed

Evidence:

- `run_history.tsv` has Red-card rows marked `success`:
  - `2026-05-19 21:36:07 Red ... 824 ... success`
  - `2026-05-19 21:54:44 Red ... 324 ... success`
- The post-move failures happened after those lines were written.

Impact:

The history file can say a run succeeded even when the upload failed. This is misleading for daily operations and future debugging.

Recommended fix:

Write run history after post-move completes, not before. Or write a second final-status field that includes `post_move_success`, `post_move_partial`, or `post_move_failed`.

### 4. `exiftool` is missing, so cluster strategy is not using capture time

Evidence:

- `command -v exiftool` returned missing.
- `ddump-cluster.sh` uses EXIF capture time only if `exiftool` exists; otherwise it falls back to filesystem modified time.

Impact:

Cluster folders may be based on when files were copied/modified, not when photos were taken. That makes time-cluster folder naming less reliable, especially after files have been moved, copied, or touched by other tools.

Recommended fix:

Install `exiftool` on the Mac before judging cluster quality:

```bash
brew install exiftool
```

Then rerun a real-card test.

### 5. rclone mount is currently macFUSE, but logs still contain NFS churn and `.DS_Store` retries

Evidence:

- Current mount is macFUSE.
- rclone logs show NFS server starts at `2026-05-20 00:42:31` and `2026-05-20 00:57:54`, then macFUSE starts at `2026-05-20 01:17:32`, `01:18:02`, and `01:18:33`.
- rclone logs show `.DS_Store` failed upload retries into the combine root, for example `combine for remote ".DS_Store": directory not found`.
- rclone logs show a Google Drive API quota warning at `2026-05-20 00:48:04`.

Impact:

The current state is better than NFS, but the mount has been restarted multiple times and has recently had noisy cache/upload retries. Finder stability still needs real-world testing after the switch.

Recommended fix:

Add `--cache-dir "$HOME/Library/Caches/rclone-google-drive"` explicitly and remove stale cache only after confirming no uploads are queued. Keep `--exclude ".DS_Store"`, but also avoid copying local `.DS_Store` through DDump post-move.

### 6. `--allow-non-empty` is masking a real mountpoint hygiene problem

Evidence:

- The live mount script includes `--allow-non-empty` at line 39.
- rclone failed at `2026-05-20 01:17:32` with: `"/Users/chaserobertson/GoogleDrive" is not empty, use --allow-non-empty to mount anyway`.
- A later retry with `--allow-non-empty` mounted successfully.

Impact:

If local files are accidentally present in `~/GoogleDrive` while unmounted, `--allow-non-empty` hides them under the mount. That can make files appear missing or create confusion about whether a file is local-only or in Drive.

Recommended fix:

Replace `--allow-non-empty` with a preflight check that allows only harmless Finder files like `.DS_Store` and `.localized`. If anything else exists locally, abort and log loudly.

### 7. Live config is still pointed at the safe test path

Evidence:

- `POST_MOVE_ROOT="/Users/chaserobertson/GoogleDrive/MyDrive/_DDumpTest"`.
- `FOLDER_NAMING_STRATEGY="cluster"`.
- `CANDIDATE_MODE="all"`.

Impact:

Good: DDump is not currently aimed at the production Densley path. Keep it that way until post-move works.

### 8. Notification helper reality differs from stale docs

Evidence:

- `terminal-notifier` is missing.
- `alerter` is missing.
- `osascript` is present.
- Current `ddump-notify.sh` intentionally uses AppleScript dialogs/notifications.

Impact:

The current notification path is AppleScript-only. That is acceptable given the earlier terminal-notifier hang, but docs/install output should stop implying terminal-notifier is active.

## Recommended Immediate Order

1. Do not run another real card import yet. The Mac is already down to about 49 GB free, and 51 GB is stranded in staging.
2. Fix post-move so it uses safer copy logic or direct `rclone copy` instead of `/bin/mv` into the mount.
3. Add durable pending-import recovery so copied-but-not-uploaded files are retried.
4. Recover the existing 51 GB in `~/Temp/2026-05-19-dump` by uploading it with the fixed post-move path or direct rclone, then delete local staging only after verification.
5. Install `exiftool` before evaluating cluster behavior.
6. Add a free-space preflight check.
7. Keep `POST_MOVE_ROOT` on `_DDumpTest` until an interrupted/retried real-card test passes.

## Summary

The live Mac audit changes the priority: this is no longer just a theoretical resumability bug. DDump has already stranded 51 GB and 1,323 files locally after two Red-card imports because upload/post-move failed with `Operation not permitted`. The current mount is macFUSE and running, but DDump's use of `/bin/mv` into the mount is not safe enough. The Mac is low on disk space, `exiftool` is missing, and the run history can say `success` before upload fails. The next engineering task should be post-move/recovery correctness, not calendar or UI polish.
