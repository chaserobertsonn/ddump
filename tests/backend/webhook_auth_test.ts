import { assert, assertEquals } from "./asserts.ts";
import { hmacSha256Hex } from "../../supabase/functions/_shared/crypto.ts";
import {
  verifyRevenueCatAuthorization,
  verifyRevenueCatSignature,
  verifyStripeSignature,
} from "../../supabase/functions/_shared/webhook_auth.ts";

Deno.test("RevenueCat webhook auth requires exact configured Authorization header", () => {
  const headers = new Headers({ authorization: "RevenueCat fixture token" });
  assert(verifyRevenueCatAuthorization(headers, "RevenueCat fixture token").ok);
  assertEquals(
    verifyRevenueCatAuthorization(headers, "fixture token").reason,
    "invalid_revenuecat_authorization",
  );
  assertEquals(
    verifyRevenueCatAuthorization(new Headers(), "RevenueCat fixture token")
      .reason,
    "invalid_revenuecat_authorization",
  );
});

Deno.test("RevenueCat HMAC verifies exact raw body and rejects stale timestamps", async () => {
  const rawBody = '{"event":{"id":"evt_rc_1"}}';
  const timestamp = 1_800_000_000;
  const secret = "revenuecat_fixture_secret";
  const signature = await hmacSha256Hex(secret, `${timestamp}.${rawBody}`);
  const header = `t=${timestamp},v1=${signature}`;
  assert(
    (await verifyRevenueCatSignature(rawBody, header, secret, timestamp)).ok,
  );
  assertEquals(
    (await verifyRevenueCatSignature(`${rawBody}\n`, header, secret, timestamp))
      .reason,
    "invalid_revenuecat_signature",
  );
  assertEquals(
    (await verifyRevenueCatSignature(rawBody, header, secret, timestamp + 301))
      .reason,
    "stale_revenuecat_signature",
  );
});

Deno.test("Stripe webhook verification uses exact raw body and timestamped v1 HMAC", async () => {
  const rawBody = '{"id":"evt_1","object":"event","livemode":false}';
  const timestamp = 1_800_000_000;
  const secret = "stripe_fixture_secret";
  const signature = await hmacSha256Hex(secret, `${timestamp}.${rawBody}`);
  const header = `t=${timestamp},v1=${signature}`;

  assert((await verifyStripeSignature(rawBody, header, secret, timestamp)).ok);
  assertEquals(
    (await verifyStripeSignature(`${rawBody}\n`, header, secret, timestamp))
      .reason,
    "invalid_stripe_signature",
  );
  assertEquals(
    (await verifyStripeSignature(rawBody, header, secret, timestamp + 301))
      .reason,
    "stale_stripe_signature",
  );
});
