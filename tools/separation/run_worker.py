"""Score the desktop separator — the real program, bin/wetowl_separate.dart — end to end.

    python run_worker.py [test] [m4a]

Needs the program built (cd app && dart build cli --target bin/wetowl_separate.dart
-o build/separator) and the kit made (make_kit.sh). 'm4a' scores the parts as the booth
gets them, through 160k AAC; without it, the raw floats.
"""
import os
import pathlib
import subprocess
import sys
import tempfile

import numpy as np
from scipy.io import wavfile

from evaluate import run

HERE = pathlib.Path(__file__).resolve().parent
EXE = HERE.parents[1] / 'app/build/separator/bundle/bin/wetowl_separate'
WORK = HERE / 'kit/work'
ORT = WORK / 'onnxruntime-linux-x64-1.30.0/lib/libonnxruntime.so.1.30.0'
MODEL = WORK / 'scnet-small-v1.onnx'
subset = 'test' if 'test' in sys.argv[1:] else None
aac = 'm4a' in sys.argv[1:]


def separate(mix):
    with tempfile.TemporaryDirectory() as d:
        wavfile.write(f'{d}/in.wav', 32000, mix.astype(np.float32))
        ext = 'm4a' if aac else 'f32'
        args = [str(EXE), '--ort', str(ORT), '--model', str(MODEL), '--ffmpeg', 'ffmpeg',
                '--in', f'{d}/in.wav', '--threads', '8',
                '--instrumental', f'{d}/i.{ext}', '--drums', f'{d}/d.{ext}', '--music', f'{d}/m.{ext}']
        if not aac:
            args.append('--raw')
        r = subprocess.run(args, capture_output=True, text=True,
                           env={**os.environ, 'MALLOC_ARENA_MAX': '1'})
        if r.returncode:
            raise RuntimeError(r.stderr)

        def load(n):
            if not aac:
                return np.fromfile(f'{d}/{n}.f32', np.float32).reshape(-1, 2)
            raw = subprocess.run(['ffmpeg', '-v', 'error', '-i', f'{d}/{n}.m4a', '-f', 'f32le',
                                  '-ac', '2', '-ar', '32000', '-'], capture_output=True).stdout
            return np.frombuffer(raw, np.float32).reshape(-1, 2)
        return {'instrumental': load('i'), 'drums': load('d'), 'music': load('m')}


run(f'the desktop separator ({"AAC" if aac else "raw"})', separate, subset=subset)
