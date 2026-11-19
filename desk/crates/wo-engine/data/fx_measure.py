"""Measures rekordbox's effects, and the engine's, alike: a recording of one effect on a
record (rekordbox's master, or `fx_demo`'s render) is lined up on the record itself to the
sample, the record's own sound taken out at rekordbox's gain, and what the effect added or
took away measured, in the record's beats:

  - the span it is heard, how much of it there is (dB under the record) and its tone
    (octave bands, dB against the record);
  - its tail once off: how fast it falls (dB a beat, RT60) and, for the echoes, how far
    apart the repeats are and how much each falls;
  - filters: where the pass band's edges go (Hz) and any resonance; flanger and phaser:
    the comb's delay (ms) and the notch (Hz), and their LFO's period (beats);
  - TRANS: its period, how long it is open (duty) and how deep it cuts; PITCH: its shift
    (cents); the rolls: how far behind the record they play and their loop's length.

  python -I fx_measure.py DRY_DIR REC.wav [REC.wav ...] [--kind echo] [--json OUT.json]

DRY_DIR holds `fx_demo`'s dry.wav (the whole record, 48 kHz) and grid.txt. The kind comes
from the file's name (beat-02-echo.wav, color-space.wav, release-backspin.wav) unless
--kind says. A recording at another rate is resampled with ffmpeg first. numpy only.
"""
import json
import os
import struct
import subprocess
import sys
import tempfile

import numpy as np

R = 48_000
FRAME = 2400  # 50 ms
OCTAVES = [63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]


def read_wav(path):
    b = open(path, "rb").read()
    if b[:4] != b"RIFF" or b[8:12] != b"WAVE":
        raise ValueError(f"{path}: not a WAV file")
    i, fmt, data = 12, None, None
    while i + 8 <= len(b):
        tag, size = b[i:i + 4], struct.unpack("<I", b[i + 4:i + 8])[0]
        body = b[i + 8:i + 8 + size]
        if tag == b"fmt ":
            kind, ch, sr = struct.unpack("<HHI", body[:8])
            bits = struct.unpack("<H", body[14:16])[0]
            if kind == 0xFFFE:
                kind = struct.unpack("<H", body[24:26])[0]
            fmt = (kind, ch, sr, bits)
        elif tag == b"data":
            data = body
        i += 8 + size + (size & 1)
    kind, ch, sr, bits = fmt
    if kind == 3:
        x = np.frombuffer(data, dtype="<f4" if bits == 32 else "<f8").astype(np.float64)
    elif bits == 16:
        x = np.frombuffer(data, dtype="<i2") / 32768.0
    elif bits == 24:
        u = np.frombuffer(data[: len(data) // 3 * 3], dtype=np.uint8).reshape(-1, 3).astype(np.int32)
        v = u[:, 0] | (u[:, 1] << 8) | (u[:, 2] << 16)
        x = np.where(v >= 1 << 23, v - (1 << 24), v) / float(1 << 23)
    elif bits == 32:
        x = np.frombuffer(data, dtype="<i4") / 2147483648.0
    else:
        raise ValueError(f"{path}: {bits}-bit PCM")
    x = x[: len(x) // ch * ch].reshape(-1, ch)
    if ch == 1:
        x = np.repeat(x, 2, axis=1)
    return sr, x[:, :2]


def read_48k(path):
    sr, x = read_wav(path)
    if sr == R:
        return x
    tmp = os.path.join(tempfile.mkdtemp(), "r.wav")
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", path, "-af", "aresample=resampler=soxr", "-ar", str(R), "-c:a", "pcm_f32le", tmp], check=True)
    return read_wav(tmp)[1]


def xcorr(a, b):
    """c[k] = sum a[n + k] b[n], for k from -(len(b) - 1) to len(a) - 1 (index k + len(b) - 1)."""
    n = 1 << int(np.ceil(np.log2(len(a) + len(b))))
    c = np.fft.irfft(np.fft.rfft(a, n) * np.conj(np.fft.rfft(b, n)), n)
    return np.concatenate([c[n - len(b) + 1:], c[: len(a)]])


def onsets(x, d=48):
    """A 1 kHz envelope with its slow part taken out: the record's hits."""
    n = len(x) // d
    e = np.abs(x[: n * d]).reshape(n, d).mean(1)
    k = np.ones(200) / 200
    return e - np.convolve(e, k, "same")


def frac_shift(x, frac):
    """x delayed by `frac` of a sample (FFT, circular: x padded by the caller)."""
    n = len(x)
    f = np.fft.rfftfreq(n)
    return np.fft.irfft(np.fft.rfft(x) * np.exp(-2j * np.pi * f * frac), n)


def fine_lag(xm, ym, lag):
    """`lag` (whole samples, near enough) made exact, to a fraction of a sample, on the
    loudest 3 s of the recording's first quarter (the record still dry there)."""
    q = max(len(ym) // 4, 3 * R)
    e = np.convolve(ym[:q] ** 2, np.ones(R // 10), "same")
    a = int(np.clip(np.argmax(e) - 1.5 * R, 0, max(0, len(ym) - 3 * R)))
    seg = ym[a:a + 3 * R]
    lo = a + lag - 960
    ref = xm[max(0, lo):lo + 3 * R + 1920]
    cc = xcorr(ref, seg)[len(seg) - 1:]
    k = int(np.argmax(cc[: 1921]))
    frac = 0.0
    if 0 < k < len(cc) - 1:
        y0, y1, y2 = cc[k - 1], cc[k], cc[k + 1]
        den = y0 - 2 * y1 + y2
        frac = 0.5 * (y0 - y2) / den if den != 0 else 0.0
    return max(0, lo) + k - a + frac


def align(dry, rec):
    """Where the recording's first sample is in the record (samples, fractional), and the
    record's piece under the recording, shifted to match it. A record repeats itself bar
    for bar, so the few best places are each tried over the whole recording: the one
    where most of it is the record wins."""
    xm, ym = dry.mean(1), rec.mean(1)
    c = xcorr(onsets(xm), onsets(ym))
    zero = len(ym) // 48 - 1
    cands = []
    for k in np.argsort(c)[::-1]:
        if all(abs(k - j) > 400 for j in cands):
            cands.append(int(k))
        if len(cands) == 12 or c[k] < 0.5 * c[cands[0]]:
            break
    best = None
    for k in cands:
        lag = fine_lag(xm, ym, (k - zero) * 48)
        whole = int(round(lag))
        x = np.zeros(len(ym))
        s0, s1 = max(0, whole), min(len(xm), whole + len(ym))
        if s1 <= s0:
            continue
        x[s0 - whole:s1 - whole] = xm[s0:s1]
        fx_, fy_ = frames(x), frames(ym)
        cr = (fx_ * fy_).sum(1) / np.sqrt((fx_ ** 2).sum(1) * (fy_ ** 2).sum(1) + 1e-30)
        score = int((cr > 0.98).sum())
        if best is None or score > best[0]:
            best = (score, lag)
    lag = best[1]
    whole = int(np.floor(lag))
    pad = 4096
    i0 = whole - pad
    piece = np.zeros((len(rec) + 2 * pad, 2))
    s0, s1 = max(0, i0), min(len(dry), i0 + len(piece))
    if s1 > s0:
        piece[s0 - i0:s1 - i0] = dry[s0:s1]
    f = lag - whole
    piece = np.stack([frac_shift(piece[:, ch], -f) for ch in (0, 1)], 1)
    return lag, piece[pad:pad + len(rec)]


def frames(x, n=FRAME):
    m = len(x) // n
    return x[: m * n].reshape(m, n, *x.shape[1:])


def energy(x, n=FRAME):
    f = frames(x, n)
    return (f ** 2).reshape(len(f), -1).mean(1)


class Grid:
    def __init__(self, path):
        lines = open(path).read().split()
        self.bar_one = int(lines[0])
        self.beats = np.array([float(v) for v in lines[1:]])
        self.spb = float(np.median(np.diff(self.beats)))

    def beat(self, t):
        """The beat (fractional, from 0) at `t` seconds into the record."""
        b = self.beats
        t = np.asarray(t, float)
        v = np.interp(t, b, np.arange(len(b)))
        v = np.where(t < b[0], (t - b[0]) / self.spb, v)
        return np.where(t > b[-1], len(b) - 1 + (t - b[-1]) / self.spb, v)


def smooth(v, n):
    if n <= 1:
        return v
    return np.convolve(v, np.ones(n) / n, "same")


def period_of(series, dt, lo, hi):
    """The strongest period of `series` (sampled every `dt`) between lo and hi, same units
    as dt; None if there is none to speak of."""
    s = np.asarray(series, float)
    s = s - s.mean()
    if len(s) < 8 or s.std() == 0:
        return None
    c = np.correlate(s, s, "full")[len(s) - 1:]
    c = c / c[0]
    a, b = int(np.ceil(lo / dt)), min(int(hi / dt), len(c) - 2)
    if b <= a:
        return None
    # the first peak that stands out, not just the largest (its multiples are as large)
    k = None
    for j in range(max(a, 1), b + 1):
        if c[j] > c[j - 1] and c[j] >= c[j + 1] and c[j] > 0.5:
            k = j
            break
    if k is None:
        k = a + int(np.argmax(c[a:b + 1]))
        if c[k] < 0.5:
            return None
    y0, y1, y2 = c[k - 1], c[k], c[k + 1]
    den = y0 - 2 * y1 + y2
    return (k + (0.5 * (y0 - y2) / den if den else 0.0)) * dt


def band_db(spec_r, spec_x, freqs, centres, width=2 ** 0.5):
    out = []
    for fc in centres:
        m = (freqs >= fc / width) & (freqs < fc * width)
        out.append(10 * np.log10((spec_r[m].sum() + 1e-20) / (spec_x[m].sum() + 1e-20)))
    return out


def welch(x, n=1 << 14):
    w = np.hanning(n)
    hop = n // 2
    if len(x) < n:
        x = np.pad(x, (0, n - len(x)))
    acc = np.zeros(n // 2 + 1)
    k = 0
    for i in range(0, len(x) - n + 1, hop):
        acc += np.abs(np.fft.rfft(x[i:i + n] * w)) ** 2
        k += 1
    return acc / max(k, 1)


def stft_power(x, n=4096, hop=1024):
    w = np.hanning(n)
    idx = np.arange(0, len(x) - n + 1, hop)
    return idx, np.array([np.abs(np.fft.rfft(x[i:i + n] * w)) ** 2 for i in idx])


THIRDS = [50 * 2 ** (k / 3) for k in range(25)]  # 50 Hz .. 12.7 kHz


def by_beat(beats, values, reduce, most=24):
    """`values` (at `beats`, from where the effect came on) gathered a beat at a time."""
    beats = np.asarray(beats)
    if not len(beats):
        return []
    out = []
    for k in range(min(most, int(np.floor(beats.max())) + 1)):
        sel = [v for b, v in zip(beats, values) if k <= b < k + 1]
        out.append(reduce(sel) if sel else None)
    return out


def whiten(x):
    """The record's slope, a little smoothed: its hits, not its bass."""
    return np.convolve(np.diff(x, prepend=x[0]), [0.25, 0.5, 0.25], "same")


def bandpass(x, lo, hi):
    f = np.fft.rfftfreq(len(x), 1 / R)
    X = np.fft.rfft(x)
    X[(f < lo) | (f >= hi)] = 0
    return np.fft.irfft(X, len(x))


def echo_taps(r, x, spb, most=4):
    """An echo's repeats, as r = sum a_k x(t - kT): T (the best single lag of the whitened
    record under the whitened residual, 0.05 to 2.2 beats) and the a_k, solved together
    (a record's own repeats would bias them one at a time); also per octave."""
    rw, xw = whiten(r), whiten(x)
    lo, hi = int(0.05 * spb * R), int(2.2 * spb * R)
    if len(rw) < hi * 2:
        return None
    c = xcorr(rw, xw)[len(xw) - 1:]
    ex = np.cumsum(xw ** 2)[::-1]  # energy of x[: len - l]
    cn = c[: len(xw)] / np.sqrt(ex * (rw ** 2).sum() + 1e-30)
    T = lo + int(np.argmax(cn[lo:hi]))
    if cn[T] < 0.05:
        return None

    def taps(rr, xx):
        # (k = 0: what the effect does to the record's own sound, a DELAY taking it down)
        n = len(rr)
        cols = [np.concatenate([np.zeros(k * T), xx[: n - k * T]]) for k in range(0, most + 1) if k * T < n // 2]
        A = np.stack(cols, 1)
        a, *_ = np.linalg.lstsq(A[most * T:], rr[most * T:], rcond=None)
        return a

    a = taps(rw, xw)
    out = {"T_beats": T / R / spb, "match": float(cn[T]), "dry": float(a[0]), "a": [float(v) for v in a[1:]]}
    bands = {}
    for fc in (125, 500, 2000, 8000):
        rb, xb = bandpass(r, fc / 2 ** 0.5, fc * 2 ** 0.5), bandpass(x, fc / 2 ** 0.5, fc * 2 ** 0.5)
        bands[str(fc)] = [float(v) for v in taps(rb, xb)[1:]]
    out["bands"] = bands
    return out


def db(v):
    return round(20 * np.log10(abs(v) + 1e-9), 1)


def measure(dry, grid, rec, kind):
    lag, x = align(dry, rec)
    y = rec
    xm, ym = x.mean(1), y.mean(1)
    t_rec = lambda i: (i + lag) / R  # noqa: E731  (record time of a recording sample)
    # rekordbox's gain, on the frames where the recording is the record (before the effect)
    fx_, fy_ = frames(xm), frames(ym)
    dot = (fx_ * fy_).sum(1)
    ex, ey = (fx_ ** 2).sum(1), (fy_ ** 2).sum(1)
    corr = dot / np.sqrt(ex * ey + 1e-30)
    loud = ex > 1e-3 * ex.max()
    good = loud & (corr > 0.995)
    first = np.nonzero(good)[0]
    if len(first) < 10:
        good = loud & (corr > np.quantile(corr[loud], 0.8))
        first = np.nonzero(good)[0]
    head = first[first <= first[0] + 80]  # the first ~4 s of good frames
    g = dot[head].sum() / ex[head].sum()
    r = y - g * x
    rm = r.mean(1)
    er, exg = energy(rm), energy(g * xm)
    wet = 10 * np.log10((er + 1e-12) / (exg + 1e-12))
    floor = float(np.median(wet[head]))
    ws = np.convolve(wet, np.ones(5) / 5, "same")
    # heard: from the first good frame on (before it, a deck starting), in runs of half a
    # beat or more
    spb_f = grid.spb * R / FRAME  # frames a beat
    on = ws > floor + 10
    on[: first[0]] = False
    runs, i = [], 0
    while i < len(on):
        if on[i]:
            j = i
            while j < len(on) and on[j]:
                j += 1
            if j - i >= 0.5 * spb_f:
                runs.append((i, j - 1))
            i = j
        else:
            i += 1
    active = np.array([f for a, b in runs for f in range(a, b + 1)], dtype=int)
    out = {
        "file": None, "kind": kind,
        "at_beat": round(float(grid.beat(lag / R)), 2),
        "gain_db": round(20 * np.log10(abs(g) + 1e-12), 2),
        "floor_db": round(floor, 1),
    }
    if len(active) == 0:
        out["heard"] = False
        return out
    beat_of_frame = lambda f: grid.beat(t_rec((f + 0.5) * FRAME))  # noqa: E731
    f_on, f_last = int(active[0]), int(active[-1])
    b_on, b_last = float(beat_of_frame(f_on)), float(beat_of_frame(f_last))
    out["heard"] = True
    out["on_beat"] = round(b_on, 2)
    out["heard_beats"] = round(b_last - b_on, 2)
    # its plateau: from half a bar after it comes on to half a bar before four bars are up
    # (a hand on the button is not exact), but not past where it is last heard
    p0 = f_on + int(2 * spb_f)
    p1 = min(f_on + int(14 * spb_f), f_last)
    if kind.startswith("color"):
        p0, p1 = f_on, f_last
    p1 = max(p1, p0 + 4)
    s0, s1 = p0 * FRAME, p1 * FRAME
    out["wet_db"] = round(10 * np.log10(er[p0:p1].sum() / (exg[p0:p1].sum() + 1e-12) + 1e-12), 1)
    # its tone, the octaves of what it added against the record's
    sr_, sx_ = welch(rm[s0:s1]), welch(g * xm[s0:s1])
    freqs = np.fft.rfftfreq(1 << 14, 1 / R)
    out["tone_db"] = {str(f): round(float(v), 1) for f, v in zip(OCTAVES, band_db(sr_, sx_, freqs, OCTAVES))}
    # its tail: the residual a beat at a time, from the last time it was as loud as on
    # its plateau down to the floor
    eb = smooth(er, max(1, int(round(spb_f))))
    level = np.median(eb[p0:p1])
    after = np.nonzero(eb[p0:f_last + 1] > level / 2)[0]
    f_off = p0 + (int(after[-1]) if len(after) else 0)
    tail_db = 10 * np.log10(eb / (exg.mean() + 1e-12) + 1e-12)
    stop = np.nonzero(tail_db[f_off:] < floor + 6)[0]
    f_end = f_off + (int(stop[0]) if len(stop) else len(tail_db) - f_off - 1)
    if f_end - f_off > spb_f:
        t = np.arange(f_off, f_end)
        k0 = f_off + int(0.25 * spb_f)
        tt, dd = t[t >= k0], tail_db[f_off:f_end][t >= k0]
        if len(tt) > 4:
            slope = np.polyfit(tt / spb_f, dd, 1)[0]  # dB a beat
            out["tail_db_per_beat"] = round(float(slope), 2)
            out["rt60_s"] = round(float(-60 / slope * grid.spb), 2) if slope < 0 else None
        out["tail_beats"] = round((f_end - f_off) / spb_f, 2)
    # the echoes: their repeats against the record, while it is on (the plateau, and not
    # into the beat before it was turned off); a ping pong's each side alone
    if any(k in kind for k in ("delay", "echo", "ping-pong", "spiral", "helix")):
        e0 = s0
        e1 = min(s1, max(s0 + 2 * R, (f_off - int(spb_f)) * FRAME))
        sides = [("", rm[e0:e1], (g * xm)[e0:e1])]
        if "ping-pong" in kind:
            sides = [("L ", r[e0:e1, 0], g * x[e0:e1, 0]), ("R ", r[e0:e1, 1], g * x[e0:e1, 1])]
        for side, rr, xx in sides:
            t = echo_taps(rr, xx, grid.spb)
            if not t:
                continue
            a = t["a"]
            key = side.strip().lower()
            sfx = f"_{key}" if key else ""
            out["repeat_beats" + sfx] = round(t["T_beats"], 3)
            out["repeat_match" + sfx] = round(t["match"], 2)
            out["dry_db" + sfx] = db(1 + t["dry"])
            out["repeats_db" + sfx] = [db(v) for v in a]
            out["repeat_fall_db" + sfx] = round(float(np.median([db(a[k + 1]) - db(a[k]) for k in range(len(a) - 1)])), 1) if len(a) > 1 else None
            out["first_repeat_db_by_octave" + sfx] = {f: db(v[0]) for f, v in t["bands"].items()}
            out["fall_db_by_octave" + sfx] = {f: round(db(v[1]) - db(v[0]), 1) for f, v in t["bands"].items() if len(v) > 1}
    # filters: the pass band's edges, a frame at a time, over 1/3 octaves
    idx, PY = stft_power(ym[s0:s1])
    _, PX = stft_power(g * xm[s0:s1])
    if len(idx):
        f4 = np.fft.rfftfreq(4096, 1 / R)
        H = np.array([band_db(py, px, f4, THIRDS, 2 ** (1 / 6)) for py, px in zip(PY, PX)])
        lows, highs, peaks = [], [], []
        for h in H:
            ok = np.nonzero(h > -6)[0]
            # (nothing through: shut, its edges crossed)
            lows.append(THIRDS[ok[0]] if len(ok) else THIRDS[-1])
            highs.append(THIRDS[ok[-1]] if len(ok) else THIRDS[0])
            peaks.append(h.max())
        if lows:
            out["low_edge_hz"] = [round(float(np.percentile(lows, 5))), round(float(np.percentile(lows, 95)))]
            out["high_edge_hz"] = [round(float(np.percentile(highs, 5))), round(float(np.percentile(highs, 95)))]
            out["resonance_db"] = round(float(np.percentile(peaks, 95)), 1)
            # a beat at a time (from where it is first heard), the slower sweeps' shape
            beat_at = grid.beat(t_rec(s0 + idx + 2048)) - b_on
            out["edges_by_beat"] = by_beat(beat_at, list(zip(lows, highs)), lambda v: [round(float(np.median([a for a, _ in v]))), round(float(np.median([b for _, b in v])))])
            dt = 1024 / R / grid.spb
            span = len(H) * dt
            pl = period_of(np.log2(lows), dt, 0.4, span / 2)
            ph = period_of(np.log2(highs), dt, 0.4, span / 2)
            per = [v for v in (pl, ph) if v]
            if per and not kind.startswith("color"):
                out["sweep_beats"] = round(max(per), 2)
    # flanger and phaser: the comb's delay and the deepest notch
    if any(k in kind for k in ("flanger", "phaser", "helix", "sweep", "spiral")):
        d_r = np.diff(rm[s0:s1])
        d_x = np.diff(xm[s0:s1])
        taus, qual, at = [], [], []
        for i in range(960, len(d_r) - FRAME, FRAME // 2):
            at.append(grid.beat(t_rec(s0 + i + FRAME // 2)) - b_on)
            a = d_r[i:i + FRAME]
            b = d_x[i - 960:i + FRAME]
            c = xcorr(b, a)[len(a) - 1:][: 961][::-1]  # c[l] = sum a[n] b'[n - l]
            c = np.abs(c) / np.sqrt((a ** 2).sum() * (b[960:] ** 2).sum() + 1e-20)
            l = 15 + int(np.argmax(c[15:]))
            taus.append(l / R * 1000)
            qual.append(c[l])
        if taus:
            taus = np.array(taus)
            out["delay_ms"] = [round(float(np.percentile(taus, 5)), 2), round(float(np.percentile(taus, 95)), 2)]
            out["delay_match"] = round(float(np.median(qual)), 2)
            out["delay_by_beat"] = by_beat(at, list(taus), lambda v: round(float(np.median(v)), 2))
            dt = (FRAME // 2) / R / grid.spb
            p = period_of(taus, dt, 0.4, len(taus) * dt / 2)
            if p:
                out["lfo_beats"] = round(p, 2)
        # the notch: a quarter beat at a time (the record's own dips average out), its
        # transfer smoothed over a sixth of an octave, the deepest dip 200 Hz to 5 kHz
        f4 = np.fft.rfftfreq(4096, 1 / R)
        band = (f4 > 200) & (f4 < 5000)
        q = np.floor((grid.beat(t_rec(s0 + idx + 2048)) - b_on) * 4)
        notch, at = [], []
        for v in np.unique(q):
            sel = q == v
            h = 10 * np.log10((PY[sel].sum(0) + 1e-20) / (PX[sel].sum(0) + 1e-20))
            fb = f4[band]
            hs = np.array([h[band][(fb >= f / 2 ** (1 / 12)) & (fb < f * 2 ** (1 / 12))].mean() for f in fb])
            # a dip against its octave round it, not the band's slope
            trend = np.array([hs[(fb >= f / 2 ** 0.5) & (fb < f * 2 ** 0.5)].mean() for f in fb])
            notch.append(float(fb[int(np.argmin(hs - trend))]))
            at.append(v / 4)
        if notch:
            out["notch_hz"] = [round(float(np.percentile(notch, 5))), round(float(np.percentile(notch, 95)))]
            out["notch_by_beat"] = by_beat(at, notch, lambda v: round(float(np.median(v))))
    # TRANS: the gate, 5 ms at a time
    if "trans" in kind:
        gy, gx = energy(ym[s0:s1], 240), energy(g * xm[s0:s1], 240)
        gdb = np.clip(10 * np.log10((gy + 1e-12) / (gx + 1e-12)), -60, 6)
        p = period_of(gdb, 240 / R / grid.spb, 0.1, 2.5)
        out["gate_beats"] = round(p, 3) if p else None
        out["gate_open"] = round(float((gdb > -10).mean()), 2)
        out["gate_depth_db"] = round(float(np.percentile(gdb, 5)), 1)
        # where in the beat it opens: sixteen slots, the median gain in each (dB)
        ph = grid.beat(t_rec(s0 + np.arange(len(gdb)) * 240 + 120)) % 1.0
        out["gate_in_beat_db"] = [round(float(np.median(gdb[(ph >= k / 16) & (ph < (k + 1) / 16)])), 0) for k in range(16)]
    # PITCH: the shift, from the spectra on a scale of cents
    if "pitch" in kind:
        cents = np.arange(0, 6 * 1200, 5)
        hz = 100 * 2 ** (cents / 1200)
        f8 = np.fft.rfftfreq(8192, 1 / R)
        _, QY = stft_power(ym[s0:s1], 8192, 2048)
        _, QX = stft_power(g * xm[s0:s1], 8192, 2048)
        shifts = []
        for qy, qx in zip(QY, QX):
            ly = np.log(np.interp(hz, f8, qy) + 1e-12)
            lx = np.log(np.interp(hz, f8, qx) + 1e-12)
            ly, lx = ly - ly.mean(), lx - lx.mean()
            c = xcorr(ly, lx)
            mid = len(lx) - 1
            k = int(np.argmax(c[mid - 300:mid + 301])) - 300
            shifts.append(k * 5)
        if shifts:
            out["pitch_cents"] = int(np.median(shifts))
    # the rolls, the brakes, the spins: where in the record each frame of it is
    if any(k in kind for k in ("roll", "brake", "backspin", "helix")):
        # each frame looked for near where the record is by now and near where the
        # effect came on (a roll holds there however far the record runs on)
        n, hop = 2048, 1024
        dxm, dym = whiten(xm), whiten(ym)
        w = int(1.2 * grid.spb * R)
        # (positions in the recording's own samples: x is the record under it, lined up)
        on_at = int(f_on * FRAME)
        pos, offs, quals, ts = [], [], [], []
        for i in range(max(0, (f_on - int(spb_f)) * FRAME), min(len(ym) - n, (f_last + int(2 * spb_f)) * FRAME), hop):
            a = dym[i:i + n]
            if (a ** 2).sum() < 1e-9:
                continue
            here = i
            found = None
            # (where it came on first: a record repeating itself bar for bar matches as
            # well near where it is by now, and a held roll is not there)
            for centre in (on_at, here):
                lo = max(0, centre - w)
                b = dxm[lo:centre + w + n]
                if len(b) < n + 10:
                    continue
                c = xcorr(b, a)[len(a) - 1:][: len(b) - n + 1]
                e = np.sqrt(np.convolve(b ** 2, np.ones(n), "valid")[: len(c)] * (a ** 2).sum() + 1e-20)
                c = c / e
                k = int(np.argmax(c))
                if found is None or c[k] > found[1] + 0.02:
                    found = (lo + k, c[k])
            if found:
                pos.append(found[0])
                offs.append((found[0] - here) / R / grid.spb)
                quals.append(found[1])
                ts.append(grid.beat(t_rec(i)) - b_on)
        if pos:
            pos, offs, quals, ts = map(np.array, (pos, offs, quals, ts))
            ok = quals > 0.5
            step = np.diff(pos[ok]) / R / grid.spb
            back = -step[step < -0.02]
            if len(back):
                # each jump back is a loop less the hop: the loop's length, the jump seen
                # most (a repeating record makes others, whole bars)
                v = max(back, key=lambda j: int((np.abs(back - j) < 0.03).sum()))
                out["loop_beats"] = round(float(np.median(back[np.abs(back - v) < 0.03]) + hop / R / grid.spb), 3)
            during = ok & (ts >= 0) & (ts < b_last - b_on)
            out["behind_beats"] = round(float(-np.min(offs[during])), 2) if during.any() else None
            after = ok & (ts > b_last - b_on + 0.5)
            out["after_off_beats"] = round(float(np.median(offs[after])), 2) if after.any() else None
            out["match"] = round(float(np.median(quals)), 2)
        # where the sound has gone (a brake's stop): the first frame after it comes on
        # 30 dB under the record
        gone = np.nonzero(10 * np.log10((energy(ym)[f_on:] + 1e-12) / (exg[f_on:] + 1e-12)) < -30)[0]
        if len(gone):
            out["silent_after_beats"] = round(len(gone) and float(gone[0] / spb_f), 2)
    return out


SHOW = {
    "delay": ["repeat_beats", "repeat_match", "dry_db", "repeats_db", "first_repeat_db_by_octave", "tail_beats"],
    "echo": ["repeat_beats", "repeat_match", "dry_db", "repeats_db", "repeat_fall_db", "first_repeat_db_by_octave", "fall_db_by_octave", "rt60_s"],
    "ping-pong": ["repeat_beats_l", "repeats_db_l", "repeat_beats_r", "repeats_db_r", "repeat_fall_db_l", "repeat_fall_db_r", "first_repeat_db_by_octave_l"],
    "spiral": ["repeat_beats", "repeat_match", "dry_db", "repeats_db", "repeat_fall_db", "first_repeat_db_by_octave", "fall_db_by_octave", "rt60_s", "delay_ms"],
    "reverb": ["wet_db", "rt60_s", "tail_db_per_beat", "tone_db"],
    "trans": ["gate_beats", "gate_open", "gate_depth_db", "gate_in_beat_db"],
    "filter": ["low_edge_hz", "high_edge_hz", "resonance_db", "sweep_beats", "edges_by_beat"],
    "flanger": ["wet_db", "delay_ms", "lfo_beats", "delay_match", "resonance_db", "delay_by_beat"],
    "phaser": ["wet_db", "notch_hz", "lfo_beats", "resonance_db", "notch_by_beat"],
    "pitch": ["pitch_cents", "wet_db"],
    "slip-roll": ["loop_beats", "behind_beats", "after_off_beats", "match"],
    "roll": ["loop_beats", "behind_beats", "after_off_beats", "match"],
    "vinyl-brake": ["silent_after_beats", "behind_beats", "heard_beats"],
    "helix": ["wet_db", "repeat_beats", "repeats_db", "rt60_s", "loop_beats", "tone_db"],
    "space": ["wet_db", "rt60_s", "low_edge_hz", "high_edge_hz", "tone_db"],
    "dub-echo": ["wet_db", "repeat_beats", "repeats_db", "repeat_fall_db", "rt60_s", "tone_db"],
    "sweep": ["low_edge_hz", "high_edge_hz", "resonance_db", "notch_hz", "edges_by_beat"],
    "noise": ["wet_db", "low_edge_hz", "high_edge_hz", "tone_db"],
    "crush": ["wet_db", "tone_db"],
    "backspin": ["silent_after_beats", "behind_beats", "heard_beats"],
}


def kind_of(path):
    base = os.path.splitext(os.path.basename(path))[0]
    parts = base.split("-")
    if parts[0] == "beat" and len(parts) > 2:
        return "beat-" + "-".join(parts[2:])
    return base


def short(kind):
    for p in ("beat-", "color-", "release-"):
        if kind.startswith(p):
            return kind[len(p):]
    return kind


def main(argv):
    args = [a for a in argv[1:]]
    want_json = None
    forced = None
    if "--json" in args:
        i = args.index("--json")
        want_json = args[i + 1]
        del args[i:i + 2]
    if "--kind" in args:
        i = args.index("--kind")
        forced = args[i + 1]
        del args[i:i + 2]
    dry_dir, recs = args[0], args[1:]
    _, dry = read_wav(os.path.join(dry_dir, "dry.wav"))
    grid = Grid(os.path.join(dry_dir, "grid.txt"))
    results = []
    for path in recs:
        kind = forced or kind_of(path)
        m = measure(dry, grid, read_48k(path), kind)
        m["file"] = os.path.basename(path)
        results.append(m)
        keys = ["at_beat", "gain_db", "floor_db", "on_beat", "heard_beats"] + SHOW.get(short(kind), ["wet_db", "tone_db"])
        print(f"{m['file']}: " + ", ".join(f"{k} {m.get(k)}" for k in keys if k in m))
    if want_json:
        json.dump(results, open(want_json, "w"), indent=1)


if __name__ == "__main__":
    main(sys.argv)
