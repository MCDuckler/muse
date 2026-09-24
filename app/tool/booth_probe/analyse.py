"""Where each of B's beats landed against A's in a recording of the booth, and any gap.

    python analyse.py rec.wav

Only the stretch where both are playing counts: before and after, each record's clicks
leak a little into the other's band and read as a perfect match."""
import sys, numpy as np, soundfile as sf
x, sr = sf.read(sys.argv[1]); x = x.mean(axis=1)
def band(lo, hi):
    X = np.fft.rfft(x); f = np.fft.rfftfreq(len(x), 1/sr); X[(f < lo) | (f > hi)] = 0
    return np.fft.irfft(X, len(x))
def clicks(lo, hi):
    y = np.abs(band(lo, hi)); w = int(0.0005*sr); env = np.convolve(y, np.ones(w)/w, 'same')
    floor = np.percentile(env, 20) + 1e-9
    hop = int(0.25*sr); n = len(env)//hop
    peaks = np.array([env[i*hop:(i+1)*hop].max() for i in range(n)])
    out, last = [], -10**9
    for i in range(n):
        lo_i, hi_i = max(0, i-8), min(n, i+9)
        local = peaks[lo_i:hi_i].max()
        if local < floor * 20: continue           # nothing here but the other record
        seg = env[i*hop:(i+1)*hop]; j = int(np.argmax(seg > 0.5*local))
        if seg.max() > 0.5*local and i*hop + j - last > int(0.2*sr):
            # onset: first crossing of half this click's own peak
            k0 = i*hop + j; pk = env[k0:k0+int(0.004*sr)].max()
            s0 = max(0, k0-int(0.006*sr)); k = s0 + int(np.argmax(env[s0:k0+int(0.012*sr)]))
            out.append(k/sr); last = k
    return np.array(out)
a, b = clicks(800, 1300), clicks(2500, 3500)
print(f'clicks: A {len(a)} ({a[0]:.1f}–{a[-1]:.1f} s), B {len(b)} ({b[0]:.1f}–{b[-1]:.1f} s)')
pairs = [(t, (t - a[np.argmin(np.abs(a-t))])*1000) for t in b if np.min(np.abs(a-t)) < 0.24]
t, off = np.array(pairs).T
print(f'both playing: {len(off)} beats, {t[0]:.1f}–{t[-1]:.1f} s ({t[-1]-t[0]:.0f} s)')
print(f'B − A on each beat: median {np.median(off):+.1f} ms, spread (sd) {off.std():.1f} ms, '
      f'nine tenths within {np.percentile(np.abs(off-np.median(off)),90):.1f} ms of it, worst {np.max(np.abs(off)):.1f} ms')
for s in np.array_split(np.arange(len(off)), 8):
    if len(s): print(f'   {t[s[0]]:5.1f}s  {np.median(off[s]):+6.1f} ms  (±{off[s].std():.1f})')
for name, f0 in (('A tone', 220), ('B tone', 440)):
    y = band(f0-30, f0+30); w = int(0.01*sr); n = len(y)//w
    r = np.sqrt((y[:n*w].reshape(n, w)**2).mean(1)); top = np.percentile(r, 95)
    dips = [i*0.01 for i in range(50, n-50)
            if (m := np.median(np.r_[r[i-50:i-3], r[i+4:i+50]])) > 0.3*top and r[i] < 0.4*m]
    merged = [d for k, d in enumerate(dips) if k == 0 or d - dips[k-1] > 0.1]
    print(f'{name}: dropouts {len(merged)}' + (' at ' + ', '.join(f'{d:.2f}s' for d in merged[:8]) if merged else ''))
