# Public Release Checklist

Last evidence review: 2026-09-01

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
- [x] Public v0.3.14 uses the GitHub Releases API and predates Sparkle.
  - Evidence: baseline source inspection on 2026-08-22; no public migration release has been published.
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
- [x] Implementation branch pins Sparkle 2.9.6, rejects updater downgrades, embeds stable/beta configuration, signs enclosures/feeds synthetically, and defers install/relaunch until safe idle.
  - Evidence: `docs/IMPLEMENTATION_EVIDENCE_2026-09-01.md`.
- [x] Protected candidate/beta/stable workflow code and immutable R2/appcast promotion/rollback tooling are implemented with no production activation.
  - Evidence: workflow/action-pin/static/synthetic release tests on 2026-09-01.

### PLANNED

- [ ] Treat 0.3.18 as a private-beta candidate, not the paid marketing release.
- [ ] Exercise Sparkle with a real protected signed/notarized candidate and clean Mac update.
- [ ] Publish and externally verify immutable assets through Cloudflare R2 at `downloads.ddump.app` after approval.
- [ ] Publish and externally verify separate beta/stable appcasts at `updates.ddump.app` after approval.
- [ ] Configure and exercise protected beta/stable Environments, promotion, and rollback.
- [ ] Complete the paid-launch, entitlement, legal, support, and monitoring gates.

### BLOCKED

- [ ] Do not publish 0.3.18 as paid stable until `docs/GO_LIVE_CHECKLIST.md` passes.
- [x] Keep the repository public and MIT licensed; visibility and licensing changes are out of scope.
- [ ] Do not claim full automatic updates until Sparkle is externally verified.

### OWNER DECISION

- [ ] Approve private-beta audience and release notes.
- [ ] Approve stable paid release version and rollout.

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
6. [x] Implement pinned Sparkle 2 and synthetically reject tampered appcasts/assets.
7. [x] Implement separate beta/stable URLs and channel allowlisting; external feed verification remains pending.
8. [ ] Publish a signed/notarized migration release through the current public GitHub updater and test `v0.3.14 -> migration release -> Sparkle stable`.
9. [ ] Change website links only after the approved R2 stable asset readback passes.
10. [ ] Keep the public GitHub API/migration asset available through an approved adoption threshold and legacy-client support window.
11. [ ] Remove the app's public GitHub Releases dependency only after migration evidence passes.
12. [ ] Exercise rollback, higher-version forward fix, and out-of-band rescue installer.
13. [ ] Obtain legal review of customer terms, privacy, refunds, tax, and accurate MIT-source representations.

## Release automation gate

- [x] PR CI is read-only and references no production secrets.
- [x] Candidate build is manual and exact version/build/SHA/channel-specific.
- [x] Workflow code fails closed on missing signing/notarization/signature/approval/readback inputs; real protected execution remains pending.
- [ ] Apple notarization must return `Accepted`.
- [ ] Gatekeeper must report Notarized Developer ID.
- [x] Sparkle EdDSA private key is referenced only as a protected Environment secret; configuration remains pending.
- [ ] R2 credentials are configured least privilege and environment-scoped.
- [ ] Candidate asset is immutable and read back after upload.
- [x] Merge/PR workflow contains no customer-feed mutation.
- [x] Beta promotion is isolated in a `release-beta` Environment workflow.
- [x] Stable promotion is isolated in a separate `release-stable` Environment workflow and does not rebuild the artifact.
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

## Known limitations before public cutover

- Public v0.3.14 is not Sparkle. The new bounded migration path exists only in the implementation branch and has not been published or exercised end to end.
- Update checks and automatic opening are off by default.
- The public website still downloads v0.3.14 from GitHub.
- Release workflows are implemented but no real protected candidate, R2 upload, appcast promotion, or external readback has run.
- Cloud sync through local provider folders depends on the customer's signed-in sync app. Direct rclone remains an advanced path.
- Google Calendar OAuth still requires proper consent-screen/test-user configuration where applicable.
- Calendar ambiguity and post-upload rename/move behavior still require full end-to-end release testing.

## Public repository and MIT license invariant

- [x] Repository remains public.
- [x] MIT license remains unchanged.
- [x] Release automation does not mutate repository visibility or licensing.
- [ ] Release and website language accurately describes the public MIT source and separately approved paid hosted services.

## Final public-release approval

- [ ] Exact version, source SHA, artifact SHA-256, appcast, and manifest are identified.
- [ ] All required tests and legal/operations gates pass.
- [ ] Owner approves the channel and rollout.
- [ ] Public asset and appcast external readback pass.
- [ ] Monitoring and rollback are live.
- [ ] Stable promotion is performed as an explicit action, not a merge side effect.
