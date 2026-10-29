import Foundation

// Settings Apply: validates a draft and applies it. A behaviour-identical Swift port of the
// workspace's apply-settings.py, so the shipped app needs no Python (stock macOS has none).
//
// What stays identical to the script, on purpose: the validation order and every message, the bytes
// of preferences.json / settings.lua / shortcuts.lua, the `-- settings revision` line in init.lua,
// the exclusive lock, the backup copy taken before any write, the bridge requests and their
// timeouts, and the result contract the Settings footer parses (status 0 = saved, anything else =
// failed with one plain sentence; "could not be applied" in the success line = windows not floated).
//
// Numbers keep their JSON type (6 stays 6, 6.0 stays 6.0, 0.06 prints as 0.06), strings are kept as
// code points (a lone surrogate survives parsing and fails at the same step the script fails), and
// dictionaries keep insertion order. That is why this file carries its own small JSON reader and writer
// instead of using JSONSerialization.

// MARK: - Result

struct SettingsApplyResult: Equatable {
    /// 0 = saved. Anything else = failed; the sentence is in `stderr`.
    var status: Int32
    /// What the script prints on success ("Saved. …" with a trailing newline).
    var stdout: String
    /// What the script prints on failure (one plain sentence with a trailing newline).
    var stderr: String
    /// stdout + stderr, trimmed: the string the Settings window shows or matches against.
    var message: String { (stdout + stderr).trimmingCharacters(in: .whitespacesAndNewlines) }
    var succeeded: Bool { status == 0 }
}

/// Where Apply reads and writes. `current` resolves through `MicrofishPaths` (so the test
/// environment variables apply); tests may build their own.
struct SettingsApplyLocations {
    var preferences: URL
    var initLua: URL
    var settingsLua: URL
    var shortcutsLua: URL
    var runtime: URL
    var backups: URL
    var log: URL
    var catalog: URL
    var bridge: URL
    var engine: URL
    var childEnvironment: [String: String]

    static var current: SettingsApplyLocations {
        SettingsApplyLocations(
            preferences: MicrofishPaths.preferences, initLua: MicrofishPaths.initLua,
            settingsLua: MicrofishPaths.settingsLua, shortcutsLua: MicrofishPaths.shortcutsLua,
            runtime: MicrofishPaths.runtime, backups: MicrofishPaths.settingsBackups,
            log: MicrofishPaths.logs.appendingPathComponent("settings-apply.log"),
            catalog: MicrofishPaths.shortcutCatalog, bridge: MicrofishPaths.bridgeExecutable,
            engine: MicrofishPaths.engineExecutable, childEnvironment: MicrofishPaths.childEnvironment)
    }
}

// MARK: - Values (JSON as Python reads it)

typealias SettingsApplyText = [UInt32]

private func T(_ s: String) -> SettingsApplyText { s.unicodeScalars.map { $0.value } }

indirect enum SettingsApplyValue: Equatable {
    case null
    case bool(Bool)
    case int(Int)
    /// An integer beyond Int64. It only ever fails a range check, so only its sign is kept.
    case bigInt(negative: Bool)
    case float(Double)
    case string(SettingsApplyText)
    case list([SettingsApplyValue])
    case dict(SettingsApplyDict)

    static func s(_ text: String) -> SettingsApplyValue { .string(T(text)) }
    var isNumber: Bool { switch self { case .int, .bigInt, .float: return true; default: return false } }
    var text: SettingsApplyText? { if case .string(let t) = self { return t }; return nil }
    var dictionary: SettingsApplyDict? { if case .dict(let d) = self { return d }; return nil }
    /// Python truthiness.
    var truthy: Bool {
        switch self {
        case .null: return false
        case .bool(let b): return b
        case .int(let i): return i != 0
        case .bigInt: return true
        case .float(let d): return d != 0
        case .string(let t): return !t.isEmpty
        case .list(let l): return !l.isEmpty
        case .dict(let d): return d.count > 0
        }
    }
    /// A number as Python would compare it (bool counts as 0/1). nil for anything else.
    var comparable: Double? {
        switch self {
        case .bool(let b): return b ? 1 : 0
        case .int(let i): return Double(i)
        case .bigInt(let neg): return neg ? -Double.infinity : Double.infinity
        case .float(let d): return d
        default: return nil
        }
    }
}

/// An insertion-ordered dictionary with Python's assignment rule: a repeated key keeps its first place
/// and takes the last value.
struct SettingsApplyDict: Equatable {
    private(set) var keys: [SettingsApplyText] = []
    private var storage: [SettingsApplyText: SettingsApplyValue] = [:]
    init() {}
    init(_ pairs: [(String, SettingsApplyValue)]) { for (k, v) in pairs { self[T(k)] = v } }
    var count: Int { keys.count }
    var items: [(key: SettingsApplyText, value: SettingsApplyValue)] { keys.map { ($0, storage[$0]!) } }
    subscript(key: SettingsApplyText) -> SettingsApplyValue? {
        get { storage[key] }
        set {
            guard let newValue else { if storage.removeValue(forKey: key) != nil { keys.removeAll { $0 == key } }; return }
            if storage[key] == nil { keys.append(key) }
            storage[key] = newValue
        }
    }
    subscript(key: String) -> SettingsApplyValue? {
        get { storage[T(key)] }
        set { self[T(key)] = newValue }
    }
    func contains(_ key: String) -> Bool { storage[T(key)] != nil }
}

// MARK: - Failures

enum SettingsApplyFailure: Error {
    /// The script raises ValueError(message): the sentence goes to the footer as is.
    case message(String)
    /// A JSON reading error or any unexpected error: the generic sentence; the detail goes to the log.
    case generic(String)
    /// A bridge call that did not answer in time.
    case timeout(String)
}

private let genericText = "Microfish couldn’t save these settings."
private let timeoutText = "Microfish isn’t responding. Try again."

// MARK: - Python text rules

private enum Py {
    static func isSpace(_ c: UInt32) -> Bool {
        switch c {
        case 0x09...0x0D, 0x1C...0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000: return true
        default: return false
        }
    }
    static func strip(_ t: SettingsApplyText) -> SettingsApplyText {
        var a = 0, b = t.count
        while a < b, isSpace(t[a]) { a += 1 }
        while b > a, isSpace(t[b - 1]) { b -= 1 }
        return Array(t[a..<b])
    }
    static func rstrip(_ t: SettingsApplyText) -> SettingsApplyText {
        var b = t.count
        while b > 0, isSpace(t[b - 1]) { b -= 1 }
        return Array(t[0..<b])
    }
    static func lower(_ t: SettingsApplyText) -> SettingsApplyText {
        var out: SettingsApplyText = []
        for c in t {
            if let u = Unicode.Scalar(c) { out.append(contentsOf: u.properties.lowercaseMapping.unicodeScalars.map { $0.value }) } else { out.append(c) }
        }
        return out
    }
    static func split(_ t: SettingsApplyText, on sep: SettingsApplyText) -> [SettingsApplyText] {
        var parts: [SettingsApplyText] = [], current: SettingsApplyText = [], i = 0
        while i < t.count {
            if i + sep.count <= t.count, Array(t[i..<(i + sep.count)]) == sep { parts.append(current); current = []; i += sep.count } else { current.append(t[i]); i += 1 }
        }
        parts.append(current)
        return parts
    }
    /// str.splitlines() with the default (no line ends kept).
    static func splitLines(_ t: SettingsApplyText) -> [SettingsApplyText] {
        var lines: [SettingsApplyText] = [], current: SettingsApplyText = [], i = 0
        while i < t.count {
            let c = t[i]
            switch c {
            case 0x0A, 0x0B, 0x0C, 0x1C, 0x1D, 0x1E, 0x85, 0x2028, 0x2029, 0x0D:
                lines.append(current); current = []
                if c == 0x0D, i + 1 < t.count, t[i + 1] == 0x0A { i += 1 }
            default: current.append(c)
            }
            i += 1
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }
    /// UTF-8 for a string, or nil when it holds a lone surrogate (Python's "surrogates not allowed").
    static func utf8(_ t: SettingsApplyText) -> [UInt8]? {
        var out: [UInt8] = []
        for c in t {
            guard let u = Unicode.Scalar(c) else { return nil }
            out.append(contentsOf: Array(String(Character(u)).utf8))
        }
        return out
    }
    static func string(_ t: SettingsApplyText) -> String {
        var s = String.UnicodeScalarView()
        for c in t { s.append(Unicode.Scalar(c) ?? "\u{FFFD}") }
        return String(s)
    }
    /// Python's float repr: the shortest string that reads back as the same double.
    static func floatRepr(_ d: Double) -> String {
        if d.isNaN { return "nan" }
        if d.isInfinite { return d < 0 ? "-inf" : "inf" }
        if d == 0 { return d.sign == .minus ? "-0.0" : "0.0" }
        let sign = d < 0 ? "-" : ""
        let description = "\(abs(d))"
        let halves = description.split(separator: "e", omittingEmptySubsequences: false)
        let mantissa = String(halves[0]), exponent = halves.count > 1 ? Int(halves[1])! : 0
        let parts = mantissa.split(separator: ".", omittingEmptySubsequences: false)
        let whole = String(parts[0]), fraction = parts.count > 1 ? String(parts[1]) : ""
        var digits = Array(whole + fraction), point = whole.count + exponent
        while digits.first == "0" { digits.removeFirst(); point -= 1 }
        while digits.last == "0" { digits.removeLast() }
        let body: String
        if point <= -4 || point > 16 {
            let e = point - 1
            let tail = String(digits.dropFirst())
            body = String(digits[0]) + (tail.isEmpty ? "" : "." + tail) + "e" + (e < 0 ? "-" : "+") + (abs(e) < 10 ? "0" : "") + String(abs(e))
        } else if point <= 0 {
            body = "0." + String(repeating: "0", count: -point) + String(digits)
        } else if point >= digits.count {
            body = String(digits) + String(repeating: "0", count: point - digits.count) + ".0"
        } else {
            body = String(digits[0..<point]) + "." + String(digits[point...])
        }
        return sign + body
    }
}

// MARK: - JSON reader (Python's json module, strict, plus NaN / Infinity)

private struct SettingsApplyJSONReader {
    /// Python's own recursion limit stops the script a little below 1000 levels (it answers with the
    /// generic sentence); the reader gives up at the same depth.
    static let maxDepth = 990
    let s: [UInt32]
    var i = 0

    struct Bad: Error {}

    init(_ text: SettingsApplyText) { s = text }

    static func parse(_ text: SettingsApplyText) throws -> SettingsApplyValue {
        var r = SettingsApplyJSONReader(text)
        r.skip()
        let v = try r.value(depth: 0)
        r.skip()
        if r.i != r.s.count { throw Bad() }
        return v
    }

    mutating func skip() { while i < s.count, s[i] == 0x20 || s[i] == 0x09 || s[i] == 0x0A || s[i] == 0x0D { i += 1 } }
    func isDigit(_ c: UInt32) -> Bool { c >= 0x30 && c <= 0x39 }
    func starts(_ word: String) -> Bool {
        let w = T(word)
        return i + w.count <= s.count && Array(s[i..<(i + w.count)]) == w
    }

    mutating func value(depth: Int) throws -> SettingsApplyValue {
        guard i < s.count else { throw Bad() }
        switch s[i] {
        case 0x22: return .string(try string())
        case 0x7B: return try object(depth: depth + 1)
        case 0x5B: return try array(depth: depth + 1)
        case 0x6E where starts("null"): i += 4; return .null
        case 0x74 where starts("true"): i += 4; return .bool(true)
        case 0x66 where starts("false"): i += 5; return .bool(false)
        case 0x4E where starts("NaN"): i += 3; return .float(.nan)
        case 0x49 where starts("Infinity"): i += 8; return .float(.infinity)
        case 0x2D where starts("-Infinity"): i += 9; return .float(-.infinity)
        default: return try number()
        }
    }

    mutating func number() throws -> SettingsApplyValue {
        let start = i
        if i < s.count, s[i] == 0x2D { i += 1 }
        guard i < s.count, isDigit(s[i]) else { throw Bad() }
        if s[i] == 0x30 { i += 1 } else { while i < s.count, isDigit(s[i]) { i += 1 } }
        var isFloat = false
        if i + 1 < s.count, s[i] == 0x2E, isDigit(s[i + 1]) {
            isFloat = true; i += 1
            while i < s.count, isDigit(s[i]) { i += 1 }
        }
        if i < s.count, s[i] == 0x65 || s[i] == 0x45 {
            var j = i + 1
            if j < s.count, s[j] == 0x2B || s[j] == 0x2D { j += 1 }
            if j < s.count, isDigit(s[j]) {
                isFloat = true
                while j < s.count, isDigit(s[j]) { j += 1 }
                i = j
            }
        }
        let literal = String(String.UnicodeScalarView(s[start..<i].map { Unicode.Scalar($0)! }))
        if isFloat { return .float(strtod(literal, nil)) }
        if let n = Int(literal) { return .int(n) }
        return .bigInt(negative: literal.hasPrefix("-"))
    }

    mutating func string() throws -> SettingsApplyText {
        i += 1
        var out: SettingsApplyText = []
        func hex4(_ at: Int) -> UInt32? {
            guard at + 4 <= s.count else { return nil }
            var v: UInt32 = 0
            for k in 0..<4 {
                let c = s[at + k]
                let d: UInt32
                switch c {
                case 0x30...0x39: d = c - 0x30
                case 0x41...0x46: d = c - 0x41 + 10
                case 0x61...0x66: d = c - 0x61 + 10
                default: return nil
                }
                v = v * 16 + d
            }
            return v
        }
        while true {
            guard i < s.count else { throw Bad() }
            let c = s[i]
            if c == 0x22 { i += 1; return out }
            if c < 0x20 { throw Bad() }
            if c != 0x5C { out.append(c); i += 1; continue }
            i += 1
            guard i < s.count else { throw Bad() }
            let e = s[i]
            switch e {
            case 0x22, 0x5C, 0x2F: out.append(e); i += 1
            case 0x62: out.append(8); i += 1
            case 0x66: out.append(12); i += 1
            case 0x6E: out.append(10); i += 1
            case 0x72: out.append(13); i += 1
            case 0x74: out.append(9); i += 1
            case 0x75:
                guard var u = hex4(i + 1) else { throw Bad() }
                i += 5
                if u >= 0xD800 && u <= 0xDBFF, i + 1 < s.count, s[i] == 0x5C, s[i + 1] == 0x75, let low = hex4(i + 2), low >= 0xDC00 && low <= 0xDFFF {
                    u = 0x10000 + ((u - 0xD800) << 10) + (low - 0xDC00)
                    i += 6
                }
                out.append(u)
            default: throw Bad()
            }
        }
    }

    mutating func array(depth: Int) throws -> SettingsApplyValue {
        if depth > Self.maxDepth { throw Bad() }
        i += 1; skip()
        var items: [SettingsApplyValue] = []
        if i < s.count, s[i] == 0x5D { i += 1; return .list(items) }
        while true {
            skip(); items.append(try value(depth: depth)); skip()
            guard i < s.count else { throw Bad() }
            if s[i] == 0x2C { i += 1; continue }
            if s[i] == 0x5D { i += 1; return .list(items) }
            throw Bad()
        }
    }

    mutating func object(depth: Int) throws -> SettingsApplyValue {
        if depth > Self.maxDepth { throw Bad() }
        i += 1; skip()
        var d = SettingsApplyDict()
        if i < s.count, s[i] == 0x7D { i += 1; return .dict(d) }
        while true {
            skip()
            guard i < s.count, s[i] == 0x22 else { throw Bad() }
            let key = try string()
            skip()
            guard i < s.count, s[i] == 0x3A else { throw Bad() }
            i += 1; skip()
            d[key] = try value(depth: depth)
            skip()
            guard i < s.count else { throw Bad() }
            if s[i] == 0x2C { i += 1; continue }
            if s[i] == 0x7D { i += 1; return .dict(d) }
            throw Bad()
        }
    }
}

// MARK: - JSON writer (json.dumps)

private enum SettingsApplyJSONWriter {
    struct Unencodable: Error {}

    /// `json.dumps(value, ensure_ascii:, indent:)`, as UTF-8 bytes. With ensure_ascii off a lone surrogate
    /// cannot be written (the script's file write fails there), so it throws.
    static func dumps(_ v: SettingsApplyValue, indent: Int?, ensureASCII: Bool) throws -> [UInt8] {
        var out: [UInt8] = []
        try write(v, level: 0, indent: indent, ascii: ensureASCII, into: &out)
        return out
    }
    private static func put(_ s: String, _ out: inout [UInt8]) { out.append(contentsOf: Array(s.utf8)) }
    private static func newline(_ level: Int, _ indent: Int?, _ out: inout [UInt8]) {
        guard let indent else { return }
        out.append(0x0A); out.append(contentsOf: [UInt8](repeating: 0x20, count: indent * level))
    }
    private static func write(_ v: SettingsApplyValue, level: Int, indent: Int?, ascii: Bool, into out: inout [UInt8]) throws {
        switch v {
        case .null: put("null", &out)
        case .bool(let b): put(b ? "true" : "false", &out)
        case .int(let n): put(String(n), &out)
        case .bigInt: throw Unencodable()
        case .float(let d):
            put(d.isNaN ? "NaN" : d.isInfinite ? (d < 0 ? "-Infinity" : "Infinity") : Py.floatRepr(d), &out)
        case .string(let t): try writeString(t, ascii: ascii, into: &out)
        case .list(let items):
            if items.isEmpty { put("[]", &out); return }
            out.append(0x5B)
            for (n, item) in items.enumerated() {
                if n > 0 { out.append(0x2C); if indent == nil { out.append(0x20) } }
                newline(level + 1, indent, &out)
                try write(item, level: level + 1, indent: indent, ascii: ascii, into: &out)
            }
            newline(level, indent, &out)
            out.append(0x5D)
        case .dict(let d):
            if d.count == 0 { put("{}", &out); return }
            out.append(0x7B)
            for (n, item) in d.items.enumerated() {
                if n > 0 { out.append(0x2C); if indent == nil { out.append(0x20) } }
                newline(level + 1, indent, &out)
                try writeString(item.key, ascii: ascii, into: &out)
                put(": ", &out)
                try write(item.value, level: level + 1, indent: indent, ascii: ascii, into: &out)
            }
            newline(level, indent, &out)
            out.append(0x7D)
        }
    }
    private static func hex(_ n: UInt32) -> String {
        let h = String(n, radix: 16)
        return "\\u" + String(repeating: "0", count: 4 - h.count) + h
    }
    private static func writeString(_ t: SettingsApplyText, ascii: Bool, into out: inout [UInt8]) throws {
        out.append(0x22)
        for c in t {
            switch c {
            case 0x22: put("\\\"", &out)
            case 0x5C: put("\\\\", &out)
            case 0x0A: put("\\n", &out)
            case 0x0D: put("\\r", &out)
            case 0x09: put("\\t", &out)
            case 0x08: put("\\b", &out)
            case 0x0C: put("\\f", &out)
            case 0..<0x20: put(hex(c), &out)
            case 0x20...0x7E: out.append(UInt8(c))
            default:
                if ascii {
                    if c > 0xFFFF { let n = c - 0x10000; put(hex(0xD800 + (n >> 10)) + hex(0xDC00 + (n & 0x3FF)), &out) } else { put(hex(c), &out) }
                } else {
                    guard let u = Unicode.Scalar(c) else { throw Unencodable() }
                    out.append(contentsOf: Array(String(Character(u)).utf8))
                }
            }
        }
        out.append(0x22)
    }
}

// MARK: - Catalog and defaults

private struct SettingsApplyCatalog {
    struct Entry { var id: SettingsApplyText; var label: String; var chord: SettingsApplyText; var command: SettingsApplyText }
    var entries: [Entry]
    var defaults = SettingsApplyDict()
    var labels: [SettingsApplyText: String] = [:]

    init(_ data: Data) throws {
        guard let text = SettingsApplyIO.decode(data), case .list(let list) = try SettingsApplyJSONReader.parse(SettingsApplyIO.universalNewlines(text)) else { throw SettingsApplyFailure.generic("shortcut catalog unreadable") }
        let strip = try? NSRegularExpression(pattern: "\\s*\\([^)]*\\)")
        entries = []
        for item in list {
            guard let d = item.dictionary, let id = d["id"]?.text, let label = d["label"]?.text, let chord = d["default"]?.text, let command = d["command"]?.text else { throw SettingsApplyFailure.generic("shortcut catalog entry incomplete") }
            let plain = Py.string(label)
            let cleaned = strip?.stringByReplacingMatches(in: plain, range: NSRange(plain.startIndex..., in: plain), withTemplate: "") ?? plain
            entries.append(Entry(id: id, label: cleaned, chord: chord, command: command))
            defaults[id] = .string(chord)
            labels[id] = cleaned
        }
    }
    func label(_ id: SettingsApplyText) -> String { "“" + (labels[id] ?? "a shortcut") + "”" }
}

private enum SettingsApplyRules {
    static let defaultKeys = ["dragReorder", "focusFollowsMouse", "mouseFollowsFocus", "autoCenter", "sliverWidth", "padding", "windowGap",
        "swipeSensitivity", "swipeDeceleration", "swipeFingers", "reverseSwipe", "scrollModifier", "borderColor", "borderWidth", "borderRadius",
        "minimapPosition", "minimapStyle", "minimapDelay", "minimapFade", "showOnHyper", "hyperHoldDelay", "floatPip", "tabStyle", "tabHeight",
        "tabMatchAppColor", "floatingRules", "tabAliases", "rowsEnabled", "rowCount", "shortcuts"]
    static func defaults(_ catalog: SettingsApplyCatalog) -> SettingsApplyDict {
        SettingsApplyDict([
            ("dragReorder", .bool(false)), ("focusFollowsMouse", .bool(false)), ("mouseFollowsFocus", .bool(false)), ("autoCenter", .bool(false)),
            ("sliverWidth", .int(20)), ("padding", .int(4)), ("windowGap", .int(4)), ("swipeSensitivity", .float(0.35)), ("swipeDeceleration", .float(6.0)),
            ("swipeFingers", .int(3)), ("reverseSwipe", .bool(false)), ("scrollModifier", .s("hyper")), ("borderColor", .s("#009193")), ("borderWidth", .float(2.0)),
            ("borderRadius", .float(14.0)), ("minimapPosition", .s("bottom")), ("minimapStyle", .s("cards")), ("minimapDelay", .float(1.3)),
            ("minimapFade", .float(0.22)), ("showOnHyper", .bool(true)), ("hyperHoldDelay", .float(0.2)), ("floatPip", .bool(true)),
            ("tabStyle", .s("folder")), ("tabHeight", .int(34)), ("tabMatchAppColor", .bool(false)),
            ("floatingRules", .list([])), ("tabAliases", .dict(SettingsApplyDict())), ("rowsEnabled", .bool(false)), ("rowCount", .int(2)),
            ("shortcuts", .dict(catalog.defaults))])
    }
    static let ranges: [(key: String, lo: String, hi: String)] = [
        ("rowCount", "2", "9"), ("sliverWidth", "0", "200"), ("padding", "0", "100"), ("windowGap", "0", "100"), ("swipeSensitivity", "0.1", "2"),
        ("swipeDeceleration", "1", "10"), ("swipeFingers", "3", "4"), ("borderWidth", "0", "12"), ("borderRadius", "0", "60"),
        ("minimapDelay", "0.1", "10"), ("minimapFade", "0", "3"), ("hyperHoldDelay", "0.05", "2")]
    static let bools = ["dragReorder", "focusFollowsMouse", "mouseFollowsFocus", "autoCenter", "reverseSwipe", "showOnHyper", "floatPip", "rowsEnabled", "tabMatchAppColor"]
    static let wholeNumbers = ["sliverWidth", "padding", "windowGap", "swipeFingers", "rowCount"]
    static let enums: [(key: String, values: [String])] = [
        ("tabStyle", ["folder", "folder-compact", "classic", "side"]), ("minimapPosition", ["bottom", "top", "center", "left", "right"]),
        ("minimapStyle", ["cards", "compact", "titles"]), ("scrollModifier", ["hyper", "controlOption"])]
    static let optionalEnums: [(key: String, values: [String])] = [("minimapHide", ["release", "timer"])]
    static let names: [String: String] = [
        "rowCount": "Number of rows", "sliverWidth": "Edge sliver", "padding": "Outer padding", "windowGap": "Window padding",
        "swipeSensitivity": "Swipe sensitivity", "swipeDeceleration": "Swipe deceleration", "swipeFingers": "Swipe fingers",
        "borderWidth": "Outline width", "borderRadius": "Corner radius", "minimapDelay": "Hide after", "minimapFade": "Fade out",
        "hyperHoldDelay": "Hold Hyper for", "dragReorder": "Drag to reorder", "focusFollowsMouse": "Focus follows pointer",
        "mouseFollowsFocus": "Move pointer to focused window", "autoCenter": "Auto-center", "reverseSwipe": "Reverse swipe",
        "showOnHyper": "Show Minimap with Hyper", "floatPip": "Float Picture in Picture", "rowsEnabled": "Rows",
        "tabMatchAppColor": "Match app color", "tabStyle": "Tab style", "minimapPosition": "Minimap position",
        "minimapStyle": "Minimap layout", "scrollModifier": "Scroll modifier", "minimapHide": "Hide Minimap"]
    static func name(_ key: String) -> String { names[key] ?? "That setting" }
    static let pipPattern = "(?i)^(picture[ -]in[ -]picture|pip)$"
    static let chordKeys: Set<SettingsApplyText> = {
        var keys = Set<String>()
        for c in "abcdefghijklmnopqrstuvwxyz0123456789" { keys.insert(String(c)) }
        for k in "leftarrow rightarrow uparrow downarrow leftbracket rightbracket backslash equal minus space return tab escape delete forwarddelete home end pageup pagedown semicolon quote comma period slash grave".split(separator: " ") { keys.insert(String(k)) }
        for i in 1...20 { keys.insert("f\(i)") }
        return Set(keys.map { T($0) })
    }()
}

// MARK: - Validation (normalize)

private enum SettingsApplyValidation {
    typealias R = SettingsApplyRules
    static func fail(_ text: String) -> SettingsApplyFailure { .message(text) }

    static func normalize(_ raw: SettingsApplyValue, _ catalog: SettingsApplyCatalog) throws -> SettingsApplyDict {
        guard case .dict(let rawDict) = raw else { throw fail("Microfish couldn’t read these settings, so nothing was changed.") }
        let known = Set(R.defaultKeys.map { T($0) } + R.optionalEnums.map { T($0.key) })
        if rawDict.keys.contains(where: { !known.contains($0) }) { throw fail("These settings include options this version of Microfish doesn’t know, so nothing was changed.") }
        var out = R.defaults(catalog)
        for (k, v) in rawDict.items { out[k] = v }

        // Tab height: str(value) must be '28' or '34' (so 28, 34, "28" and "34" pass; 28.0 and True do not).
        let height: Int?
        switch out["tabHeight"]! {
        case .int(let n) where n == 28 || n == 34: height = n
        case .string(let t) where t == T("28"): height = 28
        case .string(let t) where t == T("34"): height = 34
        default: height = nil
        }
        guard let height else { throw fail("Tab height must be 28 or 34 points.") }
        out["tabHeight"] = .int(height)

        for key in R.bools {
            guard case .bool = out[key]! else { throw fail(R.name(key) + " must be on or off.") }
        }
        for (key, lo, hi) in R.ranges {
            let v = out[key]!
            var ok = false
            switch v {
            case .int(let n): ok = Double(n) >= Double(lo)! && Double(n) <= Double(hi)!
            case .float(let d): ok = d.isFinite && d >= Double(lo)! && d <= Double(hi)!
            default: ok = false
            }
            if !ok { throw fail("\(R.name(key)) must be a number from \(lo) to \(hi).") }
        }
        for key in R.wholeNumbers {
            switch out[key]! {
            case .int: break
            case .float(let d):
                if d != d.rounded(.towardZero) { throw fail(R.name(key) + " must be a whole number.") }
                out[key] = .int(Int(d))
            default: break
            }
        }
        for (key, values) in R.enums where !values.contains(where: { out[key]!.text == T($0) }) {
            throw fail(R.name(key) + " has a value Microfish doesn’t support.")
        }
        for (key, values) in R.optionalEnums {
            if let v = out[key], !values.contains(where: { v.text == T($0) }) { throw fail(R.name(key) + " has a value Microfish doesn’t support.") }
        }
        guard let color = out["borderColor"]!.text, isHexColor(color) else { throw fail("Outline color needs six hex digits, like #009193.") }

        guard case .list(let rawRules) = out["floatingRules"]!, rawRules.count <= 200 else { throw fail("Microfish supports at most 200 floating rules.") }
        var rules: [SettingsApplyValue] = []
        let invalidRule = "One of the floating rules isn’t valid."
        for rule in rawRules {
            guard let r = rule.dictionary else { throw fail(invalidRule) }
            let id = r["id"] ?? .s(""), bundle = r["bundle"] ?? .s(""), pattern = r["titlePattern"] ?? .s(""), enabled = r["enabled"] ?? .bool(true)
            for v in [id, bundle, pattern] {
                guard let t = v.text, t.count <= 4096 else { throw fail(invalidRule) }
            }
            guard case .bool = enabled else { throw fail(invalidRule) }
            if pattern.text!.isEmpty { throw fail("A floating rule needs a title pattern. Use .* to match every title.") }
            rules.append(.dict(SettingsApplyDict([("id", id), ("bundle", bundle), ("titlePattern", pattern), ("enabled", enabled)])))
        }
        out["floatingRules"] = .list(rules)

        guard case .dict(let aliases) = out["tabAliases"]!, aliases.count <= 500 else { throw fail("Microfish supports at most 500 tab names.") }
        for (k, v) in aliases.items {
            guard let name = v.text, k.count <= 8192, name.count <= 200, !name.contains(where: { $0 == 0x0D || $0 == 0x0A || $0 == 0x09 }) else {
                throw fail("Tab names must be one line and at most 200 characters.")
            }
        }

        guard case .dict(let shortcuts) = out["shortcuts"]!, !shortcuts.keys.contains(where: { catalog.defaults[$0] == nil }) else {
            throw fail("A shortcut in these settings isn’t one Microfish knows, so nothing was changed.")
        }
        var merged = catalog.defaults
        for (k, v) in shortcuts.items { merged[k] = v }
        var seen: [SettingsApplyText: SettingsApplyText] = [:]
        for (action, value) in merged.items {
            let chord = try normalizeChord(value)
            merged[action] = .string(chord)
            if !chord.isEmpty {
                if let first = seen[chord] { throw fail("Two shortcuts conflict: " + catalog.label(first) + " and " + catalog.label(action) + " use the same keys. Choose different keys.") }
                seen[chord] = action
            }
        }
        out["shortcuts"] = .dict(merged)
        return out
    }

    static func isHexColor(_ t: SettingsApplyText) -> Bool {
        guard t.count == 7, t[0] == 0x23 else { return false }
        return t[1...].allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x46) || ($0 >= 0x61 && $0 <= 0x66) }
    }

    static func normalizeChord(_ value: SettingsApplyValue) throws -> SettingsApplyText {
        guard let chord = value.text else { throw fail("A shortcut isn’t valid, so nothing was changed.") }
        if Py.strip(chord).isEmpty { return [] }
        let parts = Py.split(Py.strip(Py.lower(chord)), on: T(" - "))
        guard parts.count == 2 else { throw fail("A shortcut needs at least one modifier key and one other key.") }
        let mods = Py.split(parts[0], on: T("+")).map { Py.strip($0) }
        let key = Py.strip(parts[1])
        let allowed = ["ctrl", "alt", "cmd", "shift"].map { T($0) }
        let modSet = Set(mods)
        if modSet.count != mods.count || !modSet.allSatisfy({ allowed.contains($0) }) || !(modSet.contains(T("ctrl")) || modSet.contains(T("alt")) || modSet.contains(T("cmd"))) || !R.chordKeys.contains(key) {
            throw fail("A shortcut uses keys Microfish can’t use. Choose different keys.")
        }
        var out: SettingsApplyText = []
        for m in ["ctrl", "alt", "cmd", "shift"] where modSet.contains(T(m)) {
            if !out.isEmpty { out += T(" + ") }
            out += T(m)
        }
        return out + T(" - ") + key
    }

    // MARK: Derived settings (settings.lua, shortcuts.lua, float rules)

    static func effectiveRules(_ p: SettingsApplyDict) -> [SettingsApplyDict] {
        guard case .list(let all) = p["floatingRules"]! else { return [] }
        var rules = all.compactMap { $0.dictionary }.filter { if case .bool(true) = $0["enabled"]! { return true }; return false }
        if case .bool(true) = p["floatPip"]! {
            rules.insert(SettingsApplyDict([("id", .s("automatic-pip")), ("bundle", .s("")), ("titlePattern", .s(R.pipPattern)), ("enabled", .bool(true))]), at: 0)
        }
        return rules
    }

    static func setup(_ p: SettingsApplyDict) -> SettingsApplyValue {
        func D(_ pairs: [(String, SettingsApplyValue)]) -> SettingsApplyValue { .dict(SettingsApplyDict(pairs)) }
        let gap = p["windowGap"]!
        var windows = SettingsApplyDict([("spacing", D([("title", .s(".*")), ("horizontal_padding", gap), ("vertical_padding", gap)])),
                                         ("settings_panel", D([("title", .s("^Paneru Settings$")), ("floating", .bool(true))]))])
        for (i, r) in effectiveRules(p).enumerated() {
            var entry = SettingsApplyDict([("title", r["titlePattern"]!), ("floating", .bool(true))])
            if !r["bundle"]!.text!.isEmpty { entry["bundle_id"] = r["bundle"]! }
            windows["float_" + String(format: "%03d", i)] = .dict(entry)
        }
        let width = p["borderWidth"]!
        let positive = (width.comparable ?? 0) > 0
        let hyper = p["scrollModifier"]!.text == T("hyper")
        let reversed: Bool = { if case .bool(true) = p["reverseSwipe"]! { return true }; return false }()
        let pad = p["padding"]!
        return D([
            ("default_workspaces", .int(1)),
            ("options", D([("drag_reorder", p["dragReorder"]!), ("create_virtual_workspace_automatically", .bool(false)), ("reap_empty_workspaces", .bool(true)),
                           ("focus_follows_mouse", p["focusFollowsMouse"]!), ("mouse_follows_focus", p["mouseFollowsFocus"]!),
                           ("preset_column_widths", .list([.float(0.33), .float(0.5), .float(0.66), .float(1.0)])), ("animation_speed", .float(1000000.0)),
                           ("sliver_width", p["sliverWidth"]!), ("auto_center", p["autoCenter"]!), ("disable_native_tabs", .bool(false)),
                           ("tab_style", p["tabStyle"]!), ("tab_height", p["tabHeight"]!)])),
            ("padding", D([("left", pad), ("right", pad), ("top", pad), ("bottom", pad)])),
            ("swipe", D([("continuous", .bool(false)), ("sensitivity", p["swipeSensitivity"]!), ("deceleration", p["swipeDeceleration"]!),
                         ("gesture", D([("fingers_count", p["swipeFingers"]!), ("direction", .s(reversed ? "Reversed" : "Natural")), ("vertical", .bool(false))])),
                         ("scroll", D([("modifier", .s(hyper ? "ctrl + alt + cmd" : "ctrl + alt")), ("window_step", .bool(false))]))])),
            ("decorations", D([("workspace_popup_status", .bool(false)), ("workspace_menu_status", .bool(false)),
                               ("menu", D([("descriptor", D([("style", .s("hidden"))]))])),
                               ("active", D([("border", D([("enabled", .bool(positive)), ("color", p["borderColor"]!), ("width", width), ("radius", p["borderRadius"]!)]))]))])),
            ("restore", D([("enabled", .bool(true))])),
            ("windows", .dict(windows))])
    }

    static func shortcutSetup(_ p: SettingsApplyDict, _ catalog: SettingsApplyCatalog) -> SettingsApplyValue {
        guard case .dict(let chords) = p["shortcuts"]! else { return .null }
        let bindings = catalog.entries.map { e in
            SettingsApplyValue.dict(SettingsApplyDict([("id", .string(e.id)), ("chord", chords[e.id] ?? .null), ("command", .string(e.command))]))
        }
        return .dict(SettingsApplyDict([("rows_enabled", p["rowsEnabled"]!), ("row_count", p["rowCount"]!), ("bindings", .list(bindings))]))
    }

    /// The script's `lua()`: decimal byte escapes for everything that is not plain printable ASCII.
    static func lua(_ v: SettingsApplyValue) throws -> String {
        switch v {
        case .bool(let b): return b ? "true" : "false"
        case .int(let n): return String(n)
        case .float(let d): return Py.floatRepr(d)
        case .string(let t):
            guard let bytes = Py.utf8(t) else { throw SettingsApplyFailure.generic("string with a lone surrogate cannot be written") }
            var s = "\""
            for b in bytes {
                if b >= 32 && b < 127 && b != 34 && b != 92 { s.unicodeScalars.append(Unicode.Scalar(b)) } else { s += "\\" + String(format: "%03d", Int(b)) }
            }
            return s + "\""
        case .list(let items): return "{" + (try items.map { try lua($0) }).joined(separator: ",") + "}"
        case .dict(let d): return "{" + (try d.items.map { "[" + (try lua(.string($0.key))) + "]=" + (try lua($0.value)) }).joined(separator: ",") + "}"
        default: throw SettingsApplyFailure.message(genericText)
        }
    }
}

// MARK: - File and process helpers

private enum SettingsApplyIO {
    static func decode(_ data: Data) -> String? {
        let s = String(decoding: data, as: UTF8.self)
        return Data(s.utf8) == data ? s : nil
    }
    /// Text-mode reading: \r\n and lone \r become \n.
    static func universalNewlines(_ s: String) -> SettingsApplyText {
        var out: SettingsApplyText = []
        var previousReturn = false
        for u in s.unicodeScalars {
            if u.value == 0x0D { out.append(0x0A); previousReturn = true; continue }
            if u.value == 0x0A, previousReturn { previousReturn = false; continue }
            previousReturn = false
            out.append(u.value)
        }
        return out
    }
    static func readText(_ url: URL) throws -> SettingsApplyText {
        guard let data = try? Data(contentsOf: url) else { throw SettingsApplyFailure.generic("cannot read \(url.lastPathComponent)") }
        guard let text = decode(data) else { throw SettingsApplyFailure.generic("\(url.lastPathComponent) is not UTF-8") }
        return universalNewlines(text)
    }
    static func nowNanoseconds() -> UInt64 {
        var ts = timespec()
        clock_gettime(CLOCK_REALTIME, &ts)
        return UInt64(ts.tv_sec) * 1_000_000_000 + UInt64(ts.tv_nsec)
    }

    /// mkstemp beside the target, fsync, rename over it (the same recipe, so the file ends up 0600 too).
    static func atomicWrite(_ url: URL, _ bytes: [UInt8]) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var template = Array((dir.appendingPathComponent("." + url.lastPathComponent + "XXXXXX")).path.utf8CString)
        let fd = mkstemp(&template)
        guard fd >= 0 else { throw SettingsApplyFailure.generic("mkstemp failed: errno \(errno)") }
        let temp = String(decoding: template.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        var renamed = false
        defer { if !renamed { unlink(temp) } }
        var offset = 0
        while offset < bytes.count {
            let n = bytes[offset...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if n < 0 { close(fd); throw SettingsApplyFailure.generic("write failed: errno \(errno)") }
            offset += n
        }
        fsync(fd)
        close(fd)
        guard rename(temp, url.path) == 0 else { throw SettingsApplyFailure.generic("rename failed: errno \(errno)") }
        renamed = true
    }

    final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Data()
        func set(_ d: Data) { lock.lock(); value = d; lock.unlock() }
        func get() -> Data { lock.lock(); defer { lock.unlock() }; return value }
    }
    struct Child { var status: Int32; var stdout: Data; var stderr: Data }
    enum ChildError: Error { case timeout, launch(String) }

    /// subprocess.run(capture_output, timeout): a child that overstays is killed (it is our own process).
    static func run(_ executable: URL, _ arguments: [String], environment: [String: String], timeout: TimeInterval) throws -> Child {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        let out = Pipe(), err = Pipe()
        process.standardOutput = out; process.standardError = err; process.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { throw ChildError.launch(String(describing: error)) }
        let outBox = Box(), errBox = Box(), drained = DispatchGroup()
        for (pipe, box) in [(out, outBox), (err, errBox)] {
            drained.enter()
            DispatchQueue.global(qos: .userInitiated).async { box.set(pipe.fileHandleForReading.readDataToEndOfFile()); drained.leave() }
        }
        let timedOut = exited.wait(timeout: .now() + timeout) == .timedOut
        if timedOut { kill(process.processIdentifier, SIGKILL); exited.wait() }
        _ = drained.wait(timeout: .now() + (timedOut ? 1 : 30))
        if timedOut { throw ChildError.timeout }
        return Child(status: process.terminationStatus, stdout: outBox.get(), stderr: errBox.get())
    }
}

// MARK: - Apply

enum SettingsApply {
    /// Python's `repr(float)`. Exposed for the tests, which compare it with Python over many doubles.
    static func pythonFloatRepr(_ d: Double) -> String { Py.floatRepr(d) }

    /// Applies the draft file at `draft`. Blocking (flock, bridge calls of up to 10 s): call it off the
    /// main thread. Never throws; failures come back as a non-zero status and one plain sentence.
    static func run(draft: URL, locations: SettingsApplyLocations = .current) -> SettingsApplyResult {
        var lockFD: Int32 = -1
        defer { if lockFD >= 0 { close(lockFD) } }
        do {
            // The lock serialises two Applies; it is held until this function returns.
            do {
                try FileManager.default.createDirectory(at: locations.runtime, withIntermediateDirectories: true)
                lockFD = open(locations.runtime.appendingPathComponent("settings.lock").path, O_WRONLY | O_CREAT | O_TRUNC, 0o666)
                guard lockFD >= 0, flock(lockFD, LOCK_EX) == 0 else { throw SettingsApplyFailure.generic("cannot take settings.lock: errno \(errno)") }
            }
            let note = try apply(draft, locations)
            return SettingsApplyResult(status: 0, stdout: note + "\n", stderr: "")
        } catch SettingsApplyFailure.message(let text) {
            return SettingsApplyResult(status: 1, stdout: "", stderr: text + "\n")
        } catch SettingsApplyFailure.timeout(let detail) {
            log(locations, "timeout: " + detail)
            return SettingsApplyResult(status: 1, stdout: "", stderr: timeoutText + "\n")
        } catch SettingsApplyFailure.generic(let detail) {
            log(locations, detail)
            return SettingsApplyResult(status: 1, stdout: "", stderr: genericText + "\n")
        } catch {
            log(locations, "unexpected: \(error)")
            return SettingsApplyResult(status: 1, stdout: "", stderr: genericText + "\n")
        }
    }

    private static func log(_ l: SettingsApplyLocations, _ text: String) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd HH:mm:ss "
        let line = formatter.string(from: Date()) + text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        try? FileManager.default.createDirectory(at: l.log.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let handle = FileHandle(forWritingAtPath: l.log.path) ?? (FileManager.default.createFile(atPath: l.log.path, contents: nil) ? FileHandle(forWritingAtPath: l.log.path) : nil) else { return }
        _ = try? handle.seekToEnd(); try? handle.write(contentsOf: Data(line.utf8)); try? handle.close()
    }

    private static func parse(_ text: SettingsApplyText, what: String) throws -> SettingsApplyValue {
        do { return try SettingsApplyJSONReader.parse(text) } catch { throw SettingsApplyFailure.generic("unreadable JSON: " + what) }
    }

    /// Rows can only shrink while the windows in the removed rows are floating or gone; the engine says which.
    private static func validateRowReduction(_ p: SettingsApplyDict, _ l: SettingsApplyLocations) throws {
        guard FileManager.default.fileExists(atPath: l.preferences.path) else { return }
        let old = try parse(try SettingsApplyIO.readText(l.preferences), what: "preferences.json")
        guard let oldDict = old.dictionary else { throw SettingsApplyFailure.generic("unexpected: preferences.json is not an object") }
        let oldLimit: SettingsApplyValue = oldDict["rowsEnabled"] ?? .bool(false)
        let limitValue: SettingsApplyValue = oldLimit.truthy ? (oldDict["rowCount"] ?? .int(2)) : .int(1)
        var newLimit = 1
        if case .bool(true) = p["rowsEnabled"]!, case .int(let n) = p["rowCount"]! { newLimit = n }
        guard let previous = limitValue.comparable else { throw SettingsApplyFailure.generic("unexpected: old row count is not a number") }
        if Double(newLimit) >= previous { return }

        let notResponding = SettingsApplyFailure.message("Microfish isn’t responding, so rows can’t be reduced yet. Open Microfish and try again.")
        let result: SettingsApplyIO.Child
        do { result = try SettingsApplyIO.run(l.engine, ["query", "state", "--json"], environment: l.childEnvironment, timeout: 5) } catch {
            log(l, "row check: \(error)"); throw notResponding
        }
        guard let stdout = SettingsApplyIO.decode(result.stdout), let stderr = SettingsApplyIO.decode(result.stderr) else { throw SettingsApplyFailure.generic("engine answered in a non-UTF-8 encoding") }
        if result.status != 0 {
            log(l, "row check: " + (stderr.isEmpty ? stdout : stderr))
            throw notResponding
        }
        let state = try parse(SettingsApplyIO.universalNewlines(stdout), what: "engine state")
        func bad(_ why: String) -> SettingsApplyFailure { .generic("unexpected: engine state " + why) }
        guard let stateDict = state.dictionary, let active = stateDict["active"], let activeDict = active.dictionary else { throw bad("has no active section") }
        guard let current = (activeDict["virtual_workspace_number"] ?? .int(1)).comparable else { throw bad("row number is not a number") }
        if current > Double(newLimit) { throw SettingsApplyFailure.message("Switch to a row that will remain before reducing rows.") }
        guard let rowsValue = stateDict["virtual_workspaces"] else { throw bad("has no rows") }
        let rows: [SettingsApplyValue]
        switch rowsValue {
        case .list(let l): rows = l
        case .dict(let d) where d.count == 0: rows = []
        case .string(let t) where t.isEmpty: rows = []
        default: throw bad("rows are not a list")
        }
        for row in rows {
            guard let r = row.dictionary, let number = r["number"]?.comparable else { throw bad("row without a number") }
            guard number > Double(newLimit) else { continue }
            let windows: [SettingsApplyValue]
            switch r["windows"] ?? .null {
            case .list(let l): windows = l
            case .dict(let d) where d.count == 0: windows = []
            case .string(let t) where t.isEmpty: windows = []
            default: throw bad("row without windows")
            }
            for w in windows {
                guard let wd = w.dictionary else { throw bad("window is not an object") }
                if !(wd["floating"] ?? .bool(false)).truthy {
                    throw SettingsApplyFailure.message("Move windows out of rows \(newLimit + 1) and above before reducing rows.")
                }
            }
        }
    }

    private static func apply(_ draft: URL, _ l: SettingsApplyLocations) throws -> String {
        let catalog = try SettingsApplyCatalog(Data(contentsOf: l.catalog))
        let prefs = try SettingsApplyValidation.normalize(try parse(try SettingsApplyIO.readText(draft), what: "draft"), catalog)
        try validateRowReduction(prefs, l)

        let fm = FileManager.default
        try fm.createDirectory(at: l.runtime, withIntermediateDirectories: true)
        var template = Array(l.runtime.appendingPathComponent("settings-XXXXXX").path.utf8CString)
        guard mkdtemp(&template) != nil else { throw SettingsApplyFailure.generic("cannot make a scratch folder: errno \(errno)") }
        let scratch = URL(fileURLWithPath: String(decoding: template.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self), isDirectory: true)
        defer { try? fm.removeItem(at: scratch) }

        let rulesURL = scratch.appendingPathComponent("rules.json")
        let rules = SettingsApplyValue.list(SettingsApplyValidation.effectiveRules(prefs).map { r in
            .dict(SettingsApplyDict([("bundle", r["bundle"]!), ("titlePattern", r["titlePattern"]!), ("enabled", r["enabled"]!)]))
        })
        try Data(try SettingsApplyJSONWriter.dumps(rules, indent: nil, ensureASCII: true)).write(to: rulesURL)

        func bridge(_ verb: String) throws -> SettingsApplyIO.Child {
            do { return try SettingsApplyIO.run(l.bridge, [verb, rulesURL.path], environment: l.childEnvironment, timeout: 10) }
            catch SettingsApplyIO.ChildError.timeout { throw SettingsApplyFailure.timeout(verb) }
            catch { throw SettingsApplyFailure.generic("unexpected: \(verb) could not run: \(error)") }
        }
        func text(_ data: Data) throws -> String {
            guard let s = SettingsApplyIO.decode(data) else { throw SettingsApplyFailure.generic("bridge answered in a non-UTF-8 encoding") }
            return String(Py.string(SettingsApplyIO.universalNewlines(s)))
        }

        let checked = try bridge("validate-rules")
        if checked.status != 0 {
            let err = try text(checked.stderr), outText = try text(checked.stdout)
            let said = Py.strip(T(err)).isEmpty ? Py.strip(T(outText)) : Py.strip(T(err))
            let detail = Py.splitLines(said)
            log(l, "validate-rules: " + detail.map { Py.string($0) }.joined(separator: " / "))
            // The bridge's words are shown only when it said one short plain line (it names the bad rule).
            let first = detail.count == 1 ? Py.strip(detail[0]) : []
            let plain = Py.string(first)
            let hasPathOrAddress = plain.range(of: "[/\\\\]|0x|\\bat \\w", options: .regularExpression) != nil
            if !first.isEmpty, first.count <= 80, first.last != 0x3A, !hasPathOrAddress { throw SettingsApplyFailure.message("A floating rule isn’t valid: " + plain) }
            throw SettingsApplyFailure.message("A floating rule isn’t valid, so nothing was saved.")
        }

        // Backup first: whatever the next writes do, the previous files are kept.
        let backup = l.backups.appendingPathComponent(String(SettingsApplyIO.nowNanoseconds()), isDirectory: true)
        try fm.createDirectory(at: l.backups, withIntermediateDirectories: true)
        try fm.createDirectory(at: backup, withIntermediateDirectories: false)
        for file in [l.preferences, l.settingsLua, l.shortcutsLua, l.initLua] where fm.fileExists(atPath: file.path) {
            guard let data = try? Data(contentsOf: file) else { throw SettingsApplyFailure.generic("cannot back up \(file.lastPathComponent)") }
            try data.write(to: backup.appendingPathComponent(file.lastPathComponent))
        }

        func lines(_ s: String) throws -> [UInt8] { Array(s.utf8) }
        try SettingsApplyIO.atomicWrite(l.settingsLua, try lines("-- Generated by the settings panel.\nreturn " + SettingsApplyValidation.lua(SettingsApplyValidation.setup(prefs)) + "\n"))
        try SettingsApplyIO.atomicWrite(l.shortcutsLua, try lines("-- Generated shortcuts.\nreturn " + SettingsApplyValidation.lua(SettingsApplyValidation.shortcutSetup(prefs, catalog)) + "\n"))
        do {
            let json = try SettingsApplyJSONWriter.dumps(.dict(prefs), indent: 2, ensureASCII: false) + [0x0A]
            try SettingsApplyIO.atomicWrite(l.preferences, json)
        } catch is SettingsApplyJSONWriter.Unencodable {
            throw SettingsApplyFailure.generic("preferences contain a string that cannot be written")
        }

        // init.lua: drop the previous revision line, add a new one. The engine reloads on this change.
        var initText = try SettingsApplyIO.readText(l.initLua)
        initText = removingRevision(initText)
        guard let initBytes = Py.utf8(Py.rstrip(initText) + T("\n-- settings revision \(SettingsApplyIO.nowNanoseconds())\n")) else { throw SettingsApplyFailure.generic("init.lua cannot be written") }
        try SettingsApplyIO.atomicWrite(l.initLua, initBytes)

        // Match current windows as well as future spawn-time rules. Never unfloat on removal.
        // The settings are saved by now: a slow or failing answer here is a note, not a failure.
        let note = "Saved. Floating could not be applied to the windows that are open now; new windows follow the rules."
        let floated: SettingsApplyIO.Child
        do { floated = try SettingsApplyIO.run(l.bridge, ["apply-float-rules", rulesURL.path], environment: l.childEnvironment, timeout: 10) }
        catch SettingsApplyIO.ChildError.timeout { log(l, "apply-float-rules timeout"); return note }
        catch { throw SettingsApplyFailure.generic("unexpected: apply-float-rules could not run: \(error)") }
        if floated.status != 0 {
            let err = Py.strip(T(try text(floated.stderr)))
            log(l, "apply-float-rules: " + Py.string(err.isEmpty ? Py.strip(T(try text(floated.stdout))) : err))
            return note
        }
        return "Saved. Microfish will pick up the changes."
    }

    /// `re.sub(r'\n-- settings revision \d+\n?$', '\n', text)`: the revision line at the very end, which
    /// `$` also allows to be followed by one final newline.
    private static func removingRevision(_ text: SettingsApplyText) -> SettingsApplyText {
        let marker = T("\n-- settings revision ")
        func isDigit(_ c: UInt32) -> Bool { Unicode.Scalar(c)?.properties.generalCategory == .decimalNumber }
        var start = text.count - marker.count - 1
        while start >= 0 {
            if Array(text[start..<(start + marker.count)]) == marker {
                var end = start + marker.count
                let digitsStart = end
                while end < text.count, isDigit(text[end]) { end += 1 }
                if end > digitsStart {
                    let rest = Array(text[end...])
                    if rest.isEmpty { return Array(text[..<start]) + [0x0A] }
                    if rest == [0x0A] { return Array(text[..<start]) + [0x0A] }
                    if rest == [0x0A, 0x0A] { return Array(text[..<start]) + [0x0A, 0x0A] }
                }
            }
            start -= 1
        }
        return text
    }
}
