#!/usr/bin/env bash
# Test the update-signature checks with throwaway keys (no keychain, nothing secret). macOS only: it uses
# Sparkle's sign_update (app/Vendor/Sparkle, see fetch-sparkle.sh) and verify-ed-signature.swift.
#
#   app/Scripts/test-signing.sh [path/to/verify-ed-signature]     (built from the .swift file when not given)
#
# Proves: an archive and an appcast signed with key A verify against A's public key and NOT against B's;
# an archive or appcast changed after signing does not verify; an unsigned appcast does not verify; the
# checker agrees with Sparkle's own `sign_update --verify`; a signed appcast can be extended by appcast.py
# and signed again.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SIGN_UPDATE="${SIGN_UPDATE:-$HERE/../Vendor/Sparkle/bin/sign_update}"
[ -x "$SIGN_UPDATE" ] || { echo "test-signing: no sign_update at $SIGN_UPDATE (run app/Scripts/fetch-sparkle.sh)" >&2; exit 2; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
V="${1:-}"
if [ -z "$V" ]; then V="$T/verify-ed-signature"; swiftc -O "$HERE/verify-ed-signature.swift" -o "$V"; fi

pass=0; fail=0
ok() { pass=$((pass+1)); }
no() { fail=$((fail+1)); echo "FAIL: $*"; }
expect() { # expect WANT_EXIT DESC CMD...   (CMD's output is hidden unless it fails unexpectedly)
  local want="$1" desc="$2"; shift 2
  set +e; "$@" >"$T/out" 2>&1; local got=$?; set -e
  if [ "$got" = "$want" ]; then ok; else no "$desc (exit $got, wanted $want)"; cat "$T/out"; fi
}

head -c 32 /dev/urandom | base64 > "$T/a.key"; head -c 32 /dev/urandom | base64 > "$T/b.key"
PUB_A="$("$V" public-key --private-key-file "$T/a.key")"; PUB_B="$("$V" public-key --private-key-file "$T/b.key")"

# --- an update archive, signed the way the release workflow does (key on stdin) ----------------------------
head -c 100000 /dev/urandom > "$T/Microfish-0.1.0.zip"
"$SIGN_UPDATE" --ed-key-file - "$T/Microfish-0.1.0.zip" < "$T/a.key" > "$T/sig.txt"
expect 0 "archive verifies against its own public key"    "$V" zip "$T/Microfish-0.1.0.zip" --public-key "$PUB_A" --signature-output "$T/sig.txt"
expect 1 "archive does not verify against another key"    "$V" zip "$T/Microfish-0.1.0.zip" --public-key "$PUB_B" --signature-output "$T/sig.txt"
cp "$T/Microfish-0.1.0.zip" "$T/tampered.zip"; printf 'x' | dd of="$T/tampered.zip" bs=1 seek=500 conv=notrunc 2>/dev/null
expect 1 "archive changed after signing is rejected"      "$V" zip "$T/tampered.zip" --public-key "$PUB_A" --signature-output "$T/sig.txt"
head -c 99999 "$T/Microfish-0.1.0.zip" > "$T/short.zip"
expect 1 "archive of a different length is rejected"      "$V" zip "$T/short.zip" --public-key "$PUB_A" --signature-output "$T/sig.txt"
expect 2 "garbage public key is a usage error"            "$V" zip "$T/Microfish-0.1.0.zip" --public-key "not-a-key" --signature-output "$T/sig.txt"
expect 0 "Sparkle's own --verify agrees (key A)"          "$SIGN_UPDATE" --ed-key-file "$T/a.key" --verify "$T/Microfish-0.1.0.zip" "$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' "$T/sig.txt")"

# --- an appcast, built by appcast.py and signed ------------------------------------------------------------------
sig="$(cat "$T/sig.txt")"
python3 -I "$HERE/appcast.py" add --appcast "$T/appcast.xml" --tag v0.1.0-beta.1 --zip "$T/Microfish-0.1.0.zip" \
  --signing-output "$sig" --min-system 15.0 --notes embedded >/dev/null
expect 1 "an unsigned appcast does not verify"            "$V" feed "$T/appcast.xml" --public-key "$PUB_A"
"$SIGN_UPDATE" --ed-key-file - "$T/appcast.xml" < "$T/a.key" >/dev/null
expect 0 "signed appcast verifies against its own key"    "$V" feed "$T/appcast.xml" --public-key "$PUB_A"
expect 1 "signed appcast does not verify against another key" "$V" feed "$T/appcast.xml" --public-key "$PUB_B"
expect 0 "Sparkle's own --verify agrees on the appcast (key A)" "$SIGN_UPDATE" --ed-key-file "$T/a.key" --verify "$T/appcast.xml"
expect 1 "Sparkle's own --verify rejects the appcast under key B" "$SIGN_UPDATE" --ed-key-file "$T/b.key" --verify "$T/appcast.xml"
expect 0 "the signed appcast is still a valid feed (appcast.py check)" python3 -I "$HERE/appcast.py" check "$T/appcast.xml"
sed 's|Microfish 0.1.0-beta.1|Microfish 9.9.9|' "$T/appcast.xml" > "$T/edited.xml"
expect 1 "appcast edited after signing is rejected"       "$V" feed "$T/edited.xml" --public-key "$PUB_A"
expect 1 "... and Sparkle's own --verify rejects it too"  "$SIGN_UPDATE" --ed-key-file "$T/a.key" --verify "$T/edited.xml"
sed 's|https://github.com/elenaOnline/microfish/releases/download|https://example.invalid/evil|' "$T/appcast.xml" > "$T/redirected.xml"
expect 1 "appcast with a swapped download URL is rejected" "$V" feed "$T/redirected.xml" --public-key "$PUB_A"
# one more byte appended after the signature block
cp "$T/appcast.xml" "$T/appended.xml"; echo '<!-- more -->' >> "$T/appended.xml"
expect 1 "appcast with content appended after the signature is rejected" "$V" feed "$T/appended.xml" --public-key "$PUB_A"

# --- the next release: add to the signed feed, sign again ------------------------------------------------------
python3 -I "$HERE/appcast.py" add --appcast "$T/appcast.xml" --tag v0.1.0-beta.2 --zip "$T/Microfish-0.1.0.zip" \
  --signing-output "$sig" --min-system 15.0 --notes embedded >/dev/null
expect 1 "after appcast.py edits the file the old signature is gone" "$V" feed "$T/appcast.xml" --public-key "$PUB_A"
"$SIGN_UPDATE" --ed-key-file - "$T/appcast.xml" < "$T/a.key" >/dev/null
expect 0 "re-signed appcast with two items verifies"     "$V" feed "$T/appcast.xml" --public-key "$PUB_A"
expect 0 "... and has both items"                        test "$(grep -o '<sparkle:shortVersionString>' "$T/appcast.xml" | wc -l | tr -d ' ')" = 2

echo "signing tests: $pass passed, $fail failed"
[ "$fail" = 0 ]
