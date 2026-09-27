#!/usr/bin/env bash
# The desktop app built here and installed for this user, for trying a change without
# a round trip through GitHub: deploy/desktop-local.sh [--debug]
#
# Lands in ~/.local/opt/wetowl (the bundle), ~/.local/bin/wetowl (a launcher) and a
# desktop entry, so it is in the menu and on the path. Points at the live house unless
# MUSE_SERVER says otherwise.
#
# The two helpers are built and put beside the app exactly as the release does it
# (.github/workflows/desktop.yml): wetowl-fetch, which keeps fetching with the window
# shut and leases the pool's jobs, and wetowl-separate, which takes records apart.
# The app and the fetcher look for them next to their own binary and nowhere else —
# an install without them leaves every split this computer asks for failing with
# "no separator for this computer", which is what the first version of this script
# did to a working machine.
set -euo pipefail
cd "$(dirname "$0")/../app"
mode=release
[ "${1:-}" = "--debug" ] && mode=debug
SERVER=${MUSE_SERVER:-https://89-58-49-140.nip.io}
stamp=$(date -u +%Y%m%d%H%M)
echo "== building ($mode) against $SERVER, build local-$stamp"
flutter build linux --$mode --dart-define=MUSE_SERVER="$SERVER" --dart-define=MUSE_BUILD="$stamp"
src=build/linux/x64/$mode/bundle
echo "$stamp" > "$src/build-stamp.txt"
echo "== building the helpers"
dart build cli --target bin/wetowl_fetch.dart -o build/fetcher
cp build/fetcher/bundle/bin/wetowl_fetch "$src/wetowl-fetch"
dart build cli --target bin/wetowl_separate.dart -o build/separator
cp build/separator/bundle/bin/wetowl_separate "$src/wetowl-separate"
chmod +x "$src/wetowl-fetch" "$src/wetowl-separate"
# Each has to start and say what it wants (they exit non-zero saying it, hence || true).
said="$("$src/wetowl-separate" 2>&1 || true)"
echo "$said" | grep -q 'usage: wetowl-separate' || { echo "the separator does not start: $said" >&2; exit 1; }
said="$("$src/wetowl-fetch" 2>&1 || true)"
echo "$said" | grep -q 'usage: wetowl-fetch' || { echo "the fetcher does not start: $said" >&2; exit 1; }
dst=$HOME/.local/opt/wetowl
mkdir -p "$dst" "$HOME/.local/bin" "$HOME/.local/share/applications" "$HOME/.local/share/icons/hicolor/512x512/apps"
rsync -a --delete "$src/" "$dst/"
# Removed first: a launcher that was left as a symlink into the bundle would be
# written *through*, and the app's own binary replaced with two lines of shell.
rm -f "$HOME/.local/bin/wetowl"
cat > "$HOME/.local/bin/wetowl" <<LAUNCH
#!/usr/bin/env bash
exec "$dst/wetowl" "\$@"
LAUNCH
chmod +x "$HOME/.local/bin/wetowl"
cp web/icons/Icon-512.png "$HOME/.local/share/icons/hicolor/512x512/apps/wetowl.png" 2>/dev/null || true
cat > "$HOME/.local/share/applications/wetowl.desktop" <<ENTRY
[Desktop Entry]
Type=Application
Name=WetOwl (local build)
Comment=The house, built from this checkout
Exec=$HOME/.local/bin/wetowl
Icon=wetowl
Terminal=false
Categories=AudioVideo;Audio;
ENTRY
command -v update-desktop-database >/dev/null && update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true
echo "== installed: run \`wetowl\` (log at ~/.local/share/io.wetowl.muse/wetowl.log or the app support dir)"
