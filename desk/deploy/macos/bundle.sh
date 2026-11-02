#!/bin/bash
# Builds "WetOwl Desk.app" on a Mac (CI: .github/workflows/desk.yml, job macos):
# the Desk for Apple silicon and Intel in one program, the stage inside it, signed ad hoc.
#
#   deploy/macos/bundle.sh [STAGE_APP]
#
# STAGE_APP is a built WetOwl.app (flutter build macos in ../app), carried at
# Contents/Helpers/WetOwl.app — the window the Desk opens for the show
# (crates/wo-deskcore/src/stage.rs). It keeps the app's bundle id (io.wetowl.muse), so
# it shares the WetOwl app's sign-in and fetched records on that Mac. Without it the
# Desk looks for a WetOwl.app in ~/Applications or /Applications.
#
# Out: target/macos/WetOwl Desk.app and target/macos/wetowl-desk-macos.zip.
# Signed by no one (no paid Apple account): see install.sh for how a Mac opens it
# without an administrator.
set -euo pipefail
desk=$(cd "$(dirname "$0")/../.." && pwd)
cd "$desk"
stage="${1:-}"
export MACOSX_DEPLOYMENT_TARGET=11.0

targets=(aarch64-apple-darwin x86_64-apple-darwin)
for t in "${targets[@]}"; do
  cargo build --release -p wetowl-desk --target "$t"
done

out="$desk/target/macos"
app="$out/WetOwl Desk.app"
rm -rf "${app:?}"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

# Rust programs join into one universal file fine (unlike the Dart helpers of v1).
lipo -create -output "$app/Contents/MacOS/wetowl-desk" \
  "target/aarch64-apple-darwin/release/wetowl-desk" "target/x86_64-apple-darwin/release/wetowl-desk"
lipo -archs "$app/Contents/MacOS/wetowl-desk"

version=$(sed -n 's/^version = "\(.*\)"/\1/p' apps/wetowl-desk/Cargo.toml | head -1)
build="$(date -u +%Y%m%d%H%M)"
sed -e "s/__VERSION__/$version/" -e "s/__BUILD__/$build/" deploy/macos/Info.plist > "$app/Contents/Info.plist"
plutil -lint "$app/Contents/Info.plist"
printf '%s %s\n' "$(git rev-parse --short HEAD)" "$build" > "$app/Contents/Resources/build.txt"

# The icon, from the Linux launcher's 256 px picture.
set_dir="$out/AppIcon.iconset"
rm -rf "${set_dir:?}"
mkdir -p "$set_dir"
for s in 16 32 128 256; do
  sips -z $s $s deploy/icon-256.png --out "$set_dir/icon_${s}x${s}.png" >/dev/null
done
for s in 16 32 128; do
  sips -z $((s * 2)) $((s * 2)) deploy/icon-256.png --out "$set_dir/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$set_dir" -o "$app/Contents/Resources/AppIcon.icns"
rm -rf "${set_dir:?}"

if [ -n "$stage" ]; then
  mkdir -p "$app/Contents/Helpers"
  ditto "$stage" "$app/Contents/Helpers/WetOwl.app"
  lipo -archs "$app/Contents/Helpers/WetOwl.app/Contents/MacOS/WetOwl"
  # inside first, then the bundle around it (a seal over unsigned code is "damaged")
  codesign --force --sign - --entitlements ../app/macos/Runner/Release.entitlements "$app/Contents/Helpers/WetOwl.app"
fi
codesign --force --sign - --identifier io.wetowl.desk "$app"
codesign --verify --deep --strict --verbose=2 "$app"

# ditto keeps the frameworks' links and the signatures as they are
rm -f "$out/wetowl-desk-macos.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$out/wetowl-desk-macos.zip"
ls -lh "$out/wetowl-desk-macos.zip"
echo "WetOwl Desk $(cat "$app/Contents/Resources/build.txt") bundled in $app"
