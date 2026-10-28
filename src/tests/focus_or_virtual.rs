//! Tests for `Operation::FocusOrVirtual` (bound as e.g.
//! `window_virtualfocus_north`/`_south`): focuses a stack neighbor
//! above/below if one exists, otherwise switches the virtual workspace like
//! `Operation::Virtual` would — see `switch_virtual_workspace_bind` in
//! `src/ecs/workspace.rs`. Deliberately a separate command from
//! `Operation::Virtual` (`window_virtual_north`/`_south`), which must keep
//! meaning exactly "switch workspace", unconditionally.

use bevy::prelude::*;

use crate::assert_focused;
use crate::commands::{Command, Direction, Operation};
use crate::ecs::ActiveWorkspaceMarker;
use crate::ecs::layout::LayoutStrip;
use crate::events::Event;

use super::*;

fn active_virtual_index(world: &mut World) -> u32 {
    let mut query = world.query_filtered::<&LayoutStrip, With<ActiveWorkspaceMarker>>();
    query
        .single(world)
        .expect("exactly one active strip")
        .virtual_index
}

#[test]
fn test_focus_or_virtual_south_focuses_stack_sibling_before_switching_workspace() {
    let commands = vec![
        Event::MenuOpened { window_id: 0 },
        Event::Command {
            command: Command::Window(Operation::Focus(Direction::East)),
        },
        Event::Command {
            command: Command::Window(Operation::Stack(true)),
        },
        // Jump to VW1 and straight back so it exists for the eventual
        // fallback switch, without relying on auto-create being enabled.
        Event::Command {
            command: Command::Window(Operation::VirtualNumber(1)),
        },
        Event::Command {
            command: Command::Window(Operation::VirtualNumber(0)),
        },
        // Focus window 0 (top of the 2-item stack), then press South twice.
        Event::Command {
            command: Command::Window(Operation::Focus(Direction::First)),
        },
        Event::Command {
            command: Command::Window(Operation::FocusOrVirtual(Direction::South)),
        },
        Event::Command {
            command: Command::Window(Operation::FocusOrVirtual(Direction::South)),
        },
    ];

    TestHarness::new()
        .with_windows(2)
        .on_iteration(6, |world, _state| {
            // First South: a sibling exists below window 0 in the stack, so
            // focus must move to it instead of switching virtual workspace.
            assert_focused!(world, 1);
            assert_eq!(
                active_virtual_index(world),
                0,
                "focusing a stack sibling must not switch virtual workspace"
            );
        })
        .on_iteration(7, |world, _state| {
            // Second South: window 1 is the last stack item, nothing left to
            // focus, so this must fall through to switching workspaces.
            assert_eq!(
                active_virtual_index(world),
                1,
                "with nothing left to focus, South must fall through to switching workspace"
            );
        })
        .run(commands);
}

#[test]
fn test_focus_or_virtual_north_switches_workspace_immediately_without_a_stack() {
    let commands = vec![
        Event::MenuOpened { window_id: 0 },
        Event::Command {
            command: Command::Window(Operation::VirtualNumber(1)),
        },
        Event::Command {
            command: Command::Window(Operation::FocusOrVirtual(Direction::North)),
        },
    ];

    TestHarness::new()
        .with_windows(1)
        .on_iteration(2, |world, _state| {
            assert_eq!(
                active_virtual_index(world),
                0,
                "with no stack sibling to focus, North must switch virtual workspace"
            );
        })
        .run(commands);
}

/// Regression: `Operation::Virtual` (`window_virtual_north`/`_south`) must
/// keep switching the virtual workspace unconditionally, even when the
/// focused window is in a stack with a focusable neighbor — that
/// focus-or-switch behavior belongs only to the separate
/// `Operation::FocusOrVirtual` command.
#[test]
fn test_plain_virtual_south_switches_workspace_even_with_a_stack_sibling() {
    let commands = vec![
        Event::MenuOpened { window_id: 0 },
        Event::Command {
            command: Command::Window(Operation::Focus(Direction::East)),
        },
        Event::Command {
            command: Command::Window(Operation::Stack(true)),
        },
        Event::Command {
            command: Command::Window(Operation::VirtualNumber(1)),
        },
        Event::Command {
            command: Command::Window(Operation::VirtualNumber(0)),
        },
        Event::Command {
            command: Command::Window(Operation::Focus(Direction::First)),
        },
        Event::Command {
            command: Command::Window(Operation::Virtual(Direction::South)),
        },
    ];

    TestHarness::new()
        .with_windows(2)
        .on_iteration(6, |world, _state| {
            // Row 1 is empty, so the engine holds the keyboard: window 0 is
            // parked and no longer carries the focus marker.
            let mut focused = world.query_filtered::<(), With<crate::ecs::FocusedMarker>>();
            assert_eq!(focused.iter(world).count(), 0);
            assert_eq!(
                active_virtual_index(world),
                1,
                "plain Virtual(South) must switch workspace unconditionally, \
                 not focus the stack sibling"
            );
        })
        .run(commands);
}

#[test]
fn rowmove_detaches_only_selected_display_tab_and_stops_at_last_row() {
    let command = |operation| Event::Command {
        command: Command::Window(operation),
    };
    TestHarness::new()
        .with_windows(3)
        .on_iteration(0, |world, _| {
            world.insert_resource(
                crate::config::Config::try_from("default_workspaces=2\n[options]\n[bindings]\n")
                    .unwrap(),
            );
        })
        .on_iteration(6, |world, _| {
            let selected = find_window_entity(1, world);
            let sibling = find_window_entity(0, world);
            let mut strips = world.query::<&LayoutStrip>();
            let source = strips.iter(world).find(|s| s.virtual_index == 0).unwrap();
            assert!(source.contains(sibling));
            assert!(!source.contains(selected));
            let destination = strips.iter(world).find(|s| s.virtual_index == 1).unwrap();
            assert!(destination.contains(selected));
            assert!(!destination.contains(sibling));
            assert_focused!(world, 1);
        })
        .on_iteration(7, |world, _| {
            assert_eq!(active_virtual_index(world), 1);
            let mut strips = world.query::<&LayoutStrip>();
            assert_eq!(strips.iter(world).count(), 2);
        })
        .run(vec![
            Event::MenuOpened { window_id: 0 },
            command(Operation::Focus(Direction::East)),
            command(Operation::Stack(true)),
            command(Operation::ToggleTabbedDisplay),
            command(Operation::VirtualNumber(1)),
            command(Operation::VirtualNumber(0)),
            command(Operation::RowMove(Direction::South)),
            command(Operation::RowMove(Direction::South)),
        ]);
}

#[test]
fn rowcolumnmove_preserves_display_tab_column() {
    let command = |operation| Event::Command {
        command: Command::Window(operation),
    };
    TestHarness::new()
        .with_windows(3)
        .on_iteration(0, |world, _| {
            world.insert_resource(
                crate::config::Config::try_from("default_workspaces=2\n[options]\n[bindings]\n")
                    .unwrap(),
            );
        })
        .on_iteration(6, |world, _| {
            let selected = find_window_entity(1, world);
            let sibling = find_window_entity(0, world);
            let mut strips = world.query::<&LayoutStrip>();
            let destination = strips.iter(world).find(|s| s.virtual_index == 1).unwrap();
            assert!(destination.contains(selected));
            assert!(destination.contains(sibling));
            assert!(destination.is_tabbed_display(selected));
            assert!(destination.is_tabbed_display(sibling));
            assert_eq!(destination.len(), 1);
            assert_focused!(world, 1);
        })
        .run(vec![
            Event::MenuOpened { window_id: 0 },
            command(Operation::Focus(Direction::East)),
            command(Operation::Stack(true)),
            command(Operation::ToggleTabbedDisplay),
            command(Operation::VirtualNumber(1)),
            command(Operation::VirtualNumber(0)),
            command(Operation::RowColumnMove(Direction::South)),
        ]);
}

#[test]
fn row_count_reload_seeds_missing_rows_without_duplicates_or_deleting_occupied_rows() {
    use crate::config::Config;
    TestHarness::new()
        .with_windows(1)
        .on_iteration(0, |world, _| {
            world.insert_resource(
                Config::try_from("default_workspaces=3\n[options]\n[bindings]\n").unwrap(),
            );
        })
        .on_iteration(1, |world, _| {
            let mut strips = world.query::<&LayoutStrip>();
            let indexes: std::collections::HashSet<_> =
                strips.iter(world).map(|s| s.virtual_index).collect();
            assert_eq!(indexes, [0, 1, 2].into_iter().collect());
            assert_eq!(strips.iter(world).count(), 3);
            world.insert_resource(
                Config::try_from("default_workspaces=3\n[options]\n[bindings]\n").unwrap(),
            );
        })
        .on_iteration(2, |world, _| {
            let mut strips = world.query::<&LayoutStrip>();
            assert_eq!(strips.iter(world).count(), 3);
            world.insert_resource(
                Config::try_from("default_workspaces=1\n[options]\n[bindings]\n").unwrap(),
            );
        })
        .on_iteration(3, |world, _| {
            let mut strips = world.query::<&LayoutStrip>();
            assert_eq!(strips.iter(world).count(), 3);
            assert_focused!(world, 0);
        })
        .run(vec![Event::MenuOpened { window_id: 0 }; 4]);
}

#[test]
fn preseeded_rows_do_not_duplicate_physical_windows_on_startup() {
    TestHarness::new()
        .with_windows(3)
        .with_config(
            crate::config::Config::try_from("default_workspaces=2\n[options]\n[bindings]\n")
                .unwrap(),
        )
        .on_iteration(0, |world, _| {
            let mut strips = world.query::<&LayoutStrip>();
            assert_eq!(
                strips
                    .iter(world)
                    .find(|s| s.virtual_index == 0)
                    .unwrap()
                    .all_windows()
                    .len(),
                3
            );
            assert!(
                strips
                    .iter(world)
                    .find(|s| s.virtual_index == 1)
                    .unwrap()
                    .all_windows()
                    .is_empty()
            );
        })
        .run(vec![Event::MenuOpened { window_id: 0 }]);
}

#[test]
fn row_north_prepends_once_preserving_existing_group_and_entity() {
    let command = |operation| Event::Command {
        command: Command::Window(operation),
    };
    TestHarness::new()
        .with_windows(3)
        .with_config(
            crate::config::Config::try_from("default_workspaces=2\n[options]\n[bindings]\n")
                .unwrap(),
        )
        .on_iteration(3, |world, _| {
            let first = find_window_entity(0, world);
            let mut strips = world.query::<(Entity, &mut LayoutStrip)>();
            let (entity, _) = strips
                .iter_mut(world)
                .find(|(_, s)| s.contains(first))
                .unwrap();
            let origin = world.get::<crate::ecs::Position>(entity).unwrap().0;
            world.insert_resource(OriginalRowEntity(entity, origin));
        })
        .on_iteration(4, |world, _| {
            let entity = world.resource::<OriginalRowEntity>().0;
            let source = world.get::<LayoutStrip>(entity).unwrap();
            assert_eq!(source.virtual_index, 1);
            let previous = world
                .get::<crate::ecs::workspace::PreviousStripPosition>(entity)
                .unwrap();
            assert_eq!(previous.origin, world.resource::<OriginalRowEntity>().1);
            let first = find_window_entity(0, world);
            let selected = find_window_entity(1, world);
            assert!(
                world
                    .get::<LayoutStrip>(entity)
                    .unwrap()
                    .is_tabbed_display(first)
            );
            assert!(
                world
                    .get::<LayoutStrip>(entity)
                    .unwrap()
                    .is_tabbed_display(selected)
            );
            assert_eq!(active_virtual_index(world), 0);
        })
        .on_iteration(6, |world, _| {
            let mut strips = world.query::<&LayoutStrip>();
            assert_eq!(
                strips.iter(world).count(),
                3,
                "repeated north on empty top cannot grow"
            );
        })
        .on_iteration(7, |world, _| {
            assert_eq!(active_virtual_index(world), 1);
            assert_focused!(world, 1);
        })
        .run(vec![
            Event::MenuOpened { window_id: 0 },
            command(Operation::Focus(Direction::East)),
            command(Operation::Stack(true)),
            command(Operation::ToggleTabbedDisplay),
            command(Operation::Row(Direction::North)),
            command(Operation::Row(Direction::North)),
            command(Operation::Row(Direction::North)),
            command(Operation::Row(Direction::South)),
        ]);
}

#[derive(Resource)]
struct OriginalRowEntity(Entity, crate::manager::Origin);

#[test]
fn row_prepend_obeys_nine_row_cap() {
    TestHarness::new()
        .with_windows(1)
        .with_config(
            crate::config::Config::try_from("default_workspaces=9\n[options]\n[bindings]\n")
                .unwrap(),
        )
        .on_iteration(1, |world, _| {
            assert_eq!(active_virtual_index(world), 0);
            assert_eq!(world.query::<&LayoutStrip>().iter(world).count(), 9);
        })
        .run(vec![
            Event::MenuOpened { window_id: 0 },
            Event::Command {
                command: Command::Window(Operation::Row(Direction::North)),
            },
        ]);
}

#[test]
fn addressed_stack_replay_uses_right_destination() {
    TestHarness::new()
        .with_windows(3)
        .on_iteration(1, |world, _| {
            let left = find_window_entity(0, world);
            let middle = find_window_entity(1, world);
            let right = find_window_entity(2, world);
            let mut strips = world.query::<&LayoutStrip>();
            let strip = strips.single(world).unwrap();
            assert_eq!(
                strip.index_of(middle).unwrap(),
                strip.index_of(right).unwrap()
            );
            assert_ne!(
                strip.index_of(left).unwrap(),
                strip.index_of(middle).unwrap()
            );
        })
        .run(vec![
            Event::MenuOpened { window_id: 0 },
            Event::Command {
                command: Command::Layout(vec![crate::types::windowset::LayoutOp::Stack {
                    window: 1,
                    onto: 2,
                    tabs: false,
                }]),
            },
        ]);
}

#[test]
fn empty_top_row_is_reaped_after_leaving_and_indices_compact() {
    let command = |operation| Event::Command {
        command: Command::Window(operation),
    };
    TestHarness::new()
        .with_windows(2)
        .with_config(
            crate::config::Config::try_from("[options]\nreap_empty_workspaces=true\n[bindings]\n")
                .unwrap(),
        )
        .on_iteration(1, |world, _| {
            assert_eq!(active_virtual_index(world), 0);
            let mut strips = world.query::<&LayoutStrip>();
            assert_eq!(strips.iter(world).count(), 2);
        })
        .on_iteration(2, |world, _| {
            assert_eq!(active_virtual_index(world), 0);
            let mut strips = world.query::<&LayoutStrip>();
            assert_eq!(strips.iter(world).count(), 1);
            assert_eq!(strips.iter(world).next().unwrap().len(), 2);
        })
        .run(vec![
            Event::MenuOpened { window_id: 0 },
            command(Operation::Row(Direction::North)),
            command(Operation::Row(Direction::South)),
        ]);
}

#[test]
fn addressed_focus_reveals_inactive_row_before_focusing() {
    let command = |operation| Event::Command {
        command: Command::Window(operation),
    };
    TestHarness::new()
        .with_windows(2)
        .on_iteration(3, |world, _| {
            assert_eq!(active_virtual_index(world), 1);
            assert_focused!(world, 0);
        })
        .run(vec![
            Event::MenuOpened { window_id: 0 },
            command(Operation::VirtualMoveNumber(
                1,
                crate::commands::MoveFocus::Follow,
            )),
            command(Operation::VirtualNumber(0)),
            Event::Command {
                command: Command::Layout(vec![crate::types::windowset::LayoutOp::Focus(0)]),
            },
            Event::MenuOpened { window_id: 0 },
        ]);
}

#[test]
fn row_south_appends_once_and_returns_to_existing_windows() {
    let command = |op| Event::Command {
        command: Command::Window(op),
    };
    TestHarness::new()
        .with_windows(2)
        .with_config(
            crate::config::Config::try_from("default_workspaces=1\n[options]\n[bindings]\n")
                .unwrap(),
        )
        .on_iteration(1, |world, _| {
            assert_eq!(active_virtual_index(world), 1);
            assert_eq!(world.query::<&LayoutStrip>().iter(world).count(), 2);
        })
        .on_iteration(3, |world, _| {
            assert_eq!(active_virtual_index(world), 1);
            assert_eq!(
                world.query::<&LayoutStrip>().iter(world).count(),
                2,
                "empty bottom row must stop repeat growth"
            );
        })
        .on_iteration(4, |world, _| {
            assert_eq!(active_virtual_index(world), 0);
            assert_focused!(world, 0);
        })
        .run(vec![
            Event::MenuOpened { window_id: 0 },
            command(Operation::Row(Direction::South)),
            command(Operation::Row(Direction::South)),
            command(Operation::Row(Direction::South)),
            command(Operation::Row(Direction::North)),
        ]);
}

#[test]
fn row_south_obeys_nine_row_cap() {
    TestHarness::new()
        .with_windows(1)
        .with_config(
            crate::config::Config::try_from("default_workspaces=9\n[options]\n[bindings]\n")
                .unwrap(),
        )
        .on_iteration(2, |world, _| {
            assert_eq!(active_virtual_index(world), 8);
            assert_eq!(world.query::<&LayoutStrip>().iter(world).count(), 9);
        })
        .run(vec![
            Event::MenuOpened { window_id: 0 },
            Event::Command {
                command: Command::Window(Operation::VirtualMoveNumber(
                    8,
                    crate::commands::MoveFocus::Follow,
                )),
            },
            Event::Command {
                command: Command::Window(Operation::Row(Direction::South)),
            },
        ]);
}
