// DDumpApp.swift — the DDump Mac app.
//
// Architecture: the actual import work happens in ddump.sh (invoked by the
// com.ddump LaunchAgent on card mount). This Swift app is the UI shell:
// it reads the script's run_status.env for live progress, edits config.env
// for settings, writes control flags (pause/stop/eject) the script polls.
//
// Build (from the workspace's app/ directory):
//   swiftc -parse-as-library -o DDump DDumpApp.swift
// Then bundle into DDump.app with Contents/Info.plist + Contents/MacOS/DDump.

import SwiftUI
import AppKit
import Foundation
import CoreText
import EventKit
import UserNotifications

extension View {
  @ViewBuilder
  func ddumpOnChange<Value: Equatable>(of value: Value, perform action: @escaping (Value) -> Void) -> some View {
    if #available(macOS 14.0, *) {
      self.onChange(of: value) { _, newValue in
        action(newValue)
      }
    } else {
      self.onChange(of: value, perform: action)
    }
  }
}

// MARK: - Paths

enum DDumpPaths {
  static let appSupport: URL = {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return base.appendingPathComponent("DDump")
  }()
  static var statusFile: URL { appSupport.appendingPathComponent("state/run_status.env") }
  static var configFile: URL { appSupport.appendingPathComponent("config.env") }
  static var logFile: URL { appSupport.appendingPathComponent("logs/ddump.log") }
  static var reportsDir: URL { appSupport.appendingPathComponent("reports") }
  static var pendingDir: URL { appSupport.appendingPathComponent("state/pending_uploads") }
  static var lastSkippedVolumeFile: URL { appSupport.appendingPathComponent("state/last_skipped_volume.env") }
  static var appNotificationQueue: URL { appSupport.appendingPathComponent("state/app_notifications.tsv") }
  static var scriptFile: URL { appSupport.appendingPathComponent("bin/ddump.sh") }
  static var controlDir: URL { appSupport.appendingPathComponent("state/control") }
  static var manualSelectionFile: URL { appSupport.appendingPathComponent("state/manual_selection.paths") }
  static var manualSelectionPolicyFile: URL { controlDir.appendingPathComponent("manual_import_policy.txt") }
  static var manualShootNameFile: URL { controlDir.appendingPathComponent("manual_shoot_name.txt") }
  static var lockDir: URL { appSupport.appendingPathComponent("state/run.lock") }
  static var pauseFlag: URL { controlDir.appendingPathComponent("pause.flag") }
  static var viewOnlyFlag: URL { controlDir.appendingPathComponent("view_only.flag") }
  static var viewOnlyUntilFile: URL { controlDir.appendingPathComponent("view_only_until_epoch.txt") }
  static var stopFlag: URL { controlDir.appendingPathComponent("stop_after_file.flag") }
  static var keepMountedFlag: URL { controlDir.appendingPathComponent("keep_mounted.flag") }
  static var appCloudKeepaliveFile: URL { controlDir.appendingPathComponent("app_cloud_keepalive.touch") }
  static var ejectNowFlag: URL { controlDir.appendingPathComponent("eject_now.flag") }
  static var googleCalendarHelper: URL { appSupport.appendingPathComponent("bin/ddump-google-calendar.py") }
  static var appleCalendarCache: URL { appSupport.appendingPathComponent("state/calendar_events.tsv") }
}

func registerBundledFonts() {
  guard let resourceRoot = Bundle.main.resourceURL else { return }
  let fontsDir = resourceRoot.appendingPathComponent("Fonts")
  guard let files = try? FileManager.default.contentsOfDirectory(at: fontsDir, includingPropertiesForKeys: nil) else {
    return
  }
  for file in files where file.pathExtension.lowercased() == "otf" {
    CTFontManagerRegisterFontsForURL(file as CFURL, .process, nil)
  }
}

// MARK: - Shell config / status parsing

func parseShellEnv(_ text: String) -> [String: String] {
  var out: [String: String] = [:]
  for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
    let line = raw.trimmingCharacters(in: .whitespaces)
    if line.hasPrefix("#") || line.isEmpty { continue }
    guard let eq = line.firstIndex(of: "=") else { continue }
    let key = String(line[..<eq])
    var val = String(line[line.index(after: eq)...])
    if val.hasPrefix("\"") && val.hasSuffix("\"") && val.count >= 2 {
      val = String(val.dropFirst().dropLast())
    }
    out[key] = val
  }
  return out
}

func readShellEnv(at url: URL) -> [String: String] {
  guard let s = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
  return parseShellEnv(s)
}

func expandConfiguredPath(_ value: String) -> String {
  var expanded = value
  if expanded.hasPrefix("\\$HOME/") {
    expanded = NSHomeDirectory() + "/" + expanded.dropFirst("\\$HOME/".count)
  } else if expanded.hasPrefix("$HOME/") {
    expanded = NSHomeDirectory() + "/" + expanded.dropFirst("$HOME/".count)
  } else if expanded == "\\$HOME" || expanded == "$HOME" {
    expanded = NSHomeDirectory()
  }
  return NSString(string: expanded).expandingTildeInPath
}

func shellDoubleQuoted(_ value: String) -> String {
  var out = ""
  for ch in value {
    switch ch {
    case "\\":
      out += "\\\\"
    case "\"":
      out += "\\\""
    case "$":
      out += "\\$"
    case "`":
      out += "\\`"
    case "\n", "\r":
      out += " "
    default:
      out.append(ch)
    }
  }
  return "\"\(out)\""
}

/// Writes a single key back to a shell-style config file, replacing or appending.
func writeShellConfig(key: String, value: String, at url: URL) {
  let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
  var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
  let needle = "\(key)="
  var found = false
  for i in lines.indices {
    let stripped = lines[i].trimmingCharacters(in: .whitespaces)
    if stripped.hasPrefix(needle) {
      lines[i] = "\(key)=\(shellDoubleQuoted(value))"
      found = true
      break
    }
  }
  if !found {
    if !lines.isEmpty && !lines.last!.isEmpty { lines.append("") }
    lines.append("\(key)=\(shellDoubleQuoted(value))")
  }
  let joined = lines.joined(separator: "\n")
  try? joined.write(to: url, atomically: true, encoding: .utf8)
}

// MARK: - App state

struct SkippedVolumeNotice {
  let volume: String
  let path: String
  let reason: String
  let detail: String
  let hint: String
  let epoch: TimeInterval

  var isRecent: Bool {
    epoch > 0 && Date().timeIntervalSince1970 - epoch < 60 * 60
  }
}

struct CalendarChoice: Identifiable, Hashable {
  let id: String
  let title: String
  let source: String

  var displayName: String {
    source.isEmpty ? title : "\(title) — \(source)"
  }
}

final class AppState: ObservableObject {
  @Published var phase: String = "idle"
  @Published var message: String = "Waiting for a card…"
  @Published var volume: String = ""
  @Published var total: Int = 0
  @Published var processed: Int = 0
  @Published var imported: Int = 0
  @Published var skipped: Int = 0
  @Published var failed: Int = 0
  @Published var uploadTotal: Int = 0
  @Published var uploadDone: Int = 0
  @Published var uploadFailed: Int = 0
  @Published var uploadPercent: Double = 0
  @Published var uploadSpeed: String = ""
  @Published var uploadETA: String = ""
  @Published var uploadTarget: String = ""
  @Published var uploadItem: String = ""
  @Published var uploadLastError: String = ""
  @Published var cardEjected: Bool = false
  @Published var ejectStatus: String = "pending"
  @Published var startedEpoch: TimeInterval = 0
  @Published var updatedAt: String = ""
  @Published var config: [String: String] = [:]
  @Published var paused: Bool = false
  @Published var viewOnlyMode: Bool = false
  @Published var viewOnlyUntilEpoch: TimeInterval = 0
  @Published var stopRequested: Bool = false
  @Published var ejectQueued: Bool = false
  @Published var keepMountedRequested: Bool = false
  @Published var runActive: Bool = false
  @Published var pendingUploadCount: Int = 0
  @Published var needsReinsertCount: Int = 0
  @Published var localFreeGB: Int = 0
  @Published var stagingFolderCount: Int = 0
  @Published var lastUtilityMessage: String = ""
  @Published var cloudMountActive: Bool = false
  @Published var cloudServiceLoaded: Bool = false
  @Published var cloudRcloneReady: Bool = false
  @Published var cloudRemoteConfigured: Bool = false
  @Published var cloudDiagnosticMessage: String = ""
  @Published var cloudActionInProgress: Bool = false
  @Published var cloudActionMessage: String = ""
  @Published var cloudLastCheckedAt: String = ""
  @Published var networkOnline: Bool = false
  @Published var cloudSetupBrowserRunning: Bool = false
  @Published var onboardingRestartRequested: Bool = false
  @Published var skippedVolumeNotice: SkippedVolumeNotice?
  @Published var appleCalendars: [CalendarChoice] = []
  @Published var macOSNotificationAuthorization: UNAuthorizationStatus = .notDetermined

  private var timer: Timer?
  private var mountKeepaliveTimer: Timer?
  private var statusTick: Int = 0
  private var cloudSetupProcess: Process?

  deinit {
    timer?.invalidate()
    mountKeepaliveTimer?.invalidate()
  }

  init() {
    refreshStatus()
    refreshConfig()
    if get("MACOS_NOTIFICATIONS_ENABLED", default: "1") == "1" {
      UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
        self.refreshMacOSNotificationAuthorization()
      }
    } else {
      refreshMacOSNotificationAuthorization()
    }
    refreshControlFlags()
    refreshLockState()
    refreshHealth()
    timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
      guard let self else { return }
      self.refreshStatus()
      self.refreshControlFlags()
      self.refreshLockState()
      self.statusTick += 1
      if self.statusTick % 5 == 0 {
        self.refreshHealth()
      }
      if self.statusTick % 15 == 0 {
        self.refreshCloudMountStatus(showProgress: false)
      }
      self.processQueuedAppNotifications()
    }
    // Passive cloud-use marker: do not remount on a timer. The idle watcher
    // only keeps rclone mounted while setup/upload work has recently touched it.
    mountKeepaliveTimer = Timer.scheduledTimer(withTimeInterval: 120.0, repeats: true) { [weak self] _ in
      guard let self else { return }
      if self.cloudActionInProgress || self.cloudSetupBrowserRunning {
        self.touchCloudKeepalive()
      }
    }
    refreshCloudMountStatus(showProgress: false)
    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
      self?.checkForUpdatesIfNeeded()
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
      guard let self else { return }
      if self.get("CALENDAR_PROVIDER", default: "apple") == "apple" {
        self.refreshAvailableAppleCalendars()
      }
      if self.get("CALENDAR_PROVIDER", default: "apple") == "apple",
         self.get("CALENDAR_AUTH_STATUS", default: "") == "authorized" {
        self.refreshAppleCalendarCache(showDialog: false)
      }
    }
  }

  private func processQueuedAppNotifications() {
    let url = DDumpPaths.appNotificationQueue
    guard FileManager.default.fileExists(atPath: url.path),
          let text = try? String(contentsOf: url, encoding: .utf8),
          !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return
    }
    try? "".write(to: url, atomically: true, encoding: .utf8)
    guard get("MACOS_NOTIFICATIONS_ENABLED", default: "1") == "1" else { return }

    for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
      let parts = rawLine.split(separator: "\t", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
      guard parts.count >= 5 else { continue }
      let kind = parts[1]
      let title = parts[3].trimmingCharacters(in: .whitespacesAndNewlines)
      let message = parts[4].trimmingCharacters(in: .whitespacesAndNewlines)
      guard !title.isEmpty || !message.isEmpty else { continue }

      let content = UNMutableNotificationContent()
      content.title = title.isEmpty ? "DDump" : title
      content.body = message
      if kind == "warn" {
        content.sound = UNNotificationSound(named: UNNotificationSoundName("Basso"))
      } else if kind == "done" {
        content.sound = UNNotificationSound(named: UNNotificationSoundName("Glass"))
      }
      let request = UNNotificationRequest(
        identifier: "ddump.\(UUID().uuidString)",
        content: content,
        trigger: nil
      )
      UNUserNotificationCenter.current().add(request)
    }
  }

  func touchCloudKeepalive() {
    do {
      try FileManager.default.createDirectory(at: DDumpPaths.controlDir, withIntermediateDirectories: true)
      try "\(nowTimestamp())\n".write(to: DDumpPaths.appCloudKeepaliveFile, atomically: true, encoding: .utf8)
    } catch {
      appendAppLog("could not update cloud keepalive: \(error.localizedDescription)")
    }
  }

  private struct UploadLogSnapshot {
    var done: Int?
    var total: Int?
    var percent: Double?
    var speed: String?
    var eta: String?
    var item: String?
    var lastError: String?
  }

  private func readLogTail(maxBytes: UInt64 = 220_000) -> String {
    guard let handle = try? FileHandle(forReadingFrom: DDumpPaths.logFile) else { return "" }
    defer { try? handle.close() }
    let size = (try? handle.seekToEnd()) ?? 0
    if size > maxBytes {
      try? handle.seek(toOffset: size - maxBytes)
    } else {
      try? handle.seek(toOffset: 0)
    }
    let data = handle.readDataToEndOfFile()
    return String(data: data, encoding: .utf8) ?? ""
  }

  private func firstMatch(_ pattern: String, in text: String) -> [String]? {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
    guard let match = regex.firstMatch(in: text, range: nsRange) else { return nil }
    var groups: [String] = []
    for idx in 1..<match.numberOfRanges {
      guard let range = Range(match.range(at: idx), in: text) else {
        groups.append("")
        continue
      }
      groups.append(String(text[range]))
    }
    return groups
  }

  private func latestUploadSnapshotFromLog() -> UploadLogSnapshot? {
    let lines = readLogTail().split(separator: "\n").map(String.init)
    guard !lines.isEmpty else { return nil }
    var snapshot = UploadLogSnapshot()

    for line in lines.reversed() {
      if snapshot.lastError == nil, let range = line.range(of: "ERROR : ") {
        let errorText = String(line[range.upperBound...])
          .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        snapshot.lastError = String(errorText.prefix(220))
      }
      if snapshot.item == nil,
         let groups = firstMatch(#"INFO  : ([^:]+): Copied"#, in: line),
         let item = groups.first {
        snapshot.item = item
      }
      if snapshot.percent == nil,
         let groups = firstMatch(#"INFO  :\s+.*?, ([0-9]+)%, ([^,]+), ETA ([^ ]+) \(xfr#([0-9]+)/([0-9]+)\)"#, in: line),
         groups.count >= 5 {
        snapshot.percent = Double(groups[0])
        snapshot.speed = groups[1].trimmingCharacters(in: .whitespacesAndNewlines)
        snapshot.eta = groups[2].trimmingCharacters(in: .whitespacesAndNewlines)
        snapshot.done = Int(groups[3])
        snapshot.total = Int(groups[4])
      }
      if snapshot.percent != nil && snapshot.lastError != nil && snapshot.item != nil {
        break
      }
    }

    return (snapshot.percent != nil || snapshot.lastError != nil || snapshot.item != nil) ? snapshot : nil
  }

  func refreshStatus() {
    let parsed = readShellEnv(at: DDumpPaths.statusFile)
    let parsedPhase = parsed["phase"] ?? "idle"
    let uploadSnapshot = parsedPhase == "uploading" ? latestUploadSnapshotFromLog() : nil
    DispatchQueue.main.async {
      self.phase = parsedPhase
      self.message = parsed["message"] ?? "Waiting for a card…"
      self.volume = parsed["volume"] ?? ""
      self.total = Int(parsed["total"] ?? "0") ?? 0
      self.processed = Int(parsed["processed"] ?? "0") ?? 0
      self.imported = Int(parsed["imported"] ?? "0") ?? 0
      self.skipped = Int(parsed["skipped"] ?? "0") ?? 0
      self.failed = Int(parsed["failed"] ?? "0") ?? 0
      self.uploadTotal = Int(parsed["upload_total"] ?? "") ?? uploadSnapshot?.total ?? 0
      self.uploadDone = Int(parsed["upload_done"] ?? "") ?? uploadSnapshot?.done ?? 0
      self.uploadFailed = Int(parsed["upload_failed"] ?? "") ?? 0
      self.uploadPercent = Double(parsed["upload_percent"] ?? "") ?? uploadSnapshot?.percent ?? 0
      self.uploadSpeed = parsed["upload_speed"].flatMap { $0.isEmpty ? nil : $0 } ?? uploadSnapshot?.speed ?? ""
      self.uploadETA = parsed["upload_eta"].flatMap { $0.isEmpty ? nil : $0 } ?? uploadSnapshot?.eta ?? ""
      self.uploadTarget = parsed["upload_target"] ?? ""
      self.uploadItem = parsed["upload_item"].flatMap { $0.isEmpty ? nil : $0 } ?? uploadSnapshot?.item ?? ""
      self.uploadLastError = parsed["upload_last_error"].flatMap { $0.isEmpty ? nil : $0 } ?? uploadSnapshot?.lastError ?? ""
      self.cardEjected = parsed["card_ejected"] == "1"
      self.ejectStatus = parsed["eject_status"] ?? "pending"
      self.startedEpoch = TimeInterval(parsed["started_epoch"] ?? "0") ?? 0
      self.updatedAt = parsed["updated_at"] ?? ""
      self.refreshSkippedVolumeNotice()
    }
  }

  func refreshSkippedVolumeNotice() {
    let parsed = readShellEnv(at: DDumpPaths.lastSkippedVolumeFile)
    guard !parsed.isEmpty else {
      self.skippedVolumeNotice = nil
      return
    }
    let notice = SkippedVolumeNotice(
      volume: parsed["volume"] ?? "card",
      path: parsed["path"] ?? "",
      reason: parsed["reason"] ?? "",
      detail: parsed["detail"] ?? "DDump saw a volume but skipped it.",
      hint: parsed["hint"] ?? "Use Manual select import if this is a real camera card.",
      epoch: TimeInterval(parsed["epoch"] ?? "0") ?? 0
    )
    self.skippedVolumeNotice = notice.isRecent ? notice : nil
  }

  func dismissSkippedVolumeNotice() {
    skippedVolumeNotice = nil
    try? FileManager.default.removeItem(at: DDumpPaths.lastSkippedVolumeFile)
  }

  func refreshConfig() {
    let parsed = readShellEnv(at: DDumpPaths.configFile)
    DispatchQueue.main.async {
      self.config = parsed
    }
  }

  func refreshControlFlags() {
    let fm = FileManager.default
    let p = fm.fileExists(atPath: DDumpPaths.pauseFlag.path)
    var v = fm.fileExists(atPath: DDumpPaths.viewOnlyFlag.path)
    var viewOnlyUntil = (try? String(contentsOf: DDumpPaths.viewOnlyUntilFile, encoding: .utf8))
      .flatMap { TimeInterval($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
    if v && viewOnlyUntil > 0 && viewOnlyUntil <= Date().timeIntervalSince1970 {
      do {
        try fm.removeItem(at: DDumpPaths.viewOnlyFlag)
        guard !fm.fileExists(atPath: DDumpPaths.viewOnlyFlag.path) else {
          throw CocoaError(.fileWriteUnknown)
        }
        v = false
        viewOnlyUntil = 0
        if fm.fileExists(atPath: DDumpPaths.viewOnlyUntilFile.path) {
          try? fm.removeItem(at: DDumpPaths.viewOnlyUntilFile)
        }
        lastUtilityMessage = "Import pause ended. Automatic card imports are back on."
      } catch {
        v = true
        lastUtilityMessage = "The pause timer ended, but DDump could not resume imports: \(error.localizedDescription)"
      }
    }
    let s = fm.fileExists(atPath: DDumpPaths.stopFlag.path)
    let e = fm.fileExists(atPath: DDumpPaths.ejectNowFlag.path)
    let k = fm.fileExists(atPath: DDumpPaths.keepMountedFlag.path)
    DispatchQueue.main.async {
      self.paused = p
      self.viewOnlyMode = v
      self.viewOnlyUntilEpoch = viewOnlyUntil
      self.stopRequested = s
      self.ejectQueued = e
      self.keepMountedRequested = k
    }
  }

  func refreshLockState() {
    let active = FileManager.default.fileExists(atPath: DDumpPaths.lockDir.path)
    DispatchQueue.main.async { self.runActive = active }
  }

  func refreshHealth() {
    let fm = FileManager.default
    let pending = (try? fm.contentsOfDirectory(at: DDumpPaths.pendingDir, includingPropertiesForKeys: nil))
      .map { $0.filter { $0.lastPathComponent.hasPrefix("pending.") && $0.pathExtension == "tsv" }.count } ?? 0

    let stagingPath = NSString(string: get("DEST_ROOT", default: "\(NSHomeDirectory())/Temp")).expandingTildeInPath
    let stagingURL = URL(fileURLWithPath: stagingPath)
    let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey]
    let values = try? stagingURL.resourceValues(forKeys: keys)
    let freeGB = Int((values?.volumeAvailableCapacityForImportantUsage ?? 0) / 1_000_000_000)
    let staged = (try? fm.contentsOfDirectory(at: stagingURL, includingPropertiesForKeys: [.isDirectoryKey]))
      .map { urls in
        urls.filter { url in
          let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
          let name = url.lastPathComponent
          return isDir && (name.hasSuffix("-ddump") || name.hasSuffix("-dump"))
        }.count
      } ?? 0

    var needsReinsert = 0
    if sqliteMemoryEnabled {
      let dbPath = DDumpPaths.appSupport.appendingPathComponent("state/ddump.sqlite3").path
      if fm.fileExists(atPath: dbPath) {
        let task = Process()
        task.launchPath = "/bin/bash"
        task.arguments = ["-lc", "/usr/bin/sqlite3 \(shellDoubleQuoted(dbPath)) \"SELECT COUNT(*) FROM media_files WHERE status='needs_reinsert';\" 2>/dev/null || echo 0"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
          try task.run()
          task.waitUntilExit()
          let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "0"
          needsReinsert = Int(out) ?? 0
        } catch {
          needsReinsert = 0
        }
      }
    }

    DispatchQueue.main.async {
      self.pendingUploadCount = pending
      self.needsReinsertCount = needsReinsert
      self.localFreeGB = freeGB
      self.stagingFolderCount = staged
    }
  }

  func get(_ key: String, default def: String = "") -> String {
    config[key] ?? def
  }

  var sqliteMemoryEnabled: Bool {
    return get("DB_ENABLED", default: "0") == "1"
  }

  func preferredColorScheme() -> ColorScheme? {
    switch get("APP_COLOR_SCHEME", default: "system").lowercased() {
    case "light": return .light
    case "dark": return .dark
    default: return nil
    }
  }

  func requestOnboardingRestart() {
    set("ONBOARDING_COMPLETED", "0")
    DispatchQueue.main.async {
      self.onboardingRestartRequested = true
    }
  }

  func clearOnboardingRestartRequest() {
    DispatchQueue.main.async {
      self.onboardingRestartRequested = false
    }
  }

  var uploadRootForUI: String {
    let configuredRoot = get("POST_MOVE_ROOT", default: "").trimmingCharacters(in: .whitespacesAndNewlines)
    if !configuredRoot.isEmpty {
      return expandConfiguredPath(configuredRoot)
    }
    if get("POST_MOVE_DATE_MODE", default: "smart") == "smart" {
      let sample = get("SMART_SAMPLE_PATH")
      let pattern = #"^(.+)/[0-9]{4}/[0-9]{4}\.[0-9]{2}/[0-9]{4}\.[0-9]{2}\.[0-9]{2}(/.*)?$"#
      if let regex = try? NSRegularExpression(pattern: pattern),
         let match = regex.firstMatch(in: sample, range: NSRange(sample.startIndex..., in: sample)),
         let range = Range(match.range(at: 1), in: sample) {
        return expandConfiguredPath(String(sample[range]))
      }
    }
    return "\(NSHomeDirectory())/Temp"
  }

  var backupRootForUI: String {
    expandConfiguredPath(uploadRootForUI.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  var backupRootWarningForUI: String? {
    guard get("ENABLE_POST_EJECT_MOVE", default: "1") == "1" else { return nil }
    let root = backupRootForUI
    guard !root.isEmpty else {
      return "Backup Folder is not set. DDump will keep files only in the Dump Folder until you choose a Backup Folder."
    }
    var isDirectory: ObjCBool = false
    if FileManager.default.fileExists(atPath: root, isDirectory: &isDirectory), isDirectory.boolValue {
      return nil
    }
    return "Backup Folder is unavailable: \(shortDisplayPath(root, keepLastComponents: 5)). DDump will not silently mark a backup complete until this folder is reachable."
  }

  var dumpRootForUI: String {
    expandConfiguredPath(get("DEST_ROOT", default: "\(NSHomeDirectory())/Temp/DDump"))
  }

  func displayPath(_ path: String) -> String {
    let expanded = expandConfiguredPath(path)
    let home = NSHomeDirectory()
    if expanded == home { return "~" }
    if expanded.hasPrefix(home + "/") {
      return "~/" + expanded.dropFirst(home.count + 1)
    }
    return expanded
  }

  func shortDisplayPath(_ path: String, keepLastComponents: Int = 4) -> String {
    let display = displayPath(path)
    let prefix: String
    let body: String
    if display.hasPrefix("~/") {
      prefix = "~/"
      body = String(display.dropFirst(2))
    } else if display.hasPrefix("/") {
      prefix = "/"
      body = String(display.dropFirst())
    } else {
      prefix = ""
      body = display
    }
    let parts = body.split(separator: "/").map(String.init)
    guard parts.count > keepLastComponents else { return display }
    return prefix + "…" + "/" + parts.suffix(keepLastComponents).joined(separator: "/")
  }

  var gdriveMountEnabledForUI: Bool {
    return self.get("GDRIVE_MOUNT_ENABLED", default: "0") == "1"
  }

  var cloudUploadsEnabledForUI: Bool {
    let explicit = self.get("CLOUD_UPLOADS_ENABLED", default: "")
    if !explicit.isEmpty {
      return explicit == "1"
    }
    return self.get("GDRIVE_MOUNT_ENABLED", default: "0") == "1"
  }

  var gdriveMountPointForUI: String {
    return expandConfiguredPath(self.get("GDRIVE_MOUNT_POINT", default: "\(NSHomeDirectory())/GoogleDrive"))
  }

  var gdriveMountLabelForUI: String {
    return self.get("GDRIVE_MOUNT_LABEL", default: "com.ddump.rclone-gdrive")
  }

  var gdriveRemoteForUI: String {
    return self.get("GDRIVE_REMOTE", default: "combined:")
  }

  var rcloneBinForUI: String {
    return expandConfiguredPath(self.get("RCLONE_BIN", default: "\(NSHomeDirectory())/bin/rclone"))
  }

  var googleDriveDesktopRootForUI: String? {
    let fm = FileManager.default
    let exact = "\(NSHomeDirectory())/Library/CloudStorage/GoogleDrive"
    if fm.fileExists(atPath: exact) {
      return exact
    }
    let cloudStorage = "\(NSHomeDirectory())/Library/CloudStorage"
    guard let entries = try? fm.contentsOfDirectory(atPath: cloudStorage) else { return nil }
    if let match = entries.sorted().first(where: { $0 == "GoogleDrive" || $0.hasPrefix("GoogleDrive-") }) {
      return "\(cloudStorage)/\(match)"
    }
    return nil
  }

  var defaultCloudUploadFolderForUI: String {
    if let driveRoot = googleDriveDesktopRootForUI {
      return "\(driveRoot)/My Drive/DDump Uploads"
    }
    return "\(gdriveMountPointForUI)/DDump Uploads"
  }

  var cloudDestinationReadyForUI: Bool {
    let destination = uploadRootForUI.trimmingCharacters(in: .whitespacesAndNewlines)
    return !destination.isEmpty && pathUsesGoogleDriveDestination(destination)
  }

  var cloudSetupConnectionOKForUI: Bool {
    return get("CLOUD_SETUP_CONNECTION_OK", default: "0") == "1" && cloudDestinationReadyForUI
  }

  var cloudSetupNeedsAttentionForUI: Bool {
    let directUpload = get("GDRIVE_DIRECT_UPLOAD", default: "0") == "1"
    let managedMount = get("GDRIVE_MOUNT_ENABLED", default: "0") == "1"
    return cloudUploadsEnabledForUI
      && (
        !cloudDestinationReadyForUI
        || !cloudSetupConnectionOKForUI
        || ((directUpload || managedMount) && (!cloudRcloneReady || !cloudRemoteConfigured))
        || (managedMount && !cloudMountActive)
      )
  }

  func pathUsesGoogleDriveDestination(_ path: String) -> Bool {
    if pathUsesGDriveMount(path) { return true }
    let expandedPath = expandConfiguredPath(path)
      .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let cloudBase = "\(NSHomeDirectory())/Library/CloudStorage/GoogleDrive"
      .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    return expandedPath == cloudBase
      || expandedPath.hasPrefix(cloudBase + "/")
      || expandedPath.hasPrefix(cloudBase + "-")
  }

  func pathUsesGDriveMount(_ path: String) -> Bool {
    let expandedMount = expandConfiguredPath(gdriveMountPointForUI)
      .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let expandedPath = expandConfiguredPath(path)
      .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    return expandedPath == expandedMount || expandedPath.hasPrefix(expandedMount + "/")
  }

  func cloudRelativePath(_ path: String) -> String? {
    let expandedMount = expandConfiguredPath(gdriveMountPointForUI)
      .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let expandedPath = expandConfiguredPath(path)
      .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    if expandedPath == expandedMount { return "" }
    let prefix = expandedMount + "/"
    guard expandedPath.hasPrefix(prefix) else { return nil }
    return String(expandedPath.dropFirst(prefix.count))
  }

  func cloudPseudoLocalPath(relativePath: String) -> String {
    let cleaned = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: " /"))
    if cleaned.isEmpty { return gdriveMountPointForUI }
    return "\(gdriveMountPointForUI)/\(cleaned)"
  }

  func rcloneRemoteJoin(_ base: String, _ rel: String) -> String {
    let cleanedRel = rel.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    if cleanedRel.isEmpty { return base }
    if base.hasSuffix(":") { return base + cleanedRel }
    return base.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + cleanedRel
  }

  func cloudRemotePath(for pseudoLocalPath: String) -> String? {
    guard let rel = cloudRelativePath(pseudoLocalPath) else { return nil }
    var remote = gdriveRemoteForUI.trimmingCharacters(in: .whitespacesAndNewlines)
    if remote.isEmpty { remote = "combined:" }
    if !remote.contains(":") { remote += ":" }
    return rcloneRemoteJoin(remote, rel)
  }

  func dateFormatFromShellFormat(_ shellFormat: String, fallback: String) -> String {
    var out = shellFormat
    out = out.replacingOccurrences(of: "%Y", with: "yyyy")
    out = out.replacingOccurrences(of: "%m", with: "MM")
    out = out.replacingOccurrences(of: "%d", with: "dd")
    out = out.replacingOccurrences(of: "%H", with: "HH")
    out = out.replacingOccurrences(of: "%M", with: "mm")
    out = out.replacingOccurrences(of: "%S", with: "ss")
    return out.contains("%") ? fallback : out
  }

  func formattedDateFolder(_ shellFormat: String, fallback: String) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = dateFormatFromShellFormat(shellFormat, fallback: fallback)
    return formatter.string(from: Date())
  }

  func existingChildDirectory(parent: String, named desired: String) -> String {
    let fm = FileManager.default
    if fm.fileExists(atPath: "\(parent)/\(desired)") {
      return "\(parent)/\(desired)"
    }
    guard let entries = try? fm.contentsOfDirectory(atPath: parent) else {
      return "\(parent)/\(desired)"
    }
    let desiredLower = desired.lowercased()
    if let match = entries.sorted().first(where: { entry in
      let base = entry.replacingOccurrences(of: #" \([0-9]+\)$"#, with: "", options: .regularExpression)
      return base.lowercased() == desiredLower
    }) {
      return "\(parent)/\(match)"
    }
    return "\(parent)/\(desired)"
  }

  var todaysUploadDestinationForUI: String {
    let root = backupRootForUI.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !root.isEmpty else { return root }
    if get("POST_MOVE_DATE_MODE", default: "smart") == "fixed" {
      return root
    }
    let year = formattedDateFolder(get("POST_MOVE_YEAR_FORMAT", default: "%Y"), fallback: "yyyy")
    let month = formattedDateFolder(get("POST_MOVE_MONTH_FORMAT", default: "%Y.%m"), fallback: "yyyy.MM")
    let day = formattedDateFolder(get("POST_MOVE_DAY_FORMAT", default: "%Y.%m.%d"), fallback: "yyyy.MM.dd")
    let yearDir = existingChildDirectory(parent: root, named: year)
    let monthDir = existingChildDirectory(parent: yearDir, named: month)
    return existingChildDirectory(parent: monthDir, named: day)
  }

  func openUploadDestination(openTodayFolder: Bool = true) {
    let destination = (openTodayFolder ? todaysUploadDestinationForUI : uploadRootForUI)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let expandedDestination = expandConfiguredPath(destination)
    let expandedRoot = backupRootForUI
    if get("GDRIVE_DIRECT_UPLOAD", default: "0") == "1",
       let remoteDest = cloudRemotePath(for: expandedDestination) {
      openCloudRemoteDestination(remoteDest)
      return
    }
    var isDirectory: ObjCBool = false
    if FileManager.default.fileExists(atPath: expandedDestination, isDirectory: &isDirectory), isDirectory.boolValue {
      openInFinder(expandedDestination)
      return
    }
    if openTodayFolder,
       FileManager.default.fileExists(atPath: expandedRoot, isDirectory: &isDirectory),
       isDirectory.boolValue {
      lastUtilityMessage = "Today's dated Backup Folder has not been created yet. Opened the Backup Folder root instead."
      appendAppLog("today backup folder missing; opened backup root instead: today=\(expandedDestination) root=\(expandedRoot)")
      openInFinder(expandedRoot)
      return
    }
    let message = "Backup Folder is unavailable: \(expandedRoot.isEmpty ? expandedDestination : expandedRoot)"
    lastUtilityMessage = message
    appendAppLog(message)
    sendIntegrityWarningPhoneAlert(title: "DDump: Backup Folder unavailable", message: message)
    openInFinder(expandedRoot.isEmpty ? expandedDestination : expandedRoot)
  }

  private func sendIntegrityWarningPhoneAlert(title: String, message: String) {
    guard get("NTFY_NOTIFY_INTEGRITY_WARNING", default: "1") == "1" else { return }
    let topic = get("NTFY_TOPIC").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !topic.isEmpty,
          let encodedTopic = topic.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
          let body = "\(title)\nintegrity_warning\n\(message)".data(using: .utf8) else {
      return
    }
    DispatchQueue.global(qos: .utility).async {
      let task = Process()
      task.launchPath = "/usr/bin/curl"
      task.arguments = [
        "-fsS", "-m", "10",
        "-H", "Title: \(title)",
        "-H", "Tags: warning",
        "--data-binary", "@-",
        "https://ntfy.sh/\(encodedTopic)"
      ]
      let stdin = Pipe()
      task.standardInput = stdin
      task.standardOutput = Pipe()
      task.standardError = Pipe()
      do {
        try task.run()
        stdin.fileHandleForWriting.write(body)
        stdin.fileHandleForWriting.closeFile()
        task.waitUntilExit()
      } catch {
        // Phone alerts are best-effort; the visible warning remains the source of truth.
      }
    }
  }

  private func openCloudRemoteDestination(_ remoteDest: String) {
    let configuredBin = rcloneBinForUI
    setCloudAction(true, "Opening Google Drive folder…")
    lastUtilityMessage = "Opening Google Drive folder…"
    appendAppLog("open cloud destination requested: \(remoteDest)")
    DispatchQueue.global(qos: .utility).async {
      let task = Process()
      task.launchPath = "/bin/bash"
      task.arguments = ["-lc", """
set -euo pipefail
export PATH="${HOME}/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
configured_bin=\(shellDoubleQuoted(configuredBin))
remote_dest=\(shellDoubleQuoted(remoteDest))
expand_user_path() {
  local raw="$1"
  raw="${raw/#\\$HOME/$HOME}"
  raw="${raw/#$HOME/$HOME}"
  raw="${raw/#\\~/$HOME}"
  printf '%s' "$raw"
}
configured_bin="$(expand_user_path "$configured_bin")"
if [ -n "$configured_bin" ] && [ -x "$configured_bin" ]; then
  rclone="$configured_bin"
elif command -v rclone >/dev/null 2>&1; then
  rclone="$(command -v rclone)"
elif [ -x "/opt/homebrew/bin/rclone" ]; then
  rclone="/opt/homebrew/bin/rclone"
elif [ -x "/usr/local/bin/rclone" ]; then
  rclone="/usr/local/bin/rclone"
else
  echo "error=rclone missing"
  exit 2
fi
"$rclone" mkdir "$remote_dest" --tpslimit 1 --tpslimit-burst 1 >/dev/null
link="$("$rclone" link "$remote_dest" --tpslimit 1 --tpslimit-burst 1)"
printf 'url=%s\\n' "$link"
"""]
      let pipe = Pipe()
      task.standardOutput = pipe
      task.standardError = pipe
      do {
        try task.run()
      } catch {
        DispatchQueue.main.async {
          self.cloudActionInProgress = false
          self.cloudActionMessage = ""
          self.lastUtilityMessage = "Could not open Google Drive folder: \(error.localizedDescription)"
          self.showUtilityDialog(title: "Could not open Google Drive folder", text: self.lastUtilityMessage)
        }
        return
      }
      task.waitUntilExit()
      let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
      let parsed = parseShellEnv(out)
      DispatchQueue.main.async {
        self.cloudActionInProgress = false
        self.cloudActionMessage = ""
        if task.terminationStatus == 0,
           let rawURL = parsed["url"],
           let url = URL(string: rawURL.trimmingCharacters(in: .whitespacesAndNewlines)) {
          NSWorkspace.shared.open(url)
          self.lastUtilityMessage = "Opened Google Drive folder \(remoteDest)."
          self.appendAppLog("open cloud destination success: \(remoteDest)")
        } else {
          let reason = parsed["error"] ?? out.trimmingCharacters(in: .whitespacesAndNewlines)
          self.lastUtilityMessage = reason.isEmpty ? "Could not get a Google Drive folder link." : self.plainCloudFailure(reason)
          self.appendAppLog("open cloud destination failed: \(self.lastUtilityMessage)")
          self.showUtilityDialog(
            title: "Could not open Google Drive folder",
            text: "\(self.lastUtilityMessage)\nDDump verified the folder through rclone, but Google Drive did not return a web link."
          )
        }
      }
    }
  }

  func set(_ key: String, _ value: String) {
    config[key] = value
    writeShellConfig(key: key, value: value, at: DDumpPaths.configFile)
  }

  func setMacOSNotificationsEnabled(_ enabled: Bool) {
    set("MACOS_NOTIFICATIONS_ENABLED", enabled ? "1" : "0")
    guard enabled else { return }
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
      self.refreshMacOSNotificationAuthorization()
      guard !granted else { return }
      DispatchQueue.main.async {
        self.lastUtilityMessage = error?.localizedDescription
          ?? "Mac notifications are blocked. Allow DDump in System Settings > Notifications."
      }
    }
  }

  func refreshMacOSNotificationAuthorization() {
    UNUserNotificationCenter.current().getNotificationSettings { settings in
      DispatchQueue.main.async {
        self.macOSNotificationAuthorization = settings.authorizationStatus
      }
    }
  }

  func openMacOSNotificationSettings() {
    guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else { return }
    NSWorkspace.shared.open(url)
  }

  func sendTestMacOSNotification() {
    let center = UNUserNotificationCenter.current()
    center.requestAuthorization(options: [.alert, .sound]) { granted, error in
      self.refreshMacOSNotificationAuthorization()
      guard granted else {
        DispatchQueue.main.async {
          self.lastUtilityMessage = error?.localizedDescription
            ?? "Mac notifications are blocked. Allow DDump in System Settings > Notifications."
        }
        return
      }
      let content = UNMutableNotificationContent()
      content.title = "DDump notifications are on"
      content.body = "Import and storage alerts will appear here."
      content.sound = .default
      let request = UNNotificationRequest(
        identifier: "ddump.test.\(UUID().uuidString)",
        content: content,
        trigger: nil
      )
      center.add(request) { addError in
        guard let addError else { return }
        DispatchQueue.main.async {
          self.lastUtilityMessage = "Could not send the test notification: \(addError.localizedDescription)"
        }
      }
    }
  }

  func connectAppleCalendar() {
    let store = EKEventStore()
    lastUtilityMessage = "Asking macOS for Calendar access..."
    set("CALENDAR_PROVIDER", "apple")
    set("CALENDAR_AUTH_STATUS", "pending")

    let finish: (Bool, Error?) -> Void = { granted, error in
      DispatchQueue.main.async {
        if granted {
          self.set("CALENDAR_PROVIDER", "apple")
          self.set("CALENDAR_AUTH_STATUS", "authorized")
          self.lastUtilityMessage = "Mac Calendar connected. Refreshing local shoot events..."
          self.refreshAvailableAppleCalendars()
          self.refreshAppleCalendarCache(showDialog: false)
        } else {
          self.set("CALENDAR_AUTH_STATUS", "not_authorized")
          let reason = error?.localizedDescription ?? "Allow Calendar access in System Settings, then try again."
          self.lastUtilityMessage = "Mac Calendar access was not approved. \(reason)"
        }
      }
    }

    if #available(macOS 14.0, *) {
      store.requestFullAccessToEvents(completion: finish)
    } else {
      store.requestAccess(to: .event, completion: finish)
    }
  }

  func refreshAvailableAppleCalendars() {
    let store = EKEventStore()
    let update: () -> Void = {
      let choices = store.calendars(for: .event)
        .sorted {
          if $0.source.title == $1.source.title { return $0.title < $1.title }
          return $0.source.title < $1.source.title
        }
        .map { calendar in
          CalendarChoice(
            id: calendar.calendarIdentifier,
            title: calendar.title,
            source: calendar.source.title
          )
        }
      DispatchQueue.main.async {
        self.appleCalendars = choices
      }
    }

    let complete: (Bool, Error?) -> Void = { granted, _ in
      if granted { update() }
    }

    if #available(macOS 14.0, *) {
      store.requestFullAccessToEvents(completion: complete)
    } else {
      store.requestAccess(to: .event, completion: complete)
    }
  }

  func refreshAppleCalendarCache(showDialog: Bool = true) {
    let store = EKEventStore()
    let calendarFilter = get("CALENDAR_NAME", default: "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    let selectedCalendarIDs = Set(
      get("CALENDAR_IDS", default: "")
        .split(separator: ",")
        .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    )
    lastUtilityMessage = "Refreshing Mac Calendar events..."

    let refresh: () -> Void = {
      let calendar = Calendar.current
      let now = Date()
      let start = calendar.date(byAdding: .day, value: -14, to: now) ?? now
      let end = calendar.date(byAdding: .day, value: 90, to: now) ?? now
      let calendars = store.calendars(for: .event).filter { cal in
        if !selectedCalendarIDs.isEmpty {
          return selectedCalendarIDs.contains(cal.calendarIdentifier)
        }
        return calendarFilter.isEmpty || cal.title.lowercased().contains(calendarFilter)
      }
      let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendars.isEmpty ? nil : calendars)
      let events = store.events(matching: predicate)
        .filter { !$0.isAllDay }
        .sorted { $0.startDate < $1.startDate }

      let formatter = ISO8601DateFormatter()
      var lines: [String] = [
        "# DDump local Mac Calendar cache",
        "# refreshed_at=\(formatter.string(from: now))",
        "# range_start=\(formatter.string(from: start))",
        "# range_end=\(formatter.string(from: end))",
        "# columns: start_epoch<TAB>end_epoch<TAB>yyyy-mm-dd<TAB>calendar<TAB>title<TAB>calendar_id"
      ]
      for event in events {
        let title = event.title?
          .replacingOccurrences(of: "\t", with: " ")
          .replacingOccurrences(of: "\n", with: " ")
          .trimmingCharacters(in: .whitespacesAndNewlines) ?? "Calendar Event"
        let calTitle = event.calendar.title
          .replacingOccurrences(of: "\t", with: " ")
          .replacingOccurrences(of: "\n", with: " ")
        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.dateFormat = "yyyy-MM-dd"
        let day = dayFormatter.string(from: event.startDate)
        let startEpoch = Int(event.startDate.timeIntervalSince1970)
        let endEpoch = Int(event.endDate.timeIntervalSince1970)
        guard endEpoch >= startEpoch else { continue }
        lines.append("\(startEpoch)\t\(endEpoch)\t\(day)\t\(calTitle)\t\(title)\t\(event.calendar.calendarIdentifier)")
      }

      do {
        try FileManager.default.createDirectory(at: DDumpPaths.appleCalendarCache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(to: DDumpPaths.appleCalendarCache, atomically: true, encoding: .utf8)
        DispatchQueue.main.async {
          self.set("CALENDAR_PROVIDER", "apple")
          self.set("CALENDAR_AUTH_STATUS", "authorized")
          self.lastUtilityMessage = "Mac Calendar ready. Cached \(events.count) event(s) for background imports."
          if showDialog {
            self.showUtilityDialog(title: "Mac Calendar Ready", text: "DDump cached \(events.count) upcoming calendar event(s) for shoot naming.")
          }
        }
      } catch {
        DispatchQueue.main.async {
          self.lastUtilityMessage = "Could not save Mac Calendar cache: \(error.localizedDescription)"
        }
      }
    }

    let complete: (Bool, Error?) -> Void = { granted, error in
      if granted {
        refresh()
      } else {
        DispatchQueue.main.async {
          self.set("CALENDAR_AUTH_STATUS", "not_authorized")
          let reason = error?.localizedDescription ?? "Allow Calendar access in System Settings, then try again."
          self.lastUtilityMessage = "Mac Calendar access was not approved. \(reason)"
        }
      }
    }

    if #available(macOS 14.0, *) {
      store.requestFullAccessToEvents(completion: complete)
    } else {
      store.requestAccess(to: .event, completion: complete)
    }
  }

  func connectGoogleCalendar() {
    let clientID = get(
      "GOOGLE_CALENDAR_CLIENT_ID",
      default: "570098546449-737pvkselaqtncp2e6kdmhkf55eemche.apps.googleusercontent.com"
    )
    let clientSecret = get("GOOGLE_CALENDAR_CLIENT_SECRET", default: "")
    set("CALENDAR_PROVIDER", "google")
    set("GOOGLE_CALENDAR_CLIENT_ID", clientID)
    set("CALENDAR_AUTH_STATUS", "pending")
    lastUtilityMessage = "Opening Google Calendar sign-in..."

    DispatchQueue.global(qos: .utility).async {
      let task = Process()
      task.launchPath = "/bin/bash"
      let helper = shellDoubleQuoted(DDumpPaths.googleCalendarHelper.path)
      let quotedClientID = shellDoubleQuoted(clientID)
      let quotedClientSecret = shellDoubleQuoted(clientSecret)
      task.arguments = ["-lc", """
set +e
export PATH="${HOME}/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
helper=\(helper)
client_id=\(quotedClientID)
client_secret=\(quotedClientSecret)
if [ ! -x "$helper" ]; then
  echo "status=missing_helper"
  exit 3
fi
"$helper" --client-id "$client_id" --client-secret "$client_secret" auth --timeout 300
exit "$?"
"""]
      let pipe = Pipe()
      task.standardOutput = pipe
      task.standardError = Pipe()
      do {
        try task.run()
      } catch {
        DispatchQueue.main.async {
          self.set("CALENDAR_AUTH_STATUS", "not_authorized")
          self.lastUtilityMessage = "Could not start Google Calendar sign-in: \(error.localizedDescription)"
        }
        return
      }
      task.waitUntilExit()
      let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
      let parsed = parseShellEnv(out)
      let status = parsed["status"] ?? ""
      DispatchQueue.main.async {
        switch status {
        case "authorized":
          self.set("CALENDAR_AUTH_STATUS", "authorized")
          self.lastUtilityMessage = "Google Calendar connected. DDump can read events for shoot naming."
        case "browser_opening":
          self.set("CALENDAR_AUTH_STATUS", "pending")
          self.lastUtilityMessage = "Google Calendar authorization opened in the browser. Finish sign-in, then click Check connection."
        case "timeout":
          self.set("CALENDAR_AUTH_STATUS", "pending")
          self.lastUtilityMessage = "Google Calendar authorization did not finish. If Google says Access blocked, add this Google account as an OAuth test user or publish the consent screen, then reconnect."
        case "missing_helper":
          self.set("CALENDAR_AUTH_STATUS", "missing_helper")
          self.lastUtilityMessage = "Google Calendar helper is missing. Reinstall DDump, then try again."
        default:
          self.set("CALENDAR_AUTH_STATUS", "not_authorized")
          let error = parsed["error"] ?? ""
          if error.contains("client_secret") {
            self.lastUtilityMessage = "Google Calendar needs the OAuth client secret from the Google Cloud Desktop client. Add GOOGLE_CALENDAR_CLIENT_SECRET in config, then reconnect."
          } else {
            self.lastUtilityMessage = "Google Calendar authorization was not confirmed. Click Connect Google Calendar to try again."
          }
        }
      }
    }
  }

  func checkGoogleCalendarConnection() {
    let clientID = get(
      "GOOGLE_CALENDAR_CLIENT_ID",
      default: "570098546449-737pvkselaqtncp2e6kdmhkf55eemche.apps.googleusercontent.com"
    )
    let clientSecret = get("GOOGLE_CALENDAR_CLIENT_SECRET", default: "")
    lastUtilityMessage = "Checking Google Calendar connection..."
    DispatchQueue.global(qos: .utility).async {
      let task = Process()
      task.launchPath = "/bin/bash"
      let helper = shellDoubleQuoted(DDumpPaths.googleCalendarHelper.path)
      let quotedClientID = shellDoubleQuoted(clientID)
      let quotedClientSecret = shellDoubleQuoted(clientSecret)
      task.arguments = ["-lc", """
export PATH="${HOME}/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
helper=\(helper)
client_id=\(quotedClientID)
client_secret=\(quotedClientSecret)
[ -x "$helper" ] || { echo "status=missing_helper"; exit 3; }
"$helper" --client-id "$client_id" --client-secret "$client_secret" status
"""]
      let pipe = Pipe()
      task.standardOutput = pipe
      do {
        try task.run()
      } catch {
        DispatchQueue.main.async {
          self.set("CALENDAR_AUTH_STATUS", "not_authorized")
          self.lastUtilityMessage = "Could not check Google Calendar: \(error.localizedDescription)"
        }
        return
      }
      task.waitUntilExit()
      let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
      let parsed = parseShellEnv(out)
      let status = parsed["status"] ?? ""
      DispatchQueue.main.async {
        if task.terminationStatus == 0 || status == "authorized" {
          self.set("CALENDAR_PROVIDER", "google")
          self.set("GOOGLE_CALENDAR_CLIENT_ID", clientID)
          self.set("CALENDAR_AUTH_STATUS", "authorized")
          self.lastUtilityMessage = "Google Calendar connected. DDump can read events for shoot naming."
        } else if status == "missing_helper" {
          self.set("CALENDAR_AUTH_STATUS", "missing_helper")
          self.lastUtilityMessage = "Google Calendar helper is missing. Reinstall DDump, then try again."
        } else {
          self.set("CALENDAR_AUTH_STATUS", "not_authorized")
          let error = parsed["error"] ?? ""
          if error.contains("client_secret") {
            self.lastUtilityMessage = "Google Calendar needs the OAuth client secret from the Google Cloud Desktop client."
          } else {
            self.lastUtilityMessage = "Google Calendar is not connected yet."
          }
        }
      }
    }
  }

  func validateCalendarLink(_ rawURL: String) {
    let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: trimmed), ["http", "https", "webcal"].contains(url.scheme?.lowercased() ?? "") else {
      set("CALENDAR_AUTH_STATUS", "not_authorized")
      lastUtilityMessage = "Enter a valid private calendar link."
      return
    }

    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    if components?.scheme?.lowercased() == "webcal" {
      components?.scheme = "https"
    }
    guard let fetchURL = components?.url else {
      set("CALENDAR_AUTH_STATUS", "not_authorized")
      lastUtilityMessage = "Could not read that calendar link."
      return
    }

    set("CALENDAR_PROVIDER", "ics")
    set("CALENDAR_ICS_URL", trimmed)
    set("CALENDAR_AUTH_STATUS", "pending")
    lastUtilityMessage = "Checking calendar link..."

    var request = URLRequest(url: fetchURL)
    request.timeoutInterval = 15
    URLSession.shared.dataTask(with: request) { data, _, error in
      DispatchQueue.main.async {
        if let error {
          self.set("CALENDAR_AUTH_STATUS", "not_authorized")
          self.lastUtilityMessage = "Calendar link check failed: \(error.localizedDescription)"
          return
        }
        guard let data, let text = String(data: data, encoding: .utf8), text.contains("BEGIN:VCALENDAR") else {
          self.set("CALENDAR_AUTH_STATUS", "not_authorized")
          self.lastUtilityMessage = "That link did not return a calendar file."
          return
        }
        self.set("CALENDAR_PROVIDER", "ics")
        self.set("CALENDAR_ICS_URL", trimmed)
        self.set("CALENDAR_AUTH_STATUS", "authorized")
        self.lastUtilityMessage = "Calendar link connected."
      }
    }.resume()
  }

  var progressFraction: Double {
    total > 0 ? Double(processed) / Double(total) : 0
  }

  var isUploading: Bool {
    phase == "uploading"
  }

  var displayProgressFraction: Double {
    if isUploading {
      if uploadPercent > 0 { return min(max(uploadPercent / 100.0, 0), 1) }
      if uploadTotal > 0 { return min(max(Double(uploadDone) / Double(uploadTotal), 0), 1) }
    }
    return progressFraction
  }

  var displayPercent: Int {
    Int(displayProgressFraction * 100)
  }

  var displayProgressCount: String {
    if isUploading {
      if uploadTotal > 0 {
        return "\(uploadDone) / \(uploadTotal) uploaded"
      }
      return "\(imported) staged · uploading"
    }
    return "\(processed) / \(total) files"
  }

  var displayETA: String {
    if isUploading && !uploadETA.isEmpty {
      return uploadETA
    }
    return formatETA(etaSeconds)
  }

  var etaSeconds: Int? {
    guard processed > 0, total > processed, startedEpoch > 0 else { return nil }
    let elapsed = Date().timeIntervalSince1970 - startedEpoch
    guard elapsed > 1 else { return nil }
    let rate = Double(processed) / elapsed
    guard rate > 0 else { return nil }
    return Int(Double(total - processed) / rate)
  }

  // MARK: control actions

  private func ensureControlDir() {
    try? FileManager.default.createDirectory(
      at: DDumpPaths.controlDir, withIntermediateDirectories: true)
  }

  func pause() {
    ensureControlDir()
    FileManager.default.createFile(atPath: DDumpPaths.pauseFlag.path, contents: Data())
    paused = true
  }

  func resume() {
    try? FileManager.default.removeItem(at: DDumpPaths.pauseFlag)
    paused = false
  }

  func setViewOnlyMode(_ enabled: Bool, duration: TimeInterval? = nil) {
    guard !runActive else {
      lastUtilityMessage = "Wait for the current run to finish before changing View Only mode."
      return
    }
    let fm = FileManager.default
    let until = duration.map { Date().timeIntervalSince1970 + $0 } ?? 0
    do {
      try fm.createDirectory(at: DDumpPaths.controlDir, withIntermediateDirectories: true)
      if enabled {
        if duration != nil {
          try "\(Int(until))\n".write(to: DDumpPaths.viewOnlyUntilFile, atomically: true, encoding: .utf8)
        } else if fm.fileExists(atPath: DDumpPaths.viewOnlyUntilFile.path) {
          try fm.removeItem(at: DDumpPaths.viewOnlyUntilFile)
        }
        try Data().write(to: DDumpPaths.viewOnlyFlag, options: .atomic)
      } else {
        if fm.fileExists(atPath: DDumpPaths.viewOnlyFlag.path) {
          try fm.removeItem(at: DDumpPaths.viewOnlyFlag)
        }
        if fm.fileExists(atPath: DDumpPaths.viewOnlyUntilFile.path) {
          try fm.removeItem(at: DDumpPaths.viewOnlyUntilFile)
        }
      }
    } catch {
      lastUtilityMessage = "Could not change the import pause: \(error.localizedDescription)"
      refreshControlFlags()
      return
    }
    if enabled {
      viewOnlyUntilEpoch = until
      viewOnlyMode = true
      lastUtilityMessage = "Imports are paused \(viewOnlyDurationLabel.lowercased()). Newly connected cards and drives will stay untouched and mounted."
    } else {
      viewOnlyMode = false
      viewOnlyUntilEpoch = 0
      lastUtilityMessage = "Automatic card import is back on."
    }
  }

  func pauseAutoImportsForCustomDays() {
    let alert = NSAlert()
    alert.messageText = "Pause imports for custom days"
    alert.informativeText = "Enter a whole number of days. DDump will resume automatic imports when the timer ends."
    alert.alertStyle = .informational
    let field = NSTextField(string: "2")
    field.placeholderString = "Number of days"
    field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
    alert.accessoryView = field
    alert.addButton(withTitle: "Pause Imports")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    let raw = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let days = Int(raw), (1...3650).contains(days) else {
      lastUtilityMessage = "Enter a whole number from 1 to 3650 days."
      return
    }
    setViewOnlyMode(true, duration: TimeInterval(days) * 24 * 60 * 60)
  }

  var viewOnlyDurationLabel: String {
    guard viewOnlyUntilEpoch > 0 else { return "indefinitely" }
    let remaining = max(0, viewOnlyUntilEpoch - Date().timeIntervalSince1970)
    if remaining >= 23 * 60 * 60 {
      let days = Int(ceil(Double(remaining) / Double(24 * 60 * 60)))
      return "for \(days) day\(days == 1 ? "" : "s")"
    }
    if remaining >= 59 * 60 {
      let hours = Int(ceil(Double(remaining) / Double(60 * 60)))
      return "for \(hours) hour\(hours == 1 ? "" : "s")"
    }
    let minutes = max(1, Int(ceil(Double(remaining) / 60.0)))
    return "for \(minutes) minute\(minutes == 1 ? "" : "s")"
  }

  func stop() {
    ensureControlDir()
    FileManager.default.createFile(atPath: DDumpPaths.stopFlag.path, contents: Data())
    stopRequested = true
  }

  func ejectNow() {
    ensureControlDir()
    // Tell the script to stop after current file AND skip the eject grace.
    FileManager.default.createFile(atPath: DDumpPaths.stopFlag.path, contents: Data())
    FileManager.default.createFile(atPath: DDumpPaths.ejectNowFlag.path, contents: Data())
    // Also clear keep_mounted so we don't override the eject.
    try? FileManager.default.removeItem(at: DDumpPaths.keepMountedFlag)
    stopRequested = true
    ejectQueued = true
  }

  func doNotEject() {
    ensureControlDir()
    FileManager.default.createFile(atPath: DDumpPaths.keepMountedFlag.path, contents: Data())
    try? FileManager.default.removeItem(at: DDumpPaths.ejectNowFlag)
    keepMountedRequested = true
    ejectQueued = false
  }

  @discardableResult
  func retryPendingUploads(userMessagePrefix: String = "Retry") -> Bool {
    guard FileManager.default.fileExists(atPath: DDumpPaths.scriptFile.path) else {
      lastUtilityMessage = "DDump script not installed."
      return false
    }
    let task = Process()
    task.launchPath = "/bin/bash"
    task.arguments = [DDumpPaths.scriptFile.path]
    var env = ProcessInfo.processInfo.environment
    env["DDUMP_RETRY_EXISTING_DUMPS"] = "1"
    task.environment = env
    do {
      try task.run()
      lastUtilityMessage = "\(userMessagePrefix) started. DDump will back up existing Dump folders first, then check cards."
      return true
    } catch {
      lastUtilityMessage = "Could not start retry: \(error.localizedDescription)"
      return false
    }
  }

  func cleanupOldStagingFolders() {
    let days = Int(get("SAFE_CLEANUP_DAYS", default: "7")) ?? 7
    let stagingPath = NSString(string: get("DEST_ROOT", default: "\(NSHomeDirectory())/Temp")).expandingTildeInPath
    let stagingURL = URL(fileURLWithPath: stagingPath)
    let fm = FileManager.default
    let cutoff = Date().addingTimeInterval(-Double(max(days, 1)) * 24 * 60 * 60)
    let urls = (try? fm.contentsOfDirectory(at: stagingURL, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey])) ?? []
    let candidates = urls.filter { url in
      let name = url.lastPathComponent
      guard name.hasSuffix("-ddump") || name.hasSuffix("-dump") else { return false }
      let vals = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
      return (vals?.isDirectory == true) && ((vals?.contentModificationDate ?? Date()) < cutoff)
    }
    guard !candidates.isEmpty else {
      lastUtilityMessage = "No staging folders older than \(days) day(s)."
      return
    }

    let alert = NSAlert()
    alert.messageText = "Move old staging folders to Trash?"
    alert.informativeText = "DDump found \(candidates.count) staging folder(s) older than \(days) day(s). This uses the Mac Trash, not permanent deletion."
    alert.addButton(withTitle: "Move to Trash")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }

    var removed = 0
    for url in candidates {
      if (try? fm.trashItem(at: url, resultingItemURL: nil)) != nil {
        removed += 1
      }
    }
    lastUtilityMessage = "Moved \(removed) old staging folder(s) to Trash."
    refreshHealth()
  }

  func ensureUploadServerForAppSession(showProgress: Bool = false, reason: String = "Upload server") {
    guard gdriveMountEnabledForUI else { return }
    guard get("GDRIVE_DIRECT_UPLOAD", default: "0") != "1" else { return }
    guard cloudSetupConnectionOKForUI else {
      refreshCloudMountStatus(showProgress: false)
      return
    }
    startCloudMount(userMessagePrefix: reason, showProgress: showProgress)
  }

  private func setCloudAction(_ running: Bool, _ message: String) {
    if running {
      touchCloudKeepalive()
    }
    DispatchQueue.main.async {
      self.cloudActionInProgress = running
      self.cloudActionMessage = message
    }
  }

  private func appendAppLog(_ message: String) {
    let line = "\(nowTimestamp()) [DDumpApp] \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    do {
      try FileManager.default.createDirectory(
        at: DDumpPaths.logFile.deletingLastPathComponent(),
        withIntermediateDirectories: true)
      if !FileManager.default.fileExists(atPath: DDumpPaths.logFile.path) {
        FileManager.default.createFile(atPath: DDumpPaths.logFile.path, contents: nil)
      }
      let handle = try FileHandle(forWritingTo: DDumpPaths.logFile)
      handle.seekToEndOfFile()
      handle.write(data)
      handle.closeFile()
    } catch {
      // Logging must never block the user action it describes.
    }
  }

  private func plainCloudFailure(_ reason: String) -> String {
    let lower = reason.lowercased()
    if lower.contains("rclone binary") || lower.contains("rclone missing") || lower.contains("rclone install") {
      return "The cloud helper is not installed yet."
    }
    if lower.contains("remote") && lower.contains("not configured") {
      return "Google Drive is not connected yet."
    }
    if lower.contains("launchagent missing") {
      return "DDump's background cloud service is not installed. Run the DDump installer once, then retry."
    }
    if lower.contains("mount retries exhausted") {
      return "DDump could not open the Google Drive folder. Check the internet connection, then retry."
    }
    if lower.contains("timed out") {
      return "Google Drive took too long to respond. Check the internet connection, then retry."
    }
    if reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return "DDump could not finish the cloud setup step."
    }
    if lower.contains("rclone") {
      return reason.replacingOccurrences(of: "rclone", with: "cloud helper")
    }
    return reason
  }

  private func rcloneAuthURL(in text: String) -> String? {
    let pattern = #"http://127\.0\.0\.1:[0-9]+/auth\?state=[A-Za-z0-9_\-]+"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    guard let match = regex.firstMatch(in: text, range: range),
          let swiftRange = Range(match.range, in: text) else {
      return nil
    }
    return String(text[swiftRange])
  }

  private func copyAuthURLForBrowser(_ url: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(url, forType: .string)
    lastUtilityMessage = "Google Drive connection link copied. Paste it into the Chrome profile where you are already logged in."
    appendAppLog("cloud setup auth link copied for browser handoff")
  }

  private func nowTimestamp() -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f.string(from: Date())
  }

  private func showUtilityDialog(title: String, text: String) {
    DispatchQueue.main.async {
      let alert = NSAlert()
      alert.alertStyle = .informational
      alert.messageText = title
      alert.informativeText = text
      alert.addButton(withTitle: "OK")
      alert.runModal()
    }
  }

  private func checkForUpdatesIfNeeded(force: Bool = false) {
    guard get("UPDATE_CHECKS_ENABLED", default: "0") == "1" || force else { return }
    let frequency = get("UPDATE_CHECK_FREQUENCY", default: "weekly")
    let now = Int(Date().timeIntervalSince1970)
    let last = Int(get("UPDATE_LAST_CHECK_EPOCH", default: "0")) ?? 0
    let interval: Int
    switch frequency {
    case "startup":
      interval = 0
    case "monthly":
      interval = 30 * 24 * 60 * 60
    default:
      interval = 7 * 24 * 60 * 60
    }
    if !force && last > 0 && interval > 0 && now - last < interval {
      return
    }
    set("UPDATE_LAST_CHECK_EPOCH", "\(now)")

    let repo = get("UPDATE_GITHUB_REPO", default: "chaserobertsonn/ddump")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !repo.isEmpty,
          let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return }
    var request = URLRequest(url: url)
    request.timeoutInterval = 12
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

    URLSession.shared.dataTask(with: request) { data, _, error in
      if let error {
        DispatchQueue.main.async {
          self.lastUtilityMessage = "Could not check for updates: \(error.localizedDescription)"
        }
        return
      }
      guard let data,
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        DispatchQueue.main.async {
          self.lastUtilityMessage = "Could not read the update response."
        }
        return
      }
      let tag = (json["tag_name"] as? String) ?? ""
      let releaseURL = (json["html_url"] as? String) ?? "https://github.com/\(repo)/releases/latest"
      let assetURL = ((json["assets"] as? [[String: Any]]) ?? [])
        .compactMap { asset -> String? in
          let name = ((asset["name"] as? String) ?? "").lowercased()
          guard name.hasSuffix(".dmg") || name.hasSuffix(".zip") else { return nil }
          return asset["browser_download_url"] as? String
        }
        .first
      guard !tag.isEmpty else { return }

      let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
      if self.normalizedVersion(tag) == self.normalizedVersion(current) {
        DispatchQueue.main.async {
          self.lastUtilityMessage = "DDump is up to date."
        }
        return
      }

      DispatchQueue.main.async {
        self.lastUtilityMessage = "DDump \(tag) is available."
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "DDump update available"
        alert.informativeText = "Installed version: \(current)\nLatest release: \(tag)\n\nDownload the latest installer, then open it to update DDump. Fully automatic updates will be added with signed public releases."
        alert.addButton(withTitle: assetURL == nil ? "Open Download Page" : "Download Installer")
        alert.addButton(withTitle: "Later")
        let shouldOpen = self.get("AUTO_UPDATES_ENABLED", default: "0") == "1" || alert.runModal() == .alertFirstButtonReturn
        if shouldOpen, let url = URL(string: assetURL ?? releaseURL) {
          NSWorkspace.shared.open(url)
        }
      }
    }.resume()
  }

  func checkForUpdatesNow() {
    lastUtilityMessage = "Checking for DDump updates…"
    checkForUpdatesIfNeeded(force: true)
  }

  func runTroubleshooter() {
    refreshHealth()
    refreshSkippedVolumeNotice()
    let backup = todaysUploadDestinationForUI.trimmingCharacters(in: .whitespacesAndNewlines)
    let backupExists = backup.isEmpty ? false : FileManager.default.fileExists(atPath: expandConfiguredPath(backup))
    let dump = dumpRootForUI
    let dumpExists = FileManager.default.fileExists(atPath: expandConfiguredPath(dump))
    let calendarMode = get("CALENDAR_SOURCE", default: "apple")
    let calendarStatus = get("CALENDAR_AUTH_STATUS", default: "not checked")
    let calendarCacheExists = FileManager.default.fileExists(atPath: DDumpPaths.appleCalendarCache.path)
    let calendarSummary = "\(calendarStatus), cache \(calendarCacheExists ? "ready" : "missing")"
    let notice = skippedVolumeNotice.map { "\($0.volume): \($0.reason)" } ?? "none"
    let text = """
    Quick checks:
    Dump Folder: \(dumpExists ? "available" : "missing") — \(displayPath(dump))
    Backup Folder: \(backupExists ? "available" : "missing") — \(shortDisplayPath(backup, keepLastComponents: 5))
    Calendar: \(calendarMode) — \(calendarSummary)
    Last card notice: \(notice)

    If a card did not import, leave it inserted, increase the scan window, or use Manual import and choose the card itself.
    """
    lastUtilityMessage = "Troubleshooter ran. Check the dialog for current status."
    let alert = NSAlert()
    alert.alertStyle = .informational
    alert.messageText = "DDump Troubleshooter"
    alert.informativeText = text
    alert.addButton(withTitle: "Open log")
    alert.addButton(withTitle: "Privacy Settings")
    alert.addButton(withTitle: "Done")
    let result = alert.runModal()
    if result == .alertFirstButtonReturn {
      openInFinder(DDumpPaths.logFile.path)
    } else if result == .alertSecondButtonReturn {
      openNetworkVolumePrivacySettings()
    }
  }

  func openBugReportEmail() {
    let recipient = get("BUG_REPORT_EMAIL", default: "donna@densleyfilmandphoto.com")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !recipient.isEmpty else {
      lastUtilityMessage = "Bug report email is not configured."
      return
    }
    let logTail = recentLogTail(maxLines: 180)
    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    let subject = "DDump bug report \(version)"
    let body = """
    What happened?


    What were you doing right before it happened?


    DDump version: \(version)
    macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
    Computer: \(Host.current().localizedName ?? "unknown")
    Dump Folder: \(displayPath(dumpRootForUI))
    Backup Folder: \(shortDisplayPath(todaysUploadDestinationForUI, keepLastComponents: 5))

    Recent DDump log:
    \(logTail)
    """
    var components = URLComponents()
    components.scheme = "mailto"
    components.path = recipient
    components.queryItems = [
      URLQueryItem(name: "subject", value: subject),
      URLQueryItem(name: "body", value: body)
    ]
    guard let url = components.url else {
      lastUtilityMessage = "Could not prepare bug report email."
      return
    }
    NSWorkspace.shared.open(url)
    lastUtilityMessage = "Prepared bug report email."
  }

  private func recentLogTail(maxLines: Int) -> String {
    guard let text = try? String(contentsOf: DDumpPaths.logFile, encoding: .utf8) else {
      return "No log file found."
    }
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    return lines.suffix(maxLines).joined(separator: "\n")
  }

  private func normalizedVersion(_ raw: String) -> String {
    raw.trimmingCharacters(in: .whitespacesAndNewlines)
      .trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
  }

  var shouldWarnBeforeQuit: Bool {
    if runActive { return true }
    if ["starting", "scanning", "importing", "stopping"].contains(phase) { return true }
    return false
  }

  func startCloudMount(userMessagePrefix: String = "Cloud mount", showProgress: Bool = false, completion: ((Bool) -> Void)? = nil) {
    let mountPoint = gdriveMountPointForUI
    let mountLabel = gdriveMountLabelForUI
    let remote = gdriveRemoteForUI
    let rcloneBin = rcloneBinForUI
    let retryCSV = get("GDRIVE_MOUNT_RETRY_SECONDS", default: "15,30,60,180")
    let waitSeconds = get("GDRIVE_MOUNT_WAIT_SECONDS", default: "30")
    touchCloudKeepalive()
    DispatchQueue.main.async {
      self.lastUtilityMessage = "\(userMessagePrefix) starting…"
    }
    appendAppLog("cloud action start: \(userMessagePrefix) mount start requested")
    if showProgress {
      setCloudAction(true, "Starting cloud mount…")
    }
    DispatchQueue.global(qos: .utility).async {
      let task = Process()
      task.launchPath = "/bin/bash"
      let actionTimeout = max(45, Int(self.get("GDRIVE_ACTION_TIMEOUT_SECONDS", default: "180")) ?? 180)
      let timeoutFlag = DDumpPaths.appSupport.appendingPathComponent("state/cloud-mount-timeout.flag")
      try? FileManager.default.createDirectory(
        at: DDumpPaths.appSupport.appendingPathComponent("state"),
        withIntermediateDirectories: true
      )
      try? Data().write(to: timeoutFlag)
      try? FileManager.default.removeItem(at: timeoutFlag)
      let timeoutQueue = DispatchQueue(label: "ddump.cloud.mount.timeout")
      task.arguments = ["-lc", """
set +e
mount_point=\(shellDoubleQuoted(mountPoint))
mount_label=\(shellDoubleQuoted(mountLabel))
remote=\(shellDoubleQuoted(remote))
rclone_bin=\(shellDoubleQuoted(rcloneBin))
retry_csv=\(shellDoubleQuoted(retryCSV))
wait_seconds=\(shellDoubleQuoted(waitSeconds))
legacy_label="com.ddump.rclone-gdrive.legacy"
lock_dir="${HOME}/Library/Application Support/DDump/state/cloud-mount-start.lock"
if ! [[ "$wait_seconds" =~ ^[0-9]+$ ]]; then wait_seconds=30; fi
if [ "$wait_seconds" -lt 10 ]; then wait_seconds=10; fi
if [ -x "$rclone_bin" ]; then
  rclone="$rclone_bin"
elif command -v rclone >/dev/null 2>&1; then
  rclone="$(command -v rclone)"
else
  echo "ddump_reason=rclone binary not found; install rclone in Cloud settings."
  exit 21
fi
remote_name="${remote%%:*}"
if [ -z "$remote_name" ]; then
  echo "ddump_reason=rclone remote is blank; run Cloud setup."
  exit 22
fi
if ! "$rclone" listremotes 2>/dev/null | /usr/bin/grep -Fxq "${remote_name}:"; then
  echo "ddump_reason=rclone remote '${remote_name}:' is not configured; run Cloud setup."
  exit 23
fi
run_with_timeout() {
  seconds="$1"
  shift
  "$@" >/dev/null 2>&1 &
  pid="$!"
  elapsed=0
  while /bin/kill -0 "$pid" >/dev/null 2>&1; do
    if [ "$elapsed" -ge "$seconds" ]; then
      /bin/kill -TERM "$pid" >/dev/null 2>&1 || true
      /bin/sleep 1
      /bin/kill -KILL "$pid" >/dev/null 2>&1 || true
      /bin/wait "$pid" >/dev/null 2>&1 || true
      return 124
    fi
    /bin/sleep 1
    elapsed=$((elapsed+1))
  done
  /bin/wait "$pid" >/dev/null 2>&1
}
mount_entry_exists() {
  /sbin/mount | /usr/bin/grep -q " on ${mount_point} "
}
mount_ready() {
  mount_entry_exists || return 1
  run_with_timeout 8 /bin/ls -1 "${mount_point}"
}
clear_stale_mount() {
  mount_entry_exists || return 0
  mount_ready && return 0
  /bin/launchctl bootout "gui/${uid}/${mount_label}" >/dev/null 2>&1 || true
  /bin/launchctl bootout "gui/${uid}/${legacy_label}" >/dev/null 2>&1 || true
  stale_pids="$(/usr/bin/pgrep -f "rclone (mount|nfsmount).* ${mount_point}" 2>/dev/null || true)"
  if [ -n "$stale_pids" ]; then
    /bin/kill -TERM $stale_pids >/dev/null 2>&1 || true
    /bin/sleep 1
    /bin/kill -KILL $stale_pids >/dev/null 2>&1 || true
  fi
  run_with_timeout 10 /sbin/umount -f "${mount_point}" || true
  run_with_timeout 10 /usr/sbin/diskutil unmount force "${mount_point}" || true
}
uid="$(/usr/bin/id -u)"
clear_stale_mount
if mount_ready; then
  echo "ddump_reason=mount already active"
  exit 0
fi
if [ -x "${HOME}/.local/bin/finderserver" ]; then
  "${HOME}/.local/bin/finderserver" on >/dev/null 2>&1 || true
fi
plist="${HOME}/Library/LaunchAgents/${mount_label}.plist"
/bin/mkdir -p "${mount_point}"
/bin/mkdir -p "${HOME}/Library/Application Support/DDump/state"
lock_pid_file="${lock_dir}/pid"
if ! /bin/mkdir "${lock_dir}" >/dev/null 2>&1; then
  stale_lock=0
  lock_pid="$(/bin/cat "${lock_pid_file}" 2>/dev/null || true)"
  if [ -z "${lock_pid}" ]; then
    stale_lock=1
  elif ! echo "${lock_pid}" | /usr/bin/grep -Eq '^[0-9]+$'; then
    stale_lock=1
  elif ! /bin/kill -0 "${lock_pid}" >/dev/null 2>&1; then
    stale_lock=1
  fi
  if [ "${stale_lock}" = "0" ]; then
    lock_mtime="$(/usr/bin/stat -f '%m' "${lock_dir}" 2>/dev/null || echo 0)"
    now_epoch="$(/bin/date '+%s')"
    if echo "${lock_mtime}" | /usr/bin/grep -Eq '^[0-9]+$'; then
      if [ $((now_epoch - lock_mtime)) -gt 180 ]; then
        stale_lock=1
      fi
    fi
  fi
  if [ "${stale_lock}" = "1" ]; then
    /bin/rm -f "${lock_pid_file}" >/dev/null 2>&1 || true
    /bin/rmdir "${lock_dir}" >/dev/null 2>&1 || true
    /bin/mkdir "${lock_dir}" >/dev/null 2>&1 || true
  fi
fi
if ! [ -d "${lock_dir}" ]; then
  # Another mount worker is active. Wait for it to finish instead of exiting "success".
  i=0
  while [ "$i" -lt "$wait_seconds" ]; do
    if mount_ready; then
      exit 0
    fi
    /bin/sleep 1
    i=$((i+1))
  done
  exit 1
fi
/bin/echo "$$" > "${lock_pid_file}"
cleanup_lock() {
  /bin/rm -f "${lock_pid_file}" >/dev/null 2>&1 || true
  /bin/rmdir "${lock_dir}" >/dev/null 2>&1 || true
}
trap cleanup_lock EXIT

if [ ! -f "$plist" ] && [ -f "${HOME}/Library/LaunchAgents/${legacy_label}.plist" ]; then
  mount_label="$legacy_label"
  plist="${HOME}/Library/LaunchAgents/${mount_label}.plist"
fi
if [ ! -f "$plist" ]; then
  echo "ddump_reason=mount LaunchAgent missing at ${plist}."
  exit 1
fi

attempt_mount() {
  if /bin/launchctl print "gui/${uid}/${mount_label}" >/dev/null 2>&1 \
     && ! mount_ready; then
    # Clear any stale scheduled/running agent before retrying.
    /bin/launchctl bootout "gui/${uid}/${mount_label}" >/dev/null 2>&1 || true
  fi
  /bin/launchctl bootstrap "gui/${uid}" "$plist" >/dev/null 2>&1 || true
  /bin/launchctl kickstart -k "gui/${uid}/${mount_label}" >/dev/null 2>&1 || true
  i=0
  while [ "$i" -lt "$wait_seconds" ]; do
    if mount_ready; then
      return 0
    fi
    /bin/sleep 1
    i=$((i+1))
  done
  return 1
}

if attempt_mount; then
  echo "ddump_reason=mount active and ready"
  exit 0
fi

IFS=',' read -r -a retries <<<"$retry_csv"
for delay in "${retries[@]}"; do
  delay="$(echo "$delay" | /usr/bin/xargs)"
  if ! [[ "$delay" =~ ^[0-9]+$ ]]; then
    continue
  fi
  /bin/sleep "$delay"
  if attempt_mount; then
    echo "ddump_reason=mount active and ready"
    exit 0
  fi
done
echo "ddump_reason=mount retries exhausted (check rclone-gdrive.log)."
exit 1
"""]
      let pipe = Pipe()
      task.standardOutput = pipe
      task.standardError = pipe
      do {
        try task.run()
      } catch {
        DispatchQueue.main.async {
          if showProgress {
            self.cloudActionInProgress = false
            self.cloudActionMessage = ""
          }
          self.lastUtilityMessage = "Could not start cloud mount: \(error.localizedDescription)"
          completion?(false)
        }
        return
      }
      timeoutQueue.asyncAfter(deadline: .now() + .seconds(actionTimeout)) {
        if task.isRunning {
          try? Data("1".utf8).write(to: timeoutFlag)
          task.terminate()
          DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .seconds(2)) {
            if task.isRunning {
              task.interrupt()
            }
          }
        }
      }
      task.waitUntilExit()
      let didTimeout = FileManager.default.fileExists(atPath: timeoutFlag.path)
      try? FileManager.default.removeItem(at: timeoutFlag)
      let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
      let parsed = parseShellEnv(out)
      let reason = parsed["ddump_reason"] ?? ""
      let ok = task.terminationStatus == 0 && !didTimeout
      DispatchQueue.main.async {
        if showProgress {
          self.cloudActionInProgress = false
          self.cloudActionMessage = ""
        }
        if ok {
          self.lastUtilityMessage = "\(userMessagePrefix) is on and ready."
          self.appendAppLog("cloud action success: \(userMessagePrefix) mount ready")
        } else {
          if didTimeout {
            self.lastUtilityMessage = "\(userMessagePrefix) timed out after \(actionTimeout)s."
          } else if !reason.isEmpty {
            self.lastUtilityMessage = reason
          } else {
            self.lastUtilityMessage = "\(userMessagePrefix) did not become ready."
          }
          self.appendAppLog("cloud action failed: \(userMessagePrefix) mount not ready: \(self.lastUtilityMessage)")
          let missingNote: String
          if self.needsReinsertCount > 0 {
            missingNote = "Missing from prior checks: \(self.needsReinsertCount) file(s)."
          } else {
            missingNote = "Missing from prior checks: none currently marked."
          }
          if showProgress {
            self.showUtilityDialog(
              title: "Cloud mount not ready",
              text: "\(self.lastUtilityMessage)\nPending upload batches: \(self.pendingUploadCount).\n\(missingNote)\nDiagnostics: \(self.cloudDiagnosticMessage)"
            )
          }
        }
        self.refreshCloudMountStatus(showProgress: false)
        completion?(ok)
      }
    }
  }

  func hardRestartCloudMount() {
    let mountPoint = gdriveMountPointForUI
    let mountLabel = gdriveMountLabelForUI
    lastUtilityMessage = "Hard reset requested…"
    setCloudAction(true, "Hard resetting cloud mount…")
    DispatchQueue.global(qos: .utility).async {
      let task = Process()
      task.launchPath = "/bin/bash"
      task.arguments = ["-lc", """
mount_point=\(shellDoubleQuoted(mountPoint))
mount_label=\(shellDoubleQuoted(mountLabel))
legacy_label="com.ddump.rclone-gdrive.legacy"
uid="$(/usr/bin/id -u)"
run_with_timeout() {
  seconds="$1"
  shift
  "$@" >/dev/null 2>&1 &
  pid="$!"
  elapsed=0
  while /bin/kill -0 "$pid" >/dev/null 2>&1; do
    if [ "$elapsed" -ge "$seconds" ]; then
      /bin/kill -TERM "$pid" >/dev/null 2>&1 || true
      /bin/sleep 1
      /bin/kill -KILL "$pid" >/dev/null 2>&1 || true
      /bin/wait "$pid" >/dev/null 2>&1 || true
      return 124
    fi
    /bin/sleep 1
    elapsed=$((elapsed+1))
  done
  /bin/wait "$pid" >/dev/null 2>&1
}
plist="${HOME}/Library/LaunchAgents/${mount_label}.plist"
if [ ! -f "$plist" ] && [ -f "${HOME}/Library/LaunchAgents/${legacy_label}.plist" ]; then
  mount_label="$legacy_label"
  plist="${HOME}/Library/LaunchAgents/${mount_label}.plist"
fi
if [ -x "${HOME}/.local/bin/finderserver" ]; then
  "${HOME}/.local/bin/finderserver" on >/dev/null 2>&1 || true
fi
/bin/rm -rf "${HOME}/Library/Application Support/DDump/state/rclone-mount.lock" >/dev/null 2>&1 || true
/bin/rm -rf "${HOME}/Library/Application Support/DDump/state/cloud-mount-start.lock" >/dev/null 2>&1 || true
stale_pids="$(/usr/bin/pgrep -f "rclone (mount|nfsmount).* ${mount_point}" 2>/dev/null || true)"
if [ -n "${stale_pids}" ]; then
  /bin/kill -TERM ${stale_pids} >/dev/null 2>&1 || true
  /bin/sleep 1
  /bin/kill -KILL ${stale_pids} >/dev/null 2>&1 || true
fi
if /sbin/mount | /usr/bin/grep -q " on ${mount_point} "; then
  run_with_timeout 10 /sbin/umount -f "${mount_point}" || true
  run_with_timeout 10 /usr/sbin/diskutil unmount force "${mount_point}" || true
fi
/bin/launchctl bootout "gui/${uid}/${mount_label}" >/dev/null 2>&1 || true
/bin/sleep 2
if [ -f "$plist" ]; then
  /bin/launchctl bootstrap "gui/${uid}" "$plist" >/dev/null 2>&1 || true
  /bin/launchctl kickstart -k "gui/${uid}/${mount_label}" >/dev/null 2>&1 || true
fi
exit 0
"""]
      do {
        try task.run()
      } catch {
        DispatchQueue.main.async {
          self.cloudActionInProgress = false
          self.cloudActionMessage = ""
          self.lastUtilityMessage = "Could not hard-restart cloud mount: \(error.localizedDescription)"
        }
        return
      }
      task.waitUntilExit()
      DispatchQueue.main.async {
        self.lastUtilityMessage = "Hard restart requested. Retrying mount..."
        self.startCloudMount(userMessagePrefix: "Cloud hard restart", showProgress: true)
      }
    }
  }

  func stopCloudMount() {
    let mountPoint = gdriveMountPointForUI
    let mountLabel = gdriveMountLabelForUI
    lastUtilityMessage = "Stopping cloud mount…"
    setCloudAction(true, "Stopping cloud mount…")
    DispatchQueue.global(qos: .utility).async {
      let task = Process()
      task.launchPath = "/bin/bash"
      task.arguments = ["-lc", """
mount_point=\(shellDoubleQuoted(mountPoint))
mount_label=\(shellDoubleQuoted(mountLabel))
legacy_label="com.ddump.rclone-gdrive.legacy"
uid="$(/usr/bin/id -u)"
run_with_timeout() {
  seconds="$1"
  shift
  "$@" >/dev/null 2>&1 &
  pid="$!"
  elapsed=0
  while /bin/kill -0 "$pid" >/dev/null 2>&1; do
    if [ "$elapsed" -ge "$seconds" ]; then
      /bin/kill -TERM "$pid" >/dev/null 2>&1 || true
      /bin/sleep 1
      /bin/kill -KILL "$pid" >/dev/null 2>&1 || true
      /bin/wait "$pid" >/dev/null 2>&1 || true
      return 124
    fi
    /bin/sleep 1
    elapsed=$((elapsed+1))
  done
  /bin/wait "$pid" >/dev/null 2>&1
}
if /sbin/mount | /usr/bin/grep -q " on ${mount_point} "; then
  run_with_timeout 10 /sbin/umount -f "${mount_point}" || true
  run_with_timeout 10 /usr/sbin/diskutil unmount force "${mount_point}" || true
fi
/bin/launchctl bootout "gui/${uid}/${mount_label}" >/dev/null 2>&1 || true
/bin/launchctl bootout "gui/${uid}/${legacy_label}" >/dev/null 2>&1 || true
exit 0
"""]
      do {
        try task.run()
      } catch {
        DispatchQueue.main.async {
          self.cloudActionInProgress = false
          self.cloudActionMessage = ""
          self.lastUtilityMessage = "Could not stop cloud mount: \(error.localizedDescription)"
        }
        return
      }
      task.waitUntilExit()
      DispatchQueue.main.async {
        self.cloudActionInProgress = false
        self.cloudActionMessage = ""
        self.lastUtilityMessage = "Cloud mount stop requested."
        self.refreshCloudMountStatus(showProgress: false)
      }
    }
  }

  func refreshCloudMountStatus(showProgress: Bool = false) {
    let mountPoint = gdriveMountPointForUI
    let mountLabel = gdriveMountLabelForUI
    let remote = gdriveRemoteForUI
    let rcloneBin = rcloneBinForUI
    if !cloudUploadsEnabledForUI {
      DispatchQueue.main.async {
        if showProgress {
          self.cloudActionInProgress = false
          self.cloudActionMessage = ""
        }
        self.cloudMountActive = false
        self.cloudServiceLoaded = false
        self.cloudRemoteConfigured = false
        self.cloudDiagnosticMessage = "Cloud uploads are disabled in settings."
        self.cloudLastCheckedAt = self.nowTimestamp()
      }
      return
    }
    if get("GDRIVE_DIRECT_UPLOAD", default: "0") == "1" {
      DispatchQueue.main.async {
        if showProgress {
          self.cloudActionInProgress = false
          self.cloudActionMessage = ""
        }
        self.cloudMountActive = false
        self.cloudServiceLoaded = false
        self.cloudRemoteConfigured = !remote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        self.cloudDiagnosticMessage = "Direct rclone upload mode is active; no Finder mount is required."
        self.cloudLastCheckedAt = self.nowTimestamp()
      }
      return
    }
    if showProgress {
      setCloudAction(true, "Refreshing mount diagnostics…")
    }
    DispatchQueue.global(qos: .utility).async {
      let task = Process()
      task.launchPath = "/bin/bash"
      task.arguments = ["-lc", """
set +e
mount_point=\(shellDoubleQuoted(mountPoint))
mount_label=\(shellDoubleQuoted(mountLabel))
remote=\(shellDoubleQuoted(remote))
rclone_bin=\(shellDoubleQuoted(rcloneBin))

run_with_timeout() {
  seconds="$1"
  shift
  "$@" >/dev/null 2>&1 &
  pid="$!"
  elapsed=0
  while /bin/kill -0 "$pid" >/dev/null 2>&1; do
    if [ "$elapsed" -ge "$seconds" ]; then
      /bin/kill -TERM "$pid" >/dev/null 2>&1 || true
      /bin/sleep 1
      /bin/kill -KILL "$pid" >/dev/null 2>&1 || true
      /bin/wait "$pid" >/dev/null 2>&1 || true
      return 124
    fi
    /bin/sleep 1
    elapsed=$((elapsed+1))
  done
  /bin/wait "$pid" >/dev/null 2>&1
}
mount_ready() {
  /sbin/mount | /usr/bin/grep -q " on ${mount_point} " || return 1
  run_with_timeout 8 /bin/ls -1 "${mount_point}"
}

if [ -x "$rclone_bin" ]; then
  rclone="$rclone_bin"
elif command -v rclone >/dev/null 2>&1; then
  rclone="$(command -v rclone)"
else
  rclone=""
fi

if [ -n "$rclone" ]; then
  rclone_ready=1
  echo "rclone_ready=1"
  remotes="$("$rclone" listremotes 2>/dev/null || true)"
  first_remote="$(printf '%s\n' "$remotes" | /usr/bin/sed -n '1p')"
  remote_count="$(printf '%s\n' "$remotes" | /usr/bin/sed '/^$/d' | /usr/bin/wc -l | /usr/bin/awk '{print $1}')"
  echo "first_remote=$first_remote"
  echo "remote_count=$remote_count"
  remote_name="${remote%%:*}:"
  if printf '%s\n' "$remotes" | /usr/bin/grep -Fxq "$remote_name"; then
    remote_configured=1
    echo "remote_configured=1"
  else
    remote_configured=0
    echo "remote_configured=0"
  fi
else
  rclone_ready=0
  remote_configured=0
  echo "rclone_ready=0"
  echo "remote_configured=0"
  echo "first_remote="
  echo "remote_count=0"
fi

if mount_ready; then
  mount_active=1
  echo "mount_active=1"
else
  mount_active=0
  echo "mount_active=0"
fi

if /usr/sbin/scutil -r www.apple.com 2>/dev/null | /usr/bin/grep -q "Reachable"; then
  echo "network_online=1"
else
  echo "network_online=0"
fi

uid="$(/usr/bin/id -u)"
legacy_label="com.ddump.rclone-gdrive.legacy"
if /usr/bin/pgrep -f "rclone (mount|nfsmount).* ${mount_point}" >/dev/null 2>&1; then
  rclone_proc=1
else
  rclone_proc=0
fi

if /bin/launchctl print "gui/${uid}/${mount_label}" >/dev/null 2>&1; then
  service_loaded=1
  echo "service_loaded=1"
elif /bin/launchctl print "gui/${uid}/${legacy_label}" >/dev/null 2>&1; then
  service_loaded=1
  echo "service_loaded=1"
elif [ "${rclone_proc:-0}" = "1" ]; then
  service_loaded=1
  echo "service_loaded=1"
else
  service_loaded=0
  echo "service_loaded=0"
fi

diag=""
if [ "${rclone_ready:-0}" = "0" ]; then
  diag="rclone binary not found"
elif [ "${remote_configured:-0}" = "0" ]; then
  diag="rclone remote '${remote}' is not configured"
elif [ "${mount_active:-0}" = "1" ]; then
  diag="mount active and ready"
elif /sbin/mount | /usr/bin/grep -q " on ${mount_point} "; then
  diag="mount is present but not responding; restart the cloud mount"
elif [ "${service_loaded:-0}" = "0" ]; then
  diag="mount service is not loaded"
else
  last_log="$(tail -n 1 "${HOME}/Library/Application Support/DDump/logs/rclone-gdrive.log" 2>/dev/null || true)"
  if [ -n "$last_log" ]; then
    diag="service running but mount inactive; last mount log: ${last_log}"
  else
    diag="service running but mount inactive"
  fi
fi
echo "diag_reason=$diag"
echo "checked_at=$(/bin/date '+%Y-%m-%d %H:%M:%S')"
"""]
      let pipe = Pipe()
      task.standardOutput = pipe
      task.standardError = Pipe()
      do {
        try task.run()
      } catch {
        DispatchQueue.main.async {
          if showProgress {
            self.cloudActionInProgress = false
            self.cloudActionMessage = ""
          }
        }
        return
      }
      task.waitUntilExit()
      let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
      let parsed = parseShellEnv(out)
      DispatchQueue.main.async {
        if showProgress {
          self.cloudActionInProgress = false
          self.cloudActionMessage = ""
        }
        self.cloudMountActive = parsed["mount_active"] == "1"
        self.cloudServiceLoaded = parsed["service_loaded"] == "1"
        self.cloudRcloneReady = parsed["rclone_ready"] == "1"
        self.cloudRemoteConfigured = parsed["remote_configured"] == "1"
        let discoveredFirstRemote = (parsed["first_remote"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let discoveredRemoteCount = Int(parsed["remote_count"] ?? "0") ?? 0
        let configuredRemote = self.get("GDRIVE_REMOTE", default: "combined:").trimmingCharacters(in: .whitespacesAndNewlines)
        if !self.cloudRemoteConfigured
           && discoveredRemoteCount == 1
           && !discoveredFirstRemote.isEmpty
           && (configuredRemote.isEmpty || configuredRemote == "combined:") {
          self.set("GDRIVE_REMOTE", discoveredFirstRemote)
          self.lastUtilityMessage = "Cloud remote auto-selected: \(discoveredFirstRemote)"
          self.refreshCloudMountStatus(showProgress: false)
          return
        }
        self.cloudDiagnosticMessage = parsed["diag_reason"] ?? ""
        self.networkOnline = parsed["network_online"] == "1"
        self.cloudLastCheckedAt = parsed["checked_at"] ?? self.nowTimestamp()
      }
    }
  }

  func installRcloneViaApp() {
    let configuredBin = rcloneBinForUI
    setCloudAction(true, "Installing cloud helper…")
    lastUtilityMessage = "Installing the cloud helper…"
    appendAppLog("cloud setup button: install cloud helper")
    DispatchQueue.global(qos: .utility).async {
      let task = Process()
      task.launchPath = "/bin/bash"
      task.arguments = ["-lc", """
set +e
export PATH="${HOME}/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
configured_bin=\(shellDoubleQuoted(configuredBin))

expand_user_path() {
  local raw="$1"
  raw="${raw/#\\$HOME/$HOME}"
  raw="${raw/#$HOME/$HOME}"
  raw="${raw/#\\~/$HOME}"
  printf '%s' "$raw"
}

emit_success() {
  local path="$1"
  echo "install_ok=1"
  echo "rclone_path=$path"
  echo "install_message=rclone ready at $path"
  exit 0
}

emit_fail() {
  local msg="$1"
  echo "install_ok=0"
  echo "install_message=$msg"
  exit 1
}

configured_bin="$(expand_user_path "$configured_bin")"
candidate=""

if [ -n "$configured_bin" ] && [ -x "$configured_bin" ]; then
  candidate="$configured_bin"
fi

if [ -z "$candidate" ] && command -v rclone >/dev/null 2>&1; then
  candidate="$(command -v rclone)"
fi

if [ -z "$candidate" ]; then
  arch="$(/usr/bin/uname -m)"
  case "$arch" in
    arm64) archive="rclone-current-osx-arm64.zip" ;;
    x86_64) archive="rclone-current-osx-amd64.zip" ;;
    *) emit_fail "Unsupported Mac architecture: $arch" ;;
  esac

  tmpdir="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ddump-rclone.XXXXXX")"
  if [ -z "$tmpdir" ] || [ ! -d "$tmpdir" ]; then
    emit_fail "Could not create temp folder for rclone install."
  fi
  zip_path="$tmpdir/$archive"
  url="https://downloads.rclone.org/${archive}"
  /usr/bin/curl -fsSL --connect-timeout 20 --max-time 240 "$url" -o "$zip_path" || emit_fail "Download failed for ${url}"
  /usr/bin/unzip -q "$zip_path" -d "$tmpdir" || emit_fail "Could not unzip downloaded rclone package."
  extracted_dir="$(/usr/bin/find "$tmpdir" -maxdepth 1 -type d -name "rclone-v*" | /usr/bin/head -n 1)"
  if [ -z "$extracted_dir" ] || [ ! -x "$extracted_dir/rclone" ]; then
    emit_fail "Downloaded rclone package did not contain a runnable binary."
  fi
  /bin/mkdir -p "${HOME}/bin" || emit_fail "Could not create ${HOME}/bin."
  /bin/cp "$extracted_dir/rclone" "${HOME}/bin/rclone" || emit_fail "Could not copy rclone into ${HOME}/bin."
  /bin/chmod +x "${HOME}/bin/rclone" || emit_fail "Could not mark ${HOME}/bin/rclone executable."
  candidate="${HOME}/bin/rclone"
fi

if [ ! -x "$candidate" ]; then
  emit_fail "rclone install finished but executable was not found."
fi

"$candidate" version >/dev/null 2>&1 || emit_fail "rclone installed, but version check failed."
emit_success "$candidate"
"""]
      let pipe = Pipe()
      task.standardOutput = pipe
      task.standardError = pipe
      do {
        try task.run()
      } catch {
        DispatchQueue.main.async {
          self.cloudActionInProgress = false
          self.cloudActionMessage = ""
          self.lastUtilityMessage = "Could not start cloud helper install: \(error.localizedDescription)"
          self.appendAppLog("cloud setup install failed to start: \(error.localizedDescription)")
        }
        return
      }
      task.waitUntilExit()
      let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
      let parsed = parseShellEnv(out)
      let installOK = task.terminationStatus == 0 && parsed["install_ok"] == "1"
      let installMessage = parsed["install_message"] ?? ""
      let installedPath = parsed["rclone_path"] ?? ""
      DispatchQueue.main.async {
        self.cloudActionInProgress = false
        self.cloudActionMessage = ""
        if installOK {
          if !installedPath.isEmpty {
            self.set("RCLONE_BIN", installedPath)
          }
          self.lastUtilityMessage = "Cloud helper installed. Opening Google Drive connection…"
          self.appendAppLog("cloud setup install success: \(installMessage.isEmpty ? installedPath : installMessage)")
          self.refreshCloudMountStatus(showProgress: false)
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            self.launchCloudSetupInBrowser()
          }
        } else {
          self.lastUtilityMessage = installMessage.isEmpty
            ? "Cloud helper install failed. Check the internet connection, then retry."
            : self.plainCloudFailure(installMessage)
          self.appendAppLog("cloud setup install failed: \(self.lastUtilityMessage)")
          self.showUtilityDialog(
            title: "Cloud helper install failed",
            text: self.lastUtilityMessage
          )
        }
      }
    }
  }

  func openNetworkVolumePrivacySettings() {
    let candidates = [
      "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders",
      "x-apple.systempreferences:com.apple.preference.security?Privacy"
    ]
    for raw in candidates {
      if let u = URL(string: raw), NSWorkspace.shared.open(u) {
        lastUtilityMessage = "Opened macOS privacy settings."
        return
      }
    }
    lastUtilityMessage = "Could not open privacy settings automatically."
  }

  func resumePendingUploadsNow() {
    setCloudAction(true, "Checking mount and resuming uploads…")
    startCloudMount(userMessagePrefix: "Cloud mount", showProgress: false) { ready in
      DispatchQueue.main.async {
        self.cloudActionInProgress = false
        self.cloudActionMessage = ""
        if !ready {
          self.lastUtilityMessage = "Cloud mount is not ready yet. DDump will auto-resume when network/mount recover."
          return
        }
        if self.retryPendingUploads(userMessagePrefix: "Resume now") {
          self.lastUtilityMessage = "Resume now started."
        }
      }
    }
  }

  func launchCloudSetupInBrowser() {
    if cloudSetupBrowserRunning {
      lastUtilityMessage = "Google Drive connection is already open. Finish it in the browser, or cancel and try again."
      appendAppLog("cloud setup button: connect clicked while sign-in already running")
      return
    }
    let configuredBin = rcloneBinForUI
    let configuredRemote = gdriveRemoteForUI
    cloudSetupBrowserRunning = true
    lastUtilityMessage = "Opening Google Drive connection in your browser…"
    setCloudAction(true, "Opening Google Drive connection…")
    appendAppLog("cloud setup button: connect Google Drive")
    DispatchQueue.global(qos: .utility).async {
      let task = Process()
      task.launchPath = "/bin/bash"
      task.arguments = ["-lc", """
set +e
export PATH="${HOME}/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
configured_bin=\(shellDoubleQuoted(configuredBin))
configured_remote=\(shellDoubleQuoted(configuredRemote))
expand_user_path() {
  local raw="$1"
  raw="${raw/#\\$HOME/$HOME}"
  raw="${raw/#$HOME/$HOME}"
  raw="${raw/#\\~/$HOME}"
  printf '%s' "$raw"
}
configured_bin="$(expand_user_path "$configured_bin")"
if [ -n "$configured_bin" ] && [ -x "$configured_bin" ]; then
  rclone="$configured_bin"
elif command -v rclone >/dev/null 2>&1; then
  rclone="$(command -v rclone)"
elif [ -x "/opt/homebrew/bin/rclone" ]; then
  rclone="/opt/homebrew/bin/rclone"
elif [ -x "/usr/local/bin/rclone" ]; then
  rclone="/usr/local/bin/rclone"
else
  echo "setup_error=rclone missing"
  exit 2
fi
echo "rclone_path=$rclone"
ensure_shared_drive_mount_remote() {
  local base_name="$1"
  local conf token drives_file remote_name label upstreams count tmp_conf
  conf="$("$rclone" config file 2>/dev/null | /usr/bin/tail -n 1)"
  [[ -n "$conf" && -w "$conf" ]] || return 1
  token="$("$rclone" config show "$base_name" 2>/dev/null | /usr/bin/sed -n 's/^token = //p')"
  [[ -n "$token" ]] || return 1
  drives_file="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/ddump-rclone-drives.XXXXXX")"
  "$rclone" backend drives "${base_name}:" >"$drives_file" 2>/dev/null || { /bin/rm -f "$drives_file"; return 1; }
  upstreams="MyDrive=${base_name}:"
  count=0
  while IFS=$'\\t' read -r drive_id drive_name; do
    [[ -n "$drive_id" && -n "$drive_name" ]] || continue
    count=$((count + 1))
    label="$(printf '%s' "$drive_name" | /usr/bin/tr -cd '[:alnum:]_-' | /usr/bin/cut -c1-32)"
    [[ -n "$label" ]] || label="Shared${count}"
    remote_name="ddump-${label}"
    if ! "$rclone" listremotes 2>/dev/null | /usr/bin/grep -Fxq "${remote_name}:"; then
      {
        /bin/echo ""
        /bin/echo "[${remote_name}]"
        /bin/echo "type = drive"
        /bin/echo "scope = drive"
        /bin/echo "team_drive = ${drive_id}"
        /bin/echo "token = ${token}"
      } >>"$conf"
    fi
    upstreams="${upstreams} ${label}=${remote_name}:"
  done < <(/usr/bin/awk '
    /"id":/ { id=$0; sub(/^.*"id": "/, "", id); sub(/".*$/, "", id) }
    /"name":/ { name=$0; sub(/^.*"name": "/, "", name); sub(/".*$/, "", name); gsub(/\\\\u0026/, "\\\\&", name); if (id != "") print id "\\t" name; id="" }
  ' "$drives_file")
  /bin/rm -f "$drives_file"
  [[ "$count" -gt 0 ]] || return 1
  tmp_conf="${conf}.ddump.$$"
  /usr/bin/awk 'BEGIN { skip=0 } /^\\[combined\\]$/ { skip=1; next } /^\\[/ { skip=0 } !skip { print }' "$conf" >"$tmp_conf" && /bin/mv "$tmp_conf" "$conf"
  {
    /bin/echo ""
    /bin/echo "[combined]"
    /bin/echo "type = combine"
    /bin/echo "upstreams = ${upstreams}"
  } >>"$conf"
  return 0
}
remotes="$("$rclone" listremotes 2>/dev/null || true)"
configured_name="${configured_remote%%:*}"
target_name="ddump-gdrive"
if [ -n "$configured_name" ] && [ "$configured_name" != "combined" ]; then
  target_name="$configured_name"
fi
if [ -n "$configured_name" ] && printf '%s\\n' "$remotes" | /usr/bin/grep -Fxq "${configured_name}:"; then
  echo "selected_remote=${configured_name}:"
  echo "setup_status=already_connected"
  exit 0
fi
if printf '%s\\n' "$remotes" | /usr/bin/grep -Fxq "${target_name}:"; then
  if ensure_shared_drive_mount_remote "$target_name"; then
    echo "selected_remote=combined:"
  else
    echo "selected_remote=${target_name}:"
  fi
  echo "setup_status=already_connected"
  exit 0
fi
"$rclone" config create "$target_name" drive scope drive config_is_local true
create_status=$?
if [ "$create_status" -ne 0 ]; then
  echo "setup_error=Google Drive connection did not finish."
  exit "$create_status"
fi
remotes="$("$rclone" listremotes 2>/dev/null || true)"
if printf '%s\\n' "$remotes" | /usr/bin/grep -Fxq "${target_name}:"; then
  if ensure_shared_drive_mount_remote "$target_name"; then
    echo "selected_remote=combined:"
  else
    echo "selected_remote=${target_name}:"
  fi
  echo "setup_status=connected"
  exit 0
fi
count="$(printf '%s\\n' "$remotes" | /usr/bin/sed '/^$/d' | /usr/bin/wc -l | /usr/bin/awk '{print $1}')"
if [ "$count" = "1" ]; then
  selected="$(printf '%s\\n' "$remotes" | /usr/bin/sed -n '1p')"
  echo "selected_remote=$selected"
  echo "setup_status=connected"
  exit 0
fi
echo "setup_error=Google Drive connection finished, but DDump could not identify the connected account."
exit 4
"""]
      let pipe = Pipe()
      task.standardOutput = pipe
      task.standardError = pipe
      let outputLock = NSLock()
      var liveOutput = ""
      var copiedAuthURL = ""
      pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
        let data = handle.availableData
        guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
        outputLock.lock()
        liveOutput += chunk
        let combinedOutput = liveOutput
        outputLock.unlock()
        guard let self, let authURL = self.rcloneAuthURL(in: combinedOutput), authURL != copiedAuthURL else { return }
        copiedAuthURL = authURL
        DispatchQueue.main.async {
          self.copyAuthURLForBrowser(authURL)
        }
      }
      do {
        try task.run()
      } catch {
        pipe.fileHandleForReading.readabilityHandler = nil
        DispatchQueue.main.async {
          self.cloudActionInProgress = false
          self.cloudActionMessage = ""
          self.cloudSetupBrowserRunning = false
          self.lastUtilityMessage = "Could not open Google Drive connection: \(error.localizedDescription)"
          self.appendAppLog("cloud setup connect failed to start: \(error.localizedDescription)")
        }
        return
      }
      DispatchQueue.main.async {
        self.cloudSetupProcess = task
        if task.isRunning {
          self.cloudSetupBrowserRunning = true
          self.cloudActionInProgress = false
          self.cloudActionMessage = ""
          self.lastUtilityMessage = "Google Drive connection is open. Finish sign-in in the browser; DDump will continue automatically."
          self.appendAppLog("cloud setup connect running: waiting for browser sign-in")
        }
      }
      task.terminationHandler = { [weak self] finished in
        guard let self else { return }
        pipe.fileHandleForReading.readabilityHandler = nil
        outputLock.lock()
        let output = liveOutput
        outputLock.unlock()
        let parsed = parseShellEnv(output)
        DispatchQueue.main.async {
          self.cloudSetupProcess = nil
          self.cloudSetupBrowserRunning = false
          self.cloudActionInProgress = false
          self.cloudActionMessage = ""
          let selectedRemote = (parsed["selected_remote"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
          if finished.terminationStatus == 0 && !selectedRemote.isEmpty {
            let rclonePath = parsed["rclone_path"] ?? ""
            if !rclonePath.isEmpty {
              self.set("RCLONE_BIN", rclonePath)
            }
            self.set("GDRIVE_REMOTE", selectedRemote)
            self.set("CLOUD_UPLOADS_ENABLED", "1")
            self.set("GDRIVE_MOUNT_ENABLED", "0")
            self.set("GDRIVE_DIRECT_UPLOAD", "0")
            self.set("ENABLE_POST_EJECT_MOVE", "1")
            self.set("CLOUD_SETUP_CONNECTION_OK", "0")
            self.lastUtilityMessage = "Google Drive connected. Next, choose the upload folder."
            self.appendAppLog("cloud setup connect success: selected_remote=\(selectedRemote)")
            self.refreshCloudMountStatus(showProgress: false)
            NSApplication.shared.activate(ignoringOtherApps: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
              if self.cloudDestinationReadyForUI {
                self.testCloudUploadConnection(showProgress: true)
              } else {
                self.chooseCloudDestinationFolder()
              }
            }
          } else if finished.terminationStatus != 0 {
            let reason = self.plainCloudFailure(parsed["setup_error"] ?? "Google Drive connection did not finish.")
            self.lastUtilityMessage = reason
            self.appendAppLog("cloud setup connect failed: \(reason)")
            self.showUtilityDialog(
              title: "Google Drive not connected",
              text: "\(reason)\nClick Connect Google Drive to try again."
            )
          } else {
            self.lastUtilityMessage = "Google Drive connection finished, but DDump could not identify the connected account."
            self.appendAppLog("cloud setup connect failed: no selected remote")
          }
        }
      }
    }
  }

  func stopCloudSetupInBrowser(showMessage: Bool = true) {
    guard let task = cloudSetupProcess else {
      if showMessage {
        lastUtilityMessage = "Google Drive connection is not running."
      }
      cloudSetupBrowserRunning = false
      appendAppLog("cloud setup cancel requested: no sign-in process running")
      return
    }
    if task.isRunning {
      task.terminate()
      DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2.0) {
        if task.isRunning {
          task.interrupt()
        }
      }
    }
    cloudSetupProcess = nil
    cloudSetupBrowserRunning = false
    if showMessage {
      lastUtilityMessage = "Cancelled Google Drive connection."
    }
    appendAppLog("cloud setup cancel requested")
  }

  func finishCloudSetupFromBrowser() {
    setCloudAction(true, "Checking Google Drive connection…")
    lastUtilityMessage = "Checking Google Drive connection…"
    appendAppLog("cloud setup button: check Google Drive connection")
    let configuredBin = rcloneBinForUI
    let configuredRemote = gdriveRemoteForUI
    DispatchQueue.global(qos: .utility).async {
      let task = Process()
      task.launchPath = "/bin/bash"
      task.arguments = ["-lc", """
set +e
export PATH="${HOME}/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
configured_bin=\(shellDoubleQuoted(configuredBin))
configured_remote=\(shellDoubleQuoted(configuredRemote))
expand_user_path() {
  local raw="$1"
  raw="${raw/#\\$HOME/$HOME}"
  raw="${raw/#$HOME/$HOME}"
  raw="${raw/#\\~/$HOME}"
  printf '%s' "$raw"
}
configured_bin="$(expand_user_path "$configured_bin")"
if [ -n "$configured_bin" ] && [ -x "$configured_bin" ]; then
  rclone="$configured_bin"
elif command -v rclone >/dev/null 2>&1; then
  rclone="$(command -v rclone)"
elif [ -x "/opt/homebrew/bin/rclone" ]; then
  rclone="/opt/homebrew/bin/rclone"
elif [ -x "/usr/local/bin/rclone" ]; then
  rclone="/usr/local/bin/rclone"
else
  echo "setup_error=rclone missing"
  exit 2
fi
echo "rclone_path=$rclone"
remotes="$("$rclone" listremotes 2>/dev/null || true)"
count="$(printf '%s\\n' "$remotes" | /usr/bin/sed '/^$/d' | /usr/bin/wc -l | /usr/bin/awk '{print $1}')"
echo "remote_count=$count"
selected=""
current_name="${configured_remote%%:*}:"
if [ -n "$current_name" ] && printf '%s\\n' "$remotes" | /usr/bin/grep -Fxq "$current_name"; then
  selected="$current_name"
fi
if [ -z "$selected" ]; then
  selected="$(printf '%s\\n' "$remotes" | /usr/bin/sed -n '1p')"
fi
echo "selected_remote=$selected"
exit 0
"""]
      let pipe = Pipe()
      task.standardOutput = pipe
      task.standardError = pipe
      do {
        try task.run()
      } catch {
        DispatchQueue.main.async {
          self.cloudActionInProgress = false
          self.cloudActionMessage = ""
          self.lastUtilityMessage = "Could not verify setup: \(error.localizedDescription)"
        }
        return
      }
      task.waitUntilExit()
      let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
      let parsed = parseShellEnv(out)
      let selectedRemote = (parsed["selected_remote"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      let remoteCount = Int(parsed["remote_count"] ?? "0") ?? 0
      let rclonePath = parsed["rclone_path"] ?? ""
      let setupError = parsed["setup_error"] ?? ""
      DispatchQueue.main.async {
        self.cloudActionInProgress = false
        self.cloudActionMessage = ""
        if !setupError.isEmpty {
          self.lastUtilityMessage = self.plainCloudFailure(setupError)
          self.appendAppLog("cloud setup check failed: \(self.lastUtilityMessage)")
          self.showUtilityDialog(
            title: "Cloud setup incomplete",
            text: "\(self.lastUtilityMessage)\nClick Connect Google Drive to try again."
          )
          return
        }
        if remoteCount <= 0 || selectedRemote.isEmpty {
          self.lastUtilityMessage = "Google Drive is not connected yet."
          self.appendAppLog("cloud setup check failed: no remote found")
          self.showUtilityDialog(
            title: "Google Drive not connected",
            text: "Click Connect Google Drive and finish sign-in in the browser."
          )
          return
        }
        if !rclonePath.isEmpty {
          self.set("RCLONE_BIN", rclonePath)
        }
        self.set("GDRIVE_REMOTE", selectedRemote)
        self.set("CLOUD_UPLOADS_ENABLED", "1")
        self.set("GDRIVE_MOUNT_ENABLED", "0")
        self.set("GDRIVE_DIRECT_UPLOAD", "0")
        self.set("ENABLE_POST_EJECT_MOVE", "1")
        self.set("CLOUD_SETUP_CONNECTION_OK", "0")
        let currentDest = self.get("POST_MOVE_ROOT", default: "").trimmingCharacters(in: .whitespacesAndNewlines)
        if currentDest.isEmpty {
          self.set("POST_MOVE_ROOT", self.defaultCloudUploadFolderForUI)
        }
        self.stopCloudSetupInBrowser(showMessage: false)
        self.lastUtilityMessage = "Google Drive connected. Next, choose the upload folder."
        self.appendAppLog("cloud setup check success: selected_remote=\(selectedRemote)")
        if self.cloudDestinationReadyForUI {
          self.testCloudUploadConnection(showProgress: true)
        } else {
          self.chooseCloudDestinationFolder()
        }
      }
    }
  }

  func chooseCloudDestinationFolder() {
    guard !cloudActionInProgress else { return }
    appendAppLog("cloud setup button: choose upload folder")
    if get("GDRIVE_DIRECT_UPLOAD", default: "0") == "1" {
      presentCloudPathPrompt()
    } else {
      lastUtilityMessage = "Opening your Google Drive folder…"
      setCloudAction(true, "Opening Google Drive folder…")
      startCloudMount(userMessagePrefix: "Cloud setup", showProgress: false) { ready in
        DispatchQueue.main.async {
          self.cloudActionInProgress = false
          self.cloudActionMessage = ""
          if !ready {
            let reason = self.plainCloudFailure(self.lastUtilityMessage)
            self.lastUtilityMessage = reason
            self.appendAppLog("cloud setup choose folder failed: \(reason)")
            self.showUtilityDialog(
              title: "Could not open Google Drive folder",
              text: "\(reason)\nClick Choose upload folder to try again."
            )
            return
          }
          self.presentCloudDestinationPicker()
        }
      }
    }
  }

  private func presentCloudPathPrompt() {
    let current = uploadRootForUI.trimmingCharacters(in: .whitespacesAndNewlines)
    let currentRel = cloudRelativePath(current)
    let defaultRel = currentRel?.isEmpty == false ? currentRel! : "DDump Uploads"

    NSApplication.shared.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.messageText = "Choose Google Drive upload folder"
    alert.informativeText = "Enter the folder path inside Google Drive. Shared drives and My Drive folders are both available through the connected rclone remote."
    alert.addButton(withTitle: "Use Folder")
    alert.addButton(withTitle: "Cancel")
    let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 520, height: 24))
    input.stringValue = defaultRel
    input.placeholderString = "Example: Densley/1 — Media/1 — Uploads/1 — Photo"
    alert.accessoryView = input

    guard alert.runModal() == .alertFirstButtonReturn else {
      lastUtilityMessage = "No upload folder chosen yet. Click Choose upload folder to continue."
      appendAppLog("cloud setup choose remote path cancelled")
      return
    }

    let rel = input.stringValue.trimmingCharacters(in: CharacterSet(charactersIn: " \n\r\t/"))
    guard !rel.isEmpty else {
      lastUtilityMessage = "Enter a Google Drive folder path before testing."
      showUtilityDialog(title: "Upload folder not chosen", text: lastUtilityMessage)
      return
    }

    let selectedPath = cloudPseudoLocalPath(relativePath: rel)
    set("POST_MOVE_ROOT", selectedPath)
    set("ENABLE_POST_EJECT_MOVE", "1")
    set("CLOUD_UPLOADS_ENABLED", "1")
    set("GDRIVE_MOUNT_ENABLED", "0")
    set("GDRIVE_DIRECT_UPLOAD", "0")
    set("CLOUD_SETUP_CONNECTION_OK", "0")
    lastUtilityMessage = "Upload folder chosen. Testing \(rel)…"
    appendAppLog("cloud setup choose remote path success: \(rel)")
    testCloudUploadConnection(showProgress: true)
  }

  private func presentCloudDestinationPicker() {
    let mountURL = URL(fileURLWithPath: NSString(string: gdriveMountPointForUI).expandingTildeInPath)
    let defaultURL = URL(fileURLWithPath: defaultCloudUploadFolderForUI)
    try? FileManager.default.createDirectory(at: defaultURL, withIntermediateDirectories: true)

    NSApplication.shared.activate(ignoringOtherApps: true)
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = true
    panel.directoryURL = FileManager.default.fileExists(atPath: defaultURL.path) ? defaultURL : mountURL
    panel.prompt = "Use This Folder"
    panel.message = "Choose the Google Drive folder where DDump should copy finished dumps."
    guard panel.runModal() == .OK, let url = panel.url else {
      lastUtilityMessage = "No upload folder chosen yet. Click Choose upload folder to continue."
      appendAppLog("cloud setup choose folder cancelled")
      return
    }

    let selectedPath = url.path
    guard pathUsesGoogleDriveDestination(selectedPath) else {
      lastUtilityMessage = "Choose a folder inside Google Drive."
      appendAppLog("cloud setup choose folder rejected outside mount: \(selectedPath)")
      showUtilityDialog(
        title: "Choose a Google Drive folder",
        text: "\(lastUtilityMessage)\nClick Choose upload folder to try again."
      )
      return
    }

    set("POST_MOVE_ROOT", selectedPath)
    set("ENABLE_POST_EJECT_MOVE", "1")
    set("CLOUD_UPLOADS_ENABLED", "1")
    set("GDRIVE_MOUNT_ENABLED", "0")
    set("GDRIVE_DIRECT_UPLOAD", "0")
    set("CLOUD_SETUP_CONNECTION_OK", "0")
    lastUtilityMessage = "Upload folder chosen. Testing the connection…"
    appendAppLog("cloud setup choose folder success: \(selectedPath)")
    testCloudUploadConnection(showProgress: true)
  }

  func testCloudUploadConnection(showProgress: Bool = true) {
    var destination = uploadRootForUI.trimmingCharacters(in: .whitespacesAndNewlines)
    if destination.isEmpty {
      destination = defaultCloudUploadFolderForUI
      set("POST_MOVE_ROOT", destination)
    }
    guard pathUsesGoogleDriveDestination(destination) else {
      lastUtilityMessage = "Choose a folder inside the Google Drive folder before testing."
      set("CLOUD_SETUP_CONNECTION_OK", "0")
      appendAppLog("cloud setup test blocked: destination outside mount")
      showUtilityDialog(
        title: "Upload folder not chosen",
        text: "\(lastUtilityMessage)\nClick Choose upload folder to continue."
      )
      return
    }
    let destinationForTest = destination

    if showProgress {
      setCloudAction(true, "Testing upload folder…")
    }
    lastUtilityMessage = "Testing the upload folder…"
    appendAppLog("cloud setup button: test upload folder")
    if get("GDRIVE_DIRECT_UPLOAD", default: "0") == "1" {
      testDirectCloudUploadConnection(destination: destinationForTest, showProgress: showProgress)
      return
    }
    if get("GDRIVE_MOUNT_ENABLED", default: "0") != "1" {
      testLocalCloudFolderConnection(destination: destinationForTest, showProgress: showProgress)
      return
    }
    startCloudMount(userMessagePrefix: "Cloud setup", showProgress: false) { ready in
      if !ready {
        DispatchQueue.main.async {
          if showProgress {
            self.cloudActionInProgress = false
            self.cloudActionMessage = ""
          }
          let reason = self.plainCloudFailure(self.lastUtilityMessage)
          self.set("CLOUD_SETUP_CONNECTION_OK", "0")
          self.lastUtilityMessage = reason
          self.appendAppLog("cloud setup test failed before write: \(reason)")
          self.showUtilityDialog(
            title: "Cloud test failed",
            text: "\(reason)\nClick Retry cloud test to try again."
          )
        }
        return
      }

      DispatchQueue.global(qos: .utility).async {
        let destURL = URL(fileURLWithPath: NSString(string: destinationForTest).expandingTildeInPath)
        let testURL = destURL.appendingPathComponent(".ddump-connection-test-\(UUID().uuidString)")
        do {
          try FileManager.default.createDirectory(at: destURL, withIntermediateDirectories: true)
          try "DDump connection test \(Date())\n".write(to: testURL, atomically: false, encoding: .utf8)
          let attrs = try FileManager.default.attributesOfItem(atPath: testURL.path)
          let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
          guard size > 0 else {
            throw NSError(domain: "DDump", code: 1, userInfo: [NSLocalizedDescriptionKey: "The test file was not written."])
          }
          try? FileManager.default.removeItem(at: testURL)
          DispatchQueue.main.async {
            if showProgress {
              self.cloudActionInProgress = false
              self.cloudActionMessage = ""
            }
            self.set("CLOUD_SETUP_CONNECTION_OK", "1")
            self.set("CLOUD_SETUP_TESTED_AT", self.nowTimestamp())
            self.lastUtilityMessage = "Cloud setup complete. DDump will upload to \(destinationForTest)."
            self.appendAppLog("cloud setup test success: \(destinationForTest)")
            self.refreshCloudMountStatus(showProgress: false)
            self.showUtilityDialog(
              title: "Cloud setup complete",
              text: "DDump will upload finished dumps to:\n\(destinationForTest)"
            )
          }
        } catch {
          try? FileManager.default.removeItem(at: testURL)
          DispatchQueue.main.async {
            if showProgress {
              self.cloudActionInProgress = false
              self.cloudActionMessage = ""
            }
            self.set("CLOUD_SETUP_CONNECTION_OK", "0")
            let reason = self.plainCloudFailure(error.localizedDescription)
            self.lastUtilityMessage = reason
            self.appendAppLog("cloud setup test failed while writing: \(reason)")
            self.showUtilityDialog(
              title: "Cloud test failed",
              text: "\(reason)\nClick Retry cloud test to try again."
            )
          }
        }
      }
    }
  }

  private func testLocalCloudFolderConnection(destination: String, showProgress: Bool) {
    DispatchQueue.global(qos: .utility).async {
      let appPath = self.get("GOOGLE_DRIVE_DESKTOP_APP_PATH", default: "/Applications/Google Drive.app")
      if FileManager.default.fileExists(atPath: appPath) {
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = ["-a", appPath]
        try? task.run()
      } else {
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = ["-a", self.get("GOOGLE_DRIVE_DESKTOP_APP_NAME", default: "Google Drive")]
        try? task.run()
      }

      Thread.sleep(forTimeInterval: 5)

      let destURL = URL(fileURLWithPath: NSString(string: destination).expandingTildeInPath)
      let testURL = destURL.appendingPathComponent(".ddump-connection-test-\(UUID().uuidString)")
      do {
        try FileManager.default.createDirectory(at: destURL, withIntermediateDirectories: true)
        try "DDump Google Drive Desktop handoff test \(Date())\n".write(to: testURL, atomically: false, encoding: .utf8)
        let attrs = try FileManager.default.attributesOfItem(atPath: testURL.path)
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        guard size > 0 else {
          throw NSError(domain: "DDump", code: 1, userInfo: [NSLocalizedDescriptionKey: "The test file was not written."])
        }
        try? FileManager.default.removeItem(at: testURL)
        DispatchQueue.main.async {
          if showProgress {
            self.cloudActionInProgress = false
            self.cloudActionMessage = ""
          }
          self.set("CLOUD_SETUP_CONNECTION_OK", "1")
          self.set("CLOUD_SETUP_TESTED_AT", self.nowTimestamp())
          self.lastUtilityMessage = "Google Drive Desktop folder is ready. DDump will copy finished dumps there and keep staging as backup."
          self.appendAppLog("cloud setup local Drive Desktop test success: \(destination)")
          self.refreshCloudMountStatus(showProgress: false)
          self.showUtilityDialog(
            title: "Cloud setup complete",
            text: "DDump verified local Google Drive handoff to:\n\(destination)\n\nGoogle Drive Desktop will sync it from there. Staging stays on disk as backup."
          )
        }
      } catch {
        try? FileManager.default.removeItem(at: testURL)
        DispatchQueue.main.async {
          if showProgress {
            self.cloudActionInProgress = false
            self.cloudActionMessage = ""
          }
          self.set("CLOUD_SETUP_CONNECTION_OK", "0")
          let reason = self.plainCloudFailure(error.localizedDescription)
          self.lastUtilityMessage = reason
          self.appendAppLog("cloud setup local Drive Desktop test failed: \(reason)")
          self.showUtilityDialog(
            title: "Google Drive folder test failed",
            text: "\(reason)\nOpen Google Drive Desktop, wait for it to finish starting, then retry."
          )
        }
      }
    }
  }

  private func testDirectCloudUploadConnection(destination: String, showProgress: Bool) {
    guard let remoteDest = cloudRemotePath(for: destination) else {
      if showProgress {
        cloudActionInProgress = false
        cloudActionMessage = ""
      }
      set("CLOUD_SETUP_CONNECTION_OK", "0")
      lastUtilityMessage = "Choose a Google Drive folder before testing."
      showUtilityDialog(title: "Upload folder not chosen", text: lastUtilityMessage)
      return
    }

    let configuredBin = rcloneBinForUI
    let testName = ".ddump-connection-test-\(UUID().uuidString)"
    DispatchQueue.global(qos: .utility).async {
      let task = Process()
      task.launchPath = "/bin/bash"
      task.arguments = ["-lc", """
set -euo pipefail
export PATH="${HOME}/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
configured_bin=\(shellDoubleQuoted(configuredBin))
remote_dest=\(shellDoubleQuoted(remoteDest))
test_name=\(shellDoubleQuoted(testName))
expand_user_path() {
  local raw="$1"
  raw="${raw/#\\$HOME/$HOME}"
  raw="${raw/#$HOME/$HOME}"
  raw="${raw/#\\~/$HOME}"
  printf '%s' "$raw"
}
configured_bin="$(expand_user_path "$configured_bin")"
if [ -n "$configured_bin" ] && [ -x "$configured_bin" ]; then
  rclone="$configured_bin"
elif command -v rclone >/dev/null 2>&1; then
  rclone="$(command -v rclone)"
elif [ -x "/opt/homebrew/bin/rclone" ]; then
  rclone="/opt/homebrew/bin/rclone"
elif [ -x "/usr/local/bin/rclone" ]; then
  rclone="/usr/local/bin/rclone"
else
  echo "setup_error=rclone missing"
  exit 2
fi
tmp="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/ddump-cloud-test.XXXXXX")"
cleanup() {
  /bin/rm -f "$tmp" >/dev/null 2>&1 || true
  "$rclone" deletefile "${remote_dest}/${test_name}" >/dev/null 2>&1 || true
}
trap cleanup EXIT
printf 'DDump cloud connection test\\n' > "$tmp"
"$rclone" mkdir "$remote_dest" --tpslimit 1 --tpslimit-burst 1 >/dev/null
"$rclone" copyto "$tmp" "${remote_dest}/${test_name}" --drive-chunk-size 8M --multi-thread-streams 0 --tpslimit 1 --tpslimit-burst 1 --contimeout 10s --timeout 30s --retries 6 --low-level-retries 6 --retries-sleep 10s >/dev/null
"$rclone" lsf "$remote_dest" --max-depth 1 --tpslimit 1 --tpslimit-burst 1 | /usr/bin/grep -Fxq "$test_name"
echo "remote_dest=$remote_dest"
"""]
      let pipe = Pipe()
      task.standardOutput = pipe
      task.standardError = pipe
      do {
        try task.run()
      } catch {
        DispatchQueue.main.async {
          if showProgress {
            self.cloudActionInProgress = false
            self.cloudActionMessage = ""
          }
          self.set("CLOUD_SETUP_CONNECTION_OK", "0")
          self.lastUtilityMessage = "Cloud test failed: \(error.localizedDescription)"
          self.showUtilityDialog(title: "Cloud test failed", text: self.lastUtilityMessage)
        }
        return
      }
      task.waitUntilExit()
      let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
      let parsed = parseShellEnv(out)
      DispatchQueue.main.async {
        if showProgress {
          self.cloudActionInProgress = false
          self.cloudActionMessage = ""
        }
        if task.terminationStatus == 0 {
          self.set("CLOUD_SETUP_CONNECTION_OK", "1")
          self.set("CLOUD_SETUP_TESTED_AT", self.nowTimestamp())
          self.lastUtilityMessage = "Cloud setup complete. DDump verified \(parsed["remote_dest"] ?? remoteDest)."
          self.appendAppLog("cloud setup direct test success: \(remoteDest)")
          self.refreshCloudMountStatus(showProgress: false)
          self.showUtilityDialog(
            title: "Cloud setup complete",
            text: "DDump verified uploads to:\n\(remoteDest)"
          )
        } else {
          self.set("CLOUD_SETUP_CONNECTION_OK", "0")
          let reason = self.plainCloudFailure(parsed["setup_error"] ?? out.trimmingCharacters(in: .whitespacesAndNewlines))
          self.lastUtilityMessage = reason.isEmpty ? "Cloud test failed." : reason
          self.appendAppLog("cloud setup direct test failed: \(self.lastUtilityMessage)")
          self.showUtilityDialog(
            title: "Cloud test failed",
            text: "\(self.lastUtilityMessage)\nClick Test upload folder to try again."
          )
        }
      }
    }
  }

  func openRcloneSetupInTerminal() {
    launchCloudSetupInBrowser()
  }

  func runCloudSetupWizard() {
    let alert = NSAlert()
    alert.alertStyle = .informational
    alert.messageText = "Cloud setup"
    alert.informativeText = """
DDump will guide this in order:

1) Install the cloud helper
2) Connect Google Drive
3) Choose the upload folder
4) Test the connection
"""
    alert.addButton(withTitle: "Start Guided Setup")
    alert.addButton(withTitle: "Dismiss")
    let response = alert.runModal()
    if response == .alertFirstButtonReturn {
      if !cloudRcloneReady {
        installRcloneViaApp()
      } else if !cloudRemoteConfigured {
        launchCloudSetupInBrowser()
      } else if !cloudDestinationReadyForUI {
        chooseCloudDestinationFolder()
      } else {
        testCloudUploadConnection(showProgress: true)
      }
      return
    }
  }

  func startManualSelectionImport() {
    guard !runActive else {
      lastUtilityMessage = "DDump is already running. Stop or let it finish first."
      return
    }
    guard FileManager.default.fileExists(atPath: DDumpPaths.scriptFile.path) else {
      lastUtilityMessage = "DDump script not installed."
      return
    }

    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = true
    panel.canCreateDirectories = false
    panel.directoryURL = URL(fileURLWithPath: "/Volumes")
    panel.prompt = "Select Folder to Import"
    panel.message = "Pick the card itself or a folder on the card. Choose the card volume if you want DDump to recognize it automatically in the future."
    guard panel.runModal() == .OK else { return }

    let selected = panel.urls.map(\.path).filter { !$0.isEmpty }
    guard !selected.isEmpty else {
      lastUtilityMessage = "No files or folders selected."
      return
    }

    let confirmAlert = NSAlert()
    confirmAlert.messageText = "Import selected folder"
    confirmAlert.informativeText = "Trusting a card saves its hardware ID so DDump imports it automatically next time. Import Once does not change your trusted-card list. Exact files already present in the Dump Folder will be skipped either way."
    confirmAlert.alertStyle = .informational
    confirmAlert.addButton(withTitle: "Trust Card & Auto-Import")
    confirmAlert.addButton(withTitle: "Import Once")
    confirmAlert.addButton(withTitle: "Cancel")
    let response = confirmAlert.runModal()
    guard response != .alertThirdButtonReturn else { return }
    let manualPolicy = response == .alertFirstButtonReturn ? "trust" : "once"

    do {
      try FileManager.default.createDirectory(
        at: DDumpPaths.controlDir, withIntermediateDirectories: true)
      let payload = selected.joined(separator: "\n") + "\n"
      try payload.write(to: DDumpPaths.manualSelectionFile, atomically: true, encoding: .utf8)
      try "\(manualPolicy)\n".write(to: DDumpPaths.manualSelectionPolicyFile, atomically: true, encoding: .utf8)
    } catch {
      lastUtilityMessage = "Could not save manual selection: \(error.localizedDescription)"
      return
    }

    let task = Process()
    task.launchPath = "/bin/bash"
    task.arguments = [DDumpPaths.scriptFile.path]
    var env = ProcessInfo.processInfo.environment
    env["DDUMP_MANUAL_SELECTION_FILE"] = DDumpPaths.manualSelectionFile.path
    env["DDUMP_MANUAL_SELECTION_SAFETY_GB"] = "2"
    task.environment = env
    do {
      try task.run()
      lastUtilityMessage = manualPolicy == "trust"
        ? "Manual import started. DDump will remember eligible card volumes for automatic imports."
        : "Manual import started for \(selected.count) selected folder(s)."
    } catch {
      lastUtilityMessage = "Could not start manual import: \(error.localizedDescription)"
    }
  }

}

// MARK: - Helpers

func formatETA(_ seconds: Int?) -> String {
  guard let s = seconds, s > 0 else { return "—" }
  if s < 60 { return "\(s)s" }
  let m = s / 60
  let r = s % 60
  if m < 60 { return "\(m)m \(String(format: "%02d", r))s" }
  let h = m / 60
  let mm = m % 60
  return "\(h)h \(mm)m"
}

func openInFinder(_ path: String) {
  let expanded = expandConfiguredPath(path)
  if FileManager.default.fileExists(atPath: expanded) {
    NSWorkspace.shared.open(URL(fileURLWithPath: expanded))
  } else {
    let alert = NSAlert()
    alert.messageText = "Folder not found"
    alert.informativeText = expanded
    alert.runModal()
  }
}

func titleCaseSettingLabel(_ value: String) -> String {
  switch value {
  case "smart": return "Smart"
  case "brand": return "Brand"
  case "model": return "Model"
  case "full": return "Full"
  case "template": return "Template"
  case "sequential": return "Sequential"
  case "custom": return "Custom"
  case "calendar": return "Calendar"
  case "camera": return "Camera"
  case "lookback", "hours": return "Hours"
  case "today", "calendar_day", "same_day": return "Today"
  default:
    return value
      .replacingOccurrences(of: "_", with: " ")
      .replacingOccurrences(of: "-", with: " ")
      .capitalized
  }
}

extension AppState {
  var currentBytesLabel: String {
    let kb = 1024.0
    let mb = kb * 1024.0
    let gb = mb * 1024.0
    let estimatedPerFile = 6.5 * mb
    let bytes = Double(max(total, 0)) * estimatedPerFile
    if bytes >= gb {
      return String(format: "%.1f GB", bytes / gb)
    }
    if bytes >= mb {
      return String(format: "%.0f MB", bytes / mb)
    }
    return "\(Int(bytes / kb)) KB"
  }
}

struct InfoHint: View {
  let text: String
  @State private var showing = false

  var body: some View {
    Button {
      showing.toggle()
    } label: {
      Image(systemName: "info.circle")
        .foregroundColor(.secondary)
    }
    .buttonStyle(.plain)
    .help(text)
    .popover(isPresented: $showing, arrowEdge: .top) {
      Text(text)
        .font(DDumpFont.ui(12))
        .foregroundColor(.ddumpFG1)
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 260, alignment: .leading)
        .padding(12)
        .background(Color.ddumpSurface)
    }
  }
}

extension Color {
  static let ddumpBG = Color(red: 0x0B / 255.0, green: 0x0A / 255.0, blue: 0x09 / 255.0)
  static let ddumpBGAlt = Color(red: 0x11 / 255.0, green: 0x0F / 255.0, blue: 0x0D / 255.0)
  static let ddumpSurface = Color(red: 0x16 / 255.0, green: 0x13 / 255.0, blue: 0x10 / 255.0)
  static let ddumpSurface2 = Color(red: 0x1D / 255.0, green: 0x1A / 255.0, blue: 0x16 / 255.0)
  static let ddumpSurface3 = Color(red: 0x26 / 255.0, green: 0x22 / 255.0, blue: 0x1C / 255.0)
  static let ddumpSurface4 = Color(red: 0x32 / 255.0, green: 0x2D / 255.0, blue: 0x26 / 255.0)
  static let ddumpFG1 = Color(red: 0xF2 / 255.0, green: 0xEB / 255.0, blue: 0xE0 / 255.0)
  static let ddumpFG2 = Color(red: 0xB8 / 255.0, green: 0xAF / 255.0, blue: 0xA2 / 255.0)
  static let ddumpFG3 = Color(red: 0x7A / 255.0, green: 0x74 / 255.0, blue: 0x68 / 255.0)
  static let ddumpFG4 = Color(red: 0x4E / 255.0, green: 0x48 / 255.0, blue: 0x3F / 255.0)
  static let ddumpLine1 = Color.white.opacity(0.06)
  static let ddumpLine2 = Color.white.opacity(0.10)
  static let ddumpLine3 = Color.white.opacity(0.16)
  static let ddumpPeach = Color(red: 0xE8 / 255.0, green: 0xB9 / 255.0, blue: 0x99 / 255.0)
  static let ddumpPeachLight = Color(red: 0xF4 / 255.0, green: 0xD8 / 255.0, blue: 0xC0 / 255.0)
  static let ddumpPeachSoft = Color(red: 0xE8 / 255.0, green: 0xB9 / 255.0, blue: 0x99 / 255.0, opacity: 0.12)
  static let ddumpSuccess = Color(red: 0x7F / 255.0, green: 0xB0 / 255.0, blue: 0x89 / 255.0)
  static let ddumpWarning = Color(red: 0xD4 / 255.0, green: 0xA8 / 255.0, blue: 0x57 / 255.0)
  static let ddumpDanger = Color(red: 0xD1 / 255.0, green: 0x72 / 255.0, blue: 0x66 / 255.0)
}

enum DDumpFont {
  static func display(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
    let name = (weight == .bold || weight == .black || weight == .heavy) ? "Montserrat Alternates Bold" : "Montserrat Alternates SemiBold"
    return .custom(name, size: size)
  }

  static func ui(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
    let name: String
    if weight == .bold || weight == .black || weight == .heavy {
      name = "Montserrat Bold"
    } else if weight == .semibold {
      name = "Montserrat SemiBold"
    } else if weight == .medium {
      name = "Montserrat Medium"
    } else {
      name = "Montserrat Regular"
    }
    return .custom(name, size: size)
  }
}

struct DDumpPrimaryButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(DDumpFont.ui(13, weight: .medium))
      .lineLimit(1)
      .minimumScaleFactor(0.82)
      .foregroundColor(Color(red: 0x1A / 255.0, green: 0x11 / 255.0, blue: 0x07 / 255.0))
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
      .background(
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .fill(LinearGradient(colors: [.ddumpPeachLight, .ddumpPeach], startPoint: .top, endPoint: .bottom))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .stroke(Color.black.opacity(0.35), lineWidth: 1)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .stroke(Color.white.opacity(0.12), lineWidth: 1)
          .blendMode(.plusLighter)
      )
      .opacity(configuration.isPressed ? 0.88 : 1)
      .scaleEffect(configuration.isPressed ? 0.99 : 1)
  }
}

struct DDumpSecondaryButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(DDumpFont.ui(13, weight: .medium))
      .lineLimit(1)
      .minimumScaleFactor(0.82)
      .foregroundColor(.ddumpFG1)
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
      .background(
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .fill(LinearGradient(colors: [.ddumpSurface3, .ddumpSurface2], startPoint: .top, endPoint: .bottom))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .stroke(Color.black.opacity(0.45), lineWidth: 1)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .stroke(Color.white.opacity(0.08), lineWidth: 1)
          .blendMode(.plusLighter)
      )
      .opacity(configuration.isPressed ? 0.88 : 1)
      .scaleEffect(configuration.isPressed ? 0.99 : 1)
  }
}

struct DDumpStatusPill: View {
  let text: String
  let color: Color

  var body: some View {
    HStack(spacing: 6) {
      Circle()
        .fill(color)
        .frame(width: 6, height: 6)
        .shadow(color: color.opacity(0.7), radius: 4, x: 0, y: 0)
      Text(text)
        .font(DDumpFont.ui(11, weight: .medium))
    }
    .foregroundColor(.ddumpFG1)
    .padding(.horizontal, 10)
    .padding(.vertical, 4)
    .background(color.opacity(0.14), in: Capsule())
  }
}

struct DDumpTabChip: View {
  let icon: String
  let title: String
  let active: Bool
  let onTap: () -> Void

  var body: some View {
    Button(action: onTap) {
      HStack(spacing: 6) {
        Image(systemName: icon)
          .foregroundColor(active ? .ddumpPeach : .ddumpFG2)
        Text(title)
          .lineLimit(1)
          .minimumScaleFactor(0.82)
      }
      .font(DDumpFont.ui(12, weight: active ? .medium : .regular))
      .foregroundColor(active ? .ddumpFG1 : .ddumpFG2)
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
      .background(
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .fill(active ? Color.ddumpSurface2 : Color.clear)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .stroke(active ? Color.black.opacity(0.45) : Color.clear, lineWidth: 1)
      )
    }
    .buttonStyle(.plain)
  }
}

extension View {
  func ddumpFormSkin() -> some View {
    self
      .scrollContentBackground(.hidden)
      .background(Color.ddumpBG)
      .tint(.ddumpPeach)
      .foregroundColor(.ddumpFG1)
  }
}

// MARK: - Main window

struct ContentView: View {
  @EnvironmentObject var state: AppState
  @State private var showingSettings = false
  @State private var showingOnboarding = false

  var phaseColor: Color {
    if state.viewOnlyMode && !state.runActive { return .ddumpWarning }
    switch state.phase {
    case "importing", "scanning", "starting", "uploading", "recovering": return .ddumpPeach
    case "complete": return .ddumpSuccess
    case "stopped", "paused": return .ddumpWarning
    default: return .ddumpFG3
    }
  }

  var phaseLabel: String {
    if state.viewOnlyMode && !state.runActive { return "Imports paused" }
    switch state.phase {
    case "starting": return "Preparing…"
    case "scanning": return "Scanning card"
    case "importing": return state.paused ? "Paused (will resume)" : "Importing"
    case "uploading": return "Uploading"
    case "recovering": return "Recovering"
    case "paused": return "Paused"
    case "stopped": return "Stopped"
    case "complete": return "Done"
    default: return state.runActive ? "Working…" : "Waiting"
    }
  }

  func appIconImage() -> NSImage {
    NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
  }

  var body: some View {
    VStack(spacing: 0) {
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          HStack(spacing: 16) {
            Image(nsImage: appIconImage())
              .resizable()
              .frame(width: 56, height: 56)
              .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
              Text("DDump")
                .font(DDumpFont.display(22, weight: .semibold))
                .foregroundColor(.ddumpFG1)
              HStack(spacing: 10) {
                DDumpStatusPill(text: "\(phaseLabel)\(state.volume.isEmpty ? "" : " · \(state.volume)")", color: phaseColor)
                Text("\(state.total) files · \(state.currentBytesLabel)")
                  .font(.system(size: 12, weight: .regular, design: .monospaced))
                  .foregroundColor(.ddumpFG3)
              }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
              Text("Free locally")
                .font(DDumpFont.ui(11, weight: .semibold))
                .textCase(.uppercase)
                .tracking(1.4)
                .foregroundColor(.ddumpFG3)
              Text("\(state.localFreeGB) GB")
                .font(.system(size: 18, weight: .medium, design: .monospaced))
                .foregroundColor(.ddumpFG1)
            }
          }
          .padding(.bottom, 18)
          .overlay(alignment: .bottom) {
            Rectangle().fill(Color.ddumpLine1).frame(height: 1)
          }

          if state.viewOnlyMode && !state.runActive {
            ViewOnlyPanel()
              .padding(.top, 18)
          }

          if !state.runActive && state.total == 0 {
            IdleView()
              .padding(.top, 18)
            if state.skippedVolumeNotice != nil {
              SkippedVolumePanel()
                .padding(.top, 14)
            }
          } else {
            ProgressDetail()
              .padding(.top, 18)
          }

          ScanWindowInlineControl()
            .padding(.top, 14)

          DestinationSummaryPanel()
            .padding(.top, 18)

          BackupFolderWarningPanel()
            .padding(.top, 14)

          RunChecklistPanel()
            .padding(.top, 20)

          HealthPanel()
            .padding(.top, 18)
        }
        .padding(.horizontal, 28)
        .padding(.top, 22)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, alignment: .topLeading)
      }
      .background(Color.ddumpBG)

      MainActionFooter(showingSettings: $showingSettings)
    }
    .background(Color.ddumpBG)
    .frame(minWidth: 320, minHeight: 360)
    .sheet(isPresented: $showingSettings) {
      SettingsSheet(isPresented: $showingSettings)
        .environmentObject(state)
        .preferredColorScheme(state.preferredColorScheme())
    }
    .sheet(isPresented: $showingOnboarding) {
      FirstRunWizard(isPresented: $showingOnboarding)
        .environmentObject(state)
        .preferredColorScheme(state.preferredColorScheme())
    }
    .onAppear {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
        if state.get("ONBOARDING_COMPLETED", default: "0") != "1" {
          showingOnboarding = true
        }
      }
    }
    .ddumpOnChange(of: state.onboardingRestartRequested) { requested in
      guard requested else { return }
      showingSettings = false
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
        showingOnboarding = true
        state.clearOnboardingRestartRequest()
      }
    }
  }

  private var footerSettingsButton: some View {
    Button {
      showingSettings = true
    } label: {
      Label("Settings", systemImage: "gearshape")
    }
    .buttonStyle(DDumpSecondaryButtonStyle())
    .keyboardShortcut(",", modifiers: .command)
  }

  private var footerBackupButton: some View {
    Button {
      state.openUploadDestination()
    } label: {
      Label("Backup Folder", systemImage: "folder")
    }
    .buttonStyle(DDumpSecondaryButtonStyle())
  }

  private var footerLogButton: some View {
    Button {
      openInFinder(DDumpPaths.logFile.path)
    } label: {
      Label("Log", systemImage: "doc.text")
    }
    .buttonStyle(DDumpSecondaryButtonStyle())
  }
}

struct FirstRunWizard: View {
  @Binding var isPresented: Bool
  @EnvironmentObject var state: AppState
  @State private var page = 0
  @State private var stagingFolder = "\(NSHomeDirectory())/Temp"
  @State private var primaryDestination = ""
  @State private var fallbackEnabled = false
  @State private var fallbackDestination = ""
  @State private var autoEject = true
  @State private var lookbackHours = "24"
  @State private var scanMode = "today"
  @State private var ntfyTopic = ""
  @State private var defaultShootName = ""

  private let pageCount = 4

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack {
        Text("Set Up DDump")
          .font(DDumpFont.display(26, weight: .semibold))
        Spacer()
        Text("Step \(page + 1) of \(pageCount)")
          .foregroundColor(.secondary)
      }

      Group {
        switch page {
        case 0: introPage
        case 1: folderPage
        case 2: safetyPage
        default: notificationPage
        }
      }
      .frame(minHeight: 330, alignment: .topLeading)

      HStack {
        Button(page == pageCount - 1 ? "Skip and Finish" : "Skip this Step") {
          skipStep()
        }
        .buttonStyle(DDumpSecondaryButtonStyle())

        Spacer()

        Button("Back") {
          page = max(0, page - 1)
        }
        .disabled(page == 0)
        .buttonStyle(DDumpSecondaryButtonStyle())

        Button(page == pageCount - 1 ? "Finish" : "Next") {
          if page == pageCount - 1 {
            finish()
          } else {
            saveCurrent()
            page += 1
          }
        }
        .buttonStyle(DDumpPrimaryButtonStyle())
      }
    }
    .padding(28)
    .frame(minWidth: 500, idealWidth: 680, maxWidth: 760)
    .background(Color.ddumpBG)
    .onAppear {
      stagingFolder = state.get("DEST_ROOT", default: "\(NSHomeDirectory())/Temp")
      primaryDestination = state.get("POST_MOVE_ROOT")
      fallbackDestination = state.get("POST_MOVE_FALLBACK_ROOT")
      fallbackEnabled = !fallbackDestination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      autoEject = state.get("EJECT_ON_SUCCESS", default: "1") == "1"
      scanMode = normalizedScanMode(state.get("CANDIDATE_MODE", default: "today"))
      lookbackHours = state.get("LOOKBACK_HOURS", default: "24")
      ntfyTopic = state.get("NTFY_TOPIC")
      defaultShootName = state.get("DEFAULT_SHOOT_NAME")
    }
  }

  private var introPage: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Plug in a camera card and DDump copies only new media into your Dump Folder. When that copy is verified, it can eject the card and copy organized shoot folders to your Backup Folder.")
      wizardBullet("Verify the Dump Folder copy before anything leaves the card.")
      wizardBullet("Name folders from capture times, camera info, or your Mac Calendar.")
      wizardBullet("Send finished folders to Google Drive, Dropbox, Box, OneDrive, iCloud Drive, pCloud, a local drive, or a NAS folder.")
      wizardBullet("Change these choices any time in Settings.")
    }
    .foregroundColor(.ddumpFG1)
  }

  private var folderPage: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Choose the first verified copy and the optional backup copy.")
        .foregroundColor(.secondary)
      labeledFolder("Dump Folder", value: $stagingFolder, prompt: "Choose Dump Folder")
      labeledFolder("Backup Folder", value: $primaryDestination, prompt: "Choose Backup Folder")
      Toggle("Use a fallback if the Backup Folder is unavailable", isOn: $fallbackEnabled)
      if fallbackEnabled {
        labeledFolder("Backup fallback", value: $fallbackDestination, prompt: "Choose Backup Folder fallback")
      }
      Text("Recommended: keep the Dump Folder on this Mac or a connected SSD. The Backup Folder can be cloud, NAS, another SSD, or another local folder.")
        .font(.caption)
        .foregroundColor(.secondary)
    }
  }

  private var safetyPage: some View {
    VStack(alignment: .leading, spacing: 14) {
      Toggle("Auto-eject card after local copy is verified", isOn: $autoEject)
      HStack {
        Text("Scan mode")
        Spacer()
        Picker("", selection: $scanMode) {
          Text("Today").tag("today")
          Text("Hours").tag("lookback")
        }
        .labelsHidden()
        .frame(width: 170)
      }
      HStack {
        Text("Lookback")
        Spacer()
        TextField("24", text: $lookbackHours)
          .frame(width: 80)
          .multilineTextAlignment(.trailing)
        Text("hours")
      }
      .disabled(scanMode != "lookback")
      TextField("Default offline shoot name (optional)", text: $defaultShootName)
      Text("Today is safest for normal same-day imports. Hours is useful when you need to recover older files. DDump still skips files already copied into the Dump Folder.")
        .font(.caption)
        .foregroundColor(.secondary)
    }
  }

  private var notificationPage: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Optional phone alerts")
        .font(DDumpFont.ui(17, weight: .semibold))
      Text("DDump can send phone alerts through ntfy, a lightweight push-notification app for iPhone. Leave this blank if Mac notifications are enough.")
        .foregroundColor(.secondary)
      HStack {
        TextField("Private ntfy topic", text: $ntfyTopic)
      }
      HStack(spacing: 8) {
        Button("iPhone app") {
          if let url = URL(string: "https://apps.apple.com/us/app/ntfy/id1625396347") {
            NSWorkspace.shared.open(url)
          }
        }
        .buttonStyle(DDumpSecondaryButtonStyle())

        Button("Setup guide") {
          if let url = URL(string: "https://ntfy.sh/docs/subscribe/phone/") {
            NSWorkspace.shared.open(url)
          }
        }
        .buttonStyle(DDumpSecondaryButtonStyle())
      }
      Text("Install ntfy on your phone, create or choose a private topic name, then paste that same topic here. You can customize which events use phone alerts later in Settings > Notifications.")
        .font(.caption)
        .foregroundColor(.secondary)
    }
  }

  private func wizardBullet(_ text: String) -> some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: "checkmark.circle.fill").foregroundColor(.ddumpSuccess)
      Text(text)
    }
  }

  private func labeledFolder(_ label: String, value: Binding<String>, prompt: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(label).font(.caption).foregroundColor(.secondary)
      HStack {
        TextField(label, text: value)
        Button("Choose…") {
          if let picked = pickFolder(prompt: prompt) {
            value.wrappedValue = picked
          }
        }
        .buttonStyle(DDumpSecondaryButtonStyle())
      }
    }
  }

  private func saveCurrent() {
    state.set("DEST_ROOT", stagingFolder)
    if !primaryDestination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      state.set("POST_MOVE_ROOT", primaryDestination)
      state.set("ENABLE_POST_EJECT_MOVE", "1")
    }
    state.set("POST_MOVE_FALLBACK_ROOT", fallbackEnabled ? fallbackDestination : "")
    state.set("EJECT_ON_SUCCESS", autoEject ? "1" : "0")
    state.set("LOOKBACK_HOURS", lookbackHours)
    state.set("CANDIDATE_MODE", normalizedScanMode(scanMode))
    state.set("NTFY_TOPIC", ntfyTopic)
    state.set("DEFAULT_SHOOT_NAME", defaultShootName)
  }

  private func finish() {
    saveCurrent()
    state.set("ONBOARDING_COMPLETED", "1")
    isPresented = false
  }

  private func skipStep() {
    saveCurrent()
    if page == pageCount - 1 {
      state.set("ONBOARDING_COMPLETED", "1")
      isPresented = false
    } else {
      page += 1
    }
  }

  private func normalizedScanMode(_ value: String) -> String {
    let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return (cleaned == "lookback" || cleaned == "hours") ? "lookback" : "today"
  }
}

/// Settings presented as a sheet so it ALWAYS opens reliably across macOS versions
/// (independent of the auto-bound Settings scene which has quirks).
struct SettingsSheet: View {
  @Binding var isPresented: Bool
  @EnvironmentObject var state: AppState

  enum SettingsTab: String, CaseIterable {
    case general = "General"
    case naming = "Naming"
    case detection = "Import"
    case notifications = "Alerts"

    var icon: String {
      switch self {
      case .general: return "gearshape"
      case .naming: return "character.textbox"
      case .detection: return "camera.aperture"
      case .notifications: return "bell"
      }
    }
  }

  @State private var tab: SettingsTab = .general

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text("Preferences")
            .font(DDumpFont.ui(11, weight: .semibold))
            .textCase(.uppercase)
            .tracking(1.4)
            .foregroundColor(.ddumpFG3)
          Text("Settings")
            .font(DDumpFont.display(26, weight: .semibold))
            .foregroundColor(.ddumpFG1)
        }
        Spacer()
        Button("Done") { isPresented = false }
          .buttonStyle(DDumpPrimaryButtonStyle())
          .keyboardShortcut(.defaultAction)
      }
      .padding(.horizontal, 24)
      .padding(.top, 18)

      SettingsTabBar(selected: $tab)
      .padding(.horizontal, 24)
      .padding(.top, 14)
      .padding(.bottom, 12)

      SettingsView(tab: tab)
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }
    .frame(minWidth: 320, idealWidth: 560, maxWidth: 620, minHeight: 420, idealHeight: 640, maxHeight: 720)
    .background(Color.ddumpBG)
  }
}

struct ScanWindowInlineControl: View {
  @EnvironmentObject var state: AppState
  @State private var lookbackHours: String = "24"
  @State private var scanMode: String = "today"
  @State private var savedMessage: String = ""
  @FocusState private var hoursFocused: Bool

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 10) {
        label
        Spacer(minLength: 8)
        field
      }
      VStack(alignment: .leading, spacing: 8) {
        label
        field
      }
    }
    .padding(10)
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(Color.ddumpSurface)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(Color.ddumpLine1, lineWidth: 1)
    )
    .onAppear {
      scanMode = normalizedScanMode(state.get("CANDIDATE_MODE", default: "today"))
      lookbackHours = state.get("LOOKBACK_HOURS", default: "24")
    }
  }

  private var label: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text("Scan window")
        .font(DDumpFont.ui(12, weight: .semibold))
        .foregroundColor(.ddumpFG1)
      Text(scanMode == "today" ? "DDump imports files changed today." : "DDump imports files changed within this many hours.")
        .font(DDumpFont.ui(11))
        .foregroundColor(.ddumpFG3)
        .lineLimit(2)
    }
  }

  private var field: some View {
    HStack(spacing: 8) {
      Picker("", selection: $scanMode) {
        Text("Today").tag("today")
        Text("Hours").tag("lookback")
      }
      .labelsHidden()
      .pickerStyle(.segmented)
      .frame(width: 150)
      .ddumpOnChange(of: scanMode) { _ in save() }

      if scanMode == "lookback" {
        TextField("24", text: $lookbackHours)
          .frame(width: 62)
          .multilineTextAlignment(.trailing)
          .textFieldStyle(.roundedBorder)
          .focused($hoursFocused)
          .onSubmit(save)
        Text("hours")
          .font(DDumpFont.ui(12))
          .foregroundColor(.ddumpFG2)
      }
      Button("Save") { save() }
        .buttonStyle(DDumpSecondaryButtonStyle())
      if !savedMessage.isEmpty {
        Text(savedMessage)
          .font(DDumpFont.ui(11, weight: .medium))
          .foregroundColor(.ddumpSuccess)
      }
    }
  }

  private func save() {
    let cleaned = lookbackHours.trimmingCharacters(in: .whitespacesAndNewlines)
    let numeric = Int(cleaned).map { max(1, min($0, 720)) } ?? 24
    lookbackHours = "\(numeric)"
    scanMode = normalizedScanMode(scanMode)
    state.set("CANDIDATE_MODE", scanMode)
    state.set("LOOKBACK_HOURS", lookbackHours)
    hoursFocused = false
    savedMessage = "Saved"
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
      savedMessage = ""
    }
  }

  private func normalizedScanMode(_ value: String) -> String {
    let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return (cleaned == "lookback" || cleaned == "hours") ? "lookback" : "today"
  }
}

struct SettingsTabBar: View {
  @Binding var selected: SettingsSheet.SettingsTab

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 4) {
        tabButtons
      }
      LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 2), spacing: 4) {
        tabButtons
      }
    }
    .padding(4)
    .background(
      RoundedRectangle(cornerRadius: 9, style: .continuous)
        .fill(Color.ddumpBGAlt)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 9, style: .continuous)
        .stroke(Color.ddumpLine1, lineWidth: 1)
    )
  }

  @ViewBuilder
  private var tabButtons: some View {
    ForEach(SettingsSheet.SettingsTab.allCases, id: \.self) { t in
      DDumpTabChip(icon: t.icon, title: t.rawValue, active: selected == t) {
        selected = t
      }
      .frame(maxWidth: .infinity)
    }
  }
}

struct ControlBar: View {
  @EnvironmentObject var state: AppState

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 8) {
          controlButtons(fillWidth: false)
          Spacer(minLength: 0)
        }
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2), alignment: .leading, spacing: 8) {
          controlButtons(fillWidth: true)
        }
      }

      if state.ejectQueued {
        Label("Eject queued", systemImage: "eject.circle")
          .foregroundColor(.ddumpWarning)
          .font(DDumpFont.ui(12))
      } else if state.keepMountedRequested {
        Label("Will stay mounted", systemImage: "pin.slash.circle")
          .foregroundColor(.ddumpWarning)
          .font(DDumpFont.ui(12))
      } else if state.stopRequested {
        Label("Stop queued", systemImage: "stop.circle")
          .foregroundColor(.ddumpWarning)
          .font(DDumpFont.ui(12))
      }
    }
  }

  @ViewBuilder
  private func controlButtons(fillWidth: Bool) -> some View {
    if state.paused {
      Button {
        state.resume()
      } label: {
        Label("Resume", systemImage: "play.fill")
      }
      .buttonStyle(DDumpSecondaryButtonStyle())
      .keyboardShortcut("r", modifiers: .command)
      .frame(maxWidth: fillWidth ? .infinity : nil)
    } else {
      Button {
        state.pause()
      } label: {
        Label("Pause", systemImage: "pause.fill")
      }
      .buttonStyle(DDumpSecondaryButtonStyle())
      .keyboardShortcut("p", modifiers: .command)
      .disabled(!state.runActive)
      .frame(maxWidth: fillWidth ? .infinity : nil)
    }

    Button {
      state.stop()
    } label: {
      Label("Stop after file", systemImage: "stop.fill")
    }
    .buttonStyle(DDumpSecondaryButtonStyle())
    .keyboardShortcut(".", modifiers: .command)
    .disabled(!state.runActive || state.stopRequested)
    .frame(maxWidth: fillWidth ? .infinity : nil)

    Button {
      state.doNotEject()
    } label: {
      Label("Do not eject", systemImage: "pin.slash.fill")
    }
    .buttonStyle(DDumpSecondaryButtonStyle())
    .disabled(!state.runActive)
    .frame(maxWidth: fillWidth ? .infinity : nil)

    Button {
      state.ejectNow()
    } label: {
      Label("Eject after file", systemImage: "eject.fill")
    }
    .buttonStyle(DDumpPrimaryButtonStyle())
    .keyboardShortcut("e", modifiers: .command)
    .disabled(!state.runActive || state.ejectQueued)
    .frame(maxWidth: fillWidth ? .infinity : nil)
  }
}

struct MainActionFooter: View {
  @EnvironmentObject var state: AppState
  @Binding var showingSettings: Bool

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 8) {
        settingsButton
        Spacer(minLength: 10)
        actionButtons(fillWidth: false)
      }
      LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
        settingsButton.frame(maxWidth: .infinity)
        actionButtons(fillWidth: true)
      }
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 10)
    .background(Color.ddumpBG.opacity(0.98))
    .overlay(alignment: .top) { Rectangle().fill(Color.ddumpLine1).frame(height: 1) }
  }

  private var settingsButton: some View {
    Button {
      showingSettings = true
    } label: {
      Label("Settings", systemImage: "gearshape")
    }
    .buttonStyle(DDumpSecondaryButtonStyle())
    .keyboardShortcut(",", modifiers: .command)
  }

  @ViewBuilder
  private func actionButtons(fillWidth: Bool) -> some View {
    if !state.runActive {
      if state.viewOnlyMode {
        Button {
          state.setViewOnlyMode(false)
        } label: {
          Label("Resume auto-import", systemImage: "play.circle.fill")
        }
        .buttonStyle(DDumpSecondaryButtonStyle())
        .help("Allow DDump to automatically import newly connected camera cards again.")
        .frame(maxWidth: fillWidth ? .infinity : nil)
      } else {
        Menu {
          Button("Indefinite") { state.setViewOnlyMode(true) }
          Button("1 hour") { state.setViewOnlyMode(true, duration: 60 * 60) }
          Button("8 hours") { state.setViewOnlyMode(true, duration: 8 * 60 * 60) }
          Button("1 day") { state.setViewOnlyMode(true, duration: 24 * 60 * 60) }
          Divider()
          Button("Custom days…") { state.pauseAutoImportsForCustomDays() }
        } label: {
          Label("Pause imports", systemImage: "pause.circle.fill")
        }
        .menuStyle(.borderlessButton)
        .help("Pause automatic imports before connecting storage you only want to browse.")
        .frame(maxWidth: fillWidth ? .infinity : nil)
      }
    } else if state.paused {
      Button {
        state.resume()
      } label: {
        Label("Resume", systemImage: "play.fill")
      }
      .buttonStyle(DDumpSecondaryButtonStyle())
      .keyboardShortcut("r", modifiers: .command)
      .frame(maxWidth: fillWidth ? .infinity : nil)
    } else {
      Button {
        state.pause()
      } label: {
        Label("Pause", systemImage: "pause.fill")
      }
      .buttonStyle(DDumpSecondaryButtonStyle())
      .keyboardShortcut("p", modifiers: .command)
      .disabled(!state.runActive)
      .frame(maxWidth: fillWidth ? .infinity : nil)
    }

    Button {
      state.stop()
    } label: {
      Label("Stop", systemImage: "stop.fill")
    }
    .buttonStyle(DDumpSecondaryButtonStyle())
    .keyboardShortcut(".", modifiers: .command)
    .disabled(!state.runActive || state.stopRequested)
    .frame(maxWidth: fillWidth ? .infinity : nil)

    Button {
      state.startManualSelectionImport()
    } label: {
      Label("Select folder to import", systemImage: "folder.badge.plus")
    }
    .buttonStyle(DDumpSecondaryButtonStyle())
    .disabled(state.runActive)
    .frame(maxWidth: fillWidth ? .infinity : nil)

    Button {
      state.doNotEject()
    } label: {
      Label("Do not eject", systemImage: "pin.slash.fill")
    }
    .buttonStyle(DDumpSecondaryButtonStyle())
    .disabled(!state.runActive)
    .frame(maxWidth: fillWidth ? .infinity : nil)

    Button {
      state.ejectNow()
    } label: {
      if state.ejectQueued {
        Text("Eject queued")
      } else {
        Label("Eject", systemImage: "eject.fill")
      }
    }
    .buttonStyle(DDumpPrimaryButtonStyle())
    .keyboardShortcut("e", modifiers: .command)
    .disabled(!state.runActive)
    .frame(maxWidth: fillWidth ? .infinity : nil)
  }
}

struct IdleView: View {
  @EnvironmentObject var state: AppState

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Insert an SD card and DDump will")
        .font(DDumpFont.ui(11, weight: .semibold))
        .textCase(.uppercase)
        .tracking(1.4)
        .foregroundColor(.ddumpFG3)
      VStack(alignment: .leading, spacing: 6) {
        Label("Detect photo files automatically — no DCIM required", systemImage: "magnifyingglass")
        Label("Copy locally, verify size, optional SHA-256", systemImage: "checkmark.shield")
        Label("Group by capture-time clusters", systemImage: "square.3.layers.3d")
        Label("Copy to your Backup Folder when the dump is verified", systemImage: "folder.badge.plus")
        Label("Eject only when files are safe", systemImage: "eject")
      }
      .font(DDumpFont.ui(13))
      .foregroundColor(.ddumpFG2)
    }
  }
}

struct ViewOnlyPanel: View {
  @EnvironmentObject var state: AppState

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: "eye.fill")
        .font(.system(size: 18, weight: .semibold))
        .foregroundColor(.ddumpWarning)
        .frame(width: 24)
      VStack(alignment: .leading, spacing: 4) {
        Text("Imports paused \(state.viewOnlyDurationLabel)")
          .font(DDumpFont.ui(14, weight: .semibold))
          .foregroundColor(.ddumpFG1)
        Text("Plugged-in SSDs and SD cards will stay mounted. DDump will not scan, copy, upload, or eject them. Manual import still works when you choose it yourself.")
          .font(DDumpFont.ui(12))
          .foregroundColor(.ddumpFG2)
      }
      Spacer(minLength: 8)
      Button("Resume auto-import") {
        state.setViewOnlyMode(false)
      }
      .buttonStyle(DDumpSecondaryButtonStyle())
    }
    .padding(12)
    .background(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(Color.ddumpWarning.opacity(0.09))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .stroke(Color.ddumpWarning.opacity(0.45), lineWidth: 1)
    )
  }
}

struct SkippedVolumePanel: View {
  @EnvironmentObject var state: AppState

  var body: some View {
    if let notice = state.skippedVolumeNotice {
      VStack(alignment: .leading, spacing: 10) {
        HStack(alignment: .top, spacing: 10) {
          InfoHint(text: "This card was detected, but DDump did not import it automatically. The text here explains whether the card was untrusted, outside the scan window, or did not match camera-card safety checks.")
          VStack(alignment: .leading, spacing: 4) {
            Text("DDump saw \(notice.volume), but did not import it.")
              .font(DDumpFont.ui(13, weight: .semibold))
              .foregroundColor(.ddumpFG1)
            Text(notice.detail)
              .font(DDumpFont.ui(12))
              .foregroundColor(.ddumpFG2)
            Text(notice.hint)
              .font(DDumpFont.ui(12))
              .foregroundColor(.ddumpFG2)
          }
          Spacer(minLength: 8)
          Button {
            state.dismissSkippedVolumeNotice()
          } label: {
            Image(systemName: "xmark")
              .font(DDumpFont.ui(11, weight: .semibold))
          }
          .buttonStyle(.plain)
          .foregroundColor(.ddumpFG3)
          .help("Dismiss")
        }

        HStack(spacing: 8) {
          Button {
            state.startManualSelectionImport()
          } label: {
            Label("Select folder to import", systemImage: "folder.badge.plus")
          }
          .buttonStyle(DDumpPrimaryButtonStyle())
          .disabled(state.runActive)

          Button {
            openInFinder(DDumpPaths.logFile.path)
          } label: {
            Label("Open log", systemImage: "doc.text")
          }
          .buttonStyle(DDumpSecondaryButtonStyle())
        }
      }
      .padding(12)
      .background(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(Color.ddumpSurface)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .stroke(Color.ddumpWarning.opacity(0.45), lineWidth: 1)
      )
    }
  }
}

struct BackupFolderWarningPanel: View {
  @EnvironmentObject var state: AppState

  var body: some View {
    if let warning = state.backupRootWarningForUI {
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundColor(.ddumpWarning)
        VStack(alignment: .leading, spacing: 4) {
          Text("Backup Folder needs attention")
            .font(DDumpFont.ui(13, weight: .semibold))
            .foregroundColor(.ddumpFG1)
          Text(warning)
            .font(DDumpFont.ui(12))
            .foregroundColor(.ddumpFG2)
          Text("Files remain in the Dump Folder, but DDump will not call the backup complete until the Backup Folder works.")
            .font(DDumpFont.ui(12))
            .foregroundColor(.ddumpFG2)
        }
        Spacer(minLength: 8)
        Button {
          state.openUploadDestination(openTodayFolder: false)
        } label: {
          Label("Check folder", systemImage: "folder.badge.questionmark")
        }
        .buttonStyle(DDumpSecondaryButtonStyle())
      }
      .padding(12)
      .background(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(Color.ddumpSurface)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .stroke(Color.ddumpWarning.opacity(0.55), lineWidth: 1)
      )
    }
  }
}

struct DestinationSummaryPanel: View {
  @EnvironmentObject var state: AppState

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 12) {
        folderCard(
          title: "Dump Folder",
          subtitle: "First verified copy",
          path: state.shortDisplayPath(state.dumpRootForUI, keepLastComponents: 3),
          buttonTitle: "Open",
          systemImage: "tray.and.arrow.down",
          action: { openInFinder(state.dumpRootForUI) }
        )
        folderCard(
          title: "Backup Folder",
          subtitle: "After the dump is verified",
          path: state.shortDisplayPath(state.todaysUploadDestinationForUI, keepLastComponents: 4),
          buttonTitle: "Open",
          systemImage: "folder.badge.plus",
          action: { state.openUploadDestination() }
        )
      }
      VStack(spacing: 10) {
        folderCard(
          title: "Dump Folder",
          subtitle: "First verified copy",
          path: state.shortDisplayPath(state.dumpRootForUI, keepLastComponents: 3),
          buttonTitle: "Open",
          systemImage: "tray.and.arrow.down",
          action: { openInFinder(state.dumpRootForUI) }
        )
        folderCard(
          title: "Backup Folder",
          subtitle: "After the dump is verified",
          path: state.shortDisplayPath(state.todaysUploadDestinationForUI, keepLastComponents: 4),
          buttonTitle: "Open",
          systemImage: "folder.badge.plus",
          action: { state.openUploadDestination() }
        )
      }
    }
    .fixedSize(horizontal: false, vertical: true)
  }

  private func folderCard(
    title: String,
    subtitle: String,
    path: String,
    buttonTitle: String,
    systemImage: String,
    action: @escaping () -> Void
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 2) {
          Text(title)
            .font(DDumpFont.ui(11, weight: .semibold))
            .textCase(.uppercase)
            .tracking(1.2)
            .foregroundColor(.ddumpFG3)
          Text(subtitle)
            .font(DDumpFont.ui(11))
            .foregroundColor(.ddumpFG3)
        }
        Spacer()
        Button(buttonTitle, action: action)
          .buttonStyle(DDumpSecondaryButtonStyle())
      }
      Spacer(minLength: 0)
      HStack(spacing: 8) {
        Image(systemName: systemImage)
          .foregroundColor(.ddumpFG3)
        Text(path.isEmpty ? "Not set" : path)
          .font(.system(size: 12, weight: .regular, design: .monospaced))
          .foregroundColor(.ddumpFG1)
          .lineLimit(1)
          .truncationMode(.middle)
          .textSelection(.enabled)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      Spacer(minLength: 0)
    }
    .padding(14)
    .frame(maxWidth: .infinity, minHeight: 118, maxHeight: 118, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(Color.ddumpSurface)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .stroke(Color.ddumpLine1, lineWidth: 1)
    )
  }
}

struct HealthPanel: View {
  @EnvironmentObject var state: AppState

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if state.cloudActionInProgress {
        HStack(spacing: 10) {
          ProgressView()
            .controlSize(.small)
            .tint(.ddumpPeach)
          Text(state.cloudActionMessage.isEmpty ? "Working…" : state.cloudActionMessage)
            .font(DDumpFont.ui(12, weight: .medium))
            .foregroundColor(.ddumpFG2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.ddumpSurface2)
        )
        .overlay(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .stroke(Color.ddumpLine1, lineWidth: 1)
        )
      }

      LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], alignment: .leading, spacing: 8) {
        Label("\(state.localFreeGB)GB free locally", systemImage: "internaldrive")
        Label("\(state.pendingUploadCount) pending upload\(state.pendingUploadCount == 1 ? "" : "s")", systemImage: "arrow.triangle.2.circlepath")
        Label("\(state.stagingFolderCount) dump folder\(state.stagingFolderCount == 1 ? "" : "s")", systemImage: "tray.full")
      }
      .font(DDumpFont.ui(12))
      .foregroundColor(.ddumpFG2)
      .padding(.vertical, 10)
      .overlay(alignment: .top) { Rectangle().fill(Color.ddumpLine1).frame(height: 1) }
      .overlay(alignment: .bottom) { Rectangle().fill(Color.ddumpLine1).frame(height: 1) }

      LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 8)], alignment: .leading, spacing: 8) {
        Button {
          state.retryPendingUploads()
        } label: {
          Label("Retry Pending Uploads", systemImage: "arrow.clockwise")
        }
        .buttonStyle(DDumpSecondaryButtonStyle())
        .disabled(state.pendingUploadCount == 0 || state.runActive)
      }
      .font(DDumpFont.ui(12))

      if !state.lastUtilityMessage.isEmpty {
        Text(state.lastUtilityMessage)
          .font(DDumpFont.ui(12))
          .foregroundColor(.ddumpFG3)
      }
    }
  }
}

struct ProgressDetail: View {
  @EnvironmentObject var state: AppState

  private var friendlyMessage: String {
    humanReadableStatus(state.message)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(state.volume.isEmpty ? "Card" : state.volume)
        .font(DDumpFont.ui(18, weight: .semibold))
        .foregroundColor(.ddumpFG1)
      Text(friendlyMessage)
        .font(DDumpFont.ui(12))
        .foregroundColor(.ddumpFG2)
        .lineLimit(2)

      ProgressView(value: state.displayProgressFraction)
        .progressViewStyle(.linear)
        .tint(.ddumpPeach)

      HStack {
        Text(state.displayProgressCount)
        Spacer()
        Text("ETA \(state.displayETA)")
        Spacer()
        Text("\(state.displayPercent)%").bold()
      }
      .font(.system(size: 13, weight: .medium, design: .monospaced))
      .monospacedDigit()
      .foregroundColor(.ddumpFG2)

      HStack(spacing: 24) {
        Label("\(state.imported) imported", systemImage: "checkmark.circle")
          .foregroundColor(.ddumpSuccess)
        Label("\(state.skipped) skipped", systemImage: "arrow.right.circle")
          .foregroundColor(.ddumpFG3)
        if state.isUploading {
          Label(state.cardEjected ? "card ejected" : "eject \(state.ejectStatus)", systemImage: state.cardEjected ? "eject.circle.fill" : "eject.circle")
            .foregroundColor(state.cardEjected ? .ddumpSuccess : .ddumpWarning)
          if !state.uploadSpeed.isEmpty {
            Label(state.uploadSpeed, systemImage: "speedometer")
              .foregroundColor(.ddumpFG2)
          }
        }
        if state.failed > 0 {
          Label("\(state.failed) failed", systemImage: "exclamationmark.triangle")
            .foregroundColor(.ddumpDanger)
        }
      }
      .font(DDumpFont.ui(12))

      if state.isUploading {
        VStack(alignment: .leading, spacing: 6) {
          if !state.uploadItem.isEmpty {
            Label("Now uploading \(state.uploadItem)", systemImage: "icloud.and.arrow.up")
              .foregroundColor(.ddumpFG2)
          }
          if !state.uploadTarget.isEmpty {
            Label(state.uploadTarget, systemImage: "folder")
              .foregroundColor(.ddumpFG3)
              .lineLimit(2)
              .textSelection(.enabled)
          }
          if !state.uploadLastError.isEmpty {
            Label(state.uploadLastError, systemImage: "wifi.exclamationmark")
              .foregroundColor(.ddumpWarning)
              .lineLimit(3)
              .textSelection(.enabled)
          }
        }
        .font(DDumpFont.ui(12))
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.ddumpSurface2)
        )
        .overlay(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .stroke(Color.ddumpLine1, lineWidth: 1)
        )
      }

      if state.runActive {
        ManualShootNameControl()
      }
    }
  }

  private func humanReadableStatus(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "Waiting for a card." }

    if trimmed.hasPrefix("Run complete.") {
      let metrics = parseSummaryMetrics(trimmed)
      let volumes = metrics["volumes"] ?? 0
      let imported = metrics["imported"] ?? 0
      let duplicates = metrics["skipped_duplicate"] ?? 0
      let skippedExt = metrics["skipped_extension"] ?? 0
      let copyFail = metrics["copy_fail"] ?? 0
      let verifyFail = metrics["verify_fail"] ?? 0
      let uploadIncomplete = metrics["upload_incomplete"] ?? 0
      let errors = metrics["errors"] ?? 0
      let cardWord = volumes == 1 ? "card" : "cards"
      if errors > 0 || copyFail > 0 || verifyFail > 0 || uploadIncomplete > 0 {
        return "Finished with attention needed. \(volumes) \(cardWord) checked, \(imported) imported, \(copyFail + verifyFail) copy or verify issues, \(uploadIncomplete) backup issues."
      }
      if imported > 0 {
        return "Finished. \(volumes) \(cardWord) checked, \(imported) imported, \(duplicates) already copied, \(skippedExt) non-media skipped."
      }
      if duplicates > 0 {
        return "Finished. \(volumes) \(cardWord) checked. \(duplicates) files were already marked copied, so DDump did not copy them again."
      }
      return "Finished. \(volumes) \(cardWord) checked. No files matched the scan window."
    }

    return trimmed
      .replacingOccurrences(of: "_", with: " ")
      .replacingOccurrences(of: "  ", with: " ")
  }

  private func parseSummaryMetrics(_ text: String) -> [String: Int] {
    var metrics: [String: Int] = [:]
    let pattern = #"([a-z_]+)=([0-9]+)"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return metrics }
    let nsText = text as NSString
    let range = NSRange(location: 0, length: nsText.length)
    regex.enumerateMatches(in: text, range: range) { match, _, _ in
      guard let match, match.numberOfRanges == 3 else { return }
      let key = nsText.substring(with: match.range(at: 1))
      let value = Int(nsText.substring(with: match.range(at: 2))) ?? 0
      metrics[key] = value
    }
    return metrics
  }
}

struct ManualShootNameControl: View {
  @State private var shootName: String = ""
  @State private var savedMessage: String = ""

  private func load() {
    shootName = (try? String(contentsOf: DDumpPaths.manualShootNameFile, encoding: .utf8))?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  }

  private func save() {
    do {
      try FileManager.default.createDirectory(at: DDumpPaths.controlDir, withIntermediateDirectories: true)
      let cleaned = shootName.trimmingCharacters(in: .whitespacesAndNewlines)
      if cleaned.isEmpty {
        try? FileManager.default.removeItem(at: DDumpPaths.manualShootNameFile)
        savedMessage = "Auto naming"
      } else {
        try "\(cleaned)\n".write(to: DDumpPaths.manualShootNameFile, atomically: true, encoding: .utf8)
        savedMessage = "Will use \"\(cleaned)\""
      }
    } catch {
      savedMessage = "Could not save name"
    }
  }

  var body: some View {
    HStack(spacing: 10) {
      Label("Shoot name", systemImage: "textformat")
        .font(DDumpFont.ui(12, weight: .medium))
        .foregroundColor(.ddumpFG2)
      TextField("Optional, e.g. Wedding 123", text: $shootName)
        .textFieldStyle(.roundedBorder)
        .onSubmit { save() }
      Button {
        save()
      } label: {
        Label("Use name", systemImage: "checkmark.circle")
      }
      .buttonStyle(DDumpSecondaryButtonStyle())
      if !savedMessage.isEmpty {
        Text(savedMessage)
          .font(DDumpFont.ui(11))
          .foregroundColor(.ddumpFG3)
      }
    }
    .onAppear { load() }
  }
}

struct RunChecklistPanel: View {
  @EnvironmentObject var state: AppState

  enum StepState {
    case pending
    case active
    case done
    case blocked
  }

  private var runFinished: Bool {
    state.phase == "complete" || state.phase == "stopped"
  }

  private var postMoveEnabled: Bool {
    state.get("CLOUD_UPLOADS_ENABLED", default: "0") == "1"
      || state.get("ENABLE_POST_EJECT_MOVE", default: "1") == "1"
  }

  private var ejectEnabled: Bool {
    state.get("EJECT_ON_SUCCESS", default: "1") == "1"
  }

  private func summaryMetric(_ key: String) -> Int? {
    let pattern = "\(key)=([0-9]+)"
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let full = state.message as NSString
    let range = NSRange(location: 0, length: full.length)
    guard let match = regex.firstMatch(in: state.message, range: range), match.numberOfRanges > 1 else {
      return nil
    }
    let metric = full.substring(with: match.range(at: 1))
    return Int(metric)
  }

  private var step1State: StepState {
    if state.isUploading {
      return .done
    }
    if state.runActive && ["starting", "scanning", "importing", "paused"].contains(state.phase) {
      return .active
    }
    if runFinished && (state.imported > 0 || state.skipped > 0 || state.total > 0) {
      return .done
    }
    if runFinished && (summaryMetric("errors") ?? 0) > 0 && state.imported == 0 {
      return .blocked
    }
    return .pending
  }

  private var step2State: StepState {
    if !ejectEnabled {
      return .done
    }
    if state.cardEjected || state.isUploading {
      return .done
    }
    if state.ejectStatus == "failed" || state.ejectStatus == "kept" {
      return .blocked
    }
    if step1State != .done {
      return .pending
    }
    if runFinished {
      if (summaryMetric("kept_mounted") ?? 0) > 0 {
        return .blocked
      }
      return .done
    }
    if state.runActive && state.imported > 0 {
      return .active
    }
    return .pending
  }

  private var step3State: StepState {
    if !postMoveEnabled {
      return .done
    }
    if state.isUploading { return .active }
    if runFinished {
      let moveFail = summaryMetric("post_move_fail") ?? 0
      let moveBlocked = summaryMetric("post_move_blocked") ?? 0
      if moveFail == 0 && moveBlocked == 0 && state.pendingUploadCount == 0 {
        return .done
      }
      return .blocked
    }
    if step2State != .done { return .pending }
    return .pending
  }

  private var step4State: StepState {
    guard runFinished else { return .pending }
    if step1State == .done && step2State == .done && step3State == .done && (summaryMetric("errors") ?? 0) == 0 {
      return .done
    }
    return .blocked
  }

  private func icon(for step: StepState) -> String {
    switch step {
    case .pending: return "circle"
    case .active: return "clock.arrow.circlepath"
    case .done: return "checkmark.circle.fill"
    case .blocked: return "exclamationmark.circle.fill"
    }
  }

  private func color(for step: StepState) -> Color {
    switch step {
    case .pending: return .ddumpFG3
    case .active: return .ddumpPeach
    case .done: return .ddumpSuccess
    case .blocked: return .ddumpWarning
    }
  }

  private func row(_ title: String, step: StepState, linkTitle: String? = nil, linkPath: String? = nil, cloudDestination: Bool = false) -> some View {
    HStack(spacing: 10) {
      Image(systemName: icon(for: step))
        .foregroundColor(color(for: step))
      Text(title)
        .foregroundColor(step == .done ? .ddumpSuccess : .ddumpFG1)
      Spacer()
      if let linkTitle, let linkPath, !linkPath.isEmpty {
        Button(linkTitle) {
          if cloudDestination {
            state.openUploadDestination()
          } else {
            openInFinder(linkPath)
          }
        }
        .buttonStyle(.link)
        .foregroundColor(.ddumpPeach)
      }
    }
    .font(DDumpFont.ui(13))
    .padding(.vertical, 4)
    .padding(.horizontal, 12)
    .background(step == .active ? Color.ddumpPeachSoft : Color.clear)
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(step == .active ? Color.ddumpPeach.opacity(0.22) : Color.clear, lineWidth: 1)
    )
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("Checklist").font(DDumpFont.ui(18, weight: .semibold)).foregroundColor(.ddumpFG1)
        Spacer()
        if state.runActive {
          Text("\(state.displayProgressCount) · \(state.displayETA) remaining")
            .font(.system(size: 12, weight: .regular, design: .monospaced))
            .foregroundColor(.ddumpFG3)
        }
      }
      row("1. Copy to Dump Folder", step: step1State, linkTitle: "Open Dump Folder", linkPath: state.get("DEST_ROOT", default: "\(NSHomeDirectory())/Temp"))
      row("2. Eject card", step: step2State)
      row("3. Copy to Backup Folder", step: step3State, linkTitle: "Open Backup Folder", linkPath: state.uploadRootForUI, cloudDestination: true)
      row("4. All complete!", step: step4State)
    }
    .padding(14)
    .background(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(Color.ddumpSurface)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .stroke(Color.ddumpLine1, lineWidth: 1)
    )
  }
}

// MARK: - Settings

struct SettingsView: View {
  let tab: SettingsSheet.SettingsTab

  var body: some View {
    Group {
      switch tab {
      case .general:
        GeneralSettings()
      case .naming:
        NamingSettings()
      case .detection:
        DetectionSettings()
      case .notifications:
        NotificationsSettings()
      }
    }
    .background(Color.ddumpBG)
  }
}

enum TroubleshootTopic: String, CaseIterable, Identifiable {
  case calendar = "Calendar naming"
  case cardImport = "Card did not import"
  case backup = "Backup copy missing"
  case dumpFolder = "Dump Folder missing"
  case notifications = "Alerts not working"
  case syncFolder = "Google Drive / sync folder"

  var id: String { rawValue }

  var icon: String {
    switch self {
    case .calendar: return "calendar"
    case .cardImport: return "sdcard"
    case .backup: return "externaldrive.badge.icloud"
    case .dumpFolder: return "tray.full"
    case .notifications: return "bell"
    case .syncFolder: return "arrow.triangle.2.circlepath"
    }
  }
}

struct GeneralSettings: View {
  @EnvironmentObject var state: AppState
  @State private var localStaging: String = ""
  @State private var dumpFallbackRoot: String = ""
  @State private var enablePostMove: Bool = true
  @State private var uploadRoot: String = ""
  @State private var uploadRoots: String = ""
  @State private var fallbackRoot: String = ""
  @State private var destinationMode: String = "fixed"
  @State private var updateChecksEnabled: Bool = false
  @State private var autoUpdatesEnabled: Bool = false
  @State private var updateCheckFrequency: String = "weekly"
  @State private var windowRestoreMode: String = "remember"
  @State private var autoLaunchSyncApps: Bool = true
  @State private var showTroubleshooting: Bool = false
  @State private var selectedTroubleTopic: TroubleshootTopic?
  @State private var troubleshootTitle: String = ""
  @State private var troubleshootLines: [String] = []

  var body: some View {
    Form {
      Section {
        TextField("Dump Folder", text: $localStaging, onCommit: {
          state.set("DEST_ROOT", localStaging)
        })
        Text("This is the first verified copy from the card. Recommended: a fast folder on this Mac or a directly connected SSD, with enough free space for the full shoot.")
          .font(.caption)
          .foregroundColor(.secondary)
        TextField("Dump Folder fallback", text: $dumpFallbackRoot, onCommit: {
          state.set("DUMP_FALLBACK_ROOT", dumpFallbackRoot)
        })
        Text("If the SSD or NAS you chose as the Dump Folder is not connected, DDump uses this local fallback instead of stopping silently.")
          .font(.caption)
          .foregroundColor(.secondary)

        HStack {
          Button("Choose Dump Folder…") {
            if let picked = pickFolder(prompt: "Choose Dump Folder") {
              localStaging = picked
              state.set("DEST_ROOT", picked)
            }
          }
          Button("Choose fallback…") {
            if let picked = pickFolder(prompt: "Choose Dump Folder fallback") {
              dumpFallbackRoot = picked
              state.set("DUMP_FALLBACK_ROOT", picked)
            }
          }
        }
      } header: {
        Text("Dump Folder")
      } footer: {
        Text("DDump never treats the card as safe until this first copy is written and verified.")
          .font(.caption).foregroundColor(.secondary)
      }

      Section {
        Toggle("Copy finished folders to a Backup Folder", isOn: $enablePostMove)
          .ddumpOnChange(of: enablePostMove) { v in
            state.set("ENABLE_POST_EJECT_MOVE", v ? "1" : "0")
          }
        Picker("Backup folder mode", selection: $destinationMode) {
          Text("One Fixed Folder").tag("fixed")
          Text("Smart Year/Month/Day").tag("smart")
        }
        .pickerStyle(.segmented)
        .ddumpOnChange(of: destinationMode) { v in
          state.set("POST_MOVE_DATE_MODE", v == "smart" ? "smart" : "fixed")
        }
        if destinationMode == "smart" {
          Text("DDump keeps the Backup Folder you chose, then creates today's YYYY / YYYY.MM / YYYY.MM.DD folders inside it.")
            .font(.caption)
            .foregroundColor(.secondary)
        }
        TextField("Backup Folder", text: $uploadRoot, onCommit: {
          state.set("POST_MOVE_ROOT", uploadRoot)
        })
        if let warning = dateLadderRootWarning(uploadRoot) {
          Label(warning, systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundColor(.ddumpWarning)
        }
        Text("This is the second copy after the Dump Folder is verified. It can be Google Drive Desktop, Dropbox, Box, OneDrive, iCloud Drive, pCloud, a NAS, another internal folder, or another SSD.")
          .font(.caption)
          .foregroundColor(.secondary)
        Toggle("Open sync apps when needed", isOn: $autoLaunchSyncApps)
          .ddumpOnChange(of: autoLaunchSyncApps) { v in
            state.set("AUTO_LAUNCH_SYNC_APPS", v ? "1" : "0")
          }
        Text("If the Backup Folder lives in Google Drive, Dropbox, Box, OneDrive, or pCloud and the folder is missing, DDump can open that app and wait briefly before using a fallback or warning you.")
          .font(.caption)
          .foregroundColor(.secondary)
        TextField("Extra Backup Folders (comma-separated)", text: $uploadRoots, onCommit: {
          state.set("POST_MOVE_ROOTS", uploadRoots)
        })
        TextField("Backup Folder fallback", text: $fallbackRoot, onCommit: {
          state.set("POST_MOVE_FALLBACK_ROOT", fallbackRoot)
        })
        HStack {
          Button("Choose Backup Folder…") {
            if let picked = pickFolder(prompt: "Choose Backup Folder") {
              uploadRoot = picked
              state.set("POST_MOVE_ROOT", picked)
            }
          }
          Button("Choose fallback…") {
            if let picked = pickFolder(prompt: "Choose Backup Folder fallback") {
              fallbackRoot = picked
              state.set("POST_MOVE_FALLBACK_ROOT", picked)
            }
          }
        }
      } header: {
        Text("Backup Folder")
      } footer: {
        Text("Files go: card to Dump Folder first. After that verification passes, DDump copies organized folders to the Backup Folder and any extra backup folders you choose.")
          .font(.caption).foregroundColor(.secondary)
      }

      Section("Launch") {
        HStack {
          Text("Window size")
          Spacer()
          Picker("", selection: $windowRestoreMode) {
            Text("Remember Last Size").tag("remember")
            Text("Compact").tag("compact")
            Text("Large").tag("large")
          }
          .labelsHidden()
          .frame(width: 190)
          .ddumpOnChange(of: windowRestoreMode) { v in
            state.set("WINDOW_RESTORE_MODE", v)
          }
        }

        Button {
          state.requestOnboardingRestart()
        } label: {
          Label("Restart setup wizard", systemImage: "sparkles")
        }
        .buttonStyle(DDumpPrimaryButtonStyle())

        Text("Use Restart setup wizard any time you want to walk through staging, destination, auto-eject, scan window, and notification choices again. Each wizard page can be skipped.")
          .font(.caption)
          .foregroundColor(.secondary)
      }

      Section("Google Drive helper") {
        Text("Optional. Use this only if your Backup Folder is inside Google Drive and you want DDump to help connect or test that folder.")
          .font(.caption)
          .foregroundColor(.secondary)
        ViewThatFits(in: .horizontal) {
          HStack(spacing: 8) {
            cloudHelperButtons
          }
          LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2), spacing: 8) {
            cloudHelperButtons
          }
        }
        if !state.lastUtilityMessage.isEmpty {
          Text(state.lastUtilityMessage)
            .font(.caption)
            .foregroundColor(.secondary)
        }
      }

      Section("Manual tools") {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
          troubleshootButton
          openDumpFolderButton
          openBackupFolderButton
          openLogButton
          sendBugReportButton
            .gridCellColumns(2)
        }
        .padding(.top, 8)
        Text("Use these when a card did not import, a folder does not open, or you need to send a useful bug report.")
          .font(.caption)
          .foregroundColor(.secondary)

        if showTroubleshooting {
          troubleshootPanel
        }

        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
          Button {
            state.startManualSelectionImport()
          } label: {
            settingsButtonLabel("Manual select…", systemImage: "slider.horizontal.3")
          }
          .buttonStyle(DDumpSecondaryButtonStyle())
          .disabled(state.runActive)
          .frame(maxWidth: .infinity)

          Button {
            state.cleanupOldStagingFolders()
          } label: {
            settingsButtonLabel("Safe cleanup", systemImage: "trash")
          }
          .buttonStyle(DDumpSecondaryButtonStyle())
          .disabled(state.runActive)
          .frame(maxWidth: .infinity)

          Button {
            openInFinder(DDumpPaths.reportsDir.path)
          } label: {
            settingsButtonLabel("Receipts", systemImage: "doc.plaintext")
          }
          .buttonStyle(DDumpSecondaryButtonStyle())
          .frame(maxWidth: .infinity)
        }
        Text("These are kept out of the main screen because most users only need them occasionally.")
          .font(.caption)
          .foregroundColor(.secondary)
      }

      Section("Check updates") {
        HStack(spacing: 10) {
          Button {
            state.checkForUpdatesNow()
          } label: {
            Label("Update now", systemImage: "arrow.clockwise")
          }
          .buttonStyle(DDumpPrimaryButtonStyle())

          Spacer(minLength: 8)

          Text("Version \(appVersion)")
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .foregroundColor(.secondary)
            .lineLimit(1)
            .textSelection(.enabled)
        }

        Toggle("Check for updates", isOn: $updateChecksEnabled)
          .ddumpOnChange(of: updateChecksEnabled) { v in
            state.set("UPDATE_CHECKS_ENABLED", v ? "1" : "0")
          }

        Toggle("Open download page automatically", isOn: $autoUpdatesEnabled)
          .ddumpOnChange(of: autoUpdatesEnabled) { v in
            state.set("AUTO_UPDATES_ENABLED", v ? "1" : "0")
          }
          .disabled(!updateChecksEnabled)

        HStack {
          Text("Check frequency")
          Spacer()
          Picker("", selection: $updateCheckFrequency) {
            Text("Upon Start").tag("startup")
            Text("Weekly").tag("weekly")
            Text("Monthly").tag("monthly")
          }
          .labelsHidden()
          .frame(width: 180)
          .ddumpOnChange(of: updateCheckFrequency) { v in
            state.set("UPDATE_CHECK_FREQUENCY", v)
          }
        }
        .disabled(!updateChecksEnabled)

        Text("Update now checks GitHub Releases immediately. Automatic update checks are off by default; signed in-app updates can be added later.")
          .font(.caption)
          .foregroundColor(.secondary)
      }

      Section("Theme") {
        Picker("Appearance", selection: Binding(
          get: { state.get("APP_COLOR_SCHEME", default: "system") },
          set: { state.set("APP_COLOR_SCHEME", $0) }
        )) {
          Label("System", systemImage: "circle.lefthalf.filled").tag("system")
          Label("Light", systemImage: "sun.max.fill").tag("light")
          Label("Dark", systemImage: "moon.fill").tag("dark")
        }
      }
    }
    .formStyle(.grouped)
    .ddumpFormSkin()
    .onAppear {
      localStaging = state.get("DEST_ROOT", default: "\(NSHomeDirectory())/Temp")
      dumpFallbackRoot = state.get("DUMP_FALLBACK_ROOT", default: "\(NSHomeDirectory())/Temp/DDump")
      enablePostMove = state.get("ENABLE_POST_EJECT_MOVE", default: "1") == "1"
      uploadRoot = state.get("POST_MOVE_ROOT")
      uploadRoots = state.get("POST_MOVE_ROOTS")
      fallbackRoot = state.get("POST_MOVE_FALLBACK_ROOT")
      destinationMode = state.get("POST_MOVE_DATE_MODE", default: "smart") == "fixed" ? "fixed" : "smart"
      updateChecksEnabled = state.get("UPDATE_CHECKS_ENABLED", default: "0") == "1"
      autoUpdatesEnabled = state.get("AUTO_UPDATES_ENABLED", default: "0") == "1"
      updateCheckFrequency = state.get("UPDATE_CHECK_FREQUENCY", default: "weekly")
      windowRestoreMode = state.get("WINDOW_RESTORE_MODE", default: "remember")
      autoLaunchSyncApps = state.get("AUTO_LAUNCH_SYNC_APPS", default: "1") == "1"
    }
  }

  @ViewBuilder
  private var troubleshootButton: some View {
    Button {
      showTroubleshooting.toggle()
      if showTroubleshooting && selectedTroubleTopic == nil {
        runTroubleshoot(.cardImport)
      }
    } label: {
      settingsButtonLabel("Troubleshoot", systemImage: "wrench.and.screwdriver")
    }
    .frame(maxWidth: .infinity)
    .buttonStyle(DDumpPrimaryButtonStyle())
  }

  @ViewBuilder
  private var openDumpFolderButton: some View {
    Button {
      openInFinder(state.dumpRootForUI)
    } label: {
      settingsButtonLabel("Open Dump Folder", systemImage: "tray.full")
    }
    .frame(maxWidth: .infinity)
    .buttonStyle(DDumpSecondaryButtonStyle())
  }

  @ViewBuilder
  private var openBackupFolderButton: some View {
    Button {
      state.openUploadDestination()
    } label: {
      settingsButtonLabel("Open Backup Folder", systemImage: "folder")
    }
    .frame(maxWidth: .infinity)
    .buttonStyle(DDumpSecondaryButtonStyle())
  }

  @ViewBuilder
  private var openLogButton: some View {
    Button {
      openInFinder(DDumpPaths.logFile.path)
    } label: {
      settingsButtonLabel("Open Log", systemImage: "doc.text")
    }
    .frame(maxWidth: .infinity)
    .buttonStyle(DDumpSecondaryButtonStyle())
  }

  @ViewBuilder
  private var sendBugReportButton: some View {
    Button {
      state.openBugReportEmail()
    } label: {
      settingsButtonLabel("Send Bug Report", systemImage: "envelope")
    }
    .frame(maxWidth: .infinity)
    .buttonStyle(DDumpSecondaryButtonStyle())
  }

  private func settingsButtonLabel(_ title: String, systemImage: String) -> some View {
    Label(title, systemImage: systemImage)
      .frame(maxWidth: .infinity, alignment: .center)
      .frame(minHeight: 24)
  }

  private var troubleshootPanel: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("What needs help?")
        .font(DDumpFont.ui(12, weight: .semibold))
        .foregroundColor(.ddumpFG1)

      LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
        ForEach(TroubleshootTopic.allCases) { topic in
          if topic == selectedTroubleTopic {
            Button {
              runTroubleshoot(topic)
            } label: {
              Label(topic.rawValue, systemImage: topic.icon)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .frame(maxWidth: .infinity)
            .buttonStyle(DDumpPrimaryButtonStyle())
          } else {
            Button {
              runTroubleshoot(topic)
            } label: {
              Label(topic.rawValue, systemImage: topic.icon)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .frame(maxWidth: .infinity)
            .buttonStyle(DDumpSecondaryButtonStyle())
          }
        }
      }

      if !troubleshootTitle.isEmpty {
        VStack(alignment: .leading, spacing: 8) {
          Text(troubleshootTitle)
            .font(DDumpFont.ui(12, weight: .semibold))
            .foregroundColor(.ddumpFG1)
          ForEach(troubleshootLines.indices, id: \.self) { idx in
            Text(troubleshootLines[idx])
              .font(DDumpFont.ui(11))
              .foregroundColor(idx == 0 ? .ddumpFG2 : .ddumpFG3)
              .fixedSize(horizontal: false, vertical: true)
          }

          ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
              troubleshootActions
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
              troubleshootActions
            }
          }
        }
        .padding(10)
        .background(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.ddumpSurface2)
        )
        .overlay(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .stroke(Color.ddumpLine1, lineWidth: 1)
        )
      }
    }
    .padding(10)
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(Color.ddumpSurface)
    )
  }

  @ViewBuilder
  private var troubleshootActions: some View {
    Button {
      state.refreshAppleCalendarCache(showDialog: false)
      runTroubleshoot(selectedTroubleTopic ?? .calendar)
    } label: {
      settingsButtonLabel("Recheck", systemImage: "arrow.clockwise")
    }
    .frame(maxWidth: .infinity)
    .buttonStyle(DDumpSecondaryButtonStyle())

    Button {
      state.openNetworkVolumePrivacySettings()
    } label: {
      settingsButtonLabel("Privacy Settings", systemImage: "lock.shield")
    }
    .frame(maxWidth: .infinity)
    .buttonStyle(DDumpSecondaryButtonStyle())

    Button {
      openInFinder(DDumpPaths.logFile.path)
    } label: {
      settingsButtonLabel("Open Log", systemImage: "doc.text")
    }
    .frame(maxWidth: .infinity)
    .buttonStyle(DDumpSecondaryButtonStyle())
  }

  private func runTroubleshoot(_ topic: TroubleshootTopic) {
    selectedTroubleTopic = topic
    state.refreshHealth()
    state.refreshSkippedVolumeNotice()

    let fm = FileManager.default
    let dump = state.dumpRootForUI
    let dumpExists = fm.fileExists(atPath: expandConfiguredPath(dump))
    let backup = state.todaysUploadDestinationForUI
    let backupRoot = state.backupRootForUI
    let backupRootExists = fm.fileExists(atPath: expandConfiguredPath(backupRoot))
    let backupTodayExists = fm.fileExists(atPath: expandConfiguredPath(backup))
    let calendarProvider = state.get("CALENDAR_PROVIDER", default: "apple")
    let calendarStatus = state.get("CALENDAR_AUTH_STATUS", default: "not checked")
    let calendarCacheReady = fm.fileExists(atPath: DDumpPaths.appleCalendarCache.path)
    let ntfyTopic = state.get("NTFY_TOPIC").trimmingCharacters(in: .whitespacesAndNewlines)
    let noticesOn = state.get("USE_NOTIFICATIONS", default: "1") == "1"
    let driveRunning = NSWorkspace.shared.runningApplications.contains {
      ($0.bundleIdentifier ?? "").contains("drivefs") ||
      ($0.localizedName ?? "").localizedCaseInsensitiveContains("Google Drive")
    }
    let lastNotice = state.skippedVolumeNotice.map { "\($0.volume): \($0.detail)" } ?? "No recent skipped-card notice."

    switch topic {
    case .calendar:
      troubleshootTitle = "Calendar naming"
      troubleshootLines = [
        calendarProvider == "apple"
          ? "DDump is set to use the Mac Calendar app. That is the best public default because it works with Apple, Google, Exchange, and subscribed calendars after they sync to macOS."
          : "DDump is set to use \(calendarProvider).",
        "Permission: \(calendarStatus). Local event cache: \(calendarCacheReady ? "ready" : "missing").",
        calendarCacheReady
          ? "If a folder still says Shoot-1 or Cluster, check Naming settings: calendar naming must be selected, the shoot must be on your Mac Calendar, and the capture time must fall inside the event or the attach window."
          : "Fix: open Privacy Settings, allow DDump calendar access if macOS asks, make sure the event appears in the Mac Calendar app, then click Recheck."
      ]
    case .cardImport:
      troubleshootTitle = "Card did not import"
      troubleshootLines = [
        "Last card notice: \(lastNotice)",
        "Fix: leave the card inserted, increase the scan window on the main screen, then click Retry Pending Uploads.",
        "If the card is real camera media but detection missed it, use Manual select and choose the card volume itself, not the deepest DCIM folder."
      ]
    case .backup:
      troubleshootTitle = "Backup copy missing"
      troubleshootLines = [
        "Backup root: \(backupRootExists ? "available" : "missing") — \(state.shortDisplayPath(backupRoot, keepLastComponents: 5)).",
        "Today's backup folder: \(backupTodayExists ? "available" : "missing") — \(state.shortDisplayPath(backup, keepLastComponents: 5)).",
        backupRootExists
          ? "Fix: click Retry Pending Uploads. DDump will re-copy existing Dump Folder sessions into the Backup Folder without deleting the Dump Folder copy."
          : "Fix: open the sync app or connect the SSD/NAS, then click Recheck. If this is Google Drive Desktop, confirm the Google Drive app is running and the folder appears in Finder."
      ]
    case .dumpFolder:
      troubleshootTitle = "Dump Folder"
      troubleshootLines = [
        "Dump Folder: \(dumpExists ? "available" : "missing") — \(state.displayPath(dump)).",
        dumpExists
          ? "This first verified copy location is reachable. If importing still fails, check free disk space and card detection."
          : "Fix: connect the SSD/NAS you use for the Dump Folder or choose a local fallback folder. DDump should never keep going silently when this location is missing."
      ]
    case .notifications:
      troubleshootTitle = "Alerts"
      troubleshootLines = [
        "Mac alerts: \(noticesOn ? "enabled" : "off"). ntfy topic: \(ntfyTopic.isEmpty ? "not set" : ntfyTopic).",
        ntfyTopic.isEmpty
          ? "Fix: open Alerts settings, install the ntfy app on your phone, create or choose a topic, then paste that topic into DDump."
          : "If phone alerts are missing, confirm the ntfy app is installed and subscribed to this exact topic. Use Open Log if the issue continues."
      ]
    case .syncFolder:
      troubleshootTitle = "Google Drive / sync folder"
      troubleshootLines = [
        "Google Drive app: \(driveRunning ? "running" : "not running"). Backup root: \(backupRootExists ? "available" : "missing").",
        "DDump can copy to any local folder, external SSD, NAS, or folder watched by Google Drive, Dropbox, Box, OneDrive, iCloud Drive, or pCloud.",
        backupRootExists
          ? "If Google Drive still shows syncing, DDump has copied to the local Drive folder; Google Drive Desktop is now responsible for cloud sync."
          : "Fix: launch the sync app, wait for the folder to appear in Finder, then click Recheck or choose a reachable Backup Folder."
      ]
    }
  }

  private var appVersion: String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
  }

  @ViewBuilder
  private var cloudHelperButtons: some View {
    Button {
      state.launchCloudSetupInBrowser()
    } label: {
      settingsButtonLabel("Connect Drive", systemImage: "globe")
    }
    .buttonStyle(DDumpSecondaryButtonStyle())
    .frame(maxWidth: .infinity)

    Button {
      state.chooseCloudDestinationFolder()
    } label: {
      settingsButtonLabel("Choose folder", systemImage: "folder.badge.plus")
    }
    .buttonStyle(DDumpSecondaryButtonStyle())
    .frame(maxWidth: .infinity)

    Button {
      state.testCloudUploadConnection(showProgress: true)
    } label: {
      settingsButtonLabel("Test folder", systemImage: "checkmark.seal")
    }
    .buttonStyle(DDumpSecondaryButtonStyle())
    .frame(maxWidth: .infinity)

    Button {
      state.refreshCloudMountStatus(showProgress: true)
    } label: {
      settingsButtonLabel("Check status", systemImage: "arrow.clockwise")
    }
    .buttonStyle(DDumpSecondaryButtonStyle())
    .frame(maxWidth: .infinity)
  }

  private func dateLadderRootWarning(_ path: String) -> String? {
    let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let pattern = #"/[0-9]{4}/[0-9]{4}\.[0-9]{2}/[0-9]{4}\.[0-9]{2}\.[0-9]{2}(/)?$"#
    guard let regex = try? NSRegularExpression(pattern: pattern),
          regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) != nil else {
      return nil
    }
    return "This looks like a dated day folder. Choose the parent before the year folder, or use Smart mode with a sample path, so DDump does not nest dates twice."
  }
}

struct NamingSettings: View {
  @EnvironmentObject var state: AppState
  @State private var strategy: String = "sequential"
  @State private var fallback: String = "sequential"
  @State private var seqPrefix: String = "Shoot-"
  @State private var customValues: String = ""
  @State private var clusterGap: String = "45"
  @State private var clusterGroupingEnabled: Bool = true
  @State private var clusterAttachMinutes: String = "120"
  @State private var smartSamplePath: String = ""
  @State private var smartAssignExisting: Bool = false
  @State private var splitPhotoVideo: Bool = false
  @State private var defaultShootName: String = ""
  @State private var folderTemplate: String = "{smart_camera} - {shoot} - {date_ymd}"
  @State private var smartCameraMode: String = "smart"
  @State private var fileRenameEnabled: Bool = false
  @State private var fileNameTemplate: String = "{filename}"
  @State private var calendarProvider: String = "apple"
  @State private var calendarName: String = ""
  @State private var calendarID: String = ""
  @State private var calendarICSURL: String = ""
  @State private var calendarPadding: String = "15"
  @State private var calendarAmbiguityPromptsEnabled: Bool = true

  let strategies = ["template", "sequential", "custom", "calendar", "smart", "camera"]
  let smartCameraModes = ["smart", "brand", "model", "full"]
  let templateTokens = [
    "{smart_camera}", "{camera_brand}", "{camera_model_short}", "{camera_model}",
    "{calendar_event}", "{shoot}", "{cluster}", "{date}", "{date_ymd}", "{date_yymmdd}",
    "{year}", "{month}", "{day}", "{time}", "{folder}", "{filename}", "{sequence}",
    "{sequence_2}", "{sequence_3}", "{sequence_4}", "{total}", "{lens}", "{serial}",
    "{artist}", "{software}", "{iso}", "{focal_length}", "{gps}", "{dimensions}"
  ]

  var body: some View {
    Form {
      Section("Folder naming") {
        HStack(spacing: 6) {
          Text("Strategy")
          InfoHint(text: "Template: combine camera, calendar, date, and metadata tokens. Sequential: Shoot-1, Shoot-2. Calendar: event titles. Smart: infer from sample path. Camera: keep camera folder names.")
          Spacer()
          Picker("", selection: $strategy) {
            ForEach(strategies, id: \.self) { Text(titleCaseSettingLabel($0)).tag($0) }
          }
          .labelsHidden()
          .frame(width: 220)
        }
        .ddumpOnChange(of: strategy) { v in state.set("FOLDER_NAMING_STRATEGY", v) }

        HStack(spacing: 6) {
          Text("Fallback")
          InfoHint(text: "Used when the primary naming mode cannot decide a folder name.")
          Spacer()
          Picker("", selection: $fallback) {
            ForEach(strategies.filter { $0 != "calendar" && $0 != "smart" }, id: \.self) { Text(titleCaseSettingLabel($0)).tag($0) }
          }
          .labelsHidden()
          .frame(width: 220)
        }
        .ddumpOnChange(of: fallback) { v in state.set("FOLDER_NAMING_FALLBACK", v) }
      }

      Section("Template strategy") {
        TextField("Default offline shoot name", text: $defaultShootName, onCommit: {
          state.set("DEFAULT_SHOOT_NAME", defaultShootName)
        })
        Text("Used for {shoot} when calendar naming has no event or internet is unavailable. Leave blank to use capture-time cluster names.")
          .font(.caption)
          .foregroundColor(.secondary)

        HStack(spacing: 6) {
          TextField("Folder template", text: $folderTemplate, onCommit: {
            state.set("FOLDER_NAME_TEMPLATE", folderTemplate)
          })
          InfoHint(text: "Example: {smart_camera} - {calendar_event} - {date_ymd}")
        }
        HStack(spacing: 6) {
          Text("Smart camera label")
          InfoHint(text: "Smart keeps labels short and expands only when a shoot has multiple brands, models, or camera bodies. Brand uses Canon/Sony/DJI. Model uses simplified model. Full combines both.")
          Spacer()
          Picker("", selection: $smartCameraMode) {
            ForEach(smartCameraModes, id: \.self) { Text(titleCaseSettingLabel($0)).tag($0) }
          }
          .labelsHidden()
          .frame(width: 180)
        }
        .ddumpOnChange(of: smartCameraMode) { v in state.set("SMART_CAMERA_LABEL_MODE", v) }

        Toggle("Rename files with a template", isOn: $fileRenameEnabled)
          .ddumpOnChange(of: fileRenameEnabled) { v in
            state.set("FILE_RENAME_ENABLED", v ? "1" : "0")
          }
        HStack(spacing: 6) {
          TextField("File template", text: $fileNameTemplate, onCommit: {
            state.set("FILE_NAME_TEMPLATE", fileNameTemplate)
          })
          InfoHint(text: "Extension is preserved automatically. Example: {smart_camera}-{date_ymd}-{sequence_4}")
        }
        .disabled(!fileRenameEnabled)

        Text("Tokens")
          .font(.caption)
          .foregroundColor(.secondary)
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 8)], alignment: .leading, spacing: 8) {
          ForEach(templateTokens, id: \.self) { token in
            Button(token) {
              if fileRenameEnabled {
                fileNameTemplate += token
                state.set("FILE_NAME_TEMPLATE", fileNameTemplate)
              } else {
                folderTemplate += token
                state.set("FOLDER_NAME_TEMPLATE", folderTemplate)
              }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
          }
        }
        Text("Template names can use EXIF fields when the camera provides them: make, model, lens, serial, ISO, focal length, dimensions, GPS, capture date/time, plus calendar event and sequence tokens.")
          .font(.caption)
          .foregroundColor(.secondary)
      }

      Section("Time grouping") {
        Toggle("Enable clustering before naming", isOn: $clusterGroupingEnabled)
          .ddumpOnChange(of: clusterGroupingEnabled) { v in
            state.set("CLUSTER_GROUPING_ENABLED", v ? "1" : "0")
          }
        HStack {
          Text("New cluster after gap (minutes)")
          InfoHint(text: "If two files are farther apart than this, DDump starts a new shoot cluster.")
          Spacer()
          TextField("45", text: $clusterGap)
            .frame(width: 80)
            .multilineTextAlignment(.trailing)
            .onSubmit { state.set("CLUSTER_GAP_MINUTES", clusterGap) }
        }
        HStack {
          Text("Attach to existing shoot within (minutes)")
          InfoHint(text: "Across separate card inserts, clusters within this window join the same shoot bucket. Useful for multi-camera and drone workflow.")
          Spacer()
          TextField("120", text: $clusterAttachMinutes)
            .frame(width: 80)
            .multilineTextAlignment(.trailing)
            .onSubmit { state.set("CLUSTER_ATTACH_MINUTES", clusterAttachMinutes) }
        }
      }

      Section("Sequential strategy") {
        HStack(spacing: 6) {
          TextField("Folder prefix (e.g. \"Shoot-\")", text: $seqPrefix, onCommit: {
            state.set("FOLDER_NAME_SEQUENTIAL_PREFIX", seqPrefix)
          })
          InfoHint(text: "Sequential uses this prefix plus number: Shoot-1, Shoot-2, ...")
        }
      }

      Section("Custom strategy") {
        HStack(spacing: 6) {
          TextField("Comma-separated names (e.g. \"Bride Prep,Ceremony,Reception\")",
                    text: $customValues, onCommit: {
            state.set("FOLDER_NAME_CUSTOM_VALUES", customValues)
          })
          InfoHint(text: "DDump picks the next unused name from this list.")
        }
      }

      Section("Smart strategy") {
        HStack(spacing: 6) {
          TextField("Sample shoot folder path", text: $smartSamplePath, onCommit: {
            state.set("SMART_SAMPLE_PATH", smartSamplePath)
          })
          InfoHint(text: "Paste one real destination path. DDump reuses its year/month/day folder pattern automatically.")
        }
        if let preview = smartStructurePreview() {
          VStack(alignment: .leading, spacing: 6) {
            Text("DDump reads that as:")
              .font(.caption)
              .foregroundColor(.secondary)
            Text("Root: \(preview.root)")
              .font(.system(size: 12, weight: .regular, design: .monospaced))
            Text("Tomorrow: \(preview.tomorrow)")
              .font(.system(size: 12, weight: .regular, design: .monospaced))
            Text("Next week: \(preview.nextWeek)")
              .font(.system(size: 12, weight: .regular, design: .monospaced))
            if let warning = preview.warning {
              Label(warning, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundColor(.ddumpWarning)
            }
          }
          .padding(10)
          .background(Color.white.opacity(0.035))
          .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
          Text("Choose the lowest real shoot/date folder, for example .../2026/2026.06/2026.06.12/1 - Photo. DDump infers the parent before the year/month/day ladder and previews future folders here.")
            .font(.caption)
            .foregroundColor(.secondary)
        }
        Toggle("Use existing folders under today's Drive date folder", isOn: $smartAssignExisting)
          .ddumpOnChange(of: smartAssignExisting) { v in
            state.set("SMART_ASSIGN_EXISTING_FOLDERS", v ? "1" : "0")
          }
        Text("Advanced. Leave off unless those destination folders were made for your shoots today.")
          .font(.caption)
          .foregroundColor(.secondary)
        Toggle("Split videos to sibling 2 — Video folder", isOn: $splitPhotoVideo)
          .ddumpOnChange(of: splitPhotoVideo) { v in
            state.set("SPLIT_PHOTO_VIDEO", v ? "1" : "0")
          }
      }

      Section("Calendar naming") {
        Text("Optional. DDump can use your Mac Calendar to name shoots without any internet account setup. This works with iCloud, Google, Exchange, and subscribed calendars already synced to the Mac Calendar app.")
          .font(.caption)
          .foregroundColor(.secondary)

        CalendarProviderRow(
          icon: "calendar",
          title: "Mac Calendar",
          detail: "Recommended. Uses calendars already synced to this Mac after one macOS permission prompt.",
          selected: calendarProvider == "apple",
          status: calendarProvider == "apple" ? state.get("CALENDAR_AUTH_STATUS", default: "not_authorized") : "",
          primaryAction: {
            calendarProvider = "apple"
            state.connectAppleCalendar()
          },
          secondaryAction: nil
        )

        CalendarProviderRow(
          icon: "g.circle",
          title: "Google Calendar",
          detail: "Optional direct Google Calendar authorization. Only use this if Mac Calendar is not synced.",
          selected: calendarProvider == "google",
          status: calendarProvider == "google" ? state.get("CALENDAR_AUTH_STATUS", default: "not_authorized") : ""
        ) {
          calendarProvider = "google"
          state.set("CALENDAR_PROVIDER", "google")
          state.connectGoogleCalendar()
        } secondaryAction: {
          state.checkGoogleCalendarConnection()
        }

        CalendarProviderRow(
          icon: "link",
          title: "Calendar Link",
          detail: "Paste a private ICS or webcal link. Read-only and simple, but sync timing depends on the calendar provider.",
          selected: calendarProvider == "ics",
          status: calendarProvider == "ics" ? state.get("CALENDAR_AUTH_STATUS", default: "not_authorized") : "",
          primaryAction: {
            calendarProvider = "ics"
            state.set("CALENDAR_PROVIDER", "ics")
            state.set("CALENDAR_AUTH_STATUS", calendarICSURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "not_authorized" : "pending")
          },
          secondaryAction: nil
        )

        if calendarProvider == "ics" {
          TextField("Private ICS or webcal link", text: $calendarICSURL, onCommit: {
            state.set("CALENDAR_ICS_URL", calendarICSURL)
          })
          Button {
            state.validateCalendarLink(calendarICSURL)
          } label: {
            Label("Connect calendar link", systemImage: "checkmark.circle")
          }
          .buttonStyle(DDumpPrimaryButtonStyle())
        }

        if calendarProvider == "apple" {
          HStack {
            Text("Calendar to use")
            Spacer()
            Picker("", selection: $calendarID) {
              Text("All calendars").tag("")
              ForEach(state.appleCalendars) { calendar in
                Text(calendar.displayName).tag(calendar.id)
              }
            }
            .labelsHidden()
            .frame(width: 280)
          }
          .ddumpOnChange(of: calendarID) { v in
            state.set("CALENDAR_IDS", v)
            state.set("CALENDAR_NAME", "")
            state.refreshAppleCalendarCache(showDialog: false)
          }
          Text("Choose the shoot calendar DDump should trust for folder names. This prevents shared work schedules or privacy-masked calendars from naming folders Busy.")
            .font(.caption)
            .foregroundColor(.secondary)
        } else {
          TextField("Calendar name filter (optional)", text: $calendarName, onCommit: {
            state.set("CALENDAR_NAME", calendarName)
          })
        }
        HStack {
          Text("Event window padding")
          Spacer()
          TextField("15", text: $calendarPadding)
            .frame(width: 80)
            .multilineTextAlignment(.trailing)
            .onSubmit { state.set("CALENDAR_EVENT_PADDING_MIN", calendarPadding) }
          Text("minutes")
            .foregroundColor(.secondary)
        }
        Button {
          state.refreshAppleCalendarCache()
        } label: {
          Label("Refresh Mac Calendar events", systemImage: "arrow.clockwise")
        }
        .buttonStyle(DDumpSecondaryButtonStyle())
        .disabled(calendarProvider != "apple")
        Toggle("Ask about clusters outside calendar events", isOn: $calendarAmbiguityPromptsEnabled)
          .ddumpOnChange(of: calendarAmbiguityPromptsEnabled) { v in
            state.set("CALENDAR_AMBIGUITY_PROMPTS_ENABLED", v ? "1" : "0")
          }
      }
    }
    .formStyle(.grouped)
    .ddumpFormSkin()
    .onAppear {
      strategy = state.get("FOLDER_NAMING_STRATEGY", default: "sequential")
      fallback = state.get("FOLDER_NAMING_FALLBACK", default: "sequential")
      seqPrefix = state.get("FOLDER_NAME_SEQUENTIAL_PREFIX", default: "Shoot-")
      customValues = state.get("FOLDER_NAME_CUSTOM_VALUES")
      clusterGap = state.get("CLUSTER_GAP_MINUTES", default: "45")
      clusterGroupingEnabled = (state.get("CLUSTER_GROUPING_ENABLED", default: "1") == "1")
      clusterAttachMinutes = state.get("CLUSTER_ATTACH_MINUTES", default: "120")
      smartSamplePath = state.get("SMART_SAMPLE_PATH")
      smartAssignExisting = (state.get("SMART_ASSIGN_EXISTING_FOLDERS", default: "0") == "1")
      splitPhotoVideo = (state.get("SPLIT_PHOTO_VIDEO", default: "0") == "1")
      defaultShootName = state.get("DEFAULT_SHOOT_NAME")
      folderTemplate = state.get("FOLDER_NAME_TEMPLATE", default: "{smart_camera} - {shoot} - {date_ymd}")
      smartCameraMode = state.get("SMART_CAMERA_LABEL_MODE", default: "smart")
      fileRenameEnabled = (state.get("FILE_RENAME_ENABLED", default: "0") == "1")
      fileNameTemplate = state.get("FILE_NAME_TEMPLATE", default: "{filename}")
      calendarProvider = state.get("CALENDAR_PROVIDER", default: "apple")
      calendarName = state.get("CALENDAR_NAME")
      calendarID = state.get("CALENDAR_IDS")
      calendarICSURL = state.get("CALENDAR_ICS_URL")
      calendarPadding = state.get("CALENDAR_EVENT_PADDING_MIN", default: "15")
      calendarAmbiguityPromptsEnabled = (state.get("CALENDAR_AMBIGUITY_PROMPTS_ENABLED", default: "1") == "1")
      if calendarProvider == "apple" {
        state.refreshAvailableAppleCalendars()
      }
    }
  }

  private struct SmartPreview {
    let root: String
    let tomorrow: String
    let nextWeek: String
    let warning: String?
  }

  private func smartStructurePreview() -> SmartPreview? {
    let sample = smartSamplePath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !sample.isEmpty else { return nil }
    let pattern = #"^(.+)/[0-9]{4}/[0-9]{4}\.[0-9]{2}/[0-9]{4}\.[0-9]{2}\.[0-9]{2}(/.*)?$"#
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: sample, range: NSRange(sample.startIndex..., in: sample)),
          let rootRange = Range(match.range(at: 1), in: sample) else {
      return nil
    }
    let root = String(sample[rootRange])
    let suffix: String
    if let suffixRange = Range(match.range(at: 2), in: sample) {
      suffix = String(sample[suffixRange])
    } else {
      suffix = ""
    }
    let calendar = Calendar.current
    let tomorrow = calendar.date(byAdding: .day, value: 1, to: Date()) ?? Date()
    let nextWeek = calendar.date(byAdding: .day, value: 7, to: Date()) ?? Date()
    let warning: String?
    if suffix.lowercased().contains("/dcim/") || suffix.lowercased().hasSuffix("/dcim") {
      warning = "This sample is inside a card folder like DCIM. Choose the shoot folder or dated destination folder instead so DDump does not infer a path too deep."
    } else {
      warning = nil
    }
    return SmartPreview(
      root: root,
      tomorrow: smartPath(root: root, date: tomorrow, suffix: suffix),
      nextWeek: smartPath(root: root, date: nextWeek, suffix: suffix),
      warning: warning
    )
  }

  private func smartPath(root: String, date: Date, suffix: String) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy"
    let year = formatter.string(from: date)
    formatter.dateFormat = "yyyy.MM"
    let month = formatter.string(from: date)
    formatter.dateFormat = "yyyy.MM.dd"
    let day = formatter.string(from: date)
    return "\(root)/\(year)/\(month)/\(day)\(suffix)"
  }
}

struct DetectionSettings: View {
  @EnvironmentObject var state: AppState
  @State private var prefixes: String = ""
  @State private var requirePhotos: Bool = true
  @State private var extensions: String = ""
  @State private var ejectOnSuccess: Bool = true
  @State private var ejectGraceSeconds: String = "60"
  @State private var verifyHash: Bool = false
  @State private var lookbackHours: String = "24"
  @State private var scanMode: String = "today"
  @State private var videoExtensions: String = ""
  @State private var promptSourceFoldersOnNewCard: Bool = false
  @State private var sqliteMemoryEnabled: Bool = false
  @State private var ntfyTopic: String = ""
  @State private var ntfyStagingStarted: Bool = false
  @State private var ntfyCardEjected: Bool = true
  @State private var ntfyUploadStarted: Bool = false
  @State private var ntfyUploadComplete: Bool = true
  @State private var ntfyMountFailed: Bool = true
  @State private var ntfyCardAlmostFull: Bool = true
  @State private var ntfyIntegrityWarning: Bool = true
  @State private var cardAlmostFullAlertEnabled: Bool = true
  @State private var notificationTimeoutSeconds: String = "60"

  var body: some View {
    Form {
      Section("Memory") {
        Toggle("Use SQLite memory (beta)", isOn: $sqliteMemoryEnabled)
          .ddumpOnChange(of: sqliteMemoryEnabled) { v in state.set("DB_ENABLED", v ? "1" : "0") }
        Text("Default OFF. When off, staging folders are the memory: DDump imports from the lookback window only if files are not already in staging.")
          .font(.caption)
          .foregroundColor(.secondary)
      }

      Section("Cards") {
        Toggle("View-only mode", isOn: Binding(
          get: { state.viewOnlyMode },
          set: { state.setViewOnlyMode($0) }
        ))
        .disabled(state.runActive)
        Text("When on, automatic runs leave newly connected SSDs and cards completely untouched and mounted. Manual import remains available.")
          .font(.caption)
          .foregroundColor(.secondary)
        HStack(spacing: 6) {
          TextField("Auto-trust name prefixes (comma-separated)",
                    text: $prefixes, onCommit: { state.set("TRUSTED_NAME_PREFIXES", prefixes) })
          InfoHint(text: "Cards with these names auto-import without confirmation.")
        }
        Toggle("Require photos or trusted card", isOn: $requirePhotos)
          .ddumpOnChange(of: requirePhotos) { v in state.set("REQUIRE_PHOTOS_OR_TRUSTED", v ? "1" : "0") }
        Toggle("Eject card on successful import", isOn: $ejectOnSuccess)
          .ddumpOnChange(of: ejectOnSuccess) { v in state.set("EJECT_ON_SUCCESS", v ? "1" : "0") }
        HStack {
          Text("Eject safety delay (seconds)")
          InfoHint(text: "DDump waits at least this long before ejecting, so you can tap Do Not Eject.")
          Spacer()
          TextField("60", text: $ejectGraceSeconds)
            .frame(width: 80)
            .multilineTextAlignment(.trailing)
            .onSubmit { state.set("EJECT_GRACE_SECONDS", ejectGraceSeconds) }
        }
        Toggle("Alert when card is almost full for another similar shoot", isOn: $cardAlmostFullAlertEnabled)
          .ddumpOnChange(of: cardAlmostFullAlertEnabled) { v in
            state.set("CARD_ALMOST_FULL_ALERT_ENABLED", v ? "1" : "0")
          }
      }

      Section("Scan window") {
        Toggle("Ask me to choose card folders manually", isOn: $promptSourceFoldersOnNewCard)
          .ddumpOnChange(of: promptSourceFoldersOnNewCard) { v in state.set("PROMPT_FOR_SOURCE_FOLDERS_ON_NEW_DRIVE", v ? "1" : "0") }
        Text("Advanced. Leave off to scan the whole card for media inside the time window.")
          .font(.caption)
          .foregroundColor(.secondary)

        HStack(spacing: 6) {
          Text("Scan mode")
          InfoHint(text: "Today imports files changed since local midnight. Hours imports files changed within the number of hours you enter.")
          Spacer()
          Picker("", selection: $scanMode) {
            Text("Today").tag("today")
            Text("Hours").tag("lookback")
          }
          .labelsHidden()
          .frame(width: 190)
          .ddumpOnChange(of: scanMode) { v in
            state.set("CANDIDATE_MODE", normalizedScanMode(v))
          }
        }

        HStack {
          Text("Lookback hours")
          InfoHint(text: "How far back DDump scans on each card insert.")
          Spacer()
          TextField("24", text: $lookbackHours)
            .frame(width: 80)
            .multilineTextAlignment(.trailing)
            .onSubmit { state.set("LOOKBACK_HOURS", lookbackHours) }
        }
        .disabled(scanMode != "lookback")
      }

      Section("Verification") {
        Toggle("Verify each copied file with SHA-256 hash", isOn: $verifyHash)
          .ddumpOnChange(of: verifyHash) { v in state.set("VERIFY_COPY_HASH", v ? "1" : "0") }
      }

      Section("File types") {
        TextField("Recognized photo extensions", text: $extensions, onCommit: { state.set("PHOTO_FILE_EXTENSIONS", extensions) })
        TextField("Video extensions for split mode", text: $videoExtensions, onCommit: { state.set("VIDEO_FILE_EXTENSIONS", videoExtensions) })
      }

    }
    .formStyle(.grouped)
    .ddumpFormSkin()
    .onAppear {
      prefixes = state.get("TRUSTED_NAME_PREFIXES", default: "")
      requirePhotos = (state.get("REQUIRE_PHOTOS_OR_TRUSTED", default: "1") == "1")
      extensions = state.get("PHOTO_FILE_EXTENSIONS")
      ejectOnSuccess = (state.get("EJECT_ON_SUCCESS", default: "1") == "1")
      ejectGraceSeconds = state.get("EJECT_GRACE_SECONDS", default: "60")
      verifyHash = (state.get("VERIFY_COPY_HASH", default: "0") == "1")
      scanMode = normalizedScanMode(state.get("CANDIDATE_MODE", default: "today"))
      lookbackHours = state.get("LOOKBACK_HOURS", default: "24")
      videoExtensions = state.get("VIDEO_FILE_EXTENSIONS", default: "mp4,mov,m4v,avi,mts,m2ts,3gp,3gpp,insv,gpr,braw,mxf,crm,r3d,ari,arri,cine")
      promptSourceFoldersOnNewCard = (state.get("PROMPT_FOR_SOURCE_FOLDERS_ON_NEW_DRIVE", default: "0") == "1")
      sqliteMemoryEnabled = state.sqliteMemoryEnabled
      cardAlmostFullAlertEnabled = (state.get("CARD_ALMOST_FULL_ALERT_ENABLED", default: "1") == "1")
      ntfyTopic = state.get("NTFY_TOPIC", default: "")
      notificationTimeoutSeconds = state.get("NOTIFICATION_TIMEOUT_SECONDS", default: "60")
      ntfyStagingStarted = (state.get("NTFY_NOTIFY_STAGING_STARTED", default: "0") == "1")
      ntfyCardEjected = (state.get("NTFY_NOTIFY_CARD_EJECTED", default: "1") == "1")
      ntfyUploadStarted = (state.get("NTFY_NOTIFY_UPLOAD_STARTED", default: "0") == "1")
      ntfyUploadComplete = (state.get("NTFY_NOTIFY_UPLOAD_COMPLETE", default: "1") == "1")
      ntfyMountFailed = (state.get("NTFY_NOTIFY_MOUNT_FAILED", default: "0") == "1")
      ntfyCardAlmostFull = (state.get("NTFY_NOTIFY_CARD_ALMOST_FULL", default: "1") == "1")
      ntfyIntegrityWarning = (state.get("NTFY_NOTIFY_INTEGRITY_WARNING", default: "1") == "1")
    }
  }

  private func normalizedScanMode(_ value: String) -> String {
    let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return (cleaned == "lookback" || cleaned == "hours") ? "lookback" : "today"
  }
}

struct NotificationEventConfig: Identifiable {
  let id: String
  let title: String
  let ntfyKey: String
  let macosKey: String
  let templateKey: String
  let defaultNtfy: Bool
  let defaultMacOS: Bool
  let defaultTemplate: String
  let tokens: [String]
  let example: String
}

struct NotificationsSettings: View {
  @EnvironmentObject var state: AppState
  @State private var ntfyTopic: String = ""
  @State private var macOSNotificationsEnabled: Bool = true
  @State private var notificationTimeoutSeconds: String = "60"
  @State private var ntfyEnabled: [String: Bool] = [:]
  @State private var macosEnabled: [String: Bool] = [:]
  @State private var templates: [String: String] = [:]

  static let events: [NotificationEventConfig] = [
    .init(
      id: "pending_recovery_missing",
      title: "Recovery needs card",
      ntfyKey: "NTFY_NOTIFY_PENDING_RECOVERY_MISSING",
      macosKey: "MACOS_NOTIFY_PENDING_RECOVERY_MISSING",
      templateKey: "NTFY_TEMPLATE_PENDING_RECOVERY_MISSING",
      defaultNtfy: true,
      defaultMacOS: true,
      defaultTemplate: "{import_time} import is missing {missing_count} of {total_count} items. Please reinsert the same card to retry.",
      tokens: ["{import_time}", "{missing_count}", "{total_count}", "{examples}", "{roots}", "{message}"],
      example: "5/26 5:24pm import is missing 2 of 80 items. Please reinsert the same card to retry."
    ),
    .init(id: "staging_started", title: "Staging started", ntfyKey: "NTFY_NOTIFY_STAGING_STARTED", macosKey: "MACOS_NOTIFY_STAGING_STARTED", templateKey: "NTFY_TEMPLATE_STAGING_STARTED", defaultNtfy: false, defaultMacOS: true, defaultTemplate: "{message}", tokens: ["{message}", "{title}", "{event}"], example: "Red: staging started."),
    .init(id: "upload_started", title: "Upload started", ntfyKey: "NTFY_NOTIFY_UPLOAD_STARTED", macosKey: "MACOS_NOTIFY_UPLOAD_STARTED", templateKey: "NTFY_TEMPLATE_UPLOAD_STARTED", defaultNtfy: false, defaultMacOS: true, defaultTemplate: "{message}", tokens: ["{message}", "{title}", "{event}"], example: "Red: upload started for 42 file(s)."),
    .init(id: "upload_complete", title: "Upload complete", ntfyKey: "NTFY_NOTIFY_UPLOAD_COMPLETE", macosKey: "MACOS_NOTIFY_UPLOAD_COMPLETE", templateKey: "NTFY_TEMPLATE_UPLOAD_COMPLETE", defaultNtfy: true, defaultMacOS: true, defaultTemplate: "{message}", tokens: ["{message}", "{title}", "{event}"], example: "Red: uploaded 42 file(s) to 2026.06.01."),
    .init(id: "card_ejected", title: "Card ejected", ntfyKey: "NTFY_NOTIFY_CARD_EJECTED", macosKey: "MACOS_NOTIFY_CARD_EJECTED", templateKey: "NTFY_TEMPLATE_CARD_EJECTED", defaultNtfy: true, defaultMacOS: true, defaultTemplate: "{message}", tokens: ["{message}", "{title}", "{event}"], example: "Red: card ejected after import."),
    .init(id: "card_almost_full", title: "Card almost full", ntfyKey: "NTFY_NOTIFY_CARD_ALMOST_FULL", macosKey: "MACOS_NOTIFY_CARD_ALMOST_FULL", templateKey: "NTFY_TEMPLATE_CARD_ALMOST_FULL", defaultNtfy: true, defaultMacOS: true, defaultTemplate: "{message}", tokens: ["{message}", "{title}", "{event}"], example: "Red: free 14 GB, last import 64 GB."),
    .init(id: "integrity_warning", title: "Integrity warning", ntfyKey: "NTFY_NOTIFY_INTEGRITY_WARNING", macosKey: "MACOS_NOTIFY_INTEGRITY_WARNING", templateKey: "NTFY_TEMPLATE_INTEGRITY_WARNING", defaultNtfy: true, defaultMacOS: true, defaultTemplate: "{message}", tokens: ["{message}", "{title}", "{event}"], example: "Run finished with copy/verify issues."),
    .init(id: "mount_failed", title: "Cloud mount failed", ntfyKey: "NTFY_NOTIFY_MOUNT_FAILED", macosKey: "MACOS_NOTIFY_MOUNT_FAILED", templateKey: "NTFY_TEMPLATE_MOUNT_FAILED", defaultNtfy: false, defaultMacOS: false, defaultTemplate: "{message}", tokens: ["{message}", "{title}", "{event}"], example: "Google Drive mount did not become ready.")
  ]

  var body: some View {
    Form {
      Section("Delivery") {
        HStack {
          Toggle("Mac notifications", isOn: Binding(
            get: { macOSNotificationsEnabled },
            set: { value in
              macOSNotificationsEnabled = value
              state.setMacOSNotificationsEnabled(value)
            }
          ))
          Spacer()
          Button("Send test") {
            state.sendTestMacOSNotification()
          }
          .buttonStyle(DDumpSecondaryButtonStyle())
          .disabled(!macOSNotificationsEnabled)
        }
        Text("On by default. Shows DDump import, upload, eject, and warning alerts through macOS. Individual event switches are below.")
          .font(.caption)
          .foregroundColor(.secondary)
        if macOSNotificationsEnabled && state.macOSNotificationAuthorization == .denied {
          HStack {
            Label("Blocked by macOS", systemImage: "exclamationmark.triangle.fill")
              .foregroundColor(.ddumpWarning)
            Spacer()
            Button("Open Notification Settings") {
              state.openMacOSNotificationSettings()
            }
            .buttonStyle(DDumpSecondaryButtonStyle())
          }
        }
        VStack(alignment: .leading, spacing: 8) {
          Text("Phone alerts are optional.")
            .font(DDumpFont.ui(13, weight: .semibold))
          Text("DDump can use ntfy to push simple alerts to your phone. Install the ntfy app, choose a private topic name, then paste that topic here. If you leave this blank, DDump only uses Mac notifications.")
            .font(.caption)
            .foregroundColor(.secondary)
          HStack(spacing: 8) {
            Button("iPhone app") {
              if let url = URL(string: "https://apps.apple.com/us/app/ntfy/id1625396347") {
                NSWorkspace.shared.open(url)
              }
            }
            .buttonStyle(DDumpSecondaryButtonStyle())

            Button("Setup guide") {
              if let url = URL(string: "https://ntfy.sh/docs/subscribe/phone/") {
                NSWorkspace.shared.open(url)
              }
            }
            .buttonStyle(DDumpSecondaryButtonStyle())
          }
        }
        TextField("Private phone-alert topic", text: $ntfyTopic, onCommit: { state.set("NTFY_TOPIC", ntfyTopic) })
        HStack {
          Text("macOS action timeout (seconds)")
          Spacer()
          TextField("60", text: $notificationTimeoutSeconds)
            .frame(width: 80)
            .multilineTextAlignment(.trailing)
            .onSubmit { state.set("NOTIFICATION_TIMEOUT_SECONDS", notificationTimeoutSeconds) }
        }
      }

      Section("Events") {
        ForEach(Self.events) { event in
          notificationEventRow(event)
        }
      }
    }
    .formStyle(.grouped)
    .ddumpFormSkin()
    .onAppear(perform: load)
  }

  func notificationEventRow(_ event: NotificationEventConfig) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .center, spacing: 14) {
        Text(event.title)
          .font(.headline)
        Spacer()
        Toggle("NTFY", isOn: boolBinding(event.id, event.ntfyKey, event.defaultNtfy, channel: "ntfy"))
          .toggleStyle(.checkbox)
        Toggle("macOS", isOn: boolBinding(event.id, event.macosKey, event.defaultMacOS, channel: "macos"))
          .toggleStyle(.checkbox)
      }

      VStack(alignment: .leading, spacing: 6) {
        Text("ntfy message")
          .font(.caption)
          .foregroundColor(.secondary)
        TextEditor(text: templateBinding(event))
          .font(.system(.caption, design: .monospaced))
          .frame(minHeight: 48)
          .scrollContentBackground(.hidden)
          .background(Color.ddumpBGAlt)
          .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
          .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
              .stroke(Color.ddumpLine1, lineWidth: 1)
          )
          .disabled(!(ntfyEnabled[event.id] ?? event.defaultNtfy))
      }

      HStack(spacing: 6) {
        ForEach(event.tokens, id: \.self) { token in
          Button(token) {
            let current = templates[event.id] ?? event.defaultTemplate
            let next = current.isEmpty ? token : "\(current) \(token)"
            templates[event.id] = next
            state.set(event.templateKey, next)
          }
          .buttonStyle(DDumpSecondaryButtonStyle())
        }
      }

      Text("Example: \(event.example)")
        .font(.caption)
        .foregroundColor(.secondary)
    }
    .padding(.vertical, 6)
  }

  func boolBinding(_ id: String, _ key: String, _ defaultValue: Bool, channel: String) -> Binding<Bool> {
    Binding(
      get: {
        if channel == "ntfy" {
          return ntfyEnabled[id] ?? defaultValue
        }
        return macosEnabled[id] ?? defaultValue
      },
      set: { value in
        if channel == "ntfy" {
          ntfyEnabled[id] = value
        } else {
          macosEnabled[id] = value
        }
        state.set(key, value ? "1" : "0")
      }
    )
  }

  func templateBinding(_ event: NotificationEventConfig) -> Binding<String> {
    Binding(
      get: { templates[event.id] ?? event.defaultTemplate },
      set: { value in
        templates[event.id] = value
        state.set(event.templateKey, value)
      }
    )
  }

  func load() {
    state.refreshMacOSNotificationAuthorization()
    macOSNotificationsEnabled = state.get("MACOS_NOTIFICATIONS_ENABLED", default: "1") == "1"
    ntfyTopic = state.get("NTFY_TOPIC", default: "")
    notificationTimeoutSeconds = state.get("NOTIFICATION_TIMEOUT_SECONDS", default: "60")
    for event in Self.events {
      ntfyEnabled[event.id] = state.get(event.ntfyKey, default: event.defaultNtfy ? "1" : "0") == "1"
      macosEnabled[event.id] = state.get(event.macosKey, default: event.defaultMacOS ? "1" : "0") == "1"
      templates[event.id] = state.get(event.templateKey, default: event.defaultTemplate)
    }
  }
}

struct CloudSettings: View {
  @EnvironmentObject var state: AppState
  @State private var enabled: Bool = true
  @State private var managedMountEnabled: Bool = false
  @State private var showSetupGuide: Bool = false
  @State private var showAdvanced: Bool = false
  @State private var mountPoint: String = ""
  @State private var remote: String = ""
  @State private var rcloneBin: String = ""
  @State private var mountLabel: String = ""
  @State private var networkResumeEnabled: Bool = true
  @State private var networkResumeCheckSeconds: String = "20"
  @State private var networkResumeCooldownSeconds: String = "120"

  private func sectionHeader(_ title: String, caption: String? = nil) -> some View {
    HStack(alignment: .firstTextBaseline) {
      Text(title)
        .font(DDumpFont.ui(18, weight: .semibold))
        .foregroundColor(.ddumpFG1)
      Spacer()
      if let caption, !caption.isEmpty {
        Text(caption)
          .font(DDumpFont.ui(12))
          .foregroundColor(.ddumpFG3)
      }
    }
  }

  private func connectionRow(_ label: String, text: Binding<String>, onCommit: @escaping () -> Void) -> some View {
    HStack(spacing: 14) {
      Text(label)
        .font(DDumpFont.ui(12, weight: .medium))
        .foregroundColor(.ddumpFG2)
        .frame(width: 165, alignment: .leading)
      TextField("", text: text, onCommit: onCommit)
        .font(.system(size: 12, weight: .regular, design: .monospaced))
        .textFieldStyle(.plain)
        .foregroundColor(.ddumpFG1)
    }
    .padding(.vertical, 10)
  }

  private func statusCard(_ ok: Bool, okText: String, failText: String, icon: String, hint: String = "") -> some View {
    let tint = ok ? Color.ddumpSuccess : Color.ddumpDanger
    return HStack(alignment: .top, spacing: 10) {
      Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
        .font(.system(size: 16, weight: .semibold))
        .foregroundColor(tint)
        .frame(width: 20, alignment: .leading)
      VStack(alignment: .leading, spacing: 2) {
        Label(ok ? okText : failText, systemImage: icon)
          .labelStyle(.titleAndIcon)
          .font(DDumpFont.ui(13, weight: .medium))
          .foregroundColor(tint)
        if !hint.isEmpty {
          Text(hint)
            .font(DDumpFont.ui(12))
            .foregroundColor(.ddumpFG3)
        }
      }
      Spacer()
    }
    .padding(12)
    .background(
      RoundedRectangle(cornerRadius: 9, style: .continuous)
        .fill(tint.opacity(0.12))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 9, style: .continuous)
        .stroke(tint.opacity(0.35), lineWidth: 1)
    )
  }

  private func wizardMilestone(_ done: Bool, _ text: String) -> some View {
    HStack(spacing: 7) {
      Image(systemName: done ? "checkmark.circle.fill" : "circle")
        .font(.system(size: 12, weight: .semibold))
        .foregroundColor(done ? .ddumpSuccess : .ddumpFG3)
      Text(text)
        .font(DDumpFont.ui(12, weight: done ? .medium : .regular))
        .foregroundColor(done ? .ddumpFG2 : .ddumpFG3)
    }
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        if state.cloudActionInProgress {
          HStack(spacing: 10) {
            ProgressView()
              .controlSize(.small)
              .tint(.ddumpPeach)
            Text(state.cloudActionMessage.isEmpty ? "Working…" : state.cloudActionMessage)
              .font(DDumpFont.ui(12, weight: .medium))
              .foregroundColor(.ddumpFG2)
          }
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
          .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
              .fill(Color.ddumpSurface2)
          )
          .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
              .stroke(Color.ddumpLine1, lineWidth: 1)
          )
        }

        sectionHeader("Cloud setup")
        VStack(alignment: .leading, spacing: 12) {
          let cloudOff = !enabled
          let directUpload = state.get("GDRIVE_DIRECT_UPLOAD", default: "0") == "1"
          let needsRclone = directUpload || managedMountEnabled
          let needsInstall = enabled && needsRclone && !state.cloudRcloneReady
          let needsConnect = enabled && needsRclone && state.cloudRcloneReady && !state.cloudRemoteConfigured
          let needsDestination = enabled && (!needsRclone || (state.cloudRcloneReady && state.cloudRemoteConfigured)) && !state.cloudDestinationReadyForUI
          let needsTest = enabled && (!needsRclone || (state.cloudRcloneReady && state.cloudRemoteConfigured)) && state.cloudDestinationReadyForUI && !state.cloudSetupConnectionOKForUI
          let done = enabled && (!needsRclone || (state.cloudRcloneReady && state.cloudRemoteConfigured)) && state.cloudDestinationReadyForUI && state.cloudSetupConnectionOKForUI
          let stepNumber: Int = {
            if cloudOff { return 1 }
            if needsInstall { return 1 }
            if needsConnect { return 2 }
            if needsDestination { return 3 }
            if needsTest { return 4 }
            return 5
          }()
          let titleText: String = {
            if cloudOff { return "Cloud uploads are turned off." }
            if needsInstall { return "Install the cloud helper." }
            if needsConnect {
              return state.cloudSetupBrowserRunning ? "Finish Google Drive connection in the browser." : "Connect Google Drive."
            }
            if needsDestination { return "Choose the upload folder." }
            if needsTest { return "Test the upload connection." }
            return "Cloud setup complete."
          }()
          let detailText: String = {
            if cloudOff { return "Turn cloud uploads on to start the guided setup." }
            if needsInstall { return "DDump installs the small helper it needs to talk to Google Drive." }
            if needsConnect { return "DDump opens Google Drive connection directly. You do not need to create or name anything manually." }
            if needsDestination { return "Pick the Google Drive Desktop folder where finished dumps should land." }
            if needsTest { return "DDump writes and removes a tiny test file to prove the upload folder works." }
            return "DDump is ready to copy finished dumps to Google Drive while keeping staging as backup."
          }()

          HStack(alignment: .center, spacing: 10) {
            Text("Step \(stepNumber) of 5")
              .font(DDumpFont.ui(12, weight: .semibold))
              .foregroundColor(.ddumpPeach)
              .padding(.horizontal, 10)
              .padding(.vertical, 5)
              .background(Capsule().fill(Color.ddumpPeach.opacity(0.12)))
            Text(titleText)
              .font(DDumpFont.ui(15, weight: .semibold))
              .foregroundColor(.ddumpFG1)
            Spacer()
          }

          Text(detailText)
            .font(DDumpFont.ui(12))
            .foregroundColor(.ddumpFG2)
            .fixedSize(horizontal: false, vertical: true)

          HStack(spacing: 12) {
            wizardMilestone(!needsRclone || state.cloudRcloneReady, "Helper")
            wizardMilestone(!needsRclone || state.cloudRemoteConfigured, "Google Drive")
            wizardMilestone(state.cloudDestinationReadyForUI, "Folder")
            wizardMilestone(state.cloudSetupConnectionOKForUI, "Tested")
          }

          HStack(spacing: 10) {
            if cloudOff {
              Button {
                enabled = true
                managedMountEnabled = false
                state.set("CLOUD_UPLOADS_ENABLED", "1")
                state.set("ENABLE_POST_EJECT_MOVE", "1")
                state.set("GDRIVE_MOUNT_ENABLED", "0")
                state.set("GDRIVE_DIRECT_UPLOAD", "0")
                state.refreshCloudMountStatus()
                state.lastUtilityMessage = "Cloud uploads are on. Continue setup below."
              } label: {
                Label("Turn on cloud uploads", systemImage: "icloud")
              }
              .buttonStyle(DDumpPrimaryButtonStyle())
            } else if needsInstall {
              Button {
                state.installRcloneViaApp()
              } label: {
                Label("Install cloud helper", systemImage: "square.and.arrow.down")
              }
              .buttonStyle(DDumpPrimaryButtonStyle())
            } else if needsConnect {
              Button {
                if state.cloudSetupBrowserRunning {
                  state.finishCloudSetupFromBrowser()
                } else {
                  state.launchCloudSetupInBrowser()
                }
              } label: {
                Label(state.cloudSetupBrowserRunning ? "Check Google Drive connection" : "Connect Google Drive", systemImage: "globe")
              }
              .buttonStyle(DDumpPrimaryButtonStyle())
              if state.cloudSetupBrowserRunning {
                Button {
                  state.stopCloudSetupInBrowser()
                } label: {
                  Label("Cancel", systemImage: "xmark.circle")
                }
                .buttonStyle(DDumpSecondaryButtonStyle())
              }
            } else if needsDestination {
              Button {
                state.chooseCloudDestinationFolder()
              } label: {
                Label("Choose upload folder", systemImage: "folder.badge.plus")
              }
              .buttonStyle(DDumpPrimaryButtonStyle())
            } else if needsTest {
              Button {
                state.testCloudUploadConnection(showProgress: true)
              } label: {
                Label(state.cloudSetupConnectionOKForUI ? "Reconnect cloud folder" : "Test upload connection", systemImage: "checkmark.seal")
              }
              .buttonStyle(DDumpPrimaryButtonStyle())
            } else {
              Button {
                state.refreshCloudMountStatus(showProgress: true)
              } label: {
                Label("Re-check cloud status", systemImage: "arrow.clockwise")
              }
              .buttonStyle(DDumpPrimaryButtonStyle())
            }

            if enabled {
              Button {
                enabled = false
                managedMountEnabled = false
                state.set("CLOUD_UPLOADS_ENABLED", "0")
                state.set("ENABLE_POST_EJECT_MOVE", "0")
                state.set("GDRIVE_MOUNT_ENABLED", "0")
                state.set("GDRIVE_DIRECT_UPLOAD", "0")
                state.refreshCloudMountStatus()
                state.lastUtilityMessage = "Cloud uploads are disabled."
              } label: {
                Label("Turn off cloud uploads", systemImage: "icloud.slash")
              }
              .buttonStyle(DDumpSecondaryButtonStyle())
            }
          }
          .disabled(state.cloudActionInProgress)

          if !state.lastUtilityMessage.isEmpty {
            HStack(alignment: .top, spacing: 10) {
              if done {
                Image(systemName: "checkmark.circle.fill")
                  .foregroundColor(.ddumpSuccess)
                  .font(.system(size: 14, weight: .semibold))
              } else {
                InfoHint(text: "This message reports the current Google Drive helper status or the result of the last cloud setup action.")
              }
              Text(state.lastUtilityMessage)
                .font(DDumpFont.ui(12, weight: .medium))
                .foregroundColor(.ddumpFG2)
                .fixedSize(horizontal: false, vertical: true)
              Spacer(minLength: 0)
            }
            .padding(10)
            .background(
              RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.ddumpSurface2)
            )
            .overlay(
              RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.ddumpLine1, lineWidth: 1)
            )
          }

          if done {
            Text("Upload destination: \(state.uploadRootForUI)")
              .font(DDumpFont.ui(12))
              .foregroundColor(.ddumpFG2)
          }
        }
        .padding(14)
        .background(
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.ddumpSurface)
        )
        .overlay(
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(Color.ddumpLine1, lineWidth: 1)
        )

        Button {
          showAdvanced.toggle()
        } label: {
          Label(showAdvanced ? "Hide advanced cloud controls" : "Show advanced cloud controls", systemImage: "slider.horizontal.3")
        }
        .buttonStyle(DDumpSecondaryButtonStyle())

        if showAdvanced {
          sectionHeader("Connection", caption: "advanced repair controls")

          VStack(spacing: 0) {
          HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
              Text("Enable DDump-managed cloud mount")
                .font(DDumpFont.ui(14, weight: .medium))
                .foregroundColor(.ddumpFG1)
              Text("Advanced fallback only. Google Drive Desktop folder copy is preferred and keeps staging as the backup.")
                .font(DDumpFont.ui(12))
                .foregroundColor(.ddumpFG3)
            }
            Spacer()
            Toggle("", isOn: $managedMountEnabled)
              .labelsHidden()
              .toggleStyle(.switch)
              .tint(.ddumpPeach)
              .ddumpOnChange(of: enabled) { v in
                managedMountEnabled = state.gdriveMountEnabledForUI
              }
              .ddumpOnChange(of: managedMountEnabled) { v in
                state.set("CLOUD_UPLOADS_ENABLED", "1")
                state.set("ENABLE_POST_EJECT_MOVE", "1")
                state.set("GDRIVE_MOUNT_ENABLED", v ? "1" : "0")
                state.set("GDRIVE_DIRECT_UPLOAD", "0")
                state.refreshCloudMountStatus()
              }
          }
          .padding(.vertical, 12)

          Rectangle().fill(Color.ddumpLine1).frame(height: 1)
          connectionRow("rclone remote", text: $remote) {
            state.set("GDRIVE_REMOTE", remote)
            state.refreshCloudMountStatus()
          }
          Rectangle().fill(Color.ddumpLine1).frame(height: 1)
          connectionRow("Mount point folder", text: $mountPoint) {
            state.set("GDRIVE_MOUNT_POINT", mountPoint)
            state.refreshCloudMountStatus()
          }
          Rectangle().fill(Color.ddumpLine1).frame(height: 1)
          connectionRow("rclone binary path", text: $rcloneBin) {
            state.set("RCLONE_BIN", rcloneBin)
            state.refreshCloudMountStatus()
          }
          Rectangle().fill(Color.ddumpLine1).frame(height: 1)
          connectionRow("Mount service label", text: $mountLabel) {
            state.set("GDRIVE_MOUNT_LABEL", mountLabel)
            state.refreshCloudMountStatus()
          }
          }
          .padding(.horizontal, 14)
          .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
              .fill(Color.ddumpSurface)
          )
          .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
              .stroke(Color.ddumpLine1, lineWidth: 1)
          )

          sectionHeader("Status", caption: state.cloudLastCheckedAt.isEmpty ? nil : "Last check \(state.cloudLastCheckedAt)")
          if enabled {
          VStack(spacing: 10) {
            statusCard(state.cloudRcloneReady, okText: "Cloud helper found", failText: "Cloud helper missing", icon: "wrench.and.screwdriver", hint: state.cloudRcloneReady ? "" : "Install the cloud helper from guided setup.")
            statusCard(state.cloudRemoteConfigured, okText: "Google Drive connected", failText: "Google Drive not connected", icon: "link", hint: state.cloudRemoteConfigured ? "" : "Use Connect Google Drive in guided setup.")
            statusCard(state.cloudServiceLoaded, okText: "Mount service loaded", failText: "Mount service not loaded", icon: "gearshape.2", hint: state.cloudServiceLoaded ? "" : "Use Start mount to load the LaunchAgent.")
            statusCard(state.cloudMountActive, okText: "Mount active", failText: "Mount inactive", icon: "externaldrive.badge.icloud", hint: state.cloudMountActive ? "" : "DDump will retry with backoff before sending a failure alert.")
            statusCard(state.networkOnline, okText: "Network reachable", failText: "Network unavailable", icon: "wifi", hint: state.networkOnline ? "" : "DDump waits and retries automatically when connection returns.")
          }
          } else {
          HStack(spacing: 8) {
            Image(systemName: "icloud.slash")
              .foregroundColor(.ddumpFG3)
            Text("Cloud uploads are disabled for this app.")
              .font(DDumpFont.ui(12))
              .foregroundColor(.ddumpFG3)
          }
          .padding(10)
          .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
              .fill(Color.ddumpSurface2)
          )
          .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
              .stroke(Color.ddumpLine1, lineWidth: 1)
          )
          }

          sectionHeader("Actions")
          VStack(alignment: .leading, spacing: 10) {
          if !enabled {
            Text("Cloud actions are disabled. Turn on cloud above to manage mount/setup.")
              .font(DDumpFont.ui(12))
              .foregroundColor(.ddumpFG3)
          }
          HStack(spacing: 10) {
            Button {
              state.startCloudMount(showProgress: true)
            } label: {
              Label("Start mount", systemImage: "play.circle")
            }
            .buttonStyle(DDumpPrimaryButtonStyle())

            Button {
              state.stopCloudMount()
            } label: {
              Label("Stop mount", systemImage: "stop.circle")
            }
            .buttonStyle(DDumpSecondaryButtonStyle())

            Button {
              state.refreshCloudMountStatus(showProgress: true)
            } label: {
              Label("Re-check status", systemImage: "arrow.clockwise")
            }
            .buttonStyle(DDumpSecondaryButtonStyle())
          }
          .disabled(state.cloudActionInProgress || !enabled)

          HStack(spacing: 10) {
            Button {
              state.hardRestartCloudMount()
            } label: {
              Label("Hard restart mount", systemImage: "bolt.circle")
            }
            .buttonStyle(DDumpSecondaryButtonStyle())

            Button {
              openInFinder(state.gdriveMountPointForUI)
            } label: {
              Label("Open mount folder", systemImage: "folder")
            }
            .buttonStyle(DDumpSecondaryButtonStyle())

            Button {
              state.resumePendingUploadsNow()
            } label: {
              Label("Resume uploads now", systemImage: "arrow.up.circle")
            }
            .buttonStyle(DDumpSecondaryButtonStyle())

            Menu {
              Button {
                state.installRcloneViaApp()
              } label: {
                Label("Install cloud helper", systemImage: "square.and.arrow.down")
              }
              Button {
                state.launchCloudSetupInBrowser()
              } label: {
                Label("Connect Google Drive", systemImage: "globe")
              }
              Button {
                state.finishCloudSetupFromBrowser()
              } label: {
                Label("Check Google Drive", systemImage: "checkmark.circle")
              }
              Button {
                state.stopCloudSetupInBrowser()
              } label: {
                Label("Cancel sign-in", systemImage: "xmark.circle")
              }
              Button {
                state.chooseCloudDestinationFolder()
              } label: {
                Label("Choose upload folder", systemImage: "folder.badge.plus")
              }
              Button {
                state.testCloudUploadConnection(showProgress: true)
              } label: {
                Label("Test upload folder", systemImage: "checkmark.seal")
              }
              Button {
                state.openNetworkVolumePrivacySettings()
              } label: {
                Label("Open privacy settings", systemImage: "hand.raised")
              }
              Button {
                showSetupGuide = true
              } label: {
                Label("Guided setup help", systemImage: "sparkles")
              }
            } label: {
              Label("More setup actions", systemImage: "ellipsis.circle")
            }
            .buttonStyle(DDumpSecondaryButtonStyle())
            Spacer(minLength: 0)
          }
          .disabled(state.cloudActionInProgress || !enabled)

          if !state.lastUtilityMessage.isEmpty {
            HStack(alignment: .top, spacing: 10) {
              InfoHint(text: "This message reports the current cloud helper status or the result of the last advanced cloud action.")
              Text(state.lastUtilityMessage)
                .font(DDumpFont.ui(12, weight: .medium))
                .foregroundColor(.ddumpFG2)
                .fixedSize(horizontal: false, vertical: true)
              Spacer(minLength: 0)
            }
            .padding(10)
            .background(
              RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.ddumpSurface2)
            )
            .overlay(
              RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.ddumpLine1, lineWidth: 1)
            )
          }
          }

          sectionHeader("Offline resume")
          VStack(alignment: .leading, spacing: 12) {
          Toggle("Auto-retry pending uploads when internet reconnects", isOn: $networkResumeEnabled)
            .toggleStyle(.switch)
            .tint(.ddumpPeach)
            .ddumpOnChange(of: networkResumeEnabled) { v in
              state.set("NETWORK_RESUME_ENABLED", v ? "1" : "0")
            }
          HStack {
            Text("Reconnect check interval (seconds)")
              .foregroundColor(.ddumpFG2)
            Spacer()
            TextField("20", text: $networkResumeCheckSeconds)
              .frame(width: 90)
              .multilineTextAlignment(.trailing)
              .textFieldStyle(.roundedBorder)
              .onSubmit { state.set("NETWORK_RESUME_CHECK_SECONDS", networkResumeCheckSeconds) }
          }
          HStack {
            Text("Retry cooldown (seconds)")
              .foregroundColor(.ddumpFG2)
            Spacer()
            TextField("120", text: $networkResumeCooldownSeconds)
              .frame(width: 90)
              .multilineTextAlignment(.trailing)
              .textFieldStyle(.roundedBorder)
              .onSubmit { state.set("NETWORK_RESUME_COOLDOWN_SECONDS", networkResumeCooldownSeconds) }
          }
          }
          .font(DDumpFont.ui(13))
          .padding(14)
          .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
              .fill(Color.ddumpSurface)
          )
          .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
              .stroke(Color.ddumpLine1, lineWidth: 1)
          )

          sectionHeader("Diagnostics")
          VStack(alignment: .leading, spacing: 10) {
          Text(state.cloudDiagnosticMessage.isEmpty ? "No diagnostic message yet." : state.cloudDiagnosticMessage)
            .font(.system(size: 12, weight: .regular, design: .monospaced))
            .foregroundColor(.ddumpFG2)
            .textSelection(.enabled)
          Button {
            state.refreshCloudMountStatus(showProgress: true)
          } label: {
            Label("Run diagnostics now", systemImage: "stethoscope")
          }
          .buttonStyle(DDumpSecondaryButtonStyle())
          }
          .padding(14)
          .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
              .fill(Color.ddumpSurface2)
          )
          .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
              .stroke(Color.ddumpLine1, lineWidth: 1)
          )

          HStack(alignment: .top, spacing: 10) {
          InfoHint(text: "These steps are for installing DDump on another Mac and approving macOS folder permissions when needed.")
          VStack(alignment: .leading, spacing: 3) {
            Text("Friend install flow")
              .font(DDumpFont.ui(13, weight: .semibold))
              .foregroundColor(.ddumpFG1)
            Text("Run installer, open Cloud setup, follow the one-button guided steps, and wait for the upload-folder test to pass.")
              .font(DDumpFont.ui(12))
              .foregroundColor(.ddumpFG2)
            Text("macOS requires you to allow network-volume access once per app identity. There is no system-level ‘approve all’ button.")
              .font(DDumpFont.ui(12))
              .foregroundColor(.ddumpFG3)
          }
          }
          .padding(12)
          .background(Color.ddumpBGAlt)
          .overlay(alignment: .top) {
            Rectangle().fill(Color.ddumpLine1).frame(height: 1)
          }
        }
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 14)
    }
    .background(Color.ddumpBG)
    .onAppear {
      enabled = state.cloudUploadsEnabledForUI
      managedMountEnabled = state.gdriveMountEnabledForUI
      mountPoint = state.get("GDRIVE_MOUNT_POINT", default: "\(NSHomeDirectory())/GoogleDrive")
      remote = state.get("GDRIVE_REMOTE", default: "combined:")
      rcloneBin = state.get("RCLONE_BIN", default: "\(NSHomeDirectory())/bin/rclone")
      mountLabel = state.get("GDRIVE_MOUNT_LABEL", default: "com.ddump.rclone-gdrive")
      networkResumeEnabled = state.get("NETWORK_RESUME_ENABLED", default: "1") == "1"
      networkResumeCheckSeconds = state.get("NETWORK_RESUME_CHECK_SECONDS", default: "20")
      networkResumeCooldownSeconds = state.get("NETWORK_RESUME_COOLDOWN_SECONDS", default: "120")
      state.refreshCloudMountStatus()
    }
    .sheet(isPresented: $showSetupGuide) {
      CloudSetupGuideSheet(isPresented: $showSetupGuide)
        .environmentObject(state)
        .preferredColorScheme(state.preferredColorScheme())
    }
  }
}

struct CloudSetupGuideSheet: View {
  @EnvironmentObject var state: AppState
  @Binding var isPresented: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Text("Cloud setup")
          .font(DDumpFont.display(22, weight: .semibold))
          .foregroundColor(.ddumpFG1)
        Spacer()
        Button("Dismiss") { isPresented = false }
          .buttonStyle(DDumpSecondaryButtonStyle())
      }

      Text("Follow these steps in order:")
        .font(DDumpFont.ui(13, weight: .medium))
        .foregroundColor(.ddumpFG2)

      VStack(alignment: .leading, spacing: 8) {
        Text("1. Install the cloud helper")
        Text("2. Connect Google Drive")
        Text("3. Choose the Google Drive upload folder")
        Text("4. Let DDump test the upload folder")
      }
      .font(DDumpFont.ui(12))
      .foregroundColor(.ddumpFG2)

      HStack(spacing: 10) {
        Button {
          state.installRcloneViaApp()
        } label: {
          Label("Install cloud helper", systemImage: "square.and.arrow.down")
        }
        .buttonStyle(DDumpPrimaryButtonStyle())

        Button {
          state.launchCloudSetupInBrowser()
        } label: {
          Label("Connect Google Drive", systemImage: "globe")
        }
        .buttonStyle(DDumpSecondaryButtonStyle())
      }

      HStack(spacing: 10) {
        Button {
          state.finishCloudSetupFromBrowser()
        } label: {
          Label("Check Google Drive", systemImage: "checkmark.circle")
        }
        .buttonStyle(DDumpPrimaryButtonStyle())

        Button {
          state.chooseCloudDestinationFolder()
        } label: {
          Label("Choose upload folder", systemImage: "folder.badge.plus")
        }
        .buttonStyle(DDumpSecondaryButtonStyle())

        Button {
          state.testCloudUploadConnection(showProgress: true)
        } label: {
          Label("Test upload folder", systemImage: "checkmark.seal")
        }
        .buttonStyle(DDumpSecondaryButtonStyle())

        Button {
          state.stopCloudSetupInBrowser()
        } label: {
          Label("Cancel sign-in", systemImage: "xmark.circle")
        }
        .buttonStyle(DDumpSecondaryButtonStyle())
      }

      if !state.lastUtilityMessage.isEmpty {
        Text(state.lastUtilityMessage)
          .font(DDumpFont.ui(12))
          .foregroundColor(.ddumpFG3)
      }

      Spacer()
    }
    .padding(18)
    .frame(minWidth: 680, minHeight: 320)
    .background(Color.ddumpBG)
  }
}

struct CalendarSettings: View {
  @EnvironmentObject var state: AppState
  @State private var provider: String = "none"
  @State private var calendarName: String = ""
  @State private var calendarID: String = ""
  @State private var icsURL: String = ""
  @State private var padding: String = "15"
  @State private var ambiguityPromptsEnabled: Bool = true

  var body: some View {
    Form {
      Section("Calendar wizard") {
        Text("Calendar naming can use Apple Calendar, Google Calendar, or a private calendar link. Apple Calendar is the recommended public/offline option because it reads calendars already synced to this Mac and does not require Google API verification.")
          .font(.callout)
          .foregroundColor(.secondary)

        CalendarProviderRow(
          icon: "calendar",
          title: "Mac Calendar",
          detail: "Recommended. Uses the local macOS Calendar database after one permission prompt. Works with iCloud, Google, Exchange, and subscribed calendars already synced to this Mac.",
          selected: provider == "apple",
          status: provider == "apple" ? state.get("CALENDAR_AUTH_STATUS", default: "not_authorized") : "",
          primaryAction: {
          provider = "apple"
          state.connectAppleCalendar()
          },
          secondaryAction: nil
        )

        CalendarProviderRow(
          icon: "g.circle",
          title: "Google Calendar",
          detail: "Optional direct Google Calendar authorization. Useful if the Mac Calendar app is not synced, but public distribution may require Google OAuth verification.",
          selected: provider == "google",
          status: provider == "google" ? state.get("CALENDAR_AUTH_STATUS", default: "not_authorized") : ""
        ) {
          provider = "google"
          state.set("CALENDAR_PROVIDER", "google")
          state.connectGoogleCalendar()
        } secondaryAction: {
          state.checkGoogleCalendarConnection()
        }

        CalendarProviderRow(
          icon: "link",
          title: "Calendar Link",
          detail: "Paste a private ICS or webcal link. Read-only and simple, but provider sync may be delayed.",
          selected: provider == "ics",
          status: provider == "ics" ? state.get("CALENDAR_AUTH_STATUS", default: "not_authorized") : "",
          primaryAction: {
          provider = "ics"
          state.set("CALENDAR_PROVIDER", "ics")
          state.set("CALENDAR_AUTH_STATUS", icsURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "not_authorized" : "pending")
          },
          secondaryAction: nil
        )
      }

      if provider == "ics" {
        Section("Calendar link") {
          TextField("Private ICS or webcal link", text: $icsURL, onCommit: {
            state.set("CALENDAR_ICS_URL", icsURL)
          })
          HStack {
            Button {
              state.validateCalendarLink(icsURL)
            } label: {
              Label("Connect calendar link", systemImage: "checkmark.circle")
            }
            .buttonStyle(DDumpPrimaryButtonStyle())
            Spacer()
          }
        }
      }

      Section("Calendar matching") {
        if provider == "apple" {
          HStack {
            Text("Calendar to use")
            Spacer()
            Picker("", selection: $calendarID) {
              Text("All calendars").tag("")
              ForEach(state.appleCalendars) { calendar in
                Text(calendar.displayName).tag(calendar.id)
              }
            }
            .labelsHidden()
            .frame(width: 300)
          }
          .ddumpOnChange(of: calendarID) { v in
            state.set("CALENDAR_IDS", v)
            state.set("CALENDAR_NAME", "")
            state.refreshAppleCalendarCache(showDialog: false)
          }
          Text("Pick the calendar that contains real shoot names. Shared schedules may expose private events as Busy, so they should not be used for naming.")
            .font(.caption)
            .foregroundColor(.secondary)
        } else {
          TextField("Calendar name filter (optional)", text: $calendarName, onCommit: {
            state.set("CALENDAR_NAME", calendarName)
          })
        }
        HStack {
          Text("Event window padding (minutes each side)")
          Spacer()
          TextField("15", text: $padding)
            .frame(width: 80)
            .multilineTextAlignment(.trailing)
            .onSubmit { state.set("CALENDAR_EVENT_PADDING_MIN", padding) }
        }
        HStack {
          Button {
            state.refreshAppleCalendarCache()
          } label: {
            Label("Refresh Mac Calendar events", systemImage: "arrow.clockwise")
          }
          .buttonStyle(DDumpSecondaryButtonStyle())
          .disabled(provider != "apple")
          Spacer()
        }
        Toggle("Ask about clusters outside calendar events", isOn: $ambiguityPromptsEnabled)
          .ddumpOnChange(of: ambiguityPromptsEnabled) { v in
            state.set("CALENDAR_AMBIGUITY_PROMPTS_ENABLED", v ? "1" : "0")
          }
      }

      Section("Pending questions") {
        Text("When a capture-time cluster falls between scheduled shoots, DDump will hold a simple question on the main screen: previous shoot, next shoot, or Other. Choosing an answer will rename/move the destination folder automatically.")
          .font(.caption)
          .foregroundColor(.secondary)
      }

      Section("Status") {
        HStack {
          Text("Selected provider")
          Spacer()
          Text(providerLabel(provider))
            .foregroundColor(.secondary)
        }
        HStack {
          Text("Connection")
          Spacer()
          Text(statusLabel(state.get("CALENDAR_AUTH_STATUS", default: "not_authorized")))
            .foregroundColor(statusColor(state.get("CALENDAR_AUTH_STATUS", default: "not_authorized")))
        }
        if !state.lastUtilityMessage.isEmpty {
          Text(state.lastUtilityMessage)
            .font(.caption)
            .foregroundColor(.secondary)
        }
      }
    }
    .formStyle(.grouped)
    .ddumpFormSkin()
    .onAppear {
      provider = state.get("CALENDAR_PROVIDER", default: "none")
      calendarName = state.get("CALENDAR_NAME")
      calendarID = state.get("CALENDAR_IDS")
      icsURL = state.get("CALENDAR_ICS_URL")
      padding = state.get("CALENDAR_EVENT_PADDING_MIN", default: "15")
      ambiguityPromptsEnabled = state.get("CALENDAR_AMBIGUITY_PROMPTS_ENABLED", default: "1") == "1"
      if provider == "apple" {
        state.refreshAvailableAppleCalendars()
      }
    }
  }

  private func providerLabel(_ raw: String) -> String {
    switch raw {
    case "google": return "Google Calendar"
    case "apple": return "Apple Calendar"
    case "ics": return "Calendar Link"
    default: return "Not connected"
    }
  }

  private func statusLabel(_ raw: String) -> String {
    switch raw {
    case "authorized": return "Connected"
    case "pending": return "Waiting"
    case "missing_helper": return "Helper needed"
    case "not_authorized": return "Not connected"
    default: return raw.isEmpty ? "Not connected" : raw
    }
  }

  private func statusColor(_ raw: String) -> Color {
    switch raw {
    case "authorized": return .green
    case "pending": return .ddumpPeach
    default: return .secondary
    }
  }
}

struct CalendarProviderRow: View {
  let icon: String
  let title: String
  let detail: String
  let selected: Bool
  let status: String
  let primaryAction: () -> Void
  let secondaryAction: (() -> Void)?

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .top, spacing: 12) {
        Image(systemName: selected ? "checkmark.circle.fill" : icon)
          .font(.system(size: 20, weight: .semibold))
          .foregroundColor(selected ? .green : .ddumpPeach)
          .frame(width: 24)
        VStack(alignment: .leading, spacing: 4) {
          HStack {
            Text(title)
              .font(DDumpFont.ui(13, weight: .semibold))
            Spacer()
            if selected && !status.isEmpty {
              Text(shortStatus(status))
                .font(DDumpFont.ui(11, weight: .semibold))
                .foregroundColor(status == "authorized" ? .green : .ddumpPeach)
            }
          }
          Text(detail)
            .font(DDumpFont.ui(12))
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      HStack {
        if selected {
          Button {
            primaryAction()
          } label: {
            Label("Reconnect", systemImage: "arrow.right.circle")
          }
          .buttonStyle(DDumpSecondaryButtonStyle())
        } else {
          Button {
            primaryAction()
          } label: {
            Label("Connect", systemImage: "arrow.right.circle")
          }
          .buttonStyle(DDumpPrimaryButtonStyle())
        }
        if let secondaryAction {
          Button {
            secondaryAction()
          } label: {
            Label("Check connection", systemImage: "arrow.clockwise")
          }
          .buttonStyle(DDumpSecondaryButtonStyle())
        }
        Spacer()
      }
    }
    .padding(.vertical, 4)
  }

  private func shortStatus(_ raw: String) -> String {
    switch raw {
    case "authorized": return "Connected"
    case "pending": return "Waiting"
    case "missing_helper": return "Helper needed"
    default: return "Not connected"
    }
  }
}

func pickFolder(prompt: String) -> String? {
  let panel = NSOpenPanel()
  panel.canChooseDirectories = true
  panel.canChooseFiles = false
  panel.allowsMultipleSelection = false
  panel.prompt = prompt
  return panel.runModal() == .OK ? panel.url?.path : nil
}

// MARK: - Window frame persistence

func configuredWindowRestoreMode() -> String {
  let mode = readShellEnv(at: DDumpPaths.configFile)["WINDOW_RESTORE_MODE"] ?? "remember"
  switch mode {
  case "compact", "large", "remember": return mode
  default: return "remember"
  }
}

func applyConfiguredWindowMode(_ window: NSWindow) {
  let mode = configuredWindowRestoreMode()
  switch mode {
  case "compact":
    window.setFrameAutosaveName("")
    window.setContentSize(NSSize(width: 720, height: 620))
    window.center()
  case "large":
    window.setFrameAutosaveName("")
    window.setContentSize(NSSize(width: 980, height: 820))
    window.center()
  default:
    window.setFrameAutosaveName("DDumpMainWindow")
  }
}

/// AppDelegate that assigns a frameAutosaveName to the main window so macOS
/// remembers its position/size across launches.
class WindowMemoryDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
  weak var appState: AppState?

  func applicationDidFinishLaunching(_ notification: Notification) {
    UNUserNotificationCenter.current().delegate = self
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
      for window in NSApplication.shared.windows {
        // SwiftUI Settings scenes create separate windows; tag the main one only
        if window.title == "DDump" || window.contentViewController is NSHostingController<AnyView> {
          applyConfiguredWindowMode(window)
        }
        if window.title == "DDump" {
          applyConfiguredWindowMode(window)
        }
      }
    }
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    if appState?.get("MACOS_NOTIFICATIONS_ENABLED", default: "1") == "1" {
      completionHandler([.banner, .sound])
    } else {
      completionHandler([])
    }
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if !flag {
      for window in sender.windows where window.title == "DDump" {
        window.makeKeyAndOrderFront(nil)
      }
    }
    return true
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let state = appState else {
      return .terminateNow
    }
    if !state.shouldWarnBeforeQuit {
      return .terminateNow
    }

    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "A transfer is still running"
    let pendingText = state.pendingUploadCount > 0 ? "\(state.pendingUploadCount) pending upload batch(es)." : "No pending upload batches."
    let missingText = state.needsReinsertCount > 0 ? "\(state.needsReinsertCount) file(s) currently marked missing." : "No files currently marked missing."
    alert.informativeText = "Current phase: \(state.phase).\n\(pendingText)\n\(missingText)\n\nQuit DDump anyway?"
    alert.addButton(withTitle: "Quit Anyway")
    alert.addButton(withTitle: "Cancel")
    let response = alert.runModal()
    return response == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
  }

  func applicationWillTerminate(_ notification: Notification) {
    try? FileManager.default.removeItem(at: DDumpPaths.appCloudKeepaliveFile)
  }
}

// MARK: - App entry point

@main
struct DDumpApp: App {
  @NSApplicationDelegateAdaptor(WindowMemoryDelegate.self) var appDelegate
  @StateObject private var state = AppState()

  init() {
    registerBundledFonts()
  }

  var body: some Scene {
    WindowGroup("DDump") {
      ContentView()
        .environmentObject(state)
        .background(WindowAccessor())
        .preferredColorScheme(state.preferredColorScheme())
        .onAppear {
          appDelegate.appState = state
        }
    }
    // Settings are opened through ContentView's sheet. The native Settings scene
    // was unreliable on this Mac and created a competing Cmd+, path.
  }
}

/// Tags the SwiftUI window with a frame autosave name so the OS remembers
/// its position + size across launches. Adapted from the standard
/// NSViewRepresentable bridge pattern.
struct WindowAccessor: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView {
    let v = NSView()
    DispatchQueue.main.async {
      if let window = v.window {
        applyConfiguredWindowMode(window)
      }
    }
    return v
  }
  func updateNSView(_ nsView: NSView, context: Context) {}
}
