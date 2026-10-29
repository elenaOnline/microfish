// Offscreen renders of every tab-face state and whole strips, for old/new pixel diffs. Same code builds against both
// source trees. Each strip is rendered after the bar has already been rebuilt with other content, so a pooled view
// that kept stale state would show. Argv[1]: output directory. Never shows a window.
_ = NSApplication.shared
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/tabs-render"
try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
var written = 0
func renderFace(_ name: String, style: String, dark: Bool, selected: Bool, first: Bool, last: Bool, matched: NSColor?, extra: (FolderTabFace) -> Void = { _ in }) throws {
 let w = 110, h = style == "side" ? 60 : 35
 let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w * 2, pixelsHigh: h * 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
 rep.size = NSSize(width: w, height: h)
 let face = FolderTabFace(frame: CGRect(x: 0, y: 0, width: w, height: h))
 let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
 face.appearance = appearance; face.style = style; face.selected = selected; face.first = first; face.last = last; face.matchedColor = matched
 extra(face)
 NSGraphicsContext.saveGraphicsState()
 NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
 appearance.performAsCurrentDrawingAppearance { face.draw(face.bounds) }
 NSGraphicsContext.restoreGraphicsState()
 try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outDir + "/" + name + ".png")); written += 1
}
for style in ["folder", "folder-compact", "classic", "side"] {
 for dark in [false, true] {
  for selected in [false, true] {
   for (first, last) in [(false, false), (true, false), (false, true)] {
    for matched in [nil, NSColor(srgbRed: 0.95, green: 0.9, blue: 0.8, alpha: 1)] {
     try renderFace("\(style)-\(dark ? "dark" : "light")-\(selected ? "sel" : "unsel")-\(first ? "F" : "")\(last ? "L" : "")-\(matched == nil ? "plain" : "matched")", style: style, dark: dark, selected: selected, first: first, last: last, matched: matched)
    }
   }
  }
#if TABS_NEWAPI
  for selected in [false, true] {
   try renderFace("folder-\(dark ? "dark" : "light")-\(selected ? "sel" : "unsel")-INCREASE-CONTRAST", style: "folder", dark: dark, selected: selected, first: false, last: false, matched: nil) { $0.increaseContrast = true }
   try renderFace("folder-\(dark ? "dark" : "light")-\(selected ? "sel" : "unsel")-REDUCE-TRANSPARENCY", style: "folder", dark: dark, selected: selected, first: false, last: false, matched: nil) { $0.reduceTransparency = true }
  }
#endif
 }
}
// --- Whole strips built by the real TabBars.update path (panels are never ordered on screen).
func renderStrips() throws {
 guard let screen = NSScreen.screens.first, let number = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { return }
 let vf = screen.visibleFrame
 func entries(_ n: Int) -> String {
  // Unresolvable bundle ids: the generic app icon is drawn, avoiding Launch Services' asynchronous icon loading (non-deterministic pixels).
  let apps = [("Notes", "test.microfish.notes"), ("Finder", "test.microfish.finder"), ("Safari", "test.microfish.safari"), ("Calendar", "test.microfish.cal"), ("Mail", "test.microfish.mail"), ("Preview", "test.microfish.prev"), ("Terminal", "test.microfish.term"), ("Maps", "test.microfish.maps")]
  return (0..<n).map { "\(5000 + $0)\t1\t\(apps[$0 % 8].0)\t\(apps[$0 % 8].1)\tDocument \($0)\t34\t5001" }.joined(separator: "\n")
 }
 for (style, height) in [("folder", 34.0), ("folder", 28.0), ("folder-compact", 34.0), ("classic", 34.0), ("side", 34.0)] {
  for dark in [false, true] {
   for count in [3, 9, 14] {
    NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    let bars = TabBars(); bars.style = style; bars.height = CGFloat(height); bars.ordersPanels = false
    bars.aliases = ["test.microfish.notes\tDocument 0": "Renamed"]
    let snap = NavigatorSnapshot("5001\t\(number)\n" + entries(count))
    let window = CGRect(x: vf.minX + 200, y: vf.minY + 100, width: 640, height: 400)
    let live = (0..<count).map { LiveWindow(id: 5000 + $0, frame: window, layer: 0) }
    // Dirty the bar first: many tabs with overflow and a late selection, then very few, other titles.
    for (n, focus) in [(12, 11), (2, 1)] {
     let dirty = NavigatorSnapshot("\(5000 + focus)\t\(number)\n" + entries(n).replacingOccurrences(of: "Document", with: "Other"))
     bars.update(dirty, windows: (0..<n).map { LiveWindow(id: 5000 + $0, frame: window, layer: 0) })
    }
    bars.update(snap, windows: live)
    guard let strip = bars.stripView(column: 1), let content = strip.superview else { print("no strip", style); continue }
    content.layoutSubtreeIfNeeded()
    let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds)!
    content.cacheDisplay(in: content.bounds, to: rep)
    let name = "STRIP-\(style)-\(Int(height))-\(dark ? "dark" : "light")-\(count)"
    writeDescription(content, outDir + "/" + name + ".txt")
    try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outDir + "/" + name + ".png")); written += 1
   }
  }
 }
 NSApp.appearance = nil
}
try renderStrips()
print("rendered", written)
