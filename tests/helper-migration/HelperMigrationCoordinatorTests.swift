import Foundation

private final class TestLeaseProvider: HelperMigrationIngestLeaseProviding {
  var lease: HelperMigrationIngestLease

  init(_ lease: HelperMigrationIngestLease) {
    self.lease = lease
  }

  func currentIngestLease() throws -> HelperMigrationIngestLease {
    lease
  }
}

@main
enum HelperMigrationCoordinatorTests {
  private static let fm = FileManager.default
  private static var failures = 0

  static func main() throws {
    try run("success installs helpers only at safe idle", testSuccessInstall)
    try run("active ingest defers migration", testActiveRunDeferral)
    try run("tamper traversal symlink and permission rejection", testManifestRejections)
    try run("customer config state logs receipts are preserved", testPreservation)
    try run("interrupted pre-swap and post-swap recovery", testInterruptedRecovery)
    try run("rollback and forward fix", testRollbackAndForwardFix)
    try run("bundled v1 resource manifest validates", testBundledResourceManifest)

    guard failures == 0 else {
      fputs("FAIL: \(failures) helper migration test(s) failed.\n", stderr)
      exit(1)
    }
    print("PASS: helper migration coordinator")
  }

  private static func run(_ name: String, _ body: () throws -> Void) throws {
    do {
      try body()
      print("PASS: \(name)")
    } catch {
      failures += 1
      fputs("FAIL: \(name): \(error)\n", stderr)
    }
  }

  private static func testSuccessInstall() throws {
    let fixture = try Fixture(version: "1.0.0")
    try fixture.seedExistingInstall()
    let result = try fixture.coordinator.migrate(manifestURL: fixture.manifestURL)
    expect(result == .installed(version: "1.0.0"), "expected install result")
    expect(fm.fileExists(atPath: fixture.appSupport.appendingPathComponent("bin/ddump-test.sh").path), "helper script installed")
    expect(try mode(fixture.appSupport.appendingPathComponent("bin/ddump-test.sh")) == 0o755, "helper script is executable")
    let launchAgent = try String(contentsOf: fixture.launchAgents.appendingPathComponent("com.ddump.plist"), encoding: .utf8)
    expect(launchAgent.contains(fixture.appSupport.path), "LaunchAgent template rendered app support path")
    expect(fm.fileExists(atPath: fixture.appSupport.appendingPathComponent("state/helper-migration/launchagent-activation.json").path), "activation plan written")
    expect(!launchAgent.contains("{{BIN_DIR}}"), "LaunchAgent template placeholders rendered")
    expect(fm.fileExists(atPath: fixture.appSupport.appendingPathComponent("state/helper-migration/snapshots/snapshot-none/bin/old-helper.sh").path), "previous helper snapshot preserved")
  }

  private static func testActiveRunDeferral() throws {
    let fixture = try Fixture(version: "1.0.0", safeIdle: false, phase: "copying")
    try write("old", to: fixture.appSupport.appendingPathComponent("bin/old-helper.sh"), mode: 0o755)
    let result = try fixture.coordinator.migrate(manifestURL: fixture.manifestURL)
    expect(result == .deferred(phase: "copying"), "expected deferral while copying")
    expect(fm.fileExists(atPath: fixture.appSupport.appendingPathComponent("bin/old-helper.sh").path), "old helper preserved during deferral")
    expect(!fm.fileExists(atPath: fixture.appSupport.appendingPathComponent("state/helper-migration/installed.json").path), "no receipt written during deferral")
  }

  private static func testManifestRejections() throws {
    let tamper = try Fixture(version: "1.0.0")
    try write("#!/bin/bash\necho tampered\n", to: tamper.resources.appendingPathComponent("bin/ddump-test.sh"), mode: 0o755)
    try expectThrows(HelperMigrationError.checksumMismatch(path: "bin/ddump-test.sh", expected: "", actual: "")) {
      _ = try tamper.coordinator.migrate(manifestURL: tamper.manifestURL)
    }

    let traversal = try Fixture(version: "1.0.0")
    try traversal.writeManifest(files: [
      traversal.file(role: .appSupportBin, source: "../evil.sh", install: "ddump-test.sh", sha: String(repeating: "0", count: 64), mode: 0o755)
    ])
    try expectThrows(HelperMigrationError.invalidRelativePath("../evil.sh")) {
      _ = try traversal.coordinator.migrate(manifestURL: traversal.manifestURL)
    }

    let symlink = try Fixture(version: "1.0.0")
    let real = symlink.resources.appendingPathComponent("bin/real.sh")
    try write("#!/bin/bash\necho real\n", to: real, mode: 0o755)
    let link = symlink.resources.appendingPathComponent("bin/ddump-test.sh")
    try fm.removeItem(at: link)
    try fm.createSymbolicLink(at: link, withDestinationURL: real)
    try expectThrows(HelperMigrationError.symlinkRejected(link.path)) {
      _ = try symlink.coordinator.migrate(manifestURL: symlink.manifestURL)
    }

    let badMode = try Fixture(version: "1.0.0")
    try write("#!/bin/bash\necho bad mode\n", to: badMode.resources.appendingPathComponent("bin/ddump-test.sh"), mode: 0o644)
    let sha = try Shasum256Verifier().sha256Hex(of: badMode.resources.appendingPathComponent("bin/ddump-test.sh"))
    try badMode.writeManifest(files: [
      badMode.file(role: .appSupportBin, source: "bin/ddump-test.sh", install: "ddump-test.sh", sha: sha, mode: 0o755)
    ])
    try expectThrows(HelperMigrationError.permissionMismatch(path: "bin/ddump-test.sh", expected: 0o755, actual: 0o644)) {
      _ = try badMode.coordinator.migrate(manifestURL: badMode.manifestURL)
    }

    let targetSymlink = try Fixture(version: "1.0.0")
    try fm.createDirectory(at: targetSymlink.appSupport, withIntermediateDirectories: true)
    try fm.createSymbolicLink(
      at: targetSymlink.appSupport.appendingPathComponent("bin"),
      withDestinationURL: targetSymlink.root.appendingPathComponent("outside-bin")
    )
    try expectThrows(HelperMigrationError.symlinkRejected(targetSymlink.appSupport.appendingPathComponent("bin").path)) {
      _ = try targetSymlink.coordinator.migrate(manifestURL: targetSymlink.manifestURL)
    }
  }

  private static func testPreservation() throws {
    let fixture = try Fixture(version: "1.0.0")
    let preserved = [
      fixture.appSupport.appendingPathComponent("config.env"),
      fixture.appSupport.appendingPathComponent("state/import-state.env"),
      fixture.appSupport.appendingPathComponent("logs/ddump.log"),
      fixture.appSupport.appendingPathComponent("receipts/upload.json"),
      fixture.appSupport.appendingPathComponent("customer/final-file.txt")
    ]
    for url in preserved {
      try write("preserve \(url.lastPathComponent)", to: url, mode: 0o644)
    }
    _ = try fixture.coordinator.migrate(manifestURL: fixture.manifestURL)
    for url in preserved {
      let content = try String(contentsOf: url, encoding: .utf8)
      expect(content.hasPrefix("preserve"), "\(url.path) preserved")
    }
  }

  private static func testInterruptedRecovery() throws {
    let pre = try Fixture(version: "1.0.0")
    try pre.writeJournal(phase: "staged", targetVersion: "1.0.0", stageHasBin: true)
    let preResult = try pre.coordinator.recoverInterruptedMigration()
    expect(preResult == .recoveredPreSwap(version: "none"), "pre-swap recovery reported")
    expect(!fm.fileExists(atPath: pre.appSupport.appendingPathComponent("state/helper-migration/journal.json").path), "pre-swap journal removed")
    expect(!fm.fileExists(atPath: pre.appSupport.appendingPathComponent("state/helper-migration/stage-test").path), "pre-swap staging removed")

    let post = try Fixture(version: "2.0.0")
    try post.writeJournal(phase: "swapping", targetVersion: "2.0.0", stageHasBin: true)
    let postResult = try post.coordinator.recoverInterruptedMigration()
    expect(postResult == .recoveredPostSwap(version: "2.0.0"), "post-swap recovery reported")
    expect(fm.fileExists(atPath: post.appSupport.appendingPathComponent("bin/recovered.sh").path), "post-swap staged bin completed")
    let receipt = try String(contentsOf: post.appSupport.appendingPathComponent("state/helper-migration/installed.json"), encoding: .utf8)
    expect(receipt.contains("\"version\" : \"2.0.0\""), "post-swap recovery receipt written")
  }

  private static func testRollbackAndForwardFix() throws {
    let fixture = try Fixture(version: "1.0.0")
    _ = try fixture.coordinator.migrate(manifestURL: fixture.manifestURL)

    try fixture.replacePayload(version: "2.0.0", scriptText: "#!/bin/bash\necho v2\n")
    _ = try fixture.coordinator.migrate(manifestURL: fixture.manifestURL)
    let v2Content = try String(contentsOf: fixture.appSupport.appendingPathComponent("bin/ddump-test.sh"), encoding: .utf8)
    expect(v2Content.contains("v2"), "forward fix installed newer helper")

    let rollback = try fixture.coordinator.rollbackToPreviousSnapshot()
    expect(rollback == .rolledBack(version: "1.0.0"), "rollback reported previous version")
    let rolledBackContent = try String(contentsOf: fixture.appSupport.appendingPathComponent("bin/ddump-test.sh"), encoding: .utf8)
    expect(rolledBackContent.contains("v1"), "rollback restored previous helper")
  }

  private static func testBundledResourceManifest() throws {
    guard let projectDir = ProcessInfo.processInfo.environment["DDUMP_PROJECT_DIR"] else {
      throw TestError("DDUMP_PROJECT_DIR is required")
    }
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ddump-helper-bundled-\(UUID().uuidString)", isDirectory: true)
    let appSupport = root.appendingPathComponent("Application Support/DDump", isDirectory: true)
    let launchAgents = root.appendingPathComponent("LaunchAgents", isDirectory: true)
    let resources = URL(fileURLWithPath: projectDir).appendingPathComponent("resources/helpers/v1", isDirectory: true)
    let coordinator = HelperMigrationCoordinator(
      roots: .init(appSupportDirectory: appSupport, launchAgentDirectory: launchAgents, helperResourcesDirectory: resources),
      leaseProvider: TestLeaseProvider(HelperMigrationIngestLease(verifiedSafeIdle: true, phase: "safe-idle"))
    )
    let result = try coordinator.migrate(manifestURL: resources.appendingPathComponent("helper-manifest.json"))
    expect(result == .installed(version: "1.0.0"), "bundled v1 manifest installed")
    expect(fm.fileExists(atPath: appSupport.appendingPathComponent("bin/ddump-helper-migration-smoke.sh").path), "bundled helper smoke script installed")
  }

  private static func expect(_ condition: Bool, _ message: String) {
    if !condition {
      failures += 1
      fputs("FAIL: \(message)\n", stderr)
    }
  }

  private static func expectThrows(_ expected: HelperMigrationError, body: () throws -> Void) throws {
    do {
      try body()
      failures += 1
      fputs("FAIL: expected throw \(expected)\n", stderr)
    } catch let error as HelperMigrationError {
      switch (expected, error) {
      case (.checksumMismatch, .checksumMismatch),
           (.invalidRelativePath, .invalidRelativePath),
           (.symlinkRejected, .symlinkRejected),
           (.permissionMismatch, .permissionMismatch):
        return
      default:
        failures += 1
        fputs("FAIL: expected \(expected), got \(error)\n", stderr)
      }
    }
  }

  private static func write(_ text: String, to url: URL, mode: Int) throws {
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.data(using: .utf8)!.write(to: url)
    try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
  }

  private static func mode(_ url: URL) throws -> Int {
    let attrs = try fm.attributesOfItem(atPath: url.path)
    return ((attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o777
  }

  private struct TestError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) {
      self.description = description
    }
  }

  private struct Fixture {
    let root: URL
    let appSupport: URL
    let launchAgents: URL
    let resources: URL
    let manifestURL: URL
    let coordinator: HelperMigrationCoordinator

    init(version: String, safeIdle: Bool = true, phase: String = "safe-idle") throws {
      root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ddump-helper-tests-\(UUID().uuidString)", isDirectory: true)
      appSupport = root.appendingPathComponent("Application Support/DDump", isDirectory: true)
      launchAgents = root.appendingPathComponent("LaunchAgents", isDirectory: true)
      resources = root.appendingPathComponent("Resources/helpers", isDirectory: true)
      manifestURL = resources.appendingPathComponent("helper-manifest.json")
      try fm.createDirectory(at: resources, withIntermediateDirectories: true)
      let lease = TestLeaseProvider(HelperMigrationIngestLease(verifiedSafeIdle: safeIdle, phase: phase))
      coordinator = HelperMigrationCoordinator(
        roots: .init(appSupportDirectory: appSupport, launchAgentDirectory: launchAgents, helperResourcesDirectory: resources),
        leaseProvider: lease
      )
      try replacePayload(version: version, scriptText: "#!/bin/bash\necho v1\n")
    }

    func seedExistingInstall() throws {
      try HelperMigrationCoordinatorTests.write("#!/bin/bash\necho old\n", to: appSupport.appendingPathComponent("bin/old-helper.sh"), mode: 0o755)
      try HelperMigrationCoordinatorTests.write("old launch agent", to: launchAgents.appendingPathComponent("com.ddump.plist"), mode: 0o644)
    }

    func replacePayload(version: String, scriptText: String) throws {
      try HelperMigrationCoordinatorTests.write(scriptText, to: resources.appendingPathComponent("bin/ddump-test.sh"), mode: 0o755)
      try HelperMigrationCoordinatorTests.write("""
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0">
      <dict>
        <key>Label</key>
        <string>com.ddump</string>
        <key>ProgramArguments</key>
        <array>
          <string>/bin/bash</string>
          <string>{{BIN_DIR}}/ddump-test.sh</string>
        </array>
        <key>StandardOutPath</key>
        <string>{{LOG_DIR}}/launchd.out.log</string>
      </dict>
      </plist>
      """, to: resources.appendingPathComponent("LaunchAgents/com.ddump.plist"), mode: 0o644)
      let scriptSHA = try Shasum256Verifier().sha256Hex(of: resources.appendingPathComponent("bin/ddump-test.sh"))
      let plistSHA = try Shasum256Verifier().sha256Hex(of: resources.appendingPathComponent("LaunchAgents/com.ddump.plist"))
      try writeManifest(version: version, files: [
        file(role: .appSupportBin, source: "bin/ddump-test.sh", install: "ddump-test.sh", sha: scriptSHA, mode: 0o755),
        file(role: .launchAgentTemplate, source: "LaunchAgents/com.ddump.plist", install: "com.ddump.plist", sha: plistSHA, mode: 0o644)
      ])
    }

    func file(
      role: HelperMigrationManifest.File.Role,
      source: String,
      install: String,
      sha: String,
      mode: Int
    ) -> HelperMigrationManifest.File {
      HelperMigrationManifest.File(
        role: role,
        sourceRelativePath: source,
        installRelativePath: install,
        sha256: sha,
        mode: mode,
        signing: nil
      )
    }

    func writeManifest(version: String = "1.0.0", files: [HelperMigrationManifest.File]) throws {
      let manifest = HelperMigrationManifest(
        schemaVersion: 1,
        helperSetVersion: version,
        minimumAppVersion: "0.3.18",
        createdAt: "2026-09-01T00:00:00Z",
        forwardFixForVersions: [],
        preservePreviousSnapshot: true,
        files: files
      )
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try encoder.encode(manifest).write(to: manifestURL)
    }

    func writeJournal(phase: String, targetVersion: String, stageHasBin: Bool) throws {
      let migrationRoot = appSupport.appendingPathComponent("state/helper-migration", isDirectory: true)
      let stage = migrationRoot.appendingPathComponent("stage-test", isDirectory: true)
      let oldBin = migrationRoot.appendingPathComponent("old-bin-test", isDirectory: true)
      try fm.createDirectory(at: migrationRoot, withIntermediateDirectories: true)
      if stageHasBin {
        try HelperMigrationCoordinatorTests.write("#!/bin/bash\necho recovered\n", to: stage.appendingPathComponent("bin/recovered.sh"), mode: 0o755)
      }
      let journal: [String: Any] = [
        "migrationID": "test",
        "targetVersion": targetVersion,
        "previousVersion": "none",
        "phase": phase,
        "stagingPath": stage.path,
        "snapshotPath": migrationRoot.appendingPathComponent("snapshots/snapshot-none").path,
        "oldBinPath": oldBin.path,
        "installedFiles": [
          [
            "role": "appSupportBin",
            "installRelativePath": "recovered.sh",
            "targetPath": appSupport.appendingPathComponent("bin/recovered.sh").path
          ]
        ]
      ]
      let data = try JSONSerialization.data(withJSONObject: journal, options: [.prettyPrinted, .sortedKeys])
      try data.write(to: migrationRoot.appendingPathComponent("journal.json"))
    }
  }
}
