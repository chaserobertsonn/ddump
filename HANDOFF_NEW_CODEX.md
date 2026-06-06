# DDump Handoff for New Codex Session

Start in the real DDump checkout:

```bash
cd /Users/chase/Personal-Projects/DDump
```

Do not use `/Users/chase/DFP Coding/DDump`; that stale path does not exist and
causes cmux/Codex hook errors before tool calls can run.

## Current Branch State

- Repo: `https://github.com/chaserobertsonn/ddump.git`
- Main app: `app/DDumpApp.swift`
- Import engine: `bin/ddump.sh`
- Installed app target: `/Users/chase/Applications/DDump.app`
- User config: `/Users/chase/Library/Application Support/DDump/config.env`

## Recent Fixes Already Pushed

- Fixed rclone failure handling so a failed cloud upload cannot be reported as
  successful.
- Fixed the main checklist so cloud uploads count as destination work even when
  local post-eject move is disabled.
- Manually recovered the missing `Cluster 2 12_46-12_59` upload for 2026-06-05
  and verified 123 local files vs 123 remote files.

## Calendar Wizard Work Added

The Calendar settings tab now has public-app setup options instead of terminal
instructions:

- Google Calendar: app-side browser sign-in entry point. Legacy developer flow
  can use an existing `gcalcli`; true public release still needs a bundled
  native OAuth client/helper.
- Apple Calendar: uses EventKit and the normal macOS Calendar permission prompt.
- Calendar Link: accepts and validates a private `.ics` or `webcal` URL.
- Calendar ambiguity prompts setting: keeps future main-screen questions enabled
  for clusters outside scheduled event windows.

Config keys added:

```text
CALENDAR_PROVIDER="none"        # none | google | apple | ics
CALENDAR_AUTH_STATUS="not_authorized"
CALENDAR_ICS_URL=""
CALENDAR_NAME=""
CALENDAR_EVENT_PADDING_MIN="15"
CALENDAR_AMBIGUITY_PROMPTS_ENABLED="1"
```

The app bundle Info.plist now includes Calendar privacy usage strings in both
`bin/install.sh` and `scripts/build-app.sh`.

## Still Needed

1. Implement real Google Calendar native OAuth for public release.
   - Use a desktop/native OAuth client with PKCE.
   - Do not require Terminal, Homebrew, or user copy/paste.
   - Store tokens in the user keychain or a secure app-support token file.
2. Add actual Apple Calendar and ICS lookup backends to
   `bin/ddump-calendar-lookup.sh` or a new helper.
   - Current lookup still primarily uses the legacy Google helper.
3. Implement pending calendar ambiguity questions on the main screen.
   - For clusters outside an event window, offer previous event, next event, or
     Other/manual name.
   - After the answer, rename/move the destination folder and re-run cloud
     verification.
4. Implement Google Drive Desktop primary transport with rclone verification.
   - Optional launch Google Drive at job start.
   - Copy into the local Drive folder when healthy.
   - Verify remote with rclone.
   - Fall back to direct rclone upload for missing files.
   - Optional quit Google Drive after verified complete.

## Validation Commands

```bash
bash -n bin/*.sh
swiftc -parse-as-library -o /private/tmp/DDump-check app/DDumpApp.swift
./bin/install.sh
git status --short
```

After installing, open `/Users/chase/Applications/DDump.app`, go to Settings ->
Calendar, and check that the new wizard appears. Apple Calendar should open a
macOS permission dialog. Calendar Link should reject non-calendar URLs and accept
real private ICS links.
