# Legacy GitHub Updater Migration

The current public v0.3.14 install can discover only GitHub Releases. New
Sparkle builds must never depend on GitHub after migration.

## Implemented foundation

- The legacy checker uses strict semantic ordering and cannot offer an equal or
  older release.
- Sparkle 2.9.6 is pinned by version and archive SHA-256.
- Migration builds can enable Sparkle with stable/beta feed URLs and an
  embedded public EdDSA key.
- New builds prefer Sparkle; the GitHub path runs only when Sparkle is disabled.
- Helper resources are versioned inside the app and synchronize only at safe
  idle after an update.

## Required release sequence

1. Configure and verify the R2 stable asset and signed stable appcast.
2. Build a signed/notarized migration release from protected `main` with
   Sparkle enabled.
3. Publish only that migration release through GitHub so v0.3.14 can discover
   it.
4. On a clean test Mac, preserve config, trust records, pending work, receipts,
   logs, account state, entitlement state, and customer files while installing
   the migration release.
5. Publish a higher Sparkle stable test item and verify the migration build
   discovers, verifies, downloads, and installs it only at safe idle.
6. Verify beta never appears to a stable install and tampered feed/archive are
   rejected.
7. Keep the GitHub migration asset available through an owner-approved adoption
   and support window.

No GitHub release, R2 object, appcast, website link, or production feed was
changed by this implementation branch.
