# A real record made into what the booth sends MilkDrop each frame, for the bench
# (stage_bench --audio --feed): its sound, and per frame the levels and the hits.
#
#   python milk_feed.py <record> <out dir> [seconds 24]
#
# The loudest stretch of the record (where a drop is, as a rule), [seconds] long:
#   <out>/pcm.raw    s16 mono 44.1 kHz
#   <out>/feed.f32   per frame (60 a second) 8 floats: bass mid treb, their followers
#                    (as milk_feed.dart: 0.55 + the band + the hit), the kick, the snare
#
# The bands and the hits are this file's guess, not the booth's analysis: the low,
# middle and high bands' energy (each ranked within the stretch), the kick a rise in
# the low band and the snare in the middle, each decaying as dyn.hit.* does.
import os, subprocess, sys
import numpy as np

RATE, FPS = 44100, 60
HOP = RATE // FPS  # 735


def decode(path):
    raw = subprocess.run(['ffmpeg', '-v', 'quiet', '-i', path, '-f', 's16le', '-ac', '1', '-ar', str(RATE), '-'],
                         stdout=subprocess.PIPE, check=True).stdout
    return np.frombuffer(raw, np.int16)


def loudest(pcm, seconds):
    n = seconds * RATE
    if len(pcm) <= n:
        return pcm
    sec = np.sqrt(np.add.reduceat(pcm.astype(np.float64) ** 2, np.arange(0, len(pcm), RATE)) / RATE)
    w = seconds
    run = np.convolve(sec, np.ones(w), 'valid')
    start = int(np.argmax(run[: max(1, len(sec) - w)])) * RATE
    return pcm[start:start + n]


def bands(pcm):
    frames = len(pcm) // HOP
    win = np.hanning(2048)
    x = np.pad(pcm.astype(np.float32) / 32768, (1024, 1024))
    freqs = np.fft.rfftfreq(2048, 1 / RATE)
    edges = [(20, 150), (150, 2500), (2500, 12000)]
    out = np.zeros((frames, 3), np.float32)
    for f in range(frames):
        spec = np.abs(np.fft.rfft(x[f * HOP:f * HOP + 2048] * win)) ** 2
        for i, (lo, hi) in enumerate(edges):
            out[f, i] = spec[(freqs >= lo) & (freqs < hi)].sum()
    return np.log1p(out * 100)


def rank(v):
    lo, hi = np.percentile(v, 5), np.percentile(v, 95)
    return np.clip((v - lo) / max(1e-6, hi - lo), 0, 1)


def hits(band, decay=0.82):
    rise = np.maximum(0, np.diff(band, prepend=band[0]))
    rise = rise / max(1e-6, np.percentile(rise, 98))
    # A hit at most every 0.15 s (a kick's own wobble is not another kick).
    out, h, last = np.zeros_like(band), 0.0, -99
    for i, r in enumerate(np.clip(rise, 0, 1)):
        h *= decay
        if r > 0.35 and r > h and i - last >= 9:
            h, last = max(h, r), i
        out[i] = h
    return out


def main():
    src, out = sys.argv[1], sys.argv[2]
    seconds = int(sys.argv[3]) if len(sys.argv) > 3 else 24
    os.makedirs(out, exist_ok=True)
    pcm = loudest(decode(src), seconds)
    b = bands(pcm)
    low, mid, high = rank(b[:, 0]), rank(b[:, 1]), rank(b[:, 2])
    kick, snare, top = hits(b[:, 0]), hits(b[:, 1]), hits(b[:, 2], 0.7)
    lv = np.stack([0.55 + low + 1.7 * kick, 0.55 + mid + 1.5 * snare, 0.55 + high + 1.5 * top], 1)
    att = np.zeros_like(lv)
    a = lv[0].copy()
    for i in range(len(lv)):
        a += (lv[i] - a) * 0.12
        att[i] = a
    feed = np.concatenate([lv, att, kick[:, None], snare[:, None]], 1).astype(np.float32)
    pcm.astype('<i2').tofile(f'{out}/pcm.raw')
    feed.tofile(f'{out}/feed.f32')
    print(f'{src}: {len(feed)} frames, kicks/s {(np.diff((kick > 0.5).astype(int)) > 0).sum() / seconds:.2f} snares/s {(np.diff((snare > 0.5).astype(int)) > 0).sum() / seconds:.2f}')


if __name__ == '__main__':
    main()
