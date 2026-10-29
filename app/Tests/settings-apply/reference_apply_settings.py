#!/usr/bin/python3
# The original Python Settings backend (apply-settings.py), kept unchanged as the oracle for the
# differential test in run.py. The app no longer runs it; SettingsApply.swift replaced it.
"""Validate and apply native settings without executing user-provided code."""
import contextlib
import fcntl
import json
import math
import os
import plistlib
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
CATALOG = json.loads((ROOT/'config/shortcut-defaults.json').read_text())
SHORTCUT_DEFAULTS = {a['id']:a['default'] for a in CATALOG}
LABELS = {a['id']:re.sub(r'\s*\([^)]*\)','',a['label']) for a in CATALOG}
def label(action): return '“'+LABELS.get(action,'a shortcut')+'”'
DEFAULTS = dict(dragReorder=False, focusFollowsMouse=False, mouseFollowsFocus=False, autoCenter=False,
 sliverWidth=20, padding=4, windowGap=4, swipeSensitivity=0.35, swipeDeceleration=6.0,
 swipeFingers=3, reverseSwipe=False, scrollModifier='hyper', borderColor='#009193', borderWidth=2.0,
 borderRadius=14.0, minimapPosition='bottom', minimapStyle='cards', minimapDelay=1.3,
 minimapFade=0.22, showOnHyper=True, hyperHoldDelay=0.2, floatPip=True,
 tabStyle='folder',tabHeight=34,tabMatchAppColor=False,
 floatingRules=[], tabAliases={}, rowsEnabled=False, rowCount=2, shortcuts=SHORTCUT_DEFAULTS)
RANGES = dict(rowCount=(2,9),sliverWidth=(0,200),padding=(0,100),windowGap=(0,100),swipeSensitivity=(0.1,2),
 swipeDeceleration=(1,10),swipeFingers=(3,4),borderWidth=(0,12),borderRadius=(0,60),
 minimapDelay=(0.1,10),minimapFade=(0,3),hyperHoldDelay=(0.05,2))
BOOLS = ['dragReorder','focusFollowsMouse','mouseFollowsFocus','autoCenter','reverseSwipe','showOnHyper','floatPip','rowsEnabled','tabMatchAppColor']
ENUMS = dict(tabStyle=['folder','folder-compact','classic','side'],minimapPosition=['bottom','top','center','left','right'],minimapStyle=['cards','compact','titles'],scrollModifier=['hyper','controlOption'])
# Every message below can end up in the Settings footer ("Couldn’t apply · <message>"), so each one is a
# plain sentence that names the setting the way the Settings window does. Detail for support goes to
# work/settings-apply.log. Settings parses this script's exit code (0 = saved, anything else = failed,
# message on stderr) and looks for "could not be applied" in the success line: keep both.
NAMES = dict(rowCount='Number of rows',sliverWidth='Edge sliver',padding='Outer padding',windowGap='Window padding',
 swipeSensitivity='Swipe sensitivity',swipeDeceleration='Swipe deceleration',swipeFingers='Swipe fingers',
 borderWidth='Outline width',borderRadius='Corner radius',minimapDelay='Hide after',minimapFade='Fade out',
 hyperHoldDelay='Hold Hyper for',dragReorder='Drag to reorder',focusFollowsMouse='Focus follows pointer',
 mouseFollowsFocus='Move pointer to focused window',autoCenter='Auto-center',reverseSwipe='Reverse swipe',
 showOnHyper='Show Minimap with Hyper',floatPip='Float Picture in Picture',rowsEnabled='Rows',
 tabMatchAppColor='Match app color',tabStyle='Tab style',minimapPosition='Minimap position',
 minimapStyle='Minimap layout',scrollModifier='Scroll modifier',minimapHide='Hide Minimap')
def name(key): return NAMES.get(key,'That setting')
PIP_PATTERN = r'(?i)^(picture[ -]in[ -]picture|pip)$'
# Navigator-only keys: validated when present, never added when absent, so a saved file keeps
# meaning "use the helper's default" until the user actually picks a value.
OPTIONAL_ENUMS = dict(minimapHide=['release','timer'])

def normalize(raw):
 if not isinstance(raw,dict): raise ValueError('Microfish couldn’t read these settings, so nothing was changed.')
 unknown=set(raw)-set(DEFAULTS)-set(OPTIONAL_ENUMS)
 if unknown: raise ValueError('These settings include options this version of Microfish doesn’t know, so nothing was changed.')
 out=dict(DEFAULTS);out.update(raw)
 if str(out['tabHeight']) not in ['28','34']: raise ValueError('Tab height must be 28 or 34 points.')
 out['tabHeight']=int(out['tabHeight'])
 for key in BOOLS:
  if type(out[key]) is not bool: raise ValueError(name(key)+' must be on or off.')
 for key,(lo,hi) in RANGES.items():
  v=out[key]
  if type(v) not in (int,float) or not math.isfinite(v) or not lo<=v<=hi: raise ValueError(f'{name(key)} must be a number from {lo} to {hi}.')
 for key in ['sliverWidth','padding','windowGap','swipeFingers','rowCount']:
  if out[key]!=int(out[key]): raise ValueError(name(key)+' must be a whole number.')
  out[key]=int(out[key])
 for key,values in ENUMS.items():
  if out[key] not in values: raise ValueError(name(key)+' has a value Microfish doesn’t support.')
 for key,values in OPTIONAL_ENUMS.items():
  if key in out and out[key] not in values: raise ValueError(name(key)+' has a value Microfish doesn’t support.')
 if not isinstance(out['borderColor'],str) or not re.fullmatch(r'#[0-9a-fA-F]{6}',out['borderColor']): raise ValueError('Outline color needs six hex digits, like #009193.')
 if not isinstance(out['floatingRules'],list) or len(out['floatingRules'])>200: raise ValueError('Microfish supports at most 200 floating rules.')
 rules=[]
 for rule in out['floatingRules']:
  if not isinstance(rule,dict): raise ValueError('One of the floating rules isn’t valid.')
  r={k:rule.get(k,default) for k,default in [('id',''),('bundle',''),('titlePattern',''),('enabled',True)]}
  if any(not isinstance(r[k],str) or len(r[k])>4096 for k in ['id','bundle','titlePattern']) or type(r['enabled']) is not bool: raise ValueError('One of the floating rules isn’t valid.')
  if not r['titlePattern']: raise ValueError('A floating rule needs a title pattern. Use .* to match every title.')
  rules.append(r)
 out['floatingRules']=rules
 aliases=out['tabAliases']
 if not isinstance(aliases,dict) or len(aliases)>500: raise ValueError('Microfish supports at most 500 tab names.')
 if any(not isinstance(k,str) or not isinstance(v,str) or len(k)>8192 or len(v)>200 or any(c in v for c in '\r\n\t') for k,v in aliases.items()): raise ValueError('Tab names must be one line and at most 200 characters.')
 shortcuts=out['shortcuts']
 if not isinstance(shortcuts,dict) or set(shortcuts)-set(SHORTCUT_DEFAULTS):raise ValueError('A shortcut in these settings isn’t one Microfish knows, so nothing was changed.')
 merged=dict(SHORTCUT_DEFAULTS);merged.update(shortcuts)
 seen={}
 for action,chord in merged.items():
  chord=normalize_chord(chord);merged[action]=chord
  if chord and chord in seen:raise ValueError('Two shortcuts conflict: '+label(seen[chord])+' and '+label(action)+' use the same keys. Choose different keys.')
  if chord:seen[chord]=action
 out['shortcuts']=merged
 return out


KEYS=set('abcdefghijklmnopqrstuvwxyz0123456789') | set('leftarrow rightarrow uparrow downarrow leftbracket rightbracket backslash equal minus space return tab escape delete forwarddelete home end pageup pagedown semicolon quote comma period slash grave'.split()) | {'f'+str(i) for i in range(1,21)}
def normalize_chord(chord):
 if not isinstance(chord,str):raise ValueError('A shortcut isn’t valid, so nothing was changed.')
 if not chord.strip():return ''
 parts=chord.lower().strip().split(' - ')
 if len(parts)!=2:raise ValueError('A shortcut needs at least one modifier key and one other key.')
 mods=[x.strip() for x in parts[0].split('+')];key=parts[1].strip()
 if len(set(mods))!=len(mods) or not set(mods)<=set(['ctrl','alt','cmd','shift']) or not set(mods)&set(['ctrl','alt','cmd']) or key not in KEYS:raise ValueError('A shortcut uses keys Microfish can’t use. Choose different keys.')
 return ' + '.join(m for m in ['ctrl','alt','cmd','shift'] if m in mods)+' - '+key

def shortcut_setup(p):
 return dict(rows_enabled=p['rowsEnabled'],row_count=p['rowCount'],bindings=[dict(id=a['id'],chord=p['shortcuts'][a['id']],command=a['command']) for a in CATALOG])

def log(text):
 try:
  with (ROOT/'work/settings-apply.log').open('a',encoding='utf-8') as f:f.write(time.strftime('%Y-%m-%d %H:%M:%S ')+text.strip()+'\n')
 except OSError:pass

def validate_row_reduction(p):
 oldpath=ROOT/'config/preferences.json'
 if not oldpath.exists():return
 old=json.loads(oldpath.read_text());oldlimit=old.get('rowCount',2) if old.get('rowsEnabled',False) else 1
 newlimit=p['rowCount'] if p['rowsEnabled'] else 1
 if newlimit>=oldlimit:return
 plist=plistlib.loads((ROOT/'config/trial.plist').read_bytes());engine=plist['ProgramArguments'][0]
 try:result=subprocess.run([engine,'query','state','--json'],capture_output=True,text=True,timeout=5)
 except (subprocess.TimeoutExpired,OSError) as error:log('row check: '+repr(error));result=None
 if result is None or result.returncode:
  if result:log('row check: '+(result.stderr or result.stdout))
  raise ValueError('Microfish isn’t responding, so rows can’t be reduced yet. Open Microfish and try again.')
 state=json.loads(result.stdout)
 if state['active'].get('virtual_workspace_number',1)>newlimit:raise ValueError('Switch to a row that will remain before reducing rows.')
 for row in state['virtual_workspaces']:
  if row['number']>newlimit and any(not w.get('floating',False) for w in row['windows']):raise ValueError(f'Move windows out of rows {newlimit+1} and above before reducing rows.')

def effective_rules(p):
 rules=[r for r in p['floatingRules'] if r['enabled']]
 if p['floatPip']: rules=[dict(id='automatic-pip',bundle='',titlePattern=PIP_PATTERN,enabled=True)]+rules
 return rules

def setup(p):
 windows={'spacing':dict(title='.*',horizontal_padding=p['windowGap'],vertical_padding=p['windowGap']), 'settings_panel':dict(title='^Paneru Settings$',floating=True)}
 for i,r in enumerate(effective_rules(p)):
  windows[f'float_{i:03}']=dict(title=r['titlePattern'],floating=True)
  if r['bundle']: windows[f'float_{i:03}']['bundle_id']=r['bundle']
 return dict(default_workspaces=1,options=dict(drag_reorder=p['dragReorder'],create_virtual_workspace_automatically=False,reap_empty_workspaces=True,focus_follows_mouse=p['focusFollowsMouse'],mouse_follows_focus=p['mouseFollowsFocus'],preset_column_widths=[.33,.5,.66,1.0],animation_speed=1000000.0,sliver_width=p['sliverWidth'],auto_center=p['autoCenter'],disable_native_tabs=False,tab_style=p['tabStyle'],tab_height=p['tabHeight']),
  padding={k:p['padding'] for k in ['left','right','top','bottom']},
  swipe=dict(continuous=False,sensitivity=p['swipeSensitivity'],deceleration=p['swipeDeceleration'],gesture=dict(fingers_count=p['swipeFingers'],direction='Reversed' if p['reverseSwipe'] else 'Natural',vertical=False),scroll=dict(modifier='ctrl + alt + cmd' if p['scrollModifier']=='hyper' else 'ctrl + alt',window_step=False)),
  decorations=dict(workspace_popup_status=False,workspace_menu_status=False,menu=dict(descriptor=dict(style='hidden')),active=dict(border=dict(enabled=p['borderWidth']>0,color=p['borderColor'],width=p['borderWidth'],radius=p['borderRadius']))),restore=dict(enabled=True),windows=windows)

def lua(v):
 if v is True:return 'true'
 if v is False:return 'false'
 if isinstance(v,(int,float)):return repr(v)
 if isinstance(v,str):
  # Decimal byte escapes avoid Lua quoting, newline and Unicode escape ambiguity.
  return '"'+''.join(chr(b) if 32<=b<127 and b not in (34,92) else '\\%03d'%b for b in v.encode('utf-8'))+'"'
 if isinstance(v,list):return '{'+','.join(lua(x) for x in v)+'}'
 if isinstance(v,dict):return '{'+','.join('['+lua(k)+']='+lua(x) for k,x in v.items())+'}'
 raise ValueError('Microfish couldn’t save these settings.')

def atomic(path,data):
 path.parent.mkdir(parents=True,exist_ok=True)
 fd,name=tempfile.mkstemp(prefix='.'+path.name,dir=path.parent)
 try:
  with os.fdopen(fd,'w',encoding='utf-8') as f:f.write(data);f.flush();os.fsync(f.fileno())
  os.replace(name,path)
 finally:
  if os.path.exists(name):os.unlink(name)

def apply(path):
 prefs=normalize(json.loads(Path(path).read_text()))
 validate_row_reduction(prefs)
 bridge=ROOT/'bin/PaneruNavigatorCommand'
 with tempfile.TemporaryDirectory(prefix='settings-',dir=ROOT/'work') as tmp:
  rules=Path(tmp)/'rules.json';rules.write_text(json.dumps([{k:r[k] for k in ['bundle','titlePattern','enabled']} for r in effective_rules(prefs)]))
  result=subprocess.run([str(bridge),'validate-rules',str(rules)],capture_output=True,text=True,timeout=10)
  if result.returncode:
   detail=(result.stderr.strip() or result.stdout.strip()).splitlines()
   log('validate-rules: '+' / '.join(detail))
   # Show the bridge's words only when it said one short plain line (it names the bad rule); anything longer is log-only.
   first=detail[0].strip() if len(detail)==1 else ''
   if first and len(first)<=80 and not first.endswith(':') and not re.search(r'[/\\]|0x|\bat \w',first):raise ValueError('A floating rule isn’t valid: '+first)
   raise ValueError('A floating rule isn’t valid, so nothing was saved.')
  backup=ROOT/'work/settings-backups'/str(time.time_ns());backup.mkdir(parents=True)
  for name in ['preferences.json','settings.lua','shortcuts.lua','init.lua']:
   p=ROOT/'config'/name
   if p.exists():(backup/name).write_bytes(p.read_bytes())
  atomic(ROOT/'config/settings.lua','-- Generated by the settings panel.\nreturn '+lua(setup(prefs))+'\n')
  atomic(ROOT/'config/shortcuts.lua','-- Generated shortcuts.\nreturn '+lua(shortcut_setup(prefs))+'\n')
  atomic(ROOT/'config/preferences.json',json.dumps(prefs,ensure_ascii=False,indent=2)+'\n')
  init=ROOT/'config/init.lua'
  text=re.sub(r'\n-- settings revision \d+\n?$', '\n',init.read_text())
  atomic(init,text.rstrip()+'\n-- settings revision '+str(time.time_ns())+'\n')
  # Match current windows as well as future spawn-time rules. Never unfloat on removal.
  # The settings are saved by now: a slow answer here is a note, not a failure.
  try:result=subprocess.run([str(bridge),'apply-float-rules',str(rules)],capture_output=True,text=True,timeout=10)
  except subprocess.TimeoutExpired as error:
   log('apply-float-rules timeout: '+repr(error))
   print('Saved. Floating could not be applied to the windows that are open now; new windows follow the rules.');return
  if result.returncode:
   log('apply-float-rules: '+(result.stderr.strip() or result.stdout.strip()))
   print('Saved. Floating could not be applied to the windows that are open now; new windows follow the rules.')
  else:print('Saved. Microfish will pick up the changes.')

if __name__=='__main__':
 try:
  if len(sys.argv)!=2:raise ValueError('Microfish couldn’t save these settings.')
  with (ROOT/'work/settings.lock').open('w') as lock:
   fcntl.flock(lock,fcntl.LOCK_EX)
   apply(sys.argv[1])
 except json.JSONDecodeError as error:
  log('unreadable JSON: '+repr(error));print('Microfish couldn’t save these settings.',file=sys.stderr);sys.exit(1)
 except ValueError as error:
  print(str(error),file=sys.stderr);sys.exit(1)
 except subprocess.TimeoutExpired as error:
  log('timeout: '+repr(error));print('Microfish isn’t responding. Try again.',file=sys.stderr);sys.exit(1)
 except Exception as error:
  # Anything unexpected (bad JSON, missing file, odd engine output): the detail goes to the log, not the footer.
  log('unexpected: '+repr(error));print('Microfish couldn’t save these settings.',file=sys.stderr);sys.exit(1)
