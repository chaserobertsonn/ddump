# Remote Paywall and Billing Lab Guide

RevenueCat owns the hosted paywall and system-browser checkout. DDump never
downloads executable paywall code and never permits remote configuration to
alter ingest, helper, file, recovery, or eject behavior.

## Allowed remote changes

An approved catalog/Paywall Builder variant may change:

- layout and approved copy;
- monthly and annual package presentation;
- truthful amount, cadence, trial, renewal, tax, cancellation, and restore
  disclosures;
- targeting and experiment identifiers;
- the RevenueCat Web Purchase Link selected by the backend.

Weekly products, unknown product IDs, omitted restore access, arbitrary
components, unknown schema fields, non-HTTPS portal links, and unapproved link
tokens fail closed.

## Stable assignment

The backend returns an offering, variant, and experiment identifier for the
authenticated DDump account. App-side `PaywallCoordinator` keeps an assigned
variant stable across approved refreshes. Test-only backend overrides are
limited to catalogs in `DDUMP_BILLING_LAB_CATALOGS_JSON`, expire after 24 hours,
and are rejected for production or stable builds.

## Billing Lab

The Account settings tab exposes Billing Lab only for `debug` and `beta` build
flavors. Use a separate non-promotable `private-preview` candidate for Billing
Lab; the beta artifact eligible for exact-byte stable promotion uses stable
product behavior. The lab shows environment, account ID, offering, variant, experiment,
approved product IDs, and signed entitlement state without showing secrets.

Approved test scenarios expire after one hour:

- successful purchase;
- canceled checkout;
- abandoned checkout;
- restore;
- expiry;
- refund;
- failed renewal;
- offline grace;
- delayed webhook;
- provider outage.

These are synthetic test-environment entitlement responses. They never create
live provider charges and are impossible to select through the stable UI or a
production backend.

## Experiment procedure

1. Create the hosted test paywall in RevenueCat and verify its final checkout
   disclosures.
2. Add the corresponding catalog to the backend's approved test catalog array.
3. Deploy the test backend and refresh Billing Lab.
4. Force the approved variant for a test account.
5. Exercise monthly/annual checkout, abandonment, restore, lifecycle states,
   offline grace, and outage.
6. Confirm active card work is unaffected and only the next import at safe idle
   can be denied.
7. Record offering/variant/experiment IDs and redacted test evidence.
8. Remove or let the override expire.

No experiment moves to production until Chase approves price, copy, targeting,
trial, tax, refund, device, grace, support, and rollout decisions.
