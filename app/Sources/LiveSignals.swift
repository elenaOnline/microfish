import AppKit

// Event-driven replacements for the helper's polling. Nothing here reads
// window geometry itself; it only decides when Navigator.tick() should.

// Watches one file path with a DispatchSource. The engine publishes by writing
// "<path>.tmp" and renaming it over <path>, which replaces the inode, so the
// descriptor is reopened on delete/rename. Watching the file (not its folder) keeps
// the helper's own log from feeding back into the watcher.
final class FileWatcher {
 let path: String
 private let queue: DispatchQueue
 private let handler: () -> Void
 private var source: DispatchSourceFileSystemObject?
 private var fd: Int32 = -1
 private var retry: DispatchSourceTimer?
 init(path: String, queue: DispatchQueue = .main, handler: @escaping () -> Void) { self.path = path; self.queue = queue; self.handler = handler }
 deinit { stop() }
 var isAttached: Bool { source != nil }
 func start() { if !attach() { scheduleRetry() } }
 func stop() { source?.cancel(); source = nil; retry?.cancel(); retry = nil }
 @discardableResult private func attach() -> Bool {
  let fd = open(path, O_EVTONLY)
  guard fd >= 0 else { return false }
  self.fd = fd
  let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename, .attrib, .revoke], queue: queue)
  s.setEventHandler { [weak self, weak s] in
   guard let self, let s, s === self.source else { return }
   // Reopen first so the handler sees (and watches) the file now at the path.
   if !s.data.isDisjoint(with: [.delete, .rename, .revoke]) { self.reattach() }
   self.handler()
  }
  s.setCancelHandler { close(fd) }
  source = s; s.resume()
  // The kevent is registered only after this turn of the queue. A rename in the gap leaves the fd on an
  // inode that was unlinked or replaced before any watch existed, and no event would ever come. Check the
  // fd against the path once registration has certainly happened, and again later; `verify()` also runs
  // from LiveSignals' slow fallback.
  for delay in [0.004, 0.04] { queue.asyncAfter(deadline: .now() + delay) { [weak self, weak s] in if let s, s === self?.source { self?.verify() } } }
  return true
 }
 // The descriptor must still be the file at the path (same dev+ino, still linked); otherwise reattach and
 // report, since content may have changed unseen.
 func verify() {
  guard source != nil, fd >= 0 else { return }
  var a = stat(), b = stat()
  if fstat(fd, &a) == 0, stat(path, &b) == 0, a.st_nlink > 0, a.st_ino == b.st_ino, a.st_dev == b.st_dev { return }
  reattach(); handler()
 }
 private func reattach() {
  source?.cancel(); source = nil
  if !attach() { scheduleRetry() }
 }
 // The path may briefly not exist, or not exist yet: retry slowly until it does.
 private func scheduleRetry() {
  guard retry == nil else { return }
  let t = DispatchSource.makeTimerSource(queue: queue)
  t.schedule(deadline: .now() + 0.25, repeating: 1.0, leeway: .milliseconds(200))
  t.setEventHandler { [weak self] in
   guard let self, self.attach() else { return }
   self.retry?.cancel(); self.retry = nil
   self.handler()
  }
  retry = t; t.resume()
 }
}

// When tracked geometry needs reading at frame rate. Active from any kick until
// `quiet` seconds after the last kick or the last change in what was read; while
// not active a 10 Hz probe (one read per lifecycle tick) catches anything no precursor announced.
struct MotionGate {
 var quiet: TimeInterval = 0.5
 var probeEvery: TimeInterval = 0.09   // one read per lifecycle tick (10 Hz) catches motion nothing announced
 private(set) var activeUntil: TimeInterval = -.infinity
 private(set) var lastRead: TimeInterval = -.infinity
 private(set) var signature: Int?
 func isActive(_ now: TimeInterval) -> Bool { now < activeUntil }
 func shouldRead(_ now: TimeInterval) -> Bool { isActive(now) || now - lastRead >= probeEvery }
 mutating func kick(_ now: TimeInterval, hold: TimeInterval? = nil) { activeUntil = max(activeUntil, now + (hold ?? quiet)) }
 // Returns true when the read differs from the previous one (which also extends activity).
 @discardableResult mutating func observe(_ signature: Int, now: TimeInterval) -> Bool {
  lastRead = now
  let changed = signature != self.signature
  self.signature = signature
  if changed { kick(now) }
  return changed
 }
}
// Identity of what the tab bars depend on: the stacking order and frames of normal windows.
func geometrySignature(_ windows: [LiveWindow]) -> Int {
 var h = Hasher()
 for w in windows where w.layer == 0 { h.combine(w.id); h.combine(w.frame.origin.x); h.combine(w.frame.origin.y); h.combine(w.frame.size.width); h.combine(w.frame.size.height) }
 return h.finalize()
}

// Re-sampling policy for TabColorSampler: capture when the window id/size, the
// appearance or the group's membership/selection changed, plus a slow safety
// refresh and one settle capture after a change (the app repaints after the event).
struct SampleGate {
 var minInterval: TimeInterval = 1
 var settle: TimeInterval = 1.2
 var safety: TimeInterval = 45
 var retry: TimeInterval = 3
 var titleInterval: TimeInterval = 3
 private struct Stamp { var at: TimeInterval; var size: CGSize; var appearance: String; var key: Int; var titles: Int; var settleAt: TimeInterval? }
 private var stamps: [Int: Stamp] = [:]
 var count: Int { stamps.count }
 mutating func claim(id: Int, size: CGSize, appearance: String, key: Int, titles: Int = 0, have: Bool, now: TimeInterval) -> Bool {
  guard let s = stamps[id] else { stamps[id] = Stamp(at: now, size: size, appearance: appearance, key: key, titles: titles, settleAt: now + settle); return true }
  let age = now - s.at
  let changed = s.size != size || s.appearance != appearance || s.key != key
  // Page navigation changes titles (and often the toolbar colour); a title that animates must not capture every second.
  let retitled = s.titles != titles
  let due = (changed && age >= minInterval) || (retitled && age >= titleInterval) || (!have && age >= retry) || age >= safety || (s.settleAt.map { now >= $0 && age >= minInterval } ?? false)
  guard due else { return false }
  stamps[id] = Stamp(at: now, size: size, appearance: appearance, key: key, titles: titles, settleAt: changed ? now + settle : nil)   // title-only changes get no settle capture: a storm stays at one capture per titleInterval
  if stamps.count > 100 { stamps = stamps.filter { $0.key == id } }
  return true
 }
}
// CGPreflightScreenCaptureAccess is a TCC round trip; the answer changes rarely.
private var preflightCache: (value: Bool, at: TimeInterval)?
func screenCaptureAllowed(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
 if let c = preflightCache, now - c.at < (c.value ? 30 : 10) { return c.value }
 let v = CGPreflightScreenCaptureAccess(); preflightCache = (v, now); return v
}

// What the snapshot says about layout: ids, columns, focus, tab groups, display, visibility. Not titles or app names.
func snapshotLayoutSignature(_ snapshot: NavigatorSnapshot) -> Int {
 var h = Hasher()
 h.combine(snapshot.focused); h.combine(snapshot.display); h.combine(snapshot.tabsVisible)
 for e in snapshot.entries { h.combine(e.id); h.combine(e.column); h.combine(e.tabHeight); h.combine(e.selectedID) }
 return h.finalize()
}

final class LiveSignals {
 var gate = MotionGate()
 // Called on the main queue when a signal needs an immediate tick (and may start the display link).
 var onWake: (() -> Void)?
 private(set) var watching = false
 private var watchers: [FileWatcher] = []
 private var dirty = true
 private var lastFallback: TimeInterval = 0
 private var themeObserver: NSObjectProtocol?
 static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
 func watch(_ paths: [String]) {
  watching = true
  for path in paths {
   let w = FileWatcher(path: path) { [weak self] in self?.fileChanged() }
   watchers.append(w); w.start()
  }
 }
 // A write by itself is not motion (titles alone rewrite the snapshot several times a second): it marks
 // the files dirty and wakes one tick. Whether it was motion is decided in the tick, from what it contains.
 static let coalesce = 1.0 / 120
 private var wakeQueued = false
 private var lastWake: TimeInterval = -.infinity
 func fileChanged() { dirty = true; wake() }
 // Leading edge immediately, the rest of a burst folded into one trailing tick (several renames per
 // publish, title storms).
 func wake() {
  guard !wakeQueued else { return }
  let wait = lastWake + Self.coalesce - Self.now
  if wait <= 0 { lastWake = Self.now; onWake?(); return }
  wakeQueued = true
  DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
   guard let self else { return }
   self.wakeQueued = false; self.lastWake = Self.now; self.onWake?()
  }
 }
 // Called from tick(): a read and bar update happen once even if nothing moved, so titles re-render.
 private var readOnce = false
 private var layout: Int?
 func requestRead() { readOnce = true }
 func snapshotChanged(_ signature: Int) {
  readOnce = true
  if signature != layout { layout = signature; gate.kick(Self.now, hold: 0.5) }
 }
 // The intent file's action decides how long tracking is held: only a swipe's scroll intent (rewritten
 // once per wall-clock second) needs the long hold; mouse-down "dismiss" and "hide" need none.
 func intentSeen(_ action: String) {
  switch action {
  case "scroll", "swipe", "swiping", "lift": gate.kick(Self.now, hold: 1.3)   // swipe/swiping/lift: the contact intents main's engine writes; momentum follows a lift
  case "show", "row": gate.kick(Self.now, hold: 0.5)
  default: break
  }
 }
 // True when a watched file changed since the last call. Without watchers (tests) always true,
 // and a 2 s fallback covers a watcher that failed to attach.
 func takeFileChange() -> Bool {
  guard watching else { return true }
  let now = Self.now
  if dirty || now - lastFallback >= 2 {
   if !dirty { watchers.forEach { $0.verify() } }   // slow check that no watcher sits on a replaced inode
   dirty = false; lastFallback = now; return true
  }
  return false
 }
 func shouldRead() -> Bool { !watching || readOnce || gate.shouldRead(Self.now) }
 func observe(_ windows: [LiveWindow]) { readOnce = false; gate.observe(geometrySignature(windows), now: Self.now) }
 // A tab-colour capture finished: one tick to apply it, no tracking.
 func sampleReady() { readOnce = true; wake() }
 var motionActive: Bool { gate.isActive(Self.now) }
 func kick(hold: TimeInterval? = nil) { let was = motionActive; gate.kick(Self.now, hold: hold); if !was { onWake?() } }
 // Modifier and button state are readable without any permission, unlike key events.
 // Control+Option held (Hyper, fluid scroll) or a mouse button down precede window motion
 // that no file announces; poll them cheaply, never touching WindowServer.
 func armed() -> Bool {
  let f = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
  return (f.contains(.control) && f.contains(.option)) || NSEvent.pressedMouseButtons != 0
 }
 // One clock for everything periodic. No tab bars: 10 Hz, the pace Hyper-hold reveal and view-end
 // detection need (modifier state has no event source without Input Monitoring). Bars visible:
 // 30 Hz to catch Control+Option / mouse-down before the action key; the lifecycle tick still runs at 10 Hz.
 static let idleInterval = 0.1, barsInterval = 1.0 / 30
 private(set) var wakeCount = 0
 private var clock: DispatchSourceTimer?
 private var clockInterval = 0.0
 private var lifecycle: (() -> Void)?
 private var barsVisible: (() -> Bool)?
 // Cheap per-fire work while bars are visible (keeps the Hyper-hold keystroke baselines as fresh as a frame-rate tick did).
 var onFastFire: (() -> Void)?
 func startClock(barsVisible: @escaping () -> Bool, lifecycle: @escaping () -> Void) {
  guard clock == nil else { return }
  self.barsVisible = barsVisible; self.lifecycle = lifecycle
  let t = DispatchSource.makeTimerSource(queue: .main)
  t.setEventHandler { [weak self] in self?.fire() }
  clock = t; schedule(Self.idleInterval); t.resume()
  // An appearance switch repaints the sampled colours; the windows need a moment to redraw.
  themeObserver = DistributedNotificationCenter.default().addObserver(forName: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main) { [weak self] _ in self?.kick(hold: 2) }
 }
 private func schedule(_ interval: Double) {
  clockInterval = interval
  clock?.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(interval < 0.05 ? 8 : 10))
 }
 func fire() {
  wakeCount += 1
  let bars = barsVisible?() ?? false
  if bars {
   if armed() { kick() }
   onFastFire?()
   // 30 Hz clock: the lifecycle tick keeps its 10 Hz cadence.
   if wakeCount % 3 == 0 { lifecycle?() }
  } else { lifecycle?() }
  let want = (barsVisible?() ?? false) ? Self.barsInterval : Self.idleInterval
  if want != clockInterval { schedule(want) }
 }
 func stop() {
  watchers.forEach { $0.stop() }; watchers = []; clock?.cancel(); clock = nil; watching = false
  if let o = themeObserver { DistributedNotificationCenter.default().removeObserver(o); themeObserver = nil }
 }
}
