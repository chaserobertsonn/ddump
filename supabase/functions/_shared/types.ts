export type Environment = "test" | "production";

export type EntitlementStatus =
  | "unknown"
  | "pending"
  | "trialing"
  | "active"
  | "past_due"
  | "canceled"
  | "expired"
  | "refunded"
  | "disputed"
  | "chargeback"
  | "revoked"
  | "support_hold"
  | "indeterminate";

export type Provider = "revenuecat" | "stripe";

export interface RevenueCatEvent {
  provider: "revenuecat";
  environment: Environment;
  projectId: string;
  eventId: string;
  appUserId: string;
  type: string;
  productId?: string;
  entitlementIds: string[];
  transactionId?: string;
  originalTransactionId?: string;
  effectiveAtMs: number;
  purchasedAtMs?: number;
  expirationAtMs?: number;
  cancellationAtMs?: number;
  periodType?: string;
  raw: Record<string, unknown>;
}

export interface CanonicalEntitlementState {
  accountId: string;
  environment: Environment;
  productId: string;
  status: EntitlementStatus;
  revenuecatAppUserId: string;
  startsAt?: string;
  paidThroughAt?: string;
  expiresAt?: string;
  graceExpiresAt?: string;
  sourceEventId?: string;
  recomputedAt: string;
  details: Record<string, unknown>;
}

export interface InstallationBinding {
  installationId: string;
  installationPublicKeySha256: string;
  deviceFingerprintHash?: string;
  revocationEpochMs?: number;
}

export interface EntitlementPolicy {
  issuer: string;
  audience: string;
  schema: "ddump.entitlement.v1";
  environment: Environment;
  keyId: string;
  refreshSeconds: number;
  graceSeconds: number;
  maxAuthorizedDevices: number;
}

export interface EntitlementDocumentPayload {
  schema: "ddump.entitlement.v1";
  iss: string;
  aud: string;
  kid: string;
  jti: string;
  environment: Environment;
  account_id: string;
  product_id: string;
  entitlement_id: string;
  status: EntitlementStatus;
  iat: number;
  nbf: number;
  refresh_at: number;
  grace_expires_at: number;
  exp: number;
  installation_id: string;
  installation_public_key_sha256: string;
  device_fingerprint_hash?: string;
  device_policy: {
    max_authorized_devices: number;
  };
  account_revocation_epoch?: number;
  installation_revocation_epoch?: number;
}

export interface VerificationContext {
  issuer: string;
  audience: string;
  environment: Environment;
  nowMs: number;
  expectedAccountId: string;
  expectedProductId: string;
  expectedInstallation: InstallationBinding;
  allowedPublicKeysByKid: Record<string, CryptoKey>;
  accountRevocationEpochMs?: number;
  replayCache?: ReplayCache;
  requireUsableNow?: boolean;
}

export interface ReplayCache {
  seen(tokenId: string): Promise<boolean> | boolean;
  remember(tokenId: string, expiresAtMs: number): Promise<void> | void;
}

export interface WebhookVerificationResult {
  ok: boolean;
  reason?: string;
}
