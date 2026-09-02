import Foundation

public protocol SystemBrowserOpening {
  func openSystemBrowser(url: URL) throws
}

public struct PasswordlessSignInStart: Codable, Hashable, Sendable {
  public let flowID: String
  public let authorizationURL: URL
  public let state: String
  public let pkceVerifier: String
  public let expiresAt: Date

  public init(flowID: String, authorizationURL: URL, state: String, pkceVerifier: String, expiresAt: Date) throws {
    guard !flowID.isEmpty else { throw PaidLaunchValidationError.empty("flowID") }
    guard !state.isEmpty else { throw PaidLaunchValidationError.empty("state") }
    guard !pkceVerifier.isEmpty else { throw PaidLaunchValidationError.empty("pkceVerifier") }
    self.flowID = flowID
    self.authorizationURL = authorizationURL
    self.state = state
    self.pkceVerifier = pkceVerifier
    self.expiresAt = expiresAt
  }
}

public struct AuthCallback: Codable, Hashable, Sendable {
  public let url: URL
  public let receivedAt: Date

  public init(url: URL, receivedAt: Date) {
    self.url = url
    self.receivedAt = receivedAt
  }

  public func queryValue(named name: String) -> String? {
    URLComponents(url: url, resolvingAgainstBaseURL: false)?
      .queryItems?
      .first(where: { $0.name == name })?
      .value
  }
}

public enum AccountSessionState: Equatable {
  case signedOut
  case signInPending(flowID: String, expiresAt: Date)
  case authenticated(AccountIdentity)
  case refreshRequired(AccountIdentity)
  case failed(String)
}

public enum AccountCoordinatorError: Error, Equatable, CustomStringConvertible {
  case callbackWithoutPendingFlow
  case expiredPendingFlow
  case callbackStateMismatch
  case callbackContainedBearerCredential

  public var description: String {
    switch self {
    case .callbackWithoutPendingFlow:
      return "callback received without a pending sign-in flow"
    case .expiredPendingFlow:
      return "pending sign-in flow expired"
    case .callbackStateMismatch:
      return "callback state did not match the pending sign-in flow"
    case .callbackContainedBearerCredential:
      return "callback URL contained a bearer credential"
    }
  }
}

public protocol PasswordlessAuthServicing {
  func beginPasswordlessSignIn(email: String, installationID: InstallationID) throws -> PasswordlessSignInStart
  func redeemPasswordlessCallback(_ callback: AuthCallback, pendingFlow: PasswordlessSignInStart) throws -> AccountSession
  func refreshSession(_ session: AccountSession) throws -> AccountSession
  func logout(_ session: AccountSession) throws
}

public final class AccountCoordinator {
  private let authService: PasswordlessAuthServicing
  private let browser: SystemBrowserOpening
  private let sessionBox: CodableKeychainBox<AccountSession>
  private let pendingFlowBox: CodableKeychainBox<PasswordlessSignInStart>?
  private let clock: PaidLaunchClock
  private var pendingFlow: PasswordlessSignInStart?

  public private(set) var state: AccountSessionState

  public init(
    authService: PasswordlessAuthServicing,
    browser: SystemBrowserOpening,
    sessionBox: CodableKeychainBox<AccountSession>,
    pendingFlowBox: CodableKeychainBox<PasswordlessSignInStart>? = nil,
    clock: PaidLaunchClock
  ) {
    self.authService = authService
    self.browser = browser
    self.sessionBox = sessionBox
    self.pendingFlowBox = pendingFlowBox
    self.clock = clock
    self.pendingFlow = try? pendingFlowBox?.load()
    if let session = try? sessionBox.load() {
      self.state = session.expiresAt > clock.now ? .authenticated(session.identity) : .refreshRequired(session.identity)
    } else {
      self.state = .signedOut
    }
  }

  @discardableResult
  public func beginPasswordlessSignIn(email: String, installationID: InstallationID) throws -> PasswordlessSignInStart {
    let start = try authService.beginPasswordlessSignIn(email: email, installationID: installationID)
    pendingFlow = start
    try pendingFlowBox?.save(start)
    state = .signInPending(flowID: start.flowID, expiresAt: start.expiresAt)
    try browser.openSystemBrowser(url: start.authorizationURL)
    return start
  }

  @discardableResult
  public func handleSystemBrowserCallback(_ callback: AuthCallback) throws -> AccountSession {
    guard let pendingFlow else { throw AccountCoordinatorError.callbackWithoutPendingFlow }
    guard pendingFlow.expiresAt >= clock.now else {
      state = .failed(AccountCoordinatorError.expiredPendingFlow.description)
      throw AccountCoordinatorError.expiredPendingFlow
    }
    guard callback.queryValue(named: "state") == pendingFlow.state else {
      state = .failed(AccountCoordinatorError.callbackStateMismatch.description)
      throw AccountCoordinatorError.callbackStateMismatch
    }
    if callback.queryValue(named: "access_token") != nil || callback.queryValue(named: "refresh_token") != nil {
      state = .failed(AccountCoordinatorError.callbackContainedBearerCredential.description)
      throw AccountCoordinatorError.callbackContainedBearerCredential
    }

    let session = try authService.redeemPasswordlessCallback(callback, pendingFlow: pendingFlow)
    try sessionBox.save(session)
    self.pendingFlow = nil
    try pendingFlowBox?.delete()
    state = .authenticated(session.identity)
    return session
  }

  @discardableResult
  public func currentSession() throws -> AccountSession? {
    guard let session = try sessionBox.load() else {
      state = .signedOut
      return nil
    }
    if session.expiresAt > clock.now {
      state = .authenticated(session.identity)
      return session
    }
    let refreshed = try authService.refreshSession(session)
    try sessionBox.save(refreshed)
    state = .authenticated(refreshed.identity)
    return refreshed
  }

  public func logoutWhenSafe(isSafeIdle: Bool) throws -> Bool {
    guard isSafeIdle else { return false }
    if let session = try sessionBox.load() {
      try authService.logout(session)
    }
    try sessionBox.delete()
    try pendingFlowBox?.delete()
    pendingFlow = nil
    state = .signedOut
    return true
  }
}
