//! The empty-row keyboard hold: after entering an empty row no parked,
//! invisible window may receive keystrokes. The engine makes itself the front
//! process (an accessory app with no windows) until the row gets a window or
//! the user leaves it. Driven through `Operation::Row`, like `rows.rs`.

use std::time::Duration;

use bevy::prelude::*;

use crate::commands::{Direction, MoveFocus, Operation};
use crate::ecs::SpawnWindowTrigger;
use crate::ecs::focus::KeyboardHold;
use crate::events::Event;
use crate::platform::{ProcessSerialNumber, WinID};

use super::rows::{active_row, cmd, ecs_focus, focus, production_config, rows, send};
use super::*;

const OTHER_PID: i32 = 2;

/// Rows 0 (windows 0, 1, 2) and 1 (windows 3, 4); row 0 active, focused on 1.
/// Row reaping is on, as in a typical configuration.
fn rig() -> TestHarness {
    let mut h = TestHarness::new()
        .with_config(production_config())
        .with_windows(5);
    send(&mut h, vec![Event::MenuOpened { window_id: 0 }]);
    for id in [3, 4] {
        focus(&mut h, id);
        send(
            &mut h,
            vec![cmd(Operation::VirtualMoveNumber(1, MoveFocus::Stay))],
        );
    }
    focus(&mut h, 1);
    h
}

/// Row 1 remembers window 4, then the user goes one row further, into a row
/// with nothing in it.
fn into_empty_row(h: &mut TestHarness) {
    send(h, vec![cmd(Operation::Row(Direction::South))]);
    focus(h, 4);
    assert_eq!(active_row(h), 1);
    send(h, vec![cmd(Operation::Row(Direction::South))]);
    assert_eq!(active_row(h), 2);
    assert!(rows(h)[2].windows.is_empty(), "row 2 is empty");
}

fn held(h: &mut TestHarness) -> bool {
    h.world().resource::<KeyboardHold>().engaged()
}

fn window_frame() -> IRect {
    IRect::new(0, 0, TEST_WINDOW_WIDTH, TEST_WINDOW_HEIGHT)
}

/// A window of `pid` appears, the app already reporting it focused as a real
/// one would for its own new window... or not, per `app_reports`.
fn new_window(h: &mut TestHarness, pid: i32, id: WinID, app_reports: Option<WinID>) {
    let window = h
        .mock_state
        .spawn_window(pid, TEST_WORKSPACE_ID, id, window_frame());
    if let Some(reported) = app_reports {
        h.mock_state.set_focused_window(reported);
    }
    h.world().trigger(SpawnWindowTrigger(vec![window]));
    h.advance(Duration::from_millis(600));
}

#[test]
fn entering_an_empty_row_holds_the_keyboard() {
    let mut h = rig();
    send(&mut h, vec![cmd(Operation::Row(Direction::South))]);
    focus(&mut h, 4);
    assert!(
        h.mock_state.self_activations().is_empty(),
        "a row with windows needs no hold"
    );
    assert!(!held(&mut h));

    send(&mut h, vec![cmd(Operation::Row(Direction::South))]);
    assert_eq!(active_row(&mut h), 2);
    assert_eq!(
        h.mock_state.self_activations(),
        vec![Some(TEST_PROCESS_ID)],
        "the engine took the front once, naming the app it left"
    );
    assert!(h.mock_state.engine_is_front());
    assert!(held(&mut h));
    assert_eq!(
        ecs_focus(&mut h),
        Vec::<WinID>::new(),
        "window 4 is parked: nothing may hold the focus marker"
    );
}

#[test]
fn leaving_the_empty_row_focuses_the_remembered_window_through_the_handoff() {
    let mut h = rig();
    into_empty_row(&mut h);
    let before = h.mock_state.focus_calls().len();

    send(&mut h, vec![cmd(Operation::Row(Direction::North))]);

    assert_eq!(active_row(&mut h), 1);
    assert_eq!(ecs_focus(&mut h), vec![4]);
    let asked = h.mock_state.focus_calls()[before..]
        .iter()
        .map(|call| call.target)
        .collect::<Vec<_>>();
    assert!(
        asked.contains(&4),
        "the OS was never asked to focus the remembered window: {asked:?}"
    );
    assert_eq!(h.mock_state.app_focused_window(TEST_PROCESS_ID), Some(4));
    assert!(!h.mock_state.engine_is_front(), "an app is in front again");
    assert!(!held(&mut h));
}

/// The window comes from the app the user just left (⌘N through its menu), or
/// from an app that was never in front. Either way the row it lands in is the
/// one on screen, and it takes focus.
#[test]
fn a_window_arriving_in_the_held_row_is_placed_there_and_focused() {
    for (pid, id) in [(TEST_PROCESS_ID, 10), (OTHER_PID, 20)] {
        let mut h = rig().with_app(OTHER_PID, "other", "Other", |app| app.is_frontmost = false);
        into_empty_row(&mut h);
        assert!(held(&mut h));

        // The app still names the old parked window: the worst case.
        new_window(&mut h, pid, id, (pid == TEST_PROCESS_ID).then_some(4));

        assert_eq!(active_row(&mut h), 2, "pid {pid}: the row stays");
        assert_eq!(rows(&mut h)[2].windows, vec![id], "pid {pid}: placed");
        assert_eq!(ecs_focus(&mut h), vec![id], "pid {pid}: focused");
        assert!(!held(&mut h), "pid {pid}: the hold ended");
        assert!(
            !h.mock_state.engine_is_front(),
            "pid {pid}: an app is front"
        );
        assert_eq!(h.mock_state.app_focused_window(pid), Some(id));
    }
}

#[test]
fn without_a_hold_a_background_apps_new_window_does_not_take_focus() {
    let mut h = rig().with_app(OTHER_PID, "other", "Other", |app| app.is_frontmost = false);
    new_window(&mut h, OTHER_PID, 20, None);
    assert_eq!(active_row(&mut h), 0);
    assert!(rows(&mut h)[0].windows.contains(&20), "placed in the row");
    assert_eq!(
        ecs_focus(&mut h),
        vec![1],
        "focus stays with the user's window"
    );
    assert!(h.mock_state.self_activations().is_empty());
}

#[test]
fn a_front_switch_to_another_process_releases_the_hold_without_a_focus_request() {
    let mut h = rig();
    into_empty_row(&mut h);
    assert!(held(&mut h));
    // Spotlight, Raycast: not a process the engine manages.
    let before = h.mock_state.focus_calls().len();
    h.mock_state.unmanaged_takes_front();
    send(
        &mut h,
        vec![Event::ApplicationFrontSwitched {
            psn: ProcessSerialNumber {
                high: 0,
                low: 0x5107,
            },
        }],
    );
    assert!(!held(&mut h));
    assert_eq!(h.mock_state.focus_calls().len(), before, "no focus request");
    assert_eq!(active_row(&mut h), 2, "still in the empty row");
    assert_eq!(ecs_focus(&mut h), Vec::<WinID>::new());
}

#[test]
fn the_engines_own_front_switch_keeps_the_hold() {
    let mut h = rig();
    into_empty_row(&mut h);
    send(
        &mut h,
        vec![Event::ApplicationFrontSwitched { psn: ENGINE_PSN }],
    );
    assert!(held(&mut h));
}

/// Cmd-Tab into an app whose window is parked on another row ends the hold and
/// takes that row, as it does without one.
#[test]
fn switching_to_an_app_with_a_parked_window_leaves_the_held_row() {
    let mut h = rig();
    into_empty_row(&mut h);
    h.mock_state.focus_window(4);
    h.advance(Duration::from_millis(600));
    assert!(!held(&mut h));
    assert_eq!(active_row(&mut h), 1);
    assert_eq!(ecs_focus(&mut h), vec![4]);
}

#[test]
fn no_focus_is_recovered_onto_a_parked_window_while_held() {
    let mut h = rig();
    into_empty_row(&mut h);
    // `recover_lost_focus` runs once a second whenever nothing holds focus.
    h.advance(Duration::from_secs(3));
    assert_eq!(ecs_focus(&mut h), Vec::<WinID>::new());
    assert!(held(&mut h));
    assert_eq!(active_row(&mut h), 2);
}

/// The last window of the active row is moved away. With nothing left to look
/// at the window follows, so the focused window stays on screen: nothing is
/// parked under the keyboard and no hold is needed.
#[test]
fn moving_the_active_rows_last_window_away_keeps_focus_on_it_and_needs_no_hold() {
    let mut h = TestHarness::new()
        .with_config(production_config())
        .with_windows(2);
    send(&mut h, vec![Event::MenuOpened { window_id: 0 }]);
    // Window 1 alone on row 1, which is active and focused on it.
    focus(&mut h, 1);
    send(
        &mut h,
        vec![cmd(Operation::VirtualMoveNumber(1, MoveFocus::Follow))],
    );
    assert_eq!(active_row(&mut h), 1);
    assert_eq!(rows(&mut h)[1].windows, vec![1]);

    send(
        &mut h,
        vec![cmd(Operation::VirtualMoveNumber(0, MoveFocus::Stay))],
    );

    assert_eq!(active_row(&mut h), 0, "the window took its row along");
    assert_eq!(ecs_focus(&mut h), vec![1]);
    assert!(!held(&mut h));
    assert!(h.mock_state.self_activations().is_empty());
}

/// Focus on another display's visible window is not endangered by this
/// display's row going empty, so the keyboard is left alone.
#[test]
fn an_empty_row_on_another_display_than_the_focus_does_not_hold() {
    let mut h = TestHarness::new()
        .with_config(production_config())
        .with_display(
            EXT_DISPLAY_ID,
            IRect::new(0, -EXT_DISPLAY_HEIGHT, EXT_DISPLAY_WIDTH, 0),
            vec![EXT_WORKSPACE_ID],
        )
        .with_windows(2)
        .with_workspace_window(100, EXT_WORKSPACE_ID, |_| {});
    h.advance(Duration::from_millis(600));
    // Focus is on the external display's window; the pointer, and with it the
    // row keys, are on the main display.
    focus(&mut h, 100);
    h.mock_state.set_active_display(TEST_DISPLAY_ID);
    send(&mut h, vec![Event::DisplayChanged]);
    assert_eq!(ecs_focus(&mut h), vec![100]);

    send(&mut h, vec![cmd(Operation::Row(Direction::South))]);

    let main_rows = rows(&mut h)
        .into_iter()
        .filter(|row| row.windows.is_empty())
        .count();
    assert_eq!(main_rows, 1, "the main display got an empty row");
    assert!(!held(&mut h));
    assert!(h.mock_state.self_activations().is_empty());
    assert_eq!(ecs_focus(&mut h), vec![100], "the focus stays where it was");
}
