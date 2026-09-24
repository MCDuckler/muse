"""Where deck B's onsets fell against deck A's, from a recording with A on the left and
B on the right: the lag at which the two onset envelopes line up best, window by window,
labelled with what the test was doing at the time. Positive is B late."""
import sys

import numpy as np
import soundfile as sf

rec, started_file, events_file = sys.argv[1:4]
x, rate = sf.read(rec, dtype="float32")
started = float(open(started_file).read())
events = []
for line in open(events_file):
    t, _, what = line.strip().partition(" ")
    events.append((float(t) - started, what))

HOP, WIN = rate // 400, 1024                    # 2.5 ms hops


KICK = len(sys.argv) > 4 and sys.argv[4] == "kick"
WAVE = len(sys.argv) > 4 and sys.argv[4] == "wave"


def envelope(y: np.ndarray) -> np.ndarray:
    n = (len(y) - WIN) // HOP
    w = np.hanning(WIN).astype(np.float32)
    hz = rate / WIN
    # The whole spectrum, bass-weighted as the analysis weighs it — or the kick drum
    # alone, which is on the beat and never between, so it cannot mistake one for the
    # other the way hats between the beats let the whole spectrum.
    edges = [1, int(150 / hz)] if KICK else [1, int(200 / hz), int(800 / hz), int(3000 / hz), WIN // 2]
    weights = [1.0] if KICK else [2.0, 1.0, 1.0, 0.4]
    out = np.zeros(n, np.float32)
    prev = None
    for s in range(0, n, 4096):
        idx = np.arange(WIN)[None, :] + HOP * np.arange(s, min(n, s + 4096))[:, None]
        mag = np.log1p(100 * np.abs(np.fft.rfft(y[idx] * w, axis=1)))
        joined = mag if prev is None else np.vstack([prev, mag])
        rise = np.maximum(0, np.diff(joined, axis=0))
        if prev is None:
            rise = np.vstack([np.zeros((1, rise.shape[1])), rise])
        for (lo, hi), wt in zip(zip(edges[:-1], edges[1:]), weights):
            out[s:s + len(rise)] += wt * rise[:, lo:hi].sum(1)
        prev = mag[-1:]
    return out - np.convolve(out, np.ones(200) / 200, mode="same")


if WAVE:
    # The same sound on both sides: the waveforms themselves, which line up one way only.
    step_s, span_s = 1.0, 2.0
    rows = []
    reach = int(0.25 * rate)
    t = reach
    while t + int(span_s * rate) + reach < len(x):
        a = x[t:t + int(span_s * rate), 0].astype(np.float64)
        seg = x[t - reach:t + int(span_s * rate) + reach, 1].astype(np.float64)
        if np.sqrt(np.mean(a * a)) > 1e-3 and np.sqrt(np.mean(seg * seg)) > 1e-3:
            n = 1 << int(np.ceil(np.log2(len(seg) + len(a))))
            c = np.fft.irfft(np.fft.rfft(seg, n) * np.conj(np.fft.rfft(a, n)), n)[: 2 * reach + 1]
            i = int(np.argmax(c))
            norm = np.sqrt(np.dot(a, a) * np.dot(seg[i:i + len(a)], seg[i:i + len(a)])) + 1e-12
            rows.append((t / rate, (i - reach) / rate * 1000, c[i] / norm))
        t += int(step_s * rate)
    last = None
    print("\nB against A, by the waveforms (2 s windows; + is B late):")
    for tt, lag, st in rows:
        what = "before"
        for et, e in events:
            if et <= tt:
                what = e
        if what != last:
            print(f"  -- {what}")
            last = what
        print(f"  {tt:6.1f}s  {lag:+7.2f} ms   (match {st:.2f})")
    sys.exit(0)

ea, eb = envelope(x[:, 0]), envelope(x[:, 1])
level_a = np.sqrt(np.convolve(x[:, 0] ** 2, np.ones(rate) / rate, mode="same"))[::HOP][: len(ea)]
level_b = np.sqrt(np.convolve(x[:, 1] ** 2, np.ones(rate) / rate, mode="same"))[::HOP][: len(eb)]
reach = int(0.2 * rate / HOP)
span, step = int(4 * rate / HOP), int(1 * rate / HOP)
rows = []
for s in range(reach, len(ea) - span - reach, step):
    if level_a[s:s + span].min() < 1e-3 or level_b[s:s + span].min() < 1e-3:
        continue
    a = ea[s:s + span]
    c = np.array([np.dot(a, eb[s + L:s + L + span]) for L in range(-reach, reach + 1)])
    i = int(np.argmax(c))
    d = 0.0
    if 0 < i < len(c) - 1:
        p, q, r = c[i - 1], c[i], c[i + 1]
        den = p - 2 * q + r
        d = 0.5 * (p - r) / den if den else 0.0
    lag_ms = (i - reach + d) * HOP / rate * 1000
    strength = c[i] / (np.sqrt(np.dot(a, a) * np.dot(eb[s:s + span], eb[s:s + span])) + 1e-9)
    rows.append((s * HOP / rate, lag_ms, strength))


def phase(t: float) -> str:
    what = "before"
    for et, e in events:
        if et <= t:
            what = e
    return what


print(f"\nB against A, by the sound ({'kick drums' if KICK else 'whole spectrum'}, 4 s windows; + is B late):")
last = None
for t, lag, st in rows:
    p = phase(t)
    if p != last:
        print(f"  -- {p}")
        last = p
    print(f"  {t:6.1f}s  {lag:+7.1f} ms   (match {st:.2f})")
