#!/usr/bin/env bash
# The booth on the real desktop engine, heard: two click tracks mixed by the automix
# into a private PipeWire sink nobody hears, recorded, and measured.
#
#   app/tool/booth_probe/run.sh          (Linux, PipeWire, flutter; python with numpy+soundfile)
#
# What it prints is where B's beats landed against A's while both played, and whether
# either dropped out. PROBE_A_BPM=150 PROBE_PITCH=0.8267 plays A — made at 150 — at
# 124: a master left pitched by an earlier mix, which the automix must still match. Last run (2026-09-23, Rubber Band, critically damped lock): within
# 5 ms, ±1 ms from beat to beat. See integration_test/booth_sync_test.dart.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
APP=$(cd "$HERE/../.." && pwd)
PY=${PYTHON:-python3}
W=$(mktemp -d)
REC=
SINK=
tidy() {
  # Only ever the recorder by its own pid: "kill 0" would be the whole process group.
  if [ -n "$REC" ]; then kill -INT "$REC" 2>/dev/null || true; fi
  if [ -n "$SINK" ]; then pactl unload-module "$SINK" || true; fi
  rm -rf "$W"
}
trap tidy EXIT
"$PY" "$HERE/make_tracks.py" "$W" "${PROBE_A_BPM:-124}"
SINK=$(pactl load-module module-null-sink sink_name=wetowl_probe sink_properties=device.description=wetowl_probe)
pw-record --target wetowl_probe -P '{ stream.capture.sink=true }' --rate 48000 --channels 2 --format f32 "$W/rec.wav" &
REC=$!
cd "$APP"
flutter test integration_test/booth_sync_test.dart -d linux \
  --dart-define=PROBE_DIR="$W" --dart-define=PROBE_PITCH="${PROBE_PITCH:-1}" --dart-define=BOOTH_TRACE=true > "$W/test.out" 2>&1 || { tail -30 "$W/test.out"; exit 1; }
grep -E '^booth:' "$W/test.out" || true
grep -hE "bpm on show|started;" "$W/events.txt" 2>/dev/null || true
# The lock's own view, a line every couple of seconds: time since it began, what it
# measured, the rate it set.
grep -E '^lock: ' "$W/test.out" | awk 'NR % 40 == 1 {print "   " $0}' || true
kill -INT $REC; wait $REC 2>/dev/null || true; REC=
"$PY" "$HERE/analyse.py" "$W/rec.wav"
