#!/usr/bin/env bash
# CI: choose the developer directory (an Xcode, or the Command Line Tools) with the newest macOS SDK whose own
# linker can read it, select it, and say which SDK it brings.
#
# Why not simply "newest Xcode": a runner image can carry Command Line Tools with a newer SDK than any of its
# Xcodes (macos-26 in October 2026: Xcode 26.6 with SDK 26.5, CLT with SDK 27.0). The helper is written against
# the macOS 27 SDK (`NSMenuItem.preferredImageVisibility` has no 26.x declaration), and the engine's build.rs
# links the private SkyLight framework from the SDKs of $DEVELOPER_DIR, or of the CLT when it is unset. Mixing
# the two (Xcode 26's ld reading the CLT's 27 SDK) fails with "tapi error: unknown architecture arm64e.x1".
# So each candidate is probed by linking SkyLight with its own tools, and the build sees one consistent
# toolchain: DEVELOPER_DIR is exported for an Xcode (build.rs then searches that Xcode's SDKs) and left unset
# for the CLT (build.rs's default).
set -euo pipefail
probe_dir="$(mktemp -d)"; trap 'rm -rf "$probe_dir"' EXIT
printf 'int main(void){return 0;}\n' > "$probe_dir/p.c"

sdk_version() { DEVELOPER_DIR="$1" xcrun --sdk macosx --show-sdk-version 2>/dev/null || echo 0; }
links_skylight() {   # the candidate's clang+ld against the candidate's SDK, with the private framework
  local dev="$1" sdk
  sdk="$(DEVELOPER_DIR="$dev" xcrun --sdk macosx --show-sdk-path 2>/dev/null)" || return 1
  DEVELOPER_DIR="$dev" xcrun clang -arch arm64 -isysroot "$sdk" -F "$sdk/System/Library/PrivateFrameworks" \
    -framework SkyLight "$probe_dir/p.c" -o "$probe_dir/p" 2>"$probe_dir/err" || { sed 's/^/    /' "$probe_dir/err" | head -n 3; return 1; }
}

candidates=()
for app in /Applications/Xcode*.app; do [ -d "$app/Contents/Developer" ] && candidates+=("$app/Contents/Developer"); done
[ -d /Library/Developer/CommandLineTools/usr/bin ] && candidates+=(/Library/Developer/CommandLineTools)

best=""; best_sdk="0"
for dev in "${candidates[@]}"; do
  v="$(sdk_version "$dev")"
  if links_skylight "$dev"; then ok=yes; else ok=no; fi
  echo "  $dev: macOS SDK $v, links SkyLight: $ok"
  [ "$ok" = yes ] || continue
  if [ "$(printf '%s\n%s\n' "$best_sdk" "$v" | sort -V | tail -n 1)" = "$v" ] && [ "$v" != "$best_sdk" ]; then
    best="$dev"; best_sdk="$v"
  fi
done
[ -n "$best" ] || { echo "::error::No developer directory on this runner links the SkyLight framework with its own SDK."; exit 1; }

echo "Using $best (macOS SDK $best_sdk)"
sudo xcode-select -s "$best"
if [ -n "${GITHUB_ENV:-}" ]; then
  case "$best" in
    /Library/Developer/CommandLineTools) ;;                      # build.rs defaults to the CLT's SDKs
    *) echo "DEVELOPER_DIR=$best" >> "$GITHUB_ENV" ;;           # build.rs searches this Xcode's SDKs
  esac
fi
xcode-select -p
echo "macOS SDK $(xcrun --sdk macosx --show-sdk-version), $(xcrun swiftc --version 2>&1 | head -n 1)"
if [ "${best_sdk%%.*}" -lt 27 ]; then
  echo "::warning title=macOS SDK older than 27::The helper uses macOS 27 SDK API; this runner's newest usable SDK is $best_sdk."
fi
