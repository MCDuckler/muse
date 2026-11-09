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
  cargo build --release -p wetowl-desk -p wetowl-stage --target "$t"
done

out="$desk/target/macos"
app="$out/WetOwl Desk.app"
rm -rf "${app:?}"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

# Rust programs join into one universal file fine (unlike the Dart helpers of v1).
lipo -create -output "$app/Contents/MacOS/wetowl-desk" \
  "target/aarch64-apple-darwin/release/wetowl-desk" "target/x86_64-apple-darwin/release/wetowl-desk"
lipo -archs "$app/Contents/MacOS/wetowl-desk"
# the Rust stage beside it (the Desk directing; chosen on the Show page)
lipo -create -output "$app/Contents/MacOS/wetowl-stage" \
  "target/aarch64-apple-darwin/release/wetowl-stage" "target/x86_64-apple-darwin/release/wetowl-stage"
# the dancers the Rust stage draws (their scans, skeletons, moves)
rm -rf "$app/Contents/Resources/dance"
mkdir -p "$app/Contents/Resources/dance"
for d in ../app/assets/show/dance/*/; do
  m=$(basename "$d")
  mkdir -p "$app/Contents/Resources/dance/$m"
  cp "$d"dancer.json "$d"dancer.bin "$d"moves.bin "$d"skin.webp "$app/Contents/Resources/dance/$m/"
done

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
codesign --force --sign - --identifier io.wetowl.stage "$app/Contents/MacOS/wetowl-stage"
codesign --force --sign - --identifier io.wetowl.desk "$app"
codesign --verify --deep --strict --verbose=2 "$app"

# The download is portable: a folder "WetOwl Desk" holding the app and how to open it the
# first time. It runs from wherever it is unpacked (Downloads, the Desktop, a stick): the
# app finds its stage, MilkDrop and dancers inside itself and writes only to ~/Library.
port="$out/portable/WetOwl Desk"
rm -rf "${out:?}/portable"
mkdir -p "$port"
ditto "$app" "$port/WetOwl Desk.app"
cat > "$port/READ ME FIRST.txt" <<README
WetOwl Desk for Mac — build $(cat "$app/Contents/Resources/build.txt")

Nothing to install. Double-click WetOwl Desk.app here, or move this folder anywhere first
(the Desktop, Applications, a USB stick). Apple silicon and Intel, macOS 11 or newer.

THE FIRST TIME macOS stops it ("Apple could not verify…"), because the app is not signed
with a paid Apple developer account. Open it once in either way:

  A) Click Done. Open System Settings › Privacy & Security, scroll to
     "WetOwl Desk was blocked…" and click Open Anyway (it asks for your Mac's password).

  B) No password: open Terminal, type   xattr -dr com.apple.quarantine   (with a space
     at the end), drag WetOwl Desk.app into the Terminal window, press Return. Then
     double-click the app.

After that it opens like any other app.

Sign in with your WetOwl account. The show's stage window opens from the Show page.
Controllers (Pioneer DDJ-400, Hercules RMX) and rekordbox USB sticks need no driver.

Its log:       ~/Library/Logs/WetOwl Desk.log
Its settings:  ~/Library/Application Support/wetowl-desk
Newest build:  https://github.com/MCDuckler/muse/releases/download/wetowl-desk-macos/wetowl-desk-macos.zip
README

# ditto keeps the frameworks' links and the signatures as they are
rm -f "$out/wetowl-desk-macos.zip"
ditto -c -k --sequesterRsrc --keepParent "$port" "$out/wetowl-desk-macos.zip"
ls -lh "$out/wetowl-desk-macos.zip"
echo "WetOwl Desk $(cat "$app/Contents/Resources/build.txt") bundled in $app"
