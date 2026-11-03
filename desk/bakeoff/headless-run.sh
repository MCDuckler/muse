#!/bin/bash
# Runs any command inside a headless mutter (its own Wayland display, one 1920x1080@60
# virtual monitor on the real GPU — two with SCREENS=2) with its sound into a null sink:
# nothing on the screen, nothing out loud. For the stage's live tests:
#   bakeoff/headless-run.sh env WO_STAGE_RUST=target/release/wetowl-stage \
#       cargo test --release -p wo-deskcore --test stage_rust_live -- --ignored
# mutter's log goes to $LOG (default /dev/null). Exits with the command's status.
DISP=wo-run-$$
MON="--virtual-monitor 1920x1080@60"
[ "${SCREENS:-1}" = 2 ] && MON="$MON --virtual-monitor 1280x720@60"
M=$(pactl load-module module-null-sink sink_name=wo_run 2>/dev/null)
dbus-run-session -- bash -c '
  mutter --headless --wayland --no-x11 --wayland-display='"$DISP"' '"$MON"' >"${LOG:-/dev/null}" 2>&1 &
  MP=$!
  for i in $(seq 50); do [ -S "$XDG_RUNTIME_DIR/'"$DISP"'" ] && break; sleep 0.1; done
  WAYLAND_DISPLAY='"$DISP"' PULSE_SINK=wo_run "$@"
  st=$?
  kill $MP; wait $MP 2>/dev/null
  exit $st
' bash "$@"
st=$?
[ -n "$M" ] && pactl unload-module "$M"
exit $st
