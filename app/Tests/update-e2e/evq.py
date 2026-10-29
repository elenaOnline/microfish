#!/usr/bin/env python3 -I
"""Query the probe's events.jsonl for run.sh.
  evq.py wait FILE TIMEOUT [k=v | k!=v ...]   print the first matching event (JSON), exit 1 on timeout
  evq.py has  FILE [k=v ...]                  exit 0 if an event matches
  evq.py get  FILE FIELD [k=v ...]            print FIELD of the first matching event
  evq.py list FILE                            one readable line per event
Values compare as strings; `k!=v` negates; a bare `k=` matches a missing/empty field."""
import json, sys, time

def load(path):
    out = []
    try:
        for line in open(path):
            line = line.strip()
            if line:
                try: out.append(json.loads(line))
                except ValueError: pass
    except FileNotFoundError:
        pass
    return out

def match(ev, conds):
    for c in conds:
        if "!=" in c:
            k, v = c.split("!=", 1)
            if str(ev.get(k, "")) == v: return False
        else:
            k, v = c.split("=", 1)
            if str(ev.get(k, "")) != v: return False
    return True

def first(path, conds):
    for ev in load(path):
        if match(ev, conds): return ev
    return None

cmd = sys.argv[1]
if cmd == "wait":
    path, timeout, conds = sys.argv[2], float(sys.argv[3]), sys.argv[4:]
    end = time.time() + timeout
    while time.time() < end:
        ev = first(path, conds)
        if ev: print(json.dumps(ev, sort_keys=True)); sys.exit(0)
        time.sleep(0.1)
    sys.exit(1)
elif cmd == "has":
    sys.exit(0 if first(sys.argv[2], sys.argv[3:]) else 1)
elif cmd == "get":
    ev = first(sys.argv[2], sys.argv[4:])
    if not ev: sys.exit(1)
    print(ev.get(sys.argv[3], "")); sys.exit(0)
elif cmd == "list":
    evs = load(sys.argv[2]); t0 = evs[0]["t"] if evs else 0
    for e in evs:
        extra = {k: v for k, v in e.items() if k not in ("t", "pid", "version", "build", "event")}
        print("+%7.3fs pid=%-6s v%-14s %-22s %s" % (e["t"] - t0, e["pid"], e["version"], e["event"], json.dumps(extra, sort_keys=True) if extra else ""))
