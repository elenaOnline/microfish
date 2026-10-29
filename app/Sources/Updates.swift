import AppKit
import Sparkle

// Sparkle 2 for Microfish. Needs `-F app/Vendor/Sparkle -framework Sparkle` (see app/Scripts/fetch-sparkle.sh),
// so it is only part of the app build and of the update probe, not of the Settings/HUD test builds.
//
// Lifecycle contract (CONTRACT.md "Process lifecycle"): before the bundle is replaced the engine is
// stopped exactly as Quit Microfish stops it. Two ways an update gets installed:
//   1. Install and Relaunch (user, or Sparkle's immediate install): Sparkle asks us through
//      `shouldPostponeRelaunchForUpdate`; we stop the engine (`prepareForUpdate`) and only then let
//      it terminate this app and swap the bundle. The relaunched app starts the engine as usual.
//   2. Install on quit (automatic download): Sparkle installs when the app terminates. Every terminate
//      already goes through `applicationShouldTerminate` -> Quit Microfish, which stops the engine first.
// If the engine cannot be stopped nothing is installed now, and the user is told in plain words.

@MainActor final class MicrofishUpdateController: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate, UpdateChecking {
    let model: UpdateSettingsModel
    private(set) var updater: SPUUpdater!
    private var standardController: SPUStandardUpdaterController?
    private var observations: [NSKeyValueObservation] = []

    /// Stops the engine the way Quit Microfish does and reports whether it is gone. The app wires this to
    /// `Navigator.stopEngineForUpdate`. The default (no engine to stop) succeeds at once.
    var prepareForUpdate: (_ done: @escaping (Bool) -> Void) -> Void = { $0(true) }
    /// Called when Sparkle's relaunch was held back or finished, so the app can clear "engine stopped for update".
    var updateCycleEnded: (() -> Void)?
    /// Tells the user an update could not be installed now. Replaced in tests; the app shows an alert.
    var reportProblem: (_ title: String, _ detail: String) -> Void = MicrofishUpdateController.alert
    /// Test probes point the feed somewhere else; the app uses `SUFeedURL`.
    var feedURLOverride: String?
    var log: (String) -> Void = { NSLog("Updates: %@", $0) }

    /// True for a running app bundle that carries a feed and a public key. An unbundled dev run is not
    /// configured, so it never touches the updater.
    nonisolated static var isConfigured: Bool {
        let b = Bundle.main
        return b.bundleURL.pathExtension == "app"
            && (b.object(forInfoDictionaryKey: "SUFeedURL") as? String)?.isEmpty == false
            && (b.object(forInfoDictionaryKey: "SUPublicEDKey") as? String)?.isEmpty == false
    }

    /// `userDriver == nil` is the real app: Sparkle's standard windows. A probe passes its own headless driver.
    init(userDriver: SPUUserDriver? = nil, model: UpdateSettingsModel? = nil) {
        self.model = model ?? .shared
        super.init()
        if let userDriver {
            updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: userDriver, delegate: self)
        } else {
            let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
            standardController = controller
            updater = controller.updater
        }
        wireModel()
    }

    /// Starts the updater: scheduled checks follow the user's settings from here on.
    func start() throws {
        do { try updater.start() } catch { model.available = false; throw error }
        refreshModel()
    }

    // MARK: Settings model

    private func wireModel() {
        model.available = true
        model.onSetAutomaticChecks = { [weak self] in self?.updater.automaticallyChecksForUpdates = $0; self?.refreshModel() }
        model.onSetAutomaticDownloads = { [weak self] in self?.updater.automaticallyDownloadsUpdates = $0; self?.refreshModel() }
        model.onSetBeta = { [weak self] in self?.setBeta($0) }
        model.onCheckNow = { [weak self] in self?.checkForUpdates() }
        let paths: [PartialKeyPath<SPUUpdater>] = [\.automaticallyChecksForUpdates, \.automaticallyDownloadsUpdates, \.allowsAutomaticUpdates, \.canCheckForUpdates, \.sessionInProgress]
        for path in paths {
            if let key = path as? KeyPath<SPUUpdater, Bool> {
                observations.append(updater.observe(key, options: [.new]) { [weak self] _, _ in DispatchQueue.main.async { MainActor.assumeIsolated { self?.refreshModel() } } })
            }
        }
    }
    func refreshModel() {
        model.automaticChecks = updater.automaticallyChecksForUpdates
        model.automaticDownloads = updater.automaticallyDownloadsUpdates
        model.canAutomaticallyDownload = updater.allowsAutomaticUpdates
        model.lastCheck = updater.lastUpdateCheckDate
        model.canCheck = updater.canCheckForUpdates
        model.checking = updater.sessionInProgress && !updater.canCheckForUpdates
        model.beta = Self.betaEnabled
    }

    nonisolated static var betaEnabled: Bool { UserDefaults.standard.bool(forKey: UpdateSettingsModel.betaKey) }
    /// Changing the channel resets the update cycle so the very next check (and any pending schedule)
    /// uses the new channel; the delegate reads the key on every check.
    func setBeta(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: UpdateSettingsModel.betaKey)
        log("beta updates \(on ? "on" : "off")")
        updater.resetUpdateCycle()
        refreshModel()
    }

    // MARK: Menu hooks (UpdateChecking)

    var canCheckForUpdates: Bool { updater.canCheckForUpdates }
    private(set) var waitingVersion: String? {
        get { model.waitingVersion }
        set { model.waitingVersion = newValue }
    }
    func checkForUpdates() {
        waitingVersion = nil
        updater.checkForUpdates()
    }

    // MARK: SPUUpdaterDelegate

    nonisolated func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        Self.betaEnabled ? ["beta"] : []
    }
    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        MainActor.assumeIsolated { feedURLOverride }
    }
    nonisolated func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        MainActor.assumeIsolated {
            log("installing \(item.displayVersionString): stopping the engine first")
            prepareForUpdate { [weak self] stopped in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        if stopped {
                            self.log("engine stopped; releasing the install")
                            installHandler()
                        } else {
                            self.log("engine did not stop; install held back")
                            self.updateCycleEnded?()
                            self.reportProblem("Microfish can’t update right now", "The window manager didn’t stop cleanly, so version \(item.displayVersionString) was not installed. It will be installed the next time you quit Microfish.")
                        }
                    }
                }
            }
        }
        return true
    }
    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        // Sparkle installs when this app terminates, and a terminate always runs the clean quit first.
        MainActor.assumeIsolated { log("\(item.displayVersionString) will install when Microfish quits") }
        return false
    }
    nonisolated func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        MainActor.assumeIsolated { log("relaunching") }
    }
    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        MainActor.assumeIsolated { log("found \(item.displayVersionString) (\(item.versionString))") }
    }
    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        MainActor.assumeIsolated { log("no update: \((error as NSError).localizedDescription)") }
    }
    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        MainActor.assumeIsolated { log("update aborted: \((error as NSError).localizedDescription)") }
    }
    nonisolated func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        MainActor.assumeIsolated {
            log("cycle finished\(error.map { ": \(($0 as NSError).localizedDescription)" } ?? "")")
            updateCycleEnded?()
            refreshModel()
        }
    }

    // MARK: SPUStandardUserDriverDelegate (gentle reminders)
    // Microfish is a menu-bar app: a scheduled check must never throw a window over the user's work.
    // When the app is in the background a found update waits behind "Update Available…" in the menu and
    // in Settings; a check the user starts, or one that finds an update while Settings is in front, opens
    // Sparkle's window as usual.

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }
    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
    }
    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        MainActor.assumeIsolated { if !handleShowingUpdate { waitingVersion = update.displayVersionString } }
    }
    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        MainActor.assumeIsolated { waitingVersion = nil }
    }
    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated { waitingVersion = nil }
    }

    // MARK: Alert

    static func alert(_ title: String, _ detail: String) {
        DispatchQueue.main.async {
            let a = NSAlert()
            a.messageText = title; a.informativeText = detail; a.alertStyle = .warning
            a.addButton(withTitle: "OK")
            NSApp.activate()
            a.runModal()
        }
    }
}
