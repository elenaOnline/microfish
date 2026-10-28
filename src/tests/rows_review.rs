//! Row switching under adversarial timing: input arriving while a row switch
//! is still handing focus to the OS, many presses in one frame against the
//! same presses spread out, and a strip's offset across switches.

use std::time::Duration;

use bevy::prelude::*;

use crate::commands::{Command, Direction, MoveFocus, Operation};
use crate::config::{Config, MainOptions};
use crate::ecs::layout::LayoutStrip;
use crate::ecs::{ActiveWorkspaceMarker, FocusedMarker, Position};
use crate::events::Event;
use crate::manager::{Origin, Window};
use crate::platform::WinID;

use super::*;

fn cmd(op: Operation) -> Event {
    Event::Command {
        command: Command::Window(op),
    }
}

fn frames(h: &mut TestHarness, n: usize) {
    for _ in 0..n {
        h.advance(Duration::from_millis(20));
    }
}

fn window_x(h: &mut TestHarness, id: WinID) -> i32 {
    let world = h.world();
    let mut query = world.query::<&Window>();
    query
        .iter(world)
        .find(|window| window.id() == id)
        .expect("window not found")
        .frame()
        .min
        .x
}

/// A typical setup: no auto-centre, no continuous swipe, animations off.
fn production(animated: bool) -> Config {
    (
        MainOptions {
            animation_speed: Some(1_000_000.0),
            virtual_workspace_animations: Some(animated),
            auto_center: Some(false),
            continuous_swipe: Some(false),
            reap_empty_workspaces: Some(true),
            sliver_width: Some(4),
            ..Default::default()
        },
        vec![],
    )
        .into()
}

/// `(virtual index, active, x)` of every row, in row order.
fn strips(h: &mut TestHarness) -> Vec<(u32, bool, i32)> {
    let world = h.world();
    let mut query = world.query::<(&LayoutStrip, &Position, Has<ActiveWorkspaceMarker>)>();
    let mut rows = query
        .iter(world)
        .map(|(strip, position, active)| (strip.virtual_index, active, position.0.x))
        .collect::<Vec<_>>();
    rows.sort_unstable();
    rows
}

fn layout_focus(h: &mut TestHarness) -> Vec<WinID> {
    let world = h.world();
    world
        .query_filtered::<&Window, With<FocusedMarker>>()
        .iter(world)
        .map(|window| window.id())
        .collect()
}

/// Row count, windows per row in row order, and the active row's ordinal.
fn structure(h: &mut TestHarness) -> (usize, Vec<Vec<WinID>>, usize) {
    let world = h.world();
    let ids: Vec<(Entity, WinID)> = world
        .query::<(Entity, &Window)>()
        .iter(world)
        .map(|(entity, window)| (entity, window.id()))
        .collect();
    let id_of = |entity: Entity| ids.iter().find(|(e, _)| *e == entity).unwrap().1;
    let mut rows = world
        .query::<(&LayoutStrip, Has<ActiveWorkspaceMarker>)>()
        .iter(world)
        .map(|(strip, active)| {
            let mut windows = strip
                .all_windows()
                .into_iter()
                .map(id_of)
                .collect::<Vec<_>>();
            windows.sort_unstable();
            (strip.virtual_index, windows, active)
        })
        .collect::<Vec<_>>();
    rows.sort();
    let active = rows.iter().position(|row| row.2).unwrap();
    (
        rows.len(),
        rows.into_iter().map(|row| row.1).collect(),
        active,
    )
}

/// The OS and the layout must name the same window.
fn assert_native_focus_follows_layout(h: &mut TestHarness, what: &str) {
    let layout = layout_focus(h);
    let os = h.mock_state.app_focused_window(TEST_PROCESS_ID);
    assert_eq!(layout.len(), 1, "{what}: one layout focus, got {layout:?}");
    assert_eq!(
        os,
        Some(layout[0]),
        "{what}: the layout focuses window {} but the OS holds {os:?}, so keystrokes go elsewhere",
        layout[0]
    );
}

/// Row 0 holds windows 0, 1 and 2 (wider than the display, scrolled), row 1
/// holds 3 and 4. Row 0 is active, focused on 1.
fn rig(animated: bool) -> TestHarness {
    let mut h = TestHarness::new()
        .with_config(production(animated))
        .with_windows(5);
    h.world()
        .write_message::<Event>(Event::MenuOpened { window_id: 0 });
    frames(&mut h, 30);
    for id in [3, 4] {
        h.mock_state.focus_window(id);
        frames(&mut h, 30);
        h.world()
            .write_message::<Event>(cmd(Operation::VirtualMoveNumber(1, MoveFocus::Stay)));
        frames(&mut h, 30);
    }
    h.mock_state.focus_window(1);
    frames(&mut h, 30);
    h
}

/// `n` rows with window `i` alone on row `i`, starting on row `start`.
fn n_rows(n: usize, start: usize) -> TestHarness {
    let mut h = TestHarness::new()
        .with_config(production(false))
        .with_windows(i32::try_from(n).unwrap());
    h.world()
        .write_message::<Event>(Event::MenuOpened { window_id: 0 });
    frames(&mut h, 30);
    for i in 1..n {
        h.mock_state.focus_window(WinID::try_from(i).unwrap());
        frames(&mut h, 30);
        h.world()
            .write_message::<Event>(cmd(Operation::VirtualMoveNumber(
                u32::try_from(i).unwrap(),
                MoveFocus::Stay,
            )));
        frames(&mut h, 30);
    }
    h.world()
        .write_message::<Event>(cmd(Operation::VirtualNumber(u32::try_from(start).unwrap())));
    frames(&mut h, 30);
    h.mock_state.focus_window(WinID::try_from(start).unwrap());
    frames(&mut h, 30);
    h
}

/// A row switch asks the OS for focus only once the row is on screen. Input
/// of any other kind landing before that must not swallow the request: the
/// layout would show the new row while the keyboard stayed in the window
/// parked on the row just left.
#[test]
fn native_focus_reaches_the_new_row_when_a_window_command_follows_the_switch() {
    for gap in 0..=4 {
        for animated in [false, true] {
            let mut h = rig(animated);
            h.world()
                .write_message::<Event>(cmd(Operation::Row(Direction::South)));
            frames(&mut h, gap);
            h.world().write_message::<Event>(cmd(Operation::Center));
            frames(&mut h, 100);
            assert_native_focus_follows_layout(
                &mut h,
                &format!("row switch, Center {gap} frames later, animated={animated}"),
            );
        }
    }
}

#[test]
fn native_focus_reaches_the_new_row_when_a_swipe_follows_the_switch() {
    for gap in 0..=4 {
        let mut h = rig(false);
        h.world()
            .write_message::<Event>(cmd(Operation::Row(Direction::South)));
        frames(&mut h, gap);
        h.world().write_message::<Event>(Event::Swipe {
            delta: 0.0,
            fingers: 3,
        });
        frames(&mut h, 100);
        assert_native_focus_follows_layout(
            &mut h,
            &format!("row switch, swipe {gap} frames later"),
        );
    }
}

#[test]
fn native_focus_reaches_the_neighbour_when_a_window_command_follows_column_navigation() {
    for gap in 0..=4 {
        let mut h = rig(false);
        h.world()
            .write_message::<Event>(cmd(Operation::Focus(Direction::East)));
        frames(&mut h, gap);
        h.world().write_message::<Event>(cmd(Operation::Center));
        frames(&mut h, 100);
        assert_native_focus_follows_layout(&mut h, &format!("East, Center {gap} frames later"));
    }
}

/// A command that moves the focus itself owns it: the row switch it
/// interrupted must not ask the OS for its own, older target afterwards.
#[test]
fn an_interrupting_focus_command_is_not_overridden_by_the_interrupted_switch() {
    let mut h = rig(false);
    h.world()
        .write_message::<Event>(cmd(Operation::Row(Direction::South)));
    frames(&mut h, 1);
    h.world()
        .write_message::<Event>(cmd(Operation::Row(Direction::North)));
    frames(&mut h, 100);
    assert_eq!(strips(&mut h).iter().find(|row| row.1).unwrap().0, 0);
    assert_native_focus_follows_layout(&mut h, "down then straight back up");
    assert_eq!(layout_focus(&mut h), vec![1]);
}

/// Many presses in one frame land where the same presses spread out would.
#[test]
fn batch_of_row_presses_equals_the_same_presses_one_frame_apart() {
    let mut mismatches = vec![];
    for start in 0..3usize {
        for len in 1..=3u32 {
            for bits in 0..(1u32 << len) {
                let dirs = (0..len)
                    .map(|i| {
                        if bits >> i & 1 == 0 {
                            Direction::North
                        } else {
                            Direction::South
                        }
                    })
                    .collect::<Vec<_>>();
                let mut spread = n_rows(3, start);
                for direction in &dirs {
                    spread
                        .world()
                        .write_message::<Event>(cmd(Operation::Row(direction.clone())));
                    frames(&mut spread, 40);
                }
                let mut batch = n_rows(3, start);
                for direction in &dirs {
                    batch
                        .world()
                        .write_message::<Event>(cmd(Operation::Row(direction.clone())));
                }
                frames(&mut batch, 40 * dirs.len());
                let (spread, batch) = (structure(&mut spread), structure(&mut batch));
                if spread != batch {
                    mismatches.push(format!(
                        "start {start} {dirs:?}: spread {spread:?}, batch {batch:?}"
                    ));
                }
            }
        }
    }
    assert!(mismatches.is_empty(), "{}", mismatches.join("\n"));
}

#[test]
fn row_presses_respect_the_nine_row_cap_in_batches() {
    let press = |h: &mut TestHarness, direction: Direction| {
        for _ in 0..3 {
            h.world()
                .write_message::<Event>(cmd(Operation::Row(direction.clone())));
        }
        frames(h, 60);
        let (rows, _, active) = structure(h);
        (rows, active)
    };
    assert_eq!(
        press(&mut n_rows(9, 8), Direction::South),
        (9, 8),
        "south of the ninth row"
    );
    assert_eq!(
        press(&mut n_rows(9, 0), Direction::North),
        (9, 0),
        "north of the first of nine rows"
    );
    assert_eq!(
        press(&mut n_rows(8, 7), Direction::South),
        (9, 8),
        "one row grown below"
    );
    assert_eq!(
        press(&mut n_rows(8, 0), Direction::North),
        (9, 0),
        "one row grown above"
    );
}

/// The strip sliding after a switch is the row complaint that matters most:
/// whatever offset a row was left at - derived or placed by hand - is where it
/// comes back, and it stays there once the OS has confirmed focus.
#[test]
fn row_viewport_survives_round_trips_and_the_focus_echo() {
    for animated in [false, true] {
        let mut h = rig(animated);
        // Place row 0 by hand: window 1 centred.
        h.world().write_message::<Event>(cmd(Operation::Center));
        frames(&mut h, 40);
        let placed = strips(&mut h)[0].2;
        assert_ne!(placed, -176, "test setup: Center must move the strip");
        for round in 0..3 {
            h.world()
                .write_message::<Event>(cmd(Operation::Row(Direction::South)));
            frames(&mut h, 40);
            h.world()
                .write_message::<Event>(cmd(Operation::Row(Direction::North)));
            for frame in 0..60 {
                h.advance(Duration::from_millis(20));
                if frame >= 2 {
                    assert_eq!(
                        strips(&mut h)[0],
                        (0, true, placed),
                        "round {round}, frame {frame}, animated={animated}: row 0 slid away from where it was left"
                    );
                }
            }
            assert_native_focus_follows_layout(&mut h, "after the round trip");
        }
    }
}

/// Cmd-Tab into a window on a parked row, long after the restore guard of the
/// last visit has lapsed, must show the whole window and leave the strip there.
#[test]
fn cmd_tab_into_a_hidden_row_window_exposes_it_without_a_restore_guard() {
    let mut h = TestHarness::new()
        .with_config(production(false))
        .with_windows(6);
    h.world()
        .write_message::<Event>(Event::MenuOpened { window_id: 0 });
    frames(&mut h, 25);
    for id in [2, 3, 4, 5] {
        h.world()
            .write_message::<Event>(Event::CancelKeyboardFocusHandoff);
        h.mock_state.focus_window(id);
        frames(&mut h, 25);
        h.world()
            .write_message::<Event>(cmd(Operation::VirtualMoveNumber(1, MoveFocus::Stay)));
        frames(&mut h, 25);
    }
    h.world()
        .write_message::<Event>(cmd(Operation::VirtualNumber(1)));
    frames(&mut h, 25);
    let row = {
        let world = h.world();
        let mut query =
            world.query_filtered::<Entity, (With<LayoutStrip>, With<ActiveWorkspaceMarker>)>();
        query.single(world).unwrap()
    };
    // Dragged so a quarter of window 2 hangs off the left edge, then parked.
    h.world()
        .entity_mut(row)
        .insert(Position(Origin::new(-100, TEST_MENUBAR_HEIGHT)));
    frames(&mut h, 25);
    assert_eq!(window_x(&mut h, 2), -100, "test setup");
    h.world()
        .write_message::<Event>(cmd(Operation::VirtualNumber(0)));
    // Longer than the two-second restore guard.
    frames(&mut h, 150);
    h.world()
        .write_message::<Event>(Event::CancelKeyboardFocusHandoff);
    h.mock_state.focus_window(2);
    for frame in 0..40 {
        h.advance(Duration::from_millis(20));
        if frame >= 3 {
            assert_eq!(window_x(&mut h, 2), 0, "frame {frame}: window 2 moved");
        }
    }
}

/// An app slow to hand focus to the row just switched to must not make the
/// switch undo itself. The keyboard handoff for a column move treats a refusal
/// as a window that cannot take focus and floats it out of the strip; for a
/// row switch that tore a tiled window out of the layout, and giving up then
/// reconciled to the window parked on the row just left, bouncing back to it.
#[test]
fn a_slow_app_does_not_float_its_window_or_bounce_the_row_switch() {
    use crate::ecs::Unmanaged;
    let mut h = rig(false);
    let before = structure(&mut h);
    for id in [3, 4] {
        h.mock_state.refuse_focus(id, 10);
    }
    h.world()
        .write_message::<Event>(cmd(Operation::Row(Direction::South)));
    frames(&mut h, 60);
    let after = structure(&mut h);
    assert_eq!(after.2, 1, "the row switched to must stay shown: {after:?}");
    assert_eq!(
        after.1, before.1,
        "no window may leave its row because its app was slow to focus"
    );
    let world = h.world();
    let floating = world
        .query::<(&Window, &Unmanaged)>()
        .iter(world)
        .filter(|(_, unmanaged)| matches!(unmanaged, Unmanaged::Floating))
        .map(|(window, _)| window.id())
        .collect::<Vec<_>>();
    assert!(floating.is_empty(), "floated {floating:?}");
}
