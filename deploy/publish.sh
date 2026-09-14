#!/usr/bin/env bash
# Deploys muse to the box. Run from the repo root: deploy/publish.sh [server|web|apk|ios|all]
#
# Two mistakes this exists to prevent, both made the hard way:
#   * rsyncing server/muse/ onto /opt/muse/server/ instead of server/ — with --delete
#     that removes the Dockerfile the image is built from.
#   * rsyncing the web build with --delete over a directory that also holds the
#     installable builds, which quietly deletes the download people install from. The
#     exclude that papered over it only knew about the APK, so the day an iPhone build
#     was added it went out, worked, and was gone by the next web publish. The builds
#     now live in a directory of their own that no rsync here points at.
set -euo pipefail
cd "$(dirname "$0")/.."

HOST=${MUSE_HOST:-root@158.69.192.169}
KEY=${MUSE_KEY:-$HOME/Documents/chris.pem}
SERVER_URL=${MUSE_SERVER_URL:-https://158-69-192-169.nip.io}
SSH="ssh -i $KEY"
# Where the installable builds live. Deliberately not the web root: see above.
DL=/opt/muse/deploy/downloads
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
  # No excludes for the downloads any more: they are not in this directory. The symbol
  # files are for reading a stack trace off a debug build; nothing serves them and they
  # are another megabyte and a half over the wire on every publish.
  rsync -az --delete --exclude '*.symbols' \
    -e "$SSH" app/build/web/ "$HOST":/opt/muse/deploy/web/
  # And the thing that went wrong, asserted rather than remembered: a web publish must
  # never cost the phones their downloads.
  for f in muse.apk wetowl.ipa; do
    code=$(curl -s -o /dev/null -w '%{http_code}' -I "$SERVER_URL/$f")
    [ "$code" = 200 ] || echo "   ! $SERVER_URL/$f answers $code"
  done
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
  scp -q -i "$KEY" "$apk" "$HOST":$DL/muse.apk
  # What the app reads to find out whether there is a newer one. A plain file beside
  # the APK rather than an endpoint: it is written by whatever publishes the APK, so
  # the two cannot get out of step.
  printf '{"version":"%s","build":"%s","bytes":%s,"built":"%s"}\n' \
    "$version" "$build" "$bytes" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    | $SSH "$HOST" "cat > $DL/muse.apk.json"
  echo "   $SERVER_URL/muse.apk  ($version build $build, $((bytes / 1024 / 1024))MB)"
}

# The iPhone build, fetched from the Mac that made it and put beside the APK.
#
# iOS binaries can only be produced on macOS, so the build itself happens on a rented
# one for ten minutes in GitHub Actions (see .github/workflows/ios.yml) and lands on a
# release. This brings the newest one down and serves it from the same place the APK is
# served from, so the app has one link to offer and nobody has to go to GitHub on a
# phone. Needs `gh` signed in, which is the same thing that can read the private repo.
publish_ios() {
  echo "== ipa"
  command -v gh >/dev/null || { echo "   (no gh — skipping the iPhone build)"; return; }
  local tmp
  tmp=$(mktemp -d)
  local tag
  tag=$(gh release list --repo MCDuckler/muse --limit 20 \
          --json tagName --jq '[.[] | select(.tagName | startswith("ios-"))][0].tagName')
  [ -n "$tag" ] || { echo "   (no iPhone release yet)"; return; }
  gh release download "$tag" --repo MCDuckler/muse --pattern '*.ipa' \
     --dir "$tmp" --clobber >/dev/null

  local ipa
  ipa=$(ls "$tmp"/*.ipa | head -1)
  local bytes
  bytes=$(stat -c%s "$ipa")
  # The stamp the app will report about itself, read out of the binary rather than
  # taken from the tag: those are minutes apart, and "is this newer than what I am
  # running" has to compare the same number the running copy says.
  local build
  build=$(unzip -p "$ipa" 'Payload/Runner.app/Frameworks/App.framework/App' 2>/dev/null \
            | strings | grep -oE '^20[0-9]{10}$' | sort -u | tail -1)
  [ -n "$build" ] || build=$(echo "$tag" | tr -dc '0-9')

  scp -q -i "$KEY" "$ipa" "$HOST":$DL/wetowl.ipa
  printf '{"version":"%s","build":"%s","bytes":%s,"built":"%s","tag":"%s"}\n' \
    "$(sed -n 's/^version: *\([^+]*\).*/\1/p' app/pubspec.yaml | tr -d '[:space:]')" \
    "$build" "$bytes" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$tag" \
    | $SSH "$HOST" "cat > $DL/wetowl.ipa.json"

  # The same build again, described the way a sideloader wants to hear about it.
  #
  # An unsigned ipa cannot be installed by tapping it: iOS has nowhere to put it, so
  # Safari downloads a file and that is the end of it. It has to be signed on the phone
  # by SideStore or AltStore, and those install from a *source* — a list of apps with
  # versions, the shape AltStore defined and SideStore reads. Added once, WetOwl sits
  # in their Browse tab and every later build shows up there as an update, which is as
  # close to the Android row's behaviour as iOS allows without an Apple account.
  local date
  date=$(date -u +%Y-%m-%d)
  local version
  version=$(sed -n 's/^version: *\([^+]*\).*/\1/p' app/pubspec.yaml | tr -d '[:space:]')
  cat <<JSON | $SSH "$HOST" "cat > $DL/wetowl-source.json"
{
  "name": "WetOwl",
  "identifier": "dev.muse.source",
  "subtitle": "The music you keep, on your own box.",
  "iconURL": "$SERVER_URL/icons/Icon-192.png",
  "website": "$SERVER_URL",
  "apps": [
    {
      "name": "WetOwl",
      "bundleIdentifier": "dev.muse.muse",
      "developerName": "WetOwl",
      "subtitle": "Your own music server, on your phone.",
      "localizedDescription": "The WetOwl client: your library, playlists, jams and downloads from your own server.",
      "iconURL": "$SERVER_URL/icons/Icon-192.png",
      "tintColor": "6750A4",
      "category": "entertainment",
      "screenshotURLs": [],
      "versions": [
        {
          "version": "$version",
          "buildVersion": "$build",
          "date": "$date",
          "localizedDescription": "Build $build.",
          "downloadURL": "$SERVER_URL/wetowl.ipa",
          "size": $bytes,
          "minOSVersion": "15.0"
        }
      ]
    }
  ]
}
JSON
  rm -rf "$tmp"
  echo "   $SERVER_URL/wetowl.ipa  ($tag, build $build, $((bytes / 1024 / 1024))MB)"
  echo "   $SERVER_URL/wetowl-source.json  (add as a source in SideStore/AltStore)"
}

case "$what" in
  server) publish_server ;;
  ios)    publish_ios ;;
  web)    publish_web ;;
  apk)    publish_apk ;;
  all)    publish_server; publish_web; publish_apk; publish_ios ;;
  *) echo "usage: deploy/publish.sh [server|web|apk|ios|all]" >&2; exit 2 ;;
esac
