import { RevenueCatEvent } from "./types.ts";

export function parseRevenueCatWebhook(
  payload: Record<string, unknown>,
  projectId: string,
): RevenueCatEvent {
  const event =
    (payload.event && typeof payload.event === "object"
      ? payload.event
      : payload) as Record<
        string,
        unknown
      >;
  const aliases = (event.aliases as string[] | undefined) || [];
  const entitlementIds = normalizeStringArray(
    event.entitlement_ids ?? event.entitlementIds ?? event.entitlement_id,
  );
  const eventId = stringValue(event.id ?? event.event_id ?? payload.id);
  const appUserId = stringValue(
    event.app_user_id ?? event.appUserId ?? aliases[0],
  );
  const type = stringValue(event.type ?? event.event_type);

  if (!eventId) throw new Error("revenuecat_event_id_missing");
  if (!appUserId) throw new Error("revenuecat_app_user_id_missing");
  if (!type) throw new Error("revenuecat_event_type_missing");

  const environment = normalizeEnvironment(
    event.environment ?? payload.environment,
  );
  return {
    provider: "revenuecat",
    environment,
    projectId,
    eventId,
    appUserId,
    type,
    productId: optionalString(event.product_id ?? event.productId),
    entitlementIds,
    transactionId: optionalString(event.transaction_id ?? event.transactionId),
    originalTransactionId: optionalString(
      event.original_transaction_id ?? event.originalTransactionId,
    ),
    effectiveAtMs: numberValue(
      event.event_timestamp_ms ?? event.timestamp_ms ?? event.purchased_at_ms ??
        Date.now(),
    ),
    purchasedAtMs: optionalNumber(event.purchased_at_ms ?? event.purchasedAtMs),
    expirationAtMs: optionalNumber(
      event.expiration_at_ms ?? event.expirationAtMs,
    ),
    cancellationAtMs: optionalNumber(
      event.cancellation_at_ms ?? event.cancellationAtMs,
    ),
    periodType: optionalString(event.period_type ?? event.periodType),
    raw: payload,
  };
}

function normalizeEnvironment(value: unknown): "test" | "production" {
  const normalized = String(value || "TEST").toUpperCase();
  return normalized === "PRODUCTION" ? "production" : "test";
}

function normalizeStringArray(value: unknown): string[] {
  if (Array.isArray(value)) return value.map(String).filter(Boolean);
  if (typeof value === "string" && value) return [value];
  return [];
}

function optionalString(value: unknown): string | undefined {
  const string = String(value ?? "");
  return string ? string : undefined;
}

function stringValue(value: unknown): string {
  return optionalString(value) || "";
}

function optionalNumber(value: unknown): number | undefined {
  if (value === null || value === undefined || value === "") return undefined;
  const number = Number(value);
  return Number.isFinite(number) ? number : undefined;
}

function numberValue(value: unknown): number {
  return optionalNumber(value) ?? Date.now();
}
