#!/usr/bin/env python3
"""Performance-team headless runner: builds src/ + tests into a scratch dir and runs them. No windows.
Usage: tests/run.py [--scratch DIR] [suite ...]   suites: hud drag spatial team live press tabfix queue hudfix leak pixel (default: all)
The hud/drag/spatial suites are the Minimap team's existing ones (read from the main tree's work/)."""
from pathlib import Path
import argparse, shutil, subprocess, sys
here = Path(__file__).resolve().parent
root = Path('/path/to/microfish-workspace')
p = argparse.ArgumentParser(); p.add_argument('--scratch', default='/tmp/mfperf/scratch'); p.add_argument('--src', default=str(here.parent/'src')); p.add_argument('--overlay', help='dir mirroring root-relative test files that replace the main tree copies'); p.add_argument('suites', nargs='*')
a = p.parse_args(); src = Path(a.src); scratch = Path(a.scratch); (scratch/'work/spatial-tests').mkdir(parents=True, exist_ok=True)
if (root/'work/navigator.tsv').exists(): shutil.copy2(root/'work/navigator.tsv', scratch/'work/navigator.tsv')
FW = ['-framework', 'AppKit', '-framework', 'QuartzCore']
OTHERS = [f for f in ['TabBars.swift', 'Settings.swift', 'ShortcutRecorder.swift', 'SpatialOverview.swift', 'LiveSignals.swift'] if (src/f).exists()]
def build(name, text, others=OTHERS, defines=('NAVIGATOR_TESTS',)):
    d = scratch/name; d.mkdir(exist_ok=True); (d/'main.swift').write_text(text)
    subprocess.run(['swiftc', '-suppress-warnings', *sum([['-D', x] for x in defines], []), *[str(src/f) for f in others], str(d/'main.swift'), '-o', str(d/'tests'), *FW], check=True)
    return d/'tests'
def rd(rel):
    if a.overlay and (Path(a.overlay)/rel).exists(): return (Path(a.overlay)/rel).read_text()
    return (root/rel).read_text()
def suite_hud(): return build('hud', (src/'main.swift').read_text()+'\n'+rd('work/hud-all-rows-tests.swift'))
def suite_drag():
    text = '\n'.join([(src/'main.swift').read_text()] + [rd(f'work/{n}.swift') for n in ['navigator-click-tests','navigator-tab-tests','navigator-preferences-tests','navigator-tab-order-tests','navigator-drag-tests']])
    for f in ['work/minimap-group-icons-tests.swift','work/rows-minimap-tests.swift']: text += '\ndo {\n'+rd(f)+'\n}'
    return build('drag', text)
def suite_spatial(): return build('spatial', rd('work/spatial-tests/main.swift'), others=['SpatialOverview.swift'], defines=())
def suite_live(): return build('live', (src/'main.swift').read_text()+'\n'+(here/'live-signals-tests.swift').read_text())
def suite_team():
    # Minimap team's t_*.swift (each in its own do{} scope after main.swift), read from their tests dir.
    # All of Minimap's t_*.swift pass on main now (their round-2 source landed). If their tests directory runs ahead of
    # main again, pin the files that pass on main here (the 7 older files gave 204 checks on 282dd80).
    files = sorted((root/'polish/teams/minimap/tests').glob('t_*.swift'))
    ov = Path(a.overlay)/'polish/teams/minimap/tests' if a.overlay else None
    files = [ov/f.name if ov and (ov/f.name).exists() else f for f in files]
    prelude = 'var teamChecks=0\nfunc teamCheck(_ c: @autoclosure () -> Bool, _ m: String) { precondition(c(), m); teamChecks += 1 }\n'
    # The map tile is an NSControl now (NSButton leaks KVO dependencies on macOS 27): two assertions are adjusted textually.
    body = '\n'.join(f'do {{ // {f.name}\n{f.read_text().replace("is NSButton || m.visibleRect", "is NSControl || m.visibleRect").replace("$0 as? NSButton }.first { $0.accessibilityLabel()", "$0 as? NSControl }.first { $0.accessibilityLabel()")}\n}}' for f in files)
    return build('team', (src/'main.swift').read_text()+'\n'+prelude+body+'\nprint("Minimap team checks passed:", teamChecks)\n')
def suite_press(): return build('press', (src/'main.swift').read_text()+'\n'+(here/'press-tests.swift').read_text())
def suite_tabfix(): return build('tabfix', (src/'main.swift').read_text()+'\n'+(here/'tab-fixes-tests.swift').read_text())
def suite_hudfix(): return build('hudfix', (src/'main.swift').read_text()+'\n'+(here/'hud-final-tests.swift').read_text())
def suite_queue(): return build('queue', (src/'main.swift').read_text()+'\n'+(here/'queue-tests.swift').read_text())
def suite_leak():
    # Flat NSKeyValueDependency count over view-rebuild churn (tests/leak-churn.py); a stand-in "binary" for the loop below.
    return here/'leak-churn.py'
def suite_pixel(): return here/'pixel-diff.py'
SUITES = {'hud': suite_hud, 'drag': suite_drag, 'spatial': suite_spatial, 'team': suite_team, 'live': suite_live, 'press': suite_press, 'tabfix': suite_tabfix, 'queue': suite_queue, 'hudfix': suite_hudfix, 'leak': suite_leak, 'pixel': suite_pixel}
for n in (a.suites or list(SUITES)):
    exe = SUITES[n]()
    cmd = [sys.executable, str(exe), '--src', str(src)] if n in ('leak', 'pixel') else [str(exe)]
    r = subprocess.run(cmd, cwd=scratch); print(f'== suite {n}: exit {r.returncode}')
    if r.returncode: sys.exit(r.returncode)
