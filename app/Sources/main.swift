import AppKit
// Mask the backdrop itself: layer clipping alone can leave compositor corners.
final class RoundedHUDView: NSVisualEffectView {
 override func draw(_ dirtyRect:NSRect) {
  super.draw(dirtyRect)
  let dark=hudDark(self),path=NSBezierPath(roundedRect:bounds.insetBy(dx:0.25,dy:0.25),xRadius:16,yRadius:16)
  hudColor(dark ? 0x2B2E2F:0xF3F4F3).withAlphaComponent(dark ? 0.72:0.92).setFill();path.fill()
  (dark ? NSColor.white:NSColor.black).withAlphaComponent(dark ? 0.10:0.08).setStroke();path.lineWidth=0.5;path.stroke()
 }
 private var maskSize = NSSize.zero
 override func layout() {
  super.layout()
  guard bounds.size != maskSize, bounds.width > 0, bounds.height > 0 else { return }
  maskSize=bounds.size
  maskImage=NSImage(size:bounds.size,flipped:false) { rect in
   NSColor.white.setFill()
   NSBezierPath(roundedRect:rect,xRadius:16,yRadius:16).fill()
   return true
  }
 }
}

import QuartzCore

func hudColor(_ hex:UInt32)->NSColor { NSColor(srgbRed:CGFloat((hex>>16)&255)/255,green:CGFloat((hex>>8)&255)/255,blue:CGFloat(hex&255)/255,alpha:1) }
func hudDark(_ view:NSView)->Bool { view.effectiveAppearance.bestMatch(from:[.aqua,.darkAqua]) == .darkAqua }
struct HUDMetrics {
 let card:CGSize; let gap:CGFloat; let gutter:CGFloat; let pad:CGFloat; let left:CGFloat; let radius:CGFloat; let emptyHeight:CGFloat
 init(_ style:String) {
  card=style == "titles" ? CGSize(width:140,height:36):style == "compact" ? CGSize(width:76,height:50):CGSize(width:108,height:72)
  gap=style == "cards" ? 8:6;gutter=style == "compact" ? 28:30;pad=style == "compact" ? 12:14;left=style == "compact" ? 10:12;radius=style == "cards" ? 10:9;emptyHeight=style == "cards" ? 36:style == "compact" ? 28:30
 }
}
final class HUDEmptySlot:NSView {
 override func draw(_ dirtyRect:NSRect) {
  let p=NSBezierPath(roundedRect:bounds.insetBy(dx:0.5,dy:0.5),xRadius:9,yRadius:9)
  (hudDark(self) ? NSColor.white:NSColor.black).withAlphaComponent(hudDark(self) ? 0.24:0.22).setStroke();p.lineWidth=1;p.setLineDash([1,2],count:2,phase:0);p.stroke()
 }
}
final class HUDBadge:NSTextField {
 override func draw(_ dirtyRect:NSRect) {
  hudColor(hudDark(self) ? 0x3CC6C4:0x007F81).setFill();NSBezierPath(roundedRect:bounds,xRadius:4,yRadius:4).fill();super.draw(dirtyRect)
 }
}

func makeFailureHUD(action:String,diagnostic:String,width:CGFloat=340,appearance:NSAppearance?=nil)->RoundedHUDView {
 let height:CGFloat=62
  let effect=RoundedHUDView(frame:CGRect(x:0,y:0,width:width,height:height))
  effect.material = .hudWindow; effect.blendingMode = .behindWindow; effect.state = .active
  effect.wantsLayer=true; effect.layer?.cornerRadius=16; effect.layer?.masksToBounds=true
  let title=NSTextField(labelWithString:action == "focus" ? "Focus not confirmed" : "Move not confirmed")
  let sourceAppearance=appearance ?? NSApp?.effectiveAppearance ?? NSAppearance.currentDrawing()
  effect.appearance=NSAppearance(named:sourceAppearance.bestMatch(from:[.aqua,.darkAqua]) == .darkAqua ? .vibrantDark:.vibrantLight)
  let dark=hudDark(effect)
  title.font = .systemFont(ofSize:13,weight:.semibold); title.textColor = hudColor(dark ? 0xFF6961:0xC4000F)
  title.frame=CGRect(x:44,y:31,width:width-60,height:17); effect.addSubview(title)
  let warning=NSImageView(frame:CGRect(x:14,y:26,width:20,height:20));warning.image=NSImage(systemSymbolName:"exclamationmark.triangle",accessibilityDescription:"Warning");warning.contentTintColor=hudColor(dark ? 0xFF6961:0xD70015);effect.addSubview(warning)
  let detail=NSTextField(labelWithString:"The target may have changed. Try again.")
  detail.font = .systemFont(ofSize:12); detail.frame=CGRect(x:44,y:14,width:width-60,height:16)
  detail.toolTip=String(diagnostic.prefix(500)); effect.addSubview(detail)
 return effect
}
struct NavigatorPreferences {
 var position = "bottom", style = "cards"
 var delay = 1.3, fade = 0.22, hyperDelay = 0.2
 var tabStyle = "folder", tabHeight = 34, tabMatchAppColor = false
 var showOnHyper = true
 var hide = "release"
 var aliases: [String:String] = [:]
 init(_ data: Data? = nil) {
  guard let data, let json = (try? JSONSerialization.jsonObject(with:data)) as? [String:Any] else { return }
  if let value=json["minimapPosition"] as? String, ["bottom","top","center","left","right"].contains(value) { position=value }
  if let value=json["minimapStyle"] as? String, ["cards","compact","titles"].contains(value) { style=value }
  if let value=json["minimapDelay"] as? Double, value.isFinite { delay=min(30,max(0,value)) }
  if let value=json["minimapFade"] as? Double, value.isFinite { fade=min(5,max(0,value)) }
  if let value=json["hyperHoldDelay"] as? Double, value.isFinite { hyperDelay=min(2,max(0.05,value)) }
  if let value=json["showOnHyper"] as? Bool { showOnHyper=value }
  if let value=json["minimapHide"] as? String, ["release","timer"].contains(value) { hide=value }
  if let value=json["tabStyle"] as? String, ["folder","folder-compact","classic","side"].contains(value) { tabStyle=value }
  if let value=json["tabHeight"] as? Int, [28,34].contains(value) { tabHeight=value }
  tabMatchAppColor=json["tabMatchAppColor"] as? Bool ?? false
  aliases=json["tabAliases"] as? [String:String] ?? [:]
 }
}
func minimapFrame(size: CGSize, visible: CGRect, position: String) -> CGRect {
 var origin=CGPoint(x:visible.midX-size.width/2,y:visible.minY+18)
 switch position {
 case "top": origin.y=visible.maxY-size.height-18
 case "center": origin.y=visible.midY-size.height/2
 case "left": origin=CGPoint(x:visible.minX+18,y:visible.midY-size.height/2)
 case "right": origin=CGPoint(x:visible.maxX-size.width-18,y:visible.midY-size.height/2)
 default: break
 }
 origin.x=max(visible.minX,min(origin.x,visible.maxX-size.width))
 origin.y=max(visible.minY,min(origin.y,visible.maxY-size.height))
 return CGRect(origin:origin,size:size)
}
struct MinimapRows {
 struct Row { let index: Int; let windowCount: Int; let summary: String }
 let current: Int
 let count: Int
 let rows: [Row]
 init?(_ content: String) {
  let fields=content.components(separatedBy:"\n").map { $0.components(separatedBy:"\t") }
  guard let header=fields.first(where: { $0.first == "#rows" }), header.count >= 3,
   let current=Int(header[1]), let count=Int(header[2]), count > 0, count <= 100, (1...count).contains(current) else { return nil }
  self.current=current; self.count=count
  var byIndex: [Int:Row] = [:]
  for f in fields where f.first == "#row" && f.count >= 4 {
   guard let index=Int(f[1]), (1...count).contains(index), let windows=Int(f[2]), windows >= 0 else { continue }
   byIndex[index]=Row(index:index,windowCount:windows,summary:f[3])
  }
  rows=(max(1,current-1)...min(count,current+1)).map { byIndex[$0] ?? Row(index:$0,windowCount:0,summary:"") }
 }
}

// Full-row HUD data stays independent of the menu overview renderer.
struct HUDRows {
 let current: Int
 let indices: [Int]
 let entries: [Int:[Entry]]
 init?(_ content: String) {
  let fields=content.components(separatedBy:"\n").map { $0.components(separatedBy:"\t") }
  let legacy=MinimapRows(content)
  var current=legacy?.current ?? 1, declared=Set<Int>(), groups: [Int:[Entry]] = [:]
  if let legacy { declared.formUnion(1...legacy.count) }
  for f in fields {
   if f.first == "spatialmeta", f.count >= 2, let row=Int(f[1]), row > 0 { current=row; declared.insert(row) }
   if f.first == "spatialrow", f.count >= 2, let row=Int(f[1]), row > 0 { declared.insert(row) }
   if f.first == "spatial", f.count >= 13, let row=Int(f[1]), row > 0, let col=Int(f[2]), let id=Int(f[3]), id > 0 {
    declared.insert(row)
    groups[row,default:[]].append(Entry(id:id,column:col,app:f[10],bundle:f[11],title:f[12],tabHeight:f[8] == "1" ? 28 : 0,selectedID:Int(f[9]) ?? 0))
   }
  }
  guard !declared.isEmpty else { return nil }
  // Active-window records retain the engine's exact tab metadata and order.
  groups[current]=NavigatorSnapshot(content).entries
  self.current=current; indices=declared.sorted(); entries=groups
 }
}
struct HUDRowsLayout {
 let size: CGSize
 let rowHeight: CGFloat
 let compact: Bool
 init(rowCount: Int, maxColumns: Int, visible: CGRect, style: String) {
  let metrics=HUDMetrics(style)
  let availableHeight=max(28,visible.height-36)
  compact=style == "compact" || (style == "cards" && 2*metrics.pad+CGFloat(rowCount)*(metrics.card.height+metrics.gap)-metrics.gap > availableHeight)
  let effective=HUDMetrics(compact ? "compact":style)
  rowHeight=effective.card.height+effective.gap
  let m=HUDMetrics(compact ? "compact":style)
  let lane=max(m.card.width*2+m.gap,CGFloat(maxColumns)*(m.card.width+m.gap)-m.gap)
  size=CGSize(width:min(950,max(180,visible.width-36),m.left+m.gutter+lane+m.pad),height:min(availableHeight,2*m.pad+CGFloat(rowCount)*rowHeight-m.gap))
 }
}
struct HyperHold {
 var began: TimeInterval?
 var blocked=false
 var revealed=false
 mutating func update(exactHyper: Bool, otherKey: Bool, now: TimeInterval, delay: TimeInterval) -> Bool {
  guard exactHyper else { began=nil; blocked=false; revealed=false; return false }
  if otherKey { blocked=true }
  guard !blocked else { return false }
  if began == nil { began=now }
  if !revealed, now-(began ?? now)>=delay { revealed=true; return true }
  return false
 }
}

// Other-key detection for a bare Hyper hold: the session keyDown counter is sampled
// while the chord is down, so a tap between polls still moves it.
struct KeyCounterWatch {
 var base: UInt32?
 mutating func otherKey(exact: Bool, counter: UInt32) -> Bool {
  guard exact else { base=counter; return false }
  if base == nil { base=counter }
  return counter != base
 }
}
// A mouse press during a bare Hyper hold (Hyper-click) is not a request for the HUD either.
struct ChordInputWatch {
 var keys=KeyCounterWatch(), left=KeyCounterWatch(), right=KeyCounterWatch(), other=KeyCounterWatch()
 mutating func interrupted(exact: Bool, key: UInt32, leftDown: UInt32, rightDown: UInt32, otherDown: UInt32, buttonsDown: Bool) -> Bool {
  let k=keys.otherKey(exact:exact,counter:key), l=left.otherKey(exact:exact,counter:leftDown)
  let r=right.otherKey(exact:exact,counter:rightDown), o=other.otherKey(exact:exact,counter:otherDown)
  return k || l || r || o || (exact && buttonsDown)
 }
}
// A fading HUD must not swallow clicks.
func hudIgnoresMouse(alpha: Double) -> Bool { alpha < 1 }
// Strip motion: window frames of the snapshot's windows, rounded to half points, in id order.
func stripMotionSignature(_ windows: [LiveWindow], ids: Set<Int>) -> [Int] {
 windows.filter { ids.contains($0.id) }.sorted { $0.id < $1.id }.flatMap { w in
  [w.id,Int((w.frame.minX*2).rounded()),Int((w.frame.minY*2).rounded()),Int((w.frame.width*2).rounded()),Int((w.frame.height*2).rounded())]
 }
}
struct StripMotion {
 var last: [Int]?
 mutating func moved(_ signature: [Int]) -> Bool { defer { last=signature }; return last != nil && last != signature }
 mutating func reset() { last=nil }
}
// Keeps `current` when the item is already fully in view, else the smallest scroll that shows it.
func revealOffset(current: CGFloat, visible: CGFloat, itemMin: CGFloat, itemMax: CGFloat, content: CGFloat) -> CGFloat {
 let limit=max(0,content-visible)
 var offset=current
 if itemMax > offset+visible { offset=itemMax-visible }
 if itemMin < offset { offset=itemMin }
 return min(limit,max(0,offset))
}
// What the HUD displays, as a string: equal strings need no rebuild. Titles show only in "titles" style.
func hudRenderSignature(_ rows: HUDRows, focused: Int, viewing: Int?, style: String, position: String, dark: Bool, visible: CGRect, aliases: [String:String]) -> String {
 var out="\(style)|\(position)|\(dark)|\(visible)|\(rows.current)|\(focused)|\(viewing.map(String.init) ?? "-")"
 for row in rows.indices {
  out+="\nrow\(row)"
  for e in rows.entries[row] ?? [] {
   out+="\n\(e.id),\(e.column),\(e.app),\(e.bundle),\(e.tabHeight),\(e.selectedID)"
   if style == "titles" { out+=",\(e.title)" }
  }
 }
 return out+"\n"+aliases.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator:"\n")
}
struct HUDScrollState {
 var lanes: [Int:CGFloat] = [:]
 var fromTop: CGFloat?
}
struct Chord: OptionSet {
 let rawValue: Int
 static let control=Chord(rawValue:1), option=Chord(rawValue:2), command=Chord(rawValue:4)
 static let hyper: Chord = [.control,.option,.command]
 init(rawValue: Int) { self.rawValue=rawValue }
 init(_ flags: NSEvent.ModifierFlags) {
  var c=Chord()
  if flags.contains(.control) { c.insert(.control) }
  if flags.contains(.option) { c.insert(.option) }
  if flags.contains(.command) { c.insert(.command) }
  self=c
 }
}
struct HUDStep {
 var present: HUDPresence.Kind?
 var alpha = 1.0
 var orderOut = false
 var fast = false
}
// Every show/hide decision for the HUD, time-injected so it runs without windows.
// release: keyboard sessions appear revealDelay after the navigation and leave when the chord is
// released (command-tab model). timer: appear at once and linger delay+fade. Scroll gestures are
// always timer-style. Alpha is a pure function of time; the Navigator applies it each fast tick.
struct HUDPresence {
 enum Kind { case show, row, scroll }
 static let revealDelay=0.15, releaseFade=0.12, engageTravel=24.0
 var mode="release", delay=1.3, fade=0.22
 var visible=false, timer=false, forced=false, moved=false
 var chord=Chord(), escapedChord: Chord?
 var pending: (due: TimeInterval, kind: Kind, chord: Chord)?
 // The engine writes show/row intents before it runs the command: render once a newer snapshot
 // lands, or deferWait after the intent, whichever is first. The earliest intent keeps the deadline.
 static let deferWait=0.15
 var deferred: (kind: Kind, mtime: TimeInterval)?
 var anchor: TimeInterval=0, releaseAt: TimeInterval?
 // Hover engages only by intent: the pointer moved into the HUD from outside, or travelled
 // engageTravel inside it. A pointer resting (or nudged) where the HUD appeared never holds it.
 var lastPointer=CGPoint.zero, travel=0.0, wasInside=false
 var fast: Bool { visible || pending != nil }
 func held(_ mods: Chord) -> Bool { !chord.isEmpty && chord.isSubset(of:mods) }
 mutating func present(now: TimeInterval, pointer: CGPoint, timer: Bool, chord: Chord) {
  if !visible { lastPointer=pointer; travel=0; moved=false; wasInside=true }
  visible=true; self.timer=timer; self.chord=chord; anchor=now; releaseAt=nil; forced=false; pending=nil
 }
 mutating func hide() { visible=false; pending=nil; forced=false; releaseAt=nil; moved=false; timer=false; deferred=nil }
 mutating func holdRender(_ kind: Kind, mtime: TimeInterval, now: TimeInterval = .infinity) { deferred=(kind,deferred?.mtime ?? min(mtime,now)) }
 mutating func releaseRender(snapshot: TimeInterval, now: TimeInterval) -> Kind? {
  guard let d=deferred, snapshot > d.mtime || now >= d.mtime+Self.deferWait else { return nil }
  deferred=nil
  if timer { anchor=now }
  return d.kind
 }
 // Ongoing strip motion counts as activity for a scroll (timer) session, like a hold.
 mutating func motion(now: TimeInterval) { if visible && timer { anchor=now; releaseAt=nil } }
 // Returns the kind to render now, or nil (nothing yet, or a reveal is pending).
 mutating func navigate(_ kind: Kind, chord observed: Chord, mtime: TimeInterval, now: TimeInterval, pointer: CGPoint) -> Kind? {
  let t=kind == .scroll || mode == "timer"
  if kind == .scroll { deferred=nil }
  if t || visible { present(now:now,pointer:pointer,timer:t,chord:observed.isEmpty && visible ? chord:observed); return kind }
  guard !observed.isEmpty else { return nil }
  let due=pending.flatMap { $0.chord.isSubset(of:observed) ? $0.due:nil } ?? min(mtime,now)+Self.revealDelay
  pending=(due,kind,observed)
  return nil
 }
 mutating func bareHoldReveal(now: TimeInterval, mods: Chord, pointer: CGPoint) -> Bool {
  if visible { anchor=now; return false }
  if let e=escapedChord, e.isSubset(of:mods) { return false }
  present(now:now,pointer:pointer,timer:mode == "timer",chord:mods); deferred=nil
  return true
 }
 // true: stay and re-render. false: the click committed; the HUD leaves.
 mutating func clickCommitted(chordHeld: Bool, now: TimeInterval) -> Bool {
  guard visible else { return true }
  if mode == "release" && !chordHeld { forced=true; timer=false; releaseAt=nil; return false }
  anchor=now; return true
 }
 // A plain keystroke (no ⌃⌥⌘) means the user moved on: like ⌘Tab, the HUD gets out of the way.
 // Also catches Karabiner's Caps-tap Escape, too brief for a key-state poll.
 mutating func typed(mods: Chord, dragging: Bool) -> Bool {
  guard visible, !dragging, mods.isEmpty else { return false }
  hide(); return true
 }
 mutating func escape(mods: Chord, dragging: Bool) -> Bool {
  guard !dragging, visible || pending != nil else { return false }
  let was=visible
  hide()
  if !mods.isEmpty { escapedChord=mods }
  return was
 }
 mutating func step(now: TimeInterval, mods: Chord, pointer: CGPoint, frame: CGRect, pressing: Bool, tabDrag: Bool) -> HUDStep {
  if let e=escapedChord, !e.isSubset(of:mods) { escapedChord=nil }
  if let p=pending {
   if !p.chord.isSubset(of:mods) { pending=nil }
   else if now >= p.due { present(now:now,pointer:pointer,timer:false,chord:p.chord); deferred=nil; return HUDStep(present:p.kind,alpha:1,fast:true) }
  }
  guard visible else { return HUDStep(alpha:0,fast:pending != nil) }
  let inside=frame.contains(pointer), step=hypot(pointer.x-lastPointer.x,pointer.y-lastPointer.y)
  if !moved, inside {
   if !wasInside && step > 0 { moved=true }
   travel += step; if travel >= Self.engageTravel { moved=true }
  }
  wasInside=inside; lastPointer=pointer
  let busy=pressing || tabDrag
  let hold = busy || (!forced && ((moved && inside) || (timer ? mods.isSuperset(of:[.control,.option]) : held(mods))))
  if hold { anchor=now; releaseAt=nil; return HUDStep(fast:true) }
  var out=HUDStep(fast:true)
  if timer {
   let t=now-anchor
   if t >= delay+fade && t > delay { out.orderOut=true }
   else if t > delay { out.alpha=1-(t-delay)/fade }
  } else {
   let start=releaseAt ?? now, len=min(fade,Self.releaseFade)
   releaseAt=start
   if now-start >= len { out.orderOut=true } else { out.alpha=1-(now-start)/len }
  }
  if out.orderOut { hide(); out.fast=false }
  return out
 }
}

func viewingColumn(_ windows: [(column:Int,x:Double,width:Double)], left:Double, right:Double) -> Int? {
 let center=(left+right)/2
 return windows.filter { min($0.x+$0.width,right) > max($0.x,left) }.min {
  let a=abs(($0.x+$0.width/2)-center), b=abs(($1.x+$1.width/2)-center)
  if a == b { return $0.column < $1.column }
  return a < b
 }?.column
}

func shouldDismiss(visible: Bool, inside: Bool, pressed: Bool = false) -> Bool { !visible || (!inside && !pressed) }
func selectedWindow(_ members: [Entry], focused: Int) -> Int? {
 members.first { $0.id == focused }?.id
  ?? members.first { $0.id == members.first?.selectedID }?.id
  ?? members.first?.id
}
// One icon per app keeps repeated same-app tabs from obscuring other apps.
// Preserve presentation order; focused/remembered selection still owns clicks.
func minimapApps(_ members: [Entry]) -> [Entry] {
 var seen=Set<String>()
 return members.filter { seen.insert($0.bundle.isEmpty ? $0.app : $0.bundle).inserted }
}
struct MinimapIconLayout {
 let frames: [CGRect]
 let hiddenCount: Int
 let labelStart: CGFloat
 init(appCount: Int, cardWidth: CGFloat, style: String) {
  let titles=style == "titles"
  let size:CGFloat=min(style == "cards" ? 26 : style == "compact" ? 20:18,max(18,cardWidth-8))
  let available=max(size,min(titles ? 70 : cardWidth-8,cardWidth-8))
  let step=size*0.5
  let capacity=max(1,Int((available-size)/step)+1)
  let shown=min(max(0,appCount),capacity)
  let span=shown == 0 ? 0 : size+CGFloat(shown-1)*step
  let start:CGFloat=titles ? min(8,max(0,cardWidth-span)) : max(0,(cardWidth-span)/2)
  let y:CGFloat=titles ? 9 : style == "compact" ? 24 : 38
  frames=(0..<shown).map { CGRect(x:start+CGFloat($0)*step,y:y,width:size,height:size) }
  hiddenCount=max(0,appCount-shown)
  labelStart=titles ? start+span+7 : 4
 }
}
enum StripDropKind: String { case column = "reorder-column", tab = "move-tab", detach = "detach-tab" }
struct StripDrop: Equatable {
 let kind: StripDropKind
 let source: Int
 let target: Int
 let before: Bool
 var arguments: [String] { [kind.rawValue,String(source),before ? "before" : "after",String(target)] }
}
struct StripDropTarget {
 let id: Int
 let frame: CGRect
}
// Screen-space targets allow a press to cross nonactivating panel boundaries.
func stripInsertion(at point: CGPoint, targets: [StripDropTarget]) -> (target: StripDropTarget, before: Bool)? {
 guard let first=targets.first, let last=targets.last,
  point.y >= first.frame.minY-5, point.y <= first.frame.maxY+5,
  point.x >= first.frame.minX-12, point.x <= last.frame.maxX+12 else { return nil }
 let target=targets.first { point.x < $0.frame.maxX } ?? last
 return (target,point.x < target.frame.midX)
}
// Card centres group a tab; narrow edge slots extract it as a column.
// Known split columns have no tab landing affordance.
func minimapTabDrop(source: Int, point: CGPoint, targets: [StripDropTarget], entries: [Entry]) -> StripDrop? {
 guard let insertion=stripInsertion(at:point,targets:targets) else { return nil }
 let edge=insertion.before ? insertion.target.frame.minX : insertion.target.frame.maxX
 if abs(point.x-edge) <= 12 { return StripDrop(kind:.detach,source:source,target:insertion.target.id,before:insertion.before) }
 guard let target=entries.first(where: { $0.id == insertion.target.id }),
  let origin=entries.first(where: { $0.id == source }), target.column != origin.column else { return nil }
 let members=entries.filter { $0.column == target.column }
 guard members.count == 1 || members.allSatisfy({ $0.tabHeight > 0 }) else { return nil }
 let anchor=insertion.before ? members.first! : members.last!
 return StripDrop(kind:.tab,source:source,target:anchor.id,before:insertion.before)
}
struct HUDRowDrop {
 let row: Int
 let anchor: Int?
 let after: Bool
 let marker: CGRect
 func arguments(source: Int, sourceRow: Int) -> [String] {
  var args=["move-column-row",String(source),String(sourceRow),String(row)]
  if let anchor { args += [after ? "after" : "before",String(anchor)] }
  else { args.append("append") }
  return args
 }
}
func hudRowDrop(source: Int, sourceRow: Int, point: CGPoint, lanes: [Int:CGRect], cards: [Int:[StripDropTarget]]) -> HUDRowDrop? {
 guard let row=lanes.keys.sorted().first(where: { lanes[$0]!.contains(point) }), let lane=lanes[row] else { return nil }
 let targets=(cards[row] ?? []).filter { $0.id != source }.sorted { $0.frame.minX < $1.frame.minX }
 guard !targets.isEmpty else {
  return row == sourceRow ? nil : HUDRowDrop(row:row,anchor:nil,after:false,marker:CGRect(x:lane.minX+2,y:lane.minY,width:3,height:lane.height))
 }
 let target=targets.first { point.x < $0.frame.midX } ?? targets.last!
 let after=point.x >= target.frame.midX
 return HUDRowDrop(row:row,anchor:target.id,after:after,marker:CGRect(x:after ? target.frame.maxX+2 : target.frame.minX-3,y:lane.minY,width:3,height:lane.height))
}
struct CardDrag {
 var origin: CGPoint?
 var started = false
 var cancelled = false
 mutating func begin(at point: CGPoint) { origin=point; started=false; cancelled=false }
 mutating func update(at point: CGPoint) -> Bool {
  guard let origin, !cancelled else { return false }
  if hypot(point.x-origin.x,point.y-origin.y) >= 6 { started=true }
  return started
 }
 mutating func cancel() { cancelled=true }
 mutating func reset() { self=CardDrag() }
}
final class DropInsertionMark: NSView {
 var color=NSColor.systemTeal
 var outline=false
 override func hitTest(_ point: NSPoint) -> NSView? { nil }
 override func draw(_ dirtyRect: NSRect) {
  if outline { color.setStroke(); let path=NSBezierPath(roundedRect:bounds.insetBy(dx:2,dy:2),xRadius:8,yRadius:8); path.lineWidth=3; path.stroke() }
  else { color.setFill(); bounds.fill() }
 }
}
struct CardPress {
 var armed = false
 mutating func begin() { armed = true }
 mutating func drag(inside: Bool) { if !inside { armed = false } }
 mutating func end(inside: Bool) -> Bool { let fire = armed && inside; armed = false; return fire }
}
func isHyperClick(_ flags: NSEvent.ModifierFlags) -> Bool {
 flags.intersection([.control,.option,.command,.shift,.function]) == [.control,.option,.command]
}
final class ColumnCard: NSView {
 var diagnosticName = "card"
 var entryID = 0
 var hudStyle="cards"
 var hudActive: Bool?
 override func draw(_ dirtyRect: NSRect) {
  guard let active=hudActive else { return }
  let dark=hudDark(self),radius=HUDMetrics(hudStyle).radius
  let path=NSBezierPath(roundedRect:bounds.insetBy(dx:0.75,dy:0.75),xRadius:radius,yRadius:radius)
  hudColor(active ? (dark ? 0x1D4647:0xDCEEEE):(dark ? 0x3A3E3F:0xFFFFFF)).setFill();path.fill()
  (active ? hudColor(dark ? 0x3CC6C4:0x00898B):(dark ? NSColor.white:NSColor.black).withAlphaComponent(dark ? 0.08:0.10)).setStroke()
  path.lineWidth=active ? 1.5:0.5;path.stroke()
 }
 // The tab strip also uses cards and exposes them itself; only the minimap opts in.
 var exposedAsButton = false
 override func isAccessibilityElement() -> Bool { exposedAsButton || super.isAccessibilityElement() }
 override func accessibilityRole() -> NSAccessibility.Role? { exposedAsButton ? .button : super.accessibilityRole() }
 override func accessibilityPerformPress() -> Bool { guard exposedAsButton, let onClick else { return super.accessibilityPerformPress() }; onClick(); return true }
 var onPress: ((Bool) -> Void)?
 var onClick: (() -> Void)?
 var onClickAt: ((CGPoint) -> Void)?
 var onDrag: ((CGPoint) -> Void)?
 var onDrop: ((CGPoint) -> Void)?
 var onCancelDrag: (() -> Void)?
 var drag = CardDrag()
 private var escapeTimer: Timer?
 var press = CardPress()
 var hyperSecondaryPress = false
 override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
 override func hitTest(_ point: NSPoint) -> NSView? {
  bounds.contains(convert(point, from: superview)) ? self : nil
 }
 override func mouseDown(with event: NSEvent) {
  NSLog("Navigator %@ mouseDown button=%d window=%d visible=%d",diagnosticName,event.buttonNumber,window?.windowNumber ?? 0,window?.isVisible == true ? 1 : 0)
  press.begin(); drag.begin(at:event.locationInWindow); onPress?(true)
 }
 // macOS may route Control-click as a secondary mouse event. Hyper
 // includes Control; keep this route equivalent without adopting ordinary
 // right-clicks as focus commands. The release follows its accepted press.
 override func rightMouseDown(with event: NSEvent) {
  guard isHyperClick(event.modifierFlags) else { super.rightMouseDown(with:event); return }
  hyperSecondaryPress=true
  mouseDown(with:event)
 }
 override func rightMouseDragged(with event: NSEvent) {
  if hyperSecondaryPress { mouseDragged(with:event) }
  else { super.rightMouseDragged(with:event) }
 }
 override func rightMouseUp(with event: NSEvent) {
  guard hyperSecondaryPress else { super.rightMouseUp(with:event); return }
  hyperSecondaryPress=false
  mouseUp(with:event)
 }
 deinit { escapeTimer?.invalidate() }
 func watchDragEscape() {
  guard escapeTimer == nil else { return }
  let timer=Timer(timeInterval:0.03,repeats:true) { [weak self] _ in
   if CGEventSource.keyState(.combinedSessionState,key:53) { self?.cancelInteraction() }
  }
  RunLoop.main.add(timer,forMode:.common); escapeTimer=timer
 }
 func cancelInteraction() {
  escapeTimer?.invalidate(); escapeTimer=nil
  let wasDragging=drag.started
  press=CardPress(); drag.cancel(); hyperSecondaryPress=false
  if wasDragging { onCancelDrag?(); NSCursor.arrow.set() }
  onPress?(false)
 }
 override func mouseDragged(with event: NSEvent) {
  if CGEventSource.keyState(.combinedSessionState,key:53) { cancelInteraction(); return }
  if onDrag != nil, drag.update(at:event.locationInWindow) {
   press.armed=false; watchDragEscape()
   if let window { onDrag?(window.convertPoint(toScreen:event.locationInWindow)) }
  } else { press.drag(inside: bounds.contains(convert(event.locationInWindow, from: nil))) }
 }
 override func mouseUp(with event: NSEvent) {
  escapeTimer?.invalidate(); escapeTimer=nil
  let inside=bounds.contains(convert(event.locationInWindow, from:nil))
  let wasDragging=drag.started
  let cancelled=drag.cancelled || CGEventSource.keyState(.combinedSessionState,key:53)
  let fire = press.end(inside:inside) && !wasDragging && !cancelled
  if wasDragging {
   if !cancelled, let window { onDrop?(window.convertPoint(toScreen:event.locationInWindow)) }
   else { onCancelDrag?() }
   NSCursor.arrow.set()
  }
  drag.reset()
  NSLog("Navigator %@ mouseUp inside=%d accepted=%d",diagnosticName,inside ? 1 : 0,fire ? 1 : 0)
  onPress?(false)
  if fire { if let onClickAt { onClickAt(convert(event.locationInWindow, from:nil)) } else { onClick?() } }
 }
}

final class StripPanel: NSPanel {
 override var canBecomeKey: Bool { false }
 override var canBecomeMain: Bool { false }
}
struct Entry { let id: Int; let column: Int; let app: String; let bundle: String; let title: String; var tabHeight: Int = 0; var selectedID: Int = 0 }
final class Navigator: NSObject, NSApplicationDelegate {
 let path: String
 var hudAppearance:NSAppearance?
 var preferences = NavigatorPreferences()
 var preferencesModified = Date.distantPast
 var hyperHold = HyperHold()
 var keyWatch = ChordInputWatch()
 var typedCounter: UInt32 = 0
 var watchTickQueued = false
 var motion = StripMotion()
 var renderRequested = false
 var lastRenderSig: String?
 var observers: [NSObjectProtocol] = []
 var appearanceObservation: NSKeyValueObservation?
 var presence = HUDPresence()
 var escapeWasDown = false
 var fastMode = false
 var fastTimer: Timer?
 var workWatch: DispatchSourceFileSystemObject?
 var statusItem: NSStatusItem?
 #if !NAVIGATOR_TESTS
 var settings: SettingsController?
 let spatialOverview=SpatialOverviewController()
 #endif
 var rootURL: URL { URL(fileURLWithPath:path).deletingLastPathComponent().deletingLastPathComponent() }
 var panel: StripPanel!
 var previous = ""
 var modified = Date.distantPast
 var navigationModifiersHeld = false
 var intentModified = Date.distantPast
 var scrollNavigation = false
 var rowNavigation = false
 var lastViewportColumn: Int?
 var pressingCard = false
 var minimapDropTargets: [StripDropTarget] = []
 var activeHUDCards: [ColumnCard] = []
 var hudRowLanes: [Int:NSView] = [:]
 var hudRowCards: [Int:[ColumnCard]] = [:]
 var minimapDropMark: DropInsertionMark?
 var tabDragRevealed = false
 var liveWindows: [LiveWindow] = []
 var snapshot = NavigatorSnapshot("")
 var lastSnapshotPoll = Date.distantPast
 let tabBars = TabBars()
 var displayLink: CADisplayLink?
 var displayLinkScreen: UInt32?
 var timer: Timer?
 var icons: [String:NSImage] = [:]
 let commandQueue = DispatchQueue(label: "local.paneru.navigator.commands", qos: .userInitiated)
 init(path: String) { self.path=path }
 func applicationDidFinishLaunching(_ notification: Notification) {
  panel=StripPanel(contentRect:.zero,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
  panel.level = .floating
  panel.isOpaque=false; panel.backgroundColor = .clear; panel.hasShadow=true
  panel.ignoresMouseEvents=false
  panel.hidesOnDeactivate=false
  panel.becomesKeyOnlyIfNeeded=true
  panel.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary,.ignoresCycle,.transient]
  panel.animationBehavior = .none
  intentModified = (try? FileManager.default.attributesOfItem(atPath:path.replacingOccurrences(of:".tsv",with:".intent"))[.modificationDate] as? Date) ?? .distantPast
  reloadPreferences()
  let status=NSStatusBar.system.statusItem(withLength:NSStatusItem.variableLength)
  if let image=NSImage(systemSymbolName:"slider.horizontal.3",accessibilityDescription:"Microfish Settings") {
   image.isTemplate=true; status.button?.image=image
  } else { status.button?.title="P" }
  status.button?.toolTip="Microfish Settings"
  status.button?.setAccessibilityLabel("Microfish Settings")
  let menu=NSMenu()
  let heading=NSMenuItem(title:"Microfish",action:nil,keyEquivalent:""); heading.isEnabled=false; menu.addItem(heading)
  let settingsItem=NSMenuItem(title:"Settings…",action:#selector(openSettings),keyEquivalent:""); settingsItem.target=self; menu.addItem(settingsItem)
  let reload=NSMenuItem(title:"Reload preferences",action:#selector(reloadFromMenu),keyEquivalent:""); reload.target=self; menu.addItem(reload)
  status.menu=menu; statusItem=status
  #if !NAVIGATOR_TESTS
  spatialOverview.pinsPath = rootURL.appendingPathComponent("work/state/paneru/view-pins.json").path
  spatialOverview.onViewAction = { [weak self] action, slot in
   self?.sendCommand([action] + (slot.map { [String($0)] } ?? []))
  }
  spatialOverview.onSettings = { [weak self] in self?.openSettings() }
  spatialOverview.onRefresh = { [weak self] completion in
   guard let self else { completion(false); return }
   let root=self.rootURL
   DispatchQueue.global(qos:.userInitiated).async {
    let process=Process(); process.executableURL=URL(fileURLWithPath:"/usr/bin/python3")
    process.arguments=[root.appendingPathComponent("scripts/refresh-microfish.py").path]
    let log=root.appendingPathComponent("work/refresh.log")
    FileManager.default.createFile(atPath:log.path,contents:nil)
    let output=try? FileHandle(forWritingTo:log)
    process.standardOutput=output; process.standardError=output
    var success=false
    do { try process.run(); process.waitUntilExit(); success=process.terminationStatus == 0 } catch { }
    try? output?.close()
    DispatchQueue.main.async { completion(success) }
   }
  }
  spatialOverview.onReload = { [weak self] in self?.reloadPreferences() }
  spatialOverview.onFocus = { [weak self] id in self?.focusWindow(id,updateMinimap:false) }
  spatialOverview.onMove = { [weak self] source, sourceRow, targetRow, anchor, after in
   var arguments = ["move-column-row", String(source), String(sourceRow), String(targetRow)]
   if let anchor { arguments += [after ? "after" : "before", String(anchor)] }
   else { arguments.append("append") }
   self?.sendCommand(arguments) { [weak self] accepted in self?.spatialOverview.showMoveResult(accepted) }
  }
  spatialOverview.attach(to:status)
  #endif
  tabBars.focus = { [weak self] id in self?.focusWindow(id, updateMinimap: false) }
  tabBars.reorder = { [weak self] drop in self?.sendCommand(drop.arguments) }
  tabBars.dragOutside = { [weak self] source, point, commit in
   self?.tabOutsideDrop(source:source,point:point,commit:commit) ?? false
  }
  tabBars.dragFinished = { [weak self] in
   self?.clearMinimapDrop(); self?.tabDragRevealed=false
  }
  // Low-rate lifecycle polling stays alive when all bars are hidden. Visible
  // geometry is paced by the owning display in common run-loop modes.
  let lifecycle = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
   guard let self else { return }
   let screenPresent = NSScreen.screens.contains { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == self.displayLinkScreen }
   if self.displayLink == nil || !screenPresent { self.tick() }
  }
  lifecycle.tolerance = 0.01
  RunLoop.main.add(lifecycle, forMode: .common)
  timer = lifecycle
  watchWorkDirectory()
  observeEnvironment()
 }
 // Spaces, displays, appearance and accessibility options change under a visible HUD.
 func observeEnvironment() {
  let workspace=NSWorkspace.shared.notificationCenter
  observers.append(workspace.addObserver(forName:NSWorkspace.activeSpaceDidChangeNotification,object:nil,queue:.main) { [weak self] _ in self?.hide() })
  observers.append(NotificationCenter.default.addObserver(forName:NSApplication.didChangeScreenParametersNotification,object:nil,queue:.main) { [weak self] _ in self?.rebuildIfVisible() })
  observers.append(workspace.addObserver(forName:NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,object:nil,queue:.main) { [weak self] _ in self?.rebuildIfVisible() })
  appearanceObservation=NSApp.observe(\.effectiveAppearance,options:[.new]) { [weak self] _, _ in DispatchQueue.main.async { self?.rebuildIfVisible() } }
 }
 func rebuildIfVisible() {
  lastRenderSig=nil
  if panel.isVisible { requestRender() }
 }
 func requestRender() { renderRequested=true }
 // The engine publishes by tmp+rename, which modifies the directory: wake at once instead of
 // waiting for the next poll. Polling stays as the fallback.
 func watchWorkDirectory() {
  let fd=open(URL(fileURLWithPath:path).deletingLastPathComponent().path,O_EVTONLY)
  guard fd >= 0 else { return }
  let source=DispatchSource.makeFileSystemObjectSource(fileDescriptor:fd,eventMask:.write,queue:.main)
  // Coalesce bursts (several renames per publish, title storms) to one tick per frame.
  source.setEventHandler { [weak self] in
   guard let self, !self.watchTickQueued else { return }
   self.watchTickQueued=true
   DispatchQueue.main.asyncAfter(deadline:.now()+1.0/120) { [weak self] in self?.watchTickQueued=false; self?.tick(forcePoll:true) }
  }
  source.setCancelHandler { close(fd) }
  source.resume(); workWatch=source
 }
 deinit {
  workWatch?.cancel(); fastTimer?.invalidate()
  observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0); NotificationCenter.default.removeObserver($0) }
 }
 @objc func openSettings() {
  #if !NAVIGATOR_TESTS
  if settings == nil {
   settings=SettingsController(rootURL:rootURL)
   settings?.onApplied = { [weak self] in self?.reloadPreferences() }
  }
  settings?.show()
  #endif
 }
 @objc func reloadFromMenu() { reloadPreferences() }
 func reloadPreferences() {
  let url=rootURL.appendingPathComponent("config/preferences.json")
  preferences=NavigatorPreferences(try? Data(contentsOf:url))
  preferencesModified=(try? FileManager.default.attributesOfItem(atPath:url.path)[.modificationDate] as? Date) ?? .distantPast
  tabBars.aliases=preferences.aliases
  tabBars.style=preferences.tabStyle; tabBars.height=CGFloat(preferences.tabHeight); tabBars.matchAppColor=preferences.tabMatchAppColor
  if panel?.isVisible == true { requestRender() }
 }
 @objc func displayTick(_ sender: CADisplayLink) { tick() }
 func screenID(_ screen: NSScreen) -> UInt32? { (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value }
 func fastNeeded() -> Bool {
  let f=NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
  return presence.fast || (f.contains(.control) && f.contains(.option))
 }
 func updateDisplayLink() {
  let fast=fastNeeded(); fastMode=fast
  let needed = tabBars.hasVisibleBars || (scrollNavigation && panel.isVisible) || fast
  let screen = NSScreen.screens.first { screenID($0) == snapshot.display } ?? (fast ? NSScreen.main : nil)
  let id = screen.flatMap { screenID($0) }
  if !needed || screen == nil {
   displayLink?.invalidate(); displayLink = nil; displayLinkScreen = nil
  } else if displayLink == nil || displayLinkScreen != id {
   displayLink?.invalidate()
   displayLink = screen?.displayLink(target: self, selector: #selector(displayTick(_:)))
   displayLinkScreen = id
   displayLink?.add(to: .main, forMode: .common)
  }
  if fast && displayLink == nil {
   if fastTimer == nil {
    let t=Timer(timeInterval:1.0/60,repeats:true) { [weak self] _ in self?.tick() }
    RunLoop.main.add(t,forMode:.common); fastTimer=t
   }
  } else if let t=fastTimer { t.invalidate(); fastTimer=nil }
 }
 func presentHUD(_ kind: HUDPresence.Kind) {
  // A swipe's first frame needs the strip's current position for the viewing highlight.
  if kind == .scroll && !(scrollNavigation && panel.isVisible) { liveWindows = readLiveWindows() }
  rowNavigation = kind == .row
  scrollNavigation = kind == .scroll
  requestRender()
 }
 // The engine writes the intent before it runs the command: hold the render for its snapshot.
 func navigateHUD(_ kind: HUDPresence.Kind, mtime: TimeInterval) {
  if kind == .scroll { presentHUD(kind) } else { presence.holdRender(kind,mtime:mtime,now:Date.timeIntervalSinceReferenceDate) }
 }
 func tick(forcePoll: Bool = false) {
  let date=Date(), now=date.timeIntervalSinceReferenceDate
  let pollSnapshot = forcePoll || date.timeIntervalSince(lastSnapshotPoll) >= 0.1
  if pollSnapshot {
   lastSnapshotPoll = date
   let prefsPath=rootURL.appendingPathComponent("config/preferences.json").path
   let prefsStamp=(try? FileManager.default.attributesOfItem(atPath:prefsPath)[.modificationDate] as? Date) ?? .distantPast
   if prefsStamp != preferencesModified { reloadPreferences() }
  }
  presence.mode=preferences.hide; presence.delay=preferences.delay; presence.fade=preferences.fade
  if pollSnapshot, let attrs=try? FileManager.default.attributesOfItem(atPath:path), let stamp=attrs[.modificationDate] as? Date, stamp != modified {
   modified=stamp
   if let content=try? String(contentsOfFile:path,encoding:.utf8) {
    previous=content
    snapshot = NavigatorSnapshot(content)
    #if !NAVIGATOR_TESTS
    spatialOverview.update(text:content)
    #endif
    if panel.isVisible { requestRender() }
   }
  }
  if (!snapshot.tabGroups.isEmpty && snapshot.tabsVisible) || (scrollNavigation && panel.isVisible) { liveWindows = readLiveWindows() }
  else { liveWindows = [] }
  if scrollNavigation && panel.isVisible && presence.timer {
   if motion.moved(stripMotionSignature(liveWindows,ids:Set(snapshot.entries.map(\.id)))) { presence.motion(now:now) }
  } else { motion.reset() }
  tabBars.update(snapshot, windows: liveWindows)
  let flags=NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
  let mods=Chord(flags), pointer=NSEvent.mouseLocation
  let intentPath=path.replacingOccurrences(of:".tsv",with:".intent")
  if pollSnapshot || fastMode, let attrs=try? FileManager.default.attributesOfItem(atPath:intentPath), let stamp=attrs[.modificationDate] as? Date, stamp != intentModified {
   intentModified=stamp
   let action=(try? String(contentsOfFile:intentPath,encoding:.utf8)) ?? "hide"
   if let kind=["show":HUDPresence.Kind.show,"row":.row,"scroll":.scroll][action] {
    let mtime=stamp.timeIntervalSinceReferenceDate
    if let k=presence.navigate(kind,chord:mods,mtime:mtime,now:now,pointer:pointer) { navigateHUD(k,mtime:mtime) }
   }
   else {
    let inside=panel.frame.contains(pointer)
    let dismiss=action != "dismiss" || shouldDismiss(visible:panel.isVisible,inside:inside,pressed:pressingCard)
    if panel.isVisible { NSLog("Navigator intent %@ inside=%d pressed=%d dismissed=%d",action,inside ? 1 : 0,pressingCard ? 1 : 0,dismiss ? 1 : 0) }
    if dismiss { hide() }
   }
  }
  if scrollNavigation && panel.isVisible {
   let column = viewportColumn(previous)
   if column != lastViewportColumn { requestRender() }
  }
  let navigationHeld=flags.contains(.control) && flags.contains(.option) && flags.contains(.command)
  if navigationModifiersHeld && !navigationHeld { sendCommand(["view-end"]) }
  navigationModifiersHeld=navigationHeld
  let exactHyper=isHyperClick(flags)
  let counter={ CGEventSource.counterForEventType(.combinedSessionState,eventType:$0) }
  let keys=counter(.keyDown)
  if keys != typedCounter, presence.typed(mods:mods,dragging:pressingCard || tabDragRevealed) { hide() }
  typedCounter=keys
  let otherKey=keyWatch.interrupted(exact:exactHyper,key:keys,leftDown:counter(.leftMouseDown),rightDown:counter(.rightMouseDown),otherDown:counter(.otherMouseDown),buttonsDown:NSEvent.pressedMouseButtons != 0)
  let reveal=hyperHold.update(exactHyper:exactHyper && preferences.showOnHyper,otherKey:otherKey,now:now,delay:preferences.hyperDelay)
  // Physical Escape (edge) dismisses at once, unless a card press or drag owns it.
  let escapeDown=CGEventSource.keyState(.combinedSessionState,key:53)
  if escapeDown && !escapeWasDown && presence.escape(mods:mods,dragging:pressingCard || tabDragRevealed) { hide() }
  escapeWasDown=escapeDown
  // A hold must not change an already-running scroll HUD to focus mode.
  if reveal && presence.bareHoldReveal(now:now,mods:mods,pointer:pointer) { presentHUD(.show) }
  if presence.visible && !panel.isVisible && !renderRequested && presence.deferred == nil { presence.hide() }
  let out=presence.step(now:now,mods:mods,pointer:pointer,frame:panel.frame,pressing:pressingCard,tabDrag:tabDragRevealed)
  if let k=out.present { presentHUD(k) }
  else if out.orderOut { hide() }
  else if presence.visible { panel.alphaValue=CGFloat(out.alpha); panel.ignoresMouseEvents=hudIgnoresMouse(alpha:out.alpha) }
  // Mission Control and Show Desktop clear the HUD, and nothing presents during them.
  if !snapshot.tabsVisible && (panel.isVisible || presence.visible || presence.pending != nil || renderRequested) { hide() }
  if let k=presence.releaseRender(snapshot:modified.timeIntervalSinceReferenceDate,now:now) { presentHUD(k) }
  if renderRequested { render(previous) }
  updateDisplayLink()
 }
 func hide() {
  cancelTabPresses(in:panel.contentView)
  clearMinimapDrop(); minimapDropTargets=[]
  pressingCard = false
  renderRequested = false
  panel.orderOut(nil)
  presence.hide()
 }
 // Read window geometry only while the swipe HUD is visible. This neither
 // captures screen pixels nor changes focus, and needs no Accessibility grant.
 func viewportColumn(_ content: String) -> Int? {
  let lines=content.components(separatedBy:"\n")
  let header=lines.first?.components(separatedBy:"\t") ?? []
  guard header.count >= 2, let display=UInt32(header[1]),
   let screen=NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value==display }) else { return nil }
  var columns: [Int:Int] = [:]
  for line in lines.dropFirst() {
   let fields=line.components(separatedBy:"\t")
   if fields.count >= 2, let id=Int(fields[0]), let col=Int(fields[1]) { columns[id]=col }
  }
  var candidates: [(column:Int,x:Double,width:Double)] = []
  for window in liveWindows {
   guard let col=columns[window.id] else { continue }
   candidates.append((col,window.frame.minX,window.frame.width))
  }
  return viewingColumn(candidates, left:screen.visibleFrame.minX, right:screen.visibleFrame.maxX)
 }
 func focusWindow(_ id: Int, updateMinimap: Bool = true) {
  if updateMinimap {
   let mods=Chord(NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask))
   if presence.clickCommitted(chordHeld:presence.held(mods),now:Date.timeIntervalSinceReferenceDate) {
    scrollNavigation = false
    rowNavigation = false
    render(previous)
   }
  }
  sendCommand(["focus",String(id)])
 }
 func sendCommand(_ arguments: [String], completion: ((Bool) -> Void)? = nil) {
  let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
   .deletingLastPathComponent().appendingPathComponent("PaneruNavigatorCommand")
  NSLog("Navigator command queued %@",arguments.joined(separator:" "))
  commandQueue.async { [weak self] in
   let command = Process()
   command.executableURL = executable
   command.arguments = arguments
   command.standardOutput = FileHandle.nullDevice
   let errors=Pipe(); command.standardError = errors
   do {
    try command.run()
    let diagnostic=String(data:errors.fileHandleForReading.readDataToEndOfFile(),encoding:.utf8) ?? ""
    command.waitUntilExit()
    if command.terminationStatus != 0 {
     NSLog("Navigator command rejected: %@",diagnostic)
     DispatchQueue.main.async { [weak self] in self?.showCommandFailure(arguments.first ?? "",diagnostic:diagnostic) }
    }
    let accepted = command.terminationStatus == 0
    DispatchQueue.main.async { completion?(accepted) }
    NSLog("Navigator command finished %@ status=%d",arguments.first ?? "",command.terminationStatus)
   }
   catch {
    DispatchQueue.main.async { completion?(false) }
    NSLog("Navigator command failed: %@",error.localizedDescription)
    DispatchQueue.main.async { [weak self] in self?.showCommandFailure(arguments.first ?? "",diagnostic:error.localizedDescription) }
   }
  }
 }
 func showCommandFailure(_ action: String, diagnostic: String) {
  guard let screen=NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == snapshot.display }) ?? NSScreen.main else { return }
  let width=min(340,screen.visibleFrame.width-64), height:CGFloat=62
  let effect=makeFailureHUD(action:action,diagnostic:diagnostic,width:width)
  cancelTabPresses(in:panel.contentView)
  clearMinimapDrop(); minimapDropTargets=[]; panel.contentView=effect
  panel.setFrame(minimapFrame(size:CGSize(width:width,height:height),visible:screen.visibleFrame,position:preferences.position),display:true)
  panel.invalidateShadow(); lastRenderSig=nil; renderRequested=false
  presence.present(now:Date.timeIntervalSinceReferenceDate,pointer:NSEvent.mouseLocation,timer:true,chord:[]); presence.deferred=nil
  panel.alphaValue=1; panel.ignoresMouseEvents=false; panel.orderFrontRegardless()
 }
 func clearMinimapDrop() { minimapDropMark?.removeFromSuperview(); minimapDropMark=nil }
 func minimapInsertion(_ point: CGPoint) -> (target: StripDropTarget,before: Bool)? {
  guard panel.isVisible else { return nil }
  refreshHUDDropTargets()
  return stripInsertion(at:point,targets:minimapDropTargets)
 }
 func showMinimapInsertion(_ insertion: (target: StripDropTarget,before: Bool)?, detaching: Bool = false) {
  clearMinimapDrop()
  guard let insertion, let view=panel.contentView else { return }
  let frame=insertion.target.frame
  let local=panel.convertPoint(fromScreen:CGPoint(x:insertion.before ? frame.minX-3 : frame.maxX+3,y:frame.minY))
  let mark=DropInsertionMark(frame:CGRect(x:local.x-1.5,y:local.y,width:3,height:frame.height))
  mark.color=detaching ? .systemOrange : .systemTeal
  view.addSubview(mark); minimapDropMark=mark
 }
 func columnDrag(source: Int, point: CGPoint, commit: Bool) {
  let insertion=minimapInsertion(point)
  let valid=insertion.flatMap { $0.target.id == source ? nil : $0 }
  showMinimapInsertion(valid)
  if commit {
   if let valid { sendCommand(StripDrop(kind:.column,source:source,target:valid.target.id,before:valid.before).arguments) }
   clearMinimapDrop()
  } else { (valid == nil ? NSCursor.operationNotAllowed : NSCursor.closedHand).set() }
 }
 func visibleScreenFrame(_ view: NSView) -> CGRect? {
  guard let window=view.window else { return nil }
  var frame=view.convert(view.bounds,to:nil)
  var parent=view.superview
  while let ancestor=parent {
   if ancestor is NSClipView { frame=frame.intersection(ancestor.convert(ancestor.bounds,to:nil)) }
   parent=ancestor.superview
  }
  guard !frame.isNull, frame.width > 3, frame.height > 3 else { return nil }
  return window.convertToScreen(frame)
 }
 func rowCardDrag(source: Int, sourceRow: Int, point: CGPoint, commit: Bool) {
  let lanes=hudRowLanes.compactMapValues { visibleScreenFrame($0) }
  let cards=hudRowCards.mapValues { cards in cards.compactMap { card in
   visibleScreenFrame(card).map { StripDropTarget(id:card.entryID,frame:$0) }
  } }
  let drop=hudRowDrop(source:source,sourceRow:sourceRow,point:point,lanes:lanes,cards:cards)
  clearMinimapDrop()
  if let drop, let view=panel.contentView {
   let mark=DropInsertionMark(frame:panel.convertFromScreen(drop.marker)); view.addSubview(mark); minimapDropMark=mark
  }
  if commit {
   if let drop { sendCommand(drop.arguments(source:source,sourceRow:sourceRow)) }
   clearMinimapDrop()
  } else { (drop == nil ? NSCursor.operationNotAllowed : NSCursor.closedHand).set() }
 }
 func tabOutsideDrop(source: Int, point: CGPoint, commit: Bool) -> Bool {
  if !tabDragRevealed, !commit {
   tabDragRevealed=true
   // An already-running session (e.g. Hyper held) keeps its chord; the drag only adds a hold.
   if !presence.visible {
    rowNavigation=false; scrollNavigation=false
    presence.present(now:Date.timeIntervalSinceReferenceDate,pointer:NSEvent.mouseLocation,timer:preferences.hide == "timer",chord:[])
   }
   render(previous)
  }
  let drop=panel.isVisible ? minimapTabDrop(source:source,point:point,targets:minimapDropTargets,entries:snapshot.entries) : nil
  if let drop, drop.kind == .tab, let insertion=minimapInsertion(point), let view=panel.contentView {
   clearMinimapDrop()
   let frame=panel.convertFromScreen(insertion.target.frame)
   let mark=DropInsertionMark(frame:frame); mark.outline=true
   view.addSubview(mark); minimapDropMark=mark
  } else { showMinimapInsertion(drop == nil ? nil : minimapInsertion(point),detaching:true) }
  if commit, let drop { sendCommand(drop.arguments) }
  return drop != nil
 }
 func makeHUDCard(_ members: [Entry], column col: Int, focused: Int, active: Bool, interactive: Bool, frame: CGRect, style: String) -> ColumnCard {
  let cardWidth=frame.width, cardHeight=frame.height
  let compact=style == "compact", titles=style == "titles"
   let chosen=members.first { $0.id == selectedWindow(members,focused:focused) } ?? members[0]
   let card=ColumnCard(frame:frame)
   card.appearance=hudAppearance
   card.diagnosticName="minimap column=\(col) target=\(chosen.id)"
   let sourceID=members.first!.id
   card.entryID=sourceID
   card.onPress = { [weak self] pressed in self?.pressingCard = pressed }
   if interactive {
   card.onDrag = { [weak self] point in self?.columnDrag(source:sourceID,point:point,commit:false) }
   card.onDrop = { [weak self] point in self?.columnDrag(source:sourceID,point:point,commit:true) }
   card.onCancelDrag = { [weak self] in self?.clearMinimapDrop() }
   }
   card.onClick = { [weak self] in
    guard let self, self.panel.isVisible, let id = selectedWindow(members, focused: focused) else { return }
    NSLog("Navigator minimap click column=%d target=%d snapshotFocused=%d",col,id,focused)
    self.focusWindow(id)
   }
   card.wantsLayer=true; card.layer?.cornerRadius=10
   card.hudActive=active;card.hudStyle=style
   card.exposedAsButton=true
   var apps=minimapApps(members)
   if let selected=selectedWindow(members,focused:focused), let member=members.first(where:{$0.id==selected}), let i=apps.firstIndex(where:{$0.bundle==member.bundle}) {
    apps.remove(at:i);apps.append(member)
   }
   let iconLayout=MinimapIconLayout(appCount:apps.count,cardWidth:cardWidth,style:style)
   let displayedApps=iconLayout.hiddenCount > 0 ? Array(apps.prefix(max(0,iconLayout.frames.count-1)))+Array(apps.suffix(1)):apps
   card.onClickAt = { [weak self, weak card] point in
    guard let self, self.panel.isVisible else { return }
    if let target=Array(zip(displayedApps,iconLayout.frames)).reversed().first(where: { $0.1.contains(point) }) {
     self.focusWindow(target.0.id)
    } else { card?.onClick?() }
   }
   for (app,frame) in zip(displayedApps,iconLayout.frames) {
    let icon=NSImageView(frame:frame)
    if icons[app.bundle]==nil, let url=NSWorkspace.shared.urlForApplication(withBundleIdentifier:app.bundle) { icons[app.bundle]=NSWorkspace.shared.icon(forFile:url.path) }
    icon.image=icons[app.bundle] ?? NSImage(named:NSImage.applicationIconName)
    icon.toolTip=app.app
    if app.id == selectedWindow(members,focused:focused), apps.count>1 {
     icon.wantsLayer=true;icon.shadow=NSShadow();icon.shadow?.shadowOffset=NSSize(width:-1,height:0);icon.shadow?.shadowBlurRadius=1.5;icon.shadow?.shadowColor=NSColor.black.withAlphaComponent(0.35)
    }
    card.addSubview(icon)
   }
   if iconLayout.hiddenCount > 0 {
    let overflow=NSTextField(labelWithString:"+\(iconLayout.hiddenCount)")
    overflow.frame=NSRect(x:cardWidth-25,y:titles ? 0 : compact ? 14 : 25,width:23,height:13)
    overflow.font = .monospacedDigitSystemFont(ofSize:9,weight:.bold)
    overflow.alignment = .right
    card.addSubview(overflow)
   }
   let alias=preferences.aliases[chosen.bundle+"\t"+chosen.title]
   let label=NSTextField(labelWithString:titles ? (alias ?? (chosen.title.isEmpty ? chosen.app : chosen.title)) : chosen.app)
   card.toolTip=apps.map { $0.app }.joined(separator:", ")+" — "+(alias ?? chosen.title)
   label.frame=NSRect(x:iconLayout.labelStart,y:titles ? (cardHeight-16)/2 : compact ? 7:18,width:max(0,cardWidth-iconLayout.labelStart-(titles && members.count>1 ? 28:8)),height:14);label.font = .systemFont(ofSize:titles ? 12:compact ? 10:11,weight:active ? .semibold : .regular)
   label.textColor=hudColor(hudDark(card) ? (active ? 0xF5F5F7:0xE5E5E7):(active ? 0x1D1D1F:0x3A3A3C))
   label.alignment = titles ? .left:.center;label.lineBreakMode = .byTruncatingTail
   card.addSubview(label)
   if members.count>1 {
    let badge=HUDBadge(labelWithString:"\(members.count)")
    let bh:CGFloat=compact ? 13:15,bw:CGFloat=max(bh,CGFloat(String(members.count).count)*6+6)
    badge.frame=NSRect(x:cardWidth-bw-(compact ? 4:5),y:titles ? (cardHeight-bh)/2:compact ? 4:5,width:bw,height:bh);badge.font = .monospacedDigitSystemFont(ofSize:9.5,weight:.bold)
    badge.textColor=hudDark(card) ? hudColor(0x062626):.white
    badge.alignment = .center;card.addSubview(badge)
   }
   if !interactive { card.toolTip=(card.toolTip ?? "")+" · another row" }
   card.setAccessibilityLabel("\(members.map { $0.app }.joined(separator:", "))\(active ? ", current" : "")\(interactive ? "" : ", another row")")
   return card
 }
 func refreshHUDDropTargets() {
  guard !activeHUDCards.isEmpty else { return }
  minimapDropTargets=activeHUDCards.compactMap { card in
   guard let window=card.window else { return nil }
   var frame=card.convert(card.bounds,to:nil)
   var parent=card.superview
   while let view=parent {
    if view is NSClipView { frame=frame.intersection(view.convert(view.bounds,to:nil)) }
    parent=view.superview
   }
   guard !frame.isNull, frame.width > 3 else { return nil }
   return StripDropTarget(id:card.entryID,frame:window.convertToScreen(frame))
  }
 }
 // Build a real HUD view independently of NSPanel ordering for headless rendering.
 func makeRowsHUD(_ rows: HUDRows, focused: Int, viewing: Int?, visible: CGRect, appearance: NSAppearance? = nil, scroll state: HUDScrollState = HUDScrollState()) -> NSView {
  activeHUDCards=[]; hudRowLanes=[:]; hudRowCards=[:]
  let maxColumns=rows.entries.values.map { Set($0.map(\.column)).count }.max() ?? 0
  let layout=HUDRowsLayout(rowCount:rows.indices.count,maxColumns:maxColumns,visible:visible,style:preferences.style)
  let root=RoundedHUDView(frame:CGRect(origin:.zero,size:layout.size))
  let dark=(appearance ?? NSApp?.effectiveAppearance ?? NSAppearance.currentDrawing()).bestMatch(from:[.aqua,.darkAqua]) == .darkAqua
  root.appearance=NSAppearance(named:dark ? .vibrantDark : .vibrantLight)
  root.material = .hudWindow; root.blendingMode = .behindWindow; root.state = .active
  root.wantsLayer=true; root.layer?.cornerRadius=16; root.layer?.masksToBounds=true
  root.setAccessibilityLabel("Minimap")
  hudAppearance=root.appearance
  let style=layout.compact ? "compact":preferences.style,m=HUDMetrics(style)
  let heights=rows.indices.map { (rows.entries[$0] ?? []).isEmpty ? min(m.emptyHeight,layout.rowHeight-m.gap):layout.rowHeight-m.gap }
  let contentHeight=2*m.pad+heights.reduce(0,+)+CGFloat(max(0,heights.count-1))*m.gap
  root.setFrameSize(CGSize(width:layout.size.width,height:min(layout.size.height,contentHeight)))
  var rowTop=contentHeight-m.pad
  var currentSpan=(min:CGFloat(0),max:CGFloat(0))
  let canvas=NSView(frame:CGRect(x:0,y:0,width:layout.size.width,height:contentHeight))
  for (index,row) in rows.indices.enumerated() {
   let current=row == rows.current
   let rowHeight=heights[index],y=rowTop-rowHeight
   rowTop=y-m.gap
   if current { currentSpan=(y,y+rowHeight) }
   let label=NSTextField(labelWithString:"\(current ? "●" : "○") \(row)")
   label.frame=CGRect(x:m.left,y:y+(rowHeight-16)/2,width:m.gutter,height:16)
   label.font = .monospacedSystemFont(ofSize:style == "compact" ? 11:12,weight:current ? .semibold : .regular)
   label.textColor=hudColor(dark ? (current ? 0x3CC6C4:0xA1A1A6):(current ? 0x00777A:0x6E6E73))
   label.setAccessibilityLabel("Row \(row)\(current ? ", current" : "")")
   canvas.addSubview(label)
   let entries=rows.entries[row] ?? [], groups=Dictionary(grouping:entries,by:{$0.column}), columns=groups.keys.sorted()
   if columns.isEmpty {
    let lane=HUDEmptySlot(frame:CGRect(x:m.left+m.gutter,y:y,width:layout.size.width-m.left-m.gutter-m.pad,height:rowHeight))
    canvas.addSubview(lane); hudRowLanes[row]=lane
    let empty=NSTextField(labelWithString:"Empty row")
    empty.frame=CGRect(x:0,y:(rowHeight-16)/2,width:lane.frame.width,height:16)
    empty.alignment = .center;empty.font = .systemFont(ofSize:11); empty.textColor = .secondaryLabelColor; lane.addSubview(empty)
    continue
   }
   let preferred=m.card.width
   let laneWidth=layout.size.width-m.left-m.gutter-m.pad
   // Normal counts fit together. Extreme columns remain reachable by scrolling,
   // with a visible scroller rather than dropping app identities.
   let cardWidth=max(32,min(preferred,(laneWidth-CGFloat(columns.count-1)*m.gap)/CGFloat(columns.count)))
   let stripWidth=max(laneWidth,CGFloat(columns.count)*(cardWidth+m.gap)-m.gap)
   let strip=NSView(frame:CGRect(x:0,y:0,width:stripWidth,height:rowHeight))
   var activeSpan: (min:CGFloat,max:CGFloat)?
   for (offset,col) in columns.enumerated() {
    let members=groups[col]!
    let active=current && (viewing.map { $0 == col } ?? members.contains { $0.id == focused })
    let card=makeHUDCard(members,column:col,focused:current ? focused : 0,active:active,interactive:current,frame:CGRect(x:CGFloat(offset)*(cardWidth+m.gap),y:0,width:cardWidth,height:rowHeight),style:style)
    if active && activeSpan == nil { activeSpan=(card.frame.minX,card.frame.maxX) }
    let sourceID=members.first!.id
    card.onDrag = { [weak self] point in self?.rowCardDrag(source:sourceID,sourceRow:row,point:point,commit:false) }
    card.onDrop = { [weak self] point in self?.rowCardDrag(source:sourceID,sourceRow:row,point:point,commit:true) }
    card.onCancelDrag = { [weak self] in self?.clearMinimapDrop() }
    card.toolTip=(card.toolTip ?? "")+" · drag to move this column between rows"
    hudRowCards[row,default:[]].append(card)
    strip.addSubview(card)
    if current { activeHUDCards.append(card) }
   }
   let scroll=NSScrollView(frame:CGRect(x:m.left+m.gutter,y:y,width:laneWidth,height:rowHeight))
   scroll.scrollerStyle = .overlay; scroll.drawsBackground=false; scroll.hasHorizontalScroller=stripWidth > laneWidth+1; scroll.autohidesScrollers=false
   scroll.documentView=strip; canvas.addSubview(scroll); hudRowLanes[row]=scroll
   if stripWidth > laneWidth+1 {
    // Keep the lane where the viewer left it; the active card is always brought into view.
    let kept=min(stripWidth-laneWidth,max(0,state.lanes[row] ?? 0))
    let x=activeSpan.map { revealOffset(current:kept,visible:laneWidth,itemMin:$0.min,itemMax:$0.max,content:stripWidth) } ?? kept
    scroll.contentView.scroll(to:CGPoint(x:x,y:0)); scroll.reflectScrolledClipView(scroll.contentView)
   }
   if stripWidth > laneWidth+1 {
    let overflow=NSTextField(labelWithString:"↔")
    overflow.frame=CGRect(x:20,y:y+2,width:24,height:13); overflow.font = .systemFont(ofSize:10)
    overflow.textColor = .secondaryLabelColor
    overflow.toolTip="Scroll horizontally for all \(columns.count) columns"
    overflow.setAccessibilityLabel(overflow.toolTip)
    canvas.addSubview(overflow)
   }
  }
  if contentHeight > root.frame.height {
   let scroll=NSScrollView(frame:root.bounds); scroll.drawsBackground=false; scroll.hasVerticalScroller=true
   scroll.documentView=canvas; root.addSubview(scroll)
   let top=contentHeight-root.frame.height
   let y=revealOffset(current:state.fromTop.map { top-$0 } ?? top,visible:root.frame.height,itemMin:currentSpan.min,itemMax:currentSpan.max,content:contentHeight)
   scroll.contentView.scroll(to:CGPoint(x:0,y:y)); scroll.reflectScrolledClipView(scroll.contentView)
  } else { root.addSubview(canvas) }
  return root
 }
 // What a rebuild would lose: each lane's horizontal offset and the many-rows vertical offset.
 func captureScroll() -> HUDScrollState {
  var state=HUDScrollState()
  guard panel?.isVisible == true else { return state }
  for (row,lane) in hudRowLanes { if let scroll=lane as? NSScrollView { state.lanes[row]=scroll.contentView.bounds.origin.x } }
  if let scroll=panel.contentView?.subviews.compactMap({ $0 as? NSScrollView }).first, let document=scroll.documentView {
   state.fromTop=document.frame.height-(scroll.contentView.bounds.origin.y+scroll.contentView.bounds.height)
  }
  return state
 }
 func render(_ content: String) {
  // Snapshot/highlight ticks must not replace the view tracking a mouse press.
  guard !pressingCard else { return }
  renderRequested=false
  let header=content.components(separatedBy:"\n").first?.components(separatedBy:"\t") ?? []
  guard header.count>=2 else { return }
  let focused=Int(header[0]) ?? 0; let display=UInt32(header[1]) ?? 0
  guard let screen=NSScreen.screens.first(where: { screenID($0) == display }) ?? NSScreen.main else { hide(); return }
  // The single-row path uses the same presentation and hit targets.
  guard let model=HUDRows(content) ?? (NavigatorSnapshot(content).entries.isEmpty ? nil : HUDRows(content+"\n#rows\t1\t1\nspatialrow\t1\n")) else {
   clearMinimapDrop(); minimapDropTargets=[]; activeHUDCards=[]; hudRowLanes=[:]; hudRowCards=[:]; lastRenderSig=nil
   panel.orderOut(nil); return
  }
  let viewing=scrollNavigation ? viewportColumn(content) : nil
  lastViewportColumn=viewing
  let dark=(NSApp?.effectiveAppearance ?? NSAppearance.currentDrawing()).bestMatch(from:[.aqua,.darkAqua]) == .darkAqua
  let signature=hudRenderSignature(model,focused:focused,viewing:viewing,style:preferences.style,position:preferences.position,dark:dark,visible:screen.visibleFrame,aliases:preferences.aliases)
  if panel.isVisible && signature == lastRenderSig { return }
  let scrollState=captureScroll(), presenting = !panel.isVisible
  clearMinimapDrop(); minimapDropTargets=[]; activeHUDCards=[]; hudRowLanes=[:]; hudRowCards=[:]
  lastRenderSig=signature
  let view=makeRowsHUD(model,focused:focused,viewing:viewing,visible:screen.visibleFrame,scroll:scrollState)
  // AppKit resizes an assigned content view to the panel’s existing size.
  // Capture the desired size first; a newly created panel is zero-sized.
  panel.setFrame(minimapFrame(size:view.frame.size,visible:screen.visibleFrame,position:preferences.position),display:false)
  panel.contentView=view
  panel.invalidateShadow()
  refreshHUDDropTargets()
  if presenting { panel.alphaValue=1; panel.ignoresMouseEvents=false }
  panel.orderFrontRegardless()
 }
}
#if !NAVIGATOR_TESTS
let app=NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate=Navigator(path:CommandLine.arguments[1])
app.delegate=delegate
app.run()

#endif
