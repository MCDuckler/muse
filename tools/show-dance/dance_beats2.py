# Beats of every capture in <dir>/joints/*.npz: accent envelope = rises of the joints'
# total acceleration; tempo by autocorrelation; beats by dynamic programming (Ellis 2007).
# Also how rhythmic it is: the envelope on the beats against between them.
import numpy as np, sys, json, glob, os
FPS = 30.0
def envelope(P):
    v = np.diff(P, axis=0) * FPS
    a = np.diff(v, axis=0) * FPS
    e = np.linalg.norm(a, axis=2).sum(1)
    e = np.convolve(e, np.hanning(5) / np.hanning(5).sum(), "same")
    e = np.maximum(0, np.diff(e, prepend=e[0]))
    e = (e - e.mean()) / (e.std() + 1e-9)
    return np.r_[0, 0, e]
def tempo(e, lo=70, hi=170):
    ac = np.correlate(e, e, "full")[len(e) - 1:]
    lags = np.arange(len(ac)); bpm = 60 * FPS / np.maximum(lags, 1)
    m = (bpm >= lo) & (bpm <= hi)
    w = np.exp(-0.5 * (np.log2(bpm / 115) / 0.9) ** 2)
    score = ac * w; score[~m] = -np.inf
    lag = int(np.argmax(score))
    if 1 <= lag < len(ac) - 1:
        y0, y1, y2 = ac[lag - 1], ac[lag], ac[lag + 1]
        lag = lag + 0.5 * (y0 - y2) / (y0 - 2 * y1 + y2 + 1e-9)
    return 60 * FPS / lag, lag
def dp_beats(e, period, tight=100.0):
    n = len(e); score = e.copy(); back = -np.ones(n, int)
    lo, hi = int(period * 0.5), int(period * 2)
    for t in range(hi, n):
        prev = np.arange(t - hi, t - lo)
        pen = -tight * (np.log((t - prev) / period)) ** 2
        k = np.argmax(score[prev] + pen)
        score[t] = e[t] + score[prev][k] + pen[k]; back[t] = prev[k]
    t = int(np.argmax(score[-int(period * 2):])) + n - int(period * 2)
    beats = [t]
    while back[t] >= 0: t = back[t]; beats.append(t)
    return np.array(beats[::-1])
d = sys.argv[1]; out = {}
for f in sorted(glob.glob(f"{d}/joints/*.npz")):
    c = os.path.basename(f)[:-4]
    P = np.load(f)["P"]
    if len(P) < 90: continue
    e = envelope(P)
    bpm, lag = tempo(e)
    b = dp_beats(e, lag)
    mid = ((b[:-1] + b[1:]) // 2)
    sal = float(e[b].mean() - e[mid].mean())
    iv = np.diff(b) / FPS
    speed = np.linalg.norm(np.diff(P, axis=0), axis=2).sum(1) * FPS
    print(f"{c:12s} bpm {bpm:6.1f} beats {len(b):4d} salience {sal:5.2f} iv-cv {iv.std() / iv.mean():.2f}")
    out[c] = {"bpm": bpm, "beats": b.tolist(), "speed": speed.tolist(), "salience": sal, "env": e.tolist()}
json.dump(out, open(f"{d}/beats.json", "w"))
