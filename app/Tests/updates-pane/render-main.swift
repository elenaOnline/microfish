import AppKit
import SwiftUI

// Renders the real Settings window on the Updates pane through the window server while it is parked off
// every screen (never key, accessory app, nothing on a display). usage: render <fixture-root> <out-dir>
@main struct Render {
    @MainActor static func main() throws {
        let app = NSApplication.shared; app.setActivationPolicy(.accessory); app.finishLaunching()
        let args = CommandLine.arguments
        let root = URL(fileURLWithPath: args[1]), out = URL(fileURLWithPath: args[2])
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for key in ["MicrofishSettingsPane", "MicrofishSettingsWindowTopLeft"] { UserDefaults.standard.removeObject(forKey: key) }
        defer { for key in ["MicrofishSettingsPane", "MicrofishSettingsWindowTopLeft"] { UserDefaults.standard.removeObject(forKey: key) } }
        let model = UpdateSettingsModel.shared
        let only = Set(args.dropFirst(3))   // optional: render only the named states, e.g. `light-updates-checks-off`
        // A fresh window per state. build.sh also runs each state in its own process: NSSwitch's knob and
        // disabled fade lag by one capture when several states share a process.
        func shoot(_ look: String, _ name: String, otherPaneDraft: Bool = false, comparePane: SettingsPane? = nil, _ setup: () -> Void) throws {
            if !only.isEmpty && !only.contains("\(look)-\(name)") { return }
            try? FileManager.default.removeItem(at: root.appendingPathComponent("work"))   // drafts persisted by the previous state
            let c = SettingsController(rootURL: root)
            guard let window = c.testWindow else { fatalError("no window") }
            window.appearance = NSAppearance(named: look == "dark" ? .darkAqua : .aqua)
            setup()
            if otherPaneDraft { c.store.draft.borderWidth = 3 }
            c.testSelect(comparePane ?? .updates)
            WindowCapture.park(window)
            try WindowCapture.capture(window, to: out.appendingPathComponent("\(look)-\(name).png"), settle: 0.8)
            print("captured", "\(look)-\(name)", window.frame.size)
            window.orderOut(nil)
        }
        func state(available: Bool = true, checks: Bool = true, downloads: Bool = false, beta: Bool = false, last: Date? = Date().addingTimeInterval(-3600 * 3), checking: Bool = false, waiting: String? = nil, canCheck: Bool = true) {
            model.available = available; model.automaticChecks = checks; model.automaticDownloads = downloads; model.canAutomaticallyDownload = checks
            model.beta = beta; model.lastCheck = last; model.checking = checking; model.waitingVersion = waiting; model.canCheck = canCheck
            model.version = "1.0.0 (1000099)"
        }
        for look in ["light", "dark"] {
            try shoot(look, "updates") { state() }
            try shoot(look, "updates-all-on") { state(checks: true, downloads: true, beta: true) }
            try shoot(look, "updates-checks-off") { state(checks: false) }
            try shoot(look, "updates-checking") { state(last: nil, checking: true, canCheck: false) }
            try shoot(look, "updates-update-waiting") { state(waiting: "1.1.0") }
            try shoot(look, "updates-unavailable") { state(available: false, last: nil); model.version = "Development build" }
            // A draft made on another pane stays reachable: Revert and Apply remain on the Updates pane.
            try shoot(look, "updates-with-unapplied-draft", otherPaneDraft: true) { state() }
            try shoot(look, "behavior-footer-for-comparison", comparePane: .behavior) { state() }
        }
        print("preflight", WindowCapture.screenCapturePreflight)
    }
}
