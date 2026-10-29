#!/usr/bin/env python3
"""Tests for version.py. Run: python3 -I app/Scripts/test_version.py"""
import io
import os
import sys
import unittest
from contextlib import redirect_stderr, redirect_stdout

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import version  # noqa: E402


class Parse(unittest.TestCase):
    def test_stable(self):
        v = version.parse("v1.2.3")
        self.assertEqual((v["short"], v["build"], v["channel"], v["prerelease"]), ("1.2.3", "1020399", "stable", False))

    def test_beta(self):
        v = version.parse("v0.1.0-beta.4")
        self.assertEqual((v["short"], v["build"], v["channel"], v["prerelease"]), ("0.1.0-beta.4", "10004", "beta", True))

    def test_formula_edges(self):
        self.assertEqual(version.parse("v0.0.1-beta.1")["build"], "101")
        self.assertEqual(version.parse("v12.34.56-beta.98")["build"], str(12_000_000 + 340_000 + 5600 + 98))
        self.assertEqual(version.parse("v99.99.99")["build"], str(99_000_000 + 990_000 + 9900 + 99))

    def test_stable_newer_than_its_betas_and_older_than_next(self):
        order = ["v1.2.3-beta.1", "v1.2.3-beta.98", "v1.2.3", "v1.2.4-beta.1", "v1.3.0-beta.1", "v2.0.0-beta.1"]
        builds = [int(version.parse(t)["build"]) for t in order]
        self.assertEqual(builds, sorted(builds))
        self.assertEqual(len(set(builds)), len(builds))

    def test_rejects(self):
        for bad in ["", "1.2.3", "v1.2", "v1.2.3.4", "v1.2.3-beta", "v1.2.3-beta.0", "v1.2.3-beta.99",
                    "v1.2.3-beta.100", "v1.2.3-beta.01", "v01.2.3", "v1.02.3", "v1.2.03", "v1.100.0", "v1.0.100",
                    "v1.2.3-rc.1", "v1.2.3-beta.1-x", "V1.2.3", " v1.2.3", "v1.2.3\n", "v1.2.3-beta.1\n",
                    "v-1.2.3", "v1.2.3+5", "v2001.0.0", "latest", "dev", None]:
            with self.assertRaises(version.BadTag, msg=repr(bad)):
                version.parse(bad)

    def test_dev(self):
        d = version.dev()
        self.assertEqual((d["short"], d["build"]), ("0.0.0-dev", "1"))


class HasBeta(unittest.TestCase):
    def test_promotion_rule(self):
        tags = ["v1.0.0-beta.1", "v1.0.0-beta.2", "v0.9.0", "junk", "v1.1.0-beta.1"]
        self.assertTrue(version.has_beta("v1.0.0", tags))
        self.assertTrue(version.has_beta("v1.1.0", tags))
        self.assertFalse(version.has_beta("v0.9.0", tags))
        self.assertFalse(version.has_beta("v1.0.1", tags))
        self.assertFalse(version.has_beta("v1.0.0", ["v1.0.00-beta.1", "v1.0.0-beta.99", "v11.0.0-beta.1"]))

    def test_needs_stable_tag(self):
        with self.assertRaises(version.BadTag):
            version.has_beta("v1.0.0-beta.1", [])


class Cli(unittest.TestCase):
    def run_cli(self, *args, stdin=""):
        out, err = io.StringIO(), io.StringIO()
        old = sys.stdin
        sys.stdin = io.StringIO(stdin)
        try:
            with redirect_stdout(out), redirect_stderr(err):
                try:
                    code = version.main(list(args))
                except SystemExit as e:
                    code = e.code
        finally:
            sys.stdin = old
        return code, out.getvalue(), err.getvalue()

    def test_field_and_env(self):
        self.assertEqual(self.run_cli("v1.2.3-beta.1", "--field", "build")[1], "1020301\n")
        self.assertEqual(self.run_cli("v1.2.3-beta.1", "--field", "prerelease")[1], "true\n")
        self.assertEqual(self.run_cli("v1.2.3", "--field", "channel")[1], "stable\n")
        code, out, _ = self.run_cli("v1.2.3", "--env")
        self.assertEqual(code, 0)
        self.assertIn("SHORT=1.2.3\n", out)
        self.assertIn("PRERELEASE=false\n", out)

    def test_bad_tag_exit_code(self):
        code, out, err = self.run_cli("v1.2")
        self.assertEqual((code, out), (2, ""))
        self.assertIn("not a release tag", err)

    def test_has_beta_cli(self):
        self.assertEqual(self.run_cli("has-beta", "v1.0.0", stdin="v1.0.0-beta.3\nv0.1.0\n")[0], 0)
        self.assertEqual(self.run_cli("has-beta", "v1.0.0", stdin="v0.1.0\n")[0], 1)
        self.assertEqual(self.run_cli("has-beta", "v1.0.0", stdin="")[0], 1)


if __name__ == "__main__":
    unittest.main()
