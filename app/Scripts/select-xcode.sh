#!/usr/bin/env bash
# CI: select the newest Xcode on the runner and say which macOS SDK it brings.
# The helper is written against the macOS 27 SDK (a few `#available(macOS 27, *)` calls need its headers),
# so a runner whose newest Xcode is older gets a warning here instead of a confusing compile error later.
set -euo pipefail
best=""; best_version="0"
for app in /Applications/Xcode*.app; do
  [ -d "$app/Contents/Developer" ] || continue
  v="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist" 2>/dev/null || echo 0)"
  if [ "$(printf '%s\n%s\n' "$best_version" "$v" | sort -V | tail -n 1)" = "$v" ] && [ "$v" != "$best_version" ]; then
    best="$app"; best_version="$v"
  fi
done
if [ -n "$best" ]; then
  echo "Using $best (Xcode $best_version)"
  sudo xcode-select -s "$best/Contents/Developer"
fi
xcode-select -p
xcodebuild -version | head -n 2
sdk="$(xcrun --show-sdk-version)"
echo "macOS SDK $sdk, $(swiftc --version 2>&1 | head -n 1)"
if [ "${sdk%%.*}" -lt 27 ]; then
  echo "::warning title=macOS SDK older than 27::The helper uses macOS 27 SDK API behind #available; this runner only has SDK $sdk."
fi
