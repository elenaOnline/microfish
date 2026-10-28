//! Which windows the engine takes on. Standard windows tile; panels, dialogs,
//! sheets, popovers and menus belong to `AppKit`, which keeps them above their
//! owner and shows and hides them itself. Every route a window can take into
//! the engine ends in `spawn_window_trigger`, so each route is covered here.

use std::time::Duration;

use bevy::prelude::*;

use crate::commands::{Command, Direction, MoveFocus, Operation};
use crate::config::Config;
use crate::ecs::layout::LayoutStrip;
use crate::ecs::{ActiveWorkspaceMarker, FocusedMarker};
use crate::events::Event;
use crate::manager::{Admission, Window, WindowKind};
use crate::platform::WinID;

use super::*;

/// (role, subrole, label, the kind the engine must read it as).
const NOT_TILED: [(&str, &str, &str, WindowKind); 8] = [
    (
        "AXWindow",
        "AXFloatingWindow",
        "inspector",
        WindowKind::Panel,
    ),
    (
        "AXWindow",
        "AXSystemFloatingWindow",
        "system panel",
        WindowKind::Panel,
    ),
    ("AXWindow", "AXDialog", "dialog", WindowKind::Dialog),
    ("AXWindow", "AXSystemDialog", "alert", WindowKind::Dialog),
    ("AXSheet", "", "sheet", WindowKind::Sheet),
    ("AXDrawer", "", "drawer", WindowKind::Sheet),
    ("AXWindow", "AXUnknown", "popover", WindowKind::Unknown),
    ("AXWindow", "", "window still filling in", WindowKind::Other),
];

const PANEL_ID: WinID = 50;

fn tracked(world: &mut World, id: WinID) -> bool {
    world
        .query::<&Window>()
        .iter(world)
        .any(|window| window.id() == id)
}

fn in_a_strip(world: &mut World, id: WinID) -> bool {
    let entity = world
        .query::<(&Window, Entity)>()
        .iter(world)
        .find_map(|(window, entity)| (window.id() == id).then_some(entity));
    entity.is_some_and(|entity| {
        world
            .query::<&LayoutStrip>()
            .iter(world)
            .any(|strip| strip.contains(entity))
    })
}

fn active_row(world: &mut World) -> u32 {
    world
        .query_filtered::<&LayoutStrip, With<ActiveWorkspaceMarker>>()
        .single(world)
        .expect("exactly one active strip")
        .virtual_index
}

fn focused_id(world: &mut World) -> Option<WinID> {
    world
        .query_filtered::<&Window, With<FocusedMarker>>()
        .iter(world)
        .next()
        .map(|window| window.id())
}

fn command(operation: Operation) -> Event {
    Event::Command {
        command: Command::Window(operation),
    }
}

/// Makes `id` one of the non-tiled kinds in the mock, as a small untitled
/// window the way popovers and panels show up.
fn make_untiled(data: &mut MockWindowData, role: &str, subrole: &str) {
    data.role = role.to_string();
    data.subrole = subrole.to_string();
    data.child_role = matches!(role, "AXSheet" | "AXDrawer");
    data.frame = IRect::new(300, 300, 520, 555);
}

#[test]
fn classification_covers_every_role_and_subrole() {
    for (role, subrole, label, kind) in NOT_TILED {
        assert_eq!(WindowKind::classify(role, subrole), kind, "{label}");
        let admission = Admission::new(role, subrole, false);
        assert!(!admission.managed(), "{label} must not be managed");
        assert!(
            Admission::new(role, subrole, true).managed(),
            "{label}: a window rule with manage = true is the explicit opt-in"
        );
    }
    let standard = Admission::new("AXWindow", "AXStandardWindow", false);
    assert_eq!(standard.kind, WindowKind::Standard);
    assert!(standard.managed());
    assert_eq!(standard.decision(false), "tiled");
    assert_eq!(standard.decision(true), "floating (window rule)");
    assert_eq!(
        Admission::new("AXWindow", "AXFloatingWindow", false).decision(false),
        "unmanaged: panel"
    );
    assert_eq!(
        Admission::new("AXWindow", "AXFloatingWindow", true).decision(false),
        "tiled (window rule manage = true)"
    );
}

#[test]
fn a_window_already_reported_is_not_reported_again() {
    let admission = Admission::new("AXWindow", "AXFloatingWindow", false);
    assert!(crate::manager::report_rejection(
        i32::MAX - 7,
        "TestApp",
        &admission,
        || Some(true)
    ));
    for _ in 0..3 {
        assert!(!crate::manager::report_rejection(
            i32::MAX - 7,
            "TestApp",
            &admission,
            || panic!("a window already reported is not read again"),
        ));
    }
}

/// A window the app announces (the created notification, a launch, a retry).
#[test]
fn announced_windows_that_are_not_standard_are_never_tiled() {
    for (role, subrole, label, _) in NOT_TILED {
        let mut h = TestHarness::new()
            .with_windows(1)
            .with_window(PANEL_ID, |w| make_untiled(w, role, subrole));
        h.run(vec![Event::MenuOpened { window_id: 0 }]);
        h.advance(Duration::from_secs(1));
        assert!(tracked(h.world(), 0), "{label}: the standard window tiles");
        assert!(
            !tracked(h.world(), PANEL_ID),
            "{label}: must not be admitted when announced"
        );
        assert!(
            h.mock_state
                .take_geometry_writes()
                .iter()
                .all(|id| *id != PANEL_ID),
            "{label}: must not be moved or resized"
        );
        assert_eq!(
            h.mock_state.window_frame(PANEL_ID),
            IRect::new(300, 300, 520, 555),
            "{label}: stays where AppKit put it"
        );
    }
}

/// Windows that exist when the engine starts.
#[test]
fn the_initial_scan_skips_what_is_not_standard() {
    for (role, subrole, label, _) in NOT_TILED {
        let mut h = TestHarness::new();
        let frame = IRect::new(0, 0, TEST_WINDOW_WIDTH, TEST_WINDOW_HEIGHT);
        h.mock_state
            .spawn_window(TEST_PROCESS_ID, TEST_WORKSPACE_ID, 0, frame);
        h.mock_state
            .spawn_window(TEST_PROCESS_ID, TEST_WORKSPACE_ID, PANEL_ID, frame);
        h.mock_state
            .update_window(PANEL_ID, |w| make_untiled(w, role, subrole));
        h.run(vec![Event::MenuOpened { window_id: 0 }]);
        h.advance(Duration::from_secs(1));
        assert!(tracked(h.world(), 0), "{label}: the standard window tiles");
        assert!(
            !tracked(h.world(), PANEL_ID),
            "{label}: must not be admitted by the initial scan"
        );
    }
}

/// Focus on a window the engine has never heard of (a panel opening, a click
/// on it) tries to discover and adopt it, and retries.
#[test]
fn focus_time_discovery_never_adopts_what_is_not_standard() {
    for (role, subrole, label, _) in NOT_TILED {
        let mut h = TestHarness::new().with_windows(1);
        h.run(vec![Event::MenuOpened { window_id: 0 }]);
        h.mock_state.spawn_window(
            TEST_PROCESS_ID,
            TEST_WORKSPACE_ID,
            PANEL_ID,
            IRect::new(300, 300, 520, 555),
        );
        h.mock_state
            .update_window(PANEL_ID, |w| make_untiled(w, role, subrole));
        h.mock_state.focus_window(PANEL_ID);
        // The first attempt, then each retry of the backoff (1, 4, 16, 64 s).
        for wait in [1, 2, 6, 20, 70] {
            h.app
                .world_mut()
                .write_message::<Event>(Event::WindowFocused {
                    window_id: PANEL_ID,
                });
            h.advance(Duration::from_secs(wait));
            assert!(
                !tracked(h.world(), PANEL_ID),
                "{label}: focus-time discovery must not adopt it"
            );
        }
        assert_eq!(focused_id(h.world()), Some(0), "{label}: tiled focus stays");
    }
}

/// A row activation re-reads the windows macOS reports on the workspace and
/// retries the ones the engine does not know.
#[test]
fn the_row_activation_retry_never_adopts_what_is_not_standard() {
    let mut h = TestHarness::new().with_windows(2);
    h.run(vec![Event::MenuOpened { window_id: 0 }]);
    h.mock_state.spawn_window(
        TEST_PROCESS_ID,
        TEST_WORKSPACE_ID,
        PANEL_ID,
        IRect::new(300, 300, 520, 555),
    );
    h.mock_state.update_window(PANEL_ID, |w| {
        make_untiled(w, "AXWindow", "AXFloatingWindow");
    });
    h.run(vec![
        command(Operation::VirtualMoveNumber(1, MoveFocus::Follow)),
        command(Operation::VirtualNumber(0)),
        command(Operation::VirtualNumber(1)),
    ]);
    h.advance(Duration::from_secs(2));
    assert!(!tracked(h.world(), PANEL_ID));
    assert!(tracked(h.world(), 0) && tracked(h.world(), 1));
}

/// An app on a hidden row opens an inspector: the panel keeps focus the way
/// `AppKit` gives it, and nothing about the row changes.
#[test]
fn focus_on_a_panel_of_a_hidden_row_app_reveals_nothing() {
    let mut h = TestHarness::new().with_windows(2);
    h.run(vec![
        Event::MenuOpened { window_id: 0 },
        // Window 0 goes to row 2 and stays hidden there; window 1 is shown.
        command(Operation::VirtualMoveNumber(1, MoveFocus::Stay)),
    ]);
    h.advance(Duration::from_secs(1));
    assert_eq!(active_row(h.world()), 0);
    assert_eq!(focused_id(h.world()), Some(1));
    let parked = h.mock_state.window_frame(0);
    h.mock_state.take_geometry_writes();

    h.mock_state.spawn_window(
        TEST_PROCESS_ID,
        TEST_WORKSPACE_ID,
        PANEL_ID,
        IRect::new(300, 300, 520, 555),
    );
    h.mock_state.update_window(PANEL_ID, |w| {
        make_untiled(w, "AXWindow", "AXFloatingWindow");
    });
    h.mock_state.focus_window(PANEL_ID);

    // The panel takes focus: the event names the panel, then names the hidden
    // row's own window while the app answers that the panel is focused.
    for window_id in [PANEL_ID, 0, PANEL_ID] {
        h.run(vec![Event::WindowFocused { window_id }]);
        h.advance(Duration::from_secs(2));
        assert_eq!(
            active_row(h.world()),
            0,
            "focus on the panel must not reveal the row of its owner's window"
        );
        assert_eq!(
            focused_id(h.world()),
            Some(1),
            "the tiled focus does not move to the panel"
        );
        assert!(!tracked(h.world(), PANEL_ID));
    }
    assert_eq!(
        h.mock_state.window_frame(0),
        parked,
        "window 0 stays parked"
    );
    assert!(
        h.mock_state
            .take_geometry_writes()
            .iter()
            .all(|id| *id != PANEL_ID),
        "the panel is never moved or resized"
    );
}

/// The app's tiled focus bookkeeping survives the panel: after the panel goes
/// away the owner's window is still where it was in the strip and focused.
#[test]
fn a_panel_does_not_disturb_the_owners_tiled_focus() {
    let mut h = TestHarness::new().with_windows(3);
    h.run(vec![
        Event::MenuOpened { window_id: 0 },
        command(Operation::Focus(Direction::First)),
    ]);
    h.advance(Duration::from_secs(1));
    assert_eq!(focused_id(h.world()), Some(0));
    h.mock_state.spawn_window(
        TEST_PROCESS_ID,
        TEST_WORKSPACE_ID,
        PANEL_ID,
        IRect::new(300, 300, 520, 555),
    );
    h.mock_state.update_window(PANEL_ID, |w| {
        make_untiled(w, "AXWindow", "AXFloatingWindow");
    });
    h.mock_state.focus_window(PANEL_ID);
    h.run(vec![Event::WindowFocused {
        window_id: PANEL_ID,
    }]);
    h.advance(Duration::from_secs(3));
    assert_eq!(focused_id(h.world()), Some(0));
    assert!(in_a_strip(h.world(), 0) && in_a_strip(h.world(), 1) && in_a_strip(h.world(), 2));
    assert!(!in_a_strip(h.world(), PANEL_ID));
    // Closing the panel hands focus back to the main window.
    h.mock_state.os_close_window(PANEL_ID);
    h.mock_state.focus_window(0);
    h.run(vec![Event::WindowFocused { window_id: 0 }]);
    h.advance(Duration::from_secs(1));
    assert_eq!(focused_id(h.world()), Some(0));
}

fn config_with(rules: &str) -> Config {
    Config::try_from(format!("[options]\n\n[bindings]\n\n{rules}").as_str())
        .expect("config should parse")
}

/// `manage = true` is the documented opt-in for an app that misreports its
/// windows, so it still wins over the kind; a `floating` rule does not.
#[test]
fn a_manage_rule_is_the_explicit_opt_in_and_a_floating_rule_is_not() {
    let config = config_with(
        r#"
[windows.misreported]
title = "Main Misreported"
manage = true

[windows.float]
title = "Always Float"
floating = true
"#,
    );
    let mut h = TestHarness::new()
        .with_config(config)
        .with_windows(1)
        .with_window(60, |w| {
            make_untiled(w, "AXWindow", "AXFloatingWindow");
            w.title = "Main Misreported".to_string();
        })
        .with_window(61, |w| {
            make_untiled(w, "AXWindow", "AXFloatingWindow");
            w.title = "Always Float".to_string();
        })
        .with_window(62, |w| {
            make_untiled(w, "AXWindow", "AXFloatingWindow");
            w.title = "Find".to_string();
        });
    h.run(vec![Event::MenuOpened { window_id: 0 }]);
    h.advance(Duration::from_secs(1));
    assert!(tracked(h.world(), 60), "the rule asked for it");
    assert!(!tracked(h.world(), 61), "floating does not admit a panel");
    assert!(!tracked(h.world(), 62));
}

/// Standard windows with no resize and no zoom button (Surfshark's 800x600
/// main window, Calculator) tile at their own size and are not fought with.
#[test]
fn a_standard_window_that_cannot_be_resized_tiles_and_is_not_fought_with() {
    let mut h = TestHarness::new()
        .with_window(0, |w| {
            w.resizable = false;
            w.frame = IRect::new(0, 0, 800, 600);
        })
        .with_window(1, |w| w.frame = IRect::new(0, 0, 400, 500));
    h.run(vec![Event::MenuOpened { window_id: 0 }]);
    h.advance(Duration::from_secs(2));
    assert!(in_a_strip(h.world(), 0), "it tiles as a column");
    // Whatever it takes to settle happens at once, then it is left alone.
    h.mock_state.take_resize_requests(0);
    h.advance(Duration::from_secs(10));
    assert!(
        h.mock_state.take_resize_requests(0).is_empty(),
        "an idle window that refuses to resize is not asked again"
    );
    // Moving around the strip asks it at most once per layout change.
    for direction in [Direction::West, Direction::East, Direction::West] {
        h.run(vec![command(Operation::Focus(direction.clone()))]);
        h.advance(Duration::from_secs(2));
        let asked = h.mock_state.take_resize_requests(0).len();
        assert!(asked <= 1, "{direction:?}: asked {asked} times");
        h.advance(Duration::from_secs(5));
        assert!(h.mock_state.take_resize_requests(0).is_empty());
    }
    let frame = h.mock_state.window_frame(0);
    assert_eq!((frame.width(), frame.height()), (800, 600), "its own size");
}
