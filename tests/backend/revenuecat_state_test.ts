import { assertEquals } from "./asserts.ts";
import {
  recomputeRevenueCatEntitlement,
  refreshResultFromState,
} from "../../supabase/functions/_shared/entitlement_state.ts";
import { InMemoryProviderInbox } from "../../supabase/functions/_shared/provider_inbox.ts";
import { parseRevenueCatWebhook } from "../../supabase/functions/_shared/revenuecat.ts";

const accountId = "acct_test_123";
const productId = "ddump_pro";
const nowMs = Date.parse("2026-09-01T18:00:00Z");
const graceMs = 7 * 24 * 60 * 60 * 1000;

Deno.test("RevenueCat duplicate and out-of-order events recompute canonical active state", async () => {
  const inbox = new InMemoryProviderInbox();
  const renewal = parseRevenueCatWebhook({
    event: {
      id: "evt_renewal",
      type: "RENEWAL",
      app_user_id: "acct_test_123",
      product_id: "ddump_pro",
      entitlement_ids: ["ddump_pro"],
      event_timestamp_ms: Date.parse("2026-08-31T00:00:00Z"),
      purchased_at_ms: Date.parse("2026-08-01T00:00:00Z"),
      expiration_at_ms: Date.parse("2026-10-01T00:00:00Z"),
      environment: "TEST",
    },
  }, "rc_test_project");
  const initial = parseRevenueCatWebhook({
    event: {
      id: "evt_initial",
      type: "INITIAL_PURCHASE",
      app_user_id: "acct_test_123",
      product_id: "ddump_pro",
      entitlement_ids: ["ddump_pro"],
      event_timestamp_ms: Date.parse("2026-08-01T00:00:00Z"),
      purchased_at_ms: Date.parse("2026-08-01T00:00:00Z"),
      expiration_at_ms: Date.parse("2026-09-01T00:00:00Z"),
      environment: "TEST",
    },
  }, "rc_test_project");

  assertEquals(
    (await inbox.receiveRevenueCatEvent(renewal)).status,
    "accepted",
  );
  assertEquals(
    (await inbox.receiveRevenueCatEvent(initial)).status,
    "accepted",
  );
  assertEquals(
    (await inbox.receiveRevenueCatEvent(renewal)).status,
    "duplicate",
  );

  const canonical = recomputeRevenueCatEntitlement(
    accountId,
    productId,
    inbox.revenueCatEvents,
    nowMs,
    graceMs,
  );
  assertEquals(canonical.status, "active");
  assertEquals(canonical.paidThroughAt, "2026-10-01T00:00:00.000Z");
});

Deno.test("RevenueCat same event id with different body dead-letters as body conflict", async () => {
  const inbox = new InMemoryProviderInbox();
  const first = parseRevenueCatWebhook({
    event: {
      id: "evt_conflict",
      type: "INITIAL_PURCHASE",
      app_user_id: accountId,
      product_id: productId,
      entitlement_ids: [productId],
      event_timestamp_ms: nowMs,
      expiration_at_ms: nowMs + 86_400_000,
      environment: "TEST",
    },
  }, "rc_test_project");
  const second = parseRevenueCatWebhook({
    event: {
      id: "evt_conflict",
      type: "REFUND",
      app_user_id: accountId,
      product_id: productId,
      entitlement_ids: [productId],
      event_timestamp_ms: nowMs,
      environment: "TEST",
    },
  }, "rc_test_project");

  assertEquals((await inbox.receiveRevenueCatEvent(first)).status, "accepted");
  assertEquals(
    (await inbox.receiveRevenueCatEvent(second)).status,
    "body_conflict",
  );
  assertEquals(inbox.revenueCatEvents.length, 1);
});

Deno.test("RevenueCat terminal refund wins over delayed active events", async () => {
  const events = [
    parseRevenueCatWebhook({
      event: {
        id: "evt_late_active",
        type: "RENEWAL",
        app_user_id: accountId,
        product_id: productId,
        entitlement_ids: [productId],
        event_timestamp_ms: Date.parse("2026-08-30T00:00:00Z"),
        expiration_at_ms: Date.parse("2026-10-01T00:00:00Z"),
        environment: "TEST",
      },
    }, "rc_test_project"),
    parseRevenueCatWebhook({
      event: {
        id: "evt_refund",
        type: "REFUND",
        app_user_id: accountId,
        product_id: productId,
        entitlement_ids: [productId],
        event_timestamp_ms: Date.parse("2026-08-29T00:00:00Z"),
        environment: "TEST",
      },
    }, "rc_test_project"),
  ];
  const canonical = recomputeRevenueCatEntitlement(
    accountId,
    productId,
    events,
    nowMs,
    graceMs,
  );
  assertEquals(canonical.status, "refunded");
  assertEquals(refreshResultFromState(canonical, false), "indeterminate");
  assertEquals(refreshResultFromState(canonical, true), "revoked");
});
