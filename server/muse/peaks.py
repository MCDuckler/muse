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
VERSION = 2


def cache_path(data_dir: pathlib.Path, sha: str, slices: int = SLICES,
               bands: bool = False) -> pathlib.Path:
    tag = f"{sha}-{slices}-v{VERSION}" + ("-bands" if bands else "")
    return data_dir / "peaks" / f"{tag}.json"


def measure_bands(audio: pathlib.Path, slices: int = SLICES) -> dict[str, list[int]]:
    """The same shape three times over: the bass, the middle and the top of each slice,
    each on its own 0–255 scale. Drawn in three inks on a deck, where "the bass drops
    out here" is the thing worth seeing."""
    out = {}
    for name, filt in (("low", "lowpass=f=250"),
                       ("mid", "highpass=f=250,lowpass=f=4000"),
                       ("high", "highpass=f=4000")):
        proc = subprocess.run(
            ["ffmpeg", "-v", "error", "-i", str(audio), "-ac", "1", "-ar", "11025",
             "-af", filt, "-f", "s16le", "-"],
            capture_output=True, timeout=120, check=True)
        samples = array.array("h")
        samples.frombytes(proc.stdout[: len(proc.stdout) // 2 * 2])
        out[name] = _levels(samples, slices)
    return out


def _levels(samples, slices: int) -> list[int]:
    """The song cut into [slices] equal pieces, each piece's loudness, 0 to 255.

    Equal *and* laid end to end across the whole file. The slice used to be
    ``len // slices`` samples long, which is that division rounded down, so the slices
    together fell short of the end of the file by up to one slice per slice — a
    thousandth at a hundred and sixty of them, but nearly a percent at thirty thousand,
    because the finer the slice the bigger the fraction thrown away. The drawing lays
    the slices across the whole record, so a shape that stops short is a shape stretched
    to fit: everything in it slides later and later through the song, by nearly half a
    second by the end of a four-minute record. That is a beat, against a grid drawn from
    the same file — the picture and the ruler under it disagreeing about where the drop
    is. Each slice is now taken between two exact boundaries, so the last one ends on
    the last sample.
    """
    if not samples:
        return [0] * slices
    n = len(samples)
    levels = []
    for i in range(slices):
        a, b = i * n // slices, (i + 1) * n // slices
        chunk = samples[a:b] if b > a else samples[a:a + 1]
        if not chunk:
            levels.append(0.0)
            continue
        levels.append(math.sqrt(sum(s * s for s in chunk) / len(chunk)))
    top = max(levels) or 1.0
    return [round(255 * (v / top) ** 0.7) for v in levels]


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
