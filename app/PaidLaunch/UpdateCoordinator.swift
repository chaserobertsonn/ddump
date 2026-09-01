import Foundation

public struct UpdateManifest: Equatable, Sendable {
  public let version: String
  public let build: String
  public let channel: ReleaseChannel
  public let minimumSystemVersion: String
  public let downloadURL: URL
  public let signature: String

  public init(
    version: String,
    build: String,
    channel: ReleaseChannel,
    minimumSystemVersion: String,
    downloadURL: URL,
    signature: String
  ) throws {
    guard !version.isEmpty else { throw PaidLaunchValidationError.empty("version") }
    guard !build.isEmpty else { throw PaidLaunchValidationError.empty("build") }
    guard downloadURL.scheme == "https" else { throw PaidLaunchValidationError.invalid("update download URL must be https") }
    guard !signature.isEmpty else { throw PaidLaunchValidationError.empty("signature") }
    self.version = version
    self.build = build
    self.channel = channel
    self.minimumSystemVersion = minimumSystemVersion
    self.downloadURL = downloadURL
    self.signature = signature
  }
}

public struct DownloadedUpdate: Equatable, Sendable {
  public let manifest: UpdateManifest
  public let localArtifactID: String

  public init(manifest: UpdateManifest, localArtifactID: String) throws {
    guard !localArtifactID.isEmpty else { throw PaidLaunchValidationError.empty("localArtifactID") }
    self.manifest = manifest
    self.localArtifactID = localArtifactID
  }
}

public enum UpdateCheckResult: Equatable, Sendable {
  case available(UpdateManifest)
  case notAvailable
  case failed(String)
}

public protocol UpdateServicing {
  func checkForUpdate(channel: ReleaseChannel) throws -> UpdateCheckResult
  func download(_ manifest: UpdateManifest) throws -> DownloadedUpdate
  func installAndRelaunch(_ update: DownloadedUpdate) throws
}

public enum UpdateCoordinatorState: Equatable, Sendable {
  case idle
  case downloaded(DownloadedUpdate)
  case installDeferred(DownloadedUpdate)
  case installed(DownloadedUpdate)
  case failed(String)
}

public struct ChannelEligibility: Equatable, Sendable {
  public let buildFlavor: BuildFlavor
  public let accountEligibleForBeta: Bool
  public let userOptedIntoBeta: Bool

  public init(buildFlavor: BuildFlavor, accountEligibleForBeta: Bool, userOptedIntoBeta: Bool) {
    self.buildFlavor = buildFlavor
    self.accountEligibleForBeta = accountEligibleForBeta
    self.userOptedIntoBeta = userOptedIntoBeta
  }

  public var selectedChannel: ReleaseChannel {
    if accountEligibleForBeta && userOptedIntoBeta {
      return .beta
    }
    return .stable
  }
}

public final class UpdateCoordinator {
  private let service: UpdateServicing

  public private(set) var state: UpdateCoordinatorState = .idle
  public private(set) var selectedChannel: ReleaseChannel

  public init(service: UpdateServicing, selectedChannel: ReleaseChannel) {
    self.service = service
    self.selectedChannel = selectedChannel
  }

  @discardableResult
  public func checkAndDownload() throws -> UpdateCoordinatorState {
    switch try service.checkForUpdate(channel: selectedChannel) {
    case .available(let manifest):
      guard manifest.channel == selectedChannel else {
        state = .failed("update channel mismatch")
        return state
      }
      let downloaded = try service.download(manifest)
      state = .downloaded(downloaded)
      return state
    case .notAvailable:
      state = .idle
      return state
    case .failed(let message):
      state = .failed(message)
      return state
    }
  }

  @discardableResult
  public func requestInstallWhenSafe(currentIngestState: ImportSafetyState) throws -> UpdateCoordinatorState {
    guard case .downloaded(let update) = state else { return state }
    guard currentIngestState.isVerifiedSafeIdle else {
      state = .installDeferred(update)
      return state
    }
    try service.installAndRelaunch(update)
    state = .installed(update)
    return state
  }

  @discardableResult
  public func ingestStateChanged(to state: ImportSafetyState) throws -> UpdateCoordinatorState {
    guard case .installDeferred(let update) = self.state, state.isVerifiedSafeIdle else {
      return self.state
    }
    try service.installAndRelaunch(update)
    self.state = .installed(update)
    return self.state
  }
}
