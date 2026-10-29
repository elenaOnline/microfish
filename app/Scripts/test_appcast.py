#!/usr/bin/env python3
"""Tests for appcast.py. Run: python3 -I app/Scripts/test_appcast.py"""
import os
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import appcast  # noqa: E402

S = appcast.S
SIG = "WVyVJpOx+a5+vNWJVY79TRjFKveNk+VhGJf2iti4CZtJsJewIUGvh/1AKKEAFbH1qUwx+vro1ECuzOsMmumoBA=="


class AppcastTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.path = os.path.join(self.dir.name, "appcast.xml")

    def tearDown(self):
        self.dir.cleanup()

    def read(self, mode):
        with open(self.path, mode) as f:
            return f.read()

    def add(self, tag, length=1000, sig=SIG, **kw):
        return appcast.add(self.path, tag, sig, length, date="Wed, 28 Oct 2026 12:00:00 GMT", **kw)

    def items(self):
        return ET.parse(self.path).getroot().find("channel").findall("item")

    def shorts(self):
        return [i.find(S + "shortVersionString").text for i in self.items()]

    def test_creates_valid_feed(self):
        self.assertEqual(self.add("v0.1.0-beta.1"), "added")
        root = ET.parse(self.path).getroot()
        self.assertEqual((root.tag, root.get("version")), ("rss", "2.0"))
        self.assertEqual(root.find("channel/title").text, "Microfish")
        raw = self.read("r")
        self.assertTrue(raw.startswith("<?xml version='1.0' encoding='utf-8'?>"))
        self.assertIn('xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"', raw)
        self.assertEqual(appcast.check(self.path), [])

    def test_beta_item_fields(self):
        self.add("v0.1.0-beta.2", length=4242, min_system="15.0")
        (item,) = self.items()
        self.assertEqual(item.find("title").text, "Microfish 0.1.0-beta.2")
        self.assertEqual(item.find(S + "version").text, "10002")
        self.assertEqual(item.find(S + "shortVersionString").text, "0.1.0-beta.2")
        self.assertEqual(item.find(S + "minimumSystemVersion").text, "15.0")
        self.assertEqual(item.find(S + "hardwareRequirements").text, "arm64")
        self.assertEqual(item.find(S + "channel").text, "beta")
        self.assertEqual(item.find("pubDate").text, "Wed, 28 Oct 2026 12:00:00 GMT")
        self.assertEqual(item.find(S + "releaseNotesLink").text,
                         "https://github.com/elenaOnline/microfish/releases/tag/v0.1.0-beta.2")
        enc = item.find("enclosure")
        self.assertEqual(enc.get("url"),
                         "https://github.com/elenaOnline/microfish/releases/download/v0.1.0-beta.2/Microfish-0.1.0-beta.2.zip")
        self.assertEqual((enc.get("length"), enc.get("type"), enc.get(S + "edSignature")),
                         ("4242", "application/octet-stream", SIG))

    def test_stable_has_no_channel(self):
        self.add("v0.1.0")
        self.assertIsNone(self.items()[0].find(S + "channel"))
        self.assertEqual(self.items()[0].find(S + "version").text, "10099")

    def test_newest_first_regardless_of_insertion_order(self):
        for tag in ["v0.1.0-beta.1", "v0.2.0", "v0.1.0", "v0.1.0-beta.2", "v0.2.0-beta.1", "v1.0.0"]:
            self.add(tag)
        self.assertEqual(self.shorts(),
                         ["1.0.0", "0.2.0", "0.2.0-beta.1", "0.1.0", "0.1.0-beta.2", "0.1.0-beta.1"])
        self.assertEqual(appcast.check(self.path), [])

    def test_idempotent_replace_keeps_position_and_date(self):
        self.add("v0.1.0-beta.1")
        self.add("v0.1.0-beta.2")
        before = self.read("rb")
        self.assertEqual(self.add("v0.1.0-beta.1"), "replaced")
        self.assertEqual(self.read("rb"), before)
        # a re-run with a new signature replaces that item only, without a new pubDate
        self.assertEqual(appcast.add(self.path, "v0.1.0-beta.1", "AAAA", 7), "replaced")
        items = self.items()
        self.assertEqual(self.shorts(), ["0.1.0-beta.2", "0.1.0-beta.1"])
        self.assertEqual(items[1].find("enclosure").get(S + "edSignature"), "AAAA")
        self.assertEqual(items[1].find("pubDate").text, "Wed, 28 Oct 2026 12:00:00 GMT")
        self.assertEqual(items[0].find("enclosure").get(S + "edSignature"), SIG)

    def test_never_drops_or_reorders_existing_items_or_foreign_elements(self):
        with open(self.path, "w", encoding="utf-8") as f:
            f.write(f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="{appcast.SPARKLE}"><channel><title>T</title>
<item><title>Odd</title><sparkle:version>weird</sparkle:version><enclosure url="u" length="1" sparkle:edSignature="QQ=="/></item>
<item><title>Old</title><sparkle:version>10001</sparkle:version><sparkle:shortVersionString>0.1.0-beta.1</sparkle:shortVersionString>
<sparkle:channel>beta</sparkle:channel><enclosure url="u" length="1" sparkle:edSignature="QQ=="/></item>
</channel></rss>""")
        self.add("v0.1.0-beta.2")
        root = ET.parse(self.path).getroot()
        titles = [i.find("title").text for i in root.find("channel").findall("item")]
        self.assertEqual(titles, ["Odd", "Microfish 0.1.0-beta.2", "Old"])
        self.assertEqual(root.find("channel/title").text, "T")

    def test_remove_for_rollback(self):
        self.add("v0.1.0-beta.1")
        self.add("v0.1.0")
        self.assertEqual(appcast.remove(self.path, "v0.1.0"), 1)
        self.assertEqual(self.shorts(), ["0.1.0-beta.1"])
        self.assertEqual(appcast.remove(self.path, "v0.1.0"), 0)

    def test_signing_output_parse(self):
        sig, length = appcast.parse_signing_output(f'sparkle:edSignature="{SIG}" length="1623481"\n')
        self.assertEqual((sig, length), (SIG, 1623481))
        with self.assertRaises(appcast.AppcastError):
            appcast.parse_signing_output("nothing here")

    def test_rejects_bad_input(self):
        for kwargs in [dict(sig=""), dict(sig="not base64!"), dict(length=0)]:
            with self.assertRaises(appcast.AppcastError):
                self.add("v0.1.0", **kwargs)
        with self.assertRaises(appcast.versionlib.BadTag):
            self.add("v1.2")
        self.assertFalse(os.path.exists(self.path))
        with open(self.path, "w") as f:
            f.write("<rss")
        with self.assertRaises(appcast.AppcastError):
            self.add("v0.1.0")
        self.assertEqual(self.read("r"), "<rss")

    def test_check_flags_problems(self):
        self.add("v0.1.0")
        tree = ET.parse(self.path)
        item = tree.getroot().find("channel/item")
        item.find("enclosure").attrib.pop(S + "edSignature")
        tree.write(self.path)
        self.assertTrue(any("edSignature" in p for p in appcast.check(self.path)))

    def test_cli(self):
        zp = os.path.join(self.dir.name, "Microfish-0.1.0-beta.1.zip")
        with open(zp, "wb") as f:
            f.write(b"x" * 321)
        out = f'sparkle:edSignature="{SIG}" length="321"'
        code = appcast.main(["add", "--appcast", self.path, "--tag", "v0.1.0-beta.1", "--zip", zp,
                             "--signing-output", out])
        self.assertEqual(code, 0)
        self.assertEqual(self.items()[0].find("enclosure").get("length"), "321")
        self.assertEqual(appcast.main(["check", self.path]), 0)
        self.assertEqual(appcast.main(["add", "--appcast", self.path, "--tag", "nope", "--length", "1",
                                       "--signature", SIG]), 2)


if __name__ == "__main__":
    unittest.main()
