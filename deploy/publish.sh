#!/usr/bin/env bash
# Deploys muse to the box. Run from the repo root: deploy/publish.sh [server|web|apk|all]
#
# Two mistakes this exists to prevent, both made the hard way:
#   * rsyncing server/muse/ onto /opt/muse/server/ instead of server/ — with --delete
#     that removes the Dockerfile the image is built from.
#   * rsyncing the web build with --delete over a directory that also holds muse.apk,
#     which quietly deletes the download people install from.
set -euo pipefail
cd "$(dirname "$0")/.."

HOST=${MUSE_HOST:-root@158.69.192.169}
KEY=${MUSE_KEY:-$HOME/Documents/chris.pem}
SERVER_URL=${MUSE_SERVER_URL:-https://158-69-192-169.nip.io}
SSH="ssh -i $KEY"
what=${1:-all}

publish_server() {
  echo "== server"
  rsync -az --delete --exclude __pycache__ --exclude tests --exclude 'muse.toml' \
    -e "$SSH" server/ "$HOST":/opt/muse/server/
  scp -q -i "$KEY" deploy/Caddyfile "$HOST":/opt/muse/deploy/Caddyfile
  # The API is a built image, not a bind mount: restarting alone runs the old code.
  $SSH "$HOST" 'cd /opt/muse/deploy && docker compose up -d --build api && docker compose restart caddy'
  sleep 6
  python3 deploy/check_routes.py "$SERVER_URL"
}

# Brotli, once per file, kept beside it for Caddy to serve as-is.
#
# The two files a cold load waits for are the app and CanvasKit: 3.9MB over the wire
# compressed on the fly, 3.0MB compressed properly here. Safari has no zstd at all, so
# the phone was getting gzip — this is most of a megabyte off the first load of the web
# app and of the PWA on the iPhone.
#
# Compressing 7MB of wasm at the highest setting takes most of a minute, and CanvasKit
# only changes when Flutter does, so the results are kept by content hash and the work
# is done once.
precompress_web() {
  command -v brotli >/dev/null || { echo "   (no brotli — serving compressed on the fly)"; return; }
  local cache=app/build/br-cache
  mkdir -p "$cache"
  local n=0
  while IFS= read -r f; do
    local sum key
    sum=$(sha256sum "$f" | cut -d' ' -f1)
    key="$cache/$sum.br"
    if [ ! -f "$key" ]; then
      brotli -f -q 11 -o "$key" "$f"
    fi
    cp "$key" "$f.br"
    n=$((n + 1))
  done < <(find app/build/web -type f \( -name '*.js' -o -name '*.wasm' -o -name '*.json' \
             -o -name '*.css' -o -name '*.html' -o -name 'NOTICES' \) -size +1k)
  echo "   precompressed $n files"
}

publish_web() {
  echo "== web"
  (cd app && flutter build web --release --dart-define=MUSE_SERVER="$SERVER_URL")
  precompress_web
  # muse.apk* rather than muse.apk: the manifest beside the APK is published by the
  # apk step and lives in the same directory, and a --delete that only knew about the
  # APK itself quietly removed it every time the web app went out — so the app could
  # never find out that a new version existed.
  # The symbol files are for reading a stack trace off a debug build; nothing serves
  # them and they are another megabyte and a half over the wire on every publish.
  rsync -az --delete --exclude 'muse.apk*' --exclude '*.symbols' \
    -e "$SSH" app/build/web/ "$HOST":/opt/muse/deploy/web/
}

publish_apk() {
  echo "== apk"
  # A registrant generated during an integration-test run lists the integration_test
  # plugin, which does not exist in a release build. Deleting it forces a fresh one.
  rm -f app/android/app/src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java
  # The launcher icon lives inside the APK, so the only moment it can follow the one
  # the server is serving is now.
  python3 deploy/bake_icon.py "$SERVER_URL" || true
  # The moment it was built, as the build number.
  #
  # Nothing was ever going to tell a new APK from the running one: the version was a
  # constant in the source that had not been touched since the first commit. A stamp
  # cannot be forgotten and is in order by construction, which is the whole of what an
  # update check needs — is the one on the server newer than the one in my hand.
  local build
  build=$(date -u +%Y%m%d%H%M)
  local version
  version=$(sed -n 's/^version: *\([^+]*\).*/\1/p' app/pubspec.yaml | tr -d '[:space:]')
  (cd app && flutter build apk --release \
      --dart-define=MUSE_SERVER="$SERVER_URL" \
      --dart-define=MUSE_BUILD="$build")

  local apk=app/build/app/outputs/flutter-apk/app-release.apk
  local bytes
  bytes=$(stat -c%s "$apk")
  scp -q -i "$KEY" "$apk" "$HOST":/opt/muse/deploy/web/muse.apk
  # What the app reads to find out whether there is a newer one. A plain file beside
  # the APK rather than an endpoint: it is written by whatever publishes the APK, so
  # the two cannot get out of step.
  printf '{"version":"%s","build":"%s","bytes":%s,"built":"%s"}\n' \
    "$version" "$build" "$bytes" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    | $SSH "$HOST" 'cat > /opt/muse/deploy/web/muse.apk.json'
  echo "   $SERVER_URL/muse.apk  ($version build $build, $((bytes / 1024 / 1024))MB)"
}

case "$what" in
  server) publish_server ;;
  web)    publish_web ;;
  apk)    publish_apk ;;
  all)    publish_server; publish_web; publish_apk ;;
  *) echo "usage: deploy/publish.sh [server|web|apk|all]" >&2; exit 2 ;;
esac
