import { assert, assertEquals } from "./asserts.ts";
import {
  customerPortalLink,
  parseBillingCatalog,
  parseBillingCatalogs,
  publicBillingCatalog,
  purchaseLink,
} from "../../supabase/functions/_shared/billing.ts";
import { readConfig } from "../../supabase/functions/_shared/config.ts";

const catalogJSON = JSON.stringify({
  schema_version: 1,
  environment: "test",
  offering_id: "test-current",
  variant_id: "control",
  customer_portal_url: "https://portal.example.test/customer/{app_user_id}",
  packages: [
    {
      package_id: "monthly",
      product_id: "ddump_test_monthly",
      display_name: "Monthly test plan",
      display_amount: "$0.00 test",
      cadence: "monthly",
      trial_disclosure: "No test trial",
      renewal_disclosure: "Test-mode renewal disclosure",
      tax_disclosure: "Test-mode tax disclosure",
      cancellation_disclosure: "Cancel in the test customer portal",
      purchase_link_token: "monthly_test_token",
    },
    {
      package_id: "annual",
      product_id: "ddump_test_annual",
      display_name: "Annual test plan",
      display_amount: "$0.00 test",
      cadence: "annual",
      trial_disclosure: "No test trial",
      renewal_disclosure: "Test-mode renewal disclosure",
      tax_disclosure: "Test-mode tax disclosure",
      cancellation_disclosure: "Cancel in the test customer portal",
      purchase_link_token: "annual_test_token",
    },
  ],
});

Deno.test("Billing Lab parses only backend-approved catalog variants", () => {
  const variants = parseBillingCatalogs(`[${catalogJSON}]`, "test");
  assertEquals(variants.length, 1);
  assertEquals(variants[0].variantId, "control");
});

Deno.test("billing catalog keeps final disclosures but never exposes purchase tokens", () => {
  const catalog = parseBillingCatalog(catalogJSON, "test")!;
  assertEquals(catalog.packages.length, 2);
  const publicCatalog = publicBillingCatalog(catalog);
  assertEquals(publicCatalog.packages[0].display_amount, "$0.00 test");
  assert(!JSON.stringify(publicCatalog).includes("monthly_test_token"));
  assertEquals(
    purchaseLink(catalog, "monthly", "account/with space").toString(),
    "https://pay.rev.cat/monthly_test_token/account%2Fwith%20space",
  );
  assertEquals(
    customerPortalLink(catalog, "account/with space").toString(),
    "https://portal.example.test/customer/account%2Fwith%20space",
  );
});

Deno.test("billing catalog rejects weekly pricing and mismatched environments", () => {
  const weekly = JSON.parse(catalogJSON);
  weekly.packages[0].cadence = "weekly";
  let weeklyFailed = false;
  try {
    parseBillingCatalog(JSON.stringify(weekly), "test");
  } catch {
    weeklyFailed = true;
  }
  assert(weeklyFailed);

  let environmentFailed = false;
  try {
    parseBillingCatalog(catalogJSON, "production");
  } catch {
    environmentFailed = true;
  }
  assert(environmentFailed);
});

Deno.test("production billing cannot be enabled without explicit approval", () => {
  let failed = false;
  try {
    readConfig((name) =>
      ({
        DDUMP_ENVIRONMENT: "production",
        DDUMP_MAX_AUTHORIZED_DEVICES: "2",
        DDUMP_DEFAULT_GRACE_SECONDS: "86400",
        DDUMP_BILLING_ENABLED: "true",
      })[name]
    );
  } catch {
    failed = true;
  }
  assert(failed);
});
