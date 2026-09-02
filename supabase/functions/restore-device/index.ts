import { readConfig } from "../_shared/config.ts";
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

  const installationPublicKeySha256 = required(
    body.installation_public_key_sha256,
    "installation_public_key_sha256",
  );
  if (!/^[a-f0-9]{64}$/.test(installationPublicKeySha256)) {
    return badRequest("invalid_installation_public_key_sha256");
  }

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
      "restore-device",
      accountId,
      10,
      60,
    )
  ) return tooManyRequests();
  if (body.account_id && String(body.account_id) !== accountId) {
    return forbidden("account_body_mismatch");
  }
  const existing = await supabase.select(
    "ddump_installations",
    [
      "select=id,authorization_status",
      `account_id=eq.${accountId}`,
      `environment=eq.${config.environment}`,
      `installation_public_key_sha256=eq.${installationPublicKeySha256}`,
      "limit=1",
    ].join("&"),
  );
  if (existing[0]?.authorization_status === "authorized") {
    return jsonResponse({
      ok: true,
      installation_id: existing[0].id,
      restored: true,
    });
  }
  const active = await supabase.select(
    "ddump_installations",
    [
      `account_id=eq.${encodeURIComponent(accountId)}`,
      `environment=eq.${config.environment}`,
      "authorization_status=eq.authorized",
      "select=id",
    ].join("&"),
  );
  if (active.length >= config.entitlementPolicy.maxAuthorizedDevices) {
    return jsonResponse({
      ok: false,
      result: "device_limit_reached",
      max_authorized_devices: config.entitlementPolicy.maxAuthorizedDevices,
    }, { status: 409 });
  }

  const installationId = crypto.randomUUID();
  const response = await supabase.insert("ddump_installations", {
    id: installationId,
    account_id: accountId,
    environment: config.environment,
    installation_public_key_sha256: installationPublicKeySha256,
    device_fingerprint_hash: optional(body.device_fingerprint_hash),
    device_label: optional(body.device_label),
    authorization_status: "authorized",
    authorized_at: new Date().toISOString(),
    max_devices_snapshot: config.entitlementPolicy.maxAuthorizedDevices,
  });
  if (!response.ok && response.status !== 409) {
    return jsonResponse({ ok: false, error: "installation_persist_failed" }, {
      status: 500,
    });
  }
  return jsonResponse({ ok: true, installation_id: installationId });
});

function required(value: unknown, name: string): string {
  const string = String(value || "");
  if (!string) throw new Error(`${name}_missing`);
  return string;
}

function optional(value: unknown): string | undefined {
  const string = String(value || "");
  return string || undefined;
}
