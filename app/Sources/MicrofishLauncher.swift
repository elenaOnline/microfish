import AppKit
final class Launcher: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let script = Bundle.main.object(forInfoDictionaryKey: "MicrofishLaunchScript") as? String else { fail("The launch script is not configured."); return }
        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process(); task.executableURL = URL(fileURLWithPath: "/bin/zsh"); task.arguments = [script]
            let pipe = Pipe(); task.standardOutput = pipe; task.standardError = pipe
            do {
                try task.run()
                let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                task.waitUntilExit()
                DispatchQueue.main.async {
                    if task.terminationStatus == 0 { NSApp.terminate(nil) }
                    else { self.fail(output.isEmpty ? "Microfish could not start." : output) }
                }
            } catch { DispatchQueue.main.async { self.fail(error.localizedDescription) } }
        }
    }
    private func fail(_ message: String) {
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert(); alert.messageText = "Microfish couldn’t start"; alert.informativeText = message; alert.runModal(); NSApp.terminate(nil)
    }
}
let app = NSApplication.shared
let launcher = Launcher(); app.delegate = launcher; app.run()
