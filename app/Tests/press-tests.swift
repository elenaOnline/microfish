// Headless tests: folder tabs select on mouse-down. Appended after src/main.swift (NAVIGATOR_TESTS) by tests/run.py.
// Real TabBars.update path with panels never ordered (ordersPanels=false); synthetic NSEvents; no window is shown.
// The overflow menu is never opened (pressing "..." would pop a menu), so overflow is checked by its wiring only.
do {
 var n = 0
 func ok(_ c: @autoclosure () -> Bool, _ m: String) { precondition(c(), "press: " + m); n += 1 }
 _ = NSApplication.shared
 func ev(_ t: NSEvent.EventType, _ p: CGPoint, _ flags: NSEvent.ModifierFlags = [], button: Int = 0) -> NSEvent {
  NSEvent.mouseEvent(with: t, location: p, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
 }
 guard let screen = NSScreen.screens.first, let number = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { print("press: no screen, skipped"); fatalError("no screen") }
 let vf = screen.visibleFrame
 func snap(_ count: Int, focused: Int = 7001) -> NavigatorSnapshot {
  let rows = (0..<count).map { "\(7000 + $0)\t1\tApp\($0)\ttest.microfish.app\($0)\tTitle \($0)\t34\t\(focused)" }
  return NavigatorSnapshot("\(focused)\t\(number)\n" + rows.joined(separator: "\n"))
 }
 func live(_ count: Int, _ w: CGRect) -> [LiveWindow] { (0..<count).map { LiveWindow(id: 7000 + $0, frame: w, layer: 0) } }
 let wide = CGRect(x: vf.minX + 200, y: vf.minY + 100, width: 640, height: 400)
 let narrow = CGRect(x: vf.minX + 200, y: vf.minY + 100, width: 300, height: 400)

 final class Rig {
  let bars = TabBars()
  var focused: [Int] = []
  var dropped: [(Int, Bool)] = []   // dragOutside(source, commit)
  var reordered = 0, finished = 0
  init() {
   bars.ordersPanels = false
   bars.focus = { [unowned self] in focused.append($0) }
   bars.dragOutside = { [unowned self] source, _, commit in dropped.append((source, commit)); return false }
   bars.reorder = { [unowned self] _ in reordered += 1 }
   bars.dragFinished = { [unowned self] in finished += 1 }
  }
  func cards() -> [ColumnCard] { (bars.stripView(column: 1)?.subviews.compactMap { $0 as? ColumnCard } ?? []).sorted { $0.frame.minX < $1.frame.minX } }
  func card(_ id: Int) -> ColumnCard { cards().first { $0.entryID == id }! }
  func tabs() -> [ColumnCard] { cards().filter { $0.entryID > 0 } }
 }
 var mid = CGPoint(x: 20, y: 15)
 func use(_ c: ColumnCard) -> ColumnCard { mid = c.convert(NSPoint(x: c.bounds.midX, y: c.bounds.midY), to: nil); return c }
 func away(_ dx: CGFloat) -> CGPoint { CGPoint(x: mid.x + dx, y: mid.y) }

 // 1. Plain press selects on mouse-down; release does not focus again.
 do {
  let r = Rig(); r.bars.update(snap(3), windows: live(3, wide))
  let c = use(r.card(7002))
  ok(c.selectsOnPress && c.onSelect != nil, "tab cards select on press")
  c.mouseDown(with: ev(.leftMouseDown, mid))
  ok(r.focused == [7002], "focus sent on mouse-down, before any release: \(r.focused)")
  ok(r.bars.stripView(column: 1) != nil, "bar still there")
  c.mouseUp(with: ev(.leftMouseUp, mid))
  ok(r.focused == [7002], "release without drag sends no second focus: \(r.focused)")
  ok(r.dropped.isEmpty && r.reordered == 0, "no drag callbacks on a click")
  // A second ordinary click selects again exactly once.
  c.mouseDown(with: ev(.leftMouseDown, mid)); c.mouseUp(with: ev(.leftMouseUp, mid))
  ok(r.focused == [7002, 7002], "each press focuses once")
  // Release outside the card after a sub-threshold slide: still one focus (from down), no click.
  c.mouseDown(with: ev(.leftMouseDown, mid)); c.mouseDragged(with: ev(.leftMouseDragged, away(2)))
  c.mouseUp(with: ev(.leftMouseUp, away(2)))
  ok(r.focused == [7002, 7002, 7002], "small jitter press: one focus")
 }
 // 2. Press that becomes a drag: dragged tab stays selected, no focus on the drop target, no stray focus.
 do {
  let r = Rig(); r.bars.update(snap(3), windows: live(3, wide))
  let c = use(r.card(7002))
  c.mouseDown(with: ev(.leftMouseDown, mid))
  c.mouseDragged(with: ev(.leftMouseDragged, away(70)))
  c.mouseDragged(with: ev(.leftMouseDragged, away(140)))
  ok(r.focused == [7002], "focus is the dragged tab during the drag: \(r.focused)")
  ok(r.dropped.count >= 2 && r.dropped.allSatisfy { $0.0 == 7002 && !$0.1 }, "drag callbacks carry the dragged tab")
  c.mouseUp(with: ev(.leftMouseUp, away(140)))
  ok(r.focused == [7002], "drop focuses nothing (not the dragged tab again, not the target): \(r.focused)")
  ok(r.dropped.last! == (7002, true), "drop committed for the dragged tab")
  ok(r.finished == 1, "drag finished once")
  // The press that followed the drag is a clean one.
  c.mouseDown(with: ev(.leftMouseDown, mid)); c.mouseUp(with: ev(.leftMouseUp, mid))
  ok(r.focused == [7002, 7002], "next click after a drag behaves normally")
 }
 // 3. Escape (cancelInteraction) mid-drag: dragged tab stays the selection, no extra focus, release is inert.
 do {
  let r = Rig(); r.bars.update(snap(3), windows: live(3, wide))
  let c = use(r.card(7001))
  c.mouseDown(with: ev(.leftMouseDown, mid))
  c.mouseDragged(with: ev(.leftMouseDragged, away(70)))
  c.cancelInteraction()
  c.mouseUp(with: ev(.leftMouseUp, away(70)))
  ok(r.focused == [7001], "cancelled drag leaves the dragged tab selected, nothing else: \(r.focused)")
  ok(!r.dropped.contains { $0.1 }, "cancelled drag never commits")
  ok(r.finished >= 1, "cancel ends the drag")
  // Cancel during a plain press (no drag): release after cancel sends nothing more.
  let d = use(r.card(7000)); d.mouseDown(with: ev(.leftMouseDown, mid)); d.cancelInteraction(); d.mouseUp(with: ev(.leftMouseUp, mid))
  ok(r.focused == [7001, 7000], "press then cancel then release: one focus, from the press")
 }
 // 4. Overflow: the "..." card is a pull-down, so it opens its menu on press (like a native pop-up button).
 // The menu is never opened here (tracking is modal), so this checks the wiring and that nothing is focused.
 do {
  let r = Rig(); r.bars.update(snap(8), windows: live(8, narrow))
  let more0 = (r.bars.stripView(column: 1)?.subviews.compactMap { $0 as? ColumnCard } ?? []).first { $0.entryID == 0 && $0.diagnosticName.hasPrefix("tab overflow") }!
  let more = use(more0)
  ok(more.selectsOnPress && more.onSelect != nil && more.onClick != nil, "overflow card opens its menu on press (and keeps the release/VoiceOver path)")
  ok(r.focused.isEmpty, "nothing focused by the overflow control")
  more.cancelInteraction()
  ok(r.focused.isEmpty, "cancelled overflow press focuses nothing")
  // Menu selection path is unchanged: selectMenu focuses the item's tag.
  ok(r.tabs().count < 8 && r.tabs().allSatisfy { $0.selectsOnPress }, "visible tabs select on press, overflow set unchanged")
 }
 // 5. Secondary / modifier / Hyper / other buttons keep act-on-release exactly as before.
 do {
  let r = Rig(); r.bars.update(snap(3), windows: live(3, wide))
  let c = use(r.card(7002))
  // Plain secondary click: never a focus.
  c.rightMouseDown(with: ev(.rightMouseDown, mid)); c.rightMouseUp(with: ev(.rightMouseUp, mid))
  ok(r.focused.isEmpty, "right-click focuses nothing")
  // Control-click arrives as a secondary event with only Control: same.
  c.rightMouseDown(with: ev(.rightMouseDown, mid, [.control])); c.rightMouseUp(with: ev(.rightMouseUp, mid, [.control]))
  ok(r.focused.isEmpty, "control-click (secondary) focuses nothing")
  // Middle button: not handled.
  c.otherMouseDown(with: ev(.otherMouseDown, mid)); c.otherMouseUp(with: ev(.otherMouseUp, mid))
  ok(r.focused.isEmpty, "other buttons focus nothing")
  // Hyper secondary route: no focus on down, one on up.
  let hyper: NSEvent.ModifierFlags = [.control, .option, .command]
  c.rightMouseDown(with: ev(.rightMouseDown, mid, hyper))
  ok(r.focused.isEmpty, "Hyper-click does not select on press")
  c.rightMouseUp(with: ev(.rightMouseUp, mid, hyper))
  ok(r.focused == [7002], "Hyper-click focuses once, on release (unchanged)")
  r.focused = []
  // Hyper on the primary button: a modifier-click, release.
  c.mouseDown(with: ev(.leftMouseDown, mid, hyper)); ok(r.focused.isEmpty, "Hyper primary press waits")
  c.mouseUp(with: ev(.leftMouseUp, mid, hyper)); ok(r.focused == [7002], "Hyper primary click focuses once on release")
  r.focused = []
  for flags: NSEvent.ModifierFlags in [[.shift], [.command], [.option], [.control], [.shift, .command]] {
   let before = r.focused.count
   c.mouseDown(with: ev(.leftMouseDown, mid, flags)); ok(r.focused.count == before, "modifier \(flags.rawValue) press waits")
   c.mouseUp(with: ev(.leftMouseUp, mid, flags))
  }
  ok(r.focused == [7002, 7002, 7002, 7002, 7002], "modifier-clicks focus once each, on release (unchanged): \(r.focused)")
  // Caps lock alone is not a modifier-click.
  r.focused = []
  c.mouseDown(with: ev(.leftMouseDown, mid, [.capsLock])); ok(r.focused == [7002], "caps lock does not defeat select-on-press")
  c.mouseUp(with: ev(.leftMouseUp, mid, [.capsLock])); ok(r.focused == [7002], "and does not double it")
  // VoiceOver press, and the card-level press hook, still focus once via onClick.
  r.focused = []
  let tabs = (r.bars.stripView(column: 1)?.accessibilityChildren() ?? []).compactMap { $0 as? NSAccessibilityElement }
  ok(tabs[0].accessibilityPerformPress() && r.focused == [7000], "VoiceOver press focuses once")
 }
 // 6. Cards that did not opt in (minimap cards, map-like buttons) keep act-on-release.
 do {
  let card = ColumnCard(frame: CGRect(x: 0, y: 0, width: 100, height: 50))
  var clicks = 0, presses = 0
  card.onClick = { clicks += 1 }; card.onPress = { if $0 { presses += 1 } }
  _ = use(card)
  ok(!card.selectsOnPress, "default is release")
  card.mouseDown(with: ev(.leftMouseDown, mid)); ok(clicks == 0 && presses == 1, "no click on down")
  card.mouseUp(with: ev(.leftMouseUp, mid)); ok(clicks == 1, "click on up")
  card.onSelect = { clicks += 100 }   // onSelect alone, without the flag, does nothing
  card.mouseDown(with: ev(.leftMouseDown, mid)); card.mouseUp(with: ev(.leftMouseUp, mid)); ok(clicks == 2, "flag required for select-on-press")
  // A selecting card with no onSelect behaves as before.
  let plain = ColumnCard(frame: CGRect(x: 0, y: 0, width: 100, height: 50)); plain.selectsOnPress = true
  _ = use(plain)
  var pc = 0; plain.onClick = { pc += 1 }
  plain.mouseDown(with: ev(.leftMouseDown, mid)); plain.mouseUp(with: ev(.leftMouseUp, mid)); ok(pc == 1, "no onSelect: click on release")
  // Accessibility press of an exposed card is unchanged.
  let ax = ColumnCard(frame: .zero); ax.exposedAsButton = true; var ac = 0; ax.onClick = { ac += 1 }
  ok(ax.accessibilityPerformPress() && ac == 1, "exposed card AX press clicks")
 }
 // 7. Bars do not rebuild while pressed; stale-press recovery still works; the selection catches up on release.
 do {
  let r = Rig(); r.bars.update(snap(3, focused: 7000), windows: live(3, wide))
  // The strip and its cards are permanent (view reuse), so a rebuild shows as the selected face moving between cards.
  func selectedTab() -> Int? { r.cards().first { card in card.subviews.contains { ($0 as? FolderTabFace)?.selected == true } }?.entryID }
  let before = r.cards()
  let c = use(r.card(7002))
  c.mouseDown(with: ev(.leftMouseDown, mid))
  r.bars.update(snap(3, focused: 7002), windows: live(3, wide))   // the engine answered the focus
  ok(selectedTab() == 7000 && zip(before, r.cards()).allSatisfy { $0 === $1 }, "no rebuild while the press is held")
  c.mouseUp(with: ev(.leftMouseUp, mid))
  r.bars.update(snap(3, focused: 7002), windows: live(3, wide))
  ok(selectedTab() == 7002, "rebuilt after release with the new selection")
  ok(r.focused == [7002], "still exactly one focus")
  // Lost mouse-up: stale recovery unwinds the press and a drag; the next press is clean.
  let r2 = Rig(); r2.bars.update(snap(3), windows: live(3, wide))
  let d = use(r2.card(7001))
  d.mouseDown(with: ev(.leftMouseDown, mid)); d.mouseDragged(with: ev(.leftMouseDragged, away(70)))
  r2.bars.backdatePress(column: 1, by: 5)
  if NSEvent.pressedMouseButtons == 0 {
   r2.bars.update(snap(3, focused: 7001), windows: live(3, wide))
   ok(r2.finished >= 1, "stale press ends the in-flight drag")
   let e = use(r2.card(7001))
   e.mouseDown(with: ev(.leftMouseDown, mid)); e.mouseUp(with: ev(.leftMouseUp, mid))
   ok(r2.focused == [7001, 7001], "after recovery each press focuses once: \(r2.focused)")
  }
 }
 // 8. Every focus path logs through the same hook: select-on-press cards call bars.focus, nothing else.
 do {
  let r = Rig(); r.bars.update(snap(3), windows: live(3, wide))
  var otherClicks = 0
  let c = use(r.card(7001)); let original = c.onClick
  c.onClick = { otherClicks += 1; original?() }
  c.mouseDown(with: ev(.leftMouseDown, mid)); c.mouseUp(with: ev(.leftMouseUp, mid))
  ok(otherClicks == 0 && r.focused == [7001], "primary click never goes through onClick")
 }

 // Mouse follows focus: the engine warps the pointer on focus, so tabs keep selecting on release.
 do {
  let prefs = NavigatorPreferences(#"{"mouseFollowsFocus":true}"#.data(using:.utf8))
  ok(prefs.mouseFollowsFocus && !NavigatorPreferences(nil).mouseFollowsFocus, "mouseFollowsFocus parsed, default off")
  let r = Rig(); r.bars.selectOnPress = false; r.bars.update(snap(3), windows: live(3, wide))
  let c = use(r.card(7002))
  ok(!c.selectsOnPress, "cards built with selectOnPress=false do not select on press")
  c.mouseDown(with: ev(.leftMouseDown, mid))
  ok(r.focused.isEmpty, "no focus on press while mouse follows focus: \(r.focused)")
  c.mouseUp(with: ev(.leftMouseUp, mid))
  ok(r.focused == [7002], "focus on release while mouse follows focus: \(r.focused)")
  r.bars.selectOnPress = true; r.bars.update(snap(3), windows: live(3, wide))
  ok(r.card(7002).selectsOnPress, "turning the setting off rebuilds cards that select on press")
 }
 print("Tab press (select on mouse-down) checks passed: \(n)")
}
