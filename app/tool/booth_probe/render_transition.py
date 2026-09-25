#!/usr/bin/env python3
"""A transition rendered offline, the way the booth would play it, and measured.

Two records prepared by prepare_records.py, a move from transitions.json (the booth's
own tables, dumped by test/curves_dump_test.dart), the bars, and where the old record
goes out and the new one comes in. The new record is stretched to the old one's tempo
(ffmpeg's rubberband where it has it, atempo otherwise), parked so that its in point
falls on the out point, and the two are mixed frame by frame as the booth does it: the
fader and each stem's level travelled to, the bands and the filter as block gains in
the frequency domain, loops read back from where they were caught. Out: a WAV of the
stretch around the move, and the numbers:

  vocal_overlap_s   seconds in which both voices are heard at once (over -30 dBFS)
  loudness_range_db how far the level strays from the record before, over the move
  dip_db            the deepest the mix sinks under the louder of the two records as
                    they are (a second at a time): level the move threw away
  phase_error_ms    how far the new record's kicks fall from the old one's, over the
                    overlap — what beat-matching left
  key_clash         chroma disagreement of the two over the overlap, 0 (agree) to 1
  drums_doubled_s   seconds in which both records' drums are heard at once, neither
                    with its bass killed — two kicks
  hole_db           the same over quarter seconds: a short hole
  start_jump_db     how much the level jumps at the move's first instant (a fader that
                    opens on a step rather than travels there)
  end_jump_db       the same at its last (a tail cut, a fader not yet across)
  fx_db             how loud the booth's own sound (a riser, a sweep, a gush) is at its
                    loudest second against the mix under it — how much of what is heard
                    is the booth rather than the records

  render_transition.py <dir> <idA> <idB> <kind> <bars> [--out ms] [--in ms] [--shift st] [--wav f]
"""
import argparse
import math
import json
import os
import pathlib
import subprocess
import sys

import numpy as np

HERE = pathlib.Path(__file__).resolve().parent
RATE = 44100
FRAME = int(RATE * 0.04)     # a control step, as the booth's tick
BLOCK = 2048                 # the frequency-domain block for the bands


def in_point(B: dict, bar_ms: int, bars: int) -> int:
    """Where the new record is parked, as AutoMix.inPoint parks it: so many bars before
    its intro ends — unless those bars are quiet (8 dB under the record's loud bars, by
    the structure), when it comes in later: half way, or already on."""
    first = B["cues"]["first_downbeat_ms"]
    mix_in = B["cues"]["mix_in_ms"]
    s = B.get("structure") or {}
    bars_ms, mix_db = s.get("bars_ms") or [], s.get("mix_db") or []
    def quiet(at_ms):
        if not bars_ms or not mix_db:
            return False
        heard = [v for v in mix_db if v > -90]
        loud = sorted(heard)[int(len(heard) * 0.9)] if heard else 0
        i = max(0, sum(1 for b in bars_ms if b <= at_ms) - 1)
        span = [v for v in mix_db[i:i + bars] if v > -90]
        return bool(span) and sum(span) / len(span) < loud - 8
    at = mix_in - bar_ms * bars
    if at >= first and quiet(at):
        half = mix_in - bar_ms * (bars // 2)
        at = mix_in if quiet(half) else half
    return max(first, at)


def out_point(A: dict, length_ms: int) -> int:
    """Where the old record goes out, as AutoMix.outPoint has it: its outro — but
    never so late that the move runs past the end of its sound — on its four-bar grid."""
    end = A["duration_ms"] - A.get("tail_ms", 0)
    at = min(A["cues"]["mix_out_ms"], end - length_ms)
    markers = [m for m in (A.get("four_bars") or []) if m <= at]
    return markers[-1] if markers else max(0, at)


def fx_sounds(shots: list[dict], cache: pathlib.Path, beat_ms: int) -> dict[tuple, np.ndarray]:
    """The booth's own sounds, at the exact lengths this move needs them.

    Asked of the app rather than written again here: `flutter test` renders them from
    lib/src/state/booth/fx_sounds.dart, which is the code the speaker gets. One call
    for all of a move's shots, and every sound cached by its name, its length and the
    beat it was made over, so a set of eleven risers renders one.
    """
    want = {(s["sound"], s["ms"]): None for s in shots}
    missing = [(name, ms) for (name, ms) in want if not (cache / f"{name}-{ms}ms-{beat_ms}b.wav").exists()]
    if missing:
        cache.mkdir(parents=True, exist_ok=True)
        spec = ",".join(f"{name}:{ms}:{beat_ms}" for name, ms in missing)
        app = HERE.parent.parent
        r = subprocess.run(
            [os.environ.get("FLUTTER", "flutter"), "test", "test/fx_sounds_test.dart"],
            cwd=app, capture_output=True,
            env={**os.environ, "FX_OUT": str(cache.resolve()), "FX_SPEC": spec})
        if r.returncode != 0:
            raise SystemExit(f"could not render the booth's sounds:\n{r.stdout.decode()[-2000:]}")
    return {k: wav(cache / f"{k[0]}-{k[1]}ms-{beat_ms}b.wav") for k in want}


def wav(path: pathlib.Path) -> np.ndarray:
    raw = subprocess.run(["ffmpeg", "-v", "error", "-i", str(path), "-ar", str(RATE), "-ac", "2",
                          "-f", "f32le", "-"], capture_output=True, check=True).stdout
    return np.frombuffer(raw, dtype="<f4").reshape(-1, 2).copy()


def stretched(path: pathlib.Path, ratio: float, shift_st: float) -> np.ndarray:
    """[path] at [ratio] times its speed, pitch kept — and shifted by [shift_st]."""
    if abs(ratio - 1) < 1e-4 and shift_st == 0:
        return wav(path)
    scale = 2 ** (shift_st / 12)
    for af in (f"rubberband=tempo={ratio}:pitch={scale}", f"atempo={ratio}"):
        r = subprocess.run(["ffmpeg", "-v", "error", "-i", str(path), "-af", af, "-ar", str(RATE), "-ac", "2",
                            "-f", "f32le", "-"], capture_output=True)
        if r.returncode == 0 and len(r.stdout) > 0:
            return np.frombuffer(r.stdout, dtype="<f4").reshape(-1, 2).copy()
    raise SystemExit("ffmpeg could not stretch the record")


def lerp_steps(steps: list[dict], key, k: float, default: float, hold_last: bool = False):
    """A value travelled to evenly between the steps that set it (the fader, the
    filter, the stems); [hold_last]: the last step's value is not travelled to, as the
    booth holds a stem move's levels to the end."""
    before = after = None
    for s in steps:
        v = key(s)
        if v is None:
            continue
        if s["at"] <= k:
            before = (s["at"], v)
        elif after is None:
            after = (s["at"], v)
    if before is None:
        return after[1] if after is not None else default
    if after is None or (hold_last and after[0] >= 1):
        return before[1]
    span = after[0] - before[0]
    t = 1.0 if span <= 0 else (k - before[0]) / span
    return before[1] + (after[1] - before[1]) * t


def held(steps: list[dict], key, k: float, default):
    got = default
    for s in steps:
        if s["at"] > k:
            break
        v = key(s)
        if v is not None:
            got = v
    return got


def band_gains(freqs: np.ndarray, eq: dict, filt: float, killed: float) -> np.ndarray:
    """The bands and the passes as a gain per bin, like the booth's chain: a low
    shelf at 250, a peak at 1 k, a high shelf at 4 k, a high-pass climbing from 20 Hz
    and a low-pass falling from 15 k with the filter knob."""
    g = np.ones_like(freqs)
    def db(x): return 10 ** (x / 20)
    low, mid, high = eq.get("low", 0), eq.get("mid", 0), eq.get("high", 0)
    g *= 1 + (db(low) - 1) / (1 + (freqs / 250) ** 2)
    g *= 1 + (db(high) - 1) * (freqs ** 2 / (freqs ** 2 + 4000 ** 2))
    g *= 1 + (db(mid) - 1) * np.exp(-((np.log2(np.maximum(freqs, 1) / 1000)) ** 2) / (2 * 1.0 ** 2))
    if filt > 0:
        hp = 10 * (8000 / 10) ** filt
        g *= (freqs ** 2 / (freqs ** 2 + hp ** 2)) ** 2
    elif filt < 0:
        lp = min(15000.0, 22000 * (60 / 22000) ** (-filt))
        g *= (lp ** 2 / (freqs ** 2 + lp ** 2)) ** 2
    return g


def process(x: np.ndarray, control, killed: float) -> np.ndarray:
    """[x] through the bands and filter as [control](block index) says, block by
    block with a Hann window and half overlap."""
    n = len(x)
    out = np.zeros_like(x)
    win = np.hanning(BLOCK).astype(np.float32)
    freqs = np.fft.rfftfreq(BLOCK, 1 / RATE)
    hop = BLOCK // 2
    for start in range(0, n - BLOCK + 1, hop):
        eq, filt = control(start)
        seg = x[start:start + BLOCK] * win[:, None]
        spec = np.fft.rfft(seg, axis=0)
        spec *= band_gains(freqs, eq, filt, killed)[:, None]
        out[start:start + BLOCK] += np.fft.irfft(spec, BLOCK, axis=0)
    return out


def onset_env(x: np.ndarray) -> np.ndarray:
    mono = x.mean(axis=1)
    hop = 441
    n = len(mono) // hop
    e = np.sqrt(np.mean(mono[: n * hop].reshape(n, hop) ** 2, axis=1) + 1e-12)
    return np.maximum(0, np.diff(np.log(e + 1e-9), prepend=0))


def chroma(x: np.ndarray) -> np.ndarray:
    mono = x.mean(axis=1)
    spec = np.abs(np.fft.rfft(mono[: min(len(mono), RATE * 20)] * np.hanning(min(len(mono), RATE * 20))))
    freqs = np.fft.rfftfreq(min(len(mono), RATE * 20), 1 / RATE)
    keep = (freqs >= 55) & (freqs <= 2000)
    pc = (np.round(69 + 12 * np.log2(freqs[keep] / 440)).astype(int)) % 12
    c = np.bincount(pc, weights=np.sqrt(spec[keep]), minlength=12)
    return c / (c.sum() + 1e-9)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("dir"); ap.add_argument("a"); ap.add_argument("b"); ap.add_argument("kind"); ap.add_argument("bars", type=int)
    ap.add_argument("--out", type=int, help="where A goes out, ms"); ap.add_argument("--in", dest="in_", type=int, help="where B comes in, ms")
    ap.add_argument("--shift", type=float, default=0); ap.add_argument("--wav"); ap.add_argument("--json")
    ap.add_argument("--debug", action="store_true", help="the level of A, B and the mix, second by second")
    args = ap.parse_args()
    d = pathlib.Path(args.dir)
    tables = json.loads((HERE / "transitions.json").read_text())
    move = tables[args.kind]
    killed = tables["_eq_killed"]
    A = json.loads((d / f"{args.a}.json").read_text()); B = json.loads((d / f"{args.b}.json").read_text())
    bar_a = 4 * 60000 / A["bpm"]
    ratio = A["bpm"] / B["bpm"]
    while ratio > 2 ** 0.5: ratio /= 2
    while ratio < 2 ** -0.5: ratio *= 2
    out_ms = args.out if args.out is not None else out_point(A, int(bar_a * args.bars))
    in_ms = args.in_ if args.in_ is not None else in_point(B, int(bar_a / ratio), args.bars)
    length = int(bar_a * args.bars)
    pre = int(bar_a * 8); post = int(bar_a * 8)

    stems_a = {n: wav(d / args.a / f"{n}.wav") for n in ("drums", "rest", "vocals")}
    stems_b = {n: stretched(d / args.b / f"{n}.wav", ratio, args.shift) for n in ("drums", "rest", "vocals")}
    def ms_a(ms): return int(ms * RATE / 1000)
    def ms_b(ms): return int(ms / ratio * RATE / 1000)
    start_a = ms_a(out_ms - pre); end_a = ms_a(out_ms + length + post)
    n = end_a - start_a
    a_at = lambda i: start_a + i                         # sample of A at output sample i
    b_off = ms_b(in_ms) - ms_a(out_ms)                   # B's sample at output 0 is start_a + b_off
    # On the bars, as the booth plays them (MixStep.onBars): 0.85 of sixteen is bar 14.
    steps = [dict(s, at=(math.floor(s["at"] * args.bars + 0.5) / args.bars if args.bars > 1 else s["at"])) for s in move["steps"]]
    def k_of(i): return (a_at(i) - ms_a(out_ms)) / max(1, ms_a(out_ms + length) - ms_a(out_ms))

    # Loops: A read back from where a loop was caught.
    loop_state = {"start": None, "len": None}
    a_index = np.arange(n) + start_a
    for s in steps:
        lb = s["decks"].get("A", {}).get("loop_bars")
        if lb is None: continue
        at_sample = ms_a(out_ms) + int(s["at"] * (ms_a(out_ms + length) - ms_a(out_ms)))
        if lb == 0:
            loop_state = {"start": None, "len": None}; continue
        if lb == -1 and loop_state["len"]:
            loop_state["len"] //= 2
        elif lb > 0:
            loop_state = {"start": at_sample, "len": int(lb * bar_a * RATE / 1000)}
        if loop_state["start"] is not None:
            i0 = at_sample - start_a
            rel = np.arange(n - i0)
            a_index[i0:] = loop_state["start"] + (rel % loop_state["len"])
    # (steps after a loop change re-write the index from their own sample on: the
    # loop above is applied in order, later steps overwrite the later stretch.)

    def deck_series(name, stems, index_fn, first_level):
        """Each stem of a deck over the output, before the bands: levels and stems."""
        total = np.zeros((n, 2), np.float32)
        for stem in ("drums", "rest", "vocals"):
            x = stems[stem]
            idx = index_fn()
            valid = (idx >= 0) & (idx < len(x))
            y = np.zeros((n, 2), np.float32)
            y[valid] = x[idx[valid]]
            lv = np.ones(n, np.float32)
            for f in range(0, n, FRAME):
                k = k_of(f)
                if k < 0:
                    v = first_level(stem)
                elif k > 1:
                    v = 1.0 if name == "B" else 0.0
                else:
                    st = lerp_steps(steps, lambda s: (s["decks"].get(name, {}).get("stems") or {}).get(stem), k, 1.0, hold_last=True)
                    v = st
                lv[f:f + FRAME] = v
            total += y * lv[:, None]
        return total

    full = move.get("fader_law") == "full"
    def fader_share(name, k):
        x = lerp_steps(steps, lambda s: s.get("crossfader"), k, 0.0)
        if k < 0: x = 0.0
        if k > 1: x = 1.0
        if full:   # both whole at the middle (Booth.levelsFor full: true)
            return (1.0 if x <= 0.5 else np.cos((x - 0.5) * np.pi)) if name == "A" else (1.0 if x >= 0.5 else np.sin(x * np.pi))
        return np.cos(x * np.pi / 2) if name == "A" else np.sin(x * np.pi / 2)

    def gate_on(raw, name, index):
        """The engine's chop on a deck: its level taken up and down in time with its
        own beat. Counted in the *record's* time — the same axis [index] is in, and the
        axis the desk's expression is evaluated on — so a loop caught under a chop
        keeps its phase, as it does in the booth."""
        if not any(s["decks"].get(name, {}).get("gate") is not None for s in steps):
            return
        origin = (A if name == "A" else B)["cues"]["first_downbeat_ms"] / 1000
        own_beat = 60 / (A if name == "A" else B)["bpm"]
        for f in range(0, n, FRAME):
            k = k_of(f)
            if not 0 <= k <= 1:
                continue
            depth = lerp_steps(steps, lambda s: s["decks"].get(name, {}).get("gate"), k, 0.0)
            if depth <= 0.001:
                continue
            div = held(steps, lambda s: s["decks"].get(name, {}).get("gate_div"), k, 2)
            t = index[f:f + FRAME] / RATE
            raw[f:f + FRAME] *= (1 - depth * (0.5 - 0.5 * np.cos(
                2 * np.pi * (t - origin) / (own_beat / div))))[:, None]

    first_a = lambda stem: 1.0
    first_b = lambda stem: (steps[0]["decks"].get("B", {}).get("stems") or {}).get(stem, 1.0)
    a_raw = deck_series("A", stems_a, lambda: a_index, first_a)
    b_raw = deck_series("B", stems_b, lambda: np.arange(n) + start_a + b_off, first_b)
    gate_on(a_raw, "A", a_index)
    gate_on(b_raw, "B", np.arange(n) + start_a + b_off)
    # The record itself, gone (dry) where the move takes it: the echo's tail is not rendered.
    for name, raw in (("A", a_raw), ("B", b_raw)):
        for f in range(0, n, FRAME):
            k = k_of(f)
            dry = held(steps, lambda s: s["decks"].get(name, {}).get("dry"), k, 1.0) if 0 <= k <= 1 else 1.0
            if dry != 1.0: raw[f:f + FRAME] *= dry

    def control_for(name):
        def control(start):
            k = k_of(start)
            eq = held(steps, lambda s: s["decks"].get(name, {}).get("eq"), k, {}) if 0 <= k <= 1 else {}
            filt = lerp_steps(steps, lambda s: s["decks"].get(name, {}).get("filter"), k, 0.0) if 0 <= k <= 1 else 0.0
            return eq, filt
        return control
    a_eq = process(a_raw, control_for("A"), killed)
    b_eq = process(b_raw, control_for("B"), killed)
    mix = np.zeros((n, 2), np.float32)
    for f in range(0, n, FRAME):
        k = k_of(f)
        mix[f:f + FRAME] = a_eq[f:f + FRAME] * fader_share("A", k) + b_eq[f:f + FRAME] * fader_share("B", k)

    # The booth's own sound, laid over the two records: each shot starts on the step
    # that fires it and runs for its own length, at its own gain. It is *not* touched
    # by the crossfader or the bands — it is a third voice beside them, which is what
    # FxChannel is.
    beat_ms = int(round(bar_a / 4))
    shots = []
    for step in steps:
        f = step.get("fx")
        if not f:
            continue
        ms = int(round(beat_ms * f["beats"] if f.get("beats") else bar_a * args.bars * f.get("span", 0)))
        if ms > 0:
            shots.append({"sound": f["sound"], "ms": ms, "gain_db": f["gain_db"], "at": step["at"]})
    fx = np.zeros((n, 2), np.float32)
    if shots:
        sounds = fx_sounds(shots, d / "fx", beat_ms)
        for shot in shots:
            x = sounds[(shot["sound"], shot["ms"])] * (10 ** (shot["gain_db"] / 20))
            i0 = ms_a(out_ms) + int(shot["at"] * (ms_a(out_ms + length) - ms_a(out_ms))) - start_a
            lo, hi = max(0, i0), min(n, i0 + len(x))
            if hi > lo:
                fx[lo:hi] += x[lo - i0:hi - i0]
        mix += fx

    # ---- the numbers
    i_out, i_end = ms_a(out_ms) - start_a, ms_a(out_ms + length) - start_a
    def rms_db(x): return 20 * np.log10(np.sqrt(np.mean(x ** 2)) + 1e-9)
    if args.debug:
        print(f"out {out_ms} ms  in {in_ms} ms  ratio {ratio:.3f}  b_off {b_off}  window {n / RATE:.1f} s")
        print(f"{'t':>5} {'k':>5} {'A raw':>6} {'B raw':>6} {'A eq':>6} {'B eq':>6} {'mix':>6}")
        for i in range(0, n - RATE, RATE):
            print(f"{i / RATE:5.1f} {k_of(i):5.2f} {rms_db(a_raw[i:i + RATE]):6.1f} {rms_db(b_raw[i:i + RATE]):6.1f} "
                  f"{rms_db(a_eq[i:i + RATE]):6.1f} {rms_db(b_eq[i:i + RATE]):6.1f} {rms_db(mix[i:i + RATE]):6.1f}")
    before = rms_db(mix[max(0, i_out - RATE * 8):i_out])
    win = RATE
    levels = [rms_db(mix[i:i + win]) for i in range(i_out, i_end, win) if i + win <= n]
    loudness_range = max(abs(l - before) for l in levels) if levels else 0.0
    # The dip: how far the mix sinks under what the records offered at that moment —
    # the louder of the two as they are, untouched. A record's own quiet stretch is
    # not the move's fault; a move that takes a record away while the other is still
    # in its intro is.
    def full(stems, index_fn):
        total = np.zeros((n, 2), np.float32)
        for stem in ("drums", "rest", "vocals"):
            x = stems[stem]; idx = index_fn(); valid = (idx >= 0) & (idx < len(x))
            y = np.zeros((n, 2), np.float32); y[valid] = x[idx[valid]]; total += y
        return total
    a_full = full(stems_a, lambda: np.arange(n) + start_a); b_full = full(stems_b, lambda: np.arange(n) + start_a + b_off)
    offered = [max(rms_db(a_full[i:i + win]), rms_db(b_full[i:i + win])) for i in range(i_out, i_end, win) if i + win <= n]
    dip = max([o - l for o, l in zip(offered, levels)] + [0.0])
    # Voices at once: both vocal stems, as the move leaves them, over -30 dBFS.
    va = a_raw[:, :] * 0
    both = 0.0
    fa, fb = fader_share, fader_share
    for i in range(i_out, i_end, win // 4):
        k = k_of(i)
        sa = fa("A", k); sb = fb("B", k)
        # the raw vocal stems again, at the move's levels
        la = lerp_steps(steps, lambda s: (s["decks"].get("A", {}).get("stems") or {}).get("vocals"), k, 1.0, hold_last=True)
        lb = lerp_steps(steps, lambda s: (s["decks"].get("B", {}).get("stems") or {}).get("vocals"), k, 1.0, hold_last=True)
        ia = a_index[i:i + win // 4]; ib = np.arange(i, i + win // 4) + start_a + b_off
        xa = stems_a["vocals"][ia[(ia >= 0) & (ia < len(stems_a["vocals"]))]]
        xb = stems_b["vocals"][ib[(ib >= 0) & (ib < len(stems_b["vocals"]))]]
        if len(xa) and len(xb) and rms_db(xa) + 20 * np.log10(max(sa * la, 1e-6)) > -30 and rms_db(xb) + 20 * np.log10(max(sb * lb, 1e-6)) > -30:
            both += 0.25
    # Two kicks: both drum stems heard, neither deck's low band killed.
    doubled = 0.0
    for i in range(i_out, i_end, win // 4):
        k = k_of(i)
        sa = fa("A", k); sb = fb("B", k)
        la = lerp_steps(steps, lambda s: (s["decks"].get("A", {}).get("stems") or {}).get("drums"), k, 1.0, hold_last=True)
        lb = lerp_steps(steps, lambda s: (s["decks"].get("B", {}).get("stems") or {}).get("drums"), k, 1.0, hold_last=True)
        ea_ = held(steps, lambda s: s["decks"].get("A", {}).get("eq"), k, {}); eb_ = held(steps, lambda s: s["decks"].get("B", {}).get("eq"), k, {})
        if ea_.get("low", 0) <= killed or eb_.get("low", 0) <= killed: continue
        ia = a_index[i:i + win // 4]; ib = np.arange(i, i + win // 4) + start_a + b_off
        xa = stems_a["drums"][ia[(ia >= 0) & (ia < len(stems_a["drums"]))]]
        xb = stems_b["drums"][ib[(ib >= 0) & (ib < len(stems_b["drums"]))]]
        if len(xa) and len(xb) and rms_db(xa) + 20 * np.log10(max(sa * la, 1e-6)) > -30 and rms_db(xb) + 20 * np.log10(max(sb * lb, 1e-6)) > -30:
            doubled += 0.25
    # Holes and jumps: quarter seconds, and the instants either side of the move.
    q = RATE // 4
    holes = [max(rms_db(a_full[i:i + q]), rms_db(b_full[i:i + q])) - rms_db(mix[i:i + q]) for i in range(i_out, i_end, q) if i + q <= n]
    hole = max(holes + [0.0])
    # A jump is the move's doing, not the record's: the mix against the records as
    # they are, either side of the instant.
    def jump(at):
        if at - q < 0 or at + q > n: return 0.0
        ref = lambda i: max(rms_db(a_full[i:i + q]), rms_db(b_full[i:i + q]))
        return abs((rms_db(mix[at:at + q]) - ref(at)) - (rms_db(mix[at - q:at]) - ref(at - q)))
    start_jump = jump(i_out); end_jump = jump(i_end)
    # The booth's own sound against the records under it, at the second it is loudest:
    # a riser that reads +3 is a riser playing the room rather than lifting it.
    fx_db = 0.0
    if shots:
        louds = [(rms_db(fx[i:i + win]), rms_db(mix[i:i + win] - fx[i:i + win]))
                 for i in range(i_out, i_end, win) if i + win <= n]
        louds = [(f, m) for f, m in louds if f > -80]
        fx_db = max((f - m for f, m in louds), default=0.0)
    # The beat: the kicks of the two over the overlap.
    ea = onset_env(a_eq[i_out:i_end]); eb = onset_env(b_eq[i_out:i_end])
    m = min(len(ea), len(eb))
    beat_frames = int(60 / A["bpm"] * RATE / 441)
    best, best_lag = -1, 0
    for lag in range(-beat_frames // 2, beat_frames // 2 + 1):
        x = ea[max(0, lag):m + min(0, lag)]; y = eb[max(0, -lag):m - max(0, lag)]
        c = float(np.dot(x - x.mean(), y - y.mean())) if len(x) > 10 else 0.0
        if c > best: best, best_lag = c, lag
    phase_ms = best_lag * 441 / RATE * 1000
    ca = chroma(a_eq[i_out:i_end]); cb = chroma(b_eq[i_out:i_end])
    key_clash = float(1 - np.dot(ca, cb) / (np.linalg.norm(ca) * np.linalg.norm(cb) + 1e-9))
    result = {
        "a": args.a, "b": args.b, "kind": args.kind, "bars": args.bars, "out_ms": out_ms, "in_ms": in_ms,
        "ratio": round(float(ratio), 4), "vocal_overlap_s": round(float(both), 2),
        "loudness_range_db": round(float(loudness_range), 1), "dip_db": round(float(dip), 1),
        "phase_error_ms": round(float(phase_ms), 1), "key_clash": round(float(key_clash), 3),
        "drums_doubled_s": round(float(doubled), 2), "hole_db": round(float(hole), 1),
        "start_jump_db": round(float(start_jump), 1), "end_jump_db": round(float(end_jump), 1),
        "fx_db": round(float(fx_db), 1),
    }
    print(json.dumps(result))
    if args.json:
        pathlib.Path(args.json).write_text(json.dumps(result))
    if args.wav:
        peak = float(np.abs(mix).max()) or 1.0
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "f32le", "-ar", str(RATE), "-ac", "2", "-i", "pipe:0",
                        str(args.wav)], input=(mix / max(1.0, peak)).astype("<f4").tobytes(), check=True)


if __name__ == "__main__":
    main()
