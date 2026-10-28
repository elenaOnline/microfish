//! Small, window-addressed client for the native navigator. Never controls AX directly.
use paneru::types::windowset::{LayoutOp, WindowSet};
use paneru::types::wire::{self, Request, Response, SendPort, Sender};
use std::time::{Duration, Instant};

type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;

fn parse(args: &[String]) -> Result<(bool, i32)> {
    if args.len() != 2 || !matches!(args[0].as_str(), "focus" | "check") {
        return Err("usage: PaneruNavigatorCommand focus|check WINDOW_ID".into());
    }
    let id: i32 = args[1].parse()?;
    if id <= 0 {
        return Err("window ID must be positive".into());
    }
    Ok((args[0] == "focus", id))
}

fn focus_available(set: &WindowSet, id: i32) -> bool {
    let Some(current) = set.current() else {
        return false;
    };
    set.displays()
        .iter()
        .flat_map(|d| d.workspaces.iter())
        .filter(|space| space.native_id == current.native_id)
        .any(|space| {
            space.columns.iter().any(|col| {
                col.windows
                    .iter()
                    .any(|w| w.id == id && w.managed && !w.floating)
            })
        })
}

fn available(set: &WindowSet, id: i32) -> bool {
    set.current().is_some_and(|space| {
        space.columns.iter().any(|col| {
            col.windows
                .iter()
                .any(|w| w.id == id && w.managed && !w.floating)
        })
    })
}

async fn snapshot(sender: &Sender<Request>) -> Result<WindowSet> {
    match sender.call(&Request::WindowSet).await? {
        Response::WindowSet(set) => Ok(*set),
        Response::Error(message) => Err(message.into()),
        _ => Err("unexpected window-set response".into()),
    }
}

async fn run(execute: bool, id: i32) -> Result<()> {
    let sender = wire::connect::<Request>(&wire::service_name())?;
    let set = snapshot(&sender).await?;
    if !focus_available(&set, id) {
        return Err("window is no longer tiled on this desktop".into());
    }
    if !execute {
        println!("target is available; no focus command sent");
        return Ok(());
    }
    sender
        .send(&Request::WindowSetApply(vec![LayoutOp::Focus(id)]))
        .await?;
    // Wait for confirmed engine focus rather than reporting transport success.
    // The engine atomically requests reveal for the same ID. No follow-up acts on
    // whichever window
    // happened to be focused before the click was handled.
    let deadline = Instant::now() + Duration::from_secs(2);
    loop {
        let fresh = snapshot(&sender).await?;
        if !focus_available(&fresh, id) {
            return Err("target disappeared while focusing".into());
        }
        if fresh.focused() == Some(id) {
            return Ok(());
        }
        if Instant::now() >= deadline {
            return Err("window did not accept focus".into());
        }
        std::thread::sleep(Duration::from_millis(20));
    }
}

fn parse_row_drop(args: &[String]) -> Result<wire::RowDrop> {
    let usage =
        "usage: move-column-row SOURCE SOURCE_ROW TARGET_ROW append|before ANCHOR|after ANCHOR";
    if !matches!(args.len(), 5 | 6) || args[0] != "move-column-row" {
        return Err(usage.into());
    }
    let source: i32 = args[1].parse()?;
    let source_row: u32 = args[2].parse()?;
    let target_row: u32 = args[3].parse()?;
    if source <= 0 || source_row == 0 || target_row == 0 {
        return Err("positive window ID and row numbers required".into());
    }
    let anchor = match (args[4].as_str(), args.len()) {
        ("append", 5) => None,
        ("before" | "after", 6) => {
            let id: i32 = args[5].parse()?;
            if id <= 0 {
                return Err("positive anchor ID required".into());
            }
            Some((
                if args[4] == "before" {
                    wire::DropSide::Before
                } else {
                    wire::DropSide::After
                },
                id,
            ))
        }
        _ => return Err(usage.into()),
    };
    Ok(wire::RowDrop {
        source,
        source_row,
        target_row,
        anchor,
        native_workspace: 0,
        display: 0,
    })
}

fn prepare_row_drop(set: &WindowSet, mut drop: wire::RowDrop) -> Result<wire::RowDrop> {
    let display = set
        .displays()
        .iter()
        .find(|d| d.active)
        .ok_or("no active display")?;
    let native = display
        .workspaces
        .iter()
        .find(|w| w.active)
        .ok_or("no active workspace")?
        .native_id;
    let row = |number| {
        display
            .workspaces
            .iter()
            .find(|w| w.native_id == native && w.number == number)
    };
    let contains = |workspace: &paneru::types::windowset::WorkspaceSet, id| {
        workspace.columns.iter().any(|c| {
            c.windows
                .iter()
                .any(|w| w.id == id && w.managed && !w.floating)
        })
    };
    if !row(drop.source_row).is_some_and(|w| contains(w, drop.source)) {
        return Err("source is no longer tiled on the expected row".into());
    }
    let target = row(drop.target_row).ok_or("target row is gone")?;
    if drop.anchor.is_some_and(|(_, id)| !contains(target, id)) {
        return Err("anchor changed row".into());
    }
    drop.native_workspace = native;
    drop.display = display.id;
    Ok(drop)
}

async fn process_row_drop(args: &[String]) -> Result<()> {
    let drop = parse_row_drop(args)?;
    let sender = wire::connect::<Request>(&wire::service_name())?;
    let drop = prepare_row_drop(&snapshot(&sender).await?, drop)?;
    match sender.call(&Request::RowDrop(drop)).await? {
        Response::LayoutDrop => {
            println!("row drop accepted");
            Ok(())
        }
        Response::Error(message) => Err(message.into()),
        _ => Err("unexpected row drop response".into()),
    }
}

fn parse_drop(args: &[String]) -> Result<(wire::DropKind, i32, wire::DropSide, i32)> {
    use wire::{DropKind, DropSide};
    if args.len() != 4 {
        return Err("usage: reorder-column|move-tab|detach-tab SOURCE before|after TARGET".into());
    }
    let kind = match args[0].as_str() {
        "reorder-column" => DropKind::Column,
        "move-tab" => DropKind::Tab,
        "detach-tab" => DropKind::Detach,
        _ => return Err("unknown drop command".into()),
    };
    let source: i32 = args[1].parse()?;
    let target: i32 = args[3].parse()?;
    if source <= 0 || target <= 0 {
        return Err("window IDs must be positive".into());
    }
    let side = match args[2].as_str() {
        "before" => DropSide::Before,
        "after" => DropSide::After,
        _ => return Err("drop side must be before or after".into()),
    };
    Ok((kind, source, side, target))
}

async fn process_drop(args: &[String]) -> Result<()> {
    let (kind, source, side, target) = parse_drop(args)?;
    let sender = wire::connect::<Request>(&wire::service_name())?;
    let set = snapshot(&sender).await?;
    if !available(&set, source) || !available(&set, target) {
        return Err("source and target must be tiled on the current workspace".into());
    }
    let workspace = set.current().ok_or("no current workspace")?;
    let drop = wire::LayoutDrop {
        source,
        target,
        side,
        kind,
        native_workspace: workspace.native_id,
        row: workspace.number,
    };
    match sender.call(&Request::LayoutDrop(drop)).await? {
        Response::LayoutDrop => {
            println!("layout drop accepted");
            Ok(())
        }
        Response::Error(message) => Err(message.into()),
        _ => Err("unexpected layout drop response".into()),
    }
}

#[derive(serde::Deserialize)]
#[serde(deny_unknown_fields)]
struct FloatRule {
    #[serde(default)]
    bundle: Option<String>,
    #[serde(rename = "titlePattern")]
    title_pattern: String,
    enabled: bool,
}

fn load_rules(path: &std::path::Path) -> Result<Vec<(Option<String>, regex::Regex)>> {
    parse_rules(&std::fs::read(path)?)
}

fn parse_rules(bytes: &[u8]) -> Result<Vec<(Option<String>, regex::Regex)>> {
    let rules: Vec<FloatRule> = serde_json::from_slice(bytes)?;
    rules
        .into_iter()
        .filter(|rule| rule.enabled)
        .map(|rule| {
            let pattern = regex::Regex::new(&rule.title_pattern)?;
            Ok((rule.bundle.filter(|bundle| !bundle.is_empty()), pattern))
        })
        .collect()
}

fn float_rule_targets(set: &WindowSet, rules: &[(Option<String>, regex::Regex)]) -> Vec<i32> {
    set.windows()
        .filter(|window| {
            window.managed
                && !window.floating
                && rules.iter().any(|(bundle, pattern)| {
                    bundle
                        .as_ref()
                        .is_none_or(|bundle| bundle == &window.bundle_id)
                        && pattern.is_match(&window.title)
                })
        })
        .map(|window| window.id)
        .collect()
}

async fn process_rules(command: &str, path: &std::path::Path) -> Result<()> {
    // Complete parsing and regex validation before opening a connection.
    let rules = load_rules(path)?;
    if command == "validate-rules" {
        println!("rules are valid");
        return Ok(());
    }
    let sender = wire::connect::<Request>(&wire::service_name())?;
    let set = snapshot(&sender).await?;
    let targets = float_rule_targets(&set, &rules);
    if !targets.is_empty() {
        sender
            .send(&Request::WindowSetApply(
                targets
                    .iter()
                    .map(|id| LayoutOp::SetFloating {
                        window: *id,
                        floating: true,
                    })
                    .collect(),
            ))
            .await?;
    }
    println!("float requested for {} tiled windows", targets.len());
    Ok(())
}

fn view_action(args: &[String]) -> Result<paneru::types::commands::Operation> {
    use paneru::types::commands::Operation;
    match args {
        [verb] if verb == "view-back" => Ok(Operation::ViewBack),
        [verb] if verb == "view-end" => Ok(Operation::ViewEnd),
        [verb] if verb == "undo-move" => Ok(Operation::UndoMove),
        [verb, slot] if verb == "view-pin" || verb == "view-save" => {
            let slot: u8 = slot.parse()?;
            if slot > 9 {
                return Err("view slot must be 0–9".into());
            }
            Ok(if verb == "view-pin" {
                Operation::ViewPin(slot)
            } else {
                Operation::ViewSave(slot)
            })
        }
        _ => Err("invalid view command".into()),
    }
}

fn main() {
    // Bound a stalled daemon call too; the protocol's focus poll alone cannot.
    std::thread::spawn(|| {
        std::thread::sleep(Duration::from_secs(4));
        std::process::exit(1);
    });
    let args = std::env::args().skip(1).collect::<Vec<_>>();
    let result = if args.first().is_some_and(|verb| {
        matches!(
            verb.as_str(),
            "view-back" | "view-end" | "view-pin" | "view-save" | "undo-move"
        )
    }) {
        view_action(&args).and_then(|operation| {
            futures_lite::future::block_on(async {
                let sender = wire::connect::<Request>(&wire::service_name())?;
                sender
                    .send(&Request::Command(paneru::types::commands::Command::Window(
                        operation,
                    )))
                    .await?;
                Ok(())
            })
        })
    } else if args.first().is_some_and(|verb| verb == "move-column-row") {
        futures_lite::future::block_on(process_row_drop(&args))
    } else if args
        .first()
        .is_some_and(|verb| matches!(verb.as_str(), "reorder-column" | "move-tab" | "detach-tab"))
    {
        futures_lite::future::block_on(process_drop(&args))
    } else if args
        .first()
        .is_some_and(|verb| matches!(verb.as_str(), "record-begin" | "record-end"))
    {
        if args.len() == 2 {
            futures_lite::future::block_on(async {
                let sender = wire::connect::<Request>(&wire::service_name())?;
                match sender
                    .call(&Request::Recording {
                        token: args[1].clone(),
                        begin: args[0] == "record-begin",
                    })
                    .await?
                {
                    Response::Recording => {
                        println!("recording lease acknowledged");
                        Ok(())
                    }
                    Response::Error(message) => Err(message.into()),
                    _ => Err("unexpected recording response".into()),
                }
            })
        } else {
            Err("usage: PaneruNavigatorCommand record-begin|record-end TOKEN".into())
        }
    } else if args
        .first()
        .is_some_and(|command| matches!(command.as_str(), "validate-rules" | "apply-float-rules"))
    {
        if args.len() == 2 {
            futures_lite::future::block_on(process_rules(&args[0], std::path::Path::new(&args[1])))
        } else {
            Err("usage: PaneruNavigatorCommand validate-rules|apply-float-rules PATH".into())
        }
    } else {
        parse(&args).and_then(|(execute, id)| futures_lite::future::block_on(run(execute, id)))
    };
    if let Err(error) = result {
        eprintln!("Navigator: {error}");
        std::process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn row_drop_parser_and_snapshot_preflight_reject_stale_or_ambiguous_targets() {
        let args = |parts: &[&str]| parts.iter().map(|s| String::from(*s)).collect::<Vec<_>>();
        let valid = parse_row_drop(&args(&["move-column-row", "123", "1", "2", "append"])).unwrap();
        for invalid in [
            vec!["move-column-row", "0", "1", "2", "append"],
            vec!["move-column-row", "123", "0", "2", "append"],
            vec!["move-column-row", "123", "1", "2", "before"],
            vec!["move-column-row", "123", "1", "2", "after", "0"],
            vec!["move-column-row", "123", "1", "2", "append", "123"],
        ] {
            assert!(parse_row_drop(&args(&invalid)).is_err());
        }
        let mut set = fixture(0, true);
        let mut display = set.displays()[0].clone();
        let mut rows = display.workspaces.as_ref().clone();
        let mut empty = rows[0].clone();
        empty.number = 2;
        empty.active = false;
        empty.columns = std::sync::Arc::new(vec![]);
        rows.push(empty);
        display.workspaces = std::sync::Arc::new(rows);
        set = WindowSet::new(vec![display], Some(123));
        let prepared = prepare_row_drop(&set, valid).unwrap();
        assert_eq!(prepared.native_workspace, 1);
        assert_eq!(prepared.display, 1);
        let mut stale = valid;
        stale.source_row = 2;
        assert!(prepare_row_drop(&set, stale).is_err());
        let mut stale = valid;
        stale.anchor = Some((wire::DropSide::Before, 123));
        assert!(prepare_row_drop(&set, stale).is_err());
        let mut stale = valid;
        stale.target_row = 3;
        assert!(prepare_row_drop(&set, stale).is_err());
        assert!(prepare_row_drop(&fixture(0, false), valid).is_err());
    }

    #[test]
    fn rejects_invalid_or_injected_targets() {
        for args in [
            vec!["focus"],
            vec!["focus", "0"],
            vec!["focus", "-1"],
            vec!["focus", "1;quit"],
            vec!["quit", "1"],
            vec!["focus", "1", "2"],
        ] {
            assert!(parse(&args.into_iter().map(String::from).collect::<Vec<_>>()).is_err());
        }
        assert_eq!(
            parse(&["check".into(), "123".into()]).unwrap(),
            (false, 123)
        );
        assert_eq!(parse(&["focus".into(), "123".into()]).unwrap(), (true, 123));
    }
    #[test]
    fn float_rules_are_exact_bundle_matches_and_idempotent() {
        let set = fixture(0, true);
        let matching = vec![(None, regex::Regex::new("^$").unwrap())];
        assert_eq!(float_rule_targets(&set, &matching), vec![123]);
        assert!(float_rule_targets(&set.float(123), &matching).is_empty());
        let wrong_bundle = vec![(
            Some("com.example.other".into()),
            regex::Regex::new(".*").unwrap(),
        )];
        assert!(float_rule_targets(&set, &wrong_bundle).is_empty());
    }

    #[test]
    fn rule_validation_rejects_bad_enabled_regex_before_ipc() {
        assert!(parse_rules(br#"[{"bundle":"", "titlePattern":"[", "enabled":true}]"#).is_err());
        assert!(
            parse_rules(br#"[{"titlePattern":"[", "enabled":false}]"#)
                .unwrap()
                .is_empty()
        );
    }

    fn fixture(x: i32, active: bool) -> WindowSet {
        use paneru::types::state::Frame;
        use paneru::types::windowset::{ColumnSet, DisplaySet, WindowRec, WorkspaceSet};
        use std::sync::Arc;
        let window = WindowRec {
            id: 123,
            app_name: String::new(),
            bundle_id: String::new(),
            title: String::new(),
            frame: Some(Frame {
                x,
                y: 0,
                width: 400,
                height: 600,
            }),
            floating: false,
            managed: true,
            visible: true,
            focused: true,
        };
        WindowSet::new(
            vec![DisplaySet {
                id: 1,
                frame: Frame {
                    x: 0,
                    y: 0,
                    width: 1000,
                    height: 800,
                },
                active: true,
                workspaces: Arc::new(vec![WorkspaceSet {
                    number: 1,
                    native_id: 1,
                    active,
                    columns: Arc::new(vec![ColumnSet::single(window, 0.4)]),
                    floating: Arc::new(vec![]),
                }]),
            }],
            Some(123),
        )
    }
    #[test]
    fn rejects_stale_workspace_and_missing_windows() {
        assert!(available(&fixture(100, true), 123));
        assert!(!available(&fixture(100, false), 123));
        assert!(!available(&fixture(100, true), 999));
    }
    #[test]
    fn focus_accepts_other_rows_but_drops_stay_on_current_row() {
        use std::sync::Arc;
        let base = fixture(100, true);
        let mut displays = base.displays().to_vec();
        let mut rows = displays[0].workspaces.as_ref().clone();
        let mut other = rows[0].clone();
        other.active = false;
        other.number = 2;
        let mut columns = other.columns.as_ref().clone();
        Arc::make_mut(&mut columns[0].windows)[0].id = 456;
        other.columns = Arc::new(columns);
        rows.push(other);
        displays[0].workspaces = Arc::new(rows);
        let set = WindowSet::new(displays.clone(), Some(123));
        assert!(focus_available(&set, 456));
        assert!(!available(&set, 456));
        Arc::make_mut(&mut displays[0].workspaces)[1].native_id = 99;
        assert!(!focus_available(&WindowSet::new(displays, Some(123)), 456));
    }

    #[test]
    fn drops_require_explicit_positive_targets_and_known_side() {
        for command in ["reorder-column", "move-tab", "detach-tab"] {
            let args = [command, "12", "after", "34"].map(String::from);
            assert!(parse_drop(&args).is_ok());
            for bad in ["0", "-1", "12;quit"] {
                let args = [command, bad, "after", "34"].map(String::from);
                assert!(parse_drop(&args).is_err());
            }
            assert!(parse_drop(&[command, "12", "inside", "34"].map(String::from)).is_err());
        }
    }
    #[test]
    fn absent_target_is_not_available() {
        assert!(!available(&WindowSet::default(), 123));
    }
}
