# DDump v2 — independent audit (for Codex)

You are reviewing **DDump**, a Mac auto-importer for camera/SD cards written
collaboratively over two long sessions. The owner (a real-estate photographer)
wants an independent audit focused on **stability**, **speed**, and **feature
gaps**. This document gives you the full context so you don't waste tokens
rediscovering it.

Read this first. The relevant files are listed below — read them directly,
don't grep for them.

---

## 1. What DDump is

A Mac app + bash importer that:

1. Detects when an SD/photo card is inserted (LaunchAgent on `StartOnMount`).
2. Quickly scans for photo files (extensions list — JPG, CR3, DNG, MP4, MOV, etc.).
3. If the card has photos AND is trusted (by UUID or name prefix), prompts or
   auto-imports.
4. Copies files into `~/Temp/YYYY-MM-DD-dump/` locally with SHA-256 verification +
   manifest dedup so already-imported files are skipped.
5. Re-organizes the imported files into "bucket" folders by one of several
   naming strategies: `cluster` (time gaps), `calendar` (event title from Google
   Calendar — not yet wired), `sequential` ("Dump 1" / "Dump 2"...), `custom`
   (cycle through user-defined names), `camera` (raw card folder names).
6. Moves the bucketed folders to a Google Drive destination through an rclone
   macFUSE mount.
7. Auto-ejects the card on success (with a 60-sec grace, skippable via UI button).
8. Sends macOS notifications at start, copy-complete, upload-complete via
   `osascript display notification`.

The Mac app (`~/Applications/DDump.app`, SwiftUI) is a UI shell that:
- Reads `~/Library/Application Support/DDump/state/run_status.env` to display
  live progress (polled every 1 sec).
- Reads/writes `~/Library/Application Support/DDump/config.env` via a Settings
  sheet.
- Writes control flags (pause / stop / eject_now) the bash script polls.
- Can update its own icon via `Contents/Resources/AppIcon.icns`.

---

## 2. Where everything lives

### Workspace (source of truth — edit here)
- `~/DFP-Coding/dump/` on `dfp-server` (a Hetzner Linux box; the photographer's
  laptop sees it via sshfs at `/Users/chaserobertson/dfp-server/DFP-Coding/dump/`)
- `bin/` — all shell scripts
- `config/config.env` — default config
- `app/DDumpApp.swift` — the Swift app, single file (~800 lines)
- `SCOPE.md` — running scope/status doc
- `README.md` — user-facing readme (slightly stale)
- `audit/` — this folder; reports for the owner
- `zz-archive/` — old throwaway scripts (e.g., recover-ddump-mac.sh)

### Installed copy (running here)
- `~/Library/Application Support/DDump/` on the Mac
  - `bin/` — copies of the shell scripts, deployed by `install.sh`
  - `config.env` — user-edited config (preserved across reinstalls; `install.sh`
    adds missing keys + migrates renamed keys)
  - `state/` — manifest, fast-seen index, trusted UUIDs, card policy, control flags
  - `logs/ddump.log`, `logs/launchd.out.log`, `logs/launchd.err.log`
  - `reports/daily-digest-YYYY-MM-DD.md`, `reports/missed-files-<runid>.tsv`

### App bundle
- `~/Applications/DDump.app` — built by hand (not Platypus — see "What we tried"
  below). Structure: `Contents/Info.plist`, `Contents/MacOS/DDump` (Swift binary,
  ~580 KB compiled with `swiftc -parse-as-library -O`),
  `Contents/Resources/AppIcon.icns` (optional, user-set via Settings).

### LaunchAgents
- `~/Library/LaunchAgents/com.ddump.plist` — fires `/bin/bash ddump.sh` on every
  mount event (`StartOnMount`).
- `~/Library/LaunchAgents/com.chase.rclone-gdrive.plist` — supervises the rclone
  mount; `KeepAlive` restarts it on crash, `ThrottleInterval 30`.

### rclone binaries (two!)
- `/opt/homebrew/bin/rclone` — Homebrew install. Used for non-mount operations
  (`rclone copy`, `rclone lsl`). **Homebrew strips the `mount` subcommand on macOS**,
  which is what kept biting us — the formula caveat says "use nfsmount instead".
- `~/bin/rclone` — **official rclone binary from rclone.org**, has full `mount`
  support. Used only by the mount script.

### Mount script
- `~/bin/rclone-gdrive-mount.sh` — launchd target for `com.chase.rclone-gdrive`.
  Force-unmounts any stale state, then `exec ~/bin/rclone mount combined: ~/GoogleDrive ...`.

---

## 3. Current rclone mount config (the key file to scrutinize)

```bash
~/bin/rclone mount combined: ~/GoogleDrive \
  --vfs-cache-mode full \
  --vfs-cache-max-size 30G \
  --vfs-cache-max-age 72h \
  --vfs-read-chunk-size 64M \
  --vfs-read-chunk-size-limit 1G \
  --dir-cache-time 12h \
  --poll-interval 1m \
  --buffer-size 64M \
  --transfers 8 \
  --checkers 16 \
  --drive-chunk-size 64M \
  --drive-acknowledge-abuse \
  --volname "GoogleDrive" \
  --noapplexattr \
  --noappledouble \
  --allow-non-empty \
  --exclude ".DS_Store" \
  --exclude "._*" \
  --exclude ".Spotlight-V100/**" \
  --exclude ".Trashes/**" \
  --exclude ".fseventsd/**" \
  --exclude ".TemporaryItems/**" \
  --exclude ".AppleDouble/**" \
  --exclude ".AppleDB/**" \
  --rc \
  --rc-addr 127.0.0.1:5572 \
  --log-file ~/Library/Logs/rclone-gdrive.log \
  --log-level INFO
```

### rclone config (~/.config/rclone/rclone.conf — tokens redacted)
- `[gdrive]` — personal My Drive, `scope = drive`, OAuth token
- `[dfp]` — `team_drive = 0ACCYPgzcDo1NUk9PVA` (Densley Film & Photo Shared Drive)
- `[kaizen]` — `team_drive = 0AJUcF48t7iOzUk9PVA` (Kaizen Creative Shared Drive)
- `[combined]` — `type = combine`, `upstreams = MyDrive=gdrive: Densley=dfp: Kaizen=kaizen:`

The combined remote is what the mount uses. Labels are space-free because the
`combine` backend's `upstreams` parser chokes on quoted-with-spaces labels.

---

## 4. What we tried & what changed (so you don't repeat)

### Transport: NFS → macFUSE (switched ~30 min before this audit)

- Started on `rclone nfsmount` because Homebrew's caveat said to.
- Owner reported constant "Server connections interrupted: GoogleDrive" popups
  in Finder during sustained use (drag/drop, multi-file moves).
- Diagnosed: rclone's built-in NFS server is single-threaded and stalls under
  Finder load; macOS NFS client times out after ~30 sec and pops the alert.
- **Switched to `rclone mount` (macFUSE)** via the official rclone binary at
  `~/bin/rclone`. Same kernel-level FUSE transport that the owner's existing
  sshfs-to-server mount uses successfully.
- Stress test (10 rapid deep-dir lists): cold 2s, warm 6–26ms. Mount line:
  `combined: on /Users/chaserobertson/GoogleDrive (macfuse, ...)`.
- macFUSE is currently 5.1.3 in the kernel. Apple has been threatening kext
  deprecation. Plan B = `rclone serve webdav` + macOS WebDAV client (slower,
  no kext). Not implemented.

### Platypus app build — failed, built by hand instead

- Tried `brew install --cask platypus` to wrap the bash. Cask is deprecated and
  hung in the CLI build. Tried `platypus_clt` directly — needed sudo (via
  `InstallCommandLineTool.sh`) to extract its embedded `ScriptExec` binary.
  No sudo available over SSH.
- Built a `.app` bundle by hand instead — just `Contents/Info.plist` +
  `Contents/MacOS/DDump`. Worked.
- Later replaced the bash launcher with a SwiftUI app (DDumpApp.swift). The
  LaunchAgent now invokes the bash script directly; the bash script does
  `open -g ~/Applications/DDump.app` when it has a real import to do, so the
  user sees a progress window.

### Settings opening — auto-bind broke, swapped to .sheet

- macOS SwiftUI's auto-bound `Settings { ... }` scene + Cmd+, kept silently
  not opening. Tried `NSApp.sendAction(Selector("showSettingsWindow:"))` and
  `@Environment(\.openSettings)` — neither reliably opened it.
- Workaround: present settings as a `.sheet` on the main window, bound to
  `@State var showingSettings`. The button calls `showingSettings = true` and
  uses `.keyboardShortcut(",", modifiers: .command)`. Bullet-proof but less
  "native" — settings appear as a sheet sliding down rather than a separate
  Settings window. Still has all five tabs.

### Window position memory

- Used `setFrameAutosaveName("DDumpMainWindow")` via a `WindowAccessor`
  NSViewRepresentable bridge. SwiftUI's `WindowGroup` doesn't expose
  frame-autosave directly. Verified to persist position + size across launches.

### Notifications — terminal-notifier hung, switched to osascript

- Originally used `terminal-notifier -actions ...` for the action-button trust
  prompt. Without Notification Center permission, `terminal-notifier -actions`
  hangs **indefinitely** (no timeout fires), blocking the script.
- Switched all action-button prompts to `osascript display dialog` — modal but
  reliable. Plain notifications still use `osascript display notification`.
- See `ddump-notify.sh`.

### Internal-volume skip — bug

- `is_internal_volume` (using `diskutil info | grep Internal`) was incorrectly
  marking some SD cards from USB-C readers as "Internal" → silent-skipped.
- Fixed: the internal-skip now also requires `! volume_has_photos`. If a volume
  has photo files, it's never silent-skipped just because diskutil mislabels it.

### Folder naming — `${VAR:-default}` parsing bug in bash 3.2

- `tmpl="${CLUSTER_FOLDER_TEMPLATE:-Cluster {n} {start}-{end}}"` — bash 3.2
  (the system `/bin/bash`) parses the first `}` as closing the parameter expansion,
  treating `} {start}-{end}}` as literal trailing text. Result: cluster folder
  names were doubled with garbage.
- Fixed by avoiding `:-` defaults that contain `}`:
  ```bash
  local tmpl="$CLUSTER_FOLDER_TEMPLATE"
  [[ -z "$tmpl" ]] && tmpl="Cluster {n} {start}-{end}"
  ```

### Eject-grace — 60-sec sleep made script look hung

- The eject-on-success path waits up to 60 sec (`EJECT_GRACE_SECONDS`, clamped
  to 60 min) before ejecting, so user can intervene. We mistakenly killed runs
  during this sleep thinking they were hung.
- Added an "Eject Now" button in the UI that touches `state/control/eject_now.flag`.
  `wait_for_min_eject_grace` checks for this flag and returns immediately.
  Also: the eject decision now allows ejecting when `run_stopped=1` if the flag
  is set, so the "Eject after this file" button works even when stop was requested.

### Manifest / fast-seen — migrated from old DFPDump

- `install.sh` renames `~/Library/Application Support/DFPDump/` → `DDump/` if the
  former exists. Manifest (7993 entries) + fast-seen (3514 entries) + trusted
  UUIDs preserved.
- Config keys migrated: `TRUSTED_NAME_PREFIX` → `TRUSTED_NAME_PREFIXES` (plural,
  comma-separated), `REQUIRE_DCIM_OR_TRUSTED` → `REQUIRE_PHOTOS_OR_TRUSTED`.

### Calendar strategy — not wired yet

- `ddump-calendar-lookup.sh` is a gcalcli wrapper that emits TSV rows
  (`start_epoch\tend_epoch\ttitle`) for a date. **Not yet integrated** into
  `rebucket_imported_files`. When `FOLDER_NAMING_STRATEGY=calendar` is selected,
  the script logs "calendar not yet wired" and falls through to the configured
  fallback (`cluster` by default).
- The Settings UI shows a placeholder Calendar tab with Install gcalcli and
  Authorize buttons.

---

## 5. Files to read directly (don't grep — these are the load-bearing ones)

In `~/DFP-Coding/dump/` on the server (or via the Mac mount at
`/Users/chaserobertson/dfp-server/DFP-Coding/dump/`):

- `SCOPE.md` — current phase status, decisions log
- `bin/ddump.sh` — main importer (~1800 lines). The volume loop starts around
  line 1394; `rebucket_imported_files` and friends are around lines 1280–1395.
- `bin/ddump-notify.sh` — notification wrapper (osascript / terminal-notifier /
  alerter dispatch)
- `bin/ddump-cluster.sh` — time-cluster helper that reads EXIF or mtime and
  emits per-file cluster assignments
- `bin/ddump-calendar-lookup.sh` — gcalcli wrapper (skeleton, not yet integrated)
- `bin/install.sh` — deploy + DFPDump→DDump migration logic
- `config/config.env` — defaults for ALL config knobs (the actual source of
  truth for what's tunable; user config has only overrides)
- `app/DDumpApp.swift` — full SwiftUI app, single file. `AppState` is the
  observable that polls the status file. `SettingsSheet` opens via `.sheet`.

Live system state (read these to verify what's running):
- `~/Library/LaunchAgents/com.ddump.plist`
- `~/Library/LaunchAgents/com.chase.rclone-gdrive.plist`
- `~/bin/rclone-gdrive-mount.sh`
- `~/Library/Application Support/DDump/config.env`
- `~/Library/Application Support/DDump/logs/ddump.log` (recent)
- `~/Library/Logs/rclone-gdrive.log` (recent)

---

## 6. Known live state (verify, but here's where it should be)

- macOS 26.5, arm64
- Swift 6.3.2 (Apple Silicon)
- macFUSE 5.1.3 (kext, loaded)
- rclone v1.74.1 (both Homebrew at `/opt/homebrew/bin/rclone` and official at
  `~/bin/rclone`)
- terminal-notifier installed (used for some plain notifications)
- gcalcli **not** installed (calendar strategy disabled in code)
- exiftool installed (cluster helper uses it for EXIF time, falls back to mtime)
- DDump.app at `~/Applications/DDump.app` (Swift binary, registered with
  Launch Services)
- Both LaunchAgents loaded + running
- Mount transport: **macFUSE** (just switched from NFS today)
- POST_MOVE_ROOT currently set to `~/GoogleDrive/MyDrive/_DDumpTest` for safe
  testing — owner will switch to the production Densley path after verification

---

## 7. What the owner cares about (in priority order)

1. **Stability of the mount during active use.** They organize files in Finder
   (drag/drop, rename, multi-file moves) for hours. The "Server connections
   interrupted: GoogleDrive" alert was the breaking issue under NFS. We just
   moved to macFUSE — they'll be testing real-world stability. Tell us if
   you see other failure modes likely to crop up.

2. **Speed of card import.** Especially: hash-verify is doubling read time on
   big MP4 files. The fast-seen index handles repeat files in milliseconds,
   but new files cost ~3× a single read. Worth reconsidering verification
   strategy (e.g., size + first-N-bytes check vs full SHA256)?

3. **The Calendar strategy.** Currently a stub. We need `compute_buckets_calendar`
   that takes the per-file capture times (from `ddump-cluster.sh` logic) and
   the events from `ddump-calendar-lookup.sh`, and emits `file\tbucket_name`
   matching event titles with ±15 min padding. Files outside any event window
   should fall through to the cluster fallback. Code review the cluster
   helper's approach + suggest the calendar function.

4. **Resumability.** The owner wants: if a card import is interrupted (eject,
   stop, crash), re-inserting the same card should pick up at the next
   un-imported file. This already works via the manifest + fast-seen index,
   BUT: rebucketing happens after the per-file copy loop completes, on the
   list of newly imported files for that run. If a run aborts mid-loop, the
   files copied so far never get rebucketed (they stay in `~/Temp/` under
   the camera folder name like `100EOSR7/`). The next run will skip those
   files (already in manifest) so they never make it to a bucket folder.
   **This is a real gap.** Suggest a clean fix.

5. **Window memory + UI polish.** Position persistence works
   (`setFrameAutosaveName`). Settings opens via sheet. There's no "menubar
   item" (owner explicitly doesn't want one). Live progress bar updates from
   the status file every 1 sec. Anything obviously missing?

---

## 8. Questions for you to specifically answer

Please write concrete recommendations, with code where relevant. Prioritize:

### Stability
- Is `rclone mount` (macFUSE) the right choice vs. per-drive separate mounts
  (`gdrive:` / `dfp:` / `kaizen:` each mounted individually)? The `combine`
  backend adds per-request overhead. Tradeoffs?
- Are the rclone tuning flags sensible for a real-estate photographer's
  workflow (5–50 GB of camera files per day)?
- What's a sane plan B for when Apple deprecates macFUSE kexts entirely?
  (rclone serve webdav? rclone serve nfs with tuned settings? Native sshfs
  via Apple's SMB?)
- The `--allow-non-empty` flag was added as a safety net. Any downsides we're
  not seeing?

### Speed
- The pre-copy SHA-256 hash (for manifest dedup) is unavoidable for new files.
  But could we add a "trust mtime+size" mode (skip hash if size+mtime match a
  manifest entry) as an optional fast path? Risk of false negatives?
- Hash-verify post-copy is a 3× read penalty on every new file. Worth keeping?
  Default off?
- `--vfs-cache-mode full` writes through a local cache. For an
  upload-only workflow (no random read), would `writes` mode be faster?

### Features
- Implement `compute_buckets_calendar` properly. Show us the function.
- Fix the resumability gap (rebucket gets skipped on interrupted imports →
  files orphaned in `~/Temp/` under camera folder names).
- The owner mentioned wanting a Slack webhook for completion notifications.
  Sketch a `slack_notify` function and where to plug it in `ddump.sh`.

### Anything else dangerous
- Are there places we're not setting `set -e` correctly, or where it's too
  aggressive (recall: bare `return 1` from a function inside an `if` clause is
  fine under set -e; bare `return 1` at the top level is not)?
- Race conditions in the rebucket → post-move sequence?
- File-naming sanitation: bucket names get `tr '/:' '__'`. Anything else macOS
  / Drive will choke on?
- Permissions: anything owned by root that shouldn't be? Anything writable
  by everyone that shouldn't be?

---

## 9. What NOT to recommend

- Don't recommend reinstalling Platypus — its installer hangs without sudo we
  can't grant over SSH; we've already built the .app by hand.
- Don't recommend the auto-bound Settings scene + Cmd+,; it doesn't work
  reliably on this Mac. We have a working sheet-based alternative.
- Don't recommend `rclone nfsmount` again — confirmed unstable for daily
  Finder use.
- Don't recommend `terminal-notifier -actions` for action-button prompts; it
  hangs without Notification Center permission.
- Don't suggest "uninstall Google Drive Mac app" as a solution to anything —
  it's already uninstalled (the owner reinstalled it earlier as a workaround
  for the NFS issue, then removed it again).

---

## 10. How the owner wants the audit output

Concrete, code-included recommendations. Not philosophy. Specifically:

1. **Stability findings**: each issue → file:line → proposed change (or full
   replacement function).
2. **Speed findings**: same format.
3. **Feature implementations** for the three open items (calendar bucketing,
   resumability, Slack notify).
4. **Anything dangerous** they should know about.

Output as one Markdown document the owner can paste-review with us.

When in doubt about current behavior: read the files listed in section 5 of
this prompt rather than asking.
