import Foundation

private struct AppHelperMigrationLeaseProvider: HelperMigrationIngestLeaseProviding {
  func currentIngestLease() throws -> HelperMigrationIngestLease {
    let fileManager = FileManager.default
    if fileManager.fileExists(atPath: DDumpPaths.lockDir.path) {
      let phase = readShellEnv(at: DDumpPaths.statusFile)["phase"] ?? "active"
      return HelperMigrationIngestLease(verifiedSafeIdle: false, phase: phase)
    }

    let phase = readShellEnv(at: DDumpPaths.statusFile)["phase"] ?? "idle"
    let unsafePhases: Set<String> = [
      "starting", "scanning", "importing", "verifying", "organizing",
      "uploading", "recovering", "eject-pending", "paused", "stopping"
    ]
    return HelperMigrationIngestLease(
      verifiedSafeIdle: !unsafePhases.contains(phase),
      phase: phase
    )
  }
}

/// Runs only for release builds that explicitly enable helper migration.
/// It never activates launchd jobs; existing jobs keep their stable paths and
/// new templates are picked up on the next approved activation or login.
final class AppHelperMigrationRunner {
  static let shared = AppHelperMigrationRunner()

  private var timer: Timer?
  private var completed = false

  private init() {}

  func startIfConfigured() {
    guard Bundle.main.object(forInfoDictionaryKey: "DDumpHelperMigrationEnabled") as? Bool == true,
          !completed,
          timer == nil else {
      return
    }
    attemptMigration()
    guard !completed else { return }
    timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
      self?.attemptMigration()
    }
  }

  private func attemptMigration() {
    guard !completed,
          let resources = Bundle.main.resourceURL?
            .appendingPathComponent("HelperPayload/current", isDirectory: true),
          FileManager.default.fileExists(atPath: resources.path) else {
      completed = true
      timer?.invalidate()
      timer = nil
      return
    }

    let coordinator = HelperMigrationCoordinator(
      roots: .init(
        appSupportDirectory: DDumpPaths.appSupport,
        launchAgentDirectory: FileManager.default.homeDirectoryForCurrentUser
          .appendingPathComponent("Library/LaunchAgents", isDirectory: true),
        helperResourcesDirectory: resources
      ),
      leaseProvider: AppHelperMigrationLeaseProvider()
    )

    do {
      if let recovery = try coordinator.recoverInterruptedMigration(),
         case .recoveredPostSwap = recovery {
        finish()
        return
      }
      let result = try coordinator.migrate(
        manifestURL: resources.appendingPathComponent("helper-manifest.json")
      )
      switch result {
      case .installed, .alreadyInstalled:
        finish()
      case .deferred, .recoveredPreSwap:
        break
      case .recoveredPostSwap, .rolledBack:
        finish()
      }
    } catch {
      // Fail closed for helper mutation while leaving the current helper set
      // and all customer files available. Diagnostics expose only the category.
      NSLog("DDump helper migration deferred after verification failure")
    }
  }

  private func finish() {
    completed = true
    timer?.invalidate()
    timer = nil
  }
}
