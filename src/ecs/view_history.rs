//! Addressed layout undo and compatible viewport bookmarks. No app contents are touched.
use bevy::prelude::*;
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};

use super::{
    ActiveWorkspaceMarker, Bounds, FocusedMarker, Initializing, Position, RepositionMarker,
    ResizeMarker, Scrolling, SpawnCommandsExt, Unmanaged, WidthRatio, layout::LayoutStrip,
    workspace::PreviousStripPosition,
};
use crate::commands::{Command, Operation};
use crate::events::Event;
use crate::manager::{Application, Display, Origin, Size, Window};

#[derive(Component)]
pub(crate) struct ViewLock;

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
struct Member {
    id: i32,
    pid: i32,
    width: i32,
    height: i32,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
struct View {
    native: u64,
    display: u32,
    display_size: [i32; 2],
    columns: Vec<Vec<Member>>,
    tabs: Vec<bool>,
    origin: [i32; 2],
    focus: Option<i32>,
}
#[derive(Clone)]
struct Row {
    entity: Entity,
    strip: LayoutStrip,
    origin: Origin,
    parent: Entity,
    active: bool,
}
#[derive(Clone)]
struct Layout {
    rows: Vec<Row>,
    windows: Vec<(Entity, Size, Option<f64>)>,
    focus: Option<Entity>,
    full_width: Vec<(Entity, f64)>,
}
impl Layout {
    fn key(&self) -> String {
        let rows = self
            .rows
            .iter()
            .map(|row| {
                (
                    row.strip.virtual_index,
                    row.strip.columns().collect::<Vec<_>>(),
                    row.strip
                        .all_windows()
                        .iter()
                        .map(|e| row.strip.is_tabbed_display(*e))
                        .collect::<Vec<_>>(),
                )
            })
            .collect::<Vec<_>>();
        format!("{rows:?}:{:?}:{:?}", self.windows, self.full_width)
    }
    fn members(&self) -> BTreeSet<Entity> {
        self.windows.iter().map(|w| w.0).collect()
    }
}
#[derive(Default, PartialEq, Eq)]
enum Transaction {
    #[default]
    Idle,
    Pointer,
    Command,
}
#[derive(Resource, Default)]
pub(crate) struct History {
    undo: Option<Layout>,
    candidate: Option<Layout>,
    transaction: Transaction,
    previous: Option<View>,
    navigating: bool,
    pins: BTreeMap<u8, View>,
    loaded: bool,
}
#[cfg(not(test))]
fn path() -> std::path::PathBuf {
    super::state::PaneruState::default_state_file_path().with_file_name("view-pins.json")
}
pub(crate) fn initialize(world: &mut World) {
    load(world);
    publish_status(world, "Navigation ready");
}
fn publish_status(world: &mut World, text: &str) {
    #[cfg(test)]
    {
        let _ = (world, text);
    }
    #[cfg(not(test))]
    {
        let locked = world
            .query_filtered::<Entity, With<ViewLock>>()
            .iter(world)
            .next()
            .is_some();
        let target = path().with_file_name("view-status.json");
        let result = (|| -> std::io::Result<()> {
            if let Some(parent) = target.parent() {
                std::fs::create_dir_all(parent)?;
            }
            let temp = target.with_extension("tmp");
            std::fs::write(
                &temp,
                serde_json::to_vec(&serde_json::json!({"locked":locked,"message":text}))?,
            )?;
            std::fs::rename(temp, target)
        })();
        if let Err(error) = result {
            tracing::warn!("View status write failed: {error}");
        }
    }
}
fn announce(world: &mut World, text: &str) {
    publish_status(world, text);
    world.commands().flash_message(text.to_owned(), 1.6);
}
fn load(world: &mut World) {
    if world.resource::<History>().loaded {
        return;
    }
    #[cfg(not(test))]
    if let Ok(data) = std::fs::read(path()) {
        match serde_json::from_slice::<BTreeMap<u8, View>>(&data) {
            Ok(pins) => {
                world.resource_mut::<History>().pins =
                    pins.into_iter().filter(|(slot, _)| *slot < 10).collect();
            }
            Err(error) => tracing::warn!("Ignoring invalid view pins: {error}"),
        }
    }
    world.resource_mut::<History>().loaded = true;
}
fn save(world: &World) -> bool {
    #[cfg(test)]
    {
        let _ = world;
        true
    }
    #[cfg(not(test))]
    {
        let target = path();
        let result = (|| -> std::io::Result<()> {
            if let Some(parent) = target.parent() {
                std::fs::create_dir_all(parent)?;
            }
            let data = serde_json::to_vec_pretty(&world.resource::<History>().pins)?;
            let temp = target.with_extension("tmp");
            std::fs::write(&temp, data)?;
            std::fs::rename(temp, target)
        })();
        if let Err(error) = result {
            tracing::warn!("Saving view pins failed: {error}");
            false
        } else {
            true
        }
    }
}
fn active(world: &mut World) -> Option<(Entity, u64)> {
    world
        .query_filtered::<(Entity, &LayoutStrip), With<ActiveWorkspaceMarker>>()
        .iter(world)
        .next()
        .map(|(entity, strip)| (entity, strip.id()))
}
fn view_for(world: &World, entity: Entity) -> Option<View> {
    let strip = world.get::<LayoutStrip>(entity)?;
    let parent = world.get::<ChildOf>(entity)?.parent();
    let display = world.get::<Display>(parent)?;
    let origin = world
        .get::<PreviousStripPosition>(entity)
        .map(|p| p.origin)
        .or_else(|| world.get::<Position>(entity).map(|p| p.0))?;
    let mut columns = Vec::new();
    let mut tabs = Vec::new();
    let mut focus = None;
    for column in strip.columns() {
        let mut members = Vec::new();
        for entity in column.window_iter() {
            let window = world.get::<Window>(entity)?;
            let size = world
                .get::<ResizeMarker>(entity)
                .map(|s| s.0)
                .or_else(|| world.get::<Bounds>(entity).map(|s| s.0))?;
            let pid = world
                .get::<ChildOf>(entity)
                .and_then(|child| world.get::<Application>(child.parent()))
                .map_or(0, |a| a.pid());
            if world.get::<FocusedMarker>(entity).is_some() {
                focus = Some(window.id());
            }
            members.push(Member {
                id: window.id(),
                pid,
                width: size.x,
                height: size.y,
            });
        }
        tabs.push(column.top().is_some_and(|e| strip.is_tabbed_display(e)));
        columns.push(members);
    }
    Some(View {
        native: strip.id(),
        display: display.id(),
        display_size: [display.bounds().width(), display.bounds().height()],
        columns,
        tabs,
        origin: [origin.x, origin.y],
        focus,
    })
}
fn current_view(world: &mut World) -> Option<View> {
    let (entity, _) = active(world)?;
    view_for(world, entity)
}
fn compatible(a: &View, b: &View) -> bool {
    a.native == b.native
        && a.display == b.display
        && a.display_size == b.display_size
        && a.tabs == b.tabs
        && a.columns.len() == b.columns.len()
        && a.columns.iter().zip(&b.columns).all(|(a, b)| {
            a.len() == b.len()
                && a.iter().zip(b).all(|(a, b)| {
                    a.id == b.id
                        && a.pid == b.pid
                        && (a.width - b.width).abs() <= 2
                        && (a.height - b.height).abs() <= 2
                })
        })
}
fn unlock(world: &mut World) {
    let locked = world
        .query_filtered::<Entity, With<ViewLock>>()
        .iter(world)
        .collect::<Vec<_>>();
    let changed = !locked.is_empty();
    for entity in locked {
        world.entity_mut(entity).remove::<ViewLock>();
    }
    if changed {
        publish_status(world, "View released");
    }
}
fn restore_view(world: &mut World, view: &View) -> bool {
    let rows = world
        .query::<(Entity, &LayoutStrip)>()
        .iter(world)
        .filter(|(_, s)| s.id() == view.native)
        .map(|(e, _)| e)
        .collect::<Vec<_>>();
    let Some(target) = rows
        .into_iter()
        .find(|e| view_for(world, *e).is_some_and(|v| compatible(view, &v)))
    else {
        announce(world, "View unavailable: windows or layout changed");
        return false;
    };
    let focus = world.get::<LayoutStrip>(target).and_then(|s| {
        s.all_windows().into_iter().find(|e| {
            world
                .get::<Window>(*e)
                .is_some_and(|w| Some(w.id()) == view.focus)
        })
    });
    let origin = Origin::new(view.origin[0], view.origin[1]);
    unlock(world);
    let already = world.get::<ActiveWorkspaceMarker>(target).is_some();
    world
        .entity_mut(target)
        .insert(ViewLock)
        .remove::<(Scrolling, RepositionMarker)>();
    if already {
        world.entity_mut(target).insert(Position(origin));
        if let Some(entity) = focus {
            world.commands().focus_entity(entity, true);
        }
    } else {
        world.entity_mut(target).insert((
            PreviousStripPosition { origin, focus },
            ActiveWorkspaceMarker,
        ));
    }
    true
}
fn layout(world: &mut World) -> Option<Layout> {
    let (_, native) = active(world)?;
    let mut rows = world
        .query::<(
            Entity,
            &LayoutStrip,
            &Position,
            &ChildOf,
            Has<ActiveWorkspaceMarker>,
        )>()
        .iter(world)
        .filter(|(_, s, _, _, _)| s.id() == native)
        .map(|(entity, strip, position, parent, active)| Row {
            entity,
            strip: strip.clone(),
            parent: parent.parent(),
            active,
            origin: world
                .get::<PreviousStripPosition>(entity)
                .map_or(position.0, |p| p.origin),
        })
        .collect::<Vec<_>>();
    rows.sort_by_key(|r| r.strip.virtual_index);
    let mut windows = Vec::new();
    let mut focus = None;
    for row in &rows {
        for entity in row.strip.all_windows() {
            let size = world
                .get::<ResizeMarker>(entity)
                .map(|s| s.0)
                .or_else(|| world.get::<Bounds>(entity).map(|s| s.0))?;
            windows.push((entity, size, world.get::<WidthRatio>(entity).map(|r| r.0)));
            if world.get::<FocusedMarker>(entity).is_some() {
                focus = Some(entity);
            }
        }
    }
    windows.sort_by_key(|w| w.0);
    let full_width = windows
        .iter()
        .filter_map(|(entity, _, _)| {
            world
                .get::<super::FullWidthMarker>(*entity)
                .map(|marker| (*entity, marker.width_ratio))
        })
        .collect();
    Some(Layout {
        rows,
        windows,
        focus,
        full_width,
    })
}
fn begin_move(world: &mut World) {
    // Explicit commands own a fresh transaction, independent of a prior mouse
    // press whose release may have been consumed by a helper or menu.
    if world.resource::<History>().transaction != Transaction::Command {
        let candidate = layout(world);
        let mut h = world.resource_mut::<History>();
        h.candidate = candidate;
        h.transaction = Transaction::Command;
    }
    unlock(world);
}
fn undo(world: &mut World) {
    let Some(saved) = world.resource_mut::<History>().undo.take() else {
        announce(world, "No layout move to undo");
        return;
    };
    let Some(now) = layout(world) else {
        return;
    };
    if now.members() != saved.members()
        || saved
            .rows
            .iter()
            .any(|r| world.get::<Display>(r.parent).is_none())
    {
        announce(world, "Cannot undo: the window set changed");
        return;
    }
    unlock(world);
    let active_row = saved.rows.iter().position(|r| r.active);
    let keep = saved.rows.iter().map(|r| r.entity).collect::<BTreeSet<_>>();
    for row in &now.rows {
        if keep.contains(&row.entity) {
            world.entity_mut(row.entity).remove::<(
                ActiveWorkspaceMarker,
                PreviousStripPosition,
                Scrolling,
                RepositionMarker,
            )>();
        } else {
            world.despawn(row.entity);
        }
    }
    for (entity, size, ratio) in saved.windows {
        if let Some((_, width_ratio)) = saved.full_width.iter().find(|(e, _)| *e == entity) {
            world.entity_mut(entity).insert(super::FullWidthMarker {
                width_ratio: *width_ratio,
            });
        } else {
            world.entity_mut(entity).remove::<super::FullWidthMarker>();
        }
        if let Some(ratio) = ratio {
            world.entity_mut(entity).insert(WidthRatio(ratio));
        } else {
            world.entity_mut(entity).remove::<WidthRatio>();
        }
        world.entity_mut(entity).remove::<Unmanaged>();
        world.commands().resize_entity(entity, size);
    }
    for (index, row) in saved.rows.into_iter().enumerate() {
        let entity = if world.get_entity(row.entity).is_ok() {
            world.entity_mut(row.entity).insert((
                row.strip,
                Position(row.origin),
                ChildOf(row.parent),
            ));
            row.entity
        } else {
            world
                .spawn((row.strip, Position(row.origin), ChildOf(row.parent)))
                .id()
        };
        if Some(index) == active_row {
            world
                .entity_mut(entity)
                .insert((ViewLock, ActiveWorkspaceMarker));
        }
    }
    if let Some(entity) = saved.focus {
        world.commands().focus_entity(entity, true);
    }
    world.resource_mut::<History>().candidate = None;
    world.resource_mut::<History>().transaction = Transaction::Idle;
    announce(world, "Layout move undone");
}
fn navigate(world: &mut World) {
    if !world.resource::<History>().navigating {
        let view = current_view(world);
        let mut history = world.resource_mut::<History>();
        history.previous = view;
        history.navigating = true;
    }
    unlock(world);
}
fn view_command(world: &mut World, op: Operation) {
    load(world);
    match op {
        Operation::UndoMove => undo(world),
        Operation::ViewEnd => world.resource_mut::<History>().navigating = false,
        Operation::ViewBack => {
            let previous = world.resource::<History>().previous.clone();
            let current = current_view(world);
            if let Some(previous) = previous {
                if restore_view(world, &previous) {
                    let mut h = world.resource_mut::<History>();
                    h.previous = current;
                    h.navigating = false;
                    announce(world, "Previous view pinned");
                }
            } else {
                announce(world, "No previous view yet");
            }
        }
        Operation::ViewPin(slot) | Operation::ViewSave(slot) if slot < 10 => {
            let existing = world.resource::<History>().pins.get(&slot).cloned();
            // A resized display invalidates the old viewport, so ordinary recall
            // can reuse this slot. Other layout changes still require explicit save.
            let existing = existing.filter(|view| {
                !world.query::<&Display>().iter(world).any(|display| {
                    display.id() == view.display
                        && [display.bounds().width(), display.bounds().height()]
                            != view.display_size
                })
            });
            if matches!(op, Operation::ViewPin(_))
                && let Some(view) = existing
            {
                let previous = current_view(world);
                if restore_view(world, &view) {
                    world.resource_mut::<History>().previous = previous;
                    announce(world, &format!("Pinned view {slot}"));
                }
            } else if let Some(view) = current_view(world) {
                restore_view(world, &view);
                world.resource_mut::<History>().pins.insert(slot, view);
                announce(
                    world,
                    if save(world) {
                        "View saved and pinned"
                    } else {
                        "Pinned for this session; saving failed"
                    },
                );
            }
            world.resource_mut::<History>().navigating = false;
        }
        _ => {}
    }
}
/// Runs before command handlers; candidates are retained only if layout really changes.
pub(crate) fn observe(mut events: MessageReader<Event>, mut commands: Commands) {
    for event in events.read() {
        let event = event.clone();
        commands.queue(move |world: &mut World| {
            if world.contains_resource::<Initializing>() {
                return;
            }
            match event {
                Event::Command {
                    command: Command::Window(op),
                } => match op {
                    Operation::UndoMove
                    | Operation::ViewBack
                    | Operation::ViewEnd
                    | Operation::ViewPin(_)
                    | Operation::ViewSave(_) => view_command(world, op),
                    Operation::Focus(_)
                    | Operation::FocusOrVirtual(_)
                    | Operation::Virtual(_)
                    | Operation::VirtualNumber(_)
                    | Operation::Row(_)
                    | Operation::VirtualAdd
                    | Operation::Center
                    | Operation::Snap => navigate(world),
                    Operation::Swap(_)
                    | Operation::Stack(_)
                    | Operation::ToggleTabbedDisplay
                    | Operation::RowMove(_)
                    | Operation::RowColumnMove(_)
                    | Operation::VirtualMove(..)
                    | Operation::VirtualMoveNumber(..)
                    | Operation::Resize(_)
                    | Operation::ResizeVertical(_)
                    | Operation::SetWidth(_)
                    | Operation::FullWidth
                    | Operation::Balance
                    | Operation::Equalize => begin_move(world),
                    _ => {}
                },
                #[cfg(feature = "lua")]
                Event::Command {
                    command: Command::Layout(ops),
                } => {
                    if ops
                        .iter()
                        .any(|op| !matches!(op, crate::types::windowset::LayoutOp::Focus(_)))
                    {
                        begin_move(world);
                    } else {
                        navigate(world);
                    }
                }
                Event::RowDrop { .. } | Event::LayoutDrop { .. } => begin_move(world),
                Event::MouseDown { .. } => {
                    let candidate = layout(world);
                    let mut h = world.resource_mut::<History>();
                    if h.transaction != Transaction::Command {
                        h.candidate = candidate;
                        h.transaction = Transaction::Pointer;
                    }
                    h.navigating = false;
                }
                Event::MouseDragged { .. } => unlock(world),
                Event::MouseUp { .. } => {
                    if world.resource::<History>().transaction == Transaction::Pointer {
                        world.resource_mut::<History>().transaction = Transaction::Idle;
                    }
                }
                Event::Swipe { .. }
                | Event::Scroll { .. }
                | Event::VerticalSwipe { .. }
                | Event::VerticalScrollTick { .. } => navigate(world),
                Event::TouchpadUp => world.resource_mut::<History>().navigating = false,
                _ => {}
            }
        });
    }
}
pub(crate) fn finish(world: &mut World) {
    if world.contains_resource::<Initializing>()
        || world.resource::<History>().transaction == Transaction::Pointer
    {
        return;
    }
    world.resource_mut::<History>().transaction = Transaction::Idle;
    let candidate = world.resource_mut::<History>().candidate.take();
    if let Some(candidate) = candidate
        && let Some(current) = layout(world)
        && candidate.members() == current.members()
        && candidate.key() != current.key()
    {
        world.resource_mut::<History>().undo = Some(candidate);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::commands::Direction;
    use crate::tests::TestHarness;
    fn command(op: Operation) -> Event {
        Event::Command {
            command: Command::Window(op),
        }
    }
    #[test]
    fn pin_holds_offset_across_click_focus_and_navigation_releases() {
        TestHarness::new()
            .with_windows(3)
            .on_iteration(1, |world, _| {
                let (row, _) = active(world).unwrap();
                assert!(world.get::<ViewLock>(row).is_some());
                let v = current_view(world).unwrap();
                world.resource_mut::<History>().previous = Some(v);
            })
            .on_iteration(2, |world, _| {
                let (row, _) = active(world).unwrap();
                assert!(world.get::<ViewLock>(row).is_some());
                assert_eq!(
                    current_view(world).unwrap().origin,
                    world.resource::<History>().pins[&1].origin
                );
            })
            .on_iteration(3, |world, _| {
                let (row, _) = active(world).unwrap();
                assert!(world.get::<ViewLock>(row).is_none());
            })
            .run(vec![
                Event::MenuOpened { window_id: 0 },
                command(Operation::ViewPin(1)),
                Event::WindowFocused { window_id: 2 },
                command(Operation::Focus(Direction::East)),
            ]);
    }
    #[test]
    fn undo_restores_column_order_and_does_not_undo_clicks() {
        TestHarness::new()
            .with_windows(3)
            .on_iteration(1, |world, _| {
                assert!(world.resource::<History>().undo.is_some());
            })
            .on_iteration(3, |world, _| {
                let current = layout(world).unwrap();
                let ids = current.rows[0]
                    .strip
                    .all_columns()
                    .iter()
                    .map(|e| world.get::<Window>(*e).unwrap().id())
                    .collect::<Vec<_>>();
                assert_eq!(ids, vec![0, 1, 2]);
                assert!(world.resource::<History>().undo.is_none());
            })
            .run(vec![
                Event::MenuOpened { window_id: 0 },
                command(Operation::Swap(Direction::East)),
                Event::WindowFocused { window_id: 2 },
                command(Operation::UndoMove),
            ]);
    }
    #[test]
    fn pin_recall_rejects_changed_layout_without_moving() {
        TestHarness::new()
            .with_windows(3)
            .on_iteration(3, |world, _| {
                let (row, _) = active(world).unwrap();
                assert!(world.get::<ViewLock>(row).is_none());
                assert!(!compatible(
                    &current_view(world).unwrap(),
                    &world.resource::<History>().pins[&2]
                ));
            })
            .run(vec![
                Event::MenuOpened { window_id: 0 },
                command(Operation::ViewSave(2)),
                command(Operation::Swap(Direction::East)),
                command(Operation::ViewPin(2)),
            ]);
    }
    #[test]
    fn navigation_sequence_retains_start_and_back_toggles() {
        TestHarness::new()
            .with_windows(3)
            .on_iteration(1, |world, _| {
                assert_eq!(
                    world.resource::<History>().previous.as_ref().unwrap().focus,
                    Some(0)
                );
            })
            .on_iteration(2, |world, _| {
                assert_eq!(
                    world.resource::<History>().previous.as_ref().unwrap().focus,
                    Some(0)
                );
            })
            .on_iteration(4, |world, _| {
                let (row, _) = active(world).unwrap();
                assert!(world.get::<ViewLock>(row).is_some());
            })
            .run(vec![
                Event::MenuOpened { window_id: 0 },
                command(Operation::Focus(Direction::East)),
                command(Operation::Focus(Direction::East)),
                command(Operation::ViewEnd),
                command(Operation::ViewBack),
            ]);
    }
    #[test]
    fn undo_restores_row_move() {
        let config =
            crate::config::Config::try_from("[options]\nreap_empty_workspaces=true\n[bindings]\n")
                .unwrap();
        TestHarness::new()
            .with_windows(2)
            .with_config(config)
            .on_iteration(3, |world, _| {
                let saved = layout(world).unwrap();
                assert_eq!(
                    saved
                        .rows
                        .iter()
                        .map(|r| r.strip.all_windows().len())
                        .collect::<Vec<_>>(),
                    vec![2]
                );
            })
            .run(vec![
                Event::MenuOpened { window_id: 0 },
                command(Operation::VirtualMoveNumber(
                    1,
                    crate::commands::MoveFocus::Follow,
                )),
                command(Operation::UndoMove),
                Event::MenuOpened { window_id: 0 },
            ]);
    }
    #[test]
    fn pin_recall_returns_to_another_row() {
        TestHarness::new()
            .with_windows(2)
            .on_iteration(4, |world, _| {
                let view = current_view(world).unwrap();
                assert!(compatible(&view, &world.resource::<History>().pins[&3]));
                let (row, _) = active(world).unwrap();
                assert!(world.get::<ViewLock>(row).is_some());
            })
            .run(vec![
                Event::MenuOpened { window_id: 0 },
                command(Operation::ViewSave(3)),
                command(Operation::VirtualNumber(1)),
                command(Operation::ViewEnd),
                command(Operation::ViewPin(3)),
            ]);
    }
    #[test]
    fn undo_recreates_reaped_source_row() {
        let config =
            crate::config::Config::try_from("[options]\nreap_empty_workspaces=true\n[bindings]\n")
                .unwrap();
        TestHarness::new()
            .with_windows(1)
            .with_config(config)
            .on_iteration(3, |world, _| {
                let current = layout(world).unwrap();
                assert_eq!(current.rows.len(), 1);
                assert_eq!(current.rows[0].strip.all_windows().len(), 1);
                assert!(current.rows[0].active);
                assert!(world.resource::<History>().undo.is_none());
            })
            .run(vec![
                Event::MenuOpened { window_id: 0 },
                command(Operation::VirtualMoveNumber(
                    1,
                    crate::commands::MoveFocus::Follow,
                )),
                command(Operation::UndoMove),
                Event::MenuOpened { window_id: 0 },
            ]);
    }
    #[test]
    fn resized_display_pin_is_replaced_by_plain_recall() {
        TestHarness::new()
            .with_windows(2)
            .on_iteration(1, |world, _| {
                world
                    .resource_mut::<History>()
                    .pins
                    .get_mut(&4)
                    .unwrap()
                    .display_size[0] += 100;
            })
            .on_iteration(2, |world, _| {
                assert!(compatible(
                    &current_view(world).unwrap(),
                    &world.resource::<History>().pins[&4]
                ));
                let (row, _) = active(world).unwrap();
                assert!(world.get::<ViewLock>(row).is_some());
            })
            .run(vec![
                Event::MenuOpened { window_id: 0 },
                command(Operation::ViewSave(4)),
                command(Operation::ViewPin(4)),
            ]);
    }
    #[test]
    fn undo_unstack_restores_tabs() {
        TestHarness::new()
            .with_windows(3)
            .on_iteration(3, |world, _| {
                world.resource_mut::<History>().undo = None;
                let stale = layout(world);
                world.resource_mut::<History>().candidate = stale;
                world.resource_mut::<History>().transaction = Transaction::Pointer;
            })
            .on_iteration(4, |world, _| {
                assert!(
                    world.resource::<History>().undo.is_some(),
                    "unstack must record undo"
                );
            })
            .on_iteration(5, |world, _| {
                let current = layout(world).unwrap();
                assert_eq!(current.rows[0].strip.columns().count(), 2);
                assert!(
                    current.rows[0]
                        .strip
                        .all_windows()
                        .iter()
                        .any(|e| current.rows[0].strip.is_tabbed_display(*e))
                );
            })
            .run(vec![
                Event::MenuOpened { window_id: 0 },
                command(Operation::Focus(Direction::East)),
                command(Operation::Stack(true)),
                command(Operation::ToggleTabbedDisplay),
                command(Operation::Stack(false)),
                command(Operation::UndoMove),
            ]);
    }
    #[test]
    fn undo_width_cycle_restores_exact_size() {
        TestHarness::new()
            .with_windows(2)
            .on_iteration(2, |world, _| {
                let current = layout(world).unwrap();
                assert_eq!(current.windows[0].1.x, crate::tests::TEST_WINDOW_WIDTH);
            })
            .run(vec![
                Event::MenuOpened { window_id: 0 },
                command(Operation::Resize(crate::commands::ResizeDirection::Grow)),
                command(Operation::UndoMove),
            ]);
    }
    #[test]
    fn keyboard_resize_ignores_unfinished_old_mouse_snapshot() {
        TestHarness::new()
            .with_windows(2)
            .on_iteration(0, |world, _| {
                let stale = layout(world);
                world.resource_mut::<History>().candidate = stale;
                world.resource_mut::<History>().transaction = Transaction::Pointer;
            })
            .on_iteration(1, |world, _| {
                assert!(
                    world.resource::<History>().undo.is_some(),
                    "keyboard move must finish even if a helper swallowed mouse-up"
                );
                let view = current_view(world).unwrap();
                world.resource_mut::<History>().pins.insert(9, view);
            })
            .on_iteration(4, |world, _| {
                // Undo must restore the first resized width, not the stale original.
                assert_eq!(
                    layout(world).unwrap().windows[0].1.x,
                    world.resource::<History>().pins[&9].columns[0][0].width
                );
            })
            .run(vec![
                Event::MenuOpened { window_id: 0 },
                command(Operation::SetWidth(0.5)),
                command(Operation::SetWidth(0.75)),
                command(Operation::UndoMove),
                Event::MenuOpened { window_id: 0 },
            ]);
    }
    #[test]
    fn undo_resize_restores_fullwidth_toggle_state() {
        TestHarness::new()
            .with_windows(2)
            .on_iteration(3, |world, _| {
                let current = layout(world).unwrap();
                assert_eq!(current.full_width.len(), 1);
                assert_eq!(
                    current.windows[0].1.x,
                    world.resource::<History>().pins[&8].columns[0][0].width
                );
            })
            .on_iteration(1, |world, _| {
                let view = current_view(world).unwrap();
                world.resource_mut::<History>().pins.insert(8, view);
            })
            .run(vec![
                Event::MenuOpened { window_id: 0 },
                command(Operation::FullWidth),
                command(Operation::Resize(crate::commands::ResizeDirection::Grow)),
                command(Operation::UndoMove),
            ]);
    }
    #[test]
    fn pin_validation_checks_process_and_geometry() {
        let mut h = TestHarness::new().with_windows(2);
        h.app.update();
        h.app.update();
        let view = current_view(h.world()).unwrap();
        let mut other = view.clone();
        assert!(compatible(&view, &other));
        other.columns[0][0].pid += 1;
        assert!(!compatible(&view, &other));
        other = view.clone();
        other.columns[0][0].width += 3;
        assert!(!compatible(&view, &other));
        other = view.clone();
        other.display_size[0] += 10;
        assert!(!compatible(&view, &other));
    }
}
