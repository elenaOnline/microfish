import AppKit
import CryptoKit
import ServiceManagement

// The helper owns the engine's lifecycle: it registers the engine's launch agent with
// SMAppService, starts it with `launchctl kickstart`, stops it with SIGTERM (the engine saves its
// session and restores windows on exit), and asks it `query active` whether it is serving.
// Everything that touches the system goes through two small protocols so tests drive the whole
// sequence with fakes; a NAVIGATOR_TESTS build cannot construct the live ones.

// MARK: Process runner

struct CommandResult: Equatable {
    var status: Int32
    var output: String
    /// The executable could not be started.
    static let noLaunch: Int32 = -1
    /// Our own per-call deadline killed a hung child (the engine may be mid-shutdown: not proof it is gone).
    static let timedOut: Int32 = 124
}

protocol EngineProcessRunner {
    /// Runs one short command to completion (or `timeout`) and returns its status and standard output.
    func run(_ executable: URL, _ arguments: [String], environment: [String: String]?, timeout: TimeInterval) -> CommandResult
}

/// The production runner: silent children, each bounded. In a NAVIGATOR_TESTS build it starts nothing, and
/// refuses outright to run launchctl, so no test can reach launchd.
struct SystemProcessRunner: EngineProcessRunner {
    func run(_ executable: URL, _ arguments: [String], environment: [String: String]?, timeout: TimeInterval) -> CommandResult {
        #if NAVIGATOR_TESTS
        precondition(executable.lastPathComponent != "launchctl", "test reached launchd")
        return CommandResult(status: CommandResult.noLaunch, output: "")
        #else
        let child = Process()
        child.executableURL = executable; child.arguments = arguments
        if let environment { child.environment = environment }
        let out = Pipe()
        child.standardOutput = out; child.standardError = FileHandle.nullDevice
        let lock = NSLock(); var collected = Data()
        out.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil } else { lock.lock(); collected.append(chunk); lock.unlock() }
        }
        do { try child.run() } catch { out.fileHandleForReading.readabilityHandler = nil; return CommandResult(status: CommandResult.noLaunch, output: "") }
        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false
        while child.isRunning {
            if Date() >= deadline { child.terminate(); child.waitUntilExit(); timedOut = true; break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        out.fileHandleForReading.readabilityHandler = nil
        let rest = (try? out.fileHandleForReading.readToEnd()) ?? Data()
        lock.lock(); collected.append(rest); let data = collected; lock.unlock()
        return CommandResult(status: timedOut ? CommandResult.timedOut : child.terminationStatus, output: String(decoding: data, as: UTF8.self))
        #endif
    }
}

// MARK: Launch agent registration

enum AgentServiceStatus: Equatable { case notRegistered, enabled, requiresApproval, notFound }

protocol AgentService {
    var status: AgentServiceStatus { get }
    func register() throws
    func unregister() throws
    func openLoginItemsSettings()
}

/// The real `SMAppService.agent(plistName:)`. Not constructible in a NAVIGATOR_TESTS build.
struct SMAgentService: AgentService {
    private let service: SMAppService
    init(plistName: String = MicrofishPaths.engineAgentPlist) {
        #if NAVIGATOR_TESTS
        preconditionFailure("test reached SMAppService")
        #else
        service = SMAppService.agent(plistName: plistName)
        #endif
    }
    var status: AgentServiceStatus {
        switch service.status {
        case .notRegistered: return .notRegistered
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        @unknown default: return .notFound
        }
    }
    func register() throws { try service.register() }
    func unregister() throws { try service.unregister() }
    func openLoginItemsSettings() { SMAppService.openSystemSettingsLoginItems() }
}

/// Stands in where only queries are wanted: it reports no agent and registers nothing.
struct UnavailableAgentService: AgentService {
    var status: AgentServiceStatus { .notFound }
    func register() throws {}
    func unregister() throws {}
    func openLoginItemsSettings() {}
}

// MARK: Which build is the running engine

/// A file's identity: device and inode. A running process keeps its executable's inode even after the file is
/// renamed or replaced, so equal identity means "this very file", whatever the path says now.
struct FileIdentity: Equatable { var device: UInt64; var inode: UInt64 }

enum EngineBuildMatch: Equatable {
    /// The running engine was started from this bundle's engine executable.
    case same
    /// It was started from a different file: a previous build that outlived an unclean update.
    case different
    /// Cannot tell (not a launchd job, no such process, unreadable): such an engine is never touched.
    case unknown
}

protocol EngineBuildInspecting {
    func compare() -> EngineBuildMatch
}

/// Reads the engine's pid from launchd (`launchctl print gui/<uid>/<label>`), asks the kernel which file that
/// process is running (`proc_pidinfo` region 0 = its executable), and compares it with the bundle's engine file.
/// Needs no cooperation from the engine; touches nothing; raises no permission prompt.
struct SystemEngineInspector: EngineBuildInspecting {
    let runner: EngineProcessRunner
    let launchctl: URL
    let domainTarget: String
    let engine: URL

    func compare() -> EngineBuildMatch {
        let printed = runner.run(launchctl, ["print", domainTarget], environment: nil, timeout: 5)
        guard printed.status == 0, let pid = Self.pid(fromLaunchctlPrint: printed.output),
              let running = Self.runningImage(pid: pid), let bundled = Self.identity(of: engine) else { return .unknown }
        return running == bundled ? .same : .different
    }

    /// The first `pid = N` line of a `launchctl print` job description (absent while the job is not running).
    static func pid(fromLaunchctlPrint text: String) -> Int32? {
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("pid = ") else { continue }
            if let pid = Int32(trimmed.dropFirst("pid = ".count)), pid > 0 { return pid }
        }
        return nil
    }

    static func identity(of url: URL) -> FileIdentity? {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return nil }
        return FileIdentity(device: UInt64(st.st_dev), inode: UInt64(st.st_ino))
    }

    /// The vnode behind the process's first mapped region, which is its main executable.
    static func runningImage(pid: Int32) -> FileIdentity? {
        var info = proc_regionwithpathinfo()
        let size = Int32(MemoryLayout<proc_regionwithpathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDREGIONPATHINFO, 0, &info, size) == size else { return nil }
        let stat = info.prp_vip.vip_vi.vi_stat
        return FileIdentity(device: UInt64(stat.vst_dev), inode: UInt64(stat.vst_ino))
    }
}

// MARK: Outcomes

enum EngineRegistration: Equatable {
    /// Registered and its plist unchanged: nothing was done.
    case ready
    /// Registered (first time) or re-registered because the bundled plist changed.
    case registered
    /// Registered but the user has not allowed it in System Settings > General > Login Items.
    case requiresApproval
    /// The bundle has no such agent (damaged or misplaced app).
    case notFound
    case failed(String)
}

enum EngineStartOutcome: Equatable {
    /// `query active` already answered: left alone.
    case alreadyRunning
    /// Kickstarted and answering.
    case started
    /// The running engine belonged to another build (left over from an unclean update): stopped with its session
    /// saved, then started from this bundle.
    case replacedStale
    /// ...but that older engine would not stop. It is left running and in use.
    case staleEngineStuck
    case requiresApproval
    case notFound
    /// Launched, but `query active` did not answer in time: almost always no Accessibility grant.
    case notResponding
    /// `launchctl kickstart` or registration failed.
    case failed(String)
    var isRunning: Bool { self == .alreadyRunning || self == .started || self == .replacedStale || self == .staleEngineStuck }
}

enum EngineStopOutcome: Equatable {
    case stopped, absent, stuck, sendFailed, unreachable
    /// Only a confirmed-gone engine lets the helper go; otherwise the tabs stay usable.
    var helperMayExit: Bool { self == .stopped || self == .absent }
}

struct EngineRestartOutcome: Equatable {
    var stop: EngineStopOutcome
    /// nil when the engine would not stop, so no start was attempted.
    var start: EngineStartOutcome?
    var succeeded: Bool { stop.helperMayExit && start?.isRunning == true }
}

// MARK: Control

protocol EngineControlling: AnyObject {
    /// `query active` answers only while the engine serves its socket. nil = cannot tell.
    func isActive() -> Bool?
    /// The engine's `query state` JSON text, or nil when it does not answer with JSON.
    func queryState(timeout: TimeInterval) -> String?
    func ensureRegistered() -> EngineRegistration
    /// Registers if needed; leaves a healthy engine alone; otherwise kickstarts and waits for it to answer.
    func start() -> EngineStartOutcome
    /// SIGTERM through launchd, then waits for the engine to exit.
    func stop() -> EngineStopOutcome
    func restart() -> EngineRestartOutcome
    func openLoginItemsSettings()
}

final class EngineControl: EngineControlling {
    let runner: EngineProcessRunner
    let service: AgentService
    let defaults: UserDefaults
    let engine: URL
    let launchctl: URL
    let label: String
    let domainTarget: String
    let plist: URL
    let environment: [String: String]
    /// nil = never replaces a running engine (tests, query-only controllers).
    let inspector: EngineBuildInspecting?
    var now: () -> Double = { ProcessInfo.processInfo.systemUptime }
    var sleep: (Double) -> Void = { Thread.sleep(forTimeInterval: $0) }
    /// How long a started engine has to answer, and how long a stopping one has to exit.
    var startTimeout = 8.0, stopTimeout = 5.0, interval = 0.1
    /// Bound for one `query` call (the engine answers in milliseconds when it is up).
    var callLimit = 2.0

    init(runner: EngineProcessRunner,
         service: AgentService,
         defaults: UserDefaults = .standard,
         engine: URL = MicrofishPaths.engineExecutable,
         launchctl: URL = URL(fileURLWithPath: "/bin/launchctl"),
         label: String = MicrofishPaths.engineLabel,
         domainTarget: String = MicrofishPaths.engineDomainTarget,
         plist: URL = MicrofishPaths.agentPlist,
         environment: [String: String] = MicrofishPaths.childEnvironment,
         inspector: EngineBuildInspecting? = nil) {
        self.inspector = inspector
        self.runner = runner; self.service = service; self.defaults = defaults
        self.engine = engine; self.launchctl = launchctl; self.label = label
        self.domainTarget = domainTarget; self.plist = plist; self.environment = environment
    }

    /// The production controller. A NAVIGATOR_TESTS build stops here: tests build their own with fakes.
    static func live() -> EngineControl {
        #if NAVIGATOR_TESTS
        preconditionFailure("test reached the live engine control")
        #else
        let runner = SystemProcessRunner()
        return EngineControl(runner: runner, service: SMAgentService(),
                             inspector: SystemEngineInspector(runner: runner, launchctl: URL(fileURLWithPath: "/bin/launchctl"),
                                                              domainTarget: MicrofishPaths.engineDomainTarget, engine: MicrofishPaths.engineExecutable))
        #endif
    }

    /// Query-only controller (`isActive`, `queryState`): no registration, nothing that reaches launchd.
    static func probe(callLimit: Double = 2) -> EngineControl {
        let control = EngineControl(runner: SystemProcessRunner(), service: UnavailableAgentService())
        control.callLimit = callLimit
        return control
    }

    private func engineCall(_ arguments: [String], timeout: TimeInterval? = nil) -> CommandResult {
        runner.run(engine, arguments, environment: environment, timeout: timeout ?? callLimit)
    }

    func isActive() -> Bool? {
        let r = engineCall(["query", "active"])
        // A slow answer is not an absent engine.
        return r.status == 0 || r.status == CommandResult.timedOut ? true : r.status == CommandResult.noLaunch ? nil : false
    }

    func queryState(timeout: TimeInterval = 2) -> String? {
        let r = engineCall(["query", "state"], timeout: timeout)
        guard r.status == 0, let data = r.output.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) != nil else { return nil }
        return r.output
    }

    // Registration

    /// SHA-256 of the bundled agent plist, hex. nil when the file cannot be read.
    func bundledPlistHash() -> String? {
        guard let data = try? Data(contentsOf: plist) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func ensureRegistered() -> EngineRegistration {
        let hash = bundledPlistHash()
        let stored = defaults.string(forKey: MicrofishPaths.registeredPlistHashKey)
        switch service.status {
        case .enabled:
            if hash == nil || hash == stored { return .ready }
            // The bundled plist changed (an update): launchd keeps the old definition until it is registered again.
            do { try service.unregister(); try service.register() }
            catch { return .failed(error.localizedDescription) }
            return finishRegistering(hash)
        case .requiresApproval:
            // Nothing more can be done until the user allows it; the hash stays unrecorded so approval re-registers once.
            return .requiresApproval
        case .notRegistered, .notFound:
            do { try service.register() }
            catch {
                // Unapproved agents report the failure through register(); the status says which kind.
                switch service.status {
                case .requiresApproval: return .requiresApproval
                case .notFound: return .notFound
                default: return .failed(error.localizedDescription)
                }
            }
            return finishRegistering(hash)
        }
    }

    private func finishRegistering(_ hash: String?) -> EngineRegistration {
        switch service.status {
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        default:
            if let hash { defaults.set(hash, forKey: MicrofishPaths.registeredPlistHashKey) }
            return .registered
        }
    }

    func openLoginItemsSettings() { service.openLoginItemsSettings() }

    // Start

    func start() -> EngineStartOutcome {
        switch ensureRegistered() {
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        case .failed(let message): return .failed(message)
        case .ready, .registered: break
        }
        var replacing = false
        if isActive() == true {
            // An engine from another build (the helper died or was force-quit, Sparkle swapped the bundle, the old
            // engine kept running) must not be adopted: stop it the normal way (it saves its session), then start ours.
            // One attempt per start(); an engine we cannot identify is adopted as before.
            guard inspector?.compare() == .different else { return .alreadyRunning }
            guard stop().helperMayExit else { return .staleEngineStuck }
            replacing = true
        }
        let up: EngineStartOutcome = replacing ? .replacedStale : .started
        let kick = runner.run(launchctl, ["kickstart", domainTarget], environment: nil, timeout: 5)
        if kick.status != 0 {
            // A kickstart that fails while the engine answers anyway (it just came up) is not a failure.
            if isActive() == true { return up }
            return .failed("launchctl kickstart exited \(kick.status)")
        }
        let deadline = now() + startTimeout
        while true {
            if isActive() == true { return up }
            if now() >= deadline { return .notResponding }
            sleep(interval)
        }
    }

    // Stop

    func stop() -> EngineStopOutcome {
        guard let up = isActive() else { return .unreachable }
        if !up { return .absent }
        let kill = runner.run(launchctl, ["kill", "SIGTERM", domainTarget], environment: nil, timeout: 5)
        if kill.status != 0 {
            // Not loaded in launchd (started some other way): ask the engine to quit itself.
            if engineCall(["send-cmd", "quit"]).status != 0 { return isActive() == false ? .stopped : .sendFailed }
        }
        let deadline = now() + stopTimeout
        while true {
            if isActive() == false { return .stopped }
            if now() >= deadline { return .stuck }
            sleep(interval)
        }
    }

    func restart() -> EngineRestartOutcome {
        let stopped = stop()
        guard stopped.helperMayExit else { return EngineRestartOutcome(stop: stopped, start: nil) }
        return EngineRestartOutcome(stop: stopped, start: start())
    }
}

// MARK: What the user is told

/// The standard alerts. Pure data here; `EngineAlert.present` shows them (never in a test build).
struct EngineAlert: Equatable {
    var title: String
    var message: String
    /// The first button, which does something; "OK" is always added after it.
    var actionTitle: String?
    enum Action: Equatable { case openLoginItems, openAccessibility }
    var action: Action?

    static func forStart(_ outcome: EngineStartOutcome) -> EngineAlert? {
        switch outcome {
        case .alreadyRunning, .started, .replacedStale: return nil
        case .staleEngineStuck:
            return EngineAlert(title: "Microfish is still running an older version",
                               message: "The older engine wouldn’t quit, so it is still in use; restart your Mac to switch to the new one.")
        case .requiresApproval:
            return EngineAlert(title: "Microfish needs your approval",
                               message: "Allow Microfish in System Settings > General > Login Items & Extensions, then open Microfish again.",
                               actionTitle: "Open Login Items Settings", action: .openLoginItems)
        case .notFound:
            return EngineAlert(title: "Microfish couldn’t start", message: "Microfish.app is damaged. Reinstall it, then open Microfish again.")
        case .notResponding:
            return EngineAlert(title: "Microfish couldn’t start",
                               message: "Microfish didn’t respond. In System Settings > Privacy & Security > Device Control and Data Access, make sure Microfish Engine and Microfish are turned on, then open Microfish again.",
                               actionTitle: "Open System Settings", action: .openAccessibility)
        case .failed:
            return EngineAlert(title: "Microfish couldn’t start", message: "Something went wrong while starting Microfish. Try opening it again.")
        }
    }

    #if !NAVIGATOR_TESTS
    /// Runs on the main thread. The helper is a menu-bar accessory, so it comes forward for the alert.
    @MainActor func present(openLoginItems: () -> Void) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title; alert.informativeText = message
        if let actionTitle { alert.addButton(withTitle: actionTitle) }
        alert.addButton(withTitle: "OK")
        guard alert.runModal() == .alertFirstButtonReturn, let action else { return }
        switch action {
        case .openLoginItems: openLoginItems()
        case .openAccessibility: NSWorkspace.shared.open(MicrofishPaths.accessibilityPane)
        }
    }
    #endif
}
