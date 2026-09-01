import CryptoKit
import Foundation

@main
enum BackendEntitlementJWSTests {
  static func main() throws {
    let privateKey = Curve25519.Signing.PrivateKey()
    let now: Int64 = 1_800_000_000
    let claims: [String: Any] = [
      "schema": "ddump.entitlement.v1",
      "iss": "https://api.ddump.app",
      "aud": "com.ddump.app",
      "kid": "test-key",
      "jti": "test-token",
      "environment": "test",
      "account_id": "account-test",
      "product_id": "ddump_test_monthly",
      "entitlement_id": "ddump_pro_test",
      "status": "active",
      "iat": now,
      "nbf": now - 60,
      "refresh_at": now + 600,
      "grace_expires_at": now + 3_600,
      "exp": now + 3_600,
      "installation_id": "install-test",
      "installation_public_key_sha256": String(repeating: "a", count: 64),
      "device_policy": ["max_authorized_devices": 2]
    ]
    let token = try sign(claims: claims, privateKey: privateKey)
    let document = try BackendEntitlementJWSDecoder().decode(
      token,
      expectedIssuer: "https://api.ddump.app",
      expectedEnvironment: "test"
    )
    let keyID = try EntitlementKeyID("test-key")
    let key = try EntitlementVerificationKey(
      keyID: keyID,
      publicKey: privateKey.publicKey.rawRepresentation,
      revokedAt: nil
    )
    let verifier = EntitlementVerifier(
      keyProvider: StaticEntitlementVerificationKeyProvider(keys: [key]),
      signatureVerifier: CryptoKitEntitlementSignatureVerifier(),
      replayProtector: InMemoryEntitlementReplayProtector()
    )
    let context = EntitlementVerificationContext(
      expectedAudience: "com.ddump.app",
      expectedAccountID: try StableAccountID("account-test"),
      expectedProductID: try ProductID("ddump_test_monthly"),
      expectedInstallationID: try InstallationID("install-test"),
      expectedInstallationPublicKeyHash: Data(repeating: 0xaa, count: 32),
      trustedNow: Date(timeIntervalSince1970: TimeInterval(now + 30))
    )
    guard case .valid = verifier.verify(document, context: context) else {
      fputs("FAIL: backend JWS did not verify in the app entitlement verifier\n", stderr)
      exit(1)
    }

    var revokedClaims = claims
    revokedClaims["account_revocation_epoch"] = now + 1
    let revokedToken = try sign(claims: revokedClaims, privateKey: privateKey)
    let revokedDocument = try BackendEntitlementJWSDecoder().decode(
      revokedToken,
      expectedIssuer: "https://api.ddump.app",
      expectedEnvironment: "test"
    )
    guard verifier.verify(revokedDocument, context: context) == .revoked(.staleOrReplayed) else {
      fputs("FAIL: pre-revocation-epoch JWS was not rejected\n", stderr)
      exit(1)
    }

    var tamperedClaims = claims
    tamperedClaims["account_id"] = "tampered"
    let parts = token.split(separator: ".").map(String.init)
    let tamperedPayload = encode(try JSONSerialization.data(withJSONObject: tamperedClaims, options: [.sortedKeys]))
    let tamperedToken = "\(parts[0]).\(tamperedPayload).\(parts[2])"
    let tamperedDocument = try BackendEntitlementJWSDecoder().decode(
      tamperedToken,
      expectedIssuer: "https://api.ddump.app",
      expectedEnvironment: "test"
    )
    guard verifier.verify(tamperedDocument, context: context) == .revoked(.invalidSignature) else {
      fputs("FAIL: tampered JWS claims were not rejected\n", stderr)
      exit(1)
    }
    print("PASS: Supabase entitlement JWS decodes and verifies in Swift")
  }

  private static func sign(
    claims: [String: Any],
    privateKey: Curve25519.Signing.PrivateKey
  ) throws -> String {
    let header = try JSONSerialization.data(
      withJSONObject: ["alg": "EdDSA", "kid": "test-key", "typ": "DDump-Entitlement"],
      options: [.sortedKeys]
    )
    let payload = try JSONSerialization.data(withJSONObject: claims, options: [.sortedKeys])
    let input = "\(encode(header)).\(encode(payload))"
    let signature = try privateKey.signature(for: Data(input.utf8))
    return "\(input).\(encode(signature))"
  }

  private static func encode(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}
