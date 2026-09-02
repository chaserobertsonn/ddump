# DDump Go-Live Checklist

Last evidence review: 2026-09-01

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
- [x] The public v0.3.14 baseline uses GitHub Releases and had no Sparkle migration path.
  - Evidence: baseline source inspection on 2026-08-22; no public release/feed was changed by the implementation branch.
- [x] Repository contains an MIT License.
  - Evidence: repository readback on 2026-08-22.

### COMPLETED

- [x] 0.3.18 private-beta candidate completed local signing, notarization, stapling, disk-image verification, and Gatekeeper validation.
  - Evidence: local Mac validation commands listed in the VERIFIED section.
- [x] Gatekeeper bundle-type fix is on `main` with green post-merge CI.
  - Evidence: GitHub merge and check-run readback listed in the VERIFIED section.
- [x] Paid-launch code foundation implements safe-idle access policy, Supabase account/backend boundaries, signed entitlements, RevenueCat hosted-checkout resolution, Billing Lab, Sparkle 2, helper migration, and protected release automation.
  - Evidence: `docs/IMPLEMENTATION_EVIDENCE_2026-09-01.md`; this does not claim external activation.

### PLANNED

- [ ] Stripe Billing monthly and yearly subscriptions.
- [ ] Configure and exercise RevenueCat Web paywalls, offerings, products, and lifecycle in real provider test mode.
- [ ] Deploy test/production account and entitlement environments with approved policies and monitoring.
- [ ] Exercise a protected signed/notarized Sparkle candidate and clean migration path.
- [ ] Configure R2 release assets and externally verify separate stable/beta appcasts.
- [ ] Exercise explicit beta/stable promotion, phased rollout, monitoring, and rollback.

### BLOCKED

- [ ] Do not call 0.3.18 the final paid marketing release.
- [x] Keep the repository public and MIT licensed; visibility and licensing changes are out of scope for this launch.
- [ ] Do not start paid marketing until every required gate below is checked.

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
- [ ] Approve beta cohort, stable health thresholds, rollout phases, and incident authority.

## 1. Card-safety release gate

All items are mandatory and non-negotiable.

- [x] Entitlement expiry cannot stop an active scan, copy, verification, organization, backup handoff, recovery, or safe-eject sequence.
- [x] Cancellation, refund, failed renewal, logout, and vendor outage cannot interrupt an active import.
- [x] Billing or update UI cannot kill or restart the ingest helper.
- [x] A mounted card can never be stranded by an entitlement response or paywall.
- [ ] Eject still waits for existing copy verification, inventory stability, do-not-eject, stop-after-file, and safety prompts.
- [x] Expired or refunded users retain access to customer files, receipts, logs, diagnostics, settings, support, and safe cleanup.
- [x] New-import denial occurs only before card work begins and only at a safe idle boundary.
- [x] A valid signed offline entitlement works through the configurable test grace period. Production duration remains OWNER DECISION.
- [x] Vendor unavailability is not treated as an explicit revocation.
- [x] Sparkle may not install or relaunch while scan, copy, verification, organization, backup handoff, recovery, mounted-card safety hold, or safe eject is active.
- [x] Entitlement and updater modules cannot directly call ingest or eject controls.
- [x] App UI, LaunchAgent, direct helper invocation, retry, and recovery entry points use the shared pre-volume-discovery authorization boundary; UI-only enforcement is absent.
- [x] A successful start authorization remains valid through scan, copy, verification, organization, backup handoff, recovery, and safe eject; state changes affect only the next run after safe idle.
- [ ] Threat-model tests cover direct/manual helper invocation, modified helper detection or supported response, LaunchAgent mount start, retry, and callback bypass attempts.
- [ ] Ingest owns a crash-recoverable atomic state machine/operation lease for idle, scan, copy, verify, organize, backup handoff, recovery, eject-pending, and safe-idle.
- [ ] Closing the UI, helper restart/kill, simultaneous entitlement change, and update races immediately before eject cannot release or bypass the active lease.
- [ ] Real-card interrupted-import tests pass on Apple Silicon and Intel or an approved Intel-equivalent test environment.

## 2. Account and identity gate

- [ ] Create separate development/test and production account environments.
- [x] Select Supabase Auth with passwordless email and PKCE as the implemented default.
- [ ] Configure account creation, email verification, sign-in, logout, session refresh, recovery, and account deletion.
- [x] Define canonical immutable DDump account ID.
- [x] Implement immutable account mappings for auth, RevenueCat App User ID, and optional Stripe Customer ID.
- [x] Implement per-installation Ed25519 identity with only its SHA-256 binding sent/stored outside Keychain.
- [ ] Define second-Mac and device-replacement behavior.
- [x] Protect passwordless sessions with PKCE, random state, expiry, Keychain-persisted pending flow, bearer-token callback rejection, and HTTPS-only service URLs.
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
- [x] App User ID policy uses DDump account IDs, not anonymous permanent licenses.
- [ ] Monthly and yearly products mapped correctly.
- [ ] One canonical paid entitlement created and documented.
- [ ] Current offering includes approved monthly/yearly packages.
- [ ] Hosted web paywall displays price, cadence, trial, renewal, cancellation, and restore terms accurately.
- [ ] Targeting rules are documented and testable.
- [x] A/B variant assignment is stable per account and recorded; beta/debug test overrides are backend-allowlisted and expiring.
- [x] Restore behavior is implemented as account sign-in, device authorization, and signed entitlement refresh.
- [x] RevenueCat private/API and purchase-link configuration is server-only; the app contains no privileged provider key.
- [x] RevenueCat webhook authorization/HMAC exact-raw-body verification is implemented and tested.
- [x] RevenueCat environment, project/app, App User ID, product, and entitlement mappings are verified before state changes.
- [x] RevenueCat webhook event IDs process idempotently and retry an incomplete `received` event.
- [x] RevenueCat is the sole provider-derived entitlement mutation source; direct Stripe webhooks are immutable audit/reconciliation triggers and never independently grant access.
- [x] Composite idempotency key includes provider, environment, project, and event ID; durable receipt precedes successful acknowledgment.
- [ ] Versioned state transition tests cover trialing, incomplete, active, past-due, unpaid, cancellation-at-period-end, expired, refunded, dispute, chargeback, duplicate, delayed, and out-of-order events.
- [ ] Stripe and RevenueCat state reconcile without duplicate subscriptions or purchases.
- [ ] Dashboard member access follows least privilege.

## 5. Entitlement service gate

- [ ] Select hosting platform, durable database, and service owner.
- [ ] Deploy development/test and production environments.
- [x] Implement authenticated entitlement refresh.
- [x] Implement verified Stripe/RevenueCat webhook ingestion.
- [x] Store canonical state and an auditable event history.
- [x] Issue signed entitlement documents with account, entitlement, status, issue time, refresh deadline, grace expiry, authorized installation binding, device policy, and key ID.
- [ ] Keep entitlement signing private key in KMS or an isolated server secret store.
- [x] Embed only public entitlement verification keys in DDump.
- [x] Store session, installation private key, signed entitlement model, and anti-rollback state in Keychain; expose only a device-bound signed document through mode-0600 app support for the shared helper gate.
- [x] Token includes issuer, audience, account, installation key hash, product, policy version, token ID, `iat`, `nbf`, refresh deadline, hard `exp`, revocation epochs, and key ID.
- [x] Refresh returns typed `valid`, `indeterminate`, or verified `revoked`; provider unavailability is never fabricated as revocation.
- [x] Reject invalid signature, wrong audience/account/installation/key hash, stale or unknown/revoked key ID, corruption, copied token, replay, and pre-revocation-epoch token.
- [x] Logout invalidates local session only after active work reaches safe idle.
- [ ] Rotate signing keys without locking out valid customers.
- [ ] Reconcile webhook lag and provider outage without asking customers to repurchase.
- [ ] Support override/repair is audited, expiring, and least privilege.
- [x] Entitlement refresh has a bounded timeout and never runs on the ingest path.
- [ ] Monitoring covers refresh latency/error, webhook lag, token issuance failures, and state divergence.

## 6. Purchase and lifecycle data-flow gate

### Purchase

- [x] App resolves RevenueCat Web Purchase Links and opens hosted checkout in the system browser without collecting card data.
- [x] Checkout is tied to an authenticated DDump account and identified RevenueCat App User ID.
- [ ] Monthly purchase returns active entitlement.
- [ ] Yearly purchase returns active entitlement.
- [ ] Trial returns trialing entitlement with correct dates.
- [ ] Checkout abandonment does not create entitlement.
- [ ] Delayed webhooks show pending state and do not double-charge.
- [x] App polls after checkout, refreshes entitlement, verifies it, and stores a signed offline token.

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

- [x] Restore is account sign-in plus refresh, not a permanent license key.
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

- [x] Sparkle 2.9.6 dependency is pinned by reviewed URL and SHA-256.
- [x] Developer ID, Sparkle EdDSA, entitlement, and release-authorization trust roles are documented separately.
- [x] EdDSA private key is referenced only by protected release/promotion secret names.
- [x] Release builds require the EdDSA public key embedded in the app.
- [x] Stable app configuration uses `https://updates.ddump.app/stable/appcast.xml`.
- [x] Explicit beta channel configuration uses `https://updates.ddump.app/beta/appcast.xml`.
- [x] Appcasts include version, build, minimum macOS, release notes, HTTPS enclosure, exact length, channel/phased metadata, enclosure EdDSA, and whole-feed EdDSA signatures.
- [x] Synthetic tampered/invalid Sparkle signature verification fails closed through Sparkle `sign_update --verify` and app verifier tests.
- [x] Tampered enclosure signatures are rejected by the pinned Sparkle verification path.
- [x] Update can download during background use but cannot install/relaunch until scan, copy, verification, organization, backup handoff, recovery, mounted-card safety hold, and safe eject are finished.
- [x] Helper migration preserves config/runtime state; Sparkle replaces only the app while customer files and app support remain outside the bundle.
- [ ] Failed update leaves current app functional.
- [x] Beta items carry a beta channel and separate URL; beta selection requires backend eligibility plus explicit local opt-in, while every other client selects stable.
- [x] Version ordering and higher-version forward-fix behavior are tested.

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
- [x] CI workflow permissions are read-only and no production secrets are referenced.
- [ ] Beta and stable GitHub Environments exist with required owner reviewers.
- [x] Third-party Actions are pinned to full commit SHAs and checked by `verify-action-pins.sh`.
- [x] Candidate workflow accepts exact source commit/version/build/channel/rollout inputs.
- [ ] Candidate source is on protected `main` or an explicitly approved protected release ref; environment approval names the exact SHA, and secret-bearing jobs use the protected default-branch workflow definition.
- [ ] Untrusted PR/fork code and arbitrary repository scripts never run with signing, notarization, Sparkle, R2, billing, or entitlement secrets.
- [ ] A no-secret build job emits provenance-attested artifacts; an isolated signer verifies the manifest and runs only fixed reviewed signing/notarization tooling.
- [x] Temporary keychain/signing material is removed by the signer trap on success or failure; runner cancellation cleanup remains a GitHub-hosted runner guarantee to verify in a real run.
- [ ] Workflow rejects reused version/build numbers.
- [x] Secretless CI builds/tests universal macOS 13+ app and installer locally; protected workflow code uses the same candidate artifact.
- [ ] Protected workflow signs nested code, app, installer, and DMG correctly in a real credentialed run.
- [ ] Workflow requires Apple notarization `Accepted` readback.
- [ ] Workflow staples and validates tickets.
- [ ] Workflow requires `codesign`, `stapler`, `spctl`, disk-image, and architecture verification.
- [ ] Verification fails closed unless app bundle ID is `com.ddump.app`, installer bundle ID is `com.ddump.app.installer`, Team ID is `W4GNV4SRNU`, nested helper signers/designated requirements match, and notarization covers the exact artifact hashes.
- [x] Workflow code generates checksums, provenance/release authorization, release-note URL metadata, and enclosure/whole-appcast Sparkle signatures; protected execution remains unverified.
- [ ] Workflow uploads immutable objects and verifies external R2 readback.
- [x] Merge/PR CI has no appcast publication step.
- [x] Beta promotion is a separate protected workflow action.
- [x] Stable promotion is a separate protected workflow action that copies exact beta bytes without rebuilding.
- [ ] Rollout expansion is a separate approved action.
- [ ] Deployment history records approver, manifest digest, previous version, and timestamps.
- [ ] Concurrency prevents two promotions racing on one channel.
- [x] Appcast promotion code uses signed-manifest digest verification and ETag compare-and-swap; external R2 execution remains unverified.

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
- [x] Documentation states that DDump remains public and MIT licensed.

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
- [ ] Legal approval for customer terms, privacy, refunds, subscription disclosures, and accurate MIT-source representations.
- [ ] Enforcement/tamper-resistance goal, signed-helper design, user-modified-helper policy, and treatment of previously distributed MIT copies approval.
- [ ] Production Stripe/RevenueCat configuration approval.
- [ ] Beta release approval.
- [ ] Stable release approval.
- [ ] Each stable rollout expansion approval.
- [ ] Rollback/forward-fix authority and customer-message approval.

## Public repository and MIT license invariant

- [x] Repository remains public.
- [x] MIT license remains unchanged.
- [x] Release automation contains no repository-visibility or licensing mutation.
- [ ] Customer website and updater distribution migrate to R2/Sparkle without removing the public repository or bounded legacy migration asset.

## Final paid-launch decision

Do not call DDump paid and launched until all five gates are green:

1. **Card safety:** billing and updates cannot interrupt active work, strand a card, hide customer files, or eject unsafely.
2. **Commerce:** monthly, yearly, trial, restore, cancellation, refund, second Mac, outage, and offline grace work end to end.
3. **Distribution:** signed Sparkle updates and R2 downloads operate on stable/beta custom domains with rollback.
4. **Operations:** owner-approved promotion, monitoring, support, incident response, and audit evidence are live.
5. **Legal:** terms, privacy, refunds, tax, and accurate MIT-source representations are complete.

Until then, 0.3.18 remains a private-beta candidate and v0.3.14 remains the latest public GitHub release.
