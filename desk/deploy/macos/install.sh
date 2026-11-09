#!/bin/bash
# WetOwl Desk on a Mac, for this user only: no administrator, no password, no
# System Settings. In Terminal:
#
#   curl -fsSL https://raw.githubusercontent.com/MCDuckler/muse/desk/desk/deploy/macos/install.sh | bash
#
# Run it again to update. It puts "WetOwl Desk.app" in ~/Applications (your own
# Applications folder; Launchpad and Spotlight find it there) and opens it. Without
# installing at all: the same zip unpacked anywhere runs as it is (its READ ME FIRST.txt).
#
# Why this works without an administrator: macOS refuses an app signed by no one
# ("unidentified developer") only when the file carries the quarantine mark, which a
# browser, Mail or AirDrop adds to a download. curl adds none, and the mark is cleared
# below anyway. Clearing it on files you own needs no administrator either.
#
# WETOWL_DESK_ZIP=<url or file> installs another build (a CI artifact, say).
set -euo pipefail

src="${WETOWL_DESK_ZIP:-https://github.com/MCDuckler/muse/releases/download/wetowl-desk-macos/wetowl-desk-macos.zip}"
dest="$HOME/Applications"
name="WetOwl Desk.app"

tmp=$(mktemp -d)
trap 'rm -rf "${tmp:?}"' EXIT

if [ -f "$src" ]; then
  cp "$src" "$tmp/desk.zip"
else
  echo "Fetching WetOwl Desk…"
  curl -fL --progress-bar "$src" -o "$tmp/desk.zip"
fi
ditto -x -k "$tmp/desk.zip" "$tmp/x"
# the app at the top (builds before 2026-11-09), or in the portable folder "WetOwl Desk"
new="$tmp/x/$name"
[ -d "$new" ] || new="$tmp/x/WetOwl Desk/$name"
[ -d "$new" ] || { echo "That download holds no $name." >&2; exit 1; }
xattr -dr com.apple.quarantine "$new" 2>/dev/null || true
codesign --verify --deep --strict "$new" || { echo "The download's signature does not hold; not installing it." >&2; exit 1; }

# A Desk that is open is asked to quit first (its stage window goes with it).
if pgrep -xq wetowl-desk; then
  echo "Quitting the open WetOwl Desk…"
  osascript -e 'quit app "WetOwl Desk"' >/dev/null 2>&1 || true
  for _ in $(seq 20); do pgrep -xq wetowl-desk || break; sleep 0.5; done
  pgrep -xq wetowl-desk && pkill -x wetowl-desk || true
fi

mkdir -p "$dest"
if [ -d "$dest/$name" ]; then
  rm -rf "${dest:?}/$name.old"
  mv "$dest/$name" "$dest/$name.old"
fi
mv "$new" "$dest/$name"
rm -rf "${dest:?}/$name.old"

echo "WetOwl Desk $(cat "$dest/$name/Contents/Resources/build.txt" 2>/dev/null) is in $dest."
echo "Its log: ~/Library/Logs/WetOwl Desk.log"
open "$dest/$name"
