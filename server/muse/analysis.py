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


def phrases(rows: np.ndarray) -> list[int]:
    """The bars phrases begin on: 0, and every bar where what follows differs most
    from what came before, snapped to the four-bar grid."""
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
    found = [0]
    for i in range(k, n - k + 1):
        if novelty[i] < threshold:
            continue
        if novelty[i] < novelty[max(0, i - 4):i + 5].max():
            continue
        # Onto the grid: the nearest multiple of four bars, within a bar.
        snapped = int(round(i / 4)) * 4
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


def sections(phrase_bars: list[int], levels: list[int], n_bars: int) -> dict:
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
        for i in range(0, n_bars):
            if steady(i):
                intro_end = int(round(i / 4)) * 4
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
    phrase_bars = phrases(rows)
    out["phrases"] = [int(downbeats[b]) for b in phrase_bars if b < len(downbeats)]
    out["drops"] = [int(downbeats[b]) for b in drops(levels, phrase_bars)
                    if b < len(downbeats)]
    where = sections(phrase_bars, levels, len(levels))
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
    out["cues"] = {
        "first_downbeat_ms": first,
        "mix_in_ms": mix_in,
        "mix_out_ms": mix_out,
        "sound_end_ms": int(sound_end),
    }
    return out
