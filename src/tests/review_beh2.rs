//! Adversarial review of the behavior batch (empty-row hold, parking audit).
//! Tests marked RED fail on the batch; the others pin down what was found sound.

use std::time::Duration;

use bevy::prelude::*;

use crate::commands::{Direction, MoveFocus, Operation};
use crate::ecs::focus::KeyboardHold;
use crate::events::Event;
use crate::manager::Origin;
use crate::platform::{ProcessSerialNumber, WinID, WorkspaceId};

use super::rows::{active_row, cmd, ecs_focus, focus, production_config, rows, send};
use super::*;

const ESCAPE: Origin = Origin::new(16, 50);

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

fn into_empty_row(h: &mut TestHarness) {
    send(h, vec![cmd(Operation::Row(Direction::South))]);
    focus(h, 4);
    assert_eq!(active_row(h), 1);
    send(h, vec![cmd(Operation::Row(Direction::South))]);
    assert_eq!(active_row(h), 2);
}

fn held(h: &mut TestHarness) -> bool {
    h.world().resource::<KeyboardHold>().engaged()
}

// ---------------------------------------------------------------- empty row

/// RED. The SLPS call "succeeds" but the engine never becomes the front
/// process (the app that was in front stays in front, so its parked window is
/// still the key window). Nothing checks, retries or reports: the engine
/// believes keystrokes are safe, `recover_lost_focus` is suppressed and the
/// focus handoff was cancelled, for as long as the row stays empty.
#[test]
fn red_a_hold_that_did_not_take_the_front_is_noticed() {
    let mut h = rig();
    h.mock_state.set_hold_ineffective();
    into_empty_row(&mut h);
    assert!(
        !h.mock_state.engine_is_front(),
        "setup: the switch did nothing"
    );
    h.advance(Duration::from_secs(10));
    let still_believes = held(&mut h) && h.mock_state.self_activations().len() == 1;
    assert!(
        !still_believes,
        "ten seconds on, the hold is engaged, the engine is not front, and no retry or release happened"
    );
}

/// RED. A front-switch notification for an app arrives late (the handoff of the
/// previous row's focus), after the engine has already taken the front for the
/// empty row. The OS front is still the engine, yet the hold is dropped, so
/// the new-window focus handoff and the Cmd-N path are gone.
#[test]
fn red_a_stale_front_switch_does_not_end_a_hold_the_engine_still_has() {
    let mut h = rig();
    into_empty_row(&mut h);
    assert!(h.mock_state.engine_is_front());
    let app_psn = ProcessSerialNumber {
        high: 0,
        low: TEST_PROCESS_ID as u32,
    };
    _ = app_psn;
    // The front switch of the app the row switch came from, delivered late.
    let psn = h.mock_state.app_psn(TEST_PROCESS_ID);
    send(&mut h, vec![Event::ApplicationFrontSwitched { psn }]);
    assert!(
        h.mock_state.engine_is_front(),
        "the OS front did not change in this scenario"
    );
    assert!(held(&mut h), "hold dropped while the engine is still front");
}

/// Sound: a stale focus event for the parked window, after the engage, is
/// dropped by the live frontmost check.
#[test]
fn stale_focus_event_after_engage_is_dropped() {
    let mut h = rig();
    into_empty_row(&mut h);
    send(&mut h, vec![Event::WindowFocused { window_id: 4 }]);
    assert_eq!(active_row(&mut h), 2);
    assert!(held(&mut h));
    assert_eq!(ecs_focus(&mut h), Vec::<WinID>::new());
}

/// Sound: the navigator's FocusWindow for a window on a hidden row, while the
/// hold is engaged, reveals the row and hands the keyboard back.
#[test]
fn focus_request_from_the_held_row_hands_the_keyboard_back() {
    let mut h = rig();
    into_empty_row(&mut h);
    let (respond_to, _answer) = async_channel::bounded(1);
    send(
        &mut h,
        vec![Event::FocusRequest {
            window: 4,
            respond_to,
        }],
    );
    h.advance(Duration::from_millis(600));
    assert_eq!(active_row(&mut h), 1);
    assert_eq!(ecs_focus(&mut h), vec![4]);
    assert!(!held(&mut h));
    assert!(!h.mock_state.engine_is_front());
}

/// RED (gap). Leave an empty row by a native Space change and come back. The
/// hold is released on the way out and nothing re-arms it on the way back,
/// because the focus marker then belongs to the other Space. The empty row is
/// on screen again with whatever key window macOS restored.
const OTHER_SPACE: WorkspaceId = TEST_WORKSPACE_ID + 2;
const OTHER_WINDOW: WinID = 9;

#[test]
fn red_returning_to_an_empty_row_by_space_change_holds_the_keyboard() {
    let spaces: Vec<WorkspaceId> = vec![TEST_WORKSPACE_ID, OTHER_SPACE];
    let mut h = TestHarness::new()
        .with_config(production_config())
        .with_display(
            TEST_DISPLAY_ID,
            IRect::new(0, 0, TEST_DISPLAY_WIDTH, TEST_DISPLAY_HEIGHT),
            spaces,
        )
        .with_windows(5)
        .with_workspace_window(OTHER_WINDOW, OTHER_SPACE, |_| {});
    send(&mut h, vec![Event::MenuOpened { window_id: 0 }]);
    for id in [3, 4] {
        focus(&mut h, id);
        send(
            &mut h,
            vec![cmd(Operation::VirtualMoveNumber(1, MoveFocus::Stay))],
        );
    }
    focus(&mut h, 1);
    into_empty_row(&mut h);
    assert!(held(&mut h));
    let activations = h.mock_state.self_activations().len();

    // Away to the other Space, where the user types into its window...
    h.mock_state
        .activate_workspace(TEST_DISPLAY_ID, OTHER_SPACE, false);
    send(&mut h, vec![Event::SpaceChanged]);
    focus(&mut h, OTHER_WINDOW);
    assert!(!held(&mut h));
    // ... and back. The empty row is the selected one again.
    h.mock_state
        .activate_workspace(TEST_DISPLAY_ID, TEST_WORKSPACE_ID, false);
    send(&mut h, vec![Event::SpaceChanged]);

    let on_screen = rows(&mut h)
        .into_iter()
        .filter(|row| row.active && row.windows.is_empty())
        .count();
    assert_eq!(on_screen, 1, "setup: the empty row is on screen again");
    assert!(
        h.mock_state.self_activations().len() > activations,
        "the empty row came back on screen with no hold: a parked window may be the key window"
    );
}

// ------------------------------------------------------------------ parking

fn with_window_on_hidden_row() -> TestHarness {
    let mut h = TestHarness::new().with_windows(2);
    h.run(vec![
        Event::MenuOpened { window_id: 0 },
        Event::Command {
            command: crate::commands::Command::Window(Operation::VirtualMoveNumber(
                1,
                MoveFocus::Stay,
            )),
        },
    ]);
    h.advance(Duration::from_secs(1));
    h
}

/// RED. A hidden-row window of an app that stopped answering accessibility
/// (a hung app: the park move never landed, so the window server still shows
/// it on screen). The audit marks it a suspect, the AX frame read fails, and
/// nothing is recorded, so the suspect is re-audited every quarter second:
/// a window-server query plus a 0.25 s AX timeout, on the main thread, for as
/// long as the app hangs. The steady state is one query per 2 s.
#[test]
fn red_a_displaced_window_whose_app_does_not_answer_is_not_audited_four_times_a_second() {
    let mut h = with_window_on_hidden_row();
    h.advance(Duration::from_secs(5));
    h.mock_state.update_window(0, |w| {
        let size = w.frame.size();
        w.frame.min = ESCAPE;
        w.frame.max = ESCAPE + size;
        w.frame_read_fails = true;
    });
    let before = h.mock_state.bounds_queries();
    h.advance(Duration::from_secs(10));
    let queries = h.mock_state.bounds_queries() - before;
    assert!(
        queries <= 8,
        "{queries} window-server queries in 10 s (steady state is one per 2 s)"
    );
}

/// RED (gap). The user closes the last windows of the row on screen. The row is
/// empty and on screen, nothing holds focus, and the app's other windows are all
/// parked on row 0, so macOS picks one of them as key window. The hold is only
/// ever engaged by a row activation, never by a row that becomes empty.
#[test]
fn red_closing_the_last_windows_of_the_active_row_holds_the_keyboard() {
    let mut h = rig();
    send(&mut h, vec![cmd(Operation::Row(Direction::South))]);
    focus(&mut h, 4);
    assert_eq!(active_row(&mut h), 1);
    h.mock_state.os_close_window(4);
    h.mock_state.os_close_window(3);
    h.advance(Duration::from_secs(2));
    h.mock_state.os_settle_window_list();
    h.advance(Duration::from_secs(2));
    let empty_on_screen = rows(&mut h)
        .into_iter()
        .any(|row| row.active && row.windows.is_empty());
    assert!(empty_on_screen, "setup: an empty row is on screen");
    assert!(
        held(&mut h) || h.mock_state.engine_is_front(),
        "an empty row is on screen, nothing holds the keyboard, windows 0 1 2 are parked"
    );
}
