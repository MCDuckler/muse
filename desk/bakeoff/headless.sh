#!/bin/bash
# Runs a bake-off booth's --bench in a headless mutter (its own Wayland display, a
# 1920x1080@60 virtual monitor on the real GPU) with its sound into a null sink: nothing
# on the screen, nothing out loud.  headless.sh <binary> <out dir> [seconds] [env…]
# (ARGS=… in the environment: more arguments for the booth, as --stage.)
# Writes <out>/bench-*.json, <out>/shot-*.png, and the logs (app.log, mutter.log, dbus.log).
BIN=$1; OUT=$2; SECS=${3:-20}; shift 3 || true
mkdir -p "$OUT"
DISP=wo-bake-$$
M=$(pactl load-module module-null-sink sink_name=wo_bake)
dbus-run-session -- bash -c "
  mutter --headless --wayland --no-x11 --wayland-display=$DISP --virtual-monitor 1920x1080@60 >'$OUT/mutter.log' 2>&1 &
  MP=\$!
  for i in \$(seq 50); do [ -S \$XDG_RUNTIME_DIR/$DISP ] && break; sleep 0.1; done
  env $* WAYLAND_DISPLAY=$DISP PULSE_SINK=wo_bake timeout $((SECS + 40)) '$BIN' --bench $SECS --out '$OUT' ${ARGS:-} >'$OUT/app.log' 2>&1
  echo exit \$? >>'$OUT/app.log'
  kill \$MP; wait \$MP 2>/dev/null
" 2>"$OUT/dbus.log"
pactl unload-module "$M"
grep -E '^\{|^exit|panicked' "$OUT/app.log"
