//! Engine behavior around windows coming and going: close, minimize, hide.

use bevy::prelude::*;

use crate::commands::{Command, MoveFocus, Operation};
use crate::ecs::{FocusedMarker, Unmanaged};
use crate::events::Event;
use crate::manager::Window;

use super::*;

fn print_state() -> Event {
    Event::Command {
        command: Command::PrintState,
    }
}

fn focused_id(world: &mut World) -> Option<i32> {
    world
        .query_filtered::<&Window, With<FocusedMarker>>()
        .iter(world)
        .next()
        .map(|window| window.id())
}

/// Closing a window that does not hold focus must not move focus: macOS never
/// changes the key window when a background window goes away, and the engine's
/// neighbour search would otherwise raise whatever column is nearest the middle.
#[test]
fn closing_an_unfocused_window_keeps_focus() {
    TestHarness::new()
        .with_windows(3)
        .on_iteration(0, |world, state| {
            assert_eq!(focused_id(world), Some(0));
            state.os_close_window(2);
        })
        .on_iteration(3, |world, _state| {
            assert_eq!(
                focused_id(world),
                Some(0),
                "closing background window 2 must leave focus on window 0"
            );
        })
        .run(vec![
            print_state(),
            print_state(),
            print_state(),
            print_state(),
        ]);
}

/// The focused window going away still hands focus to a neighbour.
#[test]
fn closing_the_focused_window_focuses_a_neighbour() {
    TestHarness::new()
        .with_windows(3)
        .on_iteration(0, |world, state| {
            assert_eq!(focused_id(world), Some(0));
            state.os_close_window(0);
        })
        .on_iteration(3, |world, _state| {
            assert!(
                focused_id(world).is_some_and(|id| id != 0),
                "a surviving window must take focus"
            );
        })
        .run(vec![
            print_state(),
            print_state(),
            print_state(),
            print_state(),
        ]);
}

/// A window on a hidden row is parked off screen; minimizing it (or closing it)
/// has nothing to do with the row the user is typing in.
#[test]
fn minimizing_a_hidden_row_window_keeps_focus() {
    let mut h = TestHarness::new().with_windows(3);
    h.run(vec![print_state()]);
    h.run(vec![Event::Command {
        command: Command::Window(Operation::VirtualMoveNumber(1, MoveFocus::Stay)),
    }]);
    assert_eq!(focused_id(h.world()), Some(1), "window 1 holds focus");
    h.mock_state.os_minimize_window(0, true);
    h.run(vec![print_state(), print_state()]);
    assert_eq!(
        focused_id(h.world()),
        Some(1),
        "minimizing parked window 0 must not move focus off window 1"
    );
}

#[test]
fn closing_a_hidden_row_window_keeps_focus() {
    let mut h = TestHarness::new().with_windows(3);
    h.run(vec![print_state()]);
    h.run(vec![Event::Command {
        command: Command::Window(Operation::VirtualMoveNumber(1, MoveFocus::Stay)),
    }]);
    assert_eq!(focused_id(h.world()), Some(1), "window 1 holds focus");
    h.mock_state.os_close_window(0);
    h.run(vec![print_state(), print_state(), print_state()]);
    assert_eq!(
        focused_id(h.world()),
        Some(1),
        "closing parked window 0 must not move focus off window 1"
    );
}

/// "Hide Others" (Cmd+Option+H) and Cmd+H on a background app hide windows that
/// are not the one in use. The window being typed in keeps focus.
#[test]
fn hiding_a_background_app_keeps_focus() {
    let mut h = TestHarness::new()
        .with_app(2, "other", "Other", |_| {})
        .with_windows(2);
    let other = h.mock_state.spawn_window(
        2,
        TEST_WORKSPACE_ID,
        10,
        bevy::math::IRect::new(0, 0, TEST_WINDOW_WIDTH, TEST_WINDOW_HEIGHT),
    );
    h.world()
        .trigger(crate::ecs::SpawnWindowTrigger(vec![other]));
    h.run(vec![print_state(), print_state()]);
    assert_eq!(focused_id(h.world()), Some(0));
    h.run(vec![
        Event::ApplicationHidden { pid: 2 },
        print_state(),
        print_state(),
    ]);
    assert_eq!(unmanaged_state(h.world(), 10), "Some(Hidden)");
    assert_eq!(
        focused_id(h.world()),
        Some(0),
        "hiding another app must not move focus off window 0"
    );
}

fn unmanaged_state(world: &mut World, id: i32) -> String {
    let mut query = world.query::<(&Window, Option<&Unmanaged>)>();
    let (_, unmanaged) = query
        .iter(world)
        .find(|(window, _)| window.id() == id)
        .expect("window");
    format!("{unmanaged:?}")
}

fn in_a_strip(world: &mut World, id: i32) -> bool {
    let entity = find_window_entity(id, world);
    let mut query = world.query::<&crate::ecs::layout::LayoutStrip>();
    query.iter(world).any(|strip| strip.contains(entity))
}

/// A floated window that is minimized and brought back from the Dock is still a
/// floating window: it must not be pulled into the tiling strip.
#[test]
fn a_floating_window_stays_floating_across_minimize() {
    let mut h = TestHarness::new().with_windows(3);
    h.run(vec![print_state()]);
    assert_eq!(focused_id(h.world()), Some(0));
    h.run(vec![Event::Command {
        command: Command::Window(Operation::Manage),
    }]);
    assert_eq!(unmanaged_state(h.world(), 0), "Some(Floating)");
    assert!(!in_a_strip(h.world(), 0));

    h.mock_state.os_minimize_window(0, true);
    h.run(vec![print_state(), print_state()]);
    h.mock_state.os_minimize_window(0, false);
    h.run(vec![print_state(), print_state()]);

    assert_eq!(
        unmanaged_state(h.world(), 0),
        "Some(Floating)",
        "restoring a minimized floating window must leave it floating"
    );
    assert!(
        !in_a_strip(h.world(), 0),
        "a floating window must not be tiled back into a strip"
    );
}
