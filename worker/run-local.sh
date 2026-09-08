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
: "${COOKIE_BROWSER:=firefox}"    # firefox | chromium | chrome — where the jar comes from
: "${FIREFOX_PROFILE:=}"          # profile name; point this at a throwaway account's
                                  # profile to keep a real account out of it
: "${MUSE_COOKIES_MODE:=fallback}"  # anonymous first, signed in only when challenged
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
  local from="$COOKIE_BROWSER"
  [ -n "$FIREFOX_PROFILE" ] && from="$COOKIE_BROWSER:$FIREFOX_PROFILE"
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

# --- the worker --------------------------------------------------------------
export MUSE_API MUSE_WORKER_NAME MUSE_CONCURRENCY MUSE_COOKIES_MODE
export MUSE_COOKIES="$COOKIE_FILE"
export MUSE_POT_BASE_URL="http://127.0.0.1:$POT_PORT"

# The worker runs as a tracked child so stopping this script stops it too. Leaving one
# behind and starting another beside it is how this machine ended up making four times
# the requests it should have.
worker_pid=""
stop() { [ -n "$worker_pid" ] && kill "$worker_pid" 2>/dev/null; kill $REFRESHER 2>/dev/null; }
trap stop EXIT INT TERM

while true; do
  ./.venv/bin/python worker.py &
  worker_pid=$!
  wait "$worker_pid"
  code=$?
  [ $code -eq 0 ] && break          # a clean stop is a stop
  log "worker exited ($code) — restarting in 10s"
  sleep 10
done
