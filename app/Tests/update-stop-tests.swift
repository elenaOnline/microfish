// Headless tests for the update-time clean stop (Navigator.stopEngineForUpdate) and the menu hooks that front
// the updater. Appended after src/main.swift (NAVIGATOR_TESTS). The "engine" is a closure; nothing is launched.
import Darwin
do {
 var n = 0
 _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
 func ok(_ c: @autoclosure () -> Bool, _ m: String) { precondition(c(), "update-stop: " + m); n += 1 }
 // A fake engine: alive until it is sent `quit`, unless `stubborn`. Counts every full stop attempt.
 final class FakeEngine { var up = true; var stubborn = false; var quits = 0 }
 func nav(_ engine: FakeEngine) -> (Navigator, exits: () -> Int, beeps: () -> Int) {
  let nav = Navigator(path: "/tmp/none/navigator.tsv")
  var exits = 0, beeps = 0
  nav.quitBackground = { $0() }; nav.quitMain = { $0() }
  nav.quitExit = { exits += 1 }; nav.quitFailed = { beeps += 1 }
  nav.systemQuit = { false }
  final class Control: EngineControlling {
  let engine: FakeEngine
  init(_ e: FakeEngine) { engine = e }
  func isActive() -> Bool? { engine.up }
  func queryState(timeout: TimeInterval) -> String? { nil }
  func ensureRegistered() -> EngineRegistration { .ready }
  func start() -> EngineStartOutcome { engine.up = true; return .started }
  func stop() -> EngineStopOutcome {
   guard engine.up else { return .absent }
   engine.quits += 1; if !engine.stubborn { engine.up = false }
   return engine.up ? .stuck : .stopped
  }
  func restart() -> EngineRestartOutcome { EngineRestartOutcome(stop: stop(), start: start()) }
  func openLoginItemsSettings() {}
 }
 nav.engineControlOverride = Control(engine)
 return (nav, { exits }, { beeps })
 }

 // 1. A healthy engine is stopped once, the helper stays, and the terminate Sparkle sends next goes straight through.
 do {
  let e = FakeEngine(); let (nav, exits, beeps) = nav(e)
  var result: Bool?
  nav.stopEngineForUpdate { result = $0 }
  ok(result == true, "done(true) once the engine is gone")
  ok(!e.up && e.quits == 1, "the engine was sent exactly one quit")
  ok(nav.quitPhase == .idle, "the quit phase is idle again (the helper is still running)")
  ok(nav.engineStoppedForUpdate, "the engine is marked as stopped for the update")
  ok(exits() == 0 && beeps() == 0, "the helper did not exit and nothing beeped")
  ok(nav.applicationShouldTerminate(NSApplication.shared) == .terminateNow, "Sparkle's terminate goes straight through")
  ok(e.quits == 1, "... without a second quit sequence")
 }
 // 2. An engine that will not stop: done(false), nothing marked, and a terminate still takes the full quit (and is refused).
 do {
  let e = FakeEngine(); e.stubborn = true; let (nav, exits, _) = nav(e)
  var result: Bool?
  nav.stopEngineForUpdate { result = $0 }
  ok(result == false, "done(false) when the engine is stuck")
  ok(!nav.engineStoppedForUpdate && nav.quitPhase == .idle, "nothing marked stopped, phase idle")
  ok(nav.applicationShouldTerminate(NSApplication.shared) == .terminateCancel, "a terminate with a live engine is refused (the quit sequence runs again)")
  ok(exits() == 0, "the helper stayed")
 }
 // 3. A user Quit already in flight is joined, not repeated; the waiter hears the Quit's outcome.
 do {
  let e = FakeEngine()
  var pending: [() -> Void] = []
  let (nav, exits, _) = nav(e)
  nav.quitBackground = { work in pending.append(work) }   // hold the stop so the second request overlaps
  nav.quitMain = { $0() }
  nav.quitMicrofish(nil)
  ok(nav.quitPhase == .stopping, "Quit is stopping the engine")
  var result: Bool?
  nav.stopEngineForUpdate { result = $0 }
  ok(result == nil && pending.count == 1, "the update stop waits for the Quit's stop instead of starting another")
  pending.removeFirst()()
  ok(result == true && e.quits == 1, "the waiter is released when the one stop finishes")
  ok(exits() == 1 && nav.quitPhase == .finishing, "the Quit still finishes by exiting the helper")
 }
 // 4. After Quit finished the engine is gone: an update stop is immediate.
 do {
  let e = FakeEngine(); let (nav, _, _) = nav(e)
  nav.quitMicrofish(nil)
  var result: Bool?
  nav.stopEngineForUpdate { result = $0 }
  ok(result == true && e.quits == 1, "done(true) at once when Quit already stopped the engine")
 }
 // 5. Two overlapping update stops share one stop.
 do {
  let e = FakeEngine(); let (nav, _, _) = nav(e)
  var pending: [() -> Void] = []
  nav.quitBackground = { pending.append($0) }
  var results: [Bool] = []
  nav.stopEngineForUpdate { results.append($0) }
  nav.stopEngineForUpdate { results.append($0) }
  ok(pending.count == 1, "one stop")
  pending.removeFirst()()
  ok(results == [true, true] && e.quits == 1, "both callers released by it")
 }
 // 6. If the cycle ends with the helper still here after the engine was stopped for it, the engine is brought back.
 do {
  let e = FakeEngine(); let (nav, _, _) = nav(e)
  var restarts = 0
  nav.restartEngineAfterAbortedUpdate = { restarts += 1 }
  nav.updateCycleEnded()
  ok(restarts == 0, "a cycle that never stopped the engine restarts nothing")
  nav.stopEngineForUpdate { _ in }
  nav.updateCycleEnded()
  ok(restarts == 1 && !nav.engineStoppedForUpdate, "an aborted update restarts the engine once and clears the mark")
  nav.updateCycleEnded()
  ok(restarts == 1, "and only once")
 }
 // 7. Menus: the item targets the helper, is disabled without an updater, follows canCheckForUpdates, and names a waiting update.
 do {
  @MainActor final class FakeUpdater: UpdateChecking {
   var canCheckForUpdates = true; var waitingVersion: String?; var checks = 0
   func checkForUpdates() { checks += 1 }
  }
  let e = FakeEngine(); let (nav, _, _) = nav(e)
  let item = nav.makeStatusMenu().items[1]
  ok(item.title == "Check for Updates…" && item.target === nav && item.action == #selector(Navigator.checkForUpdates(_:)), "status menu item")
  ok(!nav.validateMenuItem(item), "disabled when there is no updater (dev run, tests)")
  let u = MainActor.assumeIsolated { FakeUpdater() }
  nav.updater = u
  ok(nav.validateMenuItem(item) && item.title == "Check for Updates…", "enabled with an updater")
  nav.checkForUpdates(nil)
  ok(MainActor.assumeIsolated { u.checks } == 1, "the action reaches the updater")
  MainActor.assumeIsolated { u.waitingVersion = "1.1.0"; u.canCheckForUpdates = false }
  ok(!nav.validateMenuItem(item) && item.title == "Update Available (1.1.0)…", "title names a waiting update; follows canCheckForUpdates")
  let other = NSMenuItem(title: "Settings…", action: #selector(Navigator.openSettings), keyEquivalent: "")
  ok(nav.validateMenuItem(other), "other items are unaffected")
 }
 print("Update-stop checks passed:", n)
}
