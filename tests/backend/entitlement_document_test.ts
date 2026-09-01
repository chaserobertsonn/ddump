import { assert, assertEquals } from "./asserts.ts";
import {
  importEd25519PrivateKeyPkcs8,
  importEd25519PublicKeySpki,
} from "../../supabase/functions/_shared/crypto.ts";
import {
  issueEntitlementDocument,
  verifyEntitlementDocument,
} from "../../supabase/functions/_shared/entitlement_document.ts";
import {
  base64UrlDecode,
  base64UrlEncode,
  fromUtf8,
  stableJson,
} from "../../supabase/functions/_shared/encoding.ts";
import {
  CanonicalEntitlementState,
  EntitlementPolicy,
  ReplayCache,
} from "../../supabase/functions/_shared/types.ts";
import {
  TEST_PRIVATE_KEY_PKCS8_B64,
  TEST_PUBLIC_KEY_SPKI_B64,
} from "./fixtures/keys.ts";

const nowMs = Date.parse("2026-09-01T12:00:00Z");
const accountId = "acct_test_123";
const productId = "ddump_pro";
const installation = {
  installationId: "inst_test_123",
  installationPublicKeySha256: "a".repeat(64),
  deviceFingerprintHash: "b".repeat(64),
};
const policy: EntitlementPolicy = {
  issuer: "https://api.ddump.app",
  audience: "com.ddump.app",
  schema: "ddump.entitlement.v1",
  environment: "test",
  keyId: "ddump-test-key-1",
  refreshSeconds: 60,
  graceSeconds: 120,
  maxAuthorizedDevices: 2,
};
const canonical: CanonicalEntitlementState = {
  accountId,
  environment: "test",
  productId,
  status: "active",
  revenuecatAppUserId: accountId,
  recomputedAt: new Date(nowMs).toISOString(),
  details: {},
};

Deno.test("entitlement document signs and verifies with device binding", async () => {
  const privateKey = await importEd25519PrivateKeyPkcs8(
    TEST_PRIVATE_KEY_PKCS8_B64,
  );
  const publicKey = await importEd25519PublicKeySpki(TEST_PUBLIC_KEY_SPKI_B64);
  const issued = await issueEntitlementDocument(
    canonical,
    installation,
    privateKey,
    policy,
    {
      nowMs,
      tokenId: "tok_test_1",
    },
  );
  const verified = await verifyEntitlementDocument(issued.token, {
    issuer: policy.issuer,
    audience: policy.audience,
    environment: "test",
    nowMs: nowMs + 30_000,
    expectedAccountId: accountId,
    expectedProductId: productId,
    expectedInstallation: installation,
    allowedPublicKeysByKid: { "ddump-test-key-1": publicKey },
  });

  assert(verified.ok);
  assertEquals(verified.usable, "fresh");
  assertEquals(verified.payload?.account_id, accountId);
});

Deno.test("entitlement document rejects tampering, wrong device, expiry, and grace overrun", async () => {
  const privateKey = await importEd25519PrivateKeyPkcs8(
    TEST_PRIVATE_KEY_PKCS8_B64,
  );
  const publicKey = await importEd25519PublicKeySpki(TEST_PUBLIC_KEY_SPKI_B64);
  const issued = await issueEntitlementDocument(
    canonical,
    installation,
    privateKey,
    policy,
    {
      nowMs,
      tokenId: "tok_test_2",
    },
  );
  const context = {
    issuer: policy.issuer,
    audience: policy.audience,
    environment: "test" as const,
    expectedAccountId: accountId,
    expectedProductId: productId,
    expectedInstallation: installation,
    allowedPublicKeysByKid: { "ddump-test-key-1": publicKey },
  };

  const parts = issued.token.split(".");
  const payload = JSON.parse(fromUtf8(base64UrlDecode(parts[1]))) as Record<
    string,
    unknown
  >;
  payload.account_id = "acct_tampered";
  const tampered = `${parts[0]}.${base64UrlEncode(stableJson(payload))}.${
    parts[2]
  }`;
  assertEquals(
    (await verifyEntitlementDocument(tampered, { ...context, nowMs })).reason,
    "invalid_signature",
  );
  assertEquals(
    (await verifyEntitlementDocument(issued.token, {
      ...context,
      nowMs,
      expectedInstallation: {
        ...installation,
        installationPublicKeySha256: "c".repeat(64),
      },
    })).reason,
    "device_binding_mismatch",
  );
  assertEquals(
    (await verifyEntitlementDocument(issued.token, {
      ...context,
      nowMs: nowMs + 90_000,
    })).usable,
    "grace",
  );
  assertEquals(
    (await verifyEntitlementDocument(issued.token, {
      ...context,
      nowMs: nowMs + 181_000,
    })).reason,
    "hard_grace_expired",
  );
});

Deno.test("entitlement document rejects replay when a replay cache is supplied", async () => {
  const privateKey = await importEd25519PrivateKeyPkcs8(
    TEST_PRIVATE_KEY_PKCS8_B64,
  );
  const publicKey = await importEd25519PublicKeySpki(TEST_PUBLIC_KEY_SPKI_B64);
  const issued = await issueEntitlementDocument(
    canonical,
    installation,
    privateKey,
    policy,
    {
      nowMs,
      tokenId: "tok_test_replay",
    },
  );
  const seen = new Set<string>();
  const replayCache: ReplayCache = {
    seen(tokenId) {
      return seen.has(tokenId);
    },
    remember(tokenId) {
      seen.add(tokenId);
    },
  };
  const context = {
    issuer: policy.issuer,
    audience: policy.audience,
    environment: "test" as const,
    nowMs,
    expectedAccountId: accountId,
    expectedProductId: productId,
    expectedInstallation: installation,
    allowedPublicKeysByKid: { "ddump-test-key-1": publicKey },
    replayCache,
  };

  assert((await verifyEntitlementDocument(issued.token, context)).ok);
  assertEquals(
    (await verifyEntitlementDocument(issued.token, context)).reason,
    "replay_detected",
  );
});

Deno.test("entitlement hard expiry never exceeds canonical paid grace", async () => {
  const privateKey = await importEd25519PrivateKeyPkcs8(
    TEST_PRIVATE_KEY_PKCS8_B64,
  );
  const canonicalGrace = new Date(nowMs + 90_000).toISOString();
  const issued = await issueEntitlementDocument(
    { ...canonical, graceExpiresAt: canonicalGrace },
    installation,
    privateKey,
    policy,
    { nowMs, tokenId: "tok_test_capped" },
  );
  assertEquals(issued.payload.refresh_at, Math.floor((nowMs + 60_000) / 1000));
  assertEquals(issued.payload.exp, Math.floor((nowMs + 90_000) / 1000));
});
