#!/usr/bin/env python3
"""Two made-up records in stems, for measuring the moves without a library: what the
third pass of EVAL.md was measured on, written down this time.

  make_pair.py <dir> [bpm]

Each record is 64 bars at [bpm] (120): a kick on every beat and a hat on the offbeats
(drums), a bass note and a chord (rest), a sung vowel over the middle (vocals), a quiet
eight-bar intro and outro, and a drop at bar 16 where the bass and the chord open up.
Written as <dir>/<id>/{drums,rest,vocals}.wav and <dir>/<id>.json in the shape
prepare_records.py writes — enough of it for render_transition.py and eval_pairs.py.
The two differ in key (A minor 8A, E minor 9A) and in voice range, so a move between
them is not a move between a record and itself."""
import json, pathlib, sys
import numpy as np
import soundfile as sf

SR = 44100
out = pathlib.Path(sys.argv[1]); out.mkdir(parents=True, exist_ok=True)
bpm = float(sys.argv[2]) if len(sys.argv) > 2 else 120.0
beat = 60 / bpm
bars = 64
n = int(bars * 4 * beat * SR)
t = np.arange(n) / SR
bar_of = lambda i: (i / SR) / (4 * beat)


def env(on, length, decay):
    return np.exp(-np.maximum(0, t - on) / decay) * (t >= on) * (t < on + length)


def record(id_, root_hz, voice_hz, camelot, seed):
    rng = np.random.default_rng(seed)
    drums = np.zeros(n); rest = np.zeros(n); vocals = np.zeros(n)
    loud = np.where((bar_of(np.arange(n)) >= 8) & (bar_of(np.arange(n)) < 56), 1.0, 0.35)
    dropped = bar_of(np.arange(n)) >= 16
    for b in range(bars * 4):
        on = b * beat
        i0 = int(on * SR); i1 = min(n, i0 + int(0.25 * SR))
        seg = t[i0:i1] - on
        # kick: a sine falling 120 -> 45 Hz over 60 ms
        f = 45 + 75 * np.exp(-seg / 0.06)
        drums[i0:i1] += np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-seg / 0.12) * 0.9
        # hat on the offbeat
        h0 = int((on + beat / 2) * SR); h1 = min(n, h0 + int(0.06 * SR))
        drums[h0:h1] += rng.standard_normal(h1 - h0) * np.exp(-(t[h0:h1] - on - beat / 2) / 0.02) * 0.25
    # bass: root every beat, an octave lower, held; opens up (louder, longer) at the drop
    for b in range(bars * 4):
        on = b * beat; i0 = int(on * SR); i1 = min(n, i0 + int(beat * SR))
        seg = t[i0:i1] - on
        amp = 0.55 if dropped[i0] else 0.25
        rest[i0:i1] += np.sin(2 * np.pi * root_hz / 2 * seg) * np.exp(-seg / (0.5 if dropped[i0] else 0.18)) * amp
    # chord: root, minor third, fifth, held as a pad, two octaves up, from bar 4
    for k, ratio in enumerate([1.0, 2 ** (3 / 12), 2 ** (7 / 12)]):
        rest += 0.09 * np.sin(2 * np.pi * root_hz * 2 * ratio * t + k) * (bar_of(np.arange(n)) >= 4)
    # voice: a vowel (three formant-ish partials) with vibrato, sung bars 20-48 in phrases
    vib = 1 + 0.006 * np.sin(2 * np.pi * 5.5 * t)
    for k, (ratio, w) in enumerate([(1.0, 0.5), (2.0, 0.3), (3.0, 0.15), (4.0, 0.08)]):
        vocals += w * np.sin(2 * np.pi * voice_hz * ratio * np.cumsum(vib) / SR + k)
    sung = np.zeros(n)
    for phrase in range(20, 48, 4):
        i0 = int(phrase * 4 * beat * SR); i1 = int((phrase + 3) * 4 * beat * SR)
        sung[i0:i1] = 1.0
    sung = np.convolve(sung, np.ones(int(0.05 * SR)) / int(0.05 * SR), mode="same")
    vocals *= sung * 0.7
    drums *= loud; rest *= loud
    for name, x in (("drums", drums), ("rest", rest), ("vocals", vocals)):
        (out / id_).mkdir(exist_ok=True)
        sf.write(out / id_ / f"{name}.wav", np.stack([x, x], 1).astype(np.float32), SR, subtype="FLOAT")
    mix = drums + rest + vocals
    bar_ms = [int(b * 4 * beat * 1000) for b in range(bars)]
    def bar_db(x):
        outv = []
        for b in range(bars):
            i0 = int(b * 4 * beat * SR); i1 = min(n, int((b + 1) * 4 * beat * SR))
            r = float(np.sqrt(np.mean(x[i0:i1] ** 2)) + 1e-9)
            outv.append(round(20 * np.log10(r), 2))
        return outv
    downbeats = bar_ms
    beats = [int(b * beat * 1000) for b in range(bars * 4)]
    sections = [
        {"label": "intro", "start_bar": 0, "end_bar": 8, "start_ms": bar_ms[0], "end_ms": bar_ms[8], "drums": True, "vocals": False},
        {"label": "build", "start_bar": 8, "end_bar": 16, "start_ms": bar_ms[8], "end_ms": bar_ms[16], "drums": True, "vocals": False},
        {"label": "drop", "start_bar": 16, "end_bar": 32, "start_ms": bar_ms[16], "end_ms": bar_ms[32], "drums": True, "vocals": True},
        {"label": "breakdown", "start_bar": 32, "end_bar": 40, "start_ms": bar_ms[32], "end_ms": bar_ms[40], "drums": True, "vocals": True},
        {"label": "drop", "start_bar": 40, "end_bar": 56, "start_ms": bar_ms[40], "end_ms": bar_ms[56], "drums": True, "vocals": True},
        {"label": "outro", "start_bar": 56, "end_bar": 64, "start_ms": bar_ms[56], "end_ms": int(n / SR * 1000), "drums": True, "vocals": False},
    ]
    j = {
        "id": id_, "bpm": bpm, "duration_ms": int(n / SR * 1000), "lead_ms": 0, "tail_ms": 0,
        "camelot": camelot, "key_confidence": 0.9,
        "beats": beats, "downbeats": downbeats, "bar_starts_on": 0,
        "four_bars": [bar_ms[b] for b in range(0, bars, 4)],
        "phrases": [bar_ms[b] for b in range(0, bars, 8)],
        "drops": [bar_ms[16], bar_ms[40]],
        "energy": [int(255 * 10 ** ((v - max(bar_db(mix))) / 20 * 0.7)) for v in bar_db(mix)],
        "cues": {"first_downbeat_ms": 0, "mix_in_ms": bar_ms[8], "mix_out_ms": bar_ms[56], "sound_end_ms": int(n / SR * 1000)},
        "structure": {
            "bars_ms": bar_ms, "mix_db": bar_db(mix), "drums_db": bar_db(drums), "rest_db": bar_db(rest),
            "vocals_db": bar_db(vocals), "lufs": -12.0, "sections": sections,
            "drops_ms": [bar_ms[16], bar_ms[40]], "breakdowns_ms": [bar_ms[32]],
            "outs": [], "ins": [], "sources": {"stems": True},
        },
    }
    (out / f"{id_}.json").write_text(json.dumps(j))
    print(f"{id_}: {bars} bars at {bpm}, {camelot}")


record("901", 110.0, 220.0, "8A", 1)
record("902", 82.41, 196.0, "9A", 2)
