import { asArrayBuffer } from "./crypto.ts";
import {
  base64UrlDecode,
  base64UrlEncode,
  fromUtf8,
  stableJson,
  utf8,
} from "./encoding.ts";
import { sha256Hex } from "./crypto.ts";
import {
  CanonicalEntitlementState,
  EntitlementDocumentPayload,
  EntitlementPolicy,
  InstallationBinding,
  VerificationContext,
} from "./types.ts";

export interface IssuedEntitlementDocument {
  token: string;
  payload: EntitlementDocumentPayload;
  documentSha256: string;
}

export interface EntitlementVerificationResult {
  ok: boolean;
  reason?: string;
  usable?: "fresh" | "grace";
  payload?: EntitlementDocumentPayload;
}

export async function issueEntitlementDocument(
  canonical: CanonicalEntitlementState,
  installation: InstallationBinding,
  privateKey: CryptoKey,
  policy: EntitlementPolicy,
  options: {
    nowMs?: number;
    tokenId?: string;
    accountRevocationEpochMs?: number;
  } = {},
): Promise<IssuedEntitlementDocument> {
  const nowMs = options.nowMs ?? Date.now();
  const issued = Math.floor(nowMs / 1000);
  const policyHardExpiry = issued + policy.refreshSeconds + policy.graceSeconds;
  const canonicalHardExpiryMs = canonical.graceExpiresAt
    ? Date.parse(canonical.graceExpiresAt)
    : Number.NaN;
  const hardExpiresAt = Number.isFinite(canonicalHardExpiryMs)
    ? Math.min(policyHardExpiry, Math.floor(canonicalHardExpiryMs / 1000))
    : policyHardExpiry;
  if (hardExpiresAt <= issued) {
    throw new Error("canonical_entitlement_grace_expired");
  }
  const refreshAt = Math.min(issued + policy.refreshSeconds, hardExpiresAt);
  const graceExpiresAt = hardExpiresAt;
  const payload: EntitlementDocumentPayload = {
    schema: policy.schema,
    iss: policy.issuer,
    aud: policy.audience,
    kid: policy.keyId,
    jti: options.tokenId ?? crypto.randomUUID(),
    environment: policy.environment,
    account_id: canonical.accountId,
    product_id: canonical.productId,
    entitlement_id: `${canonical.productId}:${canonical.status}`,
    status: canonical.status,
    iat: issued,
    nbf: issued - 60,
    refresh_at: refreshAt,
    grace_expires_at: graceExpiresAt,
    exp: hardExpiresAt,
    installation_id: installation.installationId,
    installation_public_key_sha256: installation.installationPublicKeySha256,
    device_fingerprint_hash: installation.deviceFingerprintHash,
    device_policy: {
      max_authorized_devices: policy.maxAuthorizedDevices,
    },
    account_revocation_epoch: options.accountRevocationEpochMs
      ? Math.floor(options.accountRevocationEpochMs / 1000)
      : undefined,
    installation_revocation_epoch: installation.revocationEpochMs
      ? Math.floor(installation.revocationEpochMs / 1000)
      : undefined,
  };
  const header = { alg: "EdDSA", typ: "DDump-Entitlement", kid: policy.keyId };
  const signingInput = `${base64UrlEncode(stableJson(header))}.${
    base64UrlEncode(stableJson(payload))
  }`;
  const signature = new Uint8Array(
    await crypto.subtle.sign(
      "Ed25519",
      privateKey,
      asArrayBuffer(utf8(signingInput)),
    ),
  );
  const token = `${signingInput}.${base64UrlEncode(signature)}`;
  return {
    token,
    payload,
    documentSha256: await sha256Hex(token),
  };
}

export async function verifyEntitlementDocument(
  token: string,
  context: VerificationContext,
): Promise<EntitlementVerificationResult> {
  const parts = token.split(".");
  if (parts.length !== 3) return { ok: false, reason: "malformed_document" };

  let header: Record<string, unknown>;
  let payload: EntitlementDocumentPayload;
  try {
    header = JSON.parse(fromUtf8(base64UrlDecode(parts[0]))) as Record<
      string,
      unknown
    >;
    payload = JSON.parse(
      fromUtf8(base64UrlDecode(parts[1])),
    ) as EntitlementDocumentPayload;
  } catch {
    return { ok: false, reason: "malformed_document_json" };
  }

  if (header.alg !== "EdDSA" || header.typ !== "DDump-Entitlement") {
    return { ok: false, reason: "unsupported_document_header" };
  }
  if (header.kid !== payload.kid) {
    return { ok: false, reason: "key_id_mismatch" };
  }
  const publicKey = context.allowedPublicKeysByKid[String(header.kid)];
  if (!publicKey) return { ok: false, reason: "unknown_key_id" };

  const signingInput = `${parts[0]}.${parts[1]}`;
  const signatureOk = await crypto.subtle.verify(
    "Ed25519",
    publicKey,
    asArrayBuffer(base64UrlDecode(parts[2])),
    asArrayBuffer(utf8(signingInput)),
  );
  if (!signatureOk) return { ok: false, reason: "invalid_signature" };

  if (payload.schema !== "ddump.entitlement.v1") {
    return { ok: false, reason: "schema_mismatch" };
  }
  if (payload.iss !== context.issuer) {
    return { ok: false, reason: "issuer_mismatch" };
  }
  if (payload.aud !== context.audience) {
    return { ok: false, reason: "audience_mismatch" };
  }
  if (payload.environment !== context.environment) {
    return { ok: false, reason: "environment_mismatch" };
  }
  if (payload.account_id !== context.expectedAccountId) {
    return { ok: false, reason: "account_mismatch" };
  }
  if (payload.product_id !== context.expectedProductId) {
    return { ok: false, reason: "product_mismatch" };
  }
  if (payload.installation_id !== context.expectedInstallation.installationId) {
    return { ok: false, reason: "installation_mismatch" };
  }
  if (
    payload.installation_public_key_sha256 !==
      context.expectedInstallation.installationPublicKeySha256
  ) {
    return { ok: false, reason: "device_binding_mismatch" };
  }

  const now = Math.floor(context.nowMs / 1000);
  if (payload.nbf > now) return { ok: false, reason: "not_yet_valid" };
  if (payload.exp <= now) return { ok: false, reason: "hard_grace_expired" };
  if (payload.grace_expires_at <= now) {
    return { ok: false, reason: "grace_expired" };
  }
  if (
    ["refunded", "disputed", "chargeback", "revoked", "expired", "support_hold"]
      .includes(
        payload.status,
      )
  ) {
    return { ok: false, reason: `status_${payload.status}` };
  }

  const accountRevocation = Math.floor(
    (context.accountRevocationEpochMs ?? 0) / 1000,
  );
  if (payload.iat <= accountRevocation) {
    return { ok: false, reason: "account_revocation_epoch" };
  }
  const installationRevocation = Math.floor(
    (context.expectedInstallation.revocationEpochMs ?? 0) / 1000,
  );
  if (payload.iat <= installationRevocation) {
    return { ok: false, reason: "installation_revocation_epoch" };
  }

  if (context.replayCache) {
    if (await context.replayCache.seen(payload.jti)) {
      return { ok: false, reason: "replay_detected" };
    }
    await context.replayCache.remember(payload.jti, payload.exp * 1000);
  }

  if (context.requireUsableNow !== false && payload.refresh_at <= now) {
    return {
      ok: true,
      usable: "grace",
      reason: "refresh_due_within_grace",
      payload,
    };
  }
  return { ok: true, usable: "fresh", payload };
}
