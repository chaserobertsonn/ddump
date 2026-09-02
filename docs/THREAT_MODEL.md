# Paid Launch Threat Model

## Protected assets

- Customer media, receipts, logs, settings, pending work, and recovery state.
- Supabase sessions and installation private keys in the macOS Keychain.
- RevenueCat/Stripe webhook identity and durable provider event history.
- Server-only entitlement, Sparkle, release-authorization, Apple, R2, and
  provider private credentials.
- Stable/beta appcasts and immutable release artifacts.

## Trust boundaries

- The macOS app is untrusted for billing authority. It verifies signed,
  short-lived server entitlement documents but cannot mint them.
- RevenueCat is the provider-derived entitlement authority; direct Stripe
  events are audit/reconciliation-only.
- The entitlement service is the final access authority and keeps its private
  signing key server-side.
- Sparkle's EdDSA key authenticates update content. Developer ID/notarization
  authenticates Apple-distributed code. The release-authorization key binds
  source/provenance independently of R2.
- R2 stores bytes but does not authorize a release; protected promotion does.

## Principal threats and controls

| Threat | Control |
|---|---|
| Newer install offered an older GitHub release | Strict semantic ordering; only `remote > installed` is offered. |
| Copied or modified entitlement | Ed25519 JWS verification, account/product/installation ID and local installation-key hash binding, hard expiry, Keychain anti-rollback state. |
| Callback replay or scheme hijacking | PKCE, random state, expiry, Keychain-persisted pending flow, no bearer tokens in URL, authenticated account bootstrap. |
| Duplicate/delayed/out-of-order webhook | Raw-body authentication, provider/project/environment identity, durable composite event ID, retryable `received` state, canonical recomputation. |
| Provider event conflict | Same event ID with a different body is dead-lettered; protected replay/reconciliation tooling records operator reason. |
| Remote paywall changes ingest behavior | Strict catalog/product/component allowlist; hosted HTTPS checkout only; no remote code; billing modules have no ingest/eject methods. |
| Billing expiry interrupts a card | One shared shell gate runs before volume discovery; a start lease remains valid through active work; all existing customer surfaces stay available. |
| Update relaunch during card work | Sparkle delegate postpones relaunch/install-on-quit until run lock and unsafe phases clear. |
| Partial helper update | Manifest/hash/mode validation, same-volume staging, atomic replacement, journal recovery, preserved config/runtime state, safe-idle lease. |
| Compromised R2 credential publishes release | Immutable keys, channel-scoped credentials, signed release manifest, protected Environment approval, ETag CAS, external digest readback. |
| Compromised appcast | Whole-feed and enclosure EdDSA signatures, HTTPS, channel allowlist, separate beta/stable feeds. |
| Production billing accidentally activated | Billing disabled by default; production additionally requires explicit approval flag and complete approved catalog. |

## Residual risks requiring owner acceptance or external evidence

- Offline revocation cannot take effect before the signed hard grace expiry.
- A custom URL scheme can be claimed by another local app; PKCE/state and
  server-bound redemption prevent that app from obtaining a usable session,
  but the user may see a failed return. Universal-link migration remains an
  option after domain approval.
- Client-side access controls are not DRM against a hostile administrator.
  They are a safe product boundary that must never risk card or customer data.
- Apple notarization, R2/DNS, provider test dashboards, real payment lifecycle,
  clean-install, Intel, and real-card evidence remain external gates.
