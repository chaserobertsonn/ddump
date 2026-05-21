# DDump Feature Completeness Audit - 2026-05-20

Scope: follow-up audit after reading the server Claude session, `SCOPE.md`, the prior Codex audits, and the live Mac-side findings. This file records what was implemented in this pass and what still needs real-world proof.

## Status

DDump is now source-tracked and close to feature-complete for a private beta. I would not call it production-ready for Densley until the real-card retry/interruption test passes and the existing stranded staging folder is recovered or intentionally cleaned up.

## Completed In This Pass

- Added Git hygiene so source, config defaults, app code, install scripts, and audits can be tracked without runtime state.
- Refreshed `README.md` for DDump v2 instead of stale DFP Dump v1 paths.
- Updated `SCOPE.md` with current status and blockers.
- Added no-card/no-work run hygiene so scheduled LaunchAgent wakes do not create empty missed-file reports or append daily digest entries.
- Added a target-directory write probe before post-move uploads.
- Implemented calendar bucketing in `ddump.sh`.
- Hardened `ddump-calendar-lookup.sh` for all-day events.
- Added optional Slack webhook notifications for complete/error run summaries.
- Made the Mac app's `gcalcli` setup check asynchronous with a timeout.
- Made `install.sh` build and install the Swift app when `swiftc` is available.

## Current Feature Coverage

- Card detection: implemented.
- Trust/skip/block flow: implemented.
- Local staging and copy verification: implemented.
- Fast repeat-card skip: implemented.
- Pending upload recovery: implemented.
- Upload receipts and database state: implemented.
- Naming strategies: `smart`, `calendar`, `cluster`, `sequential`, `custom`, and `camera` implemented.
- App controls: pause, resume, stop-after-file, eject-after-file, retry pending uploads, safe cleanup, settings, and window memory implemented.
- Admin notifications: macOS notifications implemented; Slack webhook optional.

## Remaining Blockers

1. Real-card retry/interruption test against `_DDumpTest`.
2. Recover or intentionally clear `~/Temp/2026-05-19-dump`.
3. Install and authorize `gcalcli` on the Mac before using calendar naming live.
4. Install `exiftool` on the Mac for best cluster/calendar capture-time accuracy.
5. Keep production Densley upload blocked until the test above passes.

## Recommendations

- Keep `_DDumpTest` as the default upload target until a full interrupted import recovers correctly.
- Add direct `rclone copy`/`rclone move` later if mounted Google Drive remains flaky.
- Add a menubar status item only after the current app proves stable; it is polish, not a correctness blocker.
- Add automated fixture tests for bucket assignment and pending-upload recovery before wider distribution.
