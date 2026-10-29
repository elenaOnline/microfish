//! Bundled mode: the engine as `Microfish.app/Contents/Helpers/Microfish Engine.app`.
//!
//! A static launch agent starts the engine with `MICROFISH_BUNDLED=1`. In that mode the
//! engine finds its files by itself: where the user's data lives, where logs go, where the
//! product's Lua and defaults sit inside the outer app. Without the variable none of this
//! runs and the engine behaves like upstream Paneru.
//!
//! Layout (all overridable for tests, see [`Locations::resolve`]):
//!
//! | what      | default                                       | override                |
//! |-----------|-----------------------------------------------|-------------------------|
//! | support   | `~/Library/Application Support/Microfish`     | `MICROFISH_SUPPORT_DIR` |
//! | state     | `<support>/State` (`XDG_STATE_HOME`)          |                         |
//! | runtime   | `<support>/Runtime`                           |                         |
//! | logs      | `~/Library/Logs/Microfish`                    | `MICROFISH_LOG_DIR`     |
//! | resources | the outer app's `Contents/Resources`          | `MICROFISH_RESOURCES`   |
//!
//! [`prepare`] must run first thing in `main`, before any thread exists: it sets
//! environment variables (see [`Locations::exports`]).

use std::ffi::OsString;
use std::fs::{self, OpenOptions};
use std::io;
use std::os::fd::AsRawFd;
use std::path::{Path, PathBuf};

/// Set to `1` by the launch agent's plist.
pub const BUNDLED_ENV: &str = "MICROFISH_BUNDLED";
/// The log is started afresh (and the old one kept as `engine.log.1`) past this size.
const MAX_LOG_BYTES: u64 = 10 * 1024 * 1024;
const LOG_NAME: &str = "engine.log";

/// Whether this process was started as the bundled engine.
pub fn is_bundled() -> bool {
    std::env::var_os(BUNDLED_ENV).is_some_and(|value| value == "1")
}

/// The name to use for the product in text meant for people: Microfish when bundled,
/// upstream's name otherwise.
pub fn product_name() -> &'static str {
    if is_bundled() { "Microfish" } else { "Paneru" }
}

/// Said by the service-management subcommands (`install`, `start`, ...) in bundled mode:
/// the app owns the engine's lifecycle, and a second owner would fight it.
pub const REFUSAL: &str =
    "Microfish manages its engine itself. Use the Microfish app to start, stop or restart it.";

/// Where a bundled engine keeps and finds things.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Locations {
    pub support: PathBuf,
    pub state: PathBuf,
    pub runtime: PathBuf,
    pub logs: PathBuf,
    pub resources: PathBuf,
}

impl Locations {
    /// Works out the locations from an environment lookup and the engine's own path.
    /// Pure: takes the lookup as an argument so tests need no process environment.
    pub fn resolve(var: impl Fn(&str) -> Option<OsString>, exe: &Path) -> Result<Self, String> {
        let path = |name: &str| var(name).filter(|v| !v.is_empty()).map(PathBuf::from);
        let home = path("HOME");
        let in_home = |tail: &str| home.as_ref().map(|h| h.join(tail));

        let support = path("MICROFISH_SUPPORT_DIR")
            .or_else(|| in_home("Library/Application Support/Microfish"))
            .ok_or("HOME is not set, so there is no place for Microfish's files")?;
        let logs = path("MICROFISH_LOG_DIR")
            .or_else(|| in_home("Library/Logs/Microfish"))
            .ok_or("HOME is not set, so there is no place for Microfish's log")?;
        let resources = path("MICROFISH_RESOURCES")
            .or_else(|| resources_from_exe(exe))
            .ok_or_else(|| {
                format!(
                    "{} is not inside Microfish.app/Contents/Helpers, so Microfish's resources can't be found",
                    exe.display()
                )
            })?;

        Ok(Self {
            state: support.join("State"),
            runtime: support.join("Runtime"),
            support,
            logs,
            resources,
        })
    }

    /// The environment variables to set, as pairs. `MICROFISH_*` are always set (the
    /// product's Lua reads them); `PANERU_LUA` and `XDG_STATE_HOME` only when the caller
    /// left them unset, so a developer can still point the engine somewhere else.
    pub fn exports(&self, var: impl Fn(&str) -> Option<OsString>) -> Vec<(&'static str, OsString)> {
        let unset = |name: &str| var(name).is_none_or(|v| v.is_empty());
        let mut pairs = vec![
            ("MICROFISH_SUPPORT", self.support.clone().into_os_string()),
            ("MICROFISH_RUNTIME", self.runtime.clone().into_os_string()),
            (
                "MICROFISH_RESOURCES",
                self.resources.clone().into_os_string(),
            ),
        ];
        if unset("PANERU_LUA") {
            pairs.push(("PANERU_LUA", self.support.join("init.lua").into_os_string()));
        }
        if unset("XDG_STATE_HOME") {
            pairs.push(("XDG_STATE_HOME", self.state.clone().into_os_string()));
        }
        pairs
    }

    pub fn log_file(&self) -> PathBuf {
        self.logs.join(LOG_NAME)
    }
}

/// `<app>/Contents/Helpers/<Name>.app/Contents/MacOS/<exe>` -> `<app>/Contents/Resources`.
fn resources_from_exe(exe: &Path) -> Option<PathBuf> {
    let name = |p: &Path| p.file_name().map(|n| n.to_string_lossy().into_owned());
    let macos = exe.parent()?;
    let inner_contents = macos.parent()?;
    let inner_app = inner_contents.parent()?;
    let helpers = inner_app.parent()?;
    let outer_contents = helpers.parent()?;
    let shape_ok = name(macos).as_deref() == Some("MacOS")
        && name(inner_contents).as_deref() == Some("Contents")
        && inner_app.extension().is_some_and(|ext| ext == "app")
        && name(helpers).as_deref() == Some("Helpers")
        && name(outer_contents).as_deref() == Some("Contents");
    shape_ok.then(|| outer_contents.join("Resources"))
}

/// Moves `log` aside to `<log>.1` (replacing any older one) when it is larger than `max`
/// bytes. Returns whether it did. A missing log is fine.
pub fn rotate_if_larger(log: &Path, max: u64) -> io::Result<bool> {
    match fs::metadata(log) {
        Ok(meta) if meta.len() > max => {
            let mut older = log.as_os_str().to_owned();
            older.push(".1");
            fs::rename(log, older)?;
            Ok(true)
        }
        Ok(_) => Ok(false),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(false),
        Err(error) => Err(error),
    }
}

/// Appends stdout and stderr to `log` from here on.
fn redirect_output_to(log: &Path) -> io::Result<()> {
    let file = OpenOptions::new().create(true).append(true).open(log)?;
    for target in [libc::STDOUT_FILENO, libc::STDERR_FILENO] {
        // SAFETY: both descriptors are open for the life of the process; `file` is valid.
        if unsafe { libc::dup2(file.as_raw_fd(), target) } < 0 {
            return Err(io::Error::last_os_error());
        }
    }
    Ok(())
}

/// Sets the process up as the bundled engine. Call first thing in `main`, before any
/// thread starts (it changes the environment). A failure is reported on stderr and ends
/// the process: an engine that can't find its files can't do anything useful.
pub fn prepare() -> Locations {
    let fail = |message: String| -> ! {
        eprintln!("Microfish engine: {message}");
        std::process::exit(1);
    };
    let exe = std::env::current_exe().unwrap_or_else(|e| fail(format!("can't locate itself: {e}")));
    let locations =
        Locations::resolve(|name| std::env::var_os(name), &exe).unwrap_or_else(|e| fail(e));

    for dir in [
        &locations.support,
        &locations.state,
        &locations.runtime,
        &locations.logs,
    ] {
        if let Err(e) = fs::create_dir_all(dir) {
            fail(format!("can't create {}: {e}", dir.display()));
        }
    }

    let log = locations.log_file();
    let redirected = rotate_if_larger(&log, MAX_LOG_BYTES).and_then(|_| redirect_output_to(&log));
    if let Err(e) = redirected {
        // Carry on: a missing log is better than no window manager.
        eprintln!("Microfish engine: can't write {}: {e}", log.display());
    }

    let exports = locations.exports(|name| std::env::var_os(name));
    for (name, value) in exports {
        // SAFETY: called first thing in `main`, so no other thread reads the environment.
        unsafe { std::env::set_var(name, value) };
    }
    locations
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    const EXE: &str =
        "/Apps/Microfish.app/Contents/Helpers/Microfish Engine.app/Contents/MacOS/Microfish Engine";

    fn lookup(pairs: &[(&str, &str)]) -> impl Fn(&str) -> Option<OsString> {
        let map: HashMap<String, OsString> = pairs
            .iter()
            .map(|(k, v)| ((*k).to_owned(), OsString::from(*v)))
            .collect();
        move |name| map.get(name).cloned()
    }

    #[test]
    fn defaults_come_from_home_and_the_executable() {
        let found = Locations::resolve(lookup(&[("HOME", "/h")]), Path::new(EXE)).unwrap();
        assert_eq!(
            found.support,
            Path::new("/h/Library/Application Support/Microfish")
        );
        assert_eq!(
            found.state,
            Path::new("/h/Library/Application Support/Microfish/State")
        );
        assert_eq!(
            found.runtime,
            Path::new("/h/Library/Application Support/Microfish/Runtime")
        );
        assert_eq!(found.logs, Path::new("/h/Library/Logs/Microfish"));
        assert_eq!(
            found.resources,
            Path::new("/Apps/Microfish.app/Contents/Resources")
        );
        assert_eq!(
            found.log_file(),
            Path::new("/h/Library/Logs/Microfish/engine.log")
        );
    }

    #[test]
    fn overrides_win_and_need_no_home() {
        let env = lookup(&[
            ("MICROFISH_SUPPORT_DIR", "/t/support"),
            ("MICROFISH_LOG_DIR", "/t/logs"),
            ("MICROFISH_RESOURCES", "/t/res"),
        ]);
        let found = Locations::resolve(env, Path::new("/bin/engine")).unwrap();
        assert_eq!(found.support, Path::new("/t/support"));
        assert_eq!(found.state, Path::new("/t/support/State"));
        assert_eq!(found.runtime, Path::new("/t/support/Runtime"));
        assert_eq!(found.logs, Path::new("/t/logs"));
        assert_eq!(found.resources, Path::new("/t/res"));
    }

    #[test]
    fn empty_overrides_are_ignored() {
        let env = lookup(&[("HOME", "/h"), ("MICROFISH_SUPPORT_DIR", "")]);
        let found = Locations::resolve(env, Path::new(EXE)).unwrap();
        assert_eq!(
            found.support,
            Path::new("/h/Library/Application Support/Microfish")
        );
    }

    #[test]
    fn missing_pieces_are_plain_errors() {
        let no_home = Locations::resolve(lookup(&[]), Path::new(EXE)).unwrap_err();
        assert!(no_home.contains("HOME"), "{no_home}");
        let loose = Locations::resolve(
            lookup(&[("HOME", "/h")]),
            Path::new("/usr/local/bin/engine"),
        )
        .unwrap_err();
        assert!(loose.contains("resources"), "{loose}");
    }

    #[test]
    fn resources_need_the_nested_app_shape() {
        let good = Path::new(EXE);
        assert_eq!(
            resources_from_exe(good).unwrap(),
            Path::new("/Apps/Microfish.app/Contents/Resources")
        );
        // Any outer app name works (a renamed or translocated copy).
        assert!(
            resources_from_exe(Path::new(
                "/x/M 2.app/Contents/Helpers/E.app/Contents/MacOS/E"
            ))
            .is_some()
        );
        for bad in [
            "/Apps/Microfish.app/Contents/MacOS/Microfish",
            "/Apps/Microfish.app/Contents/Helpers/Engine/Contents/MacOS/E",
            "/Apps/Microfish.app/Contents/Other/E.app/Contents/MacOS/E",
            "/E",
        ] {
            assert!(resources_from_exe(Path::new(bad)).is_none(), "{bad}");
        }
    }

    #[test]
    fn exports_fill_gaps_only() {
        let found = Locations::resolve(lookup(&[("HOME", "/h")]), Path::new(EXE)).unwrap();
        let get = |pairs: &[(&'static str, OsString)], k: &str| {
            pairs.iter().find(|(n, _)| *n == k).map(|(_, v)| v.clone())
        };

        let fresh = found.exports(lookup(&[]));
        assert_eq!(
            get(&fresh, "PANERU_LUA").unwrap(),
            OsString::from("/h/Library/Application Support/Microfish/init.lua")
        );
        assert_eq!(
            get(&fresh, "XDG_STATE_HOME").unwrap(),
            OsString::from("/h/Library/Application Support/Microfish/State")
        );
        assert_eq!(
            get(&fresh, "MICROFISH_RUNTIME").unwrap(),
            OsString::from("/h/Library/Application Support/Microfish/Runtime")
        );
        assert!(get(&fresh, "MICROFISH_SUPPORT").is_some());
        assert_eq!(
            get(&fresh, "MICROFISH_RESOURCES").unwrap(),
            OsString::from("/Apps/Microfish.app/Contents/Resources")
        );

        let taken = found.exports(lookup(&[
            ("PANERU_LUA", "/dev/init.lua"),
            ("XDG_STATE_HOME", "/dev/state"),
        ]));
        assert!(get(&taken, "PANERU_LUA").is_none());
        assert!(get(&taken, "XDG_STATE_HOME").is_none());
        assert!(get(&taken, "MICROFISH_SUPPORT").is_some());
    }

    fn scratch(name: &str) -> PathBuf {
        let dir =
            std::env::temp_dir().join(format!("microfish-bundled-{}-{name}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn rotation_moves_only_a_log_past_the_limit() {
        let dir = scratch("rotate");
        let log = dir.join("engine.log");
        let older = dir.join("engine.log.1");

        // No log yet: nothing to do.
        assert!(!rotate_if_larger(&log, 10).unwrap());

        // At the limit: kept.
        fs::write(&log, "0123456789").unwrap();
        assert!(!rotate_if_larger(&log, 10).unwrap());
        assert!(log.exists() && !older.exists());

        // Past it: moved aside, so the next open starts a fresh file.
        fs::write(&log, "0123456789+").unwrap();
        assert!(rotate_if_larger(&log, 10).unwrap());
        assert!(!log.exists());
        assert_eq!(fs::read_to_string(&older).unwrap(), "0123456789+");

        // A second rotation replaces the old backup; only one is kept.
        fs::write(&log, "newer, and longer than ten").unwrap();
        assert!(rotate_if_larger(&log, 10).unwrap());
        assert_eq!(
            fs::read_to_string(&older).unwrap(),
            "newer, and longer than ten"
        );
        assert_eq!(fs::read_dir(&dir).unwrap().count(), 1);

        let _ = fs::remove_dir_all(&dir);
    }

    /// Runs inside the child process of `prepare_redirects_and_exports`; does nothing otherwise.
    #[test]
    fn prepare_child() {
        if std::env::var_os("MICROFISH_TEST_CHILD").is_none() {
            return;
        }
        let locations = prepare();
        println!("child-stdout {}", locations.support.display());
        eprintln!("child-stderr {}", std::env::var("PANERU_LUA").unwrap());
        eprintln!("child-state {}", std::env::var("XDG_STATE_HOME").unwrap());
        eprintln!(
            "child-runtime {}",
            std::env::var("MICROFISH_RUNTIME").unwrap()
        );
    }

    #[test]
    fn prepare_redirects_and_exports() {
        let dir = scratch("prepare");
        let (support, logs, res) = (dir.join("Support"), dir.join("Logs"), dir.join("Res"));
        // An oversized earlier log is rotated at startup; the child then appends to a fresh one.
        fs::create_dir_all(&logs).unwrap();
        fs::write(
            logs.join(LOG_NAME),
            vec![b'x'; usize::try_from(MAX_LOG_BYTES).unwrap() + 1],
        )
        .unwrap();

        let out = std::process::Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "bundled::tests::prepare_child",
                "--nocapture",
                "--test-threads=1",
            ])
            .env("MICROFISH_TEST_CHILD", "1")
            .env("MICROFISH_SUPPORT_DIR", &support)
            .env("MICROFISH_LOG_DIR", &logs)
            .env("MICROFISH_RESOURCES", &res)
            .env_remove("PANERU_LUA")
            .env_remove("XDG_STATE_HOME")
            .output()
            .unwrap();
        assert!(out.status.success(), "{out:?}");

        let log = fs::read_to_string(logs.join(LOG_NAME)).unwrap();
        assert!(
            log.contains(&format!("child-stdout {}", support.display())),
            "{log}"
        );
        assert!(
            log.contains(&format!(
                "child-stderr {}",
                support.join("init.lua").display()
            )),
            "{log}"
        );
        assert!(
            log.contains(&format!("child-state {}", support.join("State").display())),
            "{log}"
        );
        assert!(
            log.contains(&format!(
                "child-runtime {}",
                support.join("Runtime").display()
            )),
            "{log}"
        );
        assert!(!log.contains('x'), "the oversized log was not rotated");
        assert_eq!(
            fs::metadata(logs.join("engine.log.1")).unwrap().len(),
            MAX_LOG_BYTES + 1
        );
        assert!(support.join("State").is_dir() && support.join("Runtime").is_dir());
        // Nothing of the child's chatter reached the parent's pipes after the redirect.
        assert!(
            !String::from_utf8_lossy(&out.stderr).contains("child-"),
            "{out:?}"
        );

        let _ = fs::remove_dir_all(&dir);
    }
}
