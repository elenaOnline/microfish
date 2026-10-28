use bevy::app::{App, Plugin, Update};
use bevy::ecs::entity::Entity;
use bevy::ecs::message::MessageReader;
use bevy::ecs::query::{With, Without};
use bevy::ecs::schedule::IntoScheduleConfigs as _;
use bevy::ecs::system::{Commands, Local, Populated, Res, Single};
use bevy::math::IRect;
use bevy::time::Time;
use std::time::{Duration, Instant};
use tracing::{Level, instrument};

use crate::commands::{Command, Direction, Operation};
use crate::config::Config;
use crate::config::swipe::SwipeGestureDirection;
use crate::ecs::layout::{Column, LayoutStrip};
use crate::ecs::params::{ActiveDisplay, Windows};
use crate::ecs::{
    ActiveWorkspaceMarker, ManualStripOffset, MissionControlActive, Position, RepositionMarker,
    Scrolling, SendMessageTrigger,
};
use crate::errors::Result;
use bevy::ecs::schedule::common_conditions::on_message;

use crate::events::{Event, InputEvent};
use crate::manager::{Window, WindowManager};
use crate::platform::Modifiers;
use crate::util::round_px;

pub struct ScrollEventsPlugin;

pub(super) fn edge_snap_enabled() -> bool {
    static ENABLED: std::sync::LazyLock<bool> = std::sync::LazyLock::new(|| {
        std::env::var("PANERU_TRIAL_EDGE_SNAP").is_ok_and(|value| value == "1")
    });
    *ENABLED
}

/// Choose the closest legal left, center, or right alignment after a short
/// velocity projection. Oversized columns contribute only their two edges.
fn landing_offset(
    current: f64,
    velocity_px: f64,
    left: i32,
    right: i32,
    columns: &[(i32, i32)],
) -> Option<f64> {
    let first = columns.first()?;
    let last = columns.last()?;
    let upper = f64::from(left - first.0);
    let lower = f64::from(right - last.0 - last.1).min(upper);
    let projected = (current + velocity_px * 0.12).clamp(lower, upper);
    columns
        .iter()
        .flat_map(|&(x, width)| {
            let l = f64::from(left - x);
            let r = f64::from(right - x - width);
            let c = if width <= right - left {
                l.midpoint(r)
            } else {
                l
            };
            [
                l.clamp(lower, upper),
                c.clamp(lower, upper),
                r.clamp(lower, upper),
            ]
        })
        .min_by(|a, b| (a - projected).abs().total_cmp(&(b - projected).abs()))
}

/// Upper bound on the timestep used to *advance* the strip.
///
/// `Time::<Virtual>` is deliberately given a 10s `max_delta` (see [`crate::ecs`])
/// so `elapsed()` keeps tracking wall-clock across a stalled frame — the
/// finger-lift timeout below depends on that. It is the wrong bound for
/// integration: a frame delayed by a blocking AX round trip would otherwise
/// advance the strip by `velocity * dt * viewport_width` in one step and slam
/// it into the far clamp bound. Integrate at most one 30fps frame per update,
/// however long the frame actually took.
const MAX_STEP_SECS: f64 = 1.0 / 30.0;

/// Lower bound on the timestep used to *derive* a velocity from a gesture delta.
///
/// Here the true delta is what we want — a backlog drained after a stall really
/// does represent that much finger travel over that much time. The hazard is
/// the opposite one: on a catch-up frame `dt` approaches zero, and
/// `gesture_delta / dt` diverges.
const MIN_STEP_SECS: f64 = 1.0 / 1000.0;

/// The on-screen strip, its origin, and the scroll state being applied to it.
type ScrollingStrip<'w, 's> = Single<
    'w,
    's,
    (
        &'static LayoutStrip,
        &'static mut Position,
        &'static mut Scrolling,
    ),
    (With<ActiveWorkspaceMarker>, Without<Window>),
>;

impl Plugin for ScrollEventsPlugin {
    fn build(&self, app: &mut App) {
        let mission_control_inactive = |mission_control: Option<Res<MissionControlActive>>| {
            mission_control.is_none_or(|active| !active.0)
        };

        // Only the two gesture systems are gated on an input event. The rest of
        // the chain (inertia, snap force, integrator) must keep running after
        // the fingers stop sending events, since that's when they take over.
        app.add_systems(
            Update,
            (
                vertical_swipe_gesture
                    .run_if(mission_control_inactive)
                    .run_if(on_message::<InputEvent>),
                (
                    swipe_gesture
                        .run_if(mission_control_inactive)
                        .run_if(on_message::<InputEvent>),
                    apply_inertia,
                    apply_snap_force,
                    scrolling_integrator,
                    apply_scrolling_constraints,
                    swiping_timeout,
                )
                    .chain(),
            ),
        );
    }
}

#[instrument(level = Level::TRACE, skip_all)]
fn swipe_gesture(
    mut messages: MessageReader<InputEvent>,
    active_display: ActiveDisplay,
    mut active_workspace: Single<
        (Entity, &Position, Option<&mut Scrolling>),
        With<ActiveWorkspaceMarker>,
    >,
    time: Res<Time>,
    config: Res<Config>,
    mut commands: Commands,
) {
    let swipe_sensitivity = config.swipe_sensitivity();
    let mut total_delta = 0.0;
    let mut gesture_delta = 0.0;
    let mut touchpad_down = false;
    let mut contact = None;
    let mut has_scroll_event = false;
    let mut has_gesture_event = false;

    // Normalization: Touchpad deltas are typically small fractions.
    // Scroll wheel deltas can be larger. We scale it down slightly
    // to match the "feel" of a finger swipe.
    const SCROLL_SCALE_UPPER: f64 = 0.15;
    const SCROLL_SCALE_LOWER: f64 = 0.005;
    const SCROLL_FULL_RANGE: f64 = 2.0;
    let scroll_scale = SCROLL_SCALE_LOWER
        + ((SCROLL_SCALE_UPPER - SCROLL_SCALE_LOWER) / SCROLL_FULL_RANGE) * swipe_sensitivity;

    for InputEvent(event) in messages.read() {
        match event {
            Event::TouchpadDown => {
                touchpad_down = true;
                contact = Some(true);
                total_delta = 0.0;
            }
            Event::TouchpadUp | Event::MouseDown { .. } => {
                contact = Some(false);
            }
            Event::Scroll { delta } => {
                total_delta += *delta * scroll_scale;
                has_scroll_event = true;
            }
            Event::Swipe { delta, fingers }
                if config
                    .swipe_gesture_fingers()
                    .is_some_and(|fingers_configured| fingers_configured == *fingers) =>
            {
                contact = Some(true);
                total_delta += delta;
                gesture_delta += delta;
                has_scroll_event = true;
                has_gesture_event = true;
            }
            _ => (),
        }
    }

    if !touchpad_down && !has_scroll_event && contact.is_none() {
        return;
    }

    let (entity, position, scrolling) = &mut *active_workspace;

    // The user is driving the strip by hand now, so an earlier deliberate
    // placement (center, snap) no longer describes where they want it.
    if has_scroll_event
        && total_delta.abs() > f64::EPSILON
        && let Ok(mut entity_commands) = commands.get_entity(*entity)
    {
        entity_commands.try_remove::<ManualStripOffset>();
        entity_commands.try_remove::<RepositionMarker>();
    }

    if touchpad_down && let Some(scrolling) = scrolling.as_mut() {
        scrolling.snap_target = None;
        scrolling.velocity = 0.0;
        scrolling.is_user_swiping = true;
        scrolling.last_event = time.elapsed();
    }

    if let Some(held) = contact
        && let Some(scroll) = scrolling.as_mut()
    {
        update_contact(scroll, held, time.elapsed());
    }

    if has_scroll_event && total_delta.abs() > f64::EPSILON {
        let viewport_width = f64::from(active_display.bounds().width());
        let direction_modifier = match config.swipe_gesture_direction() {
            SwipeGestureDirection::Natural => -1.0,
            SwipeGestureDirection::Reversed => 1.0,
        };

        // Floored, not capped: dividing by the real elapsed time is correct
        // here, but a catch-up frame can drive `dt` arbitrarily close to zero.
        let dt = time.delta_secs_f64().max(MIN_STEP_SECS);
        let new_velocity = if has_gesture_event {
            gesture_delta * swipe_sensitivity / dt
        } else {
            0.0
        };

        if let Some(scrolling) = scrolling.as_mut() {
            scrolling.snap_target = None;
            // Native modifier-scroll events already include macOS momentum.
            // Add synthetic inertia only for raw multi-finger gestures.
            scrolling.velocity = if has_gesture_event {
                // Smoothen gesture velocity changes using EMA.
                0.3 * new_velocity + 0.7 * scrolling.velocity
            } else {
                0.0
            };
            scrolling.is_user_swiping = contact != Some(false);
            scrolling.last_event = time.elapsed();
            scrolling.position +=
                total_delta * viewport_width * direction_modifier * swipe_sensitivity;
        } else if let Ok(mut entity_commands) = commands.get_entity(*entity) {
            entity_commands.try_insert(Scrolling {
                touch_held: contact == Some(true),
                snap_target: None,
                velocity: new_velocity,
                position: f64::from(position.0.x)
                    + total_delta * viewport_width * direction_modifier * swipe_sensitivity,
                is_user_swiping: contact != Some(false),
                last_event: time.elapsed(),
            });
        }
    }
}

fn update_contact(scroll: &mut Scrolling, held: bool, now: Duration) {
    scroll.touch_held = held;
    if !held {
        if now.saturating_sub(scroll.last_event) > Duration::from_millis(50) {
            scroll.velocity = 0.0;
        }
        scroll.is_user_swiping = false;
    }
}

// Pausing with fingers down keeps layout reconciliation and snapping blocked.
fn hold_touch(scroll: &mut Scrolling, quiet: Duration) -> bool {
    if !scroll.touch_held {
        return false;
    }
    if quiet > Duration::from_millis(50) {
        scroll.velocity = 0.0;
    }
    true
}

#[instrument(level = Level::TRACE, skip_all)]
pub(super) fn swiping_timeout(
    strips: Populated<(Entity, &mut Scrolling), With<LayoutStrip>>,
    active_display: ActiveDisplay,
    time: Res<Time>,
    window_manager: Res<WindowManager>,
    mut commands: Commands,
) {
    const FINGER_LIFT_THRESHOLD: Duration = Duration::from_millis(50);
    const MIN_VELOCITY_PX: f64 = 5.0;
    // Predicts the distance the integrator is about to move, so it has to use
    // the same bounded step the integrator does.
    let dt = time.delta_secs_f64().min(MAX_STEP_SECS);
    let viewport_width = f64::from(active_display.bounds().width());

    for (entity, mut scroll) in strips {
        let quiet = time.elapsed().abs_diff(scroll.last_event);
        if edge_snap_enabled() && hold_touch(&mut scroll, quiet) {
            continue;
        }
        if !scroll.is_user_swiping || quiet > FINGER_LIFT_THRESHOLD {
            scroll.is_user_swiping = false;

            let landed = if edge_snap_enabled() {
                scroll
                    .snap_target
                    .is_some_and(|target| (scroll.position - target).abs() <= 1.0)
            } else {
                true
            };
            if landed
                && scroll.velocity.abs() * dt * viewport_width < MIN_VELOCITY_PX
                && let Ok(mut entity_commands) = commands.get_entity(entity)
            {
                entity_commands.try_remove::<Scrolling>();
            }
            if let Some(point) = window_manager.cursor_position() {
                commands.trigger(SendMessageTrigger(Event::MouseMoved {
                    point,
                    modifiers: Modifiers::empty(),
                }));
            }
        }
    }
}

#[instrument(level = Level::TRACE, skip_all)]
fn apply_inertia(
    mut strips: Populated<(Entity, &mut Scrolling), With<LayoutStrip>>,
    time: Res<Time>,
    config: Res<Config>,
) {
    let dt = time.delta_secs_f64();
    for (_, mut scroll) in &mut strips {
        if scroll.is_user_swiping {
            continue;
        }

        if scroll.velocity.abs() > 0.001 {
            // Unbounded on purpose: decay is monotonic toward zero, so a long
            // frame can only shed more momentum, never overshoot. After a stall
            // that is what we want.
            let decay_rate = config.swipe_deceleration();
            scroll.velocity *= (-decay_rate * dt).exp();
        } else {
            scroll.velocity = 0.0;
        }
    }
}

#[instrument(level = Level::TRACE, skip_all)]
fn apply_snap_force(
    mut strip: Single<(&LayoutStrip, &Position, &mut Scrolling)>,
    active_display: ActiveDisplay,
    windows: Windows,
    config: Res<Config>,
    time: Res<Time>,
) {
    const CENTER_MAGNETIC_FORCE: f64 = 10.0;
    const SNAP_DISPLAY_RATIO: f64 = 0.45;

    if edge_snap_enabled() {
        let viewport = active_display.actual_bounds(&config);
        let (layout, _, ref mut scroll) = *strip;
        if scroll.is_user_swiping {
            return;
        }
        if scroll.snap_target.is_none() {
            let columns: Vec<_> = layout
                .all_columns()
                .into_iter()
                .filter_map(|entity| {
                    Some((
                        windows.layout_position(entity)?.0.x,
                        windows.moving_frame(entity)?.width(),
                    ))
                })
                .collect();
            let direction = match config.swipe_gesture_direction() {
                SwipeGestureDirection::Natural => -1.0,
                SwipeGestureDirection::Reversed => 1.0,
            };
            scroll.snap_target = landing_offset(
                scroll.position,
                scroll.velocity * f64::from(viewport.width()) * direction,
                viewport.min.x,
                viewport.max.x,
                &columns,
            )
            .or(Some(scroll.position));
        }
        scroll.velocity = 0.0;
        if let Some(target) = scroll.snap_target {
            let delta = target - scroll.position;
            let step = delta * (1.0 - (-18.0 * time.delta_secs_f64().min(MAX_STEP_SECS)).exp());
            // Constraints quantize each frame: finish subpixel tails explicitly.
            scroll.position = if delta.abs() <= 2.0 {
                target
            } else {
                scroll.position + step
            };
        }
        return;
    }
    if !config.auto_center() {
        return;
    }

    let viewport = active_display.actual_bounds(&config);
    let viewport_center = viewport.center().x;
    let snap_threshold = SNAP_DISPLAY_RATIO * f64::from(viewport.width());

    let (strip, position, ref mut scroll) = *strip;
    if scroll.is_user_swiping || scroll.velocity.abs() > 0.5 {
        return;
    }

    let target_offset = strip
        .all_columns()
        .into_iter()
        .filter_map(|entity| {
            windows
                .layout_position(entity)
                .map(|p| p.0.x)
                .zip(Some(entity))
        })
        .map(|(position, entity)| {
            let col_width = windows.moving_frame(entity).map_or(0, |f| f.width());
            viewport_center - (position + col_width / 2)
        })
        .min_by_key(|target| (position.x - target).abs())
        .unwrap_or(position.x);

    let dist_to_snap = f64::from(position.x - target_offset);
    if dist_to_snap.abs() < snap_threshold {
        // This is an exponential approach, and it only pulls *toward* the
        // target while the factor stays under 1. Past that it overshoots to the
        // far side; at a 10s delta it would fling the strip 100x the distance
        // the wrong way. Clamping the factor rather than `dt` keeps that true
        // for any timestep and any `CENTER_MAGNETIC_FORCE`.
        let approach = (time.delta_secs_f64() * CENTER_MAGNETIC_FORCE).min(1.0);
        scroll.position -= dist_to_snap * approach;
    }
}

#[instrument(level = Level::TRACE, skip_all)]
fn scrolling_integrator(
    mut strip: Single<&mut Scrolling, With<LayoutStrip>>,
    time: Res<Time>,
    active_display: ActiveDisplay,
    config: Res<Config>,
) {
    let dt = time.delta_secs_f64().min(MAX_STEP_SECS);
    let viewport = active_display.actual_bounds(&config);
    let viewport_width = f64::from(viewport.width());

    // Direction modifier: Natural moves strip left (negative offset) for positive delta (finger left)
    let direction_modifier = match config.swipe_gesture_direction() {
        SwipeGestureDirection::Natural => -1.0,
        SwipeGestureDirection::Reversed => 1.0,
    };

    let scroll = &mut *strip;
    if edge_snap_enabled() && scroll.is_user_swiping {
        return;
    }
    if scroll.velocity.abs() > 0.0001 {
        scroll.position += scroll.velocity * dt * viewport_width * direction_modifier;
    }
}

#[instrument(level = Level::TRACE, skip_all)]
fn apply_scrolling_constraints(
    mut strip: ScrollingStrip,
    active_display: ActiveDisplay,
    windows: Windows,
    config: Res<Config>,
) {
    let viewport = active_display.actual_bounds(&config);
    let (strip, ref mut position, ref mut scroll) = *strip;

    let get_window_frame = |entity| windows.moving_frame(entity);
    if let Some(clamped_offset) = clamp_viewport_offset(
        round_px(scroll.position),
        strip,
        &windows,
        &get_window_frame,
        &viewport,
        &config,
    ) {
        position.x = clamped_offset;
        // Keep fractional progress during the snap tail; rounding it away on
        // every fast tick would stall before reaching the target.
        if !edge_snap_enabled() || clamped_offset != round_px(scroll.position) {
            scroll.position = f64::from(clamped_offset);
        }
    } else {
        scroll.velocity = 0.0;
    }
}

#[instrument(level = Level::TRACE, skip_all)]
fn clamp_viewport_offset<W>(
    current_offset: i32,
    layout_strip: &LayoutStrip,
    windows: &Windows,
    get_window_frame: &W,
    viewport: &IRect,
    config: &Config,
) -> Option<i32>
where
    W: Fn(Entity) -> Option<IRect>,
{
    let total_strip_width = layout_strip
        .last()
        .ok()
        .and_then(|column| column.top())
        .and_then(|entity| {
            windows
                .layout_position(entity)
                .zip(get_window_frame(entity))
        })
        .map(|(position, frame)| position.x + frame.width())?;

    let continuous_swipe = config.continuous_swipe();
    let strip_position = |column: Result<Column>| {
        column
            .ok()
            .and_then(|column| column.top())
            .and_then(|entity| windows.layout_position(entity))
            .map(|position| position.0.x)
    };

    let left_snap = strip_position(layout_strip.last());
    let right_snap = strip_position(layout_strip.first());

    Some(
        if continuous_swipe && let Some((left_snap, right_snap)) = left_snap.zip(right_snap) {
            // Allow to scroll away until the last or first window snaps.
            current_offset.clamp(viewport.min.x - left_snap, viewport.max.x - right_snap)
        } else if viewport.width() < total_strip_width {
            // Snap the strip directly to the edges.
            current_offset.clamp(viewport.max.x - total_strip_width, viewport.min.x)
        } else {
            // Snap the strip directly to the edges.
            current_offset.clamp(viewport.min.x, viewport.max.x - total_strip_width)
        },
    )
}

#[derive(Default)]
struct VerticalGestureState {
    accumulated: f64,
    last_event: Option<Instant>,
    fired: bool,
}

#[instrument(level = Level::TRACE, skip_all)]
fn vertical_swipe_gesture(
    mut messages: MessageReader<InputEvent>,
    active_display: ActiveDisplay,
    config: Res<Config>,
    mut commands: Commands,
    mut state: Local<VerticalGestureState>,
) {
    const GESTURE_TIMEOUT: Duration = Duration::from_millis(150);

    if active_display.fullscreen().is_some() {
        return;
    }

    // Reset state when the gesture times out (fingers lifted).
    if let Some(last) = state.last_event
        && last.elapsed() > GESTURE_TIMEOUT
    {
        state.accumulated = 0.0;
        state.fired = false;
    }

    for InputEvent(event) in messages.read() {
        match event {
            Event::VerticalScrollTick { delta } => {
                switch_virtual_workspace(*delta, &config, &mut commands);
            }
            Event::VerticalSwipe { delta, fingers }
                if config
                    .swipe_gesture_fingers()
                    .is_some_and(|fingers_configured| fingers_configured == *fingers) =>
            {
                state.last_event = Some(Instant::now());

                if !state.fired {
                    state.accumulated += delta;
                }
            }
            _ => {}
        }
    }

    // Threshold needs to be high enough that incidental vertical movement
    // during horizontal swipes doesn't trigger a workspace switch.
    let threshold = 0.15 / config.swipe_sensitivity();
    if state.accumulated.abs() >= threshold {
        switch_virtual_workspace(state.accumulated, &config, &mut commands);
        state.accumulated = 0.0;
        state.fired = true;
    }
}

fn switch_virtual_workspace(delta: f64, config: &Config, commands: &mut Commands) {
    let physical_finger_direction = if delta > 0.0 {
        Direction::South
    } else {
        Direction::North
    };
    let direction = match config.swipe_gesture_direction() {
        SwipeGestureDirection::Natural => physical_finger_direction.reverse(),
        SwipeGestureDirection::Reversed => physical_finger_direction,
    };
    commands.trigger(SendMessageTrigger(Event::Command {
        command: Command::Window(Operation::Virtual(direction)),
    }));
}

#[cfg(test)]
mod landing_tests {
    use super::landing_offset;
    #[test]
    fn edges_and_center_are_distinct_landings() {
        let cols = [(0, 600), (600, 600), (1200, 600)];
        assert_eq!(landing_offset(-590.0, 0.0, 0, 1000, &cols), Some(-600.0));
        assert_eq!(landing_offset(-390.0, 0.0, 0, 1000, &cols), Some(-400.0));
        assert_eq!(landing_offset(-210.0, 0.0, 0, 1000, &cols), Some(-200.0));
    }
    #[test]
    fn projection_and_bounds() {
        let cols = [(0, 600), (600, 600), (1200, 600)];
        assert_eq!(
            landing_offset(-200.0, -1800.0, 0, 1000, &cols),
            Some(-400.0)
        );
        assert_eq!(landing_offset(50.0, 5000.0, 0, 1000, &cols), Some(0.0));
        assert_eq!(
            landing_offset(-790.0, -5000.0, 0, 1000, &cols),
            Some(-800.0)
        );
        assert_eq!(landing_offset(0.0, 0.0, 0, 1000, &[]), None);
    }
    #[test]
    fn short_strip_and_oversized_column() {
        assert_eq!(landing_offset(-100.0, 0.0, 0, 1000, &[(0, 600)]), Some(0.0));
        assert_eq!(
            landing_offset(-180.0, 0.0, 0, 1000, &[(0, 1400)]),
            Some(0.0)
        );
        assert_eq!(
            landing_offset(-300.0, 0.0, 0, 1000, &[(0, 1400)]),
            Some(-400.0)
        );
    }
}

#[cfg(test)]
mod contact_tests {
    use super::{Duration, Scrolling, hold_touch};
    #[test]
    fn a_long_stationary_hold_is_not_a_release() {
        let mut scroll = Scrolling {
            touch_held: true,
            snap_target: None,
            velocity: 2.0,
            position: 100.0,
            is_user_swiping: true,
            last_event: Duration::ZERO,
        };
        assert!(hold_touch(&mut scroll, Duration::from_secs(10)));
        assert!(scroll.is_user_swiping);
        assert!(scroll.snap_target.is_none());
        assert!(scroll.velocity.abs() < f64::EPSILON);
        scroll.touch_held = false;
        assert!(!hold_touch(&mut scroll, Duration::from_secs(10)));
    }
}
