//! Hidden-row windows stay parked even when an app clamps, ignores or fights
//! the park move. Time is the harness clock: `TestHarness::advance`.

use std::time::Duration;

use bevy::prelude::*;

use crate::commands::{Command, MoveFocus, Operation};
use crate::ecs::Position;
use crate::events::Event;
use crate::manager::Origin;
use crate::platform::WinID;

use super::*;

/// Window 0 and 1 start on row 0; window 0 is sent to row 1 and parked there.
fn with_window_on_hidden_row(configure: impl FnOnce(&MockState)) -> (TestHarness, Entity) {
    let mut h = TestHarness::new().with_windows(2);
    configure(&h.mock_state);
    h.run(vec![
        Event::MenuOpened { window_id: 0 },
        Event::Command {
            command: Command::Window(Operation::VirtualMoveNumber(1, MoveFocus::Stay)),
        },
    ]);
    h.advance(Duration::from_secs(1));
    let entity = find_window_entity(0, h.world());
    (h, entity)
}

fn frame_origin(h: &TestHarness, id: WinID) -> Origin {
    h.mock_state.window_frame(id).min
}

fn logical(h: &mut TestHarness, entity: Entity) -> Origin {
    h.world().get::<Position>(entity).unwrap().0
}

/// The app moves its own window and tells the engine.
fn app_moves(h: &mut TestHarness, id: WinID, to: Origin) {
    h.mock_state.os_move_window(id, to);
    h.advance(Duration::from_millis(500));
}

fn corrections(h: &TestHarness, id: WinID) -> usize {
    h.mock_state
        .take_geometry_writes()
        .into_iter()
        .filter(|written| *written == id)
        .count()
}

#[test]
fn clamped_park_is_left_alone_and_a_real_displacement_is_corrected() {
    // AppKit keeps the title bar on screen: 41 pt above where the engine asked.
    let (mut h, entity) = with_window_on_hidden_row(|state| {
        state.update_window(0, |w| {
            w.lowest_origin_y = Some(TEST_DISPLAY_HEIGHT - 10 - 41);
        });
    });
    let target = logical(&mut h, entity);
    let clamped = Origin::new(target.x, target.y - 41);
    assert_eq!(frame_origin(&h, 0), clamped, "the park should be clamped");

    // The clamp is echoed back as move notifications, over and over.
    _ = corrections(&h, 0);
    for _ in 0..4 {
        app_moves(&mut h, 0, clamped);
    }
    assert_eq!(
        corrections(&h, 0),
        0,
        "a clamped corner sliver is parked, not displaced"
    );

    // Later the app really pulls the window back on screen.
    app_moves(&mut h, 0, Origin::new(16, 50));
    assert_eq!(
        frame_origin(&h, 0),
        clamped,
        "the window should be parked again"
    );
    assert_eq!(corrections(&h, 0), 1);
    assert_eq!(logical(&mut h, entity), target);
}

#[test]
fn displacement_without_a_notification_is_found_by_the_audit() {
    let (mut h, entity) = with_window_on_hidden_row(|_| {});
    let target = logical(&mut h, entity);
    assert_eq!(frame_origin(&h, 0), target);

    // Moved behind our back: no WindowMoved event is ever queued.
    h.mock_state.update_window(0, |w| {
        let size = w.frame.size();
        w.frame.min = Origin::new(16, 50);
        w.frame.max = w.frame.min + size;
    });
    h.advance(Duration::from_secs(6));
    assert_eq!(
        frame_origin(&h, 0),
        target,
        "the audit should park it again"
    );
    assert_eq!(logical(&mut h, entity), target);
}

#[test]
fn an_app_that_always_fights_causes_a_bounded_number_of_moves() {
    let (mut h, entity) = with_window_on_hidden_row(|_| {});
    let target = logical(&mut h, entity);
    h.mock_state
        .update_window(0, |w| w.fights_back_to = Some(Origin::new(16, 50)));
    _ = corrections(&h, 0);
    app_moves(&mut h, 0, Origin::new(16, 50));

    let mut per_ten_seconds = Vec::new();
    for _ in 0..6 {
        h.advance(Duration::from_secs(10));
        per_ten_seconds.push(corrections(&h, 0));
        assert_eq!(logical(&mut h, entity), target, "the layout stays put");
    }
    let total: usize = per_ten_seconds.iter().sum();
    assert!(
        (3..=8).contains(&total),
        "expected a few backed-off corrections in a minute, got {per_ten_seconds:?}"
    );
}

#[test]
fn showing_the_row_resets_the_episode_and_lays_out_normally() {
    let (mut h, entity) = with_window_on_hidden_row(|state| {
        state.update_window(0, |w| {
            w.lowest_origin_y = Some(TEST_DISPLAY_HEIGHT - 10 - 41);
        });
    });
    // Spend the episode: the app fights until backed off to the long waits.
    h.mock_state
        .update_window(0, |w| w.fights_back_to = Some(Origin::new(16, 50)));
    h.advance(Duration::from_secs(10));

    // Show the row, with a well-behaved app.
    h.mock_state.update_window(0, |w| w.fights_back_to = None);
    h.run(vec![Event::Command {
        command: Command::Window(Operation::VirtualNumber(1)),
    }]);
    h.advance(Duration::from_secs(1));
    let shown = logical(&mut h, entity);
    assert!(
        shown.x < TEST_DISPLAY_WIDTH - 100 && shown.y < TEST_DISPLAY_HEIGHT - 100,
        "the shown window should be laid out on screen, got {shown:?}"
    );
    assert_eq!(frame_origin(&h, 0), shown);

    // Hide it again: a fresh episode, so one displacement is corrected at once
    // even after the clamp has echoed several times.
    h.run(vec![Event::Command {
        command: Command::Window(Operation::VirtualNumber(0)),
    }]);
    h.advance(Duration::from_secs(1));
    let target = logical(&mut h, entity);
    let clamped = Origin::new(target.x, target.y - 41);
    for _ in 0..4 {
        app_moves(&mut h, 0, clamped);
    }
    _ = corrections(&h, 0);
    app_moves(&mut h, 0, Origin::new(16, 50));
    assert_eq!(frame_origin(&h, 0), clamped);
    assert_eq!(corrections(&h, 0), 1);
}
