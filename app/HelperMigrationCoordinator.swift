import Foundation

enum HelperMigrationError: Error, CustomStringConvertible, Equatable {
  case unsafeIngestState(String)
  case invalidManifest(String)
  case invalidRelativePath(String)
  case forbiddenPath(String)
  case checksumMismatch(path: String, expected: String, actual: String)
  case permissionMismatch(path: String, expected: Int, actual: Int)
  case symlinkRejected(String)
  case signatureRejected(String)
  case downgradeRejected(installed: String, target: String)
  case noRollbackSnapshot

  var description: String {
    switch self {
    case .unsafeIngestState(let phase):
      return "helper migration deferred because ingest is not verified safe idle: \(phase)"
    case .invalidManifest(let detail):
      return "invalid helper manifest: \(detail)"
    case .invalidRelativePath(let path):
      return "invalid relative path: \(path)"
    case .forbiddenPath(let path):
      return "path is outside the helper allowlist: \(path)"
    case .checksumMismatch(let path, let expected, let actual):
      return "checksum mismatch for \(path): expected \(expected), got \(actual)"
    case .permissionMismatch(let path, let expected, let actual):
      return "permission mismatch for \(path): expected \(String(expected, radix: 8)), got \(String(actual, radix: 8))"
    case .symlinkRejected(let path):
      return "symlink rejected: \(path)"
    case .signatureRejected(let detail):
      return "signature rejected: \(detail)"
    case .downgradeRejected(let installed, let target):
      return "refusing helper downgrade from \(installed) to \(target)"
    case .noRollbackSnapshot:
      return "no helper rollback snapshot is available"
    }
  }
}

struct HelperMigrationIngestLease: Equatable {
  let verifiedSafeIdle: Bool
  let phase: String
  let leaseIdentifier: String
  let checkedAt: Date

  init(verifiedSafeIdle: Bool, phase: String, leaseIdentifier: String = UUID().uuidString, checkedAt: Date = Date()) {
    self.verifiedSafeIdle = verifiedSafeIdle
    self.phase = phase
    self.leaseIdentifier = leaseIdentifier
    self.checkedAt = checkedAt
  }
}

protocol HelperMigrationIngestLeaseProviding {
  func currentIngestLease() throws -> HelperMigrationIngestLease
}

protocol HelperMigrationChecksumVerifying {
  func sha256Hex(of fileURL: URL) throws -> String
}

protocol HelperMigrationSignatureVerifying {
  func verify(fileURL: URL, policy: HelperMigrationManifest.File.SigningPolicy) throws
}

struct Shasum256Verifier: HelperMigrationChecksumVerifying {
  func sha256Hex(of fileURL: URL) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
    process.arguments = ["-a", "256", fileURL.path]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw HelperMigrationError.invalidManifest("cannot compute SHA-256 for \(fileURL.path)")
    }
    let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    guard let digest = output.split(whereSeparator: { $0 == " " || $0 == "\t" }).first else {
      throw HelperMigrationError.invalidManifest("unexpected shasum output for \(fileURL.path)")
    }
    return String(digest).lowercased()
  }
}

struct CodesignPolicyVerifier: HelperMigrationSignatureVerifying {
  func verify(fileURL: URL, policy: HelperMigrationManifest.File.SigningPolicy) throws {
    let detail = try codesignDetails(fileURL: fileURL)
    if let expectedTeam = policy.teamIdentifier, !detail.contains("TeamIdentifier=\(expectedTeam)") {
      throw HelperMigrationError.signatureRejected("\(fileURL.path) missing TeamIdentifier=\(expectedTeam)")
    }
    if let expectedIdentifier = policy.identifier, !detail.contains("Identifier=\(expectedIdentifier)") {
      throw HelperMigrationError.signatureRejected("\(fileURL.path) missing Identifier=\(expectedIdentifier)")
    }
    if let requirement = policy.designatedRequirement, !requirement.isEmpty {
      try verifyDesignatedRequirement(fileURL: fileURL, requirement: requirement)
    }
  }

  private func codesignDetails(fileURL: URL) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    process.arguments = ["-dv", "--verbose=4", fileURL.path]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw HelperMigrationError.signatureRejected("codesign details failed for \(fileURL.path)")
    }
    return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
  }

  private func verifyDesignatedRequirement(fileURL: URL, requirement: String) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    process.arguments = ["-R", requirement, "--verify", fileURL.path]
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw HelperMigrationError.signatureRejected("designated requirement failed for \(fileURL.path)")
    }
  }
}

struct HelperMigrationManifest: Codable, Equatable {
  let schemaVersion: Int
  let helperSetVersion: String
  let minimumAppVersion: String?
  let createdAt: String?
  let forwardFixForVersions: [String]?
  let preservePreviousSnapshot: Bool
  let files: [File]

  struct File: Codable, Equatable {
    let role: Role
    let sourceRelativePath: String
    let installRelativePath: String
    let sha256: String
    let mode: Int
    let signing: SigningPolicy?

    enum Role: String, Codable {
      case appSupportBin
      case launchAgentTemplate
      case appSupportTemplate
    }

    struct SigningPolicy: Codable, Equatable {
      let teamIdentifier: String?
      let identifier: String?
      let designatedRequirement: String?
    }
  }
}

enum HelperMigrationResult: Equatable {
  case installed(version: String)
  case alreadyInstalled(version: String)
  case deferred(phase: String)
  case recoveredPreSwap(version: String)
  case recoveredPostSwap(version: String)
  case rolledBack(version: String)
}

final class HelperMigrationCoordinator {
  struct Roots {
    let appSupportDirectory: URL
    let launchAgentDirectory: URL
    let helperResourcesDirectory: URL

    var binDirectory: URL { appSupportDirectory.appendingPathComponent("bin", isDirectory: true) }
    var stateDirectory: URL { appSupportDirectory.appendingPathComponent("state", isDirectory: true) }
    var migrationDirectory: URL { stateDirectory.appendingPathComponent("helper-migration", isDirectory: true) }
    var journalURL: URL { migrationDirectory.appendingPathComponent("journal.json") }
    var installedReceiptURL: URL { migrationDirectory.appendingPathComponent("installed.json") }
    var activationPlanURL: URL { migrationDirectory.appendingPathComponent("launchagent-activation.json") }
    var snapshotsDirectory: URL { migrationDirectory.appendingPathComponent("snapshots", isDirectory: true) }
  }

  private struct InstalledReceipt: Codable {
    let version: String
    let installedAt: String
    let files: [InstalledFile]
  }

  private struct InstalledFile: Codable, Equatable {
    let role: HelperMigrationManifest.File.Role
    let installRelativePath: String
    let targetPath: String
  }

  private struct LaunchAgentActivationPlan: Codable {
    let helperSetVersion: String
    let generatedAt: String
    let templatesInstalled: [String]
    let note: String
  }

  private struct Journal: Codable {
    enum Phase: String, Codable {
      case staged
      case snapshotCreated
      case swapping
      case swapped
    }

    let migrationID: String
    let targetVersion: String
    let previousVersion: String?
    var phase: Phase
    let stagingPath: String
    let snapshotPath: String
    let oldBinPath: String
    let installedFiles: [InstalledFile]
  }

  private let roots: Roots
  private let leaseProvider: HelperMigrationIngestLeaseProviding
  private let checksumVerifier: HelperMigrationChecksumVerifying
  private let signatureVerifier: HelperMigrationSignatureVerifying
  private let fileManager: FileManager
  private let now: () -> Date
  private let allowedLaunchAgentNames: Set<String>

  init(
    roots: Roots,
    leaseProvider: HelperMigrationIngestLeaseProviding,
    checksumVerifier: HelperMigrationChecksumVerifying = Shasum256Verifier(),
    signatureVerifier: HelperMigrationSignatureVerifying = CodesignPolicyVerifier(),
    fileManager: FileManager = .default,
    now: @escaping () -> Date = Date.init,
    allowedLaunchAgentNames: Set<String> = [
      "com.ddump.plist",
      "com.ddump.network-watch.plist",
      "com.ddump.cloud-idle-watch.plist",
      "com.ddump.rclone-gdrive.plist",
      "com.ddump.rclone-gdrive.legacy.plist"
    ]
  ) {
    self.roots = roots
    self.leaseProvider = leaseProvider
    self.checksumVerifier = checksumVerifier
    self.signatureVerifier = signatureVerifier
    self.fileManager = fileManager
    self.now = now
    self.allowedLaunchAgentNames = allowedLaunchAgentNames
  }

  func migrate(manifestURL: URL) throws -> HelperMigrationResult {
    let lease = try leaseProvider.currentIngestLease()
    guard lease.verifiedSafeIdle else {
      return .deferred(phase: lease.phase)
    }

    let manifest = try decodeManifest(from: manifestURL)
    let installedVersion = try currentInstalledVersion()
    if let installedVersion {
      let ordering = compareVersions(manifest.helperSetVersion, installedVersion)
      if ordering == .orderedSame {
        return .alreadyInstalled(version: installedVersion)
      }
      if ordering == .orderedAscending && !(manifest.forwardFixForVersions ?? []).contains(installedVersion) {
        throw HelperMigrationError.downgradeRejected(installed: installedVersion, target: manifest.helperSetVersion)
      }
    }

    try validate(manifest: manifest)
    try prepareRootDirectories()

    let migrationID = UUID().uuidString
    let stagingURL = roots.migrationDirectory.appendingPathComponent("stage-\(migrationID)", isDirectory: true)
    let snapshotURL = roots.snapshotsDirectory.appendingPathComponent("snapshot-\(installedVersion ?? "none")", isDirectory: true)
    let oldBinURL = roots.migrationDirectory.appendingPathComponent("old-bin-\(migrationID)", isDirectory: true)
    let installedFiles = try stage(manifest: manifest, at: stagingURL)

    var journal = Journal(
      migrationID: migrationID,
      targetVersion: manifest.helperSetVersion,
      previousVersion: installedVersion,
      phase: .staged,
      stagingPath: stagingURL.path,
      snapshotPath: snapshotURL.path,
      oldBinPath: oldBinURL.path,
      installedFiles: installedFiles
    )
    try writeJournal(journal)

    try createSnapshot(for: installedFiles, at: snapshotURL)
    journal.phase = .snapshotCreated
    try writeJournal(journal)

    journal.phase = .swapping
    try writeJournal(journal)
    try swapStagedFiles(journal: journal)

    journal.phase = .swapped
    try writeJournal(journal)
    try finishMigration(journal: journal)
    return .installed(version: manifest.helperSetVersion)
  }

  func recoverInterruptedMigration() throws -> HelperMigrationResult? {
    let lease = try leaseProvider.currentIngestLease()
    guard lease.verifiedSafeIdle else {
      return .deferred(phase: lease.phase)
    }
    guard fileManager.fileExists(atPath: roots.journalURL.path) else {
      return nil
    }
    let journal = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: roots.journalURL))
    switch journal.phase {
    case .staged, .snapshotCreated:
      try removeIfExists(URL(fileURLWithPath: journal.stagingPath, isDirectory: true))
      try removeIfExists(URL(fileURLWithPath: journal.oldBinPath, isDirectory: true))
      try removeIfExists(roots.journalURL)
      return .recoveredPreSwap(version: journal.previousVersion ?? "none")
    case .swapping, .swapped:
      try swapStagedFiles(journal: journal)
      try finishMigration(journal: journal)
      return .recoveredPostSwap(version: journal.targetVersion)
    }
  }

  func rollbackToPreviousSnapshot() throws -> HelperMigrationResult {
    let lease = try leaseProvider.currentIngestLease()
    guard lease.verifiedSafeIdle else {
      return .deferred(phase: lease.phase)
    }
    guard let snapshot = try latestSnapshot() else {
      throw HelperMigrationError.noRollbackSnapshot
    }
    let version = snapshot.lastPathComponent
    let rollbackID = UUID().uuidString
    let stagedBin = roots.migrationDirectory.appendingPathComponent("rollback-bin-\(rollbackID)", isDirectory: true)
    let oldBin = roots.migrationDirectory.appendingPathComponent("rollback-old-bin-\(rollbackID)", isDirectory: true)

    if fileManager.fileExists(atPath: snapshot.appendingPathComponent("bin").path) {
      try copyDirectory(from: snapshot.appendingPathComponent("bin"), to: stagedBin)
      if fileManager.fileExists(atPath: roots.binDirectory.path) {
        try checkedMoveItem(at: roots.binDirectory, to: oldBin)
      }
      try checkedMoveItem(at: stagedBin, to: roots.binDirectory)
    }

    let launchSnapshot = snapshot.appendingPathComponent("LaunchAgents", isDirectory: true)
    if fileManager.fileExists(atPath: launchSnapshot.path) {
      let contents = try fileManager.contentsOfDirectory(at: launchSnapshot, includingPropertiesForKeys: nil)
      for source in contents where source.pathExtension == "plist" {
        guard allowedLaunchAgentNames.contains(source.lastPathComponent) else { continue }
        let target = roots.launchAgentDirectory.appendingPathComponent(source.lastPathComponent)
        try checkedCopyFile(from: source, to: target, mode: 0o644)
      }
    }

    let receiptVersion = version.replacingOccurrences(of: "snapshot-", with: "")
    try writeInstalledReceipt(version: receiptVersion, files: [])
    try writeActivationPlan(version: receiptVersion, templates: [])
    return .rolledBack(version: receiptVersion)
  }

  private func decodeManifest(from manifestURL: URL) throws -> HelperMigrationManifest {
    guard !isSymlink(manifestURL) else {
      throw HelperMigrationError.symlinkRejected(manifestURL.path)
    }
    let manifest = try JSONDecoder().decode(HelperMigrationManifest.self, from: Data(contentsOf: manifestURL))
    guard manifest.schemaVersion == 1 else {
      throw HelperMigrationError.invalidManifest("unsupported schemaVersion \(manifest.schemaVersion)")
    }
    guard !manifest.helperSetVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw HelperMigrationError.invalidManifest("helperSetVersion is required")
    }
    guard !manifest.files.isEmpty else {
      throw HelperMigrationError.invalidManifest("files cannot be empty")
    }
    return manifest
  }

  private func validate(manifest: HelperMigrationManifest) throws {
    var seenTargets = Set<String>()
    for file in manifest.files {
      let sourceComponents = try relativeComponents(file.sourceRelativePath)
      let installComponents = try relativeComponents(file.installRelativePath)
      try validateAllowlist(file: file, sourceComponents: sourceComponents, installComponents: installComponents)
      let targetKey = "\(file.role.rawValue):\(file.installRelativePath)"
      guard seenTargets.insert(targetKey).inserted else {
        throw HelperMigrationError.invalidManifest("duplicate target \(targetKey)")
      }
      guard file.sha256.range(of: #"^[A-Fa-f0-9]{64}$"#, options: .regularExpression) != nil else {
        throw HelperMigrationError.invalidManifest("invalid sha256 for \(file.sourceRelativePath)")
      }
      guard file.mode == 0o755 || file.mode == 0o644 else {
        throw HelperMigrationError.invalidManifest("unsupported mode \(String(file.mode, radix: 8)) for \(file.sourceRelativePath)")
      }

      let sourceURL = safeURL(root: roots.helperResourcesDirectory, components: sourceComponents)
      try rejectSymlinks(from: roots.helperResourcesDirectory, through: sourceComponents, includeLeaf: true)
      guard isRegularFile(sourceURL) else {
        throw HelperMigrationError.invalidManifest("source is not a regular file: \(file.sourceRelativePath)")
      }
      let actualMode = try posixMode(sourceURL)
      guard actualMode == file.mode else {
        throw HelperMigrationError.permissionMismatch(path: file.sourceRelativePath, expected: file.mode, actual: actualMode)
      }
      let actualDigest = try checksumVerifier.sha256Hex(of: sourceURL).lowercased()
      guard actualDigest == file.sha256.lowercased() else {
        throw HelperMigrationError.checksumMismatch(path: file.sourceRelativePath, expected: file.sha256, actual: actualDigest)
      }
      if let signing = file.signing {
        try signatureVerifier.verify(fileURL: sourceURL, policy: signing)
      }
    }
  }

  private func validateAllowlist(
    file: HelperMigrationManifest.File,
    sourceComponents: [String],
    installComponents: [String]
  ) throws {
    switch file.role {
    case .appSupportBin:
      guard sourceComponents.first == "bin" else {
        throw HelperMigrationError.forbiddenPath(file.sourceRelativePath)
      }
      let installsScript = installComponents.last?.hasSuffix(".sh") == true || installComponents.last?.hasSuffix(".py") == true
      guard installComponents.count <= 2 && installsScript else {
        throw HelperMigrationError.forbiddenPath(file.installRelativePath)
      }
    case .launchAgentTemplate:
      guard sourceComponents.first == "LaunchAgents" else {
        throw HelperMigrationError.forbiddenPath(file.sourceRelativePath)
      }
      guard installComponents.count == 1 && allowedLaunchAgentNames.contains(installComponents[0]) else {
        throw HelperMigrationError.forbiddenPath(file.installRelativePath)
      }
      guard file.mode == 0o644 else {
        throw HelperMigrationError.invalidManifest("LaunchAgent templates must install as 0644")
      }
    case .appSupportTemplate:
      guard sourceComponents.first == "templates" && installComponents.first == "templates" else {
        throw HelperMigrationError.forbiddenPath(file.installRelativePath)
      }
      guard file.mode == 0o644 else {
        throw HelperMigrationError.invalidManifest("templates must install as 0644")
      }
    }
  }

  private func stage(manifest: HelperMigrationManifest, at stagingURL: URL) throws -> [InstalledFile] {
    try removeIfExists(stagingURL)
    try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: true)
    var installedFiles: [InstalledFile] = []
    var launchTemplates: [String] = []

    for file in manifest.files {
      let sourceURL = safeURL(root: roots.helperResourcesDirectory, components: try relativeComponents(file.sourceRelativePath))
      let stagedTarget = try stagedURL(for: file, under: stagingURL)
      try fileManager.createDirectory(at: stagedTarget.deletingLastPathComponent(), withIntermediateDirectories: true)
      let content: Data
      if file.role == .launchAgentTemplate || file.role == .appSupportTemplate {
        let template = String(data: try Data(contentsOf: sourceURL), encoding: .utf8) ?? ""
        content = renderTemplate(template).data(using: .utf8) ?? Data()
      } else {
        content = try Data(contentsOf: sourceURL)
      }
      try writeSynced(content, to: stagedTarget, mode: file.mode)
      let installed = try InstalledFile(role: file.role, installRelativePath: file.installRelativePath, targetPath: targetURL(for: file).path)
      installedFiles.append(installed)
      if file.role == .launchAgentTemplate {
        launchTemplates.append(file.installRelativePath)
      }
    }

    try writeActivationPlan(version: manifest.helperSetVersion, templates: launchTemplates, under: stagingURL)
    return installedFiles
  }

  private func createSnapshot(for installedFiles: [InstalledFile], at snapshotURL: URL) throws {
    try removeIfExists(snapshotURL)
    try fileManager.createDirectory(at: snapshotURL, withIntermediateDirectories: true)
    if fileManager.fileExists(atPath: roots.binDirectory.path) {
      guard !isSymlink(roots.binDirectory) else { throw HelperMigrationError.symlinkRejected(roots.binDirectory.path) }
      try copyDirectory(from: roots.binDirectory, to: snapshotURL.appendingPathComponent("bin", isDirectory: true))
    }
    let launchTargets = installedFiles.filter { $0.role == .launchAgentTemplate }
    if !launchTargets.isEmpty {
      let launchSnapshot = snapshotURL.appendingPathComponent("LaunchAgents", isDirectory: true)
      try fileManager.createDirectory(at: launchSnapshot, withIntermediateDirectories: true)
      for file in launchTargets {
        let target = URL(fileURLWithPath: file.targetPath)
        if fileManager.fileExists(atPath: target.path) {
          guard !isSymlink(target) else { throw HelperMigrationError.symlinkRejected(target.path) }
          try checkedCopyFile(from: target, to: launchSnapshot.appendingPathComponent(target.lastPathComponent), mode: try posixMode(target))
        }
      }
    }
  }

  private func swapStagedFiles(journal: Journal) throws {
    let stagingURL = URL(fileURLWithPath: journal.stagingPath, isDirectory: true)
    let oldBinURL = URL(fileURLWithPath: journal.oldBinPath, isDirectory: true)
    let stagedBin = stagingURL.appendingPathComponent("bin", isDirectory: true)
    if fileManager.fileExists(atPath: stagedBin.path) {
      try rejectSymlinks(from: roots.appSupportDirectory, through: ["bin"], includeLeaf: true)
      if !fileManager.fileExists(atPath: roots.binDirectory.path) {
        try checkedMoveItem(at: stagedBin, to: roots.binDirectory)
      } else if !fileManager.fileExists(atPath: oldBinURL.path) {
        try checkedMoveItem(at: roots.binDirectory, to: oldBinURL)
        try checkedMoveItem(at: stagedBin, to: roots.binDirectory)
      }
    } else if !fileManager.fileExists(atPath: roots.binDirectory.path), fileManager.fileExists(atPath: oldBinURL.path) {
      try checkedMoveItem(at: oldBinURL, to: roots.binDirectory)
      throw HelperMigrationError.invalidManifest("interrupted swap restored previous bin because staged bin was missing")
    }

    let stagedLaunchAgents = stagingURL.appendingPathComponent("LaunchAgents", isDirectory: true)
    if fileManager.fileExists(atPath: stagedLaunchAgents.path) {
      try fileManager.createDirectory(at: roots.launchAgentDirectory, withIntermediateDirectories: true)
      let files = try fileManager.contentsOfDirectory(at: stagedLaunchAgents, includingPropertiesForKeys: nil)
      for source in files where source.pathExtension == "plist" {
        guard allowedLaunchAgentNames.contains(source.lastPathComponent) else {
          throw HelperMigrationError.forbiddenPath(source.lastPathComponent)
        }
        let target = roots.launchAgentDirectory.appendingPathComponent(source.lastPathComponent)
        try checkedCopyFile(from: source, to: target, mode: 0o644)
      }
    }

    let stagedActivation = stagingURL.appendingPathComponent("launchagent-activation.json")
    if fileManager.fileExists(atPath: stagedActivation.path) {
      try checkedCopyFile(from: stagedActivation, to: roots.activationPlanURL, mode: 0o644)
    }
  }

  private func finishMigration(journal: Journal) throws {
    try writeInstalledReceipt(version: journal.targetVersion, files: journal.installedFiles)
    try removeIfExists(URL(fileURLWithPath: journal.stagingPath, isDirectory: true))
    try removeIfExists(URL(fileURLWithPath: journal.oldBinPath, isDirectory: true))
    try removeIfExists(roots.journalURL)
  }

  private func currentInstalledVersion() throws -> String? {
    guard fileManager.fileExists(atPath: roots.installedReceiptURL.path) else { return nil }
    return try JSONDecoder().decode(InstalledReceipt.self, from: Data(contentsOf: roots.installedReceiptURL)).version
  }

  private func latestSnapshot() throws -> URL? {
    guard fileManager.fileExists(atPath: roots.snapshotsDirectory.path) else { return nil }
    let snapshots = try fileManager.contentsOfDirectory(at: roots.snapshotsDirectory, includingPropertiesForKeys: [.contentModificationDateKey])
      .filter { $0.lastPathComponent.hasPrefix("snapshot-") }
    return try snapshots.sorted {
      let left = try $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
      let right = try $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
      return left > right
    }.first
  }

  private func writeInstalledReceipt(version: String, files: [InstalledFile]) throws {
    let receipt = InstalledReceipt(version: version, installedAt: iso8601(now()), files: files)
    let data = try JSONEncoder.pretty.encode(receipt)
    try fileManager.createDirectory(at: roots.migrationDirectory, withIntermediateDirectories: true)
    try data.write(to: roots.installedReceiptURL, options: .atomic)
    try synchronizeFile(roots.installedReceiptURL)
  }

  private func writeActivationPlan(version: String, templates: [String], under root: URL? = nil) throws {
    let plan = LaunchAgentActivationPlan(
      helperSetVersion: version,
      generatedAt: iso8601(now()),
      templatesInstalled: templates,
      note: "LaunchAgent templates are installed only after helper migration reaches safe installation. This plan does not call launchctl."
    )
    let target = (root ?? roots.migrationDirectory).appendingPathComponent("launchagent-activation.json")
    let data = try JSONEncoder.pretty.encode(plan)
    try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: target, options: .atomic)
    try synchronizeFile(target)
  }

  private func writeJournal(_ journal: Journal) throws {
    try fileManager.createDirectory(at: roots.migrationDirectory, withIntermediateDirectories: true)
    let data = try JSONEncoder.pretty.encode(journal)
    try data.write(to: roots.journalURL, options: .atomic)
    try synchronizeFile(roots.journalURL)
  }

  private func prepareRootDirectories() throws {
    try rejectExistingRootSymlink(roots.appSupportDirectory)
    try rejectExistingRootSymlink(roots.launchAgentDirectory)
    try fileManager.createDirectory(at: roots.appSupportDirectory, withIntermediateDirectories: true)
    try rejectExistingRootSymlink(roots.stateDirectory)
    try fileManager.createDirectory(at: roots.stateDirectory, withIntermediateDirectories: true)
    try rejectExistingRootSymlink(roots.migrationDirectory)
    try fileManager.createDirectory(at: roots.migrationDirectory, withIntermediateDirectories: true)
    try rejectExistingRootSymlink(roots.snapshotsDirectory)
    try fileManager.createDirectory(at: roots.snapshotsDirectory, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: roots.launchAgentDirectory, withIntermediateDirectories: true)
  }

  private func stagedURL(for file: HelperMigrationManifest.File, under stagingURL: URL) throws -> URL {
    switch file.role {
    case .appSupportBin:
      return safeURL(root: stagingURL.appendingPathComponent("bin", isDirectory: true), components: try relativeComponents(file.installRelativePath))
    case .launchAgentTemplate:
      return safeURL(root: stagingURL.appendingPathComponent("LaunchAgents", isDirectory: true), components: try relativeComponents(file.installRelativePath))
    case .appSupportTemplate:
      return safeURL(root: stagingURL.appendingPathComponent("templates", isDirectory: true), components: Array(try relativeComponents(file.installRelativePath).dropFirst()))
    }
  }

  private func targetURL(for file: HelperMigrationManifest.File) throws -> URL {
    switch file.role {
    case .appSupportBin:
      return safeURL(root: roots.binDirectory, components: try relativeComponents(file.installRelativePath))
    case .launchAgentTemplate:
      return safeURL(root: roots.launchAgentDirectory, components: try relativeComponents(file.installRelativePath))
    case .appSupportTemplate:
      return safeURL(root: roots.appSupportDirectory, components: try relativeComponents(file.installRelativePath))
    }
  }

  private func renderTemplate(_ template: String) -> String {
    template
      .replacingOccurrences(of: "{{APP_SUPPORT_DIR}}", with: roots.appSupportDirectory.path)
      .replacingOccurrences(of: "{{BIN_DIR}}", with: roots.binDirectory.path)
      .replacingOccurrences(of: "{{LOG_DIR}}", with: roots.appSupportDirectory.appendingPathComponent("logs", isDirectory: true).path)
  }

  private func relativeComponents(_ path: String) throws -> [String] {
    guard !path.isEmpty, !path.hasPrefix("/") else { throw HelperMigrationError.invalidRelativePath(path) }
    let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    guard !parts.isEmpty else { throw HelperMigrationError.invalidRelativePath(path) }
    let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
    for part in parts {
      if part.isEmpty || part == "." || part == ".." {
        throw HelperMigrationError.invalidRelativePath(path)
      }
      guard part.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
        throw HelperMigrationError.invalidRelativePath(path)
      }
    }
    return parts
  }

  private func safeURL(root: URL, components: [String]) -> URL {
    components.reduce(root) { $0.appendingPathComponent($1) }
  }

  private func rejectSymlinks(from root: URL, through components: [String], includeLeaf: Bool) throws {
    var current = root
    guard !isSymlink(root) else { throw HelperMigrationError.symlinkRejected(root.path) }
    let checked = includeLeaf ? components : Array(components.dropLast())
    for component in checked {
      current = current.appendingPathComponent(component)
      if isSymlink(current) {
        throw HelperMigrationError.symlinkRejected(current.path)
      }
    }
  }

  private func isSymlink(_ url: URL) -> Bool {
    (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
  }

  private func isRegularFile(_ url: URL) -> Bool {
    guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
    return values.isRegularFile == true && values.isSymbolicLink != true
  }

  private func posixMode(_ url: URL) throws -> Int {
    let attrs = try fileManager.attributesOfItem(atPath: url.path)
    let value = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
    return value & 0o777
  }

  private func checkedMoveItem(at source: URL, to target: URL) throws {
    guard !isSymlink(source) else { throw HelperMigrationError.symlinkRejected(source.path) }
    try rejectSymlinks(from: target.deletingLastPathComponent(), through: [target.lastPathComponent], includeLeaf: false)
    try removeIfExists(target)
    try fileManager.moveItem(at: source, to: target)
  }

  private func checkedCopyFile(from source: URL, to target: URL, mode: Int) throws {
    guard !isSymlink(source) else { throw HelperMigrationError.symlinkRejected(source.path) }
    try rejectSymlinks(from: target.deletingLastPathComponent(), through: [target.lastPathComponent], includeLeaf: false)
    try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    try removeIfExists(target)
    try fileManager.copyItem(at: source, to: target)
    try fileManager.setAttributes([.posixPermissions: mode], ofItemAtPath: target.path)
    try synchronizeFile(target)
  }

  private func copyDirectory(from source: URL, to target: URL) throws {
    guard !isSymlink(source) else { throw HelperMigrationError.symlinkRejected(source.path) }
    try rejectRecursiveSymlinks(source)
    try removeIfExists(target)
    try fileManager.copyItem(at: source, to: target)
  }

  private func writeSynced(_ data: Data, to target: URL, mode: Int) throws {
    try data.write(to: target, options: .atomic)
    try fileManager.setAttributes([.posixPermissions: mode], ofItemAtPath: target.path)
    try synchronizeFile(target)
  }

  private func synchronizeFile(_ url: URL) throws {
    if let handle = try? FileHandle(forWritingTo: url) {
      if #available(macOS 10.15.4, *) {
        try handle.synchronize()
        try handle.close()
      } else {
        handle.synchronizeFile()
        handle.closeFile()
      }
    }
  }

  private func removeIfExists(_ url: URL) throws {
    if isSymlink(url) {
      guard url.path.hasPrefix(roots.migrationDirectory.path) else {
        throw HelperMigrationError.symlinkRejected(url.path)
      }
      try fileManager.removeItem(at: url)
      return
    }
    if fileManager.fileExists(atPath: url.path) {
      try fileManager.removeItem(at: url)
    }
  }

  private func rejectRecursiveSymlinks(_ root: URL) throws {
    guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey]) else {
      return
    }
    for case let item as URL in enumerator {
      if isSymlink(item) {
        throw HelperMigrationError.symlinkRejected(item.path)
      }
    }
  }

  private func rejectExistingRootSymlink(_ url: URL) throws {
    if isSymlink(url) {
      throw HelperMigrationError.symlinkRejected(url.path)
    }
  }

  private func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
    let left = lhs.split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 }
    let right = rhs.split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 }
    let count = max(left.count, right.count)
    for index in 0..<count {
      let l = index < left.count ? left[index] : 0
      let r = index < right.count ? right[index] : 0
      if l < r { return .orderedAscending }
      if l > r { return .orderedDescending }
    }
    return .orderedSame
  }

  private func iso8601(_ date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
  }
}

private extension JSONEncoder {
  static var pretty: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
  }
}
