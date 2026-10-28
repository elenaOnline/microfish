use std::collections::{HashMap, HashSet, VecDeque};
use std::sync::{Arc, RwLock};

use bevy::prelude::*;
use objc2_core_foundation::CGPoint;
use objc2_core_graphics::CGDirectDisplayID;
use stdext::prelude::RwLockExt;

use crate::errors::Error;
use crate::events::{DestroySource, Event};
use crate::manager::app::MockApplicationApi;
use crate::manager::{
    Application, Display, MockProcessApi, MockWindowApi, MockWindowManagerApi, Origin, Size,
    Window, origin_from, origin_to,
};
use crate::platform::{Modifiers, Pid, ProcessSerialNumber, WinID, WorkspaceId};

use super::*;

/// Data for a mocked application.
pub(crate) struct MockAppData {
    pub(crate) psn: ProcessSerialNumber,
    pub(crate) bundle_id: String,
    pub(crate) name: String,
    pub(crate) focused_window_id: Option<WinID>,
    pub(crate) is_frontmost: bool,
    pub(crate) connection: Option<crate::platform::ConnID>,
}

#[derive(Default)]
pub(crate) struct MockResizeBehavior {
    pub rejected_requests: u8,
    pub delayed_reads: u8,
    pub minimum_width: i32,
    pending: Option<Size>,
    cached: Option<IRect>,
}

/// Data for a mocked window.
#[allow(clippy::struct_excessive_bools)]
pub(crate) struct MockWindowData {
    pub(crate) id: WinID,
    pub(crate) pid: Pid,
    pub(crate) frame: IRect,
    pub(crate) title: String,
    pub(crate) minimized: bool,
    pub(crate) workspace_id: WorkspaceId,
    pub(crate) visible: bool,
    pub(crate) role: String,
    pub(crate) subrole: String,
    pub(crate) identifier: String,
    pub(crate) is_full_screen: bool,
    pub(crate) border_radius: Option<f64>,
    pub(crate) horizontal_padding: i32,
    pub(crate) vertical_padding: i32,
    pub(crate) requested_padding: (Option<i32>, Option<i32>),
    pub(crate) child_role: bool,
    pub(crate) resize_behavior: Option<MockResizeBehavior>,
    /// `AppKit` keeps a title bar on screen: a requested origin below this y
    /// lands here instead, without any notification.
    pub(crate) lowest_origin_y: Option<i32>,
    /// An app that fights being parked: after every engine move to anywhere
    /// else it puts itself back here and reports the move.
    pub(crate) fights_back_to: Option<Origin>,
}

impl Default for MockWindowData {
    fn default() -> Self {
        Self {
            id: 0,
            pid: 0,
            frame: IRect::default(),
            title: String::new(),
            minimized: false,
            workspace_id: 0,
            visible: true,
            role: "AXWindow".to_string(),
            subrole: "AXStandardWindow".to_string(),
            identifier: "testid".to_string(),
            is_full_screen: false,
            border_radius: None,
            horizontal_padding: 0,
            vertical_padding: 0,
            requested_padding: (None, None),
            child_role: false,
            resize_behavior: None,
            lowest_origin_y: None,
            fights_back_to: None,
        }
    }
}

/// Data for a mocked display.
struct MockDisplayData {
    id: u32,
    bounds: IRect,
    workspaces: Vec<WorkspaceId>,
}

/// The internal state of our "Virtual macOS".
struct MockStateInner {
    apps: HashMap<Pid, MockAppData>,
    windows: HashMap<WinID, MockWindowData>,
    displays: HashMap<u32, MockDisplayData>,
    fullscreen_spaces: HashSet<WorkspaceId>,
    active_display_id: u32,
    cursor_position: Origin,
    event_queue: VecDeque<Event>,
    geometry_writes: Vec<WinID>,
    /// Windows that are gone but which the app's AX window list still reports,
    /// modelling the lag real apps show right after a window closes.
    stale_window_ids: HashMap<WinID, Pid>,
    unordered_windows: HashSet<WinID>,
    /// Windows the app keeps out of its accessibility window list while the
    /// window server still reports them on screen: a background native tab.
    background_tabs: HashSet<WinID>,
    /// Every native focus request the engine made, in order: the window it
    /// asked the OS to focus and, for a no-raise request, the window it named
    /// as the one losing focus.
    focus_calls: Vec<FocusCall>,
    /// Native focus requests each window will still ignore, modelling an app
    /// that takes the focus back from the window it was just handed to.
    refused_focus: HashMap<WinID, u8>,
    /// How many times the engine asked an app for its full window list.
    window_list_scans: usize,
    /// The apps in front when the engine made itself the front process, one
    /// entry per request (the empty-row keyboard hold).
    self_activations: Vec<Option<Pid>>,
    /// The engine is the front process: no app is.
    engine_front: bool,
}

/// The serial number the mock gives the engine itself.
pub(crate) const ENGINE_PSN: ProcessSerialNumber = ProcessSerialNumber {
    high: 0xE,
    low: 0xE,
};

/// One native focus request recorded by the mock.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct FocusCall {
    pub(crate) target: WinID,
    pub(crate) losing: Option<WinID>,
    /// Where the target window physically was when the request was made.
    pub(crate) target_origin: Origin,
}

#[derive(Clone)]
pub struct MockState {
    inner: Arc<RwLock<MockStateInner>>,
}

impl MockState {
    pub fn new() -> Self {
        Self {
            inner: Arc::new(RwLock::new(MockStateInner {
                apps: HashMap::new(),
                windows: HashMap::new(),
                displays: HashMap::new(),
                fullscreen_spaces: HashSet::new(),
                active_display_id: 0,
                cursor_position: Origin::ZERO,
                event_queue: VecDeque::new(),
                geometry_writes: Vec::new(),
                stale_window_ids: HashMap::new(),
                unordered_windows: HashSet::new(),
                background_tabs: HashSet::new(),
                focus_calls: Vec::new(),
                refused_focus: HashMap::new(),
                window_list_scans: 0,
                self_activations: Vec::new(),
                engine_front: false,
            })),
        }
    }

    #[allow(dead_code)]
    pub fn set_window_unordered(&self, window_id: WinID, unordered: bool) {
        let mut inner = self.inner.force_write();
        if unordered {
            inner.unordered_windows.insert(window_id);
        } else {
            inner.unordered_windows.remove(&window_id);
        }
    }

    /// Makes `window_id` a background native tab: on screen as far as the
    /// window server is concerned, absent from the app's accessibility window
    /// list. This is what Ghostty does with every tab but the selected one.
    #[allow(unused)]
    pub fn set_background_tab(&self, window_id: WinID, background: bool) {
        let mut inner = self.inner.force_write();
        if background {
            inner.background_tabs.insert(window_id);
        } else {
            inner.background_tabs.remove(&window_id);
        }
    }

    pub(crate) fn window_visible(&self, window_id: WinID, visible: bool) {
        let mut state = self.inner.force_write();
        let window = state.windows.get_mut(&window_id).expect("finding window");
        window.visible = visible;
    }

    // --- OS Behavior Methods ---

    pub fn spawn_app(&self, pid: Pid, bundle_id: &str, name: &str) {
        let mut inner = self.inner.force_write();
        inner.apps.insert(
            pid,
            MockAppData {
                psn: ProcessSerialNumber {
                    high: 0,
                    low: pid.cast_unsigned(),
                },
                bundle_id: bundle_id.to_string(),
                name: name.to_string(),
                focused_window_id: None,
                is_frontmost: true,
                connection: Some(0),
            },
        );
    }

    pub fn spawn_window(
        &self,
        pid: Pid,
        workspace_id: WorkspaceId,
        id: WinID,
        frame: IRect,
    ) -> Window {
        let mut inner = self.inner.force_write();
        inner.windows.insert(
            id,
            MockWindowData {
                id,
                pid,
                frame,
                title: format!("Window {id}"),
                workspace_id,
                ..default()
            },
        );
        self.create_window(id)
    }

    /// Moves the app's focused window without emitting the notifications a
    /// real focus change would produce.
    pub fn set_focused_window(&self, id: WinID) {
        let mut inner = self.inner.force_write();
        let Some(pid) = inner.windows.get(&id).map(|window| window.pid) else {
            return;
        };
        if let Some(app) = inner.apps.get_mut(&pid) {
            app.focused_window_id = Some(id);
        }
    }

    /// Full window-list queries made to any app so far.
    pub(crate) fn window_list_scans(&self) -> usize {
        self.inner.force_read().window_list_scans
    }

    /// Native focus requests made so far, oldest first.
    pub(crate) fn focus_calls(&self) -> Vec<FocusCall> {
        self.inner.force_read().focus_calls.clone()
    }

    /// Times the engine made itself the front process, each with the app that
    /// was in front, oldest first.
    pub(crate) fn self_activations(&self) -> Vec<Option<Pid>> {
        self.inner.force_read().self_activations.clone()
    }

    /// Whether the engine, not an app, is the front process.
    pub(crate) fn engine_is_front(&self) -> bool {
        self.inner.force_read().engine_front
    }

    /// The engine takes the front: no app is frontmost, and the switch is
    /// announced with the engine's own serial number.
    fn activate_engine(&self, previous: Option<Pid>) {
        let mut inner = self.inner.force_write();
        inner.self_activations.push(previous);
        inner.engine_front = true;
        for app in inner.apps.values_mut() {
            app.is_frontmost = false;
        }
        inner
            .event_queue
            .push_back(Event::ApplicationFrontSwitched { psn: ENGINE_PSN });
    }

    /// Focusing a window makes its app the front process, which ends the
    /// engine's turn as front and is announced like any front switch.
    fn take_front_from_engine(&self, id: WinID) {
        let mut inner = self.inner.force_write();
        if !std::mem::take(&mut inner.engine_front) {
            return;
        }
        let Some(pid) = inner.windows.get(&id).map(|window| window.pid) else {
            return;
        };
        if let Some(app) = inner.apps.get_mut(&pid) {
            app.is_frontmost = true;
            let psn = app.psn;
            inner
                .event_queue
                .push_back(Event::ApplicationFrontSwitched { psn });
        }
    }

    /// Makes the next `times` native focus requests for window `id` do nothing.
    pub(crate) fn refuse_focus(&self, id: WinID, times: u8) {
        self.inner.force_write().refused_focus.insert(id, times);
    }

    /// Records a native focus request and reports whether the OS honours it.
    fn record_focus_call(&self, target: WinID, losing: Option<WinID>) -> bool {
        let mut inner = self.inner.force_write();
        let target_origin = inner
            .windows
            .get(&target)
            .map_or(Origin::ZERO, |window| window.frame.min);
        inner.focus_calls.push(FocusCall {
            target,
            losing,
            target_origin,
        });
        match inner.refused_focus.get_mut(&target) {
            Some(times) if *times > 0 => {
                *times -= 1;
                false
            }
            _ => true,
        }
    }

    /// The window the application `pid` reports as focused.
    pub(crate) fn app_focused_window(&self, pid: Pid) -> Option<WinID> {
        self.inner
            .force_read()
            .apps
            .get(&pid)
            .and_then(|app| app.focused_window_id)
    }

    pub fn focus_window(&self, id: WinID) {
        let mut inner = self.inner.force_write();
        if let Some(win) = inner.windows.get(&id) {
            let pid = win.pid;
            let engine_was_front = std::mem::take(&mut inner.engine_front);
            if let Some(app) = inner.apps.get_mut(&pid) {
                app.focused_window_id = Some(id);
                // Focusing an app's window takes the front from the engine.
                app.is_frontmost |= engine_was_front;
                let psn = app.psn;
                inner
                    .event_queue
                    .push_back(Event::ApplicationFrontSwitched { psn });
                inner
                    .event_queue
                    .push_back(Event::WindowFocused { window_id: id });
            }
        }
    }

    pub fn add_display(&mut self, id: u32, bounds: IRect, workspaces: Vec<WorkspaceId>) {
        let mut inner = self.inner.force_write();
        if inner.displays.is_empty() {
            inner.active_display_id = id;
        }
        inner.displays.insert(
            id,
            MockDisplayData {
                id,
                bounds,
                workspaces,
            },
        );
    }

    pub fn set_display_bounds(&self, id: u32, bounds: IRect) {
        let mut inner = self.inner.force_write();
        inner.displays.get_mut(&id).expect("finding display").bounds = bounds;
    }

    #[allow(unused)]
    pub fn remove_display(&self, id: u32) {
        let mut inner = self.inner.force_write();
        inner.displays.remove(&id);
        if inner.active_display_id == id {
            inner.active_display_id = inner.displays.keys().copied().next().unwrap_or(0);
        }
    }

    pub fn active_display(&self) -> CGDirectDisplayID {
        self.inner.force_read().active_display_id
    }

    pub(crate) fn set_active_display(&self, id: u32) {
        self.inner.force_write().active_display_id = id;
    }

    pub(crate) fn activate_workspace(
        &self,
        display_id: u32,
        workspace_id: WorkspaceId,
        fullscreen: bool,
    ) {
        let mut inner = self.inner.force_write();
        {
            let display = inner
                .displays
                .get_mut(&display_id)
                .expect("finding display");
            display.workspaces.retain(|id| *id != workspace_id);
            display.workspaces.insert(0, workspace_id);
        }
        if fullscreen {
            inner.fullscreen_spaces.insert(workspace_id);
        } else {
            inner.fullscreen_spaces.remove(&workspace_id);
        }
    }

    pub fn drain_events(&self) -> Vec<Event> {
        let mut inner = self.inner.force_write();
        inner.event_queue.drain(..).collect()
    }

    // --- State Mutation Methods ---

    pub fn update_window<F>(&self, id: WinID, f: F)
    where
        F: FnOnce(&mut MockWindowData),
    {
        let mut inner = self.inner.force_write();
        if let Some(w) = inner.windows.get_mut(&id) {
            f(w);
        }
    }

    #[allow(unused)]
    pub fn update_app(&self, pid: Pid, f: impl FnOnce(&mut MockAppData)) {
        let mut inner = self.inner.force_write();
        if let Some(a) = inner.apps.get_mut(&pid) {
            f(a);
        }
    }

    // --- OS Behavior Methods ---

    #[allow(unused)]
    pub fn os_move_window(&self, id: WinID, origin: Origin) {
        let mut inner = self.inner.force_write();
        if let Some(w) = inner.windows.get_mut(&id) {
            let size = w.frame.size();
            w.frame.min = origin;
            w.frame.max = origin + size;
            inner
                .event_queue
                .push_back(Event::WindowMoved { window_id: id });
        }
    }

    #[allow(unused)]
    pub fn os_resize_window(&self, id: WinID, size: Size) {
        let mut inner = self.inner.force_write();
        if let Some(w) = inner.windows.get_mut(&id) {
            w.frame.max = w.frame.min + size;
            inner
                .event_queue
                .push_back(Event::WindowResized { window_id: id });
        }
    }

    #[allow(unused)]
    pub fn os_minimize_window(&self, id: WinID, minimized: bool) {
        let mut inner = self.inner.force_write();
        if let Some(w) = inner.windows.get_mut(&id) {
            w.minimized = minimized;
            if minimized {
                inner
                    .event_queue
                    .push_back(Event::WindowMinimized { window_id: id });
            } else {
                inner
                    .event_queue
                    .push_back(Event::WindowDeminimized { window_id: id });
            }
        }
    }

    /// Closes a window while its application keeps running, the way macOS
    /// actually reports it: the SLS space notification first, then the AX
    /// element teardown, with the AX element and the app's window list still
    /// reporting the window for a while after, as they do on real apps.
    #[allow(unused)]
    pub fn os_close_window(&self, id: WinID) {
        let mut inner = self.inner.force_write();
        let Some(window) = inner.windows.remove(&id) else {
            return;
        };
        inner.stale_window_ids.insert(id, window.pid);
        inner.event_queue.push_back(Event::WindowDestroyed {
            window_id: id,
            source: DestroySource::SpaceNotification,
        });
        inner.event_queue.push_back(Event::WindowDestroyed {
            window_id: id,
            source: DestroySource::Accessibility,
        });
    }

    /// Makes a window disappear with no notification at all, modelling a
    /// destroy event that never arrived — a lost notification, or a window
    /// closed while paneru was not running.
    #[allow(unused)]
    pub fn os_vanish_window(&self, id: WinID) {
        let mut inner = self.inner.force_write();
        inner.windows.remove(&id);
        inner.unordered_windows.insert(id);
    }

    /// Lets the app's window list catch up with reality after a close.
    #[allow(unused)]
    pub fn os_settle_window_list(&self) {
        self.inner.force_write().stale_window_ids.clear();
    }

    // --- Interaction Helpers ---

    #[allow(unused)]
    pub fn simulate_click(&self, point: Origin) {
        let mut inner = self.inner.force_write();
        let point = CGPoint::new(point.x.into(), point.y.into());
        inner.event_queue.push_back(Event::MouseDown {
            point,
            modifiers: Modifiers::empty(),
        });
        inner.event_queue.push_back(Event::MouseUp {
            point,
            modifiers: Modifiers::empty(),
        });
    }

    #[allow(unused)]
    pub fn simulate_window_click(&self, id: WinID) {
        let inner = self.inner.force_read();
        if let Some(w) = inner.windows.get(&id) {
            let center = w.frame.center();
            drop(inner);
            self.simulate_click(center);
        }
    }

    #[allow(unused)]
    pub fn simulate_drag(&self, start: Origin, end: Origin) {
        let mut inner = self.inner.force_write();
        let start_p = CGPoint::new(start.x.into(), start.y.into());
        let end_p = CGPoint::new(end.x.into(), end.y.into());
        inner.event_queue.push_back(Event::MouseDown {
            point: start_p,
            modifiers: Modifiers::empty(),
        });
        inner.event_queue.push_back(Event::MouseDragged {
            point: end_p,
            modifiers: Modifiers::empty(),
        });
        inner.event_queue.push_back(Event::MouseUp {
            point: end_p,
            modifiers: Modifiers::empty(),
        });
    }

    pub fn physical_window_frame(&self, id: WinID) -> IRect {
        self.inner.force_read().windows[&id].frame
    }

    pub fn set_resize_behavior(
        &self,
        id: WinID,
        rejected_requests: u8,
        delayed_reads: u8,
        minimum_width: i32,
    ) {
        self.inner
            .force_write()
            .windows
            .get_mut(&id)
            .unwrap()
            .resize_behavior = Some(MockResizeBehavior {
            rejected_requests,
            delayed_reads,
            minimum_width,
            ..Default::default()
        });
    }

    fn request_window_size(&self, id: WinID, size: Size) {
        let mut inner = self.inner.force_write();
        inner.geometry_writes.push(id);
        if let Some(window) = inner.windows.get_mut(&id) {
            let mut target = size;
            if let Some(behavior) = &mut window.resize_behavior {
                behavior.cached = Some(IRect::from_corners(
                    window.frame.min,
                    window.frame.min + size,
                ));
                if behavior.rejected_requests > 0 {
                    behavior.rejected_requests -= 1;
                    return;
                }
                target.x = target.x.max(behavior.minimum_width);
                if behavior.delayed_reads > 0 {
                    behavior.pending = Some(target);
                    return;
                }
            }
            window.frame.max = window.frame.min + target;
        }
    }

    fn read_window_frame(&self, id: WinID) -> crate::errors::Result<IRect> {
        let mut inner = self.inner.force_write();
        let window = inner.windows.get_mut(&id).ok_or(Error::InvalidWindow)?;
        if let Some(behavior) = &mut window.resize_behavior {
            behavior.delayed_reads = behavior.delayed_reads.saturating_sub(1);
            if behavior.delayed_reads == 0
                && let Some(size) = behavior.pending.take()
            {
                window.frame.max = window.frame.min + size;
            }
            behavior.cached = Some(window.frame);
        }
        Ok(window.frame)
    }

    /// Where the window really is, as the window server would report it.
    pub fn window_frame(&self, id: WinID) -> IRect {
        self.inner
            .force_read()
            .windows
            .get(&id)
            .map(|window| window.frame)
            .expect("window exists")
    }

    pub fn take_geometry_writes(&self) -> Vec<WinID> {
        std::mem::take(&mut self.inner.force_write().geometry_writes)
    }

    pub fn cursor_position(&self) -> IVec2 {
        self.inner.force_read().cursor_position
    }

    // --- Mock Factory Methods ---

    #[allow(clippy::too_many_lines)]
    pub fn create_window(&self, id: WinID) -> Window {
        let mut mw = MockWindowApi::new();

        mw.expect_id().return_const(id);

        let s = self.clone();
        mw.expect_pid().returning(move || {
            s.inner
                .force_read()
                .windows
                .get(&id)
                .map(|w| w.pid)
                .ok_or(Error::InvalidWindow)
        });

        let s = self.clone();
        mw.expect_frame().returning(move || {
            s.inner
                .force_read()
                .windows
                .get(&id)
                .map(|window| {
                    window
                        .resize_behavior
                        .as_ref()
                        .and_then(|behavior| behavior.cached)
                        .unwrap_or(window.frame)
                })
                .unwrap_or_default()
        });

        let s = self.clone();
        mw.expect_resize().returning(move |size| {
            s.request_window_size(id, size);
        });
        let s = self.clone();
        mw.expect_request_native_sibling_size()
            .returning(move |size| {
                s.request_window_size(id, size);
            });
        let s = self.clone();
        mw.expect_native_sibling_frame()
            .returning(move || s.read_window_frame(id));

        let s_move = self.clone();
        mw.expect_reposition().returning(move |origin| {
            let mut inner = s_move.inner.force_write();
            inner.geometry_writes.push(id);
            let mut fought = false;
            if let Some(w) = inner.windows.get_mut(&id) {
                let size = w.frame.size();
                let mut origin = origin;
                if let Some(lowest) = w.lowest_origin_y {
                    origin.y = origin.y.min(lowest);
                }
                if let Some(back) = w.fights_back_to.filter(|back| *back != origin) {
                    origin = back;
                    fought = true;
                }
                w.frame.min = origin;
                w.frame.max = origin + size;
            }
            if fought {
                inner
                    .event_queue
                    .push_back(Event::WindowMoved { window_id: id });
            }
        });

        let s = self.clone();
        mw.expect_focus_with_raise().returning(move |_psn| {
            if s.record_focus_call(id, None) {
                s.focus_window(id);
            }
        });

        let s = self.clone();
        mw.expect_title().returning(move || {
            Ok(s.inner
                .force_read()
                .windows
                .get(&id)
                .map(|w| w.title.clone())
                .unwrap_or_default())
        });
        // The mock reads its title from shared state every time, so there's
        // nothing to invalidate — but the call still needs an expectation.
        mw.expect_invalidate_title().return_const(());

        let s = self.clone();
        mw.expect_is_minimized().returning(move || {
            s.inner
                .force_read()
                .windows
                .get(&id)
                .is_some_and(|w| w.minimized)
        });

        let s = self.clone();
        mw.expect_update_frame()
            .returning(move || s.read_window_frame(id));

        let s = self.clone();
        mw.expect_identifier().returning(move || {
            Ok(s.inner
                .force_read()
                .windows
                .get(&id)
                .map(|w| w.identifier.clone())
                .unwrap_or_default())
        });

        let s = self.clone();
        mw.expect_role().returning(move || {
            s.inner
                .force_read()
                .windows
                .get(&id)
                .map(|w| w.role.clone())
                .ok_or_else(|| crate::errors::Error::Generic(format!("window {id} not found")))
        });

        let s = self.clone();
        mw.expect_subrole().returning(move || {
            Ok(s.inner
                .force_read()
                .windows
                .get(&id)
                .map(|w| w.subrole.clone())
                .unwrap_or_default())
        });

        let s = self.clone();
        mw.expect_child_role().returning(move || {
            Ok(s.inner
                .force_read()
                .windows
                .get(&id)
                .is_some_and(|w| w.child_role))
        });

        let s = self.clone();
        mw.expect_horizontal_padding().returning(move || {
            s.inner
                .force_read()
                .windows
                .get(&id)
                .map(|w| w.horizontal_padding)
                .unwrap_or_default()
        });

        let s = self.clone();
        mw.expect_vertical_padding().returning(move || {
            s.inner
                .force_read()
                .windows
                .get(&id)
                .map(|w| w.vertical_padding)
                .unwrap_or_default()
        });

        let s = self.clone();
        mw.expect_is_full_screen().returning(move || {
            s.inner
                .force_read()
                .windows
                .get(&id)
                .is_some_and(|w| w.is_full_screen)
        });

        let s = self.clone();
        mw.expect_border_radius().returning(move || {
            s.inner
                .force_read()
                .windows
                .get(&id)
                .and_then(|w| w.border_radius)
        });

        // Fill in remaining defaults
        mw.expect_element().return_const(None);
        mw.expect_raise_without_focus().return_const(());

        // Focusing without raising still moves the OS focus, it just leaves the
        // window order alone. Only the app's idea of its focused window changes
        // here: the notification that follows in the real thing is what
        // `focus_window` models, and callers of this already act on their own
        // request. Dropping even this much left the app reporting the previous
        // window, which made `window_focused_trigger` discard events for the
        // window that had actually been focused.
        let s = self.clone();
        mw.expect_focus_without_raise()
            .returning(move |_psn, focused, _focused_psn| {
                if s.record_focus_call(id, Some(focused.id())) {
                    s.set_focused_window(id);
                    s.take_front_from_engine(id);
                }
            });
        let s = self.clone();
        mw.expect_set_padding().returning(move |padding| {
            if let Some(window) = s.inner.force_write().windows.get_mut(&id) {
                match padding {
                    crate::manager::WindowPadding::Horizontal(value) => {
                        window.requested_padding.0 = Some(value);
                    }
                    crate::manager::WindowPadding::Vertical(value) => {
                        window.requested_padding.1 = Some(value);
                    }
                }
            }
        });

        Window::new(Box::new(mw))
    }

    pub fn create_application(&self, pid: Pid) -> Application {
        let mut ma = MockApplicationApi::new();
        let s = self.clone();

        ma.expect_pid().return_const(pid);
        ma.expect_psn()
            .returning(move || s.inner.force_read().apps.get(&pid).map(|a| a.psn).unwrap());

        let s = self.clone();
        ma.expect_focused_window_id().returning(move || {
            s.inner
                .force_read()
                .apps
                .get(&pid)
                .and_then(|a| a.focused_window_id)
                .ok_or(Error::InvalidWindow)
        });

        let s = self.clone();
        ma.expect_focused_window().returning(move |_config| {
            let inner = s.inner.force_read();
            let focused_id = inner.apps.get(&pid).and_then(|a| a.focused_window_id)?;
            if inner.windows.contains_key(&focused_id) {
                Some(s.create_window(focused_id))
            } else {
                None
            }
        });

        let s = self.clone();
        ma.expect_bundle_id().returning(move || {
            s.inner
                .force_read()
                .apps
                .get(&pid)
                .map(|a| a.bundle_id.clone())
        });

        let name = self
            .inner
            .force_read()
            .apps
            .get(&pid)
            .map(|a| a.name.clone())
            .unwrap();
        ma.expect_name().return_const(name);

        let s = self.clone();
        ma.expect_is_frontmost().returning(move || {
            s.inner
                .force_read()
                .apps
                .get(&pid)
                .is_some_and(|a| a.is_frontmost)
        });

        let s = self.clone();
        ma.expect_connection().returning(move || {
            s.inner
                .force_read()
                .apps
                .get(&pid)
                .and_then(|a| a.connection)
        });

        ma.expect_observe().returning(|| Ok(true));
        ma.expect_observe_window().returning(|_| Ok(true));
        ma.expect_unobserve_window().return_const(());
        let s = self.clone();
        let window_ids = move || {
            let inner = s.inner.force_read();
            inner
                .windows
                .values()
                .filter(|w| w.pid == pid)
                .map(|w| w.id)
                .chain(
                    inner
                        .stale_window_ids
                        .iter()
                        .filter(|&(_, &owner)| owner == pid)
                        .map(|(&id, _)| id),
                )
                .collect::<Vec<_>>()
        };

        let (s, ids) = (self.clone(), window_ids.clone());
        ma.expect_window_list().returning(move |_| {
            s.inner.force_write().window_list_scans += 1;
            ids().into_iter().map(|id| s.create_window(id)).collect()
        });

        let (s, ids) = (self.clone(), window_ids.clone());
        ma.expect_ax_window_ids().returning(move || {
            let background = s.inner.force_read().background_tabs.clone();
            ids()
                .into_iter()
                .filter(|id| !background.contains(id))
                .collect()
        });

        Application::new(Box::new(ma))
    }

    #[allow(clippy::too_many_lines)]
    pub fn create_window_manager(&self) -> MockWindowManagerApi {
        let mut wm = MockWindowManagerApi::new();

        let s = self.clone();
        wm.expect_window_is_unordered().returning(move |window_id| {
            let inner = s.inner.force_read();
            inner.unordered_windows.contains(&window_id) || !inner.windows.contains_key(&window_id)
        });

        let s = self.clone();
        wm.expect_active_display_id()
            .returning(move || Ok(s.inner.force_read().active_display_id));

        let s = self.clone();
        wm.expect_active_display_space().returning(move |id| {
            s.inner
                .force_read()
                .displays
                .get(&id)
                .map(|d| d.workspaces[0])
                .ok_or(Error::InvalidWindow)
        });

        let s = self.clone();
        wm.expect_is_fullscreen_space()
            .returning(move |display_id| {
                let inner = s.inner.force_read();
                inner
                    .displays
                    .get(&display_id)
                    .and_then(|display| display.workspaces.first())
                    .is_some_and(|workspace_id| inner.fullscreen_spaces.contains(workspace_id))
            });

        let s = self.clone();
        wm.expect_present_displays().returning(move || {
            s.inner
                .force_read()
                .displays
                .values()
                .map(|d| {
                    (
                        Display::new(d.id, d.bounds, TEST_MENUBAR_HEIGHT),
                        d.workspaces.clone(),
                    )
                })
                .collect()
        });

        let s = self.clone();
        wm.expect_find_existing_application_windows()
            .returning(move |app, spaces, _config| {
                let pid = app.pid();
                let mut windows = s
                    .inner
                    .force_read()
                    .windows
                    .values()
                    .filter_map(|w| {
                        (w.pid == pid && spaces.contains(&w.workspace_id))
                            .then_some(s.create_window(w.id))
                    })
                    .collect::<Vec<_>>();
                windows.sort_unstable_by_key(|window| window.id());
                Ok((windows, vec![]))
            });

        let s = self.clone();
        wm.expect_windows_in_workspace()
            .returning(move |workspace_id| {
                let mut windows = s
                    .inner
                    .force_read()
                    .windows
                    .values()
                    .filter_map(|w| (w.workspace_id == workspace_id).then_some(w.id))
                    .collect::<Vec<_>>();
                // Sort the windows to keep the tests consistent
                windows.sort_unstable();
                Ok(windows)
            });

        let s = self.clone();
        wm.expect_windows_on_screen().returning(move || {
            let windows = s
                .inner
                .force_read()
                .windows
                .iter()
                .filter_map(|(id, window)| window.visible.then_some(id))
                .copied()
                .collect::<Vec<_>>();
            Some(windows)
        });

        let s = self.clone();
        wm.expect_on_screen_window_bounds().returning(move || {
            let windows = s
                .inner
                .force_read()
                .windows
                .iter()
                .filter_map(|(id, window)| window.visible.then_some((*id, window.frame)))
                .collect::<Vec<_>>();
            Some(windows)
        });

        let s = self.clone();
        wm.expect_hold_keyboard().returning(move |previous| {
            s.activate_engine(previous);
            Some(ENGINE_PSN)
        });

        let s = self.clone();
        wm.expect_warp_mouse()
            .returning(move |origin| s.inner.force_write().cursor_position = origin);

        let s = self.clone();
        wm.expect_cursor_position()
            .returning(move || Some(origin_to(s.inner.force_read().cursor_position)));

        wm.expect_get_associated_windows().return_const(vec![]);

        let s = self.clone();
        wm.expect_find_window_at_point().returning(move |at_point| {
            let point = origin_from(*at_point);
            s.inner
                .force_read()
                .windows
                .iter()
                .find_map(|(id, window)| window.frame.contains(point).then_some(id))
                .ok_or(Error::NotFound(format!("no window found at point {point}")))
                .copied()
        });

        wm
    }

    pub fn create_process(&self, pid: Pid) -> MockProcessApi {
        let mut mp = MockProcessApi::new();
        let s = self.clone();

        let name = self
            .inner
            .force_read()
            .apps
            .get(&pid)
            .map(|a| a.name.clone())
            .unwrap();
        mp.expect_name().return_const(name);

        mp.expect_pid().return_const(pid);
        mp.expect_psn()
            .returning(move || s.inner.force_read().apps.get(&pid).map(|a| a.psn).unwrap());
        mp.expect_is_observable().returning(|| true);
        mp.expect_application().return_const(None);
        mp.expect_ready().return_const(true);
        mp.expect_force_manage().return_const(());

        mp
    }
}
