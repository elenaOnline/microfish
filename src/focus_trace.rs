//! Stage timing for one window focus, from the request that asked for it to the
//! OS acknowledging it.
//!
//! Every focus the user starts (a tab click through the navigator bridge, a
//! Hyper+H/L key binding) leaves one `info` line on the `microfish::focus_trace`
//! target when it completes:
//!
//! ```text
//! focus-trace kind=click window=149370 epoch_ms=1793167550123 snap_gap=5.81ms end=marker \
//!   total=41.20ms ipc_in@0.00 queued@0.05 woke@0.21 op_apply@1.58 focus_trigger@1.73 \
//!   raise_begin@1.80 slps_front@3.10 key_window@3.34 ax_raise@4.02 os_focus@18.90 marker@41.20
//! ```
//!
//! Each `stage@ms` is milliseconds since the trace began (monotonic clock), so
//! the difference of two neighbours is the time spent between them. `epoch_ms`
//! is the wall-clock time of stage zero, for lining a trace up with the
//! helper's `navigator.log`. Grep `work/paneru.stderr.log` for `focus-trace`.
//!
//! Cost when nothing is being traced is one relaxed atomic load per call site.
//! A trace that never reaches a focus operation (a key binding that swaps
//! windows, say) is dropped without a line, so the log carries focuses only.

use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

/// A trace older than this is abandoned: whatever it was waiting for is not coming.
const STALE: Duration = Duration::from_secs(3);
/// A snapshot request this close before a focus request is reported as the
/// bridge's preflight.
const SNAPSHOT_WINDOW: Duration = Duration::from_secs(1);
const MAX_MARKS: usize = 32;

struct Trace {
    kind: &'static str,
    window: Option<i32>,
    t0: Instant,
    epoch_ms: u128,
    snap_gap: Option<Duration>,
    marks: Vec<(&'static str, Duration)>,
    /// A focus operation ran, so this trace is worth a line.
    focused: bool,
    os_focus: bool,
    marker: bool,
}

impl Trace {
    fn new(kind: &'static str, window: Option<i32>, snap_gap: Option<Duration>) -> Self {
        Self {
            kind,
            window,
            t0: Instant::now(),
            epoch_ms: SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map_or(0, |d| d.as_millis()),
            snap_gap,
            marks: Vec::new(),
            focused: false,
            os_focus: false,
            marker: false,
        }
    }

    fn stale(&self) -> bool {
        self.t0.elapsed() > STALE
    }

    fn push(&mut self, stage: &'static str) {
        if self.marks.len() < MAX_MARKS {
            self.marks.push((stage, self.t0.elapsed()));
        }
    }

    fn render(&self, end: &str) -> String {
        use std::fmt::Write as _;
        let ms = |d: Duration| d.as_secs_f64() * 1000.0;
        let mut line = format!("focus-trace kind={}", self.kind);
        if let Some(window) = self.window {
            _ = write!(line, " window={window}");
        }
        _ = write!(line, " epoch_ms={}", self.epoch_ms);
        if let Some(gap) = self.snap_gap {
            _ = write!(line, " snap_gap={:.2}ms", ms(gap));
        }
        let total = self.marks.last().map_or(Duration::ZERO, |(_, at)| *at);
        _ = write!(line, " end={end} total={:.2}ms", ms(total));
        for (stage, at) in &self.marks {
            _ = write!(line, " {stage}@{:.2}", ms(*at));
        }
        line
    }
}

/// The one trace in flight. Focuses are human-paced; a new one replaces the old.
pub struct Tracer {
    active: AtomicBool,
    current: Mutex<Option<Trace>>,
    last_snapshot: Mutex<Option<Instant>>,
}

impl Tracer {
    pub const fn new() -> Self {
        Self {
            active: AtomicBool::new(false),
            current: Mutex::new(None),
            last_snapshot: Mutex::new(None),
        }
    }

    fn with<R>(&self, f: impl FnOnce(&mut Option<Trace>) -> R) -> R {
        let mut guard = self
            .current
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        f(&mut guard)
    }

    /// Stores `next`, returning the line for whatever it replaced, if that was a focus.
    fn replace(&self, next: Option<Trace>) -> Option<String> {
        self.active.store(next.is_some(), Ordering::Release);
        self.with(|slot| std::mem::replace(slot, next))
            .filter(|old| old.focused && !old.stale())
            .map(|old| old.render("superseded"))
    }

    /// The bridge asked for a window snapshot; remembered so the focus request that
    /// follows can report how long after it arrived.
    pub fn snapshot_seen(&self) {
        *self
            .last_snapshot
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(Instant::now());
    }

    /// Starts a trace at stage zero (`first`).
    pub fn begin(
        &self,
        kind: &'static str,
        window: Option<i32>,
        first: &'static str,
    ) -> Option<String> {
        let snap_gap = (kind == "click")
            .then(|| {
                self.last_snapshot
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner)
                    .map(|at| at.elapsed())
            })
            .flatten()
            .filter(|gap| *gap < SNAPSHOT_WINDOW);
        let mut trace = Trace::new(kind, window, snap_gap);
        trace.push(first);
        self.replace(Some(trace))
    }

    pub fn mark(&self, stage: &'static str) {
        if !self.active.load(Ordering::Relaxed) {
            return;
        }
        self.with(|slot| {
            if slot.as_ref().is_some_and(Trace::stale) {
                *slot = None;
                self.active.store(false, Ordering::Release);
            } else if let Some(trace) = slot {
                trace.push(stage);
            }
        });
    }

    /// Like [`Self::mark`], but a stage already recorded is left alone.
    pub fn mark_once(&self, stage: &'static str) {
        if !self.active.load(Ordering::Relaxed) {
            return;
        }
        self.with(|slot| {
            if let Some(trace) = slot
                && !trace.stale()
                && !trace.marks.iter().any(|(name, _)| *name == stage)
            {
                trace.push(stage);
            }
        });
    }

    /// A focus operation on `window` is starting. Joins the trace in flight (the
    /// click or key that asked for it) or, when nothing asked, starts its own.
    pub fn focus_started(&self, window: i32, stage: &'static str) -> Option<String> {
        let started = self.with(|slot| {
            if let Some(trace) = slot
                && !trace.stale()
            {
                trace.focused = true;
                // A request for another window (a retry, a tab group) re-targets
                // the trace rather than waiting on an id that will not come.
                trace.window = Some(window);
                trace.push(stage);
                true
            } else {
                false
            }
        });
        if started {
            return None;
        }
        let mut trace = Trace::new("other", Some(window), None);
        trace.focused = true;
        trace.push(stage);
        self.replace(Some(trace))
    }

    /// The OS reported `window` focused (the AX notification, named).
    pub fn os_focus(&self, window: i32) -> Option<String> {
        if !self.active.load(Ordering::Relaxed) {
            return None;
        }
        self.settle(|trace| {
            if trace.focused && trace.window == Some(window) && !trace.os_focus {
                trace.os_focus = true;
                trace.push("os_focus");
            }
        })
    }

    /// The engine marked `window` focused: what the navigator bridge waits on.
    pub fn marker(&self, window: i32) -> Option<String> {
        if !self.active.load(Ordering::Relaxed) {
            return None;
        }
        self.settle(|trace| {
            if trace.focused && trace.window == Some(window) && !trace.marker {
                trace.marker = true;
                trace.push("marker");
            }
        })
    }

    /// Applies `update`, and closes the trace once both the OS and the engine have
    /// acknowledged the focus.
    fn settle(&self, update: impl FnOnce(&mut Trace)) -> Option<String> {
        let line = self.with(|slot| {
            let trace = slot.as_mut()?;
            if trace.stale() {
                *slot = None;
                return None;
            }
            update(trace);
            if trace.os_focus && trace.marker {
                let line = trace.render("marker");
                *slot = None;
                return Some(line);
            }
            None
        });
        if line.is_some() {
            self.active.store(false, Ordering::Release);
        }
        line
    }
}

impl Default for Tracer {
    fn default() -> Self {
        Self::new()
    }
}

static TRACER: Tracer = Tracer::new();

fn emit(line: Option<String>) {
    if let Some(line) = line {
        tracing::info!(target: "microfish::focus_trace", "{line}");
    }
}

/// The IPC reader took a navigator tab click: stage zero.
pub(crate) fn begin_click(window: i32) {
    emit(TRACER.begin("click", Some(window), "ipc_in"));
}

/// A key binding fired in the event tap: stage zero.
pub(crate) fn begin_key() {
    emit(TRACER.begin("key", None, "tap"));
}

pub(crate) fn snapshot_seen() {
    TRACER.snapshot_seen();
}

pub(crate) fn mark(stage: &'static str) {
    TRACER.mark(stage);
}

pub(crate) fn mark_once(stage: &'static str) {
    TRACER.mark_once(stage);
}

pub(crate) fn focus_started(window: i32, stage: &'static str) {
    emit(TRACER.focus_started(window, stage));
}

pub(crate) fn os_focus(window: i32) {
    emit(TRACER.os_focus(window));
}

pub(crate) fn marker(window: i32) {
    emit(TRACER.marker(window));
}

/// Observer: a window became the engine's focused window.
pub(crate) fn focused_marker_added(
    trigger: bevy::ecs::observer::On<bevy::ecs::lifecycle::Add, crate::ecs::FocusedMarker>,
    windows: bevy::ecs::system::Query<&crate::manager::Window>,
) {
    if TRACER.active.load(Ordering::Relaxed)
        && let Ok(window) = windows.get(trigger.event().entity)
    {
        marker(window.id());
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn stages(line: &str) -> Vec<&str> {
        line.split_whitespace()
            .filter_map(|word| word.split_once('@').map(|(stage, _)| stage))
            .collect()
    }

    #[test]
    fn a_click_reports_each_stage_once_both_acknowledgements_arrive() {
        let tracer = Tracer::new();
        assert!(tracer.begin("click", Some(7), "ipc_in").is_none());
        tracer.mark("queued");
        tracer.mark_once("woke");
        tracer.mark_once("woke");
        assert!(tracer.focus_started(7, "raise_begin").is_none());
        tracer.mark("ax_raise");
        assert!(tracer.os_focus(7).is_none(), "marker not seen yet");
        let line = tracer.marker(7).expect("both acknowledgements arrived");
        assert!(line.starts_with("focus-trace kind=click window=7 epoch_ms="));
        assert!(line.contains(" end=marker total="));
        assert_eq!(
            stages(&line),
            [
                "ipc_in",
                "queued",
                "woke",
                "raise_begin",
                "ax_raise",
                "os_focus",
                "marker"
            ]
        );
        assert!(!line.contains('\n'));
        assert!(!tracer.active.load(Ordering::Relaxed));
    }

    #[test]
    fn a_trace_that_never_focused_leaves_no_line() {
        let tracer = Tracer::new();
        assert!(tracer.begin("key", None, "tap").is_none());
        tracer.mark("handler");
        // Replaced before any focus operation ran: silent.
        assert!(tracer.begin("key", None, "tap").is_none());
    }

    #[test]
    fn a_focus_that_is_replaced_before_it_settles_is_still_reported() {
        let tracer = Tracer::new();
        tracer.begin("key", None, "tap");
        tracer.focus_started(3, "nofocus_begin");
        let line = tracer
            .begin("key", None, "tap")
            .expect("the unfinished focus reports itself");
        assert!(line.contains("kind=key window=3"));
        assert!(line.contains("end=superseded"));
    }

    #[test]
    fn a_focus_nobody_asked_for_traces_itself() {
        let tracer = Tracer::new();
        assert!(tracer.focus_started(9, "raise_begin").is_none());
        tracer.os_focus(9);
        let line = tracer.marker(9).expect("settled");
        assert!(line.contains("kind=other window=9"));
    }

    #[test]
    fn acknowledgements_for_another_window_do_not_close_the_trace() {
        let tracer = Tracer::new();
        tracer.begin("click", Some(1), "ipc_in");
        tracer.focus_started(1, "raise_begin");
        assert!(tracer.os_focus(2).is_none());
        assert!(tracer.marker(2).is_none());
        assert!(tracer.active.load(Ordering::Relaxed));
    }

    #[test]
    fn marking_without_a_trace_does_nothing() {
        let tracer = Tracer::new();
        tracer.mark("queued");
        tracer.mark_once("woke");
        assert!(tracer.os_focus(1).is_none());
        assert!(tracer.marker(1).is_none());
        assert!(tracer.with(|slot| slot.is_none()));
    }

    #[test]
    fn a_snapshot_just_before_a_click_is_reported_as_the_gap() {
        let tracer = Tracer::new();
        tracer.snapshot_seen();
        tracer.begin("click", Some(1), "ipc_in");
        tracer.focus_started(1, "raise_begin");
        tracer.os_focus(1);
        let line = tracer.marker(1).unwrap();
        assert!(line.contains(" snap_gap="), "{line}");
        let key = Tracer::new();
        key.snapshot_seen();
        key.begin("key", None, "tap");
        key.focus_started(1, "nofocus_begin");
        key.os_focus(1);
        assert!(!key.marker(1).unwrap().contains("snap_gap"));
    }

    #[test]
    fn a_stale_trace_is_dropped_and_not_extended() {
        let tracer = Tracer::new();
        tracer.begin("click", Some(1), "ipc_in");
        tracer.with(|slot| {
            slot.as_mut().unwrap().t0 = Instant::now()
                .checked_sub(STALE + Duration::from_millis(1))
                .unwrap();
        });
        tracer.mark("late");
        assert!(tracer.with(|slot| slot.is_none()));
        assert!(!tracer.active.load(Ordering::Relaxed));
    }
}
