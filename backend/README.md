# DDump Paid-Launch Backend Foundation

This backend scaffold is test-mode-default and keeps all privileged material
server-side. It does not activate Stripe, RevenueCat, Supabase, or any external
service.

## Layout

- `supabase/migrations/`: durable Postgres schema for accounts, provider
  inboxes, canonical entitlements, handoffs, replay/reconciliation, repair,
  deletion, audit, and rate-limit state.
- `supabase/functions/`: Deno Edge Function entrypoints.
- `supabase/functions/_shared/`: dependency-free TypeScript modules used by the
  functions and tests.
- `tests/backend/`: deterministic Deno tests and fixtures.

## Local Test Commands

```bash
cd /Users/chaserobertson/Personal-Projects/DDump-paid-launch
npx -y deno@2.9.6 fmt --check supabase/functions tests/backend
npx -y deno@2.9.6 check supabase/functions/*/index.ts tests/backend/*.ts
npx -y deno@2.9.6 test --config backend/deno.json tests/backend
```

Customer endpoints cover account profile, browser callback handoff, billing
session/catalog, device restore, and entitlement refresh. Provider endpoints
cover RevenueCat and supplemental Stripe webhooks. The operations endpoint
supports authenticated dead-letter inspection, replay, and reconciliation.

Use `docs/TEST_MODE_BILLING.md` for provider setup and
`docs/REMOTE_PAYWALL_EXPERIMENTS.md` for allowlisted test variants. Database
objects are created by
`supabase/migrations/20260901000000_paid_launch_foundation.sql`.

`backend/env.example` lists required environment names without values.
Production private signing keys, webhook credentials, and provider API keys must
be set only in the server secret store. The app receives only public
verification keys.
