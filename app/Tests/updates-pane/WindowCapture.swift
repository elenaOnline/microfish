// WindowCapture.swift — capture what a window really looks like (window-server
// composite) without it ever being visible on any display.
//
// No @main, no top-level code: compile alongside other files with
//   swiftc WindowCapture.swift Other.swift main.swift -framework AppKit ...
//
// Usage (from your own main, after NSApplication.shared + setActivationPolicy(.accessory)):
//   let w = OffscreenWindow(contentRect: ..., styleMask: [.titled, .closable], backing: .buffered, defer: false)
//   ... build contents ...
//   try WindowCapture.capture(w, to: url)                         // window-server composite, with shadow
//   try WindowCapture.capture(w, to: url, options: .noShadow)     // frame only
//   WindowCapture.captureCacheDisplay(w, to: url)                 // the unreliable baseline, for comparison
//
// Safety: window is parked at x = -40000 (outside every NSScreen frame), shown with
// orderFrontRegardless() only (never key/main, app never activated).

import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// NSWindow that AppKit will not pull back onto a screen.
final class OffscreenWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    // NOTE: a window that is not really key always draws the *inactive* look (grey switch,
    // grey traffic lights, un-tinted default button). Overriding isKeyWindow/isMainWindow does
    // NOT change that (tested). See README.
}

enum WindowCaptureError: Error, CustomStringConvertible {
    case symbolMissing
    case captureNil(windowNumber: Int)
    case blank
    case writeFailed(URL)
    case wouldBeVisible(NSRect)
    var description: String {
        switch self {
        case .symbolMissing: return "CGWindowListCreateImage not found via dlsym"
        case .captureNil(let n): return "CGWindowListCreateImage returned nil for window \(n)"
        case .blank: return "capture returned a fully transparent image"
        case .writeFailed(let u): return "could not write PNG to \(u.path)"
        case .wouldBeVisible(let r): return "refusing to capture: window frame \(r) intersects a screen"
        }
    }
}

enum WindowCapture {
    struct Options: OptionSet {
        let rawValue: Int
        /// Crop to the window's own bounds (no shadow margin, no transparent corners' shadow).
        static let noShadow = Options(rawValue: 1 << 0)
        /// Capture at 1x nominal resolution instead of the backing scale.
        static let nominal = Options(rawValue: 1 << 1)
    }

    // CGWindowListCreateImage is marked unavailable in recent SDKs; resolve at runtime.
    private typealias CGWLCI = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    /// Result of CGPreflightScreenCaptureAccess() (does NOT prompt). Record it with your evidence.
    static var screenCapturePreflight: Bool { CGPreflightScreenCaptureAccess() }

    /// Move the window so its whole frame is outside the union of every screen frame.
    static func park(_ window: NSWindow) {
        let union = NSScreen.screens.reduce(NSRect.null) { $0.union($1.frame) }
        var f = window.frame
        f.origin.x = min(-40000, union.minX - f.width - 5000)
        f.origin.y = union.minY // y value is irrelevant once x is far outside
        window.setFrame(f, display: false)
    }

    static func isOffAllScreens(_ window: NSWindow) -> Bool {
        // include a generous margin for the shadow
        let f = window.frame.insetBy(dx: -100, dy: -100)
        return !NSScreen.screens.contains { $0.frame.intersects(f) }
    }

    /// Spin the main run loop so layout, SwiftUI and Core Animation commit.
    static func spin(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }

    /// Show the window (parked, not key, app not activated) and let it settle.
    static func present(_ window: NSWindow, settle: TimeInterval = 0.6) throws {
        park(window)
        guard isOffAllScreens(window) else { throw WindowCaptureError.wouldBeVisible(window.frame) }
        window.orderFrontRegardless()
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        spin(settle)
        // AppKit might have moved it (e.g. another process tiling it): re-park and re-check.
        if !isOffAllScreens(window) { park(window); spin(0.2) }
        guard isOffAllScreens(window) else { throw WindowCaptureError.wouldBeVisible(window.frame) }
    }

    /// Window-server composite of this window only (what the compositor holds), as a CGImage.
    static func compositeImage(_ window: NSWindow, options: Options = []) throws -> CGImage {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2) /* RTLD_DEFAULT */, "CGWindowListCreateImage") else {
            throw WindowCaptureError.symbolMissing
        }
        let fn = unsafeBitCast(sym, to: CGWLCI.self)
        let listOption = UInt32(CGWindowListOption.optionIncludingWindow.rawValue)
        var imgOpts: UInt32 = options.contains(.nominal) ? CGWindowImageOption.nominalResolution.rawValue
                                                         : CGWindowImageOption.bestResolution.rawValue
        if options.contains(.noShadow) { imgOpts |= CGWindowImageOption.boundsIgnoreFraming.rawValue }
        // .null rect => the window's bounds (including shadow unless boundsIgnoreFraming)
        guard let img = fn(CGRect.null, listOption, UInt32(window.windowNumber), imgOpts)?.takeRetainedValue() else {
            throw WindowCaptureError.captureNil(windowNumber: window.windowNumber)
        }
        return img
    }

    /// Present + capture + write PNG. Window should already have its content/appearance set.
    static func capture(_ window: NSWindow, to url: URL, settle: TimeInterval = 0.6, options: Options = []) throws {
        try present(window, settle: settle)
        let img = try compositeImage(window, options: options)
        if isFullyTransparent(img) { throw WindowCaptureError.blank }
        try writePNG(img, to: url)
    }

    /// The unreliable baseline: AppKit's own offscreen render of contentView (omits layer-backed native controls).
    @discardableResult
    static func captureCacheDisplay(_ window: NSWindow, to url: URL, settle: TimeInterval = 0.2, themeFrame: Bool = true) -> Bool {
        spin(settle)
        guard let view = (themeFrame ? window.contentView?.superview : nil) ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let cg = rep.cgImage else { return false }
        return (try? writePNG(cg, to: url)) != nil
    }

    /// Fallback: CALayer.render(in:) of the theme frame (titlebar+toolbar+content). Painted by Core Animation's software path.
    @discardableResult
    static func captureLayerRender(_ window: NSWindow, to url: URL) -> Bool {
        guard let root = window.contentView?.superview ?? window.contentView, let layer = root.layer else { return false }
        let scale = window.backingScaleFactor
        let w = Int(root.bounds.width * scale), h = Int(root.bounds.height * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return false }
        ctx.scaleBy(x: scale, y: scale)
        layer.render(in: ctx)
        guard let cg = ctx.makeImage() else { return false }
        return (try? writePNG(cg, to: url)) != nil
    }

    static func isFullyTransparent(_ img: CGImage) -> Bool {
        let w = img.width, h = img.height
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                                space: CGColorSpaceCreateDeviceRGB(),
                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return true }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        let p = data.assumingMemoryBound(to: UInt8.self)
        var i = 3
        while i < w * h * 4 { if p[i] != 0 { return false }; i += 4 * 7 }
        return true
    }

    static func writePNG(_ img: CGImage, to url: URL) throws {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw WindowCaptureError.writeFailed(url)
        }
        CGImageDestinationAddImage(dest, img, nil)
        guard CGImageDestinationFinalize(dest) else { throw WindowCaptureError.writeFailed(url) }
    }
}
