import AppKit

// Microfish.app: starts Microfish through scripts/launch-microfish.zsh and shows one short, plain alert if that
// fails. The script's own output (launchctl messages, job names, paths) never reaches the alert; it goes to
// ~/Library/Logs/Microfish/launcher.log. The alert text is chosen from a small set by what went wrong.

/// Same pane the permission helper opens (macOS 27 names it "Device Control and Data Access").
let accessPaneURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

enum LaunchFailure {
    case damaged, access, stillRunningOld, other

    var message: String {
        switch self {
        case .damaged: return "Microfish.app is damaged. Reinstall it, then open Microfish again."
        case .access: return "Microfish didn’t respond. In System Settings > Privacy & Security > Device Control and Data Access, make sure Microfish is turned on, then open Microfish again."
        case .stillRunningOld: return "ChainYourMac is still running. Quit it, then open Microfish again."
        case .other: return "Something went wrong while starting Microfish. Try opening it again."
        }
    }
    var offersSystemSettings: Bool { self == .access }

    /// Exit status 2 is the script's "no access" code; older scripts only print the pane name, so match that too.
    static func classify(status: Int32, output: String) -> LaunchFailure {
        if status == 2 || output.contains("Device Control and Data Access") { return .access }
        if output.contains("ChainYourMac is still running") { return .stillRunningOld }
        if output.contains("program files are missing") { return .damaged }
        return .other
    }
}

func logLauncher(_ text: String) {
    let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Microfish")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("launcher.log")
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(text)\n"
    if let handle = try? FileHandle(forWritingTo: file) {
        defer { try? handle.close() }
        _ = try? handle.seekToEnd(); try? handle.write(contentsOf: Data(line.utf8))
    } else {
        try? line.write(to: file, atomically: true, encoding: .utf8)
    }
}

final class Launcher: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let script = Bundle.main.object(forInfoDictionaryKey: "MicrofishLaunchScript") as? String else {
            logLauncher("MicrofishLaunchScript is missing from Info.plist")
            fail(.damaged); return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process(); task.executableURL = URL(fileURLWithPath: "/bin/zsh"); task.arguments = [script]
            let pipe = Pipe(); task.standardOutput = pipe; task.standardError = pipe
            do {
                try task.run()
                let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                task.waitUntilExit()
                DispatchQueue.main.async {
                    if task.terminationStatus == 0 { NSApp.terminate(nil); return }
                    logLauncher("launch script exited \(task.terminationStatus): \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
                    self.fail(LaunchFailure.classify(status: task.terminationStatus, output: output))
                }
            } catch {
                DispatchQueue.main.async { logLauncher("could not run the launch script: \(error)"); self.fail(.other) }
            }
        }
    }
    private func fail(_ failure: LaunchFailure) {
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert(); alert.messageText = "Microfish couldn’t start"; alert.informativeText = failure.message
        if failure.offersSystemSettings { alert.addButton(withTitle: "Open System Settings") }
        alert.addButton(withTitle: "OK")
        if alert.runModal() == .alertFirstButtonReturn && failure.offersSystemSettings { NSWorkspace.shared.open(accessPaneURL) }
        NSApp.terminate(nil)
    }
}
let app = NSApplication.shared
let launcher = Launcher(); app.delegate = launcher; app.run()
