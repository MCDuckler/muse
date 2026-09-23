"""One yardstick, every candidate measured against it.

Takes a separator — anything that turns a stereo mix at 32 kHz into an instrumental
and a drums track — and scores it against MUSDB18's real stems. The same tracks, the
same SDR, so the numbers can be put next to each other honestly.

SDR here is the plain energy ratio, not museval's BSS Eval v4 that the papers quote:
BSS Eval allows a distortion filter before scoring and so reads a little higher. It is
the right measure for comparing two of OUR options with each other, and roughly but
not exactly comparable with a published figure.
"""
import os
import sys
import time

import musdb
import numpy as np
from scipy.signal import resample_poly

RATE = 32000
HOW_MANY = 24


def to32k(x, rate=44100):
    return resample_poly(x, RATE, rate, axis=0).astype(np.float32)


def sdr(want, got):
    n = min(len(want), len(got))
    want, got = np.asarray(want[:n], float), np.asarray(got[:n], float)
    err = want - got
    return 10 * np.log10(max((want ** 2).sum(), 1e-12) / max((err ** 2).sum(), 1e-12))


PARTS = ('instrumental', 'drums', 'music')


def run(name, separate, tracks=HOW_MANY, subset=None):
    """[separate] takes (samples, 2) at 32 kHz and returns a dict with any of
    'instrumental', 'drums' and 'music'. Missing ones are simply not scored.

    [subset] None is the first [tracks] of the whole sample set, which are all
    MUSDB18's *training* tracks — the ones every published model learned from, so a
    model scores higher on them than on music it has not heard. 'test' is the held-out
    half, and the honest number for a trained model."""
    db = musdb.DB(download=True, subsets=subset) if subset else musdb.DB(download=True)
    got = {k: [] for k in PARTS}
    nothing = {k: [] for k in PARTS}
    seconds = 0.0
    audio = 0.0
    for t in db[:tracks]:
        mix = to32k(t.audio)
        truth = {k: to32k(t.targets[k].audio) for k in ('accompaniment', 'drums')}
        # "music" is everything but the drums, as the booth has always meant it.
        truth['music'] = to32k(t.audio - t.targets['drums'].audio)
        began = time.time()
        out = separate(mix)
        seconds += time.time() - began
        audio += len(mix) / RATE
        truth['instrumental'] = truth.pop('accompaniment')
        for k in PARTS:
            if k not in out:
                continue
            d = out[k]
            want = truth[k] if np.ndim(d) == 2 else truth[k].mean(axis=1)
            base = mix if np.ndim(d) == 2 else mix.mean(axis=1)
            got[k].append(sdr(want, d))
            nothing[k].append(sdr(want, base))

    print(f"\n=== {name}  [{subset or 'train'}]")
    for k in PARTS:
        if not got[k]:
            continue
        mine, none = np.median(got[k]), np.median(nothing[k])
        worse = sum(1 for a, b in zip(got[k], nothing[k]) if a < b)
        print(f"  {k:12s} median SDR {mine:6.2f} dB   "
              f"(doing nothing {none:6.2f})   {mine - none:+.2f} dB   "
              f"worse than nothing on {worse}/{len(got[k])}")
    print(f"  speed        {audio / max(seconds, 1e-9):6.1f}x realtime "
          f"({seconds:.1f}s for {audio:.0f}s of music, on {os.cpu_count()} threads)")
    return got
