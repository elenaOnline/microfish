// Headless tests for src/LiveSignals.swift. Appended after src/main.swift (NAVIGATOR_TESTS) by tests/run.py.
// Touches only a temp directory; opens no windows.
do {
 var n = 0
 func ok(_ c: @autoclosure () -> Bool, _ m: String) { precondition(c(), "LiveSignals: " + m); n += 1 }
 func pump(_ s: TimeInterval) { RunLoop.current.run(until: Date(timeIntervalSinceNow: s)) }
 func win(_ id: Int, _ x: Double, layer: Int = 0) -> LiveWindow { LiveWindow(id: id, frame: CGRect(x: x, y: 0, width: 100, height: 100), layer: layer) }

 // MotionGate: starts idle, probes, activates on change/kick, quiets after identical frames.
 var g = MotionGate()
 ok(!g.isActive(0) && g.shouldRead(0), "idle at start but the first read is due")
 ok(g.observe(1, now: 0), "first observation counts as a change")
 ok(g.isActive(0.3) && g.shouldRead(0.3), "active inside the quiet window")
 ok(!g.observe(1, now: 0.4), "identical frame is not a change")
 ok(g.isActive(0.45) && !g.isActive(0.6), "identical frames do not extend activity; it ends 0.5 s after the last change")
 ok(g.shouldRead(0.6), "probe due once the last read is older than ~90 ms")
 ok(!g.observe(1, now: 0.6) && !g.shouldRead(0.65) && g.shouldRead(0.7), "probe due every ~90 ms (one per 10 Hz lifecycle tick) while idle")
 ok(g.observe(2, now: 0.7) && g.isActive(1.1) && !g.isActive(1.25), "probe that finds movement re-activates tracking")
 g.kick(2.0); ok(g.isActive(2.4) && !g.isActive(2.6), "kick holds for the quiet period")
 g.kick(3.0, hold: 1.3); ok(g.isActive(4.2) && !g.isActive(4.4), "long hold for the once-a-second scroll intent")
 g.kick(3.1, hold: 0.1); ok(g.isActive(4.2), "a shorter kick never shortens an active hold")
 var steady = MotionGate(); _ = steady.observe(5, now: 0)
 var t = 0.0, lastActive = 0.0
 while t < 3 { t += 1.0 / 120; steady.observe(5, now: t); if steady.isActive(t) { lastActive = t } }
 ok(lastActive < 0.51, "frame-rate reads of an unchanged scene stop extending activity")
 var moving = MotionGate(); t = 0
 for i in 0..<240 { t += 1.0 / 120; moving.observe(i, now: t) }
 ok(moving.isActive(t), "continuously changing frames stay active")

 // geometrySignature
 let a = [win(1, 0), win(2, 100)]
 ok(geometrySignature(a) == geometrySignature([win(1, 0), win(2, 100)]), "equal scenes hash equal")
 ok(geometrySignature(a) != geometrySignature([win(1, 0), win(2, 101)]), "frame change is seen")
 ok(geometrySignature(a) != geometrySignature([win(2, 100), win(1, 0)]), "stacking order change is seen")
 ok(geometrySignature(a) == geometrySignature(a + [win(9, 5, layer: 24)]), "non-normal layers (menu bar, Dock) are ignored")
 ok(geometrySignature(a) != geometrySignature(a + [win(9, 5)]), "a new normal window is seen")

 // SampleGate
 var s = SampleGate()
 let sz = CGSize(width: 800, height: 600), sz2 = CGSize(width: 900, height: 600)
 ok(s.claim(id: 7, size: sz, appearance: "aqua", key: 1, have: false, now: 100), "first sight samples")
 ok(!s.claim(id: 7, size: sz, appearance: "aqua", key: 1, have: true, now: 100.5), "no resample 0.5 s later")
 ok(s.claim(id: 7, size: sz, appearance: "aqua", key: 1, have: true, now: 101.3), "one settle capture after the first")
 ok(!s.claim(id: 7, size: sz, appearance: "aqua", key: 1, have: true, now: 105), "nothing changed: no capture (old code captured every 3 s)")
 ok(!s.claim(id: 7, size: sz, appearance: "aqua", key: 1, have: true, now: 130), "still quiet at 30 s")
 ok(s.claim(id: 7, size: sz, appearance: "aqua", key: 1, have: true, now: 146.4), "slow safety refresh after 45 s")
 ok(s.claim(id: 7, size: sz2, appearance: "aqua", key: 1, have: true, now: 150), "size change samples")
 ok(!s.claim(id: 7, size: sz2, appearance: "aqua", key: 1, have: true, now: 150.4), "min interval holds")
 ok(s.claim(id: 7, size: sz2, appearance: "aqua", key: 1, have: true, now: 151.3), "settle capture follows a change")
 ok(s.claim(id: 7, size: sz2, appearance: "darkAqua", key: 1, have: true, now: 160), "appearance change samples")
 ok(s.claim(id: 7, size: sz2, appearance: "darkAqua", key: 2, have: true, now: 170), "group membership/selection change samples")
 ok(s.claim(id: 8, size: sz, appearance: "aqua", key: 3, have: false, now: 170), "another window is independent")
 ok(!s.claim(id: 8, size: sz, appearance: "aqua", key: 3, have: false, now: 170.5), "failed capture is not retried at once")
 ok(s.claim(id: 8, size: sz, appearance: "aqua", key: 3, have: false, now: 172), "settle capture still runs for a window with no sample")
 ok(!s.claim(id: 8, size: sz, appearance: "aqua", key: 3, have: false, now: 174), "no retry before 3 s")
 ok(s.claim(id: 8, size: sz, appearance: "aqua", key: 3, have: false, now: 175.2), "failed capture retried after 3 s")
 ok(screenCaptureAllowed(now: 1000) == screenCaptureAllowed(now: 1005), "preflight answer is cached")
 var st = SampleGate()
 ok(st.claim(id: 9, size: sz, appearance: "aqua", key: 1, titles: 1, have: true, now: 200), "titles: first sight")
 ok(st.claim(id: 9, size: sz, appearance: "aqua", key: 1, titles: 1, have: true, now: 201.3), "titles: settle capture")
 ok(!st.claim(id: 9, size: sz, appearance: "aqua", key: 1, titles: 2, have: true, now: 202), "a title change 0.7 s after a capture is not captured yet")
 ok(st.claim(id: 9, size: sz, appearance: "aqua", key: 1, titles: 2, have: true, now: 204.5), "page navigation (title change) re-samples once 3 s have passed")
 ok(!st.claim(id: 9, size: sz, appearance: "aqua", key: 1, titles: 3, have: true, now: 206), "an animating title is rate limited to one capture per 3 s")
 ok(st.claim(id: 9, size: sz, appearance: "aqua", key: 1, titles: 3, have: true, now: 207.7), "...and the next one 3 s after that (no extra settle capture for title-only changes)")
 ok(!st.claim(id: 9, size: sz, appearance: "aqua", key: 1, titles: 3, have: true, now: 230), "a settled title is not captured again before the safety refresh")

 // FileWatcher against the engine's write-tmp-then-rename publishing.
 let dir = NSTemporaryDirectory() + "mf-live-\(getpid())/"
 try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
 defer { try? FileManager.default.removeItem(atPath: dir) }
 let target = dir + "navigator.tsv"
 func publish(_ text: String) { try! text.write(toFile: target + ".tmp", atomically: false, encoding: .utf8); rename(target + ".tmp", target) }
 publish("0")
 var hits = 0, stamps: [UInt64] = []
 let w = FileWatcher(path: target) { hits += 1; stamps.append(DispatchTime.now().uptimeNanoseconds) }
 w.start(); ok(w.isAttached, "attached to an existing file")
 pump(0.1); ok(hits == 0, "quiet file: no events")
 var latencies: [Double] = []
 for i in 1...6 {
  let before = hits, t0 = DispatchTime.now().uptimeNanoseconds
  publish("\(i)")
  let deadline = Date(timeIntervalSinceNow: 1)
  while hits == before && Date() < deadline { pump(0.001) }
  ok(hits > before, "rename #\(i) observed (watcher reattached each time)")
  latencies.append(Double(stamps[before] - t0) / 1e6)
  ok((try? String(contentsOfFile: target, encoding: .utf8)) == "\(i)", "new content is readable in the handler")
  pump(0.02)
 }
 ok((latencies.max() ?? 99) < 50, "rename-to-handler latency under 50 ms (max \(latencies.max() ?? 0) ms)")
 print(String(format: "  file watch latency over %d renames: mean %.3f ms, max %.3f ms", latencies.count, latencies.reduce(0, +) / Double(latencies.count), latencies.max() ?? 0))
 pump(0.05); let beforeLog = hits
 try! "log line\n".write(toFile: dir + "navigator.log", atomically: false, encoding: .utf8)
 try! "x".write(toFile: dir + "other.tmp", atomically: false, encoding: .utf8)
 pump(0.15); ok(hits == beforeLog, "sibling files in the same directory do not trigger the watcher")
 let beforeTouch = hits
 let h = FileHandle(forWritingAtPath: target)!; h.seekToEndOfFile(); h.write(Data("more".utf8)); try? h.close()
 pump(0.1); ok(hits > beforeTouch, "in-place write is observed too")
 w.stop()
 let missing = dir + "later.intent"
 var lateHits = 0
 let late = FileWatcher(path: missing) { lateHits += 1 }
 late.start(); ok(!late.isAttached, "missing file: not attached yet")
 try! "show".write(toFile: missing, atomically: false, encoding: .utf8)
 let lateDeadline = Date(timeIntervalSinceNow: 3)
 while lateHits == 0 && Date() < lateDeadline { pump(0.05) }
 ok(lateHits >= 1 && late.isAttached, "file created later is picked up and attached")
 late.stop()

 // Regression (review #2): a rename that lands between reopening the path and the kevent registration used to
 // leave the watcher on an unlinked inode, deaf for good. A burst of 1 ms renames with 3 ms of handler work
 // (12-15 of 40 trials went deaf before the fix) must never leave a watcher that misses the final publish.
 do {
  let rdir = NSTemporaryDirectory() + "mf-race-\(getpid())/"
  try? FileManager.default.createDirectory(atPath: rdir, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(atPath: rdir) }
  let rtarget = rdir + "navigator.tsv"
  func raw(_ text: String) { try! text.write(toFile: rtarget + ".tmp", atomically: false, encoding: .utf8); rename(rtarget + ".tmp", rtarget) }
  func busy(_ ms: Double) { let end = DispatchTime.now().uptimeNanoseconds + UInt64(ms * 1e6); while DispatchTime.now().uptimeNanoseconds < end {} }
  raw("init")
  let wq = DispatchQueue(label: "mf.race.writer")
  var deaf = 0
  let trials = 24
  for _ in 0..<trials {
   var hits = 0
   let rw = FileWatcher(path: rtarget) { hits += 1; busy(3) }
   rw.start(); pump(0.02)
   let done = DispatchSemaphore(value: 0)
   wq.async {
    let end = DispatchTime.now().uptimeNanoseconds + 120_000_000; var i = 0
    while DispatchTime.now().uptimeNanoseconds < end { raw("\(i)"); i += 1; usleep(UInt32(1000 * (0.5 + Double.random(in: 0..<1)))) }
    done.signal()
   }
   while done.wait(timeout: .now()) == .timedOut { pump(0.002) }
   pump(0.12)
   let before = hits
   raw("final"); pump(0.15)
   if hits <= before { deaf += 1 }
   rw.stop(); pump(0.02)
  }
  ok(deaf == 0, "watcher never goes deaf under a 1 ms rename burst with handler work (\(deaf)/\(trials) deaf)")
 }

 // LiveSignals wiring
 let fresh = LiveSignals()
 ok(fresh.takeFileChange() && fresh.takeFileChange() && fresh.shouldRead(), "without watchers it behaves like the old polling (always true)")
 let sig = LiveSignals(); var woke = 0
 sig.onWake = { woke += 1 }
 sig.watch([target, missing])
 ok(sig.takeFileChange() && !sig.takeFileChange(), "dirty once at start, then quiet")
 ok(!sig.motionActive && !sig.armed() || sig.armed(), "idle gate")
 publish("again"); pump(0.1)
 ok(woke >= 1 && sig.takeFileChange() && !sig.takeFileChange(), "file change wakes once and marks dirty")
 ok(!sig.motionActive, "a file write alone is not motion")
 sig.kick(); let wakes = woke; sig.kick(); ok(woke == wakes && sig.motionActive, "kick while already active does not re-wake")
 let holds = LiveSignals(); let t0 = LiveSignals.now
 holds.intentSeen("scroll"); ok(holds.gate.isActive(t0 + 1.2) && !holds.gate.isActive(t0 + 1.4), "scroll intent holds 1.3 s")
 for a in ["swipe", "swiping", "lift"] { let hs = LiveSignals(); hs.intentSeen(a); ok(hs.gate.isActive(t0 + 1.2), "\(a) intent holds like scroll") }
 let h2 = LiveSignals(); h2.intentSeen("show"); ok(h2.gate.isActive(t0 + 0.4) && !h2.gate.isActive(t0 + 0.6), "show intent holds 0.5 s")
 let h3 = LiveSignals(); h3.intentSeen("row"); ok(h3.gate.isActive(t0 + 0.4) && !h3.gate.isActive(t0 + 0.6), "row intent holds 0.5 s")
 let h4 = LiveSignals(); h4.intentSeen("dismiss"); h4.intentSeen("hide"); ok(!h4.gate.isActive(t0 + 0.01), "dismiss and hide (every mouse-down) hold nothing")
 // Burst coalescing: many events in one burst are one leading tick plus at most one trailing tick.
 let burst = LiveSignals(); var burstTicks = 0; burst.onWake = { burstTicks += 1 }
 for _ in 0..<40 { burst.fileChanged() }
 pump(0.05); ok(burstTicks >= 1 && burstTicks <= 2, "40 file events in one burst give \(burstTicks) tick(s)")
 // Layout signature: titles and app names are not layout.
 let snapA = NavigatorSnapshot("101\t1\t1\n101\t1\tA\ta.b\tOne\t28\t101\n102\t1\tB\tb.c\tTwo\t28\t101\n")
 let snapTitles = NavigatorSnapshot("101\t1\t1\n101\t1\tA\ta.b\tOne (3)\t28\t101\n102\t1\tB\tb.c\tTwo!\t28\t101\n")
 let snapFocus = NavigatorSnapshot("102\t1\t1\n101\t1\tA\ta.b\tOne\t28\t101\n102\t1\tB\tb.c\tTwo\t28\t101\n")
 let snapSel = NavigatorSnapshot("101\t1\t1\n101\t1\tA\ta.b\tOne\t28\t102\n102\t1\tB\tb.c\tTwo\t28\t102\n")
 let snapCol = NavigatorSnapshot("101\t1\t1\n101\t1\tA\ta.b\tOne\t28\t101\n102\t2\tB\tb.c\tTwo\t28\t101\n")
 let snapHidden = NavigatorSnapshot("101\t1\t0\n101\t1\tA\ta.b\tOne\t28\t101\n102\t1\tB\tb.c\tTwo\t28\t101\n")
 let base = snapshotLayoutSignature(snapA)
 ok(base == snapshotLayoutSignature(snapTitles), "titles do not change the layout signature")
 ok([snapFocus, snapSel, snapCol, snapHidden].allSatisfy { snapshotLayoutSignature($0) != base }, "focus, selection, column and tabsVisible do")
 let sr = LiveSignals(); sr.watch([]); sr.gate.observe(1, now: LiveSignals.now - 0.6); sr.gate.observe(1, now: LiveSignals.now); var srWoke = 0; sr.onWake = { srWoke += 1 }
 ok(!sr.shouldRead() && !sr.motionActive, "quiet and just probed: nothing due")
 sr.sampleReady()
 ok(srWoke == 1 && sr.shouldRead() && !sr.motionActive, "a finished capture wakes one tick with a read, without starting tracking")
 let sc = LiveSignals(); sc.snapshotChanged(base); ok(sc.gate.isActive(LiveSignals.now + 0.4), "first snapshot kicks")
 let sc2 = LiveSignals(); sc2.snapshotChanged(base); sc2.gate = MotionGate(); sc2.snapshotChanged(snapshotLayoutSignature(snapTitles))
 ok(!sc2.gate.isActive(LiveSignals.now) && sc2.shouldRead(), "a title-only snapshot: no motion, but one read is owed")
 sig.stop(); ok(!sig.watching, "stop")

 // Navigator.tick() gating (panel never shown; window reads are read-only CGWindowList calls).
 let root = NSTemporaryDirectory() + "mf-nav-\(getpid())/"
 try? FileManager.default.createDirectory(atPath: root + "work", withIntermediateDirectories: true)
 defer { try? FileManager.default.removeItem(atPath: root) }
 try! "101\t1\t1\n101\t1\tA\ta.b\tOne\t28\t101\n102\t1\tB\tb.c\tTwo\t28\t101\n".write(toFile: root + "work/navigator.tsv", atomically: true, encoding: .utf8)
 let nav = Navigator(path: root + "work/navigator.tsv")
 nav.panel = StripPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
 nav.signals.onWake = { [unowned nav] in nav.tick() }
 nav.signals.watch([])   // watching mode without watchers: only explicit signals wake it
 nav.tick()
 ok(nav.snapshot.tabGroups.count == 1, "first tick loads the snapshot (dirty at start)")
 let first = nav.signals.gate.lastRead
 ok(first > -.infinity && nav.signals.motionActive, "first tick reads geometry and starts tracking")
 let sceneSignature = nav.signals.gate.signature!
 var quietGate = MotionGate(); _ = quietGate.observe(sceneSignature, now: LiveSignals.now - 1.1)
 nav.signals.gate = quietGate
 ok(!nav.signals.motionActive, "scene settled")
 nav.tick()
 let probed = nav.signals.gate.lastRead
 ok(probed > first, "idle tick past the probe interval does one probe read")
 for _ in 0..<20 { nav.tick() }
 ok(nav.signals.gate.lastRead == probed || nav.signals.motionActive, "idle ticks within the probe interval make no WindowServer read")
 // Title storm: only titles change. Each rewrite re-renders once (one read + update) and never starts tracking.
 nav.signals.gate = quietGate; nav.signals.gate.observe(sceneSignature, now: LiveSignals.now - 0.05)
 var lastReads: [TimeInterval] = []
 for i in 1...8 {
  try! "101\t1\t1\n101\t1\tA\ta.b\tOne \(i)\t28\t101\n102\t1\tB\tb.c\tTwo\t28\t101\n".write(toFile: root + "work/navigator.tsv", atomically: true, encoding: .utf8)
  nav.signals.fileChanged(); pump(0.03)
  lastReads.append(nav.signals.gate.lastRead)
 }
 ok(nav.snapshot.entries.first?.title == "One 8", "each title rewrite reached the snapshot")
 ok(!nav.signals.motionActive, "8 title-only rewrites never start frame-rate tracking")
 ok(Set(lastReads).count >= 7, "...but each one re-rendered with a read and bar update")
 try! "102\t1\t1\n101\t1\tA\ta.b\tOne\t28\t101\n102\t1\tB\tb.c\tTwo\t28\t101\n".write(toFile: root + "work/navigator.tsv", atomically: true, encoding: .utf8)
 nav.signals.fileChanged(); pump(0.03)
 ok(nav.signals.motionActive, "a focus change starts tracking")
 nav.signals.gate = MotionGate()
 try! "101\t1\t0\n".write(toFile: root + "work/navigator.tsv", atomically: true, encoding: .utf8)
 nav.signals.fileChanged(); pump(0.03)
 ok(nav.snapshot.tabsVisible == false && nav.liveWindows.isEmpty, "snapshot change is applied within the event's own tick; bars hidden stops reads")

 // HUD fast ticks (their fast-tick condition) must not imply window reads when nothing moves.
 try! "101\t1\t1\n101\t1\tA\ta.b\tOne\t28\t101\n102\t1\tB\tb.c\tTwo\t28\t101\n".write(toFile: root + "work/navigator.tsv", atomically: true, encoding: .utf8)
 nav.signals.onWake = nil
 nav.tick(forcePoll: true)
 ok(nav.snapshot.tabsVisible && nav.snapshot.tabGroups.count == 1, "tab group snapshot restored")
 var q2 = MotionGate(); _ = q2.observe(nav.signals.gate.signature!, now: LiveSignals.now - 1.1); nav.signals.gate = q2
 nav.tick()   // one probe read: scene is quiet again
 let settled = nav.signals.gate.lastRead
 nav.preferences.hide = "timer"; nav.preferences.delay = 30
 nav.presence.visible = true; nav.presence.timer = true; nav.presence.anchor = Date.timeIntervalSinceReferenceDate
 nav.presence.deferred = (.show, Date.timeIntervalSinceReferenceDate + 1e6)   // keeps tick() from resetting the headless HUD
 ok(nav.fastNeeded(), "HUD presence asks for display-rate ticks")
 for _ in 0..<60 { nav.tick() }
 ok(nav.fastNeeded() && nav.signals.gate.lastRead == settled, "60 HUD fast ticks made no WindowServer read")
 nav.presence.hide()

 // The single clock: 10 Hz without bars, 30 Hz with bars (lifecycle tick stays ~10 Hz), always one timer.
 var barsOn = false, lifeTicks = 0
 let clocked = LiveSignals()
 clocked.startClock(barsVisible: { barsOn }) { lifeTicks += 1 }
 pump(1.05); let idleFires = clocked.wakeCount, idleLife = lifeTicks
 ok((8...12).contains(idleFires) && idleLife == idleFires, "no bars: clock fires ~10/s and every fire is a lifecycle tick (\(idleFires))")
 barsOn = true; pump(0.3)
 let f0 = clocked.wakeCount, l0 = lifeTicks; pump(1.0)
 let barFires = clocked.wakeCount - f0, barLife = lifeTicks - l0
 ok((24...36).contains(barFires) && (8...12).contains(barLife), "bars visible: clock ~30/s, lifecycle ~10/s (\(barFires), \(barLife))")
 barsOn = false; pump(0.3)
 let f1 = clocked.wakeCount; pump(1.0)
 ok((8...12).contains(clocked.wakeCount - f1), "bars hidden: back to ~10 wakeups/s")
 clocked.stop()
 print("LiveSignals checks passed: \(n)")
}
