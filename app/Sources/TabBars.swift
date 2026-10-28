import AppKit
import QuartzCore
import ScreenCaptureKit

struct NavigatorSnapshot {
 let focused: Int
 let display: UInt32
 let tabsVisible: Bool
 let entries: [Entry]
 let tabGroups: [Int: [Entry]]
 init(_ text: String) {
  let lines = text.components(separatedBy: "\n")
  let header = lines.first?.components(separatedBy: "\t") ?? []
  tabsVisible = header.count < 3 || header[2] != "0"
  focused = header.first.flatMap(Int.init) ?? 0
  display = header.count > 1 ? UInt32(header[1]) ?? 0 : 0
  let parsed: [Entry] = lines.dropFirst().compactMap { line in
   let f = line.components(separatedBy: "\t")
   guard f.count >= 5, let id = Int(f[0]), id > 0, let column = Int(f[1]) else { return nil }
   return Entry(id: id, column: column, app: f[2], bundle: f[3], title: f[4], tabHeight: f.count > 5 ? Int(f[5]) ?? 0 : 0, selectedID: f.count > 6 ? Int(f[6]) ?? 0 : 0)
  }
  entries = parsed
  tabGroups = Dictionary(grouping: parsed, by: { $0.column }).filter { _, group in
   group.count >= 2 && group.allSatisfy { $0.tabHeight > 0 && $0.tabHeight == group[0].tabHeight }
  }
 }
}

func tabSelection(_ entries: [Entry], focused: Int, liveID: Int? = nil) -> Int? {
 if entries.contains(where: { $0.id == focused }) { return focused }
 if let liveID, entries.contains(where: { $0.id == liveID }) { return liveID }
 return entries.first.flatMap { entry in entries.contains(where: { $0.id == entry.selectedID }) ? entry.selectedID : nil }
}
func visibleTabMembers(_ entries: [Entry], capacity: Int, selected: Int?) -> [Entry] {
 let count = max(1, capacity)
 guard entries.count > count else { return entries }
 var result = Array(entries.prefix(count))
 if let chosen = entries.first(where: { $0.id == selected }), !result.contains(where: { $0.id == chosen.id }) {
  result[result.count - 1] = chosen
 }
 return result
}
func appKitRect(_ quartz: CGRect, primaryTop: CGFloat) -> CGRect {
 CGRect(x: quartz.minX, y: primaryTop - quartz.maxY, width: quartz.width, height: quartz.height)
}
// Keep every tab surface and hit target on the straight top edge. The 24pt
// clearance covers the current macOS rounded corners, including border inset.
let tabCornerClearance: CGFloat = 24
func tabBarFrame(window: CGRect, height: CGFloat, display: CGRect, visible: CGRect) -> CGRect? {
 guard height > 0, height <= 80, window.width > 2 * tabCornerClearance, window.height > 0 else { return nil }
 let overlap = window.intersection(visible)
 // A narrow exposed edge is a strip sliver, not a usable tab target.
 guard !overlap.isNull, overlap.width >= min(120, window.width * 0.5), overlap.height > 40 else { return nil }
 let raw = CGRect(x: window.minX + tabCornerClearance, y: window.maxY, width: window.width - 2 * tabCornerClearance, height: height)
 let clipped = raw.intersection(display).intersection(visible)
 guard !clipped.isNull, clipped.height >= height - 1, clipped.width >= min(120, window.width * 0.5) else { return nil }
 return clipped
}
// Translation and clipping must never change the layout width or rebuild key.
struct TabStripPlacement {
 let contentWidth: CGFloat
 let offsetX: CGFloat
 init(window: CGRect, clipped: CGRect) {
  contentWidth = max(0, window.width - 2 * tabCornerClearance)
  offsetX = window.minX + tabCornerClearance - clipped.minX
 }
}
func tabContentSignature(_ members: [Entry], selected: Int?, width: CGFloat, height: CGFloat) -> String {
 members.map { "\($0.id):\($0.app):\($0.title):\($0.bundle)" }.joined(separator: "|") + ":\(selected ?? 0):\(width):\(height)"
}
struct LiveWindow {
 let id: Int
 let frame: CGRect
 let layer: Int
}
func readLiveWindows() -> [LiveWindow] {
 guard let rows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else { return [] }
 let top = NSScreen.screens.first?.frame.maxY ?? 0
 return rows.compactMap { row in
  guard let id = row[kCGWindowNumber as String] as? Int,
   let bounds = row[kCGWindowBounds as String] as? NSDictionary,
   let frame = CGRect(dictionaryRepresentation: bounds) else { return nil }
  return LiveWindow(id: id, frame: appKitRect(frame, primaryTop: top), layer: row[kCGWindowLayer as String] as? Int ?? 0)
 }
}
// Rounded shoulders grow from a full-width bottom seam. The selected tab
// rises four points above its recessed neighbours, while retaining 28pt targets.
func folderTabPath(in bounds: CGRect, selected: Bool, compact:Bool=false) -> NSBezierPath {
 let roomy=bounds.height >= 34
 let bottom=bounds.minY + (selected || compact ? 0 : (roomy ? 4 : 3.25))
 let top=bounds.maxY - (selected || compact ? 0.75 : (roomy ? 5.5 : 4.75))
 let slant=min(8.5,bounds.width/4), radius:CGFloat=selected ? 4 : 3
 let p=NSBezierPath(); p.move(to:CGPoint(x:bounds.minX,y:bottom))
 p.line(to:CGPoint(x:bounds.minX+slant-radius/2,y:top-radius))
 p.curve(to:CGPoint(x:bounds.minX+slant+radius,y:top),controlPoint1:CGPoint(x:bounds.minX+slant,y:top),controlPoint2:CGPoint(x:bounds.minX+slant,y:top))
 p.line(to:CGPoint(x:bounds.maxX-slant-radius,y:top))
 p.curve(to:CGPoint(x:bounds.maxX-slant+radius/2,y:top-radius),controlPoint1:CGPoint(x:bounds.maxX-slant,y:top),controlPoint2:CGPoint(x:bounds.maxX-slant,y:top))
 p.line(to:CGPoint(x:bounds.maxX,y:bottom))
 if !selected { p.close() }
 return p
}
func tabPresentationFrame(window:CGRect,height:CGFloat,style:String,visible:CGRect) -> CGRect? {
 let side=style == "side"
 let height=style == "folder-compact" ? (height==34 ? 25.0:20.0):height
 let overlap=window.intersection(visible)
 guard !overlap.isNull, overlap.width >= min(100,window.width/2), overlap.height>40 else {return nil}
 if side {
  let raw=CGRect(x:window.minX-40,y:window.minY,width:41,height:window.height).intersection(visible)
  return raw.width>=20 && raw.height>40 ? raw : nil
 }
 let left=style.hasPrefix("folder") ? max(window.minX,visible.minX)+24 : max(window.minX,visible.minX+(window.minX<visible.minX ? 12:0))
 let right=style.hasPrefix("folder") ? min(window.maxX,visible.maxX)-24 : min(window.maxX,visible.maxX-(window.maxX>visible.maxX ? 12:0))
 let raw=CGRect(x:left,y:window.maxY-1,width:max(0,right-left),height:height+1).intersection(visible)
 return raw.width>=40 && raw.height>=height ? raw:nil
}
final class SideTabSeparator:NSView {
 override func draw(_ dirtyRect:NSRect) {
  NSGradient(starting:.black.withAlphaComponent(0.16),ending:.clear)?.draw(in:bounds,angle:0)
 }
 override func hitTest(_ point:NSPoint)->NSView? {nil}
}
final class FolderTabFace: NSView {
 var selected = false
 var style="folder"
 var matchedColor:NSColor?
 var first=false, last=false
 // System Increase Contrast / Reduce Transparency. Both default off, which
 // is exactly the accepted look; TabBars sets them from NSWorkspace.
 var increaseContrast=false, reduceTransparency=false
 override func draw(_ dirtyRect: NSRect) {
  let dark=effectiveAppearance.bestMatch(from:[.aqua,.darkAqua]) == .darkAqua
  let fallback=dark ? NSColor(srgbRed:0.16,green:0.17,blue:0.18,alpha:1) : .windowBackgroundColor
  var inactive=NSColor.white.withAlphaComponent(dark ? 0.10:0.88)
  // Translucent folder fills would show the desktop through; settle them onto the window colour.
  if reduceTransparency { inactive=fallback.blended(withFraction:dark ? 0.10:0.88,of:.white) ?? inactive }
  let fill=selected ? (matchedColor ?? fallback) : (style.hasPrefix("folder") ? inactive : NSColor(srgbRed:dark ? 0.165:0.835,green:dark ? 0.176:0.839,blue:dark ? 0.184:0.831,alpha:1))
  let path: NSBezierPath
  if style.hasPrefix("folder") {path=folderTabPath(in:bounds,selected:selected,compact:style == "folder-compact")}
  else {
   let r:CGFloat=style == "side" ? 10:8
   path=NSBezierPath();path.move(to:CGPoint(x:bounds.minX+(first ? r:0),y:bounds.maxY))
   path.line(to:CGPoint(x:bounds.maxX-(style == "classic" && last ? r:0),y:bounds.maxY))
   if style == "classic" && last {path.curve(to:CGPoint(x:bounds.maxX,y:bounds.maxY-r),controlPoint1:CGPoint(x:bounds.maxX,y:bounds.maxY),controlPoint2:CGPoint(x:bounds.maxX,y:bounds.maxY))}
   path.line(to:CGPoint(x:bounds.maxX,y:bounds.minY));path.line(to:CGPoint(x:bounds.minX+(style == "side" && last ? r:0),y:bounds.minY))
   if style == "side" && last {path.curve(to:CGPoint(x:bounds.minX,y:bounds.minY+r),controlPoint1:CGPoint(x:bounds.minX,y:bounds.minY),controlPoint2:CGPoint(x:bounds.minX,y:bounds.minY))}
   path.line(to:CGPoint(x:bounds.minX,y:bounds.maxY-(first ? r:0)))
   if first {path.curve(to:CGPoint(x:bounds.minX+r,y:bounds.maxY),controlPoint1:CGPoint(x:bounds.minX,y:bounds.maxY),controlPoint2:CGPoint(x:bounds.minX,y:bounds.maxY))}
   path.close()
  }
  fill.setFill();path.fill()
  NSGraphicsContext.saveGraphicsState();path.addClip()
  if style.hasPrefix("folder") {
   let stroke: NSColor
   if selected, let color=matchedColor { stroke=color.blended(withFraction:tabColorIsDark(color) ? 0.35:0.28,of:tabColorIsDark(color) ? .white:.black) ?? color }
   else {
    let strong=increaseContrast
    stroke=selected ? (dark ? NSColor(srgbRed:0.235,green:0.776,blue:0.769,alpha:1):(strong ? NSColor(srgbRed:0,green:0.44,blue:0.48,alpha:1):NSColor(srgbRed:0,green:0.761,blue:0.82,alpha:1))) : (dark ? NSColor.white.withAlphaComponent(strong ? 1:0.38):NSColor.black.withAlphaComponent(strong ? 1:0.45))
   }
   stroke.setStroke();path.lineWidth=selected ? (increaseContrast ? 2:1.5):(increaseContrast ? 1.25:0.75);path.stroke()
  } else {
   // Local edge shading stays inside the bar; no shadow spills onto the app.
   let edge=NSBezierPath();edge.move(to:CGPoint(x:0,y:bounds.maxY-0.5));edge.line(to:CGPoint(x:bounds.maxX,y:bounds.maxY-0.5))
   NSColor.white.withAlphaComponent(dark ? 0.06:0.55).setStroke();edge.lineWidth=1;edge.stroke()
   if !selected {
    NSColor.black.withAlphaComponent(0.2).setFill(); CGRect(x:0,y:0,width:bounds.width,height:0.5).fill()
    let shades=4
    for i in 0..<shades {
     NSColor.black.withAlphaComponent((dark ? 0.28:0.13)*CGFloat(shades-i)/CGFloat(shades)).setFill()
     if style == "side" {CGRect(x:0,y:bounds.minY+CGFloat(i),width:bounds.width,height:1).fill()}
     else {CGRect(x:bounds.maxX-CGFloat(i)-1,y:0,width:1,height:bounds.height).fill()}
    }
   }
  }
  NSGraphicsContext.restoreGraphicsState()
 }
}
func tabColorIsDark(_ color:NSColor) -> Bool {
 guard let c=color.usingColorSpace(.sRGB) else {return false}
 return 0.2126*c.redComponent+0.7152*c.greenComponent+0.0722*c.blueComponent < 0.5
}
struct TabWindowSample {
 let titleColor:NSColor?
 let sideColor:NSColor?
 // Transparent masks cover only pixels outside the app's own rounded shape.
 let corners:[CGImage]
}
let tabSeamExtent:CGFloat=32
// Capture at window aspect ratio, then crop locally. ScreenCaptureKit ignores
// sourceRect for desktop-independent window capture (Apple's API contract).
final class TabColorSampler {
 var samples:[Int:TabWindowSample]=[:]
 private var attempted:[Int:TimeInterval]=[:]
 private var busy=false
 private var lastFailure=""
 private var gate=SampleGate()
 var onSample: (() -> Void)?
 // Event-driven: see SampleGate. `key` identifies the group's members and selection.
 func sample(id:Int,size:CGSize = .zero,key:Int = 0,titles:Int = 0) -> TabWindowSample? {
  let now=Date.timeIntervalSinceReferenceDate
  guard screenCaptureAllowed() else {report("Screen Recording permission unavailable");return nil}
  if !busy && gate.claim(id:id,size:size,appearance:NSApp.effectiveAppearance.name.rawValue,key:key,titles:titles,have:samples[id] != nil,now:now) {
   busy=true;attempted[id]=now
   SCShareableContent.getExcludingDesktopWindows(true,onScreenWindowsOnly:true) { [weak self] content,error in
    guard let window=content?.windows.first(where: { $0.windowID == CGWindowID(id) }) else {
     DispatchQueue.main.async {self?.busy=false;self?.report("Window lookup failed: \(error?.localizedDescription ?? "window unavailable")")};return
    }
    let filter=SCContentFilter(desktopIndependentWindow:window)
    let config=SCStreamConfiguration();config.width=max(1,Int(window.frame.width));config.height=max(1,Int(window.frame.height));config.showsCursor=false
    config.ignoreShadowsSingleWindow=true;config.scalesToFit=true
    SCScreenshotManager.captureImage(contentFilter:filter,configuration:config) { image,error in
     let sample=image.flatMap(Self.extract)
     DispatchQueue.main.async {
      guard let self else {return};self.busy=false
      if let sample {self.samples[id]=sample;self.lastFailure="";self.onSample?()}
      else {self.report("Window capture failed: \(error?.localizedDescription ?? "empty sample")")}
      if self.attempted.count>100 {self.samples=self.samples.filter {$0.key==id};self.attempted=self.attempted.filter {$0.key==id}}
     }
    }
   }
  }
  return samples[id]
 }
 private func report(_ message:String) {
  if message != lastFailure {NSLog("Tab color sampling: %@",message);lastFailure=message}
 }
 static func extract(_ image:CGImage) -> TabWindowSample? {
  let w=image.width,h=image.height
  guard w>80,h>80 else {return nil}
  let title=image.cropping(to:CGRect(x:40,y:2,width:w-80,height:12)).flatMap(dominantColor)
  // Sample the edge the rail actually meets, rather than the center of a
  // potentially differently colored page/sidebar.
  let side=image.cropping(to:CGRect(x:2,y:40,width:12,height:h-80)).flatMap(dominantColor)
  return TabWindowSample(titleColor:title,sideColor:side,corners:cornerMasks(image))
 }
 static func cornerMasks(_ image:CGImage) -> [CGImage] {
  let w=image.width,h=image.height,n=Int(tabSeamExtent)
  guard w>n*2,h>n*2 else {return []}
  var pixels=[UInt8](repeating:0,count:w*h*4)
  let ok=pixels.withUnsafeMutableBytes { buffer -> Bool in
   guard let ctx=CGContext(data:buffer.baseAddress,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else {return false}
   ctx.draw(image,in:CGRect(x:0,y:0,width:w,height:h));return true
  }
  guard ok else {return []}
  // Top-left, top-right, bottom-left, bottom-right, in CGImage coordinates.
  let topColor=image.cropping(to:CGRect(x:40,y:2,width:w-80,height:12)).flatMap(dominantColor)
  let leftColor=image.cropping(to:CGRect(x:2,y:40,width:12,height:h-80)).flatMap(dominantColor)
  let rightColor=image.cropping(to:CGRect(x:w-14,y:40,width:12,height:h-80)).flatMap(dominantColor)
  return [(0,0),(w-n,0),(0,h-n),(w-n,h-n)].compactMap { ox,oy in
   guard let color=(oy==0 ? topColor:(ox==0 ? leftColor:rightColor))?.usingColorSpace(.sRGB) else {return nil}
   let rgb=[color.redComponent,color.greenComponent,color.blueComponent].map {Int(($0*255).rounded())}
   var mask=[UInt8](repeating:0,count:n*n*4)
   for y in 0..<n {for x in 0..<n {
    let src=((oy+y)*w+ox+x)*4, dst=(y*n+x)*4
    let outerX=ox==0 ? x:n-1-x,outerY=oy==0 ? y:n-1-y
    // Repair only the mostly transparent outer cutout. Uniform edge
    // color avoids copying nearby controls into the corner.
    let alpha=pixels[src+3]<128 && outerX+outerY<n ? 255:0
    for c in 0..<3 {mask[dst+c]=UInt8(rgb[c]*alpha/255)}
    mask[dst+3]=UInt8(alpha)
   }}
   let data=Data(mask) as CFData
   guard let provider=CGDataProvider(data:data) else {return nil}
   return CGImage(width:n,height:n,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:n*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent)
  }
 }
 static func dominantColor(_ image:CGImage) -> NSColor? {
  var pixels=[UInt8](repeating:0,count:64*8*4)
  let ok=pixels.withUnsafeMutableBytes { buffer -> Bool in
   guard let ctx=CGContext(data:buffer.baseAddress,width:64,height:8,bitsPerComponent:8,bytesPerRow:256,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else {return false}
   ctx.draw(image,in:CGRect(x:0,y:0,width:64,height:8));return true
  }
  guard ok else {return nil}
  var bins:[Int:(Int,Int,Int,Int)]=[:]
  for i in stride(from:0,to:pixels.count,by:4) where pixels[i+3]>240 {
   let r=Int(pixels[i]),g=Int(pixels[i+1]),b=Int(pixels[i+2]),key=(r/16)*256+(g/16)*16+b/16
   let old=bins[key] ?? (0,0,0,0);bins[key]=(old.0+1,old.1+r,old.2+g,old.3+b)
  }
  guard let best=bins.values.max(by:{$0.0<$1.0}),best.0>16 else {return nil}
  return NSColor(srgbRed:CGFloat(best.1)/CGFloat(best.0)/255,green:CGFloat(best.2)/CGFloat(best.0)/255,blue:CGFloat(best.3)/CGFloat(best.0)/255,alpha:1)
 }
}
func cancelTabPresses(in view: NSView?) {
 guard let view else { return }
 if let card = view as? ColumnCard { card.cancelInteraction() }
 for child in view.subviews { cancelTabPresses(in: child) }
}
func tabDropExposed(point: CGPoint, panelID: Int, members: Set<Int>, windows: [LiveWindow]) -> Bool {
 guard let front=windows.first(where: { $0.layer == 0 && $0.frame.contains(point) }) else { return true }
 return front.id == panelID || members.contains(front.id)
}
// The tab cards are drawn views with no native accessibility. Expose them to
// VoiceOver / Voice Control as the standard tab pattern: a tab group of radio
// buttons (announced as "tab") whose value is the selection and whose press focuses the window.
final class TabAccessibilityElement: NSAccessibilityElement {
 var onPress: (() -> Void)?
 override func accessibilityPerformPress() -> Bool {
  guard let onPress else { return false }
  onPress(); return true
 }
}
// A tab narrower than this much label drops its title and centres the icon, as Safari and Finder do. The tooltip and
// the VoiceOver label keep the name.
let tabMinLabelWidth: CGFloat = 28
func tabShowsTitle(labelWidth: CGFloat) -> Bool { labelWidth >= tabMinLabelWidth }
/// "Safari — Inbox", or just "Safari" when the window has no title.
func tabDisplayName(app: String, title: String) -> String { title.isEmpty ? app : "\(app) — \(title)" }
func middleTruncated(_ text: String, limit: Int) -> String {
 guard limit > 1, text.count > limit else { return text }
 let keep = limit - 1, head = (keep + 1) / 2, tail = keep / 2
 return String(text.prefix(head)) + "…" + String(text.suffix(tail))
}
/// One line of the "More tabs" menu: the app alone for an untitled window, a long title cut in the middle.
func tabOverflowMenuTitle(app: String, title: String) -> String {
 tabDisplayName(app: app, title: middleTruncated(title, limit: 48))
}
func tabStripAccessibilityLabel(selectedName: String, count: Int) -> String {
 "Tabs: \(middleTruncated(selectedName, limit: 40)), \(count) windows"
}
struct TabAccessibilityAction {
 let name: String
 let run: () -> Void
}
struct TabAccessibilityItem {
 let card: NSView
 let label: String
 let help: String
 let selected: Bool?   // nil: a plain button (overflow), not a tab
 let press: () -> Void
 var actions: [TabAccessibilityAction] = []   // what dragging does, for people who cannot drag
}
func installTabAccessibility(strip: NSView, items: [TabAccessibilityItem], vertical: Bool, label stripLabel: String = "Window tabs") {
 var elements: [TabAccessibilityElement] = []
 for item in items {
  item.card.setAccessibilityElement(false)
  for child in item.card.subviews { child.setAccessibilityElement(false) }
  let element = TabAccessibilityElement()
  element.setAccessibilityParent(strip)
  element.setAccessibilityRole(item.selected == nil ? .button : .radioButton)
  if item.selected != nil { element.setAccessibilityRoleDescription("tab") }
  if !item.actions.isEmpty {
   element.setAccessibilityCustomActions(item.actions.map { action in
    NSAccessibilityCustomAction(name: action.name) { action.run(); return true }
   })
  }
  element.setAccessibilityLabel(item.label)
  element.setAccessibilityHelp(item.help)
  element.setAccessibilityFrameInParentSpace(item.card.frame)
  element.setAccessibilityEnabled(true)
  if let selected = item.selected { element.setAccessibilityValue(selected ? 1:0); element.setAccessibilitySelected(selected) }
  element.onPress = item.press
  elements.append(element)
 }
 strip.setAccessibilityElement(true)
 strip.setAccessibilityRole(.tabGroup)
 strip.setAccessibilityLabel(stripLabel)
 strip.setAccessibilityOrientation(vertical ? .vertical:.horizontal)
 strip.setAccessibilityChildren(elements)
 strip.setAccessibilityTabs(elements.filter { $0.accessibilityRole() == .radioButton })
}
// A Mouse-up can be lost (Space switch, app deactivation mid-press), which
// would freeze the bar's tracking. Hardware says no button is down: recover.
func tabPressIsStale(pressed: Bool, since: TimeInterval, now: TimeInterval, buttonsDown: Int) -> Bool {
 pressed && buttonsDown == 0 && now - since > 1.5
}
private final class TabBarSurface {
 let panel = StripPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
 let seamPanel = StripPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
 var signature = ""
 var memberIDs = Set<Int>()
 var pressed = false { didSet { if pressed && !oldValue { pressedSince = Date.timeIntervalSinceReferenceDate } } }
 var pressedSince: TimeInterval = 0
 // The whole view chain from the panel down to the leaves is permanent (see labelDefaults in main.swift): a rebuild
 // re-fills `strip` rather than replacing the tree.
 let strip = NSView(frame: .zero)
 let clip = NSView(frame: .zero)
 // Cards, their label/icon leaves, the overflow card and the seam patches are pooled for life: on macOS 27 each
 // NSTextField/NSImageView freed after joining a window leaks NSKeyValueDependency objects (see labelDefaults in
 // main.swift). A rebuild takes the cards out of the old strip, re-configures them and puts them in the new one.
 private var cards: [ColumnCard] = [], cardsTaken = 0
 private var patches: [NSImageView] = [], patchesTaken = 0
 let more = ColumnCard(frame: .zero)
 /// The seam panel's content view, kept: it is the permanent parent of the corner patches.
 let seams = NSView(frame: .zero)
 func recycleCards() {
  for card in cards[0..<cardsTaken] { card.removeFromSuperview(); card.recycle() }
  more.removeFromSuperview(); more.recycle()
  seams.subviews.forEach { $0.removeFromSuperview() }
  cardsTaken = 0; patchesTaken = 0
 }
 func takeCard(frame: CGRect) -> ColumnCard {
  if cardsTaken == cards.count { cards.append(ColumnCard(frame: frame)) }
  let card = cards[cardsTaken]; cardsTaken += 1; card.frame = frame; return card
 }
 func takePatch(frame: CGRect, image: NSImage) -> NSImageView {
  if patchesTaken == patches.count { patches.append(NSImageView(frame: frame)) }
  let patch = patches[patchesTaken]; patchesTaken += 1; patch.frame = frame; patch.image = image; return patch
 }
 init() {
  seamPanel.contentView = seams
  panel.contentView = clip
  clip.wantsLayer = true; clip.layer?.masksToBounds = true
  strip.wantsLayer = true
  // A quiet attached seam, without an independently glowing HUD material.
  strip.layer?.backgroundColor = NSColor.clear.cgColor
  clip.addSubview(strip)
  panel.isExcludedFromWindowsMenu = true; seamPanel.isExcludedFromWindowsMenu = true
  // Hide (⌘H) and Hide Others must never take the tab bars away from the windows they belong to.
  panel.canHide = false; seamPanel.canHide = false
  panel.setAccessibilityLabel("Window tabs")
  seamPanel.animationBehavior = .none;seamPanel.hasShadow=false;seamPanel.level = .normal
  seamPanel.isFloatingPanel=false;seamPanel.isOpaque=false;seamPanel.backgroundColor = .clear
  seamPanel.ignoresMouseEvents=true;seamPanel.hidesOnDeactivate=false
  seamPanel.collectionBehavior=[.canJoinAllSpaces,.ignoresCycle]
  panel.animationBehavior = .none; panel.hasShadow = false
  panel.level = .normal; panel.isFloatingPanel = false; panel.isOpaque = false; panel.backgroundColor = .clear
  panel.hidesOnDeactivate = false; panel.becomesKeyOnlyIfNeeded = true
  panel.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle]
 }
 func hide() {
  // Called for every absent bar on every tick; once hidden it must cost nothing.
  guard pressed || panel.isVisible || seamPanel.isVisible else { return }
  cancelTabPresses(in: panel.contentView)
  pressed = false; panel.orderOut(nil);seamPanel.orderOut(nil)
 }
}
final class TabBars: NSObject {
 private var bars: [Int: TabBarSurface] = [:]
 private var icons: [String: NSImage] = [:]
 private var iconMisses: [String: TimeInterval] = [:]
 var aliases: [String:String] = [:]
 var style="folder"
 var height:CGFloat=34
 var matchAppColor=false
 var selectOnPress=true
 private let sampler=TabColorSampler()
 var onSampled: (() -> Void)? { didSet { sampler.onSample = onSampled } }
 var focus: ((Int) -> Void)?
 var reorder: ((StripDrop) -> Void)?
 var dragOutside: ((Int,CGPoint,Bool) -> Bool)?
 var dragFinished: (() -> Void)?
 private var dragMark: DropInsertionMark?
 private var dragSource: Int?
 private var currentWindows: [LiveWindow] = []
 func clearDragFeedback() { dragMark?.removeFromSuperview(); dragMark=nil }
 func finishDrag() { clearDragFeedback(); dragSource=nil; dragFinished?() }
 private func tabInsertion(_ point: CGPoint) -> (bar: TabBarSurface,target: StripDropTarget,before: Bool)? {
  for bar in bars.values where bar.panel.isVisible {
   guard tabDropExposed(point:point,panelID:bar.panel.windowNumber,members:bar.memberIDs.union([bar.seamPanel.windowNumber]),windows:currentWindows) else { continue }
   let strip=bar.strip
   let targets=strip.subviews.compactMap { view -> StripDropTarget? in
    guard let card=view as? ColumnCard, card.entryID > 0 else { return nil }
    let windowRect=strip.convert(card.frame,to:nil)
    let screenRect=bar.panel.convertToScreen(windowRect).intersection(bar.panel.frame)
    guard !screenRect.isNull, screenRect.width > 3 else { return nil }
    return StripDropTarget(id:card.entryID,frame:screenRect)
   }
   if style == "side", bar.panel.frame.insetBy(dx:-8,dy:-8).contains(point), !targets.isEmpty {
    let ordered=targets.sorted {$0.frame.maxY > $1.frame.maxY}
    if let target=ordered.first(where:{point.y > $0.frame.midY}) {return (bar,target,true)}
    return (bar,ordered.last!,false)
   }
   if style != "side", let insertion=stripInsertion(at:point,targets:targets.sorted {$0.frame.minX < $1.frame.minX}) { return (bar,insertion.target,insertion.before) }
  }
  return nil
 }
 private func dragTab(source: Int, point: CGPoint, commit: Bool) {
  dragSource=source; clearDragFeedback()
  if let insertion=tabInsertion(point), insertion.target.id != source, let view=insertion.bar.panel.contentView {
   // A line between folder shoulders means insertion into that tab group.
   let frame=insertion.target.frame
   let local=insertion.bar.panel.convertPoint(fromScreen:CGPoint(x:insertion.before ? frame.minX : frame.maxX,y:frame.minY))
   let mark=DropInsertionMark(frame:style == "side" ? CGRect(x:0,y:insertion.bar.panel.convertPoint(fromScreen:CGPoint(x:frame.minX,y:insertion.before ? frame.maxY:frame.minY)).y-1.5,width:41,height:3):CGRect(x:local.x-1.5,y:local.y,width:3,height:frame.height))
   view.addSubview(mark); dragMark=mark
   // Also starts/reuses the explicit drag minimap, clearing its old marker.
   _ = dragOutside?(source,CGPoint(x:-100000,y:-100000),false)
   if commit { reorder?(StripDrop(kind:.tab,source:source,target:insertion.target.id,before:insertion.before)) }
   else { NSCursor.closedHand.set() }
  } else {
   let accepted=dragOutside?(source,point,commit) ?? false
   if !commit { (accepted ? NSCursor.closedHand : NSCursor.operationNotAllowed).set() }
  }
  if commit { finishDrag() }
 }
 var ordersPanels = true
 func stripView(column: Int) -> NSView? { bars[column]?.strip }
 func panelFrame(column: Int) -> CGRect? { bars[column]?.panel.frame }
 var hasVisibleBars: Bool { bars.values.contains { $0.panel.isVisible } }
 #if NAVIGATOR_TESTS
 func backdatePress(column: Int, by seconds: TimeInterval) { bars[column]?.pressedSince -= seconds }
 #endif
 func update(_ snapshot: NavigatorSnapshot, windows: [LiveWindow]) {
  currentWindows=windows
  guard snapshot.tabsVisible, let screen = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == snapshot.display }) else {
   bars.values.forEach { $0.hide() }
   if dragSource != nil || dragMark != nil { finishDrag() }
   return
  }
  var shown = Set<Int>()
  for (column, members) in snapshot.tabGroups {
   let ids = Set(members.map { $0.id })
   guard let live = windows.first(where: { ids.contains($0.id) && $0.layer == 0 }),
    let frame = tabPresentationFrame(window: live.frame, height: height, style:style, visible: screen.visibleFrame) else { continue }
   // Do not float over an unrelated full-screen surface on the current Space.
   if windows.prefix(while: { $0.id != live.id }).contains(where: { $0.layer == 0 && !ids.contains($0.id) && $0.frame.contains(screen.visibleFrame) }) { continue }
   let bar = bars[column] ?? TabBarSurface(); bars[column] = bar
   bar.memberIDs=ids
   if tabPressIsStale(pressed:bar.pressed,since:bar.pressedSince,now:Date.timeIntervalSinceReferenceDate,buttonsDown:Int(NSEvent.pressedMouseButtons)) {
    // A lost mouse-up: unwind the card and any drag so the minimap's tab-drag hold ends too.
    cancelTabPresses(in:bar.panel.contentView); bar.pressed=false
    if dragSource != nil || dragMark != nil { finishDrag() } else { clearDragFeedback() }
   }
   shown.insert(column)
   let selection = tabSelection(members, focused: snapshot.focused, liveID: live.id)
   let side=style == "side"
   let contentWidth=frame.width
   let panelFrame=frame
   let seamFrame=side ? CGRect(x:live.frame.minX,y:live.frame.minY,width:32,height:live.frame.height) : CGRect(x:live.frame.minX,y:live.frame.maxY-32,width:live.frame.width,height:32)
   let sample=matchAppColor ? sampler.sample(id:live.id,size:live.frame.size,key:ids.sorted().hashValue &+ (selection ?? 0),titles:members.map(\.title).hashValue):nil
   let matched=side ? sample?.sideColor:sample?.titleColor
   let signature = tabContentSignature(members, selected: selection, width: contentWidth, height: frame.height) + ":\(style):\(selectOnPress):\(sample != nil):\(NSApp.effectiveAppearance.name.rawValue):\(matched?.description ?? "default")" + members.map { aliases[$0.bundle+"\t"+$0.title] ?? "" }.joined(separator:"|") + ":\(NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast):\(NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency)"
   if signature != bar.signature && !bar.pressed {
    bar.signature = signature
    bar.recycleCards()
    let view = bar.strip
    view.frame = CGRect(x: 0, y: 0, width: contentWidth, height: frame.height)
    let capacity = max(1, Int((side ? frame.height:contentWidth) / (side ? 32:65)))
    let overflow = members.count > capacity
    let visible = visibleTabMembers(members, capacity: capacity, selected: selection)
    var accessibilityItems: [TabAccessibilityItem] = []
    let increaseContrast=NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast, reduceTransparency=NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    let gap:CGFloat=style.hasPrefix("folder") ? 2.5:0
    let available = (side ? frame.height:contentWidth) - (overflow ? 30 : 0)
    let width = max(1,(available-gap*CGFloat(visible.count-1)) / CGFloat(visible.count))
    for (index, entry) in visible.enumerated() {
     let card = bar.takeCard(frame: side ? CGRect(x:0,y:frame.height-CGFloat(index+1)*width,width:41,height:width) : CGRect(x:CGFloat(index)*(width+gap),y:0,width:width,height:frame.height))
     card.entryID=entry.id
     card.diagnosticName="tab column=\(column) target=\(entry.id)"
     card.onPress = { [weak bar] down in bar?.pressed = down }
     card.onDrag = { [weak self] point in self?.dragTab(source:entry.id,point:point,commit:false) }
     card.onDrop = { [weak self] point in self?.dragTab(source:entry.id,point:point,commit:true) }
     card.onCancelDrag = { [weak self] in self?.finishDrag() }
     card.onClick = { [weak self] in
      NSLog("Navigator tab click column=%d target=%d",column,entry.id)
      self?.focus?(entry.id)
     }
     // Tabs select on mouse-down, as native tabs do. A drag from the same press reorders as before and
     // sends no further focus; releasing without a drag does not click again. onClick stays for the
     // modifier, Hyper and VoiceOver paths.
     card.selectsOnPress = selectOnPress
     card.onSelect = { [weak self] in
      NSLog("Navigator tab click column=%d target=%d on=down",column,entry.id)
      self?.focus?(entry.id)
     }
     let displayTitle=aliases[entry.bundle+"\t"+entry.title] ?? entry.title
     let name = tabDisplayName(app:entry.app,title:displayTitle)
     card.toolTip = "\(name)\nDrag to reorder, or drop it in the Minimap to move it to another column."
     card.wantsLayer = true
     let active = selection == entry.id
     if side && !active {card.setFrameSize(NSSize(width:40,height:card.frame.height))}
     if !style.hasPrefix("folder") {
      card.layer?.shadowColor=NSColor.black.cgColor;card.layer?.shadowOpacity=Float(NSApp.effectiveAppearance.bestMatch(from:[.aqua,.darkAqua]) == .darkAqua ? 0.55:0.26)
      card.layer?.shadowRadius=active ? 2.5:2;card.layer?.shadowOffset=side ? CGSize(width:0,height:active ? 0:-2):CGSize(width:active ? 0:2,height:0)
     }
     let face = FolderTabFace(frame:card.bounds); face.selected = active;face.style=style;face.matchedColor=active ? matched:nil;face.increaseContrast=increaseContrast;face.reduceTransparency=reduceTransparency
     face.first=index==0 && (side ? frame.maxY>=live.frame.maxY:live.frame.minX>=screen.visibleFrame.minX);face.last=index==visible.count-1 && (side ? frame.minY<=live.frame.minY:live.frame.maxX<=screen.visibleFrame.maxX)
     card.addSubview(face)
     if icons[entry.bundle] == nil, (iconMisses[entry.bundle] ?? 0) < Date.timeIntervalSinceReferenceDate {
      // An app Launch Services cannot resolve would otherwise be looked up on every rebuild (every frame of a live resize).
      if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: entry.bundle) { icons[entry.bundle] = NSWorkspace.shared.icon(forFile: url.path) }
      else { iconMisses[entry.bundle] = Date.timeIntervalSinceReferenceDate + 10 }
     }
     let iconSize:CGFloat=side ? 22:16
     let contentY:CGFloat=side ? (card.bounds.height-iconSize)/2 : (style == "classic" || style == "folder-compact") ? (frame.height-16)/2 : (height >= 34 ? 8.25:6.25)
     // Below ~28 pt of label the title would be a clipped letter: show the icon alone, centred.
     let labelWidth = style == "classic" ? width-39 : width-51
     let showsTitle = !side && tabShowsTitle(labelWidth:labelWidth)
     let iconX = side ? 9 : (showsTitle ? 15 : ((width-iconSize)/2*2).rounded()/2)
     let icon = card.takeIcon(frame:CGRect(x:iconX,y:contentY,width:iconSize,height:iconSize))
     icon.image=icons[entry.bundle] ?? NSImage(named:NSImage.applicationIconName);card.addSubview(icon)
     let tabLabel = displayTitle.isEmpty ? entry.app:displayTitle
     card.setAccessibilityLabel(tabLabel)
     // What a drag does, as actions: reorder within the group, or take the tab out into its own Column.
     var actions: [TabAccessibilityAction] = []
     if let at = members.firstIndex(where: { $0.id == entry.id }) {
      if at > 0 {
       let previous = members[at-1].id
       actions.append(TabAccessibilityAction(name:side ? "Move Up":"Move Left",run:{ [weak self] in self?.reorder?(StripDrop(kind:.tab,source:entry.id,target:previous,before:true)) }))
      }
      if at < members.count-1 {
       let next = members[at+1].id
       actions.append(TabAccessibilityAction(name:side ? "Move Down":"Move Right",run:{ [weak self] in self?.reorder?(StripDrop(kind:.tab,source:entry.id,target:next,before:false)) }))
      }
      if let other = members.first(where: { $0.id != entry.id }) {
       actions.append(TabAccessibilityAction(name:"Move to New Column",run:{ [weak self] in self?.reorder?(StripDrop(kind:.detach,source:entry.id,target:other.id,before:false)) }))
      }
     }
     accessibilityItems.append(TabAccessibilityItem(card:card,label:tabLabel,help:"Shows this window.",selected:active,press:{ [weak self] in self?.focus?(entry.id) },actions:actions))
     if showsTitle {
      let label=card.takeLabel(displayTitle.isEmpty ? entry.app:displayTitle)
      label.frame=CGRect(x:38,y:contentY-1,width:max(0,width-51),height:18)
      label.font = .systemFont(ofSize:style == "classic" ? 12.5:13,weight:active ? .semibold:.regular);label.lineBreakMode = .byTruncatingTail
      if active, let matched {label.textColor=tabColorIsDark(matched) ? .white:.black}
      if style == "classic" {
       let textWidth=min(max(0,width-39),(label.stringValue as NSString).size(withAttributes:[.font:label.font!]).width+2)
       let start=max(7,(width-23-textWidth)/2);icon.setFrameOrigin(CGPoint(x:start,y:contentY))
       label.frame=CGRect(x:start+23,y:contentY-1,width:textWidth,height:18)
      }
      card.addSubview(label)
     }
     view.addSubview(card,positioned:active ? .above:.below,relativeTo:nil)
     // Re-applied after joining the strip: AppKit resets a pooled card's shadowOpacity on addSubview.
     if !style.hasPrefix("folder") { card.layer?.shadowOpacity=Float(NSApp.effectiveAppearance.bestMatch(from:[.aqua,.darkAqua]) == .darkAqua ? 0.55:0.26) }
    }
    if overflow {
     let more = bar.more; more.frame = side ? CGRect(x:0,y:0,width:41,height:30):CGRect(x:available,y:0,width:30,height:frame.height)
     let face = FolderTabFace(frame:more.bounds); face.style=style; face.increaseContrast=increaseContrast;face.reduceTransparency=reduceTransparency; more.addSubview(face)
     let label = more.takeLabel("…"); label.frame = CGRect(x: 7, y: (more.bounds.height-18)/2, width: 20, height: 18); more.addSubview(label)
     more.diagnosticName="tab overflow column=\(column)"
     more.toolTip = "Show all tabs (\(members.count))"
     more.onPress = { [weak bar] down in bar?.pressed = down }
     // A pull-down: the menu hangs from the button (beside it on the side rail) and opens as the button goes down.
     let showMenu: () -> Void = { [weak self, weak more] in
      guard let self, let more else { return }
      let menu = NSMenu()
      for member in members {
       let item = NSMenuItem(title: tabOverflowMenuTitle(app:member.app,title:self.aliases[member.bundle+"\t"+member.title] ?? member.title), action: #selector(self.selectMenu(_:)), keyEquivalent: "")
       item.target = self; item.tag = member.id; item.state = member.id == selection ? .on : .off; menu.addItem(item)
      }
      menu.popUp(positioning: nil, at: side ? NSPoint(x: more.bounds.width, y: more.bounds.height) : NSPoint(x: 0, y: 0), in: more)
     }
     more.selectsOnPress = true
     more.onSelect = { [weak more] in
      showMenu()
      // Menu tracking swallows the mouse-up: end the press here so the bar is not left frozen.
      more?.cancelInteraction()
     }
     more.onClick = { showMenu() }
     more.setAccessibilityLabel("More tabs")
     // VoiceOver press: return before the menu's modal tracking starts.
     accessibilityItems.append(TabAccessibilityItem(card:more,label:"More tabs",help:"Shows a menu of all \(members.count) tabs",selected:nil,press:{ DispatchQueue.main.async { showMenu() } }))
     view.addSubview(more)
    }
    let selectedMember = members.first(where: { $0.id == selection }) ?? members[0]
    let stripLabel = tabStripAccessibilityLabel(selectedName:tabDisplayName(app:selectedMember.app,title:aliases[selectedMember.bundle+"\t"+selectedMember.title] ?? selectedMember.title),count:members.count)
    bar.panel.setAccessibilityLabel(stripLabel)
    installTabAccessibility(strip: view, items: accessibilityItems, vertical: side, label: stripLabel)
    // Never paint guessed opaque rectangles over app chrome. These masks are
    // transparent everywhere the captured app is opaque, including controls.
    let seams=bar.seams
    if !style.hasPrefix("folder"),let sample,sample.corners.count==4 {
     let placements:[(Int,CGRect)]=side ? [(0,CGRect(x:0,y:seamFrame.height-32,width:32,height:32)),(2,CGRect(x:0,y:0,width:32,height:32))] : [(0,CGRect(x:0,y:0,width:32,height:32)),(1,CGRect(x:seamFrame.width-32,y:0,width:32,height:32))]
     for (index,rect) in placements {
      if !side && ((index==0 && live.frame.minX<screen.visibleFrame.minX) || (index==1 && live.frame.maxX>screen.visibleFrame.maxX)) {continue}
      let patch=bar.takePatch(frame:rect,image:NSImage(cgImage:sample.corners[index],size:rect.size));seams.addSubview(patch)
     }
    }
    if side {
     let shadow=SideTabSeparator(frame:CGRect(x:0,y:0,width:4,height:seamFrame.height));seams.addSubview(shadow)
    }
   }
   if !bar.pressed {
    // Translate without animation; rebuild only when the visible protected span changes.
    CATransaction.begin(); CATransaction.setDisableActions(true)
    NSAnimationContext.runAnimationGroup { context in
     context.duration = 0; context.allowsImplicitAnimation = false
     if bar.panel.frame.size != panelFrame.size {
      bar.panel.setFrame(panelFrame, display: false, animate: false)
     } else if bar.panel.frame.origin != panelFrame.origin {
      // Translation avoids AppKit's resize/layout path on every swipe frame.
      bar.panel.setFrameOrigin(panelFrame.origin)
     }
     if bar.seamPanel.frame.size != seamFrame.size {bar.seamPanel.setFrame(seamFrame,display:false,animate:false)}
     else if bar.seamPanel.frame.origin != seamFrame.origin {bar.seamPanel.setFrameOrigin(seamFrame.origin)}
     if bar.panel.contentView?.frame.size != panelFrame.size { bar.panel.contentView?.setFrameSize(panelFrame.size) }
     let stripOrigin = CGPoint(x: 0, y: 0)
     if bar.strip.frame.origin != stripOrigin { bar.strip.setFrameOrigin(stripOrigin) }
    }
    CATransaction.commit()
   }
   // Attach the panel to its group's ordinary window order, not a global
   // floating level. Unrelated windows in front must also cover these tabs.
   guard ordersPanels else { continue }   // headless tests build and place strips without ever showing a window
   let hasSeams=side || (style == "classic" && sample?.corners.count == 4)
   if hasSeams {
    if !bar.seamPanel.isVisible || tabBarNeedsOrdering(panelID:bar.seamPanel.windowNumber,ownerID:live.id,windows:windows) {
     bar.seamPanel.order(.above,relativeTo:live.id)
    }
   } else {bar.seamPanel.orderOut(nil)}
   let anchor=hasSeams ? bar.seamPanel.windowNumber:live.id
   if !bar.panel.isVisible || tabBarNeedsOrdering(panelID:bar.panel.windowNumber,ownerID:anchor,windows:windows) {
    bar.panel.order(.above, relativeTo:anchor)
   }
  }
  for (key, bar) in bars where !shown.contains(key) { bar.hide() }
 }
 @objc private func selectMenu(_ item: NSMenuItem) { NSLog("Navigator tab menu click target=%d",item.tag); focus?(item.tag) }
}

// WindowServer lists front to back. Avoid redundant order calls each display
// tick, but repair placement after focus/stack changes, even if owner is stable.
func tabBarNeedsOrdering(panelID: Int, ownerID: Int, windows: [LiveWindow]) -> Bool {
 let normal = windows.filter { $0.layer == 0 }.map { $0.id }
 guard let owner = normal.firstIndex(of: ownerID), owner > 0 else { return true }
 return normal[owner - 1] != panelID
}
