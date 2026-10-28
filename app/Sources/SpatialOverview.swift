import AppKit

private func mapColor(_ hex:UInt32)->NSColor { NSColor(srgbRed:CGFloat((hex>>16)&255)/255,green:CGFloat((hex>>8)&255)/255,blue:CGFloat(hex&255)/255,alpha:1) }
private func mapDark(_ view:NSView)->Bool { view.effectiveAppearance.bestMatch(from:[.aqua,.darkAqua]) == .darkAqua }
private func mapTeal(_ view:NSView)->NSColor { mapColor(mapDark(view) ? 0x3CC6C4:0x00898B) }


struct SpatialWindow: Equatable {
    let row: Int, column: Int, id: Int
    let frame: CGRect
    let tabbed: Bool
    let selected: Int
    let app: String, bundle: String, title: String
}
struct SpatialSnapshot: Equatable {
    let activeRow: Int
    let focused: Int
    let viewport: CGRect
    let windows: [SpatialWindow]
    let declaredRows: [Int]
    init(_ text: String) {
        var active = 0, focused = 0, viewport = CGRect.zero, windows: [SpatialWindow] = []
        var declared = Set<Int>(), hasActive = false
        for line in text.components(separatedBy: "\n") {
            let f = line.components(separatedBy: "\t")
            if f.first == "spatialrow", f.count >= 2, let row = Int(f[1]) { declared.insert(row) }
            if f.first == "spatialmeta", f.count >= 6, let row = Int(f[1]), let x = Double(f[2]), let y = Double(f[3]), let w = Double(f[4]), let h = Double(f[5]), [x,y,w,h].allSatisfy({ $0.isFinite }), w > 0, h > 0 {
                active = row; hasActive = true; focused = f.count > 6 ? Int(f[6]) ?? 0 : 0; viewport = CGRect(x: x, y: y, width: w, height: h)
            }
            if f.first == "spatial", f.count >= 13, let row = Int(f[1]), let column = Int(f[2]), let id = Int(f[3]), id > 0, let x = Double(f[4]), let y = Double(f[5]), let w = Double(f[6]), let h = Double(f[7]), [x,y,w,h].allSatisfy({ $0.isFinite }), w > 0, h > 0 {
                windows.append(SpatialWindow(row: row, column: column, id: id, frame: CGRect(x: x, y: y, width: w, height: h), tabbed: f[8] == "1", selected: Int(f[9]) ?? 0, app: f[10], bundle: f[11], title: f[12]))
            }
        }
        self.activeRow = active; self.focused = focused; self.viewport = viewport; self.windows = windows; if hasActive { declared.insert(active) }; declaredRows = declared.sorted()
    }
    var rows: [Int] { Array(Set(windows.map(\.row)).union(declaredRows)).sorted() }
}
struct SpatialTile {
    let window: SpatialWindow
    let rect: CGRect
    let selected: Bool
}
struct SpatialMapLayout {
    let tiles: [SpatialTile]
    let viewports: [Int: CGRect]
    let rowFrames: [Int: CGRect]
    let height: CGFloat
    let width: CGFloat
    static let rowHeight: CGFloat = 72
    init(snapshot: SpatialSnapshot, width requestedWidth: CGFloat) {
        let rows = snapshot.rows
        let gutter: CGFloat = 36, inset: CGFloat = 10
        let minX = min(snapshot.viewport.minX, snapshot.windows.map { $0.frame.minX }.min() ?? 0)
        let maxX = max(snapshot.viewport.maxX, snapshot.windows.map { $0.frame.maxX }.max() ?? 1)
        let smallest = snapshot.windows.map { $0.frame.width }.min() ?? 1200
        let scale = max(68 / max(1, smallest), max(1, requestedWidth-gutter-inset) / max(1, maxX-minX))
        width = max(requestedWidth, gutter + (maxX-minX)*scale + inset)
        height = max(72, CGFloat(rows.count) * Self.rowHeight + 12)
        var tiles: [SpatialTile] = [], ports: [Int: CGRect] = [:], frames: [Int: CGRect] = [:]
        for (index, row) in rows.enumerated() {
            let members = snapshot.windows.filter { $0.row == row }
            let rect = CGRect(x: gutter, y: 8 + CGFloat(index) * Self.rowHeight, width: max(1, width-gutter-inset), height: 64)
            frames[row] = rect
            let minY = min(snapshot.viewport.minY, members.map { $0.frame.minY }.min() ?? 0)
            let maxY = max(snapshot.viewport.maxY, members.map { $0.frame.maxY }.max() ?? 1)
            let scaleY = rect.height / max(1, maxY-minY)
            func map(_ frame: CGRect) -> CGRect { CGRect(x: rect.minX + (frame.minX-minX)*scale, y: rect.minY + (frame.minY-minY)*scaleY, width: frame.width*scale, height: frame.height*scaleY) }
            if snapshot.viewport.width > 0 && row == snapshot.activeRow { ports[row] = map(snapshot.viewport) }
            for column in Set(members.map(\.column)).sorted() {
                let group = members.filter { $0.column == column }
                let tabbed=group.contains { $0.tabbed }
                let displayed=tabbed ? [group.first(where:{$0.id == $0.selected}) ?? group[0]]:group
                for member in displayed {
                    let raw=map(member.frame)
                    let tile=raw.insetBy(dx:min(3,raw.width*0.06),dy:min(3,raw.height*0.06))
                    if tile.width>0 && tile.height>0 {tiles.append(SpatialTile(window:member,rect:tile,selected:member.id == member.selected))}
                }
            }
        }
        self.tiles = tiles; self.viewports = ports; self.rowFrames = frames
    }
}
struct SpatialPin: Decodable, Equatable {
    struct Member: Decodable, Equatable { let id: Int; let width: Int; let height: Int }
    let display: UInt32
    let display_size: [Int]
    let columns: [[Member]]
    let origin: [Int]
    func row(in snapshot: SpatialSnapshot) -> Int? {
        guard origin.count == 2, display_size.count == 2, display_size.allSatisfy({ $0 > 0 }), !columns.isEmpty else { return nil }
        return snapshot.rows.first { row in
            let windows = snapshot.windows.filter { $0.row == row }
            let groups = Dictionary(grouping: windows, by: \.column)
            let ordered = groups.keys.sorted().map { groups[$0]! }
            return ordered.count == columns.count && zip(ordered,columns).allSatisfy { live,saved in
                Set(live.map(\.id)) == Set(saved.map(\.id)) && saved.allSatisfy { member in
                    live.contains { $0.id == member.id && abs($0.frame.width-CGFloat(member.width)) <= 2 && abs($0.frame.height-CGFloat(member.height)) <= 2 }
                }
            }
        }
    }
}
func spatialPinColor(_ slot: Int) -> NSColor {
    let colors: [NSColor] = [.systemBlue,.systemOrange,.systemPurple,.systemPink,.systemGreen,.systemIndigo,.systemRed,.systemBrown,.systemCyan,.systemYellow]
    return colors[max(0,min(9,slot))]
}
struct SpatialDrop: Equatable {
    let sourceID: Int, sourceRow: Int, row: Int
    let anchor: Int?
    let after: Bool
    let markerX: CGFloat
}
struct SpatialDrag {
    let sourceID: Int, sourceRow: Int, sourceColumn: Int
    let origin: CGPoint
    var moved = false
    mutating func track(_ point: CGPoint) { if hypot(point.x-origin.x, point.y-origin.y) >= 6 { moved = true } }
}
func spatialDrop(snapshot: SpatialSnapshot, map: SpatialMapLayout, drag: SpatialDrag, point: CGPoint) -> SpatialDrop? {
    guard point.x >= 0, point.x <= map.width,
          let row = snapshot.rows.enumerated().first(where: { index, _ in
              let y = CGFloat(index)*SpatialMapLayout.rowHeight
              let height = index == snapshot.rows.count-1 ? map.height-y : SpatialMapLayout.rowHeight
              return CGRect(x: 0,y: y,width: map.width,height: height).contains(point)
          })?.element else { return nil }
    let candidates = map.tiles.filter { $0.window.row == row && !($0.window.row == drag.sourceRow && $0.window.column == drag.sourceColumn) }
    let columns = Dictionary(grouping: candidates, by: { $0.window.column })
    let ordered = columns.keys.sorted()
    guard !ordered.isEmpty else {
        if row == drag.sourceRow { return nil }
        return SpatialDrop(sourceID: drag.sourceID, sourceRow: drag.sourceRow, row: row, anchor: nil, after: false, markerX: map.rowFrames[row]!.minX+4)
    }
    for column in ordered {
        let group = columns[column]!
        let rect = group.map(\.rect).reduce(CGRect.null) { $0.union($1) }
        if point.x < rect.midX {
            let target = group.first(where: { $0.window.id == $0.window.selected }) ?? group[0]
            let result = SpatialDrop(sourceID: drag.sourceID, sourceRow: drag.sourceRow, row: row, anchor: target.window.id, after: false, markerX: rect.minX-2)
            return spatialDropChangesOrder(result, snapshot: snapshot, drag: drag) ? result : nil
        }
    }
    let group = columns[ordered.last!]!, rect = group.map(\.rect).reduce(CGRect.null) { $0.union($1) }
    let target = group.first(where: { $0.window.id == $0.window.selected }) ?? group[0]
    let result = SpatialDrop(sourceID: drag.sourceID, sourceRow: drag.sourceRow, row: row, anchor: target.window.id, after: true, markerX: rect.maxX+2)
    return spatialDropChangesOrder(result, snapshot: snapshot, drag: drag) ? result : nil
}
private func spatialDropChangesOrder(_ drop: SpatialDrop, snapshot: SpatialSnapshot, drag: SpatialDrag) -> Bool {
    if drop.row != drag.sourceRow { return true }
    let before = Array(Set(snapshot.windows.filter { $0.row == drag.sourceRow }.map(\.column))).sorted()
    guard let anchor = snapshot.windows.first(where: { $0.id == drop.anchor })?.column else { return false }
    var after = before.filter { $0 != drag.sourceColumn }
    guard let i = after.firstIndex(of: anchor) else { return false }
    after.insert(drag.sourceColumn, at: i + (drop.after ? 1 : 0)); return after != before
}
func spatialScrollOffset(viewport: CGRect, document: CGSize, point: CGPoint) -> CGPoint {
    guard viewport.contains(point) else { return viewport.origin }
    let edge: CGFloat = 24, step: CGFloat = 16
    var result = viewport.origin
    if point.y < viewport.minY+edge { result.y -= step }
    else if point.y > viewport.maxY-edge { result.y += step }
    if point.x < viewport.minX+edge { result.x -= step }
    else if point.x > viewport.maxX-edge { result.x += step }
    result.x = max(0,min(max(0,document.width-viewport.width),result.x))
    result.y = max(0,min(max(0,document.height-viewport.height),result.y))
    return result
}
// NSControl, not NSButton: on macOS 27 every NSButton that joins a window leaks two
// NSKeyValueDependency objects when released, and this view is rebuilt on every snapshot.
private final class SpatialHitButton: NSControl {
    weak var owner: SpatialMapView?
    let tile: SpatialTile
    init(tile: SpatialTile, owner: SpatialMapView) {
        self.tile = tile; self.owner = owner; super.init(frame: tile.rect)
        target = self; action = #selector(pressed)
        toolTip = "\(tile.window.app) — \(tile.window.title). Drag to move the whole column."
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(tile.window.app), \(tile.window.title)")
        setAccessibilityHelp("Row \(tile.window.row), column \(tile.window.column + 1). Press to focus this window. Drag to move the whole column.")
        if owner.snapshot.focused == tile.window.id { setAccessibilityValueDescription("Current window") }
        setAccessibilityCustomActions(owner.moveActions(for: tile))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {}
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }  // as NSButton did
    override func mouseDown(with event: NSEvent) { owner?.begin(tile: tile, event: event) }
    override func mouseDragged(with event: NSEvent) { owner?.track(event: event) }
    override func mouseUp(with event: NSEvent) { owner?.finish(event: event) }
    @objc private func pressed() { owner?.focus(tile.window) }
    override func accessibilityPerformPress() -> Bool { owner?.focus(tile.window); return true }
}
/// Drawn-only targets (pin badges, overflow pills) exposed to VoiceOver.
private final class SpatialAXElement: NSAccessibilityElement {
    weak var owner: SpatialMapView?
    var rect: CGRect = .zero
    var press: (() -> Void)?
    override func accessibilityFrame() -> NSRect {
        guard let owner, let window = owner.window else { return .zero }
        return window.convertToScreen(owner.convert(rect, to: nil))
    }
    override func accessibilityPerformPress() -> Bool { guard let press else { return false }; press(); return true }
}
final class SpatialMapView: NSView {
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    private(set) var snapshot: SpatialSnapshot
    var onFocus: ((Int) -> Void)?
    var onMove: ((Int, Int, Int, Int?, Bool) -> Void)?
    var onDragState: ((Bool) -> Void)?
    private(set) var map: SpatialMapLayout
    private(set) var drag: SpatialDrag?
    private var drop: SpatialDrop?
    private var pending: SpatialSnapshot?
    private var monitor: Any?
    private var dragTimer: Timer?
    private var lastWindowPoint: CGPoint?
    var hasDragTimer: Bool { dragTimer != nil }
    var pins: [Int: SpatialPin] = [:] { didSet { if pins != oldValue { needsDisplay = true } } }
    var pinPadding: CGFloat = 4 { didSet { if pinPadding != oldValue { needsDisplay = true } } }
    private var icons: [String: NSImage] = [:]
    private var missingIcons = Set<String>()
    /// Counts repaint requests (observable even without an on-screen window).
    private(set) var displayRequests = 0
    override var needsDisplay: Bool { willSet { if newValue { displayRequests += 1 } } }
    var onEscape: (() -> Void)?
    /// Test hook; nil follows System Settings > Accessibility > Display > Increase contrast.
    var increaseContrastOverride: Bool?
    private var increaseContrast: Bool { increaseContrastOverride ?? NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast }
    private var requestedWidth: CGFloat
    init(snapshot: SpatialSnapshot, width: CGFloat, onFocus: ((Int) -> Void)?) {
        self.snapshot = snapshot; self.map = SpatialMapLayout(snapshot: snapshot, width: width); self.onFocus = onFocus; requestedWidth = width
        super.init(frame: CGRect(x: 0, y: 0, width: map.width, height: map.height))
        setAccessibilityElement(true); setAccessibilityRole(.group); setAccessibilityLabel("Windows by row"); rebuild()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(displayEnvironmentChanged), name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(displayEnvironmentChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }
    @objc private func displayEnvironmentChanged(_ note: Notification) { needsDisplay = true }
    // Dark/light switches while the popover is open must repaint the hand-drawn map.
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit {
        dragTimer?.invalidate(); if let monitor { NSEvent.removeMonitor(monitor) }
        NSWorkspace.shared.notificationCenter.removeObserver(self); NotificationCenter.default.removeObserver(self)
    }
    /// True when a newer snapshot no longer has the dragged window in its row, so the drop could only target stale data.
    private func dragSourceGone(in next: SpatialSnapshot) -> Bool {
        guard let state = drag else { return false }
        return !next.windows.contains { $0.id == state.sourceID && $0.row == state.sourceRow }
    }
    func update(_ snapshot: SpatialSnapshot, force: Bool = false) {
        if drag != nil {
            if snapshot == self.snapshot { pending = nil; return }
            pending = snapshot
            if dragSourceGone(in: snapshot) { cancelDrag() }
            return
        }
        // The engine rewrites the snapshot constantly; an identical one must not rebuild or repaint.
        if !force && snapshot == self.snapshot { return }
        self.snapshot = snapshot; map = SpatialMapLayout(snapshot: snapshot, width: requestedWidth)
        setFrameSize(NSSize(width: map.width, height: map.height)); rebuild(); needsDisplay = true
    }
    func resizeViewport(width: CGFloat) { if abs(width-requestedWidth) > 0.5 { cancelDrag(); requestedWidth = max(1,width); update(snapshot, force: true) } }
    private func rebuild() {
        subviews.forEach { $0.removeFromSuperview() }
        for tile in map.tiles { addSubview(SpatialHitButton(tile: tile, owner: self)) }
    }
    func focus(_ window: SpatialWindow) { onFocus?(window.id) }
    func begin(tile: SpatialTile, event: NSEvent) { begin(tile: tile, point: convert(event.locationInWindow, from: nil)) }
    func begin(tile: SpatialTile, point: CGPoint) {
        cancelDrag(); guard point.x >= visibleRect.minX+36 else { return }; drag = SpatialDrag(sourceID: tile.window.id, sourceRow: tile.window.row, sourceColumn: tile.window.column, origin: point)
        window?.makeFirstResponder(self)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.cancelDrag(); return nil }; return event
        }
    }
    func track(event: NSEvent) { track(point: convert(event.locationInWindow, from: nil)) }
    func track(point: CGPoint) {
        guard var state = drag else { return }
        let wasMoved = state.moved; state.track(point); drag = state; lastWindowPoint = convert(point, to: nil)
        if state.moved {
            if !wasMoved {
                onDragState?(true)
                let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.scrollDrag() }
                dragTimer = timer; RunLoop.main.add(timer, forMode: .common)
            }
            drop = spatialDrop(snapshot: snapshot, map: map, drag: state, point: point); needsDisplay = true
        }
    }
    func scrollDrag() {
        guard let state = drag, state.moved, let position = lastWindowPoint, let scroll = enclosingScrollView else { return }
        let point = convert(position, from: nil)
        let offset = spatialScrollOffset(viewport: visibleRect, document: bounds.size, point: point)
        scroll.contentView.scroll(to: offset); scroll.reflectScrolledClipView(scroll.contentView)
        drop = spatialDrop(snapshot: snapshot, map: map, drag: state, point: convert(position, from: nil)); needsDisplay = true
    }
    func finish(event: NSEvent) { finish(point: convert(event.locationInWindow, from: nil)) }
    func finish(point: CGPoint) {
        guard let state = drag else { return }
        var target = state.moved && visibleRect.contains(point) ? spatialDrop(snapshot: snapshot, map: map, drag: state, point: point) : nil
        // A snapshot queued during the drag can remove the anchor the drop was computed against.
        // Commit only if the source column and the anchor are still where the drop was computed.
        if let next = pending, let t = target {
            let column = { (id: Int) in next.windows.first(where: { $0.id == id }).map { ($0.row, $0.column) } }
            let before = { (id: Int) in self.snapshot.windows.first(where: { $0.id == id }).map { ($0.row, $0.column) } }
            let sourceSame = column(t.sourceID).map { $0 == (t.sourceRow, before(t.sourceID)?.1 ?? -1) } ?? false
            let anchorSame = t.anchor.map { a in column(a).map { $0 == (t.row, before(a)?.1 ?? -1) } ?? false } ?? true
            if !sourceSame || !anchorSame { target = nil }
        }
        let clicked = !state.moved ? map.tiles.first(where: { $0.window.id == state.sourceID && $0.rect.contains(point) })?.window : nil
        cancelDrag()
        if let target { onMove?(target.sourceID, target.sourceRow, target.row, target.anchor, target.after) }
        else if let clicked { focus(clicked) }
    }
    override func cancelOperation(_ sender: Any?) { if drag != nil { cancelDrag() } else { onEscape?() } }
    override func keyDown(with event: NSEvent) { if event.keyCode == 53 { cancelOperation(self) } else { super.keyDown(with: event) } }
    func cancelDrag() {
        dragTimer?.invalidate(); dragTimer = nil; lastWindowPoint = nil
        drag = nil; drop = nil
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        onDragState?(false)
        if let pending { self.pending = nil; update(pending) }; needsDisplay = true
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) { if newWindow == nil { cancelDrag() }; super.viewWillMove(toWindow: newWindow) }
    var onPin: ((Int) -> Void)?
    private var pressedPin: Int?
    private var pressedOverflow:Bool?
    func pinGeometry() -> [(slot:Int, rect:CGRect, badge:CGRect)] {
        var result: [(slot:Int, rect:CGRect, badge:CGRect)] = []
        for slot in pins.keys.sorted() {
            guard let pin = pins[slot], let row = pin.row(in:snapshot), let lane = map.rowFrames[row],
                  let screen = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == pin.display }) else { continue }
            let minX = min(snapshot.viewport.minX, snapshot.windows.map { $0.frame.minX }.min() ?? 0)
            let maxX = max(snapshot.viewport.maxX, snapshot.windows.map { $0.frame.maxX }.max() ?? 1)
            let scale = lane.width / max(1,maxX-minX)
            let x = screen.frame.minX-CGFloat(pin.origin[0])-pinPadding
            let rect = CGRect(x:lane.minX+(x-minX)*scale,y:lane.minY+2,width:CGFloat(pin.display_size[0])*scale,height:lane.height-4)
            let preceding=pins.keys.filter { $0 < slot && pins[$0]?.row(in:snapshot) == row && pins[$0]?.origin == pin.origin }.count
            let badge=CGRect(x:rect.maxX-19-CGFloat(preceding)*20,y:rect.maxY-19,width:15,height:15)
            result.append((slot,rect,badge))
        }
        return result
    }
    func pinAt(_ point: CGPoint) -> Int? {
        guard visibleRect.contains(point), point.x >= visibleRect.minX+36 else { return nil }
        return pinGeometry().reversed().first { $0.badge.contains(point) }?.slot
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local=convert(point,from:superview)
        // The row ruler is painted over the tiles; clicks and tooltips there must not reach hidden tiles.
        if bounds.contains(local) && local.x < visibleRect.minX+36 { return self }
        return pinAt(local) != nil || overflowAt(local) != nil ? self : super.hitTest(point)
    }
    /// Move-column alternatives to dragging, for VoiceOver and Switch Control.
    fileprivate func moveActions(for tile: SpatialTile) -> [NSAccessibilityCustomAction] {
        let rows = snapshot.rows
        guard let index = rows.firstIndex(of: tile.window.row) else { return [] }
        return [(index-1,"above"),(index+1,"below")].compactMap { target, side in
            guard rows.indices.contains(target) else { return nil }
            let row = rows[target]
            return NSAccessibilityCustomAction(name: "Move column to row \(row), \(side)") { [weak self] in
                guard let self, let drop = self.accessibilityDrop(sourceID: tile.window.id, toRow: row) else { return false }
                self.onMove?(drop.sourceID, drop.sourceRow, drop.row, drop.anchor, drop.after); return true
            }
        }
    }
    /// The drop a drag to the far end of `row` would produce, computed against the current snapshot.
    func accessibilityDrop(sourceID: Int, toRow row: Int) -> SpatialDrop? {
        guard let source = snapshot.windows.first(where: { $0.id == sourceID }), let index = snapshot.rows.firstIndex(of: row) else { return nil }
        let state = SpatialDrag(sourceID: source.id, sourceRow: source.row, sourceColumn: source.column, origin: .zero)
        return spatialDrop(snapshot: snapshot, map: map, drag: state, point: CGPoint(x: map.width-1, y: CGFloat(index)*SpatialMapLayout.rowHeight+SpatialMapLayout.rowHeight/2))
    }
    override func accessibilityChildren() -> [Any]? {
        var extra: [Any] = []
        for entry in pinGeometry() {
            let element = SpatialAXElement(); element.owner = self; element.rect = entry.badge
            element.setAccessibilityParent(self); element.setAccessibilityRole(.button)
            element.setAccessibilityLabel("Pinned view \(entry.slot)"); element.setAccessibilityHelp("Press to jump to this pinned view.")
            let slot = entry.slot; element.press = { [weak self] in self?.onPin?(slot) }
            extra.append(element)
        }
        for item in overflowGeometry() {
            let element = SpatialAXElement(); element.owner = self; element.rect = item.rect
            element.setAccessibilityParent(self); element.setAccessibilityRole(.button)
            element.setAccessibilityLabel("\(item.count) more \(item.count == 1 ? "column" : "columns") \(item.after ? "to the right" : "to the left") in row \(item.row)")
            let after = item.after; element.press = { [weak self] in self?.revealOverflow(after: after) }
            extra.append(element)
        }
        return subviews + extra
    }
    override func mouseDown(with event:NSEvent) { let point=convert(event.locationInWindow,from:nil);pressedPin=pinAt(point);pressedOverflow=overflowAt(point)?.after }
    override func mouseUp(with event:NSEvent) {
        defer { pressedPin=nil;pressedOverflow=nil }
        if let direction=pressedOverflow,overflowAt(convert(event.locationInWindow,from:nil))?.after==direction {revealOverflow(after:direction);return}
        if let slot=pressedPin, pinAt(convert(event.locationInWindow,from:nil)) == slot { onPin?(slot) }
    }
    func overflowGeometry()->[(row:Int,after:Bool,count:Int,rect:CGRect)] {
        var results:[(Int,Bool,Int,CGRect)]=[]
        let view=visibleRect
        for row in snapshot.rows {
            guard let lane=map.rowFrames[row],lane.intersects(view) else {continue}
            let groups=Dictionary(grouping:map.tiles.filter {$0.window.row==row},by:{$0.window.column})
            let rects=groups.values.map {$0.map(\.rect).reduce(CGRect.null){$0.union($1)}}
            for after in [false,true] {
                let count=rects.filter {after ? $0.minX>=view.maxX-32:$0.maxX<=view.minX+68}.count
                if count>0 {results.append((row,after,count,CGRect(x:after ? view.maxX-34:view.minX+40,y:lane.midY-10,width:30,height:20)))}
            }
        }
        return results
    }
    func overflowAt(_ point:CGPoint)->(after:Bool,rect:CGRect)? { overflowGeometry().first {$0.rect.contains(point)}.map {($0.after,$0.rect)} }
    func revealOverflow(after:Bool) {
        guard let scroll=enclosingScrollView else {return}
        let x=max(0,min(bounds.width-visibleRect.width,visibleRect.minX+(after ? 1:-1)*visibleRect.width*0.65))
        scroll.contentView.scroll(to:CGPoint(x:x,y:visibleRect.minY));scroll.reflectScrolledClipView(scroll.contentView);needsDisplay=true
    }
    override func draw(_ dirtyRect: NSRect) {
        let dark=mapDark(self),teal=mapTeal(self),background=mapColor(dark ? 0x2B2E2F:0xFAFAFA)
        background.setFill();bounds.fill()
        if snapshot.rows.isEmpty {text("No windows yet",in:bounds.insetBy(dx:20,dy:30),color:.secondaryLabelColor);return}
        for row in snapshot.rows {
            guard let frame=map.rowFrames[row] else {continue}
            let active=row==snapshot.activeRow
            (active ? teal.withAlphaComponent(0.06):NSColor.labelColor.withAlphaComponent(0.035)).setFill()
            NSBezierPath(roundedRect:frame.insetBy(dx:-1,dy:-1),xRadius:7,yRadius:7).fill()
            if !snapshot.windows.contains(where:{$0.row==row}) {
                let left=max(frame.minX,visibleRect.minX+38),right=min(frame.maxX,visibleRect.maxX-10)
                let slot=CGRect(x:left,y:frame.minY+1,width:max(1,right-left),height:frame.height-2)
                let path=NSBezierPath(roundedRect:slot,xRadius:7,yRadius:7);path.setLineDash([1,2],count:2,phase:0);path.lineWidth=1
                (active ? teal:NSColor.labelColor.withAlphaComponent(increaseContrast ? 0.55:0.22)).setStroke();path.stroke()
                text(active ? "Empty row · you’re here":"Empty row",in:CGRect(x:slot.minX+8,y:slot.midY-7,width:slot.width-16,height:16),color:active ? teal:.secondaryLabelColor,size:10,centered:true)
            }
        }
        NSGraphicsContext.saveGraphicsState()
        CGRect(x:visibleRect.minX+36,y:visibleRect.minY,width:max(0,visibleRect.width-36),height:visibleRect.height).clip()
        for tile in map.tiles {
            let focused=tile.window.id==snapshot.focused,rect=tile.rect
            let moving=drag?.moved==true && tile.window.row==drag?.sourceRow && tile.window.column==drag?.sourceColumn
            let alpha:CGFloat=moving ? 0.35:1
            NSGraphicsContext.saveGraphicsState();rect.clip()
            let path=NSBezierPath(roundedRect:rect.insetBy(dx:0.5,dy:0.5),xRadius:5,yRadius:5)
            mapColor(focused ? (dark ? 0x1D4647:0xDCEEEE):(dark ? 0x3A3E3F:0xFFFFFF)).withAlphaComponent(alpha).setFill();path.fill()
            (focused || moving ? teal:(dark ? NSColor.white:NSColor.black).withAlphaComponent(0.10)).withAlphaComponent(moving ? 0.4:focused ? 1:(increaseContrast ? 0.55:0.10)).setStroke()
            path.lineWidth=focused ? 1.2:(increaseContrast ? 1:0.5);if moving {path.setLineDash([1,2],count:2,phase:0)};path.stroke()
            let members=tile.window.tabbed ? snapshot.windows.filter {$0.row==tile.window.row && $0.column==tile.window.column}:[tile.window]
            var seen=Set<String>();var group=members.filter {seen.insert($0.bundle.isEmpty ? $0.app:$0.bundle).inserted}
            if let i=group.firstIndex(where:{$0.bundle==tile.window.bundle}) {group.append(group.remove(at:i))}
            let size:CGFloat=14,capacity=max(1,Int(max(0,rect.width-60-size)/(size*0.5))+1)
            group=Array(group.suffix(capacity))
            let span=size+CGFloat(max(0,group.count-1))*size*0.5
            let titleWidth=min(max(0,rect.width-span-18),(tile.window.app as NSString).size(withAttributes:[.font:NSFont.systemFont(ofSize:10,weight:.medium)]).width)
            let x=rect.midX-(span+6+titleWidth)/2
            let y=rect.height>=42 ? rect.midY-17:rect.midY-7
            for (i,member) in group.enumerated() {
                NSGraphicsContext.saveGraphicsState()
                if i==group.count-1 && group.count>1 {let shadow=NSShadow();shadow.shadowOffset=NSSize(width:-1,height:0);shadow.shadowBlurRadius=1.5;shadow.shadowColor=NSColor.black.withAlphaComponent(0.35);shadow.set()}
                (icon(member.bundle) ?? NSImage(named:NSImage.applicationIconName))?.draw(in:CGRect(x:x+CGFloat(i)*size*0.5,y:y,width:size,height:size),from:.zero,operation:.sourceOver,fraction:alpha,respectFlipped:true,hints:nil)
                NSGraphicsContext.restoreGraphicsState()
            }
            text(tile.window.app,in:CGRect(x:x+span+6,y:y,width:titleWidth,height:15),color:mapColor(dark ? 0xE5E5E7:0x3A3A3C).withAlphaComponent(alpha),size:10)
            if rect.height>=42 {
                let subtitle=moving ? "Moving…":members.count>1 ? "\(members.count) tabs · \(members.map(\.app).joined(separator:", "))":tile.window.title
                text(subtitle,in:CGRect(x:rect.minX+8,y:rect.midY+3,width:rect.width-16,height:15),color:mapColor(dark ? 0xA1A1A6:0x6E6E73).withAlphaComponent(alpha),size:9,centered:true)
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        for (row,port) in map.viewports where snapshot.windows.contains(where:{$0.row==row}) {teal.setStroke();let p=NSBezierPath(roundedRect:port.insetBy(dx:-1,dy:-1),xRadius:6,yRadius:6);p.lineWidth=1.2;p.stroke()}
        for (slot,rect,badge) in pinGeometry() {
            let color=spatialPinColor(slot);color.setStroke()
            let p=NSBezierPath(roundedRect:rect,xRadius:6,yRadius:6);p.lineWidth=1;p.stroke()
            color.setFill();NSBezierPath(roundedRect:badge,xRadius:4,yRadius:4).fill()
            text(String(slot),in:badge.insetBy(dx:0,dy:1),color:.white,size:10,centered:true)
        }
        if let drop,let lane=map.rowFrames[drop.row] {
            teal.setStroke();let line=NSBezierPath();line.move(to:CGPoint(x:drop.markerX,y:lane.minY+3));line.line(to:CGPoint(x:drop.markerX,y:lane.maxY-3));line.lineWidth=2;line.stroke()
            teal.setFill();NSBezierPath(ovalIn:CGRect(x:drop.markerX-4,y:lane.minY-1,width:8,height:8)).fill()
        }
        for item in overflowGeometry() {
            let pill=NSBezierPath(roundedRect:item.rect,xRadius:10,yRadius:10)
            NSGraphicsContext.saveGraphicsState()
            let shadow=NSShadow();shadow.shadowOffset=NSSize(width:0,height:-1)
            shadow.shadowBlurRadius=3;shadow.shadowColor=NSColor.black.withAlphaComponent(dark ? 0.40:0.20);shadow.set()
            NSColor.controlBackgroundColor.setFill();pill.fill()
            NSGraphicsContext.restoreGraphicsState()
            NSColor.labelColor.withAlphaComponent(dark ? 0.32:0.24).setStroke();pill.lineWidth=1;pill.stroke()
            text(item.after ? "\(item.count) ›":"‹ \(item.count)",in:item.rect.insetBy(dx:3,dy:3),color:.labelColor,size:9,centered:true)
        }
        NSGraphicsContext.restoreGraphicsState()
        for row in snapshot.rows {
            guard let lane=map.rowFrames[row] else {continue}
            let active=row==snapshot.activeRow,ruler=CGRect(x:visibleRect.minX,y:lane.minY-1,width:32,height:lane.height+2)
            background.setFill();ruler.insetBy(dx:-2,dy:0).fill()
            (active ? teal.withAlphaComponent(0.09):NSColor.labelColor.withAlphaComponent(0.04)).setFill();NSBezierPath(roundedRect:ruler.insetBy(dx:2,dy:0),xRadius:6,yRadius:6).fill()
            let style=NSMutableParagraphStyle();style.alignment = .center
            (String(row) as NSString).draw(in:CGRect(x:ruler.minX,y:lane.midY-7,width:ruler.width,height:16),withAttributes:[.font:NSFont.monospacedSystemFont(ofSize:11,weight:active ? .semibold:.regular),.foregroundColor:active ? teal:NSColor.secondaryLabelColor,.paragraphStyle:style])
        }
    }
    private func icon(_ bundle: String) -> NSImage? {
        if let icon = icons[bundle] { return icon }
        if missingIcons.contains(bundle) { return nil }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { missingIcons.insert(bundle); return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path); icons[bundle] = icon; return icon
    }
    private func text(_ value: String, in rect: CGRect, color: NSColor, size: CGFloat = 10, centered:Bool=false) {
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail;paragraph.alignment=centered ? .center:.left
        (value as NSString).draw(in: rect, withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: .medium), .foregroundColor: color, .paragraphStyle: paragraph])
    }
}
struct SpatialPanelGeometry {
    let size: NSSize
    let header: CGRect, footer: CGRect, scroll: CGRect
    init(available: NSSize, rowCount: Int) {
        let width = max(1, min(560, available.width-24))
        let desiredHeight: CGFloat = 68 + CGFloat(min(3,max(1,rowCount))) * SpatialMapLayout.rowHeight
        let height: CGFloat = max(1, min(available.height-32, desiredHeight))
        self.init(size: NSSize(width: width, height: height))
    }
    init(size suppliedSize: NSSize) {
        let width = max(1,suppliedSize.width), height = max(1,suppliedSize.height)
        size = NSSize(width: width, height: height)
        let headerHeight = min(38, height*0.3), footerHeight = min(30, height*0.22)
        header = CGRect(x: 0, y: 0, width: width, height: headerHeight)
        footer = CGRect(x: 0, y: height-footerHeight, width: width, height: footerHeight)
        scroll = CGRect(x: 8, y: headerHeight, width: max(1,width-16), height: max(1,height-headerHeight-footerHeight))
    }
}
private final class SpatialGearButton: NSButton {
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) { NSImage(systemSymbolName:"gearshape",accessibilityDescription:"Settings")?.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors:[mapColor(mapDark(self) ? 0xA1A1A6:0x6E6E73)]))?.draw(in:bounds.insetBy(dx:5,dy:5)) }
}
private final class SpatialClipView:NSClipView {
    var onScroll:(()->Void)?
    override func scroll(to newOrigin:NSPoint) {
        super.scroll(to:newOrigin)
        // Invalidate after AppKit has copied the old document pixels.
        onScroll?()
    }
}
final class SpatialContentView: NSView {
    private(set) var viewportInvalidations=0
    override var isFlipped: Bool { true }
    let mapView: SpatialMapView
    let scrollView = NSScrollView()
    private(set) var geometry: SpatialPanelGeometry
    static let defaultMessage = "Drag a column to move it between rows"
    var message = SpatialContentView.defaultMessage {
        didSet {
            needsDisplay = true
            // Status text is painted, not an accessibility element: speak changes for VoiceOver.
            if message != oldValue && message != Self.defaultMessage {
                NSAccessibility.post(element: self, notification: .announcementRequested, userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
            }
        }
    }
    var onEscape: (() -> Void)? { didSet { mapView.onEscape = onEscape } }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
    override func keyDown(with event: NSEvent) { if event.keyCode == 53 { cancelOperation(self) } else { super.keyDown(with: event) } }
    override func accessibilityPerformCancel() -> Bool { guard let onEscape else { return false }; onEscape(); return true }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    var onSettings: (() -> Void)?
    var onRefresh: (() -> Void)?
    var onViews: (() -> Void)?
    private let viewsButton = NSButton(title: "Views…", target: nil, action: nil)
    let refreshButton = NSButton(title: "Refresh", target: nil, action: nil)
    private let gear = SpatialGearButton()
    init(snapshot: SpatialSnapshot, available: NSSize) {
        geometry = SpatialPanelGeometry(available: available, rowCount: snapshot.rows.count)
        mapView = SpatialMapView(snapshot: snapshot, width: max(1, geometry.scroll.width-14), onFocus: nil)
        super.init(frame: CGRect(origin: .zero, size: geometry.size))
        setAccessibilityElement(true); setAccessibilityRole(.group); setAccessibilityLabel("Window map")
        // Gutters and overflow pills depend on visibleRect. Copying old pixels
        // during scrolling would move those fixed decorations into the map.
        let clip=SpatialClipView();scrollView.contentView=clip
        clip.onScroll={ [weak self] in self?.invalidateMapViewport() }
        scrollView.contentView.postsBoundsChangedNotifications=true
        NotificationCenter.default.addObserver(self,selector:#selector(mapViewportChanged),name:NSView.boundsDidChangeNotification,object:scrollView.contentView)
        scrollView.frame = geometry.scroll; scrollView.hasVerticalScroller = true; scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true; scrollView.drawsBackground = false; scrollView.documentView = mapView; addSubview(scrollView)
        gear.title = ""; gear.isBordered = false; gear.target = self; gear.action = #selector(settings); gear.toolTip = "Settings"; gear.setAccessibilityLabel("Settings")
        gear.frame = CGRect(x: max(0,bounds.width-44), y: min(12,geometry.header.height/4), width: min(30,bounds.width), height: min(30,geometry.header.height)); addSubview(gear)
        refreshButton.target = self; refreshButton.action = #selector(refresh)
        refreshButton.bezelStyle = .rounded; refreshButton.setAccessibilityLabel("Refresh windows")
        refreshButton.toolTip = "Rediscover windows and restore the saved layout. Windows may briefly move."
        refreshButton.frame = CGRect(x: max(0,bounds.width-132), y: 12, width: 82, height: 28)
        addSubview(refreshButton)
        viewsButton.target=self; viewsButton.action = #selector(views); viewsButton.bezelStyle = .rounded
        viewsButton.frame=CGRect(x:max(0,bounds.width-216),y:12,width:78,height:28)
        addSubview(viewsButton)
        layoutHeader();scrollView.tile();mapView.resizeViewport(width:max(1,scrollView.contentSize.width));centerActiveRow()
    }
    deinit { NotificationCenter.default.removeObserver(self) }
    @objc private func mapViewportChanged(_ notification:Notification) {
        // Repaint the whole newly visible surface, not just the exposed strip.
        invalidateMapViewport()
    }
    private func invalidateMapViewport() {
        viewportInvalidations += 1
        mapView.setNeedsDisplay(mapView.visibleRect)
        scrollView.contentView.setNeedsDisplay(scrollView.contentView.bounds)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        geometry = SpatialPanelGeometry(size: bounds.size)
        scrollView.frame = geometry.scroll
        layoutHeader()
        scrollView.tile(); mapView.resizeViewport(width: max(1,scrollView.contentSize.width))
        needsDisplay = true
    }
    private func layoutHeader() {
        let narrow=bounds.width<380,y:CGFloat=7
        gear.frame=CGRect(x:bounds.width-34,y:y,width:24,height:24)
        refreshButton.title="";refreshButton.image=NSImage(systemSymbolName:"arrow.clockwise",accessibilityDescription:"Refresh windows");refreshButton.isBordered=false
        refreshButton.frame=CGRect(x:bounds.width-64,y:y,width:24,height:24)
        viewsButton.title=narrow ? "":"Views ⌄";viewsButton.image=narrow ? NSImage(systemSymbolName:"bookmark",accessibilityDescription:"Views and pins"):nil
        viewsButton.isBordered = !narrow;viewsButton.isHidden=bounds.width<200;viewsButton.toolTip="Views and pins";viewsButton.setAccessibilityLabel("Views and pins")
        viewsButton.frame=CGRect(x:bounds.width-(narrow ? 94:134),y:y,width:narrow ? 24:64,height:24)
    }
    @objc private func views() { onViews?() }
    @objc private func refresh() { onRefresh?() }
    @objc private func settings() { onSettings?() }
    func centerActiveRow() {
        guard let row = mapView.map.rowFrames[mapView.snapshot.activeRow] else { return }
        let viewport = scrollView.contentView.bounds
        scrollView.contentView.scroll(to: CGPoint(x: max(0,min(mapView.bounds.width-viewport.width, (mapView.map.viewports[mapView.snapshot.activeRow]?.midX ?? row.midX)-viewport.width/2)), y: max(0,min(mapView.bounds.height-viewport.height, row.midY-viewport.height/2))))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill(); bounds.fill()
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
        ("Window map" as NSString).draw(in:CGRect(x:12,y:12,width:100,height:17),withAttributes:[.font:NSFont.systemFont(ofSize:12,weight:.semibold),.foregroundColor:NSColor.labelColor])
        NSColor.separatorColor.withAlphaComponent(0.6).setStroke()
        let path = NSBezierPath(); path.move(to: CGPoint(x: 16,y: geometry.header.maxY-1)); path.line(to: CGPoint(x: bounds.width-16,y: geometry.header.maxY-1)); path.move(to: CGPoint(x: 16,y: geometry.footer.minY)); path.line(to: CGPoint(x: bounds.width-16,y: geometry.footer.minY)); path.lineWidth = 0.5; path.stroke()
        let normal=message==Self.defaultMessage
        let showLegend=normal && bounds.width>=500
        (message as NSString).draw(in:CGRect(x:12,y:geometry.footer.minY+9,width:showLegend ? bounds.width-250:bounds.width-24,height:14),withAttributes:[.font:NSFont.systemFont(ofSize:9),.foregroundColor:NSColor.secondaryLabelColor,.paragraphStyle:paragraph])
        if showLegend {
            let x=bounds.width-218,y=geometry.footer.minY+10
            mapTeal(self).setStroke();let port=NSBezierPath(roundedRect:CGRect(x:x,y:y,width:7,height:7),xRadius:1,yRadius:1);port.lineWidth=1;port.stroke()
            ("On screen" as NSString).draw(at:CGPoint(x:x+12,y:y-2),withAttributes:[.font:NSFont.systemFont(ofSize:9),.foregroundColor:NSColor.secondaryLabelColor])
            spatialPinColor(2).setFill();NSBezierPath(roundedRect:CGRect(x:x+68,y:y-1,width:11,height:11),xRadius:3,yRadius:3).fill()
            ("2" as NSString).draw(at:CGPoint(x:x+71,y:y-1),withAttributes:[.font:NSFont.monospacedDigitSystemFont(ofSize:8,weight:.bold),.foregroundColor:NSColor.white])
            ("Pinned view · click to jump" as NSString).draw(at:CGPoint(x:x+84,y:y-2),withAttributes:[.font:NSFont.systemFont(ofSize:9),.foregroundColor:NSColor.secondaryLabelColor])
        }
    }
}
/// A transient popover closes on the mouse-down that lands on its own status item, so the
/// mouse-up action would immediately reopen it. True when this click is the tail of such a close.
func spatialStatusClickClosesPopover(closedByPressAt: TimeInterval?, now: TimeInterval) -> Bool {
    guard let closedByPressAt else { return false }
    return now - closedByPressAt >= 0 && now - closedByPressAt < 1.5
}
final class SpatialOverviewController: NSObject, NSPopoverDelegate {
    var onFocus: ((Int) -> Void)?
    var onMove: ((Int, Int, Int, Int?, Bool) -> Void)?
    var onSettings: (() -> Void)?
    var onReload: (() -> Void)?
    var onRefresh: ((@escaping (Bool) -> Void) -> Void)?
    private var refreshing = false
    var pinsPath = ""
    // The refresh script ends a failed run with one plain sentence (SystemExit); show it, not a log path.
    // A crash ends with a traceback instead, which is not for the panel.
    func refreshFailure() -> String {
        let log=URL(fileURLWithPath:pinsPath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("work/refresh.log")
        let last=((try? String(contentsOf:log,encoding:.utf8)) ?? "").split(separator:"\n").last.map(String.init)?.trimmingCharacters(in:.whitespaces) ?? ""
        let plain = !last.isEmpty && last.count < 160 && !last.contains("Error:") && !last.hasPrefix("File ") && !last.hasPrefix("Traceback")
        return plain ? last : "Couldn’t refresh windows."
    }
    var onViewAction: ((String, Int?) -> Void)?
    private var item: NSStatusItem?
    private var menu: NSMenu?
    private let popover = NSPopover()
    private var snapshot = SpatialSnapshot("")
    private var content: SpatialContentView?
    private var closedByStatusPressAt: TimeInterval?
    func attach(to item: NSStatusItem) {
        self.item = item; menu = item.menu; item.menu = nil
        // Switching apps (Cmd-Tab) must dismiss the map like a menu; the transient behavior only watches clicks.
        NotificationCenter.default.addObserver(self, selector: #selector(appResigned), name: NSApplication.didResignActiveNotification, object: nil)
        item.button?.target = self; item.button?.action = #selector(clicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp]); updateGlyph(); popover.delegate = self
    }
    @objc private func appResigned(_ note: Notification) { if popover.isShown { popover.performClose(nil) } }
    func update(text: String) {
        let next = SpatialSnapshot(text); let changed = next != snapshot
        snapshot = next; if changed { updateGlyph() }
        content?.mapView.update(next); loadPins()
    }
    private func loadPins() {
        guard let map = content?.mapView else { return }
        let data=(try? Data(contentsOf:URL(fileURLWithPath:pinsPath))) ?? Data()
        let decoded=(try? JSONDecoder().decode([String:SpatialPin].self,from:data)) ?? [:]
        map.pins=Dictionary(uniqueKeysWithValues:decoded.compactMap { key,value in
            guard let slot=Int(key), (0...9).contains(slot) else { return nil }; return (slot,value)
        })
        let root=URL(fileURLWithPath:pinsPath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        if let data=try? Data(contentsOf:root.appendingPathComponent("config/preferences.json")), let prefs=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any], let gap=prefs["windowGap"] as? Double { map.pinPadding=gap }
    }
    func showMoveResult(_ success: Bool) { content?.message = success ? "Column moved" : "Move not confirmed · layout may have changed" }
    func popoverWillClose(_ notification: Notification) {
        content?.mapView.cancelDrag()
        if let window = item?.button?.window, NSEvent.pressedMouseButtons & 1 != 0, window.frame.contains(NSEvent.mouseLocation) { closedByStatusPressAt = ProcessInfo.processInfo.systemUptime }
    }
    func popoverDidClose(_ notification: Notification) {
        item?.button?.highlight(false)
        // Drop the hidden map so snapshot updates stop re-laying-out and re-reading pins while closed.
        if content?.window == nil { content = nil; popover.contentViewController = nil }
    }
    private func updateGlyph() {
        let state = snapshot
        let image = NSImage(size: NSSize(width: 25, height: 19), flipped: false) { _ in
            var shownRows = state.rows
            if shownRows.count > 3 {
                let active = shownRows.firstIndex(of: state.activeRow) ?? 0
                let start = max(0, min(shownRows.count-3, active-1)); shownRows = Array(shownRows[start..<start+3])
            }
            if shownRows.isEmpty { shownRows = [0,1,2] }
            for (index, row) in shownRows.enumerated() {
                let groups = Dictionary(grouping: state.windows.filter { $0.row == row }, by: \.column)
                let widths = groups.keys.sorted().map { key in groups[key]!.map { $0.frame.width }.max() ?? 1 }
                if widths.isEmpty && !state.rows.isEmpty {
                    NSColor.labelColor.withAlphaComponent(row == state.activeRow ? 1 : 0.4).setStroke()
                    let rail = NSBezierPath(roundedRect: CGRect(x: 2, y: CGFloat(2-index)*5+2, width: 21, height: 3), xRadius: 0.6, yRadius: 0.6); rail.lineWidth = 0.6; rail.stroke(); continue
                }
                let actual = widths.isEmpty ? [CGFloat(7),5,8] : Array(widths.prefix(10))
                let available = max(1, 21-CGFloat(actual.count-1)), sum = max(1, actual.reduce(0,+)); var x: CGFloat = 2
                NSColor.labelColor.withAlphaComponent(row == state.activeRow ? 1 : 0.58).setFill()
                for width in actual { let w = max(0.5,width/sum*available); NSBezierPath(roundedRect: CGRect(x: x,y: CGFloat(2-index)*5+2,width: w,height: 3), xRadius: 0.6,yRadius: 0.6).fill(); x += w+1 }
            }
            return true
        }
        image.isTemplate = true; item?.button?.image = image; item?.button?.title = ""; item?.button?.toolTip = "Microfish window map"; item?.button?.setAccessibilityLabel("Microfish window map")
    }
    @objc private func viewAction(_ sender: NSMenuItem) {
        guard let value=sender.representedObject as? [String:String], let action=value["action"] else { return }
        popover.performClose(nil); onViewAction?(action,value["slot"].flatMap(Int.init))
    }
    private func showViews(in root: NSView) {
        let data=(try? Data(contentsOf:URL(fileURLWithPath:pinsPath))) ?? Data()
        let pins=(try? JSONSerialization.jsonObject(with:data)) as? [String:[String:Any]] ?? [:]
        let menu=NSMenu()
        let statusPath=URL(fileURLWithPath:pinsPath).deletingLastPathComponent().appendingPathComponent("view-status.json")
        if let data=try? Data(contentsOf:statusPath), let status=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any] {
            let label=NSMenuItem(title:(status["locked"] as? Bool == true) ? "View pinned · navigate to release" : "View follows navigation",action:nil,keyEquivalent:"")
            label.isEnabled=false; menu.addItem(label)
            if let message=status["message"] as? String, !message.isEmpty {
                let note=NSMenuItem(title:message,action:nil,keyEquivalent:""); note.isEnabled=false; menu.addItem(note)
            }
            menu.addItem(.separator())
        }
        func item(_ title: String,_ action: String,_ slot: Int? = nil) -> NSMenuItem {
            let item=NSMenuItem(title:title,action:#selector(viewAction(_:)),keyEquivalent:"")
            item.target=self; var value=["action":action]; if let slot { value["slot"]=String(slot) }; item.representedObject=value
            return item
        }
        menu.addItem(item("Undo last layout move  ·  Hyper Z","undo-move"))
        menu.addItem(item("Previous view  ·  Hyper Tab","view-back")); menu.addItem(.separator())
        for slot in 0...9 {
            let count=(pins[String(slot)]?["columns"] as? [[Any]])?.reduce(0) { $0+$1.count }
            menu.addItem(item(count.map { "Pin \(slot) · \($0) windows" } ?? "Pin \(slot) · Save current view","view-pin",slot))
        }
        let replace=NSMenuItem(title:"Save / replace pin",action:nil,keyEquivalent:""); let slots=NSMenu()
        for slot in 0...9 { slots.addItem(item("Pin \(slot)  ·  Hyper Shift \(slot)","view-save",slot)) }
        replace.submenu=slots; menu.addItem(replace)
        menu.popUp(positioning:nil,at:CGPoint(x:max(0,root.bounds.width-216),y:42),in:root)
    }
    @objc private func clicked() {
        guard let button = item?.button else { return }
        if NSApp.currentEvent?.type == .rightMouseUp, let menu, let event = NSApp.currentEvent {
            if popover.isShown { popover.performClose(nil) }
            NSMenu.popUpContextMenu(menu, with: event, for: button); return
        }
        let pressClosed = spatialStatusClickClosesPopover(closedByPressAt: closedByStatusPressAt, now: ProcessInfo.processInfo.systemUptime)
        closedByStatusPressAt = nil
        if popover.isShown { popover.performClose(nil); return }
        if pressClosed { return }
        let screen = button.window?.screen ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let available = screen?.visibleFrame.size ?? NSSize(width: 800,height: 600)
        let root = SpatialContentView(snapshot: snapshot, available: available); content = root; loadPins()
        root.onViews = { [weak self, weak root] in if let root { self?.showViews(in:root) } }
        root.refreshButton.isEnabled = !refreshing
        root.onRefresh = { [weak self, weak root] in
            guard let self, !self.refreshing else { return }
            self.refreshing = true; root?.refreshButton.isEnabled = false
            root?.message = "Refreshing windows…"
            self.onRefresh? { [weak self] success in
                guard let self else { return }
                self.refreshing = false; self.content?.refreshButton.isEnabled = true
                self.content?.message = success ? "Windows refreshed" : self.refreshFailure()
            }
        }
        root.onEscape = { [weak self] in self?.popover.performClose(nil) }
        root.onSettings = { [weak self] in self?.popover.performClose(nil); self?.onSettings?() }
        root.mapView.onPin = { [weak self] slot in self?.popover.performClose(nil); self?.onViewAction?("view-pin",slot) }
        root.mapView.onFocus = { [weak self] id in self?.onFocus?(id); self?.popover.performClose(nil) }
        root.mapView.onMove = { [weak self] source, sourceRow, row, anchor, after in self?.content?.message = "Moving column…"; self?.onMove?(source,sourceRow,row,anchor,after) }
        root.mapView.onDragState = { [weak self] dragging in self?.popover.behavior = dragging ? .applicationDefined : .transient }
        let controller = NSViewController(); controller.view = root; controller.preferredContentSize = root.bounds.size
        popover.contentViewController = controller; popover.contentSize = root.bounds.size; popover.behavior = .transient
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentSize = root.bounds.size
        button.highlight(true)
        root.window?.makeFirstResponder(root.mapView)
    }
}
