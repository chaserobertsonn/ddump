import AppKit
import Foundation
#if canImport(Sparkle)
import Sparkle

/// Sparkle owns update discovery, download, signature verification, and install.
/// This bridge owns only DDump's channel choice and safe-idle install boundary.
final class DDumpSparkleUpdateBridge: NSObject, SPUUpdaterDelegate {
  static let shared = DDumpSparkleUpdateBridge()
  private static let betaEligibilityKey = "beta-updates-eligible-v1"

  private var controller: SPUStandardUpdaterController?
  private var deferredInstallHandlers: [() -> Void] = []
  private var safeIdleTimer: Timer?

  static var isEnabledInBundle: Bool {
    Bundle.main.object(forInfoDictionaryKey: "DDumpSparkleEnabled") as? Bool == true
  }

  static var betaUpdatesEligible: Bool {
    let value = try? SecurityKeychainValueStore().data(forKey: betaEligibilityKey)
    return value == Data("1".utf8)
  }

  static func setBetaUpdatesEligible(_ eligible: Bool) {
    try? SecurityKeychainValueStore().setData(
      Data((eligible ? "1" : "0").utf8),
      forKey: betaEligibilityKey
    )
  }

  private var updateChannel: String {
    let preferences = readShellEnv(at: DDumpPaths.configFile)
    let optedIn = preferences["BETA_UPDATES_OPT_IN"] == "1"
    return Self.betaUpdatesEligible && optedIn ? "beta" : "stable"
  }

  override private init() {
    super.init()
  }

  func startIfConfigured() {
    guard Self.isEnabledInBundle, controller == nil else { return }
    guard let publicKey = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
          !publicKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return
    }
    let newController = SPUStandardUpdaterController(
      startingUpdater: true,
      updaterDelegate: self,
      userDriverDelegate: nil
    )
    controller = newController
    let preferences = readShellEnv(at: DDumpPaths.configFile)
    applyPreferences(
      checksEnabled: preferences["UPDATE_CHECKS_ENABLED"] == "1",
      automaticallyDownloadsUpdates: preferences["AUTO_UPDATES_ENABLED"] == "1",
      frequency: preferences["UPDATE_CHECK_FREQUENCY"] ?? "weekly"
    )
  }

  func checkForUpdates() {
    controller?.checkForUpdates(nil)
  }

  func applyPreferences(
    checksEnabled: Bool,
    automaticallyDownloadsUpdates: Bool,
    frequency: String
  ) {
    guard let updater = controller?.updater else { return }
    updater.automaticallyChecksForUpdates = checksEnabled
    updater.automaticallyDownloadsUpdates = checksEnabled && automaticallyDownloadsUpdates
    switch frequency {
    case "monthly":
      updater.updateCheckInterval = 30 * 24 * 60 * 60
    case "startup":
      updater.updateCheckInterval = 24 * 60 * 60
      if checksEnabled, updater.canCheckForUpdates {
        updater.checkForUpdatesInBackground()
      }
    default:
      updater.updateCheckInterval = 7 * 24 * 60 * 60
    }
  }

  func refreshChannelSelection() {
    controller?.updater.resetUpdateCycleAfterShortDelay()
  }

  func allowedChannels(for updater: SPUUpdater) -> Set<String> {
    updateChannel == "beta" ? ["beta"] : []
  }

  func feedURLString(for updater: SPUUpdater) -> String? {
    if updateChannel == "beta" {
      return Bundle.main.object(forInfoDictionaryKey: "DDumpBetaFeedURL") as? String
    }
    return Bundle.main.object(forInfoDictionaryKey: "DDumpStableFeedURL") as? String
  }

  func updater(
    _ updater: SPUUpdater,
    shouldPostponeRelaunchForUpdate item: SUAppcastItem,
    untilInvokingBlock installHandler: @escaping () -> Void
  ) -> Bool {
    guard !isVerifiedSafeIdle else { return false }
    deferInstall(installHandler)
    return true
  }

  func updater(
    _ updater: SPUUpdater,
    willInstallUpdateOnQuit item: SUAppcastItem,
    immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
  ) -> Bool {
    guard !isVerifiedSafeIdle else { return false }
    deferInstall(immediateInstallHandler)
    return true
  }

  func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool {
    isVerifiedSafeIdle
  }

  private var isVerifiedSafeIdle: Bool {
    let fileManager = FileManager.default
    guard !fileManager.fileExists(atPath: DDumpPaths.lockDir.path) else { return false }
    let status = readShellEnv(at: DDumpPaths.statusFile)
    let phase = status["phase"] ?? "idle"
    let unsafePhases: Set<String> = [
      "starting", "scanning", "importing", "verifying", "organizing",
      "uploading", "recovering", "eject-pending", "paused", "stopping"
    ]
    return !unsafePhases.contains(phase)
  }

  private func deferInstall(_ handler: @escaping () -> Void) {
    deferredInstallHandlers.append(handler)
    guard safeIdleTimer == nil else { return }
    safeIdleTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
      guard let self else {
        timer.invalidate()
        return
      }
      guard self.isVerifiedSafeIdle else { return }
      let handlers = self.deferredInstallHandlers
      self.deferredInstallHandlers.removeAll()
      timer.invalidate()
      self.safeIdleTimer = nil
      handlers.forEach { $0() }
    }
  }
}
#else
final class DDumpSparkleUpdateBridge {
  static let shared = DDumpSparkleUpdateBridge()
  static let isEnabledInBundle = false
  static let betaUpdatesEligible = false

  private init() {}
  static func setBetaUpdatesEligible(_ eligible: Bool) {}
  func startIfConfigured() {}
  func checkForUpdates() {}
  func applyPreferences(
    checksEnabled: Bool,
    automaticallyDownloadsUpdates: Bool,
    frequency: String
  ) {}
  func refreshChannelSelection() {}
}
#endif
