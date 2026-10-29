// Headless tests for the Quit Microfish flow with a fake engine. Appended after Sources/main.swift (NAVIGATOR_TESTS).
// The Navigator never reaches the real engine: tests inject engineControlOverride, and the live control refuses in a test build.
do {
 var n = 0
 func ok(_ c: @autoclosure () -> Bool, _ m: String) { precondition(c(), "quit: " + m); n += 1 }
 final class Fake: EngineControlling {
  var stops = 0, outcome: EngineStopOutcome
  init(_ o: EngineStopOutcome) { outcome = o }
  func isActive() -> Bool? { true }
  func queryState(timeout: TimeInterval) -> String? { nil }
  func ensureRegistered() -> EngineRegistration { .ready }
  func start() -> EngineStartOutcome { .started }
  func stop() -> EngineStopOutcome { stops += 1; return outcome }
  func restart() -> EngineRestartOutcome { EngineRestartOutcome(stop: stop(), start: nil) }
  func openLoginItemsSettings() {}
 }
 func make(_ outcome: EngineStopOutcome) -> (Navigator, Fake, () -> (exits: Int, fails: Int)) {
  let fake = Fake(outcome)
  let nav = Navigator(path: "/tmp/none/navigator.tsv")
  nav.engineControlOverride = fake
  nav.quitBackground = { $0() }; nav.quitMain = { $0() }
  var exits = 0, fails = 0
  nav.quitExit = { exits += 1 }; nav.quitFailed = { fails += 1 }
  return (nav, fake, { (exits, fails) })
 }
 for outcome in [EngineStopOutcome.stopped, .absent] {
  let (nav, fake, counts) = make(outcome)
  nav.quitMicrofish(nil)
  ok(fake.stops == 1 && counts().exits == 1 && counts().fails == 0 && nav.quitPhase == .finishing, "\(outcome): the helper leaves")
  nav.quitMicrofish(nil)
  ok(fake.stops == 1, "a second request after finishing does nothing")
 }
 for outcome in [EngineStopOutcome.stuck, .sendFailed, .unreachable] {
  let (nav, fake, counts) = make(outcome)
  nav.quitMicrofish(nil)
  ok(counts().exits == 0 && counts().fails == 1 && nav.quitPhase == .idle, "\(outcome): the helper stays, quit can be retried")
  nav.quitMicrofish(nil)
  ok(fake.stops == 2, "retry reaches the engine again")
 }
 do {
  // A second request while the first is still stopping is ignored.
  let (nav, fake, _) = make(.stopped)
  var release: (() -> Void)?
  nav.quitBackground = { release = $0 }
  nav.quitMicrofish(nil); nav.quitMicrofish(nil)
  ok(nav.quitPhase == .stopping && fake.stops == 0, "stopping: waits on the engine")
  release?()
  ok(fake.stops == 1, "one stop only")
 }
 print("quit checks passed:", n)
}
