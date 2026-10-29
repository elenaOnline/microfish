#!/usr/bin/env bash
# CI: choose the Xcode with the newest macOS SDK that its own linker can link the engine's private framework
# against, select it, and point DEVELOPER_DIR at it so the engine's build.rs uses the same SDKs.
#
# Only an Xcode will do for the helper: the Command Line Tools ship no SwiftUI macro plugins (with SDK 27,
# `@State` is a macro: "plugin for module 'SwiftUIMacros' not found"). The CLT is a fallback when no Xcode
# links. The engine's build.rs adds the private SkyLight framework from the SDKs of $DEVELOPER_DIR (the CLT's
# when it is unset); on macos-26 (October 2026) the CLT carries SDK 27.0, which Xcode 26's ld cannot read
# ("tapi error: unknown architecture arm64e.x1"). Exporting DEVELOPER_DIR keeps the engine and the linker on
# one SDK. The helper builds with an Xcode 26 SDK: its two macOS 27-only calls sit behind
# `#if compiler(>=6.4)` (Xcode 27's Swift), so a 26 build only lacks those (hidden menu-item images on 27).
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

pick() {   # newest SDK among the given developer directories that links SkyLight
  local dev v ok; best=""; best_sdk="0"
  for dev in "$@"; do
    v="$(sdk_version "$dev")"
    if links_skylight "$dev"; then ok=yes; else ok=no; fi
    echo "  $dev: macOS SDK $v, links SkyLight: $ok"
    [ "$ok" = yes ] || continue
    if [ "$(printf '%s\n%s\n' "$best_sdk" "$v" | sort -V | tail -n 1)" = "$v" ] && [ "$v" != "$best_sdk" ]; then
      best="$dev"; best_sdk="$v"
    fi
  done
}
xcodes=()
for app in /Applications/Xcode*.app; do [ -d "$app/Contents/Developer" ] && xcodes+=("$(cd "$app/Contents/Developer" && pwd -P)"); done
best=""; best_sdk="0"
unique=(); while IFS= read -r d; do unique+=("$d"); done < <(printf '%s\n' "${xcodes[@]+"${xcodes[@]}"}" | sed '/^$/d' | sort -u)
[ "${#unique[@]}" -gt 0 ] && pick "${unique[@]}"
if [ -z "$best" ] && [ -d /Library/Developer/CommandLineTools/usr/bin ]; then
  echo "::warning::No Xcode links SkyLight; falling back to the Command Line Tools (no SwiftUI macro plugins)."
  pick /Library/Developer/CommandLineTools
fi
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
