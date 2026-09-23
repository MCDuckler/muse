"""Replace SCNet FeatureConversion's rfft/irfft (dim=3, ortho) with matmuls against DFT matrices.
ONNX Runtime's CPU DFT kernel was 56% of runtime; a GEMM is what CPUs are good at."""
import math, torch
import models.scnet.separation as sepmod
_cache = {}
def _mats(N, dtype):
    key = (N, dtype)
    if key not in _cache:
        n = torch.arange(N, dtype=torch.float64); K = N // 2 + 1; k = torch.arange(K, dtype=torch.float64)
        ang = 2 * math.pi * torch.outer(n, k) / N                       # (N, K)
        s = 1 / math.sqrt(N)
        fc, fs = torch.cos(ang) * s, -torch.sin(ang) * s                 # rfft: re = x@fc, im = x@fs
        w = torch.full((K,), 2.0, dtype=torch.float64); w[0] = 1; w[-1] = 1 if N % 2 == 0 else 2
        ic = (w[:, None] * torch.cos(ang.T)) * s                         # irfft: x = re@ic + im@is
        is_ = (-w[:, None] * torch.sin(ang.T)) * s
        is_[0] = 0
        if N % 2 == 0: is_[-1] = 0
        _cache[key] = [m.to(dtype) for m in (fc, fs, ic, is_)]
    return _cache[key]
def forward(self, x):
    x = x.float()
    if self.inverse:
        h = self.channels // 2
        re, im = x[:, :h], x[:, h:]
        N = 2 * (x.shape[3] - 1)
        _, _, ic, is_ = _mats(N, x.dtype)
        return re @ ic + im @ is_
    fc, fs, _, _ = _mats(x.shape[3], x.dtype)
    return torch.cat([x @ fc, x @ fs], dim=1)
def install(): sepmod.FeatureConversion.forward = forward
