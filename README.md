# DDump

DDump is a macOS photo-card ingest app for photographers who need a reliable path from camera card to a verified Dump Folder and optional Backup Folder.

It is built for high-confidence transfer workflows:

- Import only recent card files (lookback window) or a manual selection.
- Copy to a verified Dump Folder first.
- Verify local copies.
- Organize into shoot folders.
- Copy to one or more Backup Folders.
- Retry/resume when cloud/mount/network fails.

## Core Workflow

1. Card mounts.
2. DDump checks trust + photo presence.
3. DDump finds candidates (lookback-only by default).
4. DDump copies to the Dump Folder and verifies each file.
5. DDump groups dumped files by capture-time clusters, names those groups by
   your selected strategy, and preserves the camera/source folder tree inside
   each named shoot folder.
6. DDump copies organized shoot folders to Backup Folder(s).
7. DDump verifies backup copy parity (file count + bytes).
8. DDump records receipts/logs/state and handles eject rules.
9. DDump retries incomplete uploads automatically, including after internet reconnect.

## Main Features

### 1) Import safety and control

- Lookback-only import scanning (default 24h).
- Manual select import for specific folders/files from a mounted card.
- Persistent View Only mode for browsing an SSD or SD card without any automatic scan, copy, upload, or eject action.
- Per-card saved source folder choices (avoids scanning whole card repeatedly).
- Do Not Eject and Eject After This File controls.
- Stop-after-file and Pause/Resume controls.
- Minimum Dump Folder free-space guardrail before import.

### 2) Reliability and resume behavior

- Dump Folder-first architecture (cloud outage does not block card copy).
- Pending upload queue with retry schedule.
- Incomplete-session recovery runs before new card work.
- Reinsert-priority handling for files marked missing/incomplete.
- Backup Folder reconciliation: skips re-copy if backup already matches source stats.
- Optional SQLite state engine (beta), default OFF.
- Dump Folder memory mode (default) to dedupe safely without DB.

### 3) Backup-folder and cloud robustness

- Normal synced folders are the default: Google Drive Desktop, Dropbox, Box,
  OneDrive, iCloud Drive, pCloud, NAS folders, local disks, or connected SSDs.
- DDump copies into those local folders after the Dump Folder copy is verified;
  the sync app handles the final upload.
- If a Backup Folder is unavailable, DDump can launch common sync apps such as
  Google Drive Desktop and record an in-app warning instead of failing silently.
- Backup Folder fallback keeps a second destination available when the main
  backup location is disconnected.
- Internet reconnect watcher: when network returns and pending backup copies
  exist, DDump auto-triggers retry.
- Advanced direct-rclone upload is still available when cloud-side verification
  is more important than sync-app speed.
- The old managed rclone mount helper is disabled by default and only installed
  when explicitly enabled for advanced testing.

### 4) Dump and Backup Folders

- Dump Folder: the first verified copy from the card. Recommended: a fast
  folder on this Mac or a directly connected SSD.
- Dump Folder fallback: local safety fallback used when a configured SSD or NAS
  Dump Folder is not connected or writable.
- Backup Folder: optional second copy after the Dump Folder is verified. This
  can be Google Drive Desktop, Dropbox, Box, OneDrive, iCloud Drive, pCloud, a
  NAS folder, another local folder, or another SSD.
- Extra Backup Folders (comma-separated).
- Backup Folder fallback when the main backup location is unavailable.
- Dump-only mode (disable Backup Folder transfer).
- Post-transfer is copy-based (the Dump Folder remains as the safety copy).
- Optional smart-mode video split to sibling Video path.
- Works with any provider that exposes a normal local folder: Google Drive
  Desktop, Dropbox, Box, OneDrive, iCloud Drive, pCloud, NAS folders, or local
  disks. DDump copies into the chosen folder; that provider handles syncing.

### 5) Folder naming and grouping

Strategies:

- `template`: generate names from tokens such as `{smart_camera}`,
  `{calendar_event}`, `{date_ymd}`, `{lens}`, `{sequence_3}`, or `{folder}`.
- `sequential` (default): `Shoot-1`, `Shoot-2`, ...
- `custom`: cycle through configured list.
- `calendar`: match each capture-time cluster to connected calendar events.
- `smart`: infer date-ladder destination shape from a sample path.
- `camera`: keep camera folder structure names.

DDump keeps backup shoot folders flat by default. For example, files copied
from `DCIM/104_2026` into a calendar bucket land directly in
`Kaysville Shoot/...`, not inside another `DCIM/104_2026` folder. The original
Dump Folder safety copy is still retained until Safe Cleanup.
When a card contains multiple shoots, the 30-minute cluster gap splits them
before calendar naming and upload. If no calendar event matches a cluster, DDump
falls back to a time-cluster folder name instead of merging everything into
`Shoot-1`.

Template mode is for Lightroom-style naming without the Lightroom dialog. A
folder template like `{smart_camera} - {calendar_event} - {date_ymd}` can produce
`Canon - Pablo Wedding - 20260622`. Optional file renaming uses the same token
set and preserves file extensions automatically. Smart camera labels simplify
EXIF make/model values into human labels such as `Canon`, `Sony`, or `DJI`.
In `smart` mode DDump keeps the label short unless the same shoot needs extra
detail, then expands to labels such as `Sony a7S III` or numbered matching
bodies when serial metadata is available.

For no-internet days, set `DEFAULT_SHOOT_NAME` or use Settings -> Naming ->
Default offline shoot name. Template mode can use that value for `{shoot}` when
there is no calendar event. Capture-time clustering still separates groups when
the gap threshold says they are different shoots.

Smart mode is for date-ladder destination folders such as:

```text
.../Client Uploads/Photos/2026/2026.05/2026.05.31/Shoot Name
```

Paste one real sample shoot folder in Settings -> Naming. DDump reuses the root before the date ladder, then automatically copies to today's `YYYY/YYYY.MM/YYYY.MM.DD` Backup Folder on every run.
Select the lowest real folder that proves the structure, not only the broad
parent. For example, choose a path like:

```text
.../Uploads/1 - Photo/2026/2026.06/2026.06.12/Shoot Name
```

The app previews what DDump thinks tomorrow and next week will look like before
you rely on the structure.

During an active card transfer, the main progress panel also has an optional Shoot name field. If filled in before staging finishes, that name overrides automatic bucket naming for that run.

Grouping controls:

- Cluster grouping toggle independent of naming strategy.
- Cluster gap minutes.
- Cross-card cluster attach window (keeps related camera/drone cards grouped).

Calendar setup is handled from Settings -> Calendar. DDump offers three
calendar sources:

- Google Calendar: opens browser sign-in from the app, requests read-only
  Calendar access, and stores a local DDump token.
- Apple Calendar: uses the standard macOS Calendar permission prompt and reads
  calendars already synced to the Mac.
- Calendar Link: accepts a private `.ics` or `webcal` URL and validates that it
  returns a calendar file.

Google OAuth note for developers: if the Google Cloud consent screen is still
in Testing, add the signed-in Google account under OAuth consent screen -> Test
users. Otherwise Google will show `Access blocked` before DDump can receive a
token. The Desktop OAuth credential also has a client secret in its downloaded
JSON; add it to `GOOGLE_CALENDAR_CLIENT_SECRET` if Google returns
`client_secret is missing`.

When calendar naming is enabled, DDump can hold pending main-screen questions
for clusters that fall outside scheduled events. The user can assign the cluster
to the previous event, next event, or a manual name; the future rename/move pass
uses that answer to correct the destination folder.

### 6) Verification and integrity

- Local copy size verification (always available).
- Optional local copy hash verification (SHA-256).
- Optional pre-copy hashing mode.
- Volume-level upload completeness verification against tracked rows.
- Integrity warning alert channel (ntfy toggle).

### 7) Notifications and operator feedback

- Native macOS notification prompts + status messages.
- Optional ntfy push events with per-event toggles.
- Optional Slack completion/error summaries.
- Main app checklist panel with progress states:
  - Copy to Dump Folder
  - Eject card
  - Copy to Backup Folder
  - All complete

### 8) App UI and settings

Tabs:

- General
- Naming
- Import
- Alerts

Includes:

- Tooltips (`i` hints) for key settings.
- Dump Folder, Dump Folder fallback, Backup Folder, and Backup Folder fallback under General.
- One-click "Update now" plus optional automatic update checks under General.
- Theme mode: light/dark/system.
- Icon preset library with multiple stored icons.
- Default icon selection for light mode and dark mode.
- Calendar naming setup in Naming, with Mac Calendar, Google Calendar, and Calendar Link options.

## Install

Download the latest DMG from GitHub Releases, open it, then double-click
`Install DDump.command`. The installer creates `~/Applications/DDump.app` and
the helper files under your user Library.

DDump release DMGs are built as universal Mac apps (`arm64` and `x86_64`) with
a macOS 13.0+ deployment target. macOS 15.x users should use DDump 0.3.1 or
newer; DDump 0.3.0 was accidentally built on a newer SDK as a macOS 26-only
binary.

Early builds are unsigned until the Apple Developer ID release is ready. If
macOS blocks launch, open System Settings -> Privacy & Security, scroll to the
security message for DDump, choose Open Anyway, then launch DDump again. You can
also control-click the installer or app and choose Open.

If a card does not auto-import, open DDump manually and use Settings -> General
-> Troubleshoot. The troubleshooter checks the card watcher, Dump Folder,
Backup Folder, calendar access, and the most recent skipped-card reason. The
same screen has Send Bug Report, which opens an email with recent logs and app
version details already filled in.

Developers can also run from this repository on macOS:

```bash
./bin/install.sh
```

Installer sets up:

- DDump scripts under `~/Library/Application Support/DDump/bin/`
- App config at `~/Library/Application Support/DDump/config.env`
- Main importer LaunchAgent `com.ddump`
- Network reconnect watcher LaunchAgent `com.ddump.network-watch`
- macOS app bundle at `~/Applications/DDump.app`

The advanced rclone mount LaunchAgent is only installed when managed mounts are
explicitly enabled. Public/test installs use normal synced folders by default.

## Uninstall

```bash
./bin/uninstall.sh
```

Removes LaunchAgents; keeps app data by design.

## Key Paths

- Config: `~/Library/Application Support/DDump/config.env`
- Main log: `~/Library/Application Support/DDump/logs/ddump.log`
- Network watcher log: `~/Library/Application Support/DDump/logs/ddump-network-watch.log`
- State dir: `~/Library/Application Support/DDump/state/`
- Pending uploads: `~/Library/Application Support/DDump/state/pending_uploads/`
- Reports: `~/Library/Application Support/DDump/reports/`
- SQLite DB (optional): `~/Library/Application Support/DDump/state/ddump.sqlite3`

## Useful Commands

Manual run:

```bash
~/Library/Application\ Support/DDump/bin/ddump.sh
```

Runtime controls:

```bash
~/Library/Application\ Support/DDump/bin/ddump-control.sh status
~/Library/Application\ Support/DDump/bin/ddump-control.sh pause
~/Library/Application\ Support/DDump/bin/ddump-control.sh resume
~/Library/Application\ Support/DDump/bin/ddump-control.sh stop
~/Library/Application\ Support/DDump/bin/ddump-control.sh keep-mounted
~/Library/Application\ Support/DDump/bin/ddump-control.sh eject-when-done
```

Trust a card:

```bash
~/Library/Application\ Support/DDump/bin/ddump-trust.sh /Volumes/CARD_NAME
```

Diagnostics snapshot:

```bash
~/Library/Application\ Support/DDump/bin/ddump-debug-snapshot.sh
```

## Configuration Highlights

Important keys:

- `DEST_ROOT`
- `ENABLE_POST_EJECT_MOVE`
- `POST_MOVE_ROOT`
- `POST_MOVE_ROOTS`
- `POST_MOVE_FALLBACK_ROOT`
- `LOOKBACK_HOURS`
- `PROMPT_FOR_SOURCE_FOLDERS_ON_NEW_DRIVE`
- `FOLDER_NAMING_STRATEGY`
- `FOLDER_NAMING_FALLBACK`
- `REBUCKET_PRESERVE_SOURCE_FOLDERS`
- `FOLDER_NAME_TEMPLATE`
- `SMART_CAMERA_LABEL_MODE`
- `FILE_RENAME_ENABLED`
- `FILE_NAME_TEMPLATE`
- `DEFAULT_SHOOT_NAME`
- `SMART_SAMPLE_PATH`
- `SMART_ASSIGN_EXISTING_FOLDERS`
- `CLUSTER_GROUPING_ENABLED`
- `CLUSTER_GAP_MINUTES`
- `CLUSTER_ATTACH_MINUTES`
- `DB_ENABLED`
- `CLOUD_UPLOADS_ENABLED`
- `GDRIVE_MOUNT_ENABLED`
- `GDRIVE_DIRECT_UPLOAD`
- `GDRIVE_REMOTE`
- `GDRIVE_MOUNT_POINT`
- `GDRIVE_MOUNT_RETRY_SECONDS`
- `GOOGLE_DRIVE_DESKTOP_ENABLED`
- `GOOGLE_DRIVE_DESKTOP_RESTART_ON_FAILURE`
- `GOOGLE_DRIVE_DESKTOP_RESTART_DELAY_SECONDS`
- `RCLONE_CACHE_DIR`
- `PREVENT_FINDER_NETWORK_METADATA`
- `CLOUD_IDLE_UNMOUNT_SECONDS`
- `NETWORK_RESUME_ENABLED`
- `NETWORK_RESUME_CHECK_SECONDS`
- `NETWORK_RESUME_COOLDOWN_SECONDS`
- `NTFY_TOPIC`
- `NTFY_NOTIFY_*` toggles
- `MACOS_NOTIFY_*` toggles
- `NTFY_TEMPLATE_*` message templates
- `UPDATE_CHECKS_ENABLED`
- `AUTO_UPDATES_ENABLED`
- `UPDATE_CHECK_FREQUENCY`
- `UPDATE_GITHUB_REPO`
- `WINDOW_RESTORE_MODE`

Cloud uploads are off by default for new installs. When a user turns them on in
the app, DDump uses Google Drive Desktop local-folder copy mode by default
(`GDRIVE_DIRECT_UPLOAD=0`). Files are copied from staging into the configured
Google Drive folder; the staging folder is kept as the local backup until the
user runs Safe Cleanup. Legacy destinations such as
`$HOME/GoogleDrive/Densley/1 — Media/1 — Uploads/1 — Photo` are resolved to the
real Google Drive Desktop location under `~/Library/CloudStorage/GoogleDrive-*`
when possible, including matching shared-drive folders.

Direct rclone upload remains available as an advanced/fallback mode by setting
`GDRIVE_DIRECT_UPLOAD=1`. In that mode, a configured destination such as
`$HOME/GoogleDrive/Densley/1 — Media/1 — Uploads/1 — Photo` is mapped to the
matching rclone remote path, for example `combined:Densley/1 — Media/1 — Uploads/1 — Photo`.
The old mounted-folder flow remains available for advanced testing by setting
`GDRIVE_DIRECT_UPLOAD=0` and `GDRIVE_MOUNT_ENABLED=1`.
`CLOUD_UPLOADS_ENABLED=1` means cloud upload is enabled; it does not imply that
the Finder mount helper should be installed or started.

If direct rclone upload is disabled and the destination is a local Google Drive
Desktop folder, DDump can launch Google Drive Desktop and restart it once when
the destination folder is unavailable or frozen. That restart is controlled by
`GOOGLE_DRIVE_DESKTOP_ENABLED=1`,
`GOOGLE_DRIVE_DESKTOP_RESTART_ON_FAILURE=1`, and
`GOOGLE_DRIVE_DESKTOP_RESTART_DELAY_SECONDS=5`. In that mode, "copied" means
DDump verified the handoff into the local Drive folder; Google Drive Desktop
still owns the final cloud sync. Direct rclone upload remains the stronger
cloud-side verification path.

First launch shows a short setup wizard for Dump Folder, Backup Folder,
fallback folders, auto-eject, scan window, offline shoot name, and phone alerts.
Every wizard page can be skipped. To rerun it later, open Settings -> General
-> Restart setup wizard.

Phone alerts use ntfy, a small push-notification app for iPhone.
Install ntfy on your phone, choose a private topic name, then paste that same
topic into DDump. DDump links directly to the iPhone app and setup guide from
both the wizard and Settings -> Alerts.

For public calendar naming, use Settings -> Naming -> Mac Calendar first.
That uses local macOS Calendar permission and works with iCloud, Google,
Exchange, and subscribed calendars already synced to the Mac. Google Calendar
OAuth remains optional for users who specifically want direct Google Calendar authorization.

Backup shoot folders are flat by default:
`REBUCKET_PRESERVE_SOURCE_FOLDERS=0` means DDump creates the shoot/calendar
folder and places media files directly inside it instead of recreating camera
folders like `DCIM/101_2026` under the Backup Folder.

## Current Defaults Worth Noting

- Lookback mode is enforced for safe card ingest behavior.
- DDump scans the whole card for eligible media inside the lookback window by default. The folder chooser is an advanced opt-in.
- Unknown volumes use smart camera-card detection. DDump does not require `DCIM`,
  but it ignores installer/update/app mounts unless they contain camera-card
  shape, such as camera hint folders or multiple media files.
- Camera-card detection accepts common structures such as Canon
  `DCIM/100CANON`, Canon date folders like `DCIM/115_2026`, Sony
  `DCIM/100MSDCF`, Fujifilm `DCIM/100_FUJI`, Panasonic `DCIM/100_PANA`, DJI
  `DCIM/DJI_001`, GoPro `DCIM/100GOPRO`, and any DCIM subtree with supported
  photo/video files.
- If no files match the scan window, DDump leaves the card mounted and looks for
  the newest older shoot so the user can choose whether to import it manually.
- Smart naming does not reuse existing destination folders by default. Turn on `SMART_ASSIGN_EXISTING_FOLDERS` only when those folders were created for your shoots today.
- SQLite memory is OFF by default (Dump Folder memory mode is default).
- Card eject grace defaults to 60 seconds.
- Update checks and auto updates are OFF by default until a public release/update feed is configured.
- Notification settings live in their own Settings tab. Each event can independently use ntfy, macOS notifications, or both.
- Default ntfy toggles prioritize card ejected, upload complete, and pending recovery. Mount-failure ntfy alerts are off by default because cloud mounts are short lived and retried from the app.
- Google Drive Desktop local-folder copy is the default cloud handoff. The
  DDump-managed rclone mount remains an advanced fallback and is disabled by
  default.
- Calendar provider defaults to Mac Calendar. Calendar naming works after the
  user approves the standard macOS Calendar permission prompt, and DDump caches
  upcoming local events for background imports.
- Calendar ambiguity prompts default on so clusters between scheduled shoots can be assigned before final naming is trusted.
- Window launch behavior defaults to `WINDOW_RESTORE_MODE=remember`; Settings
  -> General can switch to compact or large fixed startup sizes.

## Development Checks

```bash
bash -n bin/*.sh
MACOSX_DEPLOYMENT_TARGET=13.0 ./scripts/build-app.sh
./scripts/public-readiness-check.sh
```

`scripts/public-readiness-check.sh` is the pre-handoff smoke test for public
behavior: shell syntax, app build, installed app footprint, config defaults, and
old managed-mount LaunchAgents.

`swiftc` requires Apple command-line build tools on macOS.
