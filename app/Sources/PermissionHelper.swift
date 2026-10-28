import AppKit

// Microfish Access: grants macOS "Device Control and Data Access" (the Privacy_Accessibility pane) to a newly
// signed engine build. Shows the build as a draggable file tile; it never grants access or starts Microfish.

/// Name System Settings shows for the pane the deep link below opens (macOS 27: SecurityPrivacyExtension,
/// Localizable key ACCESSIBILITY = "Device Control and Data Access").
let paneName = "Device Control and Data Access"
let paneURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

// MARK: - Colours

enum Teal {
    static func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
    static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }
    /// Borders, fills and badge circles.
    static let accent = dynamic(light: rgb(0x009193), dark: rgb(0x3CC8CA))
    /// Teal used as text on the tinted badge / link (>= 4.5:1 on the window background).
    static let text = dynamic(light: rgb(0x00696B), dark: rgb(0x6FDCDE))
    /// Fill of the primary button; white label on it is 5.2:1.
    static let button = rgb(0x00797B)
    static var increaseContrast: Bool { NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast }
}

// MARK: - Step badge

final class StepBadge: NSView {
    let number: Int
    init(_ number: Int) {
        self.number = number
        super.init(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("Step \(number)")
    }
    required init?(coder: NSCoder) { fatalError() }
    override var intrinsicContentSize: NSSize { NSSize(width: 20, height: 20) }
    override func draw(_ dirtyRect: NSRect) {
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5))
        Teal.accent.withAlphaComponent(Teal.increaseContrast ? 0.28 : 0.16).setFill(); circle.fill()
        if Teal.increaseContrast { Teal.accent.setStroke(); circle.lineWidth = 1; circle.stroke() }
        let label = "\(number)" as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: Teal.text]
        let size = label.size(withAttributes: attrs)
        label.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attrs)
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

// MARK: - Build tile (drop-zone look, drag source)

enum BuildState {
    case ready(URL)
    case missing(String)   // path that is missing / not executable
    case none              // nothing selected anywhere
}

final class BuildTile: NSView, NSDraggingSource {
    var buildURL: URL?
    private(set) var isWarning = false
    let iconView = NSImageView()
    let nameLabel = NSTextField(labelWithString: "")
    let pathLabel = NSTextField(labelWithString: "")
    let buttons = NSStackView()
    let revealButton: NSButton
    let copyButton: NSButton
    private var dragOrigin: NSPoint?
    /// Only actual paths are monospaced; sentences use the system font.
    static let pathFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    static let sentenceFont = NSFont.systemFont(ofSize: 11)

    init(reveal: NSButton, copy: NSButton) {
        revealButton = reveal; copyButton = copy
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.setAccessibilityElement(false)
        NSLayoutConstraint.activate([iconView.widthAnchor.constraint(equalToConstant: 48), iconView.heightAnchor.constraint(equalToConstant: 48)])

        nameLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.font = BuildTile.pathFont
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle
        for label in [nameLabel, pathLabel] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.setContentHuggingPriority(.defaultLow, for: .horizontal)
            label.maximumNumberOfLines = 1
            label.setAccessibilityElement(false)
        }
        let text = NSStackView(views: [nameLabel, pathLabel])
        text.orientation = .vertical; text.alignment = .leading; text.spacing = 3
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        buttons.setViews([reveal, copy], in: .leading)
        buttons.orientation = .horizontal; buttons.spacing = 8
        buttons.setContentHuggingPriority(.required, for: .horizontal)
        buttons.setContentCompressionResistancePriority(.required, for: .horizontal)

        // Buttons sit on the tile's trailing edge however short the file name is.
        let row = NSStackView()
        row.setViews([iconView, text], in: .leading); row.setViews([buttons], in: .trailing)
        row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 13),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -13),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ state: BuildState, paneName: String) {
        switch state {
        case .ready(let url):
            buildURL = url; isWarning = false
            iconView.image = NSWorkspace.shared.icon(forFile: url.path)
            iconView.contentTintColor = nil
            nameLabel.stringValue = url.lastPathComponent
            pathLabel.stringValue = url.path
            pathLabel.font = BuildTile.pathFont
            toolTip = url.path
            buttons.isHidden = false
            setAccessibilityElement(true)
            setAccessibilityRole(.group)
            setAccessibilityLabel("Microfish build, draggable. Drag into the \(paneName) list.")
            setAccessibilityValue(url.path)
        case .missing(let path):
            buildURL = nil; isWarning = true
            warningIcon()
            nameLabel.stringValue = "Build missing or not executable"
            pathLabel.stringValue = path
            pathLabel.font = BuildTile.pathFont
            toolTip = path
            buttons.isHidden = true
            setAccessibilityElement(true)
            setAccessibilityRole(.group)
            setAccessibilityLabel("Build missing or not executable. Choose the intended build.")
            setAccessibilityValue(path)
        case .none:
            buildURL = nil; isWarning = true
            warningIcon()
            nameLabel.stringValue = "No build selected"
            pathLabel.stringValue = "Choose the build to give access."
            pathLabel.font = BuildTile.sentenceFont
            toolTip = nil
            buttons.isHidden = true
            setAccessibilityElement(true)
            setAccessibilityRole(.group)
            setAccessibilityLabel("No build selected. Choose the intended build.")
            setAccessibilityValue(nil)
        }
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }
    private func warningIcon() {
        let config = NSImage.SymbolConfiguration(pointSize: 30, weight: .regular)
        iconView.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config)
        iconView.contentTintColor = .systemOrange
    }

    // The whole tile is the drag source; only the buttons keep their own clicks.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        var view: NSView? = hit
        while let v = view, v !== self {
            if v is NSButton { return hit }
            view = v.superview
        }
        return self
    }
    override func resetCursorRects() {
        guard buildURL != nil else { return }
        let buttonsFrame = convert(buttons.bounds, from: buttons)
        addCursorRect(NSRect(x: 0, y: 0, width: max(0, buttonsFrame.minX - 8), height: bounds.height), cursor: .openHand)
    }
    override func layout() { super.layout(); window?.invalidateCursorRects(for: self) }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let base: NSColor = isWarning ? .systemOrange : Teal.accent
        let strong = Teal.increaseContrast
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
        base.withAlphaComponent(strong ? 0.14 : 0.07).setFill(); path.fill()
        base.withAlphaComponent(strong ? 1 : 0.6).setStroke()
        path.lineWidth = strong ? 1.5 : 1
        path.setLineDash([5, 3], count: 2, phase: 0)
        path.stroke()
    }

    override func mouseDown(with event: NSEvent) { dragOrigin = event.locationInWindow }
    override func mouseDragged(with event: NSEvent) {
        guard let url = buildURL, let start = dragOrigin else { return }
        guard hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) >= 3 else { return }
        dragOrigin = nil
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(convert(iconView.bounds, from: iconView), contents: NSWorkspace.shared.icon(forFile: url.path))
        beginDraggingSession(with: [item], event: event, source: self)
    }
    override func mouseUp(with event: NSEvent) { dragOrigin = nil }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
}

// MARK: - Link button

/// Borderless text button whose title lines up with neighbouring labels: NSButton insets its title a few points
/// from the frame, so report that inset as an alignment-rect inset and the stack view places the glyphs on the edge.
final class LinkButton: NSButton {
    static let titleInset: CGFloat = 2.5
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets(top: 0, left: LinkButton.titleInset, bottom: 0, right: 0) }
}

// MARK: - Window

final class HelperWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) { performClose(sender) }
#if PERMISSION_RENDER
    // Render harness only: stay where WindowCapture parked it (off every screen), never key.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
#endif
}

// MARK: - Delegate

final class PermissionHelper: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    var window: NSWindow!
    var root = Bundle.main.bundleURL.deletingLastPathComponent()
    let revealButton = NSButton(title: "Show in Finder", target: nil, action: nil)
    let copyButton = NSButton(title: "Copy Path", target: nil, action: nil)
    let chooseLink = LinkButton(title: "Choose Build…", target: nil, action: nil)
    let primary = NSButton(title: "Open System Settings", target: nil, action: nil)
    var tile: BuildTile!
    let hint = NSTextField(wrappingLabelWithString: "")
    static let dragHint = "If dragging doesn’t work, use + in System Settings with the copied path. This helper doesn’t grant access or start Microfish."
    static let chooseHint = "Choose the build that needs access. This helper doesn’t grant access or start Microfish."
    var state: BuildState = .none
    private var copyResetTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        _ = buildWindow()
        refresh()
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate()
    }
    func applicationDidBecomeActive(_ notification: Notification) { if window != nil { refresh() } }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // MARK: Layout

    func label(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight); field.textColor = color
        return field
    }

    /// Builds (but does not show) the window. Used by applicationDidFinishLaunching and the offscreen render harness.
    func buildWindow() -> NSWindow {
        let win = HelperWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 380), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: true)
        win.title = "Microfish Access"
        win.isReleasedWhenClosed = false
        window = win
        let content = NSView()
        win.contentView = content

        let heading = label("Give the new build access", size: 22, weight: .bold)
        heading.setAccessibilityRole(.staticText)
        let sub = label("Microfish needs \(paneName) to move windows.", color: .secondaryLabelColor)

        let stepTexts = ["Open \(paneName) in System Settings.", "Drag the build below into its list.", "Turn on its switch."]
        let steps = NSStackView(views: stepTexts.enumerated().map { index, text in
            let row = NSStackView(views: [StepBadge(index + 1), label(text)])
            row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 10
            return row
        })
        steps.orientation = .vertical; steps.alignment = .leading; steps.spacing = 9

        for button in [revealButton, copyButton] {
            button.bezelStyle = .rounded; button.controlSize = .small
            button.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
            button.target = self
        }
        revealButton.action = #selector(reveal); copyButton.action = #selector(copyPath)
        revealButton.setAccessibilityLabel("Reveal build in Finder")
        copyButton.setAccessibilityLabel("Copy build path")
        copyButton.widthAnchor.constraint(equalToConstant: copyButton.fittingSize.width).isActive = true
        tile = BuildTile(reveal: revealButton, copy: copyButton)

        hint.stringValue = PermissionHelper.dragHint
        hint.font = .systemFont(ofSize: 11); hint.textColor = .secondaryLabelColor
        hint.preferredMaxLayoutWidth = 350
        hint.widthAnchor.constraint(equalToConstant: 350).isActive = true

        chooseLink.isBordered = false
        chooseLink.font = .systemFont(ofSize: 11)
        chooseLink.attributedTitle = NSAttributedString(string: "Choose Build…", attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: Teal.text])
        chooseLink.target = self; chooseLink.action = #selector(choose)
        chooseLink.setAccessibilityLabel("Choose a different build")
        let left = NSStackView(views: [hint, chooseLink])
        left.orientation = .vertical; left.alignment = .leading; left.spacing = 6

        primary.bezelStyle = .rounded
        primary.keyEquivalent = "\r"
        primary.bezelColor = Teal.button
        primary.target = self
        primary.setContentHuggingPriority(.required, for: .horizontal)
        primary.setContentCompressionResistancePriority(.required, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let footer = NSStackView(views: [left, spacer, primary])
        footer.orientation = .horizontal; footer.alignment = .centerY; footer.spacing = 16

        let main = NSStackView(views: [heading, sub, steps, tile, footer])
        main.orientation = .vertical; main.alignment = .leading; main.spacing = 8
        main.setCustomSpacing(4, after: heading)
        main.setCustomSpacing(18, after: sub)
        main.setCustomSpacing(18, after: steps)
        main.setCustomSpacing(14, after: tile)
        main.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(main)
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalToConstant: 600),
            main.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            main.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            main.topAnchor.constraint(equalTo: content.topAnchor, constant: 26),
            main.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            tile.widthAnchor.constraint(equalTo: main.widthAnchor),
            footer.widthAnchor.constraint(equalTo: main.widthAnchor),
        ])
        win.initialFirstResponder = nil
        apply(state)
        content.layoutSubtreeIfNeeded()
        win.setContentSize(content.fittingSize)
        return win
    }

    // MARK: Menus

    func buildMenu() {
        let appName = "Microfish Access"
        let mainMenu = NSMenu()
        func add(_ menu: NSMenu, _ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            if !key.isEmpty { item.keyEquivalentModifierMask = mods }
            if let target { item.target = target }
        }
        func submenu(_ title: String) -> NSMenu {
            let item = mainMenu.addItem(withTitle: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title); item.submenu = menu; return menu
        }
        let app = submenu(appName)
        add(app, "About \(appName)", #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
        app.addItem(.separator())
        add(app, "Hide \(appName)", #selector(NSApplication.hide(_:)), "h")
        add(app, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
        add(app, "Show All", #selector(NSApplication.unhideAllApplications(_:)))
        app.addItem(.separator())
        add(app, "Quit \(appName)", #selector(NSApplication.terminate(_:)), "q")

        let file = submenu("File")
        add(file, "Choose Build…", #selector(choose), "o", target: self)
        add(file, "Show in Finder", #selector(reveal), "r", target: self)
        file.addItem(.separator())
        add(file, "Close", #selector(NSWindow.performClose(_:)), "w")

        let edit = submenu("Edit")
        add(edit, "Copy Path", #selector(copyPath), "c", target: self)

        let windowMenu = submenu("Window")
        add(windowMenu, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(reveal) || item.action == #selector(copyPath) { return tile?.buildURL != nil }
        return true
    }

    // MARK: State

    func refresh() {
        let pending = root.appendingPathComponent("config/permission-build.path")
        if let path = try? String(contentsOf: pending, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
            select(URL(fileURLWithPath: path)); return
        }
        let plist = root.appendingPathComponent("config/trial.plist")
        if let data = try? Data(contentsOf: plist), let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any], let args = dict["ProgramArguments"] as? [String], let first = args.first {
            select(URL(fileURLWithPath: first)); return
        }
        apply(.none)
    }
    func select(_ url: URL) {
        apply(FileManager.default.isExecutableFile(atPath: url.path) ? .ready(url) : .missing(url.path))
    }
    func apply(_ newState: BuildState) {
        state = newState
        tile?.show(newState, paneName: paneName)
        if case .ready = newState {
            primary.title = "Open System Settings"; primary.action = #selector(openSettings)
            primary.setAccessibilityLabel("Open \(paneName) in System Settings")
            chooseLink.isHidden = false
            hint.stringValue = PermissionHelper.dragHint
        } else {
            primary.title = "Choose Build…"; primary.action = #selector(choose)
            primary.setAccessibilityLabel("Choose the build")
            chooseLink.isHidden = true
            hint.stringValue = PermissionHelper.chooseHint
        }
        fitWindow()
    }
    /// Resize to the content (the window is not user-resizable), keeping the top-left corner where it is.
    func fitWindow() {
        guard let window, let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let top = window.frame.maxY
        window.setContentSize(content.fittingSize)
        window.setFrameTopLeftPoint(NSPoint(x: window.frame.minX, y: top))
    }

    // MARK: Actions

    @objc func openSettings() { NSWorkspace.shared.open(paneURL) }
    @objc func reveal() { if let url = tile.buildURL { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
    @objc func copyPath() {
        guard let url = tile.buildURL else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.path, forType: .string)
        copyButton.title = "Copied"
        NSAccessibility.post(element: copyButton, notification: .announcementRequested, userInfo: [.announcement: "Path copied", .priority: NSAccessibilityPriorityLevel.high.rawValue])
        copyResetTimer?.invalidate()
        copyResetTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in self?.copyButton.title = "Copy Path" }
    }
    @objc func choose() {
        let panel = NSOpenPanel()
        panel.directoryURL = root.appendingPathComponent("bin")
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = "Choose the Microfish build to give access."
        panel.prompt = "Choose"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do {
                try (url.path + "\n").write(to: self.root.appendingPathComponent("config/permission-build.path"), atomically: true, encoding: .utf8)
                self.select(url)
            } catch {
                let alert = NSAlert()
                alert.messageText = "Could not save the build selection"
                alert.informativeText = error.localizedDescription
                alert.beginSheetModal(for: self.window)
            }
        }
    }
}

enum Launcher {
    static let delegate = PermissionHelper()   // NSApplication.delegate is weak: keep it alive here
    static func run() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular); app.delegate = delegate; app.run()
    }
}

// The render harness (evidence/permission/render-main.swift) compiles this file with -DPERMISSION_RENDER and
// builds windows offscreen instead of launching.
#if !PERMISSION_RENDER
let _: Void = Launcher.run()
#endif
