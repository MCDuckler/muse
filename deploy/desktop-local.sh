#!/usr/bin/env bash
# The desktop app built here and installed for this user, for trying a change without
# a round trip through GitHub: deploy/desktop-local.sh [--debug]
#
# Lands in ~/.local/opt/wetowl (the bundle), ~/.local/bin/wetowl (a launcher) and a
# desktop entry, so it is in the menu and on the path. Points at the live house unless
# MUSE_SERVER says otherwise. The fetcher and the separator helpers are not built
# (the app starts them from the release download when it needs them).
set -euo pipefail
cd "$(dirname "$0")/../app"
mode=release
[ "${1:-}" = "--debug" ] && mode=debug
SERVER=${MUSE_SERVER:-https://89-58-49-140.nip.io}
stamp=$(date -u +%Y%m%d%H%M)
echo "== building ($mode) against $SERVER, build local-$stamp"
flutter build linux --$mode --dart-define=MUSE_SERVER="$SERVER" --dart-define=MUSE_BUILD="$stamp"
src=build/linux/x64/$mode/bundle
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
