import Foundation

public enum BackendEntitlementJWSDecoderError: Error, Equatable {
  case malformedToken
  case unsupportedHeader
  case keyIDMismatch
  case unsupportedSchema
  case issuerMismatch
  case environmentMismatch
  case malformedInstallationBinding
  case unsupportedStatus
}

public struct BackendEntitlementJWSDecoder {
  private struct Header: Codable {
    let alg: String
    let typ: String
    let kid: String
  }

  private struct Claims: Codable {
    struct DevicePolicy: Codable { let maxAuthorizedDevices: Int
      enum CodingKeys: String, CodingKey { case maxAuthorizedDevices = "max_authorized_devices" }
    }

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
    let devicePolicy: DevicePolicy

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
      case devicePolicy = "device_policy"
    }
  }

  public init() {}

  public func decode(
    _ token: String,
    expectedIssuer: String,
    expectedEnvironment: String
  ) throws -> SignedEntitlementDocument {
    let segments = token.trimmingCharacters(in: .whitespacesAndNewlines)
      .split(separator: ".", omittingEmptySubsequences: false)
    guard segments.count == 3,
          let headerData = decodeBase64URL(String(segments[0])),
          let claimsData = decodeBase64URL(String(segments[1])),
          let signature = decodeBase64URL(String(segments[2])),
          let header = try? JSONDecoder().decode(Header.self, from: headerData),
          let claims = try? JSONDecoder().decode(Claims.self, from: claimsData) else {
      throw BackendEntitlementJWSDecoderError.malformedToken
    }
    guard header.alg == "EdDSA", header.typ == "DDump-Entitlement" else {
      throw BackendEntitlementJWSDecoderError.unsupportedHeader
    }
    guard header.kid == claims.keyID else { throw BackendEntitlementJWSDecoderError.keyIDMismatch }
    guard claims.schema == "ddump.entitlement.v1" else {
      throw BackendEntitlementJWSDecoderError.unsupportedSchema
    }
    guard claims.issuer == expectedIssuer else { throw BackendEntitlementJWSDecoderError.issuerMismatch }
    guard claims.environment == expectedEnvironment else {
      throw BackendEntitlementJWSDecoderError.environmentMismatch
    }
    guard let installationKeyHash = decodeHex(claims.installationPublicKeySHA256),
          installationKeyHash.count == 32 else {
      throw BackendEntitlementJWSDecoderError.malformedInstallationBinding
    }
    guard let status = status(from: claims.status) else {
      throw BackendEntitlementJWSDecoderError.unsupportedStatus
    }

    return try SignedEntitlementDocument(
      schemaVersion: 1,
      issuer: claims.issuer,
      audience: claims.audience,
      keyID: EntitlementKeyID(claims.keyID),
      accountID: StableAccountID(claims.accountID),
      entitlementID: EntitlementID(claims.entitlementID),
      productID: ProductID(claims.productID),
      status: status,
      tokenID: EntitlementTokenID(claims.tokenID),
      policyVersion: claims.devicePolicy.maxAuthorizedDevices,
      issuedAt: Date(timeIntervalSince1970: TimeInterval(claims.issuedAt)),
      notBefore: Date(timeIntervalSince1970: TimeInterval(claims.notBefore)),
      refreshAfter: Date(timeIntervalSince1970: TimeInterval(claims.refreshAt)),
      refreshDeadline: Date(timeIntervalSince1970: TimeInterval(claims.refreshAt)),
      hardGraceExpiresAt: Date(timeIntervalSince1970: TimeInterval(claims.hardExpiresAt)),
      installationID: InstallationID(claims.installationID),
      installationPublicKey: installationKeyHash,
      accountRevocationEpoch: claims.accountRevocationEpoch.map {
        Date(timeIntervalSince1970: TimeInterval($0))
      },
      installationRevocationEpoch: claims.installationRevocationEpoch.map {
        Date(timeIntervalSince1970: TimeInterval($0))
      },
      signedPayload: Data("\(segments[0]).\(segments[1])".utf8),
      signature: signature,
      signaturePayloadFormat: .backendJWSV1
    )
  }

  private func status(from rawValue: String) -> EntitlementStatus? {
    switch rawValue {
    case "trialing": return .trialing
    case "active": return .active
    case "past_due": return .pastDue
    case "canceled": return .cancellationAtPeriodEnd
    case "expired": return .expired
    case "refunded": return .refunded
    case "disputed": return .disputed
    case "chargeback": return .chargeback
    case "support_hold": return .supportHold
    case "revoked": return .revoked
    case "pending", "unknown", "indeterminate": return .incomplete
    default: return nil
    }
  }

  private func decodeBase64URL(_ value: String) -> Data? {
    var base64 = value.replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    if base64.count % 4 != 0 {
      base64 += String(repeating: "=", count: 4 - base64.count % 4)
    }
    return Data(base64Encoded: base64)
  }

  private func decodeHex(_ value: String) -> Data? {
    guard value.count % 2 == 0, value.allSatisfy(\.isHexDigit) else { return nil }
    var data = Data()
    var index = value.startIndex
    while index < value.endIndex {
      let next = value.index(index, offsetBy: 2)
      guard let byte = UInt8(value[index..<next], radix: 16) else { return nil }
      data.append(byte)
      index = next
    }
    return data
  }
}

public final class StaticEntitlementVerificationKeyProvider: EntitlementVerificationKeyProviding {
  private let keys: [EntitlementKeyID: EntitlementVerificationKey]

  public init(keys: [EntitlementVerificationKey]) {
    self.keys = Dictionary(uniqueKeysWithValues: keys.map { ($0.keyID, $0) })
  }

  public func verificationKey(for keyID: EntitlementKeyID) -> EntitlementVerificationKey? {
    keys[keyID]
  }
}
