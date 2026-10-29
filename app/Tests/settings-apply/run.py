#!/usr/bin/env python3
"""Differential test: SettingsApply.swift against the Python reference (apply-settings.py).

For every case in the corpus (hand-written edge cases plus seeded random drafts) the same draft, the same
starting files and the same fake bridge/engine are run through
  * the reference script, copied into a throwaway fixture root (its ROOT is derived from its own location,
    so it never touches the live workspace), and
  * the Swift port, compiled with swiftc into a test binary and pointed at a throwaway support folder
    through MICROFISH_SUPPORT_DIR / MICROFISH_RESOURCES / MICROFISH_BRIDGE / MICROFISH_ENGINE / MICROFISH_LOG_DIR.
Then it compares exit code, stdout, stderr, every written file byte for byte (and its mode), the backup
copies, and every bridge/engine call (argv shape and the rules file the bridge was handed).

Nothing here talks to a real engine: the bridge and the engine are tiny shell scripts that record their
arguments. No windows, no sound, no network. Only the reference script and the test binary are started.

Usage: run.py [--reference PATH] [--scratch DIR] [--fuzz N] [--seed S] [--keep] [-k SUBSTRING]
Exit status 0 only if every case matches.
"""
import argparse, concurrent.futures, json, os, random, re, shutil, stat, subprocess, sys, tempfile, time
from pathlib import Path

HERE = Path(__file__).resolve().parent
APP = HERE.parent.parent
CATALOG = APP / 'Resources/shortcut-defaults.json'
DEFAULT_REFERENCE = HERE.parents[3] / 'reference/apply-settings.py'   # polish/teams/distribution/reference

THIN_INIT = b'-- Microfish user configuration.\ndofile(os.getenv("MICROFISH_RESOURCES").."/Lua/microfish.lua")\n-- settings revision 0\n'
CATALOG_IDS = [a['id'] for a in json.loads(CATALOG.read_text())]

# ---------------------------------------------------------------------------------------- fixtures

class Fixture:
    """One implementation's world for one case."""
    def __init__(self, kind, base, case):
        self.kind, self.base, self.case = kind, Path(base), case
        self.calls = self.base / 'calls.log'
        self.engine_calls = self.base / 'engine-calls.log'
        b = self.base
        for d in ['bin']: (b / d).mkdir(parents=True, exist_ok=True)
        if kind == 'py':
            self.root = b
            for d in ['scripts', 'config', 'work']: (b / d).mkdir(exist_ok=True)
            self.config = b / 'config'
            shutil.copy(REFERENCE, b / 'scripts/apply-settings.py')
            shutil.copy(CATALOG, self.config / 'shortcut-defaults.json')
            self.bridge = b / 'bin/PaneruNavigatorCommand'
            self.engine = b / 'bin/fake-engine'
            import plistlib
            (self.config / 'trial.plist').write_bytes(plistlib.dumps({'ProgramArguments': [str(self.engine)]}))
            self.backups = b / 'work/settings-backups'
        else:
            self.config = b / 'support'
            self.config.mkdir(exist_ok=True)
            self.res = b / 'res'; self.res.mkdir(exist_ok=True)
            shutil.copy(CATALOG, self.res / 'shortcut-defaults.json')
            self.logs = b / 'logs'
            self.bridge = b / 'bin/bridge'
            self.engine = b / 'bin/engine'
            self.backups = self.config / 'Backups/Settings'
        self.draft = b / 'draft.json'
        self._script(self.bridge, self.calls, case.get('bridge', 'exit 0'))
        self._script(self.engine, self.engine_calls, case.get('engine', 'echo "{}"'))
        if case.get('init', THIN_INIT) is not None: (self.config / 'init.lua').write_bytes(case.get('init', THIN_INIT))
        if case.get('prefs') is not None: (self.config / 'preferences.json').write_bytes(case['prefs'])
        for name, body in case.get('files', {}).items(): (self.config / name).write_bytes(body)
        self.draft.write_bytes(case['draft'])

    def _script(self, path, log, body):
        path.write_text(f"""#!/bin/sh
{{ printf 'ARGV %s %s\\n' "$1" "$(basename "$2" 2>/dev/null)"; if [ -f "$2" ]; then cat "$2"; printf '\\n'; fi; }} >> '{log}'
{body}
""")
        path.chmod(0o755)

    def run(self, timeout=90):
        env = dict(os.environ)
        for k in ['MICROFISH_SUPPORT_DIR', 'MICROFISH_RESOURCES', 'MICROFISH_BRIDGE', 'MICROFISH_ENGINE', 'MICROFISH_LOG_DIR', 'PANERU_MACH_SERVICE']: env.pop(k, None)
        if self.kind == 'py':
            cmd = ['/usr/bin/python3', str(self.root / 'scripts/apply-settings.py'), str(self.draft)]
        else:
            env.update(MICROFISH_SUPPORT_DIR=str(self.config), MICROFISH_RESOURCES=str(self.res), MICROFISH_BRIDGE=str(self.bridge),
                       MICROFISH_ENGINE=str(self.engine), MICROFISH_LOG_DIR=str(self.logs))
            cmd = [str(SWIFT_BIN), str(self.draft)]
        self.started = time.time_ns()
        p = subprocess.run(cmd, capture_output=True, env=env, timeout=timeout, cwd=str(self.base))
        return p.returncode, p.stdout.decode('utf-8', 'replace'), p.stderr.decode('utf-8', 'replace')

    # Everything observable after the run, normalised so only real differences remain.
    def snapshot(self):
        snap = {}
        for name in ['preferences.json', 'settings.lua', 'shortcuts.lua', 'init.lua']:
            p = self.config / name
            if p.exists():
                data = p.read_bytes()
                if name == 'init.lua':
                    m = re.search(rb'\n-- settings revision (\d+)\n$', data)
                    if m:
                        snap['revision'] = (int(m.group(1)), self.started)
                        data = data[:m.start(1)] + b'N' + data[m.end(1):]
                snap[name] = (data, stat.S_IMODE(p.stat().st_mode))
            else:
                snap[name] = None
        backups = {}
        if self.backups.exists():
            for d in sorted(self.backups.iterdir()):
                backups[d.name] = {f.name: (f.read_bytes(), stat.S_IMODE(f.stat().st_mode)) for f in sorted(d.iterdir())}
        snap['backup_dirs'] = sorted(backups)
        snap['backups'] = list(backups.values())
        snap['stray'] = sorted(p.name for p in self.config.iterdir() if p.name.startswith('.') or p.name.startswith('settings-'))
        scratch = self.root / 'work' if self.kind == 'py' else self.config / 'Runtime'
        snap['scratch_left'] = sorted(p.name for p in scratch.glob('settings-*') if p.name not in ('settings-backups', 'settings-apply.log')) if scratch.exists() else []
        snap['lock'] = (scratch / 'settings.lock').exists() if self.kind == 'sw' else (self.root / 'work/settings.lock').exists()
        snap['calls'] = self.calls.read_text() if self.calls.exists() else ''
        snap['engine_calls'] = re.sub(r'ARGV [^\n]*\n', lambda m: m.group(0), self.engine_calls.read_text()) if self.engine_calls.exists() else ''
        return snap

def compare_case(case, scratch):
    d = scratch / case['id']
    py, sw = Fixture('py', d / 'py', case), Fixture('sw', d / 'sw', case)
    t0 = time.time()
    r_py, r_sw = py.run(), sw.run()
    s_py, s_sw = py.snapshot(), sw.snapshot()
    problems = []
    # Intentional difference: where Python lets a codec error text through (invalid UTF-8 in a file, or a lone
    # surrogate that cannot be written), the port prints the generic sentence. Settings shows the generic
    # footer line for both (the codec text is not a sentence), and the files written before the failure match.
    codec = re.compile(r"^'utf-8' codec can't (de|en)code .*\n$", re.S)
    if codec.match(r_py[2]): r_py = (r_py[0], r_py[1], 'Microfish couldn’t save these settings.\n')
    for label, a, b in [('exit code', r_py[0], r_sw[0]), ('stdout', r_py[1], r_sw[1]), ('stderr', r_py[2], r_sw[2])]:
        if a != b: problems.append(f'{label}: python {a!r} / swift {b!r}')
    for key in ['preferences.json', 'settings.lua', 'shortcuts.lua', 'init.lua', 'backup_dirs', 'backups', 'stray', 'scratch_left', 'lock', 'calls', 'engine_calls']:
        if key == 'backup_dirs': a, b = len(s_py[key]), len(s_sw[key])
        else: a, b = s_py[key], s_sw[key]
        if a != b:
            detail = ''
            if isinstance(a, tuple) and isinstance(b, tuple):
                detail = f'\n--- python\n{a[0].decode("utf-8","replace")[:600]}\n--- swift\n{b[0].decode("utf-8","replace")[:600]}\n(modes {oct(a[1])} / {oct(b[1])})'
            problems.append(f'{key} differs{detail if detail else f": python {str(a)[:300]!r} / swift {str(b)[:300]!r}"}')
    # The revision line must be a fresh nanosecond timestamp in both.
    original = case.get('init', THIN_INIT) or b''
    case_revisions = {int(x) for x in re.findall(rb'-- settings revision (\d+)\n?$', original)}
    for impl, s in (('python', s_py), ('swift', s_sw)):
        if 'revision' in s:
            rev, started = s['revision']
            if rev in case_revisions: continue
            if not (started <= rev <= time.time_ns() and len(str(rev)) == 19): problems.append(f'{impl} revision {rev} is not a fresh time_ns value')
    # Message wording contract the Settings window relies on.
    if case.get('plain') is not None:
        text = (r_sw[1] + r_sw[2]).strip()
        banned = re.compile(r"manager|engine|lua|paneru|traceback|exception|keyerror|\.json|/Users|exit(ed)? |_|Command '", re.I)
        ok = r_sw[0] == case['plain'] and not banned.search(text) and text.isprintable() and len(text) < 160 and text.endswith('.')
        if not ok: problems.append(f'plain-language contract broken: exit {r_sw[0]}, {text!r}')
    return case['id'], case['name'], problems, round(time.time() - t0, 1), r_sw

# ---------------------------------------------------------------------------------------- corpus

def J(obj, **kw): return json.dumps(obj, **kw).encode()

def corpus():
    cases = []
    def add(name, draft, **kw):
        if not isinstance(draft, bytes): draft = J(draft, allow_nan=True)
        cases.append(dict(name=name, draft=draft, **kw))
    shortcuts = lambda d: {'shortcuts': d}
    # -- valid
    add('empty draft', {})
    add('empty draft, no previous init revision', {}, init=b'-- thin\n')
    add('full valid draft', dict(dragReorder=True, focusFollowsMouse=True, mouseFollowsFocus=True, autoCenter=True, sliverWidth=30, padding=6, windowGap=8,
        swipeSensitivity=0.5, swipeDeceleration=7, swipeFingers=4, reverseSwipe=True, scrollModifier='controlOption', borderColor='#AbCdEf', borderWidth=0,
        borderRadius=20.5, minimapPosition='left', minimapStyle='titles', minimapDelay=2, minimapFade=0.06, showOnHyper=False, hyperHoldDelay=0.5, floatPip=False,
        tabStyle='classic', tabHeight=28, tabMatchAppColor=True, rowsEnabled=True, rowCount=5, minimapHide='timer'))
    add('minimapHide release', {'minimapHide': 'release'})
    add('minimapHide absent stays absent', {'minimapFade': 0.25})
    add('minimapHide bad value', {'minimapHide': 'sometimes'}, plain=1)
    add('minimapHide wrong type', {'minimapHide': 3}, plain=1)
    for v in ['folder', 'folder-compact', 'classic', 'side']: add('tabStyle ' + v, {'tabStyle': v})
    for v in ['bottom', 'top', 'center', 'left', 'right']: add('minimapPosition ' + v, {'minimapPosition': v})
    for v in ['cards', 'compact', 'titles']: add('minimapStyle ' + v, {'minimapStyle': v})
    for v in ['hyper', 'controlOption']: add('scrollModifier ' + v, {'scrollModifier': v})
    add('tabHeight "28" string', {'tabHeight': '28'})
    add('tabHeight "34" string', {'tabHeight': '34'})
    add('tabHeight 28.0 float is rejected', {'tabHeight': 28.0}, plain=1)
    add('tabHeight true', {'tabHeight': True}, plain=1)
    add('tabHeight 30', {'tabHeight': 30}, plain=1)
    add('tabHeight " 28"', {'tabHeight': ' 28'}, plain=1)
    # -- ints vs floats
    add('ints stay ints', dict(swipeSensitivity=1, swipeDeceleration=6, borderWidth=3, borderRadius=14, minimapDelay=3, minimapFade=1, hyperHoldDelay=1))
    add('floats stay floats', dict(sliverWidth=20.0, padding=4.0, windowGap=5.0, swipeFingers=3.0, rowCount=2.0, swipeDeceleration=6.0, borderWidth=2.0))
    add('float 0.06 and friends', dict(minimapFade=0.06, minimapDelay=0.1, hyperHoldDelay=0.05, swipeSensitivity=0.1))
    add('float literals reprint', b'{"minimapFade": 0.060, "swipeSensitivity": 1.50, "borderRadius": 1E1, "borderWidth": 5e-1, "minimapDelay": 2.0e0, "hyperHoldDelay": 0.2500000}')
    add('tiny float', b'{"minimapFade": 1e-05}')
    add('tiny float 0.0001', b'{"minimapFade": 0.0001}')
    add('float needs full digits', b'{"minimapFade": 0.30000000000000004, "swipeSensitivity": 0.1000000000000000055511151231257827}')
    add('negative zero float', b'{"borderWidth": -0.0}')
    add('negative zero int', b'{"borderWidth": -0}')
    add('range edges low', dict(rowCount=2, sliverWidth=0, padding=0, windowGap=0, swipeSensitivity=0.1, swipeDeceleration=1, swipeFingers=3, borderWidth=0, borderRadius=0, minimapDelay=0.1, minimapFade=0, hyperHoldDelay=0.05))
    add('range edges high', dict(rowCount=9, sliverWidth=200, padding=100, windowGap=100, swipeSensitivity=2, swipeDeceleration=10, swipeFingers=4, borderWidth=12, borderRadius=60, minimapDelay=10, minimapFade=3, hyperHoldDelay=2))
    for key, lo, hi in [('rowCount', 2, 9), ('sliverWidth', 0, 200), ('padding', 0, 100), ('windowGap', 0, 100), ('swipeSensitivity', 0.1, 2), ('swipeDeceleration', 1, 10),
                        ('swipeFingers', 3, 4), ('borderWidth', 0, 12), ('borderRadius', 0, 60), ('minimapDelay', 0.1, 10), ('minimapFade', 0, 3), ('hyperHoldDelay', 0.05, 2)]:
        add(f'{key} below range', {key: lo - 0.01 if isinstance(lo, float) or key in ('swipeSensitivity', 'hyperHoldDelay', 'minimapDelay') else lo - 1}, plain=1)
        add(f'{key} above range', {key: hi + 1}, plain=1)
        add(f'{key} string', {key: str(lo)}, plain=1)
        add(f'{key} bool', {key: True}, plain=1)
        add(f'{key} null', {key: None}, plain=1)
        add(f'{key} NaN', f'{{"{key}": NaN}}'.encode(), plain=1)
        add(f'{key} Infinity', f'{{"{key}": Infinity}}'.encode(), plain=1)
        add(f'{key} -Infinity', f'{{"{key}": -Infinity}}'.encode(), plain=1)
        add(f'{key} huge int', f'{{"{key}": {"9" * 40}}}'.encode(), plain=1)
        add(f'{key} huge negative int', f'{{"{key}": -{"9" * 40}}}'.encode(), plain=1)
        add(f'{key} 1e400', f'{{"{key}": 1e400}}'.encode(), plain=1)
    for key in ['sliverWidth', 'padding', 'windowGap', 'swipeFingers', 'rowCount']:
        add(f'{key} fractional', {key: {'swipeFingers': 3.5, 'rowCount': 2.5}.get(key, 3.5)}, plain=1)
    add('two errors: bool before range', {'padding': 500, 'autoCenter': 'yes'}, plain=1)
    add('two errors: range before whole number', {'padding': 3.5, 'rowCount': 99}, plain=1)
    add('two errors: tabHeight first', {'tabHeight': 99, 'dragReorder': 3}, plain=1)
    add('two errors: enum after whole', {'tabStyle': 'wavy', 'padding': 3.5}, plain=1)
    add('two errors: colour after enums', {'borderColor': 'teal', 'tabStyle': 'wavy'}, plain=1)
    add('two errors: rules after colour', {'borderColor': 'teal', 'floatingRules': 'x'}, plain=1)
    # -- bools, enums, colours
    for key in ['dragReorder', 'focusFollowsMouse', 'mouseFollowsFocus', 'autoCenter', 'reverseSwipe', 'showOnHyper', 'floatPip', 'rowsEnabled', 'tabMatchAppColor']:
        for bad in ['yes', 1, 0, None, [], 'true']: add(f'{key} = {bad!r}', {key: bad}, plain=1)
    for key, vals in [('tabStyle', ['wavy', '', 'Folder', 3, None, ['folder']]), ('minimapPosition', ['middle', 'TOP']), ('minimapStyle', ['cardz']), ('scrollModifier', ['Hyper', 'control'])]:
        for bad in vals: add(f'{key} = {bad!r}', {key: bad}, plain=1)
    for c in ['teal', '#12345', '#1234567', '123456', '#GGGGGG', '#12345é', '', None, 5, ' #123456', '#123456\n', '#００００００']:
        add(f'borderColor {c!r}', {'borderColor': c}, plain=1)
    add('borderColor ok lowercase', {'borderColor': '#abcdef'})
    # -- shape of the whole draft
    for name, d in [('list', [1]), ('string', 'x'), ('number', 3), ('null', None), ('true', True)]: add('not an object: ' + name, d, plain=1)
    add('unknown key', {'futureKey': 1}, plain=1)
    add('unknown key beside bad value (unknown wins)', {'futureKey': 1, 'padding': 999}, plain=1)
    add('empty file', b'', plain=1)
    add('whitespace only', b'  \n', plain=1)
    add('truncated json', b'{"padding": 4', plain=1)
    add('trailing comma', b'{"padding": 4,}', plain=1)
    add('trailing garbage', b'{"padding": 4} x', plain=1)
    add('single quotes', b"{'padding': 4}", plain=1)
    add('BOM', b'\xef\xbb\xbf{"padding": 4}', plain=1)
    add('invalid utf-8', b'{"tabAliases": {"a": "\xff"}}', plain=1)
    add('control char in string', b'{"tabAliases": {"a": "x\x01y"}}', plain=1)
    add('literal newline in string', b'{"tabAliases": {"a": "x\ny"}}', plain=1)
    add('bad escape', b'{"tabAliases": {"a": "x\\qy"}}', plain=1)
    add('short \\u escape', b'{"tabAliases": {"a": "x\\u12y"}}', plain=1)
    add('leading zero number', b'{"padding": 04}', plain=1)
    add('plus sign number', b'{"padding": +4}', plain=1)
    add('number 1. ', b'{"padding": 1.}', plain=1)
    add('number .5', b'{"padding": .5}', plain=1)
    add('hex number', b'{"padding": 0x10}', plain=1)
    add('exponent without digits', b'{"padding": 1e}', plain=1)
    add('exponent int-valued', b'{"padding": 1e1}')
    add('capital E exponent', b'{"padding": 1E+1}')
    add('NaN literal elsewhere', b'{"tabAliases": {"a": NaN}}', plain=1)
    add('duplicate keys: last value, first place', b'{"padding": 4, "windowGap": 7, "padding": 9}')
    add('duplicate keys: last one invalid', b'{"padding": 4, "padding": 999}', plain=1)
    add('whitespace variants', b' \t\r\n{ "padding" :\t6 ,\n"windowGap"\r:7 }\n\n')
    add('nested depth 900 in a rule', b'{"floatingRules": [' + b'[' * 900 + b']' * 900 + b']}', plain=1)
    add('nested depth 1200 (parser gives up)', b'{"floatingRules": [' + b'[' * 1200 + b']' * 1200 + b']}', plain=1)
    add('key order: draft order does not matter', b'{"rowCount": 3, "padding": 5, "minimapHide": "timer", "borderColor": "#010203", "rowsEnabled": true}')
    add('minimapHide first in draft', b'{"minimapHide": "release", "padding": 5}')
    # -- floating rules
    rule = lambda **k: dict(id='r1', bundle='com.example.app', titlePattern='^Calc', enabled=True, **k)
    add('one rule', {'floatingRules': [rule()]})
    add('rule with extra keys dropped', {'floatingRules': [dict(id='x', bundle='', titlePattern='.*', enabled=False, junk=[1, 2])]})
    add('rule defaults', {'floatingRules': [{'titlePattern': 'T'}]})
    add('disabled rule not sent to bridge', {'floatingRules': [dict(id='a', bundle='b', titlePattern='c', enabled=False), dict(id='d', bundle='', titlePattern='e', enabled=True)]})
    add('floatPip off, rule on', {'floatPip': False, 'floatingRules': [rule()]})
    add('floatPip off, no rules', {'floatPip': False})
    add('many rules (200)', {'floatingRules': [dict(id=f'i{i}', bundle='b' if i % 2 else '', titlePattern=f'p{i}', enabled=True) for i in range(200)]})
    add('too many rules (201)', {'floatingRules': [dict(id=f'i{i}', bundle='', titlePattern='p', enabled=True) for i in range(201)]}, plain=1)
    add('rules not a list', {'floatingRules': {}}, plain=1)
    add('rules null', {'floatingRules': None}, plain=1)
    add('rule not an object', {'floatingRules': ['x']}, plain=1)
    add('rule empty pattern', {'floatingRules': [dict(id='a', bundle='', titlePattern='')]}, plain=1)
    add('rule missing pattern', {'floatingRules': [dict(id='a')]}, plain=1)
    add('rule enabled not bool', {'floatingRules': [dict(id='a', titlePattern='x', enabled=1)]}, plain=1)
    add('rule id not string', {'floatingRules': [dict(id=5, titlePattern='x')]}, plain=1)
    add('rule bundle null', {'floatingRules': [dict(bundle=None, titlePattern='x')]}, plain=1)
    add('rule pattern 4096 ok', {'floatingRules': [dict(titlePattern='a' * 4096)]})
    add('rule pattern 4097', {'floatingRules': [dict(titlePattern='a' * 4097)]}, plain=1)
    add('rule: empty pattern before an invalid one', {'floatingRules': [dict(titlePattern=''), 5]}, plain=1)
    add('rule: invalid before an empty pattern', {'floatingRules': [5, dict(titlePattern='')]}, plain=1)
    add('rule regex specials and quotes', {'floatingRules': [dict(bundle='a.b', titlePattern=r'^\(Untitled\) "q" \\ tab\there [a-z]+$')]})
    add('rule unicode', {'floatingRules': [dict(id='é', bundle='café', titlePattern='日本語 — ünï \U0001F41F ✓   \u0085 \x7f \x01')]})
    add('rule lone surrogate (settings.lua cannot be written)', b'{"floatingRules": [{"titlePattern": "a\\ud800b"}]}', plain=1)
    add('rule surrogate pair', b'{"floatingRules": [{"titlePattern": "fish \\ud83d\\udc1f"}]}')
    add('rule pattern is a long run of escapes', {'floatingRules': [dict(titlePattern='\\' * 50 + '"' * 50 + '\n\r\t')]})
    # -- tab aliases
    add('aliases', {'tabAliases': {'Calculator': 'Calc', 'Notes': 'N'}})
    add('aliases keep draft order', b'{"tabAliases": {"zebra": "z", "apple": "a", "mid": "m"}}')
    add('alias unicode', {'tabAliases': {'日本語': 'ニホンゴ', 'emoji \U0001F41F': '\U0001F41F\U0001F420', 'é': 'é', 'ctrl\x01': 'x'}})
    add('alias DEL and U+2028', {'tabAliases': {'a\x7f': 'b c\u0085'}})
    add('alias lone surrogate (preferences.json cannot be written)', b'{"tabAliases": {"a": "x\\ud800y"}}', plain=1)
    add('alias key lone surrogate', b'{"tabAliases": {"a\\udfffb": "x"}}', plain=1)
    add('alias value 200 chars ok', {'tabAliases': {'k': 'é' * 200}})
    add('alias value 201 chars', {'tabAliases': {'k': 'x' * 201}}, plain=1)
    add('alias key 8192 chars ok', {'tabAliases': {'k' * 8192: 'v'}})
    add('alias key 8193 chars', {'tabAliases': {'k' * 8193: 'v'}}, plain=1)
    add('alias value with tab', {'tabAliases': {'k': 'a\tb'}}, plain=1)
    add('alias value with newline', {'tabAliases': {'k': 'a\nb'}}, plain=1)
    add('alias value with CR', {'tabAliases': {'k': 'a\rb'}}, plain=1)
    add('alias value not a string', {'tabAliases': {'k': 5}}, plain=1)
    add('aliases not an object', {'tabAliases': []}, plain=1)
    add('500 aliases ok', {'tabAliases': {f'k{i}': f'v{i}' for i in range(500)}})
    add('501 aliases', {'tabAliases': {f'k{i}': 'v' for i in range(501)}}, plain=1)
    # -- shortcuts
    add('shortcut override', shortcuts({'center': 'ctrl + alt - m'}) if 'center' in CATALOG_IDS else shortcuts({CATALOG_IDS[0]: 'ctrl + alt - m'}))
    first, second, third = CATALOG_IDS[0], CATALOG_IDS[1], CATALOG_IDS[2]
    add('shortcut normalised', shortcuts({first: 'Cmd+Shift+Ctrl - ESCAPE'}))
    add('shortcut spacing and case', shortcuts({first: '  CTRL +  alt  -  F12  '}))
    add('shortcut with nbsp around', shortcuts({first: ' ctrl - k '}))
    add('shortcut Kelvin sign lowercases to k', shortcuts({first: 'ctrl - K'}))
    add('shortcut unset (empty)', shortcuts({first: ''}))
    add('shortcut unset (spaces)', shortcuts({first: '   '}))
    add('shortcut unset (unicode space)', shortcuts({first: '　'}))
    add('shortcut all unset', shortcuts({i: '' for i in CATALOG_IDS}))
    add('shortcuts: two unset do not conflict', shortcuts({first: '', second: ''}))
    add('shortcut conflict with default', shortcuts({first: 'ctrl + alt + cmd - h'}), plain=1)
    add('shortcut conflict between drafts', shortcuts({first: 'ctrl - a', second: 'ctrl - a'}), plain=1)
    add('shortcut conflict after normalising', shortcuts({first: 'ctrl - a', second: 'CTRL - A'}), plain=1)
    add('shortcut conflict with differently-ordered modifiers', shortcuts({first: 'alt+ctrl - a', second: 'ctrl + alt - a'}), plain=1)
    add('shortcut conflict, three-way reports the first pair', shortcuts({first: 'ctrl - a', second: 'ctrl - a', third: 'ctrl - a'}), plain=1)
    add('shortcut unknown id', shortcuts({'nope': 'ctrl - a'}), plain=1)
    add('shortcut id wrong case', shortcuts({first.upper(): 'ctrl - a'}), plain=1)
    add('shortcuts not an object', {'shortcuts': []}, plain=1)
    add('shortcuts null', {'shortcuts': None}, plain=1)
    for bad in ['banana', 'ctrl', 'ctrl -', '- a', 'ctrl - ', 'shift - a', 'ctrl - nope', 'ctrl+ctrl - a', 'ctrl + hyper - a', 'ctrl - a - b', 'ctrl-a', 'ctrl  -  a b', 'ctrl + - a', '+ - a', 'ctrl - A1', 'ctrl - f21', 'ctrl - f0', 'ctrl - ß', 'ctrl - İ', 5, None, [], {}, True]:
        add(f'bad chord {bad!r}', shortcuts({first: bad}), plain=1)
    for key in ['a', 'z', '0', '9', 'leftarrow', 'rightarrow', 'uparrow', 'downarrow', 'leftbracket', 'rightbracket', 'backslash', 'equal', 'minus', 'space', 'return', 'tab', 'escape', 'delete', 'forwarddelete', 'home', 'end', 'pageup', 'pagedown', 'semicolon', 'quote', 'comma', 'period', 'slash', 'grave', 'f1', 'f20']:
        add('chord key ' + key, shortcuts({first: 'ctrl + shift - ' + key}))
    for mods in ['ctrl', 'alt', 'cmd', 'ctrl + shift', 'shift + alt', 'cmd + shift + alt + ctrl', 'shift+cmd', 'alt+ctrl+cmd']:
        add('chord modifiers ' + mods, shortcuts({first: mods + ' - q'}))
    add('shortcut error message pair uses labels', shortcuts({first: 'ctrl + alt + cmd - l'}), plain=1)
    # -- existing files / backups
    old = J(dict(padding=9, rowsEnabled=False))
    add('previous files are backed up', {'padding': 7}, prefs=old, files={'settings.lua': b'-- old settings\n', 'shortcuts.lua': b'-- old shortcuts\n'})
    add('previous files with odd bytes are backed up', {'padding': 7}, prefs=old, files={'settings.lua': b'\xff\xfe\x00binary'})
    add('previous preferences unreadable JSON', {'padding': 7}, prefs=b'{broken', plain=1)
    add('previous preferences is a list', {'padding': 7}, prefs=b'[1]', plain=1)
    add('previous preferences empty', {'padding': 7}, prefs=b'', plain=1)
    add('previous preferences not utf-8', {'padding': 7}, prefs=b'\xff', plain=1)
    add('previous preferences with BOM', {'padding': 7}, prefs=b'\xef\xbb\xbf{}', plain=1)
    # -- init.lua revision handling
    user_calls = b'-- mine\npaneru.something(1)\n'
    for name, init in [
        ('thin init with revision 0', THIN_INIT),
        ('init with a big old revision', b'x = 1\n-- settings revision 1790000000000000000\n'),
        ('init without trailing newline after revision', b'x = 1\n-- settings revision 5'),
        ('init with two newlines after revision', b'x = 1\n-- settings revision 5\n\n'),
        ('init with three newlines after revision', b'x = 1\n-- settings revision 5\n\n\n'),
        ('init with spaces after revision', b'x = 1\n-- settings revision 5 \n'),
        ('init with revision in the middle', b'a\n-- settings revision 5\nb\n'),
        ('init with two revision lines', b'a\n-- settings revision 5\n-- settings revision 7\n'),
        ('init with no revision', user_calls),
        ('init without trailing newline', b'x = 1'),
        ('init with trailing blank lines and spaces', b'x = 1\n\n  \t\n\n'),
        ('init with CRLF line endings', b'a = 1\r\nb = 2\r\n-- settings revision 9\r\n'),
        ('init with lone CR line endings', b'a = 1\rb = 2\r'),
        ('init revision line only', b'-- settings revision 5\n'),
        ('init revision line only, leading newline', b'\n-- settings revision 5\n'),
        ('init empty', b''),
        ('init newline only', b'\n'),
        ('init with arabic-indic digits revision', '-- keep\n-- settings revision ٣٤\n'.encode()),
        ('init with revision word but no number', b'x\n-- settings revision \n'),
        ('init with trailing unicode whitespace', 'x  \n'.encode()),
        ('init with unicode and BOM', '﻿-- ünï ✓ \U0001F41F\nx=1\n-- settings revision 1\n'.encode()),
        ('init not utf-8 (fails after the other files are written)', b'x = "\xff"\n'),
        ('init missing (fails after the other files are written)', None),
    ]:
        add(name, {'padding': 5}, init=init)
    # -- bridge behaviour
    raw_dump = "regex parse error:\n    (\n    ^\nerror: unclosed group at /Users/x/src/lib.rs:12"
    bridges = [
        ('bridge rejects: raw dump', f"if [ \"$1\" = validate-rules ]; then echo '{raw_dump}' >&2; exit 1; fi; exit 0", 1),
        ('bridge rejects: short plain line', "if [ \"$1\" = validate-rules ]; then echo 'bad rule: unmatched paren in test' >&2; exit 1; fi; exit 0", None),
        ('bridge rejects: on stdout instead', "if [ \"$1\" = validate-rules ]; then echo 'bad rule: on stdout'; exit 1; fi; exit 0", None),
        ('bridge rejects: stderr empty falls back to stdout', "if [ \"$1\" = validate-rules ]; then echo 'from stdout'; echo '  ' >&2; exit 2; fi; exit 0", None),
        ('bridge rejects: nothing said', "if [ \"$1\" = validate-rules ]; then exit 3; fi; exit 0", 1),
        ('bridge rejects: line of exactly 80', "if [ \"$1\" = validate-rules ]; then printf '%080d\\n' 7 >&2; exit 1; fi; exit 0", None),
        ('bridge rejects: line of 81', "if [ \"$1\" = validate-rules ]; then printf '%081d\\n' 7 >&2; exit 1; fi; exit 0", 1),
        ('bridge rejects: ends with colon', "if [ \"$1\" = validate-rules ]; then echo 'error:' >&2; exit 1; fi; exit 0", 1),
        ('bridge rejects: has a path', "if [ \"$1\" = validate-rules ]; then echo 'bad file a/b' >&2; exit 1; fi; exit 0", 1),
        ('bridge rejects: has a backslash', "if [ \"$1\" = validate-rules ]; then echo 'bad \\\\ file' >&2; exit 1; fi; exit 0", 1),
        ('bridge rejects: has 0x', "if [ \"$1\" = validate-rules ]; then echo 'crash at 0xdeadbeef' >&2; exit 1; fi; exit 0", 1),
        ('bridge rejects: has "at word"', "if [ \"$1\" = validate-rules ]; then echo 'panic at main' >&2; exit 1; fi; exit 0", 1),
        ('bridge rejects: "at" inside a word is fine', "if [ \"$1\" = validate-rules ]; then echo 'what is that' >&2; exit 1; fi; exit 0", None),
        ('bridge rejects: two lines', "if [ \"$1\" = validate-rules ]; then printf 'one\\ntwo\\n' >&2; exit 1; fi; exit 0", 1),
        ('bridge rejects: line with CR LF', "if [ \"$1\" = validate-rules ]; then printf 'bad rule\\r\\n' >&2; exit 1; fi; exit 0", None),
        ('bridge rejects: unicode line', "if [ \"$1\" = validate-rules ]; then echo 'regle invalide: é ✓' >&2; exit 1; fi; exit 0", None),
        ('bridge rejects: padded line', "if [ \"$1\" = validate-rules ]; then echo '   spaced out   ' >&2; exit 1; fi; exit 0", None),
        ('bridge rejects: not utf-8', "if [ \"$1\" = validate-rules ]; then printf '\\377\\n' >&2; exit 1; fi; exit 0", None),
        ('bridge missing for apply-float-rules (floating note)', "if [ \"$1\" = apply-float-rules ]; then echo 'Command failed at /Users/x' >&2; exit 1; fi; exit 0", 0),
        ('apply-float-rules fails quietly', "if [ \"$1\" = apply-float-rules ]; then exit 4; fi; exit 0", 0),
        ('apply-float-rules fails with unicode noise', "if [ \"$1\" = apply-float-rules ]; then printf '\\377\\n' >&2; exit 4; fi; exit 0", None),
        ('validate-rules prints and succeeds', "echo hello; echo hello >&2; exit 0", 0),
    ]
    for name, body, plain in bridges:
        add(name, {'floatingRules': [rule()]}, bridge=body, plain=plain if plain is not None else None)
    add('bridge rejects but draft has an earlier error (bridge never called)', {'padding': 999}, bridge='exit 1', plain=1)
    # -- row reduction
    def reduce_case(name, engine, prefs=None, draft=None, **kw):
        add(name, draft if draft is not None else {'rowsEnabled': True, 'rowCount': 2}, prefs=prefs if prefs is not None else J({'rowsEnabled': True, 'rowCount': 4}), engine=engine, **kw)
    state = lambda active=1, rows=(): json.dumps({'active': {'virtual_workspace_number': active}, 'virtual_workspaces': list(rows)})
    echo = lambda s: "echo '" + s.replace("'", "'\\''") + "'"
    reduce_case('rows: engine fine, nothing in removed rows', echo(state(1, [{'number': 1, 'windows': [{}]}, {'number': 3, 'windows': []}])), plain=0)
    reduce_case('rows: engine exits 3', 'exit 3', plain=1)
    reduce_case('rows: engine prints junk', 'echo "not json"', plain=1)
    reduce_case('rows: engine prints {}', 'echo "{}"', plain=1)
    reduce_case('rows: engine prints a list', 'echo "[]"', plain=1)
    reduce_case('rows: engine prints nothing', 'exit 0', plain=1)
    reduce_case('rows: engine hangs (timeout)', 'exec sleep 30', plain=1)
    reduce_case('rows: active row will go', echo(state(3)), plain=1)
    reduce_case('rows: active row is the new limit', echo(state(2)), plain=0)
    reduce_case('rows: active row float 2.5', echo(state(2.5)), plain=1)
    reduce_case('rows: active row a string', echo(state('a')), plain=1)
    reduce_case('rows: active row missing -> 1', echo(json.dumps({'active': {}, 'virtual_workspaces': []})), plain=0)
    reduce_case('rows: active missing', echo(json.dumps({'virtual_workspaces': []})), plain=1)
    reduce_case('rows: active a list', echo(json.dumps({'active': [], 'virtual_workspaces': []})), plain=1)
    reduce_case('rows: windows in higher rows', echo(state(1, [{'number': 3, 'windows': [{'floating': False}]}])), plain=1)
    reduce_case('rows: floating windows are fine', echo(state(1, [{'number': 3, 'windows': [{'floating': True}, {'floating': 1}]}])), plain=0)
    reduce_case('rows: window without floating key counts as tiled', echo(state(1, [{'number': 4, 'windows': [{}]}])), plain=1)
    reduce_case('rows: window floating null counts as tiled', echo(state(1, [{'number': 4, 'windows': [{'floating': None}]}])), plain=1)
    reduce_case('rows: window floating "no" is truthy', echo(state(1, [{'number': 4, 'windows': [{'floating': 'no'}]}])), plain=0)
    reduce_case('rows: window floating 0', echo(state(1, [{'number': 4, 'windows': [{'floating': 0}]}])), plain=1)
    reduce_case('rows: a later non-object window is never reached', echo(state(1, [{'number': 4, 'windows': [{}, 5]}])), plain=1)
    reduce_case('rows: floating then a non-object window', echo(state(1, [{'number': 4, 'windows': [{'floating': True}, 5]}])), plain=1)
    reduce_case('rows: row without windows (not above limit)', echo(state(1, [{'number': 1}])), plain=0)
    reduce_case('rows: row without windows above limit', echo(state(1, [{'number': 3}])), plain=1)
    reduce_case('rows: windows empty object', echo(state(1, [{'number': 4, 'windows': {}}])), plain=0)
    reduce_case('rows: windows non-empty object', echo(state(1, [{'number': 4, 'windows': {'a': 1}}])), plain=1)
    reduce_case('rows: windows null', echo(state(1, [{'number': 4, 'windows': None}])), plain=1)
    reduce_case('rows: row without number', echo(state(1, [{'windows': []}])), plain=1)
    reduce_case('rows: row number a string', echo(state(1, [{'number': 'x', 'windows': []}])), plain=1)
    reduce_case('rows: row is not an object', echo(state(1, [5])), plain=1)
    reduce_case('rows: virtual_workspaces missing', echo(json.dumps({'active': {}})), plain=1)
    reduce_case('rows: virtual_workspaces null', echo(json.dumps({'active': {}, 'virtual_workspaces': None})), plain=1)
    reduce_case('rows: virtual_workspaces empty object', echo(json.dumps({'active': {}, 'virtual_workspaces': {}})), plain=0)
    reduce_case('rows: virtual_workspaces object', echo(json.dumps({'active': {}, 'virtual_workspaces': {'a': 1}})), plain=1)
    reduce_case('rows: virtual_workspaces empty string', echo(json.dumps({'active': {}, 'virtual_workspaces': ''})), plain=0)
    reduce_case('rows: first removed row is named', echo(state(1, [{'number': 3, 'windows': [{'floating': False}]}])), draft={'rowsEnabled': True, 'rowCount': 2}, plain=1)
    reduce_case('rows: rows turned off', echo(state(1, [{'number': 2, 'windows': [{}]}])), draft={'rowsEnabled': False}, plain=1)
    reduce_case('rows: off, row 1 only', echo(state(1, [{'number': 1, 'windows': [{}]}])), draft={'rowsEnabled': False}, plain=0)
    reduce_case('rows: not reduced (4 -> 4), engine never asked', 'exit 3', draft={'rowsEnabled': True, 'rowCount': 4}, plain=0)
    reduce_case('rows: increased, engine never asked', 'exit 3', draft={'rowsEnabled': True, 'rowCount': 6}, plain=0)
    reduce_case('rows: old rows off, engine never asked', 'exit 3', prefs=J({'rowsEnabled': False, 'rowCount': 8}), plain=0)
    reduce_case('rows: old prefs without rows keys', 'exit 3', prefs=J({'padding': 3}), draft={'rowsEnabled': False}, plain=0)
    reduce_case('rows: old rowsEnabled truthy string', echo(state(1)), prefs=J({'rowsEnabled': 'yes', 'rowCount': 5}), plain=0)
    reduce_case('rows: old rowsEnabled truthy but rowCount absent -> 2', 'exit 3', prefs=J({'rowsEnabled': 1}), draft={'rowsEnabled': False}, plain=1)
    reduce_case('rows: old rowCount a string', 'exit 3', prefs=J({'rowsEnabled': True, 'rowCount': '4'}), plain=1)
    reduce_case('rows: old rowCount null', 'exit 3', prefs=J({'rowsEnabled': True, 'rowCount': None}), plain=1)
    reduce_case('rows: old rowCount float', echo(state(1)), prefs=J({'rowsEnabled': True, 'rowCount': 4.5}), plain=0)
    reduce_case('rows: old rowCount true (counts as 1)', 'exit 3', prefs=J({'rowsEnabled': True, 'rowCount': True}), plain=0)
    reduce_case('rows: old rowCount huge', echo(state(1)), prefs=b'{"rowsEnabled": true, "rowCount": ' + b'9' * 30 + b'}', plain=0)
    reduce_case('rows: old rowCount NaN (never "reduced")', 'exit 3', prefs=b'{"rowsEnabled": true, "rowCount": NaN}', plain=1)
    reduce_case('rows: engine output has CRLF', "printf '%s\\r\\n' '" + state(1) + "'", plain=0)
    reduce_case('rows: engine fails and prints to stderr', "echo boom >&2; exit 1", plain=1)
    reduce_case('rows: engine output not utf-8', "printf '\\377'", plain=None)
    # -- timeouts after a successful save
    add('apply-float-rules hangs (note, saved)', {'floatingRules': [rule()]}, bridge='if [ "$1" = apply-float-rules ]; then exec sleep 30; fi; exit 0', plain=0)
    add('validate-rules hangs (nothing saved)', {'padding': 5}, bridge='if [ "$1" = validate-rules ]; then exec sleep 30; fi; exit 0', plain=1)
    return cases

PATHS_FUZZ = {
    'bool': ['dragReorder', 'focusFollowsMouse', 'mouseFollowsFocus', 'autoCenter', 'reverseSwipe', 'showOnHyper', 'floatPip', 'rowsEnabled', 'tabMatchAppColor'],
    'num': {'rowCount': (2, 9), 'sliverWidth': (0, 200), 'padding': (0, 100), 'windowGap': (0, 100), 'swipeSensitivity': (0.1, 2), 'swipeDeceleration': (1, 10),
            'swipeFingers': (3, 4), 'borderWidth': (0, 12), 'borderRadius': (0, 60), 'minimapDelay': (0.1, 10), 'minimapFade': (0, 3), 'hyperHoldDelay': (0.05, 2)},
    'enum': {'tabStyle': ['folder', 'folder-compact', 'classic', 'side'], 'minimapPosition': ['bottom', 'top', 'center', 'left', 'right'], 'minimapStyle': ['cards', 'compact', 'titles'],
             'scrollModifier': ['hyper', 'controlOption'], 'minimapHide': ['release', 'timer']},
}

def fuzz_cases(n, seed):
    rnd = random.Random(seed)
    alphabet = ['a', 'Z', ' ', '.', '*', '(', ')', '"', '\\', 'é', '日', '\U0001F41F', ' ', '/', '0', '-', ' ', '\x7f']
    def text(maxlen=12): return ''.join(rnd.choice(alphabet) for _ in range(rnd.randint(0, maxlen)))
    def number(lo, hi, valid, whole=False):
        r = rnd.random()
        if valid or r < 0.55:
            kind = rnd.choice(['int', 'int', 'edge'] if whole else ['int', 'float', 'round', 'edge', 'exp'])
            if kind == 'int': return rnd.randint(int(lo), int(hi))
            if kind == 'edge': return rnd.choice([lo, hi, float(lo), float(hi)])
            if kind == 'round': return round(rnd.uniform(lo, hi), rnd.randint(1, 3))
            if kind == 'exp': return float(f'{rnd.uniform(lo, hi):.{rnd.randint(1, 15)}e}')
            return rnd.uniform(lo, hi)
        return rnd.choice([lo - 1, hi + 1, lo - 0.001, hi + 0.001, hi * 10, -1, 0.5, 2.5, '5', None, True, [], 1e-9, 1e9, float(hi) + 1e-12])
    def chord():
        if rnd.random() < 0.8:   # mostly usable chords, so the saving path is exercised too
            mods = ['ctrl', 'alt', 'cmd'][:0] + rnd.sample(['ctrl', 'alt', 'cmd'], rnd.randint(1, 3)) + (['shift'] if rnd.random() < .4 else [])
            rnd.shuffle(mods)
            key = rnd.choice(['a', 'k', 'f5', 'space', 'leftarrow', 'z', 'Escape', '7', 'grave', 'f20'])
            return rnd.choice(['', ' ']) + rnd.choice([' + ', '+', ' +']).join(m.upper() if rnd.random() < .2 else m for m in mods) + ' - ' + key
        mods = rnd.sample(['ctrl', 'alt', 'cmd', 'shift'], rnd.randint(0, 4))
        key = rnd.choice(['a', 'k', 'f5', 'space', 'leftarrow', 'z', 'qq', 'f21', 'ESCAPE', ''])
        sep = rnd.choice([' - ', ' - ', ' - ', '-', ' -  '])
        return rnd.choice([' ', '', '']) + rnd.choice(['+', ' + ', ' +']).join(m.upper() if rnd.random() < .2 else m for m in mods) + sep + key
    cases = []
    for i in range(n):
        d = {}
        broken = rnd.random() < 0.2
        for k in PATHS_FUZZ['bool']:
            if rnd.random() < 0.3: d[k] = rnd.choice([True, False]) if not (broken and rnd.random() < .05) else rnd.choice([1, 'x', None])
        for k, (lo, hi) in PATHS_FUZZ['num'].items():
            if rnd.random() < 0.4: d[k] = number(lo, hi, not broken or rnd.random() < .9, whole=k in ('rowCount', 'sliverWidth', 'padding', 'windowGap', 'swipeFingers'))
        for k, vals in PATHS_FUZZ['enum'].items():
            if rnd.random() < 0.25: d[k] = rnd.choice(vals) if not (broken and rnd.random() < .1) else rnd.choice(['x', 4, None])
        if rnd.random() < 0.3: d['tabHeight'] = rnd.choice([28, 34, '28', '34', 30, 28.0])
        if rnd.random() < 0.3: d['borderColor'] = rnd.choice(['#%06x' % rnd.randrange(1 << 24), '#%06X' % rnd.randrange(1 << 24), '#12345g', 'red'])
        if rnd.random() < 0.4:
            d['floatingRules'] = [dict(id=text(5), bundle=rnd.choice(['', 'com.a.b', text(6)]), titlePattern=text(10) or ('x' if rnd.random() < .9 else ''), enabled=rnd.random() < .7) for _ in range(rnd.randint(0, 5))]
        if rnd.random() < 0.4: d['tabAliases'] = {text(8) or 'k': text(10) for _ in range(rnd.randint(0, 6))}
        if rnd.random() < 0.4: d['shortcuts'] = {rnd.choice(CATALOG_IDS): chord() for _ in range(rnd.randint(1, 3))}
        if rnd.random() < 0.05: d['mystery'] = 1
        items = list(d.items()); rnd.shuffle(items)
        kw = {}
        if rnd.random() < 0.3:
            kw['prefs'] = J({'rowsEnabled': rnd.random() < .8, 'rowCount': rnd.randint(2, 9)})
            vws = [{'number': n_, 'windows': [{'floating': rnd.random() < .5} for _ in range(rnd.randint(0, 2))]} for n_ in range(1, rnd.randint(1, 9))]
            kw['engine'] = "echo '" + json.dumps({'active': {'virtual_workspace_number': rnd.randint(1, 9)}, 'virtual_workspaces': vws}) + "'"
        if rnd.random() < 0.1: kw['bridge'] = rnd.choice(["if [ \"$1\" = validate-rules ]; then echo 'nope' >&2; exit 1; fi", 'exit 5'])
        cases.append(dict(name=f'fuzz seed {seed} #{i}', draft=json.dumps(dict(items), allow_nan=True, ensure_ascii=rnd.random() < .5).encode(), **kw))
    return cases

# ---------------------------------------------------------------------------------------- defaults

def check_defaults(scratch, cases_run):
    """The product defaults shipped in Resources/Defaults are what the script produces from an empty draft,
    and the Swift port reproduces them from an empty draft."""
    problems = []
    d = scratch / 'defaults'
    for kind in ['py', 'sw']:
        fx = Fixture(kind, d / kind, dict(draft=b'{}', init=THIN_INIT))
        code, out, err = fx.run()
        if code != 0: problems.append(f'{kind}: empty draft failed: {out}{err}')
        for name in ['preferences.json', 'settings.lua', 'shortcuts.lua']:
            shipped = APP / 'Resources/Defaults' / name
            made = fx.config / name
            if WRITE_DEFAULTS and kind == 'py' and made.exists():
                shipped.parent.mkdir(exist_ok=True); shutil.copy(made, shipped); shipped.chmod(0o644)
            if not shipped.exists(): problems.append(f'Resources/Defaults/{name} is missing')
            elif not made.exists() or shipped.read_bytes() != made.read_bytes():
                problems.append(f'Resources/Defaults/{name} differs from what {"the reference script" if kind == "py" else "the Swift port"} writes for an empty draft')
    return problems

# ---------------------------------------------------------------------------------------- extras

def check_float_repr(count=200000, seed=7):
    """Swift's float printing against Python's repr over random doubles (random bit patterns, plus the
    decimal-looking values Settings writes)."""
    import struct
    rnd = random.Random(seed)
    values = []
    for _ in range(count // 4): values.append(struct.unpack('<d', struct.pack('<Q', rnd.getrandbits(64)))[0])
    for _ in range(count // 4): values.append(rnd.uniform(0, 12))
    for _ in range(count // 4): values.append(round(rnd.uniform(0, 3), rnd.randint(1, 6)))
    for _ in range(count // 4): values.append(float(f'{rnd.uniform(0.0, 10):.{rnd.randint(1, 16)}e}') * 10.0 ** rnd.randint(-12, 12))
    values += [0.0, -0.0, 1e-05, 0.0001, 0.001, 1e16, 9999999999999998.0, 1e15, 123456789012345678.0, 5e-324, 1.7976931348623157e308, 0.1, 0.2, 0.3, 100.0, 1e22, 1e21, 2.5e-5]
    values = [v for v in values if v == v and abs(v) != float('inf')]
    feed = '\n'.join(format(struct.unpack('<Q', struct.pack('<d', v))[0], 'x') for v in values) + '\n'
    out = subprocess.run([str(SWIFT_BIN), '--float-repr'], input=feed, capture_output=True, text=True).stdout.split('\n')[:-1]
    bad = [(repr(v), o) for v, o in zip(values, out) if repr(v) != o]
    return len(values), bad[:5], len(out) == len(values)

def check_environment_and_lock(scratch):
    """Swift-only behaviour that has no Python counterpart: the bridge is reached through this install's
    Mach service, and two Applies take turns."""
    problems = []
    # 1. PANERU_MACH_SERVICE for the bridge and the engine query
    case = dict(draft=b'{"rowsEnabled": true, "rowCount": 2}', prefs=J({'rowsEnabled': True, 'rowCount': 4}),
                bridge='echo "bridge:$PANERU_MACH_SERVICE" >> "$(dirname "$0")/env.log"',
                engine='echo "engine:$PANERU_MACH_SERVICE" >> "$(dirname "$0")/env.log"; echo \'{"active": {}, "virtual_workspaces": []}\'')
    fx = Fixture('sw', scratch / 'extras/env', case)
    code, out, err = fx.run()
    seen = (fx.base / 'bin/env.log').read_text().split() if (fx.base / 'bin/env.log').exists() else []
    want = ['engine:net.webreceptor.microfish.engine'] + ['bridge:net.webreceptor.microfish.engine'] * 2
    if code != 0 or seen != want: problems.append(f'Mach service environment: exit {code}, saw {seen}')
    # 2. exclusive lock
    case = dict(draft=b'{"padding": 5}', bridge='if [ "$1" = validate-rules ]; then echo "start $$" >> "$(dirname "$0")/order.log"; sleep 1; echo "end $$" >> "$(dirname "$0")/order.log"; fi; exit 0')
    fx = Fixture('sw', scratch / 'extras/lock', case)
    env = dict(os.environ, MICROFISH_SUPPORT_DIR=str(fx.config), MICROFISH_RESOURCES=str(fx.res), MICROFISH_BRIDGE=str(fx.bridge), MICROFISH_ENGINE=str(fx.engine), MICROFISH_LOG_DIR=str(fx.logs))
    procs = [subprocess.Popen([str(SWIFT_BIN), str(fx.draft)], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) for _ in range(3)]
    codes = [p.wait(timeout=60) for p in procs]
    order = [l.split()[0] for l in (fx.base / 'bin/order.log').read_text().splitlines()]
    if codes != [0, 0, 0] or order != ['start', 'end'] * 3: problems.append(f'lock: exits {codes}, order {order}')
    backups = list((fx.config / 'Backups/Settings').iterdir())
    if len(backups) != 3: problems.append(f'lock: expected 3 backups, found {len(backups)}')
    return problems

# ---------------------------------------------------------------------------------------- main

def main():
    global REFERENCE, SWIFT_BIN, WRITE_DEFAULTS
    ap = argparse.ArgumentParser()
    ap.add_argument('--reference', default=str(DEFAULT_REFERENCE))
    ap.add_argument('--scratch')
    ap.add_argument('--fuzz', type=int, default=400)
    ap.add_argument('--seed', type=int, default=20261028)
    ap.add_argument('--keep', action='store_true')
    ap.add_argument('--jobs', type=int, default=8)
    ap.add_argument('-k', dest='only')
    ap.add_argument('--skip-build', action='store_true')
    ap.add_argument('--write-defaults', action='store_true', help='regenerate Resources/Defaults from the reference script (empty draft)')
    a = ap.parse_args()
    WRITE_DEFAULTS = a.write_defaults
    REFERENCE = Path(a.reference).resolve()
    if not REFERENCE.exists(): sys.exit(f'reference script not found: {REFERENCE}')
    scratch = Path(a.scratch or tempfile.mkdtemp(prefix='settings-apply-test-')).resolve()
    scratch.mkdir(parents=True, exist_ok=True)
    SWIFT_BIN = scratch / 'settings-apply-cli'
    if not a.skip_build:
        cmd = ['swiftc', '-suppress-warnings', str(APP / 'Sources/Paths.swift'), str(APP / 'Sources/SettingsApply.swift'), str(HERE / 'main.swift'), '-o', str(SWIFT_BIN)]
        b = subprocess.run(cmd, capture_output=True, text=True)
        if b.returncode: sys.exit('swiftc failed:\n' + b.stderr)
    cases = corpus() + fuzz_cases(a.fuzz, a.seed)
    for i, c in enumerate(cases): c['id'] = f'{i:04d}'
    if a.only: cases = [c for c in cases if a.only in c['name']]
    failed, tally = [], {}
    with concurrent.futures.ThreadPoolExecutor(a.jobs) as pool:
        for cid, name, problems, secs, sw_result in pool.map(lambda c: compare_case(c, scratch / 'cases'), cases):
            kind = 'saved' if sw_result[0] == 0 else 'rejected'
            tally[kind] = tally.get(kind, 0) + 1
            if problems:
                failed.append((cid, name, problems))
                print(f'FAIL {cid} {name}')
                for p in problems: print('     ' + p.replace('\n', '\n     '))
            elif secs > 4: print(f'ok   {cid} {name} ({secs}s)')
    default_problems = [] if (a.only and not WRITE_DEFAULTS) else check_defaults(scratch, cases)
    for p in default_problems: print('FAIL defaults: ' + p)
    extra = [] if a.only else check_environment_and_lock(scratch)
    for p in extra: print('FAIL extras: ' + p)
    if not a.only and not extra: print('extras: Mach service environment reaches bridge and engine; three concurrent Applies run one at a time and leave three backups')
    if not a.only:
        n, bad, aligned = check_float_repr()
        print(f'float repr: {n} doubles compared with Python repr, {len(bad)} different' + ('' if aligned else ' (output misaligned)'))
        for b_ in bad: print('FAIL float repr: python', b_[0], 'swift', b_[1])
        if bad or not aligned: extra.append('float repr')
    default_problems += extra
    total = len(cases)
    print(f'\nresults seen: {tally}')
    print(f'differential cases: {total}, identical: {total - len(failed)}, different: {len(failed)}; defaults check: {"ok" if not default_problems and not a.only else ("skipped" if a.only else "FAILED")}')
    if not a.keep and not failed and not default_problems: shutil.rmtree(scratch, ignore_errors=True)
    else: print(f'scratch kept at {scratch}')
    sys.exit(1 if failed or default_problems else 0)

if __name__ == '__main__':
    main()
