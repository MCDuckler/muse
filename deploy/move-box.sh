#!/usr/bin/env bash
# Copies the running WetOwl stack from the old box to the new one. Safe to re-run: the
# file copy is an incremental rsync and the database is dumped and restored whole, so a
# second run right before the switch only moves what changed since the first.
#
#   deploy/move-box.sh stage     copy everything, start the new box with its background
#                                jobs OFF (a read-only-ish replica to look at)
#   deploy/move-box.sh cutover   stop the old API, final copy, start the new box for real
#
# Why the replica runs without background jobs: the API starts download, enrichment and
# follow-poll workers in-process, and those refresh the Spotify tokens stored in the
# database. Two copies refreshing the same refresh token is how the live box would end
# up holding one Spotify has already replaced.
#
# Box to box, never through this machine: the audio is ~18 GB and the upstream here is
# ~9 Mbit/s. A throwaway ssh-agent is forwarded to the old box so it can reach the new
# one with the same key, and dies with this script.
set -euo pipefail
cd "$(dirname "$0")/.."

OLD=${MUSE_OLD_HOST:-root@158.69.192.169}
NEW=${MUSE_NEW_HOST:-root@89.58.49.140}
KEY=${MUSE_KEY:-$HOME/Documents/chris.pem}
OLD_NAME=${MUSE_OLD_NAME:-158-69-192-169.nip.io}
# The first name is the one the apps and links are built against; the rest are served too.
# Only nip.io: the provider name (v2202609418226520080.megasrv.de) resolves here too, but
# megasrv.de is shared by every netcup customer and sits on Let's Encrypt's 50-a-week limit.
NEW_NAMES=${MUSE_NEW_NAMES:-"89-58-49-140.nip.io"}
NEW_URL="https://${NEW_NAMES%% *}"
mode=${1:-}

case "$mode" in stage|cutover) ;; *) echo "usage: deploy/move-box.sh stage|cutover" >&2; exit 2 ;; esac

log() { echo "[$(date +%H:%M:%S)] $*"; }
ssh_old() { ssh -o BatchMode=yes -i "$KEY" "$OLD" "$@"; }
ssh_new() { ssh -o BatchMode=yes -o IdentitiesOnly=yes -i "$KEY" "$NEW" "$@"; }

eval "$(ssh-agent -s)" >/dev/null
trap 'ssh-agent -k >/dev/null' EXIT
ssh-add -q "$KEY"

if [ "$mode" = cutover ]; then
  log "stopping the old API — nothing writes to the old database from here on"
  ssh_old 'cd /opt/muse/deploy && docker compose stop api'
fi

log "copying files ($OLD -> $NEW)"
ssh -A -o BatchMode=yes -i "$KEY" "$OLD" "
  set -e
  R='rsync -a --numeric-ids --delete -e \"ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes\"'
  eval \$R --exclude __pycache__ /opt/muse/server/ $NEW:/opt/muse/server/
  # data/pg is dumped below instead: copying a live cluster's files gives a torn copy.
  # data/caddy holds the old name's certificate, which is no use to the new one.
  # web/ is built for one address (MUSE_SERVER is baked in), so the old box's copy would
  # point the new page at the old API. It is published fresh below instead.
  eval \$R --exclude data/pg --exclude data/caddy --exclude web /opt/muse/deploy/ $NEW:/opt/muse/deploy/
"

log "pointing the copied config at the new name"
names_csv=$(echo "$NEW_NAMES" | sed 's/ /, /g')
ssh_new "set -e; cd /opt/muse/deploy
  sed -i 's|^${OLD_NAME} {|${names_csv} {|' Caddyfile
  sed -i 's|https://${OLD_NAME}|${NEW_URL}|g' muse.toml
  grep -n ' {\$' Caddyfile | head -1
  grep -nE 'public_url|redirect_uri' muse.toml"

if [ "$mode" = stage ]; then
  # Compose reads docker-compose.override.yml on its own, so the replica needs no
  # different command line — and the switch is deleting this one file.
  ssh_new "cat > /opt/muse/deploy/docker-compose.override.yml" <<'YML'
# STAGING ONLY — delete at cutover (deploy/move-box.sh cutover does).
# Runs the API without its in-process workers so this copy never leases jobs or
# refreshes Spotify tokens while the old box is still the live one.
services:
  api:
    command: ["python", "-c", "import uvicorn; from muse import config; from muse.app import create_app; uvicorn.run(create_app(config.load(), start_workers=False), host='0.0.0.0', port=8770)"]
YML
else
  ssh_new "rm -f /opt/muse/deploy/docker-compose.override.yml"
fi

log "database"
ssh_new 'cd /opt/muse/deploy && docker compose stop api >/dev/null 2>&1 || true; docker compose up -d --wait db'
ssh -A -o BatchMode=yes -i "$KEY" "$OLD" "
  set -e -o pipefail
  docker exec deploy-db-1 pg_dump -U muse -Fc muse \
    | ssh -o BatchMode=yes $NEW 'docker exec -i deploy-db-1 pg_restore -U muse -d muse --clean --if-exists --no-owner'
"
# The dump was taken after the file copy, so while the old box is still live it can name
# audio the worker delivered in between. One more incremental pass closes that gap.
ssh -A -o BatchMode=yes -i "$KEY" "$OLD" "
  rsync -a --numeric-ids -e 'ssh -o BatchMode=yes' /opt/muse/deploy/data/muse/ $NEW:/opt/muse/deploy/data/muse/
"
for t in users tracks library_items playlist_items queue_items jobs; do
  o=$(ssh_old "docker exec deploy-db-1 psql -U muse -Atc 'select count(*) from $t'")
  n=$(ssh_new "docker exec deploy-db-1 psql -U muse -Atc 'select count(*) from $t'")
  log "  $t: old $o, new $n"
done

log "starting the stack"
ssh_new 'cd /opt/muse/deploy && docker compose up -d --build && docker compose ps --format "{{.Service}} {{.Status}}"'

log "web app, built against $NEW_URL"
PATH="$HOME/.local/flutter/bin:$PATH" MUSE_HOST="$NEW" MUSE_SERVER_URL="$NEW_URL" MUSE_KEY="$KEY" \
  deploy/publish.sh web

log "waiting for the certificate and the routes"
for _ in $(seq 1 30); do
  curl -sf -m 5 -o /dev/null "$NEW_URL/" && break
  sleep 4
done
python3 deploy/check_routes.py "$NEW_URL"

if [ "$mode" = cutover ]; then
  cat <<EOF

The new box is live at $NEW_URL. Still to do by hand:
  * worker:   MUSE_API=$NEW_URL in worker/run-local.sh, and the secret now comes from $NEW
  * publish:  MUSE_HOST / MUSE_SERVER_URL defaults in deploy/publish.sh, then
              deploy/publish.sh apk ios — the phone builds have the server URL built in
              (installed ones keep calling the old address until they update)
  * Spotify:  add $NEW_URL/spotify/callback to the app's redirect URIs
  * old box:  make its Caddy forward to the new one (installed apps keep the old address
              until they update) — see Caddyfile.pre-move there for the way back
EOF
fi
