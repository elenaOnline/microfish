import AppKit
import Observation

// The state behind Settings > Updates. Free of Sparkle so the Settings sources (and their test and
// render builds) compile without the framework; `Updates.swift` owns the updater and drives
// `UpdateSettingsModel.shared`. The pane itself is `UpdatesPane.swift`.

/// What the helper's menus need from the updater.
@MainActor protocol UpdateChecking: AnyObject {
    var canCheckForUpdates: Bool { get }
    /// Version string of an update found by a background check that has not been shown yet.
    var waitingVersion: String? { get }
    func checkForUpdates()
}

/// The values the Updates pane shows and the actions behind its controls. These settings apply
/// the moment they change (as in System Settings); they are not engine settings, so the shared
/// Apply/Revert footer has nothing to do with them.
@MainActor @Observable final class UpdateSettingsModel {
    static let shared = UpdateSettingsModel()
    /// Defaults key the beta toggle persists in; `allowedChannels(for:)` reads the same key.
    nonisolated static let betaKey = "MicrofishBetaUpdates"

    /// False when no updater is running (an unbundled dev run, or no feed configured).
    var available = false
    var automaticChecks = false
    var automaticDownloads = false
    /// Sparkle's `allowsAutomaticUpdates`: automatic downloads can only be on while checks are.
    var canAutomaticallyDownload = false
    var beta = UserDefaults.standard.bool(forKey: UpdateSettingsModel.betaKey)
    var lastCheck: Date?
    var canCheck = false
    var checking = false
    /// A found-but-not-yet-shown update (a scheduled check found it while the app was in the background).
    var waitingVersion: String?
    var version = UpdateSettingsModel.bundleVersion()

    @ObservationIgnored var onSetAutomaticChecks: ((Bool) -> Void)?
    @ObservationIgnored var onSetAutomaticDownloads: ((Bool) -> Void)?
    @ObservationIgnored var onSetBeta: ((Bool) -> Void)?
    @ObservationIgnored var onCheckNow: (() -> Void)?

    nonisolated static func bundleVersion(_ bundle: Bundle = .main) -> String {
        let short = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        switch (short, build) {
        case let (s?, b?) where s != b: return "\(s) (\(b))"
        case let (s?, _): return s
        case let (_, b?): return b
        default: return "Development build"
        }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; f.doesRelativeDateFormatting = true; return f
    }()
    var lastCheckText: String { lastCheck.map { Self.dateFormatter.string(from: $0) } ?? "Never" }
}
