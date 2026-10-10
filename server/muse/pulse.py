"""The record's sound, fifty times a second, for the show.

The analysis says what a record is made of a bar at a time (beats.py, structure.py),
and the peaks say how loud it is a hundredth of a second at a time in three bands
(peaks.py) — decoded at 11 kHz, so the top band stops at five and a half thousand
and a hi-hat barely registers. A show wants the thing between: what is happening
*now*, in the bands a light or a shader cares about, with the kick on its own and the
air on its own. That is this: five bands, the kick drum's onsets, the onsets of
everything, and — where the record has been taken apart — each stem's level, twenty
milliseconds at a time, each as a byte.

The show reads it at the needle while the record plays, and models the mixer over it
(the EQ, the filter, the fader are known exactly, so it can), which is nearer to what
the room hears than a tap before the limiter would be. Worked out once per audio
file, on the first ask, kept on disk under the file's hash like the peaks.
"""
from __future__ import annotations

import base64
import json
import pathlib
import subprocess

import numpy as np

# Bumped when what is measured changes, so what is on the disk from before is made
# again rather than read against a shader that expects something else.
VERSION = 1

# Frames a second. Twenty milliseconds is under a frame of the screen, and a kick drum's
# attack is one frame of this; finer buys nothing a shader can show.
HZ = 50

# Decoded at this rate: the air band wants more than the peaks' 11 kHz gives, and 44.1
# would double the work for nothing the ear hears in a band summed to one number.
_RATE = 22050
_HOP = _RATE // HZ        # 441 samples: one frame
_FFT = 2048               # 93 ms window, so the sub band has a few cycles to be read from

# The five bands, by name and in hertz. The sub is the kick's body; the low is the bass;
# the mid is where the voice and the chords are; the high is the snare's crack and the
# hats' body; the air is the hats' sizzle and nothing else.
BANDS = (
    ("sub", 20.0, 60.0),
    ("low", 60.0, 250.0),
    ("mid", 250.0, 2000.0),
    ("high", 2000.0, 6000.0),
    ("air", 6000.0, float(_RATE) / 2),
)

# What every record has.
CHANNELS = tuple(b[0] for b in BANDS) + ("kick", "onset")

# What a record in parts has as well.
STEM_CHANNELS = ("drums", "rest", "vocals")

# A channel's top is this percentile of it rather than its loudest frame: one click
# at 255 would put the whole record at 40.
_TOP_AT = 99.5


def cache_path(data_dir: pathlib.Path, sha: str, stems: bool = False) -> pathlib.Path:
    return data_dir / "pulse" / f"{sha}-v{VERSION}{'-s' if stems else ''}.json"


# ------------------------------------------------------------------ decoding
def _decode(audio: pathlib.Path, pan: str | None = None) -> np.ndarray:
    raw = subprocess.run(
        ["ffmpeg", "-v", "error", "-i", str(audio),
         *(["-af", f"pan=mono|c0={pan}"] if pan else ["-ac", "1"]),
         "-ar", str(_RATE), "-f", "s16le", "-"],
        capture_output=True, timeout=180, check=True).stdout
    return np.frombuffer(raw[: len(raw) // 2 * 2], dtype="<i2").astype(np.float32) / 32768.0


# ------------------------------------------------------------------ measuring
def features(x: np.ndarray) -> dict[str, np.ndarray]:
    """The channels every record has, one value a frame, each on its own scale (not yet
    bytes): the five bands' levels, the kick's onsets, everything's onsets."""
    n = max(1, len(x) // _HOP)
    # Each frame's window sits centred on the frame, so a kick at 0.500 s lands in frame
    # 25 and not in 24 or 26 depending on which way the window leans.
    lead = (_FFT - _HOP) // 2
    padded = np.concatenate([np.zeros(lead, np.float32), x.astype(np.float32),
                             np.zeros(_FFT, np.float32)])
    window = np.hanning(_FFT).astype(np.float32)
    hz = np.fft.rfftfreq(_FFT, 1.0 / _RATE)
    edges = [(np.searchsorted(hz, lo), np.searchsorted(hz, hi)) for _, lo, hi in BANDS]

    bands = np.zeros((len(BANDS), n), np.float32)
    onset = np.zeros(n, np.float32)
    previous = None
    idx = np.arange(_FFT)[None, :]
    # In blocks: a long record's spectrogram all at once is a lot of memory.
    for start in range(0, n, 1024):
        stop = min(n, start + 1024)
        rows = padded[idx + (_HOP * np.arange(start, stop))[:, None]] * window
        mag = np.abs(np.fft.rfft(rows, axis=1)).astype(np.float32)
        power = mag * mag
        for b, (a, z) in enumerate(edges):
            bands[b, start:stop] = np.sqrt(power[:, a:z].sum(axis=1) / _FFT)
        logmag = np.log1p(100.0 * mag)
        before = logmag[:1] if previous is None else previous
        onset[start:stop] = np.maximum(0.0, np.diff(logmag, axis=0, prepend=before)).sum(axis=1)
        previous = logmag[-1:]
    out = {name: bands[b] for b, (name, _, _) in enumerate(BANDS)}
    out["kick"] = _kick(x, n)
    out["onset"] = onset
    return out


def _kick(x: np.ndarray, n: int) -> np.ndarray:
    """The kick drum's onsets: how much the 30–150 Hz band's level rises frame to
    frame, in the time domain. Not off the spectrogram above: its 93 ms window leans
    across the frame before the kick, which put the kick a frame early — and a show
    that flashes a frame before the drum is a show that looks wrong."""
    if len(x) < _HOP:
        return np.zeros(n, np.float32)
    spectrum = np.fft.rfft(x.astype(np.float64))
    hz = np.fft.rfftfreq(len(x), 1.0 / _RATE)
    y = np.fft.irfft(spectrum * ((hz >= 30.0) & (hz <= 150.0)), len(x)) ** 2
    rms = np.sqrt(np.resize(y, n * _HOP).reshape(n, _HOP).mean(axis=1))
    # The rise in level, not in its log: a brick-wall band filter rings in a little
    # before a hit, and in the log the ring-in is the bigger step. The record's quiet
    # kicks still show — the channel is put on the record's own scale after this.
    # From nothing before the first frame: a record that opens on a hit opens on one.
    return np.maximum(0.0, np.diff(rms, prepend=0.0)).astype(np.float32)


def stem_levels(stems: pathlib.Path) -> dict[str, np.ndarray]:
    """Each stem's loudness a frame at a time, the three on one scale against each
    other (the voice's share of the drums is what a show reads off them)."""
    out = {}
    for name, pan in (("drums", "0.5*c0+0.5*c1"), ("rest", "0.5*c2+0.5*c3"),
                      ("vocals", "0.5*c4+0.5*c5")):
        x = _decode(stems, pan)
        n = max(1, len(x) // _HOP)
        frames = np.resize(x, n * _HOP).reshape(n, _HOP)
        out[name] = np.sqrt(np.mean(frames * frames, axis=1) + 1e-12)
    return out


def to_bytes(v: np.ndarray, top: float | None = None) -> np.ndarray:
    """0 to 255, the record's own loud at 255 (its [_TOP_AT]th percentile, or [top]),
    lifted a little (the 0.7 power, as the peaks are) so a quiet passage still moves."""
    if len(v) == 0:
        return np.zeros(0, np.uint8)
    top = top or float(np.percentile(v, _TOP_AT)) or 1.0
    scaled = np.clip(v / top, 0.0, 1.0) ** 0.7
    return np.round(255 * scaled).astype(np.uint8)


def pack(channels: dict[str, np.ndarray]) -> dict:
    """The channels as one answer: their names in order and their bytes, channel after
    channel, as base64 — a long record's pulse is a quarter of a megabyte this way and
    four times that as JSON numbers."""
    names = [c for c in CHANNELS + STEM_CHANNELS if c in channels]
    n = min(len(channels[c]) for c in names) if names else 0
    data = b"".join(bytes(channels[c][:n]) for c in names)
    return {"version": VERSION, "hz": HZ, "n": n, "channels": names,
            "data": base64.b64encode(data).decode("ascii")}


def unpack(packed: dict) -> dict[str, np.ndarray]:
    """[pack] undone, for a test or a script."""
    raw = np.frombuffer(base64.b64decode(packed["data"]), np.uint8)
    n = int(packed["n"])
    return {c: raw[i * n:(i + 1) * n] for i, c in enumerate(packed["channels"])}


def measure(audio: pathlib.Path, stems: pathlib.Path | None = None) -> dict:
    """The record's pulse, packed."""
    found = features(_decode(audio))
    out = {name: to_bytes(v) for name, v in found.items()}
    if stems is not None:
        levels = stem_levels(stems)
        top = max(float(np.percentile(v, _TOP_AT)) for v in levels.values()) or 1.0
        for name, v in levels.items():
            out[name] = to_bytes(v, top)
    return pack(out)


def for_track(data_dir: pathlib.Path, audio: pathlib.Path, sha: str,
              stems: pathlib.Path | None = None) -> dict:
    """The record's pulse, from disk if it has been measured before; otherwise in its
    turn (heavy.py). With the stems where the record is in parts: that answer is kept
    apart from the one without, so a record taken apart later gets the fuller one."""
    from . import heavy

    cached = cache_path(data_dir, sha, stems is not None)
    try:
        return json.loads(cached.read_text())
    except (OSError, ValueError):
        pass
    with heavy.turn(f"{sha}-pulse"):
        try:
            return json.loads(cached.read_text())
        except (OSError, ValueError):
            pass
        packed = measure(audio, stems)
        cached.parent.mkdir(parents=True, exist_ok=True)
        tmp = cached.with_suffix(".tmp")
        tmp.write_text(json.dumps(packed))
        tmp.replace(cached)
        return packed
