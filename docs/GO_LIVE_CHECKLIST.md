# DDump Go-Live Checklist

This is the release gate for turning the current public preview into a paid product. A checked box means verified, not merely configured.

## 1. Product and release safety

- [x] Contact-sheet landing page deployed at `ddump.app` and `www.ddump.app`
- [x] Contact-sheet macOS UI builds as a universal app for macOS 13+
- [x] Light and dark visual QA passed without clipping, overlap, or blank rendering
- [x] Core ingest engine remains outside the UI layer and unchanged by the redesign
- [x] Public-readiness, shell syntax, delayed-mount, settings-sheet, and launch checks pass
- [ ] Build DDump 0.3.18 with Developer ID signing, Apple notarization, stapling, and Gatekeeper validation
- [ ] Install 0.3.18 from the finished DMG on a clean non-developer Mac account
- [ ] Run a real-card smoke test: detect, copy, verify, organize, queue backup, eject last
- [ ] Test interrupted network, unavailable backup folder, reconnect, retry, and restart recovery
- [ ] Test update from the currently public version without losing config, trust records, pending work, or receipts
- [ ] Publish a rollback-ready GitHub release with checksum, release notes, minimum macOS version, and known issues
- [ ] Update every website download button only after the 0.3.18 asset returns HTTP 200

## 2. Pricing, paywall, and entitlement

- [ ] Decide the distribution path before building billing: Mac App Store, direct signed download, or both
- [ ] Decide launch offer, monthly/annual/lifetime products, trial length, refund policy, and founding-user treatment
- [ ] Configure RevenueCat products, offerings, entitlements, restore-purchase flow, webhook verification, and offline grace behavior
- [ ] Make ingest safety usable during billing outages; a failed entitlement check must not strand a mounted card or active copy
- [ ] Add paywall, purchase success, restore, expired, refunded, and billing-unavailable states
- [ ] Verify purchase and restore on a clean account, existing account, second Mac, expired subscription, and refunded subscription
- [ ] Keep server-side entitlement checks authoritative and never ship private billing keys in the app
- [ ] Add a manual support path for entitlement repair and refunds

## 3. GHL, reminders, and lifecycle messaging

- [ ] Create separate GHL fields for product lead, reminder request, customer status, entitlement status, platform, and consent timestamp/source
- [ ] Connect the website reminder form to a real backend; never expose GHL credentials in browser JavaScript
- [ ] Separate one-time transactional reminders from optional marketing consent
- [ ] Add privacy and terms links beside every live contact form before collecting phone numbers or email addresses
- [ ] Configure SMS sender/registration, STOP/HELP handling, quiet-hours logic, email authentication, and suppression lists
- [ ] Build workflows for reminder, download, onboarding, abandoned checkout, purchase, failed renewal, cancellation, and win-back
- [ ] Deduplicate contacts and make webhook processing idempotent
- [ ] Test text, email, both, opt-out, malformed contact data, duplicate submission, and provider outage

## 4. Legal, privacy, support, and operations

- [ ] Publish Privacy Policy, Terms, Refund Policy, Support, and contact pages
- [ ] Document what stays local, what leaves the Mac, what analytics are collected, retention, deletion, and subprocessors
- [ ] Review website and SMS consent language with qualified counsel before paid traffic
- [ ] Create `support@ddump.app` and authenticate domain email with SPF, DKIM, and DMARC
- [ ] Add in-app support diagnostics with explicit user consent and secret/path redaction
- [ ] Add crash reporting and privacy-respecting product analytics with release/version tags
- [ ] Monitor website uptime, download failures, purchase webhooks, entitlement errors, and crash spikes
- [ ] Write support playbooks for missing files, stuck eject, failed backup, lost purchase, refund, and corrupted config
- [ ] Define incident owner, rollback procedure, status-message channel, and customer notification threshold

## 5. Website, analytics, and launch

- [ ] Redirect `www.ddump.app` to canonical `https://ddump.app/` instead of serving a duplicate 200 page
- [ ] Add an Open Graph/Twitter preview image, favicon variants, Apple touch icon, and structured software-app data
- [ ] Replace prototype reminder copy and disabled behavior when GHL is connected
- [ ] Add privacy-respecting funnel events for page view, download click, reminder submit, checkout start, purchase, install, and first verified dump
- [ ] Verify mobile and desktop in Safari, Chrome, and Firefox, including keyboard navigation and reduced motion
- [ ] Validate sitemap, robots, canonical URL, security headers, 404 page, and performance budget
- [ ] Prepare launch screenshots, demo video, FAQ, comparison page, onboarding email, and support macros
- [ ] Run a private beta with working photographers before paid acquisition
- [ ] Define launch success metrics: qualified visits, downloads, installs, first verified dumps, trial starts, paid conversion, churn, refunds, and safety incidents

## Launch decision

Do not call DDump launched until these four gates are green:

1. A clean machine installs a signed and notarized release.
2. A real card completes the safety workflow and survives an interrupted backup.
3. Purchase, entitlement, restore, cancellation, and refund states work end to end.
4. Privacy, support, monitoring, and rollback paths are live.
