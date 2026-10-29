#!/bin/zsh
# Render the Settings > Updates pane (light and dark, several states) off screen.
#   app/Tests/updates-pane/build.sh [out-dir]
# Compiles the real Settings sources against a fixture root, parks the window at x=-40000 (never key, never
# on a display) and captures it with CGWindowListCreateImage. No Sparkle needed: the pane only reads UpdateModel.
set -e
here=${0:A:h}; src=$here/../../Sources; out=${1:-/tmp/mf-updates-pane-out}
work=$(mktemp -d /tmp/mf-updates-pane.XXXXXX); trap 'rm -rf $work' EXIT
mkdir -p $work/root/config; cp $here/../../Resources/shortcut-defaults.json $work/root/config/; echo '{}' > $work/root/config/preferences.json
# Drop main.swift's top-level launch block (the parser rejects it even when compiled out).
awk '/^#if !NAVIGATOR_TESTS$/{getline n; if (n ~ /^let app=/) {skip=1} else {print; print n; next}} skip && /^#endif/{skip=0; next} !skip' $src/main.swift > $work/NavigatorCore.swift
swiftc -parse-as-library -D NAVIGATOR_TESTS -D SETTINGS_TESTS -o $work/render \
  $work/NavigatorCore.swift $src/TabBars.swift $src/SpatialOverview.swift $src/Settings.swift $src/ShortcutRecorder.swift $src/LiveSignals.swift \
  $src/UpdateModel.swift $src/UpdatesPane.swift $here/WindowCapture.swift $here/render-main.swift -framework AppKit -framework SwiftUI -framework QuartzCore
states=(updates updates-all-on updates-checks-off updates-checking updates-update-waiting updates-unavailable updates-with-unapplied-draft behavior-footer-for-comparison)
# One process per image: NSSwitch's knob and disabled fade lag by one capture when states share a process.
for look in light dark; do for st in $states; do
  if [[ $# -gt 1 && ! " ${*:2} " == *" $look-$st "* ]]; then continue; fi
  $work/render $work/root $out $look-$st | grep -v preflight
done; done
