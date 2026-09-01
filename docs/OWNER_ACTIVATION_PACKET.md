# Paid Launch Owner Activation Packet

The code foundation is ready for provider test-mode setup. Nothing in this
packet has been activated externally.

## Decisions Chase must approve before production

| Area | Required decision |
|---|---|
| Pricing | Monthly price; annual price/discount; no weekly plan. |
| Trial | Eligibility, duration, payment-method requirement, and copy. |
| Refunds | Refund window, exceptions, dispute handling, and support authority. |
| Tax | Legal entity, nexus/registration advice, tax service, invoice/receipt treatment. |
| Devices | Maximum authorized Macs, replacement/deauthorization policy, support exception TTL. |
| Offline | Hard grace duration and acceptance of delayed offline refund/revocation. |
| Founders | Existing/founding-user treatment and migration communication. |
| Identity | Supabase production approval, email provider, recovery policy, deletion retention, support repair approvers. |
| Legal | Terms, Privacy Policy, Refund Policy, subscription disclosures, and accurate MIT-source representations. |
| Release | First paid version, beta cohort, phased interval, soak/health thresholds, rollback authority. |

## External setup still required

- Create/verify Supabase test and production projects, passwordless email, SMTP,
  redirect allowlist, database migration, Edge Functions, logs, alerts, backups,
  and secret stores.
- Create/verify RevenueCat project/app, monthly/annual test products, canonical
  entitlement, hosted Paywall Builder variants, Web Purchase Links, customer
  portal, webhook, and least-privilege members.
- Configure RevenueCat Billing or the supported Stripe connection in test mode;
  configure Stripe live mode only after approval.
- Create the R2 bucket, object-lock/retention posture, beta/stable scoped keys,
  and protected GitHub Environments with required reviewers.
- Configure and externally verify `downloads.ddump.app`,
  `updates.ddump.app`, and the approved API/account domains, TLS, and cache
  behavior.
- Configure GitHub repository required checks, Environment variables/secrets,
  version uniqueness policy, and monitoring.
- Configure SPF, DKIM, DMARC, support email, customer communications, privacy,
  entitlement/webhook monitoring, and incident ownership.

## Exact secret names

Server/backend names are in `backend/env.example`. Release names are in
`config/release.env.example` and `docs/RELEASE_SETUP.md`. The Mac app receives
only Supabase's publishable key and public Sparkle/entitlement verification
keys.

## Evidence still required before beta/stable

- Real RevenueCat/Stripe/Supabase test-mode monthly, annual, restore, second
  Mac, cancellation, failed renewal, refund, expiry, delayed webhook, and
  outage results.
- Protected workflow signing/notarization/Gatekeeper run and external R2
  readback for the exact candidate.
- Clean non-developer Mac install, v0.3.14 migration, Sparkle next-version,
  Apple Silicon and Intel/equivalent, real-card, interrupted import, helper
  migration, rollback, forward-fix, and rescue-installer exercises.
- Production legal/tax/support approval and explicit beta/stable promotion.

## Explicitly prohibited without a new approval

Do not enable production billing, set live prices, mutate DNS, change website
downloads, publish a GitHub migration release, promote an appcast, distribute a
customer build, change repository visibility, or change the MIT license.
