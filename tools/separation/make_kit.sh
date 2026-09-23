#!/usr/bin/env bash
# Make the files the desktop separator fetches from the house, from their sources:
#
#   tools/separation/make_kit.sh          → tools/separation/kit/*.gz
#   deploy/publish.sh models              → puts them on the box
#
# The network is exported from SCNet Small's published checkpoint (ZFTurbo's
# Music-Source-Separation-Training, MIT); ONNX Runtime is Microsoft's release (MIT).
# Every input and output is checked against a pinned hash — the output ones are the
# ones the app carries in app/lib/src/worker/separation_kit.dart, and an app refuses
# any file that does not match. If a re-export comes out different (another torch, say)
# this stops rather than publish it: a new network needs a new name there and here.
#
# Needs python3, curl, unzip, git. About 3 GB of disk while it works; not the server.
set -euo pipefail
cd "$(dirname "$0")"

KIT=kit
WORK=kit/work
mkdir -p "$WORK"

MSST_COMMIT=050cae7345f4ac1e1e27e066c2c5cdc0a2cdb679
REL=https://github.com/ZFTurbo/Music-Source-Separation-Training/releases/download/v.1.0.6
CKPT_SHA=1bc0d1abb20bfdf966dcd07637bafd03e4bc13653d09ef18bc9b3e342eafe2aa
CONFIG_SHA=19103def86d549701f824804fc5f3d244e8e8ccd4032da6ee9d5b4f2a5f2da16
MODEL_SHA=678fb1f31846e1c0bab6602bdb2a9663dad85ad8adf2e5d9e29374d645c14367
ORT=1.30.0
ORT_LINUX_SHA=245a6f8c38127551057a1cd1ffd59f0a186a227ade4f3492dea2494eb565542e
ORT_WIN_SHA=7e39e2bdbba836d98071ef28620735ba36a47c554cf794585269aecc50fab0da

check() { # file sha what
  local got; got=$(sha256sum "$1" | cut -d' ' -f1)
  [ "$got" = "$2" ] || { echo "$3 is not what it should be: $got" >&2; exit 1; }
}
fetch() { [ -f "$2" ] || curl -fsSL -o "$2" "$1"; }

echo "== ONNX Runtime $ORT"
fetch "https://github.com/microsoft/onnxruntime/releases/download/v$ORT/onnxruntime-linux-x64-$ORT.tgz" "$WORK/ort-linux.tgz"
fetch "https://github.com/microsoft/onnxruntime/releases/download/v$ORT/onnxruntime-win-x64-$ORT.zip" "$WORK/ort-win.zip"
tar -xzf "$WORK/ort-linux.tgz" -C "$WORK" "onnxruntime-linux-x64-$ORT/lib/libonnxruntime.so.$ORT"
unzip -qo "$WORK/ort-win.zip" "onnxruntime-win-x64-$ORT/lib/onnxruntime.dll" -d "$WORK"
check "$WORK/onnxruntime-linux-x64-$ORT/lib/libonnxruntime.so.$ORT" $ORT_LINUX_SHA "the Linux runtime"
check "$WORK/onnxruntime-win-x64-$ORT/lib/onnxruntime.dll" $ORT_WIN_SHA "the Windows runtime"
gzip -9 -n -c "$WORK/onnxruntime-linux-x64-$ORT/lib/libonnxruntime.so.$ORT" > "$KIT/onnxruntime-$ORT-linux-x64.so.gz"
gzip -9 -n -c "$WORK/onnxruntime-win-x64-$ORT/lib/onnxruntime.dll" > "$KIT/onnxruntime-$ORT-win-x64.dll.gz"

echo "== SCNet Small"
[ -d "$WORK/msst" ] || git clone -q https://github.com/ZFTurbo/Music-Source-Separation-Training "$WORK/msst"
git -C "$WORK/msst" checkout -q $MSST_COMMIT
fetch "$REL/config_musdb18_scnet.yaml" "$WORK/config_musdb18_scnet.yaml"
fetch "$REL/scnet_checkpoint_musdb18.ckpt" "$WORK/scnet_checkpoint_musdb18.ckpt"
check "$WORK/config_musdb18_scnet.yaml" $CONFIG_SHA "the SCNet config"
check "$WORK/scnet_checkpoint_musdb18.ckpt" $CKPT_SHA "the SCNet checkpoint"
[ -x "$WORK/venv/bin/python" ] || python3 -m venv "$WORK/venv"
"$WORK/venv/bin/pip" install -q --index-url https://download.pytorch.org/whl/cpu torch==2.14.0
"$WORK/venv/bin/pip" install -q -r requirements-export.txt
"$WORK/venv/bin/python" export_scnet.py "$WORK/msst" "$WORK/config_musdb18_scnet.yaml" \
  "$WORK/scnet_checkpoint_musdb18.ckpt" "$WORK/scnet-small-v1.onnx"
check "$WORK/scnet-small-v1.onnx" $MODEL_SHA "the exported network"
gzip -9 -n -c "$WORK/scnet-small-v1.onnx" > "$KIT/scnet-small-v1.onnx.gz"

ls -l "$KIT"/*.gz
echo "made. deploy/publish.sh models puts them on the box."
