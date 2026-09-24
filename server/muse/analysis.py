"""What a song is made of, beyond its beats: its key, its bars, how loud each bar is,
where its phrases begin, and where a DJ would come in and go out.

Everything here is worked out from the same small decode the beats were, on the beats
they found, so a song is listened to once. It is the second half of beats.measure and
is written into the same answer; see beats.py for the cache and the decode.

Key (Krumhansl & Kessler, 1982): the twelve pitch classes of the song's spectrum are
summed into a chroma and correlated with the profiles of every major and minor key; the
best fit is the key, and the margin over the runner-up is how sure it is. Phrases: the
song is described bar by bar — loudness, chroma, how much bass arrives — and a phrase
begins where the bars after differ most from the bars before (a checkerboard kernel
over a self-similarity, Foote 2000), snapped to the four-bar grid nearly all popular
music is written on. Sections are the phrases with the energy read off them: the intro
ends where the song first gets loud and stays loud, the outro starts where it last is.
"""
from __future__ import annotations

import numpy as np

# The same decode as the beats: mono at this rate.
RATE = 11025

# For the key a finer spectrum than the beats used: 4096 bins is 2.7 Hz apart, which
# tells an A from a G# down at 110 Hz.
_KEY_FFT = 4096
_KEY_HOP = 2048

# Pitch classes, from C. The wheel DJs use is the same circle of fifths with numbers on
# it: 8B is C major, 8A is A minor, and each step round is a fifth away.
NAMES = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
_CAMELOT_MAJOR = {0: "8B", 7: "9B", 2: "10B", 9: "11B", 4: "12B", 11: "1B",
                  6: "2B", 1: "3B", 8: "4B", 3: "5B", 10: "6B", 5: "7B"}
_CAMELOT_MINOR = {9: "8A", 4: "9A", 11: "10A", 6: "11A", 1: "12A", 8: "1A",
                  3: "2A", 10: "3A", 5: "4A", 0: "5A", 7: "6A", 2: "7A"}

# Krumhansl & Kessler's profiles: how much each degree of the scale is heard in a key.
_MAJOR = np.array([6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88])
_MINOR = np.array([6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17])

# Bars either side a phrase boundary is judged by.
_KERNEL_BARS = 8

# The four-bar grid: each bar's spectrum in this many bands, from frames this long.
_GRID_BANDS = 40
_GRID_FFT = 2048
# What moving the grid costs, against the changes that vote for where it is (see
# four_bars): more than any one change is worth (a change scores 3.5 at the most), so
# it takes two clear ones or three middling ones. And how much the grid counted from
# the top of the record is believed before anything is heard.
_GRID_SWITCH = 4.5
_GRID_FROM_TOP = 1.0

# A bar has to be this much of the song's loudest to count as the song being "on".
_ON = 0.6

# Bars either side of a drop that are compared, and how much louder the after has to
# be than the before for it to be one. Eight bars is the shortest breakdown anybody
# writes; a fifth of the song's range is a step rather than a swell.
_DROP_SPAN = 8
_DROP_RISE = 0.2


# ------------------------------------------------------------------ key
def chroma(x: np.ndarray) -> np.ndarray:
    """The song's twelve pitch classes, summed over the whole of it."""
    n = 1 + (len(x) - _KEY_FFT) // _KEY_HOP
    if n < 4:
        return np.zeros(12)
    window = np.hanning(_KEY_FFT).astype(np.float32)
    freqs = np.fft.rfftfreq(_KEY_FFT, 1.0 / RATE)
    # Only where notes live: below 55 Hz is rumble and above 2 kHz is mostly overtones
    # of what is already counted, and the overtones of a fifth vote for the wrong key.
    keep = (freqs >= 55) & (freqs <= 2000)
    f = freqs[keep]
    midi = 69 + 12 * np.log2(f / 440.0)
    pc = (np.round(midi).astype(int)) % 12
    # Fundamentals live low and overtones high, and an overtone a fifth up votes for
    # the wrong key: what is above 500 Hz counts for less the higher it is.
    taper = np.where(f <= 500, 1.0, np.clip(1.0 - 0.7 * np.log2(f / 500) / 2, 0.25, 1.0))
    out = np.zeros(12)
    idx = np.arange(_KEY_FFT)[None, :] + (_KEY_HOP * np.arange(n))[:, None]
    for start in range(0, n, 256):
        block = x[idx[start:start + 256]] * window
        mag = np.abs(np.fft.rfft(block, axis=1))[:, keep]
        # Gently compressed: a chord's quiet notes are still notes, but the loudest
        # note in it is still the loudest.
        mag = np.sqrt(mag) * taper
        out += np.bincount(pc, weights=mag.sum(axis=0), minlength=12)
    return out


def key_of(chroma_: np.ndarray) -> dict:
    """The key that fits, how sure that is, and its place on the wheel."""
    if chroma_.sum() <= 0:
        return {"key": None, "camelot": None, "key_confidence": 0.0}
    c = chroma_ - chroma_.mean()
    # Flat: every note as much as every other, which is noise or a drum, and a
    # correlation with anything is chance.
    if np.allclose(c, 0) or (chroma_.max() - chroma_.min()) < 0.12 * chroma_.mean():
        return {"key": None, "camelot": None, "key_confidence": 0.0}
    scores = []
    for tonic in range(12):
        for name, profile in (("major", _MAJOR), ("minor", _MINOR)):
            p = np.roll(profile, tonic)
            p = p - p.mean()
            r = float(np.dot(c, p) / (np.linalg.norm(c) * np.linalg.norm(p) + 1e-12))
            scores.append((r, tonic, name))
    scores.sort(reverse=True)
    (best, tonic, mode), (second, _, _) = scores[0], scores[1]
    confidence = float(np.clip((best - second) * 4, 0.0, 1.0))
    if best < 0.4:
        # Nothing fits: noise, speech, atonal. Better no key than a wrong one.
        return {"key": None, "camelot": None, "key_confidence": round(confidence, 2)}
    return {
        "key": f"{NAMES[tonic]} {mode}",
        "camelot": (_CAMELOT_MAJOR if mode == "major" else _CAMELOT_MINOR)[tonic],
        "key_confidence": round(confidence, 2),
    }


# ------------------------------------------------------------------ bars
def bar_features(x: np.ndarray, downbeats_ms: list[int], low_env: np.ndarray,
                 fps: float) -> tuple[np.ndarray, np.ndarray]:
    """Each bar as a few numbers: its loudness in dB, its chroma, its bass onsets.

    Returns (energy_db per bar, feature rows per bar) for the bars between one downbeat
    and the next; the last downbeat has no bar after it."""
    n = len(downbeats_ms) - 1
    if n < 1:
        return np.zeros(0), np.zeros((0, 14))
    energy = np.zeros(n)
    rows = np.zeros((n, 14))
    for i in range(n):
        a = int(downbeats_ms[i] * RATE / 1000)
        b = int(downbeats_ms[i + 1] * RATE / 1000)
        seg = x[a:b]
        if len(seg) < 64:
            continue
        rms = float(np.sqrt(np.mean(seg * seg) + 1e-12))
        energy[i] = 20 * np.log10(rms + 1e-9)
        # A coarse chroma per bar: one FFT of the bar, binned by pitch class.
        spec = np.abs(np.fft.rfft(seg * np.hanning(len(seg))))
        freqs = np.fft.rfftfreq(len(seg), 1.0 / RATE)
        keep = (freqs >= 55) & (freqs <= 2000)
        if keep.any():
            midi = 69 + 12 * np.log2(freqs[keep] / 440.0)
            pc = (np.round(midi).astype(int)) % 12
            ch = np.bincount(pc, weights=np.log1p(30.0 * spec[keep]), minlength=12)
            total = ch.sum()
            rows[i, :12] = ch / total if total > 0 else 0
        fa, fb = int(a / RATE * fps), int(b / RATE * fps)
        if fb > fa and fb <= len(low_env):
            rows[i, 12] = float(low_env[fa:fb].mean())
        rows[i, 13] = rms
    # Loudness and bass on a scale the chroma shares, so no one column decides.
    for col in (12, 13):
        top = rows[:, col].max()
        if top > 0:
            rows[:, col] /= top
    return energy, rows


def energy_levels(energy_db: np.ndarray) -> list[int]:
    """Each bar's loudness, 0 to 255 with the loudest bar at 255 — the same scale the
    seek bar's shape is drawn on."""
    if len(energy_db) == 0:
        return []
    top = float(energy_db.max())
    lin = 10 ** ((energy_db - top) / 20)
    return [int(round(255 * float(v) ** 0.7)) for v in lin]


# ------------------------------------------------------------------ the four-bar grid
def bar_spectra(x: np.ndarray, downbeats_ms: list[int]) -> np.ndarray:
    """Each bar's spectrum as the ear groups it — bands a fraction of an octave wide,
    on a log scale — averaged over the bar: what a new sound, a new part, a new section
    shows up in. One row per bar between one downbeat and the next."""
    edges = np.unique(np.geomspace(2, _GRID_FFT // 2, _GRID_BANDS + 1).astype(int))
    window = np.hanning(_GRID_FFT)
    n = max(0, len(downbeats_ms) - 1)
    rows = np.zeros((n, len(edges) - 1))
    for i in range(n):
        seg = x[int(downbeats_ms[i] * RATE / 1000):int(downbeats_ms[i + 1] * RATE / 1000)]
        if len(seg) < _GRID_FFT // 2:
            continue
        if len(seg) < _GRID_FFT:
            seg = np.pad(seg, (0, _GRID_FFT - len(seg)))
        starts = np.arange(0, len(seg) - _GRID_FFT + 1, _GRID_FFT // 2)
        frames = seg[starts[:, None] + np.arange(_GRID_FFT)[None, :]] * window
        mag = np.abs(np.fft.rfft(frames, axis=1)).mean(axis=0)
        total = np.concatenate([[0.0], np.cumsum(mag)])
        rows[i] = np.log1p((total[edges[1:]] - total[edges[:-1]]) / (edges[1:] - edges[:-1]))
    return rows


def _change(rows: np.ndarray, k: int, least: int = 2) -> np.ndarray:
    """How much the [k] bars after each bar differ from the [k] before it — fewer at
    the ends of the record, down to [least], so a change there is found where it is
    rather than where a full [k] first fits."""
    n = len(rows)
    out = np.zeros(n)
    if n == 0:
        return out
    total = np.vstack([np.zeros(rows.shape[1]), np.cumsum(rows, axis=0)])
    for i in range(least, n - least + 1):
        kk = min(k, i, n - i)
        before = (total[i] - total[i - kk]) / kk
        after = (total[i + kk] - total[i]) / kk
        out[i] = float(np.linalg.norm(after - before))
    return out


def changes(spectra: np.ndarray, energy_db: np.ndarray) -> np.ndarray:
    """How strongly the record changes at the start of each bar: the sound compared
    over two, four and eight bars either side, and the loudness over four — each
    scaled to its own biggest, so no one of them decides."""
    out = np.zeros(len(spectra))
    # A bar too short to measure reads 0 dB, the loudest there is: not a change.
    heard = energy_db[energy_db != 0]
    energy_db = np.where(energy_db == 0, heard.min() if len(heard) else 0.0, energy_db)
    for k in (2, 4, 8):
        c = _change(spectra, k)
        if c.max() > 0:
            out += c / c.max()
    c = _change(energy_db[:, None], 4)
    if c.max() > 0:
        out += 0.5 * c / c.max()
    return out


def four_bars(strength: np.ndarray) -> list[int]:
    """The bars the record's four-bar grid is on: the markers a DJ lines two records
    up by, and what the booth mixes on.

    Music is written in fours and its sections start on them — but not always on a
    grid counted from the first bar: a pickup, an intro of three or six, a break two
    bars short, and every section after it is a bar or two off a grid counted from the
    top. So the grid goes where the record's clear changes are. Each bar is on one of
    four grids; a grid is voted for by every clear change on it (the bars where the
    sound changes most, each by how much); moving from one grid to another costs more
    than any one change is worth, so the grid moves only where the record does — a
    section of odd length, followed by others that agree — and never for one fill a bar
    early. It moves on a clear change, which is where the new section starts.
    With nothing to go by, the grid is counted from the top. The best path through the
    four is found in one pass (Viterbi), and every bar four on from where its grid
    starts is a marker.
    """
    n = len(strength)
    if n == 0:
        return []
    if n < 8 or strength.max() <= 0:
        return list(range(0, n, 4))
    threshold = float(strength.mean() + strength.std())
    votes = np.zeros(n)
    # The clear changes, one bar each, and not the first or last two bars: a record's
    # first sound and its last are changes of their own that say nothing of the grid.
    for i in range(2, n - 2):
        if strength[i] >= threshold and strength[i] == strength[max(0, i - 2):i + 3].max():
            votes[i] = strength[i]
    score = np.array([_GRID_FROM_TOP, 0.0, 0.0, 0.0])
    back = np.zeros((n, 4), dtype=np.int64)
    for i in range(n):
        new = np.empty(4)
        for g in range(4):
            new[g], back[i, g] = score[g], g
            # A grid is only moved onto on a clear change on one of its own bars: where
            # the section it starts begins.
            if (i - g) % 4 == 0 and votes[i] > 0:
                other = max((q for q in range(4) if q != g), key=lambda q: score[q])
                if score[other] - _GRID_SWITCH > new[g]:
                    new[g], back[i, g] = score[other] - _GRID_SWITCH, other
                new[g] += votes[i]
        score = new
    g = int(np.argmax(score))
    on = np.zeros(n, dtype=np.int64)
    for i in range(n - 1, -1, -1):
        on[i] = g
        g = int(back[i, g])
    return [i for i in range(n) if (i - on[i]) % 4 == 0]


def phrases(rows: np.ndarray, markers: list[int] | None = None) -> list[int]:
    """The bars phrases begin on: the first marker, and every bar where what follows
    differs most from what came before, moved onto the nearest four-bar marker within a
    bar (see four_bars; every fourth bar from the first where there are none)."""
    n = len(rows)
    if n < 2 * _KERNEL_BARS:
        return [0] if n else []
    k = _KERNEL_BARS
    novelty = np.zeros(n)
    for i in range(k, n - k + 1):
        before = rows[i - k:i].mean(axis=0)
        after = rows[i:i + k].mean(axis=0)
        novelty[i] = float(np.linalg.norm(after - before))
    if novelty.max() <= 0:
        return [0]
    threshold = novelty[k:n - k + 1].mean() + 0.8 * novelty[k:n - k + 1].std()
    grid = markers if markers else list(range(0, n, 4))
    found = [grid[0]]
    for i in range(k, n - k + 1):
        if novelty[i] < threshold:
            continue
        if novelty[i] < novelty[max(0, i - 4):i + 5].max():
            continue
        # Onto the grid: the nearest marker, within a bar.
        snapped = min(grid, key=lambda m: abs(m - i))
        if abs(snapped - i) > 1:
            snapped = i
        if snapped < n and snapped - found[-1] >= 4:
            found.append(snapped)
    return found


def drops(levels: list[int], phrase_bars: list[int]) -> list[int]:
    """The bars where the song opens up: a breakdown, then everything at once.

    What a DJ is listening for and what makes a mix sound meant rather than merely
    correct — the incoming record's drop landing where the outgoing's phrase turns
    over. Found as the moment the next eight bars are a good deal louder than the
    eight before, which is what a drop is; snapped to the phrase grid, because that
    is where they are written.
    """
    n = len(levels)
    if n < 2 * _DROP_SPAN:
        return []
    lv = np.array(levels, dtype=float) / 255.0
    found: list[int] = []
    for b in range(_DROP_SPAN, n - _DROP_SPAN + 1):
        before = float(lv[b - _DROP_SPAN:b].mean())
        after = float(lv[b:b + _DROP_SPAN].mean())
        # Loud after, and a real step up rather than a slow swell.
        if after < _ON or after - before < _DROP_RISE:
            continue
        # The biggest step in its own neighbourhood, so one drop is one bar.
        rises = [
            float(lv[i:i + _DROP_SPAN].mean() - lv[i - _DROP_SPAN:i].mean())
            for i in range(max(_DROP_SPAN, b - 3), min(n - _DROP_SPAN, b + 4))
        ]
        if after - before < max(rises) - 1e-9:
            continue
        # Onto the phrase it belongs to, where one is within a couple of bars.
        at = b
        for p in phrase_bars:
            if abs(p - b) <= 2:
                at = p
                break
        if not found or at - found[-1] >= _DROP_SPAN:
            found.append(at)
    return found


def sections(phrase_bars: list[int], levels: list[int], n_bars: int,
             markers: list[int] | None = None) -> dict:
    """Where the song is 'on': the bar the intro ends on and the bar the outro starts
    on, as bars — None where it cannot be said."""
    if not levels or n_bars < 8:
        return {"intro_end_bar": None, "outro_start_bar": None}
    lv = np.array(levels, dtype=float) / 255.0
    on = lv >= _ON

    def steady(i: int, length: int = 4) -> bool:
        seg = on[i:i + length]
        return len(seg) >= min(length, n_bars - i) and bool(seg.mean() >= 0.75)

    intro_end = None
    for b in phrase_bars:
        if b > 0 and steady(b):
            intro_end = b
            break
    if intro_end is None:
        grid = markers if markers else list(range(0, n_bars, 4))
        for i in range(0, n_bars):
            if steady(i):
                intro_end = min(grid, key=lambda m: abs(m - i))
                break
    outro_start = None
    for b in reversed(phrase_bars):
        if b < n_bars - 2 and not on[b:].mean() >= 0.5 and on[:b].mean() >= 0.5:
            outro_start = b
            break
    return {"intro_end_bar": intro_end, "outro_start_bar": outro_start}


# ------------------------------------------------------------------ the whole of it
def add(out: dict, x: np.ndarray, beats_ms: list[int], bar_starts_on: int,
        low_env: np.ndarray, fps: float) -> dict:
    """Write the song's key, bars, energy, phrases and cues into the beats' answer."""
    out.update(key_of(chroma(x)))
    if len(beats_ms) < 8:
        return out
    downbeats = beats_ms[bar_starts_on::4]
    out["downbeats"] = [int(b) for b in downbeats]
    energy_db, rows = bar_features(x, downbeats, low_env, fps)
    levels = energy_levels(energy_db)
    out["energy"] = levels
    markers = four_bars(changes(bar_spectra(x, downbeats), energy_db))
    out["four_bars"] = [int(downbeats[b]) for b in markers if b < len(downbeats)]
    phrase_bars = phrases(rows, markers)
    out["phrases"] = [int(downbeats[b]) for b in phrase_bars if b < len(downbeats)]
    out["drops"] = [int(downbeats[b]) for b in drops(levels, phrase_bars)
                    if b < len(downbeats)]
    where = sections(phrase_bars, levels, len(levels), markers)
    sound_end = out["duration_ms"] - out.get("tail_ms", 0)
    first = int(downbeats[0])
    mix_in = int(downbeats[where["intro_end_bar"]]) if where["intro_end_bar"] is not None \
        and where["intro_end_bar"] < len(downbeats) else first
    if where["outro_start_bar"] is not None and where["outro_start_bar"] < len(downbeats):
        mix_out = int(downbeats[where["outro_start_bar"]])
    else:
        # Thirty-two bars before the sound ends, on a downbeat; or the last phrase.
        back = max(0, len(downbeats) - 33)
        mix_out = int(downbeats[back])
    out["cues"] = sane_cues({
        "first_downbeat_ms": first,
        "mix_in_ms": mix_in,
        "mix_out_ms": mix_out,
        "sound_end_ms": int(sound_end),
    }, downbeats)
    return out


def sane_cues(cues: dict, downbeats) -> dict:
    """[cues] with an outro that begins before the intro is over — a short record read
    as all outro (88 s: mix_out at bar 3, mix_in at bar 7) — moved to thirty-two bars
    before the sound ends, or the last downbeat there is. Also run over what was kept
    before this rule, on the way out."""
    if not cues or len(downbeats) < 2:
        return cues
    if cues["mix_out_ms"] > cues["mix_in_ms"]:
        return cues
    fixed = dict(cues)
    back = max(0, len(downbeats) - 33)
    out = int(downbeats[back])
    if out <= cues["mix_in_ms"]:
        out = int(downbeats[-1])
    fixed["mix_out_ms"] = max(out, cues["mix_in_ms"])
    return fixed
