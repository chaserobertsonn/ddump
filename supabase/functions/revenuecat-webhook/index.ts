import { readConfig } from "../_shared/config.ts";
import { sha256Hex } from "../_shared/crypto.ts";
import { recomputeRevenueCatEntitlement } from "../_shared/entitlement_state.ts";
import {
  badRequest,
  jsonResponse,
  methodNotAllowed,
  unauthorized,
} from "../_shared/http.ts";
import { parseRevenueCatWebhook } from "../_shared/revenuecat.ts";
import { SupabaseRestClient } from "../_shared/supabase_rest.ts";
import {
  verifyRevenueCatAuthorization,
  verifyRevenueCatSignature,
} from "../_shared/webhook_auth.ts";

Deno.serve(async (request) => {
  if (request.method !== "POST") return methodNotAllowed();
  const config = readConfig();
  const rawBody = await request.text();
  const auth = config.revenueCatHmacSecret
    ? await verifyRevenueCatSignature(
      rawBody,
      request.headers.get("x-revenuecat-webhook-signature"),
      config.revenueCatHmacSecret,
    )
    : verifyRevenueCatAuthorization(
      request.headers,
      config.revenueCatAuthorization,
    );
  if (!auth.ok) return unauthorized(auth.reason || "unauthorized");
  let payload: Record<string, unknown>;
  try {
    payload = JSON.parse(rawBody) as Record<string, unknown>;
  } catch {
    return badRequest("invalid_json");
  }

  let event;
  try {
    event = parseRevenueCatWebhook(payload, config.revenueCatProjectId);
  } catch (error) {
    return badRequest(
      error instanceof Error ? error.message : "invalid_revenuecat_event",
    );
  }
  if (event.environment !== config.environment) {
    return badRequest("environment_mismatch");
  }

  const bodySha256 = await sha256Hex(rawBody);
  const supabase = new SupabaseRestClient({
    url: config.supabaseUrl,
    serviceRoleKey: config.supabaseServiceRoleKey,
  });

  const existing = await supabase.select(
    "ddump_provider_event_inbox",
    [
      "select=id,body_sha256,status,attempts",
      "provider=eq.revenuecat",
      `environment=eq.${event.environment}`,
      `provider_project_id=eq.${encodeURIComponent(event.projectId)}`,
      `provider_event_id=eq.${encodeURIComponent(event.eventId)}`,
      "limit=1",
    ].join("&"),
  );
  const existingRow = existing[0];
  const priorAttempts = Number(existingRow?.attempts || 0);
  if (existingRow && existingRow.body_sha256 !== bodySha256) {
    await supabase.insert("ddump_dead_letter_queue", {
      provider_event_id: existingRow.id,
      environment: event.environment,
      reason: "same_provider_event_id_different_body",
      payload,
    });
    return jsonResponse({
      ok: true,
      provider: "revenuecat",
      event_id: event.eventId,
      dead_lettered: true,
      reason: "same_provider_event_id_different_body",
    });
  }
  if (
    existingRow &&
    ["processed", "replayed"].includes(String(existingRow.status))
  ) {
    return jsonResponse({
      ok: true,
      provider: "revenuecat",
      event_id: event.eventId,
      duplicate: true,
    });
  }

  const mappingRows = await supabase.select(
    "ddump_provider_mappings",
    [
      "select=account_id",
      `environment=eq.${event.environment}`,
      "provider=eq.revenuecat",
      `provider_project_id=eq.${encodeURIComponent(event.projectId)}`,
      `provider_account_id=eq.${encodeURIComponent(event.appUserId)}`,
      "is_active=eq.true",
      "order=created_at.desc",
      "limit=1",
    ].join("&"),
  );
  const accountId = mappingRows[0]?.account_id
    ? String(mappingRows[0].account_id)
    : undefined;

  const response = await supabase.insert("ddump_provider_event_inbox", {
    provider: "revenuecat",
    environment: event.environment,
    provider_project_id: event.projectId,
    provider_event_id: event.eventId,
    livemode: event.environment === "production",
    body_sha256: bodySha256,
    effective_at: new Date(event.effectiveAtMs).toISOString(),
    account_id: accountId,
    provider_account_id: event.appUserId,
    event_type: event.type,
    raw_event: payload,
    redacted_headers: {
      "user-agent": request.headers.get("user-agent") || undefined,
    },
    status: "received",
  });

  if (!response.ok && response.status !== 409) {
    return jsonResponse({ ok: false, error: "event_persist_failed" }, {
      status: 500,
    });
  }
  await supabase.update(
    "ddump_provider_event_inbox",
    [
      "provider=eq.revenuecat",
      `environment=eq.${event.environment}`,
      `provider_project_id=eq.${encodeURIComponent(event.projectId)}`,
      `provider_event_id=eq.${encodeURIComponent(event.eventId)}`,
    ].join("&"),
    {
      attempts: priorAttempts + 1,
      status: "received",
    },
  );

  if (!accountId) {
    await supabase.insert("ddump_reconciliation_runs", {
      environment: event.environment,
      provider: "revenuecat",
      provider_account_id: event.appUserId,
      requested_by: "system",
      status: "open",
      divergence_summary: "missing_revenuecat_provider_mapping",
    });
    await markProcessed(supabase, event, "processed");
    return jsonResponse({
      ok: true,
      provider: "revenuecat",
      event_id: event.eventId,
      reconciliation_required: true,
    });
  }

  const productId = event.productId || event.entitlementIds[0] || "ddump_pro";
  const eventRows = await supabase.select(
    "ddump_provider_event_inbox",
    [
      "select=raw_event",
      "provider=eq.revenuecat",
      `environment=eq.${event.environment}`,
      `provider_project_id=eq.${encodeURIComponent(event.projectId)}`,
      `provider_account_id=eq.${encodeURIComponent(event.appUserId)}`,
      "status=neq.dead_lettered",
    ].join("&"),
  );
  const events = eventRows.map((row) =>
    parseRevenueCatWebhook(
      row.raw_event as Record<string, unknown>,
      event.projectId,
    )
  );
  const canonical = recomputeRevenueCatEntitlement(
    accountId,
    productId,
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
  await markProcessed(supabase, event, "processed");

  return jsonResponse({
    ok: true,
    provider: "revenuecat",
    event_id: event.eventId,
    canonical_status: canonical.status,
  });
});

async function markProcessed(
  supabase: SupabaseRestClient,
  event: { environment: string; projectId: string; eventId: string },
  status: "processed" | "replayed",
): Promise<void> {
  await supabase.update(
    "ddump_provider_event_inbox",
    [
      "provider=eq.revenuecat",
      `environment=eq.${event.environment}`,
      `provider_project_id=eq.${encodeURIComponent(event.projectId)}`,
      `provider_event_id=eq.${encodeURIComponent(event.eventId)}`,
    ].join("&"),
    { status, processed_at: new Date().toISOString() },
  );
}
