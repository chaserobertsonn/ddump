# DDump Go-Live Checklist

Last evidence review: 2026-08-22

This is the release gate for turning DDump from a public preview/private-beta candidate into a paid product. A checked box means evidence exists. Configuration, intent, a Slack claim, or a locally generated file without validation is not enough.

## Status vocabulary

- **VERIFIED**: backed by command output, CI evidence, or authoritative readback.
- **COMPLETED**: implemented and backed by cited verification evidence.
- **PLANNED**: approved direction, not implemented or verified.
- **BLOCKED**: dependency or safety gate prevents progress.
- **OWNER DECISION**: requires Chase's explicit choice or approval.

## Current launch classification

### VERIFIED

- [x] Repository is public and defaults to `main`.
  - Evidence: GitHub repository API readback on 2026-08-22.
- [x] Gatekeeper fix commit `fcf2ba7` merged through PR #3 as `338e231`, and post-merge macOS CI passed.
  - Evidence: GitHub PR, merge, and main check-run readback on 2026-08-22.
- [x] DDump 0.3.18 was built as a universal macOS 13+ app and installer.
  - Evidence: local Mac public-readiness output and GitHub macOS CI.
- [x] Local `DDump-0.3.18.dmg` is a valid signed disk image, notarized, stapled, and accepted by Gatekeeper.
  - Evidence: `hdiutil verify`, `xcrun stapler validate`, `spctl`, and `codesign` output on 2026-08-22.
  - SHA-256: `c723f1ec3ed95c900a0923d215335373a9d1606a3d21ecb7b087a342df056dbd`.
- [x] Latest public GitHub Release remains v0.3.14.
  - Evidence: GitHub Releases readback on 2026-08-22.
- [x] `ddump.app` currently serves HTTP 200 and links to the GitHub-hosted v0.3.14 DMG.
  - Evidence: live HTTPS readback and parsed links on 2026-08-22.
- [x] Current updater uses public GitHub Releases and opens an installer; Sparkle is absent.
  - Evidence: source inspection on 2026-08-22.
- [x] Repository contains an MIT License.
  - Evidence: repository readback on 2026-08-22.

### COMPLETED

- [x] 0.3.18 private-beta candidate completed local signing, notarization, stapling, disk-image verification, and Gatekeeper validation.
  - Evidence: local Mac validation commands listed in the VERIFIED section.
- [x] Gatekeeper bundle-type fix is on `main` with green post-merge CI.
  - Evidence: GitHub merge and check-run readback listed in the VERIFIED section.

### PLANNED

- [ ] Stripe Billing monthly and yearly subscriptions.
- [ ] RevenueCat Web paywalls, offerings, entitlements, restore, targeting, and experiments.
- [ ] DDump customer accounts and server-authoritative signed offline entitlements.
- [ ] Sparkle 2 signed updates.
- [ ] R2 release assets and separate stable/beta appcasts.
- [ ] Explicit beta/stable promotion, phased rollout, monitoring, and rollback.

### BLOCKED

- [ ] Do not call 0.3.18 the final paid marketing release.
- [ ] Do not make the repository private while the site or updater depends on public GitHub URLs.
- [ ] Do not start paid marketing until every required gate below is checked.
- [ ] Do not adopt proprietary future licensing until legal and contributor-rights review is complete.

### OWNER DECISION

- [ ] Approve monthly price.
- [ ] Approve yearly price and annual discount.
- [ ] Approve trial eligibility, length, and payment-method requirement.
- [ ] Approve refund policy and support exceptions.
- [ ] Approve offline grace period. Proposed starting point: 7 days.
- [ ] Approve number of Macs per account and replacement policy.
- [ ] Accept or reject bounded offline refund/revocation exposure through the signed hard grace deadline; immediate revocation is impossible while a Mac is offline.
- [ ] Approve launch offer and founding-user treatment.
- [ ] Approve authentication provider and account recovery policy.
- [ ] Approve future source-license model after legal review.
- [ ] Approve beta cohort, stable health thresholds, rollout phases, and incident authority.

## 1. Card-safety release gate

All items are mandatory and non-negotiable.

- [ ] Entitlement expiry cannot stop an active scan, copy, verification, organization, backup handoff, recovery, or safe-eject sequence.
- [ ] Cancellation, refund, failed renewal, logout, and vendor outage cannot interrupt an active import.
- [ ] Billing or update UI cannot kill or restart the ingest helper.
- [ ] A mounted card can never be stranded by an entitlement response or paywall.
- [ ] Eject still waits for existing copy verification, inventory stability, do-not-eject, stop-after-file, and safety prompts.
- [ ] Expired or refunded users retain access to customer files, receipts, logs, diagnostics, settings, support, and safe cleanup.
- [ ] New-import denial occurs only before card work begins and only at a safe idle boundary.
- [ ] A valid signed offline entitlement works through the approved grace period.
- [ ] Vendor unavailability is not treated as an explicit revocation.
- [ ] Sparkle may not install or relaunch while scan, copy, verification, organization, backup handoff, recovery, mounted-card safety hold, or safe eject is active.
- [ ] Entitlement and updater modules cannot directly call ingest or eject controls.
- [ ] App UI, LaunchAgent, direct helper invocation, retry, and recovery entry points all use one shared new-import authorization boundary; UI-only enforcement is forbidden.
- [ ] A successful start authorization remains valid through scan, copy, verification, organization, backup handoff, recovery, and safe eject; state changes affect only the next run after safe idle.
- [ ] Threat-model tests cover direct/manual helper invocation, modified helper detection or supported response, LaunchAgent mount start, retry, and callback bypass attempts.
- [ ] Ingest owns a crash-recoverable atomic state machine/operation lease for idle, scan, copy, verify, organize, backup handoff, recovery, eject-pending, and safe-idle.
- [ ] Closing the UI, helper restart/kill, simultaneous entitlement change, and update races immediately before eject cannot release or bypass the active lease.
- [ ] Real-card interrupted-import tests pass on Apple Silicon and Intel or an approved Intel-equivalent test environment.

## 2. Account and identity gate

- [ ] Create separate development/test and production account environments.
- [ ] Select authentication provider.
- [ ] Configure account creation, email verification, sign-in, logout, session refresh, recovery, and account deletion.
- [ ] Define canonical immutable DDump account ID.
- [ ] Map one DDump account to Stripe Customer ID and RevenueCat App User ID.
- [ ] Define privacy-preserving device identifier and reset policy.
- [ ] Define second-Mac and device-replacement behavior.
- [ ] Protect sessions against replay, fixation, CSRF, open redirect, and deep-link spoofing.
- [ ] Bind checkout handoff to account, offering, state nonce, and expiration; never return reusable auth or entitlement tokens in URLs.
- [ ] Use HTTPS universal links or a provider-approved loopback return with PKCE; if a custom URL scheme exists, treat it only as a wake-up signal and require authenticated device-bound polling/redemption with atomic single-use invalidation.
- [ ] Test scheme hijacking, replay, expired state, cross-account completion, offering mismatch, and reused handoff codes.
- [ ] Rate-limit login, recovery, entitlement refresh, and webhook endpoints.
- [ ] Verify support can repair identity mappings without asking for passwords or payment-card data.
- [ ] Mapping repair requires verified account/session or device proof, role separation or dual approval for provider-ID changes, immutable before/after audit with ticket/reason, strict maximum override TTL, customer notification, and reconciliation against Stripe/RevenueCat.
- [ ] Support overrides cannot silently rewrite paid-through dates or create permanent entitlement; provider mappings are immutable outside the approved repair workflow.
- [ ] Verify account deletion retains only legally required billing records and does not delete customer files from the Mac.

## 3. Stripe Billing gate

### Account and products

- [ ] Stripe production account is verified and owned by the correct legal entity.
- [ ] Business name, statement descriptor, support URL/email, branding, and payout account are approved.
- [ ] Monthly Product/Price created in test and live mode.
- [ ] Yearly Product/Price created in test and live mode.
- [ ] Trial behavior matches owner decision.
- [ ] Tax collection and registration posture reviewed with qualified tax support.
- [ ] Stripe Tax or approved alternative configured.
- [ ] Receipts and invoices enabled and branded.
- [ ] Failed-payment retry/dunning policy approved.
- [ ] Cancellation at period end vs immediate behavior approved.
- [ ] Refund and dispute procedures configured.
- [ ] Customer Portal supports payment-method update, invoice/receipt access, plan change, and cancellation.
- [ ] Test clocks or equivalent lifecycle tests cover renewal, failed payment, cancellation, and expiration.

### Secrets and webhooks

- [ ] Stripe secret keys stored only in approved server secret stores.
- [ ] Stripe webhook signing secrets stored only in approved server secret stores.
- [ ] Test and live credentials are separated.
- [ ] Webhook signatures and timestamps are verified.
- [ ] Stripe handler verifies the exact raw request body, expected account, `livemode`, customer mapping, and product/price identifiers.
- [ ] Provider event IDs are idempotent and replayable.
- [ ] Delayed, duplicate, and out-of-order events recompute canonical subscription state instead of using last-arrival-wins.
- [ ] Dead-letter queue and operator replay path exist.
- [ ] No Stripe secret or raw payment data appears in app binary, website JavaScript, Slack, docs, commits, logs, or analytics.

## 4. RevenueCat Web gate

- [ ] RevenueCat project and DDump app created under the correct business owner.
- [ ] Stripe Billing connection configured in test and production environments.
- [ ] App User ID policy uses DDump account IDs, not anonymous permanent licenses.
- [ ] Monthly and yearly products mapped correctly.
- [ ] One canonical paid entitlement created and documented.
- [ ] Current offering includes approved monthly/yearly packages.
- [ ] Hosted web paywall displays price, cadence, trial, renewal, cancellation, and restore terms accurately.
- [ ] Targeting rules are documented and testable.
- [ ] A/B variant assignment is stable per account and recorded.
- [ ] Restore behavior works through account sign-in.
- [ ] RevenueCat private API key is server-only.
- [ ] RevenueCat webhook authorization is verified.
- [ ] RevenueCat environment, project/app, App User ID, product, and entitlement mappings are verified before state changes.
- [ ] RevenueCat webhook event IDs process idempotently.
- [ ] RevenueCat is the sole provider-derived entitlement mutation source; direct Stripe webhooks are immutable audit/reconciliation triggers and never independently grant access.
- [ ] Composite idempotency key includes provider, environment, project/account, and event ID; durable receipt occurs before acknowledgment.
- [ ] Versioned state transition tests cover trialing, incomplete, active, past-due, unpaid, cancellation-at-period-end, expired, refunded, dispute, chargeback, duplicate, delayed, and out-of-order events.
- [ ] Stripe and RevenueCat state reconcile without duplicate subscriptions or purchases.
- [ ] Dashboard member access follows least privilege.

## 5. Entitlement service gate

- [ ] Select hosting platform, durable database, and service owner.
- [ ] Deploy development/test and production environments.
- [ ] Implement authenticated entitlement refresh.
- [ ] Implement verified Stripe/RevenueCat webhook ingestion.
- [ ] Store canonical state and an auditable event history.
- [ ] Issue signed entitlement documents with account, entitlement, status, issue time, refresh deadline, grace expiry, authorized installation binding, device policy, and key ID.
- [ ] Keep entitlement signing private key in KMS or an isolated server secret store.
- [ ] Embed only the public verification key in DDump.
- [ ] Store signed entitlement and installation private material in macOS Keychain/Secure Enclave where available; only non-secret timing metadata may use protected app support.
- [ ] Token includes issuer, audience, account, installation key, product, policy version, token ID, `iat`, `nbf`, refresh deadline, hard `exp`, and key ID.
- [ ] Refresh returns typed `valid`, `indeterminate`, or verified `revoked`; provider unavailability is never fabricated as revocation.
- [ ] Reject invalid signature, wrong audience/account/installation, stale or revoked key ID, corruption, copied token, replay, and pre-revocation-epoch token.
- [ ] Logout invalidates local cache/session after active work reaches safe idle.
- [ ] Rotate signing keys without locking out valid customers.
- [ ] Reconcile webhook lag and provider outage without asking customers to repurchase.
- [ ] Support override/repair is audited, expiring, and least privilege.
- [ ] Entitlement refresh has a bounded timeout and never runs on the ingest path.
- [ ] Monitoring covers refresh latency/error, webhook lag, token issuance failures, and state divergence.

## 6. Purchase and lifecycle data-flow gate

### Purchase

- [ ] App opens hosted paywall and Stripe Checkout in the system browser.
- [ ] Checkout is tied to an authenticated DDump account.
- [ ] Monthly purchase returns active entitlement.
- [ ] Yearly purchase returns active entitlement.
- [ ] Trial returns trialing entitlement with correct dates.
- [ ] Checkout abandonment does not create entitlement.
- [ ] Delayed webhooks show pending state and do not double-charge.
- [ ] App refreshes entitlement after checkout and stores a signed offline token.

### Cancellation

- [ ] Customer Portal cancellation reaches Stripe, RevenueCat, and DDump.
- [ ] Access remains through paid-through date when policy says so.
- [ ] Expiration restricts only new imports at safe idle.
- [ ] Active imports and customer file access are unaffected.

### Refund

- [ ] Authorized support refund reaches Stripe, RevenueCat, and DDump.
- [ ] Refund state is idempotent and auditable.
- [ ] Offline refund/revocation behavior matches the approved bounded exposure through the signed hard grace deadline.
- [ ] Active import finishes before access state changes.
- [ ] Customer files and support remain accessible.

### Restore and second Mac

- [ ] Restore is account sign-in plus refresh, not a permanent license key.
- [ ] Existing purchase restores on a clean Mac.
- [ ] Second Mac follows approved device policy.
- [ ] Device replacement does not duplicate subscription or strand access.

### Offline and outage

- [ ] Valid signed cache works for the approved grace period.
- [ ] Corrupt cache requests refresh without interrupting active work.
- [ ] Clock rollback handling is safe and recoverable.
- [ ] Last trusted server time plus monotonic elapsed time is used where supported; clock anomalies cannot extend grace.
- [ ] Stripe outage test passes.
- [ ] RevenueCat outage test passes.
- [ ] Entitlement API outage test passes.
- [ ] No valid cache while idle blocks only a new import and provides repair/support paths.

## 7. Sparkle 2 update gate

- [ ] Sparkle 2 dependency is pinned and reviewed.
- [ ] Developer ID and Sparkle EdDSA trust roles are documented separately.
- [ ] EdDSA private key is available only to protected release automation.
- [ ] EdDSA public key is embedded in the app.
- [ ] Stable app uses `https://updates.ddump.app/stable/appcast.xml`.
- [ ] Beta opt-in/account state uses `https://updates.ddump.app/beta/appcast.xml`.
- [ ] Appcasts include version, build, minimum macOS, release notes, HTTPS enclosure, exact length, and EdDSA signature.
- [ ] Tampered appcast is rejected.
- [ ] Tampered DMG is rejected.
- [ ] Update can download during background use but cannot install/relaunch until scan, copy, verification, organization, backup handoff, recovery, mounted-card safety hold, and safe eject are finished.
- [ ] Update preserves config, trust records, account, entitlement cache, pending work, receipts, logs, and customer files.
- [ ] Failed update leaves current app functional.
- [ ] Beta feed cannot leak into stable.
- [ ] Version ordering and forward-fix behavior are tested.

## 8. Cloudflare R2 and domain gate

### Accounts and buckets

- [ ] Cloudflare account and `ddump.app` zone ownership verified.
- [ ] R2 release bucket created with documented owner and region/jurisdiction considerations.
- [ ] Candidate storage is private; beta and stable use separate mandatory prefixes/buckets and write credentials.
- [ ] R2 API key has least-privilege object permissions.
- [ ] Write credential exists only in protected GitHub/server secrets.
- [ ] Versioned assets deny overwrite/delete to release jobs; retention/admin mutation uses a separately approved role.
- [ ] Promotion credentials can update only their channel pointer/appcast; clients cannot list buckets or write objects.
- [ ] Immutable assets use long-lived immutable cache headers; appcasts/pointers use revalidation-friendly cache headers, ETags, purge procedure, and multi-location rollback probes.

### Domains

- [ ] `downloads.ddump.app` DNS, TLS, custom domain, and public readback verified.
- [ ] `updates.ddump.app` DNS, TLS, custom domain, and public readback verified.
- [ ] `api.ddump.app` created if selected for entitlement/webhooks.
- [ ] `account.ddump.app` or `pay.ddump.app` created if approved.
- [ ] `www.ddump.app` redirects to canonical `https://ddump.app/`.
- [ ] Email DNS has SPF, DKIM, DMARC, and provider verification.

### Public readback

- [ ] Versioned DMG returns HTTP 200 anonymously.
- [ ] Content length and SHA-256 match release manifest.
- [ ] Separately signed release-authorization manifest binds source SHA, artifact digest, version, channel, approver, and workflow provenance; its signing authority is isolated from R2.
- [ ] Content type and Content-Disposition are correct.
- [ ] Stable and beta appcasts return HTTP 200 and valid XML.
- [ ] Cache headers support immutable assets and quickly reversible appcasts.
- [ ] External monitoring detects asset/appcast drift or outage.

## 9. GitHub release automation gate

- [ ] `main` is protected with required checks.
- [ ] CI has read-only contents and no production secrets.
- [ ] Beta and stable GitHub Environments exist with required owner reviewers.
- [ ] Third-party Actions are pinned to reviewed commit SHAs.
- [ ] Candidate workflow accepts exact source commit/version/channel inputs.
- [ ] Candidate source is on protected `main` or an explicitly approved protected release ref; environment approval names the exact SHA, and secret-bearing jobs use the protected default-branch workflow definition.
- [ ] Untrusted PR/fork code and arbitrary repository scripts never run with signing, notarization, Sparkle, R2, billing, or entitlement secrets.
- [ ] A no-secret build job emits provenance-attested artifacts; an isolated signer verifies the manifest and runs only fixed reviewed signing/notarization tooling.
- [ ] Temporary keychain/signing material is destroyed on success, failure, or cancellation; secret-bearing jobs restrict egress where practical.
- [ ] Workflow rejects reused version/build numbers.
- [ ] Workflow builds and tests universal macOS 13+ app and installer.
- [ ] Workflow signs nested code, app, installer, and DMG correctly.
- [ ] Workflow requires Apple notarization `Accepted` readback.
- [ ] Workflow staples and validates tickets.
- [ ] Workflow requires `codesign`, `stapler`, `spctl`, disk-image, and architecture verification.
- [ ] Verification fails closed unless app bundle ID is `com.ddump.app`, installer bundle ID is `com.ddump.app.installer`, Team ID is `W4GNV4SRNU`, nested helper signers/designated requirements match, and notarization covers the exact artifact hashes.
- [ ] Workflow generates checksums, manifest, release notes, and Sparkle appcast/signature.
- [ ] Workflow uploads immutable objects and verifies external R2 readback.
- [ ] Merge to `main` does not publish beta/stable appcasts.
- [ ] Beta promotion is a separate approved action.
- [ ] Stable promotion is a separate approved action.
- [ ] Rollout expansion is a separate approved action.
- [ ] Deployment history records approver, manifest digest, previous version, and timestamps.
- [ ] Concurrency prevents two promotions racing on one channel.
- [ ] Appcast promotion uses digest/ETag compare-and-swap and aborts on a concurrent feed change.

## 10. Release rollout and rollback gate

### Private preview

- [ ] Exact artifact, source SHA, checksum, expiration, testers, and known issues recorded.
- [ ] Preview does not alter stable website/appcast.
- [ ] Normal-user preview is signed/notarized.

### Beta

- [ ] Owner approves beta audience and release notes.
- [ ] Beta feed references exact tested artifact.
- [ ] Beta eligibility is a server-persisted named cohort or deterministic account/release bucket; public feed readability is not authorization.
- [ ] Cohort assignment, eligible/served counts, persistence, expansion, pause, and revocation are monitored and audited.
- [ ] Stable feed hash remains unchanged.
- [ ] Beta health thresholds and soak period are recorded.
- [ ] Update, entitlement, import, and support monitoring are live.

### Stable

- [ ] Exact tested artifact is promoted without rebuilding.
- [ ] Owner approves stable publication and initial rollout phase.
- [ ] External readback verifies stable appcast, asset, checksum, length, signature, and version.
- [ ] Website stable download resolves to approved R2 asset.
- [ ] Each rollout expansion is approval-gated and recorded.

### Rollback

- [ ] Last known-good stable and beta manifests/assets remain available.
- [ ] Appcast can be atomically restored before bad-version install.
- [ ] Cache behavior during appcast rollback is tested.
- [ ] After bad-version install, higher-version forward-fix procedure is exercised.
- [ ] True downgrade requires a separately signed/tested recovery installer and owner approval.
- [ ] Out-of-band immutable signed/notarized rescue installer and data-preserving procedure work without the installed app, updater, or current appcast.
- [ ] Rescue tests cover startup failure, broken updater, unavailable feed/CDN, cached bad appcast, no network after download, and active-card safety.
- [ ] Rollback/forward fix cannot relaunch during scan, copy, verification, organization, backup handoff, recovery, mounted-card safety hold, or safe eject.
- [ ] Customer communication threshold and owner are documented.

## 11. Required test matrix

Each row requires exact build/version, account/environment, commands or test case, expected result, actual result, evidence link, date, and tester.

| Scenario | Required result | Status |
|---|---|---|
| Clean install | Signed/notarized build installs on clean non-developer macOS 13+ account; first launch and Gatekeeper pass. | [ ] |
| Update preservation | Current public v0.3.14 and prior paid stable update without losing config, trust records, account, entitlement, pending work, receipts, logs, or customer files. | [ ] |
| Legacy updater migration | v0.3.14 installs the GitHub-delivered migration release, then Sparkle installs the next stable build from `updates.ddump.app`. | [ ] |
| Monthly purchase | Hosted checkout creates one monthly subscription and active signed entitlement. | [ ] |
| Yearly purchase | Hosted checkout creates one yearly subscription and active signed entitlement. | [ ] |
| Trial | Eligibility, dates, conversion, cancellation, expiry, and no-double-trial policy behave as approved. | [ ] |
| Restore | Existing account restores without repurchase or license key. | [ ] |
| Second Mac | Existing account activates second Mac according to approved device policy. | [ ] |
| Expired subscription | Active import finishes; new import is denied only at safe idle; files and support remain available. | [ ] |
| Refund | Provider state reconciles; active work finishes; file access remains; new import changes only at safe idle. | [ ] |
| Offline grace | Signed token works until approved grace expiry and rejects invalid/corrupt tokens safely. | [ ] |
| Billing outage | Stripe/RevenueCat/API failure does not interrupt active import or strand card. | [ ] |
| Interrupted import | Billing/update event during scan, copy, verification, organization, backup handoff, recovery, or safe eject cannot stop work, relaunch the app, or cause unsafe eject. | [ ] |
| Cancellation | Portal state reaches all systems; access remains through paid date; expiry is safe. | [ ] |
| Failed renewal | Dunning state is truthful; active work and customer files remain available. | [ ] |
| Delayed webhook | Purchase remains pending until verified; no double-charge or false entitlement. | [ ] |
| Tampered entitlement | Signature/account/audience/time failure is rejected without ingest interruption. | [ ] |
| Copied/stale entitlement | Token copied to another Mac, restored after logout/refund, issued before revocation epoch, or signed by retired/compromised key is rejected safely. | [ ] |
| Tampered appcast/DMG | Sparkle refuses update and current app remains usable. | [ ] |
| Identity/provenance mismatch | Wrong Apple Team ID, bundle ID, designated requirement, source/artifact binding, workflow identity, or release-authorization signature is rejected. | [ ] |
| Beta/stable separation | Beta changes do not alter stable feed or website download. | [ ] |
| Rollback before install | Known-good feed restores atomically and bad build stops being offered. | [ ] |
| Forward fix after install | Higher-version repair installs safely and preserves all state. | [ ] |
| Out-of-band rescue | Rescue installer recovers startup/updater/feed failure without the damaged app and preserves data/card safety. | [ ] |

## 12. Website, privacy, legal, support, and tax gate

- [ ] Replace all GitHub download links with `downloads.ddump.app` only after verified HTTP readback.
- [ ] Hosted paywall uses system browser and truthful terms.
- [ ] Publish Privacy Policy, Terms, Refund Policy, Support, and contact pages.
- [ ] Document local-only data, transmitted data, analytics, retention, deletion, and subprocessors.
- [ ] Analytics exclude filenames, paths, card names, customer media, payment data, and secrets.
- [ ] Cookie/consent requirements are reviewed for launch jurisdictions.
- [ ] Support inbox and account email are authenticated with SPF, DKIM, and DMARC.
- [ ] Support playbooks cover lost access, duplicate purchase, restore, refund, billing outage, update failure, missing files, stuck card, failed backup, and corrupted config.
- [ ] Tax collection, registrations, invoices, and record retention reviewed by qualified support.
- [ ] Legal review covers direct-download subscriptions, auto-renewal disclosures, cancellation, refunds, privacy, and source licensing.
- [ ] Contributor-rights review is complete before future proprietary licensing.
- [ ] Documentation states that existing MIT-licensed copies retain granted permissions.

## 13. Required external account inventory

- [ ] GitHub repository, Actions, Environments, branch protection, reviewers, and retention.
- [ ] Apple Developer Program team, Developer ID identity, and notarization access.
- [ ] Stripe production account, Billing, Tax decision, Checkout, Portal, receipts, refunds, disputes, and webhooks.
- [ ] RevenueCat project, Stripe connection, products, offerings, entitlement, paywalls, targeting, experiments, restore, and webhooks.
- [ ] Cloudflare `ddump.app` zone, R2, DNS, TLS, cache, and least-privilege credentials.
- [ ] Domain registrar and website hosting/deployment accounts, with organization ownership, recovery, billing contact, and deployment authority.
- [ ] Authentication and transactional email provider.
- [ ] Entitlement/API hosting and durable database.
- [ ] Error tracking, uptime/appcast/download monitoring, webhook monitoring, and release health dashboards.
- [ ] Support inbox and incident/status communication channel.
- [ ] Legal and tax advisers or approved resources.
- [ ] Google Cloud OAuth project/consent screen if direct Google Calendar sign-in remains a marketed feature.
- [ ] Optional ntfy and Slack alert destinations, with customer-owned configuration and non-blocking failure behavior.
- [ ] Customer-managed sync-provider expectations for Google Drive Desktop, Dropbox, Box, OneDrive, iCloud Drive, pCloud, NAS, and advanced rclone.
- [ ] Every production account has an owner, backup owner, billing contact, least-privilege roles, organization-owned recovery, protected recovery codes, audit logs, a break-glass procedure, and phishing-resistant MFA where supported.

## 14. Required secret inventory

All values remain encrypted and are never copied into this checklist.

- [ ] Developer ID certificate private key and certificate import password.
- [ ] Apple notarization credential or App Store Connect API private key.
- [ ] Sparkle EdDSA private key.
- [ ] Separate release-authorization manifest private key.
- [ ] Cloudflare R2 write access key ID and secret.
- [ ] Stripe secret key and webhook signing secret.
- [ ] RevenueCat private API key and webhook authorization secret.
- [ ] Entitlement signing private key.
- [ ] Account/session signing secret and authentication-provider secrets.
- [ ] Database credentials.
- [ ] Monitoring and transactional email credentials.
- [ ] Google Calendar confidential client secret stays server-side if a server-assisted flow is used; user refresh tokens use macOS Keychain unless an approved threat model permits another protected local store.
- [ ] Native/Desktop OAuth uses provider-approved redirect handling and PKCE where supported; bundled public client credentials are never treated as an authorization boundary.
- [ ] Optional Slack webhook URL, ntfy topic/token, and advanced rclone/provider tokens in protected user-local storage.
- [ ] Rotation owner, date, and revocation procedure for each production secret.

## 15. Required human approvals

- [ ] Monthly/yearly prices, trial, refund, tax, launch offer, and founding-user treatment approval.
- [ ] Authentication provider and account-recovery policy approval.
- [ ] Entitlement hosting, database, transactional email, monitoring, and service-owner approval.
- [ ] Cloudflare/R2/DNS, registrar, website hosting, and customer download/update cutover approval.
- [ ] Offline grace, bounded offline revocation exposure, device count, and replacement-policy approval.
- [ ] Beta cohort, health thresholds, rollout phases, and incident-authority approval.
- [ ] Legal/licensing and contributor-rights approval.
- [ ] Enforcement/tamper-resistance goal, signed-helper design, user-modified-helper policy, and treatment of previously distributed MIT copies approval.
- [ ] Production Stripe/RevenueCat configuration approval.
- [ ] Beta release approval.
- [ ] Stable release approval.
- [ ] Each stable rollout expansion approval.
- [ ] Rollback/forward-fix authority and customer-message approval.
- [ ] Repository visibility change approval after migration evidence.

## Repository visibility transition gate

The repository may be considered for private visibility only when all are checked:

- [ ] Website has no customer-facing GitHub asset URL.
- [ ] App has no customer updater dependency on GitHub Releases.
- [ ] Signed/notarized migration release has passed `v0.3.14 -> migration release -> Sparkle stable` on supported Macs.
- [ ] Public GitHub updater/API and migration asset remain available through the approved legacy-client adoption threshold and support window.
- [ ] Anonymous R2 stable download works.
- [ ] Stable and beta Sparkle feeds work from custom domains.
- [ ] Clean install, update preservation, outage, and rollback tests pass without public GitHub access.
- [ ] Existing MIT grants and future licensing have legal review.
- [ ] Owner explicitly approves the visibility change.

## Final paid-launch decision

Do not call DDump paid and launched until all five gates are green:

1. **Card safety:** billing and updates cannot interrupt active work, strand a card, hide customer files, or eject unsafely.
2. **Commerce:** monthly, yearly, trial, restore, cancellation, refund, second Mac, outage, and offline grace work end to end.
3. **Distribution:** signed Sparkle updates and R2 downloads operate on stable/beta custom domains with rollback.
4. **Operations:** owner-approved promotion, monitoring, support, incident response, and audit evidence are live.
5. **Legal:** terms, privacy, refunds, tax, and MIT/future-licensing review are complete.

Until then, 0.3.18 remains a private-beta candidate and v0.3.14 remains the latest public GitHub release.
