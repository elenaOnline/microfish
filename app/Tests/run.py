#!/usr/bin/env python3
"""Headless test runner for the Microfish helper. Builds app/Sources (+ a suite's test file) into a scratch dir and runs it.
No windows, no Dock icons, no sound; nothing reaches launchd, SMAppService or a real engine (NAVIGATOR_TESTS builds refuse).
Usage: app/Tests/run.py [--scratch DIR] [suite ...]
Suites: provision engine quit live press tabfix queue hudfix leak pixel (default: all that can run here), and
  hud drag spatial team: these four need test sources that live in the old workspace (work/*-tests.swift and
  polish/teams/minimap/tests), not in this repo; they are skipped with that reason.
  pixel needs a baseline tree of the old sources (--pixel-base DIR); without it, it is skipped.
The source list is app/Sources/SOURCES (one filename per line), the same list the build scripts read.
Every suite runs with MICROFISH_SUPPORT_DIR / MICROFISH_LOG_DIR / MICROFISH_RESOURCES / MICROFISH_ENGINE /
MICROFISH_BRIDGE / MICROFISH_AGENT_PLIST pointing into the scratch dir, so no test touches a real install."""
from pathlib import Path
import argparse, os, shutil, subprocess, sys
here = Path(__file__).resolve().parent
app = here.parent
p = argparse.ArgumentParser()
p.add_argument('--scratch', default='/tmp/microfish-app-tests/scratch'); p.add_argument('--src', default=str(app/'Sources')); p.add_argument('--pixel-base')
p.add_argument('suites', nargs='*')
a = p.parse_args(); src = Path(a.src); scratch = Path(a.scratch)
scratch.mkdir(parents=True, exist_ok=True)
SOURCES = [l.strip() for l in (src/'SOURCES').read_text().splitlines() if l.strip() and not l.startswith('#')]
OTHERS = [f for f in SOURCES if f not in ('main.swift', 'Updates.swift')]   # Updates.swift is the only file that imports Sparkle
FW = ['-framework', 'AppKit', '-framework', 'QuartzCore', '-framework', 'ServiceManagement']

# A throwaway install layout for the suite's environment: defaults from app/Resources, nothing real.
fixture = scratch/'fixture'
shutil.rmtree(fixture, ignore_errors=True)
(fixture/'resources/Defaults').mkdir(parents=True); (fixture/'support').mkdir(); (fixture/'logs').mkdir()
res = app/'Resources'
if (res/'shortcut-defaults.json').exists(): shutil.copy2(res/'shortcut-defaults.json', fixture/'resources/shortcut-defaults.json')
if (res/'Defaults').is_dir():
    for f in (res/'Defaults').iterdir(): shutil.copy2(f, fixture/'resources/Defaults'/f.name)
ENV = dict(os.environ, MICROFISH_SUPPORT_DIR=str(fixture/'support'), MICROFISH_LOG_DIR=str(fixture/'logs'), MICROFISH_RESOURCES=str(fixture/'resources'),
           MICROFISH_ENGINE=str(fixture/'no-such-engine'), MICROFISH_BRIDGE=str(fixture/'no-such-bridge'), MICROFISH_AGENT_PLIST=str(fixture/'no-such.plist'))

def build(name, text, others=OTHERS, defines=('NAVIGATOR_TESTS',)):
    d = scratch/name; d.mkdir(exist_ok=True); (d/'main.swift').write_text(text)
    subprocess.run(['swiftc', '-suppress-warnings', *sum([['-D', x] for x in defines], []), *[str(src/f) for f in others], str(d/'main.swift'), '-o', str(d/'tests'), *FW], check=True)
    return d/'tests'
main_text = lambda: (src/'main.swift').read_text()
def with_main(name, test_file): return lambda: build(name, main_text() + '\n' + (here/test_file).read_text())
LIB = ['Paths.swift', 'Provisioning.swift', 'EngineControl.swift', 'EngineRefresh.swift']   # the standalone suites need no UI code
def suite_provision(): return build('provision', (here/'provision-tests.swift').read_text(), others=LIB)
def suite_engine(): return build('engine', (here/'engine-tests.swift').read_text(), others=LIB)
def suite_leak(): return here/'leak-churn.py'
def suite_pixel(): return here/'pixel-diff.py'
SKIPPED = {k: 'its test sources live in the old workspace (work/*-tests.swift, polish/teams/minimap/tests), not in this repo'
           for k in ['hud', 'drag', 'spatial', 'team']}
SUITES = {'provision': suite_provision, 'engine': suite_engine, 'quit': with_main('quit', 'quit-tests.swift'),
          'live': with_main('live', 'live-signals-tests.swift'), 'press': with_main('press', 'press-tests.swift'),
          'tabfix': with_main('tabfix', 'tab-fixes-tests.swift'), 'queue': with_main('queue', 'queue-tests.swift'),
          'hudfix': with_main('hudfix', 'hud-final-tests.swift'), 'updatestop': with_main('updatestop', 'update-stop-tests.swift'), 'leak': suite_leak, 'pixel': suite_pixel}
wanted = a.suites or list(SUITES) + list(SKIPPED)
for n in wanted:
    if n in SKIPPED: print(f'== suite {n}: SKIPPED ({SKIPPED[n]})'); continue
    if n == 'pixel' and not a.pixel_base: print('== suite pixel: SKIPPED (needs --pixel-base DIR, a tree of the old sources to compare renders against; the baseline lived in polish/navigator.git)'); continue
    exe = SUITES[n]()
    if n == 'leak': cmd = [sys.executable, str(exe), '--src', str(src), '--scratch', str(scratch/'leak')]
    elif n == 'pixel': cmd = [sys.executable, str(exe), '--src', str(src), '--base', a.pixel_base, '--scratch', str(scratch/'pixel')]
    else: cmd = [str(exe)]
    r = subprocess.run(cmd, cwd=scratch, env=ENV); print(f'== suite {n}: exit {r.returncode}')
    if r.returncode: sys.exit(r.returncode)
