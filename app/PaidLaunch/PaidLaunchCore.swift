import Foundation

public struct StableAccountID: Hashable, Codable, Sendable {
  public let rawValue: String

  public init(_ rawValue: String) throws {
    let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw PaidLaunchValidationError.empty("accountID") }
    self.rawValue = trimmed
  }
}

public struct ProviderSubjectID: Hashable, Codable, Sendable {
  public let provider: String
  public let subject: String

  public init(provider: String, subject: String) throws {
    guard !provider.isEmpty else { throw PaidLaunchValidationError.empty("provider") }
    guard !subject.isEmpty else { throw PaidLaunchValidationError.empty("subject") }
    self.provider = provider
    self.subject = subject
  }
}

public struct RevenueCatAppUserID: Hashable, Codable, Sendable {
  public let rawValue: String

  public init(_ rawValue: String) throws {
    guard !rawValue.isEmpty else { throw PaidLaunchValidationError.empty("revenueCatAppUserID") }
    self.rawValue = rawValue
  }
}

public struct StripeCustomerID: Hashable, Codable, Sendable {
  public let rawValue: String

  public init(_ rawValue: String) throws {
    guard !rawValue.isEmpty else { throw PaidLaunchValidationError.empty("stripeCustomerID") }
    self.rawValue = rawValue
  }
}

public struct InstallationID: Hashable, Codable, Sendable {
  public let rawValue: String

  public init(_ rawValue: String) throws {
    guard !rawValue.isEmpty else { throw PaidLaunchValidationError.empty("installationID") }
    self.rawValue = rawValue
  }
}

public struct ProductID: Hashable, Codable, Sendable {
  public let rawValue: String

  public init(_ rawValue: String) throws {
    guard !rawValue.isEmpty else { throw PaidLaunchValidationError.empty("productID") }
    self.rawValue = rawValue
  }
}

public struct OfferingID: Hashable, Codable, Sendable {
  public let rawValue: String

  public init(_ rawValue: String) throws {
    guard !rawValue.isEmpty else { throw PaidLaunchValidationError.empty("offeringID") }
    self.rawValue = rawValue
  }
}

public struct PackageID: Hashable, Codable, Sendable {
  public let rawValue: String

  public init(_ rawValue: String) throws {
    guard !rawValue.isEmpty else { throw PaidLaunchValidationError.empty("packageID") }
    self.rawValue = rawValue
  }
}

public struct VariantID: Hashable, Codable, Sendable {
  public let rawValue: String

  public init(_ rawValue: String) throws {
    guard !rawValue.isEmpty else { throw PaidLaunchValidationError.empty("variantID") }
    self.rawValue = rawValue
  }
}

public struct EntitlementID: Hashable, Codable, Sendable {
  public let rawValue: String

  public init(_ rawValue: String) throws {
    guard !rawValue.isEmpty else { throw PaidLaunchValidationError.empty("entitlementID") }
    self.rawValue = rawValue
  }
}

public struct EntitlementTokenID: Hashable, Codable, Sendable {
  public let rawValue: String

  public init(_ rawValue: String) throws {
    guard !rawValue.isEmpty else { throw PaidLaunchValidationError.empty("tokenID") }
    self.rawValue = rawValue
  }
}

public struct EntitlementKeyID: Hashable, Codable, Sendable {
  public let rawValue: String

  public init(_ rawValue: String) throws {
    guard !rawValue.isEmpty else { throw PaidLaunchValidationError.empty("keyID") }
    self.rawValue = rawValue
  }
}

public enum PaidLaunchValidationError: Error, Equatable, CustomStringConvertible {
  case empty(String)
  case invalid(String)

  public var description: String {
    switch self {
    case .empty(let field):
      return "\(field) must not be empty"
    case .invalid(let reason):
      return reason
    }
  }
}

public protocol PaidLaunchClock {
  var now: Date { get }
  var monotonicTime: TimeInterval { get }
}

public struct SystemPaidLaunchClock: PaidLaunchClock {
  public init() {}

  public var now: Date { Date() }
  public var monotonicTime: TimeInterval { ProcessInfo.processInfo.systemUptime }
}

public enum BuildFlavor: String, Codable, Sendable {
  case debug
  case beta
  case stable
}

public enum ReleaseChannel: String, Codable, Sendable {
  case beta
  case stable
}

public enum ImportSafetyState: String, Codable, Sendable {
  case idle
  case scanning
  case copying
  case verifying
  case organizing
  case backupHandoff
  case recovering
  case ejectPending
  case mountedCardSafetyHold
  case safeEject
  case safeIdle

  public var isVerifiedSafeIdle: Bool {
    self == .idle || self == .safeIdle
  }

  public var isActiveCardWork: Bool {
    !isVerifiedSafeIdle
  }
}

public enum CustomerSurface: String, Codable, Sendable {
  case copiedFiles
  case receipts
  case logs
  case diagnostics
  case settings
  case support
  case safeCleanup
}

public struct AccountIdentity: Codable, Hashable, Sendable {
  public let accountID: StableAccountID
  public let providerSubjectID: ProviderSubjectID
  public let revenueCatAppUserID: RevenueCatAppUserID
  public let stripeCustomerID: StripeCustomerID?

  public init(
    accountID: StableAccountID,
    providerSubjectID: ProviderSubjectID,
    revenueCatAppUserID: RevenueCatAppUserID,
    stripeCustomerID: StripeCustomerID?
  ) {
    self.accountID = accountID
    self.providerSubjectID = providerSubjectID
    self.revenueCatAppUserID = revenueCatAppUserID
    self.stripeCustomerID = stripeCustomerID
  }
}

public struct AccountSession: Codable, Hashable, Sendable {
  public let identity: AccountIdentity
  public let accessToken: String
  public let refreshToken: String?
  public let expiresAt: Date

  public init(identity: AccountIdentity, accessToken: String, refreshToken: String?, expiresAt: Date) throws {
    guard !accessToken.isEmpty else { throw PaidLaunchValidationError.empty("accessToken") }
    self.identity = identity
    self.accessToken = accessToken
    self.refreshToken = refreshToken
    self.expiresAt = expiresAt
  }
}

public protocol KeychainValueStore {
  func data(forKey key: String) throws -> Data?
  func setData(_ data: Data, forKey key: String) throws
  func deleteData(forKey key: String) throws
}

public final class CodableKeychainBox<Value: Codable> {
  private let key: String
  private let store: KeychainValueStore
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder

  public init(key: String, store: KeychainValueStore) {
    self.key = key
    self.store = store
    self.encoder = JSONEncoder()
    self.decoder = JSONDecoder()
    self.encoder.dateEncodingStrategy = .iso8601
    self.decoder.dateDecodingStrategy = .iso8601
  }

  public func load() throws -> Value? {
    guard let data = try store.data(forKey: key) else { return nil }
    return try decoder.decode(Value.self, from: data)
  }

  public func save(_ value: Value) throws {
    try store.setData(encoder.encode(value), forKey: key)
  }

  public func delete() throws {
    try store.deleteData(forKey: key)
  }
}

public final class InMemoryKeychainValueStore: KeychainValueStore {
  private var values: [String: Data]

  public init(values: [String: Data] = [:]) {
    self.values = values
  }

  public func data(forKey key: String) throws -> Data? {
    values[key]
  }

  public func setData(_ data: Data, forKey key: String) throws {
    values[key] = data
  }

  public func deleteData(forKey key: String) throws {
    values.removeValue(forKey: key)
  }
}
