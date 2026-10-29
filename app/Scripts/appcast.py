#!/usr/bin/env python3
"""Create or update the Sparkle appcast (RSS 2.0 + the sparkle namespace).

    appcast.py add --appcast appcast.xml --tag v0.1.0-beta.2 --length 1234567 \\
        --signing-output 'sparkle:edSignature="..." length="1234567"'
    appcast.py add --appcast appcast.xml --tag v0.1.0 --zip Microfish-0.1.0.zip --signature BASE64
    appcast.py remove --appcast appcast.xml --tag v0.1.0-beta.1
    appcast.py check appcast.xml

`add` writes one <item> per release: title, pubDate, sparkle:version (the build number from
version.py), sparkle:shortVersionString, sparkle:minimumSystemVersion, sparkle:hardwareRequirements,
sparkle:channel (betas only), a release-notes link to the GitHub release, and the enclosure (URL of
the release asset, length, type, sparkle:edSignature as printed by Sparkle's sign_update).

Properties the release pipeline relies on:
  * idempotent per version: adding a version that is already in the file replaces that item in
    place (keeping its pubDate), so re-running a job cannot duplicate or reorder anything;
  * newest first by sparkle:version; items that are already in the file are never dropped or reordered;
  * the file is replaced atomically.
"""
import argparse
import datetime
import email.utils
import os
import re
import sys
import tempfile
import xml.etree.ElementTree as ET

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import version as versionlib  # noqa: E402

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)
S = "{%s}" % SPARKLE

DEFAULT_REPO = "elenaOnline/microfish"
DEFAULT_MIN_SYSTEM = "15.0"  # keep equal to MIN_MACOS in build-app.sh (LSMinimumSystemVersion)
CHANNEL_TITLE = "Microfish"
CHANNEL_DESCRIPTION = "Updates for Microfish."


class AppcastError(Exception):
    pass


def new_tree(repo):
    rss = ET.Element("rss", {"version": "2.0"})
    ch = ET.SubElement(rss, "channel")
    ET.SubElement(ch, "title").text = CHANNEL_TITLE
    ET.SubElement(ch, "link").text = f"https://github.com/{repo}"
    ET.SubElement(ch, "description").text = CHANNEL_DESCRIPTION
    ET.SubElement(ch, "language").text = "en"
    return ET.ElementTree(rss)


def load(path, repo):
    if not os.path.exists(path):
        return new_tree(repo)
    try:
        tree = ET.parse(path)
    except ET.ParseError as e:
        raise AppcastError(f"{path} is not valid XML: {e}")
    root = tree.getroot()
    if root.tag != "rss" or root.find("channel") is None:
        raise AppcastError(f"{path} is not an RSS feed with a <channel>")
    return tree


def item_version(item):
    v = item.find(S + "version")
    return (v.text or "").strip() if v is not None else ""


def item_short(item):
    v = item.find(S + "shortVersionString")
    return (v.text or "").strip() if v is not None else ""


def as_int(s):
    return int(s) if s.isdigit() else None


def parse_signing_output(text):
    """Pull edSignature and length out of `sign_update` output."""
    sig = re.search(r'sparkle:edSignature="([^"]+)"', text)
    length = re.search(r'length="([0-9]+)"', text)
    if not sig:
        raise AppcastError("no sparkle:edSignature=\"...\" in the signing output")
    return sig.group(1), int(length.group(1)) if length else None


def build_item(v, repo, signature, length, min_system, hardware, date, notes_kind):
    item = ET.Element("item")
    ET.SubElement(item, "title").text = f"Microfish {v['short']}"
    ET.SubElement(item, "pubDate").text = date
    ET.SubElement(item, S + "version").text = v["build"]
    ET.SubElement(item, S + "shortVersionString").text = v["short"]
    ET.SubElement(item, S + "minimumSystemVersion").text = min_system
    if hardware:
        ET.SubElement(item, S + "hardwareRequirements").text = hardware
    if v["channel"] == "beta":
        ET.SubElement(item, S + "channel").text = "beta"
    notes = f"https://github.com/{repo}/releases/tag/{v['tag']}"
    ET.SubElement(item, S + ("fullReleaseNotesLink" if notes_kind == "full" else "releaseNotesLink")).text = notes
    ET.SubElement(item, "enclosure", {
        "url": f"https://github.com/{repo}/releases/download/{v['tag']}/Microfish-{v['short']}.zip",
        "length": str(length),
        "type": "application/octet-stream",
        S + "edSignature": signature,
    })
    return item


def add(path, tag, signature, length, repo=DEFAULT_REPO, min_system=DEFAULT_MIN_SYSTEM,
        hardware="arm64", date=None, notes_kind="release"):
    v = versionlib.parse(tag)
    if not signature or not re.fullmatch(r"[A-Za-z0-9+/]+={0,2}", signature):
        raise AppcastError("the EdDSA signature is empty or not base64")
    if not length or length < 1:
        raise AppcastError("the archive length is missing")
    tree = load(path, repo)
    channel = tree.getroot().find("channel")
    items = channel.findall("item")
    existing = next((i for i in items if item_version(i) == v["build"] or item_short(i) == v["short"]), None)
    if existing is not None and not date:
        old = existing.find("pubDate")
        date = old.text if old is not None else None
    date = date or email.utils.format_datetime(datetime.datetime.now(datetime.timezone.utc), usegmt=True)
    new = build_item(v, repo, signature, length, min_system, hardware, date, notes_kind)
    if existing is not None:
        children = list(channel)
        children[children.index(existing)] = new
        channel[:] = children
    else:
        position = None
        for child in list(channel):
            if child.tag == "item":
                n = as_int(item_version(child))
                if n is not None and n < int(v["build"]):
                    position = list(channel).index(child)
                    break
        if position is None:
            last = max((i for i, c in enumerate(channel) if c.tag == "item"), default=len(channel) - 1)
            position = last + 1
        channel.insert(position, new)
    write(tree, path)
    return "replaced" if existing is not None else "added"


def remove(path, tag):
    v = versionlib.parse(tag)
    tree = load(path, DEFAULT_REPO)
    channel = tree.getroot().find("channel")
    gone = [i for i in channel.findall("item") if item_version(i) == v["build"] or item_short(i) == v["short"]]
    for i in gone:
        channel.remove(i)
    if gone:
        write(tree, path)
    return len(gone)


def write(tree, path):
    ET.indent(tree, space="  ")
    d = os.path.dirname(os.path.abspath(path))
    fd, tmp = tempfile.mkstemp(prefix=".appcast-", suffix=".xml", dir=d)
    try:
        with os.fdopen(fd, "wb") as f:
            tree.write(f, encoding="utf-8", xml_declaration=True)
            f.write(b"\n")
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def check(path):
    """Validate the shape Sparkle needs. Returns a list of problems (empty when fine)."""
    problems = []
    tree = load(path, DEFAULT_REPO)
    seen = set()
    last = None
    for n, item in enumerate(tree.getroot().find("channel").findall("item"), 1):
        v, short = item_version(item), item_short(item)
        enc = item.find("enclosure")
        if not v or not v.isdigit():
            problems.append(f"item {n}: sparkle:version missing or not a number")
        if v in seen:
            problems.append(f"item {n}: duplicate sparkle:version {v}")
        seen.add(v)
        if last is not None and v.isdigit() and int(v) > last:
            problems.append(f"item {n}: not newest first")
        if v.isdigit():
            last = int(v)
        if enc is None or not enc.get("url") or not enc.get(S + "edSignature") or not enc.get("length"):
            problems.append(f"item {n} ({short}): enclosure needs url, length and sparkle:edSignature")
        is_beta = "-beta." in short
        channel = item.find(S + "channel")
        if is_beta != (channel is not None and channel.text == "beta"):
            problems.append(f"item {n} ({short}): beta channel tag does not match the version")
    return problems


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    a = sub.add_parser("add", help="add or replace the item for one release")
    a.add_argument("--appcast", required=True)
    a.add_argument("--tag", required=True)
    a.add_argument("--zip", help="the release archive (its size is the enclosure length)")
    a.add_argument("--length", type=int)
    a.add_argument("--signature")
    a.add_argument("--signing-output", help="the line sign_update printed")
    a.add_argument("--repo", default=DEFAULT_REPO)
    a.add_argument("--min-system", default=DEFAULT_MIN_SYSTEM)
    a.add_argument("--hardware", default="arm64", help="sparkle:hardwareRequirements ('' to omit)")
    a.add_argument("--date", help="pubDate (RFC 822); default now, or the existing item's")
    a.add_argument("--notes", choices=["release", "full"], default="release",
                   help="release: sparkle:releaseNotesLink; full: sparkle:fullReleaseNotesLink (a Version History link)")
    r = sub.add_parser("remove", help="delete the item for one release (rollback)")
    r.add_argument("--appcast", required=True)
    r.add_argument("--tag", required=True)
    c = sub.add_parser("check", help="validate an appcast")
    c.add_argument("appcast")
    args = p.parse_args(argv)
    try:
        if args.cmd == "add":
            sig, length = args.signature, args.length
            if args.signing_output:
                s2, l2 = parse_signing_output(args.signing_output)
                sig, length = sig or s2, length or l2
            if args.zip and not length:
                length = os.path.getsize(args.zip)
            what = add(args.appcast, args.tag, sig, length, args.repo, args.min_system,
                       args.hardware or None, args.date, args.notes)
            print(f"{what} {args.tag} in {args.appcast}")
        elif args.cmd == "remove":
            n = remove(args.appcast, args.tag)
            print(f"removed {n} item(s) for {args.tag}")
            return 0 if n else 1
        else:
            problems = check(args.appcast)
            for line in problems:
                print(f"appcast.py: {line}", file=sys.stderr)
            return 1 if problems else 0
    except (AppcastError, versionlib.BadTag) as e:
        print(f"appcast.py: {e}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
