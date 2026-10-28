use bevy::app::AppExit;
use bevy::ecs::change_detection::{DetectChanges, DetectChangesMut};
use bevy::ecs::entity::{Entity, EntityHashMap};
use bevy::ecs::hierarchy::{ChildOf, Children};
use bevy::ecs::message::{MessageReader, MessageWriter};
use bevy::ecs::query::{Added, Changed, Has, Or, With, Without};
use bevy::ecs::system::{
    Commands, Local, NonSend, NonSendMut, ParamSet, Populated, Query, Res, ResMut, Single,
};
use bevy::math::IRect;
use bevy::tasks::AsyncComputeTaskPool;
use bevy::tasks::futures_lite::future;
use bevy::time::Time;
use objc2_foundation::NSPoint;
use std::collections::{HashMap, HashSet};
use std::pin::Pin;
use std::sync::mpsc::{Receiver, RecvTimeoutError, TryRecvError};
use std::time::{Duration, Instant};
use tracing::{Level, debug, error, info, instrument, trace, warn};

use super::{
    ActiveDisplayMarker, BProcess, ExistingMarker, FreshMarker, MouseDraggingMarker,
    MouseHeldMarker, NativeMouseResize, NativeSiblingResize, RepositionMarker, ResizeMarker,
    RetryFrontSwitch, SpawnWindowTrigger, Timeout, VerifyWindowPosition,
};

use crate::config::{Config, decorations::BorderRadiusOption};
use crate::ecs::display::FloatingLayer;
use crate::ecs::layout::{Column, LayoutStrip};
use crate::ecs::params::{ActiveDisplay, FrameActivity, Windows};
use crate::ecs::{
    ActiveWorkspaceMarker, Bounds, BruteforceWindows, FlashMessage, FocusedMarker, Initializing,
    LowPowerMode, MissionControlActive, Position, ReadDisplayProperties, RestoreWindowState,
    Scrolling, SendMessageTrigger, SpawnCommandsExt, Unmanaged, WidthRatio, WindowProperties,
};
use crate::events::{Event, InputEvent};
use crate::manager::{
    Application, Display, Process, Window, WindowManager, WindowOS, bruteforce_windows,
};
use crate::overlay::{FlashMessageManager, OverlayManager};
use crate::platform::input::TapHealth;
use crate::platform::{PlatformCallbacks, WinID};

/// Processes and applications still inside their spawn grace period, with the
/// `FreshMarker` that says whether the spawn actually completed in time.
type TimedOutSpawns<'w, 's> = Populated<
    'w,
    's,
    (Entity, Has<FreshMarker>, &'static Timeout),
    Or<(With<BProcess>, With<Application>)>,
>;

/// Windows as [`window_moved_update_frame`] sees them: the element to re-read,
/// the origin to update, and the marker saying we are the ones moving it.
type MovableWindows<'w, 's> = Query<
    'w,
    's,
    (
        Entity,
        &'static mut Window,
        &'static mut Position,
        &'static Bounds,
        Option<&'static Unmanaged>,
        Has<RepositionMarker>,
    ),
    (Without<LayoutStrip>, Without<super::drag::NativeColumnDrag>),
>;

/// Windows as the resize handler rewrites them: the OS handle to re-read the
/// frame from, the size to overwrite, and whether the window is ours to lay
/// out at all.
type ResizableWindows<'w, 's> = Query<
    'w,
    's,
    (
        &'static mut Window,
        Entity,
        &'static Position,
        &'static mut Bounds,
        Option<&'static Unmanaged>,
        Has<ResizeMarker>,
    ),
    Without<LayoutStrip>,
>;

type SizeCommits<'w, 's> = Populated<
    'w,
    's,
    (
        &'static mut Window,
        &'static Bounds,
        &'static mut WidthRatio,
        Option<&'static NativeMouseResize>,
        Option<&'static NativeSiblingResize>,
    ),
    (Changed<Bounds>, Without<super::drag::NativeColumnDrag>),
>;

type ProgrammaticGeometry = (
    Without<NativeMouseResize>,
    Without<super::drag::NativeColumnDrag>,
);
type MoveAnimations<'w, 's> = Populated<
    'w,
    's,
    (&'static mut Position, Entity, &'static RepositionMarker),
    ProgrammaticGeometry,
>;
type SizeAnimations<'w, 's> =
    Populated<'w, 's, (&'static mut Bounds, Entity, &'static ResizeMarker), ProgrammaticGeometry>;
type PositionCommits<'w, 's> = Populated<
    'w,
    's,
    (
        &'static mut Window,
        &'static Position,
        Option<&'static NativeMouseResize>,
    ),
    (Changed<Position>, Without<super::drag::NativeColumnDrag>),
>;
type PositionVerifications<'w, 's> = Populated<
    'w,
    's,
    (
        Entity,
        &'static mut Window,
        &'static Position,
        &'static mut VerifyWindowPosition,
    ),
    ProgrammaticGeometry,
>;

const ANIAMTE_SNAP_THRESHOLD: f32 = 5.0;
const LOOP_MAX_TIMEOUT_FRAME_ACTIVE_MS: u32 = 16;
const LOOP_MAX_TIMEOUT_LOWPOWER_MS: u32 = 2000;
// Real events (input, IPC, workspace changes, ...) wake the pump immediately
// via `EventLoopWaker`, so this only bounds how late the free-running 1s
// `on_timer` systems (`recover_lost_focus`, workspace refresh) can land, and
// how long a dead event tap can go unnoticed between the 30s health sweeps.
// Kept well under both: with no genuine work to do, this used to run the
// whole schedule 20 times a second.
const LOOP_MAX_TIMEOUT_MS: u32 = 500;
const TAP_HEALTH_CHECK_INTERVAL: Duration = Duration::from_secs(30);
const LOOP_TIMEOUT_STEP: u32 = 1;

/// How long [`pump_events`] may spend draining the incoming channel before it
/// has to hand the frame back, and how many events it may take in one go.
///
/// The drain previously ran until a full millisecond passed with nothing
/// arriving, a condition a sustained burst (drag, resize animation, a churning
/// app) never satisfies — the loop never exited and the window manager stopped
/// responding until the burst let up. Nothing is dropped when a cap is hit:
/// leftover events stay in the channel for the next frame to pick up.
const PUMP_BUDGET: Duration = Duration::from_millis(4);
const PUMP_MAX_EVENTS: usize = 256;

/// Gathers all present displays and spawns them as entities in the Bevy world.
/// The currently active display (identified by `window_manager.active_display_id()`) is marked with `ActiveDisplayMarker`.
///
/// # Arguments
///
/// * `window_manager` - The `WindowManager` resource for querying display information.
/// * `commands` - Bevy commands to spawn entities.
pub fn gather_displays(window_manager: Res<WindowManager>, mut commands: Commands) {
    let Ok(active_display_id) = window_manager.active_display_id() else {
        error!("Unable to get active display id!");
        return;
    };
    for (display, workspaces) in window_manager.present_displays() {
        let origin = Position(display.bounds().min);
        let entity = if display.id() == active_display_id {
            commands.spawn((display, ActiveDisplayMarker))
        } else {
            commands.spawn(display)
        }
        .id();

        commands.trigger(ReadDisplayProperties(entity));

        let Ok(active_space) = window_manager.active_display_space(active_display_id) else {
            return;
        };

        for id in workspaces {
            let active = id == active_space;
            commands.spawn_layout_strip(LayoutStrip::new(id, 0), origin.0, entity, active);
            commands.spawn((FloatingLayer::new(id), ChildOf(entity)));
        }
    }
}

/// Pre-creates additional (empty) virtual workspaces on every physical space,
/// so that `config.default_workspaces()` virtual workspaces exist right after
/// startup instead of only being created on first use.
///
/// Must run after [`gather_displays`], which spawns the `virtual_index: 0`
/// strip for every physical space.
pub fn initialise_workspaces(
    strips: Query<(&LayoutStrip, &ChildOf, &Position)>,
    config: Res<Config>,
    mut commands: Commands,
) {
    let wanted = config.default_workspaces();
    if wanted <= 1 {
        return;
    }

    let mut seen = HashSet::new();
    for (strip, child_of, origin) in &strips {
        if strip.virtual_index != 0 || !seen.insert((strip.id(), child_of.parent())) {
            continue;
        }
        for virtual_index in 1..wanted {
            if strips.iter().any(|(candidate, parent, _)| {
                candidate.id() == strip.id()
                    && parent.parent() == child_of.parent()
                    && candidate.virtual_index == virtual_index
            }) {
                continue;
            }
            commands.spawn_layout_strip(
                LayoutStrip::new(strip.id(), virtual_index),
                origin.0,
                child_of.parent(),
                false,
            );
        }
    }
}

/// Adds an existing process to the window manager. This is used during initial setup for already running applications.
/// It attempts to create a new `Application` instance from the `BProcess` and attaches it as a child entity.
/// The `ExistingMarker` is then removed from the process entity.
///
/// # Arguments
///
/// * `window_manager` - The `WindowManager` resource for creating new application instances.
/// * `process_query` - A query for existing `BProcess` entities marked with `ExistingMarker`.
/// * `commands` - Bevy commands to spawn entities and manage components.
#[instrument(level = Level::DEBUG, skip_all)]
pub(crate) fn add_existing_process(
    window_manager: Res<WindowManager>,
    processes: Populated<(Entity, &BProcess), With<ExistingMarker>>,
    mut commands: Commands,
) {
    for (entity, process) in processes {
        let Ok(app) = window_manager.new_application(&*process.0) else {
            error!("creating aplication from process '{}'", process.name());
            return;
        };
        commands.spawn((app, ExistingMarker, ChildOf(entity)));
        if let Ok(mut entity_commands) = commands.get_entity(entity) {
            entity_commands.try_remove::<ExistingMarker>();
        }
    }
}

/// Adds an existing application to the window manager. This is used during initial setup.
/// It observes the application, adds its windows to the manager, and then triggers `SpawnWindowTrigger` events for newly found windows.
/// The `ExistingMarker` is removed from the application entity after processing.
///
/// # Arguments
///
/// * `window_manager` - The `WindowManager` resource for interacting with window management logic.
/// * `displays` - A query for all `Display` entities, used to gather all existing space IDs.
/// * `app_query` - A query for existing `Application` entities marked with `ExistingMarker`.
/// * `commands` - Bevy commands to spawn entities and manage components.
#[instrument(level = Level::DEBUG, skip_all)]
pub(crate) fn add_existing_application(
    window_manager: Res<WindowManager>,
    workspaces: Query<&LayoutStrip>,
    fresh_apps: Populated<(&mut Application, Entity), With<ExistingMarker>>,
    config: Res<Config>,
    mut commands: Commands,
) {
    let spaces = workspaces
        .into_iter()
        .map(LayoutStrip::id)
        .collect::<Vec<_>>();
    let thread_pool = AsyncComputeTaskPool::get();

    for (mut app, entity) in fresh_apps {
        let mut offscreen_windows = vec![];

        if app.observe().is_ok_and(|result| result)
            && let Ok((found_windows, offscreen)) = window_manager
                .find_existing_application_windows(&mut app, &spaces, &config)
                .inspect_err(|err| warn!("{err}"))
        {
            offscreen_windows.extend(offscreen);
            commands.trigger(SpawnWindowTrigger(found_windows));
        }
        if let Ok(mut entity_commands) = commands.get_entity(entity) {
            entity_commands.try_remove::<ExistingMarker>();
        }

        if !offscreen_windows.is_empty() {
            let pid = app.pid();
            let bundle_id = app.bundle_id();
            let config = config.clone();
            let bruteforce_task = thread_pool.spawn(async move {
                bruteforce_windows(pid, bundle_id.as_deref(), offscreen_windows, &config)
            });
            commands.spawn(BruteforceWindows(bruteforce_task));
        }
    }
}

/// Finishes the initialization process once all initial windows are loaded.
/// This system refreshes displays, assigns the `FocusedMarker` to the first window of the active space,
/// and logs the total number of managed windows.
///
/// # Arguments
///
/// * `windows` - A mutable query for all `Window` components, their `Entity`, and `Has<Unmanaged>` status.
/// * `displays` - A query for all `Display` entities, including whether they have the `ActiveDisplayMarker`.
/// * `window_manager` - The `WindowManager` resource for refreshing displays and getting active space information.
/// * `commands` - Bevy commands to insert components like `FocusedMarker`.
#[instrument(level = Level::DEBUG, skip_all)]
pub(crate) fn finish_setup(
    process_query: Query<Entity, With<ExistingMarker>>,
    windows: Windows,
    applications: Query<&Application>,
    mut bruteforce_tasks: Query<(Entity, &mut BruteforceWindows)>,
    mut workspaces: Query<(&mut LayoutStrip, Has<ActiveWorkspaceMarker>, &ChildOf)>,
    window_manager: Res<WindowManager>,
    mut commands: Commands,
) {
    if !process_query.is_empty() {
        // The other two add_* functions are still running..
        return;
    }

    // Reap the bruteforced windows.
    if !bruteforce_tasks.is_empty() {
        for (entity, mut job) in &mut bruteforce_tasks {
            if let Some(found_windows) = future::block_on(future::poll_once(&mut job.0)) {
                commands.trigger(SpawnWindowTrigger(found_windows));
                if let Ok(mut entity_commands) = commands.get_entity(entity) {
                    entity_commands.try_despawn();
                }
            }
        }
        // Wait for the next tick to finish initialization.
        return;
    }

    info!(
        "Initialization: found {:?} windows.",
        windows.iter().size_hint()
    );

    let mut focused_managed_window = false;
    for (mut strip, active_strip, _) in &mut workspaces {
        // macOS reports physical Space membership, not our virtual rows.
        // Seed physical windows once; the restore pass redistributes saved rows.
        if strip.virtual_index != 0 {
            continue;
        }
        debug!("space {}: before refresh {strip:?}", strip.id());
        let workspace_windows = window_manager
            .windows_in_workspace(strip.id())
            .inspect_err(|err| {
                warn!("failed to get windows on workspace {}: {err}", strip.id());
            })
            .ok()
            .map(|workspace_windows| {
                workspace_windows
                    .into_iter()
                    .filter_map(|window_id| windows.find_managed(window_id))
                    .filter(|(window, entity)| {
                        if window.is_minimized() {
                            if let Ok(mut entity_commands) = commands.get_entity(*entity) {
                                entity_commands.try_insert(Unmanaged::Minimized);
                            }
                            false
                        } else {
                            true
                        }
                    })
                    .collect::<Vec<_>>()
            });
        let Some(workspace_windows) = workspace_windows else {
            continue;
        };

        // Preserve the order - do not flush existing windows.
        for entity in strip.all_windows() {
            if !workspace_windows.iter().any(|(_, e)| *e == entity) {
                strip.remove(entity);
            }
        }
        for (_, entity) in workspace_windows {
            if !strip.contains(entity) {
                strip.append(entity);
            }
        }
        debug!("space {}: after refresh {strip:?}", strip.id());

        if active_strip && let Some(entity) = strip.first().ok().and_then(|column| column.top()) {
            commands.focus_entity(entity, true);
            focused_managed_window = true;
        }
    }

    // An all-floating workspace has no strip member to receive the initial
    // focus marker. Mirror the frontmost app's AX focus so menu actions such as
    // Toggle Managed work immediately after launch.
    if !focused_managed_window
        && let Some(focused_window_id) = applications
            .iter()
            .find(|app| app.is_frontmost())
            .and_then(|app| app.focused_window_id().ok())
        && let Some((_, entity)) = windows.find(focused_window_id)
        && let Ok(mut entity_commands) = commands.get_entity(entity)
    {
        entity_commands.try_insert(FocusedMarker);
    }

    commands.remove_resource::<Initializing>();
    commands.trigger(RestoreWindowState);
}

/// Handles the event when a new application is launched. It creates a `Process` and `Application` object,
/// observes the application for events, and adds its windows to the manager.
/// This system processes `BProcess` entities marked with `FreshMarker`.
/// If the process is not yet ready, it continues observing it. If ready, it attempts to create and observe an `Application`.
/// A `Timeout` is added to the application if it takes too long to become observable.
///
/// # Arguments
///
/// * `window_manager` - The `WindowManager` resource for creating new application instances.
/// * `process_query` - A `Populated` query for `(Entity, &mut BProcess, Has<Children>)` with `With<FreshMarker>`.
/// * `commands` - Bevy commands to spawn entities and manage components.
pub(super) fn add_launched_process(
    window_manager: Res<WindowManager>,
    fresh_processes: Populated<(Entity, &mut BProcess, Has<Children>), With<FreshMarker>>,
    config: Res<Config>,
    mut commands: Commands,
) {
    const APP_OBSERVABLE_TIMEOUT: Duration = Duration::from_secs(10);
    let mut already_seen = HashSet::new();

    for (entity, mut process, children) in fresh_processes {
        let process = &mut *process.0;

        if !already_seen.insert(process.psn()) {
            continue;
        }

        if config.should_force_manage_process(process) {
            debug!(
                "Forcing management of launched process '{}' despite unobservable policy.",
                process.name()
            );
            process.force_manage(true);
        }

        if !process.ready() {
            continue;
        }

        if children {
            // Process already has an attached Application, so finish.
            if let Ok(mut entity_commands) = commands.get_entity(entity) {
                entity_commands.try_remove::<FreshMarker>();
            }
            continue;
        }

        let Ok(mut app) = window_manager.new_application(process) else {
            error!("creating aplication from process '{}'", process.name());
            return;
        };

        if app.observe().is_ok_and(|good| good) {
            let timeout = Timeout::new(
                APP_OBSERVABLE_TIMEOUT,
                Some(format!(
                    "{app} did not become observable in {}s.",
                    APP_OBSERVABLE_TIMEOUT.as_secs()
                )),
                &mut commands,
            );
            commands.spawn((app, FreshMarker, timeout, ChildOf(entity)));
        } else {
            debug!("failed to register some observers {}", process.name());
        }
    }
}

/// Adds windows for a newly launched application.
/// This system processes `Application` entities marked with `FreshMarker`.
/// It queries the application's window list, filters out already existing windows, and triggers `SpawnWindowTrigger` events for new windows.
/// The `FreshMarker` is removed from the application entity after processing.
///
/// # Arguments
///
/// * `app_query` - A `Populated` query for `(&mut Application, Entity)` with `With<FreshMarker>`.
/// * `windows` - A query for all `Window` components, used to check for existing windows.
/// * `commands` - Bevy commands to spawn entities and manage components.
pub(super) fn add_launched_application(
    app_query: Populated<(&mut Application, Entity, Has<Children>), With<FreshMarker>>,
    windows: Windows,
    config: Res<Config>,
    mut commands: Commands,
) {
    // TODO: maybe refactor this with add_existing_application_windows()
    let find_window = |window_id| windows.find(window_id);

    for (app, entity, has_children) in app_query {
        let mut create_windows = app.window_list(&config);
        // Retain the non-existing windows, so they can be created.
        create_windows.retain(|window| find_window(window.id()).is_none());

        if !create_windows.is_empty() {
            if let Ok(mut entity_commands) = commands.get_entity(entity) {
                entity_commands.try_remove::<FreshMarker>();
            }
            debug!(
                "spawn! (polling path found {} new windows for {entity})",
                create_windows.len(),
            );
            commands.trigger(SpawnWindowTrigger(create_windows));
        } else if has_children {
            // Windows were already created via AXCreated notification path.
            // Remove FreshMarker so the Timeout gets cleaned up.
            debug!("removing FreshMarker from {entity}: windows already created via AXCreated");
            if let Ok(mut entity_commands) = commands.get_entity(entity) {
                entity_commands.try_remove::<FreshMarker>();
            }
        }
    }
}

/// Cleans up entities which have been initializing for too long, specifically `BProcess` or `Application` entities.
/// This system removes the `Timeout` component from entities that are no longer `Fresh`.
///
/// This can be processes which are not yet observable or applications which keep failing to
/// register some of the observers.
///
/// # Arguments
///
/// * `cleanup` - A `Populated` query for `(Entity, Has<FreshMarker>, &Timeout)` components, targeting `BProcess` or `Application` entities.
/// * `commands` - Bevy commands to remove components.
pub(super) fn fresh_marker_cleanup(cleanup: TimedOutSpawns, mut commands: Commands) {
    for (entity, fresh, _) in cleanup {
        if !fresh && let Ok(mut entity_commands) = commands.get_entity(entity) {
            // Process was ready before the timer finished.
            entity_commands.try_remove::<Timeout>();
        }
    }
}

/// A Bevy system that ticks `Timeout` timers and despawns entities when their timers finish.
/// This system is responsible for cleaning up entities that have exceeded their allotted time for an operation.
///
/// # Arguments
///
/// * `timers` - A `Populated` query for `(Entity, &mut Timeout)` components.
/// * `clock` - The Bevy `Time` resource for getting the delta time.
/// * `commands` - Bevy commands to despawn entities.
pub(super) fn timeout_ticker(
    timers: Populated<(Entity, &mut Timeout)>,
    clock: Res<Time>,
    mut commands: Commands,
) {
    for (entity, mut timeout) in timers {
        if timeout.timer.is_finished() {
            if let Some(system_id) = timeout.system_id.take() {
                commands.run_system(system_id);
                commands.unregister_system(system_id);
            }
            if let Ok(mut entity_commands) = commands.get_entity(entity) {
                if let Some(on_expire) = timeout.on_expire {
                    trace!("Expiring component timer on {entity}.");
                    on_expire(&mut entity_commands);
                } else {
                    trace!("Despawning entity {entity} due to timeout.");
                    entity_commands.try_despawn();
                }
            }
        } else {
            timeout.timer.tick(clock.delta());
        }
    }
}

/// Retries querying the focused window for applications that had a transient AX error
/// during `ApplicationFrontSwitched`. Runs each frame until success or timeout.
pub(super) fn retry_front_switch(
    retries: Populated<(Entity, &RetryFrontSwitch)>,
    applications: Query<&Application>,
    mut commands: Commands,
) {
    for (entity, retry) in retries.iter() {
        let Ok(app) = applications.get(retry.0) else {
            // Application entity no longer exists, clean up.
            if let Ok(mut entity_commands) = commands.get_entity(entity) {
                entity_commands.try_despawn();
            }
            continue;
        };
        if !app.is_frontmost() {
            // App is no longer frontmost — this retry is stale.
            debug!("Discarding stale front switch retry (app no longer frontmost).");
            if let Ok(mut entity_commands) = commands.get_entity(entity) {
                entity_commands.try_despawn();
            }
            continue;
        }
        if let Ok(focused_id) = app.focused_window_id() {
            debug!("Front switch retry succeeded for window {focused_id}.");
            commands.trigger(SendMessageTrigger(Event::WindowFocused {
                window_id: focused_id,
            }));
            if let Ok(mut entity_commands) = commands.get_entity(entity) {
                entity_commands.try_despawn();
            }
        }
        // Otherwise, let timeout_ticker handle expiry.
    }
}

/// Animates window movement.
/// Fraction of the remaining distance an exponential ease-out consumes in a
/// frame, given a decay `rate` (per second) and the frame's `delta` in seconds.
/// Shared by the reposition and resize animators so the two never drift out of step.
#[allow(
    clippy::cast_possible_truncation,
    reason = "clamped to [0, 1], well within f32's range; only sub-pixel precision is lost"
)]
fn ease_out_factor(rate: f64, delta: f64) -> f32 {
    (1.0 - (-rate * delta).exp()).clamp(0.0, 1.0) as f32
}

/// This is a Bevy system that runs on `Update`. It smoothly moves windows to their target
/// positions, as indicated by the `RepositionMarker` component.
/// Animation speed is controlled by the `animation_speed` in the `Config`.
/// When a window reaches its target position, the `RepositionMarker` is removed.
///
/// # Arguments
///
/// * `windows` - A `Populated` query for `(&mut Window, Entity, &RepositionMarker)` components.
/// * `displays` - A query for all `Display` entities, used to get display bounds and menubar height.
/// * `time` - The Bevy `Time` resource for calculating delta time.
/// * `config` - The `Config` resource, used for animation speed.
/// * `commands` - Bevy commands to remove the `RepositionMarker` when animation is complete.
#[instrument(level = Level::TRACE, skip_all)]
pub(super) fn animate_entities(
    animate: MoveAnimations,
    time: Res<Time>,
    config: Res<Config>,
    mut commands: Commands,
) {
    // Frame-rate-independent exponential smoothing (ease-out).
    // `animation_speed` is the decay rate (per second); higher = snappier.
    let t = ease_out_factor(config.animation_speed(), time.delta_secs_f64());

    animate
        .into_iter()
        .for_each(|(mut position, entity, RepositionMarker(origin))| {
            let target = origin.as_vec2();
            let current = position.0.as_vec2();
            let lerped = current.lerp(target, t);

            // Snap once we're within a pixel of the target (or after one effectively-
            // complete tick), so the marker is dropped promptly.
            let finished = (target - lerped).length() <= ANIAMTE_SNAP_THRESHOLD;
            let new_pos = if finished {
                *origin
            } else {
                lerped.round().as_ivec2()
            };

            trace!(
                "entity {entity} source {} dest {origin} t {t:.3} moving to {new_pos}",
                position.0,
            );
            position.0 = new_pos;
            if finished && let Ok(mut entity_commands) = commands.get_entity(entity) {
                entity_commands.try_remove::<RepositionMarker>();
            }
        });
}

/// Animates window resizing.
/// This is a Bevy system that runs on `Update`. It resizes windows to their target
/// dimensions, as indicated by the `ResizeMarker` component.
/// When a window reaches its target size, the `ResizeMarker` is removed.
///
/// # Arguments
///
/// * `windows` - A `Populated` query for `(&mut Window, Entity, &ResizeMarker)` components.
/// * `active_display` - An `ActiveDisplay` system parameter providing immutable access to the active display.
/// * `commands` - Bevy commands to remove the `ResizeMarker` when resizing is complete.
#[instrument(level = Level::TRACE, skip_all)]
pub(super) fn animate_resize_entities(
    animate: SizeAnimations,
    time: Res<Time>,
    config: Res<Config>,
    mut commands: Commands,
) {
    // Matches animate_entities: exponential ease-out, frame-rate independent.
    let t = ease_out_factor(config.animation_speed(), time.delta_secs_f64());

    animate
        .into_iter()
        .for_each(|(mut bounds, entity, ResizeMarker(size))| {
            let target = size.as_vec2();
            let current = bounds.0.as_vec2();
            let lerped = current.lerp(target, t);

            let finished = (target - lerped).length() <= ANIAMTE_SNAP_THRESHOLD;
            let new_size = if finished {
                *size
            } else {
                lerped.round().as_ivec2()
            };

            trace!(
                "entity {entity} source {} dest {size} t {t:.3} resizing to {new_size}",
                bounds.0,
            );
            bounds.0 = new_size;
            if finished && let Ok(mut entity_commands) = commands.get_entity(entity) {
                entity_commands.try_remove::<ResizeMarker>();
            }
        });
}

/// Republishes the pointer and gesture events onto [`InputEvent`], so the input
/// systems do not have to sift the whole stream for them every frame.
///
/// Runs right after [`pump_events`], which is what puts this frame's events on
/// the stream in the first place.
pub(crate) fn demux_input_events(
    mut messages: MessageReader<Event>,
    mut input: MessageWriter<InputEvent>,
) {
    for event in messages.read() {
        if event.is_input() {
            input.write(InputEvent(event.clone()));
        }
    }
}

#[allow(clippy::too_many_arguments)]
pub(crate) fn pump_events(
    mut exit: MessageWriter<AppExit>,
    mut messages: MessageWriter<Event>,
    low_power_mode: Option<Res<LowPowerMode>>,
    incoming_events: Option<NonSend<Receiver<Event>>>,
    platform: Option<NonSendMut<Pin<Box<PlatformCallbacks>>>>,
    activity: FrameActivity,
    mut timeout: Local<u32>,
    mut last_tap_check: Local<Option<Instant>>,
) {
    let Some((ref mut platform, incoming_events)) = platform.zip(incoming_events) else {
        // No platform interface or incoming event pipe - probably executing in a unit test.
        return;
    };

    // Deliberately not paced to a frame period: waiting a full period put a
    // floor under how soon a pump could start, so an event landing right after
    // one returned had to wait out the rest of it. That latency is worse than
    // the redundant work skipping the wait costs.
    platform.pump_cocoa_event_loop(f64::from(*timeout) / 1000.0);

    let deadline = Instant::now() + PUMP_BUDGET;
    let mut received_events = Vec::new();
    let mut pending_mouse = None;
    let mut woke = false;

    // `true` when the channel went quiet, `false` when a cap sent us home with
    // events still queued. Only the quiet case may back the poll timeout off.
    let drained = loop {
        // Checked before the receive so a burst cannot keep extending the stay:
        // whatever is left stays in the channel for the next frame.
        if received_events.len() >= PUMP_MAX_EVENTS || Instant::now() >= deadline {
            trace!(
                "pump_events: yielding the frame with {} events taken",
                received_events.len()
            );
            break false;
        }

        // Polled before any timed wait: the Cocoa pump above already did this
        // frame's sleeping, so a quiet channel used to cost another millisecond.
        //
        // Once something has been taken, an empty channel ends the pump at once
        // rather than waiting another millisecond for company: a timed wait on
        // a semaphore is rarely shorter than 1.2 ms here, and it sat in front
        // of every system for every request, click and key (a sampled engine
        // spent ~1.5 ms per request in it). Producers push before they wake the
        // pump, so anything not in the channel yet will wake the next pass.
        let received = match incoming_events.try_recv() {
            Err(TryRecvError::Empty) if !received_events.is_empty() || pending_mouse.is_some() => {
                Err(RecvTimeoutError::Timeout)
            }
            Err(TryRecvError::Empty) => incoming_events.recv_timeout(Duration::from_millis(1)),
            Err(TryRecvError::Disconnected) => Err(RecvTimeoutError::Disconnected),
            Ok(event) => Ok(event),
        };
        match received {
            Ok(Event::Exit) | Err(RecvTimeoutError::Disconnected) => {
                exit.write(AppExit::Success);
                return;
            }
            Ok(event) => {
                woke |= matches!(event, Event::SystemWoke { .. });
                if matches!(event, Event::MouseMoved { .. }) {
                    pending_mouse = Some(event);
                } else {
                    received_events.extend(pending_mouse.take());
                    received_events.push(event);
                }
                *timeout = LOOP_TIMEOUT_STEP;
            }
            Err(RecvTimeoutError::Timeout) => break true,
        }
    };

    received_events.extend(pending_mouse.take());
    messages.write_batch(received_events);

    if drained {
        let frame_active = activity.mid_frame();
        let low_power = low_power_mode.is_some_and(|low_power| low_power.0);
        let timeout_limit = if frame_active {
            LOOP_MAX_TIMEOUT_FRAME_ACTIVE_MS
        } else if low_power {
            LOOP_MAX_TIMEOUT_LOWPOWER_MS
        } else {
            LOOP_MAX_TIMEOUT_MS
        };
        *timeout = timeout.min(timeout_limit) + LOOP_TIMEOUT_STEP;
    } else {
        // Still backed up: come straight back rather than sleeping on it.
        *timeout = LOOP_TIMEOUT_STEP;
    }

    // macOS can invalidate the event tap while the machine sleeps without ever
    // notifying the callback, which kills every keybinding, click and swipe
    // while the socket and the layout engine carry on as normal. Waking is the
    // usual trigger, so sweep on a slow timer too for the deaths without one.
    if woke || last_tap_check.is_none_or(|last| last.elapsed() >= TAP_HEALTH_CHECK_INTERVAL) {
        *last_tap_check = Some(Instant::now());
        match platform.ensure_input_tap_alive() {
            TapHealth::Healthy => {}
            health => warn!("input tap not healthy (woke={woke}), recovery: {health:?}"),
        }
    }
}

#[instrument(level = Level::TRACE, skip_all)]
pub(super) fn window_resized_update_frame(
    mut messages: MessageReader<Event>,
    mut windows: ResizableWindows,
    mut workspaces: Query<(&LayoutStrip, &mut Position)>,
    held: Query<&MouseHeldMarker, With<MouseDraggingMarker>>,
    native_resizes: Query<(Entity, &NativeMouseResize)>,
    pending_siblings: Query<&NativeSiblingResize>,
    mut commands: Commands,
) {
    for event in messages.read() {
        let Event::WindowResized { window_id } = event else {
            continue;
        };

        let Some((mut window, entity, position, mut bounds, unmanaged, resizing)) = windows
            .iter_mut()
            .find(|window| window.0.id() == *window_id)
        else {
            continue;
        };
        if matches!(unmanaged, Some(Unmanaged::Minimized | Unmanaged::Hidden)) {
            continue;
        }
        // Our own resize, echoed back: `commit_window_size` requested this size
        // and `animate_resize_entities` is still stepping toward it, so reading
        // the echo in here would fight the animation producing that difference.
        // Only a resize we did not initiate is new information.
        // Pending direct writes remain requests until physically verified.
        // Their delayed echoes must never become column width authorities.
        let pointer_owned = held.iter().any(|marker| marker.0 == entity);
        if pending_siblings.contains(entity) {
            if !pointer_owned {
                continue;
            }
            commands.entity(entity).remove::<NativeSiblingResize>();
        }
        if resizing && !pointer_owned {
            continue;
        }
        let Ok(new_frame) = window.update_frame() else {
            continue;
        };
        let active_strip = workspaces
            .iter_mut()
            .find(|(strip, _)| strip.contains(entity));
        // Echoes from sibling AX writes may arrive after the pointer has
        // already changed width again. Only the owning member may replace
        // the column's width until release.
        if !pointer_owned
            && let Some((strip, _)) = active_strip.as_ref()
            && let Some(owner) = native_resizes
                .iter()
                .map(|(owner, _)| owner)
                .chain(held.iter().map(|marker| marker.0))
                .find(|owner| {
                    *owner != entity && strip.index_of(*owner).ok() == strip.index_of(entity).ok()
                })
        {
            // Reassert the latest logical sibling size without adopting its
            // lagging native frame as fresh column geometry.
            if new_frame.size() != bounds.0 {
                commands
                    .entity(entity)
                    .insert(NativeSiblingResize::new(owner, bounds.0.x));
                bounds.set_changed();
            }
            continue;
        }
        if pointer_owned && active_strip.is_some() {
            commands
                .entity(entity)
                .insert(NativeMouseResize {
                    x: new_frame.min.x,
                    width: new_frame.width(),
                })
                .remove::<(ResizeMarker, RepositionMarker, VerifyWindowPosition)>();
        }
        let old_frame = IRect::from_corners(position.0, position.0 + bounds.0);
        if old_frame.size() != new_frame.size() {
            bounds.0 = new_frame.size();
        }

        // If the window was resized, shift LayoutStrip slightly to avoid moving right corner.
        let Some((strip, mut strip_position)) = active_strip else {
            // Floating window, don't nudge the strip.
            continue;
        };
        // The member under the pointer owns the width, including a lower
        // split member or an inactive synthetic/native tab. Update every
        // member before layout reads its stable first-member representative.
        let siblings = strip
            .index_of(entity)
            .ok()
            .and_then(|index| strip.get(index).ok())
            .map(|column| column.window_iter().collect::<Vec<_>>())
            .unwrap_or_default();
        for sibling in siblings {
            if pointer_owned && sibling != entity {
                commands
                    .entity(sibling)
                    .remove::<NativeMouseResize>()
                    .insert(NativeSiblingResize::new(entity, new_frame.width()));
            }
            if let Ok((_, _, _, mut sibling_bounds, _, _)) = windows.get_mut(sibling)
                && sibling_bounds.0.x != new_frame.width()
            {
                sibling_bounds.0.x = new_frame.width();
            }
        }

        if old_frame.min.x != new_frame.min.x {
            let shift = (old_frame.size() - new_frame.size()).with_y(0);
            // Search marke: reposition_entity - Updating position directly to reduce jitter.
            strip_position.0.x += shift.x;
        }

        // When the user drags the top edge of a stacked window, we adjust the window above to
        // accomodate.
        let diff = old_frame.min.y - new_frame.min.y;
        if diff.abs() > 0
            && let Some(above_entity) = strip.above(entity)
            && let Ok((_, _, _, mut above_bounds, _, _)) = windows.get_mut(above_entity)
            && above_bounds.0.y - diff > 200
        {
            above_bounds.0.y -= diff;
        }
    }
}

/// The rows currently parked at a display's corner. A row is hidden when it
/// carries the position it will be restored from, not merely when it is not
/// the active one: `ActiveWorkspaceMarker` is global, so the row each other
/// display (or native Space) is showing is inactive too, and its windows sit
/// where they are meant to be seen.
type HiddenRows<'w, 's> = Query<
    'w,
    's,
    &'static LayoutStrip,
    (
        With<crate::ecs::workspace::PreviousStripPosition>,
        Without<ActiveWorkspaceMarker>,
    ),
>;

/// How much of a parked window may show before it counts as displaced. The
/// engine itself leaves a `PARKED_STRIP_SLIVER` of 10 pt, and `AppKit` adds up to
/// ~40 pt of title bar or toolbar on top of that, so the clamp's echo of our own
/// move stays well inside it. A window showing this much in both directions,
/// roughly a title bar's worth of content, is one a person would see.
const PARKED_VISIBLE_LIMIT: i32 = 64;
/// Waits between corrective moves for one window: the first correction is
/// immediate, each later one waits for the next entry, and the last repeats.
/// A window that fights forever costs a handful of moves a minute, never a
/// flicker. The cap is short because the window sits on screen, behind the
/// row in use, for as long as the wait lasts.
const CORRECTION_BACKOFF: [Duration; 4] = [
    Duration::from_millis(250),
    Duration::from_secs(1),
    Duration::from_secs(4),
    Duration::from_secs(10),
];
/// A window seen parked this long since its last displacement starts over with
/// a fresh, immediate first correction. Short on purpose: an app that moves
/// itself back every 20 to 40 s is a sporadic re-mover, not a feedback loop,
/// and the long ladder only fits the latter. It has to span two audits
/// ([`PARKING_AUDIT_EVERY`]), the only callers that see a quiet window.
const PARKED_SETTLE: Duration = Duration::from_secs(3);
/// How often the audit looks at the window server when nothing is in doubt.
const PARKING_AUDIT_EVERY: Duration = Duration::from_secs(2);
/// How soon the audit looks again when a window was seen displaced once, or a
/// correction was held back and its wait is over.
const PARKING_RECHECK: Duration = Duration::from_millis(250);

/// Whether `frame` shows a person-visible part of a display it should not.
/// A display where the window would show just as much at its logical `target`
/// is not counted: nothing sent to the app can improve on that.
fn intrudes_on_displays(frame: IRect, target: crate::manager::Origin, displays: &[IRect]) -> bool {
    let shown = |rect: IRect, display: IRect| {
        let overlap = rect.intersect(display);
        overlap.width() >= PARKED_VISIBLE_LIMIT && overlap.height() >= PARKED_VISIBLE_LIMIT
    };
    let at_target = IRect::from_corners(target, target + frame.size());
    displays
        .iter()
        .any(|display| shown(frame, *display) && !shown(at_target, *display))
}

struct ParkingEpisode {
    target: crate::manager::Origin,
    corrections: usize,
    retry_at: Duration,
    parked_since: Option<Duration>,
    /// Seen displaced while the backoff held the correction back: the audit
    /// re-checks it as soon as `retry_at` passes, without a second sighting.
    pending: bool,
}

/// A parking correction must not become a feedback loop with an app's own
/// frame constraints. Each hidden-row window has an episode: the first
/// displacement is corrected at once, later ones back off exponentially. A
/// displacement the backoff holds back is not dropped: it is marked pending and
/// the audit looks again when the wait ends. The episode ends when the row is
/// shown, layout picks a new target, or the window has stayed parked for
/// [`PARKED_SETTLE`]. Echoes of our own successful move do not touch it.
#[derive(Default, bevy::ecs::resource::Resource)]
pub(crate) struct ParkingCorrections {
    episodes: EntityHashMap<ParkingEpisode>,
    /// Windows the window server showed displaced at the last audit. The AX
    /// move that parked them may not have landed yet, so a second sighting is
    /// needed before the audit acts.
    suspects: bevy::ecs::entity::EntityHashSet,
    /// When the audit next has something to do: every [`PARKING_AUDIT_EVERY`]
    /// at rest, sooner while a window is suspected or a correction is waiting.
    audit_due: Duration,
}

impl ParkingCorrections {
    /// Drops episodes of windows whose row is no longer hidden.
    fn retain_hidden(&mut self, strips: &HiddenRows) {
        let hidden = |entity: &Entity| strips.iter().any(|strip| strip.contains(*entity));
        self.episodes.retain(|entity, _| hidden(entity));
        self.suspects.retain(|entity| hidden(entity));
    }

    /// Whether [`Self::displaced`] would allow a correction now.
    fn may_correct(&self, entity: Entity, target: crate::manager::Origin, now: Duration) -> bool {
        self.episodes
            .get(&entity)
            .is_none_or(|episode| episode.target != target || now >= episode.retry_at)
    }

    /// A hidden-row window was seen displaced. Returns whether to send the
    /// corrective move now; when not, the audit will find it again later.
    fn displaced(&mut self, entity: Entity, target: crate::manager::Origin, now: Duration) -> bool {
        let episode = self
            .episodes
            .entry(entity)
            .or_insert_with(|| ParkingEpisode::new(target));
        if episode.target != target {
            *episode = ParkingEpisode::new(target);
        }
        episode.parked_since = None;
        if now < episode.retry_at {
            episode.pending = true;
            self.audit_due = self.audit_due.min(episode.retry_at);
            return false;
        }
        let wait = CORRECTION_BACKOFF[episode.corrections.min(CORRECTION_BACKOFF.len() - 1)];
        episode.retry_at = now + wait;
        episode.corrections += 1;
        episode.pending = false;
        true
    }

    /// The audit saw the window displaced but its wait is not over: remember
    /// to look again when it is.
    fn hold_back(&mut self, entity: Entity) {
        self.suspects.remove(&entity);
        if let Some(episode) = self.episodes.get_mut(&entity) {
            episode.pending = true;
        }
    }

    fn is_pending(&self, entity: Entity) -> bool {
        self.episodes
            .get(&entity)
            .is_some_and(|episode| episode.pending)
    }

    fn audit_is_due(&self, now: Duration) -> bool {
        now >= self.audit_due
    }

    /// Schedules the next audit after one has run at `now`.
    fn audit_done(&mut self, now: Duration) {
        let mut due = now + PARKING_AUDIT_EVERY;
        if !self.suspects.is_empty() {
            due = due.min(now + PARKING_RECHECK);
        }
        for episode in self.episodes.values().filter(|episode| episode.pending) {
            due = due.min(episode.retry_at.max(now + PARKING_RECHECK));
        }
        self.audit_due = due;
    }

    /// A hidden-row window was seen parked.
    fn parked(&mut self, entity: Entity, target: crate::manager::Origin, now: Duration) {
        self.suspects.remove(&entity);
        let Some(episode) = self.episodes.get_mut(&entity) else {
            return;
        };
        episode.pending = false;
        let since = *episode.parked_since.get_or_insert(now);
        if episode.target != target || now.saturating_sub(since) >= PARKED_SETTLE {
            self.episodes.remove(&entity);
        }
    }
}

impl ParkingEpisode {
    fn new(target: crate::manager::Origin) -> Self {
        Self {
            target,
            corrections: 0,
            retry_at: Duration::ZERO,
            parked_since: None,
            pending: false,
        }
    }
}

fn display_frames(displays: &Query<&Display>) -> Vec<IRect> {
    displays.iter().map(Display::bounds).collect()
}

#[instrument(level = Level::TRACE, skip_all)]
#[allow(clippy::too_many_arguments)]
pub(crate) fn window_moved_update_frame(
    mut messages: MessageReader<Event>,
    mut windows: MovableWindows,
    strips: HiddenRows,
    displays: Query<&Display>,
    time: Res<Time>,
    mut corrections: ResMut<ParkingCorrections>,
) {
    corrections.retain_hidden(&strips);
    let mut handled = HashSet::new();
    for event in messages.read() {
        let Event::WindowMoved { window_id } = event else {
            continue;
        };

        if !handled.insert(*window_id) {
            continue;
        }
        let Some((entity, mut window, mut position, bounds, unmanaged, repositioning)) = windows
            .iter_mut()
            .find(|window| window.1.id() == *window_id)
        else {
            continue;
        };
        if matches!(unmanaged, Some(Unmanaged::Minimized | Unmanaged::Hidden)) {
            continue;
        }
        // Our own move, echoed back: `animate_entities` lerps from the current
        // `Position`, so overwriting it with the echoed frame mid-animation
        // restarts each step from behind, and the two chase each other.
        if repositioning {
            continue;
        }
        let Ok(new_frame) = window.update_frame() else {
            continue;
        };

        // Background apps can restore/constrain their own frames after our
        // parking move. Accepting that echo strands the window on screen:
        // the strip did not change, so layout has no reason to place it again.
        // A real focus event activates the row separately; a move alone must
        // never make a hidden row visible. Keep visible-row mouse moves intact.
        let hidden_row = strips
            .iter()
            .any(|strip| strip.all_windows().contains(&entity));
        if hidden_row {
            // Judge by what shows, not by distance from the corner: AppKit
            // keeps a title bar on screen, so a parked window never sits
            // exactly where it was sent.
            let now = time.elapsed();
            if !intrudes_on_displays(new_frame, position.0, &display_frames(&displays)) {
                corrections.parked(entity, position.0, now);
            } else if corrections.displaced(entity, position.0, now) {
                info!(
                    "hidden-row window {window_id} moved on screen to {:?}; parking it again",
                    new_frame.min
                );
                window.reposition(position.0);
            }
            // Preserve the layout target even if an app refuses correction.
            continue;
        }
        let old_frame = IRect::from_corners(position.0, position.0 + bounds.0);
        if old_frame.min != new_frame.min {
            position.0 = new_frame.min;
        }
    }
}

/// Safety net for [`window_moved_update_frame`]: an app can move a hidden-row
/// window without telling us, or after its correction was backed off. Every
/// [`PARKING_AUDIT_EVERY`], while any hidden row holds windows, ask the window
/// server once where everything is. The system itself ticks faster, but
/// [`ParkingCorrections::audit_due`] brings the real work forward only for a
/// window seen displaced once (a second sighting is needed) or one whose held
/// back correction is now allowed. No per-window AX read happens unless a
/// window is shown displaced twice in a row or is pending, and the backoff in
/// [`ParkingCorrections`] bounds those.
#[instrument(level = Level::TRACE, skip_all)]
pub(crate) fn audit_parked_windows(
    mut windows: MovableWindows,
    strips: HiddenRows,
    displays: Query<&Display>,
    window_manager: Res<WindowManager>,
    time: Res<Time>,
    mut corrections: ResMut<ParkingCorrections>,
) {
    let now = time.elapsed();
    if !corrections.audit_is_due(now) {
        return;
    }
    corrections.retain_hidden(&strips);
    let hidden = strips
        .iter()
        .flat_map(LayoutStrip::all_windows)
        .collect::<Vec<_>>();
    if !hidden.is_empty()
        && let Some(on_screen) = window_manager.on_screen_window_bounds()
    {
        audit_hidden(
            &hidden,
            &on_screen,
            &display_frames(&displays),
            &mut windows,
            &mut corrections,
            now,
        );
    }
    corrections.audit_done(now);
}

fn audit_hidden(
    hidden: &[Entity],
    on_screen: &[(crate::platform::WinID, IRect)],
    displays: &[IRect],
    windows: &mut MovableWindows,
    corrections: &mut ParkingCorrections,
    now: Duration,
) {
    for &entity in hidden {
        let Ok((_, mut window, position, _, unmanaged, repositioning)) = windows.get_mut(entity)
        else {
            continue;
        };
        if repositioning || matches!(unmanaged, Some(Unmanaged::Minimized | Unmanaged::Hidden)) {
            continue;
        }
        // A window the server does not list is off screen altogether.
        let shown = on_screen
            .iter()
            .find(|(id, _)| *id == window.id())
            .map(|(_, frame)| *frame);
        if !shown.is_some_and(|frame| intrudes_on_displays(frame, position.0, displays)) {
            corrections.parked(entity, position.0, now);
            continue;
        }
        // First sighting only marks the window; the next audit decides. A
        // window already known to have moved needs no second look.
        if !corrections.is_pending(entity) && corrections.suspects.insert(entity) {
            continue;
        }
        if !corrections.may_correct(entity, position.0, now) {
            corrections.hold_back(entity);
            continue;
        }
        // Our own AX cache holds the position we asked for, which would make
        // `reposition` skip the move; read the real frame first.
        match window.update_frame() {
            Ok(frame) if !intrudes_on_displays(frame, position.0, displays) => {
                corrections.parked(entity, position.0, now);
            }
            Ok(frame) if corrections.displaced(entity, position.0, now) => {
                info!(
                    "audit: hidden-row window {} found on screen at {:?}; parking it again",
                    window.id(),
                    frame.min
                );
                window.reposition(position.0);
            }
            _ => {}
        }
    }
}

pub(crate) fn gather_initial_processes(
    receiver: Option<NonSendMut<Receiver<Event>>>,
    existing_config: Option<Res<Config>>,
    mut displays: Query<&mut Display>,
    mut commands: Commands,
) {
    let Some(receiver) = receiver else {
        // Probably running in a mock environment, ignore.
        return;
    };
    let mut initial_processes: Vec<BProcess> = Vec::new();
    let mut toml_config = None;
    loop {
        match receiver.recv().expect("error reading initial processes") {
            Event::ProcessesLoaded | Event::Exit => break,
            Event::ApplicationLaunched { psn, observer } => {
                let process: BProcess = Process::new(&psn, observer.clone()).into();
                if process.pid() != 0 {
                    initial_processes.push(process);
                } else {
                    debug!("Skipping process with PID 0 (likely kernel_task).");
                }
            }
            Event::InitialConfig(config) => {
                toml_config = Some(config);
            }
            event => warn!("Stray event during initial process gathering: {event:?}"),
        }
    }

    // A Lua `paneru.setup{...}` config is inserted at build time and wins; the
    // TOML config drained from the channel is only the fallback. Use whichever
    // is authoritative for the force-manage and menubar decisions below.
    let effective = existing_config
        .as_deref()
        .cloned()
        .or_else(|| toml_config.clone());

    if let Some(config) = &effective {
        let height = config.menubar_height();
        for mut display in &mut displays {
            display.set_menubar_height_override(height);
        }
    }

    while let Some(mut process) = initial_processes.pop() {
        let forced = effective
            .as_ref()
            .is_some_and(|c| c.should_force_manage_process(&**process));

        if process.is_observable() || forced {
            if forced {
                debug!(
                    "Forcing management of existing process '{}' despite unobservable policy.",
                    process.name()
                );
                process.force_manage(true);
            } else {
                debug!("Adding existing process {}", process.name());
            }
            commands.spawn((ExistingMarker, process));
        } else {
            debug!(
                "Existing application '{}' is not observable, ignoring it.",
                process.name(),
            );
        }
    }

    // The input event tap holds its own clone of the `Config` handle from
    // `InitialConfig` and reads swipe/scroll settings off it per event. A Lua
    // `paneru.setup{...}` builds a fresh handle, so its settings must be
    // published into the tap's existing handle rather than replacing it, or
    // gestures would keep reading stale settings.
    match (existing_config.as_deref(), toml_config) {
        #[cfg(feature = "lua")]
        (Some(lua_config), Some(shared)) => {
            shared.replace_inner_from(lua_config);
            commands.insert_resource(shared);
        }
        (None, Some(config)) => commands.insert_resource(config),
        _ => {}
    }
}

#[derive(Default)]
pub(super) struct OverlayWindowConfigCache {
    window_id: Option<WinID>,
    focused_border_radius: Option<f64>,
    detected_border_radius: Option<f64>,
}

#[allow(clippy::too_many_arguments)]
pub(super) fn update_overlays(
    // Gating lives in the `overlay_dirty` run condition (strip change *or*
    // focus change); this query just resolves the current active workspace.
    active_workspace: Populated<(Has<Scrolling>, &LayoutStrip), With<ActiveWorkspaceMarker>>,
    windows: Windows,
    applications: Query<&Application>,
    overlay_mgr: Option<NonSendMut<OverlayManager>>,
    mission_control_active: Res<MissionControlActive>,
    config: Res<Config>,
    mut window_config_cache: Local<OverlayWindowConfigCache>,
    window_manager: Res<WindowManager>,
) {
    use crate::overlay::BorderParams;
    use objc2_foundation::{NSPoint, NSRect, NSSize};

    let Some(mut overlay_mgr) = overlay_mgr else {
        return;
    };

    let dim_opacity = config.dim_inactive_opacity();
    let border_enabled = config.border_active_window();

    // Hide overlays during swipe, mission control, native fullscreen spaces,
    // or briefly after a space change (macOS space-switch animation).
    let Some((swiping, active_strip)) = active_workspace.iter().next() else {
        return;
    };

    if swiping || mission_control_active.0 || active_strip.is_fullscreen() {
        overlay_mgr.hide_all();
        return;
    }

    if dim_opacity == 0.0 && !border_enabled {
        overlay_mgr.remove_all();
        return;
    }

    let Some((window, entity)) = windows.focused() else {
        return;
    };
    let focused_window_id = window.id();
    let show_overlay = !window.is_full_screen()
        && (active_strip.contains(entity)
            // if the window is floating, check whether it's present in the workspace.
            || window_manager
                .windows_in_workspace(active_strip.id())
                .is_ok_and(|ids| ids.contains(&focused_window_id)));

    if !show_overlay {
        // No managed window on the active workspace has focus — hide the overlay rather than
        // dimming everything or drawing a ghost border around an off-screen window.
        overlay_mgr.hide_all();
        return;
    }

    // Find the focused managed window's absolute CG frame.
    let focused_abs_cg = {
        let frame = window.frame();
        let h_pad = window.horizontal_padding();
        let v_pad = window.vertical_padding();
        Some(NSRect::new(
            NSPoint::new(
                f64::from(frame.min.x + h_pad),
                f64::from(frame.min.y + v_pad),
            ),
            NSSize::new(
                f64::from(frame.width() - 2 * h_pad),
                f64::from(frame.height() - 2 * v_pad),
            ),
        ))
    };

    let border_params = if border_enabled {
        if window_config_cache.window_id != Some(focused_window_id) || config.is_changed() {
            let Some((window, _, parent)) = windows.find_parent(focused_window_id) else {
                return;
            };
            let Ok(app) = applications.get(parent) else {
                return;
            };
            let properties = WindowProperties::new(app, window, &config);
            window_config_cache.window_id = Some(focused_window_id);
            window_config_cache.focused_border_radius = properties.border_radius();
            window_config_cache.detected_border_radius = window.border_radius();
        }

        let calculated_radius = match config.border_radius() {
            BorderRadiusOption::Auto => window_config_cache.detected_border_radius.unwrap_or(10.0),
            BorderRadiusOption::Value(value) => value.max(0.0),
        };

        Some(BorderParams {
            color: config.border_color(),
            opacity: config.border_opacity(),
            width: config.border_width(),
            radius: window_config_cache
                .focused_border_radius
                .unwrap_or(calculated_radius),
        })
    } else {
        window_config_cache.window_id = None;
        None
    };

    let dim_color = config.dim_inactive_color();
    overlay_mgr.update(
        dim_opacity,
        dim_color,
        focused_abs_cg,
        border_params.as_ref(),
    );
}

#[instrument(level = Level::TRACE, skip_all)]
pub(super) fn commit_window_position(mut moved_windows: PositionCommits) {
    // `par_iter_mut` runs on `ComputeTaskPool` worker threads, which have no
    // `CFRunLoop` of their own to drain thread-local autorelease pools.
    moved_windows
        .par_iter_mut()
        .for_each(|(mut window, position, native)| {
            let mut origin = position.0;
            if let Some(native) = native {
                origin.x = native.x;
                if window.frame().min == origin {
                    return;
                }
            }
            objc2::rc::autoreleasepool(|_| window.reposition(origin));
        });
}

#[instrument(level = Level::TRACE, skip_all)]
pub(super) fn verify_window_position(mut windows: PositionVerifications, mut commands: Commands) {
    for (entity, mut window, position, mut verification) in &mut windows {
        if window
            .update_frame()
            .is_ok_and(|frame| frame.min == position.0)
        {
            if let Ok(mut entity_commands) = commands.get_entity(entity) {
                entity_commands.try_remove::<VerifyWindowPosition>();
            }
            continue;
        }

        window.reposition(position.0);
        if verification.tick()
            && let Ok(mut entity_commands) = commands.get_entity(entity)
        {
            entity_commands.try_remove::<VerifyWindowPosition>();
        }
    }
}

#[instrument(level = Level::TRACE, skip_all)]
pub(super) fn commit_window_size(active_display: ActiveDisplay, mut resized_windows: SizeCommits) {
    let display_bounds = active_display.bounds();
    resized_windows.par_iter_mut().for_each(
        |(mut window, size, mut width_ratio, native, sibling)| {
            width_ratio.0 = f64::from(size.0.x) / f64::from(display_bounds.width());
            let mut target = size.0;
            if let Some(native) = native {
                target.x = native.width;
                if window.frame().size() == target {
                    return;
                }
            }
            objc2::rc::autoreleasepool(|_| {
                if sibling.is_some() {
                    window.request_native_sibling_size(target);
                } else {
                    window.resize(target);
                }
            });
        },
    );
}

/// Check actual sibling frames, not optimistic cache or logical Bounds. The
/// latest target replaces the previous retry budget; no retry touches owner.
#[allow(clippy::type_complexity)]
pub(super) fn verify_native_sibling_resize(
    mut windows: ParamSet<(
        Populated<(Entity, &mut Window, &Bounds, &mut NativeSiblingResize)>,
        Query<&mut Bounds>,
    )>,
    held: Query<&MouseHeldMarker>,
    strips: Query<&LayoutStrip>,
    time: Res<Time>,
    mut commands: Commands,
) {
    let mut constraints = Vec::new();
    for (entity, mut window, bounds, mut pending) in &mut windows.p0() {
        if held.iter().any(|marker| marker.0 == entity) {
            // A new physical gesture outranks every older sibling request.
            commands.entity(entity).remove::<NativeSiblingResize>();
            continue;
        }
        let tracking = held.iter().any(|marker| marker.0 == pending.owner);
        if !tracking && !pending.released {
            // Tracking itself may make background AX requests unavailable.
            // Give the final target one fresh bounded budget after release
            // before treating an observed width as an application constraint.
            pending.released = true;
            pending.exhausted = false;
            pending.remaining = 6;
            pending.timer.reset();
        }
        if pending.exhausted && tracking {
            continue;
        }
        pending.timer.tick(time.delta());
        if !pending.timer.just_finished() {
            continue;
        }
        let frame = window.native_sibling_frame();
        if let Ok(frame) = frame
            && (frame.width() - pending.width).abs() <= 1
        {
            commands.entity(entity).remove::<NativeSiblingResize>();
            continue;
        }
        if pending.remaining > 0 {
            pending.remaining -= 1;
            let target = bounds.0.with_x(pending.width);
            window.request_native_sibling_size(target);
            continue;
        }
        if tracking {
            pending.exhausted = true;
            continue;
        }
        // A persistent minimum or rejection cannot be made smaller by ECS.
        // Reconcile a wider physical constraint only after the pointer releases.
        if let Ok(frame) = frame {
            let width = frame.width().max(pending.width);
            if let Some(column) = strips.iter().find_map(|strip| {
                strip
                    .index_of(entity)
                    .ok()
                    .and_then(|index| strip.get(index).ok())
            }) {
                constraints.push((column.window_iter().collect::<Vec<_>>(), width));
            }
            warn!(
                window_id = window.id(),
                requested_width = pending.width,
                actual_width = frame.width(),
                "native sibling resize exhausted bounded retries"
            );
        } else {
            warn!(
                window_id = window.id(),
                "native sibling frame unavailable after bounded retries"
            );
        }
        commands.entity(entity).remove::<NativeSiblingResize>();
    }
    for (members, width) in constraints {
        for member in members {
            if let Ok(mut bounds) = windows.p1().get_mut(member) {
                bounds.0.x = bounds.0.x.max(width);
            }
        }
    }
}

/// Reconcile once after release or a lost-release timeout. Populated keeps
/// this dormant whenever no native drag owns a window.
pub(super) fn finish_native_mouse_resize(
    resized: Populated<(Entity, &mut Position, &mut Bounds), With<NativeMouseResize>>,
    held: Query<&MouseHeldMarker>,
    mut strips: Query<&mut LayoutStrip>,
    mut commands: Commands,
) {
    for (entity, mut position, mut bounds) in resized {
        if held.iter().any(|marker| marker.0 == entity) {
            continue;
        }
        commands.entity(entity).remove::<NativeMouseResize>();
        position.set_changed();
        bounds.set_changed();
        for mut strip in &mut strips {
            if strip.contains(entity) {
                strip.set_changed();
            }
        }
    }
}

/// Restores user-visible window state before Paneru shuts down: clears any
/// brightness dim, removes the dim/border overlay window, and centers every
/// managed window on the display its frame center falls in.
pub(super) fn cleanup_on_exit(
    mut exit_events: MessageReader<AppExit>,
    mut all_windows: Query<&mut Window>,
    displays: Query<&Display>,
    window_manager: Res<WindowManager>,
    mut overlay_mgr: Option<NonSendMut<OverlayManager>>,
) {
    for _ in exit_events.read() {
        let ids = all_windows.iter().map(|w| w.id()).collect::<Vec<_>>();
        info!("exit cleanup: restoring {} window(s)", ids.len());
        window_manager.dim_windows(&ids, 0.0);

        if let Some(ref mut overlay_mgr) = overlay_mgr {
            overlay_mgr.remove_all();
        }

        let display_bounds = displays.iter().map(Display::bounds).collect::<Vec<_>>();
        if display_bounds.is_empty() {
            return;
        }

        for mut window in &mut all_windows {
            let frame = window.frame();
            let center = frame.center();
            let bounds = display_bounds
                .iter()
                .find(|b| {
                    center.x >= b.min.x
                        && center.x <= b.max.x
                        && center.y >= b.min.y
                        && center.y <= b.max.y
                })
                .copied()
                .unwrap_or(display_bounds[0]);

            let mut size = frame.size();
            if size.x > bounds.width() || size.y > bounds.height() {
                let new_size = bevy::math::IVec2::new(
                    size.x.min(bounds.width() * 9 / 10),
                    size.y.min(bounds.height() * 9 / 10),
                );
                window.resize(new_size);
                size = new_size;
            }

            let origin = bevy::math::IVec2::new(
                bounds.min.x + (bounds.width() - size.x) / 2,
                bounds.min.y + (bounds.height() - size.y) / 2,
            );
            info!(
                "exit cleanup: window {} -> origin {:?}, size {:?}",
                window.id(),
                origin,
                size
            );
            window.reposition(origin);
        }
    }
}

pub(crate) fn update_flash_messages(
    messages: Populated<(Entity, &FlashMessage, &Timeout)>,
    active_display: Single<(&Display, Entity), With<ActiveDisplayMarker>>,
    flash_mgr: Option<NonSendMut<FlashMessageManager>>,
    mut commands: Commands,
) {
    let Some(mut flash_manager) = flash_mgr else {
        return;
    };

    if messages.is_empty() {
        flash_manager.remove();
        return;
    }

    let (display, _) = *active_display;
    let bounds = display.bounds();
    let top_right = NSPoint::new(f64::from(bounds.max.x), f64::from(bounds.min.y));

    // When several FlashMessages coexist (rapid keypresses spawn a fresh
    // one per workspace switch before the previous timer expires), the
    // naïve loop would call `show()` for every one of them in arbitrary
    // order — the OSD ends up flickering between strings, and the moment
    // any one of them expires its `is_finished()` branch calls
    // `flash_manager.remove()` even though the newer ones are still
    // alive. Keep the newest (most time remaining), despawn the rest,
    // and render exactly once.
    let mut alive: Option<(Entity, &str, &Timeout)> = None;
    let mut stale: Vec<Entity> = Vec::new();
    for (entity, FlashMessage(flash), timeout) in messages {
        if timeout.timer.is_finished() {
            stale.push(entity);
            continue;
        }
        match alive {
            None => alive = Some((entity, flash, timeout)),
            Some((prev_entity, _, prev_timeout)) => {
                if timeout.timer.remaining() > prev_timeout.timer.remaining() {
                    stale.push(prev_entity);
                    alive = Some((entity, flash, timeout));
                } else {
                    stale.push(entity);
                }
            }
        }
    }

    for entity in stale {
        if let Ok(mut entity_commands) = commands.get_entity(entity) {
            entity_commands.try_despawn();
        }
    }

    if let Some((_, flash, timeout)) = alive {
        let opacity = timeout.timer.fraction_remaining();
        flash_manager.show(flash, opacity, top_right);
    } else {
        flash_manager.remove();
    }
}

pub(crate) fn update_low_power_state(low_power_mode: Option<ResMut<LowPowerMode>>) {
    let Some(mut state) = low_power_mode else {
        return;
    };
    let process_info = objc2_foundation::NSProcessInfo::processInfo();
    state.0 = process_info.isLowPowerModeEnabled();
}

#[instrument(level = Level::DEBUG, skip_all)]
pub(crate) fn window_creation_event(mut messages: MessageReader<Event>, mut commands: Commands) {
    for event in messages.read() {
        let Event::WindowCreated { element } = event else {
            continue;
        };

        if let Ok(window) = WindowOS::new(element)
            .inspect_err(|err| {
                trace!("not adding window {element:?}: {err}");
            })
            .map(|window| Window::new(Box::new(window)))
        {
            commands.trigger(SpawnWindowTrigger(vec![window]));
        }
    }
}

/// Managed windows whose geometry has settled: nothing in flight, so two of them
/// sharing a frame really do share it.
type SettledWindows<'w, 's> = Query<
    'w,
    's,
    (
        Entity,
        &'static Window,
        &'static Position,
        &'static Bounds,
        &'static ChildOf,
    ),
    (
        Without<Unmanaged>,
        Without<RepositionMarker>,
        Without<ResizeMarker>,
    ),
>;

/// Whether the app is showing `window_id` right now.
///
/// Two signals, because neither alone covers a native tab: the window server
/// stops listing a window it has ordered out, and an app drops a background tab
/// from its accessibility list while the window server still calls that tab on
/// screen. Ghostty does the latter. An empty accessibility list is an app that
/// did not answer, not an app showing nothing.
fn app_shows_window(ax_window_ids: &[WinID], on_screen: &[WinID], window_id: WinID) -> bool {
    on_screen.contains(&window_id)
        && (ax_window_ids.is_empty() || ax_window_ids.contains(&window_id))
}

/// Folds a background native tab that ended up in a column of its own back into
/// the column of the tab that is actually showing.
///
/// [`detect_tabbed_windows`] catches this when the tab window is created, but
/// only when the app has already stopped showing the sibling by then. Ghostty
/// does not always oblige, and the leftover column is a slot in the strip that
/// can never show anything: focus lands in it, the strip scrolls to it, and
/// there is nothing there.
///
/// Deliberately narrow. Two managed windows of one app share a frame exactly
/// only when they share a column, which is what this is repairing, and
/// [`app_shows_window`] is what tells a background tab from a window the user
/// can see.
#[allow(clippy::needless_pass_by_value)]
pub(crate) fn regroup_stray_native_tabs(
    windows: SettledWindows,
    apps: Query<&Application>,
    mut workspaces: Query<(&mut LayoutStrip, Has<ActiveWorkspaceMarker>)>,
    window_manager: Res<WindowManager>,
    mission_control: Res<MissionControlActive>,
    mut commands: Commands,
) {
    if mission_control.0 {
        return;
    }
    let Some(mut strip) = workspaces
        .iter_mut()
        .find_map(|(strip, active)| active.then_some(strip))
    else {
        return;
    };
    let Some(on_screen) = window_manager.windows_on_screen() else {
        return;
    };

    // Column tops only: a window sharing a column is already grouped, and
    // stacked siblings never share a frame.
    let tops = strip.all_columns();
    // Only a column of its own can be a stray: pulling a window out of a stack
    // or an existing tab group would break a grouping the user set up.
    let strays = strip
        .columns()
        .filter_map(|column| match column {
            Column::Single(entity) => Some(*entity),
            Column::Stack(_) | Column::Tabs(_) | Column::Fullscren(_) => None,
        })
        .collect::<Vec<_>>();
    // One accessibility round trip per app, not per window: this runs on a timer
    // and the call crosses into the app.
    let mut ax_windows: EntityHashMap<Vec<WinID>> = EntityHashMap::default();
    let columns = tops
        .into_iter()
        .filter_map(|entity| windows.get(entity).ok())
        .map(
            |(entity, window, Position(position), Bounds(bounds), child)| {
                let app = child.parent();
                let ax_window_ids = ax_windows.entry(app).or_insert_with(|| {
                    apps.get(app)
                        .map(|app| app.ax_window_ids())
                        .unwrap_or_default()
                });
                (
                    entity,
                    app_shows_window(ax_window_ids, &on_screen, window.id()),
                    *position,
                    *bounds,
                    app,
                )
            },
        )
        .collect::<Vec<_>>();

    let mut regrouped = Vec::new();
    for (hidden, showing, position, bounds, app) in &columns {
        if *showing || regrouped.contains(hidden) || !strays.contains(hidden) {
            continue;
        }
        let Some((leader, ..)) = columns.iter().find(
            |(
                candidate,
                candidate_showing,
                candidate_position,
                candidate_bounds,
                candidate_app,
            )| {
                *candidate_showing
                    && candidate != hidden
                    && candidate_app == app
                    && candidate_position.chebyshev_distance(*position) <= 1
                    && candidate_bounds.chebyshev_distance(*bounds) <= 1
            },
        ) else {
            continue;
        };

        debug!("stray native tab {hidden} folded into the column of {leader}");
        if strip
            .convert_to_tabs(*leader, *hidden)
            .inspect_err(|err| error!("Failed to convert to tabs: {err}"))
            .is_ok()
        {
            regrouped.push(*hidden);
        }
    }

    if let Some(leader) = regrouped.first() {
        commands.reshuffle_around(*leader);
    }
}

pub(crate) fn detect_tabbed_windows(
    created: Populated<(Entity, &Position, &Bounds, &ChildOf), Added<Window>>,
    windows: Query<(Entity, &Window, &Position, &Bounds, &ChildOf), With<Window>>,
    apps: Query<(Entity, &Application)>,
    mut workspaces: Query<(&mut LayoutStrip, Has<ActiveWorkspaceMarker>)>,
    window_manager: Res<WindowManager>,
    active_display: Single<&Display, With<ActiveDisplayMarker>>,
    mut commands: Commands,
) {
    let display_bounds = active_display.bounds();
    let Some(workspace_entities) = workspaces
        .iter()
        .find_map(|(strip, active)| active.then_some(strip.all_windows()))
    else {
        return;
    };

    for (entity, Position(position), Bounds(bounds), child) in created {
        let Ok((app_entity, app)) = apps.get(child.parent()) else {
            continue;
        };

        // First find all the windows which have the same size and the same parent app.
        // .. and in the same workspace.
        let mut same_size = workspace_entities
            .iter()
            .filter_map(|e| windows.get(*e).ok())
            .filter(|(leader, _, _, Bounds(leader_bounds), child)| {
                *leader != entity
                    && child.parent() == app_entity
                    && leader_bounds.chebyshev_distance(*bounds) <= 1
            })
            .collect::<Vec<_>>();
        if same_size.is_empty() {
            continue;
        }

        let on_screen = window_manager.windows_on_screen().unwrap_or_default();
        let ax_window_ids = app.ax_window_ids();
        // A leader the app has stopped showing is the tab this one replaced.
        let hidden_leader = |leader_id| !app_shows_window(&ax_window_ids, &on_screen, leader_id);

        // Now check whether any of these found windows have the same position?
        let tabbed = same_size
            .iter()
            .find_map(|(leader, window, Position(leader_position), _, _)| {
                // If the window has a positional match, it's tabbed! The hidden
                // test belongs here rather than after the search: a group the
                // app is already showing one member of would otherwise be
                // picked and then rejected, hiding the sibling that matches.
                (leader_position.chebyshev_distance(*position) <= 1 && hidden_leader(window.id()))
                    .then_some((*leader, window.id()))
            })
            .or_else(|| {
                // Otherwise if no windows were found by position, sort all the windows by distance
                // and then pick the one which is currently offscreen.
                // This heuristic relaxes the position matching, because the window is bumped into view.
                same_size.sort_by_key(|(_, _, Position(candidate_position), _, _)| {
                    position.x.abs_diff(candidate_position.x)
                });
                same_size.into_iter().find_map(
                    |(leader, window, Position(leader_position), Bounds(leader_bounds), _)| {
                        let offscreen = !display_bounds.contains(*leader_position)
                            || !display_bounds.contains(*leader_position + leader_bounds);
                        offscreen.then_some((leader, window.id()))
                    },
                )
            });

        if let Some((leader, leader_id)) = tabbed
            && hidden_leader(leader_id)
            && let Some((mut strip, _)) =
                workspaces.iter_mut().find(|strip| strip.0.contains(leader))
            && strip.contains(leader)
        {
            debug!("Tabbed window detected: adding {entity} to leader {leader}");
            if strip
                .convert_to_tabs(leader, entity)
                .inspect_err(|err| error!("Failed to convert to tabs: {err}"))
                .is_ok()
            {
                commands.focus_entity(entity, false);
            }
        }
    }
}

/// Listens for focus events for unknown window IDs and attempts to auto-discover
/// and manage them on the fly (e.g., when a user clicks an unmanaged tab or window).
#[allow(clippy::needless_pass_by_value)]
pub(crate) fn auto_discover_unmanaged_focused_windows(
    mut messages: MessageReader<Event>,
    windows: Query<&Window>,
    apps: Query<&Application>,
    config: Res<Config>,
    time: Res<Time>,
    mut cache: Local<HashMap<WinID, (Duration, usize)>>,
    mut commands: Commands,
) {
    const CACHE_CLEANUP_SIZE: usize = 1000;
    // A window the app cannot hand over yet (its role and subrole fill in a beat
    // after creation, as a terminal's do) is not unmanageable for good, so a failed
    // discovery is only remembered for a while before the window may be tried again.
    // Each try scans every app's windows, so a window that keeps failing (a panel
    // that takes focus on every use) waits longer each time: the last wait repeats.
    const RETRY_BACKOFF: [Duration; 4] = [
        Duration::from_secs(1),
        Duration::from_secs(4),
        Duration::from_secs(16),
        Duration::from_secs(64),
    ];
    if cache.len() > CACHE_CLEANUP_SIZE {
        cache.clear();
    }
    let now = time.elapsed();

    for event in messages.read() {
        let Event::WindowFocused { window_id } = *event else {
            continue;
        };

        if windows.iter().any(|w| w.id() == window_id)
            || cache.get(&window_id).is_some_and(|(failed_at, failures)| {
                let wait = RETRY_BACKOFF[(*failures - 1).min(RETRY_BACKOFF.len() - 1)];
                now.saturating_sub(*failed_at) < wait
            })
        {
            continue;
        }

        trace!("Focus event for unknown window id {window_id}; attempting on-the-fly discovery.");

        let mut discovered = None;
        let (frontmost, non_frontmost): (Vec<_>, Vec<_>) =
            apps.iter().partition(|app| app.is_frontmost());

        for app in frontmost.into_iter().chain(non_frontmost) {
            if let Some(window) = app.focused_window(&config)
                && window.id() == window_id
            {
                debug!("Discovered unknown focused window {window_id} via focused_window.");
                discovered = Some(window);
                break;
            }

            let window_list = app.window_list(&config);
            if let Some(window) = window_list.into_iter().find(|w| w.id() == window_id) {
                debug!("Discovered unknown focused window {window_id} via window_list scan.");
                discovered = Some(window);
                break;
            }
        }

        if let Some(window) = discovered {
            commands.trigger(SpawnWindowTrigger(vec![window]));
        } else {
            trace!(
                "Failed to discover manageable window for focused ID {window_id}; caching as unmanageable."
            );
            let failures = cache.get(&window_id).map_or(0, |(_, failures)| *failures);
            cache.insert(window_id, (now, failures + 1));
        }
    }
}

#[cfg(all(test, feature = "lua"))]
mod tests {
    use std::sync::mpsc::channel;

    use bevy::prelude::*;

    use super::gather_initial_processes;
    use crate::config::Config;
    use crate::events::Event;

    /// The input event tap keeps the handle it received on `InitialConfig` and
    /// reads swipe settings off it per event, so the Lua config must land in
    /// *that* handle rather than in a fresh one only the ECS can see.
    #[test]
    fn lua_config_reaches_the_handle_the_event_tap_holds() {
        let lua_config: Config = "[options]\n[swipe.gesture]\nfingers_count = 3\n"
            .try_into()
            .expect("config should parse");
        let tap_config = Config::defaults().expect("defaults should parse");
        assert_eq!(tap_config.swipe_gesture_fingers(), None);

        let (sender, receiver) = channel();
        sender
            .send(Event::InitialConfig(tap_config.clone()))
            .expect("send initial config");
        sender.send(Event::ProcessesLoaded).expect("send loaded");

        let mut app = App::new();
        app.insert_resource(lua_config);
        app.insert_non_send(receiver);
        app.add_systems(Update, gather_initial_processes);
        app.update();

        assert_eq!(tap_config.swipe_gesture_fingers(), Some(3));
    }
}

#[cfg(test)]
mod parking_correction_tests {
    use super::*;
    use crate::manager::Origin;

    const DISPLAY: IRect = IRect {
        min: Origin::new(0, 0),
        max: Origin::new(1512, 982),
    };

    fn at(secs: f32) -> Duration {
        Duration::from_secs_f32(secs)
    }

    #[test]
    fn corrections_back_off_and_successful_echoes_do_not_rearm() {
        let mut episodes = ParkingCorrections::default();
        let entity = Entity::from_bits(123);
        let target = Origin::new(1500, 970);
        let waits = [0.0, 0.25, 1.25, 5.25, 15.25, 25.25, 35.25];
        let mut now = 0.0;
        for wait in waits {
            // Seen displaced every half second between corrections.
            while now < wait {
                assert!(!episodes.displaced(entity, target, at(now)), "at {now}");
                now += 0.25;
            }
            assert!(episodes.displaced(entity, target, at(wait)), "at {wait}");
            episodes.parked(entity, target, at(wait));
            assert!(
                episodes.episodes.contains_key(&entity),
                "an echo of our own move keeps the episode"
            );
            now = wait + 0.25;
        }
        let mut episodes = ParkingCorrections::default();
        assert!(episodes.displaced(entity, target, at(0.0)));
        // A new target starts a new episode.
        assert!(episodes.displaced(entity, target + Origin::new(10, 0), at(0.1)));
        // Showing the row drops the episode (the systems call `retain_hidden`).
        episodes.episodes.remove(&entity);
        assert!(episodes.displaced(entity, target, at(0.2)));
    }

    #[test]
    fn staying_parked_ends_the_episode() {
        let mut episodes = ParkingCorrections::default();
        let entity = Entity::from_bits(123);
        let target = Origin::new(1500, 970);
        assert!(episodes.displaced(entity, target, at(0.0)));
        assert!(!episodes.displaced(entity, target, at(0.1)));
        episodes.parked(entity, target, at(2.0));
        episodes.parked(entity, target, at(4.0));
        assert!(episodes.episodes.contains_key(&entity));
        episodes.parked(entity, target, at(5.0));
        assert!(!episodes.episodes.contains_key(&entity));
        assert!(episodes.displaced(entity, target, at(5.1)));
    }

    #[test]
    fn a_held_back_displacement_brings_the_audit_forward() {
        let mut episodes = ParkingCorrections::default();
        let entity = Entity::from_bits(123);
        let target = Origin::new(1500, 970);
        assert!(episodes.displaced(entity, target, at(0.0)));
        assert!(episodes.displaced(entity, target, at(0.25)));
        // The next wait ends at 1.25.
        episodes.audit_done(at(0.25));
        assert!(!episodes.audit_is_due(at(1.0)), "at rest the audit waits");
        // A bounce inside the wait is dropped now, but remembered.
        assert!(!episodes.displaced(entity, target, at(0.75)));
        assert!(episodes.is_pending(entity));
        assert!(!episodes.audit_is_due(at(1.0)));
        assert!(episodes.audit_is_due(at(1.25)), "due when the wait ends");
        // An audit that runs early re-arms for the end of the wait, not 2 s on.
        episodes.audit_done(at(1.0));
        assert!(!episodes.audit_is_due(at(1.0)));
        assert!(episodes.audit_is_due(at(1.25)));
        // It then acts without a second sighting.
        assert!(episodes.displaced(entity, target, at(1.25)));
        assert!(!episodes.is_pending(entity));
        // Seeing the window parked clears the mark.
        assert!(!episodes.displaced(entity, target, at(1.5)));
        episodes.parked(entity, target, at(1.75));
        assert!(!episodes.is_pending(entity));
    }

    #[test]
    fn a_suspect_is_looked_at_again_soon() {
        let mut episodes = ParkingCorrections::default();
        let entity = Entity::from_bits(123);
        episodes.suspects.insert(entity);
        episodes.audit_done(at(10.0));
        assert!(episodes.audit_is_due(at(10.25)));
        assert!(!episodes.audit_is_due(at(10.0)));
        episodes.parked(entity, Origin::new(1500, 970), at(10.25));
        episodes.audit_done(at(10.25));
        assert!(!episodes.audit_is_due(at(11.0)));
        assert!(episodes.audit_is_due(at(12.25)));
    }

    #[test]
    fn only_a_visible_intrusion_is_displacement() {
        let target = Origin::new(1502, 972);
        let size = Origin::new(1496, 932);
        let frame = |origin: Origin| IRect::from_corners(origin, origin + size);
        let displays = [DISPLAY];
        // Exactly parked, and the clamped and slivered landings seen live.
        for origin in [target, Origin::new(1502, 931), Origin::new(1480, 950)] {
            assert!(!intrudes_on_displays(frame(origin), target, &displays));
        }
        // Back on screen where the user would see it.
        assert!(intrudes_on_displays(
            frame(Origin::new(16, 50)),
            target,
            &displays
        ));
        // A strip along one edge is a sliver, not an intrusion.
        assert!(!intrudes_on_displays(
            frame(Origin::new(16, 940)),
            target,
            &displays
        ));
    }

    #[test]
    fn a_display_that_shows_the_target_anyway_is_not_judged() {
        // Parked at the corner of a display with another to its right: the
        // target itself shows on that neighbour, so it cannot be a displacement.
        let right = IRect::from_corners(Origin::new(1512, 0), Origin::new(3024, 982));
        let target = Origin::new(1502, 100);
        let frame = IRect::from_corners(target, target + Origin::new(400, 400));
        assert!(!intrudes_on_displays(frame, target, &[DISPLAY, right]));
    }
}
