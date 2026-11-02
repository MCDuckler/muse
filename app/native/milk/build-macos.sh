#!/bin/bash
# MilkDrop's helper for a Mac: wetowl-milk and projectM, for Apple silicon and Intel
# in one file each, built here (build-macos/), and — given an app — put in its
# Contents/MacOS, where the app looks (lib/src/state/show/milk_feed.dart), signed ad
# hoc. Run on a Mac (CI: .github/workflows/desk.yml).
#
#   app/native/milk/build-macos.sh                 build only
#   app/native/milk/build-macos.sh <App.app>       build (if not built) and put in
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
build="$here/build-macos"
cmake -S "$here" -B "$build" -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0
cmake --build "$build" --config Release -j 4
helper="$build/wetowl-milk"
lipo -archs "$helper"
# projectM under the name the helper asks for (@rpath/libprojectM-4.N.dylib)
want=$(basename "$(otool -L "$helper" | awk '/projectM/ {print $1; exit}')")
lib=$(find "$build" -name "$want" | head -1)
[ -n "$lib" ] || { echo "no $want under $build" >&2; exit 1; }
echo "helper: $helper, projectM: $want"
[ $# -ge 1 ] || exit 0

dest="$1/Contents/MacOS"
[ -d "$dest" ] || { echo "not an app: $1" >&2; exit 1; }
cp "$helper" "$dest/wetowl-milk"
cp -L "$lib" "$dest/$want"
chmod 755 "$dest/wetowl-milk"
# each signed on its own; the app around them is signed after (bundle.sh, desktop.yml)
codesign --force --sign - "$dest/$want"
codesign --force --sign - --identifier io.wetowl.milk "$dest/wetowl-milk"
ls -l "$dest"
