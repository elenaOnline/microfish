use std::collections::HashMap;
use std::time::Duration;

use bevy::app::{App, Plugin, PostUpdate, PreUpdate, Update};
use bevy::ecs::entity::Entity;
use bevy::ecs::hierarchy::ChildOf;
use bevy::ecs::lifecycle::{Add, Remove};
use bevy::ecs::message::MessageReader;
use bevy::ecs::observer::On;
use bevy::ecs::query::{Added, Has, With};
use bevy::ecs::resource::Resource;
use bevy::ecs::schedule::IntoScheduleConfigs as _;
use bevy::ecs::system::{Commands, Populated, Query, Res, ResMut, Single};
use bevy::math::IRect;
use bevy::prelude::Event as BevyEvent;
use bevy::time::common_conditions::on_timer;
use tracing::{Level, debug, error, info, instrument, trace, warn};

use super::{FocusedMarker, MouseHeldMarker, SystemTheme, Timeout, Unmanaged, VerifyFocus};
use crate::config::Config;
use crate::ecs::layout::LayoutStrip;
use crate::ecs::params::{ActiveDisplay, GlobalState, WindowCtx, Windows};
use crate::ecs::workspace::{RestoreFocusMarker, column_closest_to_center};
use crate::ecs::{
    ActiveWorkspaceMarker, Bounds, Position, RaiseWindow, ResizeMarker, Scrolling,
    SendMessageTrigger, SpawnCommandsExt, StrayFocusEvent,
};
use crate::events::Event;
use crate::manager::{Application, Display, Window, WindowManager};
use crate::platform::{Pid, ProcessSerialNumber, WorkspaceId};

const REFRESH_WINDOW_CHECK_FREQ_MS: u64 = 1000;
pub(crate) const VERIFY_FOCUS_TIMEOUT: Duration = Duration::from_millis(300);

#[derive(Default)]
pub struct TierMemory {
    pub last_managed: Option<Entity>,
    pub last_floating: Option<Entity>,
}

/// Keyed by `WorkspaceId` so toggling on one Space can't reach a window last
/// focused on another. Cleared on entity despawn (`forget`) so recycled
/// Entity IDs can't resolve to the wrong window, and on workspace despawn
/// (`forget_workspace`) to bound the map.
#[derive(Default, Resource)]
pub struct FocusHistory {
    by_workspace: HashMap<WorkspaceId, TierMemory>,
}

impl FocusHistory {
    pub fn record(
        &mut self,
        workspace: WorkspaceId,
        entity: Entity,
        unmanaged: Option<&Unmanaged>,
    ) {
        let slot = self.by_workspace.entry(workspace).or_default();
        match unmanaged {
            None => slot.last_managed = Some(entity),
            Some(Unmanaged::Floating) => slot.last_floating = Some(entity),
            Some(_) => {}
        }
    }

    pub fn last_managed(&self, workspace: WorkspaceId) -> Option<Entity> {
        self.by_workspace
            .get(&workspace)
            .and_then(|t| t.last_managed)
    }

    pub fn last_floating(&self, workspace: WorkspaceId) -> Option<Entity> {
        self.by_workspace
            .get(&workspace)
            .and_then(|t| t.last_floating)
    }

    pub fn forget(&mut self, entity: Entity) {
        for slot in self.by_workspace.values_mut() {
            if slot.last_managed == Some(entity) {
                slot.last_managed = None;
            }
            if slot.last_floating == Some(entity) {
                slot.last_floating = None;
            }
        }
    }

    pub fn forget_workspace(&mut self, workspace: WorkspaceId) {
        self.by_workspace.remove(&workspace);
    }
}

pub struct FocusEventsPlugin;

impl Plugin for FocusEventsPlugin {
    fn build(&self, app: &mut App) {
        app.init_resource::<FocusHistory>();
        app.init_resource::<KeyboardFocusHandoff>();
        app.init_resource::<KeyboardHold>();
        app.add_systems(
            PreUpdate,
            cancel_keyboard_focus
                .after(super::systems::pump_events)
                .run_if(bevy::ecs::schedule::common_conditions::on_message::<Event>),
        );
        app.add_systems(
            Update,
            (
                detect_focus_rejection.before(super::systems::timeout_ticker),
                fix_window_size_on_focus,
                resolve_keyboard_hold.run_if(|hold: Res<KeyboardHold>| hold.engaged()),
            ),
        );
        app.add_systems(
            PostUpdate,
            (
                autocenter_window_on_focus.after(super::systems::animate_resize_entities),
                mouse_follows_focus.after(super::systems::animate_resize_entities),
                confirm_keyboard_focus
                    .after(super::systems::animate_resize_entities)
                    .after(super::systems::animate_entities)
                    .after(super::systems::commit_window_position)
                    .after(super::systems::commit_window_size)
                    .run_if(|handoff: Res<KeyboardFocusHandoff>| handoff.active()),
                recover_lost_focus.run_if(on_timer(Duration::from_millis(
                    REFRESH_WINDOW_CHECK_FREQ_MS,
                ))),
            ),
        );
        app.add_observer(dim_remove_window_trigger)
            .add_observer(dim_window_trigger)
            .add_observer(maintain_focus_singleton)
            .add_observer(remember_selected_tab)
            .add_observer(maintain_verify_focus_singleton)
            .add_observer(virtual_strip_activated)
            .add_observer(stray_focus_observer)
            .add_observer(begin_keyboard_focus)
            .add_observer(focus_window_trigger)
            .add_observer(raise_window_trigger);
    }
}

#[derive(BevyEvent)]
pub(super) struct FocusWindow {
    pub entity: Entity,
    pub raise: bool,
    pub source: Option<Entity>,
}

/// Only explicit keyboard navigation gets bounded native confirmation. Swipes
/// continue to use their existing focus path.
#[derive(BevyEvent)]
pub(crate) struct KeyboardFocusRequest {
    pub target: Entity,
    pub source: Option<Entity>,
    /// The request reveals a row. A slow app is no reason to float its window
    /// or to fall back to the window parked on the row just left; see
    /// [`KeyboardFocusAttempt::row_switch`].
    pub row_switch: bool,
}

/// The engine holding the keyboard for an empty row.
///
/// Entering an empty row leaves the window that had focus parked and invisible.
/// Keystrokes must not reach it: typing or pressing Return into a terminal
/// nobody can see. So the engine makes itself the front process, which has no
/// window and no menu, and the keys go nowhere. The hold ends when a window
/// appears in the row, when the row stops being the active one, or when any
/// other process takes the front.
#[derive(Default, Resource)]
pub(crate) struct KeyboardHold(Option<HeldRow>);

#[derive(Clone, Copy)]
struct HeldRow {
    /// The empty row being held.
    row: Entity,
    /// The engine's own serial number, to tell its front switch from another's.
    own: ProcessSerialNumber,
    /// The app whose window was left parked, which ⌘N asks for a new window.
    previous: Option<Pid>,
}

impl KeyboardHold {
    pub(crate) fn engaged(&self) -> bool {
        self.0.is_some()
    }

    /// The app that was in front when the hold began.
    pub(crate) fn previous(&self) -> Option<Pid> {
        self.0.and_then(|held| held.previous)
    }

    pub(crate) fn engage(&mut self, row: Entity, own: ProcessSerialNumber, previous: Option<Pid>) {
        self.0 = Some(HeldRow { row, own, previous });
    }

    /// Ends the hold. The OS front process is left to whatever takes it next.
    pub(crate) fn release(&mut self) {
        if self.0.take().is_some() {
            crate::platform::hold::release();
        }
    }

    /// A front switch to `psn`: the engine's own is the hold taking effect, any
    /// other process (an app, Spotlight, Raycast) ends it.
    pub(super) fn front_switched(&mut self, psn: ProcessSerialNumber) {
        let Some(held) = self.0 else {
            return;
        };
        if held.own == psn {
            // The live proof that the hold took: without it the parked window
            // would still be the keyboard target.
            info!("empty row: the engine is front, keystrokes reach no window");
        } else {
            info!("empty row: front switch to another process, keyboard released");
            self.release();
        }
    }
}

/// A window appeared in the held row, or the row is no longer the active one:
/// the hold has done its job. A new window is visible, and the only thing in
/// view, so it is safe to give it the keyboard; that is what makes the
/// empty-row then ⌘N flow, and a window arriving from another app, work.
fn resolve_keyboard_hold(
    mut hold: ResMut<KeyboardHold>,
    strips: Query<(&LayoutStrip, Has<ActiveWorkspaceMarker>)>,
    mut commands: Commands,
) {
    let Some(current) = hold.0 else {
        return;
    };
    let Ok((strip, active)) = strips.get(current.row) else {
        hold.release();
        return;
    };
    if !active {
        hold.release();
        return;
    }
    if strip.len() == 0 {
        return;
    }
    hold.release();
    if let Some(target) = strip.first().ok().and_then(|column| column.top()) {
        info!(
            "empty row {} got a window: keyboard released to it",
            strip.virtual_index + 1
        );
        crate::commands::focus_with_verification(target, None, &mut commands);
    }
}

#[derive(Default, Resource)]
pub(crate) struct KeyboardFocusHandoff(Option<KeyboardFocusAttempt>);

impl KeyboardFocusHandoff {
    /// Drops any pending request. An empty row supersedes it: its target would
    /// put a parked window back in front of the keyboard.
    pub(crate) fn cancel(&mut self) {
        self.0 = None;
    }

    pub(super) fn cancel_target_in(&mut self, entities: &[Entity]) {
        if self
            .0
            .as_ref()
            .is_some_and(|attempt| entities.contains(&attempt.target))
        {
            self.0 = None;
        }
    }

    pub(super) fn active(&self) -> bool {
        self.0.is_some()
    }
}

struct KeyboardFocusAttempt {
    target: Entity,
    source: Option<Entity>,
    elapsed: Duration,
    next_check: Duration,
    retries: u8,
    confirmations: u8,
    prepared: bool,
    /// Other input arrived before the OS was asked to focus the target. That
    /// input may be about something else entirely (a resize, a swipe), in
    /// which case the request still has to be made, or it may move the focus
    /// itself, in which case it must not. The frame's other systems settle
    /// which; see [`confirm_keyboard_focus`].
    interrupted: bool,
    /// Revealing a row, like switching Spaces, is not undone because the app
    /// there is slow to take focus: no rejection float, and giving up leaves
    /// the row shown instead of reconciling to a window on a hidden row.
    row_switch: bool,
}

fn begin_keyboard_focus(
    trigger: On<KeyboardFocusRequest>,
    mut handoff: ResMut<KeyboardFocusHandoff>,
    windows: Windows,
    apps: Query<&Application>,
) {
    // Rapid repeated navigation advances the logical selection before native
    // focus catches up. Capture the actual source, not that optimistic marker.
    let source = apps
        .iter()
        .find(|app| app.is_frontmost())
        .and_then(|app| app.focused_window_id().ok())
        .and_then(|id| windows.find(id).map(|(_, entity)| entity))
        .or(trigger.source);
    handoff.0 = Some(KeyboardFocusAttempt {
        target: trigger.target,
        source,
        elapsed: Duration::ZERO,
        next_check: Duration::ZERO,
        retries: 0,
        confirmations: 0,
        prepared: false,
        interrupted: false,
        row_switch: trigger.row_switch,
    });
}

fn cancel_keyboard_focus(
    mut handoff: ResMut<KeyboardFocusHandoff>,
    mut messages: MessageReader<Event>,
) {
    // Consume the entire batch: a short-circuit iterator leaves old cancel
    // events unread, which could cancel the next keyboard request.
    let (mut clicked, mut interrupted) = (false, false);
    for event in messages.read() {
        match event {
            // The user took the focus themselves.
            Event::MouseDown { .. } | Event::CancelKeyboardFocusHandoff => clicked = true,
            Event::Command {
                command: crate::commands::Command::Window(crate::commands::Operation::Focus(_)),
            } => {}
            Event::Swipe { .. }
            | Event::VerticalSwipe { .. }
            | Event::Scroll { .. }
            | Event::VerticalScrollTick { .. }
            | Event::Command {
                command: crate::commands::Command::Window(_),
            } => interrupted = true,
            _ => {}
        }
    }
    if clicked {
        handoff.0 = None;
    } else if interrupted && let Some(attempt) = handoff.0.as_mut() {
        if attempt.prepared {
            // The OS has been asked once; what is left is only the check.
            handoff.0 = None;
        } else {
            attempt.interrupted = true;
        }
    }
}

type KeyboardRevealMarkers<'w, 's> = Query<
    'w,
    's,
    (),
    bevy::ecs::query::Or<(
        With<super::RepositionMarker>,
        With<super::ReshuffleAroundMarker>,
        With<super::EnsureVisibleMarker>,
        With<ResizeMarker>,
    )>,
>;

fn keyboard_reveal_pending(
    target: Entity,
    windows: &Windows,
    strips: &Query<(Entity, &mut LayoutStrip)>,
    origins: &Query<&Position, With<LayoutStrip>>,
    moving: &KeyboardRevealMarkers,
) -> bool {
    let strip = strips
        .iter()
        .find_map(|(entity, strip)| strip.contains(target).then_some(entity));
    let uncommitted = strip
        .and_then(|strip| origins.get(strip).ok())
        .zip(windows.layout_position(target))
        .is_some_and(|(origin, layout)| {
            let expected = origin.0 + layout.0;
            windows
                .frame(target)
                .is_none_or(|frame| frame.min != expected)
                || windows
                    .get(target)
                    .is_none_or(|window| window.frame().min != expected)
        });
    uncommitted || moving.contains(target) || strip.is_some_and(|entity| moving.contains(entity))
}

fn request_keyboard_native_focus(
    attempt: &KeyboardFocusAttempt,
    native_id: Option<crate::platform::WinID>,
    windows: &Windows,
    commands: &mut Commands,
) {
    commands.trigger(FocusWindow {
        entity: attempt.target,
        raise: false,
        source: native_id
            .and_then(|id| windows.find(id).map(|(_, entity)| entity))
            .or(attempt.source),
    });
}

fn activate_prepared_keyboard_target(
    attempt: &mut KeyboardFocusAttempt,
    native_id: Option<crate::platform::WinID>,
    windows: &Windows,
    commands: &mut Commands,
) {
    attempt.prepared = true;
    attempt.elapsed = Duration::ZERO;
    attempt.next_check = Duration::from_millis(150);
    if !attempt.row_switch
        && let Ok(mut entity_commands) = commands.get_entity(attempt.target)
    {
        entity_commands.try_insert((
            VerifyFocus,
            Timeout::for_component::<VerifyFocus>(VERIFY_FOCUS_TIMEOUT),
        ));
    }
    request_keyboard_native_focus(attempt, native_id, windows, commands);
}

/// Input arrived before the OS was asked to focus the target. A command that
/// moves the focus itself has already done so by now, and the target no longer
/// holds it: that command owns the focus. Otherwise the target is still what
/// the layout shows focused and the OS has to be told - left alone, a row
/// switch cut short by a resize would leave the keyboard in the window parked
/// on the row just left.
fn finish_interrupted_keyboard_focus(
    attempt: &KeyboardFocusAttempt,
    windows: &Windows,
    commands: &mut Commands,
) {
    if windows
        .focused()
        .is_some_and(|(_, focused)| focused == attempt.target)
    {
        request_keyboard_native_focus(attempt, None, windows, commands);
    }
}

#[allow(clippy::too_many_arguments, clippy::too_many_lines)]
fn confirm_keyboard_focus(
    mut handoff: ResMut<KeyboardFocusHandoff>,
    time: Res<bevy::time::Time>,
    windows: Windows,
    apps: Query<(Entity, &Application)>,
    strips: Query<(Entity, &mut LayoutStrip)>,
    strip_origins: Query<&Position, With<LayoutStrip>>,
    moving: KeyboardRevealMarkers,
    mut commands: Commands,
) {
    let Some(attempt) = handoff.0.as_mut() else {
        return;
    };
    if attempt.interrupted {
        finish_interrupted_keyboard_focus(attempt, &windows, &mut commands);
        handoff.0 = None;
        return;
    }
    attempt.elapsed += time.delta();
    if attempt.prepared {
        if attempt.elapsed < attempt.next_check {
            return;
        }
        attempt.next_check += Duration::from_millis(150);
    }
    let parent_of = |entity: Entity| {
        windows
            .get(entity)
            .and_then(|window| windows.find_parent(window.id()))
            .map(|(_, _, parent)| parent)
    };
    let Some(target_parent) = parent_of(attempt.target) else {
        handoff.0 = None;
        return;
    };
    let Some(target_window) = windows.get(attempt.target) else {
        handoff.0 = None;
        return;
    };
    let source_parent = attempt.source.and_then(parent_of);
    let native = apps
        .iter()
        .find(|(_, app)| app.is_frontmost())
        .map(|(parent, app)| (parent, app.focused_window_id().ok()));
    if native.is_some_and(|(parent, _)| parent != target_parent && Some(parent) != source_parent) {
        handoff.0 = None;
        return;
    }
    // Giving up hands the layout to whatever the OS focused. For a row switch
    // that is only right when it is on the row now shown: a window on the row
    // just left would make the switch bounce back to it.
    let reconcile_to = native.and_then(|(_, id)| id).filter(|id| {
        !attempt.row_switch
            || windows.find(*id).is_some_and(|(_, actual)| {
                strips
                    .iter()
                    .any(|(_, strip)| strip.contains(actual) && strip.contains(attempt.target))
            })
    });
    if !attempt.prepared {
        if keyboard_reveal_pending(attempt.target, &windows, &strips, &strip_origins, &moving) {
            if attempt.elapsed >= Duration::from_millis(600) {
                warn!(
                    window_id = target_window.id(),
                    "keyboard reveal did not settle before focus handoff"
                );
                if let Some(window_id) = reconcile_to {
                    commands.trigger(SendMessageTrigger(Event::WindowFocused { window_id }));
                }
                handoff.0 = None;
            }
            return;
        }
        activate_prepared_keyboard_target(
            attempt,
            native.and_then(|(_, id)| id),
            &windows,
            &mut commands,
        );
        return;
    }
    let confirmed = native.is_some_and(|(parent, id)| {
        parent == target_parent
            && id.is_some_and(|id| {
                id == target_window.id()
                    || windows.find_parent(id).is_some_and(|(_, actual, _)| {
                        shares_a_tab_group(&strips, &windows, attempt.target, actual)
                    })
            })
    });
    if confirmed {
        if attempt.confirmations == 0
            && let Some((_, Some(window_id))) = native
        {
            // This is a native AX acknowledgment, including the actual member
            // of a tab group, not the optimistic logical selection.
            commands.trigger(SendMessageTrigger(Event::WindowFocused { window_id }));
        }
        attempt.confirmations += 1;
        if attempt.confirmations >= 2 || attempt.elapsed >= Duration::from_millis(600) {
            handoff.0 = None;
        }
        return;
    }
    attempt.confirmations = 0;
    if attempt.retries < 2 && attempt.elapsed < Duration::from_millis(600) {
        attempt.retries += 1;
        // The first attempt already revealed the target. Retry after layout has
        // settled, rather than repeating the pre-reveal focus request.
        if let Ok(mut entity_commands) = commands.get_entity(attempt.target) {
            entity_commands.try_insert(FocusedMarker);
        }
        request_keyboard_native_focus(
            attempt,
            native.and_then(|(_, id)| id),
            &windows,
            &mut commands,
        );
        return;
    }
    warn!(
        window_id = target_window.id(),
        retries = attempt.retries,
        "keyboard focus handoff did not receive native confirmation"
    );
    if let Some(window_id) = reconcile_to {
        commands.trigger(SendMessageTrigger(Event::WindowFocused { window_id }));
    }
    handoff.0 = None;
}

fn remember_selected_tab(trigger: On<Add, FocusedMarker>, mut strips: Query<&mut LayoutStrip>) {
    let entity = trigger.event().entity;
    for mut strip in &mut strips {
        if strip.is_tabbed_display(entity) {
            strip.remember_selected_tab(entity);
        }
    }
}

#[instrument(level = Level::DEBUG, skip_all, fields(trigger))]
fn maintain_focus_singleton(
    trigger: On<Add, FocusedMarker>,
    windows: Query<(Entity, Has<FocusedMarker>), With<Window>>,
    mut config: GlobalState,
    mut commands: Commands,
) {
    let focused_entity = trigger.event().entity;

    for (entity, focused) in windows {
        if focused
            && entity != focused_entity
            && let Ok(mut entity_commands) = commands.get_entity(entity)
        {
            debug!("window {entity} lost focus.");
            entity_commands.try_remove::<FocusedMarker>();
        }
    }

    // Check if the reshuffle was caused by a keyboard switch or mouse move.
    // Skip reshuffle if caused by mouse - because then it won't center.
    if config.ffm_flag().is_none() {
        config.set_skip_reshuffle(false);
    }
    config.set_ffm_flag(None);
}

/// Whether two windows are members of one native tab group: the app shows one
/// of them at a time, and focusing any of them can leave the focus on the one
/// the app decided to show.
///
/// The strip knows the ones it has already grouped. The rest are recognised the
/// same way [`super::systems::detect_tabbed_windows`] recognises them in the
/// first place: same app, same frame.
fn shares_a_tab_group(
    workspaces: &Query<(Entity, &mut LayoutStrip)>,
    windows: &Windows,
    target: Entity,
    actual: Entity,
) -> bool {
    if workspaces.iter().any(|(_, strip)| {
        strip
            .tab_group(target)
            .is_some_and(|group| group.contains(&actual))
    }) {
        return true;
    }

    let parent_of = |entity: Entity| {
        windows
            .get(entity)
            .and_then(|window| windows.find_parent(window.id()))
            .map(|(_, _, parent)| parent)
    };
    let (Some(target_app), Some(actual_app)) = (parent_of(target), parent_of(actual)) else {
        return false;
    };
    if target_app != actual_app {
        return false;
    }

    windows
        .frame(target)
        .zip(windows.frame(actual))
        .is_some_and(|(target_frame, actual_frame)| {
            target_frame.min.chebyshev_distance(actual_frame.min) <= 1
                && target_frame.size().chebyshev_distance(actual_frame.size()) <= 1
        })
}

#[instrument(level = Level::DEBUG, skip_all, fields(focused))]
fn fix_window_size_on_focus(
    focused: Single<Entity, Added<FocusedMarker>>,
    mut windows: Query<(&mut Window, &mut Bounds, Has<ResizeMarker>)>,
) {
    if let Ok((mut window, mut bounds, resizing)) = windows.get_mut(*focused)
        && !resizing
        && let Ok(frame) = window.update_frame()
        && frame.size() != bounds.0
    {
        debug!("fixing window {} size!", window.id());
        bounds.0 = frame.size();
    }
}

/// Ensures at most one window entity carries [`VerifyFocus`] at any time, so
/// rapid focus switching cancels verification on intermediate windows.
#[instrument(level = Level::DEBUG, skip_all, fields(trigger))]
fn maintain_verify_focus_singleton(
    trigger: On<Add, VerifyFocus>,
    verifying: Query<Entity, With<VerifyFocus>>,
    mut commands: Commands,
) {
    let target = trigger.event().entity;
    for entity in verifying {
        if entity != target
            && let Ok(mut entity_commands) = commands.get_entity(entity)
        {
            entity_commands.try_remove::<(Timeout, VerifyFocus)>();
        }
    }
}

#[instrument(level = Level::DEBUG, skip_all)]
fn detect_focus_rejection(
    pending: Populated<(Entity, &Window, &ChildOf, &Timeout), With<VerifyFocus>>,
    apps: Query<&Application>,
    mut workspaces: Query<(Entity, &mut LayoutStrip)>,
    windows: Windows,
    mut commands: Commands,
) {
    for (target_entity, target_window, child_of, timeout) in &pending {
        if !timeout.timer.is_finished() {
            continue;
        }
        let Ok(app) = apps.get(child_of.parent()) else {
            continue;
        };
        // Only treat as a rejection if the target window's application is
        // currently frontmost and reports a different window of the same app
        // as focused.
        if !app.is_frontmost() {
            continue;
        }
        let Ok(actual_window_id) = app.focused_window_id() else {
            continue;
        };
        if actual_window_id == target_window.id() {
            continue;
        }
        let Some((actual_window, actual_entity, actual_parent)) =
            windows.find_parent(actual_window_id)
        else {
            continue;
        };
        if actual_parent != child_of.parent() {
            continue;
        }
        // If focus in the ECS world has already moved to a third window (neither
        // `target_entity` nor `actual_entity`), do not treat it as a rejection.
        if windows
            .focused()
            .is_some_and(|(_, focused)| focused != target_entity && focused != actual_entity)
        {
            continue;
        }

        // Native tabs share one slot: asking for a background tab makes the app
        // select it, and the focus notification names whichever tab of the group
        // the app ended up showing. That is the app doing what was asked, not
        // refusing it — floating the window here is how a tabbed terminal ends up
        // scattered across the layout as windows nothing tiles.
        if shares_a_tab_group(&workspaces, &windows, target_entity, actual_entity) {
            debug!(
                "focus landed on tab sibling {actual_entity} of {target_entity}; not a rejection.",
            );
            continue;
        }

        info!(
            "focus rejection detected: requested window {} ({target_entity}), app focused window {} ({actual_entity}) instead; floating {target_entity}.",
            target_window.id(),
            actual_window.id(),
        );
        if let Ok(mut entity_commands) = commands.get_entity(target_entity) {
            entity_commands
                .try_remove::<(Timeout, VerifyFocus)>()
                .try_insert(Unmanaged::Floating);
        }
        for (_, mut strip) in &mut workspaces {
            if strip.contains(target_entity) {
                strip.remove(target_entity);
            }
        }
        commands.focus_entity(actual_entity, false);
    }
}

#[instrument(level = Level::DEBUG, skip_all, fields(trigger))]
fn autocenter_window_on_focus(
    pinned: Query<
        (),
        (
            With<super::view_history::ViewLock>,
            With<ActiveWorkspaceMarker>,
        ),
    >,
    focused: Single<Entity, Added<FocusedMarker>>,
    mouse_held: Query<&MouseHeldMarker>,
    restored: Query<&RestoreFocusMarker>,
    global_state: GlobalState,
    active_display: ActiveDisplay,
    mut ctx: WindowCtx,
) {
    let entity = *focused;
    if !pinned.is_empty() {
        return;
    }

    // Skip auto-centering when this focus came from a workspace restore, since
    // the strip is already at its saved origin. window_focused_trigger and
    // timeout_ticker are responsible for clearing the marker.
    if restored.iter().any(|marker| marker.entity == entity) {
        return;
    }

    if global_state.skip_reshuffle() || global_state.initializing() || !mouse_held.is_empty() {
        return;
    }
    if active_display.active_strip().tabbed(entity) {
        return;
    }
    if ctx.config.auto_center()
        && let Some((_, _, None)) = ctx.windows.get_managed(entity)
        && let Some(size) = ctx.windows.size(entity)
        && let Some(mut origin) = ctx.windows.origin(entity)
    {
        let center = active_display.bounds().center();
        origin.x = center.x - size.x / 2;
        ctx.commands.reposition_entity(entity, origin);
    }
    ctx.commands.reshuffle_around(entity);
}

#[instrument(level = Level::DEBUG, skip_all, fields(trigger))]
fn mouse_follows_focus(
    focused: Single<Entity, Added<FocusedMarker>>,
    windows: Windows,
    global_state: GlobalState,
    config: Res<Config>,
    window_manager: Res<WindowManager>,
    displays: Query<&Display>,
    workspaces: Query<(
        &LayoutStrip,
        &ChildOf,
        Option<&Scrolling>,
        Has<ActiveWorkspaceMarker>,
    )>,
) {
    let entity = *focused;
    let Some(window) = windows.get(entity) else {
        return;
    };
    if workspaces
        .iter()
        .find_map(|(_, _, scrolling, active)| if active { scrolling } else { None })
        .is_some_and(|scrolling| scrolling.is_user_swiping)
    {
        debug!("Suppressing center mouse due to a swipe");
        return;
    }

    trace!(
        "window {}, skip_reshuffle {}, ffm flag {:?}.",
        window.id(),
        global_state.skip_reshuffle(),
        global_state.ffm_flag()
    );
    if config.mouse_follows_focus()
        && !global_state.skip_reshuffle()
        && global_state.ffm_flag().is_none_or(|id| id != window.id())
        && let Some(frame) = windows.moving_frame(entity)
        && let Some(display_bounds) = workspaces
            .into_iter()
            .find_map(|(strip, child, _, _)| strip.contains(entity).then_some(child))
            .and_then(|child| displays.get(child.parent()).ok())
            .map(Display::bounds)
    {
        let visible = display_bounds.intersect(frame);
        // If the overlap is smaller than 50x50, the window is probably hidden
        // off screen, so do not move the mouse.
        if visible.size().length_squared() > 5000 {
            let origin = visible.center();
            debug!("centering on {} {origin}", window.id());
            window_manager.warp_mouse(origin);
        }
    }
}

fn dim_window_trigger(
    trigger: On<Add, FocusedMarker>,
    windows: Windows,
    window_manager: Res<WindowManager>,
    config: Res<Config>,
    theme: Option<Res<SystemTheme>>,
) {
    let Some(window) = windows.get(trigger.event().entity) else {
        return;
    };

    let dark = theme.is_some_and(|theme| theme.is_dark);
    if config.window_dim_ratio(dark).is_some() {
        window_manager.dim_windows(&[window.id()], 0.0);
    }
}

fn dim_remove_window_trigger(
    trigger: On<Remove, FocusedMarker>,
    windows: Windows,
    active_display: ActiveDisplay,
    window_manager: Res<WindowManager>,
    config: Res<Config>,
    theme: Option<Res<SystemTheme>>,
) {
    let Some((window, _, None)) = windows.get_managed(trigger.event().entity) else {
        return;
    };

    let same_display = active_display
        .active_strip()
        .contains(trigger.event().entity);
    if !same_display {
        // Do not dim the window loosing focus on another display.
        return;
    }

    let dark = theme.is_some_and(|theme| theme.is_dark);
    if let Some(dim_ratio) = config.window_dim_ratio(dark) {
        window_manager.dim_windows(&[window.id()], dim_ratio);
    }
}

#[instrument(level = Level::DEBUG, skip_all, fields(trigger))]
fn virtual_strip_activated(
    trigger: On<Add, FocusedMarker>,
    workspaces: Query<(Entity, &LayoutStrip, Has<ActiveWorkspaceMarker>)>,
    mut commands: Commands,
) {
    let owner_strip = workspaces.into_iter().find_map(|(entity, strip, active)| {
        (strip.contains(trigger.entity) && !active).then_some(entity)
    });
    if let Some(entity) = owner_strip
        && let Ok(mut entity_commands) = commands.get_entity(entity)
    {
        entity_commands.try_insert(ActiveWorkspaceMarker);
    }
}

fn focus_window_trigger(
    trigger: On<FocusWindow>,
    windows: Windows,
    apps: Query<&Application>,
    verifying: Query<Entity, With<VerifyFocus>>,
    mut commands: Commands,
) {
    let FocusWindow {
        entity,
        raise,
        source,
    } = *trigger.event();
    for other in verifying {
        if other != entity
            && let Ok(mut entity_commands) = commands.get_entity(other)
        {
            entity_commands.try_remove::<(Timeout, VerifyFocus)>();
        }
    }
    let Some(window) = windows.get(entity) else {
        return;
    };
    let Some(psn) = windows.psn(window.id(), &apps) else {
        return;
    };
    if !raise
        && let Some(focused_window) = source
            .and_then(|entity| windows.get(entity))
            .or_else(|| windows.focused().map(|(window, _)| window))
        && let Some(focused_psn) = windows.psn(focused_window.id(), &apps)
    {
        window.focus_without_raise(psn, focused_window, focused_psn);
    } else {
        window.focus_with_raise(psn);
    }
}

fn raise_window_trigger(
    trigger: On<RaiseWindow>,
    windows: Query<(Entity, &Window, &Position, &Bounds)>,
    active_display: ActiveDisplay,
    config: Res<Config>,
) {
    let RaiseWindow { entity, with_strip } = *trigger.event();

    let Ok((focus, window, _, _)) = windows.get(entity) else {
        return;
    };

    if with_strip {
        let viewport = active_display.actual_bounds(&config);
        let strip = active_display.active_strip();
        strip
            .all_windows()
            .into_iter()
            .filter_map(|entity| {
                if entity == focus {
                    None
                } else {
                    windows.get(entity).ok()
                }
            })
            .filter(|(_, _, origin, size)| {
                let frame = IRect::from_corners(origin.0, origin.0 + size.0);
                viewport.intersect(frame).width() > 50
            })
            .for_each(|(_, window, _, _)| {
                window.raise_without_focus();
            });
    }

    // Raise the focused window last, because raised windows get OS focus events.
    window.raise_without_focus();
}

#[instrument(level = Level::DEBUG, skip_all)]
fn recover_lost_focus(
    windows: Windows,
    active_workspace: Query<&LayoutStrip, With<ActiveWorkspaceMarker>>,
    active_display: ActiveDisplay,
    hold: Res<KeyboardHold>,
    mut commands: Commands,
) {
    // An empty row holds the keyboard on purpose: no window has focus.
    if windows.focused().is_some() || hold.engaged() {
        return;
    }
    // The column the user is looking at, as when a row is shown again. The
    // active strip is on screen, so its real frames say where that is.
    if let Ok(strip) = active_workspace
        .single()
        .inspect_err(|err| error!("Unable to get current workspace: {err}"))
        && let Some(entity) = column_closest_to_center(strip, active_display.display(), &windows)
            .or_else(|| strip.first().ok().and_then(|col| col.top()))
    {
        error!("Lost focus marker, recovering!");
        commands.focus_entity(entity, false);
    }
}

pub(super) fn stray_focus_observer(
    trigger: On<Add, Window>,
    focus_events: Populated<(Entity, &StrayFocusEvent)>,
    windows: Windows,
    mut commands: Commands,
) {
    let entity = trigger.event().entity;
    let Some(window_id) = windows.get(entity).map(|window| window.id()) else {
        return;
    };

    focus_events
        .iter()
        .filter(|(_, stray_focus)| stray_focus.0 == window_id)
        .for_each(|(timeout_entity, _)| {
            debug!("Re-queueing lost focus event for window id {window_id}.");
            commands.trigger(SendMessageTrigger(Event::WindowFocused { window_id }));
            if let Ok(mut entity_commands) = commands.get_entity(timeout_entity) {
                entity_commands.try_despawn();
            }
        });
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::manager::MockWindowApi;
    use crate::manager::app::MockApplicationApi;
    use crate::platform::WinID;
    use bevy::ecs::world::World;

    fn spawn_app(world: &mut World, frontmost: bool, focused_id: WinID) -> Entity {
        let mut api = MockApplicationApi::new();
        api.expect_is_frontmost().returning(move || frontmost);
        api.expect_focused_window_id()
            .returning(move || Ok(focused_id));
        world.spawn(Application::new(Box::new(api))).id()
    }

    fn spawn_window(world: &mut World, app: Entity, id: WinID) -> Entity {
        let mut api = MockWindowApi::new();
        api.expect_id().returning(move || id);
        world
            .spawn((
                Window::new(Box::new(api)),
                Position(bevy::math::IVec2::ZERO),
                Bounds(bevy::math::IVec2::new(800, 600)),
                ChildOf(app),
            ))
            .id()
    }

    fn expired_verify_timeout() -> Timeout {
        let mut timeout = Timeout::for_component::<VerifyFocus>(VERIFY_FOCUS_TIMEOUT);
        timeout.timer.tick(VERIFY_FOCUS_TIMEOUT);
        timeout
    }

    #[test]
    fn record_and_read_per_tier() {
        let mut world = World::new();
        let managed = world.spawn(()).id();
        let floating = world.spawn(()).id();
        let mut history = FocusHistory::default();

        history.record(1, managed, None);
        history.record(1, floating, Some(&Unmanaged::Floating));

        assert_eq!(history.last_managed(1), Some(managed));
        assert_eq!(history.last_floating(1), Some(floating));
    }

    #[test]
    fn record_ignores_minimized_and_hidden() {
        let mut world = World::new();
        let entity = world.spawn(()).id();
        let mut history = FocusHistory::default();

        history.record(1, entity, Some(&Unmanaged::Minimized));
        history.record(1, entity, Some(&Unmanaged::Hidden));

        assert_eq!(history.last_managed(1), None);
        assert_eq!(history.last_floating(1), None);
    }

    #[test]
    fn per_workspace_isolation() {
        let mut world = World::new();
        let a = world.spawn(()).id();
        let b = world.spawn(()).id();
        let mut history = FocusHistory::default();

        history.record(1, a, None);
        history.record(2, b, None);

        assert_eq!(history.last_managed(1), Some(a));
        assert_eq!(history.last_managed(2), Some(b));
    }

    #[test]
    fn forget_clears_entity_across_workspaces() {
        let mut world = World::new();
        let target = world.spawn(()).id();
        let other = world.spawn(()).id();
        let mut history = FocusHistory::default();

        history.record(1, target, None);
        history.record(2, target, Some(&Unmanaged::Floating));
        history.record(2, other, None);

        history.forget(target);

        assert_eq!(history.last_managed(1), None);
        assert_eq!(history.last_floating(2), None);
        assert_eq!(history.last_managed(2), Some(other));
    }

    #[test]
    fn forget_workspace_drops_entry() {
        let mut world = World::new();
        let entity = world.spawn(()).id();
        let mut history = FocusHistory::default();

        history.record(1, entity, None);
        history.forget_workspace(1);

        assert_eq!(history.last_managed(1), None);
    }

    /// Native tabs share a slot: the app answering with a sibling of the tab
    /// group is it doing what was asked, so the requested window must keep its
    /// place in the layout.
    #[test]
    fn focus_landing_on_a_tab_sibling_is_not_a_rejection() {
        let mut world = World::new();
        let app = spawn_app(&mut world, true, 2);
        let target = spawn_window(&mut world, app, 1);
        let sibling = spawn_window(&mut world, app, 2);

        let mut strip = LayoutStrip::default();
        strip.append(target);
        strip
            .convert_to_tabs(target, sibling)
            .expect("target is in the strip");
        world.spawn(strip);

        world
            .entity_mut(target)
            .insert((FocusedMarker, VerifyFocus, expired_verify_timeout()));

        let system_id = world.register_system(detect_focus_rejection);
        _ = world.run_system(system_id);

        assert!(
            world.get::<Unmanaged>(target).is_none(),
            "a tab sibling taking the focus must not float the requested tab"
        );
        let mut strips = world.query::<&LayoutStrip>();
        assert!(
            strips.single(&world).expect("one strip").contains(target),
            "and must not take it out of the layout"
        );
    }

    #[test]
    fn focus_rejection_floats_target_and_clears_verify_focus() {
        let mut world = World::new();
        let app = spawn_app(&mut world, true, 2);
        let target = spawn_window(&mut world, app, 1);
        let actual = spawn_window(&mut world, app, 2);
        // Move actual so it does not share a frame with target (not a tab group).
        world
            .entity_mut(actual)
            .insert(Position(bevy::math::IVec2::new(800, 0)));

        let mut strip = LayoutStrip::default();
        strip.append(target);
        strip.append(actual);
        world.spawn(strip);

        world
            .entity_mut(target)
            .insert((FocusedMarker, VerifyFocus, expired_verify_timeout()));

        let system_id = world.register_system(detect_focus_rejection);
        _ = world.run_system(system_id);

        assert!(
            world
                .get::<Unmanaged>(target)
                .is_some_and(|u| matches!(u, Unmanaged::Floating))
        );
        assert!(world.get::<VerifyFocus>(target).is_none());
        assert!(world.get::<Timeout>(target).is_none());
    }

    #[test]
    fn rapid_switching_cancels_verify_focus_on_previous_window() {
        let mut world = World::new();
        world.add_observer(maintain_verify_focus_singleton);

        let app = spawn_app(&mut world, true, 2);
        let first = spawn_window(&mut world, app, 1);
        let second = spawn_window(&mut world, app, 2);

        world
            .entity_mut(first)
            .insert((VerifyFocus, expired_verify_timeout()));
        world
            .entity_mut(second)
            .insert((VerifyFocus, expired_verify_timeout()));
        world.flush();

        assert!(
            world.get::<VerifyFocus>(first).is_none(),
            "arming VerifyFocus on a new window must cancel it on the previous window"
        );
        assert!(world.get::<Timeout>(first).is_none());
        assert!(world.get::<VerifyFocus>(second).is_some());
    }
    #[derive(Default, Resource)]
    struct KeyboardRetryTargets(Vec<(Entity, Option<Entity>, bool)>);

    fn keyboard_fixture() -> (World, Entity, std::sync::Arc<std::sync::atomic::AtomicI32>) {
        use std::sync::{
            Arc,
            atomic::{AtomicI32, Ordering},
        };
        let mut world = World::new();
        let native = Arc::new(AtomicI32::new(1));
        let mut entities = Vec::new();
        for id in 1..=3 {
            let mut api = MockApplicationApi::new();
            let state = native.clone();
            api.expect_is_frontmost()
                .returning(move || state.load(Ordering::SeqCst) == id);
            api.expect_focused_window_id().returning(move || Ok(id));
            let app = world.spawn(Application::new(Box::new(api))).id();
            entities.push(spawn_window(&mut world, app, id));
        }
        let source = entities[0];
        let target = entities[1];
        world.entity_mut(target).insert(FocusedMarker);
        world.insert_resource(KeyboardFocusHandoff(Some(KeyboardFocusAttempt {
            target,
            source: Some(source),
            elapsed: Duration::ZERO,
            next_check: Duration::from_millis(150),
            retries: 0,
            confirmations: 0,
            prepared: true,
            interrupted: false,
            row_switch: false,
        })));
        let mut time = bevy::time::Time::<()>::default();
        time.advance_by(Duration::from_millis(150));
        world.insert_resource(time);
        world.init_resource::<bevy::ecs::message::Messages<Event>>();
        world.init_resource::<KeyboardRetryTargets>();
        world.add_observer(
            |event: On<FocusWindow>, mut retries: ResMut<KeyboardRetryTargets>| {
                retries.0.push((event.entity, event.source, event.raise));
            },
        );
        (world, target, native)
    }

    #[test]
    fn keyboard_handoff_retries_native_cross_app_refusal_and_reclaim() {
        use std::sync::atomic::Ordering;
        let (mut world, target, native) = keyboard_fixture();
        let source = world
            .resource::<KeyboardFocusHandoff>()
            .0
            .as_ref()
            .unwrap()
            .source;
        let system = world.register_system(confirm_keyboard_focus);
        // The optimistic ECS marker must not count as native confirmation.
        world.run_system(system).unwrap();
        let pending = world.resource::<KeyboardFocusHandoff>().0.as_ref().unwrap();
        assert_eq!(pending.retries, 1);
        assert_eq!(pending.confirmations, 0);
        assert!(world.get::<FocusedMarker>(target).is_some());
        native.store(2, Ordering::SeqCst);
        world.run_system(system).unwrap();
        assert_eq!(
            world
                .resource::<KeyboardFocusHandoff>()
                .0
                .as_ref()
                .unwrap()
                .confirmations,
            1
        );
        // The old app reclaims after one native acknowledgment: retry once more.
        native.store(1, Ordering::SeqCst);
        world.run_system(system).unwrap();
        assert_eq!(
            world
                .resource::<KeyboardFocusHandoff>()
                .0
                .as_ref()
                .unwrap()
                .retries,
            2
        );
        native.store(2, Ordering::SeqCst);
        world.run_system(system).unwrap();
        assert!(world.resource::<KeyboardFocusHandoff>().0.is_none());
        assert_eq!(
            world.resource::<KeyboardRetryTargets>().0,
            vec![(target, source, false), (target, source, false)]
        );
    }

    #[test]
    fn keyboard_handoff_stops_after_two_refusals_without_floating_target() {
        let (mut world, target, _) = keyboard_fixture();
        let system = world.register_system(confirm_keyboard_focus);
        for _ in 0..4 {
            world.run_system(system).unwrap();
        }
        assert!(world.resource::<KeyboardFocusHandoff>().0.is_none());
        assert!(world.get::<Unmanaged>(target).is_none());
    }

    #[test]
    fn keyboard_handoff_yields_to_click_app_switch_and_swipe() {
        use std::sync::atomic::Ordering;
        for event in [
            Event::CancelKeyboardFocusHandoff,
            Event::MouseDown {
                point: objc2_core_foundation::CGPoint::new(0.0, 0.0),
                modifiers: crate::platform::Modifiers::empty(),
            },
            Event::Swipe {
                delta: 1.0,
                fingers: 3,
            },
        ] {
            let (mut world, _, _) = keyboard_fixture();
            world.write_message(event);
            let cancel = world.register_system(cancel_keyboard_focus);
            world.run_system(cancel).unwrap();
            let system = world.register_system(confirm_keyboard_focus);
            world.run_system(system).unwrap();
            assert!(world.resource::<KeyboardFocusHandoff>().0.is_none());
            assert!(world.resource::<KeyboardRetryTargets>().0.is_empty());
        }
        let (mut world, _, native) = keyboard_fixture();
        native.store(3, Ordering::SeqCst);
        let system = world.register_system(confirm_keyboard_focus);
        world.run_system(system).unwrap();
        assert!(world.resource::<KeyboardFocusHandoff>().0.is_none());
    }
    #[test]
    fn old_click_is_drained_before_a_new_keyboard_request() {
        let (mut world, target, _) = keyboard_fixture();
        world.write_message(Event::CancelKeyboardFocusHandoff);
        world.write_message(Event::CancelKeyboardFocusHandoff);
        let cancel = world.register_system(cancel_keyboard_focus);
        world.run_system(cancel).unwrap();
        assert!(world.resource::<KeyboardFocusHandoff>().0.is_none());
        world.add_observer(begin_keyboard_focus);
        world.trigger(KeyboardFocusRequest {
            target,
            source: None,
            row_switch: false,
        });
        world.run_system(cancel).unwrap();
        assert!(world.resource::<KeyboardFocusHandoff>().active());
    }
    #[test]
    fn keyboard_reveal_commits_geometry_before_native_activation() {
        use std::sync::{Arc, Mutex};
        let (mut world, target, _) = keyboard_fixture();
        let source = world
            .resource::<KeyboardFocusHandoff>()
            .0
            .as_ref()
            .unwrap()
            .source;
        let physical = Arc::new(Mutex::new(IRect::new(0, 0, 800, 600)));
        let frame = physical.clone();
        let mut api = MockWindowApi::new();
        api.expect_id().return_const(2);
        api.expect_frame().returning(move || *frame.lock().unwrap());
        world.entity_mut(target).insert((
            Window::new(Box::new(api)),
            super::super::WidthRatio(0.5),
            super::super::LayoutPosition(bevy::math::IVec2::new(400, 0)),
        ));
        let mut strip = LayoutStrip::default();
        strip.append(target);
        world.spawn((strip, Position(bevy::math::IVec2::new(200, 0))));
        {
            let mut handoff = world.resource_mut::<KeyboardFocusHandoff>();
            let attempt = handoff.0.as_mut().unwrap();
            attempt.prepared = false;
            attempt.next_check = Duration::ZERO;
        }
        let system = world.register_system(confirm_keyboard_focus);
        world.run_system(system).unwrap();
        assert!(world.resource::<KeyboardRetryTargets>().0.is_empty());
        // Logical geometry alone is insufficient: the native commit still lags.
        world
            .entity_mut(target)
            .insert(Position(bevy::math::IVec2::new(600, 0)));
        world.run_system(system).unwrap();
        assert!(world.resource::<KeyboardRetryTargets>().0.is_empty());
        *physical.lock().unwrap() = IRect::new(600, 0, 1400, 600);
        world.run_system(system).unwrap();
        assert_eq!(
            world.resource::<KeyboardRetryTargets>().0,
            vec![(target, source, false)]
        );
    }

    #[test]
    fn rapid_keyboard_request_replaces_old_target_and_uses_native_source() {
        let (mut world, old_target, _) = keyboard_fixture();
        let source = world
            .resource::<KeyboardFocusHandoff>()
            .0
            .as_ref()
            .unwrap()
            .source;
        let new_target = world
            .query::<(Entity, &Window)>()
            .iter(&world)
            .find_map(|(e, w)| (w.id() == 3).then_some(e))
            .unwrap();
        world.add_observer(begin_keyboard_focus);
        world.trigger(KeyboardFocusRequest {
            target: new_target,
            source: Some(old_target),
            row_switch: false,
        });
        let pending = world.resource::<KeyboardFocusHandoff>().0.as_ref().unwrap();
        assert_eq!(pending.target, new_target);
        assert_eq!(pending.source, source);
        assert!(!pending.prepared);
        assert!(world.resource::<KeyboardRetryTargets>().0.is_empty());
    }
    #[test]
    fn keyboard_native_tab_sibling_acknowledgment_does_not_retry() {
        use std::sync::atomic::Ordering;
        let (mut world, target, native) = keyboard_fixture();
        let parent = world.get::<ChildOf>(target).unwrap().parent();
        let mut app = MockApplicationApi::new();
        let active = native.clone();
        app.expect_is_frontmost()
            .returning(move || active.load(Ordering::SeqCst) == 2);
        app.expect_focused_window_id().return_const(Ok(20));
        world
            .entity_mut(parent)
            .insert(Application::new(Box::new(app)));
        let sibling = spawn_window(&mut world, parent, 20);
        let mut strip = LayoutStrip::default();
        strip.append(target);
        strip.convert_to_tabs(target, sibling).unwrap();
        world.spawn(strip);
        native.store(2, Ordering::SeqCst);
        let system = world.register_system(confirm_keyboard_focus);
        world.run_system(system).unwrap();
        world.run_system(system).unwrap();
        assert!(world.resource::<KeyboardFocusHandoff>().0.is_none());
        assert!(world.resource::<KeyboardRetryTargets>().0.is_empty());
    }
}
