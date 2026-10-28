use objc2::rc::Retained;
use objc2::runtime::AnyObject;
use objc2::{AnyThread, DefinedClass, MainThreadMarker, MainThreadOnly, define_class, msg_send};
use objc2_app_kit::{
    NSAccessibilityAnnouncementKey, NSAccessibilityAnnouncementRequestedNotification,
    NSAccessibilityNotificationUserInfoKey, NSAccessibilityPostNotificationWithUserInfo,
    NSAccessibilityPriorityKey, NSAppearance, NSAppearanceCustomization, NSAppearanceNameAqua,
    NSAppearanceNameDarkAqua, NSAppearanceNameVibrantDark, NSAppearanceNameVibrantLight,
    NSApplication, NSBackingStoreType, NSBezierPath, NSColor, NSCompositingOperation,
    NSFloatingWindowLevel, NSFont, NSGraphicsContext, NSImage, NSImageView, NSLineBreakMode,
    NSScreen, NSTextAlignment, NSTextField, NSView, NSVisualEffectBlendingMode,
    NSVisualEffectMaterial, NSVisualEffectState, NSVisualEffectView, NSWindow,
    NSWindowCollectionBehavior, NSWindowStyleMask,
};
use objc2_core_foundation::CGFloat;
use objc2_foundation::{NSArray, NSDictionary, NSNumber, NSPoint, NSRect, NSSize, NSString};

#[derive(Clone, PartialEq)]
pub struct BorderParams {
    pub color: (f64, f64, f64),
    pub opacity: f64,
    pub width: f64,
    pub radius: f64,
}

/// Parameters for the fullscreen dim + cutout overlay.
#[derive(Clone, PartialEq)]
pub struct DimParams {
    pub opacity: f32,
    pub color: (f64, f64, f64),
    /// The focused window rect to cut out (in Cocoa screen coordinates).
    /// `None` means dim everything (no focused window).
    pub cutout: Option<NSRect>,
    pub border: Option<BorderParams>,
}

// ── DimView: fullscreen dark overlay with a transparent cutout + border ──

#[derive(Debug, Clone)]
struct DimViewIvars {
    opacity: f32,
    dim_r: f64,
    dim_g: f64,
    dim_b: f64,
    // Cutout rect in the view's local coordinates.
    cutout_x: f64,
    cutout_y: f64,
    cutout_w: f64,
    cutout_h: f64,
    has_cutout: bool,
    // Border params (only drawn if has_border is true).
    has_border: bool,
    border_r: f64,
    border_g: f64,
    border_b: f64,
    border_opacity: f64,
    border_width: f64,
    border_radius: f64,
}

define_class!(
    #[unsafe(super(NSView))]
    #[thread_kind = MainThreadOnly]
    #[name = "PaneruDimView"]
    #[ivars = DimViewIvars]
    #[derive(Debug)]
    struct DimView;

    impl DimView {
        #[unsafe(method(drawRect:))]
        fn draw_rect(&self, _dirty_rect: NSRect) {
            let ivars = self.ivars();
            let bounds = self.bounds();

            // Fill the entire view with the dim color.
            let dim_color = NSColor::colorWithSRGBRed_green_blue_alpha(
                ivars.dim_r as CGFloat,
                ivars.dim_g as CGFloat,
                ivars.dim_b as CGFloat,
                CGFloat::from(ivars.opacity),
            );
            dim_color.setFill();
            NSBezierPath::fillRect(bounds);

            if ivars.has_cutout {
                let half = if ivars.has_border { ivars.border_width / 2.0 } else { 0.0 };
                let radius = ivars.border_radius as CGFloat;

                // Expand the cutout by half the border width so the clear hole
                // extends just past the window edge. The border straddles the
                // window edge: outer half visible in the cutout, inner half
                // hidden behind the window.
                let cutout = NSRect::new(
                    NSPoint::new(ivars.cutout_x - half, ivars.cutout_y - half),
                    NSSize::new(ivars.cutout_w + ivars.border_width, ivars.cutout_h + ivars.border_width),
                );

                // Punch a rounded transparent hole using Clear compositing.
                if let Some(ctx) = NSGraphicsContext::currentContext() {
                    ctx.setCompositingOperation(NSCompositingOperation::Clear);
                    let hole = NSBezierPath::bezierPathWithRoundedRect_xRadius_yRadius(
                        cutout, radius, radius,
                    );
                    hole.fill();
                    ctx.setCompositingOperation(NSCompositingOperation::SourceOver);
                }

                // Draw border centered on the window edge — half grows
                // outward (visible in the cutout), half grows inward (behind
                // the window).
                if ivars.has_border {
                    let border_rect = NSRect::new(
                        NSPoint::new(ivars.cutout_x, ivars.cutout_y),
                        NSSize::new(ivars.cutout_w, ivars.cutout_h),
                    );
                    let path = NSBezierPath::bezierPathWithRoundedRect_xRadius_yRadius(
                        border_rect, radius, radius,
                    );
                    path.setLineWidth(ivars.border_width as CGFloat);
                    let border_color = NSColor::colorWithSRGBRed_green_blue_alpha(
                        ivars.border_r as CGFloat,
                        ivars.border_g as CGFloat,
                        ivars.border_b as CGFloat,
                        ivars.border_opacity as CGFloat,
                    );
                    border_color.setStroke();
                    path.stroke();
                }
            }
        }

        #[unsafe(method(isFlipped))]
        fn is_flipped(&self) -> bool {
            true
        }
    }
);

impl DimView {
    fn new(mtm: MainThreadMarker, frame: NSRect, params: &DimParams) -> Retained<Self> {
        let (has_cutout, cx, cy, cw, ch) = params.cutout.map_or((false, 0.0, 0.0, 0.0, 0.0), |r| {
            (true, r.origin.x, r.origin.y, r.size.width, r.size.height)
        });
        let (has_border, br, bg, bb, bo, bw, brad) =
            params
                .border
                .as_ref()
                .map_or((false, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0), |b| {
                    (
                        true, b.color.0, b.color.1, b.color.2, b.opacity, b.width, b.radius,
                    )
                });
        let this = Self::alloc(mtm).set_ivars(DimViewIvars {
            opacity: params.opacity,
            dim_r: params.color.0,
            dim_g: params.color.1,
            dim_b: params.color.2,
            cutout_x: cx,
            cutout_y: cy,
            cutout_w: cw,
            cutout_h: ch,
            has_cutout,
            has_border,
            border_r: br,
            border_g: bg,
            border_b: bb,
            border_opacity: bo,
            border_width: bw,
            border_radius: brad,
        });
        unsafe { msg_send![super(this), initWithFrame: frame] }
    }
}

// ── Coordinate helpers ──────────────────────────────────────────────────

/// Convert an absolute CG screen frame (origin top-left, y-down) to Cocoa
/// screen coordinates (origin bottom-left of primary screen, y-up).
fn cg_abs_to_cocoa(frame: NSRect, primary_screen_height: f64) -> NSRect {
    let cocoa_y = primary_screen_height - frame.origin.y - frame.size.height;
    NSRect::new(NSPoint::new(frame.origin.x, cocoa_y), frame.size)
}

/// Height of the display at the global origin (the main display, whose Cocoa
/// frame origin is `(0, 0)`). The CG↔Cocoa Y-flip is anchored to this display,
/// so it must be *that* screen — `NSScreen::screens()[0]` is NOT reliably the
/// main display, and using the wrong one offsets the overlay (and, when
/// displays are stacked, lands it on the wrong monitor).
fn primary_screen_height(mtm: MainThreadMarker) -> f64 {
    let screens = NSScreen::screens(mtm);
    let mut fallback = 0.0;
    let mut first = true;
    for screen in &screens {
        let frame = screen.frame();
        if first {
            fallback = frame.size.height;
            first = false;
        }
        if frame.origin.x == 0.0 && frame.origin.y == 0.0 {
            return frame.size.height;
        }
    }
    fallback
}

/// Do two Cocoa rects overlap? Used to decide which displays a focused window
/// touches (a window straddling a seam touches both).
fn rects_intersect(a: NSRect, b: NSRect) -> bool {
    a.origin.x < b.origin.x + b.size.width
        && b.origin.x < a.origin.x + a.size.width
        && a.origin.y < b.origin.y + b.size.height
        && b.origin.y < a.origin.y + a.size.height
}

// ── Overlay window factory ──────────────────────────────────────────────

fn make_overlay_window(mtm: MainThreadMarker, cocoa_frame: NSRect) -> Retained<NSWindow> {
    let window = unsafe {
        NSWindow::initWithContentRect_styleMask_backing_defer(
            NSWindow::alloc(mtm),
            cocoa_frame,
            NSWindowStyleMask::Borderless,
            NSBackingStoreType::Buffered,
            false,
        )
    };
    window.setOpaque(false);
    window.setBackgroundColor(Some(&NSColor::clearColor()));
    window.setIgnoresMouseEvents(true);
    window.setHasShadow(false);
    window.setLevel(NSFloatingWindowLevel);
    window.setCollectionBehavior(
        NSWindowCollectionBehavior::Transient
            | NSWindowCollectionBehavior::IgnoresCycle
            | NSWindowCollectionBehavior::CanJoinAllSpaces
            | NSWindowCollectionBehavior::Stationary
            | NSWindowCollectionBehavior::FullScreenNone,
    );

    window
}
// ── OverlayManager ──────────────────────────────────────────────────────

pub struct OverlayManager {
    mtm: MainThreadMarker,
    /// One overlay window per display. macOS will not reliably let a single
    /// window span multiple displays (with "Displays have separate Spaces" it
    /// renders on only one), so each screen gets its own overlay drawn in that
    /// screen's local coordinates. Indexed in lockstep with `NSScreen::screens`.
    overlays: Vec<(Retained<NSWindow>, DimParams)>,
    hidden: bool,
}

impl OverlayManager {
    pub fn new(mtm: MainThreadMarker) -> Self {
        Self {
            mtm,
            overlays: Vec::new(),
            hidden: false,
        }
    }

    /// Update the per-display overlays.
    /// `focused_abs_cg` is the focused window rect in absolute CG coords,
    /// or `None` if no window is focused.
    pub fn update(
        &mut self,
        dim_opacity: f32,
        dim_color: (f64, f64, f64),
        focused_abs_cg: Option<NSRect>,
        border: Option<&BorderParams>,
    ) {
        let screen_h = primary_screen_height(self.mtm);
        let screens = NSScreen::screens(self.mtm);

        // The focused window in Cocoa global coords (shared across all screens).
        let focused_cocoa = focused_abs_cg.map(|cg| cg_abs_to_cocoa(cg, screen_h));

        // A display was added/removed — tear down and rebuild from scratch.
        if self.overlays.len() != screens.len() {
            for (window, _) in self.overlays.drain(..) {
                window.orderOut(None::<&AnyObject>);
            }
        }

        for (i, screen) in (&screens).into_iter().enumerate() {
            let frame = screen.frame();

            // Cut out the focused window on every display it touches, each in
            // that display's local (flipped, top-left origin) coordinates. A
            // window straddling a seam draws on both, clipped to each.
            let cutout_local = focused_cocoa
                .filter(|wc| rects_intersect(*wc, frame))
                .map(|wc| {
                    NSRect::new(
                        NSPoint::new(
                            wc.origin.x - frame.origin.x,
                            (frame.origin.y + frame.size.height) - (wc.origin.y + wc.size.height),
                        ),
                        wc.size,
                    )
                });

            let params = DimParams {
                opacity: dim_opacity,
                color: dim_color,
                cutout: cutout_local,
                border: border.cloned(),
            };

            if let Some((window, stored)) = self.overlays.get_mut(i) {
                if *stored == params {
                    // Keep geometry in sync cheaply (no forced redraw).
                    window.setFrame_display(frame, false);
                } else {
                    let view = DimView::new(self.mtm, frame, &params);
                    window.setContentView(Some(&view));
                    window.setFrame_display(frame, true);
                    *stored = params;
                }
                if self.hidden {
                    window.orderFront(None::<&AnyObject>);
                }
            } else {
                let window = make_overlay_window(self.mtm, frame);
                let view = DimView::new(self.mtm, frame, &params);
                window.setContentView(Some(&view));
                window.orderFront(None::<&AnyObject>);
                self.overlays.push((window, params));
            }
        }
        self.hidden = false;
    }

    pub fn remove_all(&mut self) {
        for (window, _) in self.overlays.drain(..) {
            window.orderOut(None::<&AnyObject>);
        }
        self.hidden = false;
    }

    pub fn hide_all(&mut self) {
        if self.hidden {
            return;
        }
        for (window, _) in &self.overlays {
            window.orderOut(None::<&AnyObject>);
        }
        self.hidden = true;
    }
}

// ── FlashMessage ────────────────────────────────────────────────────────
//
// The engine's transient confirmations ("View 3", "Move undone",
// "Settings reloaded", row badges) in the same family as the helper's own
// transient panels (`src/main.swift`: the minimap HUD and `FailureHUDView`):
// `.hudWindow` material behind the window, 16 pt corners, a vibrant appearance
// that follows the system, the system type scale, and a place inside the
// display's visible frame, 18 pt in from its edge. Top right is where macOS
// shows its own transient HUDs (volume, brightness, Focus) and keeps clear of
// the minimap, which may be up while Hyper is held.

/// Corner radius shared with the helper's HUD panels.
const HUD_RADIUS: f64 = 16.0;
/// Distance from the visible frame's edge, as the minimap uses.
const HUD_EDGE_INSET: f64 = 18.0;
/// One-line confirmation: height and horizontal padding.
const NOTE_HEIGHT: f64 = 40.0;
const NOTE_PADDING: f64 = 18.0;
/// Warning: the failure HUD's metrics (title, detail, warning glyph).
const WARNING_WIDTH: f64 = 340.0;
const WARNING_HEIGHT: f64 = 62.0;
/// `NSFontWeightMedium` / `NSFontWeightSemibold`. The macOS 27 SDK no longer
/// exports these as symbols, so the documented values are used.
const FONT_WEIGHT_MEDIUM: f64 = 0.23;
const FONT_WEIGHT_SEMIBOLD: f64 = 0.3;
/// Row badge (`workspace_popup_status`): a square HUD tile holding the number.
const BADGE_SIDE: f64 = 64.0;

/// The backdrop's own rounded mask, as the helper's `RoundedHUDView` sets it:
/// layer clipping alone can leave square compositor corners on the material.
fn rounded_mask(size: NSSize) -> Retained<NSImage> {
    let image = NSImage::initWithSize(NSImage::alloc(), size);
    #[allow(deprecated)]
    image.lockFocus();
    NSColor::whiteColor().setFill();
    NSBezierPath::bezierPathWithRoundedRect_xRadius_yRadius(
        NSRect::new(NSPoint::new(0.0, 0.0), size),
        HUD_RADIUS,
        HUD_RADIUS,
    )
    .fill();
    #[allow(deprecated)]
    image.unlockFocus();
    image
}

/// What a flash says: a one-line note, a row badge, or a warning with a detail
/// line (the failure HUD's layout).
#[derive(Clone, Debug, PartialEq)]
pub struct FlashContent {
    pub title: String,
    pub detail: Option<String>,
}

impl FlashContent {
    fn is_badge(&self) -> bool {
        self.detail.is_none() && !self.title.is_empty() && self.title.chars().count() <= 2
    }
}

/// The appearance the helper's panels use for a given system appearance.
fn hud_appearance(mtm: MainThreadMarker) -> (Retained<NSAppearance>, bool) {
    let app = NSApplication::sharedApplication(mtm);
    let effective = app.effectiveAppearance();
    let names = NSArray::from_slice(&[unsafe { NSAppearanceNameAqua }, unsafe {
        NSAppearanceNameDarkAqua
    }]);
    let dark = effective
        .bestMatchFromAppearancesWithNames(&names)
        .is_some_and(|name| &*name == unsafe { NSAppearanceNameDarkAqua });
    let vibrant = if dark {
        unsafe { NSAppearanceNameVibrantDark }
    } else {
        unsafe { NSAppearanceNameVibrantLight }
    };
    let appearance = NSAppearance::appearanceNamed(vibrant).unwrap_or(effective);
    (appearance, dark)
}

fn hud_color(rgb: u32) -> Retained<NSColor> {
    NSColor::colorWithSRGBRed_green_blue_alpha(
        f64::from((rgb >> 16) & 0xFF) / 255.0,
        f64::from((rgb >> 8) & 0xFF) / 255.0,
        f64::from(rgb & 0xFF) / 255.0,
        1.0,
    )
}

fn hud_label(mtm: MainThreadMarker) -> Retained<NSTextField> {
    let label = NSTextField::labelWithString(&NSString::from_str(""), mtm);
    label.setLineBreakMode(NSLineBreakMode::ByTruncatingTail);
    label.setMaximumNumberOfLines(1);
    label
}

/// The flash window. It is built once and re-configured per message, so no
/// view is ever freed (on macOS 27 freeing a label that had a superview leaks;
/// see the helper's view pooling).
struct FlashPanel {
    window: Retained<NSWindow>,
    effect: Retained<NSVisualEffectView>,
    title: Retained<NSTextField>,
    detail: Retained<NSTextField>,
    glyph: Retained<NSImageView>,
}

impl FlashPanel {
    fn new(mtm: MainThreadMarker) -> Self {
        let frame = NSRect::new(
            NSPoint::new(0.0, 0.0),
            NSSize::new(WARNING_WIDTH, NOTE_HEIGHT),
        );
        let window = make_overlay_window(mtm, frame);
        window.setLevel(NSFloatingWindowLevel + 1);
        window.setHasShadow(true);
        let effect = NSVisualEffectView::initWithFrame(NSVisualEffectView::alloc(mtm), frame);
        effect.setMaterial(NSVisualEffectMaterial::HUDWindow);
        effect.setBlendingMode(NSVisualEffectBlendingMode::BehindWindow);
        effect.setState(NSVisualEffectState::Active);
        effect.setWantsLayer(true);
        if let Some(layer) = effect.layer() {
            layer.setCornerRadius(HUD_RADIUS);
            layer.setMasksToBounds(true);
        }
        let title = hud_label(mtm);
        let detail = hud_label(mtm);
        let glyph = NSImageView::initWithFrame(
            NSImageView::alloc(mtm),
            NSRect::new(NSPoint::new(14.0, 21.0), NSSize::new(20.0, 20.0)),
        );
        glyph.setImage(
            NSImage::imageWithSystemSymbolName_accessibilityDescription(
                &NSString::from_str("exclamationmark.triangle"),
                Some(&NSString::from_str("Warning")),
            )
            .as_deref(),
        );
        effect.addSubview(&title);
        effect.addSubview(&detail);
        effect.addSubview(&glyph);
        window.setContentView(Some(&effect));
        Self {
            window,
            effect,
            title,
            detail,
            glyph,
        }
    }

    /// Lays the panel out for `content` and returns its size.
    fn configure(&self, mtm: MainThreadMarker, content: &FlashContent, max_width: f64) -> NSSize {
        let (appearance, dark) = hud_appearance(mtm);
        self.effect.setAppearance(Some(&appearance));
        let title = NSString::from_str(&content.title);
        self.title.setStringValue(&title);
        self.title.setTextColor(Some(&NSColor::labelColor()));
        self.title.setAlignment(NSTextAlignment::Left);
        if let Some(detail) = &content.detail {
            // The failure HUD: glyph, red title, one line of detail.
            let width = WARNING_WIDTH.min(max_width);
            let red = hud_color(if dark { 0x00FF_6961 } else { 0x00C4_000F });
            self.title.setFont(Some(&NSFont::systemFontOfSize_weight(
                13.0,
                FONT_WEIGHT_SEMIBOLD,
            )));
            self.title.setTextColor(Some(&red));
            self.title.setFrame(NSRect::new(
                NSPoint::new(44.0, 31.0),
                NSSize::new(width - 60.0, 17.0),
            ));
            self.detail.setStringValue(&NSString::from_str(detail));
            self.detail.setFont(Some(&NSFont::systemFontOfSize(12.0)));
            self.detail
                .setTextColor(Some(&NSColor::secondaryLabelColor()));
            self.detail.setFrame(NSRect::new(
                NSPoint::new(44.0, 14.0),
                NSSize::new(width - 60.0, 16.0),
            ));
            self.detail.setHidden(false);
            self.glyph.setContentTintColor(Some(&hud_color(if dark {
                0x00FF_6961
            } else {
                0x00D7_0015
            })));
            self.glyph.setFrame(NSRect::new(
                NSPoint::new(14.0, 21.0),
                NSSize::new(20.0, 20.0),
            ));
            self.glyph.setHidden(false);
            NSSize::new(width, WARNING_HEIGHT)
        } else if content.is_badge() {
            self.detail.setHidden(true);
            self.glyph.setHidden(true);
            let font = NSFont::monospacedDigitSystemFontOfSize_weight(30.0, FONT_WEIGHT_SEMIBOLD);
            self.title.setFont(Some(&font));
            self.title.setAlignment(NSTextAlignment::Center);
            let height = self.title.intrinsicContentSize().height.ceil();
            self.title.setFrame(NSRect::new(
                NSPoint::new(0.0, ((BADGE_SIDE - height) / 2.0).round()),
                NSSize::new(BADGE_SIDE, height),
            ));
            NSSize::new(BADGE_SIDE, BADGE_SIDE)
        } else {
            self.detail.setHidden(true);
            self.glyph.setHidden(true);
            self.title.setFont(Some(&NSFont::systemFontOfSize_weight(
                13.0,
                FONT_WEIGHT_MEDIUM,
            )));
            // Measured size plus slack: under a vibrant appearance the label's
            // cell asks for a few points more than `sizeToFit` reports, which
            // truncated short notes. The text is centred, so slack is invisible.
            self.title.sizeToFit();
            let mut text = self.title.frame().size;
            text.width += 8.0;
            let width = (text.width.ceil() + 2.0 * NOTE_PADDING)
                .max(120.0)
                .min(max_width.max(120.0));
            self.title.setAlignment(NSTextAlignment::Center);
            let height = text.height.ceil();
            self.title.setFrame(NSRect::new(
                NSPoint::new(NOTE_PADDING, ((NOTE_HEIGHT - height) / 2.0).round()),
                NSSize::new(width - 2.0 * NOTE_PADDING, height),
            ));
            NSSize::new(width, NOTE_HEIGHT)
        }
    }
}

/// Where a flash of `size` sits: the top-right corner of `visible` (Cocoa
/// coordinates, the screen's `visibleFrame`), inset like the minimap.
pub fn flash_frame(visible: NSRect, size: NSSize) -> NSRect {
    let x = visible.origin.x + visible.size.width - size.width - HUD_EDGE_INSET;
    let y = visible.origin.y + visible.size.height - size.height - HUD_EDGE_INSET;
    NSRect::new(
        NSPoint::new(x.max(visible.origin.x), y.max(visible.origin.y)),
        size,
    )
}

/// The opacity of a flash with `remaining` seconds left: fully there, then a
/// short fade at the end (the minimap's release fade), no fade-in.
pub fn flash_opacity(remaining: f32) -> f32 {
    const FADE: f32 = 0.2;
    (remaining / FADE).clamp(0.0, 1.0)
}

pub struct FlashMessageManager {
    mtm: MainThreadMarker,
    panel: Option<FlashPanel>,
    /// What is on screen: the content, its display and appearance, so a
    /// per-frame `show` only changes the alpha.
    shown: Option<(FlashContent, u32, bool)>,
    visible: bool,
}

impl FlashMessageManager {
    pub fn new(mtm: MainThreadMarker) -> Self {
        Self {
            mtm,
            panel: None,
            shown: None,
            visible: false,
        }
    }

    /// Shows `content` on display `display_id` at `opacity`. `fallback` is the
    /// display's usable area in CG coordinates, used only if no `NSScreen`
    /// matches the display.
    pub fn show(
        &mut self,
        content: &FlashContent,
        opacity: f32,
        display_id: u32,
        fallback: NSRect,
    ) {
        let mtm = self.mtm;
        let panel = self.panel.get_or_insert_with(|| FlashPanel::new(mtm));
        let dark = hud_appearance(mtm).1;
        let key = (content.clone(), display_id, dark);
        if !self.visible || self.shown.as_ref() != Some(&key) {
            let screens = NSScreen::screens(mtm);
            let visible = crate::util::read_screen_property(&screens, display_id, |screen| {
                screen.visibleFrame()
            })
            .unwrap_or_else(|| cg_abs_to_cocoa(fallback, primary_screen_height(mtm)));
            let max_width = (visible.size.width - 2.0 * HUD_EDGE_INSET).min(480.0);
            let size = panel.configure(mtm, content, max_width);
            panel.effect.setMaskImage(Some(&rounded_mask(size)));
            panel
                .window
                .setFrame_display(flash_frame(visible, size), true);
            panel.window.invalidateShadow();
            let is_new =
                self.shown.as_ref().is_none_or(|(old, ..)| old != content) || !self.visible;
            self.shown = Some(key);
            if is_new {
                announce(content);
            }
        }
        panel.window.setAlphaValue(CGFloat::from(opacity));
        if !self.visible {
            panel.window.orderFrontRegardless();
            self.visible = true;
        }
    }

    pub fn remove(&mut self) {
        if let Some(panel) = &self.panel
            && self.visible
        {
            panel.window.orderOut(None::<&AnyObject>);
        }
        self.visible = false;
        self.shown = None;
    }
}

/// Reads the flash to `VoiceOver`, as a system HUD would be read.
fn announce(content: &FlashContent) {
    let text = match &content.detail {
        Some(detail) => format!("{}. {detail}", content.title),
        None => content.title.clone(),
    };
    let Some(mtm) = MainThreadMarker::new() else {
        return;
    };
    let app = NSApplication::sharedApplication(mtm);
    let announcement = NSString::from_str(&text);
    let priority = NSNumber::new_isize(50); // NSAccessibilityPriorityMedium
    unsafe {
        let keys: [&NSAccessibilityNotificationUserInfoKey; 2] =
            [NSAccessibilityAnnouncementKey, NSAccessibilityPriorityKey];
        let objects: [&AnyObject; 2] = [&announcement, &priority];
        let info = NSDictionary::from_slices(&keys, &objects);
        NSAccessibilityPostNotificationWithUserInfo(
            &app,
            NSAccessibilityAnnouncementRequestedNotification,
            Some(&info),
        );
    }
}

#[cfg(test)]
mod tests {
    use super::{FlashContent, HUD_EDGE_INSET, flash_frame, flash_opacity};
    use objc2_foundation::{NSPoint, NSRect, NSSize};

    fn rect(x: f64, y: f64, w: f64, h: f64) -> NSRect {
        NSRect::new(NSPoint::new(x, y), NSSize::new(w, h))
    }

    /// Distance from the top of the screen to the top of `frame`, in points,
    /// for a screen `height` tall (Cocoa coordinates, origin bottom-left).
    fn top_gap(frame: NSRect, height: f64) -> f64 {
        height - (frame.origin.y + frame.size.height)
    }

    fn assert_close(actual: f64, expected: f64) {
        assert!((actual - expected).abs() < 1e-9, "{actual} != {expected}");
    }

    #[test]
    fn flash_sits_below_a_notched_menu_bar() {
        // 14-inch MacBook Pro default: 1512×982, a 37 pt menu bar, Dock hidden.
        let visible = rect(0.0, 0.0, 1512.0, 982.0 - 37.0);
        let frame = flash_frame(visible, NSSize::new(180.0, 40.0));
        assert_close(top_gap(frame, 982.0), 37.0 + HUD_EDGE_INSET);
        assert_close(frame.origin.x + frame.size.width, 1512.0 - HUD_EDGE_INSET);
    }

    #[test]
    fn flash_sits_below_a_plain_menu_bar_and_clear_of_a_right_dock() {
        // 1920×1080, a 24 pt menu bar, a 70 pt Dock on the right.
        let visible = rect(0.0, 0.0, 1920.0 - 70.0, 1080.0 - 24.0);
        let frame = flash_frame(visible, NSSize::new(340.0, 62.0));
        assert_close(top_gap(frame, 1080.0), 24.0 + HUD_EDGE_INSET);
        assert_close(frame.origin.x + frame.size.width, 1850.0 - HUD_EDGE_INSET);
    }

    #[test]
    fn flash_on_a_secondary_display_stays_on_it() {
        // A display left of and above the main one.
        let visible = rect(-1920.0, 1080.0, 1920.0, 1080.0 - 24.0);
        let frame = flash_frame(visible, NSSize::new(64.0, 64.0));
        assert!(frame.origin.x >= visible.origin.x);
        assert!(frame.origin.x + frame.size.width <= visible.origin.x + visible.size.width);
        assert!(frame.origin.y + frame.size.height <= visible.origin.y + visible.size.height);
    }

    #[test]
    fn flash_holds_then_fades_out_without_fading_in() {
        assert!((flash_opacity(1.6) - 1.0).abs() < f32::EPSILON);
        assert!((flash_opacity(0.2) - 1.0).abs() < f32::EPSILON);
        assert!((flash_opacity(0.1) - 0.5).abs() < 1e-6);
        assert!(flash_opacity(0.0).abs() < f32::EPSILON);
    }

    #[test]
    fn short_titles_are_badges_and_warnings_never_are() {
        let badge = FlashContent {
            title: "3".into(),
            detail: None,
        };
        let warning = FlashContent {
            title: "3".into(),
            detail: Some("x".into()),
        };
        let note = FlashContent {
            title: "View 3".into(),
            detail: None,
        };
        assert!(badge.is_badge());
        assert!(!warning.is_badge());
        assert!(!note.is_badge());
    }
}
