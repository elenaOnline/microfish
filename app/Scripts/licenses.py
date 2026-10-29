#!/usr/bin/env python3
"""Write the Rust dependency notices that ship in Microfish.app/Contents/Resources/Credits.

    licenses.py --manifest-path Cargo.toml --out Credits/RustDependencies.txt [--target aarch64-apple-darwin]

Walks `cargo metadata` from the root package along normal and build dependencies (what ends up in,
or compiles into, the engine; dev-dependencies are skipped), then lists each crate with its version,
SPDX license expression and repository, followed by the text of every license/notice file found in
the crate's source directory. cargo-about would add SPDX-aware deduplication and a curated
"clarify" table for crates without license files; this covers the same attribution duty with no
extra tool, and prints a warning for any crate it finds no license text for.
"""
import argparse
import json
import os
import re
import subprocess
import sys

NOTICE_NAME = re.compile(r"^(LICEN[CS]E|COPYING|COPYRIGHT|NOTICE|UNLICENSE)([-_.].*)?$", re.I)
SKIP_DIRS = {"target", "tests", "test", "benches", "examples", "doc", "docs", ".git", "node_modules"}
MAX_BYTES = 120_000


def metadata(manifest, target):
    cmd = ["cargo", "metadata", "--format-version", "1", "--locked", "--manifest-path", manifest]
    if target:
        cmd += ["--filter-platform", target]
    out = subprocess.run(cmd, check=True, capture_output=True, text=True).stdout
    return json.loads(out)


def shipped_packages(meta):
    """Packages reachable from the root through normal/build dependency edges."""
    nodes = {n["id"]: n for n in meta["resolve"]["nodes"]}
    by_id = {p["id"]: p for p in meta["packages"]}
    root = meta["resolve"]["root"]
    seen, todo = set(), [root]
    while todo:
        pid = todo.pop()
        if pid in seen:
            continue
        seen.add(pid)
        for dep in nodes[pid]["deps"]:
            if any(k.get("kind") in (None, "build") for k in dep["dep_kinds"]):
                todo.append(dep["pkg"])
    seen.discard(root)
    return sorted((by_id[i] for i in seen), key=lambda p: (p["name"], p["version"]))


def notice_files(pkg):
    base = os.path.dirname(pkg["manifest_path"])
    found = []
    for dirpath, dirs, files in os.walk(base):
        depth = os.path.relpath(dirpath, base).count(os.sep) + (0 if dirpath == base else 1)
        dirs[:] = sorted(d for d in dirs if d.lower() not in SKIP_DIRS) if depth < 3 else []
        for f in sorted(files):
            full = os.path.join(dirpath, f)
            if NOTICE_NAME.match(f) and os.path.isfile(full) and os.path.getsize(full) <= MAX_BYTES:
                found.append(full)
    return base, found


def render(packages):
    lines = ["Microfish's engine is built from the following Rust crates.",
             "A license text that several crates ship verbatim is printed once and referenced afterwards.", ""]
    missing = []
    first_seen = {}
    for pkg in packages:
        base, files = notice_files(pkg)
        lines += ["=" * 78, f"{pkg['name']} {pkg['version']}",
                  f"License: {pkg.get('license') or pkg.get('license_file') or 'unspecified'}"]
        if pkg.get("repository"):
            lines.append(f"Source: {pkg['repository']}")
        lines.append("")
        if not files:
            missing.append(pkg["name"])
            lines += ["(no license file in the published crate; see the SPDX expression above)", ""]
        for full in files:
            with open(full, encoding="utf-8", errors="replace") as f:
                text = f.read().strip()
            key = re.sub(r"\s+", " ", text)
            where = f"{pkg['name']} {pkg['version']}"
            if key in first_seen:
                lines += [f"--- {os.path.relpath(full, base)}: same text as {first_seen[key]} ---", ""]
            else:
                first_seen[key] = where + ", " + os.path.relpath(full, base)
                lines += [f"--- {os.path.relpath(full, base)} ---", text, ""]
    return "\n".join(lines) + "\n", missing


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--manifest-path", default="Cargo.toml")
    p.add_argument("--out", required=True)
    p.add_argument("--target", default="aarch64-apple-darwin")
    a = p.parse_args(argv)
    packages = shipped_packages(metadata(a.manifest_path, a.target))
    text, missing = render(packages)
    with open(a.out, "w", encoding="utf-8") as f:
        f.write(text)
    print(f"licenses.py: {len(packages)} crates -> {a.out}")
    if missing:
        print(f"licenses.py: warning: no license file shipped by: {', '.join(missing)}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
