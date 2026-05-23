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
  static var iconLibraryDir: URL { appSupport.appendingPathComponent("icons") }
  static var iconPresetManifest: URL { iconLibraryDir.appendingPathComponent("presets.json") }
  static var scriptFile: URL { appSupport.appendingPathComponent("bin/ddump.sh") }
  static var controlDir: URL { appSupport.appendingPathComponent("state/control") }
  static var manualSelectionFile: URL { appSupport.appendingPathComponent("state/manual_selection.paths") }
  static var lockDir: URL { appSupport.appendingPathComponent("state/run.lock") }
  static var pauseFlag: URL { controlDir.appendingPathComponent("pause.flag") }
  static var stopFlag: URL { controlDir.appendingPathComponent("stop_after_file.flag") }
  static var keepMountedFlag: URL { controlDir.appendingPathComponent("keep_mounted.flag") }
  static var ejectNowFlag: URL { controlDir.appendingPathComponent("eject_now.flag") }
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

final class AppState: ObservableObject {
  @Published var phase: String = "idle"
  @Published var message: String = "Waiting for a card…"
  @Published var volume: String = ""
  @Published var total: Int = 0
  @Published var processed: Int = 0
  @Published var imported: Int = 0
  @Published var skipped: Int = 0
  @Published var failed: Int = 0
  @Published var startedEpoch: TimeInterval = 0
  @Published var updatedAt: String = ""
  @Published var config: [String: String] = [:]
  @Published var paused: Bool = false
  @Published var stopRequested: Bool = false
  @Published var ejectQueued: Bool = false
  @Published var keepMountedRequested: Bool = false
  @Published var runActive: Bool = false
  @Published var pendingUploadCount: Int = 0
  @Published var localFreeGB: Int = 0
  @Published var stagingFolderCount: Int = 0
  @Published var lastUtilityMessage: String = ""
  @Published var cloudMountActive: Bool = false
  @Published var cloudServiceLoaded: Bool = false
  @Published var cloudRcloneReady: Bool = false
  @Published var cloudRemoteConfigured: Bool = false
  @Published var cloudDiagnosticMessage: String = ""

  private var timer: Timer?
  private var mountKeepaliveTimer: Timer?
  private var statusTick: Int = 0

  deinit {
    timer?.invalidate()
    mountKeepaliveTimer?.invalidate()
  }

  init() {
    refreshStatus()
    refreshConfig()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
      self?.ensureUploadServerForAppSession()
    }
    timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
      self?.refreshStatus()
      self?.refreshControlFlags()
      self?.refreshLockState()
      self?.refreshHealth()
      self?.statusTick += 1
      if (self?.statusTick ?? 0) % 5 == 0 {
        self?.refreshCloudMountStatus()
      }
    }
    // Keep Google Drive mounted while the DDump app is open.
    // When DDump closes, this refresh stops and finderserver's normal timer can unmount.
    mountKeepaliveTimer = Timer.scheduledTimer(withTimeInterval: 300.0, repeats: true) { [weak self] _ in
      self?.ensureUploadServerForAppSession()
    }
    refreshCloudMountStatus()
  }

  func refreshStatus() {
    let parsed = readShellEnv(at: DDumpPaths.statusFile)
    DispatchQueue.main.async {
      self.phase = parsed["phase"] ?? "idle"
      self.message = parsed["message"] ?? "Waiting for a card…"
      self.volume = parsed["volume"] ?? ""
      self.total = Int(parsed["total"] ?? "0") ?? 0
      self.processed = Int(parsed["processed"] ?? "0") ?? 0
      self.imported = Int(parsed["imported"] ?? "0") ?? 0
      self.skipped = Int(parsed["skipped"] ?? "0") ?? 0
      self.failed = Int(parsed["failed"] ?? "0") ?? 0
      self.startedEpoch = TimeInterval(parsed["started_epoch"] ?? "0") ?? 0
      self.updatedAt = parsed["updated_at"] ?? ""
    }
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
    let s = fm.fileExists(atPath: DDumpPaths.stopFlag.path)
    let e = fm.fileExists(atPath: DDumpPaths.ejectNowFlag.path)
    let k = fm.fileExists(atPath: DDumpPaths.keepMountedFlag.path)
    DispatchQueue.main.async {
      self.paused = p
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

    DispatchQueue.main.async {
      self.pendingUploadCount = pending
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

  var uploadRootForUI: String {
    if get("FOLDER_NAMING_STRATEGY", default: "cluster") == "smart" {
      let sample = get("SMART_SAMPLE_PATH")
      let pattern = #"^(.+)/[0-9]{4}/[0-9]{4}\.[0-9]{2}/[0-9]{4}\.[0-9]{2}\.[0-9]{2}(/.*)?$"#
      if let regex = try? NSRegularExpression(pattern: pattern),
         let match = regex.firstMatch(in: sample, range: NSRange(sample.startIndex..., in: sample)),
         let range = Range(match.range(at: 1), in: sample) {
        return String(sample[range])
      }
    }
    return get("POST_MOVE_ROOT", default: "\(NSHomeDirectory())/Temp")
  }

  var gdriveMountEnabledForUI: Bool {
    return self.get("GDRIVE_MOUNT_ENABLED", default: "1") == "1"
  }

  var gdriveMountPointForUI: String {
    return self.get("GDRIVE_MOUNT_POINT", default: "\(NSHomeDirectory())/GoogleDrive")
  }

  var gdriveMountLabelForUI: String {
    return self.get("GDRIVE_MOUNT_LABEL", default: "com.ddump.rclone-gdrive")
  }

  var gdriveRemoteForUI: String {
    return self.get("GDRIVE_REMOTE", default: "combined:")
  }

  var rcloneBinForUI: String {
    return self.get("RCLONE_BIN", default: "\(NSHomeDirectory())/bin/rclone")
  }

  func pathUsesGDriveMount(_ path: String) -> Bool {
    let expandedMount = NSString(string: gdriveMountPointForUI).expandingTildeInPath
      .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let expandedPath = NSString(string: path).expandingTildeInPath
      .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    return expandedPath == expandedMount || expandedPath.hasPrefix(expandedMount + "/")
  }

  func set(_ key: String, _ value: String) {
    config[key] = value
    writeShellConfig(key: key, value: value, at: DDumpPaths.configFile)
  }

  var progressFraction: Double {
    total > 0 ? Double(processed) / Double(total) : 0
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

  func retryPendingUploads() {
    guard FileManager.default.fileExists(atPath: DDumpPaths.scriptFile.path) else {
      lastUtilityMessage = "DDump script not installed."
      return
    }
    let task = Process()
    task.launchPath = "/bin/bash"
    task.arguments = [DDumpPaths.scriptFile.path]
    do {
      try task.run()
      lastUtilityMessage = "Retry started. DDump will upload pending folders first."
    } catch {
      lastUtilityMessage = "Could not start retry: \(error.localizedDescription)"
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

  func ensureUploadServerForAppSession() {
    guard gdriveMountEnabledForUI else { return }
    guard pathUsesGDriveMount(uploadRootForUI) else { return }
    startCloudMount(userMessagePrefix: "Upload server")
  }

  func startCloudMount(userMessagePrefix: String = "Cloud mount") {
    let mountPoint = gdriveMountPointForUI
    let mountLabel = gdriveMountLabelForUI
    let retryCSV = get("GDRIVE_MOUNT_RETRY_SECONDS", default: "5,15,60,180,360,600")
    let waitSeconds = get("GDRIVE_MOUNT_WAIT_SECONDS", default: "30")
    DispatchQueue.global(qos: .utility).async {
      let task = Process()
      task.launchPath = "/bin/bash"
      task.arguments = ["-lc", """
mount_point=\(shellDoubleQuoted(mountPoint))
mount_label=\(shellDoubleQuoted(mountLabel))
retry_csv=\(shellDoubleQuoted(retryCSV))
wait_seconds=\(shellDoubleQuoted(waitSeconds))
legacy_label="com.chase.rclone-gdrive"
lock_dir="${HOME}/Library/Application Support/DDump/state/cloud-mount-start.lock"
if ! [[ "$wait_seconds" =~ ^[0-9]+$ ]]; then wait_seconds=30; fi
if [ "$wait_seconds" -lt 10 ]; then wait_seconds=10; fi
if /sbin/mount | /usr/bin/grep -q " on ${mount_point} "; then
  exit 0
fi
if [ -x "${HOME}/.local/bin/finderserver" ]; then
  "${HOME}/.local/bin/finderserver" on >/dev/null 2>&1 || true
fi
uid="$(/usr/bin/id -u)"
plist="${HOME}/Library/LaunchAgents/${mount_label}.plist"
/bin/mkdir -p "${mount_point}"
 /bin/mkdir -p "${HOME}/Library/Application Support/DDump/state"
if ! /bin/mkdir "${lock_dir}" >/dev/null 2>&1; then
  # Another mount worker is already trying. Avoid parallel retries.
  exit 0
fi
cleanup_lock() { /bin/rmdir "${lock_dir}" >/dev/null 2>&1 || true; }
trap cleanup_lock EXIT

if [ ! -f "$plist" ] && [ -f "${HOME}/Library/LaunchAgents/${legacy_label}.plist" ]; then
  mount_label="$legacy_label"
  plist="${HOME}/Library/LaunchAgents/${mount_label}.plist"
fi
if [ ! -f "$plist" ]; then
  exit 1
fi

attempt_mount() {
  if /bin/launchctl print "gui/${uid}/${mount_label}" >/dev/null 2>&1 \
     && ! /sbin/mount | /usr/bin/grep -q " on ${mount_point} "; then
    # Clear any stale scheduled/running agent before retrying.
    /bin/launchctl bootout "gui/${uid}/${mount_label}" >/dev/null 2>&1 || true
  fi
  /bin/launchctl bootstrap "gui/${uid}" "$plist" >/dev/null 2>&1 || true
  /bin/launchctl kickstart -k "gui/${uid}/${mount_label}" >/dev/null 2>&1 || true
  i=0
  while [ "$i" -lt "$wait_seconds" ]; do
    if /sbin/mount | /usr/bin/grep -q " on ${mount_point} "; then
      return 0
    fi
    /bin/sleep 1
    i=$((i+1))
  done
  return 1
}

if attempt_mount; then
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
    exit 0
  fi
done
exit 1
"""]
      do {
        try task.run()
      } catch {
        DispatchQueue.main.async {
          self.lastUtilityMessage = "Could not start cloud mount: \(error.localizedDescription)"
        }
        return
      }
      task.waitUntilExit()
      DispatchQueue.main.async {
        if task.terminationStatus == 0 {
          self.lastUtilityMessage = "\(userMessagePrefix) is on and ready."
        } else {
          self.lastUtilityMessage = "\(userMessagePrefix) did not become ready."
        }
        self.refreshCloudMountStatus()
      }
    }
  }

  func hardRestartCloudMount() {
    let mountPoint = gdriveMountPointForUI
    let mountLabel = gdriveMountLabelForUI
    DispatchQueue.global(qos: .utility).async {
      let task = Process()
      task.launchPath = "/bin/bash"
      task.arguments = ["-lc", """
mount_point=\(shellDoubleQuoted(mountPoint))
mount_label=\(shellDoubleQuoted(mountLabel))
legacy_label="com.chase.rclone-gdrive"
uid="$(/usr/bin/id -u)"
plist="${HOME}/Library/LaunchAgents/${mount_label}.plist"
if [ ! -f "$plist" ] && [ -f "${HOME}/Library/LaunchAgents/${legacy_label}.plist" ]; then
  mount_label="$legacy_label"
  plist="${HOME}/Library/LaunchAgents/${mount_label}.plist"
fi
if [ -x "${HOME}/.local/bin/finderserver" ]; then
  "${HOME}/.local/bin/finderserver" on >/dev/null 2>&1 || true
fi
if /sbin/mount | /usr/bin/grep -q " on ${mount_point} "; then
  /usr/sbin/diskutil unmount force "${mount_point}" >/dev/null 2>&1 || /sbin/umount -f "${mount_point}" >/dev/null 2>&1 || true
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
          self.lastUtilityMessage = "Could not hard-restart cloud mount: \(error.localizedDescription)"
        }
        return
      }
      task.waitUntilExit()
      DispatchQueue.main.async {
        self.lastUtilityMessage = "Hard restart requested. Retrying mount..."
        self.startCloudMount(userMessagePrefix: "Cloud hard restart")
      }
    }
  }

  func stopCloudMount() {
    let mountPoint = gdriveMountPointForUI
    let mountLabel = gdriveMountLabelForUI
    DispatchQueue.global(qos: .utility).async {
      let task = Process()
      task.launchPath = "/bin/bash"
      task.arguments = ["-lc", """
mount_point=\(shellDoubleQuoted(mountPoint))
mount_label=\(shellDoubleQuoted(mountLabel))
legacy_label="com.chase.rclone-gdrive"
uid="$(/usr/bin/id -u)"
if /sbin/mount | /usr/bin/grep -q " on ${mount_point} "; then
  /usr/sbin/diskutil unmount "${mount_point}" >/dev/null 2>&1 || /sbin/umount -f "${mount_point}" >/dev/null 2>&1 || true
fi
/bin/launchctl bootout "gui/${uid}/${mount_label}" >/dev/null 2>&1 || true
/bin/launchctl bootout "gui/${uid}/${legacy_label}" >/dev/null 2>&1 || true
exit 0
"""]
      do {
        try task.run()
      } catch {
        DispatchQueue.main.async {
          self.lastUtilityMessage = "Could not stop cloud mount: \(error.localizedDescription)"
        }
        return
      }
      task.waitUntilExit()
      DispatchQueue.main.async {
        self.lastUtilityMessage = "Cloud mount stop requested."
        self.refreshCloudMountStatus()
      }
    }
  }

  func refreshCloudMountStatus() {
    let mountPoint = gdriveMountPointForUI
    let mountLabel = gdriveMountLabelForUI
    let remote = gdriveRemoteForUI
    let rcloneBin = rcloneBinForUI
    DispatchQueue.global(qos: .utility).async {
      let task = Process()
      task.launchPath = "/bin/bash"
      task.arguments = ["-lc", """
set +e
mount_point=\(shellDoubleQuoted(mountPoint))
mount_label=\(shellDoubleQuoted(mountLabel))
remote=\(shellDoubleQuoted(remote))
rclone_bin=\(shellDoubleQuoted(rcloneBin))

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
  remote_name="${remote%%:*}:"
  if "$rclone" listremotes 2>/dev/null | /usr/bin/grep -Fxq "$remote_name"; then
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
fi

if /sbin/mount | /usr/bin/grep -q " on ${mount_point} "; then
  mount_active=1
  echo "mount_active=1"
else
  mount_active=0
  echo "mount_active=0"
fi

uid="$(/usr/bin/id -u)"
if /bin/launchctl print "gui/${uid}/${mount_label}" >/dev/null 2>&1; then
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
elif [ "${service_loaded:-0}" = "0" ]; then
  diag="mount service is not loaded"
elif [ "${mount_active:-0}" = "0" ]; then
  last_log="$(tail -n 1 "${HOME}/Library/Application Support/DDump/logs/rclone-gdrive.log" 2>/dev/null || true)"
  if [ -n "$last_log" ]; then
    diag="service running but mount inactive; last mount log: ${last_log}"
  else
    diag="service running but mount inactive"
  fi
else
  diag="mount active and ready"
fi
echo "diag_reason=$diag"
"""]
      let pipe = Pipe()
      task.standardOutput = pipe
      task.standardError = Pipe()
      do {
        try task.run()
      } catch {
        return
      }
      task.waitUntilExit()
      let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
      let parsed = parseShellEnv(out)
      DispatchQueue.main.async {
        self.cloudMountActive = parsed["mount_active"] == "1"
        self.cloudServiceLoaded = parsed["service_loaded"] == "1"
        self.cloudRcloneReady = parsed["rclone_ready"] == "1"
        self.cloudRemoteConfigured = parsed["remote_configured"] == "1"
        self.cloudDiagnosticMessage = parsed["diag_reason"] ?? ""
      }
    }
  }

  func openRcloneSetupInTerminal() {
    let mountRemote = gdriveRemoteForUI
    let remoteName = mountRemote.split(separator: ":").first.map(String.init) ?? "combined"
    let cmd = "if command -v rclone >/dev/null 2>&1; then rclone config reconnect \(remoteName): || rclone config; else echo 'rclone not found'; fi"
    let task = Process()
    task.launchPath = "/usr/bin/osascript"
    task.arguments = [
      "-e",
      "tell application \"Terminal\" to do script \(shellDoubleQuoted(cmd))"
    ]
    do {
      try task.run()
      lastUtilityMessage = "Opened Terminal for rclone setup."
    } catch {
      lastUtilityMessage = "Could not open Terminal for rclone setup."
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
    panel.canChooseFiles = true
    panel.allowsMultipleSelection = true
    panel.canCreateDirectories = false
    panel.directoryURL = URL(fileURLWithPath: "/Volumes")
    panel.prompt = "Import Selected"
    panel.message = "Pick files or folders from a mounted card."
    guard panel.runModal() == .OK else { return }

    let selected = panel.urls.map(\.path).filter { !$0.isEmpty }
    guard !selected.isEmpty else {
      lastUtilityMessage = "No files or folders selected."
      return
    }

    do {
      try FileManager.default.createDirectory(
        at: DDumpPaths.controlDir, withIntermediateDirectories: true)
      let payload = selected.joined(separator: "\n") + "\n"
      try payload.write(to: DDumpPaths.manualSelectionFile, atomically: true, encoding: .utf8)
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
      lastUtilityMessage = "Manual import started for \(selected.count) selected item(s)."
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
  let expanded = NSString(string: path).expandingTildeInPath
  if FileManager.default.fileExists(atPath: expanded) {
    NSWorkspace.shared.open(URL(fileURLWithPath: expanded))
  } else {
    let alert = NSAlert()
    alert.messageText = "Folder not found"
    alert.informativeText = expanded
    alert.runModal()
  }
}

struct InfoHint: View {
  let text: String
  var body: some View {
    Image(systemName: "info.circle")
      .foregroundColor(.secondary)
      .help(text)
  }
}

// MARK: - Main window

struct ContentView: View {
  @EnvironmentObject var state: AppState
  @State private var showingSettings = false

  var phaseColor: Color {
    switch state.phase {
    case "importing", "scanning", "starting": return .blue
    case "complete": return .green
    case "stopped", "paused": return .orange
    default: return .secondary
    }
  }

  var phaseLabel: String {
    switch state.phase {
    case "starting": return "Preparing…"
    case "scanning": return "Scanning card"
    case "importing": return state.paused ? "Paused (will resume)" : "Importing"
    case "paused": return "Paused"
    case "stopped": return "Stopped"
    case "complete": return "Done"
    default: return state.runActive ? "Working…" : "Waiting"
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(spacing: 14) {
        Image(systemName: state.phase == "complete" ? "checkmark.seal.fill" : "camera.aperture")
          .font(.system(size: 38))
          .foregroundColor(phaseColor)
        VStack(alignment: .leading, spacing: 2) {
          Text("DDump").font(.title2).bold()
          Text(phaseLabel).foregroundColor(phaseColor)
        }
        Spacer()
        if !state.updatedAt.isEmpty && state.runActive {
          Text(state.updatedAt).font(.caption2).foregroundColor(.secondary)
        }
      }

      Divider()

      if !state.runActive && state.total == 0 {
        IdleView()
      } else {
        ProgressDetail()
      }

      RunChecklistPanel()

      HealthPanel()

      // Control buttons — always visible; disabled when no run active
      ControlBar()

      Spacer(minLength: 8)

      HStack(spacing: 12) {
        Button {
          showingSettings = true
        } label: {
          Label("Settings…", systemImage: "gearshape")
        }
        .keyboardShortcut(",", modifiers: .command)

        Spacer()

        Button {
          openInFinder(state.uploadRootForUI)
        } label: {
          Label("Open Uploads", systemImage: "folder")
        }

        Button {
          openInFinder(DDumpPaths.logFile.path)
        } label: {
          Label("Log", systemImage: "doc.text")
        }
      }
    }
    .padding(20)
    .frame(minWidth: 560, minHeight: 420)
    .sheet(isPresented: $showingSettings) {
      SettingsSheet(isPresented: $showingSettings)
        .environmentObject(state)
    }
  }
}

/// Settings presented as a sheet so it ALWAYS opens reliably across macOS versions
/// (independent of the auto-bound Settings scene which has quirks).
struct SettingsSheet: View {
  @Binding var isPresented: Bool
  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("Settings").font(.title2).bold()
        Spacer()
        Button("Done") { isPresented = false }
          .keyboardShortcut(.defaultAction)
      }
      .padding(.horizontal, 16)
      .padding(.top, 16)

      SettingsView()
        .padding(.top, 4)
    }
    .frame(minWidth: 620, minHeight: 460)
  }
}

struct ControlBar: View {
  @EnvironmentObject var state: AppState

  var body: some View {
    HStack(spacing: 10) {
      if state.paused {
        Button {
          state.resume()
        } label: {
          Label("Resume", systemImage: "play.fill")
        }
        .controlSize(.large)
        .keyboardShortcut("r", modifiers: .command)
      } else {
        Button {
          state.pause()
        } label: {
          Label("Pause", systemImage: "pause.fill")
        }
        .controlSize(.large)
        .keyboardShortcut("p", modifiers: .command)
        .disabled(!state.runActive)
      }

      Button {
        state.stop()
      } label: {
        Label("Stop after this file", systemImage: "stop.fill")
      }
      .controlSize(.large)
      .keyboardShortcut(".", modifiers: .command)
      .disabled(!state.runActive || state.stopRequested)

      Button {
        state.doNotEject()
      } label: {
        Label("Do Not Eject", systemImage: "pin.slash.fill")
      }
      .controlSize(.large)
      .disabled(!state.runActive)

      Button {
        state.ejectNow()
      } label: {
        Label("Eject after this file", systemImage: "eject.fill")
      }
      .controlSize(.large)
      .keyboardShortcut("e", modifiers: .command)
      .disabled(!state.runActive || state.ejectQueued)

      Spacer()

      if state.ejectQueued {
        Label("Eject queued", systemImage: "eject.circle")
          .foregroundColor(.orange)
          .font(.caption)
      } else if state.keepMountedRequested {
        Label("Will stay mounted", systemImage: "pin.slash.circle")
          .foregroundColor(.orange)
          .font(.caption)
      } else if state.stopRequested {
        Label("Stop queued", systemImage: "stop.circle")
          .foregroundColor(.orange)
          .font(.caption)
      }
    }
  }
}

struct IdleView: View {
  @EnvironmentObject var state: AppState

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Insert an SD card and DDump will:").foregroundColor(.secondary)
      VStack(alignment: .leading, spacing: 4) {
        Label("Detect photo files automatically (no DCIM required)", systemImage: "magnifyingglass")
        Label("Copy locally, verify size, optionally SHA-256", systemImage: "checkmark.shield")
        Label("Group by time clusters", systemImage: "rectangle.3.group")
        Label("Upload to Google Drive at your chosen path", systemImage: "icloud.and.arrow.up")
        Label("Auto-eject after current file (button) or 60-sec safety grace", systemImage: "eject")
      }
      .font(.callout)
      .foregroundColor(.primary)
      .padding(.leading, 8)

      Spacer().frame(height: 12)
      VStack(alignment: .leading, spacing: 2) {
        Text("Destination").font(.caption).foregroundColor(.secondary)
        Text(state.uploadRootForUI)
          .font(.callout)
          .lineLimit(2)
        Text("Naming: \(state.get("FOLDER_NAMING_STRATEGY", default: "cluster"))")
          .font(.caption).foregroundColor(.secondary)
      }
      .padding(.leading, 8)
    }
  }
}

struct HealthPanel: View {
  @EnvironmentObject var state: AppState

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 16) {
        Label("\(state.localFreeGB)GB free locally", systemImage: "internaldrive")
        Label("\(state.pendingUploadCount) pending upload\(state.pendingUploadCount == 1 ? "" : "s")", systemImage: "arrow.triangle.2.circlepath")
        Label("\(state.stagingFolderCount) staging folder\(state.stagingFolderCount == 1 ? "" : "s")", systemImage: "tray.full")
      }
      .font(.caption)
      .foregroundColor(.secondary)

      HStack(spacing: 10) {
        Button {
          state.retryPendingUploads()
        } label: {
          Label("Retry Pending Uploads", systemImage: "arrow.clockwise")
        }
        .disabled(state.pendingUploadCount == 0 || state.runActive)

        Button {
          openInFinder(state.get("DEST_ROOT", default: "\(NSHomeDirectory())/Temp"))
        } label: {
          Label("Staging", systemImage: "tray")
        }

        Button {
          openInFinder(DDumpPaths.reportsDir.path)
        } label: {
          Label("Receipts", systemImage: "doc.plaintext")
        }

        Button {
          state.cleanupOldStagingFolders()
        } label: {
          Label("Safe Cleanup", systemImage: "trash")
        }
        .disabled(state.runActive)

        Button {
          state.startManualSelectionImport()
        } label: {
          Label("Manual Select Import…", systemImage: "slider.horizontal.3")
        }
        .disabled(state.runActive)
      }
      .font(.caption)

      if !state.lastUtilityMessage.isEmpty {
        Text(state.lastUtilityMessage)
          .font(.caption2)
          .foregroundColor(.secondary)
      }
    }
    .padding(10)
    .background(Color(NSColor.controlBackgroundColor))
    .clipShape(RoundedRectangle(cornerRadius: 10))
  }
}

struct ProgressDetail: View {
  @EnvironmentObject var state: AppState

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(state.volume.isEmpty ? "Card" : state.volume).font(.headline)
      Text(state.message)
        .font(.caption)
        .foregroundColor(.secondary)
        .lineLimit(2)

      ProgressView(value: state.progressFraction)
        .progressViewStyle(.linear)

      HStack {
        Text("\(state.processed) / \(state.total) files")
        Spacer()
        Text("ETA \(formatETA(state.etaSeconds))")
        Spacer()
        Text("\(Int(state.progressFraction * 100))%").bold()
      }
      .font(.callout)
      .monospacedDigit()

      HStack(spacing: 24) {
        Label("\(state.imported) imported", systemImage: "checkmark.circle")
          .foregroundColor(.green)
        Label("\(state.skipped) skipped", systemImage: "arrow.right.circle")
          .foregroundColor(.secondary)
        if state.failed > 0 {
          Label("\(state.failed) failed", systemImage: "exclamationmark.triangle")
            .foregroundColor(.red)
        }
      }
      .font(.caption)
    }
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
    state.get("ENABLE_POST_EJECT_MOVE", default: "1") == "1"
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
    if step2State != .done {
      return .pending
    }
    if runFinished {
      let moveFail = summaryMetric("post_move_fail") ?? 0
      let moveBlocked = summaryMetric("post_move_blocked") ?? 0
      if moveFail == 0 && moveBlocked == 0 && state.pendingUploadCount == 0 {
        return .done
      }
      return .blocked
    }
    if state.runActive && state.imported > 0 {
      return .active
    }
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
    case .pending: return .secondary
    case .active: return .blue
    case .done: return .green
    case .blocked: return .orange
    }
  }

  private func row(_ title: String, step: StepState, linkTitle: String? = nil, linkPath: String? = nil) -> some View {
    HStack(spacing: 10) {
      Image(systemName: icon(for: step))
        .foregroundColor(color(for: step))
      Text(title)
        .foregroundColor(step == .done ? .green : .primary)
      Spacer()
      if let linkTitle, let linkPath, !linkPath.isEmpty {
        Button(linkTitle) {
          openInFinder(linkPath)
        }
        .buttonStyle(.link)
      }
    }
    .font(.callout)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Checklist").font(.headline)
      row("1. Transfer to staging folder", step: step1State, linkTitle: "Open staging", linkPath: state.get("DEST_ROOT", default: "\(NSHomeDirectory())/Temp"))
      row("2. Eject card", step: step2State)
      row("3. Transfer to destination folder", step: step3State, linkTitle: "Open destination", linkPath: state.uploadRootForUI)
      row("4. All complete!", step: step4State)
    }
    .padding(10)
    .background(Color(NSColor.controlBackgroundColor))
    .clipShape(RoundedRectangle(cornerRadius: 10))
  }
}

// MARK: - Settings

struct SettingsView: View {
  var body: some View {
    TabView {
      DestinationSettings()
        .tabItem { Label("Destination", systemImage: "folder") }
      NamingSettings()
        .tabItem { Label("Naming", systemImage: "textformat") }
      DetectionSettings()
        .tabItem { Label("Detection", systemImage: "camera") }
      CloudSettings()
        .tabItem { Label("Cloud", systemImage: "icloud") }
      CalendarSettings()
        .tabItem { Label("Calendar", systemImage: "calendar") }
      AppearanceSettings()
        .tabItem { Label("Appearance", systemImage: "paintbrush") }
    }
    .padding(16)
    .frame(minWidth: 560, minHeight: 380)
  }
}

struct DestinationSettings: View {
  @EnvironmentObject var state: AppState
  @State private var localStaging: String = ""
  @State private var enablePostMove: Bool = true
  @State private var uploadRoot: String = ""
  @State private var uploadRoots: String = ""
  @State private var fallbackRoot: String = ""

  var body: some View {
    Form {
      Section {
        Toggle("Enable transfer to destination folders", isOn: $enablePostMove)
          .onChange(of: enablePostMove) { _, v in
            state.set("ENABLE_POST_EJECT_MOVE", v ? "1" : "0")
          }
        TextField("Local staging folder", text: $localStaging, onCommit: {
          state.set("DEST_ROOT", localStaging)
        })
        TextField("Primary destination", text: $uploadRoot, onCommit: {
          state.set("POST_MOVE_ROOT", uploadRoot)
        })
        TextField("Additional destinations (comma-separated)", text: $uploadRoots, onCommit: {
          state.set("POST_MOVE_ROOTS", uploadRoots)
        })
        TextField("Fallback destination if primary is unavailable", text: $fallbackRoot, onCommit: {
          state.set("POST_MOVE_FALLBACK_ROOT", fallbackRoot)
        })
        HStack {
          Button("Browse local…") {
            if let picked = pickFolder(prompt: "Choose local staging folder") {
              localStaging = picked
              state.set("DEST_ROOT", picked)
            }
          }
          Button("Browse upload…") {
            if let picked = pickFolder(prompt: "Choose primary upload destination") {
              uploadRoot = picked
              state.set("POST_MOVE_ROOT", picked)
            }
          }
          Button("Browse fallback…") {
            if let picked = pickFolder(prompt: "Choose fallback destination") {
              fallbackRoot = picked
              state.set("POST_MOVE_FALLBACK_ROOT", picked)
            }
          }
        }
      } header: {
        Text("Folders")
      } footer: {
        Text("Files go: SD card → staging. Then DDump copies to the destination(s). Disable destination transfer to keep staging-only backups.")
          .font(.caption).foregroundColor(.secondary)
      }
    }
    .formStyle(.grouped)
    .onAppear {
      localStaging = state.get("DEST_ROOT", default: "\(NSHomeDirectory())/Temp")
      enablePostMove = state.get("ENABLE_POST_EJECT_MOVE", default: "1") == "1"
      uploadRoot = state.get("POST_MOVE_ROOT")
      uploadRoots = state.get("POST_MOVE_ROOTS")
      fallbackRoot = state.get("POST_MOVE_FALLBACK_ROOT")
    }
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
  @State private var smartAssignExisting: Bool = true
  @State private var splitPhotoVideo: Bool = false

  let strategies = ["sequential", "custom", "calendar", "smart", "camera"]

  var body: some View {
    Form {
      Section("Folder naming") {
        HStack(spacing: 6) {
          Text("Strategy")
          InfoHint(text: "Sequential: Shoot-1, Shoot-2. Custom: picks from your list. Calendar: event titles. Smart: infer from sample path. Camera: keep camera folder names.")
          Spacer()
          Picker("", selection: $strategy) {
            ForEach(strategies, id: \.self) { Text($0).tag($0) }
          }
          .labelsHidden()
          .frame(width: 220)
        }
        .onChange(of: strategy) { _, v in state.set("FOLDER_NAMING_STRATEGY", v) }

        HStack(spacing: 6) {
          Text("Fallback")
          InfoHint(text: "Used when the primary naming mode cannot decide a folder name.")
          Spacer()
          Picker("", selection: $fallback) {
            ForEach(strategies.filter { $0 != "calendar" && $0 != "smart" }, id: \.self) { Text($0).tag($0) }
          }
          .labelsHidden()
          .frame(width: 220)
        }
        .onChange(of: fallback) { _, v in state.set("FOLDER_NAMING_FALLBACK", v) }
      }

      Section("Time grouping") {
        Toggle("Enable clustering before naming", isOn: $clusterGroupingEnabled)
          .onChange(of: clusterGroupingEnabled) { _, v in
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
        Toggle("Use existing folders under today's Drive date folder", isOn: $smartAssignExisting)
          .onChange(of: smartAssignExisting) { _, v in
            state.set("SMART_ASSIGN_EXISTING_FOLDERS", v ? "1" : "0")
          }
        Toggle("Split videos to sibling 2 — Video folder", isOn: $splitPhotoVideo)
          .onChange(of: splitPhotoVideo) { _, v in
            state.set("SPLIT_PHOTO_VIDEO", v ? "1" : "0")
          }
      }
    }
    .formStyle(.grouped)
    .onAppear {
      strategy = state.get("FOLDER_NAMING_STRATEGY", default: "sequential")
      fallback = state.get("FOLDER_NAMING_FALLBACK", default: "sequential")
      seqPrefix = state.get("FOLDER_NAME_SEQUENTIAL_PREFIX", default: "Shoot-")
      customValues = state.get("FOLDER_NAME_CUSTOM_VALUES")
      clusterGap = state.get("CLUSTER_GAP_MINUTES", default: "45")
      clusterGroupingEnabled = (state.get("CLUSTER_GROUPING_ENABLED", default: "1") == "1")
      clusterAttachMinutes = state.get("CLUSTER_ATTACH_MINUTES", default: "120")
      smartSamplePath = state.get("SMART_SAMPLE_PATH")
      smartAssignExisting = (state.get("SMART_ASSIGN_EXISTING_FOLDERS", default: "1") == "1")
      splitPhotoVideo = (state.get("SPLIT_PHOTO_VIDEO", default: "0") == "1")
    }
  }
}

struct DetectionSettings: View {
  @EnvironmentObject var state: AppState
  @State private var prefixes: String = "DFP_"
  @State private var requirePhotos: Bool = true
  @State private var extensions: String = ""
  @State private var ejectOnSuccess: Bool = true
  @State private var ejectGraceSeconds: String = "60"
  @State private var verifyHash: Bool = false
  @State private var lookbackHours: String = "24"
  @State private var videoExtensions: String = ""
  @State private var promptSourceFoldersOnNewCard: Bool = true
  @State private var sqliteMemoryEnabled: Bool = false
  @State private var ntfyTopic: String = "dfp-chase-scheduler"
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
          .onChange(of: sqliteMemoryEnabled) { _, v in state.set("DB_ENABLED", v ? "1" : "0") }
        Text("Default OFF. When off, staging folders are the memory: DDump imports from the lookback window only if files are not already in staging.")
          .font(.caption)
          .foregroundColor(.secondary)
      }

      Section("Cards") {
        HStack(spacing: 6) {
          TextField("Auto-trust name prefixes (comma-separated)",
                    text: $prefixes, onCommit: { state.set("TRUSTED_NAME_PREFIXES", prefixes) })
          InfoHint(text: "Cards with these names auto-import without confirmation.")
        }
        Toggle("Require photos or trusted card", isOn: $requirePhotos)
          .onChange(of: requirePhotos) { _, v in state.set("REQUIRE_PHOTOS_OR_TRUSTED", v ? "1" : "0") }
        Toggle("Eject card on successful import", isOn: $ejectOnSuccess)
          .onChange(of: ejectOnSuccess) { _, v in state.set("EJECT_ON_SUCCESS", v ? "1" : "0") }
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
          .onChange(of: cardAlmostFullAlertEnabled) { _, v in
            state.set("CARD_ALMOST_FULL_ALERT_ENABLED", v ? "1" : "0")
          }
      }

      Section("Scan window") {
        Toggle("Prompt to choose folders when a new card is first seen", isOn: $promptSourceFoldersOnNewCard)
          .onChange(of: promptSourceFoldersOnNewCard) { _, v in state.set("PROMPT_FOR_SOURCE_FOLDERS_ON_NEW_DRIVE", v ? "1" : "0") }

        HStack(spacing: 6) {
          Text("Candidate mode")
          InfoHint(text: "Safety lock: DDump only scans files from the last N hours, never the full card.")
          Spacer()
          Text("Only last N hours")
            .foregroundColor(.secondary)
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
      }

      Section("Verification") {
        Toggle("Verify each copied file with SHA-256 hash", isOn: $verifyHash)
          .onChange(of: verifyHash) { _, v in state.set("VERIFY_COPY_HASH", v ? "1" : "0") }
      }

      Section("File types") {
        TextField("Recognized photo extensions", text: $extensions, onCommit: { state.set("PHOTO_FILE_EXTENSIONS", extensions) })
        TextField("Video extensions for split mode", text: $videoExtensions, onCommit: { state.set("VIDEO_FILE_EXTENSIONS", videoExtensions) })
      }

      Section("ntfy alerts") {
        TextField("Topic (e.g. dfp-chase-scheduler)", text: $ntfyTopic, onCommit: { state.set("NTFY_TOPIC", ntfyTopic) })
        HStack {
          Text("Notification timeout (seconds)")
          Spacer()
          TextField("60", text: $notificationTimeoutSeconds)
            .frame(width: 80)
            .multilineTextAlignment(.trailing)
            .onSubmit { state.set("NOTIFICATION_TIMEOUT_SECONDS", notificationTimeoutSeconds) }
        }
        Toggle("Staging started", isOn: $ntfyStagingStarted)
          .onChange(of: ntfyStagingStarted) { _, v in state.set("NTFY_NOTIFY_STAGING_STARTED", v ? "1" : "0") }
        Toggle("Card ejected", isOn: $ntfyCardEjected)
          .onChange(of: ntfyCardEjected) { _, v in state.set("NTFY_NOTIFY_CARD_EJECTED", v ? "1" : "0") }
        Toggle("Upload started", isOn: $ntfyUploadStarted)
          .onChange(of: ntfyUploadStarted) { _, v in state.set("NTFY_NOTIFY_UPLOAD_STARTED", v ? "1" : "0") }
        Toggle("Upload complete", isOn: $ntfyUploadComplete)
          .onChange(of: ntfyUploadComplete) { _, v in state.set("NTFY_NOTIFY_UPLOAD_COMPLETE", v ? "1" : "0") }
        Toggle("Mount failed", isOn: $ntfyMountFailed)
          .onChange(of: ntfyMountFailed) { _, v in state.set("NTFY_NOTIFY_MOUNT_FAILED", v ? "1" : "0") }
        Toggle("Card almost full", isOn: $ntfyCardAlmostFull)
          .onChange(of: ntfyCardAlmostFull) { _, v in state.set("NTFY_NOTIFY_CARD_ALMOST_FULL", v ? "1" : "0") }
        Toggle("Integrity warning", isOn: $ntfyIntegrityWarning)
          .onChange(of: ntfyIntegrityWarning) { _, v in state.set("NTFY_NOTIFY_INTEGRITY_WARNING", v ? "1" : "0") }
      }
    }
    .formStyle(.grouped)
    .onAppear {
      prefixes = state.get("TRUSTED_NAME_PREFIXES", default: "DFP_")
      requirePhotos = (state.get("REQUIRE_PHOTOS_OR_TRUSTED", default: "1") == "1")
      extensions = state.get("PHOTO_FILE_EXTENSIONS")
      ejectOnSuccess = (state.get("EJECT_ON_SUCCESS", default: "1") == "1")
      ejectGraceSeconds = state.get("EJECT_GRACE_SECONDS", default: "60")
      verifyHash = (state.get("VERIFY_COPY_HASH", default: "0") == "1")
      state.set("CANDIDATE_MODE", "lookback")
      lookbackHours = state.get("LOOKBACK_HOURS", default: "24")
      videoExtensions = state.get("VIDEO_FILE_EXTENSIONS", default: "mp4,mov,m4v,avi,mts,m2ts,3gp,3gpp,insv,gpr")
      promptSourceFoldersOnNewCard = (state.get("PROMPT_FOR_SOURCE_FOLDERS_ON_NEW_DRIVE", default: "1") == "1")
      sqliteMemoryEnabled = state.sqliteMemoryEnabled
      cardAlmostFullAlertEnabled = (state.get("CARD_ALMOST_FULL_ALERT_ENABLED", default: "1") == "1")
      ntfyTopic = state.get("NTFY_TOPIC", default: "dfp-chase-scheduler")
      notificationTimeoutSeconds = state.get("NOTIFICATION_TIMEOUT_SECONDS", default: "60")
      ntfyStagingStarted = (state.get("NTFY_NOTIFY_STAGING_STARTED", default: "0") == "1")
      ntfyCardEjected = (state.get("NTFY_NOTIFY_CARD_EJECTED", default: "1") == "1")
      ntfyUploadStarted = (state.get("NTFY_NOTIFY_UPLOAD_STARTED", default: "0") == "1")
      ntfyUploadComplete = (state.get("NTFY_NOTIFY_UPLOAD_COMPLETE", default: "1") == "1")
      ntfyMountFailed = (state.get("NTFY_NOTIFY_MOUNT_FAILED", default: "1") == "1")
      ntfyCardAlmostFull = (state.get("NTFY_NOTIFY_CARD_ALMOST_FULL", default: "1") == "1")
      ntfyIntegrityWarning = (state.get("NTFY_NOTIFY_INTEGRITY_WARNING", default: "1") == "1")
    }
  }
}
struct CloudSettings: View {
  @EnvironmentObject var state: AppState
  @State private var enabled: Bool = true
  @State private var mountPoint: String = ""
  @State private var remote: String = ""
  @State private var rcloneBin: String = ""
  @State private var mountLabel: String = ""
  @State private var networkResumeEnabled: Bool = true
  @State private var networkResumeCheckSeconds: String = "20"
  @State private var networkResumeCooldownSeconds: String = "120"

  var body: some View {
    Form {
      Section("Connection") {
        Toggle("Enable DDump-managed cloud mount", isOn: $enabled)
          .onChange(of: enabled) { _, v in
            state.set("GDRIVE_MOUNT_ENABLED", v ? "1" : "0")
            state.refreshCloudMountStatus()
          }
        TextField("rclone remote (example: combined:)", text: $remote, onCommit: {
          state.set("GDRIVE_REMOTE", remote)
          state.refreshCloudMountStatus()
        })
        TextField("Mount point folder", text: $mountPoint, onCommit: {
          state.set("GDRIVE_MOUNT_POINT", mountPoint)
          state.refreshCloudMountStatus()
        })
        TextField("rclone binary path", text: $rcloneBin, onCommit: {
          state.set("RCLONE_BIN", rcloneBin)
          state.refreshCloudMountStatus()
        })
        TextField("Mount service label", text: $mountLabel, onCommit: {
          state.set("GDRIVE_MOUNT_LABEL", mountLabel)
          state.refreshCloudMountStatus()
        })
      }

      Section("Offline resume") {
        Toggle("Auto-retry pending uploads when internet reconnects", isOn: $networkResumeEnabled)
          .onChange(of: networkResumeEnabled) { _, v in
            state.set("NETWORK_RESUME_ENABLED", v ? "1" : "0")
          }
        HStack {
          Text("Reconnect check interval (seconds)")
          Spacer()
          TextField("20", text: $networkResumeCheckSeconds)
            .frame(width: 80)
            .multilineTextAlignment(.trailing)
            .onSubmit { state.set("NETWORK_RESUME_CHECK_SECONDS", networkResumeCheckSeconds) }
        }
        HStack {
          Text("Retry cooldown (seconds)")
          Spacer()
          TextField("120", text: $networkResumeCooldownSeconds)
            .frame(width: 80)
            .multilineTextAlignment(.trailing)
            .onSubmit { state.set("NETWORK_RESUME_COOLDOWN_SECONDS", networkResumeCooldownSeconds) }
        }
      }

      Section("Status") {
        Label(state.cloudRcloneReady ? "rclone found" : "rclone missing", systemImage: state.cloudRcloneReady ? "checkmark.circle.fill" : "xmark.circle.fill")
          .foregroundColor(state.cloudRcloneReady ? .green : .orange)
        Label(state.cloudRemoteConfigured ? "remote configured" : "remote not configured", systemImage: state.cloudRemoteConfigured ? "checkmark.circle.fill" : "xmark.circle.fill")
          .foregroundColor(state.cloudRemoteConfigured ? .green : .orange)
        Label(state.cloudServiceLoaded ? "mount service loaded" : "mount service not loaded", systemImage: state.cloudServiceLoaded ? "checkmark.circle.fill" : "xmark.circle.fill")
          .foregroundColor(state.cloudServiceLoaded ? .green : .orange)
        Label(state.cloudMountActive ? "mount is active" : "mount is not active", systemImage: state.cloudMountActive ? "checkmark.circle.fill" : "xmark.circle.fill")
          .foregroundColor(state.cloudMountActive ? .green : .orange)
      }

      Section("Actions") {
        HStack(spacing: 10) {
          Button("Start mount") { state.startCloudMount() }
          Button("Stop mount") { state.stopCloudMount() }
          Button("Re-check status") { state.refreshCloudMountStatus() }
          Button("Hard restart mount") { state.hardRestartCloudMount() }
        }
        HStack(spacing: 10) {
          Button("Open rclone setup in Terminal") { state.openRcloneSetupInTerminal() }
          Button("Open mount folder") { openInFinder(state.gdriveMountPointForUI) }
        }
      }

      Section("Diagnostics") {
        Text(state.cloudDiagnosticMessage.isEmpty ? "No diagnostic message yet." : state.cloudDiagnosticMessage)
          .font(.caption)
          .foregroundColor(.secondary)
          .textSelection(.enabled)
        Button("Run diagnostics now") { state.refreshCloudMountStatus() }
      }

      Section {
        Text("Friend install flow: run DDump installer, open this tab, connect remote in Terminal once, then set Upload destination inside your mounted cloud folder.")
          .font(.caption)
          .foregroundColor(.secondary)
      }
    }
    .formStyle(.grouped)
    .onAppear {
      enabled = state.get("GDRIVE_MOUNT_ENABLED", default: "1") == "1"
      mountPoint = state.get("GDRIVE_MOUNT_POINT", default: "\(NSHomeDirectory())/GoogleDrive")
      remote = state.get("GDRIVE_REMOTE", default: "combined:")
      rcloneBin = state.get("RCLONE_BIN", default: "\(NSHomeDirectory())/bin/rclone")
      mountLabel = state.get("GDRIVE_MOUNT_LABEL", default: "com.ddump.rclone-gdrive")
      networkResumeEnabled = state.get("NETWORK_RESUME_ENABLED", default: "1") == "1"
      networkResumeCheckSeconds = state.get("NETWORK_RESUME_CHECK_SECONDS", default: "20")
      networkResumeCooldownSeconds = state.get("NETWORK_RESUME_COOLDOWN_SECONDS", default: "120")
      state.refreshCloudMountStatus()
    }
  }
}

struct CalendarSettings: View {
  @EnvironmentObject var state: AppState
  @State private var calendarName: String = ""
  @State private var padding: String = "15"
  @State private var gcalcliInstalled: Bool = false
  @State private var authChecked: Bool = false
  @State private var notice: String = ""

  var body: some View {
    Form {
      Section {
        Text("When the naming strategy is calendar, DDump looks up Google Calendar events for the import date and names each shoot folder by the matching event title.")
          .font(.callout)
          .foregroundColor(.secondary)
      }

      Section("Setup") {
        HStack {
          Image(systemName: gcalcliInstalled ? "checkmark.circle.fill" : "circle")
            .foregroundColor(gcalcliInstalled ? .green : .secondary)
          Text("gcalcli installed")
          Spacer()
          if !gcalcliInstalled {
            Button("Install instructions…") {
              notice = "In Terminal:\n  brew install gcalcli\n\nThen authorize:\n  gcalcli list"
            }
          }
        }
        HStack {
          Image(systemName: authChecked ? "checkmark.circle.fill" : "circle")
            .foregroundColor(authChecked ? .green : .secondary)
          Text("Google Calendar authorized")
          Spacer()
          if gcalcliInstalled && !authChecked {
            Button("Authorize…") {
              runGcalcliAuth()
            }
          }
        }
        Button("Re-check") { checkGcalcli() }
        if !notice.isEmpty {
          Text(notice).font(.caption).foregroundColor(.secondary)
        }
      }

      Section("Calendar selection") {
        TextField("Calendar name (blank = primary)",
                  text: $calendarName, onCommit: {
          state.set("CALENDAR_NAME", calendarName)
        })
        HStack {
          Text("Event window padding (minutes each side)")
          Spacer()
          TextField("15", text: $padding)
            .frame(width: 80)
            .multilineTextAlignment(.trailing)
            .onSubmit { state.set("CALENDAR_EVENT_PADDING_MIN", padding) }
        }
      }

      Section {
        Text("Files outside a matching event window use the configured fallback naming strategy.")
          .font(.caption).foregroundColor(.secondary)
      }
    }
    .formStyle(.grouped)
    .onAppear {
      calendarName = state.get("CALENDAR_NAME")
      padding = state.get("CALENDAR_EVENT_PADDING_MIN", default: "15")
      checkGcalcli()
    }
  }

  func checkGcalcli() {
    notice = "Checking calendar setup..."
    DispatchQueue.global(qos: .utility).async {
      let task = Process()
      task.launchPath = "/bin/bash"
      task.arguments = ["-lc", "command -v gcalcli >/dev/null 2>&1 && echo installed; gcalcli list >/dev/null 2>&1 && echo authed"]
      let pipe = Pipe()
      task.standardOutput = pipe
      task.standardError = Pipe()

      do {
        try task.run()
      } catch {
        DispatchQueue.main.async {
          gcalcliInstalled = false
          authChecked = false
          notice = "Could not check gcalcli."
        }
        return
      }

      DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 4) {
        if task.isRunning {
          task.terminate()
        }
      }

      task.waitUntilExit()
      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      let s = String(data: data, encoding: .utf8) ?? ""
      DispatchQueue.main.async {
        gcalcliInstalled = s.contains("installed")
        authChecked = s.contains("authed")
        notice = task.terminationStatus == 0 ? "" : "Calendar authorization not confirmed."
      }
    }
  }

  func runGcalcliAuth() {
    notice = "Open Terminal and run:  gcalcli list  — it will open a browser. After authorizing, click Re-check above."
  }
}

struct IconPreset: Codable, Identifiable, Hashable {
  let id: String
  let name: String
  let fileName: String
  let createdAt: TimeInterval
}

struct AppearanceSettings: View {
  @EnvironmentObject var state: AppState
  @Environment(\.colorScheme) var colorScheme
  @State private var notice: String = ""
  @State private var refreshTrigger: Int = 0
  @State private var colorSchemeChoice: String = "system"
  @State private var presets: [IconPreset] = []
  @State private var selectedPresetID: String = ""
  @State private var defaultLightPresetID: String = ""
  @State private var defaultDarkPresetID: String = ""
  @State private var lastAppliedSignature: String = ""

  var body: some View {
    Form {
      Section("Theme") {
        Picker("Appearance", selection: $colorSchemeChoice) {
          Label("System", systemImage: "circle.lefthalf.filled").tag("system")
          Label("Light", systemImage: "sun.max.fill").tag("light")
          Label("Dark", systemImage: "moon.fill").tag("dark")
        }
        .onChange(of: colorSchemeChoice) { _, v in
          state.set("APP_COLOR_SCHEME", v)
          applyConfiguredDefaultIconForCurrentAppearance(force: true)
        }
      }

      Section {
        HStack(alignment: .top, spacing: 16) {
          let img = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
          Image(nsImage: img)
            .resizable()
            .frame(width: 96, height: 96)
            .id(refreshTrigger)
          VStack(alignment: .leading, spacing: 8) {
            Text("Upload and store icon presets. You can pick one now, and set separate defaults for light and dark mode.")
              .font(.callout).foregroundColor(.secondary)
            Picker("Current icon", selection: $selectedPresetID) {
              Text("Built-in DDump icon").tag("")
              ForEach(presets) { preset in
                Text(preset.name).tag(preset.id)
              }
            }
            HStack {
              Button("Add Icon…") { chooseIcon() }
              Button("Apply Now") { applySelectedPresetNow() }
              Button("Remove Selected") { removeSelectedPreset() }
              Button("Reset") { resetIcon() }
            }
            Picker("Default for Light", selection: $defaultLightPresetID) {
              Text("Built-in DDump icon").tag("")
              ForEach(presets) { preset in
                Text(preset.name).tag(preset.id)
              }
            }
            .onChange(of: defaultLightPresetID) { _, v in
              state.set("APP_ICON_DEFAULT_LIGHT", v)
              applyConfiguredDefaultIconForCurrentAppearance(force: true)
            }

            Picker("Default for Dark", selection: $defaultDarkPresetID) {
              Text("Built-in DDump icon").tag("")
              ForEach(presets) { preset in
                Text(preset.name).tag(preset.id)
              }
            }
            .onChange(of: defaultDarkPresetID) { _, v in
              state.set("APP_ICON_DEFAULT_DARK", v)
              applyConfiguredDefaultIconForCurrentAppearance(force: true)
            }
            if !notice.isEmpty {
              Text(notice).font(.caption).foregroundColor(.secondary)
            }
          }
        }
      } header: {
        Text("App icon")
      } footer: {
        Text("Finder/Dock may take a moment to refresh after icon changes.")
          .font(.caption).foregroundColor(.secondary)
      }
    }
    .formStyle(.grouped)
    .onAppear {
      colorSchemeChoice = state.get("APP_COLOR_SCHEME", default: "system")
      defaultLightPresetID = state.get("APP_ICON_DEFAULT_LIGHT")
      defaultDarkPresetID = state.get("APP_ICON_DEFAULT_DARK")
      loadPresets()
      applyConfiguredDefaultIconForCurrentAppearance(force: false)
    }
    .onChange(of: colorScheme) { _, _ in
      if colorSchemeChoice == "system" {
        applyConfiguredDefaultIconForCurrentAppearance(force: true)
      }
    }
  }

  func chooseIcon() {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.allowedContentTypes = [.image, .icns]
    panel.prompt = "Use as DDump icon"
    if panel.runModal() == .OK, let url = panel.url {
      addPreset(from: url)
    }
  }

  func effectiveAppearanceMode() -> String {
    switch colorSchemeChoice {
    case "light":
      return "light"
    case "dark":
      return "dark"
    default:
      return colorScheme == .dark ? "dark" : "light"
    }
  }

  func presetURL(_ preset: IconPreset) -> URL {
    DDumpPaths.iconLibraryDir.appendingPathComponent(preset.fileName)
  }

  func loadPresets() {
    let fm = FileManager.default
    try? fm.createDirectory(at: DDumpPaths.iconLibraryDir, withIntermediateDirectories: true)
    guard let data = try? Data(contentsOf: DDumpPaths.iconPresetManifest),
          let decoded = try? JSONDecoder().decode([IconPreset].self, from: data)
    else {
      presets = []
      selectedPresetID = ""
      return
    }
    let filtered = decoded.filter { fm.fileExists(atPath: presetURL($0).path) }
    presets = filtered.sorted { $0.createdAt < $1.createdAt }
    if filtered.count != decoded.count {
      savePresets()
    }
    if !selectedPresetID.isEmpty && presets.first(where: { $0.id == selectedPresetID }) == nil {
      selectedPresetID = ""
    }
    if !defaultLightPresetID.isEmpty && presets.first(where: { $0.id == defaultLightPresetID }) == nil {
      defaultLightPresetID = ""
      state.set("APP_ICON_DEFAULT_LIGHT", "")
    }
    if !defaultDarkPresetID.isEmpty && presets.first(where: { $0.id == defaultDarkPresetID }) == nil {
      defaultDarkPresetID = ""
      state.set("APP_ICON_DEFAULT_DARK", "")
    }
  }

  func savePresets() {
    if let data = try? JSONEncoder().encode(presets) {
      try? data.write(to: DDumpPaths.iconPresetManifest, options: [.atomic])
    }
  }

  func addPreset(from url: URL) {
    let fm = FileManager.default
    do {
      try fm.createDirectory(at: DDumpPaths.iconLibraryDir, withIntermediateDirectories: true)
      let id = UUID().uuidString
      let fileName = "\(id).icns"
      let out = DDumpPaths.iconLibraryDir.appendingPathComponent(fileName)
      if url.pathExtension.lowercased() == "icns" {
        try fm.copyItem(at: url, to: out)
      } else if let img = NSImage(contentsOf: url) {
        try writeICNS(image: img, to: out)
      } else {
        notice = "Could not read image."
        return
      }
      let name = url.deletingPathExtension().lastPathComponent
      let preset = IconPreset(id: id, name: name.isEmpty ? "Icon \(presets.count + 1)" : name, fileName: fileName, createdAt: Date().timeIntervalSince1970)
      presets.append(preset)
      selectedPresetID = preset.id
      savePresets()
      applySelectedPresetNow()
      notice = "Icon preset added and applied."
    } catch {
      notice = "Failed to add icon: \(error.localizedDescription)"
    }
  }

  func applySelectedPresetNow() {
    if selectedPresetID.isEmpty {
      resetIcon()
      return
    }
    guard let preset = presets.first(where: { $0.id == selectedPresetID }) else {
      notice = "Selected preset not found."
      return
    }
    installIcon(from: presetURL(preset))
  }

  func removeSelectedPreset() {
    guard !selectedPresetID.isEmpty,
          let idx = presets.firstIndex(where: { $0.id == selectedPresetID })
    else {
      notice = "Select an icon preset to remove."
      return
    }
    let preset = presets[idx]
    try? FileManager.default.removeItem(at: presetURL(preset))
    presets.remove(at: idx)
    if defaultLightPresetID == preset.id {
      defaultLightPresetID = ""
      state.set("APP_ICON_DEFAULT_LIGHT", "")
    }
    if defaultDarkPresetID == preset.id {
      defaultDarkPresetID = ""
      state.set("APP_ICON_DEFAULT_DARK", "")
    }
    selectedPresetID = ""
    savePresets()
    notice = "Preset removed."
    applyConfiguredDefaultIconForCurrentAppearance(force: true)
  }

  func applyConfiguredDefaultIconForCurrentAppearance(force: Bool) {
    let mode = effectiveAppearanceMode()
    let presetID = (mode == "dark") ? defaultDarkPresetID : defaultLightPresetID
    let signature = "\(mode):\(presetID)"
    if !force && signature == lastAppliedSignature {
      return
    }
    lastAppliedSignature = signature
    if presetID.isEmpty {
      if force {
        resetIcon()
      }
      return
    }
    guard let preset = presets.first(where: { $0.id == presetID }) else {
      notice = "Default \(mode) icon preset is missing."
      return
    }
    installIcon(from: presetURL(preset))
  }

  func installIcon(from url: URL) {
    let target = Bundle.main.bundleURL
      .appendingPathComponent("Contents/Resources/AppIcon.icns")
    do {
      if FileManager.default.fileExists(atPath: target.path) {
        try FileManager.default.removeItem(at: target)
      }
      if url.pathExtension.lowercased() == "icns" {
        try FileManager.default.copyItem(at: url, to: target)
      } else if let img = NSImage(contentsOf: url) {
        try writeICNS(image: img, to: target)
      }
      // Touch the bundle so Finder/Dock pick up the change
      let task = Process()
      task.launchPath = "/usr/bin/touch"
      task.arguments = [Bundle.main.bundlePath]
      try? task.run()
      task.waitUntilExit()
      refreshTrigger += 1
      notice = "Icon updated. May take a moment to appear everywhere."
    } catch {
      notice = "Failed to set icon: \(error.localizedDescription)"
    }
  }

  func resetIcon() {
    let target = Bundle.main.bundleURL
      .appendingPathComponent("Contents/Resources/AppIcon.icns")
    let defaultIcon = Bundle.main.bundleURL
      .appendingPathComponent("Contents/Resources/DefaultAppIcon.icns")
    do {
      if FileManager.default.fileExists(atPath: defaultIcon.path) {
        if FileManager.default.fileExists(atPath: target.path) {
          try FileManager.default.removeItem(at: target)
        }
        try FileManager.default.copyItem(at: defaultIcon, to: target)
      }
      refreshTrigger += 1
      selectedPresetID = ""
      notice = "Reset to default icon."
    } catch {
      notice = "Failed to reset icon: \(error.localizedDescription)"
    }
  }

  func writeICNS(image: NSImage, to url: URL) throws {
    let sizes: [(Int, String)] = [
      (16, "icon_16x16.png"),
      (32, "icon_16x16@2x.png"),
      (32, "icon_32x32.png"),
      (64, "icon_32x32@2x.png"),
      (128, "icon_128x128.png"),
      (256, "icon_128x128@2x.png"),
      (256, "icon_256x256.png"),
      (512, "icon_256x256@2x.png"),
      (512, "icon_512x512.png"),
      (1024, "icon_512x512@2x.png"),
    ]
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("DDumpIcon-\(UUID().uuidString).iconset")
    try? FileManager.default.removeItem(at: tmp)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    for (sz, name) in sizes {
      let target = NSImage(size: NSSize(width: sz, height: sz))
      target.lockFocus()
      image.draw(in: NSRect(x: 0, y: 0, width: sz, height: sz))
      target.unlockFocus()
      if let tiff = target.tiffRepresentation,
         let rep = NSBitmapImageRep(data: tiff),
         let png = rep.representation(using: .png, properties: [:]) {
        try png.write(to: tmp.appendingPathComponent(name))
      }
    }
    let task = Process()
    task.launchPath = "/usr/bin/iconutil"
    task.arguments = ["-c", "icns", "-o", url.path, tmp.path]
    try task.run()
    task.waitUntilExit()
    try? FileManager.default.removeItem(at: tmp)
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

/// AppDelegate that assigns a frameAutosaveName to the main window so macOS
/// remembers its position/size across launches.
class WindowMemoryDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
      for window in NSApplication.shared.windows {
        // SwiftUI Settings scenes create separate windows; tag the main one only
        if window.title == "DDump" || window.contentViewController is NSHostingController<AnyView> {
          window.setFrameAutosaveName("DDumpMainWindow")
        }
        if window.title == "DDump" {
          window.setFrameAutosaveName("DDumpMainWindow")
        }
      }
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
}

// MARK: - App entry point

@main
struct DDumpApp: App {
  @NSApplicationDelegateAdaptor(WindowMemoryDelegate.self) var appDelegate
  @StateObject private var state = AppState()

  var body: some Scene {
    WindowGroup("DDump") {
      ContentView()
        .environmentObject(state)
        .background(WindowAccessor())
        .preferredColorScheme(state.preferredColorScheme())
    }
    .windowResizability(.contentSize)
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
        window.setFrameAutosaveName("DDumpMainWindow")
      }
    }
    return v
  }
  func updateNSView(_ nsView: NSView, context: Context) {}
}
