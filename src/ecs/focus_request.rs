//! The navigator's "focus this window" request, answered when the engine has it.
//!
//! A tab click used to cost the bridge a window-set snapshot before it sent the
//! focus (the client checks that the target is still tiled on this desktop), then
//! a snapshot every 20 ms afterwards until the window reported itself focused.
//! Each snapshot reads every window's title over accessibility and asks the
//! window server for the workspace's windows, on the main thread, one frame after
//! it arrives. This request does the check and the focus in one step, inside the
//! frame that receives it, and answers from the focus acknowledgment itself.
//!
//! The check is the one the bridge made, so the same windows are refused: the
//! target must be a tiled (managed, not floating) window of a strip whose native
//! workspace is the current one. Other virtual rows of that workspace qualify;
//! the focus op reveals the row first.

use std::time::{Duration, Instant};

use bevy::app::{App, PostUpdate, PreUpdate};
use bevy::ecs::entity::Entity;
use bevy::ecs::hierarchy::ChildOf;
use bevy::ecs::lifecycle::Add;
use bevy::ecs::message::MessageReader;
use bevy::ecs::observer::On;
use bevy::ecs::query::{Has, With};
use bevy::ecs::resource::Resource;
use bevy::ecs::schedule::IntoScheduleConfigs as _;
use bevy::ecs::system::{Commands, Query, ResMut};
use bevy::ecs::world::World;

use crate::commands::Command;
use crate::ecs::focus::FocusWindow;
use crate::ecs::layout::LayoutStrip;
use crate::ecs::params::Windows;
use crate::ecs::{
    ActiveDisplayMarker, ActiveWorkspaceMarker, FocusedMarker, SendMessageTrigger, SpawnCommandsExt,
};
use crate::events::{Event, Reply};
use crate::manager::{Application, Display};
use crate::platform::WinID;
use crate::types::windowset::LayoutOp;
use crate::types::wire::Response;

/// How long a request waits for the window to take the focus. The bridge used to
/// give up after the same two seconds.
const ACCEPT_FOCUS_WITHIN: Duration = Duration::from_secs(2);

struct Pending {
    entity: Entity,
    respond_to: Reply,
    deadline: Instant,
}

/// Requests whose window has not yet become the focused window.
#[derive(Default, Resource)]
pub(crate) struct PendingFocusRequests(Vec<Pending>);

pub(crate) fn register(app: &mut App) {
    app.init_resource::<PendingFocusRequests>();
    app.add_systems(
        PreUpdate,
        focus_request_handler.after(crate::ecs::view_history::observe),
    );
    app.add_systems(PostUpdate, expire_focus_requests);
    app.add_observer(focus_acknowledged);
}

/// Focuses `entity` and reveals its row, the way a script's `Focus` op does.
///
/// A window on a row that is not showing needs that row activated first; the op
/// is retried once the row has been restored, never applied to a parked window.
pub(crate) fn queue_focus(commands: &mut Commands, entity: Entity, window: WinID) {
    commands.queue(move |world: &mut World| {
        let target = world
            .query::<(Entity, &LayoutStrip, Has<ActiveWorkspaceMarker>)>()
            .iter(world)
            .find(|(_, strip, _)| strip.contains(entity))
            .map(|(row, _, active)| (row, active));
        if let Some((row, false)) = target {
            if let Some(mut previous) =
                world.get_mut::<crate::ecs::workspace::PreviousStripPosition>(row)
            {
                previous.focus = Some(entity);
            }
            world.entity_mut(row).insert(ActiveWorkspaceMarker);
            world.trigger(SendMessageTrigger(Event::Command {
                command: Command::Layout(vec![LayoutOp::Focus(window)]),
            }));
        } else {
            crate::focus_trace::mark("focus_trigger");
            world.trigger(FocusWindow {
                entity,
                raise: true,
                source: None,
            });
            world.commands().reshuffle_around(entity);
        }
    });
}

/// Whether `window` may be focused from the navigator: tiled, and on the native
/// workspace that is current on the active display.
fn focus_target(
    window: WinID,
    windows: &Windows,
    apps: &Query<&Application>,
    strips: &Query<(&LayoutStrip, &ChildOf, Has<ActiveWorkspaceMarker>)>,
    displays: &Query<Has<ActiveDisplayMarker>, With<Display>>,
) -> Option<Entity> {
    let (_, entity, parent) = windows.find_parent(window)?;
    apps.get(parent).ok()?;
    let (_, _, unmanaged) = windows.get_managed(entity)?;
    if unmanaged.is_some() {
        return None;
    }
    // "Here": the showing workspace of the active display, else of the first.
    let active_display = |display: Entity| displays.get(display).unwrap_or(false);
    let any_marked = displays.iter().any(|marked| marked);
    let current = strips
        .iter()
        .filter(|(_, _, showing)| *showing)
        .find(|(_, child, _)| !any_marked || active_display(child.parent()))
        .map(|(strip, _, _)| strip.id())?;
    strips
        .iter()
        .any(|(strip, _, _)| strip.id() == current && strip.contains(entity))
        .then_some(entity)
}

fn focus_request_handler(
    mut messages: MessageReader<Event>,
    windows: Windows,
    apps: Query<&Application>,
    strips: Query<(&LayoutStrip, &ChildOf, Has<ActiveWorkspaceMarker>)>,
    displays: Query<Has<ActiveDisplayMarker>, With<Display>>,
    focused: Query<(), With<FocusedMarker>>,
    mut pending: ResMut<PendingFocusRequests>,
    mut commands: Commands,
) {
    for event in messages.read() {
        let Event::FocusRequest { window, respond_to } = event else {
            continue;
        };
        crate::focus_trace::mark("op_apply");
        let Some(entity) = focus_target(*window, &windows, &apps, &strips, &displays) else {
            _ = respond_to.try_send(Response::Error(
                "window is no longer tiled on this desktop".to_string(),
            ));
            continue;
        };
        queue_focus(&mut commands, entity, *window);
        if focused.contains(entity) {
            // Already the focused window; the op above still reveals it.
            _ = respond_to.try_send(Response::Focused);
        } else {
            pending.0.push(Pending {
                entity,
                respond_to: respond_to.clone(),
                deadline: Instant::now() + ACCEPT_FOCUS_WITHIN,
            });
        }
    }
}

/// The engine now has `entity` as its focused window.
fn focus_acknowledged(trigger: On<Add, FocusedMarker>, mut pending: ResMut<PendingFocusRequests>) {
    if pending.0.is_empty() {
        return;
    }
    let entity = trigger.event().entity;
    pending.0.retain(|request| {
        if request.entity != entity {
            return true;
        }
        _ = request.respond_to.try_send(Response::Focused);
        false
    });
}

/// Answers the requests that will not be acknowledged: the window went away, or
/// never took the focus.
fn expire_focus_requests(mut pending: ResMut<PendingFocusRequests>, windows: Windows) {
    if pending.0.is_empty() {
        return;
    }
    let now = Instant::now();
    pending.0.retain(|request| {
        let reason = if windows.get(request.entity).is_none() {
            "target disappeared while focusing"
        } else if now >= request.deadline {
            "window did not accept focus"
        } else {
            return true;
        };
        _ = request
            .respond_to
            .try_send(Response::Error(reason.to_string()));
        false
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::assert_focused;
    use crate::ecs::Unmanaged;
    use crate::tests::{
        TEST_DISPLAY_HEIGHT, TEST_DISPLAY_ID, TEST_DISPLAY_WIDTH, TEST_WORKSPACE_ID, TestHarness,
        find_window_entity,
    };
    use bevy::math::IRect;

    fn request(window: WinID) -> (Event, async_channel::Receiver<Response>) {
        let (respond_to, answer) = async_channel::bounded(1);
        (Event::FocusRequest { window, respond_to }, answer)
    }

    fn start() -> Event {
        Event::MenuOpened { window_id: 0 }
    }

    #[test]
    fn a_tiled_window_is_focused_and_the_request_answered_once_it_holds_the_focus() {
        let (event, answer) = request(2);
        TestHarness::new()
            .with_windows(3)
            .on_iteration(1, move |world, _| {
                assert_eq!(answer.try_recv(), Ok(Response::Focused));
                assert_focused!(world, 2);
            })
            .run(vec![start(), event]);
    }

    #[test]
    fn asking_for_the_focused_window_is_answered_at_once() {
        let (event, answer) = request(0);
        TestHarness::new()
            .with_windows(2)
            .on_iteration(1, move |world, _| {
                assert_eq!(answer.try_recv(), Ok(Response::Focused));
                assert_focused!(world, 0);
            })
            .run(vec![start(), event]);
    }

    #[test]
    fn a_window_that_is_gone_is_refused_in_the_bridges_words() {
        let (event, answer) = request(99);
        TestHarness::new()
            .with_windows(2)
            .on_iteration(1, move |_, _| {
                assert_eq!(
                    answer.try_recv(),
                    Ok(Response::Error(
                        "window is no longer tiled on this desktop".to_string()
                    ))
                );
            })
            .run(vec![start(), event]);
    }

    #[test]
    fn a_floating_window_is_refused_and_focus_stays_put() {
        let (event, answer) = request(1);
        TestHarness::new()
            .with_windows(2)
            .on_iteration(0, |world, _| {
                let floating = find_window_entity(1, world);
                world.entity_mut(floating).insert(Unmanaged::Floating);
            })
            .on_iteration(1, move |world, _| {
                assert!(matches!(answer.try_recv(), Ok(Response::Error(_))));
                assert_focused!(world, 0);
                let entity = find_window_entity(1, world);
                assert!(world.entity(entity).get::<FocusedMarker>().is_none());
            })
            .run(vec![start(), event]);
    }

    #[test]
    fn a_window_on_another_native_workspace_is_refused() {
        let (event, answer) = request(99);
        TestHarness::new()
            .with_display(
                TEST_DISPLAY_ID,
                IRect::new(0, 0, TEST_DISPLAY_WIDTH, TEST_DISPLAY_HEIGHT),
                vec![TEST_WORKSPACE_ID, TEST_WORKSPACE_ID + 1],
            )
            .with_workspace_window(0, TEST_WORKSPACE_ID, |_| {})
            .with_workspace_window(99, TEST_WORKSPACE_ID + 1, |_| {})
            .on_iteration(1, move |world, _| {
                assert!(matches!(answer.try_recv(), Ok(Response::Error(_))));
                assert_focused!(world, 0);
            })
            .run(vec![start(), event]);
    }

    #[test]
    fn a_request_nobody_acknowledges_is_answered_when_it_runs_out_of_time() {
        let (respond_to, answer) = async_channel::bounded(1);
        let mut harness = TestHarness::new().with_windows(1);
        harness.run(vec![start()]);
        let entity = find_window_entity(0, harness.world());
        harness
            .world()
            .resource_mut::<PendingFocusRequests>()
            .0
            .push(Pending {
                entity,
                respond_to,
                deadline: Instant::now() - Duration::from_millis(1),
            });
        harness.advance(Duration::from_millis(60));
        assert_eq!(
            answer.try_recv(),
            Ok(Response::Error("window did not accept focus".to_string()))
        );
        assert!(
            harness
                .world()
                .resource::<PendingFocusRequests>()
                .0
                .is_empty()
        );
    }

    #[test]
    fn a_window_that_closes_while_waiting_is_reported() {
        let (respond_to, answer) = async_channel::bounded(1);
        let mut harness = TestHarness::new().with_windows(1);
        harness.run(vec![start()]);
        let entity = find_window_entity(0, harness.world());
        harness
            .world()
            .resource_mut::<PendingFocusRequests>()
            .0
            .push(Pending {
                entity,
                respond_to,
                deadline: Instant::now() + Duration::from_secs(60),
            });
        harness.world().despawn(entity);
        harness.advance(Duration::from_millis(60));
        assert_eq!(
            answer.try_recv(),
            Ok(Response::Error(
                "target disappeared while focusing".to_string()
            ))
        );
    }
}
