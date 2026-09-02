import {
  CanonicalEntitlementState,
  EntitlementStatus,
  RevenueCatEvent,
} from "./types.ts";

const ACTIVE_TYPES = new Set([
  "INITIAL_PURCHASE",
  "RENEWAL",
  "UNCANCELLATION",
  "PRODUCT_CHANGE",
]);
const REFUND_TYPES = new Set(["REFUND", "NON_RENEWING_PURCHASE_REVOKE"]);
const DISPUTE_TYPES = new Set(["DISPUTE", "DISPUTE_OPENED"]);
const CHARGEBACK_TYPES = new Set(["CHARGEBACK"]);

export function recomputeRevenueCatEntitlement(
  accountId: string,
  productId: string,
  events: RevenueCatEvent[],
  nowMs: number,
  graceMs: number,
): CanonicalEntitlementState {
  const trusted = events
    .filter((event) => event.provider === "revenuecat")
    .filter((event) =>
      event.productId === productId || event.entitlementIds.includes(productId)
    )
    .sort((left, right) =>
      left.effectiveAtMs - right.effectiveAtMs ||
      left.eventId.localeCompare(right.eventId)
    );

  if (trusted.length === 0) {
    return state(accountId, "test", productId, "unknown", "", nowMs, {
      reason: "no_trusted_events",
    });
  }

  const environment = trusted[trusted.length - 1].environment;
  const appUserId = trusted[trusted.length - 1].appUserId;
  const terminal = latestOf(
    trusted,
    (event) =>
      CHARGEBACK_TYPES.has(event.type) || DISPUTE_TYPES.has(event.type) ||
      REFUND_TYPES.has(event.type),
  );
  if (terminal) {
    const status = CHARGEBACK_TYPES.has(terminal.type)
      ? "chargeback"
      : DISPUTE_TYPES.has(terminal.type)
      ? "disputed"
      : "refunded";
    return state(accountId, environment, productId, status, appUserId, nowMs, {
      source_event_id: terminal.eventId,
      terminal_type: terminal.type,
    });
  }

  const latestBillingIssue = latestOf(
    trusted,
    (event) => event.type === "BILLING_ISSUE",
  );
  const latestExpiration = latestOf(
    trusted,
    (event) => event.type === "EXPIRATION",
  );
  const latestCancellation = latestOf(
    trusted,
    (event) => event.type === "CANCELLATION",
  );
  const latestActive = latestOf(
    trusted,
    (event) => ACTIVE_TYPES.has(event.type),
  );
  const source = latestOf(trusted, () => true)!;
  const paidThroughMs = maxNumber(trusted.map((event) => event.expirationAtMs));
  const purchasedAtMs = minNumber(trusted.map((event) => event.purchasedAtMs));
  const graceExpiresMs = paidThroughMs ? paidThroughMs + graceMs : undefined;

  let status: EntitlementStatus = "pending";
  if (
    latestBillingIssue &&
    (!paidThroughMs ||
      latestBillingIssue.effectiveAtMs >= (latestActive?.effectiveAtMs ?? 0))
  ) {
    status = paidThroughMs && paidThroughMs > nowMs ? "past_due" : "expired";
  } else if (latestCancellation && paidThroughMs && paidThroughMs > nowMs) {
    status = "canceled";
  } else if (latestActive && paidThroughMs && paidThroughMs > nowMs) {
    status = latestActive.periodType?.toUpperCase() === "TRIAL"
      ? "trialing"
      : "active";
  } else if (latestExpiration || (paidThroughMs && paidThroughMs <= nowMs)) {
    status = "expired";
  }

  return {
    accountId,
    environment,
    productId,
    status,
    revenuecatAppUserId: appUserId,
    startsAt: purchasedAtMs ? new Date(purchasedAtMs).toISOString() : undefined,
    paidThroughAt: paidThroughMs
      ? new Date(paidThroughMs).toISOString()
      : undefined,
    expiresAt: paidThroughMs
      ? new Date(paidThroughMs).toISOString()
      : undefined,
    graceExpiresAt: graceExpiresMs
      ? new Date(graceExpiresMs).toISOString()
      : undefined,
    sourceEventId: source.eventId,
    recomputedAt: new Date(nowMs).toISOString(),
    details: {
      event_count: trusted.length,
      cancellation_at: latestCancellation?.cancellationAtMs
        ? new Date(latestCancellation.cancellationAtMs).toISOString()
        : undefined,
    },
  };
}

export function refreshResultFromState(
  canonical: CanonicalEntitlementState | undefined,
  providerAvailable: boolean,
): "valid" | "revoked" | "indeterminate" {
  if (!providerAvailable) return canonical ? "indeterminate" : "indeterminate";
  if (!canonical) return "revoked";
  if (
    ["active", "trialing", "canceled", "past_due"].includes(canonical.status)
  ) return "valid";
  if (
    canonical.status === "indeterminate" || canonical.status === "pending" ||
    canonical.status === "unknown"
  ) {
    return "indeterminate";
  }
  return "revoked";
}

function state(
  accountId: string,
  environment: "test" | "production",
  productId: string,
  status: EntitlementStatus,
  appUserId: string,
  nowMs: number,
  details: Record<string, unknown>,
): CanonicalEntitlementState {
  return {
    accountId,
    environment,
    productId,
    status,
    revenuecatAppUserId: appUserId,
    recomputedAt: new Date(nowMs).toISOString(),
    details,
  };
}

function latestOf(
  events: RevenueCatEvent[],
  predicate: (event: RevenueCatEvent) => boolean,
) {
  return [...events].reverse().find(predicate);
}

function maxNumber(values: Array<number | undefined>): number | undefined {
  const numbers = values.filter((value): value is number =>
    Number.isFinite(value)
  );
  return numbers.length ? Math.max(...numbers) : undefined;
}

function minNumber(values: Array<number | undefined>): number | undefined {
  const numbers = values.filter((value): value is number =>
    Number.isFinite(value)
  );
  return numbers.length ? Math.min(...numbers) : undefined;
}
