import AppKit

private final class MinimapPositionTarget:NSButton {
    override func draw(_ dirtyRect:NSRect) {
        let path=NSBezierPath(roundedRect:bounds.insetBy(dx:0.5,dy:0.5),xRadius:3,yRadius:3)
        (state == .on ? hudColor(hudDark(self) ? 0x3CC6C4:0x007F81):NSColor.controlBackgroundColor).setFill();path.fill()
        NSColor.separatorColor.setStroke();path.lineWidth=1;path.stroke()
    }
}
private final class ShortcutList: NSStackView { override var isFlipped: Bool { true } }

final class SettingsController: NSObject {
    var onApplied: (() -> Void)?
    private let rootURL: URL
    private var window: NSWindow?
    private var values: [String: Any] = [:]
    private var controls: [String: NSControl] = [:]
    private var rows: [[String: Any]] = []
    private var rules: [[String: Any]] = []
    private var aliases: [String: String] = [:]
    private let picker = NSPopUpButton()
    private let rulePicker = NSPopUpButton()
    private let alias = NSTextField()
    private let status = NSTextField(wrappingLabelWithString: "Settings hot reload; runtime behavior awaits engine confirmation.")
    private var save = NSButton()
    private let recorder = ShortcutRecorder()
    private let recordingQueue = DispatchQueue(label: "local.paneru.shortcut-recording")
    private var shortcutCatalog: [[String: String]] = []
    private var shortcuts: [String: String] = [:]
    private var shortcutButtons: [String: NSButton] = [:]
    private var shortcutActions: [NSButton] = []
    private let shortcutStatus = NSTextField(wrappingLabelWithString: "")
    private var recordingID: String?
    private var isApplying = false
    private var settingsTabs: NSTabView?
    private var styleButtons: [NSButton] = []
    private var positionButtons:[NSButton]=[]

    init(rootURL: URL) { self.rootURL = rootURL; super.init() }
    func show() {
        if window == nil { build() }
        window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); refresh()
    }
    private func label(_ text: String) -> NSTextField {
        let f = NSTextField(wrappingLabelWithString: text); f.preferredMaxLayoutWidth = 535; return f
    }
    private func button(_ text: String, _ action: Selector) -> NSButton { NSButton(title: text, target: self, action: action) }
    private func toggle(_ key: String, _ text: String, _ fallback: Bool = false) -> NSView {
        let b = NSButton(checkboxWithTitle: text, target: nil, action: nil)
        b.state = (values[key] as? Bool ?? fallback) ? .on : .off; controls[key] = b; return b
    }
    #if SETTINGS_TESTS
    func renderPages(to directory: URL) throws {
        build()
        let position=controls["minimapPosition"] as! NSPopUpButton
        let savedPosition=position.indexOfSelectedItem
        for button in positionButtons { selectMinimapPosition(button);precondition(position.indexOfSelectedItem==button.tag && positionButtons.filter {$0.state == .on}.count==1) }
        selectMinimapPosition(positionButtons[savedPosition])
        let style=controls["minimapStyle"] as! NSPopUpButton,savedStyle=style.indexOfSelectedItem
        let testSegments=NSSegmentedControl(labels:["Cards","Compact","Titles"],trackingMode:.selectOne,target:nil,action:nil)
        for i in 0..<3 { testSegments.selectedSegment=i;selectMinimapLayout(testSegments);precondition(style.indexOfSelectedItem==i) }
        style.selectItem(at:savedStyle)
        print("Minimap settings: five positions and three layout drafts passed")
        precondition(!shortcutCatalog.isEmpty && shortcutButtons.count == shortcutCatalog.count)
        precondition(shortcutConflicts().isEmpty && save.isEnabled)
        let before = shortcuts
        let ids = shortcuts.keys.sorted(); shortcuts[ids[0]] = shortcuts[ids[1]]
        updateShortcutUI(); precondition(!shortcutConflicts().isEmpty && !save.isEnabled)
        shortcuts[ids[0]] = ""; updateShortcutUI(); precondition(shortcutConflicts().isEmpty && save.isEnabled)
        shortcuts = before; updateShortcutUI()
        print("Shortcut drafts: catalogue, defaults, conflict blocking, clear checks passed")
        guard let host = window?.contentView, let body = host.subviews.first as? NSStackView, let tabs = body.arrangedSubviews.first as? NSTabView else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for index in 0..<tabs.numberOfTabViewItems {
            tabs.selectTabViewItem(at: index); host.layoutSubtreeIfNeeded()
            if let page = tabs.selectedTabViewItem?.view {
                func inspect(_ view: NSView) {
                    let frame = view.convert(view.bounds, to: page)
                    precondition(frame.minX >= -1 && frame.minY >= -1 && frame.maxX <= page.bounds.width + 1 && frame.maxY <= page.bounds.height + 1, "Clipped settings view: \(view) \(frame) page \(page.bounds)")
                    if let scroll = view as? NSScrollView, let list = scroll.documentView as? ShortcutList {
                        list.layoutSubtreeIfNeeded()
                        precondition(list.arrangedSubviews.count == shortcutCatalog.count && list.frame.height > scroll.contentView.bounds.height)
                        for row in list.arrangedSubviews {
                            precondition(row.frame.minX >= -1 && row.frame.maxX <= list.bounds.width + 1)
                            for control in row.subviews { let aligned = control.alignmentRect(forFrame: control.frame); precondition(aligned.minX >= -1 && aligned.maxX <= row.bounds.width + 1, "Control \(control) alignment \(aligned) row \(row.bounds)") }
                        }
                        precondition(list.arrangedSubviews.first!.frame.intersects(scroll.documentVisibleRect), "First shortcut must be visible initially")
                    }
                    if !(view is NSClipView) { for child in view.subviews { inspect(child) } }
                }
                for child in page.subviews { inspect(child) }
                print("Settings page \(index): layout bounds passed")
            }
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            if let data = bitmap.representation(using: .png, properties: [:]) { try data.write(to: directory.appendingPathComponent("settings-\(index).png")) }
        }
    }
    #endif
    private static let ranges: [String: ClosedRange<Double>] = ["sliverWidth": 0...200, "padding": 0...100, "windowGap": 0...100, "swipeSensitivity": 0.1...2, "swipeDeceleration": 1...10, "borderWidth": 0...12, "borderRadius": 0...60, "minimapDelay": 0.1...10, "minimapFade": 0...3, "hyperHoldDelay": 0.05...2, "rowCount": 2...9]
    private func number(_ key: String, _ text: String, _ fallback: Double) -> NSView {
        let f = NSTextField(string: String(describing: values[key] ?? fallback)); f.widthAnchor.constraint(equalToConstant: 90).isActive = true
        controls[key] = f
        let range = Self.ranges[key].map { "(\($0.lowerBound)–\($0.upperBound))" } ?? ""
        return NSStackView(views: [label(text), f, label(range)])
    }
    private func choice(_ key: String, _ text: String, _ options: [String], _ fallback: String) -> NSView {
        let p = NSPopUpButton(); p.addItems(withTitles: options); p.selectItem(withTitle: String(describing: values[key] ?? fallback)); controls[key] = p
        return NSStackView(views: [label(text), p])
    }
    private func build() {
        if let data = try? Data(contentsOf: rootURL.appendingPathComponent("config/preferences.json")), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { values = json }
        rules = values["floatingRules"] as? [[String: Any]] ?? []; aliases = values["tabAliases"] as? [String: String] ?? [:]
        if let data = try? Data(contentsOf: rootURL.appendingPathComponent("config/shortcut-defaults.json")), let catalog = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] { shortcutCatalog = catalog }
        shortcuts = Dictionary(uniqueKeysWithValues: shortcutCatalog.compactMap { item in guard let id = item["id"], let chord = item["default"] else { return nil }; return (id, chord) })
        shortcuts.merge(values["shortcuts"] as? [String: String] ?? [:]) { _, saved in saved }
        configureRecorder()
        let tabs = NSTabView(); settingsTabs = tabs
        func page(_ title: String, _ views: [NSView]) {
            let content = NSStackView(views: views); content.orientation = .vertical; content.alignment = .leading; content.spacing = 10
            let holder = NSView(); holder.addSubview(content); content.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: 18), content.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -18), content.topAnchor.constraint(equalTo: holder.topAnchor, constant: 18)])
            let item = NSTabViewItem(identifier: title); item.label = title; item.view = holder; tabs.addTabViewItem(item)
        }
        page("Behavior", [toggle("dragReorder", "Drag title bars to reorder columns", false), toggle("focusFollowsMouse", "Focus follows mouse"), toggle("mouseFollowsFocus", "Mouse follows focus"), toggle("autoCenter", "Automatically center focused windows"), number("sliverWidth", "Edge sliver (pt)", 20), number("padding", "Outer padding (pt)", 4), number("windowGap", "Window padding per side (pt)", 4), number("swipeSensitivity", "Swipe sensitivity", 0.35), number("swipeDeceleration", "Swipe deceleration", 6), choice("swipeFingers", "Swipe fingers", ["3", "4"], "3"), toggle("reverseSwipe", "Reverse swipe direction"), choice("scrollModifier", "Modifier scroll", ["hyper", "controlOption"], "hyper")])
        page("Rows", [toggle("rowsEnabled", "Enable virtual rows", false), label("Hyper + Up / K above the top row or Down / J below the bottom row creates a row when the current row is populated (up to 9). Empty rows disappear when you leave them; the current row is always kept."), label("Hyper + Up / Down or K / J changes rows; H / L moves horizontally. Shift + Up / Down moves the selected window; Shift + U / I moves its column. Added rows persist with the session."), label("With rows disabled, Up / Down focuses within a stack and Shift + Up / Down swaps windows. Whole-column row commands are inactive.")])
        page("Shortcuts", [label("Click a shortcut, then press a key with Control, Option, or Command. Escape cancels. Engine shortcuts pause during capture and resume automatically."), shortcutPage(), shortcutStatus, NSStackView(views: [button("Reset all shortcuts", #selector(resetAllShortcuts)), button("Cancel recording", #selector(cancelRecording))])])
        let well = NSColorWell(); let hex = UInt32((values["borderColor"] as? String ?? "#009193").dropFirst(), radix: 16) ?? 0x009193
        well.color = NSColor(srgbRed: CGFloat((hex >> 16)&255)/255, green: CGFloat((hex >> 8)&255)/255, blue: CGFloat(hex&255)/255, alpha: 1); controls["borderColor"] = well
        page("Appearance", [NSStackView(views: [label("Focused window border"), well]), number("borderWidth", "Border width (pt)", 2), number("borderRadius", "Border radius (pt)", 14), label("Tab bars"), tabStylePicker(), tabHeightPicker(), toggle("tabMatchAppColor", "Match selected tab to app color"), button("Enable color sampling access…", #selector(colorAccess)), label("Color sampling needs Screen Recording access; otherwise tabs use theme colors."), button("Rename individual tabs → Window rules", #selector(openWindowRules))])
        page("Minimap", minimapPage())
        picker.target = self; picker.action = #selector(selectionChanged)
        picker.widthAnchor.constraint(equalToConstant: 535).isActive = true; rulePicker.widthAnchor.constraint(equalToConstant: 535).isActive = true
        alias.placeholderString = "Custom tab title"; alias.widthAnchor.constraint(equalToConstant: 400).isActive = true
        page("Window rules", [toggle("floatPip", "Automatically float Picture in Picture", true), label("Title heuristic: Picture in Picture, Picture-in-Picture, or PiP (case insensitive)."), button("Refresh current windows", #selector(refresh)), picker, NSStackView(views: [button("Always float window", #selector(floatWindow)), button("Always float app", #selector(floatApp))]), rulePicker, NSStackView(views: [button("Remove selected rule", #selector(removeRule)), button("Enable / disable rule", #selector(toggleRule))]), label("Removing a rule does not re-tile existing windows; use Hyper+Space."), label("Tab title for selected window"), alias, NSStackView(views: [button("Set title", #selector(setAlias)), button("Reset title", #selector(resetAlias))]), label("Rules and titles are drafts until Apply. Exact window titles may change as documents change.")])
        save = button("Apply", #selector(apply)); save.keyEquivalent = "\r"
        let body = NSStackView(views: [tabs, status, NSStackView(views:[button("Revert",#selector(revertSettings)),save])]); body.orientation = .vertical; body.alignment = .leading; body.spacing = 12; body.translatesAutoresizingMaskIntoConstraints = false
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 650), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "Microfish Settings"; w.isReleasedWhenClosed = false; let host = w.contentView!; host.addSubview(body)
        NSLayoutConstraint.activate([body.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 18), body.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -18), body.topAnchor.constraint(equalTo: host.topAnchor, constant: 18), body.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -18), tabs.widthAnchor.constraint(equalTo: body.widthAnchor), tabs.heightAnchor.constraint(equalToConstant: 510)])
        w.center(); window = w; updateRules(); updateShortcutUI()
    }
    private func minimapPage()->[NSView] {
        let positions=["top","left","center","right","bottom"]
        let hidden=NSPopUpButton();hidden.addItems(withTitles:positions);hidden.selectItem(withTitle:values["minimapPosition"] as? String ?? "bottom");controls["minimapPosition"]=hidden
        let diagram=NSView();diagram.wantsLayer=true;diagram.layer?.backgroundColor=NSColor.quaternaryLabelColor.cgColor;diagram.layer?.cornerRadius=8
        diagram.widthAnchor.constraint(equalToConstant:150).isActive=true;diagram.heightAnchor.constraint(equalToConstant:92).isActive=true
        let frames=[CGRect(x:60,y:70,width:30,height:16),CGRect(x:8,y:35,width:20,height:24),CGRect(x:54,y:30,width:42,height:32),CGRect(x:122,y:35,width:20,height:24),CGRect(x:60,y:6,width:30,height:16)]
        positionButtons=positions.enumerated().map { i,name in
            let b=MinimapPositionTarget(frame:frames[i]);b.tag=i;b.title="";b.bezelStyle = .regularSquare;b.setButtonType(.toggle);b.target=self;b.action=#selector(selectMinimapPosition(_:));b.toolTip=name.capitalized;b.setAccessibilityLabel("Minimap position: \(name)");b.state=hidden.indexOfSelectedItem==i ? .on:.off;b.contentTintColor = hudColor(0x007F81);diagram.addSubview(b);return b
        }
        let layout=NSPopUpButton();let styles=["cards","compact","titles"];layout.addItems(withTitles:styles);layout.selectItem(withTitle:values["minimapStyle"] as? String ?? "cards");controls["minimapStyle"]=layout
        let segments=NSSegmentedControl(labels:["Cards","Compact","Titles"],trackingMode:.selectOne,target:self,action:#selector(selectMinimapLayout(_:)));segments.selectedSegment=layout.indexOfSelectedItem
        let choices=NSStackView(views:[NSStackView(views:[label("Position"),diagram]),NSStackView(views:[label("Show"),segments])]);choices.orientation = .vertical;choices.alignment = .leading;choices.spacing=10
        func heading(_ text:String)->NSTextField { let f=label(text);f.font = .systemFont(ofSize:12,weight:.semibold);return f }
        func timing(_ key:String,_ title:String,_ hint:String,_ fallback:Double)->NSView {
            let field=NSTextField(string:String(describing:values[key] ?? fallback));field.widthAnchor.constraint(equalToConstant:70).isActive=true;controls[key]=field
            let hintLabel=label(hint);hintLabel.font = .systemFont(ofSize:10);hintLabel.textColor = .secondaryLabelColor
            let text=NSStackView(views:[label(title),hintLabel]);text.orientation = .vertical;text.alignment = .leading;text.spacing=2;text.widthAnchor.constraint(equalToConstant:350).isActive=true
            return NSStackView(views:[text,field,label("s")])
        }
        return [choices,heading("Timing"),timing("minimapDelay","Hide after","Counted from the end of navigation · 0.1–10",1.3),timing("minimapFade","Fade","0–3",0.22),heading("Reveal"),toggle("showOnHyper","Show while Hyper is held",true),timing("hyperHoldDelay","Hold for","0.05–2",0.2),label("Arrow navigation and scrolling always reveal the minimap.")]
    }
    @objc private func selectMinimapPosition(_ sender:NSButton) {
        (controls["minimapPosition"] as? NSPopUpButton)?.selectItem(at:sender.tag)
        for b in positionButtons { b.state=b===sender ? .on:.off }
    }
    @objc private func selectMinimapLayout(_ sender:NSSegmentedControl) { (controls["minimapStyle"] as? NSPopUpButton)?.selectItem(at:sender.selectedSegment) }
    @objc private func revertSettings() { guard !isApplying, recordingID == nil else { return };window?.close();window=nil;controls=[:];shortcutButtons=[:];shortcutActions=[];build();window?.makeKeyAndOrderFront(nil);refresh() }
    private func tabHeightPicker() -> NSView {
        let p=NSPopUpButton();p.addItems(withTitles:["Standard · 28 pt","Roomy · 34 pt"])
        p.selectItem(at:(values["tabHeight"] as? Int ?? 34)==28 ? 0:1);controls["tabHeight"]=p
        let row=NSStackView(views:[label("Tab height"),p])
        let stack=NSStackView(views:[row,label("Folder Compact uses 20 / 25 pt. Side uses the window height.")]);stack.orientation = .vertical;stack.alignment = .leading
        return stack
    }
    private func tabStylePicker() -> NSView {
        let names=["folder","folder-compact","classic","side"]
        let hidden=NSPopUpButton();hidden.addItems(withTitles:names);hidden.selectItem(withTitle:values["tabStyle"] as? String ?? "folder");controls["tabStyle"]=hidden
        styleButtons=names.enumerated().map { index,name in
            let b=NSButton(title:name == "folder-compact" ? "Folder Compact":name.capitalized,target:self,action:#selector(selectTabStyle(_:)))
            b.tag=index;b.setButtonType(.toggle);b.bezelStyle = .regularSquare;b.imagePosition = .imageAbove
            b.image=NSImage(size:NSSize(width:114,height:42),flipped:false) { rect in
                NSColor.controlBackgroundColor.setFill();NSBezierPath(roundedRect:rect.insetBy(dx:2,dy:1),xRadius:4,yRadius:4).fill()
                let page=CGRect(x:20,y:3,width:80,height:28)
                NSColor.windowBackgroundColor.setFill();page.fill()
                for i in 0..<3 {
                    let r=name == "side" ? CGRect(x:9,y:3+CGFloat(i)*9,width:11,height:9) : CGRect(x:20+CGFloat(i)*26,y:31,width:26,height:9)
                    (i == 1 ? NSColor.windowBackgroundColor:NSColor.disabledControlTextColor.withAlphaComponent(0.45)).setFill()
                    let path=name.hasPrefix("folder") ? folderTabPath(in:r,selected:i==1,compact:name == "folder-compact"):NSBezierPath(rect:r)
                    path.fill();NSColor.separatorColor.setStroke();path.lineWidth=0.5;path.stroke()
                }
                return true
            }
            b.state=hidden.indexOfSelectedItem == index ? .on:.off
            b.widthAnchor.constraint(equalToConstant:125).isActive=true;b.heightAnchor.constraint(equalToConstant:70).isActive=true
            return b
        }
        return NSStackView(views:styleButtons)
    }
    @objc private func selectTabStyle(_ sender:NSButton) {
        (controls["tabStyle"] as? NSPopUpButton)?.selectItem(at:sender.tag)
        for b in styleButtons {b.state=b===sender ? .on:.off}
    }
    @objc private func openWindowRules() { settingsTabs?.selectTabViewItem(withIdentifier:"Window rules") }
    @objc private func colorAccess() {
        if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
    }
    private var selected: [String: Any]? { rows.indices.contains(picker.indexOfSelectedItem) ? rows[picker.indexOfSelectedItem] : nil }
    private func key(_ row: [String: Any]) -> String { (row["bundle_id"] as? String ?? "") + "\t" + (row["title"] as? String ?? "") }
    @objc private func selectionChanged() { alias.stringValue = selected.flatMap { aliases[key($0)] } ?? "" }
    private func updateRules() {
        rulePicker.removeAllItems()
        for r in rules { rulePicker.addItem(withTitle: "\((r["enabled"] as? Bool ?? true) ? "" : "[Disabled] ")\(r["bundle"] as? String ?? "") · \(r["titlePattern"] as? String ?? "")") }
        if rules.isEmpty { rulePicker.addItem(withTitle: "No floating rules") }
    }
    @objc private func toggleRule() { let i = rulePicker.indexOfSelectedItem; if rules.indices.contains(i) { rules[i]["enabled"] = !(rules[i]["enabled"] as? Bool ?? true); updateRules(); rulePicker.selectItem(at: i) } }
    @objc private func floatWindow() { addRule(true) }
    @objc private func floatApp() { addRule(false) }
    private func addRule(_ exact: Bool) {
        guard let row = selected, let bundle = row["bundle_id"] as? String, !bundle.isEmpty else { status.stringValue = "Select a window with an app identifier first."; return }
        let pattern = exact ? "^" + Self.escapeRegex(row["title"] as? String ?? "") + "$" : ".*"
        if !rules.contains(where: { $0["bundle"] as? String == bundle && $0["titlePattern"] as? String == pattern }) { rules.append(["id": UUID().uuidString, "bundle": bundle, "titlePattern": pattern, "enabled": true]); updateRules() }
        status.stringValue = "Rule added to draft. Apply to save."
    }
    @objc private func removeRule() { let i = rulePicker.indexOfSelectedItem; if rules.indices.contains(i) { rules.remove(at: i); updateRules() } }
    @objc private func setAlias() { guard let row = selected else { return }; let text = alias.stringValue.trimmingCharacters(in: .whitespacesAndNewlines); if text.isEmpty { aliases.removeValue(forKey: key(row)) } else { aliases[key(row)] = text }; status.stringValue = "Tab title updated in draft. Apply to save." }
    @objc private func resetAlias() { guard let row = selected else { return }; aliases.removeValue(forKey: key(row)); alias.stringValue = ""; status.stringValue = "Title reset in draft. Apply to save." }
    @objc private func refresh() {
        let root = rootURL; status.stringValue = "Reading windows…"
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let data = try Data(contentsOf: root.appendingPathComponent("config/trial.plist"))
                let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
                guard let executable = (plist?["ProgramArguments"] as? [String])?.first else { throw NSError(domain: "Settings", code: 1, userInfo: [NSLocalizedDescriptionKey: "No trial executable configured."]) }
                let result = try Self.run(executable, ["query", "state", "--json"])
                guard result.0 == 0, let state = try JSONSerialization.jsonObject(with: result.1) as? [String: Any] else { throw NSError(domain: "Settings", code: 2, userInfo: [NSLocalizedDescriptionKey: "Window query failed: " + String(decoding: result.1, as: UTF8.self)]) }
                let rows = (state["virtual_workspaces"] as? [[String: Any]] ?? []).flatMap { $0["windows"] as? [[String: Any]] ?? [] }
                let focused = (state["active"] as? [String: Any])?["focused_window_id"] as? NSNumber
                DispatchQueue.main.async {
                    self.rows = rows; self.picker.removeAllItems()
                    for row in rows { self.picker.addItem(withTitle: "\(row["app_name"] as? String ?? "App") — \(row["title"] as? String ?? "Untitled")\((row["floating"] as? Bool ?? false) ? " [floating]" : "")") }
                    if let focused, let i = rows.firstIndex(where: { $0["window_id"] as? NSNumber == focused }) { self.picker.selectItem(at: i) }
                    self.selectionChanged(); self.status.stringValue = "Window list refreshed. Rules and titles save with Apply."
                }
            } catch { DispatchQueue.main.async { self.status.stringValue = error.localizedDescription } }
        }
    }
    @objc private func apply() {
        guard !isApplying, recordingID == nil else { status.stringValue = "Finish or cancel shortcut recording before applying."; return }
        guard shortcutConflicts().isEmpty else { status.stringValue = "Resolve shortcut conflicts before applying."; return }
        guard !shortcutCatalog.isEmpty else { status.stringValue = "Shortcut catalogue is unavailable; settings were not changed."; return }
        var draft = values
        for (key, control) in controls {
            if let p = control as? NSPopUpButton { if key == "tabHeight" { draft[key] = p.indexOfSelectedItem == 0 ? 28:34 } else if key == "swipeFingers" { draft[key] = Int(p.titleOfSelectedItem ?? "3") ?? 3 } else { draft[key] = p.titleOfSelectedItem ?? "" } }
            else if let b = control as? NSButton { draft[key] = b.state == .on }
            else if let c = control as? NSColorWell, let rgb = c.color.usingColorSpace(.sRGB) { draft[key] = String(format: "#%02X%02X%02X", Int((rgb.redComponent*255).rounded()), Int((rgb.greenComponent*255).rounded()), Int((rgb.blueComponent*255).rounded())) }
            else if let f = control as? NSTextField { guard let n = Double(f.stringValue), n.isFinite else { status.stringValue = "Enter a valid number for \(key)."; return }
                if let range = Self.ranges[key], !range.contains(n) { status.stringValue = "\(key) must be between \(range.lowerBound) and \(range.upperBound)."; return }
                if ["sliverWidth", "padding", "windowGap", "rowCount"].contains(key), n.rounded() != n { status.stringValue = "\(key) must be a whole number."; return }
                draft[key] = n }
        }
        draft["floatingRules"] = rules; draft["tabAliases"] = aliases; draft["shortcuts"] = shortcuts
        let root = rootURL; let submitted = draft; isApplying = true; updateShortcutUI(); status.stringValue = "Validating settings and requesting reload…"
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let directory = root.appendingPathComponent("work/settings-drafts"); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let path = directory.appendingPathComponent(UUID().uuidString + ".json")
                try JSONSerialization.data(withJSONObject: submitted, options: [.prettyPrinted, .sortedKeys]).write(to: path, options: .atomic)
                let result = try Self.run("/usr/bin/python3", [root.appendingPathComponent("scripts/apply-settings.py").path, path.path])
                let message = String(decoding: result.1, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                DispatchQueue.main.async {
                    self.isApplying = false; self.updateShortcutUI()
                    if result.0 == 0 { self.values = submitted; self.status.stringValue = message.isEmpty ? "Saved; reload requested. Runtime behavior awaits engine confirmation." : message; self.onApplied?(); try? FileManager.default.removeItem(at: path) }
                    else { self.status.stringValue = "Apply failed (\(result.0)); draft retained at \(path.path). \(message)" }
                }
            } catch { DispatchQueue.main.async { self.isApplying = false; self.updateShortcutUI(); self.status.stringValue = "Apply failed: " + error.localizedDescription } }
        }
    }
    private func shortcutPage() -> NSView {
        let content = ShortcutList(); content.orientation = .vertical; content.alignment = .leading; content.spacing = 7
        for item in shortcutCatalog {
            guard let id = item["id"] else { continue }
            let title = NSTextField(labelWithString: item["label"] ?? id); title.widthAnchor.constraint(equalToConstant: 225).isActive = true
            let record = button("", #selector(recordShortcut(_:))); record.identifier = NSUserInterfaceItemIdentifier(id); record.widthAnchor.constraint(equalToConstant: 205).isActive = true; shortcutButtons[id] = record
            let reset = button("Reset", #selector(resetShortcut(_:))); reset.identifier = NSUserInterfaceItemIdentifier(id)
            let clear = button("Clear", #selector(clearShortcut(_:))); clear.identifier = NSUserInterfaceItemIdentifier(id)
            shortcutActions += [record, reset, clear]
            content.addArrangedSubview(NSStackView(views: [title, record, reset, clear]))
        }
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false; scroll.documentView = content
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor), content.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor), content.topAnchor.constraint(equalTo: scroll.contentView.topAnchor), scroll.heightAnchor.constraint(equalToConstant: 330), scroll.widthAnchor.constraint(equalToConstant: 568)])
        return scroll
    }
    private func configureRecorder() {
        let bridge = rootURL.appendingPathComponent("bin/PaneruNavigatorCommand").path
        let queue = recordingQueue
        recorder.suspend = { completion in
            let token = UUID().uuidString.lowercased()
            queue.async {
                do {
                    let result = try Self.run(bridge, ["record-begin", token])
                    guard result.0 == 0 else { throw NSError(domain: "ShortcutRecorder", code: Int(result.0), userInfo: [NSLocalizedDescriptionKey: "Could not pause engine shortcuts: " + String(decoding: result.1, as: UTF8.self)]) }
                    completion(.success({ queue.async { _ = try? Self.run(bridge, ["record-end", token]) } }))
                } catch {
                    // A timed-out acknowledgement may still have installed the lease.
                    _ = try? Self.run(bridge, ["record-end", token])
                    completion(.failure(error))
                }
            }
        }
        recorder.didFinish = { [weak self] chord, error in
            guard let self else { return }
            if let id = self.recordingID, let chord { self.shortcuts[id] = chord }
            self.recordingID = nil; self.updateShortcutUI()
            if let error { self.shortcutStatus.stringValue = error }
        }
    }
    private func shortcutConflicts() -> [[String]] {
        Dictionary(grouping: shortcuts.keys.filter { !(shortcuts[$0] ?? "").isEmpty }, by: { shortcuts[$0]! }).values.filter { $0.count > 1 }.map { $0.sorted() }.sorted { $0[0] < $1[0] }
    }
    private func updateShortcutUI() {
        let conflicts = shortcutConflicts()
        let duplicates = Set(conflicts.flatMap { $0 })
        for (id, control) in shortcutButtons {
            control.title = recordingID == id ? "Press shortcut… (Esc cancels)" : Self.displayChord(shortcuts[id] ?? "")
            control.contentTintColor = duplicates.contains(id) ? .systemRed : nil
            control.setAccessibilityLabel((shortcutCatalog.first { $0["id"] == id }?["label"] ?? id) + ": " + control.title)
        }
        shortcutActions.forEach { $0.isEnabled = recordingID == nil && !isApplying }
        save.isEnabled = !isApplying && recordingID == nil && conflicts.isEmpty && !shortcutCatalog.isEmpty
        if recordingID != nil { shortcutStatus.stringValue = "Pausing engine shortcuts, then listening. Escape cancels; recording expires after 12 seconds." }
        else if shortcutCatalog.isEmpty { shortcutStatus.stringValue = "Shortcut catalogue unavailable. Apply is disabled." }
        else if conflicts.isEmpty { shortcutStatus.stringValue = "Shortcut changes are drafts until Apply. Clear disables an action." }
        else {
            let ids = conflicts[0]
            let names = ids.prefix(2).map { id in shortcutCatalog.first { $0["id"] == id }?["label"] ?? id }.joined(separator: " / ")
            shortcutStatus.stringValue = "Conflict: " + names + (ids.count > 2 ? " and \(ids.count - 2) more" : "") + (conflicts.count > 1 ? ". \(conflicts.count) conflicting groups." : ".") + " Resolve red shortcuts before Apply."
        }
    }
    static func displayChord(_ chord: String) -> String {
        if chord.isEmpty { return "Disabled — click to record" }
        return chord.replacingOccurrences(of: "ctrl + ", with: "⌃").replacingOccurrences(of: "alt + ", with: "⌥").replacingOccurrences(of: "cmd + ", with: "⌘").replacingOccurrences(of: "shift - ", with: "⇧").replacingOccurrences(of: "ctrl - ", with: "⌃").replacingOccurrences(of: "alt - ", with: "⌥").replacingOccurrences(of: "cmd - ", with: "⌘").replacingOccurrences(of: "leftarrow", with: "←").replacingOccurrences(of: "rightarrow", with: "→").replacingOccurrences(of: "uparrow", with: "↑").replacingOccurrences(of: "downarrow", with: "↓").uppercased()
    }
    @objc private func recordShortcut(_ sender: NSButton) {
        guard !isApplying, recordingID == nil, let id = sender.identifier?.rawValue, let window else { return }
        recordingID = id; updateShortcutUI(); recorder.begin(window: window)
    }
    @objc private func cancelRecording() { recorder.cancel() }
    @objc private func resetShortcut(_ sender: NSButton) {
        guard !isApplying, recordingID == nil, let id = sender.identifier?.rawValue else { return }
        shortcuts[id] = shortcutCatalog.first { $0["id"] == id }?["default"] ?? ""; updateShortcutUI()
    }
    @objc private func clearShortcut(_ sender: NSButton) { guard !isApplying, recordingID == nil, let id = sender.identifier?.rawValue else { return }; shortcuts[id] = ""; updateShortcutUI() }
    @objc private func resetAllShortcuts() {
        guard !isApplying, recordingID == nil else { return }
        for item in shortcutCatalog { if let id = item["id"] { shortcuts[id] = item["default"] ?? "" } }; updateShortcutUI()
    }
    // Match Rust regex escaping rather than relying on ICU-specific quoting.
    static func escapeRegex(_ text: String) -> String {
        let special = Set("\\.+*?()|[]{}^$#&-~")
        return text.map { special.contains($0) ? "\\" + String($0) : String($0) }.joined()
    }
    private static func run(_ executable: String, _ arguments: [String]) throws -> (Int32, Data) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: executable); p.arguments = arguments
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe; try p.run()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
        timer.schedule(deadline: .now() + 15)
        timer.setEventHandler { if p.isRunning { p.terminate() } }
        timer.resume(); defer { timer.cancel() }
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit(); return (p.terminationStatus, data)
    }
}
