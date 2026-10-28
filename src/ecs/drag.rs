//! Native title-bar drag ownership and one-shot whole-column insertion.
use crate::config::Config;
use crate::ecs::layout::LayoutStrip;
use crate::ecs::params::Windows;
use crate::ecs::{
    ActiveWorkspaceMarker, MouseDraggingMarker, MouseHeldMarker, NativeMouseResize, Position,
    RepositionMarker, ResizeMarker, SpawnCommandsExt, Unmanaged,
};
use crate::events::Event;
use crate::manager::{Origin, Window};
use bevy::prelude::*;

pub(super) struct DragReorderPlugin;
impl Plugin for DragReorderPlugin {
    fn build(&self, app: &mut App) {
        app.add_systems(
            Update,
            (apply_helper_drop, apply_row_drop)
                .chain()
                .run_if(bevy::ecs::schedule::common_conditions::on_message::<Event>),
        );
        app.add_systems(
            Update,
            track_native_drag
                .after(super::mouse::mouse_down_trigger)
                .after(super::mouse::refresh_mouse_hold)
                .before(super::systems::window_moved_update_frame)
                .before(super::systems::window_resized_update_frame)
                .run_if(bevy::ecs::schedule::common_conditions::on_message::<Event>),
        );
        app.add_systems(
            Update,
            finish_native_drag
                .after(track_native_drag)
                .before(super::mouse::mouse_up_trigger)
                .after(super::systems::window_moved_update_frame)
                .after(super::systems::window_resized_update_frame)
                .run_if(
                    bevy::ecs::schedule::common_conditions::on_message::<Event>
                        .or_eager(|dragged: Query<(), With<NativeColumnDrag>>| !dragged.is_empty()),
                ),
        );
    }
}

#[derive(Component, Clone)]
pub(crate) struct DragCandidate {
    strip: Entity,
    signature: Vec<Vec<Entity>>,
    centers: Vec<i32>,
    original: IRect,
    display_bounds: IRect,
    slot: usize,
    pointer_x: i32,
    cancelled: bool,
}

#[derive(Component)]
pub(crate) struct NativeColumnDrag {
    hold: Entity,
    candidate: DragCandidate,
}

fn signature(strip: &LayoutStrip) -> Vec<Vec<Entity>> {
    strip
        .columns()
        .map(|column| {
            let mut members = column.window_iter().collect::<Vec<_>>();
            members.sort_unstable();
            members
        })
        .collect()
}

/// Only the native header band, excluding the outer resize edges. Actual
/// unchanged-size `WindowMoved` traffic is still required before taking ownership.
fn title_bar_start(frame: IRect, point: Origin) -> bool {
    point.x >= frame.min.x + 8
        && point.x < frame.max.x - 8
        && point.y >= frame.min.y + 6
        && point.y < frame.min.y + 32
}

pub(super) fn capture(
    owner: Entity,
    strip_entity: Entity,
    strip: &LayoutStrip,
    windows: &Windows,
    point: Origin,
    display_bounds: IRect,
) -> Option<DragCandidate> {
    let (_, _, unmanaged) = windows.get_managed(owner)?;
    if unmanaged.is_some() {
        return None;
    }
    let original = windows.get(owner)?.frame();
    if windows.moving_frame(owner)? != windows.frame(owner)? {
        return None;
    }
    if !title_bar_start(original, point) {
        return None;
    }
    let slot = strip.index_of(owner).ok()?;
    let centers = strip
        .columns()
        .enumerate()
        .filter(|(index, _)| *index != slot)
        .map(|(_, column)| {
            let representative = strip.selected_tab(column).or_else(|| column.top())?;
            Some(visible_drop_center(
                windows.frame(representative)?,
                display_bounds,
            ))
        })
        .collect::<Option<Vec<_>>>()?;
    Some(DragCandidate {
        strip: strip_entity,
        signature: signature(strip),
        centers,
        original,
        display_bounds,
        slot,
        pointer_x: point.x,
        cancelled: false,
    })
}

/// Reachable drop zone for a clipped neighbor. Fully hidden columns keep their
/// offscreen threshold: this first pass does not synthesize edge autoscrolling.
pub(crate) fn visible_drop_center(frame: IRect, bounds: IRect) -> i32 {
    let left = frame.min.x.max(bounds.min.x);
    let right = frame.max.x.min(bounds.max.x);
    if left >= right {
        return frame.center().x;
    }
    (left + (right - left) / 2).clamp(bounds.min.x + 24, bounds.max.x - 24)
}

/// Cross a visible neighbor's drop zone with the pointer. Snapshot centers never
/// chase the dragged window, so hovering near a boundary cannot oscillate.
fn insertion_slot(mut slot: usize, center: i32, centers: &[i32]) -> usize {
    while slot < centers.len() && center > centers[slot].saturating_add(16) {
        slot += 1;
    }
    while slot > 0 && center < centers[slot - 1].saturating_sub(16) {
        slot -= 1;
    }
    slot
}

#[allow(clippy::type_complexity)]
fn track_native_drag(
    mut events: MessageReader<Event>,
    mut candidates: Query<(
        Entity,
        &MouseHeldMarker,
        &mut DragCandidate,
        Has<MouseDraggingMarker>,
    )>,
    mut windows: Query<(
        &mut Window,
        &mut Position,
        Option<&Unmanaged>,
        Has<NativeMouseResize>,
    )>,
    config: Res<Config>,
    mut commands: Commands,
) {
    for event in events.read() {
        if matches!(
            event,
            Event::CancelKeyboardFocusHandoff
                | Event::MissionControlShowAllWindows
                | Event::MissionControlShowFrontWindows
                | Event::MissionControlShowDesktop
        ) {
            for (_, _, mut candidate, _) in &mut candidates {
                candidate.cancelled = true;
            }
        }
        if let Event::MouseDragged { point, .. } = event {
            for (_, _, mut candidate, _) in &mut candidates {
                candidate.pointer_x = crate::manager::origin_from(*point).x;
            }
        }
        let Event::WindowMoved { window_id } = event else {
            if let Event::WindowResized { window_id } = event {
                for (_, held, mut candidate, _) in &mut candidates {
                    if windows
                        .get(held.0)
                        .is_ok_and(|(window, _, _, _)| window.id() == *window_id)
                    {
                        candidate.cancelled = true;
                    }
                }
            }
            continue;
        };
        for (hold, held, mut candidate, dragging) in &mut candidates {
            if !dragging || candidate.cancelled || !config.drag_reorder() {
                continue;
            }
            let Ok((mut window, mut position, unmanaged, resizing)) = windows.get_mut(held.0)
            else {
                continue;
            };
            if window.id() != *window_id {
                continue;
            }
            if unmanaged.is_some() || resizing {
                candidate.cancelled = true;
                continue;
            }
            let Ok(frame) = window.update_frame() else {
                candidate.cancelled = true;
                continue;
            };
            if frame.size().chebyshev_distance(candidate.original.size()) > 1 {
                candidate.cancelled = true;
                continue;
            }
            if frame.min.chebyshev_distance(candidate.original.min) < 5 {
                continue;
            }
            candidate.slot =
                insertion_slot(candidate.slot, candidate.pointer_x, &candidate.centers);
            position.0 = frame.min;
            commands
                .entity(held.0)
                .remove::<(RepositionMarker, ResizeMarker)>()
                .insert(NativeColumnDrag {
                    hold,
                    candidate: candidate.clone(),
                });
        }
    }
}

type DraggedWindows<'w, 's> = Query<
    'w,
    's,
    (
        Entity,
        &'static NativeColumnDrag,
        &'static mut Window,
        Has<NativeMouseResize>,
        Option<&'static Unmanaged>,
    ),
>;

#[allow(clippy::too_many_arguments)]
fn finish_native_drag(
    mut events: MessageReader<Event>,
    mut dragged: DraggedWindows,
    mut held: Query<&mut DragCandidate>,
    mut strips: Query<(Entity, &mut LayoutStrip, Has<ActiveWorkspaceMarker>)>,
    displays: Query<&crate::manager::Display, With<crate::ecs::ActiveDisplayMarker>>,
    mission: Option<Res<crate::ecs::MissionControlActive>>,
    config: Res<Config>,
    mut commands: Commands,
) {
    let mut release = None;
    let mut cancelled = false;
    for event in events.read() {
        match event {
            Event::MouseUp { point, .. } => release = Some(crate::manager::origin_from(*point)),
            Event::CancelKeyboardFocusHandoff
            | Event::MissionControlShowAllWindows
            | Event::MissionControlShowFrontWindows
            | Event::MissionControlShowDesktop => cancelled = true,
            Event::MouseDown { .. } => release = None,
            _ => {}
        }
    }
    for (owner, drag, mut window, resizing, unmanaged) in &mut dragged {
        let valid_hold = held.get(drag.hold).ok();
        let valid_strip = strips
            .get(drag.candidate.strip)
            .is_ok_and(|(_, strip, selected)| {
                selected && signature(strip) == drag.candidate.signature
            });
        // One release-time AX read catches a late resize/move notification;
        // there is no native geometry polling while the pointer is stationary.
        let final_frame = if release.is_some() {
            window.update_frame().ok()
        } else {
            Some(window.frame())
        };
        let abort = cancelled
            || !config.drag_reorder()
            || mission.as_ref().is_some_and(|mission| mission.0)
            || !valid_strip
            || valid_hold.is_none_or(|candidate| candidate.cancelled)
            || resizing
            || unmanaged.is_some()
            || final_frame.is_none_or(|frame| {
                frame
                    .size()
                    .chebyshev_distance(drag.candidate.original.size())
                    > 1
            })
            || displays.single().map_or(true, |display| {
                display.bounds() != drag.candidate.display_bounds
            });
        if release.is_none() && !abort {
            continue;
        }
        tracing::debug!(
            ?owner,
            slot = drag.candidate.slot,
            abort,
            valid_strip,
            cancelled,
            candidate_cancelled = valid_hold.is_some_and(|candidate| candidate.cancelled),
            resizing,
            size_changed = window
                .frame()
                .size()
                .chebyshev_distance(drag.candidate.original.size())
                > 1,
            ?release,
            "finishing native column drag"
        );
        if !abort
            && release.is_some_and(|point| drag.candidate.display_bounds.contains(point))
            && let Ok((_, mut strip, _)) = strips.get_mut(drag.candidate.strip)
            && final_frame.is_some()
        {
            let slot = insertion_slot(
                drag.candidate.slot,
                release.expect("release checked above").x,
                &drag.candidate.centers,
            );
            let _ = strip.move_column(owner, slot);
        }
        if abort && let Ok(mut candidate) = held.get_mut(drag.hold) {
            candidate.cancelled = true;
        }
        commands.entity(owner).remove::<NativeColumnDrag>();
        if let Ok((_, mut strip, _)) = strips.get_mut(drag.candidate.strip) {
            strip.set_changed();
        }
        commands.reshuffle_around(owner);
    }
}

/// Acknowledgment follows live-world validation and the model mutation. Geometry
/// settles through the same ordered reveal/focus pathway as explicit navigation.
fn apply_helper_drop(
    mut events: MessageReader<Event>,
    windows: Windows,
    mut strips: Query<(&mut LayoutStrip, Has<ActiveWorkspaceMarker>), Without<Window>>,
    busy: Query<(), With<NativeColumnDrag>>,
    mut commands: Commands,
) {
    use crate::types::wire::Response;
    for event in events.read() {
        let Event::LayoutDrop { drop, respond_to } = event else {
            continue;
        };
        let result = (|| {
            if !busy.is_empty() {
                return Err("native drag is still active".to_string());
            }
            let source = windows
                .find(drop.source)
                .map(|(_, e)| e)
                .ok_or("source window is gone")?;
            let target = windows
                .find(drop.target)
                .map(|(_, e)| e)
                .ok_or("target window is gone")?;
            if [source, target].into_iter().any(|e| {
                windows
                    .get_managed(e)
                    .is_none_or(|(_, _, unmanaged)| unmanaged.is_some())
            }) {
                return Err("source and target must be tiled".into());
            }
            let (mut strip, _) = strips
                .iter_mut()
                .find(|(s, active)| {
                    *active
                        && s.id() == drop.native_workspace
                        && s.virtual_index + 1 == drop.row
                        && s.contains(source)
                        && s.contains(target)
                })
                .ok_or("source or target changed workspace")?;
            strip.apply_drop(source, target, drop.kind, drop.side)?;
            commands.entity(source).insert(super::FocusedMarker);
            commands.reshuffle_around(source);
            commands.trigger(super::focus::KeyboardFocusRequest {
                target: source,
                source: windows.focused().map(|(_, e)| e),
                row_switch: false,
            });
            Ok(())
        })();
        let response = match result {
            Ok(()) => Response::LayoutDrop,
            Err(e) => Response::Error(e),
        };
        let _ = respond_to.try_send(response);
    }
}

type RowDropStrips<'w, 's> = Query<
    'w,
    's,
    (
        Entity,
        &'static mut LayoutStrip,
        &'static ChildOf,
        Option<&'static mut super::workspace::PreviousStripPosition>,
        &'static mut Position,
        Has<ActiveWorkspaceMarker>,
    ),
    Without<Window>,
>;

struct PreparedRowDrop {
    source: Entity,
    source_strip: Entity,
    target_strip: Entity,
    column: LayoutStrip,
    members: Vec<Entity>,
    anchor: Option<(crate::types::wire::DropSide, Entity)>,
    replacement: Option<Entity>,
    focused: Option<Entity>,
}

fn prepare_row_drop(
    drop: &crate::types::wire::RowDrop,
    windows: &Windows,
    strips: &RowDropStrips,
    display: (Entity, u32),
    busy: bool,
) -> std::result::Result<Option<PreparedRowDrop>, String> {
    if busy {
        return Err("native drag is still active".to_string());
    }
    if display.1 != drop.display {
        return Err("active display changed".into());
    }
    let Some((active_strip, active_parent)) = strips
        .iter()
        .find_map(|(_, s, parent, _, _, active)| active.then_some((s.id(), parent.parent())))
    else {
        return Err("no active workspace".into());
    };
    if active_strip != drop.native_workspace || active_parent != display.0 {
        return Err("active native workspace changed".into());
    }
    let source = windows
        .find(drop.source)
        .map(|(_, e)| e)
        .ok_or("source window is gone")?;
    if windows
        .get_managed(source)
        .is_none_or(|(_, _, u)| u.is_some())
    {
        return Err("source must be tiled".into());
    }
    let locate = |row| {
        strips.iter().find_map(|(e, s, parent, _, _, _)| {
            (s.id() == drop.native_workspace
                && s.virtual_index + 1 == row
                && parent.parent() == active_parent)
                .then_some(e)
        })
    };
    let source_strip = locate(drop.source_row).ok_or("source row is gone")?;
    let target_strip = locate(drop.target_row).ok_or("target row is gone")?;
    let source_layout = &strips
        .get(source_strip)
        .map_err(|_| "source row is gone")?
        .1;
    let column = source_layout
        .column_strip(source)
        .ok_or("source changed row")?;
    if matches!(
        column.first().map_err(|e| e.to_string())?,
        super::layout::Column::Fullscren(_)
    ) {
        return Err("fullscreen column cannot be moved".into());
    }
    let members = column.all_windows();
    if members
        .iter()
        .any(|e| windows.get_managed(*e).is_none_or(|(_, _, u)| u.is_some()))
    {
        return Err("column contains an unmanaged window".into());
    }
    let anchor = if let Some((side, id)) = drop.anchor {
        let e = windows
            .find(id)
            .map(|(_, e)| e)
            .ok_or("anchor window is gone")?;
        if !strips
            .get(target_strip)
            .map_err(|_| "target row is gone")?
            .1
            .contains(e)
        {
            return Err("anchor changed row".into());
        }
        Some((side, e))
    } else {
        None
    };
    // Self-column anchor is a valid no-op on the same row.
    if anchor.is_some_and(|(_, e)| members.contains(&e)) {
        return Ok(None);
    }
    let focused = windows.focused().map(|(_, e)| e);
    let replacement = source_layout
        .columns()
        .filter(|c| !c.window_iter().any(|e| members.contains(&e)))
        .find_map(|c| source_layout.selected_tab(c).or_else(|| c.top()));
    Ok(Some(PreparedRowDrop {
        source,
        source_strip,
        target_strip,
        column,
        members,
        anchor,
        replacement,
        focused,
    }))
}

fn apply_row_drop(
    mut events: MessageReader<Event>,
    windows: Windows,
    mut strips: RowDropStrips,
    display: Single<(Entity, &crate::manager::Display), With<super::ActiveDisplayMarker>>,
    busy: Query<(), With<NativeColumnDrag>>,
    mut handoff: Option<ResMut<super::focus::KeyboardFocusHandoff>>,
    mut commands: Commands,
) {
    use crate::types::wire::{DropSide, Response};
    for event in events.read() {
        let Event::RowDrop { drop, respond_to } = event else {
            continue;
        };
        let result = (|| {
            let Some(PreparedRowDrop {
                source,
                source_strip,
                target_strip,
                mut column,
                members,
                anchor,
                replacement,
                focused,
            }) = prepare_row_drop(
                drop,
                &windows,
                &strips,
                (display.0, display.1.id()),
                !busy.is_empty(),
            )?
            else {
                return Ok(());
            };
            let (_, mut source_layout, _, previous, _, source_active) = strips
                .get_mut(source_strip)
                .map_err(|_| "source row is gone")?;
            for e in &members {
                source_layout.remove(*e);
            }
            if source_strip != target_strip
                && let Some(mut previous) = previous
                && previous.focus.is_some_and(|e| members.contains(&e))
            {
                previous.focus = replacement;
            }
            let (_, mut target_layout, _, previous, mut position, target_active) =
                strips.get_mut(target_strip).expect("validated target row");
            let slot = anchor.map_or(target_layout.len(), |(side, e)| {
                target_layout
                    .index_of(e)
                    .expect("validated anchor survives extraction")
                    + usize::from(side == DropSide::After)
            });
            target_layout.append_strip(&mut column);
            target_layout
                .move_column(source, slot)
                .expect("transferred column exists");
            if let Some(mut previous) = previous
                && previous.focus.is_none()
            {
                previous.focus = Some(source);
            }
            position.set_changed();
            if source_strip != target_strip {
                if let Some(ref mut handoff) = handoff {
                    handoff.cancel_target_in(&members);
                }
                if source_active && !target_active && focused.is_some_and(|e| members.contains(&e))
                {
                    for e in &members {
                        commands.entity(*e).remove::<super::FocusedMarker>();
                    }
                    if let Some(replacement) = replacement {
                        commands.focus_entity(replacement, false);
                    }
                }
            }
            // No focus request for incoming or inactive rows; keep the current row.
            Ok(())
        })();
        let _ = respond_to.try_send(match result {
            Ok(()) => Response::LayoutDrop,
            Err(e) => Response::Error(e),
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn insertion_is_stable_inside_midpoint_dead_band() {
        assert_eq!(insertion_slot(0, 300, &[300, 700]), 0);
        assert_eq!(insertion_slot(0, 317, &[300, 700]), 1);
        assert_eq!(insertion_slot(1, 290, &[300, 700]), 1);
        assert_eq!(insertion_slot(1, 283, &[300, 700]), 0);
        assert_eq!(insertion_slot(0, 900, &[300, 700]), 2);
    }
    #[test]
    fn header_band_excludes_content_and_resize_edges() {
        let frame = IRect::new(0, 20, 400, 600);
        assert!(title_bar_start(frame, Origin::new(100, 36)));
        assert!(!title_bar_start(frame, Origin::new(100, 100)));
        assert!(!title_bar_start(frame, Origin::new(2, 36)));
        assert!(!title_bar_start(frame, Origin::new(100, 22)));
    }
}
