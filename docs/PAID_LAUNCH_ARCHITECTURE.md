# DDump Paid Launch Architecture

Last evidence review: 2026-09-01

This document describes the implemented foundation and remaining activation gates for a paid direct-download DDump product. Code-level completion is not evidence that provider dashboards, production billing, DNS, or public distribution are active.

## Status vocabulary

Every material item uses one of these labels:

- **VERIFIED**: supported by command output, CI evidence, or an authoritative external readback.
- **COMPLETED**: implemented and backed by cited verification evidence.
- **PLANNED**: approved direction that is not implemented or verified.
- **BLOCKED**: cannot safely proceed until a dependency is resolved.
- **OWNER DECISION**: Chase must choose or approve the value before implementation or production use.

Unchecked checklist items are not complete.

## Current evidence register

| Status | Fact | Evidence |
|---|---|---|
| VERIFIED | The GitHub repository is public and its default branch is `main`. | `gh repo view chaserobertsonn/ddump --json visibility,isPrivate,defaultBranchRef` returned `PUBLIC`, `false`, and `main` on 2026-08-22. |
| VERIFIED | Gatekeeper fix `fcf2ba7` merged through [PR #3](https://github.com/chaserobertsonn/ddump/pull/3) as `338e231`, with successful PR and post-merge macOS CI. | PR check runs [32551876450](https://github.com/chaserobertsonn/ddump/actions/runs/32551876450) and [32551510032](https://github.com/chaserobertsonn/ddump/actions/runs/32551510032), plus successful main run [32559156635](https://github.com/chaserobertsonn/ddump/actions/runs/32559156635), read back on 2026-08-22. |
| VERIFIED | Gatekeeper fix commit is `fcf2ba7`. | Local and GitHub commit readback. |
| VERIFIED | The local `DDump-0.3.18.dmg` exists, has a valid disk-image checksum, is stapled, and is accepted by Gatekeeper as Notarized Developer ID. | Read-only Mac validation on 2026-08-22: `hdiutil verify` valid, `xcrun stapler validate` worked, and `spctl` returned `accepted` with `source=Notarized Developer ID`. SHA-256: `c723f1ec3ed95c900a0923d215335373a9d1606a3d21ecb7b087a342df056dbd`; Apple notarization submission `4b653a42-e63f-408d-b031-8564165101e6` returned `Accepted`. |
| VERIFIED | The current app and installer build as universal `arm64` and `x86_64` binaries for macOS 13+. | Local Mac public-readiness output and successful GitHub macOS CI. |
| VERIFIED | The latest public GitHub Release is [v0.3.14](https://github.com/chaserobertsonn/ddump/releases/tag/v0.3.14). | `gh release view` readback on 2026-08-22. |
| VERIFIED | `ddump.app` currently links three download buttons to the GitHub-hosted v0.3.14 DMG. | HTTPS 200 readback and parsed live anchor URLs on 2026-08-22. |
| VERIFIED | The updater queries `https://api.github.com/repos/<repo>/releases/latest` and opens a DMG, ZIP, or release page. | `app/DDumpApp.swift`, `checkForUpdatesIfNeeded`. |
| VERIFIED | At the `ebfb538` baseline Sparkle was absent and the updater used GitHub Releases. | Source inspection on 2026-08-22. |
| VERIFIED | The repository contains the MIT License. | `LICENSE` readback on 2026-08-22. |
| COMPLETED | Strict semantic ordering rejects equal/older GitHub releases. | `scripts/test-swift.sh` on 2026-09-01. |
| COMPLETED | Account, hosted checkout, signed entitlement, safe-idle access policy, Billing Lab, Sparkle 2.9.6, helper migration, and release workflow foundations are implemented. | `docs/IMPLEMENTATION_EVIDENCE_2026-09-01.md`. |
| COMPLETED | Supabase schema/functions cover immutable account/provider mappings, device authorization, raw-body webhooks, canonical recomputation, signed entitlements, rate limits, deletion, dead-letter replay, and reconciliation. | Deno format/type checks and 17 tests on 2026-09-01. |

## Release classification

### COMPLETED

- The Gatekeeper bundle-type fix is on `main`; the evidence register records successful post-merge CI.
- Paid-launch foundation implementation and deterministic safety/release tests are complete on the implementation branch.

### VERIFIED

- A signed, notarized, stapled, Gatekeeper-accepted 0.3.18 DMG exists locally.
- The public site and current updater still use public GitHub distribution.

### PLANNED

- Treat 0.3.18 as a private-beta candidate only.
- Deploy and exercise the paid-launch foundation against real provider test mode.
- Move customer-facing downloads and update feeds to Cloudflare R2 custom domains after external verification and owner approval.
- Publish and test the bounded v0.3.14 GitHub-to-Sparkle migration release.

### BLOCKED

- The source repository must not become private while the website or updater depends on public GitHub release/API URLs.
- Paid launch is blocked until account, billing, entitlement, restore, outage, update, rollback, legal, and card-safety tests pass.
- Repository visibility and MIT licensing remain unchanged and are outside this launch's scope.

### OWNER DECISION

- Monthly and yearly prices, trial terms, refund policy, tax posture, launch offer, and founding-user treatment.
- Authentication provider and account recovery policy.
- Offline entitlement grace period. Proposed starting point: 7 days, subject to approval and abuse testing.
- Maximum number of concurrently authorized Macs and device-replacement policy.
- Whether bounded offline refund/revocation exposure through the signed hard grace deadline is acceptable. Immediate revocation cannot be guaranteed while a Mac is offline.
- Beta eligibility, rollout percentages, stable promotion criteria, and rollback authority.
- Future source-license model after legal review.

## Non-negotiable card-safety invariants

These rules outrank billing, growth experiments, analytics, and update behavior.

1. **Never interrupt active media work.** Entitlement expiry, refund, cancellation, failed renewal, webhook delay, vendor outage, or account logout must not stop an active scan, copy, verification, organization, backup handoff, recovery, or safe-eject sequence.
2. **Never strand a mounted card.** Billing code must not kill the import helper, remove required controls, force-quit DDump, or leave a card waiting for an entitlement response.
3. **Never eject before safety conditions pass.** Billing state cannot bypass copy verification, inventory stability checks, stop-after-file behavior, do-not-eject state, pending safety prompts, or existing eject gates.
4. **Never take customer files hostage.** Expired or refunded users retain access to files already copied, receipts, logs, diagnostics, settings, support, and safe cleanup. DDump must not encrypt, hide, delete, relocate, or revoke access to customer media.
5. **Gate only at a safe idle boundary.** A denied entitlement may prevent starting a new import only before DDump begins card work. If card work has started, the current safety workflow finishes.
6. **Fail safely during vendor outages.** A valid signed offline entitlement remains usable through its grace period. An unavailable billing service is not the same as an explicit revocation.
7. **Updates never alter active card state.** Sparkle may download in the background, but installation, relaunch, or termination is prohibited during an active import, pending verification, mounted-card safety hold, or recovery operation.
8. **Billing UI is not an ingest dependency.** Hosted paywalls and system-browser checkout run outside the ingest engine. Their failure cannot block status, diagnostics, file access, or safe eject.

The entitlement adapter must expose a simple capability result to the presentation layer. It must not call ingest or eject methods directly.

## Target system boundaries

### macOS app

Responsibilities:

- Authenticate the customer through the system browser.
- Open the hosted RevenueCat Web paywall and Stripe checkout.
- Poll or receive a safe callback after checkout, then refresh entitlement.
- Verify signed offline entitlement documents using an embedded public verification key.
- Enforce new-import access only at a safe idle boundary.
- Integrate Sparkle 2 with separate beta and stable appcasts.
- Keep private billing, entitlement-signing, Sparkle-signing, and Apple credentials out of the app binary.

The app may contain public identifiers such as Stripe Price IDs, RevenueCat public SDK keys, OAuth client IDs, Sparkle public EdDSA key, appcast URLs, and entitlement public verification keys. None of those may grant privileged server access.

### Customer account and entitlement service

Responsibilities:

- Own the canonical DDump customer identity and account recovery path.
- Map the account to Stripe Customer ID and RevenueCat App User ID.
- Keep provider mappings immutable outside a controlled support-repair workflow requiring proof of account/device control, role separation or dual approval for identity changes, immutable before/after audit with ticket/reason, bounded override TTL, customer notification, and provider reconciliation.
- Accept only authenticated app requests.
- Consume verified, idempotent Stripe and RevenueCat webhooks.
- Calculate server-authoritative capability state.
- Issue short-lived, signed offline entitlement documents containing account ID, entitlement ID, status, issued time, refresh deadline, grace expiry, authorized installation binding, device policy, and key ID.
- Record an auditable entitlement event trail without storing payment-card data.

The Supabase/Postgres implementation foundation is COMPLETED but undeployed. Production project ownership, email delivery, secrets, policy values, monitoring, and activation remain external gates and OWNER DECISION items.

### Stripe Billing

Responsibilities:

- Monthly and yearly subscriptions.
- Checkout, invoices, receipts, payment methods, taxes, refunds, disputes, failed-payment retries, and customer portal.
- Canonical payment and invoice records.

DDump must use Stripe-hosted Checkout and Customer Portal in the system browser. No raw card details enter the app or DDump servers.

### RevenueCat Web

Responsibilities:

- Hosted paywalls and remotely managed presentation.
- Offerings, products, entitlement mapping, restores, targeting, and A/B experiments.
- Stripe Billing integration and normalized subscription lifecycle events.

RevenueCat is not a substitute for DDump account identity, webhook verification, or a signed offline entitlement service.

### Cloudflare R2 and domains

Responsibilities:

- `downloads.ddump.app`: immutable public DMGs, ZIPs if required, checksums, release notes, and rollback assets.
- `updates.ddump.app/beta/appcast.xml`: beta Sparkle appcast.
- `updates.ddump.app/stable/appcast.xml`: stable Sparkle appcast.
- Optional `api.ddump.app`: authenticated entitlement refresh and verified webhooks.
- Optional `account.ddump.app` or `pay.ddump.app`: hosted account and paywall entry point.

R2 assets must be public-read, versioned, immutable, cacheable, and independently recoverable. Upload credentials remain server-side.

## Identity and entitlement model

- DDump uses customer accounts, not permanent client-side license keys.
- One DDump account maps to one RevenueCat App User ID and one Stripe Customer ID.
- A restore is account sign-in plus entitlement refresh, not re-entry of a license key.
- Device limits are enforced server-side. Device identifiers must be privacy-preserving and resettable through support.
- Each offline entitlement is bound to an authorized installation identifier or installation public key. Corresponding private material stays in macOS Keychain or Secure Enclave where available and is never synced as a bearer credential.
- Subscription state is server-authoritative. The local app only trusts a current server response or a valid signed offline entitlement.
- The app embeds only the public key required to verify offline entitlement signatures.
- Revocation and refund state apply at the next safe idle boundary. Active imports still finish safely.

### Enforcement boundary and limits

`server-authoritative` means the server is the source of subscription truth. It does not mean a customer-controlled Mac is tamper-proof DRM. Public MIT-licensed source and binaries remain subject to their granted permissions, and a motivated local administrator can modify software they control. Paid-launch policy, support, and hosted services must not promise retroactive or unbreakable enforcement.

The current importer can start through the app, its LaunchAgent, direct `ddump.sh` invocation, and retry/recovery paths. A UI-only paywall is therefore not an enforcement boundary. The planned implementation must route every supported **new import** entry point through one shared entitlement/start-authorization boundary.

An ingest-owned state machine and atomic operation lease are the sole authority for `idle`, `scanning`, `copying`, `verifying`, `organizing`, `backup-handoff`, `recovering`, `eject-pending`, and `safe-idle`. A successful start acquires a crash-recoverable run lease that remains valid through safe eject. Entitlement changes may only set `deny-next-import`; Sparkle may only install after the ingest coordinator acknowledges `safe-idle`. Closing the UI, restarting the helper, a simultaneous billing event, or an update race cannot release or bypass that lease.

The enforcement/tamper-resistance goal, signed-helper design, treatment of user-modified helpers, and commercial expectations for already distributed MIT copies are OWNER DECISION items requiring legal and product review.

## Data flows

### 1. Monthly or yearly purchase

1. The signed app creates a one-time checkout handoff bound to the authenticated DDump account, authorized installation key, expected offering, state nonce, PKCE challenge, and a short expiration. Use an HTTPS universal link or provider-approved loopback return. A custom URL scheme, if retained, is only a wake-up signal; the app must redeem an authorization code with PKCE or poll an authenticated, device-bound, single-use handoff server-side and never trust callback parameters alone. No reusable session or entitlement token appears in a URL.
2. The app creates or resumes the DDump account session in the system browser and opens the RevenueCat-hosted paywall for the server-selected offering and experiment variant.
3. The customer chooses monthly, yearly, or an approved trial and completes Stripe-hosted Checkout.
4. Stripe creates or updates the Customer and Subscription, calculates tax, and sends the receipt or invoice.
5. Stripe sends signed events to the configured RevenueCat integration and, if retained for audit coverage, the DDump Stripe webhook endpoint.
6. RevenueCat updates the mapped entitlement and sends a signed/authenticated webhook to DDump.
7. RevenueCat is the sole provider-derived mutation source for DDump entitlement state. Direct Stripe events are immutable billing/audit evidence and reconciliation triggers; they never independently grant access. A conflicting refund, dispute, or chargeback triggers provider reconciliation and may fail closed for the next import only after safe idle.
8. The browser returns to a success page. The app validates state, account, offering, expiration, and single-use status, then atomically consumes the handoff or polls the entitlement service until webhook-derived state is visible or a bounded timeout expires.
9. The service returns a signed offline entitlement. The app verifies it and enables new imports.
10. A delayed webhook produces a truthful pending state, not a fake success or repeated charge.

### 2. Entitlement refresh

1. The app authenticates to the DDump account service.
2. It submits its current entitlement token, app version, channel, and privacy-preserving device identifier.
3. The service reads canonical state derived from verified provider events and may reconcile with RevenueCat server APIs.
4. The service returns a typed result: `valid` with a newly signed entitlement, `indeterminate` for a retryable provider/outage condition, or `revoked` for verified terminal loss of access. Canonical subscription detail includes trialing, incomplete, active, past-due, unpaid, cancellation-at-period-end, expired, refunded, disputed, chargeback, and support-hold.
5. The app verifies signature, audience, account, key ID, and time bounds before caching the token atomically.
6. A refresh failure preserves the last valid signed token and follows offline rules. It never mutates ingest state.

### 3. Offline access

1. The app reads the signed token from macOS Keychain and proves possession of the authorized installation key. Non-secret monotonic timing metadata may live in protected app support.
2. It verifies signature, issuer, audience, account, installation key, product, policy version, token ID, `iat`, `nbf`, refresh deadline, hard `exp`, and key ID.
3. Before grace expiry, the app allows new imports according to the approved policy and continues all active work.
4. After grace expiry, the app waits until the system is safely idle before denying a new import and presenting account repair options.
5. Existing files, logs, receipts, diagnostics, settings, and safe-eject controls remain available.
6. Clock rollback or corrupt-token signals request online refresh but never interrupt an active import.
7. Grace evaluation uses the last trusted server time plus monotonic elapsed time where supported. Clock anomalies never extend the hard grace deadline.
8. Logout deletes the local entitlement and installation session after any active run reaches safe idle. A restored/copied token, revoked key ID, or token issued before the installation/account revocation epoch is rejected.

### 4. Cancellation

1. The customer cancels in the Stripe Customer Portal.
2. Stripe records cancellation immediately or at period end and emits signed events.
3. RevenueCat and DDump update the entitlement through verified webhooks.
4. Access normally remains active through the paid-through date.
5. The app receives the updated expiration at refresh and shows a truthful renewal state.
6. At final expiration, restrictions begin only at a safe idle boundary.

### 5. Refund

1. An authorized human issues the refund in Stripe under the approved policy.
2. Stripe emits signed refund and subscription events.
3. RevenueCat and DDump reconcile entitlement state idempotently.
4. The app refreshes to refunded or revoked status.
5. Any active import, verification, backup handoff, or safe-eject sequence finishes.
6. An offline Mac may retain access until its already signed hard grace deadline; this bounded exposure requires explicit owner acceptance.
7. New-import access changes only after safe idle. Customer file access and support remain available.

### 6. Restore and second Mac

1. The customer chooses Restore Access or Sign In on the new Mac.
2. The system browser completes account authentication.
3. The service maps the account to existing Stripe and RevenueCat identities.
4. Server-side device policy approves, replaces, or asks the customer to manage an old device.
5. The service returns a signed entitlement bound to that authorized Mac installation.
6. No purchase is duplicated and no permanent license key is required.

### 7. Billing or entitlement outage

1. The app attempts refresh with a bounded timeout and no blocking call on the ingest path.
2. A valid signed entitlement continues through the approved grace period.
3. If an import is active, it completes regardless of token age or vendor response.
4. If the app is idle with no valid cache, it blocks only the start of a new import and explains the temporary service state.
5. Status, diagnostics, account repair, file access, and safe eject remain available.
6. Monitoring alerts the operator. Recovery triggers reconciliation before any customer is asked to repurchase.

## Paywall and experimentation rules

- Paywall content, offerings, prices, targeting rules, and experiment allocation are managed remotely through RevenueCat Web and Stripe products/prices.
- A/B assignment must be stable per account and recorded with offering ID, variant ID, price IDs, country, app version, and attribution source.
- Price and copy changes require owner approval but not an app release when supported by existing paywall components.
- The app must display the final Stripe checkout amount, cadence, trial, tax handling, renewal terms, cancellation path, and restore access truthfully.
- Experiments may optimize conversion. They may not weaken card safety, hide restore, misstate price, or create a false countdown.
- Analytics events must exclude filenames, paths, card volume names, customer media, secret values, and raw payment data.

## Secrets and trust boundaries

Never place these in Slack, documentation values, commits, logs, app binaries, release assets, or client-side JavaScript:

- Stripe secret keys and webhook signing secrets.
- RevenueCat private API keys and webhook credentials.
- Entitlement-signing private keys and account-session signing secrets.
- Sparkle EdDSA private key.
- Release-authorization manifest private key.
- Apple notarization credentials, App Store Connect private keys, certificate private keys, or certificate-export passwords.
- Cloudflare R2 write credentials.
- Authentication-provider client secrets, database credentials, or recovery keys.

Store production secrets only in encrypted GitHub Environment secrets or an approved server secret store. Use separate development, beta, and production credentials where providers support it. Rotate credentials after exposure or operator departure.

## Public repository and MIT license invariant

The current website links directly to a public GitHub Release asset, and the current updater calls the public GitHub Releases API. Repository visibility changes are prohibited for this launch and would also break anonymous website downloads and the in-app release check or force customers through authenticated GitHub access.

Required migration order:

1. Publish and verify release assets at `downloads.ddump.app`.
2. Build a signed/notarized migration release that the current GitHub updater can discover and that installs Sparkle 2 with the stable custom-domain appcast.
3. Keep the public GitHub Releases API and migration asset available while testing `v0.3.14 -> migration release -> Sparkle stable` on supported Macs.
4. Move website downloads to R2 and verify anonymous clean install, update preservation, rollback, outage behavior, and legacy-client adoption.
5. Define a measured support plan for clients that never installed the migration release.
6. Keep the repository public, keep the MIT license, and retain the bounded migration asset for legacy clients. Paid services and hosted infrastructure do not require a visibility or licensing change.

## Required external inventory

### Accounts and services

- GitHub owner/repository with Actions, branch protection, Environments, artifact retention, and approved reviewers.
- Apple Developer Program team with Developer ID Application identity and notarization access.
- Stripe production account with Billing, Tax decision, Checkout, Customer Portal, receipts, refunds, disputes, and webhook endpoints.
- RevenueCat project with Web Billing/Stripe integration, DDump app, products, offerings, entitlement, paywalls, targeting, experiments, and webhooks.
- Cloudflare account and `ddump.app` zone with R2, custom domains, DNS, TLS, cache, and least-privilege API credentials.
- Domain registrar account and current website hosting/deployment account, each with verified organization ownership, recovery, and billing contacts.
- Authentication provider and transactional email provider for sign-in, verification, account recovery, and security notices.
- Entitlement API hosting and durable database.
- Error tracking, uptime monitoring, webhook monitoring, release health, and support inbox.
- Legal and tax support appropriate to launch jurisdictions.
- Google Cloud OAuth project and consent screen if direct Google Calendar sign-in remains a marketed feature.
- Optional ntfy and Slack workspaces/endpoints if phone or Slack alerts are offered in the paid product.
- Customer-managed sync-provider accounts such as Google Drive Desktop, Dropbox, Box, OneDrive, iCloud Drive, pCloud, NAS, or advanced rclone. DDump does not own those customer credentials.

Every production account requires an owner, backup owner, billing contact, least-privilege roles, organization-owned recovery methods, protected recovery codes, audit logging, and a documented break-glass path. Use phishing-resistant MFA where supported. Personal shared credentials are not an ownership model.

### Required secrets

| Secret | Store | Consumer |
|---|---|---|
| Apple signing certificate private key and certificate password | GitHub stable/beta Environment secret or secured signing service | macOS release job |
| Apple notarization credential or App Store Connect API key | GitHub Environment secret | notarization job |
| Sparkle EdDSA private key | GitHub Environment secret or isolated signing service | appcast/signature job |
| Release-authorization manifest private key | Separate isolated signing service or KMS | release authorization only |
| Cloudflare R2 access key ID and secret | GitHub Environment secret | upload and promotion jobs |
| Stripe secret key | Server secret store | account/billing backend |
| Stripe webhook signing secret | Server secret store | Stripe webhook handler |
| RevenueCat private API key | Server secret store | entitlement reconciliation |
| RevenueCat webhook authorization secret | Server secret store | RevenueCat webhook handler |
| Entitlement signing private key | Isolated server secret store or KMS | entitlement issuer only |
| Account/session signing secret | Server secret store | auth service |
| Database credentials | Server secret store | entitlement/account service |
| Monitoring and transactional email keys | Server secret store | backend/alerts |
| Google Calendar confidential OAuth client secret, if a server-assisted flow is used | Server secret store only | Calendar backend only |
| Google Calendar user refresh tokens | macOS Keychain unless an approved threat model permits another protected user-local store | Calendar integration only |
| Optional Slack webhook URL and ntfy topic/token | Protected user-local config or approved secret store; always redacted | User-configured alerts only |
| Optional rclone config and provider refresh tokens | Protected user-local rclone/config storage; never release automation | Advanced customer-managed cloud path only |

Public app keys, Price IDs, Product IDs, account IDs, Team ID, appcast URLs, Sparkle public key, and entitlement public key are configuration, not secrets, but still require environment separation and change review.

Native/Desktop OAuth client IDs and any provider-designated non-confidential desktop credential are public application identifiers, not an authorization boundary. A native flow must use the provider-approved loopback/universal-link pattern and PKCE where supported. It must never treat a bundled client credential as proof of DDump identity.

### Required domains and DNS

- `ddump.app`: marketing website and approved hosted paywall entry.
- `www.ddump.app`: redirect to canonical host.
- `downloads.ddump.app`: public immutable release assets.
- `updates.ddump.app`: stable and beta appcasts.
- `api.ddump.app`: proposed entitlement/account API and webhooks.
- `account.ddump.app` or `pay.ddump.app`: optional owner-approved account/paywall host.
- Email DNS: SPF, DKIM, DMARC, and provider verification for support and account mail.

### Required webhooks

- Stripe to RevenueCat managed integration.
- RevenueCat to DDump entitlement service.
- Stripe to DDump backend if direct invoice, refund, dispute, or portal audit events are required.
- Authentication-provider lifecycle events if account deletion or security notifications depend on them.
- Optional outbound Slack webhook and ntfy notification delivery. These are customer-configured alert destinations, not billing authority, and their failure cannot affect ingest or eject.

Every webhook must verify provider signatures or authorization against the exact raw request body, reject stale timestamps where supported, confirm test/live environment and expected provider account, validate mapped customer/product identifiers, store provider event IDs, process idempotently, retry safely, and expose dead-letter/replay tooling. Events can be duplicated, delayed, or out of order, so handlers recompute canonical state from effective provider state instead of applying naive last-arrival-wins updates.

### Required dashboard settings

- Stripe: products/prices, trial behavior, tax collection, receipts, dunning, failed-payment retries, cancellation behavior, refund policy, Customer Portal, branding, statement descriptor, support contacts, webhook destinations, and test/live separation.
- RevenueCat: Stripe app connection, App User ID policy, entitlement/product mapping, current offering, monthly/yearly packages, hosted paywall, targeting, experiments, restore behavior, webhook authorization, environment separation, and project-member access.
- GitHub: protected `main`, required checks, no release on merge, beta/stable Environments, required reviewers, secret access limits, artifact retention, concurrency, and least-privilege Actions permissions.
- Apple: Developer ID certificate/team roles, App Store Connect/notarization key access, certificate expiry alerts, and approved bundle identifiers/team continuity.
- Cloudflare: R2 buckets, public custom domains, CORS if required, cache control, lifecycle/retention, object versioning strategy, DNS/TLS, access logs, and write-token scope.
- Registrar/website host: registrant ownership, auto-renew, transfer lock, DNSSEC decision, recovery contacts, deployment protection, preview access, production branch, rollback, and audit retention.
- Authentication: allowed redirects/origins, session lifetime, MFA and recovery policy, email verification, account deletion, abuse/rate limits, production domains, and environment separation.
- Entitlement hosting/database: region, encryption, backups/restore drills, point-in-time recovery, retention/deletion, network ingress, service identities, quotas, logs, and incident alerts.
- Transactional email: verified sender domains, SPF/DKIM/DMARC, templates, unsubscribe classification, bounce/complaint handling, and rate limits.
- Sparkle: stable/beta feed URLs, EdDSA public key, version ordering, minimum system version, phased rollout policy, release notes, and critical-update rules.
- Monitoring: download/appcast probes, webhook age/error alerts, entitlement error rate, checkout success, release adoption, crash rate, and card-safety incident alerts.
- Google Cloud, if used: OAuth consent-screen publication/testing state, allowed redirect model, scopes, test users, verification status, support/privacy links, and credential ownership.
- Optional alert integrations: Slack webhook/ntfy validation, redaction, opt-in defaults, rate limits, and non-blocking failure behavior.

## Human approvals

No automation may infer these approvals:

- Owner approval for prices, trial, refund policy, grace period, bounded offline revocation exposure, device limit, launch offer, and enforcement model.
- Owner approval for authentication/account recovery, entitlement hosting/database, transactional email, monitoring, and service ownership.
- Owner approval for Cloudflare/R2/DNS, registrar, website hosting, and customer download/update cutover.
- Legal approval for terms, privacy, refunds, tax posture, and accurate MIT-source representations.
- Owner approval for production Stripe and RevenueCat activation.
- Owner approval for merge when product decisions remain.
- Owner approval for beta release publication.
- Owner approval for stable promotion and rollout expansion.
- Named incident authority approval for rollback or rollout pause.
- Owner approval before rotating production credentials in a way that can interrupt service.

## Exit criteria for paid marketing release

Paid marketing remains BLOCKED until all of the following have evidence:

- Account, monthly, yearly, trial, restore, cancellation, refund, second-Mac, expired, and offline-grace flows pass in production-like mode.
- Billing and entitlement outages cannot interrupt an active import or unsafe-eject a card.
- Website downloads and Sparkle beta/stable feeds operate from R2 custom domains.
- The v0.3.14 GitHub-updater migration path and approved legacy-client support window are verified.
- A clean Mac installs the signed stable build and an existing install updates without data loss.
- Rollback, forward-fix, and out-of-band rescue procedures are exercised.
- Release authorization proves exact source, workflow, signer identity, notarization, and artifact digest independently of R2.
- Terms, Privacy Policy, Refund Policy, support, tax, monitoring, and incident ownership are live.
- Stable promotion requires an explicit approved action and produces an auditable record.

## Official implementation references

Provider behavior changes over time. These official references were rechecked on 2026-09-01:

- RevenueCat Web Purchase Links: <https://www.revenuecat.com/docs/web/web-billing/web-purchase-links>
- RevenueCat Web payment integrations: <https://www.revenuecat.com/docs/web/payment-integrations>
- RevenueCat hosted web paywalls: <https://www.revenuecat.com/docs/web/paywalls>
- RevenueCat webhooks: <https://www.revenuecat.com/docs/integrations/webhooks>
- Stripe subscriptions: <https://docs.stripe.com/billing/subscriptions/overview>
- Stripe webhook signature verification: <https://docs.stripe.com/webhooks/signature>
- Supabase Auth PKCE: <https://supabase.com/docs/guides/auth/sessions/pkce-flow>
- Sparkle publishing and EdDSA appcast signatures: <https://sparkle-project.org/documentation/publishing/>
- Sparkle update preferences and signed-feed settings: <https://sparkle-project.org/documentation/customization/>
- Apple Developer ID and notarization: <https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution>
- Cloudflare R2 public buckets and custom domains: <https://developers.cloudflare.com/r2/buckets/public-buckets/>
- Cloudflare R2 S3 conditional operations: <https://developers.cloudflare.com/r2/api/s3/api/>
