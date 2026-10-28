use super::*;
use crate::commands::{Command, Operation};
use crate::config::Config;
use crate::ecs::MouseHeldMarker;
use crate::ecs::drag::{DragCandidate, NativeColumnDrag};
use crate::ecs::layout::LayoutStrip;
use crate::events::Event;
use crate::manager::{Origin, Window};
use crate::platform::Modifiers;
use bevy::prelude::*;
use objc2_core_foundation::CGPoint;
use std::time::Duration;

fn harness(enabled: bool) -> TestHarness {
    let mut h = TestHarness::new().with_windows(3).with_config(
        Config::try_from(
            format!("[options]\ndrag_reorder={enabled}\nanimation_speed=1000000\n[bindings]\n")
                .as_str(),
        )
        .unwrap(),
    );
    h.advance(Duration::from_millis(500));
    h
}
fn send(h: &mut TestHarness, event: Event) {
    h.world().write_message(event);
}
fn point(origin: Origin) -> CGPoint {
    CGPoint::new(f64::from(origin.x), f64::from(origin.y))
}
fn order(h: &mut TestHarness) -> Vec<Entity> {
    h.world()
        .query::<&LayoutStrip>()
        .single(h.app.world())
        .unwrap()
        .columns()
        .map(|c| c.window_iter().next().unwrap())
        .collect()
}
fn frame(h: &mut TestHarness, id: i32) -> IRect {
    let e = find_window_entity(id, h.world());
    h.world().get::<Window>(e).unwrap().frame()
}
fn start(h: &mut TestHarness, id: i32, content: bool) -> Origin {
    let f = frame(h, id);
    let p = f.min + IVec2::new(100, if content { 80 } else { 16 });
    send(
        h,
        Event::MouseDown {
            point: point(p),
            modifiers: Modifiers::empty(),
        },
    );
    h.advance(Duration::from_millis(40));
    p
}
fn move_native(h: &mut TestHarness, id: i32, p: Origin) {
    send(
        h,
        Event::MouseDragged {
            point: point(p + IVec2::new(100, 16)),
            modifiers: Modifiers::empty(),
        },
    );
    h.mock_state.os_move_window(id, p);
    h.advance(Duration::from_millis(60));
}
fn release(h: &mut TestHarness, p: Origin) {
    send(
        h,
        Event::MouseUp {
            point: point(p),
            modifiers: Modifiers::empty(),
        },
    );
    h.advance(Duration::from_millis(100));
}

#[test]
fn titlebar_drag_keeps_native_geometry_then_commits_once_on_real_release() {
    let mut h = harness(true);
    let before = order(&mut h);
    start(&mut h, 0, false);
    assert_eq!(
        h.world()
            .query::<&DragCandidate>()
            .iter(h.app.world())
            .count(),
        1
    );
    h.mock_state.take_geometry_writes();
    let p = Origin::new(850, frame(&mut h, 0).min.y + 20);
    move_native(&mut h, 0, p);
    assert_eq!(order(&mut h), before, "no live reorder before MouseUp");
    assert_eq!(frame(&mut h, 0).min, p);
    assert!(
        !h.mock_state.take_geometry_writes().contains(&0),
        "engine must not write held window geometry"
    );
    let owner = find_window_entity(0, h.world());
    assert!(h.world().get::<NativeColumnDrag>(owner).is_some());
    release(&mut h, p + IVec2::new(100, 16));
    assert_eq!(order(&mut h), vec![before[1], before[2], before[0]]);
    assert!(h.world().get::<NativeColumnDrag>(owner).is_none());
    assert_eq!(
        h.world()
            .query::<&MouseHeldMarker>()
            .iter(h.app.world())
            .count(),
        0
    );
    h.advance(Duration::from_millis(500));
    assert_eq!(order(&mut h), vec![before[1], before[2], before[0]]);
}

#[test]
fn disabled_and_content_drag_do_not_rearrange() {
    for (enabled, content) in [(false, false), (true, true)] {
        let mut h = harness(enabled);
        let before = order(&mut h);
        start(&mut h, 0, content);
        assert_eq!(
            h.world()
                .query::<&DragCandidate>()
                .iter(h.app.world())
                .count(),
            0
        );
        let p = Origin::new(850, frame(&mut h, 0).min.y);
        move_native(&mut h, 0, p);
        release(&mut h, p + IVec2::new(100, 16));
        assert_eq!(order(&mut h), before);
    }
}

#[test]
fn escape_lost_release_and_size_change_cancel_instead_of_commit() {
    for cancellation in 0..4 {
        let mut h = harness(true);
        let before = order(&mut h);
        start(&mut h, 0, false);
        let p = Origin::new(850, frame(&mut h, 0).min.y);
        move_native(&mut h, 0, p);
        match cancellation {
            0 => send(&mut h, Event::CancelKeyboardFocusHandoff),
            1 => h.advance(Duration::from_secs(6)),
            2 => {
                let f = frame(&mut h, 0);
                h.mock_state
                    .os_resize_window(0, f.size() + IVec2::new(30, 0));
            }
            _ => send(
                &mut h,
                Event::MouseDown {
                    point: point(p + IVec2::new(100, 80)),
                    modifiers: Modifiers::empty(),
                },
            ),
        }
        release(&mut h, p + IVec2::new(100, 16));
        assert_eq!(order(&mut h), before);
        let owner = find_window_entity(0, h.world());
        assert!(h.world().get::<NativeColumnDrag>(owner).is_none());
    }
}

#[test]
fn whole_tabbed_column_keeps_members_and_display_mode() {
    for far_side in [false, true] {
        let mut h = harness(true);
        send(
            &mut h,
            Event::Command {
                command: Command::Window(Operation::Focus(crate::commands::Direction::East)),
            },
        );
        h.advance(Duration::from_millis(500));
        send(
            &mut h,
            Event::Command {
                command: Command::Window(Operation::Stack(true)),
            },
        );
        h.advance(Duration::from_millis(100));
        send(
            &mut h,
            Event::Command {
                command: Command::Window(Operation::ToggleTabbedDisplay),
            },
        );
        h.advance(Duration::from_millis(100));
        let selected = find_window_entity(1, h.world());
        let sibling = find_window_entity(0, h.world());
        let other = find_window_entity(2, h.world());
        start(&mut h, 1, false);
        // The mock has no native z-order; overlapping members may hit either
        // title bar. Reordering must move the same whole column in both cases.
        let held = h
            .world()
            .query::<&MouseHeldMarker>()
            .single(h.app.world())
            .unwrap()
            .0;
        let owner_id = h.world().get::<Window>(held).unwrap().id();
        let hold_entity = h
            .world()
            .query::<(Entity, &MouseHeldMarker)>()
            .single(h.app.world())
            .unwrap()
            .0;
        assert!(
            h.world().get::<DragCandidate>(hold_entity).is_some(),
            "group drag must capture the hit-tested native header"
        );
        let source_frame = frame(&mut h, owner_id);
        let bounds = h
            .world()
            .query::<&crate::manager::Display>()
            .single(h.app.world())
            .unwrap()
            .bounds();
        let boundary = crate::ecs::drag::visible_drop_center(frame(&mut h, 2), bounds);
        let p = Origin::new(
            boundary - 100 + if far_side { 32 } else { 0 },
            source_frame.min.y + 20,
        );
        move_native(&mut h, owner_id, p);
        assert!(
            h.world().get::<NativeColumnDrag>(held).is_some(),
            "group move must own native geometry"
        );
        release(&mut h, p + IVec2::new(100, 16));
        let world = h.world();
        let strip = world.query::<&LayoutStrip>().single(world).unwrap();
        let group_slot = usize::from(far_side);
        assert_eq!(strip.index_of(other).unwrap(), 1 - group_slot);
        assert_eq!(strip.index_of(selected).unwrap(), group_slot);
        assert_eq!(strip.index_of(sibling).unwrap(), group_slot);
        assert!(strip.is_tabbed_display(selected));
        assert!(strip.is_tabbed_display(sibling));
    }
}

#[test]
fn real_movement_and_stable_size_are_both_required() {
    for resizing in [false, true] {
        let mut h = harness(true);
        let before = order(&mut h);
        start(&mut h, 0, false);
        let f = frame(&mut h, 0);
        if resizing {
            send(
                &mut h,
                Event::MouseDragged {
                    point: point(f.min + IVec2::new(100, 16)),
                    modifiers: Modifiers::empty(),
                },
            );
            h.mock_state
                .os_resize_window(0, f.size() + IVec2::new(40, 0));
        }
        h.mock_state.os_move_window(0, Origin::new(850, f.min.y));
        h.advance(Duration::from_millis(60));
        let owner = find_window_entity(0, h.world());
        assert!(h.world().get::<NativeColumnDrag>(owner).is_none());
        release(&mut h, Origin::new(950, f.min.y + 16));
        assert_eq!(order(&mut h), before);
    }
}

#[test]
fn row_change_topology_change_and_mission_control_cancel() {
    for reason in 0..3 {
        let mut h = harness(true);
        let before = order(&mut h);
        let source = h
            .world()
            .query::<(Entity, &LayoutStrip)>()
            .single(h.app.world())
            .unwrap()
            .0;
        start(&mut h, 0, false);
        let p = Origin::new(850, frame(&mut h, 0).min.y);
        move_native(&mut h, 0, p);
        let expected = match reason {
            0 => {
                send(
                    &mut h,
                    Event::Command {
                        command: Command::Window(Operation::VirtualNumber(1)),
                    },
                );
                before.clone()
            }
            1 => {
                h.world().get_mut::<LayoutStrip>(source).unwrap().swap(0, 1);
                vec![before[1], before[0], before[2]]
            }
            _ => {
                h.world()
                    .resource_mut::<crate::ecs::MissionControlActive>()
                    .0 = true;
                before.clone()
            }
        };
        h.advance(Duration::from_millis(60));
        let owner = find_window_entity(0, h.world());
        assert!(h.world().get::<NativeColumnDrag>(owner).is_none());
        release(&mut h, p + IVec2::new(100, 16));
        let strip = h.world().get::<LayoutStrip>(source).unwrap();
        assert_eq!(
            strip
                .columns()
                .map(|c| c.window_iter().next().unwrap())
                .collect::<Vec<_>>(),
            expected
        );
    }
}

#[test]
fn removing_dragged_window_cannot_leave_ownership_or_reorder_survivors() {
    let mut h = harness(true);
    let before = order(&mut h);
    start(&mut h, 0, false);
    let p = Origin::new(850, frame(&mut h, 0).min.y);
    move_native(&mut h, 0, p);
    let source = h
        .world()
        .query::<(Entity, &LayoutStrip)>()
        .single(h.app.world())
        .unwrap()
        .0;
    h.world()
        .get_mut::<LayoutStrip>(source)
        .unwrap()
        .remove(before[0]);
    h.world().despawn(before[0]);
    release(&mut h, p + IVec2::new(100, 16));
    assert_eq!(order(&mut h), vec![before[1], before[2]]);
    assert_eq!(
        h.world()
            .query::<&NativeColumnDrag>()
            .iter(h.app.world())
            .count(),
        0
    );
}

#[test]
fn escape_before_native_motion_cancels_the_entire_gesture() {
    let mut h = harness(true);
    let before = order(&mut h);
    start(&mut h, 0, false);
    send(&mut h, Event::CancelKeyboardFocusHandoff);
    h.advance(Duration::from_millis(40));
    let p = Origin::new(850, frame(&mut h, 0).min.y);
    move_native(&mut h, 0, p);
    let owner = find_window_entity(0, h.world());
    assert!(h.world().get::<NativeColumnDrag>(owner).is_none());
    release(&mut h, p + IVec2::new(100, 16));
    assert_eq!(order(&mut h), before);
}

fn drop_request(
    h: &mut TestHarness,
    source: i32,
    target: i32,
    kind: crate::types::wire::DropKind,
    side: crate::types::wire::DropSide,
    stale_row: bool,
) -> crate::types::wire::Response {
    let strip = h
        .world()
        .query::<&LayoutStrip>()
        .single(h.app.world())
        .unwrap();
    let drop = crate::types::wire::LayoutDrop {
        source,
        target,
        kind,
        side,
        native_workspace: strip.id(),
        row: strip.virtual_index + if stale_row { 2 } else { 1 },
    };
    let (tx, rx) = async_channel::bounded(1);
    send(
        h,
        Event::LayoutDrop {
            drop,
            respond_to: tx,
        },
    );
    h.advance(Duration::from_millis(40));
    rx.try_recv().unwrap()
}

#[test]
fn helper_drop_acknowledges_actual_order_and_rejects_stale_identity() {
    use crate::types::wire::{DropKind, DropSide, Response};
    let mut h = harness(false); // helper drops do not depend on native dragging option
    let initial = order(&mut h);
    assert_eq!(
        drop_request(&mut h, 0, 2, DropKind::Column, DropSide::After, true),
        Response::Error("source or target changed workspace".into())
    );
    assert_eq!(order(&mut h), initial);
    assert_eq!(
        drop_request(&mut h, 0, 2, DropKind::Column, DropSide::After, false),
        Response::LayoutDrop
    );
    assert_eq!(order(&mut h), vec![initial[1], initial[2], initial[0]]);
    assert!(matches!(
        drop_request(&mut h, 999, 0, DropKind::Column, DropSide::Before, false),
        Response::Error(_)
    ));
}

#[test]
fn helper_tabs_reorder_merge_and_detach_without_splitting_native_siblings() {
    use crate::types::wire::{DropKind, DropSide, Response};
    let mut h = harness(false);
    let a = find_window_entity(0, h.world());
    let b = find_window_entity(1, h.world());
    let c = find_window_entity(2, h.world());
    assert_eq!(
        drop_request(&mut h, 0, 1, DropKind::Tab, DropSide::After, false),
        Response::LayoutDrop
    );
    {
        let strip = h
            .world()
            .query::<&LayoutStrip>()
            .single(h.app.world())
            .unwrap();
        assert_eq!(
            strip.get(0).unwrap().window_iter().collect::<Vec<_>>(),
            vec![b, a]
        );
        assert!(strip.is_tabbed_display(a));
    }
    assert_eq!(
        drop_request(&mut h, 0, 1, DropKind::Tab, DropSide::Before, false),
        Response::LayoutDrop
    );
    {
        let mut strip = h
            .world()
            .query::<&mut LayoutStrip>()
            .single_mut(h.world())
            .unwrap();
        assert_eq!(
            strip.get(0).unwrap().window_iter().collect::<Vec<_>>(),
            vec![a, b]
        );
        strip.convert_to_tabs(a, c).unwrap();
    }
    assert_eq!(
        drop_request(&mut h, 0, 0, DropKind::Detach, DropSide::After, false),
        Response::LayoutDrop
    );
    let strip = h
        .world()
        .query::<&LayoutStrip>()
        .single(h.app.world())
        .unwrap();
    assert_eq!(
        strip.get(0).unwrap().window_iter().collect::<Vec<_>>(),
        vec![b]
    );
    assert_eq!(
        strip.get(1).unwrap().window_iter().collect::<Vec<_>>(),
        vec![c, a]
    );
    assert!(!strip.is_tabbed_display(a));
}

#[test]
fn wide_native_drag_crosses_clipped_neighbor_with_pointer_before_window_center() {
    let mut h = harness(true);
    let before = order(&mut h);
    // Same topology as the observed wide-window case: left neighbor clipped,
    // dragged right column wider than the pointer's reachable travel distance.
    let bounds = h
        .world()
        .query::<&crate::manager::Display>()
        .single(h.app.world())
        .unwrap()
        .bounds();
    let y = frame(&mut h, 2).min.y;
    for (id, x) in [(0, -900), (1, -400), (2, 550)] {
        h.mock_state
            .os_resize_window(id, crate::manager::Size::new(950, 700));
        h.mock_state.os_move_window(id, Origin::new(x, y));
    }
    for id in 0..3 {
        let e = find_window_entity(id, h.world());
        h.world().get_mut::<crate::ecs::WidthRatio>(e).unwrap().0 =
            950.0 / f64::from(bounds.width());
    }
    h.advance(Duration::from_millis(100));
    for (id, x) in [(0, -900), (1, -400), (2, 550)] {
        h.mock_state.os_move_window(id, Origin::new(x, y));
    }
    // Refresh Window's native cache without running automatic layout first.
    for id in 0..3 {
        let e = find_window_entity(id, h.world());
        h.world()
            .get_mut::<Window>(e)
            .unwrap()
            .update_frame()
            .unwrap();
        h.world().get_mut::<crate::ecs::Position>(e).unwrap().0 = Origin::new(
            if id == 0 {
                -900
            } else if id == 1 {
                -400
            } else {
                550
            },
            y,
        );
        h.world().get_mut::<crate::ecs::Bounds>(e).unwrap().0 = crate::manager::Size::new(950, 700);
    }
    let boundary = crate::ecs::drag::visible_drop_center(frame(&mut h, 1), bounds);
    start(&mut h, 2, false);
    let p = Origin::new(boundary - 132, y);
    move_native(&mut h, 2, p);
    assert!(
        frame(&mut h, 2).center().x > frame(&mut h, 1).center().x,
        "old window-center policy still cannot cross the neighbor"
    );
    assert_eq!(order(&mut h), before);
    release(&mut h, p + IVec2::new(100, 16));
    assert_eq!(order(&mut h), vec![before[0], before[2], before[1]]);
}

fn row_harness() -> TestHarness {
    let mut h = TestHarness::new().with_windows(3).with_config(
        Config::try_from("default_workspaces=3\n[options]\nanimation_speed=1000000\n[bindings]\n")
            .unwrap(),
    );
    h.advance(Duration::from_millis(500));
    h
}
fn row_order(h: &mut TestHarness, row: u32) -> Vec<Vec<Entity>> {
    h.world()
        .query::<&LayoutStrip>()
        .iter(h.app.world())
        .find(|s| s.virtual_index + 1 == row)
        .unwrap()
        .columns()
        .map(|c| c.window_iter().collect())
        .collect()
}
fn row_drop(
    h: &mut TestHarness,
    source: i32,
    source_row: u32,
    target_row: u32,
    anchor: Option<(crate::types::wire::DropSide, i32)>,
) -> crate::types::wire::Response {
    let drop = crate::types::wire::RowDrop {
        source,
        source_row,
        target_row,
        anchor,
        display: TEST_DISPLAY_ID,
        native_workspace: TEST_WORKSPACE_ID,
    };
    let (tx, rx) = async_channel::bounded(1);
    send(
        h,
        Event::RowDrop {
            drop,
            respond_to: tx,
        },
    );
    h.advance(Duration::from_millis(80));
    rx.try_recv().unwrap()
}
fn active_row(h: &mut TestHarness) -> u32 {
    h.world()
        .query_filtered::<&LayoutStrip, With<crate::ecs::ActiveWorkspaceMarker>>()
        .single(h.app.world())
        .unwrap()
        .virtual_index
        + 1
}
#[test]
fn row_drop_moves_inactive_columns_and_reorders_without_following() {
    use crate::types::wire::{DropSide, Response};
    let mut h = row_harness();
    let original = row_order(&mut h, 1);
    assert_eq!(row_drop(&mut h, 0, 1, 2, None), Response::LayoutDrop);
    assert_eq!(row_order(&mut h, 2), vec![original[0].clone()]);
    assert_eq!(active_row(&mut h), 1);
    assert_eq!(row_drop(&mut h, 0, 2, 3, None), Response::LayoutDrop);
    assert!(row_order(&mut h, 2).is_empty());
    assert_eq!(
        row_drop(&mut h, 1, 1, 3, Some((DropSide::Before, 0))),
        Response::LayoutDrop
    );
    assert_eq!(
        row_order(&mut h, 3),
        vec![original[1].clone(), original[0].clone()]
    );
    assert_eq!(
        row_drop(&mut h, 0, 3, 3, Some((DropSide::Before, 1))),
        Response::LayoutDrop
    );
    assert_eq!(
        row_order(&mut h, 3),
        vec![original[0].clone(), original[1].clone()]
    );
    assert_eq!(active_row(&mut h), 1);
    assert_eq!(
        row_drop(&mut h, 0, 3, 1, Some((DropSide::After, 2))),
        Response::LayoutDrop
    );
    assert_eq!(
        row_order(&mut h, 1),
        vec![original[2].clone(), original[0].clone()]
    );
    assert_eq!(active_row(&mut h), 1);
}
#[test]
fn row_drop_rejects_stale_rows_and_anchors_atomically() {
    use crate::types::wire::{DropSide, Response};
    let mut h = row_harness();
    let original = row_order(&mut h, 1);
    for (source_row, target, anchor) in [
        (2, 3, None),
        (1, 99, None),
        (1, 2, Some((DropSide::Before, 1))),
        (1, 2, Some((DropSide::After, 999))),
    ] {
        assert!(matches!(
            row_drop(&mut h, 0, source_row, target, anchor),
            Response::Error(_)
        ));
        assert_eq!(row_order(&mut h, 1), original);
        assert!(row_order(&mut h, 2).is_empty());
        assert_eq!(active_row(&mut h), 1);
    }
}
#[test]
fn row_drop_preserves_native_group_display_mode_and_empty_active_row() {
    use crate::types::wire::Response;
    let mut h = row_harness();
    let a = find_window_entity(0, h.world());
    let b = find_window_entity(1, h.world());
    let c = find_window_entity(2, h.world());
    {
        let mut strip = h
            .world()
            .query::<&mut LayoutStrip>()
            .iter_mut(h.world())
            .find(|s| s.virtual_index == 0)
            .unwrap();
        strip.convert_to_tabs(a, b).unwrap();
        strip.stack_onto(a, c, true).unwrap();
    }
    h.advance(Duration::from_millis(80));
    let column = row_order(&mut h, 1);
    assert_eq!(row_drop(&mut h, 0, 1, 2, None), Response::LayoutDrop);
    assert!(row_order(&mut h, 1).is_empty());
    assert_eq!(row_order(&mut h, 2), column);
    assert_eq!(
        active_row(&mut h),
        1,
        "empty active row must not follow moved window"
    );
    let strip = h
        .world()
        .query::<&LayoutStrip>()
        .iter(h.app.world())
        .find(|s| s.virtual_index == 1)
        .unwrap();
    assert!(strip.is_tabbed_display(a) && strip.is_tabbed_display(c));
    assert_eq!(strip.tab_group(a).unwrap(), vec![b, a]);
}

#[test]
fn row_drop_rejects_native_space_and_display_change_before_mutation() {
    use crate::types::wire::{Response, RowDrop};
    let mut h = row_harness();
    let original = row_order(&mut h, 1);
    for (display, native_workspace) in [
        (TEST_DISPLAY_ID + 1, TEST_WORKSPACE_ID),
        (TEST_DISPLAY_ID, TEST_WORKSPACE_ID + 1),
    ] {
        let (tx, rx) = async_channel::bounded(1);
        send(
            &mut h,
            Event::RowDrop {
                drop: RowDrop {
                    source: 0,
                    source_row: 1,
                    target_row: 2,
                    anchor: None,
                    display,
                    native_workspace,
                },
                respond_to: tx,
            },
        );
        h.advance(Duration::from_millis(40));
        assert!(matches!(rx.try_recv().unwrap(), Response::Error(_)));
        assert_eq!(row_order(&mut h, 1), original);
        assert!(row_order(&mut h, 2).is_empty());
    }
}
