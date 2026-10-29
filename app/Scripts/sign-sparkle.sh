#!/bin/zsh
# Sign a copy of Sparkle.framework inside-out, as Sparkle's documentation prescribes for a
# NON-sandboxed host app (https://sparkle-project.org/documentation/): helpers first, the framework last,
# hardened runtime on each, a secure timestamp unless the identity is "-" (ad hoc).
#
#   app/Scripts/sign-sparkle.sh <path/to/Sparkle.framework> <identity>
#
# <identity> is "-" for ad hoc, or a codesign identity name such as "Developer ID Application".
# Run it on the framework already embedded in the app (Contents/Frameworks/Sparkle.framework), then
# sign the app itself last. Never use `codesign --deep` on the app: it re-signs the inside-out result.
#
# The XPC services are only used by sandboxed hosts; Microfish is not sandboxed, so the app does not
# set SUEnableInstallerLauncherService and they sit unused. They are signed anyway so the bundle
# validates strictly and notarizes (the notary service rejects unsigned nested code).
set -eu
fw=${1:?usage: sign-sparkle.sh <Sparkle.framework> <identity>}
id=${2:?usage: sign-sparkle.sh <Sparkle.framework> <identity>}
[[ -d $fw/Versions/B ]] || { echo "not a Sparkle framework: $fw" >&2; exit 1; }
v=$fw/Versions/B

flags=(--force --options runtime --sign "$id")
[[ $id == - ]] || flags+=(--timestamp)

# Downloader.xpc carries the network-client entitlement Sparkle ships it with: keep it.
/usr/bin/codesign $flags --preserve-metadata=entitlements $v/XPCServices/Downloader.xpc
/usr/bin/codesign $flags $v/XPCServices/Installer.xpc
/usr/bin/codesign $flags $v/Autoupdate
/usr/bin/codesign $flags $v/Updater.app
/usr/bin/codesign $flags $fw

/usr/bin/codesign --verify --strict --deep --verbose=1 $fw
echo "signed $fw"
