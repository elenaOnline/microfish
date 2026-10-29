#!/usr/bin/env bash
# Assert that an engine binary carries the expected CFBundleIdentifier in its embedded Info.plist
# (the __TEXT,__info_plist section). Without the `microfish` cargo feature the binary embeds upstream's
# identity instead, and the app would ship an engine macOS cannot tell apart from a stock Paneru.
#
#   app/Scripts/check-engine-identity.sh <binary> [expected-id]      (default net.webreceptor.microfish.engine)
set -euo pipefail
BIN="${1:?usage: check-engine-identity.sh BINARY [EXPECTED_ID]}"
WANT="${2:-net.webreceptor.microfish.engine}"
[ -f "$BIN" ] || { echo "check-engine-identity: no such file: $BIN" >&2; exit 1; }
# `launchctl plist` prints the section as an old-style (OpenStep) plist, which plutil cannot read: pick the line.
plist="$(launchctl plist __TEXT,__info_plist "$BIN" 2>&1 || true)"
got="$(printf '%s\n' "$plist" | sed -n 's/^[[:space:]]*"\{0,1\}CFBundleIdentifier"\{0,1\}[[:space:]]*=[[:space:]]*"\{0,1\}\([^";]*\)"\{0,1\};.*$/\1/p' | head -n 1)"
[ -n "$got" ] || { echo "check-engine-identity: $BIN has no CFBundleIdentifier in an embedded __TEXT,__info_plist" >&2; exit 1; }
if [ "$got" != "$WANT" ]; then
  echo "check-engine-identity: $(basename "$BIN") embeds CFBundleIdentifier '$got', expected '$WANT' (built without --features microfish?)" >&2
  exit 1
fi
echo "  engine identity: embedded CFBundleIdentifier = $got"
