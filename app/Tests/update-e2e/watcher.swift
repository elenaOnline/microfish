import CoreGraphics
import Darwin
import Foundation

// Read-only observer for the update E2E: logs (a) the moment the installed bundle's CFBundleVersion
// changes, with millisecond timestamps, and (b) every window that any process running from the scratch
// directory ever creates (Sparkle's Updater/Autoupdate progress UI would show up here), with whether it
// is on screen. It never touches a window or a process.
// usage: watcher <app bundle> <scratch dir> <log file>   (runs until SIGTERM)

let args = CommandLine.arguments
let plist = URL(fileURLWithPath: args[1]).appendingPathComponent("Contents/Info.plist")
// proc_pidpath reports /private/tmp/…, not /tmp/…: compare against the real path.
let scratch: String = {
    var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
    return realpath(args[2], &buf).map { String(cString: $0) } ?? args[2]
}()
let logURL = URL(fileURLWithPath: args[3])
FileManager.default.createFile(atPath: logURL.path, contents: nil)
let log = try! FileHandle(forWritingTo: logURL)
func emit(_ s: String) { log.write((String(format: "%.3f ", Date().timeIntervalSince1970) + s + "\n").data(using: .utf8)!) }

func pathOf(_ pid: pid_t) -> String {
    var buf = [CChar](repeating: 0, count: 4096)
    let n = proc_pidpath(pid, &buf, UInt32(buf.count))
    return n > 0 ? String(cString: buf) : ""
}
func installedVersion() -> String {
    guard let d = try? Data(contentsOf: plist), let o = try? PropertyListSerialization.propertyList(from: d, format: nil) as? [String: Any] else { return "missing" }
    return (o["CFBundleShortVersionString"] as? String ?? "?") + " (" + (o["CFBundleVersion"] as? String ?? "?") + ")"
}

func displayRects() -> [CGRect] {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16); var n: UInt32 = 0
    CGGetActiveDisplayList(16, &ids, &n)
    return ids.prefix(Int(n)).map { CGDisplayBounds($0) }
}

signal(SIGTERM, SIG_IGN)
let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
term.setEventHandler { emit("watcher-exit"); exit(0) }
term.resume()

var lastVersion = ""
var seenWindows = Set<String>()
var tick = 0
let timer = DispatchSource.makeTimerSource(queue: .main)
timer.schedule(deadline: .now(), repeating: .milliseconds(10))
timer.setEventHandler {
    let v = installedVersion()
    if v != lastVersion { emit("bundle-version \(v)"); lastVersion = v }
    tick += 1
    guard tick % 10 == 0 else { return }
    let infos = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]) ?? []
    for w in infos {
        guard let pid = w[kCGWindowOwnerPID as String] as? Int32 else { continue }
        let path = pathOf(pid)
        let name = w[kCGWindowOwnerName as String] as? String ?? "?"
        // Anything from the scratch tree, anything of the probe's identity, and Sparkle's installer processes
        // (which run from a cache or temp copy, not from the scratch tree).
        let sparkleHelper = path.contains("org.sparkle-project") || path.contains("Sparkle.framework")
        guard path.hasPrefix(scratch) || path.contains("net.webreceptor.microfish.updateprobe") || sparkleHelper else { continue }
        let title = w[kCGWindowName as String] as? String ?? ""
        let onscreen = (w[kCGWindowIsOnscreen as String] as? Bool) ?? false
        let b = w[kCGWindowBounds as String] as? [String: Double] ?? [:]
        let rect = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
        // "onscreen" in the window list only means ordered in; ondisplay means it overlaps a display, i.e. it could be seen.
        let ondisplay = onscreen && rect.width > 1 && rect.height > 1 && displayRects().contains { $0.intersects(rect) }
        let key = "\(name)|\(title)|\(ondisplay)|\(Int(rect.width))x\(Int(rect.height))"
        if seenWindows.insert(key).inserted {
            emit("window owner=\(name) title=\(title.debugDescription) ondisplay=\(ondisplay) size=\(Int(b["Width"] ?? 0))x\(Int(b["Height"] ?? 0)) layer=\(w[kCGWindowLayer as String] as? Int ?? -1) path=\(path.replacingOccurrences(of: scratch, with: "<scratch>"))")
        }
    }
}
timer.resume()
emit("watcher-start")
RunLoop.main.run()
