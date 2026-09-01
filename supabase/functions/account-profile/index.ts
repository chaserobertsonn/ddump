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
      "account-profile",
      accountId,
      30,
      60,
    )
  ) return tooManyRequests();
  const body = await request.json().catch(() => ({})) as Record<
    string,
    unknown
  >;
  const action = String(body.action || "read");

  if (action === "read") {
    const accounts = await supabase.select(
      "ddump_accounts",
      `select=beta_updates_eligible&id=eq.${
        encodeURIComponent(accountId)
      }&environment=eq.${config.environment}&limit=1`,
    );
    const mappings = await supabase.select(
      "ddump_provider_mappings",
      `select=provider,provider_account_id&account_id=eq.${
        encodeURIComponent(accountId)
      }&environment=eq.${config.environment}&is_active=eq.true`,
    );
    const mapping = (provider: string) =>
      mappings.find((row) => row.provider === provider)?.provider_account_id as
        | string
        | undefined;
    return jsonResponse({
      ok: true,
      environment: config.environment,
      account_id: accountId,
      revenuecat_app_user_id: mapping("revenuecat") || accountId,
      stripe_customer_id: mapping("stripe"),
      beta_updates_eligible: accounts[0]?.beta_updates_eligible === true,
    });
  }

  if (action === "request_deletion") {
    const response = await supabase.insert("ddump_deletion_requests", {
      environment: config.environment,
      account_id: accountId,
      requested_by: "authenticated_customer",
      deletion_scope: {
        identity: true,
        app_data: true,
        billing_records: "retention_policy",
      },
    });
    if (!response.ok && response.status !== 409) {
      return jsonResponse({ ok: false, error: "deletion_request_failed" }, {
        status: 500,
      });
    }
    await supabase.update(
      "ddump_accounts",
      `id=eq.${
        encodeURIComponent(accountId)
      }&environment=eq.${config.environment}`,
      { deletion_requested_at: new Date().toISOString() },
    );
    return jsonResponse({ ok: true, status: "open" });
  }

  return badRequest("unknown_action");
});
