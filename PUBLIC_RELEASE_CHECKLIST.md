# Public Release Checklist

## Completed

- MIT license added.
- Internal audit/scope notes removed from the public tree.
- Private drive names and personal default notification topic removed from shipped defaults.
- Update checks are off by default and use GitHub Releases when enabled.
- DMG packaging script added for unsigned early-tester distribution.
- Shell syntax check passes with `bash -n bin/*.sh`.
- Swift parse check passes with a writable module cache.
- Calendar settings wizard added with Apple Calendar permission, Calendar Link
  validation, and Google Calendar browser-sign-in entry point.
- Apple Calendar is now the recommended public calendar path. DDump caches
  upcoming local Mac Calendar events for background imports, so Google OAuth is
  optional instead of required for normal calendar naming.
- Bundled Google Calendar OAuth helper added. It uses the desktop PKCE flow,
  read-only Calendar scope, and a secure local app-support token file.
- First-run wizard added for staging folder, destination folder, fallback
  destination, auto-eject, scan window, offline shoot name, and ntfy topic.
- First-run wizard can be restarted from Settings -> General, and each page can
  be skipped.
- Settings window is capped to a bounded size, and the main window minimum size
  was reduced for smaller laptop screens.
- Folder destinations are provider-neutral. Any cloud app that exposes a local
  synced folder can be used before rclone fallback is needed.
- Smart folder sample paths now preview inferred future folders in the app.
- Destination shoot folders are flat by default so final uploads do not nest
  camera-card folders like `DCIM/101_2026`.

## Known Limitations

- The app is currently unsigned and not notarized. Early testers may need to approve it
  in macOS Privacy & Security after first launch.
- Auto-update is not Sparkle yet. DDump checks GitHub Releases and opens the
  installer asset or release page for the user. Full one-click/automatic app
  replacement should wait until the app is signed and notarized.
- Cloud syncing through a local synced folder requires the user's sync app
  (Google Drive Desktop, Dropbox, Box, OneDrive, iCloud Drive, pCloud, etc.) to
  be installed and signed in. rclone remains an advanced fallback/verification
  path, not the primary consumer setup.
- Google Calendar OAuth cannot complete while the Google Cloud consent screen is
  in Testing unless the signed-in account is added as a test user. Publish or
  verify the consent screen before broad release. Apple Calendar avoids this by
  using local macOS Calendar permission.
- The Desktop OAuth credential's client secret must be present in
  `GOOGLE_CALENDAR_CLIENT_SECRET`; it comes from the Google Cloud downloaded
  OAuth JSON and is not a user password.
- Calendar ambiguity questions are configured in settings; the full post-upload
  rename/move workflow for answered questions still needs end-to-end testing.

## Pre-Release Checks

- Run `bash -n bin/*.sh`.
- Run `CLANG_MODULE_CACHE_PATH=/private/tmp/ddump-clang-cache swiftc -parse-as-library -o /private/tmp/DDump-check app/DDumpApp.swift`.
- Run `./scripts/public-readiness-check.sh`.
- Build the DMG with `./scripts/package-dmg.sh`.
- Install from the DMG on a clean macOS user account.
- Confirm Settings opens, Cloud setup stays opt-in, and update checks are off by default.
- Confirm the first-run wizard appears on a clean account and can be completed
  without Terminal access.
- Confirm Calendar setup can connect Apple Calendar without terminal access.
- Confirm Calendar Link accepts a private ICS URL and rejects non-calendar URLs.
- Confirm Google Calendar browser sign-in works with a Google account that is
  allowed by the OAuth consent screen.
- Confirm smart folder sample preview matches the intended tomorrow/next-week
  destination structure.
- Measure app bundle size and idle RSS on a clean Mac before public marketing.

## Senior-Dev Public-Launch Follow-Ups

- Sign and notarize with Apple Developer ID.
- Add Sparkle or an equivalent signed update feed after notarized builds are
  stable. Until then, the in-app updater should only open the latest installer.
- Position Mac Calendar as the primary public calendar path. Keep direct Google
  Calendar OAuth optional unless enough users need it to justify Google's
  verification process.
- Add a clean-account QA script that covers first launch, Apple Calendar
  permission, staging copy, destination copy, no-internet import, and ntfy-off
  default behavior.
- Keep rclone/mount alerts disabled by default and verify old LaunchAgents are
  removed during upgrades.
- Trim packaged image assets so source-brand PNGs do not inflate the app bundle.
- Profile idle memory and CPU on Intel, Apple Silicon, and 8 GB RAM Macs.
