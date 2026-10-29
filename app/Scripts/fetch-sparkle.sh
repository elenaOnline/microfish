#!/bin/zsh
# Download the pinned Sparkle release, verify its SHA-256, and extract it to app/Vendor/Sparkle/
# (gitignored). Refuses on any mismatch and leaves the previous extraction untouched.
#
#   app/Scripts/fetch-sparkle.sh            # no-op when app/Vendor/Sparkle already matches the pin
#   app/Scripts/fetch-sparkle.sh --force    # fetch again
#
# Result: app/Vendor/Sparkle/{Sparkle.framework,bin/{generate_keys,sign_update,generate_appcast},VERSION}.
# Only the framework and bin/ are kept; the sample app, symbols and old DSA scripts are dropped.
set -eu
here=${0:A:h}; vendor=$here/../Vendor; lock=$vendor/sparkle.lock; dest=$vendor/Sparkle
source $lock
: ${SPARKLE_VERSION:?} ${SPARKLE_URL:?} ${SPARKLE_SHA256:?}

if [[ "${1:-}" != --force && -f $dest/VERSION && "$(<$dest/VERSION)" == "$SPARKLE_VERSION $SPARKLE_SHA256" && -d $dest/Sparkle.framework ]]; then
  echo "Sparkle $SPARKLE_VERSION already in place"; exit 0
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/sparkle-fetch.XXXXXX")   # an empty directory of its own
trap 'rm -rf "$work"' EXIT
archive=$work/Sparkle-$SPARKLE_VERSION.tar.xz
echo "Downloading $SPARKLE_URL"
/usr/bin/curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 -o $archive $SPARKLE_URL
actual=$(/usr/bin/shasum -a 256 $archive | awk '{print $1}')
if [[ $actual != $SPARKLE_SHA256 ]]; then
  echo "SHA-256 mismatch for Sparkle-$SPARKLE_VERSION.tar.xz" >&2
  echo "  expected $SPARKLE_SHA256" >&2
  echo "  actual   $actual" >&2
  echo "Refusing to extract." >&2
  exit 1
fi
mkdir $work/x
/usr/bin/tar -xf $archive -C $work/x
[[ -d $work/x/Sparkle.framework && -x $work/x/bin/sign_update ]] || { echo "unexpected archive layout" >&2; exit 1; }

rm -rf $dest.new; mkdir -p $dest.new
# ditto keeps the framework's Versions/Current symlinks.
/usr/bin/ditto $work/x/Sparkle.framework $dest.new/Sparkle.framework
mkdir $dest.new/bin
for tool in generate_keys sign_update generate_appcast; do cp $work/x/bin/$tool $dest.new/bin/; done
cp $work/x/LICENSE $dest.new/LICENSE
echo "$SPARKLE_VERSION $SPARKLE_SHA256" > $dest.new/VERSION
rm -rf $dest; mv $dest.new $dest
echo "Sparkle $SPARKLE_VERSION extracted to app/Vendor/Sparkle"
