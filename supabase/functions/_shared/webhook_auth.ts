import { constantTimeEqual, hmacSha256Hex } from "./crypto.ts";
import { WebhookVerificationResult } from "./types.ts";

export function verifyRevenueCatAuthorization(
  headers: Headers,
  expectedAuthorization: string,
): WebhookVerificationResult {
  if (!expectedAuthorization) {
    return { ok: false, reason: "revenuecat_auth_not_configured" };
  }
  const actual = headers.get("authorization") || "";
  if (!constantTimeEqual(actual, expectedAuthorization)) {
    return { ok: false, reason: "invalid_revenuecat_authorization" };
  }
  return { ok: true };
}

export async function verifyRevenueCatSignature(
  rawBody: string,
  signatureHeader: string | null,
  secret: string | undefined,
  nowSeconds = Math.floor(Date.now() / 1000),
  toleranceSeconds = 300,
): Promise<WebhookVerificationResult> {
  if (!secret) return { ok: false, reason: "revenuecat_hmac_not_configured" };
  if (!signatureHeader) {
    return { ok: false, reason: "missing_revenuecat_signature" };
  }
  const values = new Map<string, string[]>();
  for (const item of signatureHeader.split(",")) {
    const [key, value] = item.split("=", 2);
    if (!key || !value) continue;
    values.set(key, [...(values.get(key) || []), value]);
  }
  const timestamp = Number.parseInt(values.get("t")?.[0] || "", 10);
  const signatures = values.get("v1") || [];
  if (!Number.isFinite(timestamp) || signatures.length === 0) {
    return { ok: false, reason: "malformed_revenuecat_signature" };
  }
  if (Math.abs(nowSeconds - timestamp) > toleranceSeconds) {
    return { ok: false, reason: "stale_revenuecat_signature" };
  }
  const expected = await hmacSha256Hex(secret, `${timestamp}.${rawBody}`);
  if (!signatures.some((signature) => constantTimeEqual(signature, expected))) {
    return { ok: false, reason: "invalid_revenuecat_signature" };
  }
  return { ok: true };
}

export async function verifyStripeSignature(
  rawBody: string,
  signatureHeader: string | null,
  secret: string | undefined,
  nowSeconds = Math.floor(Date.now() / 1000),
  toleranceSeconds = 300,
): Promise<WebhookVerificationResult> {
  if (!secret) return { ok: false, reason: "stripe_secret_not_configured" };
  if (!signatureHeader) {
    return { ok: false, reason: "missing_stripe_signature" };
  }

  const parts = new Map<string, string[]>();
  for (const part of signatureHeader.split(",")) {
    const [key, value] = part.split("=", 2);
    if (!key || !value) continue;
    const values = parts.get(key) || [];
    values.push(value);
    parts.set(key, values);
  }

  const timestamp = Number.parseInt(parts.get("t")?.[0] || "", 10);
  const signatures = parts.get("v1") || [];
  if (!Number.isFinite(timestamp) || signatures.length === 0) {
    return { ok: false, reason: "malformed_stripe_signature" };
  }
  if (Math.abs(nowSeconds - timestamp) > toleranceSeconds) {
    return { ok: false, reason: "stale_stripe_signature" };
  }

  const signedPayload = `${timestamp}.${rawBody}`;
  const expected = await hmacSha256Hex(secret, signedPayload);
  if (!signatures.some((signature) => constantTimeEqual(signature, expected))) {
    return { ok: false, reason: "invalid_stripe_signature" };
  }
  return { ok: true };
}
