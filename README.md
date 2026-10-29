# Microfish

Microfish is a scrolling, tiling window manager for macOS, in the style of niri and PaperWM. Windows sit
in columns on a strip that scrolls sideways. A column can hold a stack or a set of tabs, and optional
rows put several strips on one display. A three-finger swipe scrolls the strip, and a minimap shows
where you are.

It has two parts:

- **The engine** is a patched build of [Paneru](https://github.com/karinushka/paneru), a Rust/Bevy
  window manager by Karinushka and contributors. It finds windows, lays them out, handles keys and
  gestures, and saves and restores your session.
- **The Microfish app** is a native AppKit/SwiftUI companion. It draws the minimap, the folder-style
  tab bars and the menu-bar window map, and it has a Settings window with a shortcut recorder.

The name is a play on microfiche.

> Status: early. Microfish is developed and used daily on macOS 27 on Apple silicon. It is built for
> macOS 15 and later, but nothing before macOS 27 has been tested. Intel Macs are not supported yet.

## Install

1. Download `Microfish-<version>.zip` from the latest
   [release](https://github.com/elenaOnline/microfish/releases/latest), unzip it, and drag
   **Microfish** into **Applications**.
2. Open Microfish. A fish appears in the menu bar.
3. Give Microfish the access it asks for (next section). Windows start tiling once the engine has it.

Microfish keeps itself up to date (see [Updates](#updates)). To remove it: choose **Quit Microfish**
from the menu-bar icon, then drag Microfish out of Applications. Your settings and saved session stay
in `~/Library/Application Support/Microfish/` until you delete that folder too.

## Permissions

| What | Where in System Settings | Why |
|---|---|---|
| **Microfish Engine**, background item | General › Login Items & Extensions › Allow in the Background | The engine runs as a background process that the app starts and stops. It does not start at login unless Microfish does. |
| **Microfish Engine**, accessibility access | Privacy & Security › Accessibility (named "Device Control and Data Access" on macOS 27) | It moves and resizes windows. |
| **Microfish**, accessibility access | the same pane | Tab bars and the window map raise and focus windows. |
| **Microfish**, Screen Recording (optional) | Privacy & Security › Screen & System Audio Recording | Only for "Match selected tab to app color" in Settings › Appearance. Everything else works without it. |

Microfish has no network access apart from update checks, and it collects nothing.

**Three-finger swipe.** If macOS uses three fingers for "Swipe between full-screen applications"
(Trackpad › More Gestures), set that gesture to four fingers, or switch Microfish to four fingers in
Settings › Behavior.

## Keys

**Hyper** is Control-Option-Command (⌃⌥⌘). Many people map Caps Lock to Hyper with
[Karabiner-Elements](https://karabiner-elements.pqrs.org). Every shortcut can be changed in
Settings › Shortcuts.

| | Default keys |
|---|---|
| Focus | Hyper ← → (or H L) left and right · Hyper J K within a stack |
| Move | Hyper ⇧ ← → (or H L) swap sideways · Hyper ⇧ J K swap within a stack |
| Stacks and tabs | Hyper [ ] stack into the left or right column · Hyper \ unstack · Hyper T show as tabs |
| Size | Hyper R / Hyper ⇧ R wider or narrower · Hyper F full width · Hyper C center · Hyper ⇧ = / − taller or shorter · Hyper E equalize heights |
| Windows and displays | Hyper Space float or tile · Hyper N next display |
| Columns | ⌃⌥ 1–9 focus column N · ⌃⌥⇧ 1–9 swap with column N |
| Views | Hyper 0–9 go to a saved view (an empty slot saves the current one) · Hyper ⇧ 0–9 replace it · Hyper Tab previous view · Hyper Z undo the last move |
| Rows (turn on in Settings › Rows) | Hyper ↑ ↓ change rows · Hyper ⇧ ↑ ↓ move the window to the row above or below · Hyper ⇧ U / I move the whole column |
| Quit | Quit Microfish in the menu-bar icon's menu stops the engine (saving your session) and the app. Hyper Q stops only the engine. |

A three-finger horizontal swipe scrolls the strip, and the scroll modifier (Hyper by default) plus a
scroll does the same. Holding Hyper shows the minimap. Left-click the menu-bar icon for the window map,
right-click it for the menu.

## Settings and your files

Settings are in the menu-bar menu (**Settings…**, ⌘,). Your files live in
`~/Library/Application Support/Microfish/`:

- `preferences.json`: what Settings saves.
- `settings.lua` and `shortcuts.lua`: generated from it. Don't edit them by hand.
- `init.lua`: yours. Microfish's own behaviour loads first, and anything you add below it runs after,
  using Paneru's Lua API (see [SCRIPTING.md](SCRIPTING.md)).
- `State/`: the saved session.

Logs are in `~/Library/Logs/Microfish/`.

## Updates

Microfish uses [Sparkle](https://sparkle-project.org) to check this repository's releases. Every
update is code-signed and notarized by Apple, and signed with an EdDSA key that the app checks before
installing. Before an update replaces the app, Microfish stops the engine cleanly (it saves your
session), then relaunches.

In **Settings › Updates** you can turn automatic checks and automatic installs on or off. **Get beta
updates** also offers pre-releases, which are tested builds from `main` that later become the next
stable version. Turning betas off never downgrades you: you stay on the beta until a newer stable
version arrives. **Check for Updates…** is in the menu-bar menu.

## Build from source

You need macOS 15 or later with Xcode 27's command-line tools (`swiftc`, `codesign`) and a Rust
toolchain (`rustup`; `rust-toolchain.toml` picks the version).

```sh
git clone https://github.com/elenaOnline/microfish.git && cd microfish
app/Scripts/fetch-sparkle.sh     # pinned Sparkle release, checked against its SHA-256
app/Scripts/build-app.sh         # builds build/Microfish.app, signed ad hoc
```

`build-app.sh --help` lists the options (`--sign` for a Developer ID, `--package` for a zip). The
helper builds with plain `swiftc`, not SwiftPM or Xcode projects. An ad hoc build gets its own
permission entries, and macOS asks again after each rebuild.

To build only the engine, run `cargo build --release --features microfish`. To run the helper's
headless tests, run `python3 app/Tests/run.py`. To run the engine's tests, run `cargo test`.
[RELEASING.md](RELEASING.md) describes the release pipeline and its branches.

## Layout

| Path | What |
|---|---|
| `src/`, `Cargo.toml` | The engine: Paneru plus Microfish's patches. Upstream's layout is kept so upstream changes can be merged. |
| `app/Sources/` | The Microfish app. `SOURCES` lists what goes into the build. |
| `app/Resources/` | The icon, `Lua/microfish.lua` (Microfish's behaviour), and `Defaults/` (first-run files) |
| `app/Packaging/` | Info.plists, entitlements, the engine's launch agent |
| `app/Scripts/` | Build, package, version, appcast and release scripts |
| `app/Tests/` | Headless tests: no windows, nothing on screen |
| `PANERU-README.md`, `ARCHITECTURE.md`, `CONFIGURATION.md`, `SCRIPTING.md` | Paneru's own documentation, which still describes the engine |

## Credits

- **[Paneru](https://github.com/karinushka/paneru)** by Karinushka and contributors is the engine
  Microfish is built on (MIT). Its full history is in this repository. Most of what makes window
  management work here is theirs.
- **[Sparkle](https://sparkle-project.org)** handles updates (MIT, with notices in
  `Contents/Resources/Credits/`).
- [niri](https://github.com/YaLTeR/niri) and [PaperWM](https://github.com/paperwm/PaperWM) are the
  inspiration for the scrolling model.
- The Rust crates the engine uses are listed with their licenses in
  `Microfish.app/Contents/Resources/Credits/RustDependencies.txt`.

## License

MIT, the same license as Paneru. See [LICENSE.txt](LICENSE.txt), which keeps Paneru's notice and adds
one for the Microfish additions.
