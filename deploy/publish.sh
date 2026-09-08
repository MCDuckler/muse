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

publish_web() {
  echo "== web"
  (cd app && flutter build web --release --dart-define=MUSE_SERVER="$SERVER_URL")
  rsync -az --delete --exclude muse.apk -e "$SSH" app/build/web/ "$HOST":/opt/muse/deploy/web/
}

publish_apk() {
  echo "== apk"
  # A registrant generated during an integration-test run lists the integration_test
  # plugin, which does not exist in a release build. Deleting it forces a fresh one.
  rm -f app/android/app/src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java
  (cd app && flutter build apk --release --dart-define=MUSE_SERVER="$SERVER_URL")
  scp -q -i "$KEY" app/build/app/outputs/flutter-apk/app-release.apk "$HOST":/opt/muse/deploy/web/muse.apk
  echo "   $SERVER_URL/muse.apk"
}

case "$what" in
  server) publish_server ;;
  web)    publish_web ;;
  apk)    publish_apk ;;
  all)    publish_server; publish_web; publish_apk ;;
  *) echo "usage: deploy/publish.sh [server|web|apk|all]" >&2; exit 2 ;;
esac
