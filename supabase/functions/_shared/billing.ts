import { Environment } from "./types.ts";

export interface BillingPackage {
  packageId: string;
  productId: string;
  displayName: string;
  displayAmount: string;
  cadence: "monthly" | "annual";
  trialDisclosure: string;
  renewalDisclosure: string;
  taxDisclosure: string;
  cancellationDisclosure: string;
  purchaseLinkToken: string;
}

export interface BillingCatalog {
  schemaVersion: 1;
  environment: Environment;
  offeringId: string;
  variantId: string;
  experimentId?: string;
  packages: BillingPackage[];
  customerPortalUrl?: string;
}

export interface PublicBillingCatalog {
  schema_version: 1;
  environment: Environment;
  offering_id: string;
  variant_id: string;
  experiment_id?: string;
  packages: Array<{
    package_id: string;
    product_id: string;
    display_name: string;
    display_amount: string;
    cadence: "monthly" | "annual";
    trial_disclosure: string;
    renewal_disclosure: string;
    tax_disclosure: string;
    cancellation_disclosure: string;
  }>;
  restore_available: true;
  customer_portal_available: boolean;
}

export function parseBillingCatalog(
  raw: string | undefined,
  environment: Environment,
): BillingCatalog | undefined {
  if (!raw) return undefined;
  const value = JSON.parse(raw) as Record<string, unknown>;
  if (Number(value.schema_version) !== 1) {
    throw new Error("unsupported_billing_catalog_schema");
  }
  if (value.environment !== environment) {
    throw new Error("billing_catalog_environment_mismatch");
  }
  const offeringId = requiredString(value.offering_id, "offering_id");
  const variantId = requiredString(value.variant_id, "variant_id");
  const rows = Array.isArray(value.packages) ? value.packages : [];
  if (rows.length !== 2) {
    throw new Error("billing_catalog_requires_monthly_and_annual");
  }
  const packages = rows.map((row) =>
    parsePackage(row as Record<string, unknown>, environment)
  );
  const cadences = new Set(packages.map((item) => item.cadence));
  if (!cadences.has("monthly") || !cadences.has("annual")) {
    throw new Error("billing_catalog_requires_monthly_and_annual");
  }
  const productIds = new Set(packages.map((item) => item.productId));
  if (productIds.size !== packages.length) {
    throw new Error("billing_catalog_duplicate_product");
  }
  const portal = optionalString(value.customer_portal_url);
  if (portal) requireHttps(portal, "customer_portal_url");
  return {
    schemaVersion: 1,
    environment,
    offeringId,
    variantId,
    experimentId: optionalString(value.experiment_id),
    packages,
    customerPortalUrl: portal,
  };
}

export function parseBillingCatalogs(
  raw: string | undefined,
  environment: Environment,
): BillingCatalog[] {
  if (!raw) return [];
  const values = JSON.parse(raw) as unknown;
  if (!Array.isArray(values)) {
    throw new Error("billing_lab_catalogs_must_be_array");
  }
  return values.map((value) =>
    parseBillingCatalog(JSON.stringify(value), environment)!
  );
}

export function publicBillingCatalog(
  catalog: BillingCatalog,
): PublicBillingCatalog {
  return {
    schema_version: 1,
    environment: catalog.environment,
    offering_id: catalog.offeringId,
    variant_id: catalog.variantId,
    experiment_id: catalog.experimentId,
    packages: catalog.packages.map((item) => ({
      package_id: item.packageId,
      product_id: item.productId,
      display_name: item.displayName,
      display_amount: item.displayAmount,
      cadence: item.cadence,
      trial_disclosure: item.trialDisclosure,
      renewal_disclosure: item.renewalDisclosure,
      tax_disclosure: item.taxDisclosure,
      cancellation_disclosure: item.cancellationDisclosure,
    })),
    restore_available: true,
    customer_portal_available: Boolean(catalog.customerPortalUrl),
  };
}

export function purchaseLink(
  catalog: BillingCatalog,
  packageId: string,
  appUserId: string,
): URL {
  const item = catalog.packages.find((candidate) =>
    candidate.packageId === packageId
  );
  if (!item) throw new Error("package_not_approved");
  return new URL(
    `https://pay.rev.cat/${encodeURIComponent(item.purchaseLinkToken)}/${
      encodeURIComponent(appUserId)
    }`,
  );
}

export function customerPortalLink(
  catalog: BillingCatalog,
  appUserId: string,
): URL {
  if (!catalog.customerPortalUrl) {
    throw new Error("customer_portal_not_configured");
  }
  const expanded = catalog.customerPortalUrl.replaceAll(
    "{app_user_id}",
    encodeURIComponent(appUserId),
  );
  const url = new URL(expanded);
  if (url.protocol !== "https:") {
    throw new Error("customer_portal_url_must_be_https");
  }
  return url;
}

function parsePackage(
  row: Record<string, unknown>,
  environment: Environment,
): BillingPackage {
  const cadence = requiredString(row.cadence, "cadence");
  if (cadence !== "monthly" && cadence !== "annual") {
    throw new Error("weekly_or_unsupported_cadence_rejected");
  }
  const productId = requiredString(row.product_id, "product_id");
  if (
    environment === "test" &&
    !["ddump_test_monthly", "ddump_test_annual"].includes(productId)
  ) {
    throw new Error("unapproved_test_product");
  }
  return {
    packageId: requiredString(row.package_id, "package_id"),
    productId,
    displayName: requiredString(row.display_name, "display_name"),
    displayAmount: requiredString(row.display_amount, "display_amount"),
    cadence,
    trialDisclosure: requiredString(row.trial_disclosure, "trial_disclosure"),
    renewalDisclosure: requiredString(
      row.renewal_disclosure,
      "renewal_disclosure",
    ),
    taxDisclosure: requiredString(row.tax_disclosure, "tax_disclosure"),
    cancellationDisclosure: requiredString(
      row.cancellation_disclosure,
      "cancellation_disclosure",
    ),
    purchaseLinkToken: validateToken(
      requiredString(row.purchase_link_token, "purchase_link_token"),
    ),
  };
}

function validateToken(value: string): string {
  if (!/^[A-Za-z0-9_-]{6,200}$/.test(value)) {
    throw new Error("invalid_purchase_link_token");
  }
  return value;
}

function requiredString(value: unknown, name: string): string {
  const result = String(value || "").trim();
  if (!result) throw new Error(`${name}_missing`);
  return result;
}

function optionalString(value: unknown): string | undefined {
  const result = String(value || "").trim();
  return result || undefined;
}

function requireHttps(value: string, name: string): void {
  const url = new URL(value.replaceAll("{app_user_id}", "test-user"));
  if (url.protocol !== "https:") throw new Error(`${name}_must_be_https`);
}
