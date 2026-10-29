#!/usr/bin/env bash
# Zip a built Microfish.app the way Sparkle and GitHub Releases want it:
#   app/Scripts/package.sh path/to/Microfish.app [--out DIR]   ->  DIR/Microfish-<short version>.zip
# ditto keeps the code signature, symlinks and the stapled notarization ticket intact; plain `zip` does not.
set -euo pipefail
APP="${1:?usage: package.sh Microfish.app [--out DIR]}"; shift
OUT="$(dirname "$APP")"
while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="${2:?--out needs a directory}"; shift 2 ;;
    *) echo "package.sh: unknown option $1" >&2; exit 1 ;;
  esac
done
[ -d "$APP/Contents" ] || { echo "package.sh: not an app bundle: $APP" >&2; exit 1; }
SHORT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
mkdir -p "$OUT"; ZIP="$(cd "$OUT" && pwd)/Microfish-$SHORT.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
echo "$ZIP"
printf '  %s bytes, sha256 %s\n' "$(stat -f %z "$ZIP")" "$(shasum -a 256 "$ZIP" | awk '{print $1}')"
