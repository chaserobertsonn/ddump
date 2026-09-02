import CryptoKit
import Foundation

private struct DDumpEntitlementJWSHeader: Codable {
  let alg: String
  let typ: String
  let kid: String
}

struct DDumpSignedEntitlement: Codable, Equatable, Sendable {
  let schema: String
  let issuer: String
  let audience: String
  let keyID: String
  let tokenID: String
  let environment: String
  let accountID: String
  let productID: String
  let entitlementID: String
  let status: String
  let issuedAt: Int64
  let notBefore: Int64
  let refreshAt: Int64
  let graceExpiresAt: Int64
  let hardExpiresAt: Int64
  let installationID: String
  let installationPublicKeySHA256: String
  let accountRevocationEpoch: Int64?
  let installationRevocationEpoch: Int64?

  enum CodingKeys: String, CodingKey {
    case schema
    case issuer = "iss"
    case audience = "aud"
    case keyID = "kid"
    case tokenID = "jti"
    case environment
    case accountID = "account_id"
    case productID = "product_id"
    case entitlementID = "entitlement_id"
    case status
    case issuedAt = "iat"
    case notBefore = "nbf"
    case refreshAt = "refresh_at"
    case graceExpiresAt = "grace_expires_at"
    case hardExpiresAt = "exp"
    case installationID = "installation_id"
    case installationPublicKeySHA256 = "installation_public_key_sha256"
    case accountRevocationEpoch = "account_revocation_epoch"
    case installationRevocationEpoch = "installation_revocation_epoch"
  }
}

enum DDumpAccessGateDecision: Equatable, Sendable {
  case allow(refreshRequired: Bool)
  case deny(reason: String)
  case indeterminate(reason: String)
}

struct DDumpAccessGateContext: Sendable {
  let publicKeys: [String: Data]
  let expectedIssuer: String
  let expectedAudience: String
  let expectedEnvironment: String
  let expectedAccountID: String
  let allowedProductIDs: Set<String>
  let expectedInstallationID: String
  let expectedInstallationPublicKeySHA256: String
  let now: Int64
  let minimumIssuedAt: Int64
  let allowedClockSkew: Int64
}

enum DDumpAccessGateCore {
  static let maximumTokenBytes = 65_536
  static let supportedSchema = "ddump.entitlement.v1"
  static let allowedStatuses: Set<String> = ["active", "trialing", "past_due", "canceled"]

  static func verify(token: String, context: DDumpAccessGateContext) -> DDumpAccessGateDecision {
    guard token.utf8.count <= maximumTokenBytes else {
      return .indeterminate(reason: "token_too_large")
    }

    let segments = token.trimmingCharacters(in: .whitespacesAndNewlines)
      .split(separator: ".", omittingEmptySubsequences: false)
    guard segments.count == 3,
          let headerData = decodeBase64URL(String(segments[0])),
          let payloadData = decodeBase64URL(String(segments[1])),
          let signature = decodeBase64URL(String(segments[2])) else {
      return .indeterminate(reason: "malformed_token")
    }

    let decoder = JSONDecoder()
    guard let header = try? decoder.decode(DDumpEntitlementJWSHeader.self, from: headerData),
          let entitlement = try? decoder.decode(DDumpSignedEntitlement.self, from: payloadData) else {
      return .indeterminate(reason: "malformed_payload")
    }
    guard header.alg == "EdDSA", header.typ == "DDump-Entitlement" else {
      return .indeterminate(reason: "unsupported_header")
    }
    guard header.kid == entitlement.keyID else {
      return .indeterminate(reason: "key_id_mismatch")
    }
    guard entitlement.schema == supportedSchema else {
      return .indeterminate(reason: "unsupported_schema")
    }
    guard let configuredKey = context.publicKeys[entitlement.keyID],
          let rawPublicKey = rawEd25519PublicKey(configuredKey),
          let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: rawPublicKey) else {
      return .indeterminate(reason: "unknown_key")
    }
    let signedInput = Data("\(segments[0]).\(segments[1])".utf8)
    guard publicKey.isValidSignature(signature, for: signedInput) else {
      return .indeterminate(reason: "invalid_signature")
    }

    guard entitlement.issuer == context.expectedIssuer else { return .deny(reason: "wrong_issuer") }
    guard entitlement.audience == context.expectedAudience else { return .deny(reason: "wrong_audience") }
    guard entitlement.environment == context.expectedEnvironment else { return .deny(reason: "wrong_environment") }
    guard entitlement.accountID == context.expectedAccountID else { return .deny(reason: "wrong_account") }
    guard context.allowedProductIDs.contains(entitlement.productID) else { return .deny(reason: "wrong_product") }
    guard entitlement.installationID == context.expectedInstallationID else { return .deny(reason: "wrong_installation") }
    guard entitlement.installationPublicKeySHA256 == context.expectedInstallationPublicKeySHA256 else {
      return .deny(reason: "wrong_installation_key")
    }
    guard entitlement.issuedAt >= context.minimumIssuedAt,
          entitlement.issuedAt > (entitlement.accountRevocationEpoch ?? -1),
          entitlement.issuedAt > (entitlement.installationRevocationEpoch ?? -1) else {
      return .deny(reason: "replayed_or_revoked")
    }
    guard entitlement.notBefore <= entitlement.issuedAt,
          entitlement.issuedAt <= entitlement.refreshAt,
          entitlement.refreshAt <= entitlement.graceExpiresAt,
          entitlement.graceExpiresAt <= entitlement.hardExpiresAt else {
      return .indeterminate(reason: "invalid_time_window")
    }
    guard entitlement.notBefore <= context.now + max(context.allowedClockSkew, 0) else {
      return .indeterminate(reason: "not_yet_valid")
    }
    guard allowedStatuses.contains(entitlement.status) else {
      return .deny(reason: "inactive_entitlement")
    }
    guard context.now < entitlement.hardExpiresAt else {
      return .deny(reason: "offline_grace_expired")
    }

    return .allow(refreshRequired: context.now >= entitlement.refreshAt)
  }

  static func parsePublicKeys(_ rawValue: String) -> [String: Data] {
    var result: [String: Data] = [:]
    for entry in rawValue.split(separator: ",", omittingEmptySubsequences: true) {
      let pair = entry.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
      guard pair.count == 2 else { continue }
      let keyID = pair[0].trimmingCharacters(in: .whitespacesAndNewlines)
      let encodedKey = pair[1].trimmingCharacters(in: .whitespacesAndNewlines)
      guard !keyID.isEmpty, let keyData = decodeBase64URL(encodedKey) else { continue }
      result[keyID] = keyData
    }
    return result
  }

  static func encodeBase64URL(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  static func decodeBase64URL(_ value: String) -> Data? {
    var base64 = value
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    let remainder = base64.count % 4
    if remainder != 0 { base64.append(String(repeating: "=", count: 4 - remainder)) }
    return Data(base64Encoded: base64)
  }

  private static func rawEd25519PublicKey(_ configured: Data) -> Data? {
    if configured.count == 32 { return configured }
    let spkiPrefix = Data([0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00])
    if configured.count == spkiPrefix.count + 32, configured.starts(with: spkiPrefix) {
      return Data(configured.suffix(32))
    }
    return nil
  }
}
