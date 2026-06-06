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
- Bundled Google Calendar OAuth helper added. It uses the desktop PKCE flow,
  read-only Calendar scope, and a secure local app-support token file.

## Known Limitations

- The app is currently unsigned and not notarized. Early testers may need to approve it
  in macOS Privacy & Security after first launch.
- Auto-update is not Sparkle yet. DDump checks GitHub Releases and opens the
  download page for the user.
- Cloud syncing requires rclone setup through the app's Cloud settings.
- Google Calendar OAuth cannot complete while the Google Cloud consent screen is
  in Testing unless the signed-in account is added as a test user. Publish or
  verify the consent screen before broad release.
- The Desktop OAuth credential's client secret must be present in
  `GOOGLE_CALENDAR_CLIENT_SECRET`; it comes from the Google Cloud downloaded
  OAuth JSON and is not a user password.
- Calendar ambiguity questions are configured in settings; the full post-upload
  rename/move workflow for answered questions still needs end-to-end testing.

## Pre-Release Checks

- Run `bash -n bin/*.sh`.
- Run `CLANG_MODULE_CACHE_PATH=/private/tmp/ddump-clang-cache swiftc -parse-as-library -o /private/tmp/DDump-check app/DDumpApp.swift`.
- Build the DMG with `./scripts/package-dmg.sh`.
- Install from the DMG on a clean macOS user account.
- Confirm Settings opens, Cloud setup stays opt-in, and update checks are off by default.
- Confirm Calendar setup can connect Apple Calendar without terminal access.
- Confirm Calendar Link accepts a private ICS URL and rejects non-calendar URLs.
- Confirm Google Calendar browser sign-in works with a Google account that is
  allowed by the OAuth consent screen.
