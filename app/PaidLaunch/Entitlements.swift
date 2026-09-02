import Foundation

public enum EntitlementStatus: String, Codable, Sendable {
  case trialing
  case active
  case pastDue
  case cancellationAtPeriodEnd
  case unpaid
  case incomplete
  case expired
  case refunded
  case disputed
  case chargeback
  case supportHold
  case revoked

  public var permitsNewImportsWhenCurrent: Bool {
    switch self {
    case .trialing, .active, .pastDue, .cancellationAtPeriodEnd:
      return true
    case .unpaid, .incomplete, .expired, .refunded, .disputed, .chargeback, .supportHold, .revoked:
      return false
    }
  }
}

public enum EntitlementSignaturePayloadFormat: String, Codable, Sendable {
  case canonicalV1
  case backendJWSV1
}

public struct SignedEntitlementDocument: Codable, Hashable, Sendable {
  public let schemaVersion: Int
  public let issuer: String
  public let audience: String
  public let keyID: EntitlementKeyID
  public let accountID: StableAccountID
  public let entitlementID: EntitlementID
  public let productID: ProductID
  public let status: EntitlementStatus
  public let tokenID: EntitlementTokenID
  public let policyVersion: Int
  public let issuedAt: Date
  public let notBefore: Date
  public let refreshAfter: Date
  public let refreshDeadline: Date
  public let hardGraceExpiresAt: Date
  public let installationID: InstallationID
  public let installationPublicKey: Data
  public let accountRevocationEpoch: Date?
  public let installationRevocationEpoch: Date?
  public let signedPayload: Data
  public let signature: Data
  public let signaturePayloadFormat: EntitlementSignaturePayloadFormat

  public init(
    schemaVersion: Int,
    issuer: String,
    audience: String,
    keyID: EntitlementKeyID,
    accountID: StableAccountID,
    entitlementID: EntitlementID,
    productID: ProductID,
    status: EntitlementStatus,
    tokenID: EntitlementTokenID,
    policyVersion: Int,
    issuedAt: Date,
    notBefore: Date,
    refreshAfter: Date,
    refreshDeadline: Date,
    hardGraceExpiresAt: Date,
    installationID: InstallationID,
    installationPublicKey: Data,
    accountRevocationEpoch: Date? = nil,
    installationRevocationEpoch: Date? = nil,
    signedPayload: Data,
    signature: Data,
    signaturePayloadFormat: EntitlementSignaturePayloadFormat = .canonicalV1
  ) throws {
    guard schemaVersion > 0 else { throw PaidLaunchValidationError.invalid("schemaVersion must be positive") }
    guard !issuer.isEmpty else { throw PaidLaunchValidationError.empty("issuer") }
    guard !audience.isEmpty else { throw PaidLaunchValidationError.empty("audience") }
    guard !installationPublicKey.isEmpty else { throw PaidLaunchValidationError.empty("installationPublicKey") }
    guard !signedPayload.isEmpty else { throw PaidLaunchValidationError.empty("signedPayload") }
    guard !signature.isEmpty else { throw PaidLaunchValidationError.empty("signature") }
    guard notBefore <= issuedAt else { throw PaidLaunchValidationError.invalid("notBefore must not be after issuedAt") }
    guard issuedAt <= refreshAfter else { throw PaidLaunchValidationError.invalid("issuedAt must not be after refreshAfter") }
    guard refreshAfter <= refreshDeadline else { throw PaidLaunchValidationError.invalid("refreshAfter must not be after refreshDeadline") }
    guard refreshDeadline <= hardGraceExpiresAt else { throw PaidLaunchValidationError.invalid("refreshDeadline must not be after hardGraceExpiresAt") }
    self.schemaVersion = schemaVersion
    self.issuer = issuer
    self.audience = audience
    self.keyID = keyID
    self.accountID = accountID
    self.entitlementID = entitlementID
    self.productID = productID
    self.status = status
    self.tokenID = tokenID
    self.policyVersion = policyVersion
    self.issuedAt = issuedAt
    self.notBefore = notBefore
    self.refreshAfter = refreshAfter
    self.refreshDeadline = refreshDeadline
    self.hardGraceExpiresAt = hardGraceExpiresAt
    self.installationID = installationID
    self.installationPublicKey = installationPublicKey
    self.accountRevocationEpoch = accountRevocationEpoch
    self.installationRevocationEpoch = installationRevocationEpoch
    self.signedPayload = signedPayload
    self.signature = signature
    self.signaturePayloadFormat = signaturePayloadFormat
  }

  public func canonicalSignedPayload() -> Data {
    if signaturePayloadFormat == .backendJWSV1 {
      return signedPayload
    }
    var fields = [
      "schema=\(schemaVersion)",
      "issuer=\(issuer)",
      "audience=\(audience)",
      "key=\(keyID.rawValue)",
      "account=\(accountID.rawValue)",
      "entitlement=\(entitlementID.rawValue)",
      "product=\(productID.rawValue)",
      "status=\(status.rawValue)",
      "token=\(tokenID.rawValue)",
      "policy=\(policyVersion)",
      "issued=\(milliseconds(issuedAt))",
      "notBefore=\(milliseconds(notBefore))",
      "refreshAfter=\(milliseconds(refreshAfter))",
      "refreshDeadline=\(milliseconds(refreshDeadline))",
      "hardGrace=\(milliseconds(hardGraceExpiresAt))",
      "installation=\(installationID.rawValue)",
      "installationKey=\(installationPublicKey.base64EncodedString())"
    ]
    if let accountRevocationEpoch {
      fields.append("accountRevocation=\(milliseconds(accountRevocationEpoch))")
    }
    if let installationRevocationEpoch {
      fields.append("installationRevocation=\(milliseconds(installationRevocationEpoch))")
    }
    return Data(fields.joined(separator: "\n").utf8)
  }

  private func milliseconds(_ date: Date) -> String {
    String(Int64((date.timeIntervalSince1970 * 1000).rounded()))
  }
}

public struct EntitlementVerificationKey: Hashable, Sendable {
  public let keyID: EntitlementKeyID
  public let publicKey: Data
  public let revokedAt: Date?

  public init(keyID: EntitlementKeyID, publicKey: Data, revokedAt: Date?) throws {
    guard !publicKey.isEmpty else { throw PaidLaunchValidationError.empty("publicKey") }
    self.keyID = keyID
    self.publicKey = publicKey
    self.revokedAt = revokedAt
  }
}

public protocol EntitlementVerificationKeyProviding {
  func verificationKey(for keyID: EntitlementKeyID) -> EntitlementVerificationKey?
}

public protocol Ed25519SignatureVerifying {
  func verify(signature: Data, message: Data, publicKey: EntitlementVerificationKey) throws -> Bool
}

public protocol EntitlementReplayProtecting {
  func minimumAcceptedIssueDate(accountID: StableAccountID, installationID: InstallationID) -> Date?
  func latestAcceptedIssueDate(accountID: StableAccountID, installationID: InstallationID) -> Date?
  func recordAccepted(tokenID: EntitlementTokenID, issuedAt: Date, accountID: StableAccountID, installationID: InstallationID)
}

public final class InMemoryEntitlementReplayProtector: EntitlementReplayProtecting {
  private var minimumIssueDates: [String: Date] = [:]
  private var latestIssueDates: [String: Date] = [:]

  public init() {}

  public func setMinimumAcceptedIssueDate(_ date: Date, accountID: StableAccountID, installationID: InstallationID) {
    minimumIssueDates[key(accountID, installationID)] = date
  }

  public func minimumAcceptedIssueDate(accountID: StableAccountID, installationID: InstallationID) -> Date? {
    minimumIssueDates[key(accountID, installationID)]
  }

  public func latestAcceptedIssueDate(accountID: StableAccountID, installationID: InstallationID) -> Date? {
    latestIssueDates[key(accountID, installationID)]
  }

  public func recordAccepted(tokenID: EntitlementTokenID, issuedAt: Date, accountID: StableAccountID, installationID: InstallationID) {
    let mapKey = key(accountID, installationID)
    if let current = latestIssueDates[mapKey], current > issuedAt {
      return
    }
    latestIssueDates[mapKey] = issuedAt
  }

  private func key(_ accountID: StableAccountID, _ installationID: InstallationID) -> String {
    "\(accountID.rawValue)|\(installationID.rawValue)"
  }
}

private struct PersistedEntitlementReplayState: Codable {
  var minimumIssueDates: [String: Date] = [:]
  var latestIssueDates: [String: Date] = [:]
}

/// Persists anti-rollback state in the login Keychain. If that state is
/// corrupt or unavailable, verification fails closed instead of accepting an
/// older copied entitlement document.
public final class KeychainEntitlementReplayProtector: EntitlementReplayProtecting {
  private let box: CodableKeychainBox<PersistedEntitlementReplayState>
  private let lock = NSLock()
  private var state: PersistedEntitlementReplayState
  private var storageAvailable: Bool

  public init(key: String = "entitlement-replay-state-v1", store: KeychainValueStore) {
    box = CodableKeychainBox(key: key, store: store)
    do {
      state = try box.load() ?? PersistedEntitlementReplayState()
      storageAvailable = true
    } catch {
      state = PersistedEntitlementReplayState()
      storageAvailable = false
    }
  }

  public func minimumAcceptedIssueDate(
    accountID: StableAccountID,
    installationID: InstallationID
  ) -> Date? {
    lock.lock()
    defer { lock.unlock() }
    guard storageAvailable else { return .distantFuture }
    return state.minimumIssueDates[mapKey(accountID, installationID)]
  }

  public func latestAcceptedIssueDate(
    accountID: StableAccountID,
    installationID: InstallationID
  ) -> Date? {
    lock.lock()
    defer { lock.unlock() }
    guard storageAvailable else { return .distantFuture }
    return state.latestIssueDates[mapKey(accountID, installationID)]
  }

  public func recordAccepted(
    tokenID: EntitlementTokenID,
    issuedAt: Date,
    accountID: StableAccountID,
    installationID: InstallationID
  ) {
    lock.lock()
    defer { lock.unlock() }
    guard storageAvailable else { return }
    let key = mapKey(accountID, installationID)
    if let current = state.latestIssueDates[key], current > issuedAt { return }
    state.latestIssueDates[key] = issuedAt
    do {
      try box.save(state)
    } catch {
      storageAvailable = false
    }
  }

  public func advanceMinimumIssueDate(
    _ issuedAt: Date,
    accountID: StableAccountID,
    installationID: InstallationID
  ) {
    lock.lock()
    defer { lock.unlock() }
    guard storageAvailable else { return }
    let key = mapKey(accountID, installationID)
    if let current = state.minimumIssueDates[key], current >= issuedAt { return }
    state.minimumIssueDates[key] = issuedAt
    do {
      try box.save(state)
    } catch {
      storageAvailable = false
    }
  }

  private func mapKey(_ accountID: StableAccountID, _ installationID: InstallationID) -> String {
    "\(accountID.rawValue)|\(installationID.rawValue)"
  }
}

public struct VerifiedEntitlement: Equatable, Sendable {
  public let document: SignedEntitlementDocument
  public let requiresOnlineRefresh: Bool
  public let isInOfflineGrace: Bool

  public init(document: SignedEntitlementDocument, requiresOnlineRefresh: Bool, isInOfflineGrace: Bool) {
    self.document = document
    self.requiresOnlineRefresh = requiresOnlineRefresh
    self.isInOfflineGrace = isInOfflineGrace
  }
}

public enum EntitlementIndeterminateReason: Equatable, Sendable {
  case serviceUnavailable
  case clockAnomaly
  case corruptLocalCache
  case timedOut
}

public enum EntitlementRevocationReason: Equatable, Sendable {
  case terminalStatus(EntitlementStatus)
  case expiredHardGrace
  case wrongAudience
  case wrongAccount
  case wrongProduct
  case wrongInstallation
  case unknownKey
  case revokedKey
  case invalidSignature
  case unsupportedSchema
  case notYetValid
  case staleOrReplayed
}

public enum EntitlementDecision: Equatable, Sendable {
  case valid(VerifiedEntitlement)
  case indeterminate(EntitlementIndeterminateReason)
  case revoked(EntitlementRevocationReason)

  public var permitsNewImports: Bool {
    switch self {
    case .valid(let entitlement):
      return entitlement.document.status.permitsNewImportsWhenCurrent
    case .indeterminate, .revoked:
      return false
    }
  }
}

public struct EntitlementVerificationContext: Sendable {
  public let expectedAudience: String
  public let expectedAccountID: StableAccountID
  public let expectedProductID: ProductID
  public let expectedInstallationID: InstallationID
  public let expectedInstallationPublicKeyHash: Data
  public let trustedNow: Date
  public let clockSkewAllowance: TimeInterval

  public init(
    expectedAudience: String,
    expectedAccountID: StableAccountID,
    expectedProductID: ProductID,
    expectedInstallationID: InstallationID,
    expectedInstallationPublicKeyHash: Data,
    trustedNow: Date,
    clockSkewAllowance: TimeInterval = 300
  ) {
    self.expectedAudience = expectedAudience
    self.expectedAccountID = expectedAccountID
    self.expectedProductID = expectedProductID
    self.expectedInstallationID = expectedInstallationID
    self.expectedInstallationPublicKeyHash = expectedInstallationPublicKeyHash
    self.trustedNow = trustedNow
    self.clockSkewAllowance = clockSkewAllowance
  }
}

public final class EntitlementVerifier {
  private let keyProvider: EntitlementVerificationKeyProviding
  private let signatureVerifier: Ed25519SignatureVerifying
  private let replayProtector: EntitlementReplayProtecting
  private let supportedSchemaVersion: Int

  public init(
    keyProvider: EntitlementVerificationKeyProviding,
    signatureVerifier: Ed25519SignatureVerifying,
    replayProtector: EntitlementReplayProtecting,
    supportedSchemaVersion: Int = 1
  ) {
    self.keyProvider = keyProvider
    self.signatureVerifier = signatureVerifier
    self.replayProtector = replayProtector
    self.supportedSchemaVersion = supportedSchemaVersion
  }

  public func verify(_ document: SignedEntitlementDocument, context: EntitlementVerificationContext) -> EntitlementDecision {
    guard document.schemaVersion == supportedSchemaVersion else { return .revoked(.unsupportedSchema) }
    guard let key = keyProvider.verificationKey(for: document.keyID) else { return .revoked(.unknownKey) }
    if let revokedAt = key.revokedAt, document.issuedAt >= revokedAt {
      return .revoked(.revokedKey)
    }
    if let minimum = replayProtector.minimumAcceptedIssueDate(accountID: document.accountID, installationID: document.installationID),
       document.issuedAt < minimum {
      return .revoked(.staleOrReplayed)
    }
    if let latest = replayProtector.latestAcceptedIssueDate(accountID: document.accountID, installationID: document.installationID),
       document.issuedAt < latest {
      return .revoked(.staleOrReplayed)
    }
    guard document.signedPayload == document.canonicalSignedPayload() else {
      return .revoked(.invalidSignature)
    }
    let signatureValid = (try? signatureVerifier.verify(
      signature: document.signature,
      message: document.signedPayload,
      publicKey: key
    )) ?? false
    guard signatureValid else { return .revoked(.invalidSignature) }
    guard document.audience == context.expectedAudience else { return .revoked(.wrongAudience) }
    guard document.accountID == context.expectedAccountID else { return .revoked(.wrongAccount) }
    guard document.productID == context.expectedProductID else { return .revoked(.wrongProduct) }
    guard document.installationID == context.expectedInstallationID else { return .revoked(.wrongInstallation) }
    guard document.installationPublicKey == context.expectedInstallationPublicKeyHash else {
      return .revoked(.wrongInstallation)
    }
    if let epoch = document.accountRevocationEpoch, document.issuedAt <= epoch {
      return .revoked(.staleOrReplayed)
    }
    if let epoch = document.installationRevocationEpoch, document.issuedAt <= epoch {
      return .revoked(.staleOrReplayed)
    }
    if document.notBefore.timeIntervalSince(context.trustedNow) > context.clockSkewAllowance {
      return .revoked(.notYetValid)
    }
    guard context.trustedNow <= document.hardGraceExpiresAt else { return .revoked(.expiredHardGrace) }
    guard document.status.permitsNewImportsWhenCurrent else { return .revoked(.terminalStatus(document.status)) }

    let requiresRefresh = context.trustedNow >= document.refreshAfter
    let isInOfflineGrace = context.trustedNow > document.refreshDeadline
    let verified = VerifiedEntitlement(
      document: document,
      requiresOnlineRefresh: requiresRefresh,
      isInOfflineGrace: isInOfflineGrace
    )
    replayProtector.recordAccepted(
      tokenID: document.tokenID,
      issuedAt: document.issuedAt,
      accountID: document.accountID,
      installationID: document.installationID
    )
    return .valid(verified)
  }
}

public protocol EntitlementDocumentStore {
  func loadSignedEntitlement() throws -> SignedEntitlementDocument?
  func saveSignedEntitlement(_ document: SignedEntitlementDocument) throws
  func deleteSignedEntitlement() throws
}

public final class KeychainEntitlementDocumentStore: EntitlementDocumentStore {
  private let box: CodableKeychainBox<SignedEntitlementDocument>

  public init(box: CodableKeychainBox<SignedEntitlementDocument>) {
    self.box = box
  }

  public func loadSignedEntitlement() throws -> SignedEntitlementDocument? {
    try box.load()
  }

  public func saveSignedEntitlement(_ document: SignedEntitlementDocument) throws {
    try box.save(document)
  }

  public func deleteSignedEntitlement() throws {
    try box.delete()
  }
}

public enum EntitlementRefreshPurpose: String, Codable, Sendable {
  case purchase
  case restore
  case secondMac
  case periodic
}

public enum RemoteEntitlementResult: Equatable, Sendable {
  case valid(SignedEntitlementDocument)
  case indeterminate(EntitlementIndeterminateReason)
  case revoked(EntitlementRevocationReason)
}

public struct EntitlementRefreshRequest: Equatable, Sendable {
  public let session: AccountSession
  public let installationID: InstallationID
  public let productID: ProductID
  public let purpose: EntitlementRefreshPurpose
  public let appVersion: String
  public let channel: ReleaseChannel

  public init(
    session: AccountSession,
    installationID: InstallationID,
    productID: ProductID,
    purpose: EntitlementRefreshPurpose,
    appVersion: String,
    channel: ReleaseChannel
  ) {
    self.session = session
    self.installationID = installationID
    self.productID = productID
    self.purpose = purpose
    self.appVersion = appVersion
    self.channel = channel
  }
}

public protocol EntitlementRefreshing {
  func refreshEntitlement(_ request: EntitlementRefreshRequest) throws -> RemoteEntitlementResult
}

public final class EntitlementClient {
  private let refresher: EntitlementRefreshing
  private let verifier: EntitlementVerifier
  private let store: EntitlementDocumentStore
  private let audience: String
  private let installationPublicKeyHash: Data
  private let clock: PaidLaunchClock

  public init(
    refresher: EntitlementRefreshing,
    verifier: EntitlementVerifier,
    store: EntitlementDocumentStore,
    audience: String,
    installationPublicKeyHash: Data,
    clock: PaidLaunchClock
  ) {
    self.refresher = refresher
    self.verifier = verifier
    self.store = store
    self.audience = audience
    self.installationPublicKeyHash = installationPublicKeyHash
    self.clock = clock
  }

  public func refresh(
    session: AccountSession,
    installationID: InstallationID,
    productID: ProductID,
    purpose: EntitlementRefreshPurpose,
    appVersion: String,
    channel: ReleaseChannel
  ) throws -> EntitlementDecision {
    let request = EntitlementRefreshRequest(
      session: session,
      installationID: installationID,
      productID: productID,
      purpose: purpose,
      appVersion: appVersion,
      channel: channel
    )
    switch try refresher.refreshEntitlement(request) {
    case .valid(let document):
      let decision = verifier.verify(document, context: context(session: session, installationID: installationID, productID: productID))
      if case .valid = decision {
        try store.saveSignedEntitlement(document)
      }
      return decision
    case .indeterminate(let reason):
      if let cached = try store.loadSignedEntitlement() {
        let cachedDecision = verifier.verify(cached, context: context(session: session, installationID: installationID, productID: productID))
        if case .valid = cachedDecision {
          return cachedDecision
        }
      }
      return .indeterminate(reason)
    case .revoked(let reason):
      return .revoked(reason)
    }
  }

  public func restore(
    session: AccountSession,
    installationID: InstallationID,
    productID: ProductID,
    appVersion: String,
    channel: ReleaseChannel
  ) throws -> EntitlementDecision {
    try refresh(
      session: session,
      installationID: installationID,
      productID: productID,
      purpose: .restore,
      appVersion: appVersion,
      channel: channel
    )
  }

  public func activateSecondMac(
    session: AccountSession,
    installationID: InstallationID,
    productID: ProductID,
    appVersion: String,
    channel: ReleaseChannel
  ) throws -> EntitlementDecision {
    try refresh(
      session: session,
      installationID: installationID,
      productID: productID,
      purpose: .secondMac,
      appVersion: appVersion,
      channel: channel
    )
  }

  private func context(session: AccountSession, installationID: InstallationID, productID: ProductID) -> EntitlementVerificationContext {
    EntitlementVerificationContext(
      expectedAudience: audience,
      expectedAccountID: session.identity.accountID,
      expectedProductID: productID,
      expectedInstallationID: installationID,
      expectedInstallationPublicKeyHash: installationPublicKeyHash,
      trustedNow: clock.now
    )
  }
}
