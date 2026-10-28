//! Adversarial review of the behavior batch (empty-row hold, parking audit).
//! Tests marked RED fail on the batch; the others pin down what was found sound.

use std::time::Duration;

use bevy::prelude::*;

use crate::commands::{Direction, MoveFocus, Operation};
use crate::ecs::focus::KeyboardHold;
use crate::events::Event;
use crate::manager::Origin;
use crate::platform::{ProcessSerialNumber, WinID};

use super::rows::{active_row, cmd, ecs_focus, focus, production_config, send};
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

/// Sound: the navigator's `FocusWindow` for a window on a hidden row, while the
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
    // Past the backoff's climb, the cost must be near the steady state (15
    // queries in 30 s, plus a look per 10 s correction step), not 4 a second.
    h.advance(Duration::from_secs(20));
    let before = h.mock_state.bounds_queries();
    h.advance(Duration::from_secs(30));
    let queries = h.mock_state.bounds_queries() - before;
    assert!(
        queries <= 24,
        "{queries} window-server queries in 30 s (steady state is one per 2 s)"
    );
}
