//! Mission Control exit must never move a window between rows or switch rows.

use std::time::Duration;

use bevy::prelude::*;

use crate::commands::{Command, MoveFocus, Operation};
use crate::ecs::layout::LayoutStrip;
use crate::ecs::{ActiveWorkspaceMarker, SelectedVirtualMarker};
use crate::events::Event;
use crate::manager::Window;
use crate::platform::{WinID, WorkspaceId};

use super::*;

fn send(h: &mut TestHarness, events: Vec<Event>) {
    for event in events {
        h.app.world_mut().write_message::<Event>(event);
    }
    h.advance(Duration::from_millis(600));
}

#[derive(Debug)]
struct Row {
    space: WorkspaceId,
    index: u32,
    active: bool,
    selected: bool,
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
        .query::<(
            &LayoutStrip,
            Has<ActiveWorkspaceMarker>,
            Has<SelectedVirtualMarker>,
        )>()
        .iter(world)
        .map(|(strip, active, selected)| Row {
            space: strip.id(),
            index: strip.virtual_index,
            active,
            selected,
            windows: strip.all_windows().into_iter().map(id_of).collect(),
        })
        .collect::<Vec<_>>();
    out.sort_by_key(|row| (row.space, row.index));
    out
}

fn space_rows(h: &mut TestHarness, space: WorkspaceId) -> Vec<Row> {
    rows(h)
        .into_iter()
        .filter(|row| row.space == space)
        .collect()
}

/// The row holding `id`, with its `active` flag.
fn row_of(h: &mut TestHarness, id: WinID) -> Option<Row> {
    rows(h).into_iter().find(|row| row.windows.contains(&id))
}

fn focus(h: &mut TestHarness, id: WinID) {
    h.mock_state.focus_window(id);
    h.advance(Duration::from_millis(600));
}

fn cmd(op: Operation) -> Event {
    Event::Command {
        command: Command::Window(op),
    }
}

/// A second native Space on the same display. `OTHER_SPACE` is where the real
/// Surfshark window lives as far as the engine's model goes: its popover is
/// ordered in and out all day, so it is not reliably tied to the Space it is
/// shown on.
const OTHER_SPACE: WorkspaceId = TEST_WORKSPACE_ID + 2;
const POPOVER: WinID = 9;

/// Three rows on the current Space: row 0 holds windows 0 and 1 and is on
/// screen, row 1 holds 2 and 3, row 2 holds 4 and 5. Row 1 was created last,
/// so that is the row a stale selection would pick. Window 9 belongs to the
/// other Space.
fn rig() -> TestHarness {
    let spaces: Vec<WorkspaceId> = vec![TEST_WORKSPACE_ID, OTHER_SPACE];
    let mut h = TestHarness::new()
        .with_display(
            TEST_DISPLAY_ID,
            IRect::new(0, 0, TEST_DISPLAY_WIDTH, TEST_DISPLAY_HEIGHT),
            spaces,
        )
        .with_windows(6)
        .with_workspace_window(POPOVER, OTHER_SPACE, |_| {});
    send(&mut h, vec![Event::MenuOpened { window_id: 0 }]);
    for (id, row) in [(4, 2), (5, 2), (2, 1), (3, 1)] {
        focus(&mut h, id);
        send(
            &mut h,
            vec![cmd(Operation::VirtualMoveNumber(row, MoveFocus::Stay))],
        );
    }
    focus(&mut h, 0);
    let current = space_rows(&mut h, TEST_WORKSPACE_ID);
    assert_eq!(current.len(), 3, "three rows: {current:?}");
    assert!(current[0].active, "row 0 is on screen: {current:?}");
    h
}

fn windows_of(h: &mut TestHarness, space: WorkspaceId, index: u32) -> Vec<WinID> {
    space_rows(h, space)
        .into_iter()
        .find(|row| row.index == index)
        .unwrap()
        .windows
}

/// Creating a hidden row from the one on screen must leave the selection where
/// the user is. The selection decides which row a Space change brings back.
#[test]
fn a_row_created_in_the_background_does_not_take_the_selection() {
    let mut h = rig();
    let current = space_rows(&mut h, TEST_WORKSPACE_ID);
    let selected = current
        .iter()
        .filter(|row| row.selected)
        .map(|row| row.index)
        .collect::<Vec<_>>();
    assert_eq!(selected, vec![0], "selection follows the row on screen");
}

/// Real macOS: she focuses the Surfshark popover (the engine reveals the
/// strip it sits in, which belongs to another Space), opens Mission Control,
/// and picks a window. Closing Mission Control must leave the row she was on
/// on screen and must not move the popover into some other row.
#[test]
fn mission_control_exit_never_switches_rows_or_moves_a_window_between_them() {
    let mut h = rig();
    focus(&mut h, POPOVER);
    assert_eq!(
        row_of(&mut h, POPOVER).map(|row| (row.space, row.active)),
        Some((OTHER_SPACE, true)),
        "focusing the popover reveals its strip"
    );
    send(&mut h, vec![Event::MissionControlShowAllWindows]);
    // The window server lists the popover on the Space that is really showing.
    h.mock_state
        .update_window(POPOVER, |window| window.workspace_id = TEST_WORKSPACE_ID);
    // Mission Control closing delivers the Space notification with it.
    send(&mut h, vec![Event::MissionControlExit, Event::SpaceChanged]);

    let current = space_rows(&mut h, TEST_WORKSPACE_ID);
    let active = current.iter().filter(|row| row.active).collect::<Vec<_>>();
    assert_eq!(active.len(), 1, "one row on screen: {current:?}");
    assert_eq!(active[0].index, 0, "the row she was on stays: {current:?}");
    assert_eq!(windows_of(&mut h, TEST_WORKSPACE_ID, 1), vec![2, 3]);
    assert_eq!(windows_of(&mut h, TEST_WORKSPACE_ID, 2), vec![4, 5]);
    assert_eq!(
        row_of(&mut h, POPOVER).map(|row| (row.space, row.index)),
        Some((TEST_WORKSPACE_ID, 0)),
        "the popover joins the row on screen, not a hidden one"
    );
}

/// A window dragged to another Space inside Mission Control leaves its row
/// whichever row that was. Only the row on screen was checked.
#[test]
fn mission_control_exit_drops_a_hidden_row_window_moved_to_another_space() {
    let mut h = rig();
    send(&mut h, vec![Event::MissionControlShowAllWindows]);
    h.mock_state
        .update_window(3, |window| window.workspace_id = OTHER_SPACE);
    send(&mut h, vec![Event::MissionControlExit]);

    assert_eq!(row_of(&mut h, 3).map(|row| row.space), None);
    assert_eq!(windows_of(&mut h, TEST_WORKSPACE_ID, 0), vec![0, 1]);
    assert_eq!(windows_of(&mut h, TEST_WORKSPACE_ID, 1), vec![2]);
    assert_eq!(windows_of(&mut h, TEST_WORKSPACE_ID, 2), vec![4, 5]);
}

/// The same check on the row on screen keeps working.
#[test]
fn mission_control_exit_drops_an_active_row_window_moved_to_another_space() {
    let mut h = rig();
    send(&mut h, vec![Event::MissionControlShowAllWindows]);
    h.mock_state
        .update_window(1, |window| window.workspace_id = OTHER_SPACE);
    send(&mut h, vec![Event::MissionControlExit]);

    assert_eq!(row_of(&mut h, 1).map(|row| row.space), None);
    assert_eq!(windows_of(&mut h, TEST_WORKSPACE_ID, 0), vec![0]);
}

/// Opening and closing Mission Control with nothing changed is a no-op, parked
/// windows included: they are still on the Space.
#[test]
fn mission_control_round_trip_changes_nothing() {
    let mut h = rig();
    let before = rows(&mut h)
        .into_iter()
        .map(|row| (row.space, row.index, row.active, row.windows))
        .collect::<Vec<_>>();
    send(&mut h, vec![Event::MissionControlShowAllWindows]);
    send(&mut h, vec![Event::MissionControlExit, Event::SpaceChanged]);
    let after = rows(&mut h)
        .into_iter()
        .map(|row| (row.space, row.index, row.active, row.windows))
        .collect::<Vec<_>>();
    assert_eq!(before, after);
}
