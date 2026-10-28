#!/usr/bin/python3
"""Every message apply-settings.py can print to the Settings footer is plain language, and the exit-code
contract holds. Runs against a temporary root only (never the real config/). Usage: apply-settings-messages.py [wt]"""
import json, os, re, shutil, stat, subprocess, sys, tempfile
from pathlib import Path

wt = Path(sys.argv[1] if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent).resolve()
BANNED = re.compile(r"manager|engine|lua|paneru|traceback|exception|keyerror|\.json|/Users|exit(ed)? |_|Command '", re.I)
fails = []

def make(bridge_script='exit 0', engine_script='echo "{}"', rows=None):
    root = Path(tempfile.mkdtemp(prefix='apply-msgs-'))
    for d in ['scripts', 'config', 'bin', 'work']: (root / d).mkdir()
    shutil.copy(wt / 'scripts/apply-settings.py', root / 'scripts/apply-settings.py')
    shutil.copy(wt / 'config/shortcut-defaults.json', root / 'config/shortcut-defaults.json')
    shutil.copy(wt / 'config/init.lua', root / 'config/init.lua')
    for name, body in [('PaneruNavigatorCommand', bridge_script), ('fake-engine', engine_script)]:
        f = root / 'bin' / name; f.write_text('#!/bin/sh\n' + body + '\n'); f.chmod(0o755)
    import plistlib
    (root / 'config/trial.plist').write_bytes(plistlib.dumps({'ProgramArguments': [str(root / 'bin/fake-engine')]}))
    return root

def run(root, draft):
    d = root / 'draft.json'; d.write_text(json.dumps(draft))
    p = subprocess.run(['/usr/bin/python3', str(root / 'scripts/apply-settings.py'), str(d)], capture_output=True, text=True, timeout=60)
    return p.returncode, (p.stdout + p.stderr).strip()

def expect(name, ok, detail=''):
    print(('PASS  ' if ok else 'FAIL  ') + name + ('' if ok else '  -> ' + detail))
    if not ok: fails.append(name)

def plain(name, code, text, want_code):
    expect(name + ': exit code', code == want_code, f'{code} {text!r}')
    expect(name + ': plain language', not BANNED.search(text) and text.isprintable() and len(text) < 160 and text.endswith('.'), repr(text))

root = make(); code, out = run(root, {}); plain('success', code, out, 0)
expect('success keeps no raw detail', 'bridge' not in out.lower())
for name, draft in [
    ('unknown key', {'futureKey': 1}),
    ('bad range', {'padding': 500}),
    ('bad bool', {'autoCenter': 'yes'}),
    ('bad whole number', {'padding': 3.5}),
    ('bad enum', {'tabStyle': 'wavy'}),
    ('bad color', {'borderColor': 'teal'}),
    ('bad shortcut', {'shortcuts': {'center': 'banana'}}),
    ('shortcut conflict', {'shortcuts': {'center': 'alt + ctrl + cmd - space'}}),
    ('unknown shortcut', {'shortcuts': {'nope': 'ctrl - a'}}),
    ('empty rule', {'floatingRules': [{'id': 'a', 'bundle': '', 'titlePattern': ''}]}),
    ('not an object', [1]),
]:
    code, out = run(make(), draft); plain(name, code, out, 1)
code, out = run(make(), {'shortcuts': {'center': 'alt + ctrl + cmd - space'}})
expect('conflict message names both actions and says conflict', 'conflict' in out and '“Center window”' in out and '“Float or tile”' in out, out)
code, out = run(make(), {'shortcuts': {'center': 'banana'}}); expect('chord message says shortcut', 'shortcut' in out.lower(), out)

# bridge rejects a rule: a long raw regex dump must not reach the footer
raw = "regex parse error:\n    (\n    ^\nerror: unclosed group at /Users/x/src/lib.rs:12"
code, out = run(make(bridge_script=f"if [ \"$1\" = validate-rules ]; then echo '{raw}' >&2; exit 1; fi; exit 0"), {})
plain('bridge rejection, raw dump', code, out, 1)
code, out = run(make(bridge_script="if [ \"$1\" = validate-rules ]; then echo 'bad rule: unmatched paren in test' >&2; exit 1; fi; exit 0"), {})
expect('bridge rejection, short plain line is kept', code == 1 and 'bad rule' in out, out)
# floating step fails after the save: still exit 0, Settings looks for "could not be applied"
code, out = run(make(bridge_script="if [ \"$1\" = apply-float-rules ]; then echo 'Command failed at /Users/x' >&2; exit 1; fi; exit 0"), {})
expect('float failure: exit 0 and contract phrase', code == 0 and 'could not be applied' in out and not BANNED.search(out), f'{code} {out!r}')
# floating step hangs after the save: a note, not a failure (exit 0, same contract phrase)
code, out = run(make(bridge_script="if [ \"$1\" = apply-float-rules ]; then exec sleep 30; fi; exit 0"), {})
expect('float timeout: exit 0 and contract phrase', code == 0 and 'could not be applied' in out and not BANNED.search(out), f'{code} {out!r}')
# the bridge hangs before anything is saved: the shared "isn't responding" wording
code, out = run(make(bridge_script="if [ \"$1\" = validate-rules ]; then exec sleep 30; fi; exit 0"), {})
plain('bridge hangs (timeout)', code, out, 1); expect('timeout says Microfish isn’t responding', out == 'Microfish isn’t responding. Try again.', out)

# row reduction: engine not answering / crashing / odd output / rows occupied
def reduce_root(engine):
    r = make(engine_script=engine)
    (r / 'config/preferences.json').write_text(json.dumps({'rowsEnabled': True, 'rowCount': 4}))
    return r
draft = {'rowsEnabled': True, 'rowCount': 2}
code, out = run(reduce_root('exit 3'), draft); plain('rows: engine not answering', code, out, 1)
code, out = run(reduce_root('echo "not json"'), draft); plain('rows: unreadable engine reply', code, out, 1)
code, out = run(reduce_root('echo "{}"'), draft); plain('rows: missing fields (KeyError)', code, out, 1)
code, out = run(reduce_root('sleep 30'), draft); plain('rows: engine hangs (timeout)', code, out, 1)
state = {'active': {'virtual_workspace_number': 3}, 'virtual_workspaces': []}
code, out = run(reduce_root(f"echo '{json.dumps(state)}'"), draft); plain('rows: on a row that will go', code, out, 1)
state = {'active': {'virtual_workspace_number': 1}, 'virtual_workspaces': [{'number': 3, 'windows': [{'floating': False}]}]}
code, out = run(reduce_root(f"echo '{json.dumps(state)}'"), draft)
plain('rows: windows in higher rows', code, out, 1); expect('names the first removed row', 'rows 3 and above' in out, out)
sys.exit(1 if fails else 0)
