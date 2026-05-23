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
- Mount preflight checks before transfer.
- Mount retry backoff schedule (`5,15,60,180,360,600` by default).
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
- `calendar`: match file capture times to Google Calendar events.
- `smart`: infer date-ladder destination shape from a sample path.
- `camera`: keep camera folder structure names.

Grouping controls:

- Cluster grouping toggle independent of naming strategy.
- Cluster gap minutes.
- Cross-card cluster attach window (keeps related camera/drone cards grouped).

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

- Destination
- Naming
- Detection
- Cloud
- Calendar
- Appearance

Includes:

- Tooltips (`i` hints) for key settings.
- Theme mode: light/dark/system.
- Icon preset library with multiple stored icons.
- Default icon selection for light mode and dark mode.

## Install

Run from this repository on macOS:

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
- `FOLDER_NAMING_STRATEGY`
- `FOLDER_NAMING_FALLBACK`
- `CLUSTER_GROUPING_ENABLED`
- `CLUSTER_GAP_MINUTES`
- `CLUSTER_ATTACH_MINUTES`
- `DB_ENABLED`
- `GDRIVE_MOUNT_ENABLED`
- `GDRIVE_MOUNT_RETRY_SECONDS`
- `NETWORK_RESUME_ENABLED`
- `NETWORK_RESUME_CHECK_SECONDS`
- `NETWORK_RESUME_COOLDOWN_SECONDS`
- `NTFY_TOPIC`
- `NTFY_NOTIFY_*` toggles

## Current Defaults Worth Noting

- Lookback mode is enforced for safe card ingest behavior.
- SQLite memory is OFF by default (staging memory mode is default).
- Card eject grace defaults to 60 seconds.
- Default ntfy toggles prioritize card ejected + upload complete (plus mount/integrity/card-full guardrails enabled where configured).

## Development Checks

```bash
bash -n bin/*.sh
swiftc -parse-as-library -o /private/tmp/DDump-check app/DDumpApp.swift
```

`swiftc` requires Apple command-line build tools on macOS.
