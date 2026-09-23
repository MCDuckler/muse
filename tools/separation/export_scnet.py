"""SCNet Small → the one-file ONNX network the desktop separator runs.

    python export_scnet.py <msst checkout> <config.yaml> <checkpoint.ckpt> <out.onnx>

What goes in the graph is the network *between* the spectrograms: SCNet's own forward
does torch.stft / torch.istft, which ONNX cannot express usefully, so they are left to
the caller (app/lib/src/separation/scnet.dart does them, and says exactly how).

Two things had to change to make it fast in ONNX Runtime, both measured:
  * the rfft/irfft inside the separation network would export as ONNX DFT ops, which
    were 56% of the runtime on CPU (172 s for a four minute record instead of 85);
    dftpatch.py swaps them for matrix multiplies against the DFT matrix — the same
    numbers to 2e-6;
  * the weights are saved inside the file rather than beside it, so there is one
    thing to fetch and check;
and the exporter's notes on where each node came from are dropped, so the same
network exported anywhere is the same bytes (the app checks them against a hash).
"""
import os
import sys

import numpy as np
import torch

msst, config_path, ckpt_path, out = sys.argv[1:5]
sys.path.insert(0, os.path.abspath(msst))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from utils.settings import get_model_from_config  # noqa: E402  (msst)
import dftpatch  # noqa: E402

dftpatch.install()
model, config = get_model_from_config('scnet', config_path)
state = torch.load(ckpt_path, map_location='cpu', weights_only=False)
model.load_state_dict(state.get('state', state))
model.eval()


class Core(torch.nn.Module):
    """SCNet.forward without the STFT at the start or the iSTFT at the end."""

    def __init__(self, m):
        super().__init__()
        self.m = m

    def forward(self, x):  # (1, 4, bins, frames): left re, left im, right re, right im
        m = self.m
        b, _, fr, t = x.shape
        skips, lengths, originals = [], [], []
        for layer in m.encoder:
            x, skip, length, original = layer(x)
            skips.append(skip)
            lengths.append(length)
            originals.append(original)
        x = m.separation_net(x)
        for fusion, su in m.decoder:
            x = fusion(x, skips.pop())
            x = su(x, lengths.pop(), originals.pop())
        return x.view(b, m.dims[0], -1, fr, t)  # (1, 4, 4, bins, frames)


core = Core(model).eval()
chunk = int(config.audio.chunk_size)  # 485100: eleven seconds at 44.1 kHz
hop = model.hop_length
pad = hop - chunk % hop
if (chunk + pad) // hop % 2 == 0:
    pad += hop
wave = torch.randn(1, 2, chunk + pad)
spec = torch.view_as_real(torch.stft(wave.reshape(-1, chunk + pad), **model.stft_config,
                                     return_complex=True))
spec = spec.permute(0, 3, 1, 2).reshape(1, 4, spec.shape[1], spec.shape[2])
with torch.no_grad():
    want = core(spec)

tmp = out + '.split.onnx'
torch.onnx.export(core, (spec,), tmp, opset_version=18, input_names=['spec'],
                  output_names=['out'], dynamo=True, do_constant_folding=True)
import onnx  # noqa: E402

exported = onnx.load(tmp, load_external_data=True)
# The exporter notes on every node where in the Python it came from — file paths
# included — so the same network exported from another checkout would be different
# bytes, and fail the hash every app checks it against. None of it is used to run it.
for node in exported.graph.node:
    del node.metadata_props[:]
    node.doc_string = ''
exported.graph.doc_string = ''
onnx.save_model(exported, out, save_as_external_data=False)
os.remove(tmp)
if os.path.exists(tmp + '.data'):
    os.remove(tmp + '.data')

import onnxruntime as ort  # noqa: E402

got = ort.InferenceSession(out, providers=['CPUExecutionProvider']).run(
    None, {'spec': spec.numpy()})[0]
diff = float(np.abs(got - want.numpy()).max())
print(f'{out}: input {tuple(spec.shape)}, output {tuple(want.shape)}, '
      f'largest difference from torch {diff:.3g} (values up to {float(want.abs().max()):.3g})')
if diff > 0.1:
    sys.exit('the exported network does not agree with torch')
