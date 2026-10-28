//! The Cocoa side of the empty-row keyboard hold.
//!
//! Entering an empty row leaves the window that held keyboard focus parked and
//! invisible, so the engine makes itself the front process instead: it is an
//! `.accessory` application with no windows and no main menu, so a keystroke
//! reaches nothing. Key events then reach the engine's own Cocoa queue (see
//! `PlatformCallbacks::pump_cocoa_event_loop`), and only because of the hold.
//! This module keeps what that pump needs, outside the ECS: whether the hold is
//! engaged, which app was in front before it, and what a key does meanwhile.

use std::sync::atomic::{AtomicI32, Ordering};

use accessibility_sys::{AXUIElementCreateApplication, AXUIElementPerformAction};
use objc2_app_kit::{NSBeep, NSEvent, NSEventModifierFlags, NSEventType};
use objc2_core_foundation::{CFArray, CFBoolean, CFNumber, CFRetained, CFString};
use tracing::{debug, info};

use super::{Pid, ProcessSerialNumber};
use crate::util::{AXUIAttributes, AXUIWrapper};

/// No hold. Otherwise the pid of the app that was in front (0: none to ask).
static HELD_PREVIOUS: AtomicI32 = AtomicI32::new(NOT_HELD);
const NOT_HELD: i32 = -1;

/// A synchronous AX call to an app that stopped answering blocks the main
/// thread, which here is the whole engine. Same bound `ApplicationOS` uses.
const MENU_WALK_TIMEOUT_SEC: f32 = 0.25;

/// How far into a menu to look for the New Window item: bar item, menu, item,
/// submenu, item. Apps that file it under a "New" submenu are one level deeper.
const MENU_WALK_DEPTH: usize = 5;
/// Each AX read is a round trip to the app, and the walk runs on the engine's
/// main thread: stop looking after this long rather than stall in a big menu.
const MENU_WALK_BUDGET: std::time::Duration = std::time::Duration::from_millis(250);

/// What the engine does with a key that arrives while it holds the keyboard.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum HoldKey {
    /// Not ours to judge: hand it to Cocoa as usual.
    Pass,
    /// ⌘N: ask the previous app for a new window.
    NewWindow,
    /// Nothing is listening: beep, as an app without windows does.
    Beep,
    /// A key repeat of the above. The first press already answered.
    Ignore,
}

/// Decides what a key does. `characters` is the key's
/// `charactersIgnoringModifiers`, so ⌘N means the key labelled N on the current
/// layout. Only ⌘ with nothing but Caps Lock, Fn or the numeric-pad bits
/// besides: ⇧⌘N, ⌥⌘N and ⌃⌘N are other commands.
#[must_use]
pub fn hold_key_action(
    held: bool,
    characters: &str,
    flags: NSEventModifierFlags,
    is_repeat: bool,
) -> HoldKey {
    if !held {
        return HoldKey::Pass;
    }
    if is_repeat {
        return HoldKey::Ignore;
    }
    let other_modifier =
        NSEventModifierFlags::Shift | NSEventModifierFlags::Option | NSEventModifierFlags::Control;
    if flags.contains(NSEventModifierFlags::Command)
        && !flags.intersects(other_modifier)
        && characters.eq_ignore_ascii_case("n")
    {
        HoldKey::NewWindow
    } else {
        HoldKey::Beep
    }
}

/// Records that the hold is engaged, with the app that was in front before it.
pub fn engage(previous: Option<Pid>) {
    HELD_PREVIOUS.store(previous.unwrap_or(0).max(0), Ordering::Release);
}

/// Records that the hold is over.
pub fn release() {
    HELD_PREVIOUS.store(NOT_HELD, Ordering::Release);
}

/// The engine's own process serial number.
#[must_use]
pub fn own_psn() -> Option<ProcessSerialNumber> {
    unsafe extern "C" {
        /// Deprecated, but the supported way to get the PSN for a pid, and the
        /// one the window server's own `_SLPS*` calls take.
        fn GetProcessForPID(pid: Pid, psn: *mut ProcessSerialNumber) -> i32;
    }
    let mut psn = ProcessSerialNumber::default();
    let status = unsafe { GetProcessForPID(std::process::id().cast_signed(), &raw mut psn) };
    (status == 0).then_some(psn)
}

/// Handles one event the pump dequeued. Returns `true` when the engine
/// consumed it, so it must not go on to `sendEvent:`.
pub fn handle_event(event: &NSEvent) -> bool {
    let previous = HELD_PREVIOUS.load(Ordering::Acquire);
    if previous == NOT_HELD || event.r#type() != NSEventType::KeyDown {
        return false;
    }
    let characters = event
        .charactersIgnoringModifiers()
        .map(|characters| characters.to_string())
        .unwrap_or_default();
    match hold_key_action(true, &characters, event.modifierFlags(), event.isARepeat()) {
        HoldKey::Pass => return false,
        HoldKey::Ignore => {}
        HoldKey::NewWindow => {
            if previous <= 0 || !press_new_window(previous) {
                info!(
                    "empty row: no New Window command to press in the previous app (pid {previous})"
                );
                NSBeep();
            }
        }
        HoldKey::Beep => NSBeep(),
    }
    true
}

/// Asks `pid` for a new window the way the user would with ⌘N, by pressing the
/// menu item that carries that shortcut. No keystroke is delivered to the app,
/// so none of its windows becomes the keyboard target before the new one
/// exists. Returns `false` when there is no such enabled item or pressing it
/// failed.
///
/// Reads the live menu bar, so it can only be exercised against a real app.
fn press_new_window(pid: Pid) -> bool {
    let Ok(app) = AXUIWrapper::from_retained(unsafe { AXUIElementCreateApplication(pid) }) else {
        return false;
    };
    unsafe {
        accessibility_sys::AXUIElementSetMessagingTimeout(app.as_ptr(), MENU_WALK_TIMEOUT_SEC);
    }
    let Ok(menu_bar) = app.get_attribute::<AXUIWrapper>(&CFString::from_static_str(
        accessibility_sys::kAXMenuBarAttribute,
    )) else {
        return false;
    };
    let deadline = std::time::Instant::now() + MENU_WALK_BUDGET;
    let Some(item) = find_new_window_item(&menu_bar, MENU_WALK_DEPTH, deadline) else {
        debug!("no enabled ⌘N item found in pid {pid} within the walk budget");
        return false;
    };
    let press = CFString::from_static_str(accessibility_sys::kAXPressAction);
    let status = unsafe {
        AXUIElementPerformAction(item.as_ptr(), std::ptr::from_ref::<CFString>(&press).cast())
    };
    debug!("pressed New Window in pid {pid}: AX status {status}");
    status == accessibility_sys::kAXErrorSuccess
}

/// The enabled menu item with the shortcut ⌘N, searching `element`'s subtree.
fn find_new_window_item(
    element: &CFRetained<AXUIWrapper>,
    depth: usize,
    deadline: std::time::Instant,
) -> Option<CFRetained<AXUIWrapper>> {
    if depth == 0 || std::time::Instant::now() >= deadline {
        return None;
    }
    if is_command_n(element) {
        return Some(element.clone());
    }
    let children = element
        .get_attribute::<CFArray<AXUIWrapper>>(&CFString::from_static_str(
            accessibility_sys::kAXChildrenAttribute,
        ))
        .ok()?;
    children
        .to_vec()
        .iter()
        .find_map(|child| find_new_window_item(child, depth - 1, deadline))
}

/// Whether `element` is an enabled menu item whose whole shortcut is ⌘N.
/// `AXMenuItemCmdModifiers` is 0 for ⌘ alone; the bits add ⇧, ⌥, ⌃, and (bit 3)
/// take the ⌘ away.
fn is_command_n(element: &CFRetained<AXUIWrapper>) -> bool {
    let attribute = |name: &'static str| CFString::from_static_str(name);
    let Ok(key) = element
        .get_attribute::<CFString>(&attribute(accessibility_sys::kAXMenuItemCmdCharAttribute))
    else {
        return false;
    };
    if !key.to_string().eq_ignore_ascii_case("n") {
        return false;
    }
    let plain_command = element
        .get_attribute::<CFNumber>(&attribute(
            accessibility_sys::kAXMenuItemCmdModifiersAttribute,
        ))
        .ok()
        .and_then(|modifiers| modifiers.as_i64())
        .is_none_or(|modifiers| modifiers == 0);
    let enabled = element
        .get_attribute::<CFBoolean>(&attribute(accessibility_sys::kAXEnabledAttribute))
        .map_or(true, |enabled| enabled.value());
    plain_command && enabled
}

#[cfg(test)]
mod tests {
    use super::*;

    const COMMAND: NSEventModifierFlags = NSEventModifierFlags::Command;

    #[test]
    fn command_n_while_held_asks_for_a_new_window() {
        assert_eq!(
            hold_key_action(true, "n", COMMAND, false),
            HoldKey::NewWindow
        );
        assert_eq!(
            hold_key_action(true, "N", COMMAND, false),
            HoldKey::NewWindow,
            "case does not matter"
        );
        assert_eq!(
            hold_key_action(true, "n", COMMAND | NSEventModifierFlags::CapsLock, false),
            HoldKey::NewWindow,
            "Caps Lock is not a chord"
        );
    }

    #[test]
    fn other_chords_on_n_are_not_new_window() {
        for extra in [
            NSEventModifierFlags::Shift,
            NSEventModifierFlags::Option,
            NSEventModifierFlags::Control,
        ] {
            assert_eq!(
                hold_key_action(true, "n", COMMAND | extra, false),
                HoldKey::Beep,
                "{extra:?}+Command+N"
            );
        }
        assert_eq!(
            hold_key_action(true, "n", NSEventModifierFlags::empty(), false),
            HoldKey::Beep,
            "a bare n"
        );
        assert_eq!(hold_key_action(true, "w", COMMAND, false), HoldKey::Beep);
        assert_eq!(hold_key_action(true, "q", COMMAND, false), HoldKey::Beep);
        assert_eq!(
            hold_key_action(true, "\r", NSEventModifierFlags::empty(), false),
            HoldKey::Beep
        );
    }

    #[test]
    fn nothing_is_judged_while_not_held() {
        assert_eq!(hold_key_action(false, "n", COMMAND, false), HoldKey::Pass);
        assert_eq!(
            hold_key_action(false, "a", NSEventModifierFlags::empty(), false),
            HoldKey::Pass
        );
    }

    #[test]
    fn a_key_repeat_is_not_answered_again() {
        assert_eq!(hold_key_action(true, "n", COMMAND, true), HoldKey::Ignore);
        assert_eq!(
            hold_key_action(true, "a", NSEventModifierFlags::empty(), true),
            HoldKey::Ignore
        );
    }
}
