// Headless tests for EngineControl and EngineRefresh with fake runners and a fake agent service. Standalone
// (NAVIGATOR_TESTS): no process is started, launchd and SMAppService are never reached, temp directories only.
import Foundation

var engineChecks = 0
func echeck(_ c: @autoclosure () -> Bool, _ m: String) { precondition(c(), "engine: " + m); engineChecks += 1 }

// A scripted world: the engine answers `query active` while `active`; launchctl calls change that.
final class FakeWorld: EngineProcessRunner {
    var active = false
    var calls: [String] = []
    /// After a kickstart the engine answers on the Nth `query active` (nil = never comes up).
    var comesUpAfter: Int? = 2
    /// After a kill the engine stops answering on the Nth `query active` (nil = never exits).
    var diesAfter: Int? = 2
    var kickstartStatus: Int32 = 0, killStatus: Int32 = 0, sendCmdStatus: Int32 = 0
    var engineMissing = false
    private var pendingUp: Int?, pendingDown: Int?
    func run(_ executable: URL, _ arguments: [String], environment: [String: String]?, timeout: TimeInterval) -> CommandResult {
        let name = executable.lastPathComponent
        calls.append(([name] + arguments).joined(separator: " "))
        if name == "launchctl" {
            switch arguments.first {
            case "kickstart": if kickstartStatus == 0 { pendingUp = comesUpAfter }; return CommandResult(status: kickstartStatus, output: "")
            case "kill": if killStatus == 0 { pendingDown = diesAfter }; return CommandResult(status: killStatus, output: "")
            default: return CommandResult(status: 1, output: "")
            }
        }
        if engineMissing { return CommandResult(status: CommandResult.noLaunch, output: "") }
        if arguments == ["send-cmd", "quit"] { if sendCmdStatus == 0 { pendingDown = 1 }; return CommandResult(status: sendCmdStatus, output: "") }
        if arguments == ["query", "active"] {
            if let n = pendingUp { if n <= 1 { active = true; pendingUp = nil } else { pendingUp = n - 1 } }
            if let n = pendingDown { if n <= 1 { active = false; pendingDown = nil } else { pendingDown = n - 1 } }
            return CommandResult(status: active ? 0 : 1, output: "")
        }
        if arguments == ["query", "state"] { return CommandResult(status: active ? 0 : 1, output: active ? "{\"windows\":[]}" : "") }
        return CommandResult(status: 1, output: "")
    }
    var launchctlCalls: [String] { calls.filter { $0.hasPrefix("launchctl") } }
}

final class FakeAgent: AgentService {
    var status: AgentServiceStatus
    var registers = 0, unregisters = 0, openedSettings = 0
    var registerError: Error?
    /// What the status becomes once register() succeeds.
    var afterRegister: AgentServiceStatus = .enabled
    init(_ status: AgentServiceStatus) { self.status = status }
    func register() throws { registers += 1; if let registerError { throw registerError }; status = afterRegister }
    func unregister() throws { unregisters += 1; status = .notRegistered }
    func openLoginItemsSettings() { openedSettings += 1 }
}

struct Boom: Error, LocalizedError { var errorDescription: String? { "boom" } }

let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("mf-engine-\(getpid())")
try! fm.createDirectory(at: root, withIntermediateDirectories: true)
let suiteName = "net.webreceptor.microfish.tests.\(getpid())"
defer { try? fm.removeItem(at: root); UserDefaults().removePersistentDomain(forName: suiteName) }

let plist = root.appendingPathComponent("agent.plist")
func writePlist(_ body: String) { try! body.write(to: plist, atomically: true, encoding: .utf8) }
writePlist("<plist>v1</plist>")

func makeControl(_ world: FakeWorld, _ agent: FakeAgent, defaults: UserDefaults) -> (EngineControl, () -> Double) {
    let c = EngineControl(runner: world, service: agent, defaults: defaults,
                          engine: URL(fileURLWithPath: "/fake/Microfish Engine"), launchctl: URL(fileURLWithPath: "/bin/launchctl"),
                          label: "test.engine", domainTarget: "gui/501/test.engine", plist: plist, environment: ["PANERU_MACH_SERVICE": "test.engine"])
    var t = 0.0
    c.now = { t }; c.sleep = { t += $0 }
    return (c, { t })
}
func freshDefaults() -> UserDefaults { let d = UserDefaults(suiteName: suiteName)!; d.removePersistentDomain(forName: suiteName); return d }
let hashKey = MicrofishPaths.registeredPlistHashKey

// MARK: start
do {
    // Inactive engine: registered, kickstarted once, waited for.
    let world = FakeWorld(), agent = FakeAgent(.notRegistered), defaults = freshDefaults()
    let (c, time) = makeControl(world, agent, defaults: defaults)
    let outcome = c.start()
    echeck(outcome == .started, "starts an inactive engine: \(outcome)")
    echeck(world.launchctlCalls == ["launchctl kickstart gui/501/test.engine"], "one kickstart of the agent: \(world.launchctlCalls)")
    echeck(agent.registers == 1 && agent.unregisters == 0, "registered once")
    echeck(defaults.string(forKey: hashKey) == c.bundledPlistHash() && c.bundledPlistHash()?.count == 64, "plist SHA-256 stored")
    echeck(time() < 8, "came up inside the wait")
}
do {
    // A healthy engine is left alone: no kickstart, no kill.
    let world = FakeWorld(); world.active = true
    let agent = FakeAgent(.enabled), defaults = freshDefaults()
    let (c, _) = makeControl(world, agent, defaults: defaults)
    defaults.set(c.bundledPlistHash(), forKey: hashKey)
    echeck(c.start() == .alreadyRunning, "healthy engine is left alone")
    echeck(world.launchctlCalls.isEmpty && agent.registers == 0 && agent.unregisters == 0, "nothing touched launchd or the registration")
}
do {
    // Never answers (no Accessibility): notResponding after ~8 s of waiting, not forever.
    let world = FakeWorld(); world.comesUpAfter = nil
    let (c, time) = makeControl(world, FakeAgent(.enabled), defaults: freshDefaults())
    echeck(c.start() == .notResponding, "silent engine: notResponding")
    echeck(time() >= 8 && time() < 8.5, "waited about 8 s: \(time())")
    echeck(world.launchctlCalls.count == 1, "kickstarted once, not in a loop")
}
do {
    // Kickstart fails while nothing answers: a failure the caller can show; a failing kickstart for an engine that came up anyway is fine.
    let world = FakeWorld(); world.kickstartStatus = 113
    let (c, _) = makeControl(world, FakeAgent(.enabled), defaults: freshDefaults())
    if case .failed = c.start() { echeck(true, "") } else { echeck(false, "kickstart failure should be .failed") }
}
do {
    // requiresApproval: no kickstart, no recorded hash; the alert offers Login Items.
    let world = FakeWorld(), agent = FakeAgent(.requiresApproval), defaults = freshDefaults()
    let (c, _) = makeControl(world, agent, defaults: defaults)
    echeck(c.start() == .requiresApproval, "requiresApproval surfaces")
    echeck(world.calls.isEmpty && agent.registers == 0 && defaults.string(forKey: hashKey) == nil, "nothing run, nothing recorded")
    let alert = EngineAlert.forStart(.requiresApproval)
    echeck(alert?.actionTitle == "Open Login Items Settings" && alert?.action == .openLoginItems, "alert offers Login Items")
    c.openLoginItemsSettings(); echeck(agent.openedSettings == 1, "the button opens Login Items through the service")
}
do {
    // register() itself reports needing approval (first registration of an unapproved agent).
    let agent = FakeAgent(.notRegistered); agent.afterRegister = .requiresApproval
    let (c, _) = makeControl(FakeWorld(), agent, defaults: freshDefaults())
    echeck(c.start() == .requiresApproval, "first registration that needs approval")
    // register() throws and the agent is missing from the bundle.
    let missing = FakeAgent(.notFound); missing.registerError = Boom()
    let (c2, _) = makeControl(FakeWorld(), missing, defaults: freshDefaults())
    echeck(c2.start() == .notFound, ".notFound when the bundle has no agent")
    echeck(EngineAlert.forStart(.notFound)?.action == nil, "damaged app: plain alert")
    // register() throws for another reason.
    let other = FakeAgent(.notRegistered); other.registerError = Boom()
    let (c3, _) = makeControl(FakeWorld(), other, defaults: freshDefaults())
    echeck(c3.start() == .failed("boom"), "other registration errors are .failed")
}
do {
    let a = EngineAlert.forStart(.notResponding)!
    echeck(a.action == .openAccessibility && a.actionTitle == "Open System Settings" && a.message.contains("Privacy & Security"), "no-Accessibility alert")
    echeck(MicrofishPaths.accessibilityPane.absoluteString == "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility", "deep link")
    echeck(EngineAlert.forStart(.started) == nil && EngineAlert.forStart(.alreadyRunning) == nil, "no alert when it is running")
}

// MARK: registration only when the plist changed
do {
    let world = FakeWorld(), agent = FakeAgent(.notRegistered), defaults = freshDefaults()
    writePlist("<plist>v1</plist>")
    let (c, _) = makeControl(world, agent, defaults: defaults)
    echeck(c.ensureRegistered() == .registered && agent.registers == 1, "first run registers")
    echeck(c.ensureRegistered() == .ready && c.ensureRegistered() == .ready, "unchanged plist: ready")
    echeck(agent.registers == 1 && agent.unregisters == 0, "no re-registration while the plist is unchanged")
    writePlist("<plist>v2</plist>")
    echeck(c.ensureRegistered() == .registered, "changed plist re-registers")
    echeck(agent.unregisters == 1 && agent.registers == 2, "unregister then register, once")
    echeck(c.ensureRegistered() == .ready && agent.registers == 2, "and then it is ready again")
    echeck(defaults.string(forKey: hashKey) == c.bundledPlistHash(), "new hash stored")
    // Approval granted later: enabled with no recorded hash re-registers once.
    let late = FakeAgent(.requiresApproval), d2 = freshDefaults()
    let (c2, _) = makeControl(FakeWorld(), late, defaults: d2)
    echeck(c2.ensureRegistered() == .requiresApproval && d2.string(forKey: hashKey) == nil, "waiting for approval records nothing")
    late.status = .enabled
    echeck(c2.ensureRegistered() == .registered && late.registers == 1, "after approval: registered once")
    echeck(c2.ensureRegistered() == .ready, "then ready")
}

// MARK: stop
do {
    // Stopped: SIGTERM through launchd, then waits for it to leave.
    let world = FakeWorld(); world.active = true
    let (c, time) = makeControl(world, FakeAgent(.enabled), defaults: freshDefaults())
    echeck(c.stop() == .stopped, "stops a running engine")
    echeck(world.launchctlCalls == ["launchctl kill SIGTERM gui/501/test.engine"], "SIGTERM via launchctl kill: \(world.launchctlCalls)")
    echeck(time() < 5 && !world.active, "gone inside the timeout")
    echeck(EngineStopOutcome.stopped.helperMayExit && EngineStopOutcome.absent.helperMayExit, "stopped and absent let the helper go")
    echeck(!EngineStopOutcome.stuck.helperMayExit && !EngineStopOutcome.sendFailed.helperMayExit && !EngineStopOutcome.unreachable.helperMayExit, "everything else keeps the helper")
}
do {
    let world = FakeWorld()   // not running
    let (c, _) = makeControl(world, FakeAgent(.enabled), defaults: freshDefaults())
    echeck(c.stop() == .absent && world.launchctlCalls.isEmpty, "absent: nothing to kill")
}
do {
    let world = FakeWorld(); world.engineMissing = true
    let (c, _) = makeControl(world, FakeAgent(.enabled), defaults: freshDefaults())
    echeck(c.stop() == .unreachable && world.launchctlCalls.isEmpty, "engine binary cannot run: unreachable, nothing killed")
}
do {
    let world = FakeWorld(); world.active = true; world.diesAfter = nil
    let (c, time) = makeControl(world, FakeAgent(.enabled), defaults: freshDefaults())
    echeck(c.stop() == .stuck, "an engine that will not exit is stuck")
    echeck(time() >= 5 && time() < 5.5, "after the 5 s timeout: \(time())")
}
do {
    // launchctl kill fails (not loaded in launchd): the engine's own quit request is used.
    let world = FakeWorld(); world.active = true; world.killStatus = 113
    let (c, _) = makeControl(world, FakeAgent(.enabled), defaults: freshDefaults())
    echeck(c.stop() == .stopped && world.calls.contains("Microfish Engine send-cmd quit"), "falls back to send-cmd quit: \(world.calls)")
    // Neither works.
    let w2 = FakeWorld(); w2.active = true; w2.killStatus = 113; w2.sendCmdStatus = 1
    let (c2, _) = makeControl(w2, FakeAgent(.enabled), defaults: freshDefaults())
    echeck(c2.stop() == .sendFailed, "both refused: sendFailed")
}
do {
    // restart: stop then start; a stuck engine is not started again.
    let world = FakeWorld(); world.active = true
    let (c, _) = makeControl(world, FakeAgent(.enabled), defaults: freshDefaults())
    let r = c.restart()
    echeck(r.stop == .stopped && r.start == .started && r.succeeded, "restart: \(r)")
    echeck(world.launchctlCalls == ["launchctl kill SIGTERM gui/501/test.engine", "launchctl kickstart gui/501/test.engine"], "kill then kickstart: \(world.launchctlCalls)")
    let stuck = FakeWorld(); stuck.active = true; stuck.diesAfter = nil
    let (c2, _) = makeControl(stuck, FakeAgent(.enabled), defaults: freshDefaults())
    let r2 = c2.restart()
    echeck(r2.stop == .stuck && r2.start == nil && !r2.succeeded && !stuck.launchctlCalls.contains { $0.contains("kickstart") }, "stuck engine is not restarted")
}
do {
    // isActive / queryState.
    let world = FakeWorld(); world.active = true
    let (c, _) = makeControl(world, FakeAgent(.enabled), defaults: freshDefaults())
    echeck(c.isActive() == true && c.queryState(timeout: 1) == "{\"windows\":[]}", "answers")
    world.active = false
    echeck(c.isActive() == false && c.queryState(timeout: 1) == nil, "does not answer")
    world.engineMissing = true
    echeck(c.isActive() == nil, "cannot tell when the binary cannot run")
}

// MARK: Refresh with a fake engine
final class FakeEngine: EngineControlling {
    var events: [String] = []
    var stopOutcome: EngineStopOutcome = .stopped
    var startOutcome: EngineStartOutcome = .started
    /// `queryState` answers: nil = no answer. Consumed in order; the last repeats.
    var states: [String?] = ["{\"a\":1}", "{\"a\":2}"]
    var stateCalls = 0
    var onStop: (() -> Void)?
    func isActive() -> Bool? { true }
    func queryState(timeout: TimeInterval) -> String? { events.append("state"); defer { stateCalls += 1 }; return states[min(stateCalls, states.count - 1)] }
    func ensureRegistered() -> EngineRegistration { .ready }
    func start() -> EngineStartOutcome { events.append("start"); return startOutcome }
    func stop() -> EngineStopOutcome { events.append("stop"); onStop?(); return stopOutcome }
    func restart() -> EngineRestartOutcome { EngineRestartOutcome(stop: stop(), start: start()) }
    func openLoginItemsSettings() {}
}
do {
    func setup(_ name: String) -> (state: URL, backups: URL, lock: URL, log: URL) {
        let base = root.appendingPathComponent(name)
        let state = base.appendingPathComponent("State")
        try! fm.createDirectory(at: state.appendingPathComponent("paneru"), withIntermediateDirectories: true)
        try! "session-1".write(to: state.appendingPathComponent("paneru/state.json"), atomically: true, encoding: .utf8)
        return (state, base.appendingPathComponent("Backups/Refresh"), base.appendingPathComponent("Runtime/refresh.lock"), base.appendingPathComponent("Logs/refresh.log"))
    }
    func refresh(_ engine: FakeEngine, _ p: (state: URL, backups: URL, lock: URL, log: URL)) -> EngineRefresh {
        let r = EngineRefresh(engine: engine, state: p.state, backups: p.backups, lock: p.lock, log: p.log)
        r.sleep = { _ in }; r.timestamp = { "20260101-000000" }
        return r
    }
    func lastLine(_ url: URL) -> String { ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").last.map(String.init) ?? "" }

    // Happy path.
    var p = setup("ok"); var engine = FakeEngine()
    engine.onStop = { try! "session-saved-on-stop".write(to: p.state.appendingPathComponent("paneru/state.json"), atomically: true, encoding: .utf8) }
    var result = refresh(engine, p).run()
    let b = p.backups.appendingPathComponent("20260101-000000")
    echeck(result.success && result.message == "Windows refreshed; session backup: \(b.path)" && result.backup == b, "refresh succeeds: \(result)")
    echeck(engine.events == ["stop", "start", "state", "state"], "stop, start, wait for state, re-read after the restore grace: \(engine.events)")
    echeck((try? String(contentsOf: b.appendingPathComponent("state-before/paneru/state.json"))) == "session-1", "state-before is the session before the stop")
    echeck((try? String(contentsOf: b.appendingPathComponent("state-stopped/paneru/state.json"))) == "session-saved-on-stop", "state-stopped is the session the stop saved")
    echeck((try? String(contentsOf: b.appendingPathComponent("state-after.json"))) == "{\"a\":2}", "state-after.json written")
    echeck(lastLine(p.log) == result.message, "the map's one-line result ends refresh.log")

    // The engine takes a few polls to answer.
    p = setup("slowstart"); engine = FakeEngine(); engine.states = [nil, nil, nil, "{\"a\":1}", "{\"a\":2}"]
    result = refresh(engine, p).run()
    echeck(result.success && engine.stateCalls == 5, "waits through unanswered polls: \(engine.stateCalls)")

    // Never answers: gives up with the plain sentence, layout stays backed up.
    p = setup("silent"); engine = FakeEngine(); engine.states = [nil]
    result = refresh(engine, p).run()
    echeck(!result.success && result.message == EngineRefresh.didNotRestart && engine.stateCalls == 40, "gives up after 40 polls: \(result), \(engine.stateCalls)")
    echeck(fm.fileExists(atPath: p.backups.appendingPathComponent("20260101-000000/state-before/paneru/state.json").path), "backup kept on failure")
    echeck(lastLine(p.log) == EngineRefresh.didNotRestart, "failure line is the last log line")

    // Engine will not stop: nothing is started, plain sentence.
    p = setup("stuck"); engine = FakeEngine(); engine.stopOutcome = .stuck
    result = refresh(engine, p).run()
    echeck(!result.success && result.message == EngineRefresh.didNotStop && engine.events == ["stop"], "stuck engine: no start: \(engine.events)")

    // Engine was not running: refresh still starts it.
    p = setup("absent"); engine = FakeEngine(); engine.stopOutcome = .absent
    result = refresh(engine, p).run()
    echeck(result.success && engine.events.first == "stop" && engine.events.contains("start"), "absent engine is started")

    // Start fails / needs approval.
    p = setup("approval"); engine = FakeEngine(); engine.startOutcome = .requiresApproval
    result = refresh(engine, p).run()
    echeck(!result.success && result.message == EngineRefresh.needsApproval && engine.stateCalls == 0, "approval needed")
    p = setup("notresponding"); engine = FakeEngine(); engine.startOutcome = .notResponding
    result = refresh(engine, p).run()
    echeck(!result.success && result.message == EngineRefresh.didNotRestart && engine.stateCalls == 0, "engine did not come up")

    // A refresh already running holds the lock: this one touches nothing.
    p = setup("locked"); engine = FakeEngine()
    try! fm.createDirectory(at: p.lock.deletingLastPathComponent(), withIntermediateDirectories: true)
    let held = open(p.lock.path, O_CREAT | O_WRONLY, 0o644); echeck(held >= 0 && flock(held, LOCK_EX | LOCK_NB) == 0, "test holds the lock")
    result = refresh(engine, p).run()
    echeck(!result.success && result.message == EngineRefresh.alreadyRunning && engine.events.isEmpty && !fm.fileExists(atPath: p.backups.path), "second refresh refused: \(result)")
    flock(held, LOCK_UN); close(held)
    result = refresh(engine, p).run()
    echeck(result.success, "the lock is released when the holder is done")

    // No saved session yet: the backup folders are still made.
    p = setup("nostate"); try! fm.removeItem(at: p.state); engine = FakeEngine()
    result = refresh(engine, p).run()
    echeck(result.success && fm.fileExists(atPath: p.backups.appendingPathComponent("20260101-000000/state-before").path), "no State folder yet: empty backups")
}
print("engine checks passed:", engineChecks)
