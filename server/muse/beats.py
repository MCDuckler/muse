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

from . import analysis

# Bumped when what is measured changes, so old answers on disk are not served for ever.
# 2: the key, the bars, each bar's loudness, the phrases and the cues.
# 3: the drops — where the song opens up. See analysis.py.
# 4: the tempo to a hundredth, and a record that keeps one tempo given one exact grid.
# 5: the tempo a DJ counts (the kick decides half, double and the triplet step, read
#    finely), and the bar's one where the record's sections change.
# 6: an exact grid carried on to where the sound starts and ends (the tracker lost the
#    first two or three beats of nearly every record, and with them its first bar),
#    and the four-bar markers where the record's sections start (four_bars).
VERSION = 12  # 9: a record too busy for the tempo found is counted at the double; 10: and one read in threes is stepped up into the break it is (116 was two thirds of 174)
# 11: the beat and not the off-beat, by the snare and the sub-bass where the bass is on
#     the "and"; and no step down a third from a tempo already busy enough to be the count.
# 12: the tracker's word (Beat This!, handed in by the pool) in the house's own reading:
#     its tempo family where the house locked onto two thirds or four thirds of the pulse,
#     its beat where the house's grid sat half a beat off it, and its beats where the
#     house heard no pulse. See tracker_line and measure.

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
    """How much new energy arrives at each frame; then the same for the bass alone
    (below 200 Hz), the low mids (200–800), the snare's band (800–3000) and the sub
    (below 60) — the bands the beat is told from the off-beat by."""
    n = 1 + (len(x) - _FFT) // _HOP
    if n < 8:
        return np.zeros((5, 0), dtype=np.float32)
    idx = np.arange(_FFT)[None, :] + (_HOP * np.arange(n))[:, None]
    window = np.hanning(_FFT).astype(np.float32)
    # In blocks: the whole spectrogram of a long song at once is a lot of memory.
    # In four bands rather than one sum. A hi-hat is noise across a thousand bins and a
    # kick drum is a thump in a dozen, so summed bin by bin the hats win — and hats are
    # as often *between* the beats as on them, which is how a tracker ends up exactly
    # half a beat out. Each band is put on its own scale and then the bass counts most:
    # in nearly everything with a pulse, the pulse is in the low end.
    hz = _RATE / _FFT
    # Five raw bands; the first two together are the bass as it always was.
    edges = [0, int(60 / hz) + 1, int(200 / hz) + 1, int(800 / hz) + 1, int(3000 / hz) + 1,
             _FFT // 2 + 1]
    raw = np.zeros((5, n), dtype=np.float32)
    previous = None
    for start in range(0, n, 2048):
        block = x[idx[start:start + 2048]] * window
        mag = np.log1p(100.0 * np.abs(np.fft.rfft(block, axis=1))).astype(np.float32)
        joined = mag if previous is None else np.vstack([previous, mag])
        rise = np.maximum(0.0, joined[1:] - joined[:-1])
        at = start if previous is None else start - 1
        for b in range(5):
            raw[b, at + 1: at + 1 + len(rise)] = rise[:, edges[b]:edges[b + 1]].sum(axis=1)
        previous = mag[-1:]
    bands = np.stack([raw[0] + raw[1], raw[2], raw[3], raw[4]])

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
    return np.stack([together / sd if sd > 1e-9 else together, each[0], each[1], each[2],
                     shaped(raw[0])])


def _off_beat(on: dict[str, float], off: dict[str, float]) -> bool:
    """Whether these are the off-beats: whether the beat is half a beat from here.

    By the bass first, as before — if far more of it arrives between these beats than
    on them, these are the off-beats. But on a record with its bassline on the "and" the
    bass says the and, and the grid sat half a beat off the kick on one record in
    fourteen. The snare and the clap do not play on the and, and the sub does not
    either: where the snare's band clearly sits on the other phase (with the low mids
    not against it), or the sub clearly does (with the snare not against it), that is
    the beat.

    Measured on the library against a neural tracker's reading: of 75 records sitting
    half a beat off, 43 are put right, and of 150 that were right none are moved.
    """
    def ratio(band: str) -> float:
        return on[band] / (off[band] + 1e-9)

    # The snare and the sub first, either way: where they are clear, the bass is not
    # asked — a bassline on the "and" is louder than the kick on the one, and asked
    # first it moved the grid onto the and over a clap that said otherwise.
    snare, lowmid, sub = ratio("snare"), ratio("lowmid"), ratio("sub")
    if snare < 0.75 and snare * lowmid < 1.0:
        return True
    if snare > 1 / 0.75 and snare * lowmid > 1.0:
        return False
    if sub < 0.6 and snare < 1.0:
        return True
    if sub > 1 / 0.6 and snare > 1.0:
        return False
    return off["bass"] > 1.6 * on["bass"] + 1e-9


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


def _autocorrelation(sig: np.ndarray) -> np.ndarray:
    e = sig.astype(np.float64) - float(sig.mean())
    size = 1 << int(np.ceil(np.log2(2 * len(e))))
    spectrum = np.fft.rfft(e, size)
    ac = np.fft.irfft(spectrum * np.conj(spectrum))[: len(e)]
    return ac / ac[0] if ac[0] > 0 else ac


_FINE_HOP = 32                   # 2.9 ms at 11 kHz


def _fine(x: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """The kick drum's onsets and the whole spectrum's, every 2.9 ms: the envelope the
    tracker uses is a frame every 11.6 ms under a 93 ms window, too smeared to tell a
    kick on every beat from a kick on every other one — which is the whole question
    between 83 and 166."""
    n = len(x)
    spectrum = np.fft.rfft(x.astype(np.float64))
    hz = np.fft.rfftfreq(n, 1.0 / _RATE)

    def band(lo: float, hi: float) -> np.ndarray:
        y = np.fft.irfft(spectrum * ((hz >= lo) & (hz <= hi)), n) ** 2
        e = y[: len(y) // _FINE_HOP * _FINE_HOP].reshape(-1, _FINE_HOP).mean(axis=1)
        rise = np.maximum(0.0, np.diff(np.log(e + 1e-9), prepend=np.log(e[0] + 1e-9)))
        return rise - np.convolve(rise, np.ones(64) / 64, mode="same")

    return band(30.0, 150.0), band(30.0, 5000.0)


def _busy(env: np.ndarray, bpm: float) -> float:
    """How many things happen in the record per beat of [bpm].

    The tempo a DJ counts is not only a matter of where the pulse is — half and double
    are both pulses — but of how much the record does between one beat and the next.
    At the counted tempo a dance record does one or two things a beat: the kick, and
    something on the off-beat. Three or more, and the beat being counted is two beats.

    That is the difference between a drum & bass record and a rap record, which is
    where this was losing: both have their kick on the one and their snare on the
    three, both autocorrelate best at eighty-seven, and one of them is a hundred and
    seventy-four. What tells them apart is that the break is busy and the rap is not.

    Measured on eight records of the library it was getting wrong and right — four
    liquid drum & bass, four German rap — the two do not overlap and are not close:
    2.76 to 3.12 against 1.86 to 2.26. Peaks in the onset envelope that clear its own
    spread, per beat.
    """
    if len(env) < 16 or bpm <= 0:
        return 0.0
    e = env - env.mean()
    spread = float(e.std())
    if spread <= 0:
        return 0.0
    inner = e[1:-1]
    peaks = int(((inner > e[:-2]) & (inner >= e[2:]) & (inner > spread)).sum())
    seconds = len(env) / _FPS
    return peaks / seconds / (bpm / 60.0) if seconds > 0 else 0.0


# Onsets a beat past which the tempo found may be half the one it would be counted at.
#
# On the two classes this was drawn from — four liquid drum & bass records and four
# German rap records — they sat either side of this with room to spare. On twenty taken
# at random from the same band of the library they do not: a synth-pop record at 91 is
# as busy as a break at 174, and eleven of the twenty doubled, which is not fine tuning,
# it is re-tempoing the library. So this is not enough on its own.
_BUSY_IS_HALVED = 2.5

# ...and the double has to land where records like that are actually counted.
#
# A blunt rule, and named as one: it is the tempo range drum & bass is mixed at. The
# case this exists for is a break whose kick and snare sit exactly where a slow
# record's do, and the only other thing true of every one of them is that it is
# somewhere near 174. Outside this the busy-ness is left alone, because outside this
# the evidence was a coin toss: of the twenty, the ones it would have doubled to 180
# and 187 are a coldwave record and an IDM record that belong where they are.
#
# The kick route below is not narrowed by this. A record with its kick on every beat of
# the faster tempo is doubled wherever it lands, which is what carries hardstyle and
# hardtekk.
_BREAK_TEMPO = (165.0, 178.0)

# Things a beat, past which a record read in threes is really a break read two thirds
# slow. Lower than _BUSY_IS_HALVED because two thirds of a tempo is a smaller lie than
# half of one, so the same record looks less busy at it.
_BUSY_IN_THREES = 2.0


def _level(x: np.ndarray, bpm: float, env: np.ndarray | None = None,
           octaves_only: bool = False) -> float:
    """The pulse a DJ counts: the kick drum's, where the tempo found is half, double or
    one and a half times it.

    [_tempo] leans towards 80 to 160 a minute, the pulse people tap to — and halves
    anything faster. For a DJ that is wrong: a hardtekk record at 163 came back at
    81.5 and was synced to a 150 record as if it were a slow one; and the triplet step
    was missed altogether — 155 with hats on the off-beats came back at 103.3, 165 at
    110. On a record made for dancing the kick is on every beat and does not play in
    threes: so of the tempo found and its neighbours, the one taken is the fastest the
    kick and the whole spectrum still repeat at nearly as strongly, as long as it is
    one a DJ would count (70 to 190). A slow record whose kick falls on every other
    beat of the doubled tempo stays slow.
    """
    if len(x) < _RATE * 8:
        return bpm
    kick_env, whole_env = _fine(x)
    kick, whole = _autocorrelation(kick_env), _autocorrelation(whole_env)
    per_second = _RATE / _FINE_HOP

    def at(ac: np.ndarray, b: float) -> float:
        # The strongest within a whisker of the lag — the tempo it is asked about has
        # been refined ([_refine]), so its multiples are where they are; any wider and
        # a record's other repetitions (a swung hat a sample short of the half-beat)
        # are taken for the one being asked about.
        lag = 60.0 * per_second / b
        lo, hi = int(lag * 0.996), int(np.ceil(lag * 1.004)) + 1
        if hi >= len(ac):
            return 0.0
        return float(ac[lo:hi].max())

    def score(b: float) -> float:
        return at(kick, b) + at(whole, b)

    best, kept = bpm, score(bpm)
    # Whether the double was taken because the record is a busy break. It settles an
    # argument below.
    a_break = False
    # Double, by either of two signs.
    #
    # The first is the kick: a record whose kick is on every beat of the faster tempo.
    #
    # The second is how busy the record is ([_busy]), and it is here because the first
    # could not see a break. A drum & bass record has its kick on the one and its snare
    # on the three exactly as a rap record does, so it repeats best at half what a DJ
    # counts and its kick says nothing against that — and the floor of 0.2 on a
    # quantity whose scale runs from 0.03 to 0.25 between records shut the door on the
    # quiet ones for good. Twelve of one artist's records in the library sat at
    # eighty-five to eighty-seven for it, every one of them a hundred and seventy-four.
    #
    # The two signs are deliberately not one test. Loosening the first was measured on
    # the same eight records and made it worse: the rap record with the strongest
    # double of the lot is genuinely ninety-two.
    if bpm * 2 <= 190.0:
        s2 = score(bpm * 2)
        if s2 >= max(0.2, 0.75 * kept):
            best, kept = bpm * 2, s2
        elif (env is not None
                and _BREAK_TEMPO[0] <= bpm * 2 <= _BREAK_TEMPO[1]
                and _busy(env, bpm) >= _BUSY_IS_HALVED):
            a_break = True
            # The score it is *held* at is the better of the two, not the double's
            # own. The double taken this way is one the score did not like, and
            # handing that small number on as what has to be beaten made the triplet
            # step below trivial to pass — a break at 174 came out at 116.
            best, kept = bpm * 2, max(s2, kept)
    # Seeded by the tracker's tempo (measure), the family is settled and only the octave
    # is the house's to decide: no triplet step.
    if octaves_only:
        return best
    # The triplet step, either way: only on clear evidence, and never out of a break.
    #
    # Two thirds of a hundred and seventy-four is a hundred and sixteen, and that is
    # where half of one artist's records went once the doubling above started working:
    # judged a busy break at 174, then stepped straight back down to 116 by this, one
    # line later. Two rules contradicting each other.
    #
    # But not by refusing the step — that was tried and cost as much as it saved. The
    # same artist has records the step *rescues*, where the pulse comes out at 116 and
    # a third on top of it is the 174 it should have been all along. What is refused
    # is the step that takes a record judged to be a break *out* of where breaks are.
    # The rule is about where it lands, not about whether to look.
    for ratio in (1.5, 1 / 1.5):
        other = best * ratio
        if not 70.0 <= other <= 190.0:
            continue
        if a_break and not (_BREAK_TEMPO[0] <= other <= _BREAK_TEMPO[1]):
            continue
        s3 = score(other)
        # A third on top, for a record too busy for the pulse it was given.
        #
        # The doubling above cannot reach these: a break read at 116 doubles to 232,
        # which is nobody's tempo, so the range test throws it out before busy-ness is
        # ever asked. But 116 is two thirds of 174 — the tracker locked onto the
        # three-against-two the break is full of — and a record doing better than two
        # things a beat at 116 is doing one and a half at 174, which is what a counted
        # tempo looks like. Only upward, only into the window breaks live in, and only
        # where the record is busy enough to say so.
        if (ratio > 1 and env is not None
                and _BREAK_TEMPO[0] <= other <= _BREAK_TEMPO[1]
                and _busy(env, best) >= _BUSY_IN_THREES):
            best, kept = other, max(s3, kept)
            continue
        if s3 >= max(0.15, 1.5 * kept) and at(kick, other) > max(0.05, at(kick, best)):
            # Down a third only from a tempo too fast to be the count — fewer than one
            # thing a beat. A record counted at 142 with a dotted rhythm scored better
            # at 95 and was stepped down to it; at 142 it was doing 1.2 things a beat,
            # which is a counted tempo, not one and a half times one. Measured against
            # the neural tracker: 8 of 23 records read at two thirds put right, none of
            # 150 right ones moved.
            if ratio < 1 and env is not None and _busy(env, best) >= 1.0:
                continue
            best, kept = other, s3
    return best


def _refine(env: np.ndarray, bpm: float) -> float:
    """The same tempo, to a hundredth of a beat a minute rather than to a frame.

    [_tempo] reads a lag counted in frames of 11.6 ms and bends it between the two
    either side, which is as fine as a frame allows and no finer: at 155 a minute a
    beat is 33.3 frames, and a third of a frame out is a quarter of a per cent. Real
    records came back at 155.4 for 155 and 151.3 for 151 — and a beat tracker told
    155.4 walks a millisecond a beat off the music and slips back by a fraction of a
    beat whenever the onsets drag it, which on the booth's decks is a mix falling apart
    every minute and a half.

    The pulse lines up four, eight, sixteen and thirty-two beats out just as it does
    one beat out, and there the same third of a frame is a quarter, an eighth, a
    sixteenth, a thirty-second of it. So the lag is found again that far out, each time
    within a fifth of a beat of where the last reading puts it — close enough that the
    hi-hats between the beats are never mistaken for it.
    """
    period = 60.0 * _FPS / bpm
    e = env.astype(np.float64) - float(env.mean())
    n = len(e)
    size = 1 << int(np.ceil(np.log2(2 * n)))
    spectrum = np.fft.rfft(e, size)
    ac = np.fft.irfft(spectrum * np.conj(spectrum))[:n]
    # Per pair of frames that overlap, so a longer lag is not marked down for having
    # fewer of them.
    ac = ac / np.maximum(1, n - np.arange(n))
    for k in (4, 8, 16, 32):
        lag = k * period
        if lag > n / 2:
            break
        reach = 0.2 * period
        lo, hi = int(np.floor(lag - reach)), int(np.ceil(lag + reach))
        if lo < 1 or hi + 1 >= n:
            break
        i = lo + int(np.argmax(ac[lo:hi + 1]))
        if i <= lo or i >= hi:
            break                       # at the edge: nothing clear this far out
        a, b, c = ac[i - 1], ac[i], ac[i + 1]
        bend = a - 2 * b + c
        if bend >= 0:
            break
        period = (i + 0.5 * (a - c) / bend) / k
    return 60.0 * _FPS / period


def _comb(env: np.ndarray, period: float, phases: np.ndarray, k: np.ndarray) -> np.ndarray:
    """How much onset lands on each of [phases] + [k] beats of [period] frames: the
    envelope read there between frames, averaged over the beats."""
    pos = phases[:, None] + k[None, :] * period
    pos = np.clip(pos, 0, len(env) - 1.001)
    i0 = np.floor(pos).astype(np.int64)
    f = pos - i0
    return ((1.0 - f) * env[i0] + f * env[i0 + 1]).mean(axis=1)


def _comb_peak(env: np.ndarray, period: float, phase: float, k: np.ndarray) -> float:
    """How much onset lands within a frame either side of each of [phase] + [k] beats:
    the peak nearby rather than the value read between frames. A drum hit is one or two
    frames wide and lands a frame early or late from beat to beat; read between frames
    at one exact phase it is half missed, and the bands that tell the beat from the
    off-beat come out closer to even than they are."""
    pos = np.round(phase + k * period).astype(np.int64)
    pos = pos[(pos >= 1) & (pos < len(env) - 1)]
    if len(pos) == 0:
        return 0.0
    return float(np.mean(np.maximum(np.maximum(env[pos - 1], env[pos]), env[pos + 1])))


def _one_grid(env: np.ndarray, low: np.ndarray, period: float,
              first: int, last: int, bands: dict[str, np.ndarray] | None = None) -> np.ndarray | None:
    """The frames the beats fall on, as one exact grid — where the record keeps one
    tempo from end to end. None where it does not, and the tracked beats stand.

    A tracker places one beat at a time, each where the onsets pull it, and on a
    record whose onsets are not all on the beat — a swung hat, a bassline ahead of the
    kick, the thin last minute of a fade — it wanders and slips. A record made on a
    computer does not wander: it is a start and a period. So the period ([_refine]) is
    taken as given, and the start is the one that puts the most onset on the beat
    across the whole record, read between frames. Then believed only if each stretch
    of 32 beats on its own agrees where the beat is — a band, or a record that changes
    tempo, does not, and keeps the beats the tracker found.
    """
    if last - first < 32 * period:
        return None
    k = np.arange(int(np.ceil(first / period)), int(np.floor(last / period)))
    phases = np.arange(0.0, period, 0.1)
    score = _comb(env, period, phases, k)
    i = int(np.argmax(score))
    best = float(phases[i])
    if 0 < i < len(score) - 1:
        a, b, c = score[i - 1], score[i], score[i + 1]
        bend = a - 2 * b + c
        if bend < 0:
            best += 0.1 * 0.5 * (a - c) / bend
    # The beat, not the off-beat: see _off_beat. Read as peaks near each beat, the way
    # the rule was measured.
    if bands:
        on = {"bass": _comb_peak(low, period, best, k)}
        off = {"bass": _comb_peak(low, period, best + period / 2, k)}
        for name, env_ in bands.items():
            on[name] = _comb_peak(env_, period, best, k)
            off[name] = _comb_peak(env_, period, best + period / 2, k)
        if _off_beat(on, off):
            best = (best + period / 2) % period
    else:
        on_ = float(_comb(low, period, np.array([best]), k)[0])
        off_ = float(_comb(low, period, np.array([best + period / 2]), k)[0])
        if off_ > 1.6 * on_ + 1e-9:
            best = (best + period / 2) % period
    # Each stretch of 32 beats, every 16, on its own: where would it put the beat? Twice
    # over — the second time with the period put right by the first. Where the period
    # is a hair out, the stretches say so by where they put the beat: a little later
    # each one along, in a straight line whose slope is how much.
    for attempt in range(2):
        near = best + np.arange(-period / 4, period / 4, 0.1)
        agree, asked = 0, 0
        centres, phases = [], []
        for w in range(0, len(k) - 32 + 1, 16):
            kw = k[w:w + 32]
            sw = _comb(env, period, near, kw)
            if float(sw.max()) < 1.3 * float(np.mean(sw)) + 1e-9:
                continue                # nothing clear here: a breakdown, a silence
            asked += 1
            found = float(near[int(np.argmax(sw))])
            if abs(found - best) <= 1.2:
                agree += 1
                centres.append(float(kw.mean()))
                phases.append(found)
        if asked < 4 or agree < 0.85 * asked:
            return None
        if attempt == 1 or len(centres) < 4:
            break
        slope, at0 = np.polyfit(np.array(centres), np.array(phases), 1)
        # Never more than a whisker: this puts right a hundredth of a beat a minute, and
        # anything bigger is the stretches disagreeing, not the period.
        if abs(slope) > 0.002 * period:
            break
        period += float(slope)
        best = float(at0)
    return best + k * period


def _to_the_ends(grid: np.ndarray, from_ms: float, to_ms: float) -> np.ndarray:
    """An exact grid carried on to where the sound starts and where it ends.

    The tracker finds its first beat two or three beats into nearly every record — it
    has nothing behind it to be pulled into step by — and with those beats went the
    record's first bar: the bars were counted from the second, and every four-bar
    phrase came out a bar out. A record on a grid was on it from its first sound, so
    the grid is simply carried back there, and on to its last. A beat the file's start
    cuts off by a hair (the encoder's own few milliseconds) is still the first beat,
    and is put at the start.
    """
    if len(grid) < 2:
        return grid
    period = float(grid[-1] - grid[0]) / (len(grid) - 1)
    frame_ms = _HOP * 1000.0 / _RATE
    beat_ms = period * frame_ms

    def ms(f: float) -> float:
        return (f * _HOP + _ONSET_AT) * 1000.0 / _RATE

    lowest = max(0.0, from_ms - 40.0) - min(40.0, 0.1 * beat_ms)
    before = max(0, int(np.floor((ms(float(grid[0])) - lowest) / beat_ms)))
    after = max(0, int(np.floor((to_ms - ms(float(grid[-1]))) / beat_ms)))
    k = np.arange(-before, len(grid) + after)
    return float(grid[0]) + k * period


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


def _on_the_beat(beats: np.ndarray, low: np.ndarray, period: float,
                 bands: dict[str, np.ndarray] | None = None) -> np.ndarray:
    """The same beats, moved half a beat along if that is where the beat is.

    Evenly spaced and sitting on onsets is true of the off-beats as well, and a tracker
    cannot tell the two apart by spacing. The bass, the snare and the sub can: see
    _off_beat.
    """
    if len(beats) < 8 or len(low) == 0:
        return beats

    def at(env: np.ndarray, frames: np.ndarray) -> float:
        frames = frames[(frames >= 1) & (frames < len(env) - 2)]
        if len(frames) == 0:
            return 0.0
        return float(np.mean([env[f - 1: f + 2].max() for f in frames]))

    half = int(round(period / 2))
    on = {"bass": at(low, beats)}
    off = {"bass": at(low, beats + half)}
    for name, env_ in (bands or {}).items():
        on[name] = at(env_, beats)
        off[name] = at(env_, beats + half)
    flip = _off_beat(on, off) if bands else off["bass"] > 1.6 * on["bass"] + 1e-6
    return beats + half if flip else beats


def _bar_starts_on_by_change(x: np.ndarray, beats_ms: np.ndarray) -> int | None:
    """Which beat of four the bar starts on, from where the record changes.

    A record is written in bars and its sections start on the one: a breakdown, a
    drop, the bass coming in, a new chord. So the spectrum of each beat is taken, and
    wherever the four beats after differ most from the four before, that beat is
    counted for its place in the bar; the place with the most change is the one.
    (By the bass alone — the old way — every beat of a four-on-the-floor record looks
    the same, and a third of the records checked had their bars a beat or three out:
    their sections changed on the analysis's beat two, three or four.) None where the
    record does not change clearly enough to say.
    """
    n = len(beats_ms)
    if n < 48:
        return None
    edges = np.unique(np.geomspace(2, 2048, 33).astype(int))
    rows = []
    for a, b in zip(beats_ms[:-1], beats_ms[1:]):
        seg = x[int(a * _RATE / 1000):int(b * _RATE / 1000)]
        if len(seg) < 256:
            rows.append(np.zeros(len(edges) - 1))
            continue
        mag = np.abs(np.fft.rfft(seg * np.hanning(len(seg)), 4096))
        rows.append(np.log1p(np.array([mag[edges[i]:edges[i + 1]].mean()
                                       for i in range(len(edges) - 1)])))
    spec = np.array(rows)
    k = 4
    change = np.zeros(len(spec))
    for i in range(k, len(spec) - k):
        change[i] = float(np.linalg.norm(spec[i:i + k].mean(axis=0) - spec[i - k:i].mean(axis=0)))
    peaks = [i for i in range(k, len(spec) - k)
             if change[i] > 0 and change[i] == change[max(0, i - 4):i + 5].max()]
    peaks = sorted(peaks, key=lambda i: -change[i])[:16]
    if len(peaks) < 6:
        return None
    weight = np.zeros(4)
    for i in peaks:
        weight[i % 4] += change[i]
    best = int(np.argmax(weight))
    # Only where the record says so clearly: most of the change on one place.
    if weight[best] < 0.45 * weight.sum():
        return None
    return best


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
        at = at[(at >= 0) & (at < len(low))]
        weight[phase] = float(np.mean([low[max(0, b - 2): b + 3].max() for b in at]))
    return int(np.argmax(weight))


# ------------------------------------------------------------------ the tracker's word
# The trained tracker (Beat This!, run by the pool's computers — beat_net.dart — and kept
# by pool.keep_beats) hears the music; the house's arithmetic hears the envelope. Where
# the two disagree about the *family* of the tempo — the house locked onto two thirds or
# four thirds of the pulse, and then doubled or halved that — the tracker is right nearly
# every time: measured over the library, 678 records sat at 4/3, 2/3, 3/2 or 3/4 of the
# tracker's count (Erasure at 170.9 for 115, Spray at 178.66 for 134), and the titles say
# the house was wrong on all of those checked. Which *octave* of that family a DJ counts is
# still the house's to decide: the tracker halves drum & bass and rap and doubles some
# pop, and the house's rules for that (_level) were measured on exactly those.
#
# The tracker's beats are only as fine as its frames (20 ms) and its minimal peak picking
# doubles a beat here and misses one there — half the library's readings have ten or
# more such steps — so what is taken from it is never its beats one by one but one line
# through them, and it is believed only where most of its beats sit on that line.
_TRACKER_REGULAR = 0.8          # share of its beats one period from the last
_TRACKER_ON_LINE = 0.15         # median distance from the line, in periods


def tracker_line(beats_ms: list[int] | None) -> dict | None:
    """The tracker's reading as one line — {"period_ms", "at0_ms", "bpm"} — where it is
    steady enough to be one; None where it is not (a band, a tempo change, or a reading
    that is mostly noise). A beat the tracker doubled or missed is still on the line, at
    its own count of the period, and does not count against it."""
    if not beats_ms or len(beats_ms) < 32:
        return None
    nb = np.array(beats_ms, dtype=float)
    ibi = np.diff(nb)
    period = float(np.median(ibi))
    if period <= 0:
        return None
    regular = float(np.mean(np.abs(ibi / period - 1.0) < 0.1))
    if regular < _TRACKER_REGULAR:
        return None
    # Each beat at its own count of the period: a doubled beat is half a step on, a
    # missed one two. (Rounded to whole steps, a run of doubled beats stood still and
    # broke the line for the rest of the record.) Then the line through the beats that
    # sit on whole counts, fitted again at those counts.
    steps = np.round(2.0 * ibi / period) / 2.0
    k = np.concatenate([[0.0], np.cumsum(steps)])
    period, at0 = np.polyfit(k, nb, 1)
    if period <= 0:
        return None
    # The beat's phase: the beats on whole counts of that line, or those half a count
    # from it, whichever there are more of — a tracker that heard the first beat on the
    # "and", or changed its mind about the beat for a breakdown, has the rest of its
    # beats half a count off its own first one. How many sit on the phase taken is how
    # far the tracker's *beat* (as against its tempo) is to be believed: phase_share.
    count = (nb - at0) / period
    on = np.abs(count - np.round(count)) < 0.25
    if float(on.mean()) < 0.5:
        count = count - 0.5
        on = np.abs(count - np.round(count)) < 0.25
    k = np.round(count[on])
    period, at0 = np.polyfit(k, nb[on], 1)
    if period <= 0:
        return None
    residual = np.abs(nb[on] - (at0 + period * k))
    if float(np.median(residual)) > _TRACKER_ON_LINE * period:
        return None
    return {"period_ms": float(period), "at0_ms": float(at0), "bpm": 60000.0 / float(period),
            "phase_share": round(float(on.mean()), 3)}


def _same_family(bpm: float, tracker_bpm: float) -> bool:
    """Whether [bpm] is the tracker's tempo or an octave of it."""
    return any(abs(bpm / (tracker_bpm * m) - 1.0) < 0.03 for m in (0.5, 1.0, 2.0))


def _tracker_tempo(env: np.ndarray, x: np.ndarray, tracker_bpm: float) -> float:
    """The tempo to count the record at, given the tracker's: the tracker's own count
    where it is one a DJ would (70 to 190) — it has heard the music, and the house's
    "tapped" prior of 80 to 160 is what halved the break it read at 174 — else the
    octave of it the envelope repeats at within that range; then the house's own
    octave rules (_level) on top: the kick on every beat of the double, the busy break.
    The same path the house takes for a record it read right in the first place."""
    if 70.0 <= tracker_bpm <= 190.0:
        return _level(x, tracker_bpm, env, octaves_only=True)
    candidates = [tracker_bpm * m for m in (0.5, 2.0) if 55.0 <= tracker_bpm * m <= 210.0]
    if not candidates:
        return tracker_bpm
    span = min(len(env), int(_FPS * 240))
    start = (len(env) - span) // 2
    ac = _autocorrelation(env[start:start + span])

    def at(b: float) -> float:
        lag = 60.0 * _FPS / b
        lo, hi = int(lag * 0.96), int(lag * 1.04) + 1
        return float(ac[lo:hi].max()) if 0 < lo < hi < len(ac) else 0.0

    strength = {b: at(b) for b in candidates}
    tapped = [b for b in candidates if 80.0 <= b < 160.0]
    best = max(candidates, key=strength.get)
    if tapped and strength[tapped[0]] >= 0.3 * strength[best]:
        best = tapped[0]
    return _level(x, best, env, octaves_only=True)


def _line_beats(line: dict, from_ms: float, to_ms: float) -> np.ndarray:
    """The tracker's line as beats, in milliseconds, from where the sound starts to
    where it ends."""
    period, at0 = line["period_ms"], line["at0_ms"]
    first = int(np.ceil((max(0.0, from_ms - 40.0) - at0) / period))
    last = int(np.floor((to_ms - at0) / period))
    return at0 + period * np.arange(first, last + 1)


def _frames_of(at_ms: np.ndarray) -> np.ndarray:
    return np.round((at_ms * _RATE / 1000.0 - _ONSET_AT) / _HOP).astype(np.int64)


# ------------------------------------------------------------------ the whole of it
def measure(audio: pathlib.Path, neural: dict | None = None) -> dict:
    """What the record is made of in time; with the tracker's reading ([neural], as
    pool.keep_beats kept it) weighed in where there is one — see tracker_line."""
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
    env, low, lowmid, snare, sub = _onsets(x)
    bands = {"lowmid": lowmid, "snare": snare, "sub": sub}
    sound_end = duration * 1000 - tail
    line = tracker_line((neural or {}).get("beats_ms"))
    # Its tempo is believed where there is a line at all; its beat only where most of
    # its beats sit on the one phase of that line.
    sure_of_the_beat = bool(line) and line["phase_share"] >= _TRACKER_REGULAR
    if neural is not None:
        out["tracker"] = {"bpm": round(line["bpm"], 2) if line else None,
                          "steady": line is not None, "took": []}

    def from_the_tracker() -> dict:
        """The tracker's line as the record's beats, where the house heard no pulse."""
        at_ms = np.maximum(_line_beats(line, lead, sound_end), 0.0)
        if len(at_ms) < 8:
            return analysis.add(out, x, [], 0, low, _FPS)
        out["tracker"]["took"].append("beats")
        out["bpm"] = round(line["bpm"], 2)
        out["grid"] = True
        out["beats"] = [int(round(ms)) for ms in at_ms]
        by_change = _bar_starts_on_by_change(x, at_ms)
        out["bar_starts_on"] = by_change if by_change is not None else _bar_starts_on(_frames_of(at_ms), low)
        return analysis.add(out, x, out["beats"], out["bar_starts_on"], low, _FPS)

    bpm, confidence = _tempo(env)
    out["confidence"] = round(confidence, 3)
    # Below this the envelope does not repeat at any tempo: there is no pulse to find,
    # and beats laid over it anyway would be a metronome that ignores the music.
    if bpm <= 0 or confidence < 0.12:
        return from_the_tracker() if sure_of_the_beat else analysis.add(out, x, [], 0, low, _FPS)
    # Refined first, so the half, the double and the triplet step are asked about at
    # exactly where they fall; refined again at whichever of them is the one.
    bpm = _refine(env, bpm)
    leveled = _level(x, bpm, env)
    # The tracker's family where the house's is another: see tracker_line.
    if line and not _same_family(leveled, line["bpm"]):
        leveled = _tracker_tempo(env, x, line["bpm"])
        out["tracker"]["took"].append("tempo")
    if abs(leveled - bpm) > 0.01:
        refined = _refine(env, leveled)
        # Refined within the family taken, not out of it: the finer reading is looked
        # for a fifth of a beat either side of the multiples, and on a record the
        # envelope repeats at another count that is far enough to walk away.
        bpm = refined if not line or _same_family(refined, line["bpm"]) else leveled
    beats = _track(env, bpm)
    beats = _on_the_beat(beats, low, 60.0 * _FPS / bpm, bands)
    # Only where there is music. The tracker walks back from the end of the file to the
    # start of it, and would count its way through the silence at either end too.
    at_ms = (beats * _HOP + _ONSET_AT) * 1000.0 / _RATE
    sounding = (at_ms >= lead - 40) & (at_ms <= sound_end)
    beats, at_ms = beats[sounding], at_ms[sounding]
    if len(beats) < 8:
        return from_the_tracker() if sure_of_the_beat else analysis.add(out, x, [], 0, low, _FPS)
    # Whether the beats found are where the onsets are. On a song with a pulse they sit
    # on the peaks of the envelope; laid over something with none, they sit wherever
    # the spacing put them, and the envelope there is no higher than anywhere else.
    on_beat = float(np.mean([env[max(0, b - 1): b + 2].max() for b in beats]))
    between = float(np.mean(env)) + 1e-9
    out["contrast"] = round(on_beat / between, 2)
    if out["contrast"] < _PULSE_CONTRAST:
        return from_the_tracker() if sure_of_the_beat else analysis.add(out, x, [], 0, low, _FPS)
    # One exact grid where the record keeps one tempo, which is what the booth holds two
    # records together by; the beats as tracked where it does not.
    grid = _one_grid(env, low, 60.0 * _FPS / bpm, int(beats[0]), int(beats[-1]) + 1, bands)
    if grid is not None:
        grid = _to_the_ends(grid, lead, sound_end)
        at_ms = (grid * _HOP + _ONSET_AT) * 1000.0 / _RATE
        beats = np.round(grid).astype(np.int64)
        out["grid"] = True
    # The tempo as the beats actually came out — a line through all of them, which is
    # far finer than the spacing of two, counted in frames of 11 ms.
    slope = float(np.polyfit(np.arange(len(at_ms)), at_ms, 1)[0])
    # The beat and not the and: where the tracker counts the same tempo and hears the
    # beat half a beat from where the house put it, the house moves. Evenly spaced and
    # on onsets is as true of the off-beats, and the tracker has heard the music.
    if sure_of_the_beat and abs(60000.0 / slope / line["bpm"] - 1.0) < 0.03:
        phase = ((at_ms - line["at0_ms"]) / line["period_ms"] + 0.5) % 1.0 - 0.5
        if float(np.median(np.abs(phase))) > 0.35:
            half = slope / 2
            shift = half if at_ms[-1] + half <= sound_end or at_ms[0] - half < lead - 40 else -half
            at_ms = at_ms + shift
            keep = (at_ms >= lead - 40) & (at_ms <= sound_end)
            at_ms = at_ms[keep]
            beats = _frames_of(at_ms)
            out["tracker"]["took"].append("beat")
    out["bpm"] = round(60000.0 / slope, 2)
    at_ms = np.maximum(at_ms, 0.0)
    out["beats"] = [int(round(ms)) for ms in at_ms]
    by_change = _bar_starts_on_by_change(x, at_ms)
    out["bar_starts_on"] = by_change if by_change is not None else _bar_starts_on(beats, low)
    return analysis.add(out, x, out["beats"], out["bar_starts_on"], low, _FPS)


def for_track(data_dir: pathlib.Path, audio: pathlib.Path, sha: str,
              wait: float | None = 20.0) -> dict:
    """The song's timing, from disk if it has been worked out before; otherwise worked
    out in its turn (heavy.py), or heavy.Busy where the turn does not come in [wait]."""
    from . import heavy, pool

    cached = cache_path(data_dir, sha)
    try:
        return json.loads(cached.read_text())
    except (OSError, ValueError):
        pass
    with heavy.turn(sha, wait=wait):
        # Worked out while this waited — by whoever asked first.
        try:
            return json.loads(cached.read_text())
        except (OSError, ValueError):
            pass
        # Kept before the turn is let go of: the next to ask for it reads it from disk.
        # With the tracker's reading where the pool has handed one in; when one arrives
        # later, pool.keep_beats throws this answer away so it is read again with it.
        return _keep(cached, measure(audio, neural=pool.beats_here(data_dir, sha)))


def _keep(cached: pathlib.Path, found: dict) -> dict:
    cached.parent.mkdir(parents=True, exist_ok=True)
    tmp = cached.with_suffix(".tmp")
    tmp.write_text(json.dumps(found, separators=(",", ":")))
    tmp.replace(cached)
    return found


def with_sound(data_dir: pathlib.Path, audio: pathlib.Path, sha: str, found: dict) -> dict:
    """[found] with its sound (analysis.sound_of) worked out and kept, for a record
    measured before there was one. The plain analysis, without the structure: what
    is kept is what was measured."""
    from . import analysis as _analysis

    cached = cache_path(data_dir, sha)
    try:
        plain = json.loads(cached.read_text())
    except (OSError, ValueError):
        plain = None
    # Worked out before (a structure built on the plain from before there was one):
    # the plain's, without another listen.
    if plain is not None and "sound" in plain:
        return {**found, "sound": plain["sound"]}
    x = _decode(audio)
    sound = _analysis.sound_for(x, found.get("downbeats") or [], found.get("energy"))
    if plain is not None:
        plain["sound"] = sound
        _keep(cached, plain)
    return {**found, "sound": sound}
