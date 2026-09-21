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


def cache_path(data_dir: pathlib.Path, sha: str) -> pathlib.Path:
    return data_dir / "peaks" / f"{sha}-{SLICES}.json"


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
    if not samples:
        return [0] * slices
    per = max(1, len(samples) // slices)
    levels = []
    for i in range(slices):
        chunk = samples[i * per:(i + 1) * per]
        if not chunk:
            levels.append(0.0)
            continue
        levels.append(math.sqrt(sum(s * s for s in chunk) / len(chunk)))
    top = max(levels) or 1.0
    return [round(255 * (v / top) ** 0.7) for v in levels]


def for_track(data_dir: pathlib.Path, audio: pathlib.Path, sha: str) -> list[int]:
    """The song's shape, from disk if it has been measured before."""
    cached = cache_path(data_dir, sha)
    try:
        return json.loads(cached.read_text())
    except (OSError, ValueError):
        pass
    shape = measure(audio)
    cached.parent.mkdir(parents=True, exist_ok=True)
    tmp = cached.with_suffix(".tmp")
    tmp.write_text(json.dumps(shape))
    tmp.replace(cached)
    return shape
