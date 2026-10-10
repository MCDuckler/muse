#!/usr/bin/env bash
# How fast the stage draws, on this machine: the release bundle started as a stage
# window (`--stage --spike`, lib/src/ui/show/stage_window.dart) with the spike's chain, for a
# few seconds per variant, its `STAGE fps=…` lines collected. Build first:
#
#   app/tool/desktop_local.sh --no-run
#   app/tool/stage_perf.sh                 # the standard set of variants
#   app/tool/stage_perf.sh "--passes 5 --scale 0.75"   # one variant, 14 s
#   NVIDIA=1 app/tool/stage_perf.sh        # through the NVIDIA card (PRIME offload)
#
# Measured 2026-10-08 on the Linux laptop (Intel Arc iGPU, Impeller GLES, 1920×1080
# window on a 2560×1440 screen): flat fill 60.6 · field shader straight to screen 61 ·
# field+trails (2 offscreen images) 55 · full chain at 1.0× 40 · at 0.75× 53–54 (steady
# over 60 s) · at 0.5× 60 · full chain through the RTX 4060 at 1.0× 56.6. Skia
# (WETOWL_SKIA=1) decays 47→29 over 15 s and is not an option. The rule that came out
# of it: offscreen passes at a scale the GPU can carry, the composite and the text at
# the screen's own size.
set -uo pipefail
cd "$(dirname "$0")/.."
bin=build/linux/x64/release/bundle/wetowl
[ -x "$bin" ] || { echo "no $bin — build first (tool/desktop_local.sh --no-run)"; exit 1; }

env_extra=()
if [ "${NVIDIA:-}" = 1 ]; then
  env_extra=(__NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia
             __EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/10_nvidia.json)
fi

run() {
  local secs=$1; shift
  local log; log=$(mktemp)
  # shellcheck disable=SC2086
  env WETOWL_NON_UNIQUE=1 "${env_extra[@]}" "$bin" --stage --spike "$@" >"$log" 2>&1 &
  local pid=$!
  sleep "$secs"
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  echo "== $*"
  # The first line is the warm-up (shaders compiling); the rest is the number.
  grep -E "STAGE fps" "$log" | tail -n +2
  rm -f "$log"
}

if [ $# -gt 0 ]; then
  # shellcheck disable=SC2086
  run 14 $1
  exit 0
fi
run 14 --passes 0
run 14 --passes 1
run 14 --passes 2
run 14 --passes 5
run 14 --passes 5 --scale 0.75
run 14 --passes 5 --scale 0.5
