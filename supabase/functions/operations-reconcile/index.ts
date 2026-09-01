import { readConfig } from "../_shared/config.ts";
import { constantTimeEqual } from "../_shared/crypto.ts";
import { recomputeRevenueCatEntitlement } from "../_shared/entitlement_state.ts";
import {
  badRequest,
  jsonResponse,
  methodNotAllowed,
  unauthorized,
} from "../_shared/http.ts";
import { parseRevenueCatWebhook } from "../_shared/revenuecat.ts";
import { SupabaseRestClient } from "../_shared/supabase_rest.ts";

Deno.serve(async (request) => {
  if (request.method !== "POST") return methodNotAllowed();
  const config = readConfig();
  const expected = config.operationsToken
    ? `Bearer ${config.operationsToken}`
    : "";
  if (
    !expected ||
    !constantTimeEqual(request.headers.get("authorization") || "", expected)
  ) {
    return unauthorized("operations_authorization_failed");
  }
  const body = await request.json().catch(() => undefined) as
    | Record<string, unknown>
    | undefined;
  if (!body) return badRequest("invalid_json");
  const action = String(body.action || "");
  const supabase = new SupabaseRestClient({
    url: config.supabaseUrl,
    serviceRoleKey: config.supabaseServiceRoleKey,
  });

  if (action === "replay_event") {
    const inboxID = String(body.provider_event_inbox_id || "");
    const reason = String(body.reason || "");
    if (!inboxID || !reason) return badRequest("replay_id_and_reason_required");
    const rows = await supabase.select(
      "ddump_provider_event_inbox",
      [
        "select=id,account_id,provider_account_id,provider_project_id,raw_event,event_type,attempts",
        `id=eq.${encodeURIComponent(inboxID)}`,
        "provider=eq.revenuecat",
        `environment=eq.${config.environment}`,
        "limit=1",
      ].join("&"),
    );
    const row = rows[0];
    if (!row?.account_id || !row?.provider_account_id) {
      return badRequest("replay_event_missing_account_mapping");
    }
    const canonical = await recompute(
      supabase,
      config,
      String(row.account_id),
      String(row.provider_account_id),
      String(row.provider_project_id),
      row.raw_event as Record<string, unknown>,
    );
    await supabase.insert("ddump_replay_requests", {
      environment: config.environment,
      provider_event_id: inboxID,
      requested_by: "operations_token",
      reason,
      status: "completed",
      started_at: new Date().toISOString(),
      completed_at: new Date().toISOString(),
      result: {
        canonical_status: canonical.status,
        product_id: canonical.productId,
      },
    });
    await supabase.update(
      "ddump_provider_event_inbox",
      `id=eq.${encodeURIComponent(inboxID)}`,
      {
        status: "replayed",
        attempts: Number(row.attempts || 0) + 1,
        processed_at: new Date().toISOString(),
      },
    );
    return jsonResponse({
      ok: true,
      action,
      provider_event_inbox_id: inboxID,
      canonical_status: canonical.status,
      product_id: canonical.productId,
    });
  }

  if (action === "request_reconciliation") {
    const accountID = String(body.account_id || "");
    const providerAccountID = String(body.provider_account_id || "");
    const reason = String(body.reason || "");
    if (!accountID || !providerAccountID || !reason) {
      return badRequest("reconciliation_identity_and_reason_required");
    }
    const response = await supabase.insert("ddump_reconciliation_runs", {
      environment: config.environment,
      provider: "revenuecat",
      account_id: accountID,
      provider_account_id: providerAccountID,
      requested_by: "operations_token",
      status: "open",
      divergence_summary: reason,
    });
    if (!response.ok) {
      return jsonResponse(
        { ok: false, error: "reconciliation_request_failed" },
        {
          status: 500,
        },
      );
    }
    return jsonResponse({ ok: true, action, status: "open" });
  }

  return badRequest("unknown_action");
});

async function recompute(
  supabase: SupabaseRestClient,
  config: ReturnType<typeof readConfig>,
  accountID: string,
  appUserID: string,
  projectID: string,
  triggerRawEvent: Record<string, unknown>,
) {
  const trigger = parseRevenueCatWebhook(triggerRawEvent, projectID);
  const eventRows = await supabase.select(
    "ddump_provider_event_inbox",
    [
      "select=raw_event",
      "provider=eq.revenuecat",
      `environment=eq.${config.environment}`,
      `provider_project_id=eq.${encodeURIComponent(projectID)}`,
      `provider_account_id=eq.${encodeURIComponent(appUserID)}`,
      "status=neq.dead_lettered",
    ].join("&"),
  );
  const events = eventRows.map((row) =>
    parseRevenueCatWebhook(row.raw_event as Record<string, unknown>, projectID)
  );
  const productID = trigger.productId || trigger.entitlementIds[0] ||
    "ddump_pro";
  const canonical = recomputeRevenueCatEntitlement(
    accountID,
    productID,
    events,
    Date.now(),
    config.entitlementPolicy.graceSeconds * 1000,
  );
  await supabase.upsert("ddump_canonical_entitlement_state", {
    account_id: canonical.accountId,
    environment: canonical.environment,
    product_id: canonical.productId,
    status: canonical.status,
    source_provider: "revenuecat",
    revenuecat_app_user_id: canonical.revenuecatAppUserId,
    starts_at: canonical.startsAt,
    paid_through_at: canonical.paidThroughAt,
    expires_at: canonical.expiresAt,
    grace_expires_at: canonical.graceExpiresAt,
    recomputed_at: canonical.recomputedAt,
    details: canonical.details,
  }, "account_id,environment,product_id");
  return canonical;
}
