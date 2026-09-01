# DDump RevenueCat and Supabase Test-Mode Setup

This guide activates only the test implementation. It does not authorize live
products, production billing, DNS changes, or a public download cutover.

## 1. Create the isolated test environment

Use a dedicated Supabase project and RevenueCat project/app for DDump test
traffic. Keep production credentials out of local shell history and repository
files. Deploy the migration in
`supabase/migrations/20260901000000_paid_launch_foundation.sql`, then deploy the
Edge Functions listed in `supabase/config.toml`.

Supabase Auth must allow passwordless email and the DDump callback. Configure
the callback according to Supabase's current native-app redirect guidance for:

```text
ddump://auth/callback
```

The callback carries only an authorization code and state. The app rejects
callbacks containing bearer or refresh tokens, validates PKCE/state/expiry,
and exchanges the code directly with Supabase.

## 2. Create RevenueCat test products

Create exactly two test products and one entitlement:

- `ddump_test_monthly`
- `ddump_test_annual`
- `ddump_pro_test`

Do not create weekly pricing. Connect the supported RevenueCat Billing or
Stripe test-mode catalog, then create Web Purchase Links through RevenueCat's
hosted Paywall Builder. Record the generated purchase-link token for each
package in the server-side billing catalog. The Mac app never receives those
tokens through the catalog endpoint; it receives only a short-lived resolved
HTTPS checkout URL for its identified RevenueCat App User ID.

## 3. Configure truthful remote disclosures

Set `DDUMP_BILLING_CATALOG_JSON` in the Supabase secret store. Every disclosure
is required and checkout fails closed when the catalog is absent or malformed.
Replace placeholders only with values verified on the hosted test checkout:

```json
{
  "schema_version": 1,
  "environment": "test",
  "offering_id": "test-current",
  "variant_id": "control",
  "experiment_id": "test-launch-copy",
  "customer_portal_url": "https://<approved-portal-url>/{app_user_id}",
  "packages": [
    {
      "package_id": "monthly",
      "product_id": "ddump_test_monthly",
      "display_name": "Monthly test plan",
      "display_amount": "<verified final test amount>",
      "cadence": "monthly",
      "trial_disclosure": "<verified test trial disclosure>",
      "renewal_disclosure": "<verified renewal disclosure>",
      "tax_disclosure": "<verified tax disclosure>",
      "cancellation_disclosure": "<verified cancellation path>",
      "purchase_link_token": "<RevenueCat Web Purchase Link token>"
    },
    {
      "package_id": "annual",
      "product_id": "ddump_test_annual",
      "display_name": "Annual test plan",
      "display_amount": "<verified final test amount>",
      "cadence": "annual",
      "trial_disclosure": "<verified test trial disclosure>",
      "renewal_disclosure": "<verified renewal disclosure>",
      "tax_disclosure": "<verified tax disclosure>",
      "cancellation_disclosure": "<verified cancellation path>",
      "purchase_link_token": "<RevenueCat Web Purchase Link token>"
    }
  ]
}
```

`DDUMP_BILLING_LAB_CATALOGS_JSON` is an array of additional catalogs using the
same schema. The backend accepts only those approved variants, only in `test`,
and only from beta/debug builds. Overrides expire after 24 hours.

## 4. Configure backend secrets and policy boundaries

Set these names in the Supabase test secret store; never commit values:

```text
DDUMP_ENVIRONMENT=test
DDUMP_SUPABASE_URL
DDUMP_SUPABASE_SERVICE_ROLE_KEY
DDUMP_SUPABASE_PROJECT_ID
DDUMP_REVENUECAT_PROJECT_ID
DDUMP_REVENUECAT_WEBHOOK_AUTHORIZATION
DDUMP_REVENUECAT_WEBHOOK_HMAC_SECRET
DDUMP_STRIPE_WEBHOOK_SECRET
DDUMP_STRIPE_ACCOUNT_ID
DDUMP_ENTITLEMENT_PRIVATE_KEY_PKCS8_B64
DDUMP_ENTITLEMENT_PUBLIC_KEY_SPKI_B64
DDUMP_ENTITLEMENT_KEY_ID
DDUMP_ENTITLEMENT_ISSUER
DDUMP_ENTITLEMENT_AUDIENCE
DDUMP_DEFAULT_GRACE_SECONDS
DDUMP_REFRESH_SECONDS
DDUMP_MAX_AUTHORIZED_DEVICES
DDUMP_HOMEPAGE_RETURN_ORIGIN
DDUMP_BILLING_ENABLED=true
DDUMP_PRODUCTION_BILLING_APPROVED=false
DDUMP_BILLING_CATALOG_JSON
DDUMP_BILLING_LAB_CATALOGS_JSON
DDUMP_OPERATIONS_TOKEN
```

Generate a distinct test Ed25519 entitlement key outside the repository. Store
the PKCS#8 private DER only in the server secret store. The app embeds the SPKI
public DER as `key-id:base64`, for example through
`DDUMP_ENTITLEMENT_PUBLIC_KEYS`. Never reuse the Sparkle signing key.

The operations token is for dead-letter replay and reconciliation only. It
must use a separate operator secret and must not be available to the app.

## 5. Configure the beta/debug app

Use non-secret build variables:

```text
DDUMP_PAID_LAUNCH_ENABLED=1
DDUMP_PAID_ENVIRONMENT=test
DDUMP_PAID_BUILD_FLAVOR=beta
DDUMP_SUPABASE_URL
DDUMP_SUPABASE_PUBLISHABLE_KEY
DDUMP_ENTITLEMENT_ISSUER
DDUMP_ENTITLEMENT_AUDIENCE
DDUMP_ENTITLEMENT_PUBLIC_KEYS
DDUMP_CHECK_EMAIL_URL
```

The Supabase publishable key and public verification key are intentionally
non-secret. The service-role key, webhook credentials, purchase-link catalog,
and private signing key must never enter the app bundle.

## 6. Test-mode verification

Run local deterministic checks first:

```bash
./scripts/run-tests.sh
npx -y deno@2.9.6 fmt --check supabase tests/backend backend
npx -y deno@2.9.6 check supabase/functions/*/index.ts tests/backend/*.ts
npx -y deno@2.9.6 test --config backend/deno.json tests/backend
```

Then exercise real provider test mode with new test accounts:

1. Passwordless sign-in and callback.
2. Monthly and annual hosted checkout.
3. Abandonment, cancellation, delayed webhook, and failed payment.
4. Restore and second-Mac authorization.
5. Renewal failure, cancellation-at-period-end, expiry, and refund.
6. Offline grace and provider/API outage.
7. Duplicate, delayed, and out-of-order webhook delivery.
8. Dead-letter replay and reconciliation through the protected operations
   endpoint.

Record provider event IDs and redacted results. Do not record email addresses,
card data, media names, mounted-card names, or private paths.

## Production lock

Production billing remains disabled unless all of these are true:

- the backend environment is `production`;
- `DDUMP_BILLING_ENABLED=true`;
- `DDUMP_PRODUCTION_BILLING_APPROVED=true` is set by an owner-approved change;
- a production catalog with approved prices, legal copy, tax, trial, refund,
  and portal configuration is present.

This repository does not set those production values.
