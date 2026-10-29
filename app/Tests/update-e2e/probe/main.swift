import AppKit
import Sparkle

// Headless update probe: `net.webreceptor.microfish.updateprobe`, never shipped. It compiles the app's real
// Updates.swift / UpdatesPane.swift and drives them with a user driver that has no UI at all (no windows, no
// Dock icon, no sound). The probe stands in for Microfish's lifecycle with a fake "engine" child process:
//   launch  -> start the engine (as the real app does after a relaunch)
//   update  -> stop the engine (Updates.swift's prepareForUpdate hook), then let Sparkle replace the bundle
//   quit    -> applicationShouldTerminate, which stops the engine first (install-on-quit path)
// Everything it does is appended to work/events.jsonl next to the install directory. Control comes from
// work/control.json (relaunched copies have no arguments or environment).

let bundle = Bundle.main.bundleURL
let work = bundle.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("work")
let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"

func mark(_ event: String, _ extra: [String: Any] = [:]) {
    var record: [String: Any] = ["t": Date().timeIntervalSince1970, "pid": getpid(), "version": version, "build": build, "event": event]
    for (k, v) in extra { record[k] = v }
    guard var data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return }
    data.append(10)
    let path = work.appendingPathComponent("events.jsonl").path
    let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
    guard fd >= 0 else { return }
    _ = data.withUnsafeBytes { write(fd, $0.baseAddress, data.count) }
    close(fd)
}

struct Control {
    var check = false, beta = false, prepare = "ok", prepareDelay = 1.5
    var mode = "manual"          // manual | background | roundtrip
    var quitAfterWillInstall = false
    static var url: URL { work.appendingPathComponent("control.json") }
    static func read() -> Control {
        var c = Control()
        guard let data = try? Data(contentsOf: url), let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return c }
        c.check = o["check"] as? Bool ?? false; c.beta = o["beta"] as? Bool ?? false
        c.prepare = o["prepare"] as? String ?? "ok"; c.prepareDelay = o["prepareDelay"] as? Double ?? 1.5
        c.mode = o["mode"] as? String ?? "manual"; c.quitAfterWillInstall = o["quitAfterWillInstall"] as? Bool ?? false
        return c
    }
    /// A check is consumed when it starts, so the relaunched (updated) copy stays idle.
    static func consumeCheck() {
        guard let data = try? Data(contentsOf: url), var o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        o["check"] = false
        if let out = try? JSONSerialization.data(withJSONObject: o) { try? out.write(to: url, options: .atomic) }
    }
}

// MARK: headless user driver: answers every question by itself and shows nothing

final class HeadlessDriver: NSObject, SPUUserDriver {
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        mark("driver:permission-request"); reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
    }
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) { mark("driver:check-started") }
    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        mark("driver:update-found", ["found": appcastItem.displayVersionString, "foundBuild": appcastItem.versionString, "channel": appcastItem.channel ?? "", "userInitiated": state.userInitiated,
              "signing": appcastItem.signingValidationStatus.rawValue, "notesURL": appcastItem.releaseNotesURL?.absoluteString ?? "",
              "hasDescription": appcastItem.itemDescription != nil])
        reply(.install)
    }
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) { mark("driver:release-notes", ["bytes": downloadData.data.count]) }
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) { mark("driver:release-notes-failed", ["error": (error as NSError).localizedDescription]) }
    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        mark("driver:no-update", ["error": (error as NSError).localizedDescription, "code": (error as NSError).code]); acknowledgement()
    }
    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        mark("driver:updater-error", ["error": (error as NSError).localizedDescription, "code": (error as NSError).code, "domain": (error as NSError).domain, "reason": (error as NSError).localizedFailureReason ?? ""]); acknowledgement()
    }
    func showDownloadInitiated(cancellation: @escaping () -> Void) { mark("driver:download-started") }
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {}
    func showDownloadDidReceiveData(ofLength length: UInt64) {}
    func showDownloadDidStartExtractingUpdate() { mark("driver:extracting") }
    func showExtractionReceivedProgress(_ progress: Double) {}
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) { mark("driver:ready-to-install"); reply(.install) }
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        mark("driver:installing", ["applicationTerminated": applicationTerminated])
    }
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) { mark("driver:installed", ["relaunched": relaunched]); acknowledgement() }
    func dismissUpdateInstallation() { mark("driver:dismiss") }
    func showUpdateInFocus() {}
}

// MARK: fake engine

final class FakeEngine {
    var process: Process?
    var pid: pid_t { process?.processIdentifier ?? 0 }
    func start() {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sleep"); p.arguments = ["3000"]
        try? p.run(); process = p
        mark("engine-start", ["enginePid": p.processIdentifier])
        try? "\(p.processIdentifier)\n".write(to: work.appendingPathComponent("engine-\(getpid()).pid"), atomically: true, encoding: .utf8)
    }
    /// SIGTERM, then wait until the process is really gone.
    func stop() -> Bool {
        guard let p = process, p.isRunning else { return true }
        p.terminate(); p.waitUntilExit()
        return kill(p.processIdentifier, 0) != 0
    }
}

// MARK: app delegate: the Navigator's quit / update-stop phases, reduced to what the lifecycle needs

@MainActor final class ProbeDelegate: NSObject, NSApplicationDelegate {
    enum Phase { case idle, stopping, finishing }
    var phase = Phase.idle
    var engineStoppedForUpdate = false
    var waiters: [(Bool) -> Void] = []
    let engine = FakeEngine()
    var controller: MicrofishUpdateController!
    var control = Control.read()

    func stopEngine(delay: TimeInterval, completion: @escaping (Bool) -> Void) {
        DispatchQueue.global().async { [self] in
            let gone = engine.stop()
            Thread.sleep(forTimeInterval: delay)
            DispatchQueue.main.async { completion(gone) }
        }
    }
    func stopEngineForUpdate(_ done: @escaping (Bool) -> Void) {
        switch phase {
        case .finishing: engineStoppedForUpdate = true; done(true)
        case .stopping: waiters.append(done)
        case .idle:
            phase = .stopping; waiters.append(done)
            mark("prepare-begin", ["enginePid": engine.pid])
            if control.prepare == "fail" {
                mark("prepare-failed"); phase = .idle
                let w = waiters; waiters = []; w.forEach { $0(false) }; return
            }
            stopEngine(delay: control.prepareDelay) { [self] gone in
                phase = .idle
                if gone { engineStoppedForUpdate = true }
                mark("prepare-end", ["engineGone": gone])
                let w = waiters; waiters = []; w.forEach { $0(gone) }
            }
        }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        mark("terminate-request", ["phase": "\(phase)", "engineStoppedForUpdate": engineStoppedForUpdate])
        if phase == .finishing || engineStoppedForUpdate { mark("terminate-now"); return .terminateNow }
        guard phase == .idle else { return .terminateCancel }
        phase = .stopping
        stopEngine(delay: 0.3) { [self] gone in
            mark("quit-engine-stopped", ["engineGone": gone])
            if gone { phase = .finishing; NSApp.terminate(nil) } else { phase = .idle }
        }
        return .terminateCancel
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        mark("launch", ["ppid": getppid(), "mode": control.mode])
        engine.start()
        UserDefaults.standard.set(control.beta, forKey: UpdateSettingsModel.betaKey)
        controller = MicrofishUpdateController(userDriver: HeadlessDriver())
        controller.prepareForUpdate = { [weak self] done in self?.stopEngineForUpdate(done) }
        controller.updateCycleEnded = { mark("update-cycle-ended") }
        controller.reportProblem = { title, detail in mark("problem-reported", ["title": title, "detail": detail]) }
        controller.log = { [weak self] message in
            mark("updates-log", ["message": message])
            // The user "quits" a second after an automatic download is staged: the install-on-quit path.
            if message.contains("will install when"), self?.control.quitAfterWillInstall == true {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { NSApp.terminate(nil) }
            }
        }
        do { try controller.start() } catch { mark("start-failed", ["error": "\(error)"]); return }
        mark("started", ["canCheck": controller.canCheckForUpdates, "beta": UpdateSettingsModel.shared.beta,
                         "autoChecks": controller.updater.automaticallyChecksForUpdates, "autoDownloads": controller.updater.automaticallyDownloadsUpdates])
        // "quitNow" in control.json stands in for the user choosing Quit Microfish.
        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
            if let d = try? Data(contentsOf: Control.url), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any], o["quitNow"] as? Bool == true {
                var n = o; n["quitNow"] = false
                if let out = try? JSONSerialization.data(withJSONObject: n) { try? out.write(to: Control.url, options: .atomic) }
                mark("quit-requested"); NSApp.terminate(nil)
            }
        }
        switch control.mode {
        case "roundtrip": roundtrip()
        case "background":
            controller.updater.automaticallyChecksForUpdates = true
            controller.updater.automaticallyDownloadsUpdates = true
            mark("background-check-begin")
            controller.updater.checkForUpdatesInBackground()
        default:
            if control.check {
                Control.consumeCheck()
                mark("check-begin", ["beta": control.beta])
                controller.setBeta(control.beta)   // the Settings toggle's path: persists and resets the update cycle
                controller.checkForUpdates()
            }
        }
    }

    /// Settings controls: what the Updates pane writes must land in Sparkle and persist.
    func roundtrip() {
        let u = controller.updater!, m = UpdateSettingsModel.shared
        let id = Bundle.main.bundleIdentifier!
        func plistValue(_ key: String) -> Any { (CFPreferencesCopyAppValue(key as CFString, id as CFString) as Any?) ?? "unset" }
        mark("roundtrip-initial", ["autoChecks": u.automaticallyChecksForUpdates, "autoDownloads": u.automaticallyDownloadsUpdates, "allowsAuto": u.allowsAutomaticUpdates, "modelChecks": m.automaticChecks])
        m.onSetAutomaticChecks?(false)
        mark("roundtrip-checks-off", ["autoChecks": u.automaticallyChecksForUpdates, "allowsAuto": u.allowsAutomaticUpdates, "modelChecks": m.automaticChecks, "persisted": "\(plistValue("SUEnableAutomaticChecks"))"])
        m.onSetAutomaticChecks?(true); m.onSetAutomaticDownloads?(true)
        mark("roundtrip-all-on", ["autoChecks": u.automaticallyChecksForUpdates, "autoDownloads": u.automaticallyDownloadsUpdates, "modelDownloads": m.automaticDownloads, "persisted": "\(plistValue("SUAutomaticallyUpdate"))"])
        m.onSetBeta?(true)
        mark("roundtrip-beta-on", ["beta": m.beta, "persisted": "\(plistValue(UpdateSettingsModel.betaKey))", "channels": controller.allowedChannels(for: u).sorted().joined(separator: ",")])
        m.onSetBeta?(false)
        mark("roundtrip-beta-off", ["beta": m.beta, "channels": controller.allowedChannels(for: u).sorted().joined(separator: ",")])
        mark("roundtrip-done")
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = MainActor.assumeIsolated { ProbeDelegate() }
app.delegate = delegate
app.run()
