#!/usr/bin/env python3
"""Old/new pixel identity for the view-reuse change. Renders tab bars (all styles, light/dark), the minimap HUD
(cards/compact/titles, plus the failure HUD) and the window-map content offscreen from a BASE source tree and from
--src, and compares the PNG bytes. Offscreen bitmaps only: nothing is shown.
With the new tree each HUD/map state is also rendered through the reuse path (names ending -REUSED, built after the
pooled views served other content) and compared with the base's fresh render of the same state.
Usage: pixel-diff.py --base DIR [--src DIR] [--scratch DIR]   (BASE and SRC are Sources/ directories)"""
from pathlib import Path
import argparse, filecmp, shutil, subprocess, sys
here = Path(__file__).resolve().parent; repo = here.parent
p = argparse.ArgumentParser()
p.add_argument('--src', default=str(repo/'Sources')); p.add_argument('--base')
p.add_argument('--scratch', default='/tmp/microfish-app-tests/pixel')
a = p.parse_args(); scratch = Path(a.scratch); shutil.rmtree(scratch, ignore_errors=True); scratch.mkdir(parents=True)
# The baseline is a tree of the old sources (a src/ directory from before the change under test).
if not a.base: sys.exit('pixel-diff needs --base DIR: a tree of the old sources to compare against')
base = Path(a.base)
new = Path(a.src)
FW = ['-framework', 'AppKit', '-framework', 'QuartzCore', '-framework', 'ServiceManagement']
OLD_OTHERS = ['TabBars.swift', 'Settings.swift', 'ShortcutRecorder.swift', 'SpatialOverview.swift', 'LiveSignals.swift']
def others_for(src, kind):
    listed = Path(src)/'SOURCES'   # the current tree lists its sources; an old tree has the fixed set
    if not listed.exists(): return ['SpatialOverview.swift'] if kind == 'map' else OLD_OTHERS
    every = [l.strip() for l in listed.read_text().splitlines() if l.strip() and l.strip() not in ('main.swift', 'Updates.swift')]
    return ['Paths.swift', 'EngineControl.swift', 'SpatialOverview.swift'] if kind == 'map' else every   # the map is built without Navigator
def build(src, tag, kind, defines):
    d = scratch/f'{kind}-{tag}'; d.mkdir()
    if kind == 'map':
        (d/'main.swift').write_text((here/'pixel-describe.swift').read_text() + '\n' + (here/'pixel-render-map.swift').read_text()); others = others_for(src, kind); defs = ['NAVIGATOR_TESTS'] + defines
    else:
        (d/'main.swift').write_text((Path(src)/'main.swift').read_text() + '\n' + (here/'pixel-describe.swift').read_text() + '\n' + (here/f'pixel-render-{kind}.swift').read_text()); others = others_for(src, kind); defs = ['NAVIGATOR_TESTS'] + defines
    subprocess.run(['swiftc', '-suppress-warnings', *sum([['-D', x] for x in defs], []), *[str(Path(src)/f) for f in others], str(d/'main.swift'), '-o', str(d/'r'), *FW], check=True)
    (d/'png').mkdir(); subprocess.run([str(d/'r'), str(d/'png')], check=True, cwd=d, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return d/'png'
total_bad = 0
for kind in ['tabs', 'hud', 'map']:
    ob = build(base, 'base', kind, []); on = build(new, 'new', kind, ['LEAK_NEWAPI'])
    # Real app icons load through Launch Services asynchronously, so a render can vary run to run even in the old tree.
    # Render the old tree twice and set aside the states it does not reproduce itself.
    again = ob.parent/'png-again'; again.mkdir(); subprocess.run([str(ob.parent/'r'), str(again)], check=True, cwd=ob.parent, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    unstable = {f.name for f in ob.glob('*.*') if not filecmp.cmp(f, again/f.name, shallow=False)}
    if unstable: print(f'{kind}: old tree does not reproduce itself for {sorted(unstable)}; excluded')
    names = sorted(f.name for f in ob.glob('*.*') if f.name not in unstable); bad = [n for n in names if not (on/n).exists() or not filecmp.cmp(ob/n, on/n, shallow=False)]
    reused = sorted(f.name for f in on.glob('*-REUSED.*') if f.name.replace('-REUSED', '') not in unstable); bad_reused = []
    for r in reused:
        b = r.replace('-REUSED', '')
        if not (ob/b).exists() or not filecmp.cmp(ob/b, on/r, shallow=False): bad_reused.append(r)
    print(f'{kind}: {len(names)} renders+dumps compared old/new, {len(bad)} differ; {len(reused)} reused-path renders vs old fresh, {len(bad_reused)} differ')
    for n in bad + bad_reused: print('  DIFF', n)
    total_bad += len(bad) + len(bad_reused)
print('pixel diff:', 'IDENTICAL' if total_bad == 0 else f'{total_bad} DIFFERENT')
sys.exit(1 if total_bad else 0)
