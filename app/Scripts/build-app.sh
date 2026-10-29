#!/usr/bin/env bash
# Build, assemble, sign and verify Microfish.app.
#
#   app/Scripts/build-app.sh [--version vX.Y.Z[-beta.N]|dev] [--sign IDENTITY] [--out DIR]
#                            [--skip-engine-build | --engine PATH] [--sparkle DIR] [--package]
#                            [--strict] [--allow-placeholder-key] [--keychain PATH]
#   app/Scripts/build-app.sh --probe-min-macos
#
# Runs on a developer Mac and on a GitHub macOS runner. It never launches what it builds.
#
#   --version    release tag, or "dev" (default): version 0.0.0-dev, build 1. Rules live in version.py.
#   --sign       signing identity: a name, a hash, or "-" for ad-hoc. Default: $MICROFISH_SIGN_IDENTITY, else "-".
#   --out        output directory (default: <repo>/build). The app is <out>/Microfish.app.
#   --engine     use this prebuilt `paneru` (its sibling `paneru-navigator-command` is the bridge)
#   --skip-engine-build   use <cargo target dir>/release/ as it is
#   --sparkle    directory holding Sparkle.framework (default: $SPARKLE_DIR, else app/Vendor/Sparkle)
#   --package    also zip the app (package.sh)
#   --strict     fail on anything a release must not lack (always on for a version other than "dev")
#   --keychain   keychain to look the identity up in (default: the search list)
set -euo pipefail

# ---- the frozen identifiers (CONTRACT.md) and build constants --------------------------------------
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPTS="$REPO/app/Scripts"
PKG="$REPO/app/Packaging"
APP_ID="net.webreceptor.microfish"
ENGINE_ID="net.webreceptor.microfish.engine"
BRIDGE_ID="net.webreceptor.microfish.command"
ENGINE_LABEL="net.webreceptor.microfish.engine"
FEED_URL="https://raw.githubusercontent.com/elenaOnline/microfish/appcast/appcast.xml"
ENGINE_APP_NAME="Microfish Engine"
ENGINE_PROGRAM="Contents/Helpers/${ENGINE_APP_NAME}.app/Contents/MacOS/${ENGINE_APP_NAME}"
# Lowest macOS the helper compiles for. 15.0 because Settings.swift:527 uses
# NSToolbar.allowsDisplayModeCustomization (macOS 15); everything else compiles for 14.0.
# Re-measure with --probe-min-macos after changing sources. Tested on macOS 27 only.
MIN_MACOS="15.0"
PLACEHOLDER_KEY="PLACEHOLDER-SPARKLE-PUBLIC-KEY-NOT-FOR-RELEASE"
DEFAULT_SOURCES="main.swift TabBars.swift Settings.swift ShortcutRecorder.swift SpatialOverview.swift LiveSignals.swift Paths.swift"

VERSION="dev"; SIGN="${MICROFISH_SIGN_IDENTITY:--}"; OUT="$REPO/build"
ENGINE_BIN=""; SKIP_ENGINE=0; SPARKLE_ARG=""; DO_PACKAGE=0; STRICT=0; ALLOW_PLACEHOLDER=0
KEYCHAIN="${MICROFISH_KEYCHAIN:-}"; PROBE=0

say() { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() { printf 'build-app.sh: error: %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d;s/^# \{0,1\}//'; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --version) VERSION="${2:?--version needs a value}"; shift 2 ;;
    --sign) SIGN="${2:?--sign needs a value}"; shift 2 ;;
    --out) OUT="${2:?--out needs a value}"; shift 2 ;;
    --engine) ENGINE_BIN="${2:?--engine needs a path}"; shift 2 ;;
    --skip-engine-build) SKIP_ENGINE=1; shift ;;
    --sparkle) SPARKLE_ARG="${2:?--sparkle needs a directory}"; shift 2 ;;
    --package) DO_PACKAGE=1; shift ;;
    --strict) STRICT=1; shift ;;
    --allow-placeholder-key) ALLOW_PLACEHOLDER=1; shift ;;
    --keychain) KEYCHAIN="${2:?--keychain needs a path}"; shift 2 ;;
    --probe-min-macos) PROBE=1; shift ;;
    -h|--help) usage 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

[ "$(uname -s)" = Darwin ] || die "this builds a macOS app and must run on macOS"
[ "$(uname -m)" = arm64 ] || die "arm64 only (Apple silicon host)"
[ "$VERSION" = dev ] || STRICT=1

# ---- helper sources and Sparkle ---------------------------------------------------------------------
helper_sources() {
  local list="$REPO/app/Sources/SOURCES" f found=()
  if [ -f "$list" ]; then
    while IFS= read -r f || [ -n "$f" ]; do
      f="${f%%#*}"; f="$(echo "$f" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
      [ -n "$f" ] && found+=("$REPO/app/Sources/$f")
    done < "$list"
  else
    for f in $DEFAULT_SOURCES; do found+=("$REPO/app/Sources/$f"); done
  fi
  printf '%s\n' "${found[@]}"
}

find_sparkle() { # prints the Sparkle.framework directory, or nothing
  local base="${SPARKLE_ARG:-${SPARKLE_DIR:-$REPO/app/Vendor/Sparkle}}"
  [ -d "$base" ] || return 0
  if [ "$(basename "$base")" = Sparkle.framework ]; then echo "$base"; return 0; fi
  find "$base" -maxdepth 3 -name Sparkle.framework -type d -not -path '*/Symbols/*' 2>/dev/null | head -n 1
}

if [ "$PROBE" = 1 ]; then
  fw="$(find_sparkle)"; fflags=()
  [ -n "$fw" ] && fflags=(-F "$(dirname "$fw")" -framework Sparkle)
  srcs=(); while IFS= read -r s; do srcs+=("$s"); done < <(helper_sources)
  lowest=""
  for t in 12.0 13.0 14.0 15.0 26.0; do
    if swiftc -typecheck -target "arm64-apple-macos$t" "${srcs[@]}" "${fflags[@]+"${fflags[@]}"}" >/dev/null 2>/tmp/probe.$$; then
      echo "macOS $t: compiles"; lowest="${lowest:-$t}"
    else
      echo "macOS $t: $(grep -m1 'error:' /tmp/probe.$$ | sed 's|.*/||')"
    fi
  done
  rm -f /tmp/probe.$$
  echo "lowest deployment target that compiles: ${lowest:-none} (script constant MIN_MACOS=$MIN_MACOS)"
  exit 0
fi

# ---- version ----------------------------------------------------------------------------------------
VERSION_FIELDS="$(python3 -I "$SCRIPTS/version.py" "$VERSION" --env)" || die "bad --version '$VERSION'"
eval "$VERSION_FIELDS"
SHORT_VERSION="$SHORT"; BUILD_VERSION="$BUILD"
say "Microfish $SHORT_VERSION (build $BUILD_VERSION, $CHANNEL), macOS $MIN_MACOS+, identity: $([ "$SIGN" = - ] && echo ad-hoc || echo "$SIGN")"

# ---- the signing identity -----------------------------------------------------------------------------
ADHOC=0; [ "$SIGN" = - ] && ADHOC=1
KC_ARGS=(); [ -n "$KEYCHAIN" ] && KC_ARGS=(--keychain "$KEYCHAIN")
resolve_identity() {
  # A name that matches several certificates makes codesign refuse ("ambiguous"). Resolve it to the
  # hash of the one certificate here; the hash is looked up at build time, never stored in the repo.
  local want="$1" lines hashes n
  lines="$(security find-identity -v -p codesigning ${KEYCHAIN:+"$KEYCHAIN"} | grep -F "\"" | grep -F -- "$want" || true)"
  [ -n "$lines" ] || die "no valid code-signing identity matches '$want' ($(security find-identity -v -p codesigning ${KEYCHAIN:+"$KEYCHAIN"} | tail -n 1))"
  hashes="$(echo "$lines" | awk '{print $2}' | sort -u)"; n="$(echo "$hashes" | wc -l | tr -d ' ')"
  if [ "$n" -gt 1 ]; then
    warn "'$want' matches $n certificates; using the first. Pass a hash or a longer name to choose."
  fi
  echo "$lines" | awk '{print $2}' | head -n 1
}
if [ "$ADHOC" = 0 ]; then
  if ! echo "$SIGN" | grep -Eq '^[0-9A-Fa-f]{40}$'; then SIGN_ID="$(resolve_identity "$SIGN")"; else SIGN_ID="$SIGN"; fi
else
  SIGN_ID="-"
fi

# ---- engine -----------------------------------------------------------------------------------------
export MACOSX_DEPLOYMENT_TARGET="$MIN_MACOS"   # so the Rust and LuaJIT objects carry the same minos
TARGET_DIR="${CARGO_TARGET_DIR:-$REPO/target}"
if [ -z "$ENGINE_BIN" ]; then
  if [ "$SKIP_ENGINE" = 0 ]; then
    say "cargo build --release (paneru, paneru-navigator-command)"
    # Build paths stay out of the binaries: panic locations would otherwise carry the builder's home directory.
    REMAP="--remap-path-prefix=$REPO=/microfish"
    [ -d "${CARGO_HOME:-$HOME/.cargo}" ] && REMAP="$REMAP --remap-path-prefix=${CARGO_HOME:-$HOME/.cargo}=/cargo"
    [ -d "${RUSTUP_HOME:-$HOME/.rustup}" ] && REMAP="$REMAP --remap-path-prefix=${RUSTUP_HOME:-$HOME/.rustup}=/rustup"
    REMAP="$REMAP --remap-path-prefix=$HOME=/home"
    JOBS=(); [ -z "${CI:-}" ] && JOBS=(-j "${MICROFISH_CARGO_JOBS:-2}")
    # The engine's own identity (embedded Info.plist), when the crate has the feature.
    FEATURES=(); grep -Eq '^microfish[[:space:]]*=' "$REPO/Cargo.toml" && FEATURES=(--features microfish)
    ( cd "$REPO" && RUSTFLAGS="${RUSTFLAGS:-} $REMAP" CARGO_TARGET_DIR="$TARGET_DIR" \
        nice -n 10 cargo build --release --locked "${JOBS[@]+"${JOBS[@]}"}" "${FEATURES[@]+"${FEATURES[@]}"}" --bin paneru --bin paneru-navigator-command )
  fi
  ENGINE_BIN="$TARGET_DIR/release/paneru"
fi
BRIDGE_BIN="$(dirname "$ENGINE_BIN")/paneru-navigator-command"
[ -x "$ENGINE_BIN" ] || die "engine binary not found: $ENGINE_BIN"
[ -x "$BRIDGE_BIN" ] || die "bridge binary not found: $BRIDGE_BIN"

# ---- output tree ------------------------------------------------------------------------------------
mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"
APP="$OUT/Microfish.app"; WORK="$OUT/.work"
rm -rf "$APP" "$WORK"; mkdir -p "$WORK"
C="$APP/Contents"
ENGINE_APP="$C/Helpers/${ENGINE_APP_NAME}.app"
mkdir -p "$C/MacOS" "$C/Resources/Credits" "$C/Frameworks" "$C/Library/LaunchAgents" \
         "$ENGINE_APP/Contents/MacOS" "$ENGINE_APP/Contents/Resources"

subst() { # subst TEMPLATE OUTFILE KEY=VALUE...  (replaces @KEY@; a KEY that starts with "__" is replaced as written)
  local in="$1" out="$2" kv k v; shift 2
  cp "$in" "$out"
  for kv in "$@"; do
    k="${kv%%=*}"; v="${kv#*=}"
    v="$(printf '%s' "$v" | sed -e 's/[\\&|]/\\&/g')"
    case "$k" in __*) sed -i '' "s|${k}|${v}|g" "$out" ;; *) sed -i '' "s|@${k}@|${v}|g" "$out" ;; esac
  done
}
plist_set() { # plist_set FILE KEY TYPE VALUE
  /usr/libexec/PlistBuddy -c "Set :$2 $4" "$1" 2>/dev/null || /usr/libexec/PlistBuddy -c "Add :$2 $3 $4" "$1"
}

# ---- helper (main executable) -----------------------------------------------------------------------
SPARKLE_FW="$(find_sparkle)"
srcs=(); while IFS= read -r s; do srcs+=("$s"); done < <(helper_sources)
for s in "${srcs[@]}"; do [ -f "$s" ] || die "listed helper source is missing: $s"; done
SWIFT_LINK=(-framework AppKit -framework QuartzCore -framework ServiceManagement)
if [ -n "$SPARKLE_FW" ]; then
  SWIFT_LINK+=(-F "$(dirname "$SPARKLE_FW")" -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks)
else
  [ "$STRICT" = 1 ] && die "Sparkle.framework not found (looked in: ${SPARKLE_ARG:-${SPARKLE_DIR:-$REPO/app/Vendor/Sparkle}}); run app/Scripts/fetch-sparkle.sh or pass --sparkle"
  warn "Sparkle.framework not found: building the helper without it (dev build; updates not available)"
fi
say "swiftc helper (${#srcs[@]} files, -target arm64-apple-macos$MIN_MACOS)"
swiftc -O -wmo -target "arm64-apple-macos$MIN_MACOS" -module-name Microfish -file-prefix-map "$REPO=/microfish" \
  "${srcs[@]}" "${SWIFT_LINK[@]}" -o "$C/MacOS/Microfish" 2>"$WORK/swiftc.log" || { cat "$WORK/swiftc.log" >&2; die "swiftc failed"; }
echo "  swiftc: $(grep -c 'warning:' "$WORK/swiftc.log" || true) warnings (log: .work/swiftc.log)"

# ---- engine app, bridge ------------------------------------------------------------------------------
install -m 755 "$ENGINE_BIN" "$ENGINE_APP/Contents/MacOS/$ENGINE_APP_NAME"
install -m 755 "$BRIDGE_BIN" "$C/MacOS/microfish-command"
if [ -f "$PKG/Engine-Info.plist" ]; then
  subst "$PKG/Engine-Info.plist" "$ENGINE_APP/Contents/Info.plist" \
    "SHORT_VERSION=$SHORT_VERSION" "BUILD_VERSION=$BUILD_VERSION" "MIN_MACOS=$MIN_MACOS" "ENGINE_ID=$ENGINE_ID" \
    "__SHORT_VERSION__=$SHORT_VERSION" "__BUILD__=$BUILD_VERSION"
else
  warn "app/Packaging/Engine-Info.plist is missing: generating a minimal one"
  cat > "$ENGINE_APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>$ENGINE_APP_NAME</string>
<key>CFBundleIdentifier</key><string>$ENGINE_ID</string>
<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
<key>CFBundleName</key><string>Microfish</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
fi
EI="$ENGINE_APP/Contents/Info.plist"
plist_set "$EI" CFBundleShortVersionString string "$SHORT_VERSION"
plist_set "$EI" CFBundleVersion string "$BUILD_VERSION"
plist_set "$EI" LSMinimumSystemVersion string "$MIN_MACOS"
/usr/libexec/PlistBuddy -c "Print :CFBundleIconFile" "$EI" >/dev/null 2>&1 || plist_set "$EI" CFBundleIconFile string AppIcon

# ---- main Info.plist, launch agent --------------------------------------------------------------------
PUBKEY="$PLACEHOLDER_KEY"
if [ -f "$PKG/sparkle-public-key.txt" ]; then
  PUBKEY="$(tr -d '[:space:]' < "$PKG/sparkle-public-key.txt")"
  [ "$(printf '%s' "$PUBKEY" | base64 -D 2>/dev/null | wc -c | tr -d ' ')" = 32 ] || die "app/Packaging/sparkle-public-key.txt is not a base64 32-byte EdDSA public key"
elif [ "$STRICT" = 1 ] && [ "$ALLOW_PLACEHOLDER" = 0 ]; then
  die "app/Packaging/sparkle-public-key.txt is missing: a release must carry the real SUPublicEDKey (generate_keys -p prints it)"
else
  warn "no app/Packaging/sparkle-public-key.txt: Info.plist gets a placeholder SUPublicEDKey (never releasable)"
fi
subst "$PKG/Info.plist" "$C/Info.plist" \
  "APP_ID=$APP_ID" "SHORT_VERSION=$SHORT_VERSION" "BUILD_VERSION=$BUILD_VERSION" "MIN_MACOS=$MIN_MACOS" \
  "FEED_URL=$FEED_URL" "SPARKLE_PUBLIC_KEY=$PUBKEY"
subst "$PKG/LaunchAgent.plist.in" "$C/Library/LaunchAgents/${ENGINE_LABEL}.plist" \
  "ENGINE_LABEL=$ENGINE_LABEL" "ENGINE_PROGRAM=$ENGINE_PROGRAM" "APP_ID=$APP_ID"
printf 'APPL????' > "$C/PkgInfo"

# ---- resources ----------------------------------------------------------------------------------------
say "icon, Lua, defaults, credits"
ICONSET="$WORK/AppIcon.iconset"; mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$REPO/app/Resources/AppIcon.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z $((size*2)) $((size*2)) "$REPO/app/Resources/AppIcon.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$C/Resources/AppIcon.icns"
cp "$C/Resources/AppIcon.icns" "$ENGINE_APP/Contents/Resources/AppIcon.icns"

copy_required() { # copy_required SRC DEST-IN-RESOURCES
  if [ -e "$1" ]; then ditto "$1" "$C/Resources/$2"
  elif [ "$STRICT" = 1 ]; then die "missing ${1#$REPO/}"
  else warn "missing ${1#$REPO/}: not included (dev build)"; fi
}
copy_required "$REPO/app/Resources/Lua" Lua
copy_required "$REPO/app/Resources/Defaults" Defaults
copy_required "$REPO/app/Resources/shortcut-defaults.json" shortcut-defaults.json

cp "$REPO/LICENSE.txt" "$C/Resources/Credits/LICENSE.txt"
if [ -n "$SPARKLE_FW" ] && [ -f "$(dirname "$SPARKLE_FW")/LICENSE" ]; then
  cp "$(dirname "$SPARKLE_FW")/LICENSE" "$C/Resources/Credits/Sparkle-LICENSE.txt"
elif [ -n "$SPARKLE_FW" ]; then
  [ "$STRICT" = 1 ] && die "Sparkle's LICENSE not found next to Sparkle.framework"; warn "Sparkle's LICENSE not found"
fi
python3 -I "$SCRIPTS/licenses.py" --manifest-path "$REPO/Cargo.toml" --out "$C/Resources/Credits/RustDependencies.txt" \
  || die "could not list Rust dependency licenses"

if [ -n "$SPARKLE_FW" ]; then
  say "Sparkle.framework $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SPARKLE_FW/Resources/Info.plist")"
  ditto "$SPARKLE_FW" "$C/Frameworks/Sparkle.framework"
else
  rmdir "$C/Frameworks"
fi
xattr -cr "$APP"

# ---- signing (inside-out) ------------------------------------------------------------------------------
TS=(--timestamp); [ "$ADHOC" = 1 ] && TS=(--timestamp=none)
SIGNED_LIST="$WORK/signed.txt"; : > "$SIGNED_LIST"
sign_one() { # sign_one PATH IDENTIFIER|- [ENTITLEMENTS|-] [extra codesign args...]
  local path="$1" ident="$2" ent="${3:--}" args
  shift 3 || shift $#
  args=(--force --sign "$SIGN_ID" -o runtime "${TS[@]}")
  [ ${#KC_ARGS[@]} -gt 0 ] && args+=("${KC_ARGS[@]}")
  [ "$ident" != - ] && args+=(--identifier "$ident")
  [ "$ent" != - ] && args+=(--entitlements "$ent")
  [ $# -gt 0 ] && args+=("$@")
  codesign "${args[@]}" "$path" 2>"$WORK/codesign.err" || { cat "$WORK/codesign.err" >&2; die "codesign failed for ${path#$APP/}"; }
  echo "$path" >> "$SIGNED_LIST"
}
existing_identifier() { codesign -d "$1" 2>&1 | sed -n 's/^Identifier=//p' | head -n 1; }

# Entitlements. An ad-hoc build has no team, so library validation would refuse to load the (also
# ad-hoc) Sparkle.framework: ad-hoc builds only get disable-library-validation; releases never do.
write_ents() { # write_ents OUT [key...]  (boolean entitlements set to true)
  local out="$1" k; shift
  { echo '<?xml version="1.0" encoding="UTF-8"?>'
    echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
    echo '<plist version="1.0"><dict>'
    for k in "$@"; do echo "<key>$k</key><true/>"; done
    echo '</dict></plist>'; } > "$out"
}
APP_ENT="$WORK/App.entitlements"; ENGINE_ENT="$WORK/Engine.entitlements"
if [ -f "$PKG/App.entitlements" ]; then cp "$PKG/App.entitlements" "$APP_ENT"; else write_ents "$APP_ENT"; fi
if [ -f "$PKG/Engine.entitlements" ]; then cp "$PKG/Engine.entitlements" "$ENGINE_ENT"
else warn "app/Packaging/Engine.entitlements is missing: using allow-unsigned-executable-memory (LuaJIT)"; write_ents "$ENGINE_ENT" com.apple.security.cs.allow-unsigned-executable-memory; fi
if [ "$ADHOC" = 1 ]; then
  for f in "$APP_ENT" "$ENGINE_ENT"; do
    /usr/libexec/PlistBuddy -c "Add :com.apple.security.cs.disable-library-validation bool true" "$f" 2>/dev/null || true
  done
fi
plutil -lint "$APP_ENT" "$ENGINE_ENT" >/dev/null

say "codesign ($([ "$ADHOC" = 1 ] && echo ad-hoc || echo 'Developer ID, timestamped'), hardened runtime)"
if [ -d "$C/Frameworks/Sparkle.framework" ]; then
  FW="$(cd "$C/Frameworks/Sparkle.framework/Versions/Current" && pwd -P)"
  # Sparkle's documented order: XPC services, Autoupdate, Updater.app, then the framework. Each keeps its
  # own identifier and entitlements (Downloader.xpc carries the network entitlement).
  for x in "$FW"/XPCServices/*.xpc "$FW/Autoupdate" "$FW/Updater.app"; do
    [ -e "$x" ] || continue
    sign_one "$x" "$(existing_identifier "$x")" - --preserve-metadata=entitlements
  done
  sign_one "$C/Frameworks/Sparkle.framework" "$(existing_identifier "$C/Frameworks/Sparkle.framework")" -
fi
sign_one "$ENGINE_APP" "$ENGINE_ID" "$ENGINE_ENT"
sign_one "$C/MacOS/microfish-command" "$BRIDGE_ID" -
sign_one "$APP" "$APP_ID" "$APP_ENT"

# ---- verification ---------------------------------------------------------------------------------------
say "verify"
fail=0
bad() { printf 'VERIFY FAILED: %s\n' "$*" >&2; fail=1; }
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | grep -v '^--' | sed 's/^/  /' || true
codesign --verify --deep --strict "$APP" 2>/dev/null || bad "codesign --verify --deep --strict"
for pair in "$APP:$APP_ID" "$ENGINE_APP:$ENGINE_ID" "$C/MacOS/microfish-command:$BRIDGE_ID"; do
  p="${pair%%:*}"; id="${pair##*:}"; name="${p#$OUT/}"
  info="$(codesign -d --verbose=4 "$p" 2>&1)"
  echo "$info" | grep -qx "Identifier=$id" || bad "$name: signing identifier is not $id"
  echo "$info" | grep -Eq '^CodeDirectory .*flags=0x[0-9a-f]+\(.*runtime' || bad "$name: hardened runtime flag is missing"
  dr="$(codesign -d -r- "$p" 2>&1 | sed -n 's/^designated => //p')"
  if [ "$ADHOC" = 0 ]; then
    echo "$dr" | grep -Fq "identifier \"$id\"" || bad "$name: designated requirement lacks identifier $id"
    echo "$dr" | grep -Fq 'anchor apple generic' || bad "$name: designated requirement lacks 'anchor apple generic'"
    echo "$dr" | grep -Fq 'certificate leaf[subject.OU]' || bad "$name: designated requirement lacks the team (leaf[subject.OU])"
    echo "$dr" | grep -Fq cdhash && bad "$name: designated requirement is a cdhash"
  fi
  echo "  $name: $id; DR: $([ "$ADHOC" = 1 ] && echo '(ad-hoc: cdhash)' || echo "$dr" | sed 's/certificate 1\[[^]]*\] \/\* exists \*\/ and //;s/certificate leaf\[field[^]]*\] \/\* exists \*\/ and //;s/(\(leaf\[subject.OU\] = \)[A-Z0-9]*/\1<team>/;s/leaf\[subject.OU\] = [A-Z0-9]*/leaf[subject.OU] = <team>/')"
done
if [ "$ADHOC" = 0 ]; then   # one team across everything that was signed, including Sparkle's internals
  teams="$(while IFS= read -r p; do codesign -d --verbose=2 "$p" 2>&1 </dev/null | sed -n 's/^TeamIdentifier=//p'; done < "$SIGNED_LIST" | sort -u)"
  [ "$(echo "$teams" | wc -l | tr -d ' ')" = 1 ] && [ -n "$teams" ] && [ "$teams" != "not set" ] || bad "signed components do not share one team identifier"
  while IFS= read -r p; do
    info="$(codesign -d --verbose=4 "$p" 2>&1 </dev/null)"
    echo "$info" | grep -q '^Timestamp=' || bad "${p#$OUT/}: no secure timestamp"
  done < "$SIGNED_LIST"
fi
find "$APP" \( -name '*.plist' -o -name '*.entitlements' \) -not -path '*/Sparkle.framework/*' -print0 | xargs -0 plutil -lint >/dev/null || bad "plutil -lint"
echo "  plutil -lint: Info.plist x2, launch agent, entitlements OK"
AGENT="$C/Library/LaunchAgents/${ENGINE_LABEL}.plist"
bp="$(/usr/libexec/PlistBuddy -c 'Print :BundleProgram' "$AGENT")"
[ -x "$APP/$bp" ] || bad "launch agent BundleProgram is not an executable: $bp"
[ "$(/usr/libexec/PlistBuddy -c 'Print :Label' "$AGENT")" = "$ENGINE_LABEL" ] || bad "launch agent Label"
[ "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$C/Info.plist")" = "$MIN_MACOS" ] || bad "LSMinimumSystemVersion"
echo "  launch agent BundleProgram -> $bp (executable)"
if grep -rIl '/Users/' "$C/Info.plist" "$ENGINE_APP/Contents/Info.plist" "$AGENT" "$C/Resources/Lua" "$C/Resources/Defaults" "$C/Resources/shortcut-defaults.json" 2>/dev/null; then
  bad "an absolute /Users/ path in a plist, Lua or defaults file"
fi
for b in "$C/MacOS/Microfish" "$C/MacOS/microfish-command" "$ENGINE_APP/Contents/MacOS/$ENGINE_APP_NAME"; do
  n="$(strings -a "$b" | grep -c '/Users/' || true)"
  [ "$n" = 0 ] || bad "${b#$OUT/}: $n strings contain /Users/ (a build path leaked)"
  minos="$(otool -l "$b" | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}')"
  [ "$(printf '%s\n%s\n' "$minos" "$MIN_MACOS" | sort -V | tail -n 1)" = "$MIN_MACOS" ] || bad "${b#$OUT/}: minos $minos is above $MIN_MACOS"
  echo "  ${b#$OUT/}: arm64, minos $minos, no /Users/ strings"
done
if [ "$STRICT" = 1 ]; then
  grep -q "$PLACEHOLDER_KEY" "$C/Info.plist" && [ "$ALLOW_PLACEHOLDER" = 0 ] && bad "SUPublicEDKey is the placeholder"
  [ -d "$C/Frameworks/Sparkle.framework" ] || bad "Sparkle.framework is not in the bundle"
fi
[ "$fail" = 0 ] || die "verification failed"
say "built $APP"

if [ "$DO_PACKAGE" = 1 ]; then "$SCRIPTS/package.sh" "$APP" --out "$OUT"; fi
