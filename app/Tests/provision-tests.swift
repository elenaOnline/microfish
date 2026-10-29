// Headless tests for Provisioning.swift. Standalone (NAVIGATOR_TESTS): only temp directories are touched.
import Foundation

var provisionChecks = 0
func pcheck(_ c: @autoclosure () -> Bool, _ m: String) { precondition(c(), "provisioning: " + m); provisionChecks += 1 }

do {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("mf-prov-\(getpid())")
    try! fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    func text(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }
    func make(_ name: String, defaults names: [String]) -> (support: URL, state: URL, runtime: URL, logs: URL, defaults: URL) {
        let base = root.appendingPathComponent(name)
        let defaults = base.appendingPathComponent("Defaults")
        try! fm.createDirectory(at: defaults, withIntermediateDirectories: true)
        for n in names { try! "default \(n)".write(to: defaults.appendingPathComponent(n), atomically: true, encoding: .utf8) }
        let support = base.appendingPathComponent("Support")
        return (support, support.appendingPathComponent("State"), support.appendingPathComponent("Runtime"), base.appendingPathComponent("Logs"), defaults)
    }
    func go(_ p: (support: URL, state: URL, runtime: URL, logs: URL, defaults: URL)) -> MicrofishProvisioning.Report {
        MicrofishProvisioning.run(support: p.support, state: p.state, runtime: p.runtime, logs: p.logs, defaults: p.defaults)
    }
    let all = MicrofishProvisioning.expectedDefaults

    // Fresh install: everything copied, folders made.
    let a = make("fresh", defaults: all)
    var r = go(a)
    pcheck(r.copied.sorted() == all.sorted() && r.problems.isEmpty && r.missingDefaults.isEmpty, "fresh install copies every default: \(r)")
    pcheck(text(a.support.appendingPathComponent("init.lua")) == "default init.lua", "content copied")
    for d in [a.support, a.state, a.runtime, a.logs] { var isDir: ObjCBool = false; pcheck(fm.fileExists(atPath: d.path, isDirectory: &isDir) && isDir.boolValue, "\(d.lastPathComponent) created") }

    // Never overwrites: user edits survive, and a second run copies nothing.
    try! "USER PREFS".write(to: a.support.appendingPathComponent("preferences.json"), atomically: true, encoding: .utf8)
    try! "-- mine\nparaneru.x()\n-- settings revision 7\n".write(to: a.support.appendingPathComponent("init.lua"), atomically: true, encoding: .utf8)
    r = go(a)
    pcheck(r.copied.isEmpty && r.kept.sorted() == all.sorted(), "second run copies nothing: \(r)")
    pcheck(text(a.support.appendingPathComponent("preferences.json")) == "USER PREFS", "preferences.json untouched")
    pcheck(text(a.support.appendingPathComponent("init.lua"))?.contains("settings revision 7") == true, "init.lua untouched")

    // One deleted file comes back; the others stay as the user left them.
    try! fm.removeItem(at: a.support.appendingPathComponent("settings.lua"))
    r = go(a)
    pcheck(r.copied == ["settings.lua"] && text(a.support.appendingPathComponent("settings.lua")) == "default settings.lua", "only the missing file is restored: \(r)")
    pcheck(text(a.support.appendingPathComponent("preferences.json")) == "USER PREFS", "still untouched")

    // An empty file the user left is theirs; a dangling symlink too.
    try! "".write(to: a.support.appendingPathComponent("shortcuts.lua"), atomically: true, encoding: .utf8)
    try! fm.removeItem(at: a.support.appendingPathComponent("settings.lua"))
    try! fm.createSymbolicLink(at: a.support.appendingPathComponent("settings.lua"), withDestinationURL: root.appendingPathComponent("nowhere"))
    r = go(a)
    pcheck(r.copied.isEmpty, "empty file and dangling symlink are kept: \(r)")
    pcheck(text(a.support.appendingPathComponent("shortcuts.lua")) == "", "empty file still empty")

    // A missing Defaults file is logged and skipped; the rest still provisions.
    let b = make("partial", defaults: ["preferences.json", "init.lua"])
    r = go(b)
    pcheck(r.copied.sorted() == ["init.lua", "preferences.json"] && r.missingDefaults.sorted() == ["settings.lua", "shortcuts.lua"], "partial defaults: \(r)")
    pcheck(r.log.contains("Defaults/settings.lua is missing from the app; skipped") && r.problems.isEmpty, "clear log line: \(r.log)")
    pcheck(!fm.fileExists(atPath: b.support.appendingPathComponent("settings.lua").path), "nothing invented for a missing default")

    // No Defaults folder at all: no crash, folders still exist, every default reported missing.
    var c = make("none", defaults: [])
    try! fm.removeItem(at: c.defaults)
    r = go(c)
    pcheck(r.copied.isEmpty && r.missingDefaults.count == all.count && fm.fileExists(atPath: c.state.path), "no Defaults folder: \(r)")

    // Extra files in Defaults are provisioned too, hidden ones are not.
    c = make("extra", defaults: all + ["extra.json", ".DS_Store"])
    r = go(c)
    pcheck(r.copied.contains("extra.json") && !r.copied.contains(".DS_Store"), "extra default copied, hidden skipped: \(r.copied)")

    // An unwritable support folder reports a problem instead of crashing.
    let d = make("blocked", defaults: all)
    try! "a file where the folder should be".write(to: d.support, atomically: true, encoding: .utf8)
    r = go(d)
    pcheck(!r.problems.isEmpty, "unusable support folder is reported: \(r)")
}

// The system runner starts nothing in a test build: no process, no launchd.
do {
    let runner = SystemProcessRunner()
    let result = runner.run(URL(fileURLWithPath: "/bin/echo"), ["hello"], environment: nil, timeout: 1)
    pcheck(result.status == CommandResult.noLaunch && result.output.isEmpty, "test build runs no process")
}
print("provisioning checks passed:", provisionChecks)
