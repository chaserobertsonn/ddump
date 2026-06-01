# Public Release Checklist

## Completed

- MIT license added.
- Internal audit/scope notes removed from the public tree.
- Private drive names and personal default notification topic removed from shipped defaults.
- Update checks are off by default and use GitHub Releases when enabled.
- DMG packaging script added for unsigned early-tester distribution.
- Shell syntax check passes with `bash -n bin/*.sh`.
- Swift parse check passes with a writable module cache.

## Known Limitations

- The app is currently unsigned and not notarized. Early testers may need to approve it
  in macOS Privacy & Security after first launch.
- Auto-update is not Sparkle yet. DDump checks GitHub Releases and opens the
  download page for the user.
- Cloud syncing requires rclone setup through the app's Cloud settings.

## Pre-Release Checks

- Run `bash -n bin/*.sh`.
- Run `CLANG_MODULE_CACHE_PATH=/private/tmp/ddump-clang-cache swiftc -parse-as-library -o /private/tmp/DDump-check app/DDumpApp.swift`.
- Build the DMG with `./scripts/package-dmg.sh`.
- Install from the DMG on a clean macOS user account.
- Confirm Settings opens, Cloud setup stays opt-in, and update checks are off by default.
