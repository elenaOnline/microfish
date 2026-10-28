//! Row (virtual workspace) switching: which window gets focus, where the
//! strips end up, and what the engine asks the OS to focus. Driven through
//! `Operation::Row`, the command `config/init.lua` sends for Hyper+Up/Down/K/J.

use std::time::Duration;

use bevy::prelude::*;

use crate::commands::{Command, Direction, MoveFocus, Operation};
use crate::ecs::layout::LayoutStrip;
use crate::ecs::{ActiveWorkspaceMarker, FocusedMarker, Position};
use crate::events::Event;
use crate::manager::Window;
use crate::platform::WinID;

use super::*;

fn cmd(op: Operation) -> Event {
    Event::Command {
        command: Command::Window(op),
    }
}

/// Delivers `events` in ONE frame, then lets the engine settle.
fn send(h: &mut TestHarness, events: Vec<Event>) {
    for event in events {
        h.app.world_mut().write_message::<Event>(event);
    }
    h.advance(Duration::from_millis(600));
}

#[derive(Debug)]
struct Row {
    index: u32,
    active: bool,
    origin_x: i32,
    windows: Vec<WinID>,
}

fn rows(h: &mut TestHarness) -> Vec<Row> {
    let world = h.world();
    let ids: Vec<(Entity, WinID)> = world
        .query::<(Entity, &Window)>()
        .iter(world)
        .map(|(entity, window)| (entity, window.id()))
        .collect();
    let id_of = |entity: Entity| ids.iter().find(|(e, _)| *e == entity).unwrap().1;
    let mut out = world
        .query::<(&LayoutStrip, &Position, Has<ActiveWorkspaceMarker>)>()
        .iter(world)
        .map(|(strip, position, active)| Row {
            index: strip.virtual_index,
            active,
            origin_x: position.0.x,
            windows: strip.all_windows().into_iter().map(id_of).collect(),
        })
        .collect::<Vec<_>>();
    out.sort_by_key(|row| row.index);
    out
}

fn active_row(h: &mut TestHarness) -> u32 {
    let active = rows(h)
        .into_iter()
        .filter(|row| row.active)
        .map(|row| row.index)
        .collect::<Vec<_>>();
    assert_eq!(active.len(), 1, "exactly one active row, got {active:?}");
    active[0]
}

/// Window ids carrying the ECS focus marker.
fn ecs_focus(h: &mut TestHarness) -> Vec<WinID> {
    let world = h.world();
    world
        .query_filtered::<&Window, With<FocusedMarker>>()
        .iter(world)
        .map(|window| window.id())
        .collect()
}

/// Focuses `id` the way the OS does: the app reports it and the notifications
/// follow.
fn focus(h: &mut TestHarness, id: WinID) {
    h.mock_state.focus_window(id);
    h.advance(Duration::from_millis(600));
}

/// `count` windows; the last `lower` of them sit on row 1, the rest on row 0.
/// Row 0 is active and `focus_id` has focus when this returns.
fn two_rows(count: i32, lower: &[WinID], focus_id: WinID) -> TestHarness {
    let mut h = TestHarness::new().with_windows(count);
    send(&mut h, vec![Event::MenuOpened { window_id: 0 }]);
    for id in lower {
        focus(&mut h, *id);
        send(
            &mut h,
            vec![cmd(Operation::VirtualMoveNumber(1, MoveFocus::Stay))],
        );
    }
    focus(&mut h, focus_id);
    h
}

fn production_config() -> crate::config::Config {
    crate::config::Config::try_from("[options]\nreap_empty_workspaces=true\n[bindings]\n").unwrap()
}

/// Row 0 holds windows 0, 1 and 2 (the strip is wider than the display, so
/// it can be scrolled); row 1 holds 3 and 4. Row 0 is active, focused on 1.
fn rig() -> TestHarness {
    two_rows(5, &[3, 4], 1)
}

/// Leaves row 1 remembering window 4, then returns to row 0.
fn leave_row_one_remembering_four(h: &mut TestHarness) {
    send(h, vec![cmd(Operation::Row(Direction::South))]);
    focus(h, 4);
    send(h, vec![cmd(Operation::Row(Direction::North))]);
    assert_eq!(active_row(h), 0);
    assert_eq!(ecs_focus(h), vec![1]);
}

/// The focus markers and the OS must agree on a window of the active row.
fn assert_focus_is_on_active_row(h: &mut TestHarness, expected: &[WinID]) {
    let active = active_row(h);
    let row = rows(h).into_iter().find(|row| row.index == active).unwrap();
    let focus = ecs_focus(h);
    assert_eq!(focus.len(), 1, "one focused window, got {focus:?}");
    assert!(
        row.windows.contains(&focus[0]),
        "focus {focus:?} is not on the active row {row:?}: keystrokes would go to a parked window"
    );
    assert!(
        expected.contains(&focus[0]),
        "focus {focus:?} should be one of {expected:?}"
    );
    assert_eq!(
        h.mock_state.app_focused_window(TEST_PROCESS_ID),
        Some(focus[0]),
        "the OS must hold the same window the layout does"
    );
}

#[test]
fn row_switch_restores_remembered_window_and_viewport() {
    let mut h = rig();
    let before = rows(&mut h);
    assert_eq!(before[0].origin_x, -400, "row 0 starts scrolled");
    leave_row_one_remembering_four(&mut h);
    assert_eq!(
        rows(&mut h)[0].origin_x,
        -400,
        "viewport restored on return"
    );
    send(&mut h, vec![cmd(Operation::Row(Direction::South))]);
    assert_eq!(active_row(&mut h), 1);
    assert_focus_is_on_active_row(&mut h, &[4]);
    assert_eq!(rows(&mut h)[1].origin_x, 0);
    send(&mut h, vec![cmd(Operation::Row(Direction::North))]);
    assert_focus_is_on_active_row(&mut h, &[1]);
    assert_eq!(rows(&mut h)[0].origin_x, -400);
}

#[test]
fn row_switch_focuses_the_row_when_the_remembered_window_closed_while_hidden() {
    let mut h = rig();
    leave_row_one_remembering_four(&mut h);
    h.mock_state.os_close_window(4);
    h.advance(Duration::from_millis(600));
    send(&mut h, vec![cmd(Operation::Row(Direction::South))]);
    assert_eq!(active_row(&mut h), 1);
    assert_focus_is_on_active_row(&mut h, &[3]);
}

#[test]
fn row_switch_focuses_the_row_when_the_remembered_window_was_minimized_while_hidden() {
    let mut h = rig();
    leave_row_one_remembering_four(&mut h);
    h.mock_state.os_minimize_window(4, true);
    h.advance(Duration::from_millis(600));
    send(&mut h, vec![cmd(Operation::Row(Direction::South))]);
    assert_eq!(active_row(&mut h), 1);
    assert_focus_is_on_active_row(&mut h, &[3]);
}

#[test]
fn row_switch_focuses_the_row_when_the_remembered_window_moved_to_another_row() {
    let mut h = rig();
    leave_row_one_remembering_four(&mut h);
    // The map drops window 4 onto row 0 while row 1 is hidden.
    send(
        &mut h,
        vec![Event::Command {
            command: Command::Layout(vec![crate::types::windowset::LayoutOp::MoveToWorkspace {
                window: 4,
                workspace: 1,
                follow: false,
            }]),
        }],
    );
    assert!(rows(&mut h)[0].windows.contains(&4), "moved onto row 0");
    send(&mut h, vec![cmd(Operation::Row(Direction::South))]);
    assert_eq!(active_row(&mut h), 1);
    assert_focus_is_on_active_row(&mut h, &[3]);
}

#[test]
fn row_presses_arriving_in_one_frame_are_all_applied() {
    let mut h = TestHarness::new()
        .with_config(production_config())
        .with_windows(6);
    send(&mut h, vec![Event::MenuOpened { window_id: 0 }]);
    for (id, row) in [(2, 1), (3, 1), (4, 2), (5, 2)] {
        focus(&mut h, id);
        send(
            &mut h,
            vec![cmd(Operation::VirtualMoveNumber(row, MoveFocus::Stay))],
        );
    }
    focus(&mut h, 0);
    send(
        &mut h,
        vec![
            cmd(Operation::Row(Direction::South)),
            cmd(Operation::Row(Direction::South)),
        ],
    );
    assert_eq!(active_row(&mut h), 2, "two presses, two rows");
    assert_focus_is_on_active_row(&mut h, &[4, 5]);
    send(
        &mut h,
        vec![
            cmd(Operation::Row(Direction::North)),
            cmd(Operation::Row(Direction::North)),
        ],
    );
    assert_eq!(active_row(&mut h), 0);
    assert_focus_is_on_active_row(&mut h, &[0, 1]);
}

#[test]
fn row_presses_in_one_frame_grow_one_row_and_stop_at_the_empty_boundary() {
    let mut h = TestHarness::new()
        .with_config(production_config())
        .with_windows(4);
    send(&mut h, vec![Event::MenuOpened { window_id: 0 }]);
    for id in [2, 3] {
        focus(&mut h, id);
        send(
            &mut h,
            vec![cmd(Operation::VirtualMoveNumber(1, MoveFocus::Stay))],
        );
    }
    focus(&mut h, 0);
    send(&mut h, vec![cmd(Operation::Row(Direction::South))]);
    assert_eq!(active_row(&mut h), 1);
    send(
        &mut h,
        vec![
            cmd(Operation::Row(Direction::South)),
            cmd(Operation::Row(Direction::South)),
            cmd(Operation::Row(Direction::South)),
        ],
    );
    let all = rows(&mut h);
    assert_eq!(all.len(), 3, "one new row, not three: {all:?}");
    assert_eq!(active_row(&mut h), 2);
    assert!(all[2].windows.is_empty());
}

#[test]
fn opposite_row_presses_in_one_frame_cancel_without_leaving_a_row_behind() {
    let mut h = TestHarness::new()
        .with_config(production_config())
        .with_windows(2);
    send(&mut h, vec![Event::MenuOpened { window_id: 0 }]);
    send(
        &mut h,
        vec![
            cmd(Operation::Row(Direction::South)),
            cmd(Operation::Row(Direction::North)),
        ],
    );
    let all = rows(&mut h);
    assert_eq!(active_row(&mut h), 0, "back where it started: {all:?}");
    assert_eq!(all.len(), 1, "the row made on the way is not kept: {all:?}");
    assert_focus_is_on_active_row(&mut h, &[0, 1]);
}

#[test]
fn row_switch_asks_the_os_for_focus_after_the_row_is_on_screen() {
    let mut h = rig();
    let before = h.mock_state.focus_calls().len();
    send(&mut h, vec![cmd(Operation::Row(Direction::South))]);
    let calls = h.mock_state.focus_calls();
    let call = calls[before..]
        .iter()
        .find(|call| call.target == 3)
        .expect("the OS is asked to focus window 3");
    assert!(
        call.target_origin.x < TEST_DISPLAY_WIDTH - 100,
        "asked while window 3 was still parked at {:?}",
        call.target_origin
    );
    assert_eq!(
        call.losing,
        Some(1),
        "the window losing focus is the one left on the previous row"
    );
}

#[test]
fn row_switch_retries_a_native_focus_the_app_refused() {
    let mut h = rig();
    h.mock_state.refuse_focus(3, 1);
    send(&mut h, vec![cmd(Operation::Row(Direction::South))]);
    assert_eq!(active_row(&mut h), 1);
    assert_focus_is_on_active_row(&mut h, &[3]);
}

#[test]
fn view_back_returns_to_the_row_and_window_before_a_row_sequence() {
    let mut h = rig();
    send(&mut h, vec![cmd(Operation::Row(Direction::South))]);
    assert_eq!(active_row(&mut h), 1);
    send(&mut h, vec![cmd(Operation::ViewBack)]);
    assert_eq!(active_row(&mut h), 0);
    assert_focus_is_on_active_row(&mut h, &[1]);
    assert_eq!(rows(&mut h)[0].origin_x, -400);
}

fn frames(h: &mut TestHarness, n: usize) {
    for _ in 0..n {
        h.advance(Duration::from_millis(20));
    }
}

#[test]
fn held_row_key_asks_the_os_to_focus_only_the_row_it_lands_on() {
    let mut h = TestHarness::new()
        .with_config(production_config())
        .with_windows(8);
    send(&mut h, vec![Event::MenuOpened { window_id: 0 }]);
    for (id, row) in [(2, 1), (3, 1), (4, 2), (5, 2), (6, 3), (7, 3)] {
        focus(&mut h, id);
        send(
            &mut h,
            vec![cmd(Operation::VirtualMoveNumber(row, MoveFocus::Stay))],
        );
    }
    focus(&mut h, 0);
    let before = h.mock_state.focus_calls().len();
    // Key repeat: a press every frame, three rows down.
    for _ in 0..3 {
        h.app
            .world_mut()
            .write_message::<Event>(cmd(Operation::Row(Direction::South)));
        frames(&mut h, 1);
    }
    frames(&mut h, 50);
    assert_eq!(active_row(&mut h), 3);
    let asked = h.mock_state.focus_calls()[before..]
        .iter()
        .map(|call| call.target)
        .collect::<Vec<_>>();
    assert!(
        asked.iter().all(|id| [6, 7].contains(id)),
        "the OS was also asked to focus windows of the rows passed through: {asked:?}"
    );
    assert_focus_is_on_active_row(&mut h, &[6, 7]);
}

/// When the focus marker is lost, the active row takes focus back on the
/// column the user is looking at, as a row switch does, not on the strip's
/// leftmost column (which may be scrolled off screen).
#[test]
fn lost_focus_recovers_to_the_column_nearest_the_viewport_center() {
    let mut h = TestHarness::new().with_windows(8);
    h.run(vec![
        Event::MenuOpened { window_id: 0 },
        cmd(Operation::Focus(Direction::East)),
        cmd(Operation::Focus(Direction::East)),
        cmd(Operation::Focus(Direction::East)),
        cmd(Operation::Focus(Direction::East)),
        cmd(Operation::Focus(Direction::East)),
    ]);
    h.advance(Duration::from_secs(1));

    // The column whose window sits nearest the display's center.
    let center = TEST_DISPLAY_WIDTH / 2;
    let nearest = (0..8)
        .min_by_key(|id| {
            let frame = h.mock_state.window_frame(*id);
            (i32::midpoint(frame.min.x, frame.max.x) - center).abs()
        })
        .unwrap();
    assert!(
        nearest >= 2,
        "setup: the strip should be scrolled, got {nearest}"
    );

    let world = h.world();
    let focused = world
        .query_filtered::<Entity, With<FocusedMarker>>()
        .iter(world)
        .collect::<Vec<_>>();
    for entity in focused {
        world.entity_mut(entity).remove::<FocusedMarker>();
    }
    h.advance(Duration::from_secs(2));

    let world = h.world();
    let recovered = world
        .query_filtered::<&Window, With<FocusedMarker>>()
        .iter(world)
        .map(|window| window.id())
        .collect::<Vec<_>>();
    assert_eq!(
        recovered,
        vec![nearest],
        "recovery should land on the column at the center, not the first one"
    );
}
