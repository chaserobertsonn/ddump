import Foundation

public struct HostedCheckoutLink: Equatable, Sendable {
  public let url: URL
  public let appUserID: RevenueCatAppUserID
  public let offeringID: OfferingID
  public let packageID: PackageID
  public let stateNonce: String
  public let expiresAt: Date

  public init(
    url: URL,
    appUserID: RevenueCatAppUserID,
    offeringID: OfferingID,
    packageID: PackageID,
    stateNonce: String,
    expiresAt: Date
  ) throws {
    guard url.scheme == "https" else { throw PaidLaunchValidationError.invalid("checkout URL must be https") }
    guard !stateNonce.isEmpty else { throw PaidLaunchValidationError.empty("stateNonce") }
    self.url = url
    self.appUserID = appUserID
    self.offeringID = offeringID
    self.packageID = packageID
    self.stateNonce = stateNonce
    self.expiresAt = expiresAt
  }
}

public struct CheckoutLinkRequest: Equatable, Sendable {
  public let session: AccountSession
  public let installationID: InstallationID
  public let offeringID: OfferingID
  public let packageID: PackageID

  public init(session: AccountSession, installationID: InstallationID, offeringID: OfferingID, packageID: PackageID) {
    self.session = session
    self.installationID = installationID
    self.offeringID = offeringID
    self.packageID = packageID
  }
}

public protocol CheckoutLinkResolving {
  func hostedCheckoutLink(for request: CheckoutLinkRequest) throws -> HostedCheckoutLink
}

public enum BillingEvent: Equatable, Sendable {
  case checkoutOpened(HostedCheckoutLink)
  case purchasePending
  case purchaseCompleted(EntitlementDecision)
  case restoreCompleted(EntitlementDecision)
  case failed(String)
}

public final class BillingCoordinator {
  private let checkoutResolver: CheckoutLinkResolving
  private let browser: SystemBrowserOpening

  public private(set) var events: [BillingEvent] = []

  public init(checkoutResolver: CheckoutLinkResolving, browser: SystemBrowserOpening) {
    self.checkoutResolver = checkoutResolver
    self.browser = browser
  }

  @discardableResult
  public func beginHostedCheckout(
    session: AccountSession,
    installationID: InstallationID,
    offeringID: OfferingID,
    packageID: PackageID
  ) throws -> HostedCheckoutLink {
    let link = try checkoutResolver.hostedCheckoutLink(for: CheckoutLinkRequest(
      session: session,
      installationID: installationID,
      offeringID: offeringID,
      packageID: packageID
    ))
    guard link.appUserID == session.identity.revenueCatAppUserID else {
      throw PaidLaunchValidationError.invalid("checkout link App User ID did not match authenticated account")
    }
    try browser.openSystemBrowser(url: link.url)
    events.append(.checkoutOpened(link))
    return link
  }

  public func recordCheckoutPending() {
    events.append(.purchasePending)
  }

  public func recordPurchaseRefresh(_ decision: EntitlementDecision) {
    events.append(.purchaseCompleted(decision))
  }

  public func recordRestoreRefresh(_ decision: EntitlementDecision) {
    events.append(.restoreCompleted(decision))
  }
}

public enum BillingLabScenario: String, Codable, Sendable {
  case successfulPurchase
  case canceledCheckout
  case failedRenewal
  case refund
  case providerOutage
}

public struct BillingLabConfiguration: Equatable, Sendable {
  public let enabled: Bool
  public let scenario: BillingLabScenario?

  public init(enabled: Bool, scenario: BillingLabScenario?) {
    self.enabled = enabled
    self.scenario = scenario
  }
}

public enum BillingLabGuard {
  public static func validate(_ configuration: BillingLabConfiguration, buildFlavor: BuildFlavor) -> Bool {
    if buildFlavor == .stable && configuration.enabled {
      return false
    }
    if configuration.enabled {
      return configuration.scenario != nil
    }
    return true
  }
}

public enum PaywallTextRole: String, Codable, Sendable {
  case headline
  case subheadline
  case priceDisclosure
  case renewalDisclosure
  case restore
  case support
}

public struct PaywallCopyBlock: Codable, Hashable, Sendable {
  public let role: PaywallTextRole
  public let text: String

  public init(role: PaywallTextRole, text: String) throws {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw PaidLaunchValidationError.empty("paywall copy")
    }
    self.role = role
    self.text = text
  }
}

public enum PaywallComponent: String, Codable, Sendable {
  case headline
  case planPicker
  case checkoutButton
  case restoreButton
  case legalDisclosure
  case supportLink
}

public struct PaywallLayout: Codable, Hashable, Sendable {
  public let components: [PaywallComponent]

  public init(components: [PaywallComponent]) throws {
    guard components.contains(.planPicker) else { throw PaidLaunchValidationError.invalid("paywall layout requires planPicker") }
    guard components.contains(.restoreButton) else { throw PaidLaunchValidationError.invalid("paywall layout requires restoreButton") }
    self.components = components
  }
}

public struct PaywallPackage: Codable, Hashable, Sendable {
  public let packageID: PackageID
  public let productID: ProductID
  public let displayName: String

  public init(packageID: PackageID, productID: ProductID, displayName: String) throws {
    guard !displayName.isEmpty else { throw PaidLaunchValidationError.empty("displayName") }
    self.packageID = packageID
    self.productID = productID
    self.displayName = displayName
  }
}

public struct PaywallTargeting: Codable, Hashable, Sendable {
  public let countryCode: String?
  public let minimumAppVersion: String?
  public let channel: ReleaseChannel?

  public init(countryCode: String?, minimumAppVersion: String?, channel: ReleaseChannel?) {
    self.countryCode = countryCode
    self.minimumAppVersion = minimumAppVersion
    self.channel = channel
  }
}

public struct RemotePaywallConfiguration: Codable, Hashable, Sendable {
  public let schemaVersion: Int
  public let offeringID: OfferingID
  public let variantID: VariantID
  public let copy: [PaywallCopyBlock]
  public let layout: PaywallLayout
  public let packages: [PaywallPackage]
  public let targeting: PaywallTargeting
  public let unknownFieldNames: [String]

  public init(
    schemaVersion: Int,
    offeringID: OfferingID,
    variantID: VariantID,
    copy: [PaywallCopyBlock],
    layout: PaywallLayout,
    packages: [PaywallPackage],
    targeting: PaywallTargeting,
    unknownFieldNames: [String] = []
  ) throws {
    guard schemaVersion == 1 else { throw PaidLaunchValidationError.invalid("unsupported paywall schema") }
    guard !copy.isEmpty else { throw PaidLaunchValidationError.empty("copy") }
    guard !packages.isEmpty else { throw PaidLaunchValidationError.empty("packages") }
    self.schemaVersion = schemaVersion
    self.offeringID = offeringID
    self.variantID = variantID
    self.copy = copy
    self.layout = layout
    self.packages = packages
    self.targeting = targeting
    self.unknownFieldNames = unknownFieldNames
  }
}

public struct PaywallValidationPolicy: Sendable {
  public let approvedProductIDs: Set<ProductID>
  public let approvedComponents: Set<PaywallComponent>
  public let requireRestoreVisible: Bool

  public init(
    approvedProductIDs: Set<ProductID>,
    approvedComponents: Set<PaywallComponent>,
    requireRestoreVisible: Bool = true
  ) {
    self.approvedProductIDs = approvedProductIDs
    self.approvedComponents = approvedComponents
    self.requireRestoreVisible = requireRestoreVisible
  }
}

public enum RemoteConfigurationValidator {
  public static func validatePaywall(
    _ configuration: RemotePaywallConfiguration,
    policy: PaywallValidationPolicy
  ) -> Bool {
    guard configuration.unknownFieldNames.isEmpty else { return false }
    let componentSet = Set(configuration.layout.components)
    guard componentSet.isSubset(of: policy.approvedComponents) else { return false }
    if policy.requireRestoreVisible && !componentSet.contains(.restoreButton) {
      return false
    }
    for package in configuration.packages where !policy.approvedProductIDs.contains(package.productID) {
      return false
    }
    return true
  }
}

public protocol PaywallConfigurationFetching {
  func paywallConfigurations(
    accountID: StableAccountID,
    offeringID: OfferingID,
    channel: ReleaseChannel
  ) throws -> [RemotePaywallConfiguration]
}

public protocol PaywallVariantAssignmentStoring {
  func variantID(accountID: StableAccountID, offeringID: OfferingID) -> VariantID?
  func setVariantID(_ variantID: VariantID, accountID: StableAccountID, offeringID: OfferingID)
}

public final class InMemoryPaywallVariantAssignmentStore: PaywallVariantAssignmentStoring {
  private var assignments: [String: VariantID] = [:]

  public init() {}

  public func variantID(accountID: StableAccountID, offeringID: OfferingID) -> VariantID? {
    assignments[key(accountID, offeringID)]
  }

  public func setVariantID(_ variantID: VariantID, accountID: StableAccountID, offeringID: OfferingID) {
    assignments[key(accountID, offeringID)] = variantID
  }

  private func key(_ accountID: StableAccountID, _ offeringID: OfferingID) -> String {
    "\(accountID.rawValue)|\(offeringID.rawValue)"
  }
}

public final class PaywallCoordinator {
  private let fetcher: PaywallConfigurationFetching
  private let assignmentStore: PaywallVariantAssignmentStoring
  private let validationPolicy: PaywallValidationPolicy

  public init(
    fetcher: PaywallConfigurationFetching,
    assignmentStore: PaywallVariantAssignmentStoring,
    validationPolicy: PaywallValidationPolicy
  ) {
    self.fetcher = fetcher
    self.assignmentStore = assignmentStore
    self.validationPolicy = validationPolicy
  }

  public func configuration(
    accountID: StableAccountID,
    offeringID: OfferingID,
    channel: ReleaseChannel
  ) throws -> RemotePaywallConfiguration {
    let candidates = try fetcher.paywallConfigurations(accountID: accountID, offeringID: offeringID, channel: channel)
      .filter { $0.offeringID == offeringID }
      .filter { RemoteConfigurationValidator.validatePaywall($0, policy: validationPolicy) }
    guard !candidates.isEmpty else { throw PaidLaunchValidationError.invalid("no approved paywall configuration available") }

    if let assigned = assignmentStore.variantID(accountID: accountID, offeringID: offeringID),
       let existing = candidates.first(where: { $0.variantID == assigned }) {
      return existing
    }

    let selected = candidates.sorted { $0.variantID.rawValue < $1.variantID.rawValue }[0]
    assignmentStore.setVariantID(selected.variantID, accountID: accountID, offeringID: offeringID)
    return selected
  }
}
