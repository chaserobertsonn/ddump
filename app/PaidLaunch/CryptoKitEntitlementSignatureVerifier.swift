import CryptoKit
import Foundation

public enum CryptoKitEntitlementSignatureError: Error {
  case malformedPublicKey
}

public struct CryptoKitEntitlementSignatureVerifier: Ed25519SignatureVerifying {
  public init() {}

  public func verify(
    signature: Data,
    message: Data,
    publicKey: EntitlementVerificationKey
  ) throws -> Bool {
    let rawKey: Data
    if publicKey.publicKey.count == 32 {
      rawKey = publicKey.publicKey
    } else {
      let prefix = Data([0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00])
      guard publicKey.publicKey.count == prefix.count + 32,
            publicKey.publicKey.starts(with: prefix) else {
        throw CryptoKitEntitlementSignatureError.malformedPublicKey
      }
      rawKey = Data(publicKey.publicKey.suffix(32))
    }
    guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: rawKey) else {
      throw CryptoKitEntitlementSignatureError.malformedPublicKey
    }
    return key.isValidSignature(signature, for: message)
  }
}
