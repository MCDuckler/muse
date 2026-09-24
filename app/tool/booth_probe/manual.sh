#!/usr/bin/env bash
# SYNC by hand with two real records on the real engine, heard: deck A into one private
# sink, deck B into another, the two joined into one stereo recording (A left, B right)
# so both share a clock, and where B's onsets fall against A's measured from the sound.
#
#   app/tool/booth_probe/manual.sh <spec.json>    (spec: a/b file + analysis, a_at, b_at)
#   PROBE_HEAR=1   also plays both decks out of the speakers, mixed as the booth mixes them
#   PROBE_KEEP=dir keeps the recording and the events there
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
APP=$(cd "$HERE/../.." && pwd)
PY=${PYTHON:-python3}
SPEC=$1
W=$(mktemp -d)
REC=
MODS=()
tidy() {
  if [ -n "$REC" ]; then kill -INT "$REC" 2>/dev/null || true; fi
  for m in "${MODS[@]}"; do pactl unload-module "$m" 2>/dev/null || true; done
  rm -rf "$W"
}
trap tidy EXIT
cp "$SPEC" "$W/manual.json"
for s in wetowl_probe_a wetowl_probe_b wetowl_probe_mix; do
  MODS+=("$(pactl load-module module-null-sink sink_name=$s sink_properties=device.description=$s)")
done
sleep 0.5
if [ -n "${PROBE_HEAR:-}" ]; then
  for s in wetowl_probe_a wetowl_probe_b; do
    MODS+=("$(pactl load-module module-loopback source=$s.monitor latency_msec=60)")
  done
fi
pw-link wetowl_probe_a:monitor_FL wetowl_probe_mix:playback_FL 2>/dev/null || true
pw-link wetowl_probe_a:monitor_FR wetowl_probe_mix:playback_FL 2>/dev/null || true
pw-link wetowl_probe_b:monitor_FL wetowl_probe_mix:playback_FR 2>/dev/null || true
pw-link wetowl_probe_b:monitor_FR wetowl_probe_mix:playback_FR 2>/dev/null || true
date +%s.%N > "$W/rec_started.txt"
pw-record --target wetowl_probe_mix -P '{ stream.capture.sink=true }' --rate 48000 --channels 2 --format f32 "$W/rec.wav" &
REC=$!
cd "$APP"
flutter test integration_test/booth_manual_sync_test.dart -d linux \
  --dart-define=PROBE_DIR="$W" --dart-define=BOOTH_TRACE=true > "$W/test.out" 2>&1 || { tail -30 "$W/test.out"; exit 1; }
grep -E "^(booth|deck):" "$W/test.out" || true
grep -E '^lock: ' "$W/test.out" | awk 'NR % 20 == 1 {print "   " $0}' || true
kill -INT $REC; wait $REC 2>/dev/null || true; REC=
if [ -n "${PROBE_KEEP:-}" ]; then mkdir -p "$PROBE_KEEP"; cp "$W"/rec.wav "$W"/events.txt "$W"/rec_started.txt "$W"/test.out "$PROBE_KEEP"/; fi
cat "$W/events.txt"
if grep -q '"fx_check"' "$SPEC"; then
  "$PY" "$HERE/fx_analyse.py" "$W/rec.wav" "$W/rec_started.txt" "$W/events.txt"
else
  "$PY" "$HERE/manual_analyse.py" "$W/rec.wav" "$W/rec_started.txt" "$W/events.txt" "${PROBE_MEASURE:-kick}"
fi
