#!/bin/bash
# Installs the newest WetOwl Desk for Linux (the rolling release wetowl-desk-linux) for this
# user, no root: the folder in ~/.local/opt/wetowl-desk, a launcher io.wetowl.desk in the
# menu. Run again to reinstall; the Desk also updates itself (crates/wo-update).
#
#   curl -fsSL https://raw.githubusercontent.com/MCDuckler/muse/desk/desk/deploy/linux/install.sh | bash
#
# (On a machine where the Desk is built by hand, deploy/install-local.sh puts its own build in
# the same folder; such a build never updates itself.)
set -euo pipefail
url="https://github.com/MCDuckler/muse/releases/download/wetowl-desk-linux/wetowl-desk-linux.tar.gz"
dest="$HOME/.local/opt/wetowl-desk"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
echo "Fetching $url"
curl -fL --progress-bar "$url" -o "$tmp/desk.tar.gz"
tar -xzf "$tmp/desk.tar.gz" -C "$tmp"
[ -x "$tmp/wetowl-desk/wetowl-desk" ] || { echo "the download holds no Desk"; exit 1; }
mkdir -p "$dest" "$HOME/.local/state" "$HOME/.local/share/applications" "$HOME/.local/share/icons/hicolor/256x256/apps"
# each file renamed into place (a running Desk keeps its old program until it restarts)
for f in "$tmp/wetowl-desk"/* ; do
  n=$(basename "$f")
  rm -rf "$dest/$n.old"
  [ -e "$dest/$n" ] && mv "$dest/$n" "$dest/$n.old"
  mv "$f" "$dest/$n"
  rm -rf "$dest/$n.old" 2>/dev/null || true
done
install -m 644 "$dest/icon-256.png" "$HOME/.local/share/icons/hicolor/256x256/apps/io.wetowl.desk.png"
cat > "$HOME/.local/share/applications/io.wetowl.desk.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=WetOwl Desk
GenericName=DJ booth
Comment=The WetOwl booth
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
echo "WetOwl Desk $(cat "$dest/build.txt") installed in $dest — in your menu as WetOwl Desk"
