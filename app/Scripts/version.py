#!/usr/bin/env python3
"""Release tag -> version fields. The one place the numbering rules live.

    version.py v1.2.3            stable
    version.py v1.2.3-beta.4     beta (N is 1-98)
    version.py dev               unreleased local build (build number 1)

Rules (see RELEASING.md):
  * short   = the tag without the leading "v" (CFBundleShortVersionString, zip name, appcast)
  * build   = X*1000000 + Y*10000 + Z*100 + N for a beta, + 99 for a stable (CFBundleVersion,
              sparkle:version), so a stable is always newer than every beta of the same X.Y.Z
  * Y and Z are 0-99 so they cannot spill into the next field; no leading zeros anywhere

Output is JSON, or one field with --field, or shell assignments with --env.
Subcommand:  version.py has-beta vX.Y.Z   reads tag names on stdin, exits 0 if any
             vX.Y.Z-beta.N (N 1-98) exists among them (the promotion rule).
"""
import argparse
import json
import re
import sys

TAG = re.compile(r"^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]?)\.(0|[1-9][0-9]?)(?:-beta\.([1-9][0-9]?))?$")
MAX_MAJOR = 2000  # keeps the build number inside 32 bits


class BadTag(ValueError):
    pass


def parse(tag):
    """Return the version fields for a release tag, or raise BadTag with a plain reason."""
    m = TAG.fullmatch(tag) if isinstance(tag, str) else None
    if not m:
        raise BadTag(
            f"'{tag}' is not a release tag: use vX.Y.Z or vX.Y.Z-beta.N "
            "(numbers without leading zeros, Y and Z 0-99, N 1-98)"
        )
    x, y, z = int(m.group(1)), int(m.group(2)), int(m.group(3))
    n = int(m.group(4)) if m.group(4) else None
    if x > MAX_MAJOR:
        raise BadTag(f"'{tag}': major version {x} is out of range (max {MAX_MAJOR})")
    if n is not None and not 1 <= n <= 98:
        raise BadTag(f"'{tag}': beta number {n} must be 1-98")
    build = x * 1_000_000 + y * 10_000 + z * 100 + (n if n is not None else 99)
    return {
        "tag": tag,
        "short": tag[1:],
        "base": f"{x}.{y}.{z}",
        "build": str(build),
        "channel": "beta" if n is not None else "stable",
        "prerelease": n is not None,
        "beta": n,
    }


def dev():
    return {"tag": "dev", "short": "0.0.0-dev", "base": "0.0.0", "build": "1",
            "channel": "dev", "prerelease": True, "beta": None}


def has_beta(base_tag, tags):
    """True if `tags` holds a beta of the stable `base_tag` (vX.Y.Z)."""
    stable = parse(base_tag)
    if stable["channel"] != "stable":
        raise BadTag(f"'{base_tag}' is not a stable tag")
    for t in tags:
        try:
            v = parse(t.strip())
        except BadTag:
            continue
        if v["channel"] == "beta" and v["base"] == stable["base"]:
            return True
    return False


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("tag", help="vX.Y.Z, vX.Y.Z-beta.N, dev, or the word has-beta followed by a stable tag")
    p.add_argument("stable", nargs="?", help=argparse.SUPPRESS)
    p.add_argument("--field", choices=["tag", "short", "base", "build", "channel", "prerelease", "beta"],
                   help="print only this field")
    p.add_argument("--env", action="store_true", help="print TAG=... SHORT=... assignments for a shell (eval-safe)")
    a = p.parse_args(argv)
    try:
        if a.tag == "has-beta":
            if not a.stable:
                p.error("has-beta needs a stable tag")
            return 0 if has_beta(a.stable, sys.stdin.read().split()) else 1
        v = dev() if a.tag == "dev" else parse(a.tag)
    except BadTag as e:
        print(f"version.py: {e}", file=sys.stderr)
        return 2
    if a.field:
        val = v[a.field]
        print(str(val).lower() if isinstance(val, bool) else ("" if val is None else val))
    elif a.env:
        for k in ("tag", "short", "base", "build", "channel", "prerelease"):
            val = v[k]
            print(f"{k.upper()}={str(val).lower() if isinstance(val, bool) else val}")
    else:
        print(json.dumps(v, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
