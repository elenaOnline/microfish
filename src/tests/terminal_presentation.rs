//! How a terminal window presents when it is created or activated while the
//! app's other windows sit on a hidden row. Terminals create their window
//! before they are key, and the app's AX focused window can lag the creation,
//! so these tests make the app report a stale focused window and check the
//! engine still reveals and focuses the window the user just asked for.

use bevy::prelude::*;

use crate::commands::{Command, MoveFocus, Operation};
use crate::ecs::layout::LayoutStrip;
use crate::ecs::{ActiveWorkspaceMarker, FocusedMarker, SpawnWindowTrigger};
use crate::events::Event;
use crate::manager::Window;
use crate::platform::{ProcessSerialNumber, WinID};

use super::*;

const OTHER_PID: i32 = 2;

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

fn window_frame() -> IRect {
    IRect::new(0, 0, TEST_WINDOW_WIDTH, TEST_WINDOW_HEIGHT)
}

/// Window 0 (the terminal) ends up alone on hidden row 1; window 1 stays on the
/// active row 0.
fn terminal_on_hidden_row() -> Vec<Event> {
    vec![
        Event::MenuOpened { window_id: 0 },
        command(Operation::VirtualMoveNumber(1, MoveFocus::Follow)),
        command(Operation::VirtualNumber(0)),
    ]
}

/// A new terminal window appears while the app's AX focused window still names
/// the old terminal window parked on a hidden row. The engine must not take
/// that stale answer as the user's focus: it would activate the hidden row and
/// park the row the new window was just inserted into.
#[test]
fn new_window_is_not_pulled_back_to_hidden_row_by_stale_app_focus() {
    let mut commands = terminal_on_hidden_row();
    commands.push(Event::Command {
        command: Command::PrintState,
    });

    TestHarness::new()
        .with_windows(2)
        .on_iteration(2, |world, state| {
            assert_eq!(active_row(world), 0);
            assert_eq!(focused_id(world), Some(1));

            let window = state.spawn_window(TEST_PROCESS_ID, TEST_WORKSPACE_ID, 2, window_frame());
            // The app has not caught up: it still reports the old window.
            state.set_focused_window(0);
            world.trigger(SpawnWindowTrigger(vec![window]));
        })
        .on_iteration(3, |world, _state| {
            assert_eq!(
                active_row(world),
                0,
                "a new window must not be parked by activating the app's old window's row"
            );
            assert_eq!(focused_id(world), Some(2));
        })
        .run(commands);
}

/// Cmd-Tab (or a Dock click) into a terminal whose only window is on a hidden
/// row reveals that row and focuses the window.
#[test]
fn activating_terminal_reveals_its_hidden_row() {
    let mut commands = terminal_on_hidden_row();
    commands.push(Event::ApplicationFrontSwitched {
        psn: ProcessSerialNumber {
            high: 0,
            low: TEST_PROCESS_ID.cast_unsigned(),
        },
    });
    commands.push(Event::Command {
        command: Command::PrintState,
    });

    let mut harness =
        TestHarness::new()
            .with_windows(1)
            .with_app(OTHER_PID, "other", "Other", |app| app.is_frontmost = false);
    let other = harness
        .mock_state
        .spawn_window(OTHER_PID, TEST_WORKSPACE_ID, 10, window_frame());
    harness.world().trigger(SpawnWindowTrigger(vec![other]));

    harness
        .on_iteration(2, |world, state| {
            assert_eq!(active_row(world), 0);
            assert_eq!(focused_id(world), Some(10));
            // The user Cmd-Tabs back to the terminal.
            state.update_app(TEST_PROCESS_ID, |app| app.is_frontmost = true);
            state.update_app(OTHER_PID, |app| app.is_frontmost = false);
            state.set_focused_window(0);
        })
        .on_iteration(3, |world, _state| {
            assert_eq!(active_row(world), 1, "the terminal's row must be revealed");
            assert_eq!(focused_id(world), Some(0));
        })
        .on_iteration(4, |_world, state| {
            let frame = state.physical_window_frame(0);
            assert!(
                frame.min.x < TEST_DISPLAY_WIDTH && frame.min.y < TEST_DISPLAY_HEIGHT,
                "the revealed window must leave the parking corner, was at {:?}",
                frame.min
            );
        })
        .run(commands);
}

/// A terminal window created while another app is in front (Spotlight, a CLI,
/// a hotkey that has not finished activating it) is placed in the strip but
/// must not steal focus from the app the user is working in; the activation
/// that follows then focuses it.
#[test]
fn window_created_before_its_app_is_frontmost_is_focused_on_activation() {
    let activation = Event::ApplicationFrontSwitched {
        psn: ProcessSerialNumber {
            high: 0,
            low: TEST_PROCESS_ID.cast_unsigned(),
        },
    };
    let mut harness =
        TestHarness::new()
            .with_windows(1)
            .with_app(OTHER_PID, "other", "Other", |app| app.is_frontmost = true);
    let other = harness
        .mock_state
        .spawn_window(OTHER_PID, TEST_WORKSPACE_ID, 10, window_frame());
    harness.world().trigger(SpawnWindowTrigger(vec![other]));

    harness
        .on_iteration(0, |world, state| {
            assert_eq!(focused_id(world), Some(0));
            // The user is in the other app; the terminal creates a window in the background.
            state.update_app(TEST_PROCESS_ID, |app| app.is_frontmost = false);
            state.update_app(OTHER_PID, |app| app.is_frontmost = true);
            state.set_focused_window(10);
            let window = state.spawn_window(TEST_PROCESS_ID, TEST_WORKSPACE_ID, 2, window_frame());
            world.trigger(SpawnWindowTrigger(vec![window]));
        })
        .on_iteration(1, |world, state| {
            assert_ne!(
                focused_id(world),
                Some(2),
                "a background app's new window must not take focus"
            );
            // Now the terminal comes to the front with the new window key.
            state.update_app(TEST_PROCESS_ID, |app| app.is_frontmost = true);
            state.update_app(OTHER_PID, |app| app.is_frontmost = false);
            state.set_focused_window(2);
        })
        .on_iteration(2, |world, _state| {
            assert_eq!(focused_id(world), Some(2));
        })
        .run(vec![
            Event::MenuOpened { window_id: 0 },
            Event::Command {
                command: Command::PrintState,
            },
            activation,
        ]);
}
