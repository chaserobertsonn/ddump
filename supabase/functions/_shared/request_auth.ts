import { sha256Hex } from "./crypto.ts";
import { base64UrlDecode, fromUtf8 } from "./encoding.ts";
import { RuntimeConfig } from "./config.ts";
import { SupabaseRestClient } from "./supabase_rest.ts";

export function gatewayVerifiedSubject(request: Request): string | undefined {
  const authorization = request.headers.get("authorization") || "";
  if (!authorization.startsWith("Bearer ")) return undefined;
  const token = authorization.slice("Bearer ".length);
  const parts = token.split(".");
  if (parts.length !== 3) return undefined;
  try {
    const payload = JSON.parse(fromUtf8(base64UrlDecode(parts[1]))) as Record<
      string,
      unknown
    >;
    const subject = String(payload.sub || "");
    const expiresAt = Number(payload.exp || 0);
    if (
      !subject || !Number.isFinite(expiresAt) ||
      expiresAt <= Math.floor(Date.now() / 1000)
    ) {
      return undefined;
    }
    return subject;
  } catch {
    return undefined;
  }
}

export async function resolveAuthenticatedAccount(
  request: Request,
  supabase: SupabaseRestClient,
  config: RuntimeConfig,
): Promise<string | undefined> {
  // Supabase's Edge gateway verifies the JWT because these routes declare
  // verify_jwt=true. We decode only the already-verified subject here and bind
  // all body identifiers to its immutable provider mapping.
  const subject = gatewayVerifiedSubject(request);
  if (!subject) return undefined;
  const existing = await findMapping(supabase, config, subject);
  if (existing) return existing;

  await supabase.insert("ddump_accounts", {
    environment: config.environment,
    stable_account_key: subject,
    auth_subject_hash: await sha256Hex(subject),
  });
  const accountRows = await supabase.select(
    "ddump_accounts",
    [
      "select=id",
      `environment=eq.${config.environment}`,
      `stable_account_key=eq.${encodeURIComponent(subject)}`,
      "limit=1",
    ].join("&"),
  );
  const accountId = accountRows[0]?.id ? String(accountRows[0].id) : undefined;
  if (!accountId) return undefined;

  await supabase.insert("ddump_provider_mappings", {
    account_id: accountId,
    environment: config.environment,
    provider: "auth",
    provider_project_id: config.supabaseProjectId,
    provider_account_id: subject,
    created_by: "verified_supabase_jwt",
  });
  await supabase.insert("ddump_provider_mappings", {
    account_id: accountId,
    environment: config.environment,
    provider: "revenuecat",
    provider_project_id: config.revenueCatProjectId,
    provider_account_id: accountId,
    created_by: "stable_account_bootstrap",
  });
  return accountId;
}

async function findMapping(
  supabase: SupabaseRestClient,
  config: RuntimeConfig,
  subject: string,
): Promise<string | undefined> {
  const mappings = await supabase.select(
    "ddump_provider_mappings",
    [
      "select=account_id",
      `environment=eq.${config.environment}`,
      "provider=eq.auth",
      `provider_project_id=eq.${encodeURIComponent(config.supabaseProjectId)}`,
      `provider_account_id=eq.${encodeURIComponent(subject)}`,
      "is_active=eq.true",
      "limit=1",
    ].join("&"),
  );
  return mappings[0]?.account_id ? String(mappings[0].account_id) : undefined;
}
