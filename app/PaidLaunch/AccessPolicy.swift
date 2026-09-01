import Foundation

public enum StartImportAuthorization: Equatable, Sendable {
  case authorized(StartImportLease)
  case denied(StartImportDenialReason)
  case deferredUntilSafeIdle
}

public struct StartImportLease: Equatable, Sendable {
  public let leaseID: String
  public let accountID: StableAccountID
  public let entitlementTokenID: EntitlementTokenID
  public let startedAt: Date

  public init(leaseID: String, accountID: StableAccountID, entitlementTokenID: EntitlementTokenID, startedAt: Date) throws {
    guard !leaseID.isEmpty else { throw PaidLaunchValidationError.empty("leaseID") }
    self.leaseID = leaseID
    self.accountID = accountID
    self.entitlementTokenID = entitlementTokenID
    self.startedAt = startedAt
  }
}

public enum StartImportDenialReason: Equatable, Sendable {
  case notSafeIdle
  case noVerifiedEntitlement
  case entitlementRevoked(EntitlementRevocationReason)
  case entitlementIndeterminate(EntitlementIndeterminateReason)
}

public protocol ImportLeaseIDGenerating {
  func nextLeaseID() -> String
}

public final class AccessPolicy {
  private let leaseIDGenerator: ImportLeaseIDGenerating
  private let clock: PaidLaunchClock
  private var pendingDenyNextImport: EntitlementRevocationReason?

  public private(set) var activeLease: StartImportLease?
  public private(set) var lastDecision: EntitlementDecision?

  public init(leaseIDGenerator: ImportLeaseIDGenerating, clock: PaidLaunchClock) {
    self.leaseIDGenerator = leaseIDGenerator
    self.clock = clock
  }

  public func updateEntitlement(_ decision: EntitlementDecision, currentIngestState: ImportSafetyState) {
    lastDecision = decision
    if case .revoked(let reason) = decision, currentIngestState.isActiveCardWork {
      pendingDenyNextImport = reason
    }
  }

  public func authorizeStartImport(
    entitlement decision: EntitlementDecision,
    currentIngestState: ImportSafetyState
  ) -> StartImportAuthorization {
    lastDecision = decision
    guard currentIngestState.isVerifiedSafeIdle else { return .denied(.notSafeIdle) }
    if let pendingDenyNextImport {
      activeLease = nil
      self.pendingDenyNextImport = nil
      return .denied(.entitlementRevoked(pendingDenyNextImport))
    }
    switch decision {
    case .valid(let entitlement):
      guard entitlement.document.status.permitsNewImportsWhenCurrent else {
        return .denied(.entitlementRevoked(.terminalStatus(entitlement.document.status)))
      }
      do {
        let lease = try StartImportLease(
          leaseID: leaseIDGenerator.nextLeaseID(),
          accountID: entitlement.document.accountID,
          entitlementTokenID: entitlement.document.tokenID,
          startedAt: clock.now
        )
        activeLease = lease
        return .authorized(lease)
      } catch {
        return .denied(.noVerifiedEntitlement)
      }
    case .indeterminate(let reason):
      return .denied(.entitlementIndeterminate(reason))
    case .revoked(let reason):
      return .denied(.entitlementRevoked(reason))
    }
  }

  public func ingestStateChanged(to state: ImportSafetyState) {
    if state.isVerifiedSafeIdle {
      activeLease = nil
    }
  }

  public func mayContinueActiveRun(currentIngestState: ImportSafetyState) -> Bool {
    activeLease != nil && currentIngestState.isActiveCardWork
  }

  public func canAccess(_ surface: CustomerSurface, entitlement decision: EntitlementDecision?) -> Bool {
    true
  }
}
