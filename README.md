# DDump

DDump is a macOS photo-card ingest app for photographers who need a reliable path from SD card to local staging and cloud destination.

It is built for high-confidence transfer workflows:

- Import only recent card files (lookback window) or a manual selection.
- Stage locally first.
- Verify local copies.
- Organize into shoot folders.
- Copy to one or more destinations.
- Retry/resume when cloud/mount/network fails.

## Core Workflow

1. Card mounts.
2. DDump checks trust + photo presence.
3. DDump finds candidates (lookback-only by default).
4. DDump copies to staging and verifies each file.
5. DDump re-buckets staged files by your naming strategy.
6. DDump copies staged buckets to destination(s).
7. DDump verifies destination copy parity (file count + bytes).
8. DDump records receipts/logs/state and handles eject rules.
9. DDump retries incomplete uploads automatically, including after internet reconnect.

## Main Features

### 1) Import safety and control

- Lookback-only import scanning (default 24h).
- Manual select import for specific folders/files from a mounted card.
- Per-card saved source folder choices (avoids scanning whole card repeatedly).
- Do Not Eject and Eject After This File controls.
- Stop-after-file and Pause/Resume controls.
- Minimum staging free-space guardrail before import.

### 2) Reliability and resume behavior

- Local staging-first architecture (cloud outage does not block card copy).
- Pending upload queue with retry schedule.
- Incomplete-session recovery runs before new card work.
- Reinsert-priority handling for files marked missing/incomplete.
- Destination reconciliation: skips re-copy if destination already matches source stats.
- Optional SQLite state engine (beta), default OFF.
- Staging-folder memory mode (default) to dedupe safely without DB.

### 3) Cloud/mount robustness

- Packaged rclone mount helper LaunchAgent.
- Cloud setup wizard only runs when cloud uploads are enabled.
- Wizard installs/uses rclone, opens Google sign-in, creates the Drive remote, and builds a combined mount when shared drives are available.
- Google Drive shared drives mount as top-level folders so both personal and team drives can be selected.
- Uses macFUSE-backed `rclone mount` when macFUSE is installed; otherwise falls back to rclone `nfsmount`. macFUSE is recommended for Finder-stable Google Drive syncing.
- DDump uses a passive app keepalive and an idle watcher: it does not remount every minute, and the cloud mount is unmounted after the idle timeout when DDump is closed and no transfer is running.
- Mount preflight checks before transfer.
- Mount retry backoff schedule (`15,30,60,180` by default).
- Finder-server timer guard during uploads to avoid unmount mid-transfer.
- Hard restart mount action in app.
- Cloud diagnostics in app (binary/remote/service/mount state + reason string).
- Internet reconnect watcher: when network returns and pending uploads exist, DDump auto-triggers retry.

### 4) Destination handling

- Primary destination.
- Additional destinations (comma-separated).
- Fallback destination root.
- Staging-only mode (disable destination transfer).
- Post-transfer is copy-based (staging remains as backup).
- Optional smart-mode video split to sibling Video path.

### 5) Folder naming and grouping

Strategies:

- `sequential` (default): `Shoot-1`, `Shoot-2`, ...
- `custom`: cycle through configured list.
- `calendar`: match file capture times to connected calendar events.
- `smart`: infer date-ladder destination shape from a sample path.
- `camera`: keep camera folder structure names.

Smart mode is for date-ladder destination folders such as:

```text
.../Client Uploads/Photos/2026/2026.05/2026.05.31/Shoot Name
```

Paste one real sample shoot folder in Settings -> Naming. DDump reuses the root before the date ladder, then automatically uploads to today's `YYYY/YYYY.MM/YYYY.MM.DD` folder on every run.

During an active card transfer, the main progress panel also has an optional Shoot name field. If filled in before staging finishes, that name overrides automatic bucket naming for that run.

Grouping controls:

- Cluster grouping toggle independent of naming strategy.
- Cluster gap minutes.
- Cross-card cluster attach window (keeps related camera/drone cards grouped).

Calendar setup is handled from Settings -> Calendar. Public users do not need
Terminal commands. DDump offers three calendar sources:

- Google Calendar: opens browser sign-in from the app, requests read-only
  Calendar access, and stores a local DDump token. No Terminal or `gcalcli`
  setup is required.
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
  - Transfer to staging
  - Eject card
  - Transfer to destination
  - All complete

### 8) App UI and settings

Tabs:

- General
- Naming
- Detection
- Notifications
- Cloud
- Calendar

Includes:

- Tooltips (`i` hints) for key settings.
- Destination mode and destination folders under General.
- Check-for-updates controls under General, off by default.
- Theme mode: light/dark/system.
- Icon preset library with multiple stored icons.
- Default icon selection for light mode and dark mode.
- Calendar wizard with Google, Apple Calendar, and Calendar Link setup options.

## Install

Download the latest DMG from GitHub Releases, open it, then double-click
`Install DDump.command`. The installer creates `~/Applications/DDump.app` and
the helper files under your user Library.

Early builds are unsigned. If macOS blocks launch, control-click the installer
or app and choose Open.

Developers can also run from this repository on macOS:

```bash
./bin/install.sh
```

Installer sets up:

- DDump scripts under `~/Library/Application Support/DDump/bin/`
- App config at `~/Library/Application Support/DDump/config.env`
- Main importer LaunchAgent `com.ddump`
- Cloud mount LaunchAgent (`GDRIVE_MOUNT_LABEL`)
- Network reconnect watcher LaunchAgent `com.ddump.network-watch`
- macOS app bundle at `~/Applications/DDump.app`

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

Cloud uploads are off by default for new installs. When a user turns them on in
the app, DDump now uploads Google Drive destinations directly with `rclone copy`
by default (`GDRIVE_DIRECT_UPLOAD=1`). A configured destination such as
`$HOME/GoogleDrive/Densley/1 — Media/1 — Uploads/1 — Photo` is mapped to the
matching rclone remote path, for example `combined:Densley/1 — Media/1 — Uploads/1 — Photo`.
This avoids requiring Finder, macFUSE, or an always-on mounted Google Drive
folder during normal imports. The old mounted-folder flow remains available for
advanced testing by setting `GDRIVE_DIRECT_UPLOAD=0` and `GDRIVE_MOUNT_ENABLED=1`.
`CLOUD_UPLOADS_ENABLED=1` means cloud upload is enabled; it does not imply that
the Finder mount helper should be installed or started.

## Current Defaults Worth Noting

- Lookback mode is enforced for safe card ingest behavior.
- DDump scans the whole card for eligible media inside the lookback window by default. The folder chooser is an advanced opt-in.
- Smart naming does not reuse existing destination folders by default. Turn on `SMART_ASSIGN_EXISTING_FOLDERS` only when those folders were created for your shoots today.
- SQLite memory is OFF by default (staging memory mode is default).
- Card eject grace defaults to 60 seconds.
- Update checks and auto updates are OFF by default until a public release/update feed is configured.
- Notification settings live in their own Settings tab. Each event can independently use ntfy, macOS notifications, or both.
- Default ntfy toggles prioritize card ejected, upload complete, and pending recovery. Mount-failure ntfy alerts are off by default because cloud mounts are short lived and retried from the app.
- The Google Drive mount uses a DDump-owned rclone cache and prevents Finder network `.DS_Store` writes by default. This avoids stale metadata uploads at the root of the combined Drive mount.
- Calendar provider defaults to `none`; setup is opt-in from the Calendar tab.
- Calendar ambiguity prompts default on so clusters between scheduled shoots can be assigned before final naming is trusted.

## Development Checks

```bash
bash -n bin/*.sh
swiftc -parse-as-library -o /private/tmp/DDump-check app/DDumpApp.swift
```

`swiftc` requires Apple command-line build tools on macOS.
