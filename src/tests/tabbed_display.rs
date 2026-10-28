//! Tests for the paneru-driven "tabbed display" toggle on `Column::Stack`
//! (one window visible at a time, sharing the full column rect, cycled with
//! the existing `Focus` North/South directions). Deliberately kept separate
//! from `src/tests/tabs.rs`, which covers the unrelated macOS-native
//! "Merge All Windows" tab detection.

use bevy::prelude::*;

use crate::assert_focused;
use crate::assert_window_size;
use crate::commands::{Command, Direction, Operation};
use crate::ecs::layout::LayoutStrip;
use crate::events::Event;

use super::*;

fn is_tabbed_display(world: &mut World, window_id: i32) -> bool {
    let entity = find_window_entity(window_id, world);
    let mut query = world.query::<&LayoutStrip>();
    query
        .single(world)
        .expect("a single active strip")
        .is_tabbed_display(entity)
}

/// Builds a 3-window `Column::Stack` (windows 0, 1, 2) followed by a fourth,
/// separate single-window column (window 3), via the same `Operation::Stack`
/// path a real keybinding would use.
fn stack_first_three(commands: &mut Vec<Event>) {
    commands.extend([
        Event::Command {
            command: Command::Window(Operation::Focus(Direction::East)),
        },
        Event::Command {
            command: Command::Window(Operation::Stack(true)),
        },
        Event::Command {
            command: Command::Window(Operation::Focus(Direction::East)),
        },
        Event::Command {
            command: Command::Window(Operation::Stack(true)),
        },
    ]);
}

#[test]
fn test_toggle_tabbed_display_gives_every_member_the_full_column_size() {
    let mut commands = vec![Event::MenuOpened { window_id: 0 }];
    stack_first_three(&mut commands);
    commands.push(Event::Command {
        command: Command::Window(Operation::ToggleTabbedDisplay),
    });

    TestHarness::new()
        .with_windows(4)
        .on_iteration(commands.len() - 1, |world, _state| {
            let expected_height = TEST_DISPLAY_HEIGHT - TEST_MENUBAR_HEIGHT;
            assert_window_size!(world, 0, TEST_WINDOW_WIDTH, expected_height);
            assert_window_size!(world, 1, TEST_WINDOW_WIDTH, expected_height);
            assert_window_size!(world, 2, TEST_WINDOW_WIDTH, expected_height);
        })
        .run(commands);
}

fn window_height(world: &mut World, id: i32) -> i32 {
    let mut query = world.query::<&crate::manager::Window>();
    query
        .iter(world)
        .find(|w| w.id() == id)
        .expect("window not found")
        .frame()
        .height()
}

#[test]
fn test_toggle_tabbed_display_off_restores_split_heights() {
    let mut commands = vec![Event::MenuOpened { window_id: 0 }];
    stack_first_three(&mut commands);
    commands.push(Event::Command {
        command: Command::Window(Operation::ToggleTabbedDisplay),
    });
    commands.push(Event::Command {
        command: Command::Window(Operation::ToggleTabbedDisplay),
    });

    TestHarness::new()
        .with_windows(4)
        .on_iteration(commands.len() - 1, |world, _state| {
            let heights = [
                window_height(world, 0),
                window_height(world, 1),
                window_height(world, 2),
            ];
            assert!(
                heights
                    .iter()
                    .any(|&h| h != TEST_DISPLAY_HEIGHT - TEST_MENUBAR_HEIGHT),
                "toggling off must restore a split (non-full-height) layout, got {heights:?}"
            );
        })
        .run(commands);
}

#[test]
fn test_focus_south_cycles_tabbed_stack_without_leaving_the_column() {
    let mut commands = vec![Event::MenuOpened { window_id: 0 }];
    stack_first_three(&mut commands);
    commands.push(Event::Command {
        command: Command::Window(Operation::ToggleTabbedDisplay),
    });
    // Start from a known tab: `Direction::First` focuses the leftmost
    // column's `top()`, which is window 0 regardless of tabbed state.
    commands.push(Event::Command {
        command: Command::Window(Operation::Focus(Direction::First)),
    });
    let after_first = commands.len() - 1;
    commands.push(Event::Command {
        command: Command::Window(Operation::Focus(Direction::South)),
    });
    let after_second = commands.len() - 1;
    commands.push(Event::Command {
        command: Command::Window(Operation::Focus(Direction::South)),
    });
    let after_third = commands.len() - 1;
    // One more South past the last tab must not jump to window 3's column.
    commands.push(Event::Command {
        command: Command::Window(Operation::Focus(Direction::South)),
    });
    let after_fourth = commands.len() - 1;

    TestHarness::new()
        .with_windows(4)
        .on_iteration(after_first, |world, _state| assert_focused!(world, 0))
        .on_iteration(after_second, |world, _state| assert_focused!(world, 1))
        .on_iteration(after_third, |world, _state| assert_focused!(world, 2))
        .on_iteration(after_fourth, |world, _state| {
            assert_focused!(world, 2);
        })
        .run(commands);
}

#[test]
fn test_close_active_tab_focuses_sibling_not_other_column() {
    let mut commands = vec![Event::MenuOpened { window_id: 0 }];
    // Stack only windows 0 and 1 (leave 2 as its own, separate column).
    commands.push(Event::Command {
        command: Command::Window(Operation::Focus(Direction::East)),
    });
    commands.push(Event::Command {
        command: Command::Window(Operation::Stack(true)),
    });
    commands.push(Event::Command {
        command: Command::Window(Operation::ToggleTabbedDisplay),
    });
    let toggle_iter = commands.len() - 1;
    // `os_close_window`'s destroy events are only drained on the *next*
    // iteration's update loop and observed the one after that — mirrors
    // `test_closing_window_of_live_app_closes_the_gap` in tiling.rs.
    commands.push(Event::Command {
        command: Command::PrintState,
    });
    commands.push(Event::Command {
        command: Command::PrintState,
    });

    TestHarness::new()
        .with_windows(3)
        .on_iteration(toggle_iter, |world, state| {
            // Window 1 is the active tab (it was focused when toggling).
            assert_focused!(world, 1);
            state.os_close_window(1);
        })
        .on_iteration(toggle_iter + 2, |world, _state| {
            assert!(
                !window_exists(world, 1),
                "closed window must be dropped from the world"
            );
            assert_focused!(world, 0);
        })
        .run(commands);
}

#[test]
fn test_toggle_tabbed_display_noop_on_single_window_column() {
    let commands = vec![
        Event::MenuOpened { window_id: 0 },
        Event::Command {
            command: Command::Window(Operation::ToggleTabbedDisplay),
        },
    ];

    TestHarness::new()
        .with_windows(1)
        .on_iteration(1, |world, _state| {
            assert!(
                !is_tabbed_display(world, 0),
                "toggling a lone Single column must be a no-op"
            );
        })
        .run(commands);
}

/// Regression: `toggle_tabbed_display` used to return a plain `bool`, so
/// "not applicable" (nothing to toggle) and "successfully turned tabs off"
/// were indistinguishable — both reported `false`. That made repeatedly
/// pressing the hotkey on a window that isn't actually stacked flash "Tabs
/// off" every single time, looking like a stuck toggle. The handler must
/// stay completely silent (no flash message) when the toggle isn't
/// applicable.
#[test]
fn test_toggle_tabbed_display_noop_does_not_flash_a_message() {
    let commands = vec![
        Event::MenuOpened { window_id: 0 },
        Event::Command {
            command: Command::Window(Operation::ToggleTabbedDisplay),
        },
        Event::Command {
            command: Command::Window(Operation::ToggleTabbedDisplay),
        },
        Event::Command {
            command: Command::Window(Operation::ToggleTabbedDisplay),
        },
    ];

    TestHarness::new()
        .with_windows(1)
        .on_iteration(3, |world, _state| {
            let mut query = world.query::<&crate::ecs::FlashMessage>();
            assert!(
                query.iter(world).next().is_none(),
                "toggling a non-applicable column must not flash any message, \
                 repeatedly or otherwise"
            );
        })
        .run(commands);
}

fn window_exists(world: &mut World, id: i32) -> bool {
    let mut query = world.query::<&crate::manager::Window>();
    query.iter(world).any(|window| window.id() == id)
}

#[test]
fn horizontal_entry_remembers_selected_tab_from_both_sides() {
    let commands = [
        Operation::Focus(Direction::East),
        Operation::Focus(Direction::East),
        Operation::Stack(true),
        Operation::ToggleTabbedDisplay,
        Operation::Focus(Direction::North),
        Operation::Focus(Direction::South),
        Operation::Focus(Direction::East),
        Operation::Focus(Direction::West),
        Operation::Focus(Direction::West),
        Operation::Focus(Direction::East),
    ];
    let events = std::iter::once(Event::MenuOpened { window_id: 0 })
        .chain(commands.into_iter().map(|operation| Event::Command {
            command: Command::Window(operation),
        }))
        .collect();
    TestHarness::new()
        .with_windows(4)
        .on_iteration(6, |world, _| assert_focused!(world, 2))
        .on_iteration(7, |world, _| {
            assert_focused!(world, 3);
            let mut state =
                bevy::ecs::system::SystemState::<crate::ecs::state::QueryStateParams>::new(world);
            let snapshot = state.get(world).unwrap().extract_window_set().unwrap();
            let column = &snapshot.current().unwrap().columns[1];
            assert_eq!(column.windows[column.selected].id, 2);
        })
        .on_iteration(8, |world, _| assert_focused!(world, 2))
        .on_iteration(9, |world, _| assert_focused!(world, 0))
        .on_iteration(10, |world, _| assert_focused!(world, 2))
        .run(events);
}

/// Run additionally with `PANERU_TRIAL_TAB_BAR_HEIGHT=28` to exercise the trial header.
#[test]
fn interactive_resize_and_move_preserve_tab_header() {
    let header = LayoutStrip::configured_tab_bar_height();
    let mut commands = vec![Event::MenuOpened { window_id: 0 }];
    commands.extend([
        Event::Command {
            command: Command::Window(Operation::Focus(Direction::East)),
        },
        Event::Command {
            command: Command::Window(Operation::Stack(true)),
        },
        Event::Command {
            command: Command::Window(Operation::ToggleTabbedDisplay),
        },
    ]);
    for _ in 0..4 {
        commands.push(Event::Command {
            command: Command::PrintState,
        });
    }
    TestHarness::new()
        .with_windows(2)
        .on_iteration(3, |world, state| {
            let entity = find_window_entity(0, world);
            world.spawn(crate::ecs::MouseHeldMarker(entity));
            state.os_move_window(0, crate::manager::Origin::new(0, TEST_MENUBAR_HEIGHT));
            state.os_resize_window(
                0,
                crate::manager::Size::new(TEST_WINDOW_WIDTH + 60, TEST_DISPLAY_HEIGHT + 100),
            );
        })
        .on_iteration(5, move |world, state| {
            let entity = find_window_entity(0, world);
            let frame = world.get::<crate::manager::Window>(entity).unwrap().frame();
            assert!(frame.min.y >= TEST_MENUBAR_HEIGHT + header);
            assert!(frame.height() <= TEST_DISPLAY_HEIGHT - TEST_MENUBAR_HEIGHT - header);
            assert_eq!(frame.width(), TEST_WINDOW_WIDTH + 60);
            assert!(
                world
                    .query::<&crate::ecs::MouseHeldMarker>()
                    .iter(world)
                    .next()
                    .is_some()
            );
            state.os_move_window(
                0,
                crate::manager::Origin::new(frame.min.x, TEST_MENUBAR_HEIGHT),
            );
        })
        .on_iteration(7, move |world, _| {
            let entity = find_window_entity(0, world);
            let frame = world.get::<crate::manager::Window>(entity).unwrap().frame();
            assert!(frame.min.y >= TEST_MENUBAR_HEIGHT + header);
            assert!(frame.max.y <= TEST_DISPLAY_HEIGHT);
        })
        .run(commands);
}

#[test]
fn arrows_recover_last_tiled_focus_from_desktop_then_navigate() {
    let events = [
        Event::MenuOpened { window_id: 0 },
        Event::Command {
            command: Command::Window(Operation::Focus(Direction::East)),
        },
        Event::Command {
            command: Command::Window(Operation::Focus(Direction::East)),
        },
        Event::Command {
            command: Command::Window(Operation::Focus(Direction::East)),
        },
    ]
    .into();
    TestHarness::new()
        .with_windows(3)
        .on_iteration(1, |world, _| {
            assert_focused!(world, 1);
            let entity = find_window_entity(1, world);
            world
                .entity_mut(entity)
                .remove::<crate::ecs::FocusedMarker>();
        })
        .on_iteration(2, |world, _| assert_focused!(world, 1))
        .on_iteration(3, |world, _| assert_focused!(world, 2))
        .run(events);
}

#[test]
fn arrows_recover_tiled_focus_from_floating_window() {
    let events = [
        Event::MenuOpened { window_id: 0 },
        Event::Command {
            command: Command::Window(Operation::Focus(Direction::East)),
        },
        Event::Command {
            command: Command::Window(Operation::Focus(Direction::West)),
        },
    ]
    .into();
    TestHarness::new()
        .with_windows(3)
        .on_iteration(1, |world, _| {
            let floating = find_window_entity(2, world);
            world
                .entity_mut(floating)
                .insert((crate::ecs::Unmanaged::Floating, crate::ecs::FocusedMarker));
        })
        .on_iteration(2, |world, _| assert_focused!(world, 1))
        .run(events);
}

#[test]
fn strip_scroll_input_works_without_tiled_focus() {
    use crate::ecs::{ActiveWorkspaceMarker, FocusedMarker, Position, Unmanaged};
    for floating_focus in [false, true] {
        let mut harness = TestHarness::new().with_windows(5);
        harness.app.update();
        let world = harness.world();
        let focused = find_window_entity(0, world);
        if floating_focus {
            world.entity_mut(focused).insert(Unmanaged::Floating);
        } else {
            world.entity_mut(focused).remove::<FocusedMarker>();
        }
        let strip = world
            .query_filtered::<Entity, With<ActiveWorkspaceMarker>>()
            .single(world)
            .unwrap();
        let before = world.get::<Position>(strip).unwrap().0.x;
        world.write_message(crate::events::InputEvent(Event::Scroll { delta: 5.0 }));
        harness.advance(std::time::Duration::from_millis(100));
        assert_ne!(harness.world().get::<Position>(strip).unwrap().0.x, before);
    }
}

#[test]
fn config_refresh_updates_tiled_padding_without_moving_floats_or_focus() {
    use crate::config::{Config, MainOptions, WindowParams};
    use crate::ecs::{FocusedMarker, Unmanaged};
    let mut harness = TestHarness::new().with_windows(2);
    harness.app.update();
    let world = harness.world();
    let floating = find_window_entity(1, world);
    world.entity_mut(floating).insert(Unmanaged::Floating);
    harness.advance(std::time::Duration::from_millis(500));
    let world = harness.world();
    let before = world
        .get::<crate::manager::Window>(floating)
        .unwrap()
        .frame();
    let focused = world
        .query_filtered::<Entity, With<FocusedMarker>>()
        .single(world)
        .unwrap();
    let mut params = WindowParams::new(".*", None);
    params.horizontal_padding = Some(7);
    params.vertical_padding = Some(9);
    world.insert_resource(Config::from((MainOptions::default(), vec![params])));
    harness.advance(std::time::Duration::from_millis(100));
    let world = harness.world();
    assert_eq!(
        world
            .get::<crate::manager::Window>(floating)
            .unwrap()
            .frame(),
        before
    );
    assert!(world.get::<FocusedMarker>(focused).is_some());
    harness.mock_state.update_window(0, |window| {
        assert_eq!(window.requested_padding, (Some(7), Some(9)));
    });
}

#[test]
fn focus_recovery_rejects_tiled_history_on_another_native_space() {
    let events = [
        Event::MenuOpened { window_id: 0 },
        Event::Command {
            command: Command::Window(Operation::Focus(Direction::East)),
        },
        Event::Command {
            command: Command::Window(Operation::Focus(Direction::East)),
        },
    ]
    .into();
    TestHarness::new()
        .with_windows(3)
        .on_iteration(1, |world, state| {
            assert_focused!(world, 1);
            let entity = find_window_entity(1, world);
            world
                .entity_mut(entity)
                .remove::<crate::ecs::FocusedMarker>();
            state.update_window(1, |window| window.workspace_id = TEST_WORKSPACE_ID + 99);
        })
        .on_iteration(2, |world, _| {
            let mut query = world.query::<(&crate::manager::Window, &crate::ecs::FocusedMarker)>();
            assert_ne!(query.single(world).unwrap().0.id(), 1);
        })
        .run(events);
}

#[derive(Resource)]
struct NativeResizeStart(IRect);

fn native_mouse_resize_regression(tabbed: bool, left_edge: bool) {
    let mut events = vec![
        Event::MenuOpened { window_id: 0 },
        Event::Command {
            command: Command::Window(Operation::Focus(Direction::East)),
        },
        Event::Command {
            command: Command::Window(Operation::Stack(true)),
        },
        Event::Command {
            command: if tabbed {
                Command::Window(Operation::ToggleTabbedDisplay)
            } else {
                Command::PrintState
            },
        },
    ];
    events.extend((0..7).map(|_| Event::Command {
        command: Command::PrintState,
    }));
    TestHarness::new()
        .with_windows(2)
        .on_iteration(3, move |world, state| {
            let entity = find_window_entity(1, world);
            let frame = world.get::<crate::manager::Window>(entity).unwrap().frame();
            // Window 1 is the lower/non-representative member of this column.
            let strip = world.query::<&LayoutStrip>().single(world).unwrap();
            assert_ne!(strip.get(0).unwrap().window_iter().next(), Some(entity));
            state.take_geometry_writes();
            world.insert_resource(NativeResizeStart(frame));
            world.spawn((
                crate::ecs::MouseHeldMarker(entity),
                crate::ecs::MouseDraggingMarker,
            ));
            if left_edge {
                state.os_move_window(
                    1,
                    crate::manager::Origin::new(frame.min.x + 120, frame.min.y),
                );
            }
            state.os_resize_window(
                1,
                crate::manager::Size::new(frame.width() - 120, frame.height()),
            );
            // Same-batch sibling echo: ownership must work before deferred
            // insertion of NativeMouseResize has been flushed.
            state.os_resize_window(0, crate::manager::Size::new(frame.width(), frame.height()));
        })
        .on_iteration(4, |world, state| {
            // A lagging sibling AX resize must not steal column ownership.
            let original = world.resource::<NativeResizeStart>().0;
            let sibling = find_window_entity(0, world);
            let frame = world
                .get::<crate::manager::Window>(sibling)
                .unwrap()
                .frame();
            state.os_resize_window(
                0,
                crate::manager::Size::new(original.width(), frame.height()),
            );
        })
        .on_iteration(5, move |world, state| {
            assert!(
                !state.take_geometry_writes().contains(&1),
                "native dragged window must receive no competing geometry writes"
            );
            let original = world.resource::<NativeResizeStart>().0;
            for id in [0, 1] {
                let entity = find_window_entity(id, world);
                let frame = world.get::<crate::manager::Window>(entity).unwrap().frame();
                assert_eq!(frame.width(), original.width() - 120, "member {id}");
                if left_edge {
                    assert_eq!(frame.max.x, original.max.x);
                } else {
                    assert_eq!(frame.min.x, original.min.x);
                }
            }
            let entity = find_window_entity(1, world);
            assert!(world.get::<crate::ecs::NativeMouseResize>(entity).is_some());
            // Exercise the real input release path, rather than manually
            // clearing resize ownership.
            world.write_message(crate::events::InputEvent(Event::MouseUp {
                point: objc2_core_foundation::CGPoint::new(0.0, 0.0),
                modifiers: crate::platform::Modifiers::empty(),
            }));
        })
        .on_iteration(8, |world, _| {
            let original = world.resource::<NativeResizeStart>().0;
            let entity = find_window_entity(1, world);
            assert!(world.get::<crate::ecs::NativeMouseResize>(entity).is_none());
            assert_eq!(
                world
                    .get::<crate::manager::Window>(entity)
                    .unwrap()
                    .frame()
                    .width(),
                original.width() - 120
            );
        })
        .run(events);
}

#[test]
fn native_mouse_resize_non_first_tab_shrinks_column() {
    native_mouse_resize_regression(true, false);
}
#[test]
fn native_mouse_resize_lower_split_shrinks_column() {
    native_mouse_resize_regression(false, false);
}
#[test]
fn native_mouse_resize_left_edge_keeps_opposite_edge() {
    native_mouse_resize_regression(true, true);
}

#[test]
fn native_mouse_resize_excludes_floating_window() {
    let events = (0..7)
        .map(|_| Event::Command {
            command: Command::PrintState,
        })
        .collect();
    TestHarness::new()
        .with_windows(2)
        .on_iteration(1, |world, _| {
            let entity = find_window_entity(1, world);
            for mut strip in world.query::<&mut LayoutStrip>().iter_mut(world) {
                strip.remove(entity);
            }
            world
                .entity_mut(entity)
                .insert(crate::ecs::Unmanaged::Floating);
        })
        .on_iteration(3, |world, state| {
            let entity = find_window_entity(1, world);
            world.spawn(crate::ecs::MouseHeldMarker(entity));
            state.os_resize_window(1, crate::manager::Size::new(333, 444));
        })
        .on_iteration(5, |world, _| {
            let entity = find_window_entity(1, world);
            assert!(world.get::<crate::ecs::NativeMouseResize>(entity).is_none());
            assert_eq!(
                world
                    .get::<crate::manager::Window>(entity)
                    .unwrap()
                    .frame()
                    .width(),
                333
            );
            let tiled = find_window_entity(0, world);
            assert_eq!(
                world
                    .get::<crate::manager::Window>(tiled)
                    .unwrap()
                    .frame()
                    .width(),
                TEST_WINDOW_WIDTH
            );
        })
        .run(events);
}

#[test]
fn native_mouse_resize_long_drag_renews_and_lost_release_expires() {
    let mut events = vec![Event::MenuOpened { window_id: 0 }];
    events.extend((0..14).map(|_| Event::MouseDragged {
        point: objc2_core_foundation::CGPoint::new(0.0, 0.0),
        modifiers: crate::platform::Modifiers::empty(),
    }));
    events.extend((0..12).map(|_| Event::Command {
        command: Command::PrintState,
    }));
    TestHarness::new()
        .with_windows(1)
        .on_iteration(0, |world, state| {
            let entity = find_window_entity(0, world);
            let timeout = crate::ecs::Timeout {
                timer: Timer::new(std::time::Duration::from_secs(5), TimerMode::Once),
                system_id: None,
                on_expire: None,
            };
            world.spawn((
                crate::ecs::MouseHeldMarker(entity),
                crate::ecs::MouseDraggingMarker,
                timeout,
            ));
            state.os_resize_window(
                0,
                crate::manager::Size::new(
                    TEST_WINDOW_WIDTH - 100,
                    TEST_DISPLAY_HEIGHT - TEST_MENUBAR_HEIGHT,
                ),
            );
        })
        .on_iteration(14, |world, _| {
            let entity = find_window_entity(0, world);
            assert!(
                world.get::<crate::ecs::NativeMouseResize>(entity).is_some(),
                "live drag exceeds the old five-second absolute timeout"
            );
        })
        .on_iteration(26, |world, _| {
            let entity = find_window_entity(0, world);
            assert!(
                world.get::<crate::ecs::NativeMouseResize>(entity).is_none(),
                "lost mouse-up must reconcile after inactivity"
            );
        })
        .run(events);
}

fn native_sibling_physical_resize(rejections: u8, delayed_reads: u8, minimum_width: i32) {
    let mut events = vec![
        Event::MenuOpened { window_id: 0 },
        Event::Command {
            command: Command::Window(Operation::Focus(Direction::East)),
        },
        Event::Command {
            command: Command::Window(Operation::Stack(true)),
        },
        Event::Command {
            command: Command::Window(Operation::ToggleTabbedDisplay),
        },
    ];
    events.extend((0..8).map(|_| Event::Command {
        command: Command::PrintState,
    }));
    TestHarness::new()
        .with_windows(2)
        .on_iteration(3, move |world, state| {
            let owner = find_window_entity(1, world);
            let frame = state.physical_window_frame(1);
            world.insert_resource(NativeResizeStart(frame));
            state.set_resize_behavior(0, rejections, delayed_reads, minimum_width);
            world.spawn((
                crate::ecs::MouseHeldMarker(owner),
                crate::ecs::MouseDraggingMarker,
            ));
            state.os_resize_window(
                1,
                crate::manager::Size::new(frame.width() - 120, frame.height()),
            );
        })
        .on_iteration(5, move |world, state| {
            let target = world.resource::<NativeResizeStart>().0.width() - 120;
            assert_eq!(
                state.physical_window_frame(1).width(),
                target,
                "retry must never resize the dragged owner"
            );
            let sibling = find_window_entity(0, world);
            assert_eq!(
                world.get::<crate::ecs::Bounds>(sibling).unwrap().0.x,
                target
            );
            let expected = if rejections > 6 {
                target + 120
            } else {
                target.max(minimum_width)
            };
            assert_eq!(
                state.physical_window_frame(0).width(),
                expected,
                "assert physical OS frame, not optimistic cache"
            );
            state.take_geometry_writes();
        })
        .on_iteration(6, |world, state| {
            assert!(
                state.take_geometry_writes().is_empty(),
                "exhausted requests must stop while held"
            );
            world.write_message(crate::events::InputEvent(Event::MouseUp {
                point: objc2_core_foundation::CGPoint::new(0.0, 0.0),
                modifiers: crate::platform::Modifiers::empty(),
            }));
        })
        .on_iteration(10, move |world, state| {
            let target = world.resource::<NativeResizeStart>().0.width() - 120;
            let expected = if rejections > 6 {
                target + 120
            } else {
                target.max(minimum_width)
            };
            for id in [0, 1] {
                let entity = find_window_entity(id, world);
                assert_eq!(
                    state.physical_window_frame(id).width(),
                    expected,
                    "physical member {id} after release"
                );
                assert_eq!(
                    world.get::<crate::ecs::Bounds>(entity).unwrap().0.x,
                    expected
                );
                assert!(
                    world
                        .get::<crate::ecs::NativeSiblingResize>(entity)
                        .is_none()
                );
            }
        })
        .run(events);
}

#[test]
fn native_sibling_retries_rejected_request_while_dragging() {
    native_sibling_physical_resize(1, 0, 0);
}
#[test]
fn native_sibling_verifies_delayed_physical_frame() {
    native_sibling_physical_resize(0, 3, 0);
}
#[test]
fn native_sibling_reconciles_minimum_only_after_release() {
    native_sibling_physical_resize(0, 0, TEST_WINDOW_WIDTH - 40);
}
#[test]
fn native_sibling_rejection_is_bounded_and_reconciled_after_release() {
    native_sibling_physical_resize(20, 0, 0);
}

#[test]
fn native_sibling_latest_target_supersedes_pending_request() {
    let mut events = vec![
        Event::MenuOpened { window_id: 0 },
        Event::Command {
            command: Command::Window(Operation::Focus(Direction::East)),
        },
        Event::Command {
            command: Command::Window(Operation::Stack(true)),
        },
        Event::Command {
            command: Command::Window(Operation::ToggleTabbedDisplay),
        },
    ];
    events.extend((0..5).map(|_| Event::Command {
        command: Command::PrintState,
    }));
    TestHarness::new()
        .with_windows(2)
        .on_iteration(3, |world, state| {
            let owner = find_window_entity(1, world);
            let frame = state.physical_window_frame(1);
            world.insert_resource(NativeResizeStart(frame));
            state.set_resize_behavior(0, 0, 8, 0);
            world.spawn((
                crate::ecs::MouseHeldMarker(owner),
                crate::ecs::MouseDraggingMarker,
            ));
            state.os_resize_window(
                1,
                crate::manager::Size::new(frame.width() - 100, frame.height()),
            );
        })
        .on_iteration(4, |world, state| {
            let frame = world.resource::<NativeResizeStart>().0;
            state.os_resize_window(
                1,
                crate::manager::Size::new(frame.width() - 160, frame.height()),
            );
        })
        .on_iteration(7, |world, state| {
            let expected = world.resource::<NativeResizeStart>().0.width() - 160;
            assert_eq!(state.physical_window_frame(0).width(), expected);
            assert_eq!(state.physical_window_frame(1).width(), expected);
            let sibling = find_window_entity(0, world);
            assert!(
                world
                    .get::<crate::ecs::NativeSiblingResize>(sibling)
                    .is_none()
            );
            state.take_geometry_writes();
            world.write_message(Event::WindowResized { window_id: 0 });
        })
        .on_iteration(8, |world, state| {
            assert!(
                state.take_geometry_writes().is_empty(),
                "matching delayed AX echo must not restart writes or budget"
            );
            let sibling = find_window_entity(0, world);
            assert!(
                world
                    .get::<crate::ecs::NativeSiblingResize>(sibling)
                    .is_none()
            );
        })
        .run(events);
}

#[test]
fn native_sibling_pending_request_yields_to_new_drag_owner() {
    let mut events = vec![
        Event::MenuOpened { window_id: 0 },
        Event::Command {
            command: Command::Window(Operation::Focus(Direction::East)),
        },
        Event::Command {
            command: Command::Window(Operation::Stack(true)),
        },
        Event::Command {
            command: Command::Window(Operation::ToggleTabbedDisplay),
        },
    ];
    events.extend((0..5).map(|_| Event::Command {
        command: Command::PrintState,
    }));
    TestHarness::new()
        .with_windows(2)
        .on_iteration(3, |world, state| {
            let owner = find_window_entity(1, world);
            state.set_resize_behavior(0, 20, 0, 0);
            world.spawn((
                crate::ecs::MouseHeldMarker(owner),
                crate::ecs::MouseDraggingMarker,
            ));
            let frame = state.physical_window_frame(1);
            state.os_resize_window(
                1,
                crate::manager::Size::new(TEST_WINDOW_WIDTH - 100, frame.height()),
            );
        })
        .on_iteration(4, |world, state| {
            let owner = find_window_entity(0, world);
            assert!(
                world
                    .get::<crate::ecs::NativeSiblingResize>(owner)
                    .is_some()
            );
            let holders: Vec<_> = world
                .query_filtered::<Entity, With<crate::ecs::MouseHeldMarker>>()
                .iter(world)
                .collect();
            for holder in holders {
                world.despawn(holder);
            }
            world.spawn((
                crate::ecs::MouseHeldMarker(owner),
                crate::ecs::MouseDraggingMarker,
            ));
            state.take_geometry_writes();
            let frame = state.physical_window_frame(0);
            state.os_resize_window(
                0,
                crate::manager::Size::new(TEST_WINDOW_WIDTH - 160, frame.height()),
            );
        })
        .on_iteration(6, |world, state| {
            assert!(
                !state.take_geometry_writes().contains(&0),
                "old pending work must not write over the new physical owner"
            );
            for id in [0, 1] {
                assert_eq!(
                    state.physical_window_frame(id).width(),
                    TEST_WINDOW_WIDTH - 160
                );
            }
            let new_owner = find_window_entity(0, world);
            let old_owner = find_window_entity(1, world);
            assert!(
                world
                    .get::<crate::ecs::NativeSiblingResize>(new_owner)
                    .is_none()
            );
            assert!(
                world
                    .get::<crate::ecs::NativeMouseResize>(new_owner)
                    .is_some()
            );
            assert!(
                world
                    .get::<crate::ecs::NativeMouseResize>(old_owner)
                    .is_none()
            );
        })
        .run(events);
}

fn tab_style_config(style: &str, height: i32) -> crate::config::Config {
    (
        crate::config::MainOptions {
            tab_style: Some(style.into()),
            tab_height: Some(height),
            ..Default::default()
        },
        vec![],
    )
        .into()
}
#[test]
fn side_presentation_reserves_once_and_releases_on_ungroup() {
    let mut commands = vec![Event::MenuOpened { window_id: 0 }];
    stack_first_three(&mut commands);
    commands.push(Event::Command {
        command: Command::Window(Operation::ToggleTabbedDisplay),
    });
    let grouped = commands.len() - 1;
    commands.push(Event::Command {
        command: Command::PrintState,
    });
    commands.push(Event::Command {
        command: Command::Window(Operation::ToggleTabbedDisplay),
    });
    TestHarness::new()
        .with_config(tab_style_config("side", 34))
        .with_windows(4)
        .on_iteration(grouped, |world, _| {
            for id in 0..3 {
                assert_window_size!(
                    world,
                    id,
                    TEST_WINDOW_WIDTH - 40,
                    TEST_DISPLAY_HEIGHT - TEST_MENUBAR_HEIGHT
                );
            }
        })
        .on_iteration(grouped + 1, |world, _| {
            for id in 0..3 {
                assert_window_size!(
                    world,
                    id,
                    TEST_WINDOW_WIDTH - 40,
                    TEST_DISPLAY_HEIGHT - TEST_MENUBAR_HEIGHT
                );
            }
        })
        .on_iteration(grouped + 2, |world, _| {
            let entity = find_window_entity(0, world);
            assert_eq!(
                world.get::<crate::ecs::Bounds>(entity).unwrap().0.x,
                TEST_WINDOW_WIDTH
            );
        })
        .run(commands);
}
#[test]
fn folder_presentation_configured_height_and_side_switch_preserve_slot() {
    let mut commands = vec![Event::MenuOpened { window_id: 0 }];
    stack_first_three(&mut commands);
    commands.push(Event::Command {
        command: Command::Window(Operation::ToggleTabbedDisplay),
    });
    let grouped = commands.len() - 1;
    commands.extend([
        Event::Command {
            command: Command::PrintState,
        },
        Event::Command {
            command: Command::PrintState,
        },
    ]);
    TestHarness::new()
        .with_config(tab_style_config("folder", 34))
        .with_windows(4)
        .on_iteration(grouped, |world, _| {
            assert_window_size!(
                world,
                0,
                TEST_WINDOW_WIDTH,
                TEST_DISPLAY_HEIGHT - TEST_MENUBAR_HEIGHT - 34
            );
            world.insert_resource(tab_style_config("side", 34));
        })
        .on_iteration(grouped + 1, |world, _| {
            assert_window_size!(
                world,
                0,
                TEST_WINDOW_WIDTH - 40,
                TEST_DISPLAY_HEIGHT - TEST_MENUBAR_HEIGHT
            );
            world.insert_resource(tab_style_config("classic", 28));
        })
        .on_iteration(grouped + 2, |world, _| {
            assert_window_size!(
                world,
                0,
                TEST_WINDOW_WIDTH,
                TEST_DISPLAY_HEIGHT - TEST_MENUBAR_HEIGHT - 28
            );
        })
        .run(commands);
}

#[test]
fn side_full_width_keeps_group_and_restores_width() {
    let mut commands = vec![Event::MenuOpened { window_id: 0 }];
    stack_first_three(&mut commands);
    commands.push(Event::Command {
        command: Command::Window(Operation::ToggleTabbedDisplay),
    });
    let grouped = commands.len() - 1;
    commands.push(Event::Command {
        command: Command::Window(Operation::FullWidth),
    });
    commands.push(Event::Command {
        command: Command::Window(Operation::FullWidth),
    });
    TestHarness::new()
        .with_config(tab_style_config("side", 34))
        .with_windows(4)
        .on_iteration(grouped + 1, |world, _| {
            for id in 0..3 {
                assert!(is_tabbed_display(world, id));
                crate::assert_window_at!(world, id, 40, TEST_MENUBAR_HEIGHT);
                assert_window_size!(
                    world,
                    id,
                    TEST_DISPLAY_WIDTH - 40,
                    TEST_DISPLAY_HEIGHT - TEST_MENUBAR_HEIGHT
                );
            }
        })
        .on_iteration(grouped + 2, |world, _| {
            for id in 0..3 {
                assert!(is_tabbed_display(world, id));
                assert_window_size!(
                    world,
                    id,
                    TEST_WINDOW_WIDTH - 40,
                    TEST_DISPLAY_HEIGHT - TEST_MENUBAR_HEIGHT
                );
            }
        })
        .run(commands);
}

#[test]
fn compact_folder_reserves_only_short_tab_height() {
    for (configured, effective) in [(28, 20), (34, 25)] {
        let mut commands = vec![Event::MenuOpened { window_id: 0 }];
        stack_first_three(&mut commands);
        commands.push(Event::Command {
            command: Command::Window(Operation::ToggleTabbedDisplay),
        });
        let grouped = commands.len() - 1;
        TestHarness::new()
            .with_config(tab_style_config("folder-compact", configured))
            .with_windows(4)
            .on_iteration(grouped, move |world, _| {
                assert_window_size!(
                    world,
                    0,
                    TEST_WINDOW_WIDTH,
                    TEST_DISPLAY_HEIGHT - TEST_MENUBAR_HEIGHT - effective
                );
            })
            .run(commands);
    }
}

#[test]
fn side_width_preset_includes_rail() {
    let mut commands = vec![Event::MenuOpened { window_id: 0 }];
    stack_first_three(&mut commands);
    commands.push(Event::Command {
        command: Command::Window(Operation::ToggleTabbedDisplay),
    });
    commands.push(Event::Command {
        command: Command::Window(Operation::SetWidth(1.0)),
    });
    let last = commands.len() - 1;
    TestHarness::new()
        .with_config(tab_style_config("side", 34))
        .with_windows(4)
        .on_iteration(last, |world, _| {
            for id in 0..3 {
                assert!(is_tabbed_display(world, id));
                crate::assert_window_at!(world, id, 40, TEST_MENUBAR_HEIGHT);
                assert_window_size!(
                    world,
                    id,
                    TEST_DISPLAY_WIDTH - 40,
                    TEST_DISPLAY_HEIGHT - TEST_MENUBAR_HEIGHT
                );
            }
        })
        .run(commands);
}
