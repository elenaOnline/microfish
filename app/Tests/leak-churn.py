#!/usr/bin/env python3
"""NSKeyValueDependency churn test (macOS 27 AppKit leak). Builds src + tests/leak-churn-tests.swift and runs it: tab bars,
the minimap HUD, the window-map content and the failure HUD are rebuilt with alternating content for N cycles in unordered
panels, and /usr/bin/heap counts NSKeyValueDependency before and after. Nothing is shown.
Usage: tests/leak-churn.py [--src DIR] [--old] [--n N] [--max GROWTH] [--scen tabs,hud,map,failure] [--scratch DIR]
  --old     SRC is a tree from before the fix (no HUDKit etc.): builds without LEAK_NEWAPI and only prints the growth.
Exit status is non-zero when any surface grew by more than --max (default 12) objects."""
from pathlib import Path
import argparse, os, subprocess, sys, shutil
here = Path(__file__).resolve().parent
p = argparse.ArgumentParser(); p.add_argument('--src', default=str(here.parent/'src')); p.add_argument('--old', action='store_true')
p.add_argument('--n', default='120'); p.add_argument('--max', default='12'); p.add_argument('--scen', default='tabs,hud,map,failure'); p.add_argument('--scratch', default='/tmp/mfperf/leak/churn')
a = p.parse_args(); src = Path(a.src); scratch = Path(a.scratch); shutil.rmtree(scratch, ignore_errors=True); scratch.mkdir(parents=True)
OTHERS = ['TabBars.swift', 'Settings.swift', 'ShortcutRecorder.swift', 'SpatialOverview.swift', 'LiveSignals.swift']
main = (src/'main.swift').read_text()
if 'var ordersPanel' not in main:   # old tree: add the test hook that keeps Navigator.render from ordering its panel
    main = main.replace(' var pressingCard = false\n', ' var pressingCard = false\n var ordersPanel = true\n', 1)
    main = main.replace('  panel.orderFrontRegardless()\n }\n}\n#if !NAVIGATOR_TESTS', '  if ordersPanel { panel.orderFrontRegardless() }\n }\n}\n#if !NAVIGATOR_TESTS', 1)
    assert 'if ordersPanel' in main
(scratch/'main.swift').write_text(main + '\n' + (here/'leak-churn-tests.swift').read_text())
defines = ['NAVIGATOR_TESTS'] + ([] if a.old else ['LEAK_NEWAPI'])
subprocess.run(['swiftc', '-suppress-warnings', *sum([['-D', d] for d in defines], []), *[str(src/f) for f in OTHERS], str(scratch/'main.swift'), '-o', str(scratch/'churn'), '-framework', 'AppKit', '-framework', 'QuartzCore'], check=True)
env = dict(os.environ, LEAK_N=a.n, LEAK_MAX='-1' if a.old else a.max, LEAK_SCEN=a.scen)
r = subprocess.run([str(scratch/'churn')], env=env, stderr=subprocess.DEVNULL)
sys.exit(r.returncode)
