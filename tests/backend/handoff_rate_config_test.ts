import { assert, assertEquals } from "./asserts.ts";
import { readConfig } from "../../supabase/functions/_shared/config.ts";
import {
  createCheckoutHandoff,
  redeemCheckoutHandoff,
} from "../../supabase/functions/_shared/handoff.ts";
import { FixedWindowRateLimiter } from "../../supabase/functions/_shared/rate_limit.ts";

Deno.test("checkout handoff is bound to account installation offering nonce and single use", async () => {
  const handoff = await createCheckoutHandoff({
    accountId: "acct_test_123",
    installationId: "inst_test_123",
    offeringId: "monthly_launch",
    pkceChallenge: "pkce_challenge",
    returnOrigin: "https://ddump.app",
    stateNonce: "state_nonce",
    ttlMs: 600_000,
    nowMs: 1_000,
  });

  const wrongAccount = await redeemCheckoutHandoff(handoff, {
    accountId: "acct_other",
    installationId: "inst_test_123",
    offeringId: "monthly_launch",
    stateNonce: "state_nonce",
    nowMs: 2_000,
  });
  assert(!wrongAccount.ok);
  assertEquals(wrongAccount.reason, "handoff_account_mismatch");
  const wrongOffering = await redeemCheckoutHandoff(handoff, {
    accountId: "acct_test_123",
    installationId: "inst_test_123",
    offeringId: "yearly_launch",
    stateNonce: "state_nonce",
    nowMs: 2_000,
  });
  assert(!wrongOffering.ok);
  assertEquals(wrongOffering.reason, "handoff_offering_mismatch");

  const redeemed = await redeemCheckoutHandoff(handoff, {
    accountId: "acct_test_123",
    installationId: "inst_test_123",
    offeringId: "monthly_launch",
    stateNonce: "state_nonce",
    nowMs: 2_000,
  });
  assert(redeemed.ok);
  const duplicate = await redeemCheckoutHandoff(redeemed.handoff, {
    accountId: "acct_test_123",
    installationId: "inst_test_123",
    offeringId: "monthly_launch",
    stateNonce: "state_nonce",
    nowMs: 3_000,
  });
  assert(!duplicate.ok);
  assertEquals(duplicate.reason, "handoff_already_consumed");
});

Deno.test("fixed window rate limiter hashes subjects and separates windows", async () => {
  const limiter = new FixedWindowRateLimiter();
  assert(
    (await limiter.check("refresh", "acct_test_123", 2, 60_000, 1_000)).allowed,
  );
  const second = await limiter.check(
    "refresh",
    "acct_test_123",
    2,
    60_000,
    2_000,
  );
  assert(second.allowed);
  assertEquals(second.remaining, 0);
  assertEquals(
    (await limiter.check("refresh", "acct_test_123", 2, 60_000, 3_000)).allowed,
    false,
  );
  assert(
    (await limiter.check("refresh", "acct_test_123", 2, 60_000, 61_000))
      .allowed,
  );
  assertEquals(second.subjectHash.includes("acct_test_123"), false);
});

Deno.test("runtime config defaults to test environment and separates production explicitly", () => {
  const testConfig = readConfig(() => undefined);
  assertEquals(testConfig.environment, "test");
  assertEquals(testConfig.entitlementPolicy.environment, "test");

  let productionWithoutApprovalFailed = false;
  try {
    readConfig((name) => ({ DDUMP_ENVIRONMENT: "production" })[name]);
  } catch {
    productionWithoutApprovalFailed = true;
  }
  assert(productionWithoutApprovalFailed);

  let productionWithInvalidPolicyFailed = false;
  try {
    readConfig((name) =>
      ({
        DDUMP_ENVIRONMENT: "production",
        DDUMP_MAX_AUTHORIZED_DEVICES: "not-approved",
        DDUMP_DEFAULT_GRACE_SECONDS: "86400",
      })[name]
    );
  } catch {
    productionWithInvalidPolicyFailed = true;
  }
  assert(productionWithInvalidPolicyFailed);

  const productionConfig = readConfig((name) =>
    ({
      DDUMP_ENVIRONMENT: "production",
      DDUMP_MAX_AUTHORIZED_DEVICES: "3",
      DDUMP_DEFAULT_GRACE_SECONDS: "86400",
    })[name]
  );
  assertEquals(productionConfig.environment, "production");
  assertEquals(productionConfig.entitlementPolicy.environment, "production");
  assertEquals(productionConfig.entitlementPolicy.maxAuthorizedDevices, 3);
});
