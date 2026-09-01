import {
  customerPortalLink,
  publicBillingCatalog,
  purchaseLink,
} from "../_shared/billing.ts";
import { readConfig } from "../_shared/config.ts";
import {
  badRequest,
  jsonResponse,
  methodNotAllowed,
  tooManyRequests,
  unauthorized,
} from "../_shared/http.ts";
import { consumePersistentRateLimit } from "../_shared/rate_limit.ts";
import { resolveAuthenticatedAccount } from "../_shared/request_auth.ts";
import { SupabaseRestClient } from "../_shared/supabase_rest.ts";

Deno.serve(async (request) => {
  if (request.method !== "POST") return methodNotAllowed();
  const config = readConfig();
  if (!config.billingEnabled) {
    return jsonResponse({ ok: false, error: "billing_disabled" }, {
      status: 503,
    });
  }
  if (!config.billingCatalog) {
    return jsonResponse(
      { ok: false, error: "billing_catalog_not_configured" },
      { status: 503 },
    );
  }
  const body = await request.json().catch(() => undefined) as
    | Record<string, unknown>
    | undefined;
  if (!body) return badRequest("invalid_json");
  const supabase = new SupabaseRestClient({
    url: config.supabaseUrl,
    serviceRoleKey: config.supabaseServiceRoleKey,
  });
  const accountId = await resolveAuthenticatedAccount(
    request,
    supabase,
    config,
  );
  if (!accountId) return unauthorized("authenticated_account_not_found");
  if (
    !await consumePersistentRateLimit(
      supabase,
      config,
      "billing-session",
      accountId,
      30,
      60,
    )
  ) return tooManyRequests();
  const buildFlavor = request.headers.get("x-ddump-build-flavor") || "stable";
  const labAllowed = config.environment === "test" &&
    (buildFlavor === "debug" || buildFlavor === "beta");
  const approvedCatalogs = [
    config.billingCatalog,
    ...config.billingLabCatalogs,
  ];
  let catalog = config.billingCatalog;
  if (labAllowed) {
    const overrideRows = await supabase.select(
      "ddump_billing_lab_overrides",
      [
        "select=offering_id,variant_id,expires_at",
        `account_id=eq.${encodeURIComponent(accountId)}`,
        "environment=eq.test",
        `expires_at=gt.${encodeURIComponent(new Date().toISOString())}`,
        "limit=1",
      ].join("&"),
    );
    const active = overrideRows[0];
    const selected = approvedCatalogs.find((item) =>
      item.offeringId === active?.offering_id &&
      item.variantId === active?.variant_id
    );
    if (selected) catalog = selected;
  }
  const mappings = await supabase.select(
    "ddump_provider_mappings",
    [
      "select=provider_account_id",
      `account_id=eq.${encodeURIComponent(accountId)}`,
      `environment=eq.${config.environment}`,
      "provider=eq.revenuecat",
      `provider_project_id=eq.${
        encodeURIComponent(config.revenueCatProjectId)
      }`,
      "is_active=eq.true",
      "limit=1",
    ].join("&"),
  );
  const appUserId = String(mappings[0]?.provider_account_id || accountId);
  const action = String(body.action || "catalog");

  if (action === "catalog") {
    return jsonResponse({
      ok: true,
      catalog: publicBillingCatalog(catalog),
      available_test_variants: labAllowed
        ? approvedCatalogs.map((item) => ({
          offering_id: item.offeringId,
          variant_id: item.variantId,
          experiment_id: item.experimentId,
        }))
        : [],
      available_test_scenarios: labAllowed
        ? [
          "successful_purchase",
          "canceled_checkout",
          "abandoned_checkout",
          "restore",
          "expiry",
          "refund",
          "failed_renewal",
          "offline_grace",
          "delayed_webhook",
          "provider_outage",
        ]
        : [],
    });
  }
  if (action === "set_test_override") {
    if (!labAllowed) return badRequest("billing_lab_not_allowed");
    const offeringId = String(body.offering_id || "");
    const variantId = String(body.variant_id || "");
    const approved = approvedCatalogs.find((item) =>
      item.offeringId === offeringId && item.variantId === variantId
    );
    if (!approved) return badRequest("billing_lab_variant_not_approved");
    const response = await supabase.upsert("ddump_billing_lab_overrides", {
      account_id: accountId,
      environment: "test",
      offering_id: approved.offeringId,
      variant_id: approved.variantId,
      requested_by: "authenticated_test_customer",
      expires_at: new Date(Date.now() + 24 * 60 * 60 * 1000).toISOString(),
      updated_at: new Date().toISOString(),
    }, "account_id,environment");
    if (!response.ok) {
      return jsonResponse({ ok: false, error: "billing_lab_override_failed" }, {
        status: 500,
      });
    }
    return jsonResponse({ ok: true, catalog: publicBillingCatalog(approved) });
  }
  if (action === "set_test_scenario") {
    if (!labAllowed) return badRequest("billing_lab_not_allowed");
    const scenario = String(body.scenario || "");
    const allowedScenarios = new Set([
      "successful_purchase",
      "canceled_checkout",
      "abandoned_checkout",
      "restore",
      "expiry",
      "refund",
      "failed_renewal",
      "offline_grace",
      "delayed_webhook",
      "provider_outage",
    ]);
    if (!allowedScenarios.has(scenario)) {
      return badRequest("billing_lab_scenario_not_approved");
    }
    const productId = String(body.product_id || catalog.packages[0].productId);
    if (!catalog.packages.some((item) => item.productId === productId)) {
      return badRequest("billing_lab_product_not_approved");
    }
    const response = await supabase.upsert("ddump_billing_lab_scenarios", {
      account_id: accountId,
      environment: "test",
      scenario,
      product_id: productId,
      requested_by: "authenticated_test_customer",
      expires_at: new Date(Date.now() + 60 * 60 * 1000).toISOString(),
      updated_at: new Date().toISOString(),
    }, "account_id,environment");
    if (!response.ok) {
      return jsonResponse({ ok: false, error: "billing_lab_scenario_failed" }, {
        status: 500,
      });
    }
    return jsonResponse({ ok: true, scenario, product_id: productId });
  }
  if (action === "checkout") {
    try {
      const url = purchaseLink(
        catalog,
        String(body.package_id || ""),
        appUserId,
      );
      return jsonResponse({
        ok: true,
        checkout_url: url.toString(),
        revenuecat_app_user_id: appUserId,
        offering_id: catalog.offeringId,
        variant_id: catalog.variantId,
        state_nonce: crypto.randomUUID(),
        expires_at: new Date(Date.now() + 10 * 60 * 1000).toISOString(),
      });
    } catch (error) {
      return badRequest(
        error instanceof Error ? error.message : "checkout_link_failed",
      );
    }
  }
  if (action === "portal") {
    try {
      return jsonResponse({
        ok: true,
        customer_portal_url: customerPortalLink(
          catalog,
          appUserId,
        ).toString(),
      });
    } catch (error) {
      return badRequest(
        error instanceof Error ? error.message : "customer_portal_failed",
      );
    }
  }
  return badRequest("unknown_action");
});
