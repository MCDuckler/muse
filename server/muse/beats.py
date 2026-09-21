"""What a song is made of in time: where it really starts and ends, how fast it goes,
and where its beats fall.

Two things want this. Playing one song into the next without a hole between them needs
to know where the sound stops and the silence at the end of the file begins — most
files have a second or two of nothing at either end, and a queue played straight
through is a queue with a pause after every song. And anything that wants to move *with*
the music — a light, a record, one day a crossfade that lands on the beat — needs to
know where the beats are, which is not something that can be worked out while playing.

Worked out once per audio file, on the first ask, and kept on disk under the file's
hash like the seek bar's shape: never again for the same audio, and a re-download of
the same song finds it waiting.

How the beats are found is the standard way (Ellis, "Beat Tracking by Dynamic
Programming", 2007), with numpy and nothing else:

  1. the song decoded small — mono, 11 kHz, which keeps every drum;
  2. an *onset envelope*: how much new energy arrives at each instant, from the
     frame-to-frame rise of a log-magnitude spectrum;
  3. the tempo, from the envelope's autocorrelation, weighed towards the tempos music
     is actually played at, so that 60 is not mistaken for 120 or 240;
  4. the beats themselves, by dynamic programming: the sequence of instants that sits on
     the most onsets while staying as evenly spaced as the tempo says.

It says how sure it is, and a song with no steady pulse — speech, an ambient piece, a
rubato piano — is reported as having no beats rather than being given invented ones.
"""
from __future__ import annotations

import json
import pathlib
import subprocess

import numpy as np

# Bumped when what is measured changes, so old answers on disk are not served for ever.
VERSION = 1

_RATE = 11025
_FFT = 1024
_HOP = 128                       # 11.6 ms: 86 frames a second
_FPS = _RATE / _HOP

# Past this the whole file is not decoded for beats: an hour-long set has no one tempo,
# and an hour of samples is a lot of memory for a small server. The silence at either
# end is still found, from the ends alone.
_BEATS_UP_TO_S = 15 * 60
_ENDS_S = 45

# Sound quieter than this, relative to the loud parts of the song, is silence — but
# never louder than the floor, so a quiet song's quiet intro is not cut off as nothing.
_BELOW_LOUD_DB = 52.0
_FLOOR_DB = -62.0

# Where in a frame its onset is. A frame is 93 ms of sound under a bell-shaped window,
# and a drum hit first shows as a rise in the frame whose window has just reached it —
# so the hit is towards the *end* of that frame, not at its middle. Measured against
# click tracks of known position rather than reasoned about.
_ONSET_AT = _FFT * 0.78

# Beats have to sit on at least this many times the envelope's average to be believed.
_PULSE_CONTRAST = 2.5

# Less than this at an end is left alone: it is not a gap, it is the edge of a file.
_WORTH_TRIMMING_MS = 250


def cache_path(data_dir: pathlib.Path, sha: str) -> pathlib.Path:
    return data_dir / "beats" / f"{sha}-v{VERSION}.json"


def _decode(audio: pathlib.Path, *before: str, after: tuple[str, ...] = ()) -> np.ndarray:
    proc = subprocess.run(
        ["ffmpeg", "-v", "error", *before, "-i", str(audio), *after,
         "-ac", "1", "-ar", str(_RATE), "-f", "s16le", "-"],
        capture_output=True, timeout=180, check=True)
    raw = proc.stdout[: len(proc.stdout) // 2 * 2]
    return np.frombuffer(raw, dtype="<i2").astype(np.float32) / 32768.0


def _duration_s(audio: pathlib.Path) -> float:
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration",
         "-of", "default=nw=1:nk=1", str(audio)],
        capture_output=True, text=True, timeout=30, check=True).stdout.strip()
    try:
        return float(out)
    except ValueError:
        return 0.0


# ------------------------------------------------------------------ silence
def _levels_db(x: np.ndarray, hop: int = 110) -> np.ndarray:
    """RMS of each ten milliseconds, in decibels below full scale."""
    n = len(x) // hop
    if n == 0:
        return np.zeros(0, dtype=np.float32)
    frames = x[: n * hop].reshape(n, hop)
    rms = np.sqrt(np.mean(frames * frames, axis=1) + 1e-12)
    return 20.0 * np.log10(rms)


def _threshold(db: np.ndarray) -> float:
    if len(db) == 0:
        return _FLOOR_DB
    return max(_FLOOR_DB, float(np.percentile(db, 95)) - _BELOW_LOUD_DB)


def _lead_ms(db: np.ndarray, threshold: float) -> int:
    loud = np.nonzero(db > threshold)[0]
    if len(loud) == 0:
        return 0
    # A breath before the first sound: a note cut at its very first sample clicks.
    return max(0, int(loud[0]) * 10 - 60)


def _tail_ms(db: np.ndarray, threshold: float) -> int:
    """How much nothing there is after the last sound."""
    loud = np.nonzero(db > threshold)[0]
    if len(loud) == 0:
        return 0
    # And room for the last note to finish dying away.
    return max(0, (len(db) - 1 - int(loud[-1])) * 10 - 200)


def _ends(db: np.ndarray, threshold: float) -> str:
    """Whether the song stops or fades: 'cold', 'fade', or '' when it cannot be said.

    A song that fades out has spent its last several seconds getting steadily quieter;
    one that ends cold was still at full volume a second before it stopped. It matters
    to anything that joins songs together: a fade has already made its own exit.
    """
    loud = np.nonzero(db > threshold)[0]
    if len(loud) < 1200:
        return ""
    last = int(loud[-1])
    # The loud moments of each stretch, not its average: drums are mostly the gaps
    # between the hits, and an average of those says "quiet" about a song at full tilt.
    body = float(np.percentile(db[: last + 1], 90))
    near = float(np.percentile(db[max(0, last - 200): max(1, last - 50)], 90))   # 2–0.5 s before
    far = float(np.percentile(db[max(0, last - 800): max(1, last - 600)], 90))   # 8–6 s before
    if near > body - 8:
        return "cold"
    if far > near + 6 and far > body - 14:
        return "fade"
    return ""


# ------------------------------------------------------------------ beats
def _onsets(x: np.ndarray) -> np.ndarray:
    """How much new energy arrives at each frame, and the same for the bass alone."""
    n = 1 + (len(x) - _FFT) // _HOP
    if n < 8:
        return np.zeros((2, 0), dtype=np.float32)
    idx = np.arange(_FFT)[None, :] + (_HOP * np.arange(n))[:, None]
    window = np.hanning(_FFT).astype(np.float32)
    # In blocks: the whole spectrogram of a long song at once is a lot of memory.
    # In four bands rather than one sum. A hi-hat is noise across a thousand bins and a
    # kick drum is a thump in a dozen, so summed bin by bin the hats win — and hats are
    # as often *between* the beats as on them, which is how a tracker ends up exactly
    # half a beat out. Each band is put on its own scale and then the bass counts most:
    # in nearly everything with a pulse, the pulse is in the low end.
    hz = _RATE / _FFT
    edges = [0, int(200 / hz) + 1, int(800 / hz) + 1, int(3000 / hz) + 1, _FFT // 2 + 1]
    bands = np.zeros((4, n), dtype=np.float32)
    previous = None
    for start in range(0, n, 2048):
        block = x[idx[start:start + 2048]] * window
        mag = np.log1p(100.0 * np.abs(np.fft.rfft(block, axis=1))).astype(np.float32)
        joined = mag if previous is None else np.vstack([previous, mag])
        rise = np.maximum(0.0, joined[1:] - joined[:-1])
        at = start if previous is None else start - 1
        for b in range(4):
            bands[b, at + 1: at + 1 + len(rise)] = rise[:, edges[b]:edges[b + 1]].sum(axis=1)
        previous = mag[-1:]

    def shaped(env: np.ndarray) -> np.ndarray:
        # Less its own local average, so a loud chorus is not one long onset; and to a
        # common scale, so the numbers below mean the same thing for every song.
        k = int(_FPS)                                   # a second
        local = np.convolve(env, np.ones(k, dtype=np.float32) / k, mode="same")
        out = np.maximum(0.0, env - local)
        sd = float(out.std())
        return out / sd if sd > 1e-9 else out

    each = [shaped(b) for b in bands]
    together = 2.0 * each[0] + 1.0 * each[1] + 1.0 * each[2] + 0.4 * each[3]
    sd = float(together.std())
    return np.stack([together / sd if sd > 1e-9 else together, each[0]])


def _tempo(env: np.ndarray) -> tuple[float, float]:
    """Beats a minute, and how much the envelope agrees that it has a pulse at all."""
    if len(env) < int(_FPS * 8):
        return 0.0, 0.0
    # The middle of the song, up to four minutes of it: intros and outros lie.
    span = min(len(env), int(_FPS * 240))
    start = (len(env) - span) // 2
    e = env[start:start + span] - env[start:start + span].mean()
    size = 1 << int(np.ceil(np.log2(2 * len(e))))
    spectrum = np.fft.rfft(e, size)
    ac = np.fft.irfft(spectrum * np.conj(spectrum))[: len(e)]
    if ac[0] <= 0:
        return 0.0, 0.0
    ac = ac / ac[0]

    lo, hi = int(_FPS * 60 / 210), int(_FPS * 60 / 55)       # 210 down to 55 a minute
    lags = np.arange(lo, hi + 1)
    bpm = 60.0 * _FPS / lags
    # Music is mostly played between 80 and 160. Without this, half and double time
    # score exactly as well as the real thing, because they line up just as often.
    prior = np.exp(-0.5 * (np.log2(bpm / 118.0) / 0.9) ** 2)
    # A real pulse also lines up at twice and three times its period.
    strength = ac[lags].copy()
    for multiple in (2, 3):
        further = lags * multiple
        ok = further < len(ac)
        strength[ok] += 0.5 * ac[further[ok]]
    scored = strength * prior
    best = int(lags[int(np.argmax(scored))])
    confidence = float(np.clip(ac[best], 0.0, 1.0))

    # Which octave. A pattern repeats just as well every two beats as every one — the
    # snare sees to that — and hi-hats between the beats repeat at twice the tempo, so
    # the strongest lag is as often half or double the pulse somebody would tap. The
    # pulse people tap sits between 80 and 160 a minute for nearly everything, so that
    # is where the answer is put, *if* the envelope repeats there too: a slow song is
    # not doubled into a tempo it shows no sign of.
    def settle(lag: int) -> int:
        """The strongest lag within a few percent of this one."""
        around = np.arange(max(lo, int(lag * 0.96)), min(len(ac) - 1, int(lag * 1.04) + 1) + 1)
        return int(around[int(np.argmax(ac[around]))]) if len(around) else lag

    for _ in range(2):
        now = 60.0 * _FPS / best
        if now < 80 and best // 2 >= lo:
            other = settle(best // 2)
        elif now >= 160 and best * 2 < len(ac):
            other = settle(best * 2)
        else:
            break
        if ac[other] < 0.3 * ac[best]:
            break
        best = other

    # Between the two lags either side, by a parabola: a frame is 11 ms, and at 170 a
    # minute that is three beats a minute of error.
    lag = float(best)
    if lo < best < len(ac) - 1:
        a, b, c = ac[best - 1], ac[best], ac[best + 1]
        bend = a - 2 * b + c
        if bend < 0:
            lag += 0.5 * (a - c) / bend
    return 60.0 * _FPS / lag, confidence


def _track(env: np.ndarray, bpm: float, tightness: float = 100.0) -> np.ndarray:
    """The frames the beats fall on."""
    period = 60.0 * _FPS / bpm
    n = len(env)
    score = env.astype(np.float64).copy()
    back = np.full(n, -1, dtype=np.int64)
    first, last = int(round(period / 2)), int(round(period * 2))
    offsets = np.arange(-last, -first + 1)
    penalty = -tightness * np.log(-offsets / period) ** 2
    for t in range(last, n):
        candidates = score[t + offsets] + penalty
        best = int(np.argmax(candidates))
        if candidates[best] > 0:
            score[t] += candidates[best]
            back[t] = t + offsets[best]
    # From the best-scoring frame in the last beat and a half, back to the start.
    tail = max(0, n - int(period * 1.5))
    t = tail + int(np.argmax(score[tail:]))
    beats = []
    while t >= 0:
        beats.append(t)
        t = int(back[t])
    return np.array(beats[::-1], dtype=np.int64)


def _on_the_beat(beats: np.ndarray, low: np.ndarray, period: float) -> np.ndarray:
    """The same beats, moved half a beat along if that is where the bass is.

    Evenly spaced and sitting on onsets is true of the off-beats as well, and a tracker
    cannot tell the two apart by spacing. The bass can: if far more of it arrives
    halfway between these beats than on them, these are the off-beats.
    """
    if len(beats) < 8 or len(low) == 0:
        return beats

    def bass_at(frames: np.ndarray) -> float:
        frames = frames[(frames >= 1) & (frames < len(low) - 2)]
        if len(frames) == 0:
            return 0.0
        return float(np.mean([low[f - 1: f + 2].max() for f in frames]))

    half = int(round(period / 2))
    on, off = bass_at(beats), bass_at(beats + half)
    return beats + half if off > 1.6 * on + 1e-6 else beats


def _bar_starts_on(beats: np.ndarray, low: np.ndarray) -> int:
    """Which beat of four the bar most likely starts on: 0 to 3.

    A guess, and labelled as one. In most music made for dancing the kick is heaviest
    on the one, so the phase with the most bass arriving on it is taken to be the one.
    """
    if len(beats) < 16:
        return 0
    weight = np.zeros(4)
    for phase in range(4):
        at = beats[phase::4]
        at = at[at < len(low)]
        weight[phase] = float(np.mean([low[max(0, b - 2): b + 3].max() for b in at]))
    return int(np.argmax(weight))


# ------------------------------------------------------------------ the whole of it
def measure(audio: pathlib.Path) -> dict:
    duration = _duration_s(audio)
    out: dict = {
        "version": VERSION, "duration_ms": int(duration * 1000),
        "lead_ms": 0, "tail_ms": 0, "ends": "",
        "bpm": None, "confidence": 0.0, "beats": [], "bar_starts_on": 0,
    }
    if duration <= 0:
        return out

    whole = duration <= _BEATS_UP_TO_S
    if whole:
        x = _decode(audio)
        db = _levels_db(x)
        threshold = _threshold(db)
        lead, tail = _lead_ms(db, threshold), _tail_ms(db, threshold)
        out["ends"] = _ends(db, threshold)
    else:
        # Only the two ends, and judged against each other: a loud set with a quiet
        # minute at the start is still a set that starts when the sound does.
        head = _decode(audio, "-t", str(_ENDS_S))
        foot = _decode(audio, "-sseof", f"-{_ENDS_S}")
        head_db, foot_db = _levels_db(head), _levels_db(foot)
        threshold = _threshold(np.concatenate([head_db, foot_db]))
        lead, tail = _lead_ms(head_db, threshold), _tail_ms(foot_db, threshold)
        out["ends"] = _ends(foot_db, threshold)
        x = None

    out["lead_ms"] = lead if lead >= _WORTH_TRIMMING_MS else 0
    out["tail_ms"] = tail if tail >= _WORTH_TRIMMING_MS else 0

    if x is None or len(x) < _RATE * 10:
        return out
    env, low = _onsets(x)
    bpm, confidence = _tempo(env)
    out["confidence"] = round(confidence, 3)
    # Below this the envelope does not repeat at any tempo: there is no pulse to find,
    # and beats laid over it anyway would be a metronome that ignores the music.
    if bpm <= 0 or confidence < 0.12:
        return out
    beats = _track(env, bpm)
    beats = _on_the_beat(beats, low, 60.0 * _FPS / bpm)
    # Only where there is music. The tracker walks back from the end of the file to the
    # start of it, and would count its way through the silence at either end too.
    at_ms = (beats * _HOP + _ONSET_AT) * 1000.0 / _RATE
    sounding = (at_ms >= lead - 40) & (at_ms <= duration * 1000 - tail)
    beats, at_ms = beats[sounding], at_ms[sounding]
    if len(beats) < 8:
        return out
    # Whether the beats found are where the onsets are. On a song with a pulse they sit
    # on the peaks of the envelope; laid over something with none, they sit wherever
    # the spacing put them, and the envelope there is no higher than anywhere else.
    on_beat = float(np.mean([env[max(0, b - 1): b + 2].max() for b in beats]))
    between = float(np.mean(env)) + 1e-9
    out["contrast"] = round(on_beat / between, 2)
    if out["contrast"] < _PULSE_CONTRAST:
        return out
    # The tempo as the beats actually came out — a line through all of them, which is
    # far finer than the spacing of two, counted in frames of 11 ms.
    slope = float(np.polyfit(np.arange(len(at_ms)), at_ms, 1)[0])
    out["bpm"] = round(60000.0 / slope, 1)
    out["beats"] = [int(round(ms)) for ms in at_ms]
    out["bar_starts_on"] = _bar_starts_on(beats, low)
    return out


def for_track(data_dir: pathlib.Path, audio: pathlib.Path, sha: str) -> dict:
    """The song's timing, from disk if it has been worked out before."""
    cached = cache_path(data_dir, sha)
    try:
        return json.loads(cached.read_text())
    except (OSError, ValueError):
        pass
    found = measure(audio)
    cached.parent.mkdir(parents=True, exist_ok=True)
    tmp = cached.with_suffix(".tmp")
    tmp.write_text(json.dumps(found, separators=(",", ":")))
    tmp.replace(cached)
    return found
