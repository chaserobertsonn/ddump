# DDump v2 — Scope & Status

**Last updated:** 2026-05-19 (live document — keep updating as work progresses)

This document captures the scope, decisions, status, and outstanding work for DDump v2.
It exists so any new session — Claude or human — can pick up exactly where the previous
session left off without losing context.

---

## Why we're doing this

Originally a Chase-specific SD-importer (called "DFP Dump") that auto-imported real-estate
photo cards to a hardcoded Google Drive path. Mid-session 2026-05-19 Chase asked to:

1. Rename **DFP Dump → DDump** (so it's not Chase-branded)
2. Make it **agnostic** — usable by any photographer (travel, event, real-estate, wedding…)
3. Replace the "DCIM-only" check with **photo-file detection** so non-camera devices (drones,
   action cams) work too, and DMG installers/random USB sticks get silently ignored
4. Replace the **intrusive Terminal monitor** with **native macOS notifications** (top-right
   banner with action buttons) so daily use doesn't pop a Terminal window
5. Add **smart folder naming** strategies:
   - `calendar` — pull event title from Google Calendar
   - `sequential` — "Dump 1", "Dump 2", …
   - `custom` — cycle through user-defined names
   - `cluster` — time-cluster by gaps in capture time
   - `camera` — keep the camera's raw folder names
6. Wrap as a **real Mac app** via Platypus (Swift rewrite later)
7. Personal use only for now; distribute to photographer friends later when stable

---

## Architecture (post-v2)

```
SD card / drone / camera mounts
   │
   ▼
LaunchAgent (com.ddump) fires ddump.sh
   │
   ▼
Quick photo-file scan (PHOTO_FILE_EXTENSIONS, max 4 dirs deep, bail on first match)
   │ no photos found AND not trusted by UUID AND not name-prefixed
   ├──→ SILENT SKIP (log line only, no notification)
   ▼ photos found
Trust check:
   - name prefix match (TRUSTED_NAME_PREFIXES, comma-separated)
   - UUID in trusted_uuids.txt
   - else → native notification with action buttons:
            [Trust] [Just this time] [Skip] [Never]
   │
   ▼ trusted
Copy SD → ~/Temp/YYYY-MM-DD-dump/<camera-folder>/file.ext
   (SHA-256 verified, manifest deduped)
   │
   ▼
REBUCKET: re-organize imported files into bucket folders by FOLDER_NAMING_STRATEGY
   - sequential: all files → "${PREFIX}${n}/" (auto-increments per day)
   - custom:     all files → first unused name from FOLDER_NAME_CUSTOM_VALUES
   - cluster:    files grouped by EXIF/mtime gaps > CLUSTER_GAP_MINUTES; each cluster
                 gets folder named via CLUSTER_FOLDER_TEMPLATE
   - calendar:   uses ddump-calendar-lookup.sh/gcalcli to match capture times to event titles,
                 then falls back for unmatched files
   - camera:     no-op (keep raw camera folder names)
   │
   ▼
Move bucket folder(s) → POST_MOVE_ROOT/YYYY/YYYY.MM/YYYY.MM.DD/<bucket name>/
   (via rclone-mounted Google Drive at ~/GoogleDrive/Densley/...)
   │
   ▼
Eject card on success
   │
   ▼
Native notification: "✓ Imported N files to <bucket>"
```

---

## Status — session ending 2026-05-19

### ✅ Phase 1 (rclone mount + basic DFP Dump fix) — DONE earlier this session
- rclone mount with shared drives wired via `combine` backend
- `~/GoogleDrive/{MyDrive,Densley,Kaizen}/`
- Mount stability hardened (Mac metadata excludes)
- POST_MOVE_ROOT repointed through the mount; verified end-to-end with real Drive write

### ✅ Phase 2A (DDump v2 core) — DONE this session
- [x] Renamed all scripts dfp-dump-*.sh → ddump-*.sh
- [x] Renamed all internal references (DFPDump → DDump, com.dfp.dump → com.ddump, log file names)
- [x] Migration logic in install.sh: old DFPDump dir auto-renamed to DDump, old LaunchAgent removed, config keys renamed (`TRUSTED_NAME_PREFIX` → `TRUSTED_NAME_PREFIXES`, `REQUIRE_DCIM_OR_TRUSTED` → `REQUIRE_PHOTOS_OR_TRUSTED`)
- [x] Live install migrated on Chase's MacBook Pro
- [x] Agnostic config schema (`config/config.env` and matching defaults in ddump.sh)
- [x] Multi-prefix `TRUSTED_NAME_PREFIXES` (comma-separated; defaults to "DFP_")
- [x] Photo-file detection (`volume_has_photos`, `count_recent_photos_on_volume`) — replaces DCIM-only check. Silent-skip verified by mounting an empty installer DMG.
- [x] `ddump-notify.sh` notification wrapper (alerter → terminal-notifier → osascript fallback)
- [x] `terminal-notifier` installed on the Pro (alerter not available in Homebrew anymore)
- [x] Native-notification trust prompt: `[Trust] [Just this time] [Skip] [Never]` via `notify_ask`
- [x] Terminal monitor turned OFF by default (`SHOW_PROGRESS_WINDOW="0"`); `USE_NOTIFICATIONS="1"` is the new primary UI
- [x] Folder-naming strategies: `sequential`, `custom`, `cluster`, `camera`
- [x] `ddump-cluster.sh` time-clustering helper (EXIF time via exiftool, mtime fallback). Bug fix: `grep '^unknown\t'` was triggering set -e exit when no unknown rows; wrapped in `|| true`. Verified end-to-end with 6 staged files: 45-min gap → 3 clusters, 4-hour gap → 1 cluster.
- [x] `rebucket_imported_files` integrated into ddump.sh just before post-move
- [x] `ddump-calendar-lookup.sh` in place and integrated into `ddump.sh` calendar bucketing
- [x] On-Mac install verified — all new scripts deployed to `~/Library/Application Support/DDump/bin/`, user config has all the new keys with sensible defaults

### ⏳ Deferred to next session

- [ ] **Live test of the full Phase 2A flow** with a real Canon SD card. Components individually verified, but the integrated rebucket + move + notify pipeline hasn't been exercised end-to-end. Chase will plug in a card and we observe.
- [x] **Calendar strategy wiring**:
  - `compute_buckets_calendar` uses ddump-calendar-lookup.sh
  - Wired into `rebucket_imported_files`
  - Files outside any event window fall through to `FOLDER_NAMING_FALLBACK` (cluster by default)
  - Event windows are padded by ±`CALENDAR_EVENT_PADDING_MIN` minutes
  - Still requires Mac-side `brew install gcalcli` and OAuth before real use
- [x] **Native Mac app shell**: `~/Applications/DDump.app` exists and wraps the importer with progress, settings, controls, window memory, and safe cleanup.
- [ ] **Menubar status item**: optional later enhancement if the app needs always-visible background status.
- [ ] **MacBook Air**: still waiting on Chase enabling Remote Login. Once on, mirror the Pro setup (rclone config + DDump install).
- [ ] **README rewrite** for non-DFP audience (was DFP-specific; needs generic photographer wording).

---

## Key decisions made

| Decision | Choice | When |
|---|---|---|
| Drive mount tool | rclone (free, scriptable) | 2026-05-19 |
| Mount type | rclone `nfsmount` (no macFUSE runtime dep) | 2026-05-19 |
| Shared-drive exposure | All in one mount via `combine` backend | 2026-05-19 |
| Combine labels | `MyDrive`, `Densley`, `Kaizen` (space-free) | 2026-05-19 |
| Delivery model | **Phased** for Phase 1, then **all-in v2 push** | 2026-05-19 |
| Cluster gap default | **45 minutes** — prefer over-splitting to under-splitting | 2026-05-19 |
| Photo detection depth | 4 directories deep, bail on first match | 2026-05-19 |
| Notification helper | `alerter` preferred but unavailable → `terminal-notifier` used | 2026-05-19 |
| Trust prompt buttons | Trust / Just this time / Skip / Never | 2026-05-19 |
| Distribution | Personal use only for now; friends later when stable | 2026-05-19 |
| Swift rewrite | Deferred until after Platypus version is field-tested | 2026-05-19 |

---

## Critical implementation notes (do NOT lose)

### Workspace vs installed copies
- Workspace (edit here): `~/DFP-Coding/dump/` on the **server** (`dfp-server`).
- Installed copy (running here): `~/Library/Application Support/DDump/` on Chase's **Mac**.
- Deploy via `install.sh` from the **Mac**, via the Finder mount of the server at
  `/Users/chaserobertson/dfp-server/DFP-Coding/dump/bin/install.sh`.
- `install.sh` is conservative: it preserves existing user config and only ADDS missing
  keys (with `migrate_key` and `add_missing_key` helpers). Renamed keys are auto-migrated.

### Notification helper detection order
1. `alerter` (best — supports rich action buttons) — not in Homebrew anymore
2. `terminal-notifier` (currently installed on the Pro) — supports `-actions`
3. `osascript display dialog` (fallback — intrusive, but works)

### Folder-naming strategy hook
`rebucket_imported_files` in ddump.sh runs **after import, before post-move**. To add a new
strategy:
1. Write a `compute_buckets_<name>` helper that reads file paths from stdin and prints
   `<file_path>\t<bucket_name>` on stdout.
2. Add a `case` arm to `rebucket_imported_files`.

### Calendar strategy (when wired)
- Needs `gcalcli` installed + authenticated (separate OAuth from rclone — `calendar.readonly`).
- `ddump-calendar-lookup.sh --date YYYY-MM-DD` returns `start_epoch\tend_epoch\ttitle` rows.
- The `compute_buckets_calendar` function (to be written) should:
  1. Take all imported file paths
  2. Get capture-time epoch for each (via `ddump-cluster.sh` logic, or directly with exiftool)
  3. Fetch events for the day via `ddump-calendar-lookup.sh`
  4. For each file, find the event whose `[start - padding, end + padding]` contains the
     file's capture time. Match → bucket = event title. No match → bucket =
     `FOLDER_NAME_UNCATEGORIZED` (or fall through to cluster).
  5. Print `<file_path>\t<bucket_name>` rows.

### Macs in scope
- **MacBook Pro** — DDump v2 deployed. Hostname `chases-macbook-pro`, SSH alias `mac`.
- **MacBook Air** — blocked on Chase enabling Remote Login.

---

## Open questions / TODOs needing Chase input

- **terminal-notifier permissions** — first time it sends a notification, macOS prompts for
  permission. Chase needs to allow it once.
- **Air Remote Login** — Chase to enable in System Settings → General → Sharing.
- **Should we uninstall the official Google Drive Mac app?** — once Phase 2A is field-tested
  with a real card, the official app is no longer needed and should be removed.
- **Slack webhook URL** — optional. If set, DDump can send admin-only complete/error summaries.

---

## How to resume work next session

1. **Read this file first.** Source of truth for what's done, what's next.
2. **Check live state on the Mac:**
   ```
   ssh mac 'mount | grep GoogleDrive; ls ~/GoogleDrive; tail -20 ~/Library/Application\ Support/DDump/logs/ddump.log; grep -E "^FOLDER_NAMING_STRATEGY|^POST_MOVE_ROOT|^TRUSTED_NAME_PREFIXES" ~/Library/Application\ Support/DDump/config.env; launchctl print gui/$(id -u)/com.ddump | head'
   ```
3. **Find the unchecked box** in the current phase, and start there.
4. **Update this file** as you make progress — tick boxes, log new decisions in the table.

---

## 2026-05-20 reliability patch notes

Patched after the Mac-side audit found 51 GB stranded in `~/Temp/2026-05-19-dump` from failed post-moves.

Completed:

- Replaced post-move `/bin/mv` into the rclone mount with conservative `rsync -rlt` copy, metadata-file excludes, content stats verification, then local removal only after copy verification succeeds.
- Added durable pending upload state in `state/pending_uploads/`:
  - `raw` rows track copied files before rebucketing.
  - `queued` rows track already-bucketed folders waiting for upload retry.
  - startup recovery retries pending uploads before scanning new cards.
- Added local free-space preflight with `MIN_FREE_SPACE_GB="100"` default. With the current Mac free space around 49 GB, DDump should refuse real imports until staging is cleaned up or the threshold is changed.
- Changed `VERIFY_COPY_HASH` default to `0`; size verification remains enabled. Full post-copy SHA-256 is now optional/paranoid mode.
- Fixed `lookback` candidate mode to avoid GNU-only `find -newermt`; it now uses macOS-safe Perl cutoff filtering.
- Made run history final status write after post-move so upload failures become `partial` instead of early `success`.
- Hardened bucket-name sanitation and rebucket error handling.
- Escaped Swift-written config values safely before writing shell-style config lines.
- Removed the competing SwiftUI native `Settings {}` scene; settings remain available through the reliable sheet.
- Updated the live Mac rclone mount script to remove `--allow-non-empty`; it now refuses to mount over unexpected local files.
- Installed patched scripts on the Mac and rebuilt `~/Applications/DDump.app`.
- Verified a small `rsync -rlt` copy into `/Users/chaserobertson/GoogleDrive/MyDrive/_DDumpTest` succeeds.

Still not done:

- Existing stranded folder `~/Temp/2026-05-19-dump` was intentionally not moved or deleted. It still needs an explicit recovery/upload step after Chase confirms.
- Production Densley cutover should stay blocked until a real-card retry/interruption test passes against `_DDumpTest`.

## 2026-05-20 Codex follow-up

Completed:

- Initialized source hygiene for GitHub tracking and refreshed the README for DDump v2.
- Added no-op scheduler hygiene: pure no-card/no-work runs no longer leave empty missed-file reports or append daily digest entries.
- Added a final target-directory write probe before post-move uploads, catching Google Drive/rclone permission failures before per-folder copy attempts.
- Implemented calendar bucketing in `ddump.sh` with EXIF/mtime capture times, per-date event lookup, event-window padding, and fallback handling for unmatched files.
- Hardened `ddump-calendar-lookup.sh` for all-day events.
- Added optional Slack webhook notifications with default error-only behavior and no webhook URL logging.
- Made the app's calendar authorization check run off the main UI thread with a timeout, so settings do not freeze if `gcalcli` hangs.

Still blocked or intentionally deferred:

- Existing stranded folder `~/Temp/2026-05-19-dump` still needs explicit recovery/upload confirmation.
- Real calendar mode needs `gcalcli` installed and authorized on the Mac before live testing.
- Production Densley cutover should stay blocked until a real-card retry/interruption test passes against `_DDumpTest`.

## 2026-05-20 rclone memory follow-up

Completed:

- Changed the Google Drive rclone mount from an always-on LaunchAgent to an on-demand service:
  - `RunAtLoad=false`
  - `KeepAlive=false`
  - DDump starts it only when `POST_MOVE_ROOT` points under `~/GoogleDrive` and the mount is not already active.
  - DDump tries a normal unmount when it started the mount itself; if the mount is busy, it leaves it running instead of forcing it.
- Replaced the Finder-heavy rclone profile with a low-memory profile:
  - `--vfs-cache-mode writes`
  - `--buffer-size 8M`
  - `--transfers 2`
  - `--checkers 4`
  - `--drive-chunk-size 16M`
  - shorter directory/poll/cache settings
- Verified the old live profile used about 1.13 GB resident memory.
- Verified the new profile started around 71 MB resident memory in a controlled test.
- Confirmed the separate `dfp-server` Finder mount remains active and separate from the Google Drive mount.

Tradeoff:

- The new profile is tuned for DDump uploads and light Finder checks, not heavy all-day Finder browsing/previews. If Finder browsing of Google Drive becomes important again, use a separate manual Finder-heavy profile instead of keeping the DDump profile always on.
