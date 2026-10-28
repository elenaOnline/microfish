import AppKit

final class BuildTile: NSView, NSDraggingSource {
    var buildURL: URL?
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 12, yRadius: 12).fill()
        NSColor.controlAccentColor.setStroke()
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 12, yRadius: 12)
        outline.lineWidth = 2; outline.stroke()
        guard let url = buildURL else { return }
        NSWorkspace.shared.icon(forFile: url.path).draw(in: NSRect(x: 20, y: 24, width: 48, height: 48))
        let text = "Drag this build into Settings\n" + url.lastPathComponent
        (text as NSString).draw(in: NSRect(x: 84, y: 20, width: bounds.width - 100, height: 58), withAttributes: [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.labelColor])
    }
    override func mouseDown(with event: NSEvent) {
        guard let url = buildURL else { return }
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(NSRect(x: 20, y: 24, width: 48, height: 48), contents: NSWorkspace.shared.icon(forFile: url.path))
        beginDraggingSession(with: [item], event: event, source: self)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
}

final class PermissionHelper: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let tile = BuildTile(frame: NSRect(x: 24, y: 136, width: 552, height: 100))
    let status = NSTextField(wrappingLabelWithString: "")
    let root = Bundle.main.bundleURL.deletingLastPathComponent()
    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 340), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Paneru Build Permissions"
        let heading = NSTextField(labelWithString: "Give the new build access")
        heading.font = .boldSystemFont(ofSize: 22); heading.frame = NSRect(x: 24, y: 284, width: 550, height: 30)
        window.contentView!.addSubview(heading)
        let help = NSTextField(wrappingLabelWithString: "Open Device Control and Data Access, drag the build into its list, then enable its switch. If dragging is unavailable, use Reveal in Finder or Copy Path with the + dialog.")
        help.frame = NSRect(x: 24, y: 238, width: 552, height: 45); window.contentView!.addSubview(help)
        window.contentView!.addSubview(tile)
        let actions: [(String, Selector, CGFloat, CGFloat)] = [("Open Settings", #selector(openSettings), 24, 140), ("Reveal in Finder", #selector(reveal), 174, 145), ("Copy Path", #selector(copyPath), 329, 110), ("Choose Build…", #selector(choose), 449, 128)]
        for (title, action, x, width) in actions {
            let button = NSButton(title: title, target: self, action: action)
            button.bezelStyle = .rounded; button.frame = NSRect(x: x, y: 91, width: width, height: 32)
            window.contentView!.addSubview(button)
        }
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        status.frame = NSRect(x: 24, y: 16, width: 552, height: 65); window.contentView!.addSubview(status)
        refresh(); window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func applicationDidBecomeActive(_ notification: Notification) { if window != nil { refresh() } }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func refresh() {
        let pending = root.appendingPathComponent("config/permission-build.path")
        if let path = try? String(contentsOf: pending, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
            select(URL(fileURLWithPath: path)); return
        }
        let plist = root.appendingPathComponent("config/trial.plist")
        if let data = try? Data(contentsOf: plist), let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any], let args = dict["ProgramArguments"] as? [String], let first = args.first { select(URL(fileURLWithPath: first)) }
    }
    func select(_ url: URL) {
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            tile.buildURL = nil; tile.needsDisplay = true
            status.stringValue = "Build missing or not executable. Choose the intended build.\n" + url.path; return
        }
        tile.buildURL = url; tile.needsDisplay = true
        status.stringValue = url.path + "\nThis helper does not grant permission or start the window manager."
    }
    @objc func openSettings() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!) }
    @objc func reveal() { if let url = tile.buildURL { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
    @objc func copyPath() { if let url = tile.buildURL { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.path, forType: .string) } }
    @objc func choose() {
        let panel = NSOpenPanel(); panel.directoryURL = root.appendingPathComponent("bin"); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            do { try (url.path + "\n").write(to: root.appendingPathComponent("config/permission-build.path"), atomically: true, encoding: .utf8); select(url) }
            catch { status.stringValue = "Could not save build selection: \(error.localizedDescription)" }
        }
    }
}
let app = NSApplication.shared
let delegate = PermissionHelper()
app.setActivationPolicy(.regular); app.delegate = delegate; app.run()
