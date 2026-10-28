// Headless tests for the final-sweep tab bar fixes. Appended after src/main.swift (NAVIGATOR_TESTS) by tests/run.py.
// Real TabBars.update path with panels never ordered; no window is shown.
do {
 var n = 0
 func ok(_ c: @autoclosure () -> Bool, _ m: String) { precondition(c(), "tabfix: " + m); n += 1 }
 _ = NSApplication.shared
 guard let screen = NSScreen.screens.first, let number = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { fatalError("no screen") }
 let vf = screen.visibleFrame
 func snap(_ count: Int, focused: Int = 7001, titles: Bool = true) -> NavigatorSnapshot {
  let rows = (0..<count).map { "\(7000 + $0)\t1\tApp\($0)\ttest.microfish.app\($0)\t\(titles ? "Title \($0)" : "")\t34\t\(focused)" }
  return NavigatorSnapshot("\(focused)\t\(number)\n" + rows.joined(separator: "\n"))
 }
 func live(_ count: Int, _ w: CGRect) -> [LiveWindow] { (0..<count).map { LiveWindow(id: 7000 + $0, frame: w, layer: 0) } }
 let wide = CGRect(x: vf.minX + 200, y: vf.minY + 100, width: 640, height: 400)
 let narrow = CGRect(x: vf.minX + 200, y: vf.minY + 100, width: 300, height: 400)
 func strip(_ bars: TabBars) -> NSView { bars.stripView(column: 1)! }
 func tabCards(_ bars: TabBars) -> [ColumnCard] { (strip(bars).subviews.compactMap { $0 as? ColumnCard }).filter { $0.entryID > 0 }.sorted { $0.frame.minX < $1.frame.minX } }
 func elements(_ bars: TabBars) -> [NSAccessibilityElement] { (strip(bars).accessibilityChildren() ?? []).compactMap { $0 as? NSAccessibilityElement } }
 func customNames(_ e: NSAccessibilityElement) -> [String] { (e.accessibilityCustomActions() ?? []).map { $0.name } }

 // Pure helpers.
 ok(tabShowsTitle(labelWidth: 28) && !tabShowsTitle(labelWidth: 27.9), "title shown from 28 pt of label")
 ok(tabOverflowMenuTitle(app: "Safari", title: "") == "Safari", "empty title: app name only")
 ok(tabOverflowMenuTitle(app: "Safari", title: "Apple") == "Safari — Apple", "titled window keeps app — title")
 let long = String(repeating: "a", count: 40) + "MIDDLE" + String(repeating: "z", count: 80)
 let cut = tabOverflowMenuTitle(app: "Safari", title: long)
 ok(cut.hasPrefix("Safari — aaaa") && cut.hasSuffix("zzzz") && cut.contains("…") && !cut.contains("MIDDLE") && cut.count <= "Safari — ".count + 48, "long title cut in the middle: \(cut)")
 ok(middleTruncated("short", limit: 48) == "short" && middleTruncated("abcdefghij", limit: 5) == "ab…ij", "middleTruncated")
 ok(tabStripAccessibilityLabel(selectedName: "Safari — Apple", count: 3) == "Tabs: Safari — Apple, 3 windows", "strip label")

 // Narrow tabs: icon only, centred; wide tabs keep the title.
 do {
  let bars = TabBars(); bars.ordersPanels = false
  bars.update(snap(8), windows: live(8, narrow))
  let cards = tabCards(bars)
  ok(cards.count >= 2 && cards.count < 8, "narrow strip overflows: \(cards.count) tabs")
  for c in cards {
   ok(!c.subviews.contains { $0 is NSTextField }, "narrow tab \(c.entryID) has no title label")
   let icon = c.subviews.compactMap { $0 as? NSImageView }.first!
   ok(abs(icon.frame.midX - c.bounds.midX) <= 0.5, "narrow tab icon is centred: \(icon.frame.midX) vs \(c.bounds.midX)")
   ok(c.toolTip?.hasPrefix("App") == true && c.toolTip!.contains("Title"), "narrow tab keeps its name in the tooltip")
   ok(c.accessibilityLabel()?.hasPrefix("Title ") == true, "narrow tab keeps its VoiceOver label")
  }
  ok(elements(bars).first?.accessibilityLabel()?.hasPrefix("Title ") == true, "AX element label survives")
 }
 do {
  let bars = TabBars(); bars.ordersPanels = false
  bars.update(snap(3), windows: live(3, wide))
  ok(tabCards(bars).allSatisfy { c in c.subviews.contains { ($0 as? NSTextField)?.stringValue.hasPrefix("Title") == true } }, "wide tabs keep their title")
  let icon = tabCards(bars)[0].subviews.compactMap { $0 as? NSImageView }.first!
  ok(icon.frame.minX == 15, "wide tab icon stays at x=15")
 }

 // Accessibility: role description, strip label, help, custom actions that reuse reorder.
 do {
  let bars = TabBars(); bars.ordersPanels = false
  var drops: [StripDrop] = []
  bars.reorder = { drops.append($0) }
  bars.update(snap(3, focused: 7001), windows: live(3, wide))
  let els = elements(bars)
  ok(els.count == 3 && els.allSatisfy { $0.accessibilityRoleDescription() == "tab" }, "tabs are announced as tab")
  ok(strip(bars).accessibilityLabel() == "Tabs: App1 — Title 1, 3 windows", "strip label names the selection: \(strip(bars).accessibilityLabel() ?? "nil")")
  ok(els.allSatisfy { !($0.accessibilityHelp() ?? "").contains("Drag") && !($0.accessibilityHelp() ?? "").lowercased().contains("regroup") }, "no Drag in AX help")
  ok(customNames(els[0]) == ["Move Right", "Move to New Column"], "first tab: \(customNames(els[0]))")
  ok(customNames(els[1]) == ["Move Left", "Move Right", "Move to New Column"], "middle tab: \(customNames(els[1]))")
  ok(customNames(els[2]) == ["Move Left", "Move to New Column"], "last tab: \(customNames(els[2]))")
  func run(_ e: NSAccessibilityElement, _ name: String) { _ = e.accessibilityCustomActions()!.first { $0.name == name }!.handler!() }
  run(els[1], "Move Left"); ok(drops.last == StripDrop(kind: .tab, source: 7001, target: 7000, before: true), "Move Left = move-tab before the previous tab")
  run(els[1], "Move Right"); ok(drops.last == StripDrop(kind: .tab, source: 7001, target: 7002, before: false), "Move Right = move-tab after the next tab")
  run(els[1], "Move to New Column"); ok(drops.last == StripDrop(kind: .detach, source: 7001, target: 7000, before: false), "Move to New Column = detach-tab beside the rest of the group")
  ok(drops.last!.arguments == ["detach-tab", "7001", "after", "7000"], "detach arguments are the existing bridge command")
  ok(drops.count == 3, "each action sends exactly one command")
  for c in tabCards(bars) { ok(c.toolTip == "App\(c.entryID - 7000) — Title \(c.entryID - 7000)\nDrag to reorder, or drop it in the Minimap to move it to another Column.", "tooltip copy: \(c.toolTip ?? "nil")") }
  let labelled = NSApp.windows.compactMap { $0 as? NSPanel }.filter { $0.accessibilityLabel() == strip(bars).accessibilityLabel() }
  ok(!labelled.isEmpty && labelled.allSatisfy { !$0.canHide }, "tab bar panel cannot be hidden (\(labelled.count) found)")
 }
 // Untitled windows: tooltip and strip label fall back to the app name.
 do {
  let bars = TabBars(); bars.ordersPanels = false
  bars.update(snap(3, titles: false), windows: live(3, wide))
  ok(tabCards(bars).allSatisfy { !$0.toolTip!.contains(" — ") && $0.toolTip!.hasPrefix("App") }, "empty title: tooltip is the app name")
  ok(strip(bars).accessibilityLabel() == "Tabs: App1, 3 windows", "empty title: strip label is the app name")
 }
 // Overflow control: pull-down wiring and copy.
 do {
  let bars = TabBars(); bars.ordersPanels = false
  bars.update(snap(8), windows: live(8, narrow))
  let more = (strip(bars).subviews.compactMap { $0 as? ColumnCard }).first { $0.entryID == 0 && $0.diagnosticName.hasPrefix("tab overflow") }!
  ok(more.selectsOnPress && more.onSelect != nil, "overflow opens on press")
  ok(more.toolTip == "Show all tabs (8)", "overflow tooltip: \(more.toolTip ?? "nil")")
  let el = elements(bars).last!
  ok(el.accessibilityLabel() == "More tabs" && el.accessibilityHelp() == "Shows a menu of all 8 tabs" && el.accessibilityRole() == .button, "overflow AX")
  ok(el.accessibilityRoleDescription() != "tab" && customNames(el).isEmpty, "overflow is a button without tab actions")
 }
 print("Tab fix checks passed:", n)
}
