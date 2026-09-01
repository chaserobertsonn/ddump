import { EntitlementPolicy, Environment } from "./types.ts";
import {
  BillingCatalog,
  parseBillingCatalog,
  parseBillingCatalogs,
} from "./billing.ts";

export interface RuntimeConfig {
  environment: Environment;
  supabaseUrl: string;
  supabaseServiceRoleKey: string;
  supabaseProjectId: string;
  revenueCatAuthorization: string;
  revenueCatHmacSecret?: string;
  revenueCatProjectId: string;
  stripeWebhookSecret?: string;
  stripeAccountId?: string;
  entitlementPrivateKeyPkcs8B64?: string;
  entitlementPublicKeySpkiB64?: string;
  entitlementPolicy: EntitlementPolicy;
  returnOrigin: string;
  billingEnabled: boolean;
  productionBillingApproved: boolean;
  billingCatalog?: BillingCatalog;
  billingLabCatalogs: BillingCatalog[];
  operationsToken?: string;
}

export function readConfig(
  getEnv: (name: string) => string | undefined = Deno.env.get,
): RuntimeConfig {
  const environment = readEnvironment(getEnv("DDUMP_ENVIRONMENT"));
  const issuer = getEnv("DDUMP_ENTITLEMENT_ISSUER") || "https://api.ddump.app";
  const audience = getEnv("DDUMP_ENTITLEMENT_AUDIENCE") || "com.ddump.app";
  const refreshSeconds = readPositiveInt(
    getEnv("DDUMP_REFRESH_SECONDS"),
    24 * 60 * 60,
  );
  const graceSeconds = readPolicyInt(
    "DDUMP_DEFAULT_GRACE_SECONDS",
    getEnv("DDUMP_DEFAULT_GRACE_SECONDS"),
    environment,
    7 * 24 * 60 * 60,
  );
  const maxAuthorizedDevices = readPolicyInt(
    "DDUMP_MAX_AUTHORIZED_DEVICES",
    getEnv("DDUMP_MAX_AUTHORIZED_DEVICES"),
    environment,
    2,
  );
  const billingEnabled = readBoolean(getEnv("DDUMP_BILLING_ENABLED"));
  const productionBillingApproved = readBoolean(
    getEnv("DDUMP_PRODUCTION_BILLING_APPROVED"),
  );
  if (
    environment === "production" && billingEnabled && !productionBillingApproved
  ) {
    throw new Error("production_billing_requires_owner_approval");
  }

  return {
    environment,
    supabaseUrl: getEnv("DDUMP_SUPABASE_URL") || "",
    supabaseServiceRoleKey: getEnv("DDUMP_SUPABASE_SERVICE_ROLE_KEY") || "",
    supabaseProjectId: getEnv("DDUMP_SUPABASE_PROJECT_ID") || "supabase-test",
    revenueCatAuthorization: getEnv("DDUMP_REVENUECAT_WEBHOOK_AUTHORIZATION") ||
      "",
    revenueCatHmacSecret: getEnv("DDUMP_REVENUECAT_WEBHOOK_HMAC_SECRET"),
    revenueCatProjectId: getEnv("DDUMP_REVENUECAT_PROJECT_ID") || "ddump-test",
    stripeWebhookSecret: getEnv("DDUMP_STRIPE_WEBHOOK_SECRET"),
    stripeAccountId: getEnv("DDUMP_STRIPE_ACCOUNT_ID"),
    entitlementPrivateKeyPkcs8B64: getEnv(
      "DDUMP_ENTITLEMENT_PRIVATE_KEY_PKCS8_B64",
    ),
    entitlementPublicKeySpkiB64: getEnv(
      "DDUMP_ENTITLEMENT_PUBLIC_KEY_SPKI_B64",
    ),
    entitlementPolicy: {
      issuer,
      audience,
      schema: "ddump.entitlement.v1",
      environment,
      keyId: getEnv("DDUMP_ENTITLEMENT_KEY_ID") || "ddump-test-key-1",
      refreshSeconds,
      graceSeconds,
      maxAuthorizedDevices,
    },
    returnOrigin: getEnv("DDUMP_HOMEPAGE_RETURN_ORIGIN") || "https://ddump.app",
    billingEnabled,
    productionBillingApproved,
    billingCatalog: parseBillingCatalog(
      getEnv("DDUMP_BILLING_CATALOG_JSON"),
      environment,
    ),
    billingLabCatalogs: parseBillingCatalogs(
      getEnv("DDUMP_BILLING_LAB_CATALOGS_JSON"),
      environment,
    ),
    operationsToken: getEnv("DDUMP_OPERATIONS_TOKEN"),
  };
}

function readBoolean(value: string | undefined): boolean {
  return value === "1" || value === "true";
}

function readEnvironment(value: string | undefined): Environment {
  if (value === "production") return "production";
  return "test";
}

function readPositiveInt(value: string | undefined, fallback: number): number {
  const parsed = Number.parseInt(value || "", 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback;
}

function readPolicyInt(
  name: string,
  value: string | undefined,
  environment: Environment,
  testFallback: number,
): number {
  if (environment === "production") {
    const parsed = Number.parseInt(value || "", 10);
    if (!Number.isFinite(parsed) || parsed <= 0) {
      throw new Error(`${name}_requires_valid_owner_approval`);
    }
    return parsed;
  }
  return readPositiveInt(value, testFallback);
}
