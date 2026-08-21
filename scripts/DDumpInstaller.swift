import AppKit
import Foundation

final class InstallerDelegate: NSObject, NSApplicationDelegate {
  private var statusWindow: NSWindow?

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)

    let confirmation = NSAlert()
    confirmation.alertStyle = .informational
    confirmation.messageText = "Install DDump?"
    confirmation.informativeText = "DDump will be installed for this Mac user and will start watching for camera cards. Your existing settings will be kept."
    confirmation.addButton(withTitle: "Install")
    confirmation.addButton(withTitle: "Cancel")
    guard confirmation.runModal() == .alertFirstButtonReturn else {
      NSApp.terminate(nil)
      return
    }

    showProgressWindow()
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let result = self?.runInstaller() ?? (1, "Installer could not start.")
      DispatchQueue.main.async {
        self?.finish(status: result.0, output: result.1)
      }
    }
  }

  private func showProgressWindow() {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 420, height: 150),
      styleMask: [.titled],
      backing: .buffered,
      defer: false
    )
    window.title = "Install DDump"
    window.isReleasedWhenClosed = false

    let label = NSTextField(labelWithString: "Installing DDump for this Mac user…")
    label.font = .systemFont(ofSize: 15, weight: .medium)
    label.alignment = .center
    label.translatesAutoresizingMaskIntoConstraints = false

    let spinner = NSProgressIndicator()
    spinner.style = .spinning
    spinner.controlSize = .regular
    spinner.translatesAutoresizingMaskIntoConstraints = false
    spinner.startAnimation(nil)

    let content = NSView()
    content.addSubview(label)
    content.addSubview(spinner)
    window.contentView = content
    NSLayoutConstraint.activate([
      label.centerXAnchor.constraint(equalTo: content.centerXAnchor),
      label.topAnchor.constraint(equalTo: content.topAnchor, constant: 34),
      spinner.centerXAnchor.constraint(equalTo: content.centerXAnchor),
      spinner.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 20),
    ])
    window.center()
    window.makeKeyAndOrderFront(nil)
    statusWindow = window
  }

  private func runInstaller() -> (Int32, String) {
    guard let resources = Bundle.main.resourceURL else {
      return (1, "The installer payload is missing.")
    }
    let payload = resources.appendingPathComponent("Payload", isDirectory: true)
    let script = payload.appendingPathComponent("bin/install.sh")
    guard FileManager.default.isExecutableFile(atPath: script.path) else {
      return (1, "The installer payload is incomplete.")
    }

    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [script.path]
    process.currentDirectoryURL = payload
    process.standardOutput = output
    process.standardError = output

    do {
      try process.run()
      let data = output.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      let installOutput = String(decoding: data, as: UTF8.self)
      guard process.terminationStatus == 0 else {
        return (process.terminationStatus, installOutput)
      }

      let publicReleaseMarker = resources.appendingPathComponent("PublicRelease")
      if FileManager.default.fileExists(atPath: publicReleaseMarker.path) {
        let installedApp = FileManager.default.homeDirectoryForCurrentUser
          .appendingPathComponent("Applications/DDump.app", isDirectory: true)
        let signatureCheck = runCommand(
          executable: "/usr/bin/codesign",
          arguments: ["--verify", "--deep", "--strict", "--verbose=2", installedApp.path]
        )
        guard signatureCheck.0 == 0 else {
          return (signatureCheck.0, "The installed app signature is invalid.\n\(signatureCheck.1)")
        }
        let gatekeeperCheck = runCommand(
          executable: "/usr/sbin/spctl",
          arguments: ["--assess", "--type", "execute", "--verbose=4", installedApp.path]
        )
        guard gatekeeperCheck.0 == 0 else {
          return (gatekeeperCheck.0, "Gatekeeper did not accept the installed app.\n\(gatekeeperCheck.1)")
        }
      }
      return (0, installOutput)
    } catch {
      return (1, error.localizedDescription)
    }
  }

  private func runCommand(executable: String, arguments: [String]) -> (Int32, String) {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = output
    process.standardError = output
    do {
      try process.run()
      let data = output.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    } catch {
      return (1, error.localizedDescription)
    }
  }

  private func finish(status: Int32, output: String) {
    statusWindow?.close()
    let alert = NSAlert()
    if status == 0 {
      alert.alertStyle = .informational
      alert.messageText = "DDump is installed"
      alert.informativeText = "DDump is ready in your Applications folder."
      alert.addButton(withTitle: "Open DDump")
      alert.runModal()
      let appURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Applications/DDump.app", isDirectory: true)
      NSWorkspace.shared.open(appURL)
    } else {
      alert.alertStyle = .critical
      alert.messageText = "DDump could not be installed"
      let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
      alert.informativeText = detail.isEmpty ? "The installer stopped before finishing." : String(detail.suffix(1800))
      alert.addButton(withTitle: "Close")
      alert.runModal()
    }
    NSApp.terminate(nil)
  }
}

let app = NSApplication.shared
let delegate = InstallerDelegate()
app.delegate = delegate
app.run()
