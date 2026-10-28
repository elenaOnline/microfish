use bevy::app::{App, Plugin, PostUpdate, PreUpdate, Update};
use bevy::ecs::change_detection::{DetectChanges as _, DetectChangesMut, Ref};
use bevy::ecs::component::Component;
use bevy::ecs::entity::Entity;
use bevy::ecs::hierarchy::ChildOf;
use bevy::ecs::lifecycle::Add;
use bevy::ecs::message::MessageReader;
use bevy::ecs::observer::On;
use bevy::ecs::query::{Added, Has, With, Without};
use bevy::ecs::schedule::IntoScheduleConfigs as _;
use bevy::ecs::schedule::common_conditions::{not, resource_exists};
use bevy::ecs::system::{Commands, Local, ParamSet, Populated, Query, Res, ResMut, Single};
use bevy::ecs::world::World;
use bevy::prelude::{Changed, Or};
use bevy::time::common_conditions::on_timer;
use std::collections::HashSet;
use std::time::Duration;
use tracing::{Level, debug, error, info, instrument, warn};

use super::{ActiveDisplayMarker, SpawnWindowTrigger};
use crate::commands::{
    Direction, MoveFocus, Operation, filter_window_operations, focus_row_with_verification,
    get_window_in_direction,
};
use crate::config::Config;
use crate::ecs::focus::{FocusHistory, KeyboardFocusHandoff, KeyboardHold};
use crate::ecs::layout::{LayoutStrip, PARKED_STRIP_SLIVER, origin_exposing};
use crate::ecs::params::{ActiveDisplay, WindowCtx, Windows};
use crate::ecs::{
    ActiveWorkspaceMarker, DockPosition, FocusedMarker, Initializing, ManualStripOffset,
    NativeFullscreenMarker, Position, RaiseWindow, RepositionMarker, Scrolling,
    SelectedVirtualMarker, SendMessageTrigger, SpawnCommandsExt, Timeout, Unmanaged,
};
use crate::errors::Result;
use crate::events::{DestroySource, Event};
use crate::manager::{Application, Display, Origin, Window, WindowManager};
use crate::platform::{WinID, WorkspaceId};

pub struct WorkspaceEventsPlugin;

/// The strip, its origin, whether it's visible, and its saved position, as
/// [`handle_virtual_window_moves`] needs them to slide a strip to/from its
/// parked position.
type MovableStrips<'w, 's> = Query<
    'w,
    's,
    (
        Entity,
        &'static mut LayoutStrip,
        &'static mut Position,
        Has<ActiveWorkspaceMarker>,
        Option<&'static mut PreviousStripPosition>,
    ),
    Without<Window>,
>;

/// The saved origin and any in-flight `RepositionMarker`, as
/// [`show_active_workspace`] needs them to restore a strip.
type RestorableStrips<'w, 's> = Query<
    'w,
    's,
    (
        Entity,
        &'static mut Position,
        &'static LayoutStrip,
        &'static ChildOf,
        Option<&'static PreviousStripPosition>,
        Option<&'static RepositionMarker>,
    ),
    Without<Window>,
>;

/// `p0`: strips added this tick. `p1`: rewrites indexes of strips sharing
/// their workspace. Must be a `ParamSet` since `p1` aliases `p0` mutably.
type RenumberStrips<'w, 's> = ParamSet<
    'w,
    's,
    (
        Query<'static, 'static, &'static LayoutStrip, Added<LayoutStrip>>,
        Query<'static, 'static, (Entity, &'static mut LayoutStrip)>,
    ),
>;

impl Plugin for WorkspaceEventsPlugin {
    fn build(&self, app: &mut App) {
        const DISPLAY_CHANGE_CHECK_FREQ: Duration = Duration::from_secs(1);

        let reap_workspaces = |config: Option<Res<Config>>| {
            config.is_some_and(|config| config.reap_empty_workspaces())
        };

        app.add_systems(
            PreUpdate,
            (
                navigate_row_bind,
                switch_virtual_workspace_bind,
                move_virtual_workspace_bind,
            )
                .after(super::view_history::observe),
        );
        app.add_systems(
            PreUpdate,
            find_orphaned_workspaces
                .after(crate::ecs::display::reconcile_displays)
                .run_if(on_timer(DISPLAY_CHANGE_CHECK_FREQ)),
        );
        app.add_systems(
            Update,
            (
                renumber_virtual_indexes,
                reap_empty_virtual_workspaces
                    .after(super::layout::configure_tab_presentation)
                    .run_if(reap_workspaces)
                    .run_if(rows_need_reaping)
                    .run_if(not(resource_exists::<Initializing>)),
                workspace_change_handler,
                workspace_created_handler,
                show_active_workspace,
                handle_virtual_window_moves,
                detect_moved_windows.run_if(not(resource_exists::<Initializing>)),
            ),
        );
        app.add_systems(PostUpdate, workspace_destroyed_handler);
        app.add_observer(cleanup_active_workspace_marker)
            .add_observer(cleanup_selected_space_marker);
    }
}

/// Marker component to move a window to a specific virtual index on its current workspace.
#[derive(Component)]
pub(super) struct VirtualMoveMarker {
    pub target_virtual_index: u32,
    pub move_focus: MoveFocus,
    pub whole_column: bool,
}

#[derive(Component, Debug)]
pub(crate) struct PreviousStripPosition {
    pub origin: Origin,
    pub focus: Option<Entity>,
}

/// Guard spawned alongside the re-focus of a restored strip's remembered
/// window. The OS's focus acknowledgment arrives several ticks after the
/// strip was already placed at its saved origin, so without this guard
/// `autocenter_window_on_focus` and `window_focused_trigger`'s reshuffle would
/// slide the strip away again (a visible wiggle on every switch); both skip
/// the named entity while this marker exists. It is despawned once focus
/// moves elsewhere, or expires via `timeout_ticker`.
#[derive(Component, Debug)]
pub(crate) struct RestoreFocusMarker {
    pub entity: Entity,
}

/// Long enough for the OS focus acknowledgments to arrive, short enough that
/// a user re-clicking the restored window soon after the switch gets the
/// normal expose-reshuffle back.
const RESTORE_FOCUS_GUARD_TIMEOUT: Duration = Duration::from_secs(2);

fn spawn_restore_focus_guard(entity: Entity, commands: &mut Commands) {
    let timeout = Timeout::new(RESTORE_FOCUS_GUARD_TIMEOUT, None, commands);
    commands.spawn((timeout, RestoreFocusMarker { entity }));
}

/// Guard spawned when `show_active_workspace` writes a restored strip's
/// `Position` directly (`virtual_workspace_animations = false`). That write
/// only fixes the strip's own aggregate offset instantly; individual member
/// windows still get re-evaluated by `position_layout_windows` on a
/// following tick (via `position_layout_strips` reacting to the strip's now
/// -`Changed<Position>`), using whatever `Position` they were last left at —
/// which, for a lower stack member parked while its strip was hidden, can
/// land close enough to its restored target that neither the "offscreen
/// distance" nor the "parked at the corner" heuristic recognizes it as a
/// restore-driven move. Left to the ordinary heuristic, that move animates,
/// riding along even though the strip itself just snapped. While a live
/// guard names a strip, `position_layout_windows` snaps every member
/// window directly, bypassing that heuristic entirely. Expires via
/// `timeout_ticker` like `RestoreFocusMarker`.
#[derive(Component, Debug)]
pub(crate) struct SnapStripMarker {
    pub strip: Entity,
}

/// Long enough for the settle described above to actually finish (it can
/// take more than one tick), short enough that an ordinary layout change
/// shortly after a switch still animates normally.
const SNAP_STRIP_GUARD_TIMEOUT: Duration = Duration::from_millis(500);

fn spawn_snap_strip_guard(strip: Entity, commands: &mut Commands) {
    let timeout = Timeout::new(SNAP_STRIP_GUARD_TIMEOUT, None, commands);
    commands.spawn((timeout, SnapStripMarker { strip }));
}

fn fullscreen_window_in_strip(
    workspace_id: WorkspaceId,
    strip: &LayoutStrip,
    windows: &Windows,
    window_manager: &WindowManager,
) -> Option<Entity> {
    window_manager
        .windows_in_workspace(workspace_id)
        .ok()
        .and_then(|window_ids| {
            window_ids.into_iter().find_map(|window_id| {
                windows
                    .find_managed(window_id)
                    .map(|(_, entity)| entity)
                    .filter(|entity| strip.contains(*entity))
            })
        })
        .or_else(|| {
            windows.managed_iter().find_map(|(window, entity, _)| {
                (strip.contains(entity) && window.is_full_screen()).then_some(entity)
            })
        })
        .or_else(|| {
            windows
                .focused()
                .map(|(_, entity)| entity)
                .filter(|entity| strip.contains(*entity))
        })
}

#[instrument(level = Level::DEBUG, skip_all, fields(trigger))]
fn workspace_change_handler(
    mut messages: MessageReader<Event>,
    windows: Windows,
    mut workspaces: Query<(
        &mut LayoutStrip,
        Entity,
        Has<ActiveWorkspaceMarker>,
        Has<SelectedVirtualMarker>,
    )>,
    active_display: Single<(&Display, Entity), With<ActiveDisplayMarker>>,
    window_manager: Res<WindowManager>,
    mut commands: Commands,
) {
    if !messages
        .read()
        .any(|event| matches!(event, Event::SpaceChanged))
    {
        return;
    }
    let (active_display, display_entity) = *active_display;

    let Ok(workspace_id) = window_manager.active_display_space(active_display.id()) else {
        error!("Unable to get active workspace id!");
        return;
    };

    let mut remove_from = None;
    let mut insert_into = None;
    for (strip, entity, active, selected) in &workspaces {
        if active && strip.id() == workspace_id {
            debug!("Workspace id {} already active", strip.id());
            return;
        }
        if active && strip.id() != workspace_id {
            debug!("Workspace id {} no longer active", strip.id());
            remove_from = Some(entity);
        }
        if !active && strip.id() == workspace_id && selected {
            debug!("Workspace id {} is active", strip.id());
            insert_into = Some(entity);
        }
    }

    if insert_into.is_none() {
        // Fallback: find any strip for this workspace, preferably the one with virtual_index 0.
        insert_into = workspaces
            .iter()
            .filter(|(strip, _, _, _)| strip.id() == workspace_id)
            .min_by_key(|(strip, _, _, _)| strip.virtual_index)
            .map(|(_, entity, _, _)| entity);
    }

    if insert_into.is_none()
        && let Some(old_space) = remove_from
        && window_manager.is_fullscreen_space(active_display.id())
        && let Ok((mut old_strip, old_strip_entity, _, _)) = workspaces.get_mut(old_space)
        && let Some(fullscreen_window) =
            fullscreen_window_in_strip(workspace_id, &old_strip, &windows, &window_manager)
        && let Ok(original_index) = old_strip.index_of(fullscreen_window)
    {
        debug!("workspace_change: space={workspace_id} fullscreen");

        let fullscreen_marker = NativeFullscreenMarker {
            layout_strip: old_strip_entity,
            workspace_id: old_strip.id(),
            index: original_index,
        };
        old_strip.remove(fullscreen_window);

        let fullscreen_strip = LayoutStrip::fullscreen(workspace_id, fullscreen_window);
        let entity = commands
            .spawn((
                Position(active_display.bounds().min),
                fullscreen_marker,
                fullscreen_strip,
                ChildOf(display_entity),
            ))
            .id();
        insert_into = Some(entity);
    }

    if let Some(into) = insert_into
        && let Ok(mut entity_commands) = commands.get_entity(into)
    {
        entity_commands.try_insert(ActiveWorkspaceMarker);
    }
}

#[instrument(level = Level::DEBUG, skip_all, fields(trigger))]
fn detect_moved_windows(
    activated_workspace: Single<Entity, Added<ActiveWorkspaceMarker>>,
    mut workspaces: Query<(&mut LayoutStrip, Entity, Has<NativeFullscreenMarker>)>,
    apps: Query<&mut Application>,
    window_manager: Res<WindowManager>,
    mut ignored_windows: Local<HashSet<WinID>>,
    mut ctx: WindowCtx,
) {
    let Ok(workspace_id) = workspaces
        .get(*activated_workspace)
        .map(|strip| strip.0.id())
    else {
        return;
    };
    debug!("workspace {workspace_id}");

    let strips = workspaces
        .iter()
        .filter_map(|strip| (strip.0.id() == workspace_id).then_some(strip.0))
        .collect::<Vec<_>>();
    let find_window = |window_id| {
        ctx.windows
            .find_managed(window_id)
            .map(|(_, entity)| entity)
    };
    let Ok((moved_windows, mut unresolved)) =
        windows_not_in_strips(workspace_id, find_window, &strips, &window_manager).inspect_err(
            |err| {
                warn!("unable to get windows in the current workspace: {err}");
            },
        )
    else {
        return;
    };
    // Skip known, but unmanaged windows.
    unresolved.retain(|window_id| {
        !ignored_windows.contains(window_id) && ctx.windows.find(*window_id).is_none()
    });

    if !unresolved.is_empty() {
        let unresolved_ids = unresolved.iter().copied().collect::<HashSet<_>>();
        // Retry unresolved window IDs: during startup bruteforce, windows on
        // inactive workspaces may have stale AX attributes (e.g. AXGroup instead
        // of AXWindow).  Now that this workspace is active, re-query each app's
        // window list — the AX data should be correct.
        let retry_windows = apps
            .into_iter()
            .flat_map(|app| {
                app.window_list(&ctx.config)
                    .into_iter()
                    .filter(|window| unresolved_ids.contains(&window.id()))
            })
            .collect::<Vec<_>>();
        if retry_windows.is_empty() {
            for id in unresolved_ids {
                ignored_windows.insert(id);
            }
        } else {
            debug!(
                "retrying unresolved windows: {}",
                retry_windows
                    .iter()
                    .map(|window| format!("{}", window.id()))
                    .collect::<Vec<_>>()
                    .join(" ")
            );
            ctx.commands.trigger(SpawnWindowTrigger(retry_windows));
        }
    }

    for entity in moved_windows {
        if workspaces
            .iter()
            .any(|(strip, _, fullscreen)| fullscreen && strip.contains(entity))
        {
            // Do not relocate fullscreen windows, this will happen
            // during the destructino of their workspace.
            continue;
        }

        debug!("Window {entity} moved to workspace {workspace_id}.");
        let moving_entities = workspaces
            .iter()
            .find_map(|(strip, _, _)| strip.tab_group(entity))
            .unwrap_or_else(|| vec![entity]);
        for (mut strip, strip_entity, _) in &mut workspaces {
            if strip_entity == *activated_workspace {
                strip.append_tab_group(&moving_entities);
            } else {
                for moving_entity in &moving_entities {
                    strip.remove(*moving_entity);
                }
            }
        }
    }
}

#[instrument(level = Level::DEBUG, skip_all, fields(trigger))]
fn workspace_destroyed_handler(
    mut messages: MessageReader<Event>,
    mut workspaces: Populated<(&mut LayoutStrip, Entity, Option<&NativeFullscreenMarker>)>,
    mut focus_history: ResMut<FocusHistory>,
    mut commands: Commands,
) {
    for event in messages.read() {
        let Event::SpaceDestroyed { space_id } = event else {
            continue;
        };
        focus_history.forget_workspace(*space_id);

        let Some((entity, fullscreen)) =
            workspaces.iter().find_map(|(strip, entity, fullscreen)| {
                let window = strip.first().ok().and_then(|col| col.top());
                (strip.id() == *space_id).then_some((entity, window.zip(fullscreen.cloned())))
            })
        else {
            continue;
        };

        if let Some((
            window,
            NativeFullscreenMarker {
                layout_strip,
                workspace_id,
                index,
            },
        )) = fullscreen
        {
            let mut strip = workspaces
                .iter_mut()
                .find_map(|(strip, entity, _)| (entity == layout_strip).then_some(strip));
            if strip.is_none() {
                strip = workspaces
                    .iter_mut()
                    .find_map(|(strip, _, _)| (strip.id() == workspace_id).then_some(strip));
            }

            debug!(
                "previously fullscreened window {entity} inserted at {}",
                index
            );
            if let Some(mut strip) = strip {
                strip.insert_at(index, window);
                commands.reshuffle_around(window);
            }
        }

        if let Ok(mut entity_commands) = commands.get_entity(entity) {
            debug!("Workspace destroyed {space_id} {entity}");
            entity_commands.try_despawn();
        }
    }
}

#[instrument(level = Level::DEBUG, skip_all, fields(trigger))]
fn workspace_created_handler(
    mut messages: MessageReader<Event>,
    active_display: Single<(&Display, Entity), With<ActiveDisplayMarker>>,
    workspaces: Query<&LayoutStrip>,
    mut commands: Commands,
) {
    for event in messages.read() {
        let Event::SpaceCreated { space_id } = event else {
            continue;
        };

        if workspaces.into_iter().any(|strip| strip.id() == *space_id) {
            warn!("Workspace {space_id} already exists!");
            continue;
        }
        debug!("Workspace create {space_id}");
        let (active_display, display_entity) = *active_display;
        let strip = LayoutStrip::new(*space_id, 0);
        let origin = active_display.bounds().min;
        commands.spawn_layout_strip(strip, origin, display_entity, false);
    }
}

fn windows_not_in_strips<F: Fn(WinID) -> Option<Entity>>(
    workspace_id: WorkspaceId,
    find_window: F,
    strips: &[&LayoutStrip],
    window_manager: &WindowManager,
) -> Result<(Vec<Entity>, Vec<WinID>)> {
    window_manager
        .windows_in_workspace(workspace_id)
        .map(|ids| {
            let mut moved = Vec::new();
            let mut unresolved = Vec::new();
            for id in ids {
                if let Some(entity) = find_window(id) {
                    // If window exists in any of the active workspace rows.
                    if strips.iter().any(|strip| strip.contains(entity)) {
                        continue;
                    }
                    moved.push(entity);
                } else {
                    unresolved.push(id);
                }
            }
            (moved, unresolved)
        })
}

#[instrument(level = Level::DEBUG, skip_all)]
fn find_orphaned_workspaces(
    orphans: Populated<(&LayoutStrip, Entity, &Timeout, Option<&ChildOf>), With<Timeout>>,
    displays: Populated<(&Display, Entity)>,
    window_manager: Res<WindowManager>,
    mut commands: Commands,
) {
    let present = window_manager.present_displays();
    let mut rehomed = false;

    for (orphan, orphan_entity, timeout, child) in orphans {
        // Row 0 is the row every space is created with, so it is re-parented
        // like a populated strip: despawning it leaves the space numbered from
        // "2" with no row that any switch or reap path recreates.
        if orphan.len() == 0 && orphan.virtual_index > 0 {
            if let Ok(mut cmd) = commands.get_entity(orphan_entity) {
                cmd.try_despawn();
            }
            debug!("despawning empty orphan workspace {}", orphan.id());
            continue;
        }
        if child.is_some() {
            // Was reparented, remove timer.
            if let Ok(mut cmd) = commands.get_entity(orphan_entity) {
                cmd.try_remove::<Timeout>();
            }
            debug!(
                "layout strip {} was re-parented, removing timeout.",
                orphan.id()
            );
            continue;
        }

        if timeout.timer.is_finished() {
            // Rescue windows from orphaned strips before despawning by floating them.
            debug!("Rescue windows from timed out orphan {}.", orphan.id());
            for lost_window in orphan.all_windows() {
                if let Ok(mut cmd) = commands.get_entity(lost_window) {
                    cmd.try_insert(Unmanaged::Floating);
                }
            }
            continue;
        }

        // Find which display now owns this space ID.
        let target = present.iter().find_map(|(present_display, spaces)| {
            if spaces.iter().any(|&id| id == orphan.id()) {
                displays
                    .iter()
                    .find(|(d, _)| d.id() == present_display.id())
            } else {
                None
            }
        });
        let Some((target_display, target_entity)) = target else {
            continue; // No display owns this space yet; wait for next tick.
        };

        debug!(
            "Re-parenting orphaned strip {} to display {}",
            orphan.id(),
            target_display.id(),
        );

        if let Ok(mut cmd) = commands.get_entity(orphan_entity) {
            cmd.try_remove::<Timeout>().insert(ChildOf(target_entity));
            commands.queue(move |world: &mut World| {
                crate::ecs::display::refresh_reparented_strip(world, orphan_entity);
            });
            rehomed = true;
        }
    }
    if rehomed {
        commands.trigger(SendMessageTrigger(Event::DisplayChanged));
    }
}

#[allow(clippy::needless_pass_by_value)]
pub(crate) fn cleanup_unordered_windows(
    windows: Query<&Window>,
    workspaces: Query<&LayoutStrip>,
    window_manager: Res<WindowManager>,
    mut commands: Commands,
) {
    let windows = workspaces
        .iter()
        .flat_map(|strip| {
            strip
                .all_windows()
                .into_iter()
                .filter(|entity| !strip.tabbed(*entity))
        })
        .filter_map(|entity| windows.get(entity).ok());

    for window in windows {
        let window_id = window.id();
        if window_manager.window_is_unordered(window_id) && window.role().is_err() {
            debug!("Window {window_id} is unordered; removing it.");
            commands.trigger(SendMessageTrigger(Event::WindowDestroyed {
                window_id,
                source: DestroySource::Accessibility,
            }));
        }
    }
}

/// Removes previuos `ActiveWorkspaceMarker`'s when a new one is inserted.
#[instrument(level = Level::DEBUG, skip_all, fields(trigger))]
fn cleanup_active_workspace_marker(
    trigger: On<Add, ActiveWorkspaceMarker>,
    workspaces: Query<(Entity, Has<ActiveWorkspaceMarker>), With<LayoutStrip>>,
    mut commands: Commands,
) {
    workspaces.iter().for_each(|(entity, marker)| {
        if entity == trigger.entity
            && let Ok(mut entity_commands) = commands.get_entity(entity)
        {
            // Mark the currently selected VW with selected marker. This also removes the previously
            // selected markers from other VW's on the same workspace.
            entity_commands.try_insert(SelectedVirtualMarker);
        } else if marker && let Ok(mut entity_commands) = commands.get_entity(entity) {
            // Remove the active marker from any other workspace.
            entity_commands.try_remove::<ActiveWorkspaceMarker>();
        }
    });
}

/// Removes previuos `SelectedVirtualMarker`'s when a new one is inserted.
#[instrument(level = Level::DEBUG, skip_all, fields(trigger))]
fn cleanup_selected_space_marker(
    trigger: On<Add, SelectedVirtualMarker>,
    workspaces: Query<(Entity, &LayoutStrip, Has<SelectedVirtualMarker>)>,
    mut commands: Commands,
) {
    let Ok(workspace_id) = workspaces
        .get(trigger.entity)
        .map(|(_, strip, _)| strip.id())
    else {
        return;
    };

    // Remove the marker from other strips on the same workspace.
    workspaces.iter().for_each(|(entity, strip, marker)| {
        if marker
            && entity != trigger.entity
            && strip.id() == workspace_id
            && let Ok(mut entity_commands) = commands.get_entity(entity)
        {
            entity_commands.try_remove::<SelectedVirtualMarker>();
        }
    });
}

#[allow(clippy::too_many_lines)]
fn handle_virtual_window_moves(
    moved_windows: Populated<(Entity, &VirtualMoveMarker), With<Window>>,
    mut workspaces: MovableStrips,
    windows: Windows,
    mut scrollings: Query<&mut Scrolling>,
    active_display: Single<(Entity, &Display, Option<&DockPosition>), With<ActiveDisplayMarker>>,
    config: Res<Config>,
    mut commands: Commands,
) {
    let Some((workspace_id, source_entity)) = workspaces
        .iter()
        .find_map(|(entity, strip, _, active, _)| active.then_some((strip.id(), entity)))
    else {
        return;
    };

    let (display_entity, active_display, dock) = *active_display;
    let viewport = active_display.actual_display_bounds(dock, &config);
    for (window_entity, move_marker) in &moved_windows {
        let mut column = move_marker
            .whole_column
            .then(|| {
                workspaces
                    .get(source_entity)
                    .ok()?
                    .1
                    .column_strip(window_entity)
            })
            .flatten();
        let moving_entities = if let Some(column) = &column {
            column.all_windows()
        } else {
            workspaces
                .get(source_entity)
                .ok()
                .and_then(|(_, strip, _, _, _)| strip.tab_group(window_entity))
                .unwrap_or_else(|| vec![window_entity])
        };
        for moving_entity in &moving_entities {
            if let Ok(mut entity_commands) = commands.get_entity(*moving_entity) {
                entity_commands.try_remove::<VirtualMoveMarker>();
            }
        }
        let follow = matches!(move_marker.move_focus, MoveFocus::Follow);

        let target_idx = move_marker.target_virtual_index;
        let target = workspaces.iter().find_map(|(entity, strip, _, _, _)| {
            (strip.id() == workspace_id && strip.virtual_index == target_idx).then_some(entity)
        });

        // Must be captured before strip.remove below.
        let source_neighbour =
            workspaces
                .get(source_entity)
                .ok()
                .and_then(|(_, strip, _, _, _)| {
                    strip
                        .left_neighbour(window_entity)
                        .or_else(|| strip.right_neighbour(window_entity))
                });
        // If source will be empty after the move, Stay becomes Follow
        // since there's nothing left to look at.
        let stay = !follow && source_neighbour.is_some();

        // With `insert_windows_mid_strip`, the window keeps its current on-screen
        // x. For an existing destination, work out the column slot nearest that x
        // and the scroll offset that lands it there; for a new strip the lone
        // window just sits at that x.
        let moved_left = (!move_marker.whole_column && config.insert_windows_mid_strip())
            .then(|| windows.moving_frame(window_entity).map(|frame| frame.min.x))
            .flatten();
        let mid_placement = moved_left.and_then(|moved_left| {
            let (_, strip, position, _, previous) = workspaces.get(target?).ok()?;
            let scroll_x = previous.map_or(position.0.x, |previous| previous.origin.x);
            Some(mid_strip_slot(strip, scroll_x, moved_left, &windows))
        });

        let target_entity = if let Some(entity) = target {
            entity
        } else {
            // Stay: spawn offscreen with PreviousStripPosition for later restoration.
            // Follow (or empty source): spawn visible, user is switching to it.
            let visible_origin = viewport.min;
            // mid-strip: keep the lone window at its current x.
            let shown = Origin::new(moved_left.unwrap_or(visible_origin.x), visible_origin.y);
            let parked = viewport.max - PARKED_STRIP_SLIVER;
            let origin = if stay { parked } else { shown };
            debug!(
                "Creating new virtual row {target_idx} on workspace {}",
                workspace_id
            );
            let mut new_strip = LayoutStrip::new(workspace_id, target_idx);
            new_strip.append_tab_group(&moving_entities);

            let mut spawned = commands.spawn_layout_strip(new_strip, origin, display_entity, false);
            if stay {
                // show_active_workspace needs this to restore the strip
                // onscreen when the user later switches to this workspace.
                spawned.insert(PreviousStripPosition {
                    origin: shown,
                    focus: Some(window_entity),
                });
            }
            spawned.id()
        };

        // Preserve the source strip's scroll position for when the user returns.
        if !stay
            && let Ok(mut entity_commands) = commands.get_entity(source_entity)
            && let Ok((_, source_strip, position, _, _)) = workspaces.get(source_entity)
        {
            let focus = source_strip
                .left_neighbour(window_entity)
                .or_else(|| source_strip.right_neighbour(window_entity));
            entity_commands.try_insert(PreviousStripPosition {
                origin: position.0,
                focus,
            });
        }

        // Move the window before moving markers to avoid being detected as a moved window.
        for (entity, mut strip, _, _, _) in &mut workspaces {
            if entity == target_entity {
                match mid_placement {
                    Some((slot, _)) => strip.insert_tab_group_at(slot, &moving_entities),
                    None => {
                        if let Some(column) = &mut column {
                            strip.append_strip(column);
                        } else {
                            strip.append_tab_group(&moving_entities);
                        }
                    }
                }
            } else {
                for moving_entity in &moving_entities {
                    strip.remove(*moving_entity);
                }
            }
        }

        // Scroll the destination so the inserted window keeps its exact x. Done
        // before the strip is shown so show_active_workspace snaps every window
        // to its final spot in one go (no horizontal slide). Resetting Scrolling
        // stops stale momentum from overriding the offset on reactivation.
        if let Some((_, desired_scroll)) = mid_placement {
            if let Ok((_, _, _, _, Some(mut previous))) = workspaces.get_mut(target_entity) {
                previous.origin.x = desired_scroll;
            }
            if let Ok(mut scroll) = scrollings.get_mut(target_entity) {
                scroll.position = f64::from(desired_scroll);
                scroll.velocity = 0.0;
            }
        }

        // Insert new markers. ActiveWorkspaceMarker switches the view.
        if let Ok(mut entity_commands) = commands.get_entity(target_entity)
            && !stay
        {
            entity_commands.try_insert(ActiveWorkspaceMarker);
        }

        if stay && let Some(neighbour) = source_neighbour {
            // Layout chain repositions the window offscreen with its hidden strip.
            commands.focus_entity(neighbour, false);

            // Force position change on the hidden strip, so it hides the moved window.
            if let Ok(mut position) = workspaces
                .get_mut(target_entity)
                .map(|(_, _, pos, _, _)| pos)
            {
                position.set_changed();
            }
        } else {
            let previous_position = workspaces
                .get_mut(target_entity)
                .ok()
                .and_then(|(_, _, _, _, previos_pos)| previos_pos);
            if let Some(mut previous) = previous_position {
                previous.focus = Some(window_entity);
            }
            commands.reshuffle_around(window_entity);

            if mid_placement.is_none()
                && let Ok(mut entity_commands) = commands.get_entity(window_entity)
            {
                entity_commands.try_remove::<FocusedMarker>();
                commands.focus_entity(window_entity, false);
            }
        }
        debug!(
            "Moved window {} to virtual workspace {}",
            window_entity, target_idx
        );
    }
}

/// Picks where in `strip` a window currently at on-screen x `moved_left` should
/// be inserted so it keeps that position. Inserting at column `i` lands the
/// window at that column's left edge, so we choose the column boundary nearest
/// `moved_left`, then return the scroll offset that makes that slot sit exactly
/// at `moved_left`. `scroll_x` is the strip's (intended) scroll offset.
///
/// Returns `(insert_index, desired_scroll)`.
fn mid_strip_slot(
    strip: &LayoutStrip,
    scroll_x: i32,
    moved_left: i32,
    windows: &Windows,
) -> (usize, i32) {
    let columns: Vec<(i32, i32)> = strip
        .all_columns()
        .into_iter()
        .filter_map(|column| {
            let layout_x = windows.layout_position(column)?.0.x;
            let width = windows
                .moving_frame(column)
                .map_or(0, |frame| frame.width());
            Some((layout_x, width))
        })
        .collect();

    let mut index = columns.len();
    let mut chosen_layout_x = columns
        .last()
        .map_or(0, |(layout_x, width)| layout_x + width);
    let mut best = (chosen_layout_x + scroll_x - moved_left).abs();
    for (i, (layout_x, _)) in columns.iter().enumerate() {
        let dist = (layout_x + scroll_x - moved_left).abs();
        if dist < best {
            best = dist;
            index = i;
            chosen_layout_x = *layout_x;
        }
    }
    (index, moved_left - chosen_layout_x)
}

/// Explicit growable row navigation. An empty boundary row is the growth stop,
/// so repeating a held Up or Down key cannot allocate an unbounded sequence of rows.
///
/// Every press in the frame counts: key repeat on a busy frame delivers several
/// at once, and reading only the first silently dropped the rest. They are
/// replayed in order against a model of the rows, and only the row the last one
/// lands on is switched to, so no intermediate row is shown and focused.
#[instrument(level = Level::DEBUG, skip_all)]
fn navigate_row_bind(
    mut messages: MessageReader<Event>,
    active_display: ActiveDisplay,
    workspaces: Query<(Entity, &LayoutStrip, Has<ActiveWorkspaceMarker>)>,
    mut commands: Commands,
) {
    let directions = filter_window_operations(&mut messages, |op| matches!(op, Operation::Row(_)))
        .filter_map(|op| match op {
            Operation::Row(direction) => Some(direction.clone()),
            _ => None,
        })
        .collect::<Vec<_>>();
    if directions.is_empty() {
        return;
    }
    let mut rows = workspaces
        .iter()
        .filter(|(_, strip, _)| strip.id() == active_display.active_strip().id())
        .collect::<Vec<_>>();
    rows.sort_by_key(|(_, strip, _)| strip.virtual_index);
    let Some(current) = rows.iter().position(|(_, _, active)| *active) else {
        return;
    };
    let count = rows.len();
    let populated = |row: usize| rows[row].1.len() != 0;
    let last_index = rows.last().map_or(0, |(_, strip, _)| strip.virtual_index);

    // Slot 0 is a row that does not exist yet above the first, slot `count + 1`
    // one below the last, and slot `n + 1` is `rows[n]`. A row made on the way
    // and left again while empty is never created, as if already reaped.
    let (mut above, mut below) = (false, false);
    let mut slot = current + 1;
    for direction in &directions {
        let cap_allows = last_index + u32::from(above) + u32::from(below) < 8;
        match direction {
            Direction::North => {
                if slot > usize::from(!above) {
                    slot -= 1;
                } else if slot == 1 && populated(0) && cap_allows {
                    (above, slot) = (true, 0);
                }
            }
            Direction::South => {
                if slot < count + usize::from(below) {
                    slot += 1;
                } else if slot == count && populated(count - 1) && cap_allows {
                    (below, slot) = (true, count + 1);
                }
            }
            _ => {}
        }
    }

    if slot == 0 {
        let entities = rows
            .iter()
            .map(|(entity, _, _)| *entity)
            .collect::<Vec<_>>();
        // Keep strip identities, group membership and saved viewport/focus
        // components. Only their ordinal row labels change.
        commands.queue(move |world: &mut bevy::ecs::world::World| {
            for entity in entities {
                if let Some(mut strip) = world.get_mut::<LayoutStrip>(entity) {
                    strip.virtual_index += 1;
                }
            }
        });
        commands.spawn_layout_strip(
            LayoutStrip::new(active_display.active_strip().id(), 0),
            active_display.bounds().min,
            active_display.entity(),
            true,
        );
    } else if slot == count + 1 {
        commands.spawn_layout_strip(
            LayoutStrip::new(active_display.active_strip().id(), last_index + 1),
            active_display.bounds().min,
            active_display.entity(),
            true,
        );
    } else if slot - 1 != current
        && let Ok(mut entity_commands) = commands.get_entity(rows[slot - 1].0)
    {
        entity_commands.try_insert(ActiveWorkspaceMarker);
    }
}

/// Handles the keybinding for switching between virtual workspaces. Moving South
/// creates a new workspace if the current one is populated and auto-create is on.
#[allow(clippy::too_many_lines)]
#[instrument(level = Level::DEBUG, skip_all)]
fn switch_virtual_workspace_bind(
    mut messages: MessageReader<Event>,
    windows: Windows,
    active_display: ActiveDisplay,
    workspaces: Query<(Entity, &LayoutStrip, Has<ActiveWorkspaceMarker>)>,
    config: Res<Config>,
    mut commands: Commands,
) {
    let Some(operation) = filter_window_operations(&mut messages, |op| {
        matches!(
            op,
            Operation::Virtual(_)
                | Operation::VirtualNumber(_)
                | Operation::VirtualAdd
                | Operation::FocusOrVirtual(_)
        )
    })
    .next() else {
        return;
    };

    // `FocusOrVirtual` is a distinct command from `Operation::Virtual` on
    // purpose: `window_virtual_north/south` must keep meaning exactly
    // "switch the virtual workspace", unconditionally, for anyone who binds
    // it that way — this new command is for callers who explicitly want
    // "focus a stack neighbor above/below first, and only switch workspace
    // once there's nothing left to focus", the same within-column traversal
    // `window_focus_north/south` uses. Only North/South are meaningful here
    // (there's no "focus" reading of East/West/First/Last/Nth to pair with
    // a workspace switch); anything else is a no-op. Once the focus check
    // doesn't apply, this reduces to a plain `Operation::Virtual(direction)`
    // and falls through to the exact same switching logic below.
    let synthesized_virtual;
    let operation = match operation {
        Operation::FocusOrVirtual(direction @ (Direction::North | Direction::South)) => {
            if let Some((_, focused_entity)) = windows.focused()
                && let Some(target) = get_window_in_direction(
                    direction,
                    focused_entity,
                    active_display.active_strip(),
                )
            {
                commands.focus_entity(target, true);
                commands.reshuffle_around(target);
                return;
            }
            synthesized_virtual = Operation::Virtual(direction.clone());
            &synthesized_virtual
        }
        Operation::FocusOrVirtual(_) => return,
        operation => operation,
    };

    let workspace_id = active_display.active_strip().id();
    let mut rows = workspaces
        .iter()
        .filter(|(_, strip, _)| strip.id() == workspace_id)
        .collect::<Vec<_>>();

    if rows.is_empty() {
        return;
    }
    rows.sort_by_key(|(_, strip, _)| strip.virtual_index);

    let current_index = rows.iter().position(|(_, _, active)| *active).unwrap_or(0);
    let next_index = match operation {
        Operation::Virtual(Direction::South | Direction::East) => {
            if current_index + 1 < rows.len() {
                current_index + 1
            } else if active_display.active_strip().len() != 0
                && config.create_workspace_automatically()
            {
                let target_index = rows[current_index].1.virtual_index + 1;
                commands.spawn_layout_strip(
                    LayoutStrip::new(workspace_id, target_index),
                    active_display.bounds().min,
                    active_display.entity(),
                    true,
                );
                if config.workspace_popup_status() {
                    commands.flash_message(format!("{}", target_index + 1), 1.0);
                }
                return;
            } else {
                current_index
            }
        }
        Operation::Virtual(Direction::North | Direction::West) => current_index.saturating_sub(1),
        Operation::Virtual(Direction::First) => 0,
        Operation::Virtual(Direction::Last) => rows.len().saturating_sub(1),
        Operation::VirtualNumber(target_virtual_index) => {
            let Some(index) = rows
                .iter()
                .position(|(_, strip, _)| strip.virtual_index == *target_virtual_index)
            else {
                commands.spawn_layout_strip(
                    LayoutStrip::new(workspace_id, *target_virtual_index),
                    active_display.bounds().min,
                    active_display.entity(),
                    true,
                );

                if config.workspace_popup_status() {
                    commands.flash_message(format!("{}", *target_virtual_index + 1), 1.0);
                }
                return;
            };
            index
        }
        Operation::VirtualAdd => {
            let next_virtual_index = rows
                .iter()
                .map(|(_, strip, _)| strip.virtual_index)
                .max()
                .unwrap_or(0)
                + 1;

            commands.spawn_layout_strip(
                LayoutStrip::new(workspace_id, next_virtual_index),
                active_display.bounds().min,
                active_display.entity(),
                true,
            );

            if config.workspace_popup_status() {
                commands.flash_message(format!("{}", next_virtual_index + 1), 1.0);
            }
            return;
        }
        _ => return,
    };

    if next_index == current_index {
        return;
    }

    let new_entity = rows[next_index].0;
    let next_virtual_index = rows[next_index].1.virtual_index;
    if let Ok(mut entity_commands) = commands.get_entity(new_entity) {
        entity_commands.try_insert(ActiveWorkspaceMarker);

        if config.workspace_popup_status() {
            commands.flash_message(format!("{}", next_virtual_index + 1), 1.0);
        }
    }
    debug!(
        "Switched virtual workspace on display {} from {} to {}",
        active_display.id(),
        rows[current_index].1.virtual_index,
        rows[next_index].1.virtual_index
    );
}

/// Handles the keybinding to move windows between virtual workspaces.
/// Missing destinations are created by `handle_virtual_window_moves`. South at
/// the last row only proceeds when `create_workspace_automatically` is on;
/// numbered targets always may create, row 0 included.
#[instrument(level = Level::DEBUG, skip_all)]
fn move_virtual_workspace_bind(
    mut messages: MessageReader<Event>,
    windows: Windows,
    active_display: ActiveDisplay,
    workspaces: Query<(Entity, &LayoutStrip, Has<ActiveWorkspaceMarker>)>,
    config: Res<Config>,
    mut commands: Commands,
) {
    let Some(operation) = filter_window_operations(&mut messages, |op| {
        matches!(
            op,
            Operation::VirtualMove(_, _)
                | Operation::VirtualMoveNumber(_, _)
                | Operation::RowMove(_)
                | Operation::RowColumnMove(_)
        )
    })
    .next() else {
        return;
    };

    let Some((_, focused_entity)) = windows.focused() else {
        return;
    };

    if matches!(
        operation,
        Operation::RowMove(_) | Operation::RowColumnMove(_)
    ) && !active_display.active_strip().contains(focused_entity)
    {
        return;
    }

    let mut rows = workspaces
        .iter()
        .filter(|(_, strip, _)| strip.id() == active_display.active_strip().id())
        .collect::<Vec<_>>();
    rows.sort_by_key(|(_, strip, _)| strip.virtual_index);

    let current_virtual_index = active_display.active_strip().virtual_index;
    let current_index = rows.iter().position(|(_, _, active)| *active).unwrap_or(0);

    let (target_virtual_index, move_focus) = match operation {
        Operation::RowMove(direction) | Operation::RowColumnMove(direction) => {
            let target = match direction {
                Direction::North => current_index.checked_sub(1),
                Direction::South => (current_index + 1 < rows.len()).then_some(current_index + 1),
                _ => None,
            };
            let Some(target) = target else {
                return;
            };
            (rows[target].1.virtual_index, MoveFocus::Follow)
        }
        Operation::VirtualMove(Direction::South | Direction::East, move_focus)
            if active_display.active_strip().len() > 1 =>
        {
            if config.create_workspace_automatically() && current_index + 1 < rows.len() {
                (rows[current_index + 1].1.virtual_index, *move_focus)
            } else {
                (current_virtual_index + 1, *move_focus)
            }
        }
        Operation::VirtualMove(Direction::North | Direction::West, move_focus) => {
            if current_virtual_index == 0 {
                return;
            }
            (current_virtual_index - 1, *move_focus)
        }
        Operation::VirtualMove(Direction::First, move_focus) => {
            if current_virtual_index == 0 {
                return;
            }
            (0, *move_focus)
        }
        Operation::VirtualMove(Direction::Last, move_focus) => {
            let last_virtual_index = rows.last().map_or(0, |(_, strip, _)| strip.virtual_index);
            if current_virtual_index == last_virtual_index {
                return;
            }
            (last_virtual_index, *move_focus)
        }
        Operation::VirtualMoveNumber(target_virtual_index, move_focus) => {
            if *target_virtual_index == current_virtual_index {
                return;
            }
            (*target_virtual_index, *move_focus)
        }
        _ => return,
    };

    if let Ok(mut entity_commands) = commands.get_entity(focused_entity) {
        entity_commands.try_insert(VirtualMoveMarker {
            target_virtual_index,
            move_focus,
            whole_column: matches!(operation, Operation::RowColumnMove(_)),
        });
    }

    if move_focus == MoveFocus::Follow && config.workspace_popup_status() {
        commands.flash_message(format!("{}", target_virtual_index + 1), 1.0);
    }

    debug!("Moving {focused_entity} to new virtual space {target_virtual_index}");
}

/// The column of `strip` whose window sits nearest the display's horizontal
/// centre. Stands in for the focus a strip never had when it is parked, so
/// that returning to it lands on whatever the user was looking at.
fn column_closest_to_center(
    strip: &LayoutStrip,
    display: &Display,
    windows: &Windows,
) -> Option<Entity> {
    let display_center = display.bounds().center().x;
    strip
        .all_columns()
        .into_iter()
        .filter_map(|candidate| {
            let center = windows.moving_frame(candidate)?.center().x;
            Some((candidate, (center - display_center).abs()))
        })
        .min_by_key(|(_, distance)| *distance)
        .map(|(candidate, _)| candidate)
}

/// The column of `strip` whose window sits nearest `viewport_center_x` when the
/// strip is placed at horizontal offset `origin_x`: what the user would be
/// looking at when the row is revealed. Unlike [`column_closest_to_center`] it
/// reads the layout, not the windows' frames, so it works for a parked strip.
fn column_nearest_viewport_center(
    strip: &LayoutStrip,
    origin_x: i32,
    viewport_center_x: i32,
    windows: &Windows,
) -> Option<Entity> {
    strip
        .columns()
        .filter_map(|column| {
            let entity = strip.selected_tab(column).or_else(|| column.top())?;
            let layout_x = windows.layout_position(entity)?.0.x;
            let center = origin_x + layout_x + windows.size(entity)?.x / 2;
            Some((entity, (center - viewport_center_x).abs()))
        })
        .min_by_key(|(_, distance)| *distance)
        .map(|(entity, _)| entity)
}

#[instrument(level = Level::DEBUG, skip_all)]
#[allow(clippy::too_many_lines, clippy::too_many_arguments)]
pub(crate) fn show_active_workspace(
    activated: Single<Entity, Added<ActiveWorkspaceMarker>>,
    windows: Windows,
    mut workspaces: RestorableStrips,
    displays: Query<(&Display, Option<&DockPosition>)>,
    focus_markers: Query<Ref<FocusedMarker>>,
    apps: Query<&Application>,
    window_manager: Res<WindowManager>,
    mut hold: ResMut<KeyboardHold>,
    mut handoff: ResMut<KeyboardFocusHandoff>,
    config: Res<Config>,
    mut commands: Commands,
) {
    let Some(workspace_id) = workspaces
        .iter()
        .find_map(|(entity, _, strip, _, _, _)| (entity == *activated).then_some(strip.id()))
    else {
        return;
    };

    // A new row ends any earlier hold; an empty one below takes it up again.
    let held_before = hold.engaged().then(|| hold.previous());
    hold.release();

    // Hide other strips on the current workspace
    let current_focus = windows.focused();
    // The focused window, when this activation leaves it parked.
    let parked_focus = current_focus.filter(|(_, focus)| {
        workspaces.iter().any(|(entity, _, strip, _, _, _)| {
            entity != *activated && strip.id() == workspace_id && strip.contains(*focus)
        })
    });
    let current_workspace = workspaces
        .iter_mut()
        .filter(|(entity, _, strip, _, _, _)| strip.id() == workspace_id && *entity != *activated);

    for (entity, mut position, strip, child, previous, moving) in current_workspace {
        let Ok((active_display, _)) = displays.get(child.parent()) else {
            continue;
        };
        if previous.is_none() {
            let mut focus =
                current_focus.and_then(|(_, entity)| strip.contains(entity).then_some(entity));
            if focus.is_none() {
                focus = column_closest_to_center(strip, active_display, &windows);
                debug!("No previous focus, taking centered one {focus:?}.");
            }

            let origin = match &moving {
                Some(RepositionMarker(destination)) => *destination,
                None => position.0,
            };
            if let Ok(mut entity_commands) = commands.get_entity(entity) {
                entity_commands.try_insert(PreviousStripPosition { origin, focus });
            }
        }

        let bounds = active_display.bounds();

        if let Ok(mut cmd) = commands.get_entity(entity) {
            cmd.try_remove::<Scrolling>()
                .try_remove::<RepositionMarker>()
                .try_remove::<ManualStripOffset>();
        }

        if config.virtual_workspace_animations() {
            commands.reposition_entity(entity, bounds.max - PARKED_STRIP_SLIVER);
        } else {
            position.0 = bounds.max - PARKED_STRIP_SLIVER;
        }
    }

    let Ok((_, mut position, strip, child, previous_position, _)) = workspaces.get_mut(*activated)
    else {
        return;
    };
    debug!("showing virtual workspace {} ({})", strip.id(), *activated);
    info!(
        "row {} shown, {} windows",
        strip.virtual_index + 1,
        strip.all_windows().len()
    );

    // An empty row shows nothing to type into, yet the window that had focus
    // is now parked out of sight and would take the keystrokes. Hold the
    // keyboard instead. Focus on another display's window is not affected, and
    // neither is a row entered with no focused window at all, unless it is
    // another empty row reached while already holding.
    if strip.len() == 0 {
        let previous = parked_focus
            .and_then(|(window, _)| windows.find_parent(window.id()))
            .and_then(|(_, _, parent)| apps.get(parent).ok())
            .map(|app| app.pid())
            .or(held_before.flatten());
        if (parked_focus.is_some() || held_before.is_some())
            && let Some(own) = window_manager.hold_keyboard(previous)
        {
            info!(
                "row {} is empty: the keyboard is held, left window {} parked",
                strip.virtual_index + 1,
                parked_focus.map_or(0, |(window, _)| window.id())
            );
            hold.engage(*activated, own, previous);
            // Without the marker a return to the old row takes the remembered
            // focus path and really focuses the window, instead of assuming
            // the OS focus never left it. The pending request, if any, would
            // put that parked window back in front of the keyboard.
            if let Some((_, focus)) = parked_focus
                && let Ok(mut entity_commands) = commands.get_entity(focus)
            {
                entity_commands.try_remove::<FocusedMarker>();
            }
            handoff.cancel();
        }
    }

    // If no previous strip position exists, then the workspace was not hidden.
    if let Some(PreviousStripPosition { origin, focus }) = previous_position {
        if let Ok(mut entity_commands) = commands.get_entity(*activated) {
            entity_commands.try_remove::<PreviousStripPosition>();
        }

        // A window of this strip already holding focus is what activated it in
        // the first place - a Cmd-Tab straight into one of its windows. The
        // remembered focus is a fallback for a plain workspace switch, so it
        // must not pull focus away from that window.
        let focused = windows
            .focused()
            .map(|(_, entity)| entity)
            .filter(|entity| strip.contains(*entity));
        let keeps_focus = focused.is_some();

        // Only a focus that arrived with this activation gets the strip moved
        // for it. A window that held focus all along - switching back from an
        // empty workspace, say - keeps the offset the user left behind, even
        // if they had scrolled it out of sight.
        let arriving_focus = focused.filter(|entity| {
            focus_markers
                .get(*entity)
                .is_ok_and(|marker| marker.is_added())
        });

        // The saved origin describes where the strip sat when it was parked,
        // which says nothing about the window that just took focus: it can
        // easily land mostly off-screen. Scroll the strip the minimum amount
        // needed to expose it, the same correction `ensure_visible_in_strip`
        // makes - it cannot do it here, because it skips a strip on the frame
        // its `ActiveWorkspaceMarker` is added.
        let origin = arriving_focus
            .and_then(|focus_entity| {
                let layout = windows.layout_position(focus_entity)?.0;
                let size = windows.size(focus_entity)?;
                let (display, dock) = displays.get(child.parent()).ok()?;
                let viewport = display.actual_display_bounds(dock, &config);
                Some(origin_exposing(layout, size, *origin, viewport))
            })
            .unwrap_or(*origin);

        if config.virtual_workspace_animations() {
            commands.reposition_entity(*activated, origin);
        } else {
            position.0 = origin;
            // The strip's own offset is fixed instantly, but member windows
            // (a lower stack member especially) can still need a correction
            // on a following tick that the ordinary offscreen/parking
            // heuristic in `position_layout_windows` won't recognize as
            // restore-driven — see `SnapStripMarker`.
            spawn_snap_strip_guard(*activated, &mut commands);
        }

        if keeps_focus {
            // The layout of a strip that has just been unparked can still
            // settle over the next frames (widths recomputed, windows the
            // workspace picked up while it was hidden). Re-check the arriving
            // window then: `ensure_visible_in_strip` only scrolls if the slot
            // it ends up in really falls off an edge. That correction fires a
            // tick after this one (its own `is_added` guard skips the
            // activation tick), so it must snap rather than animate when
            // `virtual_workspace_animations` is off — otherwise the strip
            // (and everything in it) visibly slides on top of the restore
            // this function just did instantly.
            if let Some(focus_entity) = arriving_focus {
                commands.ensure_visible_snap(focus_entity, !config.virtual_workspace_animations());
            }
            return;
        }

        // Focus on the previous window. It may be gone by now - closed,
        // minimized or moved to another row while this one was hidden - and
        // then the row would show with its windows unfocused and the key
        // window still parked on the row just left.
        let target = focus.filter(|focus| strip.contains(*focus)).or_else(|| {
            let (display, dock) = displays.get(child.parent()).ok()?;
            let viewport = display.actual_display_bounds(dock, &config);
            column_nearest_viewport_center(strip, origin.x, viewport.center().x, &windows)
        });
        if let Some(target) = target {
            info!(
                "row {}: focusing window {}",
                strip.virtual_index + 1,
                windows.get(target).map_or(0, |window| window.id())
            );
            spawn_restore_focus_guard(target, &mut commands);

            // The same ordered handoff keyboard navigation uses: the windows
            // are placed first, then the OS is asked to focus, naming the
            // window actually losing focus and retrying a refusal.
            focus_row_with_verification(
                target,
                current_focus.map(|(_, entity)| entity),
                &mut commands,
            );
            commands.trigger(RaiseWindow {
                entity: target,
                with_strip: true,
            });
        }
    }
}

/// Resolves duplicate `virtual_index` values by reassigning each
/// duplicate to the lowest unused index on its workspace. Triggered by
/// `Added<LayoutStrip>` — the only event that can introduce a duplicate
/// (despawning a strip can leave a gap but never collides). Runs
/// independently of `reap_empty_workspaces` because without it, duplicate
/// indices silently break navigation: `switch_virtual_workspace_bind`
/// sorts rows by `virtual_index` and flashes `next_virtual_index + 1` as
/// the OSD label, so two rows both at 0 mean South moves between them
/// while the OSD stays at "1" and North no-ops at the bottom of the
/// saturating sub.
///
/// Sources of duplicate creation we have to defend against:
/// - `LayoutStrip::fullscreen` pins `virtual_index` to 0 unconditionally.
/// - Restoration trusts whatever the saved state contained.
/// - Races in `handle_virtual_window_moves` between checking the target
///   and spawning a new strip for it.
///
/// Gaps in the index sequence are preserved — only duplicates get
/// renumbered. Single-strip configurations at non-zero indices stay
/// where they are.
fn renumber_virtual_indexes(mut set: RenumberStrips) {
    let affected: HashSet<WorkspaceId> = set.p0().iter().map(LayoutStrip::id).collect();
    if affected.is_empty() {
        return;
    }

    let mut strips = set.p1();
    for workspace_id in affected {
        let mut rows = strips
            .iter_mut()
            .filter(|(_, strip)| strip.id() == workspace_id)
            .collect::<Vec<_>>();
        rows.sort_by_key(|(_, strip)| strip.virtual_index);

        let mut taken: HashSet<u32> = HashSet::new();
        let mut dups: Vec<usize> = Vec::new();
        for (i, (_, strip)) in rows.iter().enumerate() {
            if !taken.insert(strip.virtual_index) {
                dups.push(i);
            }
        }
        if dups.is_empty() {
            continue;
        }

        // Reassign each dup to the lowest free index, growing `taken` as
        // we go so the next dup doesn't pick the same slot.
        for i in dups {
            let mut probe = 0u32;
            while !taken.insert(probe) {
                probe += 1;
            }
            rows[i].1.virtual_index = probe;
        }
    }
}

type ReapChanges = Or<(Changed<LayoutStrip>, Added<ActiveWorkspaceMarker>)>;

fn rows_need_reaping(dirty: Query<(), ReapChanges>) -> bool {
    !dirty.is_empty()
}

fn reap_empty_virtual_workspaces(
    active: Single<Entity, With<ActiveWorkspaceMarker>>,
    strips: Populated<(Entity, &LayoutStrip)>,
    mut commands: Commands,
) {
    let changed_entity = *active;
    let Some(workspace_id) = strips.get(changed_entity).ok().map(|(_, strip)| strip.id()) else {
        return;
    };
    debug!("cleaning up virtual workspaces on space {workspace_id}");
    let mut rows = strips
        .iter()
        .filter(|(_, strip)| strip.id() == workspace_id)
        .collect::<Vec<_>>();
    rows.sort_by_key(|(_, strip)| strip.virtual_index);

    if rows.is_empty() {
        return;
    }

    // Do not reap the strip that just became active. Switching/creating onto an
    // empty virtual workspace is intentional (e.g. South auto-create); only
    // empty rows left behind should be removed.
    let remove = rows
        .iter()
        .filter(|(entity, strip)| *entity != changed_entity && strip.len() == 0)
        .map(|(entity, _)| *entity)
        .collect::<Vec<_>>();
    let keep = rows
        .iter()
        .filter(|(entity, _)| !remove.contains(entity))
        .map(|(entity, _)| *entity)
        .collect::<Vec<_>>();
    if remove.is_empty()
        && rows
            .iter()
            .zip(0u32..)
            .all(|((_, strip), index)| strip.virtual_index == index)
    {
        return;
    }
    // Despawn and renumber together. Exposing compacted survivors alongside
    // not-yet-despawned empty rows lets duplicate-index repair reorder them.
    commands.queue(move |world: &mut World| {
        for entity in remove {
            world.despawn(entity);
        }
        for (entity, index) in keep.into_iter().zip(0u32..) {
            if let Some(mut strip) = world.get_mut::<LayoutStrip>(entity) {
                strip.virtual_index = index;
            }
        }
    });
}

#[cfg(test)]
mod reaping_tests {
    use super::*;
    #[test]
    fn reaping_does_not_expose_duplicate_indices_to_repair() {
        let mut app = App::new();
        app.add_systems(
            Update,
            (reap_empty_virtual_workspaces, renumber_virtual_indexes).chain_ignore_deferred(),
        );
        let a = app.world_mut().spawn_empty().id();
        let b = app.world_mut().spawn_empty().id();
        let empty = app.world_mut().spawn(LayoutStrip::new(1, 0)).id();
        let mut first = LayoutStrip::new(1, 2);
        first.append(a);
        let first = app.world_mut().spawn(first).id();
        let mut second = LayoutStrip::new(1, 3);
        second.append(b);
        let second = app.world_mut().spawn((second, ActiveWorkspaceMarker)).id();
        app.update();
        assert!(app.world().get_entity(empty).is_err());
        assert_eq!(
            app.world().get::<LayoutStrip>(first).unwrap().virtual_index,
            0
        );
        assert_eq!(
            app.world()
                .get::<LayoutStrip>(second)
                .unwrap()
                .virtual_index,
            1
        );
    }
}
