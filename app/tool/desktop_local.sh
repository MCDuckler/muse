#!/usr/bin/env bash
# A desktop build of what is on this disk, for looking at while working on it — the
# same flags the release build uses, without the ten minutes and the push. Builds
# (release, so the light layer runs at the speed it ships at), then starts it.
#
#   app/tool/desktop_local.sh            build and run
#   app/tool/desktop_local.sh --no-run   build only
#   MUSE_SERVER=http://localhost:8000 app/tool/desktop_local.sh
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.local/flutter/bin:$PATH"

server=${MUSE_SERVER:-https://89-58-49-140.nip.io}
stamp="local-$(date +%Y%m%d%H%M)"
echo "== building $stamp against $server"
flutter build linux --release \
  --dart-define=MUSE_SERVER="$server" \
  --dart-define=MUSE_BUILD="$stamp"

bin=build/linux/x64/release/bundle/wetowl
# No build-stamp.txt beside it: the updater reads that, and a local build is not a
# release it knows.
rm -f build/linux/x64/release/bundle/build-stamp.txt
echo "== $bin"
[ "${1:-}" = "--no-run" ] && exit 0
# Its own log, so a crash has somewhere to be read from.
log=build/wetowl-local.log
echo "== running, log in $log"
nohup "$bin" >"$log" 2>&1 &
echo "   pid $!"
