"""Two click tracks with exact grids, for integration_test/booth_sync_test.dart.

A: 124 a minute, clicking at 1 kHz over a 220 Hz tone. B: 127, clicking at 3 kHz over
440 Hz. Soft-edged clicks, so each stays in its own band and can be told apart in a
recording of both; a quiet tone under each, so a gap in either shows.
"""
import json
import sys

import numpy as np
import soundfile as sf

SR = 44100
out = sys.argv[1]
# A's own tempo: 124 by default; another to test a master playing at a pitch.
a_bpm = float(sys.argv[2]) if len(sys.argv) > 2 else 124.0


def track(bpm, click_hz, bed_hz, seconds, name):
    n = int(seconds * SR)
    t = np.arange(n) / SR
    x = 0.05 * np.sin(2 * np.pi * bed_hz * t)
    beats = np.arange(0, seconds - 0.1, 60.0 / bpm)
    length = int(0.012 * SR)
    k = np.arange(length) / SR
    burst = 0.6 * np.sin(2 * np.pi * click_hz * k) * np.hanning(length)
    for i, b in enumerate(beats):
        s = int(round(b * SR))
        x[s:s + length] += (1.0 if i % 4 == 0 else 0.7) * burst[:max(0, min(length, n - s))]
    sf.write(f'{out}/{name}.wav', np.stack([x, x], 1).astype(np.float32), SR, subtype='FLOAT')
    ms = [int(round(b * 1000)) for b in beats]
    return {'bpm': bpm, 'beats': ms, 'downbeats': ms[::4], 'duration_ms': int(seconds * 1000)}


json.dump({'a': track(a_bpm, 1000, 220, 70, 'a'), 'b': track(127.0, 3000, 440, 70, 'b')},
          open(f'{out}/grids.json', 'w'))
