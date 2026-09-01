import { readConfig } from "../_shared/config.ts";
import {
  createCheckoutHandoff,
  redeemCheckoutHandoff,
} from "../_shared/handoff.ts";
import {
  badRequest,
  forbidden,
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
      "browser-handoff",
      accountId,
      30,
      60,
    )
  ) return tooManyRequests();
  if (body.account_id && String(body.account_id) !== accountId) {
    return forbidden("account_body_mismatch");
  }

  const action = String(body.action || "create");
  if (action === "create") {
    const installationId = required(body.installation_id, "installation_id");
    if (
      !await installationAuthorized(
        supabase,
        config.environment,
        accountId,
        installationId,
      )
    ) {
      return forbidden("installation_not_authorized_for_account");
    }
    const handoff = await createCheckoutHandoff({
      accountId,
      installationId,
      offeringId: required(body.offering_id, "offering_id"),
      pkceChallenge: required(body.pkce_challenge, "pkce_challenge"),
      returnOrigin: config.returnOrigin,
      stateNonce: required(body.state_nonce, "state_nonce"),
      ttlMs: 10 * 60 * 1000,
    });
    const response = await supabase.insert("ddump_checkout_handoffs", {
      id: handoff.id,
      environment: config.environment,
      account_id: handoff.accountId,
      installation_id: handoff.installationId,
      offering_id: handoff.offeringId,
      state_nonce_sha256: handoff.stateNonceSha256,
      pkce_challenge: handoff.pkceChallenge,
      return_origin: handoff.returnOrigin,
      expires_at: new Date(handoff.expiresAtMs).toISOString(),
    });
    if (!response.ok) {
      return jsonResponse({ ok: false, error: "handoff_persist_failed" }, {
        status: 500,
      });
    }
    return jsonResponse({
      ok: true,
      handoff_id: handoff.id,
      expires_at: new Date(handoff.expiresAtMs).toISOString(),
    });
  }

  if (action === "redeem") {
    const handoffId = required(body.handoff_id, "handoff_id");
    const existingRows = await supabase.select(
      "ddump_checkout_handoffs",
      [
        "select=id,account_id,installation_id,offering_id,state_nonce_sha256,pkce_challenge,return_origin,expires_at,consumed_at",
        `id=eq.${encodeURIComponent(handoffId)}`,
        `account_id=eq.${accountId}`,
        `environment=eq.${config.environment}`,
        "limit=1",
      ].join("&"),
    );
    const existing = existingRows[0];
    if (!existing) return badRequest("handoff_missing");
    const installationId = required(body.installation_id, "installation_id");
    if (
      !await installationAuthorized(
        supabase,
        config.environment,
        accountId,
        installationId,
      )
    ) {
      return forbidden("installation_not_authorized_for_account");
    }
    const result = await redeemCheckoutHandoff({
      id: required(existing.id, "handoff.id"),
      accountId: required(existing.account_id, "handoff.account_id"),
      installationId: required(
        existing.installation_id,
        "handoff.installation_id",
      ),
      offeringId: required(existing.offering_id, "handoff.offering_id"),
      stateNonceSha256: required(
        existing.state_nonce_sha256,
        "handoff.state_nonce_sha256",
      ),
      pkceChallenge: required(
        existing.pkce_challenge,
        "handoff.pkce_challenge",
      ),
      returnOrigin: required(existing.return_origin, "handoff.return_origin"),
      expiresAtMs: Date.parse(
        required(existing.expires_at, "handoff.expires_at"),
      ),
      consumedAtMs: existing.consumed_at
        ? Date.parse(String(existing.consumed_at))
        : undefined,
    }, {
      accountId,
      installationId,
      offeringId: required(body.offering_id, "offering_id"),
      stateNonce: required(body.state_nonce, "state_nonce"),
    });
    if (!result.ok) return badRequest(result.reason);
    const updated = await supabase.update(
      "ddump_checkout_handoffs",
      `id=eq.${encodeURIComponent(handoffId)}&consumed_at=is.null`,
      {
        consumed_at: new Date(result.handoff.consumedAtMs!).toISOString(),
        consumed_by_installation_id: installationId,
      },
    );
    if (!updated.ok) {
      return jsonResponse({ ok: false, error: "handoff_consume_failed" }, {
        status: 409,
      });
    }
    return jsonResponse({
      ok: true,
      consumed_at: new Date(result.handoff.consumedAtMs!).toISOString(),
    });
  }

  return badRequest("unknown_action");
});

function required(value: unknown, name: string): string {
  const string = String(value || "");
  if (!string) throw new Error(`${name}_missing`);
  return string;
}

async function installationAuthorized(
  supabase: SupabaseRestClient,
  environment: string,
  accountId: string,
  installationId: string,
): Promise<boolean> {
  const rows = await supabase.select(
    "ddump_installations",
    [
      "select=id",
      `id=eq.${encodeURIComponent(installationId)}`,
      `account_id=eq.${accountId}`,
      `environment=eq.${environment}`,
      "authorization_status=eq.authorized",
      "limit=1",
    ].join("&"),
  );
  return Boolean(rows[0]);
}
