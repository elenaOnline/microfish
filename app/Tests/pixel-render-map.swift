// Offscreen renders of the menu map in fixed states; argv[1] is the output directory. Never opens a window.
// With -D LEAK_NEWAPI each state is also built through SpatialContentView.make after the pooled content view has
// already served other snapshots and sizes (the popover's second and later opens).
import AppKit
let fixture = """
spatialmeta	3	0	0	1200	900	21
spatialrow	1
spatialrow	2
spatialrow	3
spatialrow	4
spatialrow	5
spatialrow	6
spatial	2	0	11	-600	0	600	900	0	11	Mail	com.apple.mail	Inbox
spatial	3	0	21	0	0	600	900	1	21	Editor	com.apple.TextEdit	Document
spatial	3	0	22	0	0	600	900	1	21	Browser	com.apple.Safari	Research
spatial	3	1	23	600	0	900	450	0	23	Terminal	com.apple.Terminal	Shell
spatial	3	1	24	600	450	900	450	0	23	Notes	com.apple.Notes	Notes
spatial	4	0	31	0	0	900	900	0	31	Music	com.apple.Music	Playlist
spatial	4	1	32	900	0	600	900	0	32	Calendar	com.apple.iCal	Calendar
"""
let out = CommandLine.arguments[1]
_ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
var written = 0
func render(_ view: NSView, _ name: String) {
 view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
 let bitmap = view.bitmapImageRepForCachingDisplay(in:view.bounds)!
 view.cacheDisplay(in:view.bounds,to:bitmap)
 try! bitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:out+"/"+name+".png")); written += 1
 writeDescription(view, out+"/"+name+".txt")
}
let snap = SpatialSnapshot(fixture)
let pinJSON = #"{"display":1,"display_size":[1200,900],"columns":[[{"id":21,"width":600,"height":900},{"id":22,"width":600,"height":900}],[{"id":23,"width":900,"height":450},{"id":24,"width":900,"height":450}]],"origin":[-300,30]}"#
let pin = try! JSONDecoder().decode(SpatialPin.self,from:Data(pinJSON.utf8))
var long = "spatialmeta\t1\t0\t0\t1200\t900\t1\nspatialrow\t1\n"
for i in 0..<18 { long += "spatial\t1\t\(i)\t\(i+1)\t\(i*600)\t0\t600\t900\t0\t\(i+1)\tEditor\tcom.apple.TextEdit\tDocument \(i+1)\n" }
let emptySnap = SpatialSnapshot("spatialmeta\t2\t0\t0\t1200\t900\t0\nspatialrow\t1\nspatialrow\t2\nspatialrow\t3\n")
let longSnap = SpatialSnapshot(long)
#if LEAK_NEWAPI
// Serve other content first so the pooled view is dirty: a narrow width (borderless icon buttons), a disabled refresh button,
// a status message, pins, a long scrolled map.
func dirtyThePool() {
 let d = SpatialContentView.make(snapshot: longSnap, available: NSSize(width: 264, height: 300))
 d.refreshButton.isEnabled = false; d.message = "Refreshing windows…"; d.mapView.pins = [2: pin]
 d.scrollView.contentView.scroll(to: CGPoint(x: 500, y: 0)); d.appearance = NSAppearance(named: .darkAqua)
 SpatialContentView.recycle(d)
}
func build(_ s: SpatialSnapshot, _ size: NSSize, _ reused: Bool) -> SpatialContentView {
 if reused { dirtyThePool(); return SpatialContentView.make(snapshot: s, available: size) }
 return SpatialContentView(snapshot: s, available: size)
}
let modes = [false, true]
#else
func build(_ s: SpatialSnapshot, _ size: NSSize, _ reused: Bool) -> SpatialContentView { SpatialContentView(snapshot: s, available: size) }
let modes = [false]
#endif
for reused in modes { let suffix = reused ? "-REUSED" : ""
 for dark in [false,true] {
  let ap = NSAppearance(named: dark ? .darkAqua : .aqua)!, tag = dark ? "dark" : "light"
  let p = build(snap, NSSize(width:900,height:900), reused); p.appearance = ap; p.mapView.pins = [2:pin]; render(p,"main-\(tag)\(suffix)")
  let n = build(snap, NSSize(width:264,height:900), reused); n.appearance = ap; render(n,"narrow-\(tag)\(suffix)")
  let e = build(emptySnap, NSSize(width:480,height:900), reused); e.appearance = ap; render(e,"empty-\(tag)\(suffix)")
  let l = build(longSnap, NSSize(width:640,height:360), reused); l.appearance = ap
  l.scrollView.contentView.scroll(to:CGPoint(x:240,y:0)); render(l,"long-\(tag)\(suffix)")
  let busy = build(snap, NSSize(width:900,height:900), reused); busy.appearance = ap; busy.refreshButton.isEnabled = false; busy.message = "Refreshing windows…"; render(busy,"busy-\(tag)\(suffix)")
  let d = build(snap, NSSize(width:900,height:900), reused); d.appearance = ap
  let t = d.mapView.map.tiles.first { $0.window.id == 11 }!
  d.mapView.begin(tile:t,point:CGPoint(x:t.rect.midX,y:t.rect.midY))
  d.mapView.track(point:CGPoint(x:d.mapView.map.tiles.first { $0.window.id == 23 }!.rect.minX-5,y:d.mapView.map.rowFrames[3]!.midY))
  render(d,"drag-\(tag)\(suffix)"); d.mapView.cancelDrag()
 }
}
print("rendered", written)
