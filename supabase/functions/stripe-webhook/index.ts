import { readConfig } from "../_shared/config.ts";
import { sha256Hex } from "../_shared/crypto.ts";
import {
  badRequest,
  jsonResponse,
  methodNotAllowed,
  unauthorized,
} from "../_shared/http.ts";
import { SupabaseRestClient } from "../_shared/supabase_rest.ts";
import { verifyStripeSignature } from "../_shared/webhook_auth.ts";

Deno.serve(async (request) => {
  if (request.method !== "POST") return methodNotAllowed();
  const config = readConfig();
  const rawBody = await request.text();
  const signature = await verifyStripeSignature(
    rawBody,
    request.headers.get("stripe-signature"),
    config.stripeWebhookSecret,
  );
  if (!signature.ok) {
    return unauthorized(signature.reason || "invalid_stripe_signature");
  }

  let payload: Record<string, unknown>;
  try {
    payload = JSON.parse(rawBody) as Record<string, unknown>;
  } catch {
    return badRequest("invalid_json");
  }

  const livemode = Boolean(payload.livemode);
  if ((config.environment === "production") !== livemode) {
    return badRequest("environment_mismatch");
  }
  if (
    config.stripeAccountId && payload.account &&
    payload.account !== config.stripeAccountId
  ) {
    return badRequest("stripe_account_mismatch");
  }

  const eventId = String(payload.id || "");
  const eventType = String(payload.type || "");
  if (!eventId || !eventType) {
    return badRequest("stripe_event_missing_id_or_type");
  }

  const supabase = new SupabaseRestClient({
    url: config.supabaseUrl,
    serviceRoleKey: config.supabaseServiceRoleKey,
  });
  const response = await supabase.insert("ddump_provider_event_inbox", {
    provider: "stripe",
    environment: config.environment,
    provider_project_id: config.stripeAccountId || "stripe-test",
    provider_event_id: eventId,
    livemode,
    body_sha256: await sha256Hex(rawBody),
    effective_at: payload.created
      ? new Date(Number(payload.created) * 1000).toISOString()
      : undefined,
    provider_account_id: readStripeCustomerId(payload),
    event_type: eventType,
    raw_event: payload,
    redacted_headers: {
      "stripe-signature": "present",
      "user-agent": request.headers.get("user-agent") || undefined,
    },
    status: "ignored",
  });

  if (!response.ok && response.status !== 409) {
    return jsonResponse({ ok: false, error: "event_persist_failed" }, {
      status: 500,
    });
  }

  return jsonResponse({
    ok: true,
    provider: "stripe",
    event_id: eventId,
    authority: "audit_reconcile_only",
  });
});

function readStripeCustomerId(
  payload: Record<string, unknown>,
): string | undefined {
  const data = payload.data as Record<string, unknown> | undefined;
  const object = data?.object as Record<string, unknown> | undefined;
  return object?.customer ? String(object.customer) : undefined;
}
