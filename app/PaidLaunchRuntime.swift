import AppKit
import CryptoKit
import Foundation
import Security
import SwiftUI

private enum PaidLaunchRuntimeError: Error, CustomStringConvertible {
  case notConfigured(String)
  case invalidResponse(String)
  case service(String, Int)
  case signedOut

  var description: String {
    switch self {
    case .notConfigured(let reason): return reason
    case .invalidResponse(let reason): return reason
    case .service(let code, let status): return "Service error \(code) (HTTP \(status))"
    case .signedOut: return "Sign in to continue."
    }
  }
}

struct PaidLaunchAppConfiguration {
  let enabled: Bool
  let environment: String
  let buildFlavor: BuildFlavor
  let supabaseURL: URL?
  let supabasePublishableKey: String
  let checkEmailURL: URL
  let callbackScheme: String
  let entitlementIssuer: String
  let entitlementAudience: String
  let entitlementPublicKeys: String
  let channel: ReleaseChannel

  static func fromBundle(_ bundle: Bundle = .main) -> PaidLaunchAppConfiguration {
    func string(_ key: String, _ fallback: String = "") -> String {
      (bundle.object(forInfoDictionaryKey: key) as? String) ?? fallback
    }
    let flavor = BuildFlavor(rawValue: string("DDumpPaidBuildFlavor", "debug")) ?? .debug
    let updatePreferences = readShellEnv(at: DDumpPaths.configFile)
    let updateChannel = DDumpSparkleUpdateBridge.betaUpdatesEligible &&
        updatePreferences["BETA_UPDATES_OPT_IN"] == "1"
      ? ReleaseChannel.beta
      : ReleaseChannel.stable
    return PaidLaunchAppConfiguration(
      enabled: bundle.object(forInfoDictionaryKey: "DDumpPaidLaunchEnabled") as? Bool == true,
      environment: string("DDumpPaidEnvironment", "test") == "production" ? "production" : "test",
      buildFlavor: flavor,
      supabaseURL: URL(string: string("DDumpSupabaseURL")),
      supabasePublishableKey: string("DDumpSupabasePublishableKey"),
      checkEmailURL: URL(string: string("DDumpCheckEmailURL", "https://ddump.app/account/check-email"))!,
      callbackScheme: string("DDumpAuthCallbackScheme", "ddump"),
      entitlementIssuer: string("DDumpEntitlementIssuer", "https://api.ddump.app"),
      entitlementAudience: string("DDumpEntitlementAudience", "com.ddump.app"),
      entitlementPublicKeys: string("DDumpEntitlementPublicKeys"),
      channel: updateChannel
    )
  }

  var missingConfiguration: [String] {
    var missing: [String] = []
    if supabaseURL?.scheme != "https" { missing.append("Supabase HTTPS URL") }
    if supabasePublishableKey.isEmpty { missing.append("Supabase publishable key") }
    if entitlementPublicKeys.isEmpty { missing.append("entitlement public key") }
    return missing
  }
}

private final class AppKitSystemBrowser: SystemBrowserOpening {
  func openSystemBrowser(url: URL) throws {
    guard NSWorkspace.shared.open(url) else {
      throw PaidLaunchRuntimeError.invalidResponse("The system browser could not open the secure URL.")
    }
  }
}

private final class SynchronousJSONHTTPClient {
  struct HTTPResult {
    let status: Int
    let json: [String: Any]
  }

  func send(
    _ url: URL,
    method: String = "POST",
    headers: [String: String],
    body: [String: Any],
    timeout: TimeInterval = 30
  ) throws -> HTTPResult {
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.timeoutInterval = timeout
    request.setValue("application/json", forHTTPHeaderField: "content-type")
    request.setValue("application/json", forHTTPHeaderField: "accept")
    headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
    request.httpBody = try JSONSerialization.data(withJSONObject: body)

    let semaphore = DispatchSemaphore(value: 0)
    var responseData: Data?
    var responseStatus = 0
    var responseError: Error?
    URLSession.shared.dataTask(with: request) { data, response, error in
      responseData = data
      responseStatus = (response as? HTTPURLResponse)?.statusCode ?? 0
      responseError = error
      semaphore.signal()
    }.resume()
    if semaphore.wait(timeout: .now() + timeout + 2) == .timedOut {
      throw PaidLaunchRuntimeError.service("request_timed_out", 0)
    }
    if responseError != nil {
      throw PaidLaunchRuntimeError.service("network_unavailable", responseStatus)
    }
    let json = responseData.flatMap {
      try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
    } ?? [:]
    guard (200..<300).contains(responseStatus) else {
      let code = (json["error"] as? String) ?? "request_failed"
      throw PaidLaunchRuntimeError.service(code, responseStatus)
    }
    return HTTPResult(status: responseStatus, json: json)
  }
}

private final class SupabasePasswordlessAuthService: PasswordlessAuthServicing {
  private let configuration: PaidLaunchAppConfiguration
  private let http: SynchronousJSONHTTPClient

  init(configuration: PaidLaunchAppConfiguration, http: SynchronousJSONHTTPClient) {
    self.configuration = configuration
    self.http = http
  }

  func beginPasswordlessSignIn(email: String, installationID: InstallationID) throws -> PasswordlessSignInStart {
    guard let baseURL = configuration.supabaseURL else {
      throw PaidLaunchRuntimeError.notConfigured("Supabase is not configured.")
    }
    let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard normalizedEmail.contains("@"), normalizedEmail.count <= 254 else {
      throw PaidLaunchRuntimeError.invalidResponse("Enter a valid email address.")
    }
    let state = randomBase64URL(byteCount: 24)
    let verifier = randomBase64URL(byteCount: 48)
    let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
    var callback = URLComponents()
    callback.scheme = configuration.callbackScheme
    callback.host = "auth"
    callback.path = "/callback"
    callback.queryItems = [URLQueryItem(name: "state", value: state)]
    guard let callbackURL = callback.url else {
      throw PaidLaunchRuntimeError.invalidResponse("The authentication callback could not be created.")
    }
    _ = try http.send(
      baseURL.appendingPathComponent("auth/v1/otp"),
      headers: publicHeaders(),
      body: [
        "email": normalizedEmail,
        "create_user": true,
        "code_challenge": challenge,
        "code_challenge_method": "s256",
        "options": ["email_redirect_to": callbackURL.absoluteString],
      ]
    )
    var checkEmail = URLComponents(url: configuration.checkEmailURL, resolvingAgainstBaseURL: false)!
    checkEmail.queryItems = [URLQueryItem(name: "flow", value: state)]
    return try PasswordlessSignInStart(
      flowID: UUID().uuidString,
      authorizationURL: checkEmail.url!,
      state: state,
      pkceVerifier: verifier,
      expiresAt: Date().addingTimeInterval(15 * 60)
    )
  }

  func redeemPasswordlessCallback(
    _ callback: AuthCallback,
    pendingFlow: PasswordlessSignInStart
  ) throws -> AccountSession {
    guard let code = callback.queryValue(named: "code"), !code.isEmpty else {
      throw PaidLaunchRuntimeError.invalidResponse("The sign-in callback did not contain an authorization code.")
    }
    return try exchangeToken(body: [
      "auth_code": code,
      "code_verifier": pendingFlow.pkceVerifier,
    ], grantType: "pkce")
  }

  func refreshSession(_ session: AccountSession) throws -> AccountSession {
    guard let refreshToken = session.refreshToken, !refreshToken.isEmpty else {
      throw PaidLaunchRuntimeError.signedOut
    }
    return try exchangeToken(body: ["refresh_token": refreshToken], grantType: "refresh_token")
  }

  func logout(_ session: AccountSession) throws {
    guard let baseURL = configuration.supabaseURL else { return }
    _ = try http.send(
      baseURL.appendingPathComponent("auth/v1/logout"),
      headers: publicHeaders(accessToken: session.accessToken),
      body: [:]
    )
  }

  private func exchangeToken(body: [String: Any], grantType: String) throws -> AccountSession {
    guard let baseURL = configuration.supabaseURL,
          var components = URLComponents(
            url: baseURL.appendingPathComponent("auth/v1/token"),
            resolvingAgainstBaseURL: false
          ) else {
      throw PaidLaunchRuntimeError.notConfigured("Supabase is not configured.")
    }
    components.queryItems = [URLQueryItem(name: "grant_type", value: grantType)]
    let response = try http.send(components.url!, headers: publicHeaders(), body: body).json
    guard let accessToken = response["access_token"] as? String,
          let user = response["user"] as? [String: Any],
          let subject = user["id"] as? String else {
      throw PaidLaunchRuntimeError.invalidResponse("The authentication service returned an incomplete session.")
    }
    let profile = try http.send(
      baseURL.appendingPathComponent("functions/v1/account-profile"),
      headers: publicHeaders(accessToken: accessToken),
      body: ["action": "read"]
    ).json
    guard let accountID = profile["account_id"] as? String,
          let revenueCatID = profile["revenuecat_app_user_id"] as? String else {
      throw PaidLaunchRuntimeError.invalidResponse("The account profile was incomplete.")
    }
    let betaUpdatesEligible = profile["beta_updates_eligible"] as? Bool == true
    DDumpSparkleUpdateBridge.setBetaUpdatesEligible(betaUpdatesEligible)
    if !betaUpdatesEligible {
      writeShellConfig(key: "BETA_UPDATES_OPT_IN", value: "0", at: DDumpPaths.configFile)
    }
    let identity = AccountIdentity(
      accountID: try StableAccountID(accountID),
      providerSubjectID: try ProviderSubjectID(provider: "supabase", subject: subject),
      revenueCatAppUserID: try RevenueCatAppUserID(revenueCatID),
      stripeCustomerID: try (profile["stripe_customer_id"] as? String).map(StripeCustomerID.init)
    )
    let expiresIn = (response["expires_in"] as? NSNumber)?.doubleValue ?? 3600
    return try AccountSession(
      identity: identity,
      accessToken: accessToken,
      refreshToken: response["refresh_token"] as? String,
      expiresAt: Date().addingTimeInterval(max(60, expiresIn - 30))
    )
  }

  private func publicHeaders(accessToken: String? = nil) -> [String: String] {
    var headers = ["apikey": configuration.supabasePublishableKey]
    if let accessToken { headers["authorization"] = "Bearer \(accessToken)" }
    return headers
  }

  private func randomBase64URL(byteCount: Int) -> String {
    var bytes = [UInt8](repeating: 0, count: byteCount)
    _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    return Data(bytes).base64URLEncodedString()
  }
}

private struct StoredInstallationIdentity: Codable {
  let privateKey: Data
  var installationID: String?
}

private final class InstallationIdentityManager {
  private let box: CodableKeychainBox<StoredInstallationIdentity>

  init(store: KeychainValueStore) {
    box = CodableKeychainBox(key: "installation-identity-v1", store: store)
  }

  func identity() throws -> StoredInstallationIdentity {
    if let existing = try box.load() { return existing }
    let created = StoredInstallationIdentity(
      privateKey: Curve25519.Signing.PrivateKey().rawRepresentation,
      installationID: nil
    )
    try box.save(created)
    return created
  }

  func bind(installationID: String) throws -> StoredInstallationIdentity {
    let current = try identity()
    let updated = StoredInstallationIdentity(
      privateKey: current.privateKey,
      installationID: installationID
    )
    try box.save(updated)
    return updated
  }

  func publicKeyHash() throws -> Data {
    let key = try Curve25519.Signing.PrivateKey(rawRepresentation: identity().privateKey)
    return Data(SHA256.hash(data: key.publicKey.rawRepresentation))
  }

  func publicKeyHashHex() throws -> String {
    try publicKeyHash().map { String(format: "%02x", $0) }.joined()
  }

  func provisionalID() throws -> InstallationID {
    try InstallationID("local-\(publicKeyHashHex().prefix(24))")
  }
}

struct PaidBillingPackage: Codable, Identifiable, Hashable {
  let packageID: String
  let productID: String
  let displayName: String
  let displayAmount: String
  let cadence: String
  let trialDisclosure: String
  let renewalDisclosure: String
  let taxDisclosure: String
  let cancellationDisclosure: String

  var id: String { packageID }

  enum CodingKeys: String, CodingKey {
    case packageID = "package_id"
    case productID = "product_id"
    case displayName = "display_name"
    case displayAmount = "display_amount"
    case cadence
    case trialDisclosure = "trial_disclosure"
    case renewalDisclosure = "renewal_disclosure"
    case taxDisclosure = "tax_disclosure"
    case cancellationDisclosure = "cancellation_disclosure"
  }
}

struct PaidBillingVariant: Codable, Identifiable, Hashable {
  let offeringID: String
  let variantID: String
  let experimentID: String?

  var id: String { "\(offeringID)|\(variantID)" }
  var label: String {
    if let experimentID, !experimentID.isEmpty {
      return "\(offeringID) / \(variantID) (\(experimentID))"
    }
    return "\(offeringID) / \(variantID)"
  }

  enum CodingKeys: String, CodingKey {
    case offeringID = "offering_id"
    case variantID = "variant_id"
    case experimentID = "experiment_id"
  }
}

private struct PaidBillingCatalog: Codable {
  let environment: String
  let offeringID: String
  let variantID: String
  let experimentID: String?
  let packages: [PaidBillingPackage]
  let customerPortalAvailable: Bool

  enum CodingKeys: String, CodingKey {
    case environment
    case offeringID = "offering_id"
    case variantID = "variant_id"
    case experimentID = "experiment_id"
    case packages
    case customerPortalAvailable = "customer_portal_available"
  }
}

private final class BackendCheckoutLinkResolver: CheckoutLinkResolving {
  private let configuration: PaidLaunchAppConfiguration
  private let http: SynchronousJSONHTTPClient

  init(configuration: PaidLaunchAppConfiguration, http: SynchronousJSONHTTPClient) {
    self.configuration = configuration
    self.http = http
  }

  func hostedCheckoutLink(for request: CheckoutLinkRequest) throws -> HostedCheckoutLink {
    let json = try callFunction(
      "billing-session",
      token: request.session.accessToken,
      body: ["action": "checkout", "package_id": request.packageID.rawValue]
    )
    guard let rawURL = json["checkout_url"] as? String,
          let url = URL(string: rawURL),
          let appUserID = json["revenuecat_app_user_id"] as? String,
          let offeringID = json["offering_id"] as? String,
          let nonce = json["state_nonce"] as? String,
          let expires = json["expires_at"] as? String,
          let expiresAt = ISO8601DateFormatter().date(from: expires) else {
      throw PaidLaunchRuntimeError.invalidResponse("The hosted checkout link was incomplete.")
    }
    return try HostedCheckoutLink(
      url: url,
      appUserID: RevenueCatAppUserID(appUserID),
      offeringID: OfferingID(offeringID),
      packageID: request.packageID,
      stateNonce: nonce,
      expiresAt: expiresAt
    )
  }

  func callFunction(_ name: String, token: String, body: [String: Any]) throws -> [String: Any] {
    guard let baseURL = configuration.supabaseURL else {
      throw PaidLaunchRuntimeError.notConfigured("Supabase is not configured.")
    }
    return try http.send(
      baseURL.appendingPathComponent("functions/v1/\(name)"),
      headers: [
        "apikey": configuration.supabasePublishableKey,
        "authorization": "Bearer \(token)",
        "x-ddump-build-flavor": configuration.buildFlavor.rawValue,
      ],
      body: body
    ).json
  }
}

private final class BackendEntitlementRefresher: EntitlementRefreshing {
  private let configuration: PaidLaunchAppConfiguration
  private let resolver: BackendCheckoutLinkResolver
  private let installationPublicKeyHashHex: String
  private(set) var lastCompactToken: String?

  init(
    configuration: PaidLaunchAppConfiguration,
    resolver: BackendCheckoutLinkResolver,
    installationPublicKeyHashHex: String
  ) {
    self.configuration = configuration
    self.resolver = resolver
    self.installationPublicKeyHashHex = installationPublicKeyHashHex
  }

  func refreshEntitlement(_ request: EntitlementRefreshRequest) throws -> RemoteEntitlementResult {
    do {
      let json = try resolver.callFunction(
        "entitlement-refresh",
        token: request.session.accessToken,
        body: [
          "installation_id": request.installationID.rawValue,
          "installation_public_key_sha256": installationPublicKeyHashHex,
          "product_id": request.productID.rawValue,
          "purpose": request.purpose.rawValue,
          "app_version": request.appVersion,
          "channel": request.channel.rawValue,
        ]
      )
      let result = json["result"] as? String
      if result == "valid", let token = json["entitlement_document"] as? String {
        let document = try BackendEntitlementJWSDecoder().decode(
          token,
          expectedIssuer: configuration.entitlementIssuer,
          expectedEnvironment: configuration.environment
        )
        lastCompactToken = token
        return .valid(document)
      }
      if result == "revoked" { return .revoked(.terminalStatus(.revoked)) }
      return .indeterminate(.serviceUnavailable)
    } catch PaidLaunchRuntimeError.service(_, let status) where status == 0 || status >= 500 {
      return .indeterminate(.serviceUnavailable)
    }
  }
}

final class PaidLaunchRuntime: ObservableObject {
  static let shared = PaidLaunchRuntime()

  @Published private(set) var sessionState = "Signed out"
  @Published private(set) var accountID = ""
  @Published private(set) var entitlementState = "Not checked"
  @Published private(set) var statusMessage = ""
  @Published private(set) var packages: [PaidBillingPackage] = []
  @Published private(set) var offeringID = ""
  @Published private(set) var variantID = ""
  @Published private(set) var experimentID = ""
  @Published private(set) var portalAvailable = false
  @Published private(set) var availableTestVariants: [PaidBillingVariant] = []
  @Published private(set) var availableTestScenarios: [String] = []
  @Published private(set) var busy = false

  let configuration: PaidLaunchAppConfiguration

  private let queue = DispatchQueue(label: "com.ddump.paid-launch", qos: .userInitiated)
  private let http = SynchronousJSONHTTPClient()
  private let keychain = SecurityKeychainValueStore()
  private let browser = AppKitSystemBrowser()
  private let installationManager: InstallationIdentityManager
  private let accountCoordinator: AccountCoordinator
  private let checkoutResolver: BackendCheckoutLinkResolver
  private let billingCoordinator: BillingCoordinator
  private var checkoutPollGeneration = UUID()

  private init(configuration: PaidLaunchAppConfiguration = .fromBundle()) {
    self.configuration = configuration
    installationManager = InstallationIdentityManager(store: keychain)
    let auth = SupabasePasswordlessAuthService(configuration: configuration, http: http)
    accountCoordinator = AccountCoordinator(
      authService: auth,
      browser: browser,
      sessionBox: CodableKeychainBox(key: "account-session-v1", store: keychain),
      pendingFlowBox: CodableKeychainBox(key: "pending-auth-flow-v1", store: keychain),
      clock: SystemPaidLaunchClock()
    )
    checkoutResolver = BackendCheckoutLinkResolver(configuration: configuration, http: http)
    billingCoordinator = BillingCoordinator(checkoutResolver: checkoutResolver, browser: browser)
    updatePublishedAccountState()
  }

  var isVisible: Bool { configuration.enabled }
  var billingLabVisible: Bool { configuration.buildFlavor != .stable }
  var environmentLabel: String { configuration.environment }
  var buildFlavorLabel: String { configuration.buildFlavor.rawValue }

  func beginSignIn(email: String) {
    run("Sending secure sign-in link…") { [self] in
      _ = try accountCoordinator.beginPasswordlessSignIn(
        email: email,
        installationID: installationManager.provisionalID()
      )
      return "Check your email. The secure link opens in your browser and returns to DDump."
    }
  }

  func handleOpenURL(_ url: URL) {
    guard url.scheme == configuration.callbackScheme,
          url.host == "auth",
          url.path == "/callback" else { return }
    run("Finishing sign in…") { [self] in
      _ = try accountCoordinator.handleSystemBrowserCallback(AuthCallback(url: url, receivedAt: Date()))
      _ = try loadCatalogAndRefreshEntitlement(purpose: .secondMac)
      return "Signed in. Purchases and authorized Macs are linked to this account."
    }
  }

  func refreshAccount() {
    run("Refreshing account and paywall…") { [self] in
      _ = try loadCatalogAndRefreshEntitlement(purpose: .periodic)
      return "Account and remote billing configuration refreshed."
    }
  }

  func beginCheckout(package: PaidBillingPackage) {
    run("Opening RevenueCat hosted checkout…") { [self] in
      guard let session = try accountCoordinator.currentSession() else {
        throw PaidLaunchRuntimeError.signedOut
      }
      let installationID = try authorizeInstallation(session: session)
      _ = try billingCoordinator.beginHostedCheckout(
        session: session,
        installationID: installationID,
        offeringID: try OfferingID(offeringID),
        packageID: try PackageID(package.packageID)
      )
      billingCoordinator.recordCheckoutPending()
      scheduleCheckoutPolling()
      return "Checkout opened in your browser. DDump will refresh after RevenueCat confirms the purchase."
    }
  }

  func restorePurchases() {
    run("Restoring purchases and authorizing this Mac…") { [self] in
      _ = try loadCatalogAndRefreshEntitlement(purpose: .restore)
      return "Restore finished. The entitlement shown here is server-authoritative."
    }
  }

  func setBillingLabOverride(_ variant: PaidBillingVariant) {
    guard billingLabVisible else { return }
    run("Applying approved test paywall variant…") { [self] in
      guard let session = try accountCoordinator.currentSession() else {
        throw PaidLaunchRuntimeError.signedOut
      }
      _ = try checkoutResolver.callFunction(
        "billing-session",
        token: session.accessToken,
        body: [
          "action": "set_test_override",
          "offering_id": variant.offeringID,
          "variant_id": variant.variantID,
        ]
      )
      _ = try loadCatalogAndRefreshEntitlement(purpose: .periodic)
      return "Approved test variant applied for 24 hours."
    }
  }

  func runBillingLabScenario(_ scenario: String) {
    guard billingLabVisible, availableTestScenarios.contains(scenario) else { return }
    run("Applying approved Billing Lab scenario…") { [self] in
      guard let session = try accountCoordinator.currentSession() else {
        throw PaidLaunchRuntimeError.signedOut
      }
      guard let productID = packages.first?.productID else {
        throw PaidLaunchRuntimeError.invalidResponse("Load an approved test catalog first.")
      }
      _ = try checkoutResolver.callFunction(
        "billing-session",
        token: session.accessToken,
        body: [
          "action": "set_test_scenario",
          "scenario": scenario,
          "product_id": productID,
        ]
      )
      _ = try loadCatalogAndRefreshEntitlement(purpose: scenario == "restore" ? .restore : .periodic)
      return "Billing Lab scenario applied: \(scenario.replacingOccurrences(of: "_", with: " "))."
    }
  }

  func openCustomerPortal() {
    run("Opening customer portal…") { [self] in
      guard let session = try accountCoordinator.currentSession() else {
        throw PaidLaunchRuntimeError.signedOut
      }
      let json = try checkoutResolver.callFunction(
        "billing-session",
        token: session.accessToken,
        body: ["action": "portal"]
      )
      guard let rawURL = json["customer_portal_url"] as? String,
            let url = URL(string: rawURL) else {
        throw PaidLaunchRuntimeError.invalidResponse("The customer portal is not configured.")
      }
      try browser.openSystemBrowser(url: url)
      return "Customer portal opened in your browser."
    }
  }

  func signOut() {
    run("Signing out…") { [self] in
      let safeIdle = !FileManager.default.fileExists(atPath: DDumpPaths.lockDir.path)
      guard try accountCoordinator.logoutWhenSafe(isSafeIdle: safeIdle) else {
        return "Sign-out is waiting for active card work to reach safe idle."
      }
      return "Signed out. Existing files, receipts, logs, and safe cleanup remain available."
    }
  }

  func requestAccountDeletion() {
    run("Submitting deletion request…") { [self] in
      guard let session = try accountCoordinator.currentSession() else {
        throw PaidLaunchRuntimeError.signedOut
      }
      _ = try checkoutResolver.callFunction(
        "account-profile",
        token: session.accessToken,
        body: ["action": "request_deletion"]
      )
      return "Deletion request submitted for support-safe processing and required billing-record retention."
    }
  }

  private func loadCatalogAndRefreshEntitlement(
    purpose: EntitlementRefreshPurpose
  ) throws -> Bool {
    guard configuration.enabled else {
      throw PaidLaunchRuntimeError.notConfigured("Paid launch is disabled in this build.")
    }
    if !configuration.missingConfiguration.isEmpty {
      throw PaidLaunchRuntimeError.notConfigured(
        "Test-mode setup is incomplete: \(configuration.missingConfiguration.joined(separator: ", "))."
      )
    }
    guard let session = try accountCoordinator.currentSession() else {
      throw PaidLaunchRuntimeError.signedOut
    }
    let installationID = try authorizeInstallation(session: session)
    try refreshBetaUpdateEligibility(session: session)
    let catalogJSON = try checkoutResolver.callFunction(
      "billing-session",
      token: session.accessToken,
      body: ["action": "catalog"]
    )
    guard let rawCatalog = catalogJSON["catalog"],
          JSONSerialization.isValidJSONObject(rawCatalog) else {
      throw PaidLaunchRuntimeError.invalidResponse("The billing catalog was incomplete.")
    }
    let catalogData = try JSONSerialization.data(withJSONObject: rawCatalog)
    let catalog = try JSONDecoder().decode(PaidBillingCatalog.self, from: catalogData)
    let testVariants: [PaidBillingVariant]
    if let rawVariants = catalogJSON["available_test_variants"],
       JSONSerialization.isValidJSONObject(rawVariants) {
      let data = try JSONSerialization.data(withJSONObject: rawVariants)
      testVariants = (try? JSONDecoder().decode([PaidBillingVariant].self, from: data)) ?? []
    } else {
      testVariants = []
    }
    let testScenarios = catalogJSON["available_test_scenarios"] as? [String] ?? []
    guard catalog.environment == configuration.environment else {
      throw PaidLaunchRuntimeError.invalidResponse("The billing environment did not match this build.")
    }

    let publicKeyHash = try installationManager.publicKeyHash()
    let keyProvider = try entitlementKeyProvider()
    let replayProtector = KeychainEntitlementReplayProtector(store: keychain)
    let verifier = EntitlementVerifier(
      keyProvider: keyProvider,
      signatureVerifier: CryptoKitEntitlementSignatureVerifier(),
      replayProtector: replayProtector
    )
    let refresher = BackendEntitlementRefresher(
      configuration: configuration,
      resolver: checkoutResolver,
      installationPublicKeyHashHex: try installationManager.publicKeyHashHex()
    )
    let client = EntitlementClient(
      refresher: refresher,
      verifier: verifier,
      store: KeychainEntitlementDocumentStore(
        box: CodableKeychainBox(key: "signed-entitlement-v1", store: keychain)
      ),
      audience: configuration.entitlementAudience,
      installationPublicKeyHash: publicKeyHash,
      clock: SystemPaidLaunchClock()
    )

    var finalDecision: EntitlementDecision = .revoked(.terminalStatus(.revoked))
    for item in catalog.packages {
      let productID = try ProductID(item.productID)
      let decision: EntitlementDecision
      switch purpose {
      case .restore:
        decision = try client.restore(
          session: session,
          installationID: installationID,
          productID: productID,
          appVersion: appVersion,
          channel: selectedReleaseChannel
        )
      case .secondMac:
        decision = try client.activateSecondMac(
          session: session,
          installationID: installationID,
          productID: productID,
          appVersion: appVersion,
          channel: selectedReleaseChannel
        )
      default:
        decision = try client.refresh(
          session: session,
          installationID: installationID,
          productID: productID,
          purpose: purpose,
          appVersion: appVersion,
          channel: selectedReleaseChannel
        )
      }
      if case .valid(let verified) = decision {
        finalDecision = decision
        replayProtector.advanceMinimumIssueDate(
          verified.document.issuedAt,
          accountID: session.identity.accountID,
          installationID: installationID
        )
        if let token = refresher.lastCompactToken {
          try persistShellAccessState(
            token: token,
            session: session,
            installationID: installationID,
            installationPublicKeyHashHex: try installationManager.publicKeyHashHex(),
            minimumIssuedAt: verified.document.issuedAt,
            productIDs: catalog.packages.map(\.productID)
          )
        }
        break
      }
      if case .indeterminate = decision { finalDecision = decision }
    }

    DispatchQueue.main.async { [self] in
      packages = catalog.packages
      offeringID = catalog.offeringID
      variantID = catalog.variantID
      experimentID = catalog.experimentID ?? ""
      portalAvailable = catalog.customerPortalAvailable
      availableTestVariants = testVariants
      availableTestScenarios = testScenarios
      entitlementState = describe(finalDecision)
    }
    return finalDecision.permitsNewImports
  }

  private func scheduleCheckoutPolling() {
    let generation = UUID()
    checkoutPollGeneration = generation
    pollCheckout(generation: generation, remainingAttempts: 12)
  }

  private func pollCheckout(generation: UUID, remainingAttempts: Int) {
    guard remainingAttempts > 0 else {
      DispatchQueue.main.async { [weak self] in
        guard let self, self.checkoutPollGeneration == generation else { return }
        self.statusMessage = "Checkout was not confirmed. It may have been abandoned, declined, or delayed; use Restore purchases after checking the hosted page."
      }
      return
    }
    queue.asyncAfter(deadline: .now() + 10) { [weak self] in
      guard let self, self.checkoutPollGeneration == generation else { return }
      do {
        let active = try self.loadCatalogAndRefreshEntitlement(purpose: .purchase)
        if active {
          DispatchQueue.main.async {
            guard self.checkoutPollGeneration == generation else { return }
            self.statusMessage = "Purchase confirmed and signed entitlement refreshed."
          }
          return
        }
      } catch {
        DispatchQueue.main.async {
          guard self.checkoutPollGeneration == generation else { return }
          self.statusMessage = "Waiting for checkout confirmation; the billing service is temporarily unavailable."
        }
      }
      self.pollCheckout(generation: generation, remainingAttempts: remainingAttempts - 1)
    }
  }

  private func authorizeInstallation(session: AccountSession) throws -> InstallationID {
    let current = try installationManager.identity()
    if let installationID = current.installationID {
      return try InstallationID(installationID)
    }
    let response = try checkoutResolver.callFunction(
      "restore-device",
      token: session.accessToken,
      body: [
        "installation_public_key_sha256": try installationManager.publicKeyHashHex(),
        "device_label": Host.current().localizedName ?? "Mac",
      ]
    )
    guard let installationID = response["installation_id"] as? String else {
      throw PaidLaunchRuntimeError.invalidResponse("This Mac could not be authorized.")
    }
    _ = try installationManager.bind(installationID: installationID)
    return try InstallationID(installationID)
  }

  private var selectedReleaseChannel: ReleaseChannel {
    let preferences = readShellEnv(at: DDumpPaths.configFile)
    return DDumpSparkleUpdateBridge.betaUpdatesEligible &&
        preferences["BETA_UPDATES_OPT_IN"] == "1"
      ? .beta
      : .stable
  }

  private func refreshBetaUpdateEligibility(session: AccountSession) throws {
    let profile = try checkoutResolver.callFunction(
      "account-profile",
      token: session.accessToken,
      body: ["action": "read"]
    )
    let eligible = profile["beta_updates_eligible"] as? Bool == true
    DDumpSparkleUpdateBridge.setBetaUpdatesEligible(eligible)
    if !eligible {
      writeShellConfig(key: "BETA_UPDATES_OPT_IN", value: "0", at: DDumpPaths.configFile)
    }
    DispatchQueue.main.async {
      DDumpSparkleUpdateBridge.shared.refreshChannelSelection()
    }
  }

  private func entitlementKeyProvider() throws -> StaticEntitlementVerificationKeyProvider {
    let keys = configuration.entitlementPublicKeys.split(separator: ",").compactMap { pair -> EntitlementVerificationKey? in
      let parts = pair.split(separator: ":", maxSplits: 1).map(String.init)
      guard parts.count == 2,
            let keyID = try? EntitlementKeyID(parts[0]),
            let data = Data(base64URLOrStandardEncoded: parts[1]) else { return nil }
      return try? EntitlementVerificationKey(keyID: keyID, publicKey: data, revokedAt: nil)
    }
    guard !keys.isEmpty else {
      throw PaidLaunchRuntimeError.notConfigured("No trusted entitlement verification key is configured.")
    }
    return StaticEntitlementVerificationKeyProvider(keys: keys)
  }

  private func persistShellAccessState(
    token: String,
    session: AccountSession,
    installationID: InstallationID,
    installationPublicKeyHashHex: String,
    minimumIssuedAt: Date,
    productIDs: [String]
  ) throws {
    let stateRoot = DDumpPaths.appSupport.appendingPathComponent("state")
    let identityRoot = stateRoot.appendingPathComponent("identity")
    let entitlementRoot = stateRoot.appendingPathComponent("entitlements")
    try FileManager.default.createDirectory(at: identityRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try FileManager.default.createDirectory(at: entitlementRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try writeProtected(session.identity.accountID.rawValue, to: identityRoot.appendingPathComponent("account_id"))
    try writeProtected(installationID.rawValue, to: identityRoot.appendingPathComponent("installation_id"))
    try writeProtected(installationPublicKeyHashHex, to: identityRoot.appendingPathComponent("installation_public_key_sha256"))
    try writeProtected(token, to: entitlementRoot.appendingPathComponent("current.entitlement"))
    writeShellConfig(key: "ENTITLEMENT_PUBLIC_KEYS", value: configuration.entitlementPublicKeys, at: DDumpPaths.configFile)
    writeShellConfig(key: "ENTITLEMENT_ISSUER", value: configuration.entitlementIssuer, at: DDumpPaths.configFile)
    writeShellConfig(key: "ENTITLEMENT_AUDIENCE", value: configuration.entitlementAudience, at: DDumpPaths.configFile)
    writeShellConfig(key: "ENTITLEMENT_ENVIRONMENT", value: configuration.environment, at: DDumpPaths.configFile)
    writeShellConfig(key: "ENTITLEMENT_PRODUCT_IDS", value: productIDs.joined(separator: ","), at: DDumpPaths.configFile)
    writeShellConfig(
      key: "ENTITLEMENT_MINIMUM_ISSUED_AT",
      value: String(Int(minimumIssuedAt.timeIntervalSince1970)),
      at: DDumpPaths.configFile
    )
  }

  private func writeProtected(_ value: String, to url: URL) throws {
    try (value + "\n").write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }

  private func run(_ progress: String, operation: @escaping () throws -> String) {
    guard !busy else { return }
    busy = true
    statusMessage = progress
    queue.async { [weak self] in
      guard let self else { return }
      let result: Result<String, Error>
      do { result = .success(try operation()) }
      catch { result = .failure(error) }
      DispatchQueue.main.async {
        self.busy = false
        switch result {
        case .success(let message): self.statusMessage = message
        case .failure(let error): self.statusMessage = String(describing: error)
        }
        self.updatePublishedAccountState()
      }
    }
  }

  private func updatePublishedAccountState() {
    switch accountCoordinator.state {
    case .signedOut:
      sessionState = "Signed out"
      accountID = ""
    case .signInPending:
      sessionState = "Check your email"
    case .authenticated(let identity):
      sessionState = "Signed in"
      accountID = identity.accountID.rawValue
    case .refreshRequired(let identity):
      sessionState = "Session refresh needed"
      accountID = identity.accountID.rawValue
    case .failed(let reason):
      sessionState = "Sign-in failed"
      statusMessage = reason
    }
  }

  private func describe(_ decision: EntitlementDecision) -> String {
    switch decision {
    case .valid(let verified):
      if verified.isInOfflineGrace { return "Offline grace — refresh required" }
      if verified.requiresOnlineRefresh { return "Active — refresh due" }
      return "Active"
    case .indeterminate:
      return "Temporarily unavailable — new imports remain blocked when enforcement is enabled"
    case .revoked:
      return "No active entitlement"
    }
  }

  private var appVersion: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
  }
}

private extension Data {
  func base64URLEncodedString() -> String {
    base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  init?(base64URLOrStandardEncoded value: String) {
    var normalized = value.replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    if normalized.count % 4 != 0 {
      normalized += String(repeating: "=", count: 4 - normalized.count % 4)
    }
    self.init(base64Encoded: normalized)
  }
}
