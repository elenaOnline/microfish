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
    case requiresApproval
    case notFound
    /// Launched, but `query active` did not answer in time: almost always no Accessibility grant.
    case notResponding
    /// `launchctl kickstart` or registration failed.
    case failed(String)
    var isRunning: Bool { self == .alreadyRunning || self == .started }
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
         environment: [String: String] = MicrofishPaths.childEnvironment) {
        self.runner = runner; self.service = service; self.defaults = defaults
        self.engine = engine; self.launchctl = launchctl; self.label = label
        self.domainTarget = domainTarget; self.plist = plist; self.environment = environment
    }

    /// The production controller. A NAVIGATOR_TESTS build stops here: tests build their own with fakes.
    static func live() -> EngineControl {
        #if NAVIGATOR_TESTS
        preconditionFailure("test reached the live engine control")
        #else
        return EngineControl(runner: SystemProcessRunner(), service: SMAgentService())
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
        if isActive() == true { return .alreadyRunning }
        let kick = runner.run(launchctl, ["kickstart", domainTarget], environment: nil, timeout: 5)
        if kick.status != 0 {
            // A kickstart that fails while the engine answers anyway (it just came up) is not a failure.
            if isActive() == true { return .started }
            return .failed("launchctl kickstart exited \(kick.status)")
        }
        let deadline = now() + startTimeout
        while true {
            if isActive() == true { return .started }
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
        case .alreadyRunning, .started: return nil
        case .requiresApproval:
            return EngineAlert(title: "Microfish needs your approval",
                               message: "Allow Microfish in System Settings > General > Login Items & Extensions, then open Microfish again.",
                               actionTitle: "Open Login Items Settings", action: .openLoginItems)
        case .notFound:
            return EngineAlert(title: "Microfish couldn’t start", message: "Microfish.app is damaged. Reinstall it, then open Microfish again.")
        case .notResponding:
            return EngineAlert(title: "Microfish couldn’t start",
                               message: "Microfish didn’t respond. In System Settings > Privacy & Security > Device Control and Data Access, make sure Microfish is turned on, then open Microfish again.",
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
