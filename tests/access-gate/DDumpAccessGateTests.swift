import CryptoKit
import Foundation

@main
enum DDumpAccessGateTests {
  private static var failures = 0
  private static let now: Int64 = 1_800_000_000
  private static let installHash = String(repeating: "a", count: 64)

  static func main() throws {
    let privateKey = Curve25519.Signing.PrivateKey()
    let publicKeys = ["test-key": privateKey.publicKey.rawRepresentation]
    let valid = payload(status: "active", issuedAt: now - 60, refreshAt: now + 600, expiresAt: now + 3_600)
    let token = try signedToken(valid, privateKey: privateKey)

    expect(token, context(publicKeys), .allow(refreshRequired: false), "valid backend JWS")
    expect(token, context(publicKeys, accountID: "wrong"), .deny(reason: "wrong_account"), "wrong account")
    expect(token, context(publicKeys, installationID: "wrong"), .deny(reason: "wrong_installation"), "wrong installation")
    expect(token, context(publicKeys, installationHash: String(repeating: "b", count: 64)), .deny(reason: "wrong_installation_key"), "wrong installation key")
    expect(token, context(publicKeys, now: now + 601), .allow(refreshRequired: true), "offline grace")
    expect(token, context(publicKeys, now: now + 3_600), .deny(reason: "offline_grace_expired"), "hard grace expiry")
    expect(token, context(publicKeys, minimumIssuedAt: now), .deny(reason: "replayed_or_revoked"), "revocation epoch replay defense")

    var segments = token.split(separator: ".").map(String.init)
    let signatureIndex = segments[2].startIndex
    segments[2].replaceSubrange(signatureIndex...signatureIndex, with: segments[2][signatureIndex] == "A" ? "B" : "A")
    expect(segments.joined(separator: "."), context(publicKeys), .indeterminate(reason: "invalid_signature"), "signature tampering")
    expect(token, context(["other": privateKey.publicKey.rawRepresentation]), .indeterminate(reason: "unknown_key"), "unknown key")

    let refunded = try signedToken(payload(status: "refunded", issuedAt: now - 30, refreshAt: now + 300, expiresAt: now + 600), privateKey: privateKey)
    expect(refunded, context(publicKeys), .deny(reason: "inactive_entitlement"), "refund denies only a new start")

    let spkiPrefix = Data([0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00])
    expect(token, context(["test-key": spkiPrefix + privateKey.publicKey.rawRepresentation]), .allow(refreshRequired: false), "backend SPKI public key format")

    guard failures == 0 else {
      fputs("\(failures) access gate test(s) failed.\n", stderr)
      exit(1)
    }
    print("PASS: backend-compatible signed entitlement access gate")
  }

  private static func payload(
    status: String,
    issuedAt: Int64,
    refreshAt: Int64,
    expiresAt: Int64
  ) -> DDumpSignedEntitlement {
    DDumpSignedEntitlement(
      schema: "ddump.entitlement.v1",
      issuer: "https://api.ddump.app",
      audience: "com.ddump.app",
      keyID: "test-key",
      tokenID: "token-test",
      environment: "test",
      accountID: "account-test",
      productID: "ddump_test_monthly",
      entitlementID: "ddump_pro_test",
      status: status,
      issuedAt: issuedAt,
      notBefore: issuedAt - 60,
      refreshAt: refreshAt,
      graceExpiresAt: expiresAt,
      hardExpiresAt: expiresAt,
      installationID: "install-test",
      installationPublicKeySHA256: installHash,
      accountRevocationEpoch: issuedAt - 100,
      installationRevocationEpoch: issuedAt - 100
    )
  }

  private static func signedToken(
    _ payload: DDumpSignedEntitlement,
    privateKey: Curve25519.Signing.PrivateKey
  ) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let header = try JSONSerialization.data(
      withJSONObject: ["alg": "EdDSA", "kid": payload.keyID, "typ": "DDump-Entitlement"],
      options: [.sortedKeys]
    )
    let headerSegment = DDumpAccessGateCore.encodeBase64URL(header)
    let payloadSegment = DDumpAccessGateCore.encodeBase64URL(try encoder.encode(payload))
    let signedInput = Data("\(headerSegment).\(payloadSegment)".utf8)
    let signature = try privateKey.signature(for: signedInput)
    return "\(headerSegment).\(payloadSegment).\(DDumpAccessGateCore.encodeBase64URL(signature))"
  }

  private static func context(
    _ publicKeys: [String: Data],
    accountID: String = "account-test",
    installationID: String = "install-test",
    installationHash: String = installHash,
    now: Int64 = now,
    minimumIssuedAt: Int64 = 0
  ) -> DDumpAccessGateContext {
    DDumpAccessGateContext(
      publicKeys: publicKeys,
      expectedIssuer: "https://api.ddump.app",
      expectedAudience: "com.ddump.app",
      expectedEnvironment: "test",
      expectedAccountID: accountID,
      allowedProductIDs: ["ddump_test_monthly", "ddump_test_annual"],
      expectedInstallationID: installationID,
      expectedInstallationPublicKeySHA256: installationHash,
      now: now,
      minimumIssuedAt: minimumIssuedAt,
      allowedClockSkew: 300
    )
  }

  private static func expect(
    _ token: String,
    _ context: DDumpAccessGateContext,
    _ expected: DDumpAccessGateDecision,
    _ description: String
  ) {
    let actual = DDumpAccessGateCore.verify(token: token, context: context)
    if actual != expected {
      failures += 1
      fputs("FAIL: \(description) actual=\(actual) expected=\(expected)\n", stderr)
    }
  }
}
