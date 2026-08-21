# DDump Marketing Guide

## Positioning

DDump is a photographer-first ingest system designed to remove the two biggest risks in the handoff pipeline:

1. Missing files from rushed card offloads.
2. False confidence when cloud sync fails silently.

It is built around verifiable, recoverable transfers, not “best effort” sync.

## Core Promise

"Plug in a card, keep shooting. DDump stages safely, verifies locally, retries cloud delivery automatically, and tells you what still needs attention."

## Ideal Users

- Wedding photographers with multiple cameras/cards per day.
- Real-estate teams handing off to remote editors.
- Drone + ground shooters who combine media from multiple devices.
- Solo creators who need reliable upload when internet is unstable.
- Studios standardizing card ingest for assistants.

## Value Props

- Reliability over convenience theater.
- Resume-first architecture, not restart-from-zero behavior.
- Card-to-cloud pipeline with staging backup retained.
- Built-in operational visibility (checklist, logs, receipts, alerts).
- Flexible naming/grouping for real shoot patterns.

## Exhaustive Implemented Feature Inventory

### A) Ingest and card handling

- Auto-start on mount via LaunchAgent.
- Photo-aware card detection (silent skip for non-photo volumes).
- Trust flow with `Trust / Just this time / Skip / Never`.
- Manual import offers `Trust Card & Auto-Import` or `Import Once`.
- UUID trust memory and UUID blocklist.
- Name-prefix auto-trust rules.
- Per-card source-folder memory (no forced whole-card scans).
- Manual select import mode (specific files/folders only).
- Lookback-based candidate filtering (time-window ingest safety).
- Runtime controls: timed pause imports, pause/resume active copy, stop-after-file.
- Runtime eject controls: do-not-eject, eject-after-file.

### B) Copy verification and data safety

- Local staging-first copy pipeline.
- Post-copy size verification.
- Optional SHA-256 verification.
- Optional pre-copy hashing mode.
- Missed-file reporting.
- Upload receipts.
- Daily digest reporting with activity-aware suppression.

### C) Naming and organization

- Sequential naming (`Shoot-1`, `Shoot-2`, ...).
- Custom rotating naming list.
- Calendar naming via Google Calendar events.
- Calendar naming via local Apple Calendar permission for iCloud, Google,
  Exchange, and other calendars already synced to macOS.
- Calendar naming via private ICS/webcal links.
- Offline/default shoot name for template naming when calendar events are not
  available.
- Smart naming via sample destination path inference.
- Smart destination preview for tomorrow/next-week folder structure.
- Smart path warnings when a selected sample points inside card folders such as
  `DCIM`.
- Camera-native naming mode.
- Lightroom-style folder and file templates with EXIF/date/calendar/sequence
  tokens.
- Naming fallback strategy.
- Time-cluster grouping toggle independent of naming mode.
- Cluster gap tuning.
- Cross-card cluster attach window (multi-card same-shoot grouping).
- Optional photo/video split in smart mode.

### D) Destination transfer and cloud resilience

- Destination copy (not move) so staging remains backup.
- Flat destination shoot folders by default; DDump does not recreate
  `DCIM/101_2026` under the final shoot folder unless the user opts into
  preserving source folders.
- Primary destination root.
- Multiple additional destination roots.
- Fallback destination root.
- Staging-only operation mode.
- Provider-neutral synced-folder destinations: Google Drive Desktop, Dropbox,
  Box, OneDrive, iCloud Drive, pCloud, NAS, or local disk.
- Google Drive Desktop local-folder handoff as the fast primary path.
- rclone as advanced fallback/verification path rather than required public setup.
- Mount preflight checks before destination transfer.
- Destination reconciliation (skip if already present and matching stats).
- Pending upload queue + retry backoff schedule.
- Startup recovery of pending uploads before new card ingest.
- Reinsert-priority recovery flow for incomplete media.
- Volume-level upload completeness verification (with SQLite mode data).

### E) Mount and network operations

- Bundled rclone helper scripts for advanced fallback workflows.
- Managed mount helpers are disabled by default; normal users choose a synced
  folder instead.
- Mount retry backoff (`15,30,60,180` default) only for advanced managed-mount mode.
- Hard restart mount action in app for advanced mode.
- Finder-server keepalive guard during uploads.
- Auto-off timer guard refresh loop during uploads.
- Network reconnect watcher that auto-triggers retry when internet returns and pending uploads exist.
- Cooldown and polling controls for reconnect retry behavior.

### F) Alerts and observability

- Native macOS notifications for prompts and status.
- Optional Slack webhook alerts.
- Optional ntfy alerts with per-event toggles.
- Supported ntfy events:
  - Staging started
  - Card ejected
  - Upload started
  - Upload complete
  - Mount failed
  - Card almost full risk
  - Integrity warning
- Card almost-full heuristic alert based on free space vs last import size.
- Run status file for real-time UI and automation reads.
- Debug snapshot script for operational troubleshooting.

### G) Desktop app experience

- Main dashboard with phase, progress, ETA, counters.
- Checklist block with green/done states and blocked states.
- Quick links to staging and destination folders.
- Health panel: free space, pending count, staging folder count.
- Retry pending uploads action.
- Safe cleanup action.
- Settings tabs: General, Naming, Detection, Notifications, Cloud, Calendar.
- First-run wizard for staging folder, destination folder, fallback backup,
  auto-eject, scan window, offline shoot name, and ntfy basics.
- Restart setup wizard button in General settings; each wizard page can be
  skipped.
- General settings include destination mode, destination folders, theme, and update checks.
- Launch-size setting: remember last window size, compact, or large.
- Info tooltips (`i`) for key settings.
- Theme mode: light/dark/system.

### H) Packaging and deployment behavior

- Installer creates/updates app support layout and LaunchAgents.
- Config migration and missing-key backfill in installer.
- Mount agent installed with app.
- Network watcher agent installed with app.
- Uninstaller removes agents while preserving data.

## Differentiators vs Generic Sync Apps

- Ingest logic is card-aware, not folder-sync-only.
- Recovery is explicit and stateful, not hidden retry loops.
- Transfer lifecycle is visible to operators.
- Card ejection behavior is controlled by ingest state.
- Trust and source-folder logic reduce accidental imports.
- Destination verification reduces false “done” states.

## Sales Angles by Buyer Type

### 1) Solo photographer

- "Stop babysitting uploads between shoots."
- "Use local staging as automatic insurance."
- "Get push alerts when it’s truly complete."

### 2) Studio manager

- "Standardize ingest process across shooters/assistants."
- "Reduce missing-file incidents and editor delays."
- "Use receipts/logs as accountability artifacts."

### 3) High-volume event shooter

- "Cluster cards from multiple bodies into one shoot timeline."
- "Insert cards back-to-back and keep momentum."
- "Resume cloud transfer automatically when network stabilizes."

## Suggested Pricing Narrative

- This is not “just transfer software”; it is ingest reliability infrastructure.
- Price against avoided failure costs:
  - Reshoots
  - Late deliveries
  - Editor idle time
  - Lost trust from clients
- Package tiers idea:
  - Solo
  - Team/Studio
  - Premium support + onboarding

## Objection Handling

### "Can’t I just use Google Drive app?"

Yes, but generic sync apps do not manage card trust, lookback ingest logic, reinsert-first recovery, upload completeness verification, and operational checklist flow.

### "What if internet is down?"

DDump stages locally and retries delivery automatically. Reconnect watcher triggers when internet returns.

### "What cloud services work?"

Any service that syncs a local folder works: Google Drive Desktop, Dropbox, Box,
OneDrive, iCloud Drive, pCloud, NAS folders, and local disks. DDump handles card
ingest and organization, then copies into that folder; the provider app handles
cloud sync.

### "What if mount drops?"

Normal consumer setup does not rely on a DDump-managed mount. Advanced rclone
fallback mode preflights state, retries with backoff, guards timer during upload,
and alerts on failure.

### "What if files are missing?"

DDump keeps staging copies, tracks incomplete state, prioritizes recovery on reinsert, and sends warnings.

## Content Ideas for Marketing Assets

- Before/after workflow diagrams.
- "Day in the life" reel: card insert → eject → background upload → ntfy complete.
- Failure scenario demos:
  - Pull network mid-transfer.
  - Mount drop mid-transfer.
  - Reinsert card recovery.
- Screenshot carousel:
  - Checklist UI
  - Cloud diagnostics
  - Naming settings
  - Alert toggles

## 15 Strong Next Features (Roadmap Brainstorm)

1. Automatic per-card health score (read/write anomalies, retries, failures) in diagnostics.
2. Card wear/capacity trend analytics and proactive replacement suggestions.
3. Destination SLA monitor (time-to-upload, queue age) with threshold alerts.
4. Duplicate-content detector across shoots with review UI before deletion.
5. Verification profile presets (fast, balanced, paranoid) with one-click switching.
6. Assisted recovery wizard for “missing files” that guides reinsert and confirms closure.
7. Team roles + lockable settings profiles for assistant-proof workflows.
8. Per-client delivery rules (destination routing templates by shoot metadata).
9. Auto-priority queue (urgent client shoots upload first).
10. End-to-end checksum manifest export for legal/archival workflows.
11. Smart bandwidth mode (adaptive transfers/checkers by network quality).
12. Offline-first field mode preset for travel/event environments.
13. One-click “handoff package” bundle for editors (folder + manifest + receipt).
14. Shoot timeline view combining imports across cards/cameras for the day.
15. Built-in onboarding checklist + test mode for first-time installs.

## Messaging Variations

- Reliability-centric: "Never wonder if your files made it."
- Speed-centric: "Dump cards fast, let cloud finish in the background."
- Stress-centric: "Shoot more. Babysit less."
- Team-centric: "Standardize ingest across your whole studio."

## One-line Tagline Options

- "DDump: card ingest you can trust."
- "From card to cloud, with proof."
- "Fast local dump. Reliable cloud handoff."
- "Insert card. Keep shooting."
