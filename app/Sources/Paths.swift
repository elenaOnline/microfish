import Foundation

/// Where Microfish keeps things. One place, so the helper, Settings, Refresh and the
/// updater agree with the engine (which resolves the same paths in bundled mode).
/// Every location can be redirected by environment for tests and throwaway builds.
enum MicrofishPaths {
    static let appIdentifier = "net.webreceptor.microfish"
    static let engineLabel = "net.webreceptor.microfish.engine"
    static let engineAgentPlist = "net.webreceptor.microfish.engine.plist"
    /// Mach service the engine publishes; the bridge looks it up through `PANERU_MACH_SERVICE`.
    static let engineService = "net.webreceptor.microfish.engine"

    private static var env: [String: String] { ProcessInfo.processInfo.environment }
    private static func override(_ key: String) -> URL? {
        env[key].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
    }
    private static var library: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
    }

    /// `~/Library/Application Support/Microfish`: preferences, init.lua, generated Lua, drafts, backups.
    static var support: URL {
        override("MICROFISH_SUPPORT_DIR") ?? library.appendingPathComponent("Application Support/Microfish", isDirectory: true)
    }
    /// Saved session (`XDG_STATE_HOME` for the engine): `State/paneru/state.json`, `view-pins.json`, `view-status.json`.
    static var state: URL { support.appendingPathComponent("State", isDirectory: true) }
    static var engineState: URL { state.appendingPathComponent("paneru", isDirectory: true) }
    /// Files the engine and helper exchange while running: `navigator.tsv`, `navigator.intent`, locks.
    static var runtime: URL { support.appendingPathComponent("Runtime", isDirectory: true) }
    static var logs: URL {
        override("MICROFISH_LOG_DIR") ?? library.appendingPathComponent("Logs/Microfish", isDirectory: true)
    }
    static var engineLog: URL { logs.appendingPathComponent("engine.log") }
    static var refreshLog: URL { logs.appendingPathComponent("refresh.log") }

    static var preferences: URL { support.appendingPathComponent("preferences.json") }
    static var initLua: URL { support.appendingPathComponent("init.lua") }
    static var settingsLua: URL { support.appendingPathComponent("settings.lua") }
    static var shortcutsLua: URL { support.appendingPathComponent("shortcuts.lua") }
    static var drafts: URL { support.appendingPathComponent("Settings Drafts", isDirectory: true) }
    static var settingsBackups: URL { support.appendingPathComponent("Backups/Settings", isDirectory: true) }
    static var refreshBackups: URL { support.appendingPathComponent("Backups/Refresh", isDirectory: true) }
    static var snapshot: URL { runtime.appendingPathComponent("navigator.tsv") }
    static var intent: URL { runtime.appendingPathComponent("navigator.intent") }

    /// The bundle's `Contents/Resources` (icon, `Lua/microfish.lua`, `Defaults/`, `shortcut-defaults.json`).
    static var resources: URL {
        override("MICROFISH_RESOURCES") ?? Bundle.main.resourceURL ?? Bundle.main.bundleURL
    }
    static var defaults: URL { resources.appendingPathComponent("Defaults", isDirectory: true) }
    static var shortcutCatalog: URL { resources.appendingPathComponent("shortcut-defaults.json") }
    static var appIcon: URL { resources.appendingPathComponent("AppIcon.icns") }

    private static var contents: URL { Bundle.main.bundleURL.appendingPathComponent("Contents", isDirectory: true) }
    /// The engine executable inside the nested `Microfish Engine.app` (used for `query`, never to launch it).
    static var engineExecutable: URL {
        env["MICROFISH_ENGINE"].map { URL(fileURLWithPath: $0) }
            ?? contents.appendingPathComponent("Helpers/Microfish Engine.app/Contents/MacOS/Microfish Engine")
    }
    static var bridgeExecutable: URL {
        env["MICROFISH_BRIDGE"].map { URL(fileURLWithPath: $0) }
            ?? contents.appendingPathComponent("MacOS/microfish-command")
    }
    /// Environment for engine CLI and bridge children, so they reach this install's engine.
    static var childEnvironment: [String: String] {
        var e = env
        e["PANERU_MACH_SERVICE"] = env["PANERU_MACH_SERVICE"] ?? engineService
        return e
    }
}
