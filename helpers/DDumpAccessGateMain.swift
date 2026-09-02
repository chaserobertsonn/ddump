import Foundation

private struct DDumpAccessGateArguments {
  var tokenFile = ""
  var publicKeys = ""
  var accountFile = ""
  var installationFile = ""
  var installationKeyHashFile = ""
  var issuer = ""
  var audience = ""
  var environment = ""
  var productIDs = ""
  var minimumIssuedAt: Int64 = 0
  var now = Int64(Date().timeIntervalSince1970)

  init?(_ arguments: [String]) {
    guard arguments.first == "verify" else { return nil }
    var index = 1
    while index < arguments.count {
      guard index + 1 < arguments.count else { return nil }
      let value = arguments[index + 1]
      switch arguments[index] {
      case "--token-file": tokenFile = value
      case "--public-keys": publicKeys = value
      case "--account-file": accountFile = value
      case "--installation-file": installationFile = value
      case "--installation-key-hash-file": installationKeyHashFile = value
      case "--issuer": issuer = value
      case "--audience": audience = value
      case "--environment": environment = value
      case "--product-ids": productIDs = value
      case "--minimum-issued-at": minimumIssuedAt = Int64(value) ?? -1
      case "--now": now = Int64(value) ?? -1
      default: return nil
      }
      index += 2
    }
    guard !tokenFile.isEmpty, !publicKeys.isEmpty, !accountFile.isEmpty,
          !installationFile.isEmpty, !installationKeyHashFile.isEmpty,
          !issuer.isEmpty, !audience.isEmpty, !environment.isEmpty, !productIDs.isEmpty,
          minimumIssuedAt >= 0, now >= 0 else {
      return nil
    }
  }
}

@main
enum DDumpAccessGateCommand {
  static func main() {
    guard let arguments = DDumpAccessGateArguments(Array(CommandLine.arguments.dropFirst())) else {
      fputs("usage: DDumpAccessGate verify --token-file PATH --public-keys KEY_ID:BASE64 --account-file PATH --installation-file PATH --installation-key-hash-file PATH --issuer URL --audience ID --environment test --product-ids ID,ID [--minimum-issued-at EPOCH] [--now EPOCH]\n", stderr)
      exit(64)
    }

    guard let token = protectedString(at: arguments.tokenFile),
          let accountID = protectedString(at: arguments.accountFile),
          let installationID = protectedString(at: arguments.installationFile),
          let installationKeyHash = protectedString(at: arguments.installationKeyHashFile) else {
      print("indeterminate reason=protected_state_unavailable")
      exit(3)
    }

    let decision = DDumpAccessGateCore.verify(
      token: token,
      context: DDumpAccessGateContext(
        publicKeys: DDumpAccessGateCore.parsePublicKeys(arguments.publicKeys),
        expectedIssuer: arguments.issuer,
        expectedAudience: arguments.audience,
        expectedEnvironment: arguments.environment,
        expectedAccountID: accountID,
        allowedProductIDs: Set(arguments.productIDs.split(separator: ",").map(String.init)),
        expectedInstallationID: installationID,
        expectedInstallationPublicKeySHA256: installationKeyHash,
        now: arguments.now,
        minimumIssuedAt: arguments.minimumIssuedAt,
        allowedClockSkew: 300
      )
    )

    switch decision {
    case let .allow(refreshRequired):
      print("allow refresh_required=\(refreshRequired ? 1 : 0)")
      exit(0)
    case let .deny(reason):
      print("deny reason=\(reason)")
      exit(2)
    case let .indeterminate(reason):
      print("indeterminate reason=\(reason)")
      exit(3)
    }
  }

  private static func protectedString(at path: String) -> String? {
    let url = URL(fileURLWithPath: path)
    guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
          values.isRegularFile == true, values.isSymbolicLink != true,
          let attributes = try? FileManager.default.attributesOfItem(atPath: path),
          let permissions = attributes[.posixPermissions] as? NSNumber,
          permissions.intValue & 0o077 == 0,
          let value = try? String(contentsOf: url, encoding: .utf8) else {
      return nil
    }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
