#!/usr/bin/env bash
# Build the engine (paneru) and the bridge (paneru-navigator-command) in release mode.
#
#   app/Scripts/build-engine.sh
#
# This is the one place that runs dependency code (cargo build scripts, proc macros). The release
# workflow runs it BEFORE the Developer ID certificate is imported, so nothing from a crate can reach the
# signing key; build-app.sh then runs with --skip-engine-build. build-app.sh calls it too when it is
# not told to skip the build (local builds).
#
# Output: $CARGO_TARGET_DIR/release/{paneru,paneru-navigator-command}  (CARGO_TARGET_DIR defaults to <repo>/target)
# Environment: MICROFISH_CARGO_JOBS (default 2, ignored on CI), MACOSX_DEPLOYMENT_TARGET (default: MIN_MACOS below)
#
# It fails, rather than building something else, when the `microfish` cargo feature (the engine's own
# identity, app/Packaging/Engine-Embedded-Info.plist) is missing, and afterwards checks that the engine
# really carries net.webreceptor.microfish.engine in its embedded Info.plist.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENGINE_ID="net.webreceptor.microfish.engine"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-15.0}"   # keep equal to MIN_MACOS in build-app.sh
TARGET_DIR="${CARGO_TARGET_DIR:-$REPO/target}"
die() { printf 'build-engine.sh: error: %s\n' "$*" >&2; exit 1; }

grep -Eq '^microfish[[:space:]]*=' "$REPO/Cargo.toml" \
  || die "Cargo.toml has no 'microfish' feature: the engine would ship with upstream's identity. Refusing to build without it."

echo "==> cargo build --release --features microfish (paneru, paneru-navigator-command)"
# Build paths stay out of the binaries: panic locations would otherwise carry the builder's home directory.
REMAP="--remap-path-prefix=$REPO=/microfish"
[ -d "${CARGO_HOME:-$HOME/.cargo}" ] && REMAP="$REMAP --remap-path-prefix=${CARGO_HOME:-$HOME/.cargo}=/cargo"
[ -d "${RUSTUP_HOME:-$HOME/.rustup}" ] && REMAP="$REMAP --remap-path-prefix=${RUSTUP_HOME:-$HOME/.rustup}=/rustup"
REMAP="$REMAP --remap-path-prefix=$HOME=/home"
JOBS=(); [ -z "${CI:-}" ] && JOBS=(-j "${MICROFISH_CARGO_JOBS:-2}")
( cd "$REPO" && RUSTFLAGS="${RUSTFLAGS:-} $REMAP" CARGO_TARGET_DIR="$TARGET_DIR" \
    nice -n 10 cargo build --release --locked "${JOBS[@]+"${JOBS[@]}"}" --features microfish \
      --bin paneru --bin paneru-navigator-command )

"$REPO/app/Scripts/check-engine-identity.sh" "$TARGET_DIR/release/paneru" "$ENGINE_ID"
