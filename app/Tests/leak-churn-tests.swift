// Headless churn test for the per-render NSKeyValueDependency leak (macOS 27). Appended after src/main.swift
// (NAVIGATOR_TESTS) by tests/run.py or tests/leak-churn.py. Every view lives in an unordered window or panel:
// nothing is ever shown. Counts NSKeyValueDependency objects with /usr/bin/heap before and after N cycles.
// Env: LEAK_N (cycles, default 120), LEAK_SCEN (comma list, default all), LEAK_MAX (allowed growth, default 12;
// pass LEAK_MAX=-1 to only print, as for the baseline that must show growth).
do {
 _ = NSApplication.shared
 let env = ProcessInfo.processInfo.environment
 let N = Int(env["LEAK_N"] ?? "") ?? 120
 let allowed = Int(env["LEAK_MAX"] ?? "") ?? 12
 let wanted = (env["LEAK_SCEN"] ?? "tabs,hud,map,failure").split(separator: ",").map(String.init)
 func dependencies() -> Int {
  let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/heap"); p.arguments = [String(getpid())]
  let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
  try! p.run()
  let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
  p.waitUntilExit()
  for line in out.split(separator: "\n") where line.contains(" NSKeyValueDependency ") {
   if let n = Int(line.split(separator: " ")[0]) { return n }
  }
  return 0
 }
 var failures: [String] = []
 defer { if env["LEAK_HOLD"] != nil { print("holding"); fflush(stdout); sleep(40) } }
 func scenario(_ name: String, _ cycle: (Int) -> Void) {
  guard wanted.contains(name) else { return }
  for i in 0..<60 { autoreleasepool { cycle(i) } }      // warm-up: one-time caches (icons, fonts, class setup)
  _ = dependencies()     // the first heap run itself allocates a few dependencies; settle that before measuring
  let before = dependencies()
  for i in 0..<N { autoreleasepool { cycle(i) } }
  let after = dependencies()
  let growth = after - before
  print("leak churn \(name): \(N) cycles, NSKeyValueDependency \(before) -> \(after) (+\(growth), \(String(format: "%.2f", Double(growth) / Double(N)))/cycle)")
  if allowed >= 0 && growth > allowed { failures.append("\(name) grew by \(growth) (allowed \(allowed))") }
 }
 guard let screen = NSScreen.screens.first, let number = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { fatalError("no screen") }
 let vf = screen.visibleFrame

 // 1. Tab bars: the real TabBars.update path (panels never ordered), three styles, content that changes every cycle.
 let bars = ["folder", "classic", "side"].map { style -> TabBars in let b = TabBars(); b.style = style; b.ordersPanels = false; return b }
 let appBundles = ["test.microfish.notes", "test.microfish.finder", "test.microfish.safari", "test.microfish.cal", "test.microfish.mail", "test.microfish.prev", "test.microfish.term", "test.microfish.maps"]
 func tabSnapshot(_ count: Int, focused: Int, salt: Int) -> NavigatorSnapshot {
  let rows = (0..<count).map { "\(5000 + $0)\t1\tApp\($0 % 8)\t\(appBundles[$0 % 8])\tDocument \($0) v\(salt)\t34\t\(5000 + focused)" }
  return NavigatorSnapshot("\(5000 + focused)\t\(number)\n" + rows.joined(separator: "\n"))
 }
 let tabWindow = CGRect(x: vf.minX + 200, y: vf.minY + 200, width: 640, height: 400)
 scenario("tabs") { i in
  let count = [3, 5, 12, 2, 9][i % 5]
  let snap = tabSnapshot(count, focused: i % count, salt: i)
  let live = (0..<count).map { LiveWindow(id: 5000 + $0, frame: tabWindow, layer: 0) }
  for b in bars { b.update(snap, windows: live) }
 }

 // 2. Minimap HUD: Navigator.render with alternating content (cards, groups with badges, +N icons, empty rows,
 //    a scrolling lane, a taller-than-screen stack). The panel is unordered.
 let nav = Navigator(path: "/tmp/none.tsv")
 nav.panel = StripPanel(contentRect: CGRect(x: -20000, y: -20000, width: 10, height: 10), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
 nav.ordersPanel = false
 func hudContent(_ variant: Int) -> String {
  var s = "102\t\(number)\n"
  let cols = [3, 7, 1, 30][variant % 4]
  for c in 1...cols {
   let group = (variant % 4 == 1 && c % 2 == 0) ? 3 : 1
   for g in 0..<group {
    s += "\(100 + c * 10 + g)\t\(c)\tApp\((c + g + variant) % 8)\t\(appBundles[(c + g + variant) % 8])\tTitle \(c).\(g) v\(variant)\t\(group > 1 ? 28 : 0)\t\(100 + c * 10)\n"
   }
  }
  let rowCount = [4, 2, 12, 5][variant % 4]
  s += "#rows\t1\t\(rowCount)\nspatialmeta\t1\t0\t0\t1200\t900\t102\n"
  for r in 1...rowCount { s += "spatialrow\t\(r)\n" }
  for r in 2...max(2, rowCount) where r % 3 != 0 {
   for c in 1...(1 + (r + variant) % 4) {
    s += "spatial\t\(r)\t\(c)\t\(r * 1000 + c)\t0\t0\t600\t900\t0\t\(r * 1000 + c)\t\(["Terminal", "Notes", "Calendar", "Safari"][c % 4])\t\(appBundles[(r + c) % 8])\tWin \(r).\(c)\n"
   }
  }
  return s
 }
 let styles = ["cards", "compact", "titles"]
 scenario("hud") { i in
  nav.preferences.style = styles[(i / 4) % 3]
  nav.pressingCard = false; nav.lastRenderSig = nil
  nav.render(hudContent(i))
 }

 // 3. Window-map popover content: built the way the controller builds it on every open, snapshot updated, torn down.
 let mapWindow = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 900, height: 900), styleMask: [.borderless], backing: .buffered, defer: true)
 func mapSnapshot(_ variant: Int) -> SpatialSnapshot {
  var s = "spatialmeta\t2\t0\t0\t1200\t900\t21\nspatialrow\t1\nspatialrow\t2\nspatialrow\t3\n"
  for c in 0..<(2 + variant % 4) { s += "spatial\t2\t\(c)\t\(20 + c)\t\(c * 600)\t0\t600\t900\t0\t\(20 + c)\tEditor\tcom.apple.TextEdit\tDocument \(c) v\(variant)\n" }
  return SpatialSnapshot(s)
 }
 let mapHost = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 900))   // permanent, like the popover's own views
 mapWindow.contentView = mapHost
 scenario("map") { i in
  #if LEAK_NEWAPI
  let root = SpatialContentView.make(snapshot: mapSnapshot(i), available: NSSize(width: 900, height: 900))
  #else
  let root = SpatialContentView(snapshot: mapSnapshot(i), available: NSSize(width: 900, height: 900))
  #endif
  mapHost.addSubview(root)
  if env["LEAK_NOLAYOUT"] == nil { root.layoutSubtreeIfNeeded() }
  root.refreshButton.isEnabled = (i % 2 == 0)
  if env["LEAK_NOUPDATE"] == nil { root.mapView.update(mapSnapshot(i + 1)) }
  root.message = i % 2 == 0 ? "Refreshing windows…" : SpatialContentView.defaultMessage
  #if LEAK_NEWAPI
  root.removeFromSuperview()      // closing the popover detaches its content
  SpatialContentView.recycle(root)
  #else
  root.removeFromSuperview()
  #endif
 }

 let liveContent = SpatialContentView(snapshot: mapSnapshot(0), available: NSSize(width: 900, height: 900))
 mapHost.addSubview(liveContent)
 scenario("map_update") { i in
  liveContent.mapView.update(mapSnapshot(i))
  liveContent.layoutSubtreeIfNeeded()
 }
 scenario("map_update_nolayout") { i in
  liveContent.mapView.update(mapSnapshot(i))
 }
 // 4. Command-failure HUD, shown for each rejected command.
 let failureWindow = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 340, height: 62), styleMask: [.borderless], backing: .buffered, defer: true)
 scenario("failure") { i in
  let width: CGFloat = i % 2 == 0 ? 340 : 280
  #if LEAK_NEWAPI
  let hud = nav.failureView(action: i % 2 == 0 ? "focus" : "move", diagnostic: "diagnostic \(i)", width: width)
  #else
  let hud = makeFailureHUD(action: i % 2 == 0 ? "focus" : "move", diagnostic: "diagnostic \(i)", width: width)
  #endif
  failureWindow.contentView = hud
  failureWindow.contentView = NSView()
 }
 if !failures.isEmpty { print("leak churn FAILED: " + failures.joined(separator: "; ")); exit(1) }
 print("leak churn passed (growth bound \(allowed))")
}
