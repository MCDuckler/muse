#!/bin/bash
# Installs WetOwl Desk (v2) for this user on Linux, beside the WetOwl app (v1), which it
# leaves alone: the binary in ~/.local/opt/wetowl-desk, the launcher io.wetowl.desk, the
# icon io.wetowl.desk. Run again to update; a running Desk keeps its old binary until
# it is restarted. Logs: ~/.local/state/wetowl-desk.log.
set -euo pipefail
desk=$(cd "$(dirname "$0")/.." && pwd)
cd "$desk"
cargo build --release -p wetowl-desk

dest="$HOME/.local/opt/wetowl-desk"
mkdir -p "$dest" "$HOME/.local/state" "$HOME/.local/share/applications" "$HOME/.local/share/icons/hicolor/256x256/apps"
# a new file renamed into place: replacing a running binary in place fails (text busy)
install -m 755 target/release/wetowl-desk "$dest/wetowl-desk.new"
mv -f "$dest/wetowl-desk.new" "$dest/wetowl-desk"
printf '%s %s\n' "$(git rev-parse --short HEAD)" "$(date -u +%Y%m%d%H%M)" > "$dest/build.txt"
install -m 644 deploy/icon-256.png "$HOME/.local/share/icons/hicolor/256x256/apps/io.wetowl.desk.png"

cat > "$HOME/.local/share/applications/io.wetowl.desk.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=WetOwl Desk
GenericName=DJ booth
Comment=The WetOwl booth, native (v2 preview)
Exec=sh -c "exec $dest/wetowl-desk >> $HOME/.local/state/wetowl-desk.log 2>&1"
Icon=io.wetowl.desk
Terminal=false
Categories=AudioVideo;Audio;Music;
Keywords=dj;booth;mix;wetowl;
StartupNotify=true
StartupWMClass=wetowl-desk
DESKTOP

update-desktop-database -q "$HOME/.local/share/applications" 2>/dev/null || true
gtk-update-icon-cache -q -f -t "$HOME/.local/share/icons/hicolor" 2>/dev/null || true
echo "WetOwl Desk $(cat "$dest/build.txt") installed in $dest"
