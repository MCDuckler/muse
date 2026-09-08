#!/usr/bin/env bash
# Runs the ingest worker the way it actually has to run on a residential machine.
#
# Two things keep YouTube answering:
#   * a PO token provider (bgutil), which stops "Sign in to confirm you're not a bot"
#   * a signed-in cookie jar, exported from the browser rather than pasted in
# Without both, this IP gets challenged after a few hundred downloads and everything
# stops. Measured: 0/10 tracks without them, 6/6 with.
#
#   ./run-local.sh
set -u
cd "$(dirname "$0")"

: "${MUSE_API:=https://158-69-192-169.nip.io}"
: "${MUSE_WORKER_NAME:=laptop}"
: "${MUSE_CONCURRENCY:=6}"
: "${POT_PORT:=4416}"
: "${POT_HOME:=$HOME/.local/bgutil-pot}"
: "${FIREFOX_PROFILE:=}"          # e.g. 1aa87zud.default-release; empty = let yt-dlp pick
COOKIE_FILE="$PWD/cookies.txt"
YTDLP="$PWD/.venv/bin/yt-dlp"

if [ -z "${MUSE_WORKER_SECRET:-}" ]; then
  echo "MUSE_WORKER_SECRET is unset — the server would reject every lease" >&2
  exit 1
fi

log() { echo "[$(date +%H:%M:%S)] run-local: $*"; }

# --- PO token provider -------------------------------------------------------
if curl -sf -m 3 "http://127.0.0.1:$POT_PORT/ping" >/dev/null; then
  log "pot provider already running on $POT_PORT"
elif [ -f "$POT_HOME/build/main.js" ]; then
  nohup node "$POT_HOME/build/main.js" --port "$POT_PORT" >/tmp/muse-pot.log 2>&1 &
  sleep 3
  curl -sf -m 3 "http://127.0.0.1:$POT_PORT/ping" >/dev/null \
    && log "started pot provider on $POT_PORT" \
    || log "pot provider did not come up — see /tmp/muse-pot.log"
else
  log "no pot provider at $POT_HOME (see NOTES.md); expect bot checks"
fi

# --- cookies -----------------------------------------------------------------
# Re-exported on every start, and hourly after that: YouTube rotates these, and a jar
# that was fresh last week is a jar that gets you challenged today.
refresh_cookies() {
  local from="firefox"
  [ -n "$FIREFOX_PROFILE" ] && from="firefox:$FIREFOX_PROFILE"
  if "$YTDLP" --cookies-from-browser "$from" --cookies "$COOKIE_FILE.new" \
       --simulate --skip-download --no-warnings \
       "https://music.youtube.com/watch?v=dQw4w9WgXcQ" >/dev/null 2>&1 \
     || [ -s "$COOKIE_FILE.new" ]; then
    # yt-dlp writes the jar even when the probe URL itself fails, which is all we need.
    mv "$COOKIE_FILE.new" "$COOKIE_FILE"
    chmod 600 "$COOKIE_FILE"
    log "cookies refreshed from $from ($(grep -c youtube.com "$COOKIE_FILE") youtube entries)"
  else
    rm -f "$COOKIE_FILE.new"
    log "could not read browser cookies; keeping the existing jar"
  fi
}
refresh_cookies
( while sleep 3600; do refresh_cookies; done ) &
REFRESHER=$!
trap 'kill $REFRESHER 2>/dev/null' EXIT

# --- the worker --------------------------------------------------------------
export MUSE_API MUSE_WORKER_NAME MUSE_CONCURRENCY
export MUSE_COOKIES="$COOKIE_FILE"
export MUSE_POT_BASE_URL="http://127.0.0.1:$POT_PORT"

while true; do
  ./.venv/bin/python worker.py
  code=$?
  [ $code -eq 0 ] && break          # a clean stop is a stop
  log "worker exited ($code) — restarting in 10s"
  sleep 10
done
