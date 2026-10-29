import AppKit
import SwiftUI
import Observation

// Microfish Settings: an AppKit preferences window (NSToolbar, preference style) whose panes are
// SwiftUI grouped forms. One draft spans every pane; Apply hands it to SettingsApply (SettingsApply.swift),
// which owns validation and the generated Lua. Only keys the user changed are rewritten, so saved
// values the UI cannot represent exactly survive an Apply untouched.

// MARK: - Preferences

struct FloatRule: Hashable, Identifiable { var id: String; var bundle: String; var titlePattern: String; var enabled: Bool }

struct SettingsPrefs: Equatable {
    var dragReorder = false, focusFollowsMouse = false, mouseFollowsFocus = false, autoCenter = false
    var sliverWidth = 20.0, padding = 4.0, windowGap = 4.0
    var swipeSensitivity = 0.35, swipeDeceleration = 6.0, swipeFingers = 3, reverseSwipe = false, scrollModifier = "hyper"
    var borderColor = "#009193", borderWidth = 2.0, borderRadius = 14.0
    var tabStyle = "folder", tabHeight = 34, tabMatchAppColor = false
    var minimapHide = "release"
    var minimapPosition = "bottom", minimapStyle = "cards", minimapDelay = 1.3, minimapFade = 0.22, showOnHyper = true, hyperHoldDelay = 0.2
    var rowsEnabled = false, rowCount = 2
    var floatPip = true, floatingRules: [FloatRule] = [], tabAliases: [String: String] = [:]
    var shortcuts: [String: String] = [:]

    struct Field {
        let key: String
        let read: (inout SettingsPrefs, Any) -> Void
        let write: (SettingsPrefs) -> Any
        let same: (SettingsPrefs, SettingsPrefs) -> Bool
        let adopt: (inout SettingsPrefs, SettingsPrefs) -> Void
    }
    private static func field<T: Equatable>(_ key: String, _ path: WritableKeyPath<SettingsPrefs, T>, _ decode: @escaping (Any) -> T?, _ encode: @escaping (T) -> Any) -> Field {
        Field(key: key, read: { p, v in if let x = decode(v) { p[keyPath: path] = x } }, write: { encode($0[keyPath: path]) },
              same: { $0[keyPath: path] == $1[keyPath: path] }, adopt: { $0[keyPath: path] = $1[keyPath: path] })
    }
    private static func bool(_ v: Any) -> Bool? { (v as? NSNumber).flatMap { CFGetTypeID($0) == CFBooleanGetTypeID() ? $0.boolValue : nil } }
    private static func double(_ v: Any) -> Double? { (v as? NSNumber).flatMap { CFGetTypeID($0) == CFBooleanGetTypeID() || !$0.doubleValue.isFinite ? nil : $0.doubleValue } }
    private static func int(_ v: Any) -> Int? { double(v).flatMap { $0.rounded() == $0 ? Int($0) : nil } ?? (v as? String).flatMap { Int($0) } }
    private static func b(_ key: String, _ p: WritableKeyPath<SettingsPrefs, Bool>) -> Field { field(key, p, bool) { $0 } }
    private static func d(_ key: String, _ p: WritableKeyPath<SettingsPrefs, Double>) -> Field { field(key, p, double) { $0.rounded() == $0 && abs($0) < 1e9 ? Int($0) as Any : $0 as Any } }
    private static func i(_ key: String, _ p: WritableKeyPath<SettingsPrefs, Int>) -> Field { field(key, p, int) { $0 } }
    private static func s(_ key: String, _ p: WritableKeyPath<SettingsPrefs, String>) -> Field { field(key, p, { $0 as? String }) { $0 } }

    static let fields: [Field] = [
        b("dragReorder", \.dragReorder), b("focusFollowsMouse", \.focusFollowsMouse), b("mouseFollowsFocus", \.mouseFollowsFocus), b("autoCenter", \.autoCenter),
        d("sliverWidth", \.sliverWidth), d("padding", \.padding), d("windowGap", \.windowGap),
        d("swipeSensitivity", \.swipeSensitivity), d("swipeDeceleration", \.swipeDeceleration), i("swipeFingers", \.swipeFingers), b("reverseSwipe", \.reverseSwipe), s("scrollModifier", \.scrollModifier),
        s("borderColor", \.borderColor), d("borderWidth", \.borderWidth), d("borderRadius", \.borderRadius),
        s("tabStyle", \.tabStyle), i("tabHeight", \.tabHeight), b("tabMatchAppColor", \.tabMatchAppColor),
        field("minimapHide", \.minimapHide, { ($0 as? String).flatMap { ["release", "timer"].contains($0) ? $0 : nil } }) { $0 },
        s("minimapPosition", \.minimapPosition), s("minimapStyle", \.minimapStyle), d("minimapDelay", \.minimapDelay), d("minimapFade", \.minimapFade), b("showOnHyper", \.showOnHyper), d("hyperHoldDelay", \.hyperHoldDelay),
        b("rowsEnabled", \.rowsEnabled), i("rowCount", \.rowCount), b("floatPip", \.floatPip),
        field("floatingRules", \.floatingRules, { v in
            (v as? [[String: Any]]).map { $0.map { FloatRule(id: $0["id"] as? String ?? UUID().uuidString, bundle: $0["bundle"] as? String ?? "", titlePattern: $0["titlePattern"] as? String ?? "", enabled: bool($0["enabled"] ?? true) ?? true) } }
        }) { $0.map { ["id": $0.id, "bundle": $0.bundle, "titlePattern": $0.titlePattern, "enabled": $0.enabled] as [String: Any] } },
        field("tabAliases", \.tabAliases, { $0 as? [String: String] }) { $0 },
        field("shortcuts", \.shortcuts, { $0 as? [String: String] }) { $0 },
    ]
    static let ranges: [String: ClosedRange<Double>] = ["sliverWidth": 0...200, "padding": 0...100, "windowGap": 0...100, "swipeSensitivity": 0.1...2, "swipeDeceleration": 1...10, "borderWidth": 0...12, "borderRadius": 0...60, "minimapDelay": 0.1...10, "minimapFade": 0...3, "hyperHoldDelay": 0.05...2]

    init() {}
    init(_ raw: [String: Any], defaults: [String: String]) {
        for f in Self.fields { if let v = raw[f.key] { f.read(&self, v) } }
        shortcuts = defaults.merging(shortcuts) { _, saved in saved }
    }
    func changedKeys(from base: SettingsPrefs) -> [String] { Self.fields.filter { !$0.same(self, base) }.map(\.key) }
}

struct ShortcutAction { let id: String; let label: String; let chord: String; let command: String }

// Presentation only: groups and paired rows over the catalogue in the bundled shortcut-defaults.json.
// Catalogue entries missing here still appear, under "Other", so a new action is never hidden.
enum ShortcutLayout {
    struct Row: Identifiable { let id: String; let title: String; let ids: [String] }
    struct Group: Identifiable { let id: String; let rows: [Row] }
    static func groups(_ catalog: [ShortcutAction], rowsEnabled: Bool) -> [Group] {
        func r(_ title: String, _ ids: String...) -> Row { Row(id: ids.joined(separator: "+"), title: title, ids: ids) }
        var layout: [Group] = [
            Group(id: "Navigate", rows: [r("Focus left", "focus_leftarrow", "focus_h"), r("Focus right", "focus_rightarrow", "focus_l"),
                                        r(rowsEnabled ? "Row up" : "Focus up in stack", "row_north", "focus_k"), r(rowsEnabled ? "Row down" : "Focus down in stack", "row_south", "focus_j"),
                                        r("Previous view", "view_back"), r("Next display", "display")]),
            Group(id: "Arrange", rows: [r("Swap left", "swap_leftarrow", "swap_h"), r("Swap right", "swap_rightarrow", "swap_l"), r("Swap up in stack", "swap_k"), r("Swap down in stack", "swap_j"),
                                       r(rowsEnabled ? "Move window to row above or below" : "Swap up or down in stack", "move_row_north", "move_row_south"),
                                       r("Move column to row above or below", "move_column_north", "move_column_south"),
                                       r("Center window", "center"), r("Full width", "fullwidth"), r("Float or tile", "float"), r("Undo last move", "undo_move")]),
            Group(id: "Size", rows: [r("Make wider or narrower", "grow", "shrink"), r("Make taller or shorter", "grow_height", "shrink_height"), r("Equalize heights", "equalize")]),
            Group(id: "Stacks & Tabs", rows: [r("Stack into left column", "stack_left"), r("Stack into right column", "stack_right"), r("Unstack", "unstack"), r("Show as tabs", "tabs")]),
            Group(id: "Columns", rows: (1...9).map { r("Column \($0): focus or swap", "focus_column_\($0)", "swap_column_\($0)") }),
            Group(id: "Views", rows: (0...9).map { r("View \($0): go to or replace", "view_pin_\($0)", "view_save_\($0)") }),
            Group(id: "Microfish", rows: [r("Quit Microfish", "quit")]),
        ]
        let known = Set(catalog.map(\.id))
        layout = layout.map { Group(id: $0.id, rows: $0.rows.compactMap { row in let ids = row.ids.filter(known.contains); return ids.isEmpty ? nil : Row(id: row.id, title: row.title, ids: ids) }) }
        let placed = Set(layout.flatMap { $0.rows.flatMap(\.ids) })
        let other = catalog.filter { !placed.contains($0.id) }.map { Row(id: $0.id, title: actionName($0), ids: [$0.id]) }
        if !other.isEmpty { layout.append(Group(id: "Other", rows: other)) }
        return layout.filter { !$0.rows.isEmpty }
    }
    /// "Focus west (leftarrow)" -> "Focus left": the catalogue speaks compass, people speak left/right.
    static func actionName(_ a: ShortcutAction) -> String {
        var s = a.label.replacingOccurrences(of: #"\s*\([^)]*\)"#, with: "", options: .regularExpression)
        for (from, to) in [("west", "left"), ("east", "right"), ("north", "up"), ("south", "down")] { s = s.replacingOccurrences(of: from, with: to) }
        return s
    }
}

enum Chord {
    static let order: [(String, String, String)] = [("ctrl", "⌃", "Control"), ("alt", "⌥", "Option"), ("shift", "⇧", "Shift"), ("cmd", "⌘", "Command")]
    static let keyGlyphs: [String: (String, String)] = [
        "leftarrow": ("←", "Left Arrow"), "rightarrow": ("→", "Right Arrow"), "uparrow": ("↑", "Up Arrow"), "downarrow": ("↓", "Down Arrow"),
        "leftbracket": ("[", "Left Bracket"), "rightbracket": ("]", "Right Bracket"), "backslash": ("\\", "Backslash"), "equal": ("=", "Equals"), "minus": ("-", "Minus"),
        "space": ("Space", "Space"), "return": ("↩", "Return"), "tab": ("⇥", "Tab"), "escape": ("⎋", "Escape"), "delete": ("⌫", "Delete"), "forwarddelete": ("⌦", "Forward Delete"),
        "home": ("↖", "Home"), "end": ("↘", "End"), "pageup": ("⇞", "Page Up"), "pagedown": ("⇟", "Page Down"), "semicolon": (";", "Semicolon"), "quote": ("'", "Quote"),
        "comma": (",", "Comma"), "period": (".", "Period"), "slash": ("/", "Slash"), "grave": ("`", "Grave Accent"),
    ]
    static func parse(_ chord: String) -> (mods: Set<String>, key: String)? {
        let parts = chord.lowercased().components(separatedBy: " - ")
        guard parts.count == 2 else { return nil }
        return (Set(parts[0].split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }), parts[1].trimmingCharacters(in: .whitespaces))
    }
    static func modifiers(_ mods: Set<String>) -> String { order.filter { mods.contains($0.0) }.map(\.1).joined() }
    static func key(_ key: String) -> String { keyGlyphs[key]?.0 ?? key.uppercased() }
    /// Apple order (⌃⌥⇧⌘) and a thin space before the key, as in menus.
    static func display(_ chord: String) -> String {
        guard let (mods, k) = parse(chord) else { return chord }
        return modifiers(mods) + "\u{2009}" + key(k)
    }
    static func spoken(_ chord: String) -> String {
        guard let (mods, k) = parse(chord) else { return "Not set" }
        return (order.filter { mods.contains($0.0) }.map(\.2) + [keyGlyphs[k]?.1 ?? k.uppercased()]).joined(separator: " ")
    }
}

// MARK: - Store

enum SettingsPane: String, CaseIterable, Identifiable {
    case behavior, rows, shortcuts, appearance, minimap, rules
    var id: String { rawValue }
    var title: String { ["Behavior", "Rows", "Shortcuts", "Appearance", "Minimap", "Window Rules"][Self.allCases.firstIndex(of: self)!] }
    var symbol: String { ["slider.horizontal.3", "rectangle.grid.1x2", "keyboard", "paintbrush", "rectangle.inset.filled.on.rectangle", "list.bullet.rectangle"][Self.allCases.firstIndex(of: self)!] }
}

struct LiveWindowEntry: Identifiable, Hashable { let id: Int; let app: String; let bundle: String; let title: String; let floating: Bool
    var aliasKey: String { bundle + "\t" + title }
}

@MainActor @Observable final class SettingsStore {
    enum Phase: Equatable { case idle, applying, waiting, confirmed, unconfirmed, rejected(String), failed(String) }
    private(set) var raw: [String: Any] = [:]
    private(set) var saved = SettingsPrefs()
    var draft = SettingsPrefs() { didSet { if draft != oldValue { draftChanged(from: oldValue) } } }
    private(set) var catalog: [ShortcutAction] = []
    var invalid: [String: String] = [:]
    /// Invalid fields the user has left (or pressed Return in): only these are announced as errors.
    /// A value mid-typing ("0" on the way to "0.6") blocks Apply but stays quiet.
    var flagged: Set<String> = []
    var phase: Phase = .idle { didSet { if phase != oldValue { announce() } } }
    /// True from a real Apply being confirmed until the confirmation is acknowledged (a few seconds,
    /// the next edit, or the window being reopened). A confirmation found at open is not shown:
    /// a window that nothing was applied in has nothing to confirm.
    var justApplied = false
    @ObservationIgnored private var appliedClear: DispatchWorkItem?
    func acknowledgeOutcome() {
        appliedClear?.cancel(); justApplied = false
        if phase != .waiting && phase != .applying { applyNote = nil }
    }
    private func confirmApplied() {
        justApplied = true; phase = .confirmed
        appliedClear?.cancel()
        // A note (some windows couldn’t be floated) stays until acknowledged; a plain "Applied" fades.
        guard applyNote == nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.justApplied = false }
        appliedClear = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }
    var recordingID: String? { didSet { if recordingID == nil { recordingStarted = false } } }
    /// True once the engine has paused its shortcuts and keys are actually being captured.
    var recordingStarted = false
    var recordingNote: String?
    /// Bumped to ask the Shortcuts pane to reveal its first conflict.
    var revealConflict = 0
    /// Set when the backend saved everything but couldn't float some already-open windows.
    var applyNote: String?
    /// Bumped whenever fields must re-read the draft (Revert, external reload).
    private(set) var revision = 0
    private(set) var restoredDraft = false
    var windows: [LiveWindowEntry] = []
    var windowsNote: String?
    var selectedWindowID: Int?
    var lastFocusedWindowID: Int?
    var currentPane: SettingsPane = .behavior
    /// Screen Recording access for tab color matching; refreshed whenever the window is shown.
    var canSampleScreen = CGPreflightScreenCaptureAccess()

    @ObservationIgnored var beginRecording: ((String) -> Void)?
    @ObservationIgnored var cancelRecording: (() -> Void)?
    @ObservationIgnored var onApplied: (() -> Void)?
    @ObservationIgnored var openPane: ((SettingsPane) -> Void)?
    @ObservationIgnored var onDraftChanged: (() -> Void)?
    @ObservationIgnored private var persistWork: DispatchWorkItem?
    @ObservationIgnored private var confirmTimer: Timer?

    init() { load() }

    var prefsURL: URL { MicrofishPaths.preferences }
    var pendingURL: URL { MicrofishPaths.drafts.appendingPathComponent("pending.json") }
    var defaults: [String: String] { Dictionary(catalog.map { ($0.id, $0.chord) }, uniquingKeysWith: { a, _ in a }) }

    func load() {
        if let data = try? Data(contentsOf: MicrofishPaths.shortcutCatalog), let list = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] {
            catalog = list.compactMap { a in a["id"].map { ShortcutAction(id: $0, label: a["label"] ?? $0, chord: a["default"] ?? "", command: a["command"] ?? "") } }
        }
        raw = (try? Data(contentsOf: prefsURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        saved = SettingsPrefs(raw, defaults: defaults)
        var next = saved
        // Unapplied edits survive closing the window and restarting the helper.
        if let data = try? Data(contentsOf: pendingURL), let pending = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for f in SettingsPrefs.fields where !Self.perEntry.contains(f.key) { if let v = pending[f.key] { f.read(&next, v) } }
            for (id, v) in pending["shortcuts.changes"] as? [String: Any] ?? [:] where next.shortcuts[id] != nil { next.shortcuts[id] = v as? String ?? "" }
            for (k, v) in pending["tabAliases.changes"] as? [String: Any] ?? [:] { next.tabAliases[k] = v as? String }
        }
        restoredDraft = next != saved
        invalid = [:]; draft = next; revision += 1
        if phase == .idle { phase = Self.restingPhase(prefsURL: prefsURL) }
        if !restoredDraft { try? FileManager.default.removeItem(at: pendingURL) }
    }
    /// Picks up preferences written elsewhere without discarding the user's edits: fields the user
    /// hasn't touched follow the new file, edited ones keep the draft.
    func reloadFromDisk() {
        guard phase != .applying else { return }
        let newRaw = (try? Data(contentsOf: prefsURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? raw
        let newSaved = SettingsPrefs(newRaw, defaults: defaults)
        guard newSaved != saved else { return }
        var next = draft
        for f in SettingsPrefs.fields where f.same(draft, saved) { f.adopt(&next, newSaved) }
        // Shortcuts and tab titles rebase per entry: an outside change to one shortcut must not be
        // undone because the user is editing another.
        for (id, value) in newSaved.shortcuts where draft.shortcuts[id] == saved.shortcuts[id] { next.shortcuts[id] = value }
        for key in Set(saved.tabAliases.keys).union(newSaved.tabAliases.keys) where draft.tabAliases[key] == saved.tabAliases[key] { next.tabAliases[key] = newSaved.tabAliases[key] }
        raw = newRaw; saved = newSaved; draft = next; revision += 1
    }
    var isDirty: Bool { draft != saved }
    var conflicts: [String: [String]] { Self.conflicts(draft.shortcuts) }
    var conflictCount: Int { Self.conflictCount(draft.shortcuts) }
    nonisolated static func conflicts(_ shortcuts: [String: String]) -> [String: [String]] {
        var byChord: [String: [String]] = [:]
        for (id, chord) in shortcuts where !chord.isEmpty { byChord[chord, default: []].append(id) }
        var out: [String: [String]] = [:]
        for ids in byChord.values where ids.count > 1 { for id in ids { out[id] = ids.filter { $0 != id }.sorted() } }
        return out
    }
    /// Number of key combinations claimed by more than one action.
    nonisolated static func conflictCount(_ shortcuts: [String: String]) -> Int {
        var seen: [String: Int] = [:]
        for chord in shortcuts.values where !chord.isEmpty { seen[chord, default: 0] += 1 }
        return seen.values.filter { $0 > 1 }.count
    }
    var canApply: Bool { isDirty && invalid.isEmpty && conflictCount == 0 && phase != .applying && recordingID == nil && !catalog.isEmpty }
    var canRevert: Bool { (isDirty || !invalid.isEmpty) && phase != .applying && recordingID == nil }
    /// The last Apply ended badly (failed, or the engine refused the reload) and the user hasn't dismissed it.
    var hasBadOutcome: Bool { if case .failed = phase { return true }; if case .rejected = phase { return true }; return false }
    func dismissOutcome() { if hasBadOutcome { phase = .idle } }

    private func draftChanged(from old: SettingsPrefs) {
        // Edits keep the outcome of the last Apply visible (waiting, rejected) until the next Apply,
        // Revert or Dismiss; a failed Apply whose edits have all been undone has nothing left to say.
        if case .failed = phase, !isDirty { phase = .idle }
        justApplied = false
        if recordingID == nil { recordingNote = nil }
        persist()
        onDraftChanged?()
        if conflictCount > Self.conflictCount(old.shortcuts) { Self.post("Shortcut conflict: \(conflictCount) to resolve before applying") }
    }
    private func persist() {
        persistWork?.cancel()
        let changed = draft.changedKeys(from: saved), snapshot = draft, url = pendingURL
        var payload = Dictionary(uniqueKeysWithValues: SettingsPrefs.fields.filter { changed.contains($0.key) && !Self.perEntry.contains($0.key) }.map { ($0.key, $0.write(snapshot)) })
        // Shortcuts and tab titles are stored as per-entry changes (null = removed), so restoring a
        // draft later never reverts entries changed elsewhere or hides newly added actions.
        if changed.contains("shortcuts") { payload["shortcuts.changes"] = Self.diff(saved.shortcuts, snapshot.shortcuts) }
        if changed.contains("tabAliases") { payload["tabAliases.changes"] = Self.diff(saved.tabAliases, snapshot.tabAliases) }
        let work = DispatchWorkItem {
            if payload.isEmpty { try? FileManager.default.removeItem(at: url); return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: url, options: .atomic) }
        }
        persistWork = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.3, execute: work)
    }
    nonisolated static let perEntry: Set<String> = ["shortcuts", "tabAliases"]
    nonisolated static func diff(_ old: [String: String], _ new: [String: String]) -> [String: Any] {
        var out: [String: Any] = [:]
        for key in Set(old.keys).union(new.keys) where old[key] != new[key] { out[key] = new[key] ?? NSNull() }
        return out
    }
    func revert() {
        guard canRevert else { return }
        invalid = [:]; flagged = []; draft = saved; revision += 1; restoredDraft = false; recordingNote = nil
        dismissOutcome()
    }
    func apply() {
        guard canApply else { return }
        recordingNote = nil
        var out = raw
        for f in SettingsPrefs.fields where !f.same(draft, saved) { out[f.key] = f.write(draft) }
        let submitted = draft
        let logOffset = Optional(MicrofishPaths.engineLog).flatMap { (try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? NSNumber)?.uint64Value }
        phase = .applying; justApplied = false
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<String, Error> = Result {
                let directory = MicrofishPaths.drafts
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let path = directory.appendingPathComponent(UUID().uuidString + ".json")
                try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]).write(to: path, options: .atomic)
                defer { try? FileManager.default.removeItem(at: path) }
                let applied = SettingsApply.run(draft: path)
                let (status, message) = (applied.status, applied.message)
                if status != 0 && message.isEmpty { NSLog("settings apply exited with %d", status) }
                guard status == 0 else { throw NSError(domain: "Settings", code: Int(status), userInfo: [NSLocalizedDescriptionKey: message.isEmpty ? "Something went wrong while saving." : message]) }
                return message
            }
            DispatchQueue.main.async {
                switch result {
                case .success(let message):
                    self.applyNote = message.contains("could not be applied") ? "Some open windows couldn’t be floated. New ones follow your rules." : nil
                    self.raw = out; self.saved = submitted; self.restoredDraft = false
                    // Edits made while applying stay pending; anything else has just been saved.
                    self.persist()
                    self.phase = .waiting; self.onApplied?(); self.onDraftChanged?(); self.watchEngine(logOffset: logOffset)
                case .failure(let error):
                    self.phase = .failed(error.localizedDescription)
                }
            }
        }
    }
    /// The engine watches init.lua and logs each reload to its stderr log ("Reloaded Lua script" or
    /// "ERROR Reloading Lua script …"). Confirmation is that line appearing after our write; a failed
    /// reload leaves the previous configuration running, so it is reported rather than hidden.
    private func watchEngine(logOffset: UInt64?) {
        confirmTimer?.invalidate()
        let log = MicrofishPaths.engineLog
        guard let offset = logOffset else { phase = .unconfirmed; return }
        let started = Date()
        confirmTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] timer in
            DispatchQueue.global(qos: .utility).async {
                let verdict = SettingsController.reloadVerdict(log, from: offset)
                DispatchQueue.main.async {
                    guard let self, self.phase == .waiting else { timer.invalidate(); return }
                    switch verdict {
                    case .some(.success): self.confirmApplied(); timer.invalidate()
                    case .some(.failure(let error)): self.phase = .rejected(error.localizedDescription); timer.invalidate()
                    case .none: if Date().timeIntervalSince(started) > 10 { self.phase = .unconfirmed; timer.invalidate() }
                    }
                }
            }
        }
    }
    /// What the engine last said about the saved settings: a reload logged after preferences.json
    /// was written means it is running them.
    nonisolated static func restingPhase(prefsURL: URL) -> Phase {
        let log = MicrofishPaths.engineLog
        guard let size = (try? FileManager.default.attributesOfItem(atPath: log.path)[.size] as? NSNumber)?.uint64Value,
              let written = try? FileManager.default.attributesOfItem(atPath: prefsURL.path)[.modificationDate] as? Date,
              let handle = try? FileHandle(forReadingFrom: log) else { return .idle }
        defer { try? handle.close() }
        try? handle.seek(toOffset: size > 65536 ? size - 65536 : 0)
        let text = String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self).replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
        let iso = ISO8601DateFormatter()  // engine stamps carry microseconds; whole seconds are enough here
        for line in text.split(separator: "\n").reversed() where line.contains("Reloading Lua script") || line.contains("Reloaded Lua script") {
            guard let stamp = iso.date(from: String(line.prefix(19)) + "Z"), stamp >= written.addingTimeInterval(-1) else { return .idle }
            return line.contains("ERROR") ? .rejected("") : .confirmed
        }
        return .idle
    }
    func refreshWindows() {
        windowsNote = "Reading windows…"
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<([LiveWindowEntry], Int?), Error> = Result {
                let (status, data) = try SettingsController.run(MicrofishPaths.engineExecutable.path, ["query", "state", "--json"], environment: MicrofishPaths.childEnvironment)
                guard status == 0, let state = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw NSError(domain: "Settings", code: 2, userInfo: [NSLocalizedDescriptionKey: "Microfish isn’t responding."]) }
                let me = ProcessInfo.processInfo.processName
                let list = (state["virtual_workspaces"] as? [[String: Any]] ?? []).flatMap { $0["windows"] as? [[String: Any]] ?? [] }.compactMap { w -> LiveWindowEntry? in
                    guard let id = (w["window_id"] as? NSNumber)?.intValue, (w["app_name"] as? String) != me else { return nil }
                    return LiveWindowEntry(id: id, app: w["app_name"] as? String ?? "App", bundle: w["bundle_id"] as? String ?? "", title: w["title"] as? String ?? "", floating: w["floating"] as? Bool ?? false)
                }
                return (list, ((state["active"] as? [String: Any])?["focused_window_id"] as? NSNumber)?.intValue)
            }
            DispatchQueue.main.async {
                switch result {
                case .success(let (list, focused)):
                    self.windows = list.sorted { ($0.app.localizedLowercase, $0.title) < ($1.app.localizedLowercase, $1.title) }
                    if let focused, list.contains(where: { $0.id == focused }) { self.lastFocusedWindowID = focused }
                    if self.selectedWindowID.map({ id in !list.contains { $0.id == id } }) ?? true { self.selectedWindowID = self.lastFocusedWindowID ?? self.windows.first?.id }
                    self.windowsNote = list.isEmpty ? "No windows" : nil
                case .failure(let error): self.windows = []; self.windowsNote = error.localizedDescription
                }
            }
        }
    }
    func label(for id: String) -> String { catalog.first { $0.id == id }.map(ShortcutLayout.actionName) ?? id }
    /// What the footer says about the last Apply, one string for the footer and for VoiceOver.
    /// Nothing at rest: a window nothing was applied in has nothing to report.
    var outcomeText: String? {
        switch phase {
        case .confirmed: return justApplied ? "Applied" + (applyNote.map { ". " + $0 } ?? "") : nil
        case .unconfirmed: return "Saved. Microfish hasn’t loaded the changes yet."
        case .rejected: return "Couldn’t apply these settings. Microfish kept the previous ones."
        case .failed(let message): return Self.failureText(message)
        default: return nil
        }
    }
    /// The raw text behind a failed or rejected Apply, for the tooltip only.
    var outcomeDetail: String? {
        switch phase {
        case .rejected(let message): return message.isEmpty ? "Open the log for details." : message
        case .failed(let message): return message
        default: return nil
        }
    }
    /// SettingsApply reports one plain sentence for every failure it knows (details go to its log), so
    /// show that sentence; anything else (a crash, several lines) gets the generic line.
    nonisolated static func failureText(_ message: String) -> String {
        let generic = "Couldn’t apply these settings. Microfish kept the previous ones."
        let line = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, !line.contains("\n"), line.count <= 200, line.hasSuffix("."),
              !line.contains("Traceback"), !line.contains("Error:") else { return generic }
        return line
    }
    private func announce() {
        if let text = outcomeText { Self.post(text) }
    }
    static func post(_ text: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
    // App names and icons for rules, resolved once per bundle.
    @ObservationIgnored private var apps: [String: (String, NSImage?)] = [:]
    func app(_ bundle: String) -> (name: String, icon: NSImage?) {
        if let hit = apps[bundle] { return hit }
        var result: (String, NSImage?) = (bundle.isEmpty ? "Any app" : bundle, nil)
        if !bundle.isEmpty, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
            result = (FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""), NSWorkspace.shared.icon(forFile: url.path))
        }
        apps[bundle] = result
        return result
    }
}

// MARK: - Window controller

/// Reports when SwiftUI invalidates the pane's ideal size. A grouped Form inside a fixed frame does not
/// always do so when rows come and go, so draft changes also trigger a re-measure.
final class PaneHostingView<Content: View>: NSHostingView<Content> {
    var onIdealSizeChange: (() -> Void)?
    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        onIdealSizeChange?()
    }
}

final class SettingsWindow: NSWindow {
    // Escape cancels a running shortcut capture before anything else sees it.
    override func cancelOperation(_ sender: Any?) {}
    #if SETTINGS_TESTS
    // Render harnesses park the window off every screen; don't let AppKit pull it back on.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    #endif
}

@MainActor final class SettingsController: NSObject, NSToolbarDelegate, NSWindowDelegate {
    // Entry points stay nonisolated: the navigator calls them from AppKit callbacks on the main thread.
    nonisolated var onApplied: (() -> Void)? {
        get { MainActor.assumeIsolated { store.onApplied } }
        set { MainActor.assumeIsolated { store.onApplied = newValue } }
    }
    let store: SettingsStore
    private(set) var window: NSWindow?
    private var hosts: [SettingsPane: NSView] = [:]
    private var footer: NSView?
    private var footerHeight: CGFloat = 0
    private(set) var pane: SettingsPane = .behavior
    private var switchGeneration = 0
    private let recorder = ShortcutRecorder()
    private let recordingQueue = DispatchQueue(label: "net.webreceptor.microfish.shortcut-recording")
    fileprivate weak var searchField: NSSearchField?
    private static let paneKey = "MicrofishSettingsPane", originKey = "MicrofishSettingsWindowTopLeft"
    static let width: CGFloat = 600

    nonisolated override init() {
        store = MainActor.assumeIsolated { SettingsStore() }
        super.init()
        MainActor.assumeIsolated {
            store.openPane = { [weak self] in self?.select($0, animate: true) }
            store.onDraftChanged = { [weak self] in self?.draftDidChange() }
            configureRecorder()
        }
    }

    nonisolated func show() { MainActor.assumeIsolated { present() } }
    private func present() {
        // Remember who had the keyboard, so closing Settings can hand it back (see windowWillClose).
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApp = front }
        store.acknowledgeOutcome()
        // Reopened while About outlived the last Settings window: this window's close takes over.
        if let observer = otherWindowsObserver { NotificationCenter.default.removeObserver(observer); otherWindowsObserver = nil }
        enterAppMode()
        installMainMenu()
        if window == nil { build() }
        store.reloadFromDisk(); store.refreshWindows(); store.canSampleScreen = CGPreflightScreenCaptureAccess()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
        warmPanes()
    }

    private func build() {
        let w = SettingsWindow(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 400), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: true)
        w.isReleasedWhenClosed = false; w.delegate = self
        w.toolbarStyle = .preference
        w.titlebarSeparatorStyle = .automatic
        w.collectionBehavior = [.fullScreenNone]
        w.tabbingMode = .disallowed
        w.contentView = NSView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 400))
        installFooter(in: w.contentView!)
        let toolbar = NSToolbar(identifier: "MicrofishSettingsToolbar")
        toolbar.delegate = self; toolbar.displayMode = .iconAndLabel; toolbar.allowsUserCustomization = false
        toolbar.allowsDisplayModeCustomization = false
        w.toolbar = toolbar
        window = w
        // Read what was remembered before anything can write it: selecting a pane (and any move while
        // the window is being sized) would otherwise overwrite the stored origin with the unplaced
        // window's. Nothing is remembered until the window has been put where it belongs.
        let savedPane = Self.remembered(Self.paneKey).flatMap(SettingsPane.init(rawValue:)) ?? .behavior
        let savedOrigin = Self.remembered(Self.originKey)
        placed = false
        select(savedPane, animate: false)
        if let text = savedOrigin {
            let p = NSPointFromString(text)
            var frame = w.frame; frame.origin = NSPoint(x: p.x, y: p.y - frame.height)
            if NSScreen.screens.contains(where: { $0.visibleFrame.insetBy(dx: -1, dy: -1).contains(NSPoint(x: frame.midX, y: frame.maxY - 10)) }) { w.setFrame(w.constrainFrameRect(frame, to: nil), display: false) } else { w.center() }
        } else { w.center() }
        w.contentView?.layoutSubtreeIfNeeded()
        placed = true
    }
    /// False while the window is being built; the origin is only remembered once it has been placed.
    private var placed = false
    /// The app that was frontmost when Settings was presented.
    private var previousApp: NSRunningApplication?
    /// The app to hand the keyboard back to when Settings closes: only while this helper is still the
    /// active app (if the user already switched elsewhere, leave them there), and never itself.
    nonisolated static func appToRestore(previous: NSRunningApplication?, helperActive: Bool, helperPID: pid_t) -> NSRunningApplication? {
        guard helperActive, let previous, !previous.isTerminated, previous.processIdentifier != helperPID else { return nil }
        return previous
    }

    /// The helper's defaults domain is its executable name until the build embeds an Info.plist, then
    /// its bundle identifier; read the old domain once so the window keeps its place across that change.
    private static func remembered(_ key: String) -> String? {
        UserDefaults.standard.string(forKey: key) ?? legacyDefaultsSuite.flatMap { UserDefaults(suiteName: $0)?.string(forKey: key) }
    }
    // The origin key is new on purpose: every value stored under the old name ("MicrofishSettingsTopLeft")
    // was the unplaced window's {0, height}, written by build() before it read the real one.
    nonisolated(unsafe) static var legacyDefaultsSuite: String? = "MicrofishNavigator"

    // MARK: Panes
    private func host(for pane: SettingsPane) -> NSView {
        if let view = hosts[pane] { return view }
        let root = SettingsPaneView(pane: pane, store: store, controller: self).frame(width: Self.width)
        let view = PaneHostingView(rootView: root)
        view.sizingOptions = [.intrinsicContentSize]
        view.onIdealSizeChange = { [weak self] in self?.scheduleRefit() }
        hosts[pane] = view
        return view
    }
    private func height(for pane: SettingsPane, _ view: NSView) -> CGFloat {
        let limit = ((window?.screen ?? NSScreen.main)?.visibleFrame.height ?? 900) - 120 - footerHeight
        if pane == .shortcuts { return min(580, limit) }
        view.frame.size.width = Self.width
        return min(ceil(view.fittingSize.height), limit)
    }
    /// The status/Apply bar is one view shared by every pane, pinned to the window's bottom edge, so
    /// it never moves or fades while panes change.
    private func installFooter(in container: NSView) {
        let bar = NSHostingView(rootView: FooterBar(store: store).frame(width: Self.width))
        bar.sizingOptions = [.intrinsicContentSize]
        footerHeight = ceil(bar.fittingSize.height)
        bar.sizingOptions = []
        bar.frame = NSRect(x: 0, y: 0, width: Self.width, height: footerHeight)
        bar.autoresizingMask = [.width, .maxYMargin]
        container.addSubview(bar)
        footer = bar
    }
    func select(_ pane: SettingsPane, animate: Bool) {
        guard let window, let container = window.contentView else { return }
        if store.recordingID != nil { store.cancelRecording?() }
        let next = host(for: pane)
        let paneHeight = height(for: pane, next)
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: NSSize(width: Self.width, height: paneHeight + footerHeight)))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        frame = Self.keepOnScreen(frame, window)
        self.pane = pane; store.currentPane = pane; window.isDocumentEdited = store.isDirty
        window.title = pane.title
        window.toolbar?.selectedItemIdentifier = NSToolbarItem.Identifier(pane.rawValue)
        UserDefaults.standard.set(pane.rawValue, forKey: Self.paneKey)
        // Swap content at once (no overlapping cross-fade), pinned under the toolbar; the window
        // then grows or shrinks from its top edge, as first-party settings windows do.
        hosts.values.filter { $0 !== next && $0.superview != nil }.forEach { $0.removeFromSuperview() }
        next.frame = NSRect(x: 0, y: container.bounds.height - paneHeight, width: Self.width, height: paneHeight)
        next.autoresizingMask = [.width, .minYMargin]
        if next.superview == nil { container.addSubview(next, positioned: .below, relativeTo: footer) }
        let animated = animate && window.isVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if animated && abs(frame.height - window.frame.height) > 1 {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = window.animationResizeTime(frame)
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                window.animator().setFrame(frame, display: true)
            }
        } else {
            window.setFrame(frame, display: window.isVisible)
        }
        settleFocus()
    }
    private var refitScheduled = false
    private func draftDidChange() { window?.isDocumentEdited = store.isDirty; scheduleRefit() }
    /// SwiftUI invalidates before its new ideal size is settled, so measure again shortly after.
    private func scheduleRefit() {
        guard !refitScheduled else { return }
        refitScheduled = true
        for (i, delay) in [0.0, 0.06, 0.2].enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                if i == 2 { self?.refitScheduled = false }
                self?.refit()
            }
        }
    }
    func refit() {
        guard let window, let view = hosts[pane], view.superview != nil, pane != .shortcuts else { return }
        let paneHeight = height(for: pane, view)
        guard abs(paneHeight - view.frame.height) > 1 else { return }
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: NSSize(width: Self.width, height: paneHeight + footerHeight)))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        frame = Self.keepOnScreen(frame, window)
        let growing = paneHeight > view.frame.height
        let pin = { view.frame = NSRect(x: 0, y: (window.contentView?.bounds.height ?? 0) - paneHeight, width: Self.width, height: paneHeight) }
        if growing { view.frame = NSRect(x: 0, y: view.frame.maxY - paneHeight, width: Self.width, height: paneHeight) }
        if window.isVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = window.animationResizeTime(frame)
                window.animator().setFrame(frame, display: true)
            }, completionHandler: { MainActor.assumeIsolated { pin() } })
        } else { window.setFrame(frame, display: window.isVisible); pin() }
    }
    /// Growing from the top edge must not push Apply under the Dock: lift the window if it would.
    private static func keepOnScreen(_ frame: NSRect, _ window: NSWindow) -> NSRect {
        guard let visible = window.screen?.visibleFrame, frame.minY < visible.minY else { return frame }
        var f = frame; f.origin.y = min(visible.minY, visible.maxY - f.height); return f
    }
    /// Builds the other panes while idle so the first visit to one doesn't stall on SwiftUI setup.
    private func warmPanes() {
        let pending = SettingsPane.allCases.filter { hosts[$0] == nil }
        guard let pane = pending.first else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.window?.isVisible == true else { return }
            let view = self.host(for: pane)
            view.frame.size = NSSize(width: Self.width, height: 600)
            view.layoutSubtreeIfNeeded()
            self.warmPanes()
        }
    }
    private func settleFocus() {
        rememberOrigin()
        // Opening a pane should not drop the caret into its first text field (SwiftUI focuses it a
        // runloop turn after the view appears).
        for delay in [0.0, 0.05] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let window = self?.window else { return }
                if window.firstResponder is NSText || window.firstResponder is NSTextField { window.makeFirstResponder(window.contentView) }
            }
        }
    }
    private func rememberOrigin() {
        guard placed, let window else { return }
        UserDefaults.standard.set(NSStringFromPoint(NSPoint(x: window.frame.minX, y: window.frame.maxY)), forKey: Self.originKey)
    }
    func windowDidMove(_ notification: Notification) { rememberOrigin() }
    func windowWillClose(_ notification: Notification) {
        store.cancelRecording?()
        // The color panel belongs to this window's outline well; don't leave it floating alone.
        if NSColorPanel.sharedColorPanelExists { NSColorPanel.shared.orderOut(nil) }
        // After the close animation, so the window doesn't vanish mid-close with the Dock tile.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Another visible window of ours (About) keeps the app in front, and a regular app (menu bar,
            // ⌘Tab), until it closes too; then the app leaves app mode and hands the keyboard back.
            if self.otherWindowsVisible { self.finishWhenOtherWindowsClose() } else { self.finishClosing() }
        }
    }
    private var otherWindowsVisible: Bool { NSApp.windows.contains { $0 !== window && $0.isVisible && $0.canBecomeKey } }
    private var otherWindowsObserver: NSObjectProtocol?
    private func finishClosing() {
        if let observer = otherWindowsObserver { NotificationCenter.default.removeObserver(observer); otherWindowsObserver = nil }
        let target = Self.appToRestore(previous: previousApp, helperActive: NSApp.isActive, helperPID: ProcessInfo.processInfo.processIdentifier)
        leaveAppMode()
        previousApp = nil
        if let target { NSApp.yieldActivation(to: target); target.activate() }
    }
    private func finishWhenOtherWindowsClose() {
        guard otherWindowsObserver == nil else { return }
        otherWindowsObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] _ in
            // After the close, so the closing window no longer counts as visible.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.otherWindowsObserver != nil, self.window?.isVisible != true, !self.otherWindowsVisible else { return }
                    self.finishClosing()
                }
            }
        }
    }
    func windowDidBecomeKey(_ notification: Notification) { store.reloadFromDisk() }

    // MARK: Toolbar
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { SettingsPane.allCases.map { .init($0.rawValue) } }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarAllowedItemIdentifiers(toolbar) }
    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarAllowedItemIdentifiers(toolbar) }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let pane = SettingsPane(rawValue: id.rawValue) else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = pane.title; item.paletteLabel = pane.title; item.toolTip = pane.title
        item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
        item.target = self; item.action = #selector(toolbarSelect(_:))
        return item
    }
    @objc private func toolbarSelect(_ sender: NSToolbarItem) { if let pane = SettingsPane(rawValue: sender.itemIdentifier.rawValue), pane != self.pane { select(pane, animate: true) } }

    // MARK: Menu
    /// The helper is an accessory app with no menu of its own; while Settings is frontmost it needs
    /// the standard ones so ⌘, ⌘W ⌘M ⌘F and text editing (⌘Z ⌘X ⌘C ⌘V ⌘A) behave. No Hide, Hide Others or
    /// Show All: this app's overlays are the window manager's tab bars and minimap, so hiding it (or
    /// every other app) would hide the user's whole workspace. Quit appears once the navigator can do a full quit.
    private func installMainMenu() {
        guard NSApp.mainMenu == nil || NSApp.mainMenu?.identifier?.rawValue == "MicrofishSettingsMenu" else { return }
        let main = NSMenu(); main.identifier = .init("MicrofishSettingsMenu")
        func menu(_ title: String, _ items: [NSMenuItem]) { let m = NSMenu(title: title); items.forEach(m.addItem); let top = NSMenuItem(); top.submenu = m; main.addItem(top) }
        func item(_ title: String, _ action: Selector?, _ key: String, _ mods: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key); i.keyEquivalentModifierMask = mods; i.target = target; return i
        }
        // "Quit Microfish" is nil-targeted to the navigator's full, clean quit (engine and helper
        // together); AppKit disables it until the app delegate implements quitMicrofish:.
        let quit = Selector(("quitMicrofish:"))
        let quitItems: [NSMenuItem] = (NSApp.delegate as AnyObject?)?.responds(to: quit) == true ? [.separator(), item("Quit Microfish", quit, "q")] : []
        menu("Microfish", [item("About Microfish", #selector(menuAbout), "", target: self), .separator(), item("Settings…", #selector(menuShow), ",", target: self)] + quitItems)
        menu("Edit", [item("Undo", Selector(("undo:")), "z"), item("Redo", Selector(("redo:")), "z", [.command, .shift]), .separator(), item("Cut", #selector(NSText.cut(_:)), "x"), item("Copy", #selector(NSText.copy(_:)), "c"), item("Paste", #selector(NSText.paste(_:)), "v"), item("Select All", #selector(NSText.selectAll(_:)), "a"), .separator(), item("Find Shortcut…", #selector(menuFind), "f", target: self)])
        menu("Window", [item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"), item("Close", #selector(NSWindow.performClose(_:)), "w")])
        NSApp.mainMenu = main
        NSApp.windowsMenu = main.items.last?.submenu
    }
    @objc private func menuShow() { present() }
    @objc private func menuAbout() {
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "Microfish", .applicationIcon: Self.appIcon() as Any].compactMapValues { $0 })
        NSApp.activate()
    }
    nonisolated static func appIcon() -> NSImage? { NSImage(contentsOf: MicrofishPaths.appIcon) ?? NSImage(contentsOf: MicrofishPaths.appIcon.deletingPathExtension().appendingPathExtension("png")) }
    /// While Settings is open the helper behaves like an app: menu bar, ⌘Tab, Dock tile. It returns to
    /// a menu-bar accessory when Settings closes. Off until the engine ignores its own helper even
    /// when that helper is a regular app (BOARD 2026-10-28 00:35; engine exclusion live in 0a1ba64).
    static let becomesRegularApp = true
    private func enterAppMode() {
        guard Self.becomesRegularApp, NSApp.activationPolicy() != .regular else { return }
        NSApp.setActivationPolicy(.regular)
        if let icon = Self.appIcon() { NSApp.applicationIconImage = icon }
    }
    private func leaveAppMode() {
        guard Self.becomesRegularApp, NSApp.activationPolicy() == .regular else { return }
        NSApp.setActivationPolicy(.accessory)
    }
    @objc private func menuFind() {
        if pane != .shortcuts { select(.shortcuts, animate: true) }
        DispatchQueue.main.async { if let field = self.searchField { self.window?.makeFirstResponder(field) } }
    }

    // MARK: Recording
    private func configureRecorder() {
        let bridge = MicrofishPaths.bridgeExecutable.path
        let bridgeEnvironment = MicrofishPaths.childEnvironment
        let queue = recordingQueue
        recorder.suspend = { completion in
            let token = UUID().uuidString.lowercased()
            queue.async {
                do {
                    var result = try Self.run(bridge, ["record-begin", token], environment: bridgeEnvironment)
                    // A quick switch to another slot can arrive while the previous capture's lease is
                    // still being released; give that release a moment, once.
                    if result.0 != 0, String(decoding: result.1, as: UTF8.self).contains("lease") {
                        Thread.sleep(forTimeInterval: 0.25)
                        result = try Self.run(bridge, ["record-begin", token], environment: bridgeEnvironment)
                    }
                    guard result.0 == 0 else { throw NSError(domain: "ShortcutRecorder", code: Int(result.0), userInfo: [NSLocalizedDescriptionKey: "Couldn’t start recording. Microfish isn’t responding."]) }
                    completion(.success({ queue.async { _ = try? Self.run(bridge, ["record-end", token], environment: bridgeEnvironment) } }))
                } catch {
                    // A timed-out acknowledgement may still have installed the lease.
                    _ = try? Self.run(bridge, ["record-end", token], environment: bridgeEnvironment)
                    completion(.failure(error))
                }
            }
        }
        recorder.didStart = { [weak self] in self?.store.recordingStarted = true; SettingsStore.post("Recording. Press the new shortcut.") }
        recorder.didReject = { [weak self] unsupported in
            self?.store.recordingNote = unsupported ? "That key can’t be used in a Microfish shortcut" : "Include ⌃, ⌥ or ⌘ in the shortcut"
            NSSound.beep()
        }
        recorder.didFinish = { [weak self] chord, error in
            guard let self else { return }
            if let id = self.store.recordingID, let chord { self.store.draft.shortcuts[id] = chord }
            self.store.recordingID = nil; self.store.recordingNote = error
        }
        store.beginRecording = { [weak self] id in
            guard let self, let window = self.window, self.store.phase != .applying else { return }
            if self.store.recordingID != nil { self.recorder.cancel() }
            self.store.recordingNote = nil; self.store.recordingID = id; self.recorder.begin(window: window)
        }
        store.cancelRecording = { [weak self] in self?.recorder.cancel() }
    }

    // MARK: Processes
    /// nil while the engine hasn't reloaded since `offset`; otherwise whether the reload succeeded.
    nonisolated static func reloadVerdict(_ log: URL, from offset: UInt64) -> Result<Void, Error>? {
        guard let handle = try? FileHandle(forReadingFrom: log) else { return nil }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: offset)) != nil, let data = try? handle.readToEnd(), !data.isEmpty else { return nil }
        let plain = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
        for line in plain.split(separator: "\n") {
            // Real shape: "ERROR paneru::lua::worker: src/lua/worker.rs:342: Reloading Lua script '…': err"
            if line.contains("Reloading Lua script") && line.contains("ERROR") {
                // "…Reloading Lua script '/path/init.lua': <error>": keep the error, drop the path.
                let tail = line.components(separatedBy: "Reloading Lua script").last ?? ""
                let detail = (tail.range(of: "': ").map { String(tail[$0.upperBound...]) } ?? tail).trimmingCharacters(in: .whitespaces)
                return .failure(NSError(domain: "Settings", code: 3, userInfo: [NSLocalizedDescriptionKey: String(detail.prefix(160))]))
            }
            if line.contains("Reloaded Lua script") { return .success(()) }
        }
        return nil
    }
    nonisolated static func run(_ executable: String, _ arguments: [String], environment: [String: String]? = nil, timeout: TimeInterval = 15) throws -> (Int32, Data) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: executable); p.arguments = arguments
        if let environment { p.environment = environment }
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe; try p.run()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler { if p.isRunning { p.terminate() } }
        timer.resume(); defer { timer.cancel() }
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit(); return (p.terminationStatus, data)
    }
    static func displayChord(_ chord: String) -> String { chord.isEmpty ? "Not set" : Chord.display(chord) }
    // Match Rust regex escaping rather than relying on ICU-specific quoting.
    nonisolated static func escapeRegex(_ text: String) -> String {
        let special = Set("\\.+*?()|[]{}^$#&-~")
        return text.map { special.contains($0) ? "\\" + String($0) : String($0) }.joined()
    }
    nonisolated static func unescapeRegex(_ text: String) -> String {
        var out = "", escaping = false
        for c in text { if escaping { out.append(c); escaping = false } else if c == "\\" { escaping = true } else { out.append(c) } }
        return out
    }

    #if SETTINGS_TESTS
    var testWindow: NSWindow? { if window == nil { build() }; return window }
    func testSelect(_ pane: SettingsPane) { if window == nil { build() }; select(pane, animate: false) }
    func testHost(_ pane: SettingsPane) -> NSView { host(for: pane) }
    func testInstallMenu() { installMainMenu() }
    #endif
}

// MARK: - Shared views

private let brandTeal = Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(srgbRed: 0.235, green: 0.776, blue: 0.769, alpha: 1) : NSColor(srgbRed: 0, green: 0.498, blue: 0.506, alpha: 1) })

/// Microfish's teal stands in for the accent only when the user chose Multicolor, exactly as an
/// app's own accent color does; any explicit system accent wins.
private var usesBrandAccent: Bool { UserDefaults.standard.object(forKey: "AppleAccentColor") == nil }
private var settingsAccent: Color { usesBrandAccent ? brandTeal : .accentColor }

struct SettingsPaneView: View {
    let pane: SettingsPane
    @Bindable var store: SettingsStore
    let controller: SettingsController
    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch pane {
                case .behavior: BehaviorPane(store: store)
                case .rows: RowsPane(store: store)
                case .shortcuts: ShortcutsPane(store: store, controller: controller)
                case .appearance: AppearancePane(store: store)
                case .minimap: MinimapPane(store: store)
                case .rules: RulesPane(store: store)
                }
            }
            .formStyle(.grouped)
        }
        .tint(usesBrandAccent ? brandTeal : nil)
    }
}

struct FooterBar: View {
    @Bindable var store: SettingsStore
    private var showsResetAll: Bool { store.currentPane == .shortcuts }
    private var pane: SettingsPane { store.currentPane }
    var body: some View {
        VStack(spacing: 0) {
            Divider()
            bar
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(usesBrandAccent ? brandTeal : nil)
    }
    private var bar: some View {
        HStack(spacing: 8) {
            // The status owns the leading edge on every pane, so it never shifts sideways when the
            // Shortcuts-only button appears; it can use two lines before anything is cut off.
            status
            // Not while a failed Apply's message and its links need the room.
            if showsResetAll && !store.hasBadOutcome {
                Button("Reset All Shortcuts") { store.draft.shortcuts = store.defaults }
                    .buttonStyle(.link).foregroundStyle(settingsAccent)
                    .disabled(store.draft.shortcuts == store.defaults || store.recordingID != nil)
                    .help("Restore every shortcut to its default")
                    .padding(.trailing, 4)
            }
            Button("Revert") { store.revert() }.disabled(!store.canRevert)
                .help("Discard unapplied changes")
            // Not the default button: Return in a field or the search box must never push a draft
            // spanning every pane to the live window manager. ⌘S applies from anywhere.
            Button("Apply") { store.apply() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!store.canApply)
                .help("Apply all changes (⌘S)")
        }
        .controlSize(.regular)
        .padding(.horizontal, 20).padding(.vertical, 10)
    }
    /// One line of footer status. `alert` text is shown in the label colour (red text on the window
    /// background is under 4.5:1); the dot carries the colour.
    struct Status: Equatable { var text: String; var dot: Color; var busy = false; var alert = false; var help: String? }
    var state: Status? {
        if store.phase == .applying { return Status(text: "Applying…", dot: .secondary, busy: true) }
        if store.recordingID != nil {
            if let note = store.recordingNote { return Status(text: note, dot: .orange, alert: true) }
            return store.recordingStarted ? Status(text: "Press the new shortcut. Esc cancels, Delete clears.", dot: settingsAccent) : Status(text: "Pausing Microfish shortcuts…", dot: .secondary, busy: true)
        }
        // What blocks Apply comes first, then what the last Apply said, then the draft.
        if store.conflictCount > 0 { return Status(text: "\(store.conflictCount) shortcut conflict\(store.conflictCount == 1 ? "" : "s") to resolve before applying", dot: .red, alert: true) }
        let shown = store.invalid.filter { store.flagged.contains($0.key) }
        if let message = SettingsPrefs.fields.compactMap({ shown[$0.key] }).first ?? shown.values.sorted().first { return Status(text: message, dot: .red, alert: true) }
        if let note = store.recordingNote { return Status(text: note, dot: .orange, alert: true) }
        if store.hasBadOutcome, let text = store.outcomeText { return Status(text: text, dot: .red, alert: true, help: store.outcomeDetail) }
        if store.isDirty { return Status(text: store.restoredDraft ? "Unapplied changes from earlier" : "Unapplied changes", dot: settingsAccent) }
        switch store.phase {
        case .waiting: return Status(text: "Applying…", dot: .secondary, busy: true)
        case .confirmed: return store.outcomeText.map { Status(text: $0, dot: store.applyNote == nil ? .green : .orange) }
        case .unconfirmed: return store.outcomeText.map { Status(text: $0, dot: .orange) }
        default: return nil
        }
    }
    @ViewBuilder private var status: some View {
        let current = state
        HStack(spacing: 6) {
            if let current {
                if current.busy { ProgressView().controlSize(.small) } else { Circle().fill(current.dot).frame(width: 7, height: 7) }
                Text(current.text).font(.callout).foregroundStyle(current.alert ? Color.primary : Color.secondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .help(current.help ?? current.text)
                if store.conflictCount > 0 && store.recordingID == nil && store.phase != .applying {
                    Button("Show") { if pane != .shortcuts { store.openPane?(.shortcuts) }; store.revealConflict += 1 }
                        .buttonStyle(.link).foregroundStyle(settingsAccent).font(.callout)
                        .accessibilityLabel("Show conflicting shortcut")
                }
                if store.hasBadOutcome && store.conflictCount == 0 && store.flagged.isDisjoint(with: store.invalid.keys) && store.recordingNote == nil && store.recordingID == nil {
                    if case .rejected = store.phase {
                        Button("Open Log") { NSWorkspace.shared.open(MicrofishPaths.engineLog) }.buttonStyle(.link).foregroundStyle(settingsAccent).font(.callout)
                    }
                    Button("Dismiss") { store.dismissOutcome() }.buttonStyle(.link).foregroundStyle(settingsAccent).font(.callout)
                }
            }
        }
        // Two lines of room in every state, so a long message never changes the bar's height or is cut.
        .frame(maxWidth: .infinity, minHeight: Self.statusHeight, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(current.map { "Status: " + $0.text } ?? "")
        .accessibilityHidden(current == nil)
    }
    static let statusHeight: CGFloat = 32
}

/// A label with an optional secondary line beneath it, the grouped-form idiom for hints and ranges.
struct HintLabel: View {
    let title: String; var hint: String?
    @Environment(\.isEnabled) private var isEnabled
    init(_ title: String, _ hint: String? = nil) { self.title = title; self.hint = hint }
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).foregroundStyle(isEnabled ? .primary : .secondary)
            if let hint { Text(hint).font(.caption).foregroundStyle(isEnabled ? .secondary : .tertiary).lineLimit(2).truncationMode(.middle) }
        }
    }
}

struct NumberField: View {
    @Bindable var store: SettingsStore
    let key: String, title: String, hint: String?, unit: String
    let value: Binding<Double>
    var whole = false
    @State private var text = ""
    /// Red only once the field is left or Return is pressed, so "0" on the way to "0.6" doesn't flash.
    @State private var showError = false
    @FocusState private var focused: Bool
    private var range: ClosedRange<Double> { SettingsPrefs.ranges[key] ?? -Double.greatestFiniteMagnitude...Double.greatestFiniteMagnitude }
    static func format(_ v: Double) -> String { v.rounded() == v && abs(v) < 1e9 ? String(Int(v)) : String(v) }
    var body: some View {
        LabeledContent {
            HStack(spacing: 6) {
                TextField(title, text: $text)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 64)
                    .accessibilityLabel(title + (unit.isEmpty ? "" : ", in " + (unit == "s" ? "seconds" : "points")))
                    .accessibilityHint(hint ?? "")
                    .accessibilityValue(store.invalid[key].map { text + ", invalid. " + $0 } ?? text)
                    .focused($focused)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(showError && store.invalid[key] != nil ? Color.red : .clear, lineWidth: 1.5).allowsHitTesting(false))
                    .onSubmit { flag() }
                    .onChange(of: text) { _, new in commit(new) }
                Text(unit).foregroundStyle(.secondary).frame(minWidth: 14, alignment: .leading).accessibilityHidden(true)
            }
        } label: { HintLabel(title, hint) }
        .onAppear { text = Self.format(value.wrappedValue) }
        .onChange(of: store.revision) { _, _ in text = Self.format(value.wrappedValue) }
        .onChange(of: focused) { _, now in if !now { flag() } }
        // Leaving the pane with a half-typed value returns the field to its last good value, so no
        // error is left behind where it can't be seen.
        .onDisappear { if store.invalid[key] != nil { store.invalid[key] = nil; store.flagged.remove(key); text = Self.format(value.wrappedValue); showError = false } }
    }
    private func flag() {
        showError = store.invalid[key] != nil
        if showError { store.flagged.insert(key) }
    }
    private func commit(_ new: String) {
        let trimmed = new.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let lo = Self.format(range.lowerBound), hi = Self.format(range.upperBound)
        guard let n = Double(trimmed), n.isFinite else { store.invalid[key] = "\(title) needs a number from \(lo) to \(hi)"; return }
        guard range.contains(n) else { store.invalid[key] = "\(title) must be \(lo)–\(hi)\(unit.isEmpty ? "" : " " + unit)"; return }
        guard !whole || n.rounded() == n else { store.invalid[key] = "\(title) must be a whole number"; return }
        store.invalid[key] = nil; store.flagged.remove(key); showError = false
        if value.wrappedValue != n { value.wrappedValue = n }
    }
}

/// A slider with its value read out, stepping in fixed increments so a nudge never writes 0.6347.
struct ValueSlider: View {
    let title: String; var hint: String?
    let value: Binding<Double>; let range: ClosedRange<Double>; let step: Double; var format = "%.2f"
    var body: some View {
        LabeledContent {
            HStack(spacing: 10) {
                // Quantized in the binding rather than with `step:`, which would draw a tick per step.
                Slider(value: Binding(get: { value.wrappedValue }, set: { new in
                    let snapped = min(range.upperBound, max(range.lowerBound, (new / step).rounded() * step))
                    let clean = (snapped * 1000).rounded() / 1000
                    if clean != value.wrappedValue { value.wrappedValue = clean }
                }), in: range).labelsHidden().frame(width: 170)
                    .accessibilityLabel(title).accessibilityValue(String(format: format, value.wrappedValue))
                Text(String(format: format, value.wrappedValue)).monospacedDigit().foregroundStyle(.secondary).frame(width: 34, alignment: .trailing).accessibilityHidden(true)
            }
        } label: { HintLabel(title, hint) }
    }
}

// MARK: - Behavior

struct BehaviorPane: View {
    @Bindable var store: SettingsStore
    var body: some View {
        Form {
            Section("Windows") {
                Toggle("Drag title bars to reorder columns", isOn: $store.draft.dragReorder)
                Toggle("Focus follows mouse", isOn: $store.draft.focusFollowsMouse)
                Toggle("Mouse follows focus", isOn: $store.draft.mouseFollowsFocus)
                Toggle("Center focused windows automatically", isOn: $store.draft.autoCenter)
            }
            Section("Spacing") {
                NumberField(store: store, key: "sliverWidth", title: "Edge sliver", hint: "How much of an off-screen neighbor stays visible · 0–200", unit: "pt", value: $store.draft.sliverWidth, whole: true)
                NumberField(store: store, key: "padding", title: "Outer padding", hint: "0–100", unit: "pt", value: $store.draft.padding, whole: true)
                NumberField(store: store, key: "windowGap", title: "Window padding", hint: "Per side · 0–100", unit: "pt", value: $store.draft.windowGap, whole: true)
            }
            Section("Trackpad & Scrolling") {
                LabeledContent("Swipe with") {
                    Picker("Swipe with", selection: $store.draft.swipeFingers) { Text("3 fingers").tag(3); Text("4 fingers").tag(4) }
                        .labelsHidden().pickerStyle(.segmented).fixedSize()
                }
                ValueSlider(title: "Swipe sensitivity", value: $store.draft.swipeSensitivity, range: 0.1...2, step: 0.05)
                ValueSlider(title: "Swipe deceleration", value: $store.draft.swipeDeceleration, range: 1...10, step: 0.5, format: "%.1f")
                Toggle("Reverse swipe direction", isOn: $store.draft.reverseSwipe)
                LabeledContent("Scroll the strip while holding") {
                    Picker("Scroll the strip while holding", selection: $store.draft.scrollModifier) {
                        Text("Hyper  ⌃⌥⌘").tag("hyper"); Text("Control-Option  ⌃⌥").tag("controlOption")
                    }
                    .labelsHidden().fixedSize()
                }
            }
        }
        .toggleStyle(.switch)
    }
}

// MARK: - Rows

struct Keycap: View {
    let text: String
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        Text(text).font(.system(size: 11, weight: .medium)).padding(.horizontal, 5).frame(minWidth: 20, minHeight: 18)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(contrast == .increased ? Color.primary.opacity(0.6) : Color(nsColor: .separatorColor), lineWidth: contrast == .increased ? 1.5 : 1))
    }
}

struct RowsPane: View {
    @Bindable var store: SettingsStore
    /// Builds a legend entry from the live bindings, so a rebound key never shows a stale cap.
    private func legend(_ title: String, _ ids: [String], hint: String? = nil, rowsOnly: Bool = true, _ suffix: String? = nil) -> some View {
        let parsed = ids.compactMap { store.draft.shortcuts[$0].flatMap(Chord.parse) }
        let mods = parsed.first?.mods ?? []
        let shared = parsed.allSatisfy { $0.mods == mods }
        let hyper: Set<String> = ["ctrl", "alt", "cmd"]
        func caps(_ m: Set<String>) -> [String] { m.isSuperset(of: hyper) ? ["Hyper"] + (m.contains("shift") ? ["⇧"] : []) : [Chord.modifiers(m)] }
        let spoken = ids.compactMap { store.draft.shortcuts[$0] }.filter { !$0.isEmpty }.map(Chord.spoken).joined(separator: ", or ")
        return LabeledContent {
            HStack(spacing: 4) {
                if parsed.isEmpty { Text("Not set").foregroundStyle(.secondary) }
                else {
                    let labels = shared ? caps(mods) + parsed.map { Chord.key($0.key) } : parsed.flatMap { caps($0.mods) + [Chord.key($0.key)] }
                    ForEach(Array(labels.enumerated()), id: \.offset) { Keycap(text: $0.element) }
                }
                if let suffix { Text(suffix).font(.caption).foregroundStyle(.secondary) }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spoken.isEmpty ? "Not set" : spoken + (suffix.map { ", " + $0 } ?? ""))
        } label: { HintLabel(title, hint) }
        .disabled(rowsOnly && !store.draft.rowsEnabled)
    }
    var body: some View {
        Form {
            Section {
                Toggle(isOn: $store.draft.rowsEnabled) { HintLabel("Virtual rows", "Stack strips vertically, up to 9 rows") }
            }
            Section {
                legend("Change row", ["row_north", "row_south"])
                legend(store.draft.rowsEnabled ? "Change row (Vim keys)" : "Move within a stack (Vim keys)", ["focus_k", "focus_j"], rowsOnly: false)
                legend("Move along the strip", ["focus_leftarrow", "focus_rightarrow"], rowsOnly: false)
                legend("Move window to another row", ["move_row_north", "move_row_south"])
                legend("Move whole column to another row", ["move_column_north", "move_column_south"])
                legend("New row", ["row_north", "row_south"], hint: "Change row past the top or bottom row")
            } header: {
                Text("Keys · Hyper is ⌃⌥⌘, or hold Caps Lock")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Empty rows disappear after you leave them; the row you’re on is always kept. Added rows last for the session. With rows off, ↑ ↓ and J K move within a stack and whole-column row commands are inactive.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Change these keys in Shortcuts") { store.openPane?(.shortcuts) }
                        .buttonStyle(.link).foregroundStyle(settingsAccent).font(.caption)
                }
            }
        }
        .toggleStyle(.switch)
    }
}

// MARK: - Shortcuts

struct ShortcutSearchField: NSViewRepresentable {
    @Binding var text: String
    let prompt: String
    let controller: SettingsController
    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField(); field.placeholderString = prompt; field.delegate = context.coordinator
        field.sendsSearchStringImmediately = true; field.setAccessibilityLabel("Search shortcuts")
        controller.searchField = field
        return field
    }
    func updateNSView(_ field: NSSearchField, context: Context) { if field.stringValue != text { field.stringValue = text }; field.placeholderString = prompt }
    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func controlTextDidChange(_ note: Notification) { if let f = note.object as? NSSearchField { text.wrappedValue = f.stringValue } }
    }
}

struct ShortcutSlot: View {
    @Bindable var store: SettingsStore
    let id: String
    /// Second binding of the same action in a paired row ("Focus left" ← and H).
    var alternate = false
    var body: some View {
        let chord = store.draft.shortcuts[id] ?? ""
        let recording = store.recordingID == id
        let conflicted = store.conflicts[id] != nil
        let name = store.label(for: id) + (alternate ? ", alternate" : "")
        let fallback = store.defaults[id] ?? ""
        let helpText: String = fallback.isEmpty || fallback == chord ? name : name + " · default " + Chord.display(fallback)
        let valueText: String = recording ? "Recording. Press a shortcut, Escape cancels, Delete clears." : chord.isEmpty ? "Not set" : Chord.spoken(chord) + (conflicted ? ", conflicts" : "")
        let restoreTitle: String = fallback.isEmpty ? "Restore Default" : "Restore Default (" + Chord.display(fallback) + ")"
        Button {
            if recording { store.cancelRecording?() } else { store.beginRecording?(id) }
        } label: {
            Group {
                if recording { Text(store.recordingStarted ? "Press keys…" : "…").foregroundStyle(.tint) }
                else if chord.isEmpty { Text("Not set").foregroundStyle(.secondary) }
                else { Text(Chord.display(chord)).monospacedDigit().foregroundStyle(Color.primary) }
            }
            .lineLimit(1)
            // One width for every state, so recording or clearing never shifts the row.
            .frame(width: 84)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(recording ? AnyShapeStyle(.tint) : AnyShapeStyle(conflicted ? Color.red : .clear), lineWidth: 1.5).allowsHitTesting(false))
        // Clicking another slot while recording switches the target, as in System Settings.
        .disabled(store.phase == .applying)
        .help(helpText)
        .accessibilityLabel(name)
        .accessibilityValue(valueText)
        .accessibilityHint("Records a new shortcut")
        .contextMenu {
            Button("Record Shortcut") { store.beginRecording?(id) }
            Button("Clear") { store.draft.shortcuts[id] = "" }.disabled(chord.isEmpty)
            Button(restoreTitle) { store.draft.shortcuts[id] = fallback }.disabled(chord == fallback)
        }
    }
}

struct ShortcutsPane: View {
    @Bindable var store: SettingsStore
    let controller: SettingsController
    @State private var query = ""
    private func matches(_ row: ShortcutLayout.Row, group: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty { return true }
        let hay = ([row.title, group] + row.ids.map(store.label(for:)) + row.ids.map { Chord.display(store.draft.shortcuts[$0] ?? "") + " " + Chord.spoken(store.draft.shortcuts[$0] ?? "") }).joined(separator: " ").lowercased()
        return q.split(separator: " ").allSatisfy { hay.contains($0) }
    }
    var body: some View {
        let groups = ShortcutLayout.groups(store.catalog, rowsEnabled: store.draft.rowsEnabled)
        let visible = groups.map { g in (g, g.rows.filter { matches($0, group: g.id) }) }.filter { !$0.1.isEmpty }
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ShortcutSearchField(text: $query, prompt: "Search \(store.catalog.count) actions", controller: controller).frame(maxWidth: 260)
                Spacer(minLength: 0)
                Text("Click a shortcut, then press keys · Esc cancels").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 2)
            if visible.isEmpty && !store.catalog.isEmpty {
                ContentUnavailableView.search(text: query).frame(maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    Form {
                        if store.catalog.isEmpty { Text("Shortcuts couldn’t be loaded, so they can’t be changed.").foregroundStyle(.secondary) }
                        ForEach(visible, id: \.0.id) { group, rows in
                            Section(group.id) {
                                ForEach(rows) { row in ShortcutRowView(store: store, row: row).id(row.id) }
                            }
                        }
                    }
                    .onChange(of: store.revealConflict) { _, _ in
                        // Clear any filter that hides the conflict, then bring the first one into view.
                        query = ""
                        let conflicted = Set(store.conflicts.keys)
                        guard let target = groups.flatMap(\.rows).first(where: { $0.ids.contains(where: conflicted.contains) }) else { return }
                        DispatchQueue.main.async { withAnimation { proxy.scrollTo(target.id, anchor: .center) } }
                    }
                }
            }
        }
    }
}

struct ShortcutRowView: View {
    @Bindable var store: SettingsStore
    let row: ShortcutLayout.Row
    var body: some View {
        let conflictIDs = row.ids.filter { store.conflicts[$0] != nil }
        // "Pick another" belongs on the binding the user just changed; if neither side changed (or
        // both did), both rows carry it.
        let edited: (String) -> Bool = { store.draft.shortcuts[$0] != store.saved.shortcuts[$0] }
        let blamed = conflictIDs.filter { id in edited(id) || !(store.conflicts[id] ?? []).contains(where: edited) }
        let names = Array(Set(blamed.flatMap { store.conflicts[$0] ?? [] })).sorted().map(store.label(for:))
        let others = names.count > 2 ? names.prefix(2).joined(separator: ", ") + " and \(names.count - 2) more" : names.joined(separator: " and ")
        let changed = row.ids.contains { (store.draft.shortcuts[$0] ?? "") != (store.defaults[$0] ?? "") }
        let sameAction = row.ids.count == 2 && store.label(for: row.ids[0]) == store.label(for: row.ids[1])
        LabeledContent {
            HStack(spacing: 6) {
                // Always laid out so the slots stay in one column; shown only when the row differs.
                Button { for id in row.ids { store.draft.shortcuts[id] = store.defaults[id] ?? "" } } label: { Image(systemName: "arrow.uturn.backward") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                    .help("Restore default").accessibilityLabel("Restore default for \(row.title)")
                    .disabled(store.recordingID != nil || !changed)
                    .opacity(changed ? 1 : 0).accessibilityHidden(!changed)
                ForEach(Array(row.ids.enumerated()), id: \.element) { i, id in ShortcutSlot(store: store, id: id, alternate: sameAction && i == 1) }
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                if !names.isEmpty { Text("Also used by \(others). Pick another.").font(.caption).foregroundStyle(Color.primary).lineLimit(2) }
            }
        }
        .listRowBackground(blamed.isEmpty ? nil : Color.red.opacity(0.08))
    }
}

// MARK: - Appearance

private func tabStyleImage(_ style: String) -> NSImage {
    NSImage(size: NSSize(width: 92, height: 50), flipped: false) { _ in
        let page = CGRect(x: style == "side" ? 26 : 10, y: 4, width: style == "side" ? 60 : 72, height: style == "side" ? 42 : 30)
        NSColor.textBackgroundColor.setFill(); NSBezierPath(roundedRect: page, xRadius: 3, yRadius: 3).fill()
        NSColor.separatorColor.setStroke(); let outline = NSBezierPath(roundedRect: page.insetBy(dx: 0.25, dy: 0.25), xRadius: 3, yRadius: 3); outline.lineWidth = 0.5; outline.stroke()
        for i in 0..<3 {
            let selected = i == (style == "side" ? 0 : 1)
            let r: CGRect
            switch style {
            case "side": r = CGRect(x: 14, y: page.maxY - CGFloat(i + 1) * 14, width: 12, height: 14)
            case "classic": r = CGRect(x: page.minX + CGFloat(i) * 24, y: page.maxY, width: 24, height: 10)
            default: r = CGRect(x: page.minX + 4 + CGFloat(i) * 21, y: page.maxY - 0.5, width: 22, height: 11)
            }
            (selected ? NSColor.textBackgroundColor : NSColor.quaternaryLabelColor).setFill()
            let path = style == "folder" ? folderTabPath(in: r, selected: selected) : NSBezierPath(rect: r)
            path.fill(); NSColor.separatorColor.setStroke(); path.lineWidth = 0.5; path.stroke()
            if selected { NSColor(srgbRed: 0, green: 0.57, blue: 0.58, alpha: 1).setFill(); NSBezierPath(rect: style == "side" ? CGRect(x: r.minX, y: r.minY + 2, width: 2, height: r.height - 4) : CGRect(x: r.midX - 5, y: r.maxY - 3, width: 10, height: 1.5)).fill() }
        }
        return true
    }
}

struct TabStylePicker: View {
    @Binding var style: String
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var scheme
    private var base: String { style == "folder-compact" ? "folder" : style }
    var body: some View {
        HStack(spacing: 10) {
            ForEach([("folder", "Folder"), ("classic", "Classic"), ("side", "Side")], id: \.0) { value, title in
                let on = base == value
                Button {
                    if !on { style = value }
                } label: {
                    VStack(spacing: 6) {
                        Image(nsImage: tabStyleImage(value)).id(scheme)  // redraw the thumbnail when the appearance flips
                            .padding(6).frame(maxWidth: .infinity)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .quaternarySystemFill)))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(on ? AnyShapeStyle(.tint) : AnyShapeStyle(contrast == .increased ? Color.primary.opacity(0.6) : Color(nsColor: .separatorColor)), lineWidth: on ? 2.5 : contrast == .increased ? 1.5 : 1))
                        Text(title).font(.callout).foregroundStyle(on ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary)).fontWeight(on ? .semibold : .regular)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(title + " tabs")
                .accessibilityAddTraits(on ? [.isSelected] : [])
            }
        }
        // VoiceOver reads it as what it is: one choice of three.
        .accessibilityRepresentation {
            Picker("Tab style", selection: Binding(get: { base }, set: { if $0 != base { style = $0 } })) {
                Text("Folder").tag("folder"); Text("Classic").tag("classic"); Text("Side").tag("side")
            }
            .pickerStyle(.radioGroup)
        }
    }
}

struct OutlinePreview: View {
    let color: Color; let width: Double; let radius: Double
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .textBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
                .overlay(alignment: .topLeading) {
                    HStack(spacing: 4) { ForEach(0..<3, id: \.self) { _ in Circle().fill(Color(nsColor: .tertiaryLabelColor)).frame(width: 6, height: 6) } }.padding(7)
                }
                .padding(width == 0 ? 6 : width + 3)
            if width == 0 {
                RoundedRectangle(cornerRadius: min(radius, 30)).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 3])).foregroundStyle(.tertiary)
                VStack(spacing: 1) { Text("Outline hidden"); Text("at 0 pt") }.font(.caption).foregroundStyle(.secondary)
            } else {
                RoundedRectangle(cornerRadius: min(radius, 30)).strokeBorder(color, lineWidth: width)
            }
        }
        .frame(width: 150, height: 92)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(width == 0 ? "Outline preview: hidden" : "Outline preview: \(NumberField.format(width)) point outline, \(NumberField.format(radius)) point corners")
    }
}

struct AppearancePane: View {
    @Bindable var store: SettingsStore
    @State private var hexText = ""
    @FocusState private var hexFocused: Bool
    private var color: Binding<Color> {
        Binding(get: { Color(nsColor: Self.nsColor(store.draft.borderColor)) }, set: { new in
            if let rgb = NSColor(new).usingColorSpace(.sRGB) {
                let hex = String(format: "#%02X%02X%02X", Int((rgb.redComponent * 255).rounded()), Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
                if hex.caseInsensitiveCompare(store.draft.borderColor) != .orderedSame { store.draft.borderColor = hex }
            }
        })
    }
    static func nsColor(_ hex: String) -> NSColor {
        let v = UInt32(hex.dropFirst(), radix: 16) ?? 0x009193
        return NSColor(srgbRed: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1)
    }
    private var compact: Binding<Bool> {
        Binding(get: { store.draft.tabStyle == "folder-compact" }, set: { store.draft.tabStyle = $0 ? "folder-compact" : "folder" })
    }
    var body: some View {
        Form {
            Section("Focused Window Outline") {
                OutlinePreview(color: Color(nsColor: Self.nsColor(store.draft.borderColor)), width: store.draft.borderWidth, radius: store.draft.borderRadius)
                    .frame(maxWidth: .infinity).padding(.vertical, 4)
                LabeledContent("Color") {
                    HStack(spacing: 8) {
                        TextField("Hex color", text: $hexText).labelsHidden().textFieldStyle(.roundedBorder).frame(width: 84).font(.body.monospacedDigit())
                            .focused($hexFocused)
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(store.invalid["borderColor"] != nil && !hexFocused ? Color.red : .clear, lineWidth: 1.5).allowsHitTesting(false))
                            .accessibilityLabel("Outline color, hex")
                            .onSubmit(commitHex)
                            .onChange(of: hexText) { _, _ in checkHex() }
                            .onChange(of: hexFocused) { _, focused in if !focused { commitHex() } }
                        ColorPicker("Outline color", selection: color, supportsOpacity: false).labelsHidden()
                    }
                }
                NumberField(store: store, key: "borderWidth", title: "Width", hint: "0 hides the outline · up to 12", unit: "pt", value: $store.draft.borderWidth)
                NumberField(store: store, key: "borderRadius", title: "Corner radius", hint: "0–60", unit: "pt", value: $store.draft.borderRadius)
            }
            Section("Tab Bars") {
                TabStylePicker(style: $store.draft.tabStyle).padding(.vertical, 4)
                if store.draft.tabStyle.hasPrefix("folder") {
                    Toggle(isOn: compact) { HintLabel("Compact folder tabs", "Every tab the same short height · \(store.draft.tabHeight == 34 ? 25 : 20) pt") }
                }
                LabeledContent {
                    Picker("Tab height", selection: $store.draft.tabHeight) { Text("Standard").tag(28); Text("Roomy").tag(34) }
                        .labelsHidden().pickerStyle(.segmented).fixedSize()
                } label: {
                    HintLabel("Tab height", store.draft.tabStyle == "side" ? "Side tabs fill the window’s height" : "Folder and Classic · Standard 28 pt, Roomy 34 pt")
                }
                Toggle(isOn: $store.draft.tabMatchAppColor) {
                    HintLabel("Match selected tab to app color", store.canSampleScreen ? "Samples only the selected window" : "Needs Screen Recording access; until then tabs use theme colors")
                }
                if store.draft.tabMatchAppColor && !store.canSampleScreen {
                    LabeledContent("Screen Recording") {
                        Button("Allow Screen Recording…") { _ = CGRequestScreenCaptureAccess(); store.canSampleScreen = CGPreflightScreenCaptureAccess() }
                    }
                }
                LabeledContent("Rename individual tabs") {
                    Button("Open Window Rules") { store.openPane?(.rules) }.buttonStyle(.link).foregroundStyle(settingsAccent)
                }
            }
        }
        .toggleStyle(.switch)
        .onAppear { hexText = store.draft.borderColor.uppercased() }
        .onChange(of: store.draft.borderColor) { _, new in if new.caseInsensitiveCompare(hexText) != .orderedSame { hexText = new.uppercased() } }
        .onChange(of: store.revision) { _, _ in hexText = store.draft.borderColor.uppercased(); store.invalid["borderColor"] = nil }
    }
    static func validHex(_ s: String) -> Bool { s.range(of: #"^#?[0-9A-Fa-f]{6}$"#, options: .regularExpression) != nil }
    /// Live while typing: a complete value applies, a partial one is marked rather than half-applied.
    private func checkHex() {
        let t = hexText.trimmingCharacters(in: .whitespaces)
        if Self.validHex(t) { commitHex() } else { store.invalid["borderColor"] = "Outline color needs six hex digits, like #009193" }  // quiet until left
    }
    private func commitHex() {
        let t = hexText.trimmingCharacters(in: .whitespaces)
        store.invalid["borderColor"] = nil; store.flagged.remove("borderColor")
        guard Self.validHex(t) else { hexText = store.draft.borderColor.uppercased(); return }
        let hex = "#" + t.replacingOccurrences(of: "#", with: "").uppercased()
        if hex.caseInsensitiveCompare(store.draft.borderColor) != .orderedSame { store.draft.borderColor = hex }
    }
}

// MARK: - Minimap

struct MinimapPositionDiagram: View {
    @Binding var position: String
    @Environment(\.colorSchemeContrast) private var contrast
    private let targets: [(String, CGRect)] = [("top", CGRect(x: 60, y: 6, width: 30, height: 14)), ("left", CGRect(x: 8, y: 32, width: 18, height: 28)),
                                               ("center", CGRect(x: 55, y: 30, width: 40, height: 32)), ("right", CGRect(x: 124, y: 32, width: 18, height: 28)),
                                               ("bottom", CGRect(x: 60, y: 72, width: 30, height: 14))]
    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .quaternarySystemFill))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
            ForEach(targets, id: \.0) { name, rect in
                let on = position == name
                Button { position = name } label: {
                    RoundedRectangle(cornerRadius: 3).fill(on ? AnyShapeStyle(.tint) : AnyShapeStyle(Color(nsColor: .controlBackgroundColor)))
                        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(on ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.secondary.opacity(contrast == .increased ? 1 : 0.6)), lineWidth: contrast == .increased ? 1.5 : 1))
                }
                .buttonStyle(.plain)
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
                .help(name.capitalized)
                .accessibilityLabel(name.capitalized)
                .accessibilityAddTraits(on ? [.isSelected] : [])
            }
        }
        .frame(width: 150, height: 92)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Minimap position")
    }
}

struct MinimapPane: View {
    @Bindable var store: SettingsStore
    var body: some View {
        Form {
            Section {
                LabeledContent {
                    MinimapPositionDiagram(position: $store.draft.minimapPosition).padding(.vertical, 4)
                } label: { HintLabel("Position", store.draft.minimapPosition.capitalized) }
                LabeledContent("Show") {
                    Picker("Show", selection: $store.draft.minimapStyle) { Text("Cards").tag("cards"); Text("Compact").tag("compact"); Text("Titles").tag("titles") }
                        .labelsHidden().pickerStyle(.segmented).fixedSize()
                }
            }
            Section("Timing") {
                LabeledContent {
                    Picker("Hide", selection: $store.draft.minimapHide) { Text("When Hyper is released").tag("release"); Text("After a delay").tag("timer") }
                        .labelsHidden().pickerStyle(.menu).fixedSize()
                } label: {
                    HintLabel("Hide", store.draft.minimapHide == "release" ? "Stays while Hyper is held, like ⌘Tab" : "Counts down after each navigation")
                }
                NumberField(store: store, key: "minimapDelay", title: "Hide after", hint: store.draft.minimapHide == "release" ? "Swipes and scrolling always use this · 0.1–10" : "Counted from the end of navigation · 0.1–10", unit: "s", value: $store.draft.minimapDelay)
                NumberField(store: store, key: "minimapFade", title: "Fade", hint: store.draft.minimapHide == "release" ? "0–3 · at most 0.12 s when Hyper is released" : "0–3", unit: "s", value: $store.draft.minimapFade)
            }
            Section {
                Toggle("Show while Hyper is held", isOn: $store.draft.showOnHyper)
                NumberField(store: store, key: "hyperHoldDelay", title: "Hold for", hint: "0.05–2", unit: "s", value: $store.draft.hyperHoldDelay)
                    .disabled(!store.draft.showOnHyper)
            } header: { Text("Reveal") } footer: {
                Text("Arrow navigation and scrolling always reveal the minimap.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.switch)
    }
}

// MARK: - Window rules

struct RulesPane: View {
    @Bindable var store: SettingsStore
    private var selected: LiveWindowEntry? { store.windows.first { $0.id == store.selectedWindowID } }
    private var alias: Binding<String> {
        Binding(get: { selected.flatMap { store.draft.tabAliases[$0.aliasKey] } ?? "" }, set: { text in
            guard let w = selected else { return }
            let clean = String(text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\t", with: " ").prefix(200))
            if clean.trimmingCharacters(in: .whitespaces).isEmpty { store.draft.tabAliases.removeValue(forKey: w.aliasKey) } else { store.draft.tabAliases[w.aliasKey] = clean }
        })
    }
    private func exactPattern(_ w: LiveWindowEntry) -> String { "^" + SettingsController.escapeRegex(w.title) + "$" }
    private func hasRule(_ w: LiveWindowEntry, exact: Bool) -> Bool { store.draft.floatingRules.contains { $0.bundle == w.bundle && $0.titlePattern == (exact ? exactPattern(w) : ".*") } }
    private func add(_ w: LiveWindowEntry, exact: Bool) {
        guard !hasRule(w, exact: exact) else { return }
        store.draft.floatingRules.append(FloatRule(id: UUID().uuidString, bundle: w.bundle, titlePattern: exact ? exactPattern(w) : ".*", enabled: true))
    }
    static func removeButton(_ action: (() -> Void)?) -> some View {
        Button { action?() } label: { Image(systemName: "minus.circle") }
            .buttonStyle(.borderless).foregroundStyle(.secondary).help("Remove rule")
    }
    /// Menu items don't truncate on their own; keep long document titles to a readable middle cut.
    static func menuTitle(_ w: LiveWindowEntry) -> String {
        let title = w.title.isEmpty ? "Untitled" : w.title
        let room = max(16, 46 - w.app.count)
        let cut = title.count > room ? String(title.prefix(room * 2 / 3)) + "…" + String(title.suffix(room / 3)) : title
        return w.app + " — " + cut
    }
    static func describe(_ pattern: String) -> String {
        if pattern == ".*" { return "All windows" }
        if pattern.hasPrefix("^"), pattern.hasSuffix("$"), pattern.count >= 2, isLiteralTitle(String(pattern.dropFirst().dropLast())) { return "Window titled “" + SettingsController.unescapeRegex(String(pattern.dropFirst().dropLast())) + "”" }
        return "Titles matching “" + pattern + "”"
    }
    /// True when every regex operator in `text` is escaped, so it names one title and nothing else.
    nonisolated static func isLiteralTitle(_ text: String) -> Bool {
        var escaping = false
        for c in text {
            if escaping { escaping = false } else if c == "\\" { escaping = true } else if ".*+?()[]{}|^$".contains(c) { return false }
        }
        return !escaping
    }
    var body: some View {
        Form {
            Section("Window") {
                LabeledContent("Selected") {
                    HStack(spacing: 6) {
                        if store.windows.isEmpty { Text(store.windowsNote ?? "No windows").foregroundStyle(.secondary) }
                        else {
                            Picker("Selected window", selection: $store.selectedWindowID) {
                                ForEach(store.windows) { w in Text(Self.menuTitle(w)).tag(Optional(w.id)) }
                            }
                            .labelsHidden().frame(maxWidth: 330)
                        }
                        Button { store.refreshWindows() } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.borderless).foregroundStyle(.secondary).help("Refresh the window list").accessibilityLabel("Refresh window list")
                    }
                }
                LabeledContent("Tab title") {
                    HStack(spacing: 6) {
                        TextField("Tab title", text: alias, prompt: Text("Use window title")).labelsHidden().textFieldStyle(.roundedBorder).multilineTextAlignment(.leading).frame(maxWidth: 260)
                        Button("Reset") { alias.wrappedValue = "" }.disabled(alias.wrappedValue.isEmpty)
                    }
                }
                .disabled(selected == nil)
                LabeledContent("Always float") {
                    HStack(spacing: 6) {
                        Button("This window") { if let w = selected { add(w, exact: true) } }
                            .help("Floats this app’s windows with exactly this title").disabled(selected.map { $0.bundle.isEmpty || hasRule($0, exact: true) } ?? true)
                        Button("Whole app") { if let w = selected { add(w, exact: false) } }.disabled(selected.map { $0.bundle.isEmpty || hasRule($0, exact: false) } ?? true)
                    }
                }
            }
            Section {
                LabeledContent {
                    HStack(spacing: 8) {
                        Toggle("Picture in Picture", isOn: $store.draft.floatPip).labelsHidden()
                        Self.removeButton(nil).hidden()  // keeps every switch in one column
                    }
                } label: {
                    Label { HintLabel("Picture in Picture", "Titles “Picture in Picture”, “Picture-in-Picture” or “PiP”") } icon: {
                        Image(systemName: "pip").frame(width: 20).foregroundStyle(.secondary)
                    }
                }
                if store.draft.floatingRules.isEmpty {
                    Text("No custom rules yet — select a window above to add one").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 8)
                } else {
                    ForEach($store.draft.floatingRules) { $rule in
                        let app = store.app(rule.bundle)
                        let remove = { store.draft.floatingRules.removeAll { $0.id == rule.id } }
                        LabeledContent {
                            HStack(spacing: 8) {
                                Toggle(app.name, isOn: $rule.enabled).labelsHidden()
                                Self.removeButton(remove).accessibilityLabel("Remove rule for \(app.name)")
                            }
                        } label: {
                            Label { HintLabel(app.name, Self.describe(rule.titlePattern)) } icon: {
                                if let icon = app.icon { Image(nsImage: icon).resizable().frame(width: 20, height: 20) } else { Image(systemName: "macwindow").frame(width: 20).foregroundStyle(.secondary) }
                            }
                        }
                        .contextMenu { Button("Remove Rule", action: remove) }
                    }
                }
            } header: { Text("Floating Rules") } footer: {
                Text("Removing a rule doesn’t re-tile open windows; press \(store.draft.shortcuts["float"].map(SettingsController.displayChord) ?? "Hyper Space") on them.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.switch)
    }
}
