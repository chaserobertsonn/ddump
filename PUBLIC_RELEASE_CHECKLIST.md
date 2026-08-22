# Public Release Checklist

Last evidence review: 2026-08-22

This checklist covers public distribution. Paid-launch architecture and commerce gates are in:

- `docs/PAID_LAUNCH_ARCHITECTURE.md`
- `docs/RELEASE_AUTOMATION.md`
- `docs/DONNA_OPERATIONS.md`
- `docs/GO_LIVE_CHECKLIST.md`

A checked box requires command output, CI evidence, or authoritative external readback.

## Status vocabulary

- **VERIFIED**: backed by evidence.
- **COMPLETED**: implemented and backed by cited evidence.
- **PLANNED**: not implemented or verified.
- **BLOCKED**: dependency or safety gate prevents progress.
- **OWNER DECISION**: requires explicit owner choice or approval.

## Current release snapshot

### VERIFIED

- [x] Repository `chaserobertsonn/ddump` is public and defaults to `main`.
  - Evidence: GitHub repository readback on 2026-08-22.
- [x] Gatekeeper fix `fcf2ba7` merged through PR #3 as `338e231`, and post-merge macOS CI passed.
  - Evidence: GitHub PR, merge, and main check-run readback on 2026-08-22.
- [x] DDump 0.3.18 built as universal `arm64` and `x86_64` for macOS 13+.
  - Evidence: local Mac public-readiness output and successful macOS CI.
- [x] Local 0.3.18 DMG has valid disk-image checksum, Developer ID signature, Apple notarization ticket, and Gatekeeper acceptance.
  - Evidence: read-only local Mac `codesign`, `hdiutil`, `stapler`, and `spctl` validation on 2026-08-22; Apple notarization submission `4b653a42-e63f-408d-b031-8564165101e6` returned `Accepted`.
  - `xcrun stapler validate`: worked.
  - `spctl`: accepted, `source=Notarized Developer ID`.
  - SHA-256: `c723f1ec3ed95c900a0923d215335373a9d1606a3d21ecb7b087a342df056dbd`.
- [x] Latest public GitHub Release is v0.3.14.
  - Evidence: GitHub Releases readback on 2026-08-22.
- [x] Live `ddump.app` download buttons still point to GitHub-hosted v0.3.14.
  - Evidence: HTTPS 200 readback and parsed links on 2026-08-22.
- [x] Current updater checks the public GitHub Releases API and opens a DMG/ZIP/release page.
  - Evidence: source inspection on 2026-08-22.
- [x] Sparkle is not implemented.
  - Evidence: source/repository search on 2026-08-22.
- [x] MIT License exists in the repository.
  - Evidence: `LICENSE` readback on 2026-08-22.

### COMPLETED

- [x] Public packaging fails closed without explicit Developer ID and notarytool profile variables.
  - Evidence: `scripts/package-dmg.sh` source inspection and release command behavior.
- [x] Packaging signs/notarizes the app and final DMG, staples tickets, and verifies signatures/Gatekeeper.
  - Evidence: packaging source inspection and 0.3.18 local validation output.
- [x] CI builds an unsigned test DMG and verifies universal app and installer binaries.
  - Evidence: `.github/workflows/macos-ci.yml` readback and successful PR #3 checks.
- [x] Current public updater is disabled by default and does not silently replace the app.
  - Evidence: `config/config.env`, `bin/install.sh`, and updater source inspection.
- [x] Signed installer app replaces the old Terminal-based install path.
  - Evidence: packaging/installer source inspection and CI artifact construction.
- [x] Source defaults remove known private drive names and personal notification topics.
  - Evidence: repository default/config inspection and public-readiness checks.

### PLANNED

- [ ] Treat 0.3.18 as a private-beta candidate, not the paid marketing release.
- [ ] Implement Sparkle 2 with EdDSA signatures.
- [ ] Publish immutable assets through Cloudflare R2 at `downloads.ddump.app`.
- [ ] Publish separate beta/stable appcasts at `updates.ddump.app`.
- [ ] Add protected beta/stable promotion and rollback automation.
- [ ] Complete the paid-launch, entitlement, legal, support, and monitoring gates.

### BLOCKED

- [ ] Do not publish 0.3.18 as paid stable until `docs/GO_LIVE_CHECKLIST.md` passes.
- [ ] Do not change the repository to private while downloads or updates rely on public GitHub URLs.
- [ ] Do not claim full automatic updates until Sparkle is implemented and verified.
- [ ] Do not describe existing MIT-licensed copies as proprietary.

### OWNER DECISION

- [ ] Approve private-beta audience and release notes.
- [ ] Approve stable paid release version and rollout.
- [ ] Approve future licensing after legal review.
- [ ] Approve repository visibility only after GitHub distribution dependencies are removed.

## 0.3.18 private-beta candidate gate

- [x] Universal macOS 13+ build evidence exists.
  - Evidence: local Mac public-readiness output and successful PR #3 macOS CI.
- [x] Developer ID signature, Apple notarization, stapling, disk-image checksum, and Gatekeeper validation evidence exist.
  - Evidence: local Mac `codesign`, `hdiutil`, `stapler`, and `spctl` output.
- [x] Gatekeeper fix commit is merged and post-merge CI passes.
  - Evidence: PR #3 merged as `338e231`; main `build-and-package` check completed successfully on 2026-08-22.
- [ ] Install from the final DMG on a clean non-developer Mac account.
- [ ] Verify version, bundle identifier, app location, installer behavior, and first launch.
- [ ] Run a real-card smoke test: detect, copy, verify, organize, backup handoff, and eject last.
- [ ] Run interrupted network and unavailable-backup recovery.
- [ ] Update from v0.3.14 without losing config, trust records, pending work, receipts, logs, or customer files.
- [ ] Verify app update/install cannot relaunch during active card work.
- [ ] Record known issues, tester list, exact SHA-256, source commit, and expiration/distribution scope.
- [ ] Obtain owner approval before distributing the private beta.

## Public distribution migration

The current website and updater depend on public GitHub. Required order:

1. [ ] Configure and verify `downloads.ddump.app`.
2. [ ] Configure and verify `updates.ddump.app/beta/appcast.xml`.
3. [ ] Configure and verify `updates.ddump.app/stable/appcast.xml`.
4. [ ] Publish an immutable signed/notarized test asset to R2.
5. [ ] Verify anonymous HTTP 200, TLS, content type, length, SHA-256, and cache headers.
6. [ ] Implement Sparkle 2 and reject tampered appcasts/assets.
7. [ ] Verify beta and stable channel separation.
8. [ ] Publish a signed/notarized migration release through the current public GitHub updater and test `v0.3.14 -> migration release -> Sparkle stable`.
9. [ ] Change website links only after the approved R2 stable asset readback passes.
10. [ ] Keep the public GitHub API/migration asset available through an approved adoption threshold and legacy-client support window.
11. [ ] Remove the app's public GitHub Releases dependency only after migration evidence passes.
12. [ ] Exercise rollback, higher-version forward fix, and out-of-band rescue installer.
13. [ ] Obtain legal review of MIT/future licensing.
14. [ ] Only then consider repository privacy with explicit owner approval.

## Release automation gate

- [ ] PR CI runs without production secrets.
- [ ] Candidate build is manual and version/SHA-specific.
- [ ] Build/test/sign/notarize/staple/verify/checksum/appcast/R2 steps fail closed.
- [ ] Apple notarization must return `Accepted`.
- [ ] Gatekeeper must report Notarized Developer ID.
- [ ] Sparkle EdDSA private key remains in protected release secrets.
- [ ] R2 credentials are least privilege and environment-scoped.
- [ ] Candidate asset is immutable and read back after upload.
- [ ] Merge to `main` changes no customer feed.
- [ ] Beta promotion requires protected Environment approval.
- [ ] Stable promotion requires a separate protected Environment approval.
- [ ] Rollout expansion requires approval.
- [ ] Workflow records source SHA, manifest/checksum, approver, previous known-good version, and deployment timestamps.

## Clean install and update checks

- [ ] Clean macOS 13+ account installs without Terminal or security bypass.
- [ ] Gatekeeper accepts app and installer.
- [ ] First-run setup works without production credentials.
- [ ] Existing v0.3.14 config and data survive update.
- [ ] Trust records, pending uploads, receipts, logs, and customer files survive update.
- [ ] Failed update leaves current version functional.
- [ ] Update download/install never interrupts import or unsafe-ejects a card.
- [ ] Apple Silicon passes.
- [ ] Intel passes or an owner-approved equivalent environment passes.

## Paid public-release checks

- [ ] Monthly purchase passes.
- [ ] Yearly purchase passes.
- [ ] Trial passes.
- [ ] Restore passes.
- [ ] Second Mac passes.
- [ ] Expired subscription passes safe-idle behavior.
- [ ] Refund passes safe-idle behavior.
- [ ] Offline grace passes with signed entitlement.
- [ ] Billing and entitlement outages do not interrupt active import.
- [ ] Cancellation and failed renewal preserve paid-through access and customer files.
- [ ] No permanent client-side license key is used.

## Known limitations in the current public code

- Auto-update is not Sparkle. The app checks GitHub Releases and opens an installer or release page.
- Update checks and automatic opening are off by default.
- The public website still downloads v0.3.14 from GitHub.
- The current GitHub Actions workflow does not sign, notarize, staple, publish, generate an appcast, upload to R2, promote channels, or roll back.
- Cloud sync through local provider folders depends on the customer's signed-in sync app. Direct rclone remains an advanced path.
- Google Calendar OAuth still requires proper consent-screen/test-user configuration where applicable.
- Calendar ambiguity and post-upload rename/move behavior still require full end-to-end release testing.

## Licensing gate

DDump currently contains an MIT license. Subject to legal review of the full repository, contribution history, and third-party components, copies already distributed under MIT retain valid permissions granted under the applicable license terms. A later repository-visibility or future-license change is not expected to revoke valid existing grants.

- [ ] Legal review covers existing MIT grants and future licensing.
- [ ] Contributor-rights audit is complete.
- [ ] Future release and website language accurately distinguishes prior MIT releases from any later terms.
- [ ] Owner approves the future source and licensing model.

## Final public-release approval

- [ ] Exact version, source SHA, artifact SHA-256, appcast, and manifest are identified.
- [ ] All required tests and legal/operations gates pass.
- [ ] Owner approves the channel and rollout.
- [ ] Public asset and appcast external readback pass.
- [ ] Monitoring and rollback are live.
- [ ] Stable promotion is performed as an explicit action, not a merge side effect.
