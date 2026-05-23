# DDump

DDump is a macOS SD-card and camera-card importer for photographers. It watches for mounted cards, copies new files to local staging, verifies the local copy, groups files into useful shoot folders, uploads those folders to a configured destination, and ejects the card only when the run is safe.

The project started as DFP Dump and was renamed to DDump so it can be configured for non-DFP workflows.

## Current Capabilities

- macOS LaunchAgent starts DDump on card mount and every few minutes for pending upload retries.
- Photo-volume detection silently ignores non-photo mounts like installers.
- Trust controls support volume-name prefixes, remembered UUIDs, one-time imports, skips, and blocklisting.
- New cards can prompt for source-folder selection so imports do not have to scan an entire card.
- Local staging protects card reads from cloud upload failures.
- Pending upload recovery retries blocked uploads on later launches.
- Manual backfill import from the Mac app can target specific files/folders on a mounted card (including older than lookback windows).
- During uploads, DDump can drive `finderserver` and refresh its auto-off timer so mounts do not drop mid-transfer.
- Upload retries now reconcile destination content before re-copying, so reconnect runs resume from what is already present.
- Per-volume upload completion is verified against SQLite tracking; incomplete rows are marked for reinsert-first recovery.
- Folder naming strategies:
  - `smart`: infer the date-folder structure from a sample path and map clusters into existing shoot folders.
  - `calendar`: match capture times to Google Calendar events through `gcalcli`.
  - `cluster`: group files by capture-time gaps.
  - `sequential`: create `DDump 1`, `DDump 2`, etc.
  - `custom`: use configured names in order.
  - `camera`: keep camera folder names.
- Post-move uses `rsync` copy plus file-count/byte verification before removing local staged folders.
- The Mac app shows progress, ETA, local disk health, pending uploads, safe cleanup, settings, pause/resume, stop-after-current-file, and eject-after-current-file.
- Optional Slack webhook notifications can report complete/error run summaries.

## Install On Mac

From this project folder on the Mac:

```bash
./bin/install.sh
```

This installs:

- `~/Library/Application Support/DDump/bin/ddump.sh`
- `~/Library/Application Support/DDump/config.env`
- `~/Library/LaunchAgents/com.ddump.plist`
- `~/Applications/DDump.app`

The installer preserves existing user config and only adds missing keys.

## Configure

Edit the user config:

```bash
open -e ~/Library/Application\ Support/DDump/config.env
```

Main settings:

- `DEST_ROOT`: local staging folder.
- `POST_MOVE_ROOT`: final upload root.
- `FOLDER_NAMING_STRATEGY`: `smart`, `calendar`, `cluster`, `sequential`, `custom`, or `camera`.
- `FOLDER_NAMING_FALLBACK`: fallback when the primary naming strategy cannot classify a file.
- `TRUSTED_NAME_PREFIXES`: comma-separated volume prefixes that auto-trust.
- `CANDIDATE_MODE`: `all` or `lookback`.
- `MIN_FREE_SPACE_GB`: local free-space preflight threshold.
- `VERIFY_COPY_HASH`: optional slower post-copy SHA-256 verification.
- `HASH_BEFORE_COPY`: optional slower pre-copy hash for global duplicate checks.
- `SLACK_WEBHOOK_URL`: optional Slack incoming webhook for admin-only run notifications.

## Calendar Naming

Calendar naming requires `gcalcli` on the Mac:

```bash
brew install gcalcli
gcalcli list
```

Then set:

```bash
FOLDER_NAMING_STRATEGY="calendar"
CALENDAR_NAME=""
CALENDAR_EVENT_PADDING_MIN="15"
```

DDump matches each file's EXIF capture time, falling back to file modified time, against the calendar events for that date. Files outside a matching event window use `FOLDER_NAMING_FALLBACK`.

## Useful Commands

Manual run:

```bash
~/Library/Application\ Support/DDump/bin/ddump.sh
```

Control a running import:

```bash
~/Library/Application\ Support/DDump/bin/ddump-control.sh status
~/Library/Application\ Support/DDump/bin/ddump-control.sh pause
~/Library/Application\ Support/DDump/bin/ddump-control.sh resume
~/Library/Application\ Support/DDump/bin/ddump-control.sh stop
~/Library/Application\ Support/DDump/bin/ddump-control.sh eject-when-done
```

Trust a card manually:

```bash
~/Library/Application\ Support/DDump/bin/ddump-trust.sh /Volumes/CARD_NAME
```

## Logs And State

- Main log: `~/Library/Application Support/DDump/logs/ddump.log`
- LaunchAgent stdout: `~/Library/Application Support/DDump/logs/launchd.out.log`
- LaunchAgent stderr: `~/Library/Application Support/DDump/logs/launchd.err.log`
- User config: `~/Library/Application Support/DDump/config.env`
- SQLite state: `~/Library/Application Support/DDump/state/ddump.sqlite3`
- Pending uploads: `~/Library/Application Support/DDump/state/pending_uploads/`
- Reports: `~/Library/Application Support/DDump/reports/`

Pure no-card/no-work scheduler runs do not create missed-file reports or daily-digest entries.

## Development

Canonical source lives in this repository. The installed Mac copy is generated by `bin/install.sh`.

Run checks:

```bash
bash -n bin/*.sh
swiftc -parse-as-library -o /private/tmp/DDumpApp-check app/DDumpApp.swift
```

Swift compilation may require a matching local Xcode Command Line Tools install.

## Uninstall

```bash
./bin/uninstall.sh
```
