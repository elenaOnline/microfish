// Offscreen HUD renders for old/new pixel diffs; argv[1] is the output directory. Never shows a window.
// The same fixtures are built three ways: a plain makeRowsHUD call (both trees), and, with -D LEAK_NEWAPI, through a
// HUDKit that has already built other content and been reclaimed, which is what Navigator.render does.
_ = NSApplication.shared
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp"
var written = 0
func fixtureA() -> String {
 var s = "102\t1\n102\t2\tSafari\tcom.apple.Safari\tStart\t0\t102\n103\t3\tFinder\tcom.apple.finder\tHome\t28\t103\n104\t3\tMail\tcom.apple.mail\tInbox\t28\t103\n#rows\t1\t4\nspatialmeta\t1\t0\t0\t1200\t900\t102\n"
 for row in 1...4 { s += "spatialrow\t\(row)\n" }
 s += "spatial\t2\t1\t201\t0\t0\t600\t900\t0\t201\tTerminal\tcom.apple.Terminal\tShell\nspatial\t2\t2\t202\t600\t0\t600\t900\t0\t202\tNotes\tcom.apple.Notes\tList\nspatial\t3\t1\t301\t0\t0\t600\t900\t0\t301\tCalendar\tcom.apple.iCal\tWeek\n"
 return s
}
// Many apps in one column (+N icon overflow, count badge), a wide current row (scrolling lane), empty rows.
func fixtureB() -> String {
 var s = "110\t1\n"
 let bundles = ["com.apple.Safari", "com.apple.finder", "com.apple.mail", "com.apple.Notes", "com.apple.iCal", "com.apple.Terminal", "com.apple.TextEdit", "com.apple.Maps"]
 for c in 1...14 { for g in 0..<(c == 3 ? 7 : (c % 4 == 0 ? 2 : 1)) { s += "\(100 + c * 10 + g)\t\(c)\tApp\(g)\t\(bundles[(c + g) % 8])\tWindow \(c).\(g)\t\(c == 3 || c % 4 == 0 ? 28 : 0)\t\(100 + c * 10)\n" } }
 s += "#rows\t1\t5\nspatialmeta\t1\t0\t0\t1200\t900\t110\n"
 for row in 1...5 { s += "spatialrow\t\(row)\n" }
 for c in 1...3 { s += "spatial\t3\t\(c)\t\(300 + c)\t0\t0\t600\t900\t0\t\(300 + c)\tNotes\tcom.apple.Notes\tList \(c)\n" }
 return s
}
// Taller than the screen: vertical scrolling, compact cards.
func fixtureC() -> String {
 var s = "102\t1\n102\t2\tActive\ta\tCurrent\t0\t102\n#rows\t5\t9\nspatialmeta\t5\t0\t0\t320\t600\t102\n"
 for row in 1...9 {
  s += "spatialrow\t\(row)\n"
  if row != 5 && row != 9 { for col in 1...6 { s += "spatial\t\(row)\t\(col)\t\(row * 100 + col)\t0\t0\t100\t100\t0\t0\tApp\(row)-\(col)\tcom.apple.Notes\tWindow\n" } }
 }
 return s
}
let screen = CGRect(x: 0, y: 0, width: 1512, height: 949)
let narrow = CGRect(x: 0, y: 0, width: 360, height: 400)
func save(_ view: NSView, _ name: String, _ dark: Bool) {
 view.appearance = NSAppearance(named: dark ? .vibrantDark : .vibrantLight)
 view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
 let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!; view.cacheDisplay(in: view.bounds, to: rep)
 try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(outDir)/\(name).png")); written += 1
 writeDescription(view, "\(outDir)/\(name).txt")
}
func focused(_ text: String) -> Int { NavigatorSnapshot(text).focused }
for style in ["cards", "compact", "titles"] { for dark in [false, true] {
 let app = NSAppearance(named: dark ? .darkAqua : .aqua)!
 let nav = Navigator(path: "/tmp/none.tsv"); nav.preferences.style = style
 nav.preferences.aliases = ["com.apple.Safari\tStart": "Renamed start"]
 for (name, fixture, visible, viewing) in [("A", fixtureA(), screen, nil), ("B", fixtureB(), screen, nil), ("B-viewing", fixtureB(), screen, 4), ("C", fixtureC(), narrow, 2)] as [(String, String, CGRect, Int?)] {
  let tag = "hud-\(style)-\(dark ? "dark" : "light")-\(name)"
  save(nav.makeRowsHUD(HUDRows(fixture)!, focused: focused(fixture), viewing: viewing, visible: visible, appearance: app), tag, dark)
  #if LEAK_NEWAPI
  // Reused kit: other content first (all three fixtures, alternating styles), reclaim, then this fixture.
  let kit = HUDKit()
  let navDirty = Navigator(path: "/tmp/none.tsv"); navDirty.preferences.style = style == "cards" ? "titles" : "cards"
  for dirty in [fixtureB(), fixtureC(), fixtureA()] {
   _ = navDirty.makeRowsHUD(HUDRows(dirty)!, focused: focused(dirty), viewing: 2, visible: dirty == fixtureC() ? narrow : screen, appearance: app, kit: kit)
   kit.reclaim()
  }
  nav.preferences.aliases = ["com.apple.Safari\tStart": "Renamed start"]
  save(nav.makeRowsHUD(HUDRows(fixture)!, focused: focused(fixture), viewing: viewing, visible: visible, appearance: app, kit: kit), tag + "-REUSED", dark)
  kit.reclaim()
  #endif
 }
 // The command-failure HUD.
 save(makeFailureHUD(action: "focus", diagnostic: "test", appearance: app), "failure-\(dark ? "dark" : "light")-focus", dark)
 save(makeFailureHUD(action: "move", diagnostic: "another", width: 280, appearance: app), "failure-\(dark ? "dark" : "light")-move", dark)
 #if LEAK_NEWAPI
 let n2 = Navigator(path: "/tmp/none.tsv")
 _ = n2.failureView(action: "move", diagnostic: "first", width: 300)
 let reused = n2.failureView(action: "focus", diagnostic: "test", width: 340)
 // makeFailureHUD takes its appearance from the caller; the reused one from NSApp. Match for the comparison.
 NSApp.appearance = app
 let again = n2.failureView(action: "focus", diagnostic: "test", width: 340)
 save(again, "failure-\(dark ? "dark" : "light")-focus-REUSED", dark)
 _ = reused
 NSApp.appearance = nil
 #endif
}}
print("rendered", written)
