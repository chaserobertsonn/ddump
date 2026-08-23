# DDump Release Automation

Last evidence review: 2026-08-22

This document defines the target release pipeline for signed DDump builds. It does not authorize a release and does not claim the target automation exists.

## Status vocabulary

- **VERIFIED**: backed by command output, CI evidence, or authoritative readback.
- **COMPLETED**: implemented and backed by cited verification evidence.
- **PLANNED**: approved direction, not implemented or verified.
- **BLOCKED**: dependency or safety gate prevents progress.
- **OWNER DECISION**: requires Chase's explicit choice or approval.

## Current release state

### VERIFIED

- GitHub repository `chaserobertsonn/ddump` is public; default branch is `main`.
- Gatekeeper fix `fcf2ba7` merged through PR #3 as `338e231`; PR and post-merge macOS CI passed.
- Current GitHub Actions runs `public-readiness-check.sh`, creates an unsigned DMG on `macos-14`, verifies universal `arm64` and `x86_64` app/installer binaries, and checks for `DDump-0.3.18-unsigned.dmg`.
- A local 0.3.18 DMG exists at `~/DFP-Coding/DDump-release-0317/dist/DDump-0.3.18.dmg` on Chase's Mac.
- Read-only validation on 2026-08-22 reported:
  - `hdiutil verify`: valid disk-image checksum.
  - `xcrun stapler validate`: worked.
  - `spctl`: accepted, `source=Notarized Developer ID`.
  - Developer ID signer: this is kaizen, LLC, Team ID `W4GNV4SRNU`.
  - SHA-256: `c723f1ec3ed95c900a0923d215335373a9d1606a3d21ecb7b087a342df056dbd`.
- Latest public GitHub Release is v0.3.14.
- The live site still links v0.3.14 from GitHub.
- The app still reads public GitHub Releases and opens an installer. Sparkle is absent.

### COMPLETED

- Local build/sign/notarize/staple/Gatekeeper validation for the 0.3.18 private-beta candidate.
- CI verification for the open Gatekeeper fix.

### PLANNED

- Sparkle 2 with EdDSA signatures.
- Cloudflare R2 distribution at `downloads.ddump.app`.
- Separate stable and beta appcasts at `updates.ddump.app`.
- GitHub Actions signing, notarization, stapling, verification, checksums, appcast generation, R2 upload, explicit promotion, monitoring, and rollback support.

### BLOCKED

- 0.3.18 must not be called the final paid marketing release.
- Stable distribution is blocked until R2, Sparkle, paid entitlement, safety, update-preservation, rollback, and monitoring tests pass.
- Repository privatization is blocked while anonymous downloads and updates use public GitHub URLs.

### OWNER DECISION

- Version chosen for the first paid stable release.
- Beta cohort, rollout percentages, minimum soak time, and stable health thresholds.
- Release-note wording, known issues, and customer communication threshold.
- Whether signing runs directly in GitHub-hosted macOS runners or through a more isolated signing service.

## Core release rule

**Merge is not release.**

A merge to `main` may create an unsigned validation artifact and a candidate manifest. It must not publish to the stable appcast, replace a customer download, send customer notifications, or make a build available to every customer.

Stable promotion requires a separate explicit release action protected by a GitHub Environment with a required owner reviewer.

## Release channels

### Private preview

- Audience: owner and named internal testers.
- Delivery: expiring private URL or access-controlled artifact.
- Not referenced by a public appcast.
- May be unsigned only for developer-only checks, but any normal-user preview must be Developer ID signed and notarized.

### Beta

- Audience: opt-in accounts or named beta cohort.
- Feed: `https://updates.ddump.app/beta/appcast.xml`.
- Assets: immutable objects under `https://downloads.ddump.app/beta/<version>/...`.
- Eligibility: server-persisted account assignment. The public readability of a beta feed or asset is not cohort authorization; the signed app selects beta only after an authenticated eligibility refresh.
- Requires signed, notarized, stapled, verified artifact and owner approval.
- A beta merge or upload does not change the stable feed.

### Stable

- Audience: approved customer rollout.
- Feed: `https://updates.ddump.app/stable/appcast.xml`.
- Assets: immutable objects under `https://downloads.ddump.app/stable/<version>/...`.
- Requires owner approval, beta evidence, monitored rollout plan, and rollback readiness.
- Rollout may be phased. Expanding the phase is an explicit approved action.

Percentage rollout assignment uses a deterministic hash of immutable account ID plus release ID, is persisted server-side, and is monotonic unless an incident pause/revocation is recorded. Operators must record cohort size, assignment rule, eligible count, served count, expansion history, pause state, and revocation behavior. Manually pointing a modified client at a public feed is unsupported and does not create a paid entitlement.

## Artifact layout

Recommended immutable object keys:

```text
releases/
  beta/<version>/DDump-<version>.dmg
  beta/<version>/DDump-<version>.dmg.sha256
  beta/<version>/release-notes.html
  beta/<version>/release-manifest.json
  stable/<version>/DDump-<version>.dmg
  stable/<version>/DDump-<version>.dmg.sha256
  stable/<version>/release-notes.html
  stable/<version>/release-manifest.json
appcasts/
  beta/appcast.xml
  stable/appcast.xml
manifests/
  candidates/<git-sha>.json
```

Custom-domain URLs may hide the bucket layout but must preserve immutability and channel separation.

Candidate storage is private. Beta and stable use separate mandatory write credentials and prefixes or buckets. Versioned assets deny overwrite and delete to release jobs; retention changes require a separately approved administrative path. Promotion credentials may update only the channel pointer/appcast they own, and clients never receive R2 credentials or bucket-list access.

Versioned assets use long-lived `public, max-age=31536000, immutable` caching. Mutable appcasts and channel pointers use revalidation-friendly headers such as `no-cache, must-revalidate`, ETags, and no stale-on-error policy that could keep advertising a withdrawn build. Promotion and rollback include CDN purge/revalidation plus independent probes from multiple locations.

A release manifest should record at least:

- Version and build number.
- Git commit SHA and source branch.
- Channel and promotion timestamp.
- macOS minimum version.
- Architectures.
- DMG byte size and SHA-256.
- Expected app bundle identifier `com.ddump.app`, installer bundle identifier `com.ddump.app.installer`, Apple Team ID `W4GNV4SRNU`, signing identity subject, and designated-requirement assertions for every nested executable/helper.
- Apple notarization submission IDs and accepted status.
- Stapler and Gatekeeper results.
- Sparkle EdDSA signature and length.
- Test run URLs and workflow run ID.
- Release notes URL.
- Approver and approval record.
- Previous known-good version.
- Rollback or forward-fix instructions.
- Cryptographic release-authorization signature over the manifest digest, source SHA, artifact digest, version, and channel. Its private key is isolated from R2; promotion verifies it against a pinned public key before changing any customer pointer.

No manifest may contain a secret or private key.

## Workflow separation

### 1. Pull request validation: `macos-ci.yml`

Trigger: push and pull request.

Permissions: read-only contents by default.

Required checks:

1. Checkout exact commit.
2. Run shell syntax, source consistency, privacy manifest, license, and public-readiness checks.
3. Build app and installer for macOS 13+.
4. Verify both binaries contain `arm64` and `x86_64`.
5. Build an explicitly named unsigned test DMG.
6. Run unit, integration, card-safety, entitlement-adapter, and update tests that do not require production secrets.
7. Verify no secret patterns, private keys, provisioning material, notarization outputs, or customer data entered the artifact.
8. Upload bounded CI artifacts for private review only.

This workflow must not access production signing, R2, Stripe, RevenueCat, or entitlement-service secrets.

### 2. Candidate build: `release-candidate.yml`

Trigger: manual `workflow_dispatch` from the protected default-branch workflow or an approved protected version tag policy. Not automatic on merge and never from a pull-request or fork-controlled workflow file.

Inputs:

- Exact source commit.
- Version/build number.
- Channel candidate: private preview or beta.
- Release notes path.
- Previous known-good version.

Protected environment: `release-beta`.

Steps:

1. Verify the commit is on protected `main` or another explicitly approved protected release ref, all required checks passed, the environment approver reviewed the exact SHA, and the workflow definition comes from protected release tooling.
2. Reject a reused version/build number.
3. In a no-secret build job, run full validation, build the universal app/installer, and emit a provenance-attested candidate manifest tied to source SHA, workflow identity, and artifact hashes.
4. After Environment approval, a separate isolated signing job verifies the manifest and artifact before exposing any signing credential.
5. The secret-bearing job runs only fixed, reviewed signing/notarization tooling from the protected release workflow. It must not execute candidate binaries, repository-supplied hooks, arbitrary build scripts, or unpinned dependencies.
6. Import or access the Developer ID identity through a temporary keychain or isolated signing service without printing/exporting it; restrict network egress where practical and destroy temporary keychain material on every exit path.
7. Sign nested code, app, installer, and DMG in the correct order.
8. Verify strict signatures, bundle identifiers, Team ID `W4GNV4SRNU`, designated requirements, and nested helper signers. Generic `Notarized Developer ID` output is not sufficient.
9. Submit the exact signed app/final DMG hashes to Apple notarization and require `Accepted` readback.
10. Fetch and archive notarization logs as restricted CI artifacts.
11. Staple app/installer/DMG as applicable and validate tickets.
12. Run Gatekeeper assessment, then re-verify exact Team ID, bundle identifiers, designated requirements, architecture, and hashes.
13. In a separate scoped step or service, generate the Sparkle EdDSA signature without exposing that private key to candidate code.
14. Generate the final release manifest, provenance record, and candidate appcast entry.
15. In a separate least-privilege upload job, upload immutable candidate assets to R2 under a non-public candidate key or beta key.
16. Read back each object anonymously where intended, verify HTTP 200, byte size, SHA-256, content type, cache headers, TLS hostname, and manifest provenance.
17. Produce a private preview link and workflow summary.
18. Do not modify stable or beta appcasts unless the promotion step is separately approved.

### 3. Beta promotion: `promote-beta.yml`

Trigger: manual approved action.

Protected environment: `release-beta` with required owner reviewer.

Inputs:

- Candidate manifest digest.
- Beta rollout cohort or percentage.
- Release notes approval.

Steps:

1. Re-read the immutable candidate manifest and verify its signature/digest.
2. Confirm required tests and Apple validations are successful.
3. Verify current beta appcast and previous known-good beta.
4. Publish an updated beta appcast with compare-and-swap against the previously verified digest/ETag; abort if the feed changed concurrently.
5. Read back the appcast from `updates.ddump.app/beta/appcast.xml`.
6. Validate XML, EdDSA signature, enclosure URL, length, version ordering, and anonymous DMG download.
7. Record approver, timestamp, manifest digest, and previous feed version.
8. Start rollout monitoring.

### 4. Stable promotion: `promote-stable.yml`

Trigger: manual approved action only.

Protected environment: `release-stable` with required owner reviewer.

Required evidence:

- Beta soak period met.
- Install/update/entitlement/card-safety test matrix passed.
- Crash, import-error, update-error, entitlement-error, and support thresholds are green.
- Rollback or forward-fix candidate is ready.
- Release notes and customer communication are approved.

Steps:

1. Verify beta manifest and artifact are immutable and still match checksums.
2. Copy or promote the exact tested artifact to the stable immutable key without rebuilding it.
3. Read back and re-verify the stable asset.
4. Generate and sign a new stable appcast from the tested manifest.
5. Publish the appcast with compare-and-swap against the previously verified digest/ETag; abort if the feed changed concurrently.
6. Verify feed and download externally.
7. Start at the approved phased rollout level.
8. Monitor and require a second approved action to expand rollout.

### 5. Website download promotion

The website download URL must be a stable, controlled DDump domain that resolves to an immutable versioned object, for example:

```text
https://downloads.ddump.app/stable/0.4.0/DDump-0.4.0.dmg
```

Use a separately signed release manifest and a controlled redirect or website link that points to the approved versioned object. A checksum served from the same R2 control plane is integrity evidence, not an independent authorization anchor. Promotion must:

1. Verify the versioned object first.
2. Verify the release-authorization signature and update the stable pointer with digest/ETag compare-and-swap.
3. Read back the public URL with HTTP 200.
4. Verify byte size and SHA-256.
5. Confirm all website download buttons resolve to the approved domain and version.
6. Confirm no customer-facing link depends on repository visibility.

## Sparkle 2 requirements

### App integration

- Sparkle 2 is pinned to a reviewed version.
- The app contains only the EdDSA public key.
- Stable builds use the stable appcast by default.
- Beta access uses an explicit opt-in/account-controlled channel.
- Update checks and downloads never block the ingest thread.
- Install/relaunch is disabled while scanning, copying, verification, organization, backup handoff, recovery, a mounted-card safety hold, or safe-eject workflow is active.
- User settings, app-support files, trust records, pending uploads, receipts, logs, and account tokens survive updates.

### Appcast requirements

Each item must include:

- Version and build number.
- Minimum macOS version.
- Release notes.
- HTTPS enclosure URL on `downloads.ddump.app`.
- Exact enclosure length.
- EdDSA signature generated with the protected private key.
- Channel and phased-rollout metadata if used.

Stable and beta appcasts are separate files. A beta entry must never appear in the stable feed by accident.

## Secrets and GitHub Environments

### `ci`

No production secrets.

### `release-beta`

- Developer ID certificate/private key or signing-service credential.
- Certificate import password.
- Apple notarization credential.
- Sparkle EdDSA private key.
- Release-authorization manifest signing key, isolated from R2 and candidate source.
- Beta R2 write credential.
- Required owner reviewer.

### `release-stable`

- Same categories as beta, with separate mandatory scoped signing/promotion credentials or isolated service identities.
- Stable R2 write credential limited to stable asset/appcast prefixes.
- Release-authorization verification is required before the stable promotion identity can mutate its pointer/appcast.
- Required owner reviewer.
- Deployment history retained.

Actions permissions must be least privilege. Third-party Actions must be pinned to reviewed commit SHAs before production release automation is trusted.

## Legacy GitHub updater migration

1. Verify R2 assets and stable Sparkle appcast before changing any current client path.
2. Publish one signed/notarized migration release through the existing public GitHub Releases flow. That build installs Sparkle 2 and defaults to `https://updates.ddump.app/stable/appcast.xml`.
3. Test `v0.3.14 -> migration release -> Sparkle stable`, including config/data preservation, Gatekeeper, offline behavior, rollback, and rescue installer.
4. Move the website to immutable R2 downloads while keeping the public GitHub API and migration asset available.
5. Measure legacy-version adoption and support failures. Owner approves the retirement threshold and support window.
6. Only after the threshold passes may the app's GitHub updater dependency be considered retired. Repository privacy remains a separate owner-approved action.

## Update publication flow

1. Code passes PR checks.
2. Owner approves merge when product decisions are resolved.
3. Merge creates no customer release.
4. An approved candidate workflow builds, signs, notarizes, staples, verifies, signs for Sparkle, and uploads immutable assets.
5. Private preview passes install, update preservation, entitlement, and card-safety QA.
6. Owner approves beta promotion.
7. Beta appcast changes atomically and rollout is monitored.
8. Beta health gates pass for the approved soak period.
9. Owner approves stable promotion.
10. The exact tested artifact is promoted, stable appcast changes atomically, and rollout starts at the approved phase.
11. Monitoring decides whether an owner-approved expansion, pause, rollback, or forward fix occurs.

## Beta rollout flow

1. The entitlement service assigns and persists a named beta cohort or deterministic rollout bucket for the authenticated account.
2. Only an eligible signed app selects the beta appcast; the feed itself is not an access-control boundary.
3. Sparkle reads only the beta feed.
4. The beta appcast references a signed/notarized immutable beta asset.
5. The app downloads but does not install during scanning, copying, verification, organization, backup handoff, recovery, or safe eject.
6. Only after the full card workflow reaches safe idle and the user-approved timing is met may Sparkle verify EdDSA and Apple signatures and install.
7. The app reports privacy-safe update success/failure and version.
8. Operators monitor eligible/served counts, crash, update, entitlement, import, and support signals before an approved expansion.

## Stable rollout flow

1. Stable promotion reuses the exact tested beta artifact or an identically verified promotion object. It does not rebuild from source.
2. Stable appcast publication is a separate owner-approved action.
3. Rollout starts at the approved phase.
4. The update is not installed during scanning, copying, verification, organization, backup handoff, recovery, or safe eject.
5. Health metrics and support reports are monitored continuously.
6. Each rollout expansion is recorded and approval-gated.

## Rollback and forward-fix flow

### Before customers install the bad version

1. Pause rollout or remove the bad item from the appcast by atomically restoring the last known-good feed.
2. Preserve the bad artifact for audit but stop advertising it.
3. Verify appcast and known-good download readback.
4. Post an incident record and notify affected cohorts if required.

### After customers install the bad version

Sparkle version ordering generally prevents silently replacing a newer installed build with an older version. The safe path is normally a forward fix:

1. Stop rollout immediately.
2. Build the last known-good code plus the minimum repair under a higher version/build number.
3. Sign, notarize, staple, verify, and test it through the full pipeline.
4. Promote it through beta, then stable with incident approval.
5. If a true downgrade is required, use an explicitly designed, signed, tested recovery installer and owner approval. Never improvise a downgrade against customer data.

Before the first stable paid release, publish and retain an out-of-band rescue installer and data-preserving recovery procedure that do not depend on the installed app, its updater, or the current appcast. The rescue path must be signed/notarized, immutable, externally reachable, and tested for startup failure, updater failure, unavailable feed/CDN, cached bad appcast, no network after download, and active-card safety.

### Rollback verification

- Stable and beta feeds can be restored atomically.
- Last known-good manifests and assets remain available.
- CDN caches respect the appcast rollback policy.
- Installed settings and data remain intact.
- A rollback never triggers app termination during active card work.

## Required release test matrix

| Scenario | Required result | Evidence |
|---|---|---|
| Clean install | Signed/notarized DMG installs on a non-developer macOS 13+ account; Gatekeeper accepts it. | Command output plus screen/functional record. |
| Universal build | App and installer report both `arm64` and `x86_64`. | `lipo -archs` output. |
| Update preservation | Upgrade from current public and previous paid stable preserves config, account, trust records, pending work, receipts, logs, and customer files. | Automated assertions plus manual Mac QA. |
| Legacy updater migration | v0.3.14 discovers and installs the migration release through GitHub, then Sparkle discovers the next stable build from `updates.ddump.app`. | End-to-end Mac QA and both feed readbacks. |
| Active import update | Update may download, but cannot install/relaunch until scan, copy, verification, organization, backup handoff, recovery, and safe eject finish. | Integration test and real-card QA. |
| Beta separation | Beta feed receives candidate; stable feed remains byte-for-byte unchanged. | Appcast hashes and HTTP readback. |
| Stable approval | Stable feed cannot change without protected Environment approval. | GitHub deployment record. |
| Signature tamper | Modified DMG/appcast/signature is rejected. | Negative test output. |
| Identity/provenance mismatch | Wrong Team ID, bundle ID, designated requirement, source SHA, workflow identity, artifact digest, or release-authorization signature is rejected. | Negative test output and manifest verification record. |
| R2 readback | Public asset and appcast return HTTP 200 with correct length, checksum, content type, TLS, and cache headers. | External probe output. |
| Rollback before install | Last known-good feed is restored atomically and bad release stops being offered. | Exercise record and feed hashes. |
| Forward fix after install | Higher-version repair installs without data loss and respects card-safety gates. | End-to-end exercise. |
| Out-of-band rescue | Signed/notarized rescue installer recovers startup/updater/feed failures without depending on the damaged app and without risking active card work or customer data. | Offline and networked recovery exercise. |

## Monitoring and release health

Required signals:

- Website download URL and appcast uptime.
- DMG/appcast checksum and signature drift.
- Sparkle check, download, verification, install, and relaunch failures by version/channel.
- Crash-free sessions and startup failures by version.
- Import, verification, backup, pending-recovery, and eject safety errors by version.
- Entitlement refresh latency/error, webhook lag, and signed-token issuance failures.
- Support reports tagged by version and channel.

Privacy rule: never send filenames, customer paths, card volume names, media metadata, secret values, or customer media in release telemetry.

## Current implementation gap

The current `.github/workflows/macos-ci.yml` is validation-only. It does not sign, notarize, staple, Gatekeeper-assess, generate checksums/appcasts, sign with Sparkle EdDSA, upload to R2, promote channels, or roll back. Those remain PLANNED and must not be represented as complete.
