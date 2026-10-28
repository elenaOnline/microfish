// Text dump of a view tree (classes, frames, text, fonts, colours, tooltips, accessibility), compared old/new next to the pixels:
// hit-testing, tooltips and VoiceOver state are not visible in a bitmap. Prepended to every pixel-render program.
import AppKit
func describeTree(_ v: NSView, _ depth: Int = 0) -> String {
 var s = String(repeating: " ", count: depth) + String(describing: type(of: v)).replacingOccurrences(of: "FailureHUDView", with: "RoundedHUDView")
 // A hidden scroller's frame is stale until it next shows (AppKit re-tiles it then); it cannot be seen or hit.
 s += " f=\((v is NSScroller && v.isHidden) ? "-" : "\(v.frame)") hid=\(v.isHidden) a=\(v.alphaValue) tip=\(v.toolTip ?? "-") axl=\(v.accessibilityLabel() ?? "-") axr=\(v.accessibilityRole()?.rawValue ?? "-") axe=\(v.isAccessibilityElement()) axh=\(v.accessibilityHelp() ?? "-") layer=\(v.layer != nil) corner=\(v.layer?.cornerRadius ?? 0) shadowO=\(v.layer?.shadowOpacity ?? 0) shadowR=\(v.layer?.shadowRadius ?? 0)"
 if let t = v as? NSTextField { s += " text=\(t.stringValue) font=\(t.font.map { "\($0.fontName) \($0.pointSize)" } ?? "-") color=\(t.textColor?.description ?? "-") align=\(t.alignment.rawValue) lb=\(t.lineBreakMode.rawValue) bezel=\(t.isBezeled) bg=\(t.drawsBackground)" }
 if let i = v as? NSImageView { s += " img=\(i.image != nil) shadow=\(i.shadow != nil) tint=\(i.contentTintColor?.description ?? "-")" }
 if let b = v as? NSButton { s += " title=\(b.title) bordered=\(b.isBordered) enabled=\(b.isEnabled) image=\(b.image != nil)" }
 if let kids = v.accessibilityChildren() as? [NSAccessibilityElement] {
  for k in kids { s += "\n" + String(repeating: " ", count: depth + 1) + "AX \(k.accessibilityRole()?.rawValue ?? "-") \(k.accessibilityLabel() ?? "-") sel=\(String(describing: k.accessibilityValue())) f=\(k.accessibilityFrameInParentSpace())" }
 }
 for c in v.subviews { s += "\n" + describeTree(c, depth + 1) }
 return s
}
func writeDescription(_ v: NSView, _ path: String) { try! describeTree(v).write(toFile: path, atomically: true, encoding: .utf8) }
