"""The parts of a record: the drums, the music under them, and the same record with
the voice taken out.

Not machine separation. There is no model here and no machine to run one on — this
server is a small box that also has to serve the music — so what is here is two old
tricks done carefully, and they are honest about what they are:

  * **The voice is in the middle.** Nearly every record is mixed with the lead vocal
    dead centre and most else spread, so subtracting one channel from the other takes
    the voice with it. Only across the band a voice lives in, though: the kick and the
    bass sit in the middle too, and a record with its bottom removed is not an
    instrumental, it is a mess. So the middle is taken out between 200 Hz and 8 kHz
    and left alone either side of that.

  * **Drums are vertical and notes are horizontal.** In a spectrogram a hit is one
    moment across every frequency and a note is one frequency across many moments. A
    median along time keeps what holds still, which is the notes; a median along
    frequency keeps what is broad and brief, which is the hits. Soft masks from those
    two split the record in half. (Fitzgerald 2010, "Harmonic/Percussive Separation
    using Median Filtering".)

What they cannot do is worth saying plainly, because a DJ will hear it in the first
bar: a vocal that was panned, doubled or drenched in reverb does not come out, and
what does come out takes some of the snare and some of the reverb tail with it.
Tonal percussion — a rim, a tuned tom — lands in the music rather than the drums.
These are parts of a record, not the stems the person who made it has.

Worked out once per audio file and kept on disk under the file's hash, like the beat
grid and the seek bar's shape — but slower than either by a long way, so it is made
when it is first asked for, in the background, and the asking is told to come back.
"""
from __future__ import annotations

import logging
import pathlib
import queue
import subprocess
import threading

import numpy as np

log = logging.getLogger("muse.stems")

# Bumped when what comes out changes, so old renderings are not served for ever.
VERSION = 1

# What the parts are rendered at. Sixteen kilohertz of bandwidth: enough that a hi-hat
# is a hi-hat, small enough that a library's worth of them is not a second library.
RATE = 32000

_FFT = 2048
_HOP = 512

# How far the medians look. Seventeen frames is a third of a second, which is longer
# than a drum hit and shorter than a note; seventeen bins is about a tone and a half at
# the bottom, which is wider than a partial and narrower than a hit.
_SPAN = 17

# Frames at a time. The sliding windows the medians need are the span times the size of
# the spectrogram, so the whole of a long record at once is a gigabyte and a half.
_BLOCK = 384

# The band a voice is taken out of. Below the first the middle is the kick and the bass
# and it stays; above the second it is air and cymbals, and removing it dulls the
# record for nothing.
_VOICE_LOW = 200.0
_VOICE_HIGH = 8000.0

# The longest record that gets taken apart. An hour-long set is not a record, and the
# parts of one are not worth twenty minutes of a small server's afternoon — so past
# this the answer is no rather than a part that runs out before the record does, which
# is silence on a deck in front of a room.
UP_TO_S = 12 * 60

# How long the bench waits for more work before standing down.
IDLE = 120.0

NAMES = ("instrumental", "drums", "music")


class NotReady(Exception):
    """It is being made. Ask again shortly."""


class TooLong(Exception):
    """Longer than a record. Nothing is made of it."""


def too_long(duration_ms: int | None) -> bool:
    return duration_ms is not None and duration_ms > UP_TO_S * 1000


def cache_path(data_dir: pathlib.Path, sha: str, name: str) -> pathlib.Path:
    return data_dir / "stems" / f"{sha}-{name}-v{VERSION}.m4a"


# Sound is carried about here the way a wave file carries it: one row per sample,
# one column per channel. That is the shape ffmpeg wants either way round, so
# nothing is transposed and nothing is copied to say it.

# ------------------------------------------------------------------ the sound itself
def _decode(audio: pathlib.Path) -> np.ndarray:
    """The record as (samples, 2) floats at [RATE]. A mono file comes back as two
    identical channels, which is the honest answer: a mono record has no middle to
    take out, and it falls out of the arithmetic as silence rather than as a wrong
    guess."""
    proc = subprocess.run(
        ["ffmpeg", "-v", "error", "-t", str(UP_TO_S), "-i", str(audio),
         "-ac", "2", "-ar", str(RATE), "-f", "f32le", "-"],
        capture_output=True, timeout=600, check=True)
    flat = np.frombuffer(proc.stdout[: len(proc.stdout) // 8 * 8], dtype="<f4")
    return flat.reshape(-1, 2)


def _encode(x: np.ndarray, into: pathlib.Path) -> None:
    """Write [x] — (samples,) or (samples, channels) — beside the others, as the same
    kind of file the record itself is."""
    if x.ndim == 1:
        x = x[:, None]
    peak = float(np.abs(x).max()) if x.size else 0.0
    # Back off if the arithmetic pushed anything over: a part that clips is a part
    # nobody can use, and the booth matches levels anyway.
    if peak > 1.0:
        x = x / peak
    raw = np.ascontiguousarray(x, dtype="<f4").tobytes()
    into.parent.mkdir(parents=True, exist_ok=True)
    tmp = into.with_suffix(".tmp.m4a")
    subprocess.run(
        ["ffmpeg", "-v", "error", "-y", "-f", "f32le", "-ar", str(RATE),
         "-ac", str(x.shape[1]), "-i", "-", "-c:a", "aac", "-b:a", "160k", str(tmp)],
        input=raw, capture_output=True, timeout=600, check=True)
    tmp.replace(into)


# --------------------------------------------------- spectrograms, a block at a time
# Nothing here ever holds a whole record's spectrogram. Twelve minutes at this rate is
# forty-five thousand frames of a thousand bins, and two of those in complex numbers is
# most of a gigabyte — on a box that is also serving the music to somebody. So frames
# are taken in blocks, turned back into sound as they are finished, and added into the
# one output buffer that does have to be whole.

_WINDOW = np.hanning(_FFT).astype(np.float32)


def _frames_in(n: int) -> int:
    return 1 + max(0, (n - _FFT) // _HOP) if n >= _FFT else 0


def _stft(x: np.ndarray, first: int, last: int) -> np.ndarray:
    """Frames [first, last) of [x], windowed."""
    if last <= first:
        return np.zeros((0, _FFT // 2 + 1), dtype=np.complex64)
    at = _HOP * np.arange(first, last)
    idx = np.arange(_FFT)[None, :] + at[:, None]
    return np.fft.rfft(x[idx] * _WINDOW, axis=1).astype(np.complex64)


def _add_frames(into: np.ndarray, spectrum: np.ndarray, first: int) -> None:
    """Overlap-add frames back into [into], starting at frame [first]. The dividing
    through by the window's own weight happens once at the end, in [_finish]."""
    if spectrum.shape[0] == 0:
        return
    blocks = np.fft.irfft(spectrum, n=_FFT, axis=1).astype(np.float32) * _WINDOW
    for i in range(spectrum.shape[0]):
        at = (first + i) * _HOP
        into[at:at + _FFT] += blocks[i]


def _finish(out: np.ndarray, frames: int, length: int) -> np.ndarray:
    """Undo the windowing's weight and cut to [length]."""
    weight = np.zeros(len(out), dtype=np.float32)
    square = _WINDOW * _WINDOW
    for i in range(frames):
        at = i * _HOP
        weight[at:at + _FFT] += square
    out /= np.maximum(weight, 1e-6)
    if len(out) < length:
        out = np.pad(out, (0, length - len(out)))
    return out[:length]


def _room_for(frames: int) -> np.ndarray:
    return np.zeros(_FFT + _HOP * max(0, frames - 1), dtype=np.float32)


def _in_blocks(n_frames: int):
    """Blocks of frames, each with the neighbours a median at its edge would want, as
    (first, last, keep_from, keep_to) — so a block boundary is not a seam anybody can
    hear."""
    pad = _SPAN // 2
    for start in range(0, n_frames, _BLOCK):
        stop = min(n_frames, start + _BLOCK)
        yield max(0, start - pad), min(n_frames, stop + pad), start, stop


# ------------------------------------------------------------------ the middle of it
def without_voice(stereo: np.ndarray) -> np.ndarray:
    """The record with what is in the middle taken out, across the band a voice is in.

    Mid and side: the sides are kept whole, and the middle is kept only where a voice
    is not. What comes back is stereo, because a record collapsed to mono to do this
    would have lost the very thing that made it possible."""
    mid = ((stereo[:, 0] + stereo[:, 1]) / 2).astype(np.float32)
    side = ((stereo[:, 0] - stereo[:, 1]) / 2).astype(np.float32)
    keep = _outside_band(mid, _VOICE_LOW, _VOICE_HIGH)
    return np.stack([keep + side, keep - side], axis=1)


def _band_mask(low: float, high: float) -> np.ndarray:
    """One for the bins inside [low, high], zero outside, with an octave of slope
    either side so the band has no corners — a brick wall on a voice's band rings, and
    ringing on a kick is a kick with a tail on it."""
    freqs = np.fft.rfftfreq(_FFT, 1.0 / RATE)
    hz = np.maximum(freqs, 1e-6)
    inside = np.clip(np.log2(hz / low), 0.0, 1.0) * np.clip(np.log2(high / hz), 0.0, 1.0)
    return inside.astype(np.float32)


def _outside_band(x: np.ndarray, low: float, high: float) -> np.ndarray:
    """Everything in [x] below [low] or above [high]."""
    frames = _frames_in(len(x))
    if frames == 0:
        return np.zeros(len(x), dtype=np.float32)
    keep = 1.0 - _band_mask(low, high)
    out = _room_for(frames)
    # No medians here, so the neighbours a block would otherwise want are not taken:
    # every frame is done exactly once.
    for _, _, keep_from, keep_to in _in_blocks(frames):
        _add_frames(out, _stft(x, keep_from, keep_to) * keep, keep_from)
    return _finish(out, frames, len(x))


# ------------------------------------------------------------------ hits and notes
def _median_along(block: np.ndarray, axis: int) -> np.ndarray:
    """The median of every [_SPAN] neighbours along [axis]."""
    pad = _SPAN // 2
    widths = [(0, 0), (0, 0)]
    widths[axis] = (pad, pad)
    padded = np.pad(block, widths, mode="edge")
    windows = np.lib.stride_tricks.sliding_window_view(padded, _SPAN, axis=axis)
    return np.median(windows, axis=-1).astype(np.float32)


def hits_and_notes(mono: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """The record split in two: what is percussive, and what is not.

    Returns (drums, music), both the length of what went in."""
    mono = mono.astype(np.float32, copy=False)
    frames = _frames_in(len(mono))
    if frames == 0:
        zero = np.zeros(len(mono), dtype=np.float32)
        return zero, zero.copy()
    hits_out, notes_out = _room_for(frames), _room_for(frames)
    for first, last, keep_from, keep_to in _in_blocks(frames):
        spectrum = _stft(mono, first, last)
        magnitude = np.abs(spectrum)
        notes = _median_along(magnitude, 0)    # holds still in time: the notes
        hits = _median_along(magnitude, 1)     # broad in frequency: the drums
        # Wiener-ish soft masks: every bin is shared out rather than given to one
        # side, which is what keeps the two halves adding back up to the record.
        notes2, hits2 = notes * notes, hits * hits
        total = notes2 + hits2 + 1e-9
        keep = slice(keep_from - first, keep_to - first)
        _add_frames(hits_out, spectrum[keep] * (hits2 / total)[keep], keep_from)
        _add_frames(notes_out, spectrum[keep] * (notes2 / total)[keep], keep_from)
    return (_finish(hits_out, frames, len(mono)),
            _finish(notes_out, frames, len(mono)))


# ------------------------------------------------------------------ the whole of it
def parts_of(audio: pathlib.Path, name: str) -> dict[str, np.ndarray]:
    """The part of [audio] called [name], together with anything that comes out of
    the same pass for nothing — splitting a record into hits and notes gives both
    halves, so asking for its drums quietly gets its music too."""
    if name not in NAMES:
        raise ValueError(f"no such part: {name}")
    stereo = _decode(audio)
    if stereo.size == 0:
        raise ValueError("there is no sound in that file")
    if name == "instrumental":
        return {"instrumental": without_voice(stereo)}
    drums, music = hits_and_notes(stereo.mean(axis=1))
    return {"drums": drums, "music": music}


def make(audio: pathlib.Path, name: str) -> np.ndarray:
    """One part of [audio], as samples at [RATE]."""
    return parts_of(audio, name)[name]


def for_track(data_dir: pathlib.Path, audio: pathlib.Path, sha: str, name: str,
              duration_ms: int | None = None) -> pathlib.Path:
    """Where this part of the record is, asking for it to be made if it has not been.

    Raises [NotReady] until it exists — a minute or so for the first ask, longer if
    something is already on the bench. Whoever asked is told to come back rather than
    held on to."""
    if name not in NAMES:
        raise ValueError(f"no such part: {name}")
    if too_long(duration_ms):
        raise TooLong(name)
    cached = cache_path(data_dir, sha, name)
    if cached.exists():
        return cached
    _ask_for(data_dir, audio, sha, name)
    raise NotReady(name)


# One at a time, and no queueing the same thing twice: separation is minutes of one
# core and the better part of a gigabyte, and this box is a music server first. A page
# that asks for three parts of two records gets them one after another rather than six
# at once and a server nobody can reach.
_wanted: queue.Queue = queue.Queue()
_making: set[tuple[str, str]] = set()
_lock = threading.Lock()
_bench: threading.Thread | None = None


def underway(sha: str, name: str) -> bool:
    """Whether this part is on the bench or waiting for it."""
    with _lock:
        return (sha, name) in _making


def _ask_for(data_dir: pathlib.Path, audio: pathlib.Path, sha: str, name: str) -> None:
    global _bench
    with _lock:
        if (sha, name) in _making:
            return
        _making.add((sha, name))
        # Put it on the queue while still holding the lock, so that the bench cannot
        # decide there is nothing left and stand down in between.
        _wanted.put((data_dir, audio, sha, name))
        if _bench is None:
            _bench = threading.Thread(target=_work, name="stems", daemon=True)
            _bench.start()


def _work() -> None:
    global _bench
    while True:
        try:
            data_dir, audio, sha, name = _wanted.get(timeout=IDLE)
        except queue.Empty:
            # Nothing for a while. Stand down; the next ask starts another.
            with _lock:
                if _wanted.empty():
                    _bench = None
                    return
            continue
        try:
            for part, x in parts_of(audio, name).items():
                where = cache_path(data_dir, sha, part)
                if not where.exists():
                    _encode(x, where)
        except Exception:                                  # noqa: BLE001
            log.warning("could not make the %s of %s", name, audio, exc_info=True)
        finally:
            with _lock:
                _making.discard((sha, name))
            _wanted.task_done()
