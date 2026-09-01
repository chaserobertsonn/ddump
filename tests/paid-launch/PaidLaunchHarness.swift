import Foundation

final class TestRunner {
  private var failures: [String] = []

  func test(_ name: String, _ body: () throws -> Void) {
    do {
      try body()
      print("PASS \(name)")
    } catch {
      failures.append("\(name): \(error)")
      print("FAIL \(name): \(error)")
    }
  }

  func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
      throw TestFailure(message)
    }
  }

  func finish() -> Int32 {
    if failures.isEmpty {
      print("paid-launch harness: all tests passed")
      return 0
    }
    print("paid-launch harness: \(failures.count) failure(s)")
    for failure in failures {
      print(failure)
    }
    return 1
  }
}

struct TestFailure: Error, CustomStringConvertible {
  let description: String
  init(_ description: String) { self.description = description }
}

final class MutableClock: PaidLaunchClock {
  var now: Date
  var monotonicTime: TimeInterval

  init(now: Date) {
    self.now = now
    self.monotonicTime = 0
  }
}

final class CapturingBrowser: SystemBrowserOpening {
  private(set) var opened: [URL] = []

  func openSystemBrowser(url: URL) throws {
    opened.append(url)
  }
}

final class FakeAuthService: PasswordlessAuthServicing {
  let session: AccountSession
  var beganEmail: String?
  var loggedOut = false
  var flow: PasswordlessSignInStart!

  init(session: AccountSession, clock: PaidLaunchClock) throws {
    self.session = session
    self.flow = try PasswordlessSignInStart(
      flowID: "flow-1",
      authorizationURL: URL(string: "https://account.ddump.test/login?state=state-1")!,
      state: "state-1",
      pkceVerifier: "pkce-1",
      expiresAt: clock.now.addingTimeInterval(300)
    )
  }

  func beginPasswordlessSignIn(email: String, installationID: InstallationID) throws -> PasswordlessSignInStart {
    beganEmail = email
    return flow
  }

  func redeemPasswordlessCallback(_ callback: AuthCallback, pendingFlow: PasswordlessSignInStart) throws -> AccountSession {
    session
  }

  func refreshSession(_ session: AccountSession) throws -> AccountSession {
    session
  }

  func logout(_ session: AccountSession) throws {
    loggedOut = true
  }
}

final class FakeCheckoutResolver: CheckoutLinkResolving {
  var lastRequest: CheckoutLinkRequest?
  var link: HostedCheckoutLink!

  func hostedCheckoutLink(for request: CheckoutLinkRequest) throws -> HostedCheckoutLink {
    lastRequest = request
    return link
  }
}

final class FakeKeyProvider: EntitlementVerificationKeyProviding {
  var keys: [EntitlementKeyID: EntitlementVerificationKey] = [:]

  func verificationKey(for keyID: EntitlementKeyID) -> EntitlementVerificationKey? {
    keys[keyID]
  }
}

final class FakeEd25519Verifier: Ed25519SignatureVerifying {
  func verify(signature: Data, message: Data, publicKey: EntitlementVerificationKey) throws -> Bool {
    signature == Self.signature(for: message, keyID: publicKey.keyID)
  }

  static func signature(for message: Data, keyID: EntitlementKeyID) -> Data {
    Data("sig:\(keyID.rawValue):\(String(decoding: message, as: UTF8.self))".utf8)
  }
}

final class FakeEntitlementRefresher: EntitlementRefreshing {
  var results: [RemoteEntitlementResult] = []
  private(set) var requests: [EntitlementRefreshRequest] = []

  func refreshEntitlement(_ request: EntitlementRefreshRequest) throws -> RemoteEntitlementResult {
    requests.append(request)
    if results.isEmpty {
      return .indeterminate(.serviceUnavailable)
    }
    return results.removeFirst()
  }
}

final class FakeUpdateService: UpdateServicing {
  var checkResult: UpdateCheckResult = .notAvailable
  private(set) var downloaded: [UpdateManifest] = []
  private(set) var installed: [DownloadedUpdate] = []

  func checkForUpdate(channel: ReleaseChannel) throws -> UpdateCheckResult {
    checkResult
  }

  func download(_ manifest: UpdateManifest) throws -> DownloadedUpdate {
    downloaded.append(manifest)
    return try DownloadedUpdate(manifest: manifest, localArtifactID: "artifact-\(manifest.version)")
  }

  func installAndRelaunch(_ update: DownloadedUpdate) throws {
    installed.append(update)
  }
}

final class SequentialLeaseIDGenerator: ImportLeaseIDGenerating {
  private var next = 1

  func nextLeaseID() -> String {
    defer { next += 1 }
    return "lease-\(next)"
  }
}

final class FakePaywallFetcher: PaywallConfigurationFetching {
  var configurations: [RemotePaywallConfiguration] = []

  func paywallConfigurations(
    accountID: StableAccountID,
    offeringID: OfferingID,
    channel: ReleaseChannel
  ) throws -> [RemotePaywallConfiguration] {
    configurations
  }
}

@main
enum PaidLaunchHarness {
  static let baseDate = Date(timeIntervalSince1970: 1_800_000_000)
  static let audience = "com.ddump.app"

  static func main() {
    let runner = TestRunner()

    runner.test("passwordless sign-in uses system browser and keychain session") {
      let fixture = try Fixture()
      let browser = CapturingBrowser()
      let auth = try FakeAuthService(session: fixture.session, clock: fixture.clock)
      let box = CodableKeychainBox<AccountSession>(key: "session", store: InMemoryKeychainValueStore())
      let coordinator = AccountCoordinator(authService: auth, browser: browser, sessionBox: box, clock: fixture.clock)

      let start = try coordinator.beginPasswordlessSignIn(email: "chase@example.test", installationID: fixture.installationID)
      try runner.expect(browser.opened == [start.authorizationURL], "sign-in did not open the system browser")
      let callback = AuthCallback(url: URL(string: "ddump://auth/callback?state=state-1&code=handoff-code")!, receivedAt: fixture.clock.now)
      let session = try coordinator.handleSystemBrowserCallback(callback)
      try runner.expect(session.identity.accountID == fixture.accountID, "session account did not persist")
      let loadedSession = try box.load()
      try runner.expect(loadedSession?.identity.revenueCatAppUserID == fixture.appUserID, "RevenueCat App User ID was not stable")
    }

    runner.test("hosted checkout resolves for authenticated App User ID") {
      let fixture = try Fixture()
      let browser = CapturingBrowser()
      let resolver = FakeCheckoutResolver()
      resolver.link = try HostedCheckoutLink(
        url: URL(string: "https://pay.ddump.test/checkout?app_user_id=\(fixture.appUserID.rawValue)")!,
        appUserID: fixture.appUserID,
        offeringID: fixture.offeringID,
        packageID: fixture.monthlyPackageID,
        stateNonce: "checkout-state",
        expiresAt: fixture.clock.now.addingTimeInterval(120)
      )
      let billing = BillingCoordinator(checkoutResolver: resolver, browser: browser)
      let link = try billing.beginHostedCheckout(
        session: fixture.session,
        installationID: fixture.installationID,
        offeringID: fixture.offeringID,
        packageID: fixture.monthlyPackageID
      )

      try runner.expect(link.appUserID == fixture.appUserID, "checkout link was not bound to authenticated App User ID")
      try runner.expect(browser.opened == [link.url], "checkout did not open in the system browser")
    }

    runner.test("purchase refresh stores active entitlement and authorizes import") {
      let fixture = try Fixture()
      let document = try fixture.document(status: .active, token: "purchase-token", issuedOffset: 0)
      let client = fixture.client(remoteResults: [.valid(document)])
      let decision = try client.refresh(
        session: fixture.session,
        installationID: fixture.installationID,
        productID: fixture.productID,
        purpose: .purchase,
        appVersion: "0.4.0",
        channel: .stable
      )
      let access = AccessPolicy(leaseIDGenerator: SequentialLeaseIDGenerator(), clock: fixture.clock)
      let authorization = access.authorizeStartImport(entitlement: decision, currentIngestState: .safeIdle)

      if case .authorized(let lease) = authorization {
        try runner.expect(lease.entitlementTokenID.rawValue == "purchase-token", "wrong entitlement token authorized")
      } else {
        throw TestFailure("purchase did not authorize a new import")
      }
    }

    runner.test("restore and second Mac refresh without duplicate purchase") {
      let fixture = try Fixture()
      let secondInstall = try InstallationID("install-second")
      let restoreDoc = try fixture.document(status: .active, token: "restore-token", issuedOffset: 10)
      let secondDoc = try fixture.document(status: .active, token: "second-token", issuedOffset: 20, installationID: secondInstall)
      let refresher = FakeEntitlementRefresher()
      refresher.results = [.valid(restoreDoc), .valid(secondDoc)]
      let client = fixture.client(refresher: refresher)

      let restore = try client.restore(
        session: fixture.session,
        installationID: fixture.installationID,
        productID: fixture.productID,
        appVersion: "0.4.0",
        channel: .stable
      )
      let second = try client.activateSecondMac(
        session: fixture.session,
        installationID: secondInstall,
        productID: fixture.productID,
        appVersion: "0.4.0",
        channel: .stable
      )

      try runner.expect(restore.permitsNewImports, "restore did not grant access")
      try runner.expect(second.permitsNewImports, "second Mac did not grant access")
      try runner.expect(refresher.requests.map(\.purpose) == [.restore, .secondMac], "restore/second Mac purposes were not sent")
    }

    runner.test("cancellation and failed renewal remain truthful without interrupting access") {
      let fixture = try Fixture()
      let cancel = try fixture.decision(status: .cancellationAtPeriodEnd, token: "cancel-token")
      let failedRenewal = try fixture.decision(status: .pastDue, token: "past-due-token", issuedOffset: 10)

      try runner.expect(cancel.permitsNewImports, "cancellation at period end should remain active through paid-through date")
      try runner.expect(failedRenewal.permitsNewImports, "past-due failed renewal should not fabricate terminal revocation")
    }

    runner.test("refund and expiry deny only new imports while customer surfaces remain accessible") {
      let fixture = try Fixture()
      let refunded = try fixture.decision(status: .refunded, token: "refund-token")
      let expiredDoc = try fixture.document(
        status: .active,
        token: "expired-token",
        issuedOffset: -10_000,
        refreshAfterOffset: -9_000,
        refreshDeadlineOffset: -8_000,
        hardGraceOffset: -7_000
      )
      let expired = fixture.verifier.verify(expiredDoc, context: fixture.context())
      let access = AccessPolicy(leaseIDGenerator: SequentialLeaseIDGenerator(), clock: fixture.clock)

      let refundStart = access.authorizeStartImport(entitlement: refunded, currentIngestState: .safeIdle)
      let expiredStart = access.authorizeStartImport(entitlement: expired, currentIngestState: .safeIdle)

      try runner.expect(refundStart == .denied(.entitlementRevoked(.terminalStatus(.refunded))), "refund did not deny next import")
      try runner.expect(expiredStart == .denied(.entitlementRevoked(.expiredHardGrace)), "hard grace expiry did not deny next import")
      for surface in [CustomerSurface.copiedFiles, .logs, .settings, .support, .safeCleanup] {
        try runner.expect(access.canAccess(surface, entitlement: expired), "\(surface) should remain accessible after expiry")
      }
    }

    runner.test("offline grace and entitlement outage use cached signed entitlement") {
      let fixture = try Fixture()
      let cached = try fixture.document(
        status: .active,
        token: "cached-token",
        issuedOffset: -200,
        refreshAfterOffset: -100,
        refreshDeadlineOffset: -50,
        hardGraceOffset: 500
      )
      let store = KeychainEntitlementDocumentStore(
        box: CodableKeychainBox<SignedEntitlementDocument>(key: "entitlement", store: InMemoryKeychainValueStore())
      )
      try store.saveSignedEntitlement(cached)
      let client = fixture.client(remoteResults: [.indeterminate(.serviceUnavailable)], store: store)
      let decision = try client.refresh(
        session: fixture.session,
        installationID: fixture.installationID,
        productID: fixture.productID,
        purpose: .periodic,
        appVersion: "0.4.0",
        channel: .stable
      )

      if case .valid(let verified) = decision {
        try runner.expect(verified.isInOfflineGrace, "cached document should be in offline grace")
        try runner.expect(verified.requiresOnlineRefresh, "cached document should request online refresh")
      } else {
        throw TestFailure("outage did not fall back to valid signed cache")
      }
    }

    runner.test("active import survives entitlement change and denies next run at safe idle") {
      let fixture = try Fixture()
      let active = try fixture.decision(status: .active, token: "active-token")
      let refunded = try fixture.decision(status: .refunded, token: "refunded-token", issuedOffset: 10)
      let access = AccessPolicy(leaseIDGenerator: SequentialLeaseIDGenerator(), clock: fixture.clock)

      let start = access.authorizeStartImport(entitlement: active, currentIngestState: .safeIdle)
      try runner.expect(access.mayContinueActiveRun(currentIngestState: .copying), "active lease was not retained")
      if case .authorized = start {
        access.updateEntitlement(refunded, currentIngestState: .copying)
        try runner.expect(access.mayContinueActiveRun(currentIngestState: .copying), "entitlement change interrupted active import")
        access.ingestStateChanged(to: .safeIdle)
        let next = access.authorizeStartImport(entitlement: refunded, currentIngestState: .safeIdle)
        try runner.expect(next == .denied(.entitlementRevoked(.terminalStatus(.refunded))), "refund did not deny the next safe-idle import")
      } else {
        throw TestFailure("active entitlement failed to start import")
      }
    }

    runner.test("update downloads during active work but install waits for safe idle") {
      let fixture = try Fixture()
      let service = FakeUpdateService()
      service.checkResult = .available(try UpdateManifest(
        version: "0.4.1",
        build: "401",
        channel: .stable,
        minimumSystemVersion: "13.0",
        downloadURL: URL(string: "https://downloads.ddump.test/stable/0.4.1/DDump.dmg")!,
        signature: "sparkle-public-signature"
      ))
      let updates = UpdateCoordinator(service: service, selectedChannel: .stable)

      _ = try updates.checkAndDownload()
      try runner.expect(service.downloaded.count == 1, "update did not download")
      let deferred = try updates.requestInstallWhenSafe(currentIngestState: .verifying)
      try runner.expect(service.installed.isEmpty, "update installed during active import")
      try runner.expect(isDeferred(deferred), "update was not marked deferred")
      _ = try updates.ingestStateChanged(to: .safeIdle)
      try runner.expect(service.installed.count == 1, "update did not install after safe idle")
      _ = fixture
    }

    runner.test("beta feed requires both backend eligibility and explicit opt-in") {
      let eligible = ChannelEligibility(
        buildFlavor: .stable,
        accountEligibleForBeta: true,
        userOptedIntoBeta: true
      )
      let notEligible = ChannelEligibility(
        buildFlavor: .beta,
        accountEligibleForBeta: false,
        userOptedIntoBeta: true
      )
      let notOptedIn = ChannelEligibility(
        buildFlavor: .beta,
        accountEligibleForBeta: true,
        userOptedIntoBeta: false
      )
      try runner.expect(eligible.selectedChannel == .beta, "eligible opted-in account did not select beta")
      try runner.expect(notEligible.selectedChannel == .stable, "unapproved account selected beta")
      try runner.expect(notOptedIn.selectedChannel == .stable, "account selected beta without opt-in")
    }

    runner.test("paywall variant assignment is stable across approved refreshes") {
      let fixture = try Fixture()
      let monthly = try PaywallPackage(packageID: fixture.monthlyPackageID, productID: fixture.productID, displayName: "Monthly")
      let layout = try PaywallLayout(components: [.headline, .planPicker, .checkoutButton, .restoreButton, .legalDisclosure])
      let fetcher = FakePaywallFetcher()
      let policy = PaywallValidationPolicy(
        approvedProductIDs: [fixture.productID],
        approvedComponents: [.headline, .planPicker, .checkoutButton, .restoreButton, .legalDisclosure, .supportLink]
      )
      let store = InMemoryPaywallVariantAssignmentStore()
      let coordinator = PaywallCoordinator(fetcher: fetcher, assignmentStore: store, validationPolicy: policy)
      let variantA = try RemotePaywallConfiguration(
        schemaVersion: 1,
        offeringID: fixture.offeringID,
        variantID: VariantID("a"),
        copy: [PaywallCopyBlock(role: .headline, text: "DDump")],
        layout: layout,
        packages: [monthly],
        targeting: PaywallTargeting(countryCode: "US", minimumAppVersion: "0.4.0", channel: .stable)
      )
      let variantB = try RemotePaywallConfiguration(
        schemaVersion: 1,
        offeringID: fixture.offeringID,
        variantID: VariantID("b"),
        copy: [PaywallCopyBlock(role: .headline, text: "DDump Pro")],
        layout: layout,
        packages: [monthly],
        targeting: PaywallTargeting(countryCode: "US", minimumAppVersion: "0.4.0", channel: .stable)
      )
      fetcher.configurations = [variantB, variantA]
      let first = try coordinator.configuration(accountID: fixture.accountID, offeringID: fixture.offeringID, channel: .stable)
      fetcher.configurations = [variantB, variantA]
      let refreshed = try coordinator.configuration(accountID: fixture.accountID, offeringID: fixture.offeringID, channel: .stable)

      let expectedVariant = try VariantID("a")
      try runner.expect(first.variantID == expectedVariant, "deterministic first assignment should choose variant a")
      try runner.expect(refreshed.variantID == first.variantID, "variant assignment was not stable after refresh")
    }

    runner.test("remote configuration and Billing Lab guards reject unsafe changes") {
      let fixture = try Fixture()
      let foreignProduct = try ProductID("foreign")
      let unsafePackage = try PaywallPackage(packageID: PackageID("bad"), productID: foreignProduct, displayName: "Bad")
      let unsafe = try RemotePaywallConfiguration(
        schemaVersion: 1,
        offeringID: fixture.offeringID,
        variantID: VariantID("bad"),
        copy: [PaywallCopyBlock(role: .headline, text: "Bad")],
        layout: PaywallLayout(components: [.headline, .planPicker, .checkoutButton, .restoreButton]),
        packages: [unsafePackage],
        targeting: PaywallTargeting(countryCode: nil, minimumAppVersion: nil, channel: nil),
        unknownFieldNames: ["ingestOverride"]
      )
      let policy = PaywallValidationPolicy(
        approvedProductIDs: [fixture.productID],
        approvedComponents: [.headline, .planPicker, .checkoutButton, .restoreButton, .legalDisclosure]
      )

      try runner.expect(!RemoteConfigurationValidator.validatePaywall(unsafe, policy: policy), "unsafe remote config was accepted")
      try runner.expect(!BillingLabGuard.validate(BillingLabConfiguration(enabled: true, scenario: .refund), buildFlavor: .stable), "stable build enabled Billing Lab")
      try runner.expect(BillingLabGuard.validate(BillingLabConfiguration(enabled: true, scenario: .refund), buildFlavor: .debug), "debug build rejected Billing Lab")
    }

    runner.test("tampering wrong device unknown key and replay are rejected") {
      let fixture = try Fixture()
      var valid = try fixture.document(status: .active, token: "valid-token", issuedOffset: 0)
      let tampered = try SignedEntitlementDocument(
        schemaVersion: valid.schemaVersion,
        issuer: valid.issuer,
        audience: valid.audience,
        keyID: valid.keyID,
        accountID: valid.accountID,
        entitlementID: valid.entitlementID,
        productID: valid.productID,
        status: valid.status,
        tokenID: valid.tokenID,
        policyVersion: valid.policyVersion,
        issuedAt: valid.issuedAt,
        notBefore: valid.notBefore,
        refreshAfter: valid.refreshAfter,
        refreshDeadline: valid.refreshDeadline,
        hardGraceExpiresAt: valid.hardGraceExpiresAt,
        installationID: valid.installationID,
        installationPublicKey: valid.installationPublicKey,
        signedPayload: Data("tampered".utf8),
        signature: valid.signature
      )
      let wrongDevice = try fixture.document(status: .active, token: "wrong-device", installationID: InstallationID("other-install"))
      let unknownKey = try fixture.document(status: .active, token: "unknown-key", keyID: EntitlementKeyID("missing-key"))
      let newer = try fixture.document(status: .active, token: "newer", issuedOffset: 100)
      let olderReplay = try fixture.document(status: .active, token: "older", issuedOffset: 50)

      try runner.expect(fixture.verifier.verify(tampered, context: fixture.context()) == .revoked(.invalidSignature), "tampering was not rejected")
      try runner.expect(fixture.verifier.verify(wrongDevice, context: fixture.context()) == .revoked(.wrongInstallation), "wrong-device token was not rejected")
      try runner.expect(
        fixture.verifier.verify(
          valid,
          context: fixture.context(installationPublicKeyHash: Data("different-install-key".utf8))
        ) == .revoked(.wrongInstallation),
        "copied token with the right installation ID but wrong local key was not rejected"
      )
      try runner.expect(fixture.verifier.verify(unknownKey, context: fixture.context()) == .revoked(.unknownKey), "unknown key was not rejected")
      _ = fixture.verifier.verify(newer, context: fixture.context())
      try runner.expect(fixture.verifier.verify(olderReplay, context: fixture.context()) == .revoked(.staleOrReplayed), "stale replay was not rejected")
      valid = try fixture.document(status: .active, token: "valid-late", issuedOffset: 200)
      try runner.expect(valid.canonicalSignedPayload() == valid.signedPayload, "valid fixture payload was not canonical")
    }

    Foundation.exit(runner.finish())
  }

  private static func isDeferred(_ state: UpdateCoordinatorState) -> Bool {
    if case .installDeferred = state {
      return true
    }
    return false
  }
}

struct Fixture {
  let clock: MutableClock
  let accountID: StableAccountID
  let providerID: ProviderSubjectID
  let appUserID: RevenueCatAppUserID
  let stripeID: StripeCustomerID
  let installationID: InstallationID
  let productID: ProductID
  let offeringID: OfferingID
  let monthlyPackageID: PackageID
  let keyID: EntitlementKeyID
  let keyProvider: FakeKeyProvider
  let replayProtector: InMemoryEntitlementReplayProtector
  let verifier: EntitlementVerifier
  let session: AccountSession

  init() throws {
    clock = MutableClock(now: PaidLaunchHarness.baseDate)
    accountID = try StableAccountID("acct_123")
    providerID = try ProviderSubjectID(provider: "passwordless", subject: "subject_123")
    appUserID = try RevenueCatAppUserID("rc_app_user_acct_123")
    stripeID = try StripeCustomerID("cus_123")
    installationID = try InstallationID("install-primary")
    productID = try ProductID("ddump-monthly")
    offeringID = try OfferingID("default")
    monthlyPackageID = try PackageID("monthly")
    keyID = try EntitlementKeyID("key-1")
    keyProvider = FakeKeyProvider()
    replayProtector = InMemoryEntitlementReplayProtector()
    let key = try EntitlementVerificationKey(keyID: keyID, publicKey: Data("public-key".utf8), revokedAt: nil)
    keyProvider.keys[keyID] = key
    verifier = EntitlementVerifier(
      keyProvider: keyProvider,
      signatureVerifier: FakeEd25519Verifier(),
      replayProtector: replayProtector
    )
    let identity = AccountIdentity(
      accountID: accountID,
      providerSubjectID: providerID,
      revenueCatAppUserID: appUserID,
      stripeCustomerID: stripeID
    )
    session = try AccountSession(
      identity: identity,
      accessToken: "session-token",
      refreshToken: "refresh-token",
      expiresAt: clock.now.addingTimeInterval(3600)
    )
  }

  func context(
    installationID overrideInstallationID: InstallationID? = nil,
    installationPublicKeyHash: Data = Data("install-public-key".utf8)
  ) -> EntitlementVerificationContext {
    EntitlementVerificationContext(
      expectedAudience: PaidLaunchHarness.audience,
      expectedAccountID: accountID,
      expectedProductID: productID,
      expectedInstallationID: overrideInstallationID ?? installationID,
      expectedInstallationPublicKeyHash: installationPublicKeyHash,
      trustedNow: clock.now
    )
  }

  func decision(status: EntitlementStatus, token: String, issuedOffset: TimeInterval = 0) throws -> EntitlementDecision {
    verifier.verify(try document(status: status, token: token, issuedOffset: issuedOffset), context: context())
  }

  func client(
    remoteResults: [RemoteEntitlementResult],
    store: EntitlementDocumentStore? = nil
  ) -> EntitlementClient {
    let refresher = FakeEntitlementRefresher()
    refresher.results = remoteResults
    return client(refresher: refresher, store: store)
  }

  func client(
    refresher: EntitlementRefreshing,
    store: EntitlementDocumentStore? = nil
  ) -> EntitlementClient {
    let entitlementStore = store ?? KeychainEntitlementDocumentStore(
      box: CodableKeychainBox<SignedEntitlementDocument>(key: "entitlement", store: InMemoryKeychainValueStore())
    )
    return EntitlementClient(
      refresher: refresher,
      verifier: verifier,
      store: entitlementStore,
      audience: PaidLaunchHarness.audience,
      installationPublicKeyHash: Data("install-public-key".utf8),
      clock: clock
    )
  }

  func document(
    status: EntitlementStatus,
    token: String,
    issuedOffset: TimeInterval = 0,
    refreshAfterOffset: TimeInterval = 600,
    refreshDeadlineOffset: TimeInterval = 1_200,
    hardGraceOffset: TimeInterval = 2_400,
    installationID overrideInstallationID: InstallationID? = nil,
    keyID overrideKeyID: EntitlementKeyID? = nil
  ) throws -> SignedEntitlementDocument {
    let issued = clock.now.addingTimeInterval(issuedOffset)
    let key = overrideKeyID ?? keyID
    let provisional = try SignedEntitlementDocument(
      schemaVersion: 1,
      issuer: "api.ddump.test",
      audience: PaidLaunchHarness.audience,
      keyID: key,
      accountID: accountID,
      entitlementID: EntitlementID("entitlement-main"),
      productID: productID,
      status: status,
      tokenID: EntitlementTokenID(token),
      policyVersion: 1,
      issuedAt: issued,
      notBefore: issued.addingTimeInterval(-5),
      refreshAfter: clock.now.addingTimeInterval(refreshAfterOffset),
      refreshDeadline: clock.now.addingTimeInterval(refreshDeadlineOffset),
      hardGraceExpiresAt: clock.now.addingTimeInterval(hardGraceOffset),
      installationID: overrideInstallationID ?? installationID,
      installationPublicKey: Data("install-public-key".utf8),
      signedPayload: Data("placeholder".utf8),
      signature: Data("placeholder".utf8)
    )
    let payload = provisional.canonicalSignedPayload()
    return try SignedEntitlementDocument(
      schemaVersion: provisional.schemaVersion,
      issuer: provisional.issuer,
      audience: provisional.audience,
      keyID: provisional.keyID,
      accountID: provisional.accountID,
      entitlementID: provisional.entitlementID,
      productID: provisional.productID,
      status: provisional.status,
      tokenID: provisional.tokenID,
      policyVersion: provisional.policyVersion,
      issuedAt: provisional.issuedAt,
      notBefore: provisional.notBefore,
      refreshAfter: provisional.refreshAfter,
      refreshDeadline: provisional.refreshDeadline,
      hardGraceExpiresAt: provisional.hardGraceExpiresAt,
      installationID: provisional.installationID,
      installationPublicKey: provisional.installationPublicKey,
      signedPayload: payload,
      signature: FakeEd25519Verifier.signature(for: payload, keyID: key)
    )
  }
}
