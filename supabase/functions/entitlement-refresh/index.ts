import { readConfig } from "../_shared/config.ts";
import { importEd25519PrivateKeyPkcs8 } from "../_shared/crypto.ts";
import { issueEntitlementDocument } from "../_shared/entitlement_document.ts";
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
import {
  CanonicalEntitlementState,
  InstallationBinding,
} from "../_shared/types.ts";

Deno.serve(async (request) => {
  if (request.method !== "POST") return methodNotAllowed();
  const config = readConfig();
  const body = await request.json().catch(() => undefined) as
    | Record<string, unknown>
    | undefined;
  if (!body) return badRequest("invalid_json");
  if (!config.entitlementPrivateKeyPkcs8B64) {
    return jsonResponse(
      {
        ok: false,
        result: "indeterminate",
        error: "signing_key_not_configured",
      },
      { status: 503 },
    );
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
      "entitlement-refresh",
      accountId,
      60,
      60,
    )
  ) return tooManyRequests();
  if (body.account_id && String(body.account_id) !== accountId) {
    return forbidden("account_body_mismatch");
  }
  const productId = required(body.product_id, "product_id");
  const billingLabScenario = config.environment === "test"
    ? await activeBillingLabScenario(supabase, accountId, productId)
    : undefined;
  if (billingLabScenario === "provider_outage") {
    return jsonResponse(
      {
        ok: false,
        result: "indeterminate",
        error: "billing_lab_provider_outage",
      },
      { status: 503 },
    );
  }
  if (billingLabScenario === "delayed_webhook") {
    return jsonResponse({
      ok: true,
      result: "indeterminate",
      reason: "billing_lab_delayed_webhook",
    });
  }
  const installationId = required(body.installation_id, "installation_id");
  const installationRows = await supabase.select(
    "ddump_installations",
    [
      "select=id,installation_public_key_sha256,device_fingerprint_hash,revocation_epoch",
      `id=eq.${encodeURIComponent(installationId)}`,
      `account_id=eq.${accountId}`,
      `environment=eq.${config.environment}`,
      "authorization_status=eq.authorized",
      "limit=1",
    ].join("&"),
  );
  const installationRow = installationRows[0];
  if (!installationRow) {
    return forbidden("installation_not_authorized_for_account");
  }
  const installationPublicKeySha256 = String(
    installationRow.installation_public_key_sha256,
  );
  if (
    body.installation_public_key_sha256 &&
    String(body.installation_public_key_sha256) !== installationPublicKeySha256
  ) {
    return forbidden("installation_key_body_mismatch");
  }
  const installation: InstallationBinding = {
    installationId,
    installationPublicKeySha256,
    deviceFingerprintHash: optional(installationRow.device_fingerprint_hash),
    revocationEpochMs: installationRow.revocation_epoch
      ? Date.parse(String(installationRow.revocation_epoch))
      : undefined,
  };
  const rows = await supabase.select(
    "ddump_canonical_entitlement_state",
    [
      `account_id=eq.${encodeURIComponent(accountId)}`,
      `environment=eq.${config.environment}`,
      `product_id=eq.${encodeURIComponent(productId)}`,
      "limit=1",
    ].join("&"),
  );
  const row = rows[0];
  const synthetic = billingLabCanonical(
    billingLabScenario,
    accountId,
    productId,
    config.environment,
  );
  if (!row && !synthetic) {
    return jsonResponse({
      ok: true,
      result: "revoked",
      reason: "canonical_state_missing",
    });
  }

  const canonical = synthetic ?? rowToCanonical(row);
  if (
    !["active", "trialing", "canceled", "past_due"].includes(canonical.status)
  ) {
    return jsonResponse({
      ok: true,
      result: "revoked",
      status: canonical.status,
    });
  }
  const paidThroughMs = canonical.paidThroughAt
    ? Date.parse(canonical.paidThroughAt)
    : Number.NaN;
  if (Number.isFinite(paidThroughMs) && paidThroughMs <= Date.now()) {
    return jsonResponse({
      ok: true,
      result: "revoked",
      status: "expired",
      reason: "paid_through_elapsed",
    });
  }

  const privateKey = await importEd25519PrivateKeyPkcs8(
    config.entitlementPrivateKeyPkcs8B64,
  );
  const accountRows = await supabase.select(
    "ddump_accounts",
    `select=account_revocation_epoch&id=eq.${accountId}&environment=eq.${config.environment}&limit=1`,
  );
  const accountRevocationEpochMs = accountRows[0]?.account_revocation_epoch
    ? Date.parse(String(accountRows[0].account_revocation_epoch))
    : undefined;
  const billingLabNow = billingLabScenario === "offline_grace"
    ? Date.now() - (config.entitlementPolicy.refreshSeconds + 60) * 1000
    : undefined;
  const issued = await issueEntitlementDocument(
    canonical,
    installation,
    privateKey,
    config.entitlementPolicy,
    { accountRevocationEpochMs, nowMs: billingLabNow },
  );
  await supabase.insert("ddump_entitlement_document_issuance", {
    token_id: issued.payload.jti,
    account_id: issued.payload.account_id,
    installation_id: issued.payload.installation_id,
    environment: issued.payload.environment,
    product_id: issued.payload.product_id,
    status: issued.payload.status,
    key_id: issued.payload.kid,
    document_sha256: issued.documentSha256,
    issued_at: new Date(issued.payload.iat * 1000).toISOString(),
    refresh_at: new Date(issued.payload.refresh_at * 1000).toISOString(),
    grace_expires_at: new Date(issued.payload.grace_expires_at * 1000)
      .toISOString(),
    hard_expires_at: new Date(issued.payload.exp * 1000).toISOString(),
    replay_cache_expires_at: new Date(issued.payload.exp * 1000).toISOString(),
  });

  return jsonResponse({
    ok: true,
    result: "valid",
    entitlement_document: issued.token,
  });
});

function rowToCanonical(
  row: Record<string, unknown>,
): CanonicalEntitlementState {
  return {
    accountId: String(row.account_id),
    environment: row.environment === "production" ? "production" : "test",
    productId: String(row.product_id),
    status: String(row.status) as CanonicalEntitlementState["status"],
    revenuecatAppUserId: String(row.revenuecat_app_user_id || ""),
    startsAt: optional(row.starts_at),
    paidThroughAt: optional(row.paid_through_at),
    expiresAt: optional(row.expires_at),
    graceExpiresAt: optional(row.grace_expires_at),
    sourceEventId: optional(row.source_event_id),
    recomputedAt: String(row.recomputed_at || new Date().toISOString()),
    details: (row.details as Record<string, unknown> | undefined) || {},
  };
}

function required(value: unknown, name: string): string {
  const string = String(value || "");
  if (!string) throw new Error(`${name}_missing`);
  return string;
}

function optional(value: unknown): string | undefined {
  const string = String(value || "");
  return string || undefined;
}

async function activeBillingLabScenario(
  supabase: SupabaseRestClient,
  accountId: string,
  productId: string,
): Promise<string | undefined> {
  const rows = await supabase.select(
    "ddump_billing_lab_scenarios",
    [
      "select=scenario",
      `account_id=eq.${encodeURIComponent(accountId)}`,
      "environment=eq.test",
      `product_id=eq.${encodeURIComponent(productId)}`,
      `expires_at=gt.${encodeURIComponent(new Date().toISOString())}`,
      "limit=1",
    ].join("&"),
  );
  return rows[0]?.scenario ? String(rows[0].scenario) : undefined;
}

function billingLabCanonical(
  scenario: string | undefined,
  accountId: string,
  productId: string,
  environment: "test" | "production",
): CanonicalEntitlementState | undefined {
  const statusByScenario: Record<string, CanonicalEntitlementState["status"]> =
    {
      successful_purchase: "active",
      restore: "active",
      failed_renewal: "past_due",
      offline_grace: "active",
      expiry: "expired",
      refund: "refunded",
    };
  const status = scenario ? statusByScenario[scenario] : undefined;
  if (!status) return undefined;
  const now = new Date();
  const paidThrough = new Date(now.getTime() + 30 * 24 * 60 * 60 * 1000);
  return {
    accountId,
    environment,
    productId,
    status,
    revenuecatAppUserId: accountId,
    startsAt: now.toISOString(),
    paidThroughAt: paidThrough.toISOString(),
    expiresAt: paidThrough.toISOString(),
    recomputedAt: now.toISOString(),
    details: { billing_lab_scenario: scenario },
  };
}
