"""What a record is made of, for a booth that mixes on its own: its sections and what
each is doing, where it drops and where it breaks down, how loud each bar is in each
of its parts — and its beats and bars put right by a second opinion.

Built on the house's own analysis (beats.py, analysis.py) from two things the pool's
computers hand in with a record's parts:

  * the **beats and bars** the trained tracker heard (beat_net.dart in the app): its
    beats are only as fine as its frames, so the house keeps its own exact grid where it
    has one and takes from the tracker the one thing the arithmetic guessed at — which
    beat the bar starts on; where the house found no pulse at all, the tracker's beats
    stand on their own;
  * the **stems** (drums; bass and the rest; the voice): how loud each is in every bar
    says what the record is doing there better than the mix can — the drums gone for
    eight bars is a breakdown, the drums and bass back at once after one is a drop, a
    voice is a voice. Sections are read off these by rule, and named the way a DJ names
    them: intro, verse, chorus, inst, breakdown, build, drop, outro.

The answer is the analysis's own JSON (so anything that reads that reads this) with the
bars and sections, the drops and breakdowns, the key per section (from the stems without
the drums), the loudness, and the places a DJ would come in and go out, under
"structure". Kept per record and per what it was built from: it is built again when the
tracker's beats or the stems arrive later.
"""
from __future__ import annotations

import json
import logging
import pathlib
import subprocess

import numpy as np

from . import analysis, beats as _beats, pool

log = logging.getLogger("muse.structure")

VERSION = 1
_RATE = _beats._RATE

# Below this, relative to the record's loudest bars of the same part, a part is not
# playing in a bar.
_DRUMS_OFF_DB = 14.0
_VOICE_ON_DB = 16.0
# A bar this much under the record's loud bars is quiet (an intro, an outro, a break).
_QUIET_DB = 7.0
# The shortest section worth naming, in bars; shorter runs join a neighbour.
_LEAST_BARS = 2
# A breakdown is this long at least; the build is the rising end of it.
_BREAK_BARS = 4
_BUILD_RISE_DB = 3.0


def cache_path(data_dir: pathlib.Path, sha: str, flags: str) -> pathlib.Path:
    return data_dir / "beats" / f"{sha}-structure-v{VERSION}{'-' + flags if flags else ''}.json"


# ------------------------------------------------------------------ decoding
def _mono(path: pathlib.Path, pan: str | None = None) -> np.ndarray:
    raw = subprocess.run(
        ["ffmpeg", "-v", "error", "-i", str(path),
         *(["-af", f"pan=mono|c0={pan}"] if pan else ["-ac", "1"]),
         "-ar", str(_RATE), "-f", "s16le", "-"],
        capture_output=True, timeout=180, check=True).stdout
    return np.frombuffer(raw[: len(raw) // 2 * 2], dtype="<i2").astype(np.float32) / 32768.0


def _stems(path: pathlib.Path) -> dict[str, np.ndarray]:
    """The three stems of the six-channel file, each mono: drums, rest, vocals."""
    return {
        "drums": _mono(path, "0.5*c0+0.5*c1"),
        "rest": _mono(path, "0.5*c2+0.5*c3"),
        "vocals": _mono(path, "0.5*c4+0.5*c5"),
    }


def bar_db(x: np.ndarray, downbeats_ms: list[int]) -> list[float]:
    """How loud [x] is in each bar, in dB below full scale (-100 for nothing)."""
    if len(downbeats_ms) < 2:
        return []
    bounds = list(downbeats_ms) + [downbeats_ms[-1] + (downbeats_ms[-1] - downbeats_ms[-2])]
    out = []
    for a, b in zip(bounds[:-1], bounds[1:]):
        seg = x[int(a * _RATE / 1000):int(b * _RATE / 1000)]
        rms = float(np.sqrt(np.mean(seg * seg))) if len(seg) else 0.0
        out.append(round(max(-100.0, 20 * np.log10(rms + 1e-9)), 1))
    return out


# ------------------------------------------------------------------ the bar
def bar_phase(beats_ms: list[int], neural_downbeats_ms: list[int],
              tolerance_ms: int = 45) -> tuple[int | None, float]:
    """Which beat of four the bar starts on, by where the tracker heard the bars fall
    among the house's beats — and how much of the tracker's word that is. None where
    the tracker's bars fall on no one phase."""
    if len(beats_ms) < 8 or len(neural_downbeats_ms) < 4:
        return None, 0.0
    b = np.array(beats_ms)
    votes = np.zeros(4)
    for d in neural_downbeats_ms:
        i = int(np.argmin(np.abs(b - d)))
        if abs(int(b[i]) - d) <= tolerance_ms:
            votes[i % 4] += 1
    if votes.sum() < 4:
        return None, 0.0
    best = int(np.argmax(votes))
    share = float(votes[best] / votes.sum())
    return (best, share) if share >= 0.6 else (None, share)


def _same_octave(house: list[int], neural: list[int], sources: dict) -> list[int]:
    """The house's beats at the tracker's tempo where the two are an octave apart: the
    house counts the pulse people tap and leans on the kick to double it, and on a
    record whose kick plays every half beat it counts twice too fast — or, on a
    half-time record, half as fast. The tracker has heard the music; the house's grid
    is the finer: so the house's beats are kept and thinned to every other, or filled
    in between, to the tracker's count."""
    h = np.array(house, dtype=float)
    hp = float(np.median(np.diff(h)))
    npd = float(np.median(np.diff(np.array(neural, dtype=float))))
    if hp <= 0 or npd <= 0:
        return house
    ratio = hp / npd
    if 0.45 < ratio < 0.55:
        # Twice too fast: every other beat, from whichever of the two the tracker's
        # beats fall on.
        nb = np.array(neural, dtype=float)
        best, keep = None, house
        for offset in (0, 1):
            thinned = h[offset::2]
            near = [np.min(np.abs(thinned - b)) for b in nb[:: max(1, len(nb) // 64)]]
            score = float(np.mean(near))
            if best is None or score < best:
                best, keep = score, [int(round(x)) for x in thinned]
        sources["octave"] = "halved"
        return keep
    if 1.8 < ratio < 2.2:
        filled = np.empty(2 * len(h) - 1)
        filled[0::2] = h
        filled[1::2] = (h[:-1] + h[1:]) / 2
        sources["octave"] = "doubled"
        return [int(round(x)) for x in filled]
    return house


def _neural_grid(neural: list[int], from_ms: int, to_ms: int) -> list[int]:
    """One exact grid through the tracker's beats — each is only as fine as a frame of
    twenty milliseconds, and a line through hundreds of them is far finer — from where
    the sound starts to where it ends."""
    nb = np.array(neural, dtype=float)
    k = np.arange(len(nb))
    period, at0 = np.polyfit(k, nb, 1)
    before = max(0, int(np.floor((at0 - from_ms) / period)))
    after = max(0, int(np.floor((to_ms - (at0 + period * (len(nb) - 1))) / period)))
    grid = at0 + period * np.arange(-before, len(nb) + after)
    return [int(round(x)) for x in grid if x >= 0]


def _steady(beats_ms: list[int]) -> bool:
    """Whether beats keep one tempo closely enough to be a grid."""
    if len(beats_ms) < 32:
        return False
    ibi = np.diff(np.array(beats_ms, dtype=float))
    mid = ibi[len(ibi) // 8: -len(ibi) // 8 or None]
    return float(np.std(mid) / np.mean(mid)) < 0.05


# ------------------------------------------------------------------ sections
def _runs(states: list) -> list[tuple[int, int, object]]:
    out: list[tuple[int, int, object]] = []
    for i, s in enumerate(states):
        if out and out[-1][2] == s:
            out[-1] = (out[-1][0], i + 1, s)
        else:
            out.append((i, i + 1, s))
    return out


def label_bars(mix_db: list[float], drums_db: list[float] | None,
               vocals_db: list[float] | None) -> list[dict]:
    """The record's sections, as (start_bar, end_bar, label, ...), from how loud the
    mix, the drums and the voice are in each bar. Without stems only the mix speaks:
    intro, on, outro, and quiet stretches as breaks."""
    n = len(mix_db)
    if n < 8:
        return [{"start_bar": 0, "end_bar": n, "label": "on"}] if n else []
    mix = np.array(mix_db)
    heard = mix[mix > -90]
    loud = float(np.percentile(heard, 90)) if len(heard) else 0.0
    quiet = mix < loud - _QUIET_DB
    if drums_db is not None:
        d = np.array(drums_db)
        drums_on = d > (float(np.percentile(d[d > -90], 90)) if (d > -90).any() else 0) - _DRUMS_OFF_DB
    else:
        drums_on = ~quiet
    if vocals_db is not None:
        v = np.array(vocals_db)
        # Against the mix, as vocals.py judges it: a voice is a share of the record.
        voice_on = (v - mix) > -24.0
        voice_on &= v > -60
    else:
        voice_on = np.zeros(n, dtype=bool)

    # One state a bar; runs shorter than _LEAST_BARS join the longer neighbour.
    # Quiet only matters where the drums play: a breakdown is one thing from the drums
    # going to the drums coming back, however it climbs on the way.
    states = [(bool(drums_on[i]), bool(quiet[i]) and bool(drums_on[i]), bool(voice_on[i]))
              for i in range(n)]
    while True:
        runs = _runs(states)
        short = [r for r in runs if r[1] - r[0] < _LEAST_BARS]
        if len(runs) <= 1 or not short:
            break
        a, b, s = min(short, key=lambda r: r[1] - r[0])
        k = runs.index((a, b, s))
        left = runs[k - 1] if k > 0 else None
        right = runs[k + 1] if k + 1 < len(runs) else None
        into = left if (left and (not right or (left[1] - left[0]) >= (right[1] - right[0]))) else right
        for i in range(a, b):
            states[i] = into[2]

    # Names. The song is "on" where the drums play and it is not quiet.
    on = [(not q) and dr for (dr, q, _) in [r[2] for r in runs]]
    first_on = next((k for k, x in enumerate(on) if x), None)
    last_on = next((k for k in range(len(on) - 1, -1, -1) if on[k]), None)
    out = []
    for k, (a, b, (dr, q, vo)) in enumerate(runs):
        if first_on is None:
            label = "on"
        elif k < first_on:
            label = "intro"
        elif last_on is not None and k > last_on:
            label = "outro"
        elif not dr:
            label = "breakdown" if b - a >= _BREAK_BARS else "break"
        elif q:
            label = "break"
        else:
            # Playing. After a breakdown it is the drop; otherwise by the voice and by
            # how hard it hits.
            before = runs[k - 1][2] if k > 0 else None
            if before is not None and not before[0] and k > first_on:
                label = "drop"
            elif vo:
                label = "chorus" if float(mix[a:b].mean()) >= loud - 2.0 else "verse"
            else:
                label = "inst"
        out.append({"start_bar": a, "end_bar": b, "label": label,
                    "drums": bool(dr), "vocals": bool(vo),
                    "energy_db": round(float(mix[a:b].mean()), 1)})

    # The rising end of a breakdown is the build: the last bars before the drop where
    # the mix climbs.
    for k, s in enumerate(out):
        if s["label"] != "breakdown" or k + 1 >= len(out) or out[k + 1]["label"] != "drop":
            continue
        a, b = s["start_bar"], s["end_bar"]
        for start in range(max(a + _BREAK_BARS, b - 8), b - 1):
            if mix[b - 1] - mix[start] >= _BUILD_RISE_DB and np.all(np.diff(mix[start:b]) >= -1.0):
                s["end_bar"] = start
                out.insert(k + 1, {"start_bar": start, "end_bar": b, "label": "build",
                                   "drums": False, "vocals": s["vocals"],
                                   "energy_db": round(float(mix[start:b].mean()), 1)})
                break
    return [s for s in out if s["end_bar"] > s["start_bar"]]


# ------------------------------------------------------------------ the whole of it
def build(data_dir: pathlib.Path, track: dict, timing: dict,
          neural: dict | None, stems_path: pathlib.Path | None) -> dict:
    out = dict(timing)
    sources = {"beats": "tracked", "bar_phase": "house", "stems": stems_path is not None,
               "neural": neural is not None}
    beats_ms = list(timing.get("beats") or [])
    bar_on = int(timing.get("bar_starts_on") or 0)
    if timing.get("grid"):
        sources["beats"] = "grid"
    # The tracker's word on the bar; or its beats altogether where the house has none.
    if neural and _steady(neural["beats_ms"]):
        if len(beats_ms) >= 8:
            beats_ms = _same_octave(beats_ms, neural["beats_ms"], sources)
        hp = float(np.median(np.diff(np.array(beats_ms)))) if len(beats_ms) >= 8 else None
        npd = float(np.median(np.diff(np.array(neural["beats_ms"]))))
        if hp is None or not 0.97 < hp / npd < 1.03:
            # The house counted another tempo altogether (or none): the tracker's
            # beats, on one exact line through them, carried to the sound's ends.
            beats_ms = _neural_grid(neural["beats_ms"], timing.get("lead_ms", 0),
                                    timing["duration_ms"] - timing.get("tail_ms", 0))
            sources["beats"] = "neural"
            sources.pop("octave", None)
        if sources["beats"] == "neural" or sources.get("octave"):
            out["bpm"] = round(60000.0 / float(np.median(np.diff(np.array(beats_ms)))), 2)
    if neural:
        phase, share = bar_phase(beats_ms, neural["downbeats_ms"])
        if phase is not None:
            sources["bar_phase"] = "neural"
            sources["bar_phase_agreement"] = round(share, 2)
            bar_on = phase
        elif len(beats_ms) < 8 and _steady(neural["beats_ms"]):
            beats_ms = list(neural["beats_ms"])
            nb = np.array(beats_ms)
            firsts = [int(np.argmin(np.abs(nb - d))) % 4 for d in neural["downbeats_ms"]]
            bar_on = int(np.bincount(firsts, minlength=4).argmax()) if firsts else 0
            sources["beats"] = "neural"
            sources["bar_phase"] = "neural"
            out["bpm"] = round(60000.0 / float(np.median(np.diff(nb))), 2)
    out["beats"] = beats_ms
    out["bar_starts_on"] = bar_on

    audio = pathlib.Path(track["path"])
    x = _mono(audio) if beats_ms else np.zeros(0, dtype=np.float32)
    if len(beats_ms) >= 8 and len(x) >= _RATE * 10:
        # Everything the analysis derives from the bars, derived again on these bars.
        env, low = _beats._onsets(x)
        derived = analysis.add(
            {"duration_ms": timing["duration_ms"], "tail_ms": timing.get("tail_ms", 0)},
            x, beats_ms, bar_on, low, _beats._FPS)
        for key in ("key", "camelot", "key_confidence", "downbeats", "energy", "four_bars",
                    "phrases", "drops", "cues"):
            if key in derived:
                out[key] = derived[key]
    downbeats = list(out.get("downbeats") or [])

    structure: dict = {"version": VERSION, "sources": sources}
    mix_db = bar_db(x, downbeats) if downbeats else []
    drums_db = rest_db = vocals_db = None
    rest = None
    if stems_path is not None and downbeats:
        try:
            stems = _stems(stems_path)
            drums_db = bar_db(stems["drums"], downbeats)
            rest_db = bar_db(stems["rest"], downbeats)
            vocals_db = bar_db(stems["vocals"], downbeats)
            rest = stems["rest"]
        except (subprocess.SubprocessError, OSError) as e:
            log.warning("could not read the stems of %s: %s", track.get("sha256", "")[:12], e)
            sources["stems"] = False
    structure.update({
        "bars_ms": downbeats,
        "mix_db": mix_db,
        "drums_db": drums_db,
        "rest_db": rest_db,
        "vocals_db": vocals_db,
        "lufs": track.get("loudness_lufs"),
    })
    sections = label_bars(mix_db, drums_db, vocals_db) if mix_db else []
    for s in sections:
        s["start_ms"] = downbeats[s["start_bar"]]
        s["end_ms"] = downbeats[s["end_bar"]] if s["end_bar"] < len(downbeats) \
            else int(timing["duration_ms"] - timing.get("tail_ms", 0))
        # The key of a section long enough to have one, from the stems without drums.
        if rest is not None and s["end_bar"] - s["start_bar"] >= 8:
            seg = rest[int(s["start_ms"] * _RATE / 1000):int(s["end_ms"] * _RATE / 1000)]
            k = analysis.key_of(analysis.chroma(seg))
            s["key"] = k["key"]
            s["camelot"] = k["camelot"]
            s["key_confidence"] = k["key_confidence"]
    structure["sections"] = sections
    structure["drops_ms"] = [s["start_ms"] for s in sections if s["label"] == "drop"]
    structure["breakdowns_ms"] = [s["start_ms"] for s in sections if s["label"] == "breakdown"]
    if rest is not None:
        k = analysis.key_of(analysis.chroma(rest))
        if k["key"] is not None:
            structure["key"] = k
            out["key"], out["camelot"], out["key_confidence"] = k["key"], k["camelot"], k["key_confidence"]
    # Where a DJ would go out of this record and come into it, by its sections: out at
    # the end of the section before a breakdown or the outro; in at a section that plays.
    outs, ins = [], []
    for k, s in enumerate(sections):
        nxt = sections[k + 1] if k + 1 < len(sections) else None
        if s["label"] in ("intro",):
            ins.append({"ms": s["end_ms"], "bar": s["end_bar"], "why": "the intro is over"})
        if s["label"] in ("drop", "chorus"):
            ins.append({"ms": s["start_ms"], "bar": s["start_bar"], "why": f"its {s['label']}"})
        if nxt is not None and nxt["label"] in ("breakdown", "outro") and s["label"] not in ("intro", "break"):
            outs.append({"ms": nxt["start_ms"], "bar": nxt["start_bar"],
                         "why": f"before its {nxt['label']}"})
        if s["label"] == "outro":
            outs.append({"ms": s["start_ms"], "bar": s["start_bar"], "why": "its outro"})
    structure["cues"] = {"outs": outs, "ins": ins}
    out["structure"] = structure
    return out


def for_track(data_dir: pathlib.Path, track: dict, timing: dict) -> dict:
    """The record's structure, built once per record and per what there is to build it
    from (the tracker's beats, the stems), and kept."""
    from . import heavy

    sha = track["sha256"]
    neural = pool.beats_here(data_dir, sha)
    stems_path = pool.part_here(sha, "stems")
    flags = ("n" if neural else "") + ("s" if stems_path else "")
    cached = cache_path(data_dir, sha, flags)
    try:
        return json.loads(cached.read_text())
    except (OSError, ValueError):
        pass
    with heavy.turn(f"{sha}-structure"):
        try:
            return json.loads(cached.read_text())
        except (OSError, ValueError):
            pass
        found = build(data_dir, track, timing, neural, stems_path)
        cached.parent.mkdir(parents=True, exist_ok=True)
        tmp = cached.with_suffix(".tmp")
        tmp.write_text(json.dumps(found, separators=(",", ":")))
        tmp.replace(cached)
        return found
