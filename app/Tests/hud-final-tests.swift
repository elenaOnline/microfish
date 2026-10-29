// Final-sweep HUD fixes: failure copy and lifetime, Increase Contrast, narrow cards, AX, status menu, drop mark. Headless:
// the panel is never ordered (ordersPanel=false), nothing reaches the screen or the engine.
var finalChecks = 0
func fcheck(_ c: @autoclosure () -> Bool, _ m: String) { precondition(c(), m); finalChecks += 1 }
func fwalk(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(fwalk) }

// 1. Copy by action; view-end silent; unreachable engine named
do {
 fcheck(failureCopy(action:"view-end",diagnostic:"Navigator: no process is registered under that service name") == nil,"view-end failure is never shown")
 fcheck(failureCopy(action:"focus",diagnostic:"window is no longer tiled")?.title == "Couldn’t switch to that window","focus title")
 fcheck(failureCopy(action:"focus",diagnostic:"x")?.detail == "The layout changed. Try again.","detail")
 for a in ["move-column-row","reorder-column"] { fcheck(failureCopy(action:a,diagnostic:"")?.title == "Couldn’t move that column",a) }
 for a in ["move-tab","detach-tab","move"] { fcheck(failureCopy(action:a,diagnostic:"")?.title == "Couldn’t move that window",a) }
 fcheck(failureCopy(action:"view-save",diagnostic:"")?.title == "Couldn’t save the view","view-save")
fcheck(failureCopy(action:"view-pin",diagnostic:"")?.title == "Couldn’t go to that view","view-pin")
 for a in ["focus","view-pin","move-tab"] {
  let c=failureCopy(action:a,diagnostic:"Navigator: no process is registered under that service name")
  fcheck(c?.title == "Microfish isn’t running" && c?.detail == "Open Microfish to turn it back on.","unreachable via \(a)")
 }
 fcheck(failureCopy(action:"focus",diagnostic:"Navigator: the peer has exited")?.title == "Microfish isn’t running","peer gone is unreachable too")
 let all=["focus","move-tab","view-pin","undo-move","view-back"].compactMap { failureCopy(action:$0,diagnostic:"")?.title }
 fcheck(all.allSatisfy { !$0.contains("confirmed") && !$0.lowercased().contains("pin") && !$0.lowercased().contains("engine") },"no engine-speak or 'pin' in titles")
}

// 1b. The view: no raw diagnostic tooltip, one AX element with the message
do {
 let v=FailureHUDView(frame:.zero)
 v.configure(action:"focus",diagnostic:"minimap column=3 target=1234 secret",width:340,appearance:NSAppearance(named:.aqua))
 fcheck(v.detail.toolTip == nil && v.title.toolTip == nil && v.toolTip == nil,"no diagnostic tooltip")
 fcheck(v.isAccessibilityElement() && v.accessibilityLabel() == "Couldn’t switch to that window. The layout changed. Try again.","failure HUD is one labelled element")
 fcheck(!v.title.isAccessibilityElement() && !v.detail.isAccessibilityElement() && !v.warning.isAccessibilityElement(),"children are not separate stops")
 var clicks=0; v.onClick={ clicks += 1 }
 fcheck(v.hitTest(NSPoint(x:100,y:30)) === v,"hit lands on the view, not a label")
 let e=NSEvent.mouseEvent(with:.leftMouseDown,location:NSPoint(x:100,y:30),modifierFlags:[],timestamp:0,windowNumber:0,context:nil,eventNumber:0,clickCount:1,pressure:1)!
 v.mouseDown(with:e)
 fcheck(clicks == 1,"a click dismisses")
}

// 2. Lifetime: independent of Hide after / Fade out; a snapshot render doesn't replace it; click and navigation end it
func fixtureNav() -> Navigator {
 let nav=Navigator(path:"/tmp/none/navigator.tsv")
 nav.panel=StripPanel(contentRect:.zero,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:true)
 nav.ordersPanel=false
 nav.preferences.delay=0.6; nav.preferences.fade=0.06   // 0.66 s total
 nav.tick()   // primes the keystroke and Escape baselines, as the running helper has
 return nav
}
do {
 let nav=fixtureNav()
 let t0=Date.timeIntervalSinceReferenceDate
 nav.showCommandFailure("view-end",diagnostic:"no process is registered")
 fcheck(nav.failureUntil == nil && nav.panel.contentView !== nav.failureHUD,"view-end failure: nothing shown")
 nav.showCommandFailure("focus",diagnostic:"x")
 fcheck(nav.panel.contentView === nav.failureHUD,"focus failure installed")
 fcheck(abs((nav.failureUntil ?? 0)-t0-3.0) < 0.5,"lives about 3 s, not minimapDelay+fade")
 // a snapshot render while it is up leaves it alone
 let snap="11\t1\t1\n11\t1\tAlpha\tcom.a\tOne\n#rows\t1\t1\nspatialrow\t1\n"
 nav.previous=snap; nav.snapshot=NavigatorSnapshot(snap)
 nav.requestRender(); nav.render(snap)
 fcheck(nav.panel.contentView === nav.failureHUD && nav.failureUntil != nil,"snapshot render does not replace the failure HUD")
 nav.rebuildIfVisible()
 fcheck(nav.panel.contentView === nav.failureHUD,"appearance/contrast rebuild keeps the failure HUD")
 // the tick before expiry keeps it
 nav.tick()
 fcheck(nav.failureUntil != nil,"still up before expiry")
 // expiry
 nav.failureUntil=Date.timeIntervalSinceReferenceDate-0.01
 nav.tick()
 fcheck(nav.failureUntil == nil,"gone after its own lifetime")
 // click dismisses
 nav.showCommandFailure("focus",diagnostic:"x")
 nav.failureHUD.onClick?()
 fcheck(nav.failureUntil == nil && !nav.panel.isVisible,"click dismisses")
 // a navigation (deferred render) takes over
 nav.showCommandFailure("focus",diagnostic:"x")
 nav.presence.holdRender(.show,mtime:Date.timeIntervalSinceReferenceDate)
 nav.tick()
 fcheck(nav.failureUntil == nil,"a navigation replaces the message")
 nav.hide()
 // after dismissal minimap renders again
 nav.render(snap)
 fcheck(nav.panel.contentView !== nav.failureHUD,"minimap renders again once the failure is gone")
}

// 3. Increase Contrast
do {
 let rows=HUDRows("11\t1\t1\n#rows\t1\t1\nspatialrow\t1\n")!
 let a=hudRenderSignature(rows,focused:11,viewing:nil,style:"cards",position:"center",dark:false,visible:CGRect(x:0,y:0,width:1512,height:949),aliases:[:])
 let b=hudRenderSignature(rows,focused:11,viewing:nil,style:"cards",position:"center",dark:false,visible:CGRect(x:0,y:0,width:1512,height:949),aliases:[:],contrast:true)
 fcheck(a != b,"Increase Contrast is part of the render signature")
 func snap(_ ic: Bool, active: Bool) -> [UInt8] {
  hudIncreaseContrastOverride=ic; defer { hudIncreaseContrastOverride=nil }
  let card=ColumnCard(frame:CGRect(x:0,y:0,width:108,height:72)); card.hudActive=active; card.hudStyle="cards"
  card.appearance=NSAppearance(named:.aqua)
  let rep=card.bitmapImageRepForCachingDisplay(in:card.bounds)!; card.cacheDisplay(in:card.bounds,to:rep)
  return Array(UnsafeBufferPointer(start:rep.bitmapData!,count:rep.bytesPerRow*rep.pixelsHigh))
 }
 func darkness(_ px: [UInt8]) -> Int { stride(from:0,to:px.count,by:4).reduce(0) { $0+255-Int(px[$1]) } }   // red channel: the fill is the same, only the stroke differs
 // Relative, not an absolute pixel margin: the rep's size follows the backing scale (2x on a Retina Mac, 1x on a CI
 // runner), and macOS 26 draws the stroke a little lighter than 27. Measured: macOS 27 Retina 1.229x, macOS 26 on CI 1.116x.
 let icDark=darkness(snap(true,active:false)), plainDark=darkness(snap(false,active:false))
 print("  Increase Contrast stroke darkness: \(icDark) vs \(plainDark) (x\(String(format:"%.3f",Double(icDark)/Double(max(plainDark,1)))))")
 fcheck(Double(icDark) > Double(plainDark)*1.08,"\(icDark) vs \(plainDark): inactive card stroke is stronger with Increase Contrast")
 fcheck(snap(true,active:true) != snap(false,active:true),"active ring changes with Increase Contrast")
 let slot=HUDEmptySlot(frame:CGRect(x:0,y:0,width:200,height:36)); slot.appearance=NSAppearance(named:.aqua)
 func slotBytes(_ ic: Bool) -> [UInt8] { hudIncreaseContrastOverride=ic; defer { hudIncreaseContrastOverride=nil }; let r=slot.bitmapImageRepForCachingDisplay(in:slot.bounds)!; slot.cacheDisplay(in:slot.bounds,to:r); return Array(UnsafeBufferPointer(start:r.bitmapData!,count:r.bytesPerRow*r.pixelsHigh)) }
 fcheck(slotBytes(true) != slotBytes(false),"empty-slot stroke changes with Increase Contrast")
 fcheck(slotBytes(false) == slotBytes(false),"default render is stable")
}

// 4. Narrow cards lose their label rather than showing "…"; the scroll cue is timer-only (hud suite covers the cue)
do {
 let nav=Navigator(path:"/tmp/none/navigator.tsv")
 var many="0\t1\t1\n#rows\t1\t2\nspatialrow\t1\nspatialrow\t2\n"
 for col in 1...40 { many += "spatial\t2\t\(col)\t\(7000+col)\t0\t0\t100\t100\t0\t0\tSafari\tcom.apple.Safari\tWindow\n" }
 let v=nav.makeRowsHUD(HUDRows(many)!,focused:0,viewing:nil,visible:CGRect(x:0,y:0,width:700,height:500))
 let cards=fwalk(v).compactMap { $0 as? ColumnCard }
 fcheck(cards.count == 40 && cards.allSatisfy { $0.frame.width < 56 },"40 columns make narrow cards: \(cards.count) \(cards.first?.frame.width ?? -1)")
 let labels=cards.flatMap { c in c.subviews.compactMap { $0 as? NSTextField } }
 fcheck(labels.allSatisfy { $0.stringValue != "…" && $0.stringValue != "Safari" },"no card shows a label that would read only …")
 fcheck(cards.allSatisfy { $0.toolTip != nil && $0.accessibilityLabel()?.contains("Safari") == true },"cards keep tooltip and VoiceOver name")
 let few=nav.makeRowsHUD(HUDRows("11\t1\t1\n11\t1\tSafari\tcom.apple.Safari\tHome\n#rows\t1\t1\nspatialrow\t1\n")!,focused:11,viewing:nil,visible:CGRect(x:0,y:0,width:1512,height:949))
 fcheck(fwalk(few).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "Safari" },"a normal card keeps its label")
}

// 5. Accessibility of the minimap
do {
 let nav=Navigator(path:"/tmp/none/navigator.tsv")
 let c="11\t1\t1\n11\t1\tAlpha\tcom.a\tOne\n12\t2\tBeta\tcom.b\tTwo\n#rows\t1\t1\nspatialrow\t1\n"
 let v=nav.makeRowsHUD(HUDRows(c)!,focused:11,viewing:nil,visible:CGRect(x:0,y:0,width:1512,height:949))
 fcheck(v.isAccessibilityElement() && v.accessibilityRole() == .group && v.accessibilityLabel() == "Minimap","the Minimap label is on a real AX group")
 let cards=fwalk(v).compactMap { $0 as? ColumnCard }
 fcheck(cards.allSatisfy { ($0.accessibilityChildren() ?? []).isEmpty },"cards expose no image or text children")
 // tooltips
 fcheck(minimapCardTooltip(apps:["Safari"],title:"") == "Safari","empty title: tooltip is just the app name")
 fcheck(minimapCardTooltip(apps:["Safari","Notes"],title:"Inbox") == "Safari, Notes — Inbox","tooltip with title")
 fcheck(cards.allSatisfy { !($0.toolTip ?? "").contains(" · ") },"no middot glue in card tooltips")
}

// 6/7/8. Drop mark teal, status menu, canHide
do {
 let mark=DropInsertionMark(frame:CGRect(x:0,y:0,width:20,height:20))
 func px(_ dark: Bool) -> (r:Int,g:Int,b:Int) {
  mark.appearance=NSAppearance(named:dark ? .darkAqua : .aqua)
  let r=mark.bitmapImageRepForCachingDisplay(in:mark.bounds)!; mark.cacheDisplay(in:mark.bounds,to:r)
  let c=r.colorAt(x:10,y:10)!.usingColorSpace(.sRGB)!
  return (Int((c.redComponent*255).rounded()),Int((c.greenComponent*255).rounded()),Int((c.blueComponent*255).rounded()))
 }
 let l=px(false), d=px(true)
 fcheck(abs(l.r-0x00) <= 2 && abs(l.g-0x7F) <= 2 && abs(l.b-0x81) <= 2,"drop mark light is #007F81: \(l)")
 fcheck(abs(d.r-0x3C) <= 2 && abs(d.g-0xC6) <= 2 && abs(d.b-0xC4) <= 2,"drop mark dark is #3CC6C4: \(d)")
 let nav=Navigator(path:"/tmp/none/navigator.tsv")
 let menu=nav.makeStatusMenu()
 let titles=menu.items.map { $0.isSeparatorItem ? "-" : $0.title }
 fcheck(titles == ["Settings…","Check for Updates…","-","Quit Microfish"],"status menu has no header row: \(titles)")
 fcheck(menu.items[1].action == #selector(Navigator.checkForUpdates(_:)) && menu.items[1].target === nav,"Check for Updates… sits right after Settings…")
 fcheck(!nav.validateMenuItem(menu.items[1]),"Check for Updates… is disabled without an updater")
 fcheck(menu.items[0].keyEquivalent == "," && menu.items[0].keyEquivalentModifierMask == .command,"Settings… is ⌘,")
 #if compiler(>=6.4)  // NSMenuItem.preferredImageVisibility is in the macOS 27 SDK only (as in the sources)
 if #available(macOS 27.0, *) { fcheck(menu.items.filter { !$0.isSeparatorItem }.allSatisfy { $0.preferredImageVisibility == .hidden },"no row carries an image") }
 #endif
}
print("Final HUD checks passed:", finalChecks)
