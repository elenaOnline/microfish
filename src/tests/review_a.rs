//! Adversarial regression tests for the hidden-row parking audit, the
//! same-strip focus rule and the focus-time discovery retry.

use std::time::Duration;

use bevy::prelude::*;

use crate::commands::{Command, MoveFocus, Operation};
use crate::ecs::layout::LayoutStrip;
use crate::ecs::{ActiveWorkspaceMarker, FocusedMarker, Position};
use crate::events::Event;
use crate::manager::{Origin, Window};
use crate::platform::WinID;

use super::*;

fn command(operation: Operation) -> Event {
    Event::Command {
        command: Command::Window(operation),
    }
}

fn active_row(world: &mut World) -> u32 {
    let mut query = world.query_filtered::<&LayoutStrip, With<ActiveWorkspaceMarker>>();
    query
        .single(world)
        .expect("exactly one active strip")
        .virtual_index
}

fn focused_id(world: &mut World) -> Option<WinID> {
    let mut query = world.query_filtered::<&Window, With<FocusedMarker>>();
    query.iter(world).next().map(|window| window.id())
}

/// A focus event that arrives late must not undo the app's current answer: the
/// app says window 0 (row 1, shown) is focused, the event still names window 1
/// (row 0, hidden since). Following the event would yank the user back.
#[test]
fn stale_focus_event_for_a_hidden_row_does_not_pull_the_row_back() {
    TestHarness::new()
        .with_windows(2)
        .on_iteration(1, |world, state| {
            assert_eq!(active_row(world), 1);
            assert_eq!(focused_id(world), Some(0));
            assert_eq!(state.app_focused_window(TEST_PROCESS_ID), Some(0));
        })
        .on_iteration(3, |world, _state| {
            assert_eq!(
                active_row(world),
                1,
                "a stale event for a window on a hidden row must not reveal that row"
            );
            assert_eq!(focused_id(world), Some(0));
        })
        .run(vec![
            Event::MenuOpened { window_id: 0 },
            command(Operation::VirtualMoveNumber(1, MoveFocus::Follow)),
            Event::WindowFocused { window_id: 1 },
            Event::Command {
                command: Command::PrintState,
            },
        ]);
}

/// A focus event for a window nothing can hand over (a panel, a popup) keeps
/// arriving. Each retry is a full window-list scan of every app, on the main
/// thread; a steady event stream must not turn into a steady scan stream.
#[test]
fn unmanageable_window_focus_events_do_not_rescan_forever() {
    let mut h = TestHarness::new().with_windows(1);
    h.run(vec![Event::MenuOpened { window_id: 0 }]);
    let before = h.mock_state.window_list_scans();
    // An id that exists nowhere: every focus event for it fails discovery.
    for _ in 0..120 {
        h.app
            .world_mut()
            .write_message::<Event>(Event::WindowFocused { window_id: 777 });
        h.advance(Duration::from_millis(500));
    }
    let scans = h.mock_state.window_list_scans() - before;
    assert!(
        scans <= 5,
        "a minute of focus events for one unmanageable window cost {scans} scans"
    );
}

fn right_display() -> IRect {
    IRect::new(
        TEST_DISPLAY_WIDTH,
        0,
        TEST_DISPLAY_WIDTH + EXT_DISPLAY_WIDTH,
        EXT_DISPLAY_HEIGHT,
    )
}

/// Window 100 on the second display's only row; window 200 on the first.
fn two_displays() -> (TestHarness, Entity) {
    let mut h =
        TestHarness::new().with_display(EXT_DISPLAY_ID, right_display(), vec![EXT_WORKSPACE_ID]);
    let size = Origin::new(TEST_WINDOW_WIDTH, 600);
    let first = Origin::new(0, TEST_MENUBAR_HEIGHT);
    let second = Origin::new(TEST_DISPLAY_WIDTH, TEST_MENUBAR_HEIGHT);
    h.mock_state.spawn_window(
        TEST_PROCESS_ID,
        TEST_WORKSPACE_ID,
        200,
        IRect::from_corners(first, first + size),
    );
    h.mock_state.spawn_window(
        TEST_PROCESS_ID,
        EXT_WORKSPACE_ID,
        100,
        IRect::from_corners(second, second + size),
    );
    h.run(vec![
        Event::Command {
            command: Command::PrintState,
        },
        Event::Command {
            command: Command::PrintState,
        },
    ]);
    h.advance(Duration::from_secs(3));
    let entity = find_window_entity(100, h.world());
    (h, entity)
}

/// Window 200 is focused, so the only active strip is on the first display.
/// The second display's row is shown, not hidden, and an app that moves its
/// own window there (across to the first display, say) is not to be pulled back.
#[test]
fn visible_row_on_the_other_display_is_not_treated_as_hidden() {
    let (mut h, entity) = two_displays();
    let before = h.world().get::<Position>(entity).unwrap().0;
    assert_eq!(
        h.mock_state.window_frame(100).min,
        before,
        "laid out where planned"
    );

    let elsewhere = Origin::new(100, 200);
    h.mock_state.os_move_window(100, elsewhere);
    h.advance(Duration::from_secs(6));
    assert_eq!(
        h.mock_state.window_frame(100).min,
        elsewhere,
        "the engine moved a visible window of the other display back"
    );
}

/// Same, when the app never says it moved.
#[test]
fn audit_leaves_visible_row_on_the_other_display_alone() {
    let (mut h, _entity) = two_displays();
    let elsewhere = Origin::new(100, 200);
    h.mock_state.update_window(100, |w| {
        let size = w.frame.size();
        w.frame.min = elsewhere;
        w.frame.max = elsewhere + size;
    });
    h.advance(Duration::from_secs(10));
    assert_eq!(
        h.mock_state.window_frame(100).min,
        elsewhere,
        "the audit moved a visible window of the other display back"
    );
}
