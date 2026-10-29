#!/usr/bin/env bash
# Tests for release-gate.sh in a throwaway repo. Run: app/Scripts/test-release-gate.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
cd "$T"
git init -q -b main . && git config user.email t@example.invalid && git config user.name t
git config commit.gpgsign false; git config tag.gpgsign false
c() { git commit -q --allow-empty -m "$1"; }
pass=0; fail=0
expect() { # expect WANT_EXIT DESC ARGS...
  local want="$1" desc="$2"; shift 2
  set +e; "$HERE/release-gate.sh" "$@" >"$T/out" 2>&1; local got=$?; set -e
  if [ "$got" = "$want" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $desc (exit $got, wanted $want)"; cat "$T/out"; fi
}
git update-ref refs/remotes/origin/main HEAD 2>/dev/null || true
c one; git tag v0.1.0-beta.1; c two; git tag v0.1.0-beta.2; c three
git update-ref refs/remotes/origin/main HEAD
git tag v0.1.0; git tag v0.2.0; git tag v1.0.0-beta.1
git checkout -q -b side main~2; c offmain; git tag v0.3.0-beta.1; git tag v0.3.0; git checkout -q main
git checkout -q -b rel main; git update-ref refs/remotes/origin/release/0.1 HEAD; c hotfix; git update-ref refs/remotes/origin/release/0.1 HEAD; git tag v0.1.1-beta.1; git tag v0.1.1; git checkout -q main

expect 0 "beta"                       v0.1.0-beta.2
expect 0 "stable with a beta on main" v0.1.0
expect 1 "stable without any beta"    v0.2.0
expect 0 "override unsoaked"          v0.2.0 --allow-unsoaked
expect 1 "stable off main"            v0.3.0
expect 1 "stable off main + override" v0.3.0 --allow-unsoaked
expect 0 "hotfix stable on release/X.Y" v0.1.1
expect 2 "bad tag"                    v0.1
expect 1 "missing tag"                v9.9.9
set +e; "$HERE/release-gate.sh" v0.1.0 >"$T/out" 2>&1; set -e
if grep -q "ships changes the beta did not soak" "$T/out"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: expected a note about a stable that differs from its newest beta"; cat "$T/out"; fi
echo "release-gate tests: $pass passed, $fail failed"
[ "$fail" = 0 ]
