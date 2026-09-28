"""The shape of a song, for the seek bar.

A seek bar that is a flat line says how far through you are and nothing else. One
drawn as the song's own loudness — the quiet intro, the chorus that comes back three
times, the long fade — says where you might want to go, which is the whole point of
being able to seek.

Worked out once per audio file, on the first ask, by decoding it small (mono, 4 kHz,
which is plenty to see the shape of) and measuring each of a fixed number of slices.
Kept on disk under the file's hash, so it is never worked out again for the same audio
and a re-download of the same song finds it waiting.
"""
from __future__ import annotations

import array
import json
import math
import pathlib
import subprocess

# Slices across the song. A seek bar is at most a few hundred pixels wide on a phone,
# and a couple of pixels a slice is as fine as the eye reads it.
SLICES = 160

# Low enough to be quick, high enough that a drum still shows as a drum.
_RATE = 4000


# A deck's waveform is wider than a seek bar and coloured by band, so it may ask for
# more slices, up to this, and for the low, middle and top of each.
#
# Thirty thousand is a hundredth of a second on a five-minute record. That is what a
# deck's strip wants: at sixteen hundred a four-second view of a four-minute record had
# twenty-seven points in it, which is a third of a beat each, and a kick drum was not a
# kick drum but a bump. The cost of asking for it is nothing — the work is decoding the
# record, which is the same whatever it is sliced into, and it was measured at three
# seconds either way — and the answer is kept on the disk beside the song, so it is
# paid once per record for ever.
MOST_SLICES = 30000

# Bumped when the shape measured for the same song changes, so that what is on the disk
# from before is not drawn against a grid it no longer lines up with.
# 2: the slices laid across the whole file rather than across as much of it as divided
#    evenly — see _levels.
# 3: the three bands measured against each other on one scale instead of each against
#    itself, so that their ratio — which is what a coloured waveform draws — is real.
VERSION = 3


# How much the middle and the top are lifted before the three bands are put on one scale.
#
# Music is not flat, and a coloured waveform draws the *ratio* between the bands. Taken
# over fourteen records pulled at random from the house — the 99th percentile of each
# band's loudness against the low band's — the middle sits at 0.80 of the bass and the
# top at 0.21, quartiles 0.49–0.97 and 0.12–0.28. Put on one scale and drawn as they
# are, every record is a bass-coloured lump with a rim of air on it: the colour says
# "this is music", which is no use to anybody.
#
# Lifted by the reciprocal of those middles, a typical record uses all three and the
# difference *between* records survives — a bright record still draws brighter than a
# dull one, because only the tilt they all share is taken out. Every DJ program does
# this (Mixxx has it as three band gains the user can turn); these are measured rather
# than chosen.
_LIFT = {"low": 1.0, "mid": 1.26, "high": 4.84}


def cache_path(data_dir: pathlib.Path, sha: str, slices: int = SLICES,
               bands: bool = False) -> pathlib.Path:
    tag = f"{sha}-{slices}-v{VERSION}" + ("-bands" if bands else "")
    return data_dir / "peaks" / f"{tag}.json"


def measure_bands(audio: pathlib.Path, slices: int = SLICES) -> dict[str, list[int]]:
    """The same shape three times over: the bass, the middle and the top of each slice,
    each on its own 0–255 scale. Drawn in three inks on a deck, where "the bass drops
    out here" is the thing worth seeing."""
    raw = {}
    for name, filt in (("low", "lowpass=f=250"),
                       ("mid", "highpass=f=250,lowpass=f=4000"),
                       ("high", "highpass=f=4000")):
        proc = subprocess.run(
            ["ffmpeg", "-v", "error", "-i", str(audio), "-ac", "1", "-ar", "11025",
             "-af", filt, "-f", "s16le", "-"],
            capture_output=True, timeout=120, check=True)
        samples = array.array("h")
        samples.frombytes(proc.stdout[: len(proc.stdout) // 2 * 2])
        raw[name] = [v * _LIFT[name] for v in _rms(samples, slices)]
    # One scale for the three of them. Each against its own loudest — which is what this
    # did — makes every record's bands the same height as each other, and a colour mixed
    # from three bands that have each been stretched to fill the frame is a colour that
    # says nothing about the record.
    top = max((max(v) for v in raw.values() if v), default=0.0) or 1.0
    return {name: _to_255(v, top) for name, v in raw.items()}


def _levels(samples, slices: int) -> list[int]:
    """The song cut into [slices] equal pieces, each piece's loudness, 0 to 255."""
    return _to_255(_rms(samples, slices))


def _rms(samples, slices: int) -> list[float]:
    """Each slice's loudness, left on its own scale — so that two bands measured this
    way can be held against each other.

    The pieces are equal *and* laid end to end across the whole file. A slice used to be
    ``len // slices`` samples long, which is that division rounded down, so the slices
    together fell short of the end of the file — a thousandth of it at a hundred and
    sixty slices, but nearly a percent at thirty thousand, because the finer the slice
    the bigger the fraction thrown away. The drawing lays the slices across the whole
    record, so a shape that stops short is a shape stretched to fit: everything in it
    slides later and later through the song, by nearly half a second by the end of a
    four-minute record. That is a beat, against a grid drawn from the same file — the
    picture and the ruler under it disagreeing about where the drop is. Each slice is
    taken between two exact boundaries now, so the last one ends on the last sample.
    """
    if not samples:
        return [0.0] * slices
    n = len(samples)
    levels = []
    for i in range(slices):
        a, b = i * n // slices, (i + 1) * n // slices
        chunk = samples[a:b] if b > a else samples[a:a + 1]
        if not chunk:
            levels.append(0.0)
            continue
        levels.append(math.sqrt(sum(s * s for s in chunk) / len(chunk)))
    return levels


def _to_255(levels: list[float], top: float | None = None) -> list[int]:
    """0 to 255, loudest at 255, lifted a little (the 0.7 power) so that quiet passages
    show as something rather than as a flat line. [top] where several sets of levels
    share one scale."""
    top = top or (max(levels) if levels else 0.0) or 1.0
    return [round(255 * (max(0.0, v) / top) ** 0.7) for v in levels]


def measure(audio: pathlib.Path, slices: int = SLICES) -> list[int]:
    """The loudness of each slice of the song, 0 to 255, loudest slice at 255.

    RMS rather than peak: a single click is loud and short, and a seek bar drawn from
    peaks is a comb. Lifted a little (the 0.7 power) so quiet passages still show
    as something rather than as a flat line."""
    proc = subprocess.run(
        ["ffmpeg", "-v", "error", "-i", str(audio), "-ac", "1", "-ar", str(_RATE),
         "-f", "s16le", "-"],
        capture_output=True, timeout=90, check=True)
    samples = array.array("h")
    samples.frombytes(proc.stdout[: len(proc.stdout) // 2 * 2])
    return _levels(samples, slices)


def for_track(data_dir: pathlib.Path, audio: pathlib.Path, sha: str,
              slices: int = SLICES, bands: bool = False):
    """The song's shape, from disk if it has been measured before; otherwise in its
    turn (heavy.py)."""
    from . import heavy

    slices = max(16, min(MOST_SLICES, int(slices)))
    cached = cache_path(data_dir, sha, slices, bands)
    try:
        return json.loads(cached.read_text())
    except (OSError, ValueError):
        pass
    with heavy.turn(f"{sha}-peaks"):
        try:
            return json.loads(cached.read_text())
        except (OSError, ValueError):
            pass
        shape = measure_bands(audio, slices) if bands else measure(audio, slices)
        cached.parent.mkdir(parents=True, exist_ok=True)
        tmp = cached.with_suffix(".tmp")
        tmp.write_text(json.dumps(shape))
        tmp.replace(cached)
        return shape
