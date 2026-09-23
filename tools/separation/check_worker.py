"""The desktop separator against the Python it was written from, sample for sample.

    kit/work/venv/bin/python check_worker.py <some record> [seconds]

Runs the same record through ZFTurbo's own demix with the same exported network in
ONNX Runtime, and through app/bin/wetowl_separate.dart, both at 44.1 kHz with no
codec in between, and says how far apart they are. They should agree to within
rounding: last measured, 4.5e-7 at worst and 124 dB or better, over forty seconds.
Needs make_kit.sh to have been run and the program built.
"""
import os
import pathlib
import subprocess
import sys
import tempfile

import numpy as np
import torch

HERE = pathlib.Path(__file__).resolve().parent
WORK = HERE / 'kit/work'
EXE = HERE.parents[1] / 'app/build/separator/bundle/bin/wetowl_separate'
ORT = WORK / 'onnxruntime-linux-x64-1.30.0/lib/libonnxruntime.so.1.30.0'
MODEL = WORK / 'scnet-small-v1.onnx'
sys.path.insert(0, str(WORK / 'msst'))

import onnxruntime as ort  # noqa: E402
from utils.model_utils import demix  # noqa: E402
from utils.settings import get_model_from_config  # noqa: E402

record = sys.argv[1]
seconds = float(sys.argv[2]) if len(sys.argv) > 2 else 40

model, config = get_model_from_config('scnet', str(WORK / 'config_musdb18_scnet.yaml'))
config.inference.num_overlap = 2
config.inference.batch_size = 1
options = ort.SessionOptions()
options.enable_cpu_mem_arena = False
session = ort.InferenceSession(str(MODEL), options, providers=['CPUExecutionProvider'])


def forward(x):
    """SCNet.forward with the network in ONNX Runtime: the STFT either side as SCNet does it."""
    pad = model.hop_length - x.shape[-1] % model.hop_length
    if (x.shape[-1] + pad) // model.hop_length % 2 == 0:
        pad += model.hop_length
    x = torch.nn.functional.pad(x, (0, pad))
    b, length = x.shape[0], x.shape[-1]
    z = torch.view_as_real(torch.stft(x.reshape(-1, length), **model.stft_config, return_complex=True))
    z = z.permute(0, 3, 1, 2).reshape(b, 4, z.shape[1], z.shape[2])
    y = torch.from_numpy(session.run(None, {'spec': z.numpy()})[0])
    y = y.reshape(-1, 2, z.shape[2], z.shape[3]).permute(0, 2, 3, 1)
    y = torch.istft(torch.view_as_complex(y.contiguous()), **model.stft_config)
    return y.reshape(b, 4, 2, -1)[:, :, :, :-pad]


model.forward = forward

with tempfile.TemporaryDirectory() as d:
    raw = subprocess.run(['ffmpeg', '-v', 'error', '-t', str(seconds), '-i', record, '-ac', '2',
                          '-ar', '44100', '-f', 'f32le', '-'], capture_output=True, check=True).stdout
    mix = np.frombuffer(raw, np.float32).reshape(-1, 2)
    subprocess.run(['ffmpeg', '-v', 'error', '-y', '-f', 'f32le', '-ar', '44100', '-ac', '2',
                    '-i', 'pipe:0', '-c:a', 'pcm_f32le', f'{d}/in.wav'], input=mix.tobytes(), check=True)
    with torch.no_grad():
        want = demix(config, model, mix.T.copy(), torch.device('cpu'), 'scnet', pbar=False)
    r = subprocess.run([str(EXE), '--ort', str(ORT), '--model', str(MODEL), '--ffmpeg', 'ffmpeg',
                        '--in', f'{d}/in.wav', '--raw', '--rate', '44100', '--drums', f'{d}/d.f32',
                        '--vocals', f'{d}/v.f32', '--bass-other', f'{d}/b.f32'],
                       capture_output=True, text=True)
    if r.returncode:
        sys.exit(r.stderr)
    worst = 200.0
    for name, file, truth in (('drums', 'd', want['drums']), ('vocals', 'v', want['vocals']),
                              ('bass+other', 'b', want['bass'] + want['other'])):
        got = np.fromfile(f'{d}/{file}.f32', np.float32).reshape(-1, 2)
        truth = np.clip(truth.T, -1, 1)
        if len(got) != len(truth):
            sys.exit(f'{name}: {len(got)} samples from the program, {len(truth)} from Python')
        err = got - truth
        agree = 10 * np.log10((truth ** 2).sum() / max((err ** 2).sum(), 1e-20))
        worst = min(worst, agree)
        print(f'{name:11s} largest difference {np.abs(err).max():.2e}   agreement {agree:6.1f} dB')
    sys.exit(0 if worst > 90 else 'they do not agree')
