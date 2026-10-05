"""What a song is made of in time.

Checked against sound whose answer is known: a drum pattern at a tempo chosen here, with
a stretch of nothing at either end. The tempo has to come back right, the beats have to
be where the drums are, the nothing has to be found — and sound with no pulse at all has
to be reported as having none, rather than being given a metronome.
"""
from __future__ import annotations

import io
import wave

import numpy as np
import pytest

from muse import beats, db

RATE = 22050


def drums(bpm: float, seconds: float, lead: float, tail: float) -> tuple[bytes, list[float]]:
    rng = np.random.default_rng(7)
    n = int(RATE * seconds)
    x = np.zeros(n)
    t = np.arange(int(RATE * 0.25)) / RATE
    kick = np.sin(2 * np.pi * (55 + 60 * np.exp(-t * 30)) * t) * np.exp(-t * 14)
    snare = rng.standard_normal(int(RATE * 0.1)) * np.exp(-np.arange(int(RATE * 0.1)) / (RATE * 0.03)) * 0.5
    hat = rng.standard_normal(int(RATE * 0.03)) * np.exp(-np.arange(int(RATE * 0.03)) / (RATE * 0.006)) * 0.25
    hits, k, beat = [], 0, 60.0 / bpm
    while k * beat < seconds - 0.4:
        at = int(k * beat * RATE)
        x[at:at + len(kick)] += kick[: n - at]
        if k % 2:
            x[at:at + len(snare)] += snare[: n - at]
        off = int((k + 0.5) * beat * RATE)
        if off + len(hat) < n:
            x[off:off + len(hat)] += hat
        hits.append(lead + k * beat)
        k += 1
    whole = np.concatenate([np.zeros(int(RATE * lead)), x * 0.6, np.zeros(int(RATE * tail))])
    out = io.BytesIO()
    with wave.open(out, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes((np.clip(whole, -1, 1) * 32767).astype("<i2").tobytes())
    return out.getvalue(), hits


@pytest.mark.parametrize("bpm", [84, 100, 128])
def test_the_tempo_and_the_beats_of_a_song_with_a_pulse(tmp_path, bpm):
    audio, hits = drums(bpm, 30, lead=1.2, tail=2.0)
    f = tmp_path / "drums.wav"
    f.write_bytes(audio)
    found = beats.measure(f)

    assert found["bpm"] == pytest.approx(bpm, abs=0.5), \
        "not half of it and not double: the tempo somebody would tap"
    at = np.array(found["beats"]) / 1000.0
    misses = [float(np.min(np.abs(at - h))) for h in hits[2:-2]]
    assert max(misses) < 0.035, "every drum has a beat on it, to within a frame or two"
    assert abs(len(at) - len(hits)) <= 2, "and no beats counted through the silence"

    assert found["lead_ms"] == pytest.approx(1200, abs=120)
    assert found["tail_ms"] == pytest.approx(2000, abs=700), \
        "less the time the last drum takes to die away"


def test_a_fast_song_is_given_the_tempo_it_is_tapped_at(tmp_path):
    """Drum and bass is written at 172 and nodded to at 86; either is an honest answer,
    but it has to be one of them and the beats have to land on drums."""
    audio, hits = drums(172, 30, lead=0.0, tail=0.0)
    f = tmp_path / "fast.wav"
    f.write_bytes(audio)
    found = beats.measure(f)
    assert found["bpm"] in (pytest.approx(86, abs=0.5), pytest.approx(172, abs=1))
    at = np.array(found["beats"]) / 1000.0
    nearest = [float(np.min(np.abs(np.array(hits) - b))) for b in at[2:-2]]
    assert max(nearest) < 0.035
    assert found["lead_ms"] == 0 and found["tail_ms"] == 0, \
        "a file with no dead air is left exactly as it is"


def test_sound_with_no_pulse_is_not_given_one(tmp_path):
    rng = np.random.default_rng(3)
    t = np.arange(RATE * 25) / RATE
    wash = rng.standard_normal(len(t)) * 0.2 * (0.5 + 0.5 * np.sin(2 * np.pi * t / 11.3))
    out = io.BytesIO()
    with wave.open(out, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes((np.clip(wash, -1, 1) * 32767).astype("<i2").tobytes())
    f = tmp_path / "wash.wav"
    f.write_bytes(out.getvalue())
    found = beats.measure(f)
    assert found["bpm"] is None and found["beats"] == []


def test_it_is_asked_for_once_and_kept(client, hdr, monkeypatch):
    audio, _ = drums(120, 20, lead=1.0, tail=1.5)
    track = client.post("/uploads", headers=hdr,
                        files={"audio": ("drums.wav", io.BytesIO(audio), "audio/wav")}).json()

    r = client.get(f"/tracks/{track['id']}/analysis", headers=hdr)
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["bpm"] == pytest.approx(120, abs=0.5)
    assert body["lead_ms"] > 500 and body["tail_ms"] > 500
    assert "immutable" in r.headers["cache-control"]
    # On the row too, where a list could one day be ordered by it.
    assert db.one("select bpm from tracks where id=%s", (track["id"],))["bpm"] == \
        pytest.approx(120, abs=0.5)
    listed = client.get(f"/tracks/{track['id']}", headers=hdr).json()
    assert listed["bpm"] == pytest.approx(120, abs=0.5)

    def never(*a, **kw):
        raise AssertionError("worked out twice")

    monkeypatch.setattr(beats, "measure", never)
    assert client.get(f"/tracks/{track['id']}/analysis", headers=hdr).json() == body


def test_a_song_with_no_audio_has_no_beats_yet(client, hdr):
    t = client.post("/tracks/resolve", headers=hdr, json={"video_id": "NOAUDIO0001"}).json()
    assert client.get(f"/tracks/{t['id']}/analysis", headers=hdr).status_code == 404


def test_the_library_is_listened_to_a_song_at_a_time(client, hdr, tmp_path, monkeypatch):
    """So that "sort by tempo" is the library and not the last week's listening. A song
    with no pulse is marked as listened to as well, or it would be the only one tried."""
    from muse import beats_worker, deps

    audio, _ = drums(128, 15, lead=0.5, tail=0.5)
    fast = client.post("/uploads", headers=hdr,
                       files={"audio": ("a.wav", io.BytesIO(audio), "audio/wav")}).json()
    audio, _ = drums(84, 15, lead=0.5, tail=0.5)
    slow = client.post("/uploads", headers=hdr,
                       files={"audio": ("b.wav", io.BytesIO(audio), "audio/wav")}).json()

    from muse import catalog
    me = db.one("select id from users where name='chris'")["id"]
    for t in (fast, slow):
        catalog.remember(me, t["id"])

    data_dir = deps.cfg().data_dir
    assert beats_worker.one(data_dir) is True           # newest first
    assert db.one("select bpm from tracks where id=%s", (slow["id"],))["bpm"] == \
        pytest.approx(84, abs=0.5)
    assert db.one("select analysed_at from tracks where id=%s", (fast["id"],))["analysed_at"] is None
    assert beats_worker.one(data_dir) is True
    assert beats_worker.one(data_dir) is False, "and then there is nothing left to do"

    # Slowest first, and what has no tempo after everything that has.
    nothing = client.post("/tracks/resolve", headers=hdr, json={"video_id": "NOTEMPO0001"}).json()
    listed = client.get("/library/tracks", headers=hdr, params={"sort": "tempo"}).json()["items"]
    ids = [t["id"] for t in listed]
    assert ids.index(slow["id"]) < ids.index(fast["id"]) < ids.index(nothing["id"])

    lists = {l["id"]: l["count"] for l in client.get("/library/smart", headers=hdr).json()["lists"]}
    assert lists["slow"] == 1 and lists["quick"] == 1
    got = client.get("/library/smart/quick", headers=hdr).json()["items"]
    assert [t["id"] for t in got] == [fast["id"]]


def test_a_file_that_cannot_be_read_is_not_tried_for_ever(client, hdr, monkeypatch):
    from muse import beats_worker, deps

    audio, _ = drums(100, 12, lead=0.0, tail=0.0)
    t = client.post("/uploads", headers=hdr,
                    files={"audio": ("c.wav", io.BytesIO(audio), "audio/wav")}).json()

    def broken(*a, **kw):
        raise OSError("unreadable")

    monkeypatch.setattr(beats, "for_track", broken)
    assert beats_worker.one(deps.cfg().data_dir) is True
    row = db.one("select bpm, analysed_at from tracks where id=%s", (t["id"],))
    assert row["bpm"] is None and row["analysed_at"] is not None
    assert beats_worker.one(deps.cfg().data_dir) is False


@pytest.mark.parametrize("bpm", [155.0, 151.0, 145.3])
def test_a_long_record_keeps_its_tempo_to_the_hundredth_and_never_slips(tmp_path, bpm):
    """A record made on a computer is one tempo from end to end, and the tempo is rarely
    a whole number of 11 ms frames. Read to a frame, 155 came back as 155.4 — and a beat
    tracker told 155.4 walks a millisecond a beat off the music and slips back by a
    fraction of a beat whenever it notices, which is a mix falling apart every minute.
    """
    audio, hits = drums(bpm, 180, lead=0.5, tail=1.0)
    f = tmp_path / "long.wav"
    f.write_bytes(audio)
    found = beats.measure(f)
    assert found["bpm"] == pytest.approx(bpm, abs=0.02)
    assert found.get("grid"), "one exact grid, since the record keeps one tempo"
    at = np.array(found["beats"]) / 1000.0
    off = np.array([float(at[np.argmin(np.abs(at - h))] - h) for h in hits[2:-2]])
    # Where the analysis puts a beat against where a drum starts is the same for every
    # record — the short test above holds it to a few frames — so what is checked
    # here is that it stays the same from the first minute to the last.
    assert abs(float(np.median(off))) < 0.012
    spread = np.abs(off - np.median(off))
    assert np.percentile(spread, 95) < 0.004, "on the drums, from the first minute to the last"
    assert spread.max() < 0.006, "and never a slip"


def test_a_fast_record_is_given_the_tempo_a_dj_counts(tmp_path):
    """A hardtekk record at 163 with its kick on every beat is 163, not the 81.5 a
    listener might tap: synced as 81.5 against a record at 150 it was treated as a slow
    one. The kick is on every beat, so the kick decides."""
    rng = np.random.default_rng(3)
    bpm, seconds = 163.0, 60
    x = np.zeros(int(RATE * seconds))
    t = np.arange(int(RATE * 0.2)) / RATE
    kick = np.sin(2 * np.pi * (50 + 80 * np.exp(-t * 35)) * t) * np.exp(-t * 18)
    hat = rng.standard_normal(int(RATE * 0.02)) * np.exp(-np.arange(int(RATE * 0.02)) / (RATE * 0.004)) * 0.2
    beat = 60.0 / bpm
    k = 0
    while k * beat < seconds - 0.3:
        at = int(k * beat * RATE)
        x[at:at + len(kick)] += kick[: len(x) - at]
        off = int((k + 0.5) * beat * RATE)
        if off + len(hat) < len(x):
            x[off:off + len(hat)] += hat
        k += 1
    out = io.BytesIO()
    with wave.open(out, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes((np.clip(x * 0.6, -1, 1) * 32767).astype("<i2").tobytes())
    f = tmp_path / "tekk.wav"
    f.write_bytes(out.getvalue())
    assert beats.measure(f)["bpm"] == pytest.approx(bpm, abs=0.05)


def test_a_break_is_counted_at_the_tempo_it_is_mixed_at(tmp_path):
    """Liquid drum & bass at 174 came back at 87, and twelve of one artist's records in
    the library were sitting there.

    A break has its kick on the one and its snare on the three exactly as a rap record
    at 87 does, so it repeats best at 87 and the kick says nothing against that. The
    two were told apart by how busy the record is: at the tempo a DJ counts, a record
    does one or two things a beat, and three or more means the beat being counted is
    two beats. Measured on four of each from the library, the classes do not overlap.
    """
    rng = np.random.default_rng(11)
    bpm, seconds = 174.0, 60
    n = int(RATE * seconds)
    x = np.zeros(n)
    t = np.arange(int(RATE * 0.22)) / RATE
    kick = np.sin(2 * np.pi * (48 + 70 * np.exp(-t * 32)) * t) * np.exp(-t * 16)
    sn = rng.standard_normal(int(RATE * 0.12)) * np.exp(-np.arange(int(RATE * 0.12)) / (RATE * 0.035)) * 0.55
    hat = rng.standard_normal(int(RATE * 0.025)) * np.exp(-np.arange(int(RATE * 0.025)) / (RATE * 0.005)) * 0.22
    beat = 60.0 / bpm
    k = 0
    while k * beat < seconds - 0.4:
        at = int(k * beat * RATE)
        # The kick on one and three of the bar, the snare on two and four — the shape
        # that reads as 87 to everything that only looks for a pulse.
        if k % 4 in (0, 2):
            x[at:at + len(kick)] += kick[: n - at]
        if k % 4 in (1, 3):
            x[at:at + len(sn)] += sn[: n - at]
        for e in (0.0, 0.5):
            o = int((k + e) * beat * RATE)
            if o + len(hat) < n:
                x[o:o + len(hat)] += hat
        k += 1
    out = io.BytesIO()
    with wave.open(out, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes((np.clip(x * 0.6, -1, 1) * 32767).astype("<i2").tobytes())
    f = tmp_path / "break.wav"
    f.write_bytes(out.getvalue())
    assert beats.measure(f)["bpm"] == pytest.approx(bpm, abs=0.6)


def test_a_slow_record_is_not_hurried_by_being_sparse(tmp_path):
    """The other half of the same rule, and the one that keeps it honest: a rap record
    at 88 has its kick on the one and its snare on the three too, and must stay at 88.
    What it does not have is the break's traffic between the beats."""
    rng = np.random.default_rng(12)
    bpm, seconds = 88.0, 60
    n = int(RATE * seconds)
    x = np.zeros(n)
    t = np.arange(int(RATE * 0.3)) / RATE
    kick = np.sin(2 * np.pi * (46 + 60 * np.exp(-t * 26)) * t) * np.exp(-t * 11)
    sn = rng.standard_normal(int(RATE * 0.14)) * np.exp(-np.arange(int(RATE * 0.14)) / (RATE * 0.04)) * 0.5
    beat = 60.0 / bpm
    k = 0
    while k * beat < seconds - 0.5:
        at = int(k * beat * RATE)
        if k % 4 in (0, 2):
            x[at:at + len(kick)] += kick[: n - at]
        if k % 4 in (1, 3):
            x[at:at + len(sn)] += sn[: n - at]
        k += 1
    out = io.BytesIO()
    with wave.open(out, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes((np.clip(x * 0.6, -1, 1) * 32767).astype("<i2").tobytes())
    f = tmp_path / "slow.wav"
    f.write_bytes(out.getvalue())
    assert beats.measure(f)["bpm"] == pytest.approx(bpm, abs=0.6)


def test_the_bar_starts_where_the_record_changes(tmp_path):
    """Four-on-the-floor: every beat has the same kick, so the bass cannot say which is
    the one. The record can: its sections change there. Here a chord changes every
    four bars, on beat 2 of the kicks — so beat 2 is the one."""
    bpm, seconds = 128.0, 90
    x = np.zeros(int(RATE * seconds))
    beat = 60.0 / bpm
    t = np.arange(int(RATE * 0.2)) / RATE
    kick = np.sin(2 * np.pi * (55 + 60 * np.exp(-t * 30)) * t) * np.exp(-t * 14)
    n = int((seconds - 0.4) / beat)
    for k in range(n):
        at = int(k * beat * RATE)
        x[at:at + len(kick)] += kick[: len(x) - at]
    chords = [220.0, 293.7, 246.9, 329.6]
    for start in range(2, n, 16):             # every four bars, from beat 2
        a, b = int(start * beat * RATE), int(min(n, start + 16) * beat * RATE)
        tt = np.arange(b - a) / RATE
        f0 = chords[(start // 16) % len(chords)]
        x[a:b] += 0.15 * (np.sin(2 * np.pi * f0 * tt) + np.sin(2 * np.pi * f0 * 1.5 * tt))
    out = io.BytesIO()
    with wave.open(out, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes((np.clip(x * 0.6, -1, 1) * 32767).astype("<i2").tobytes())
    f = tmp_path / "bars.wav"
    f.write_bytes(out.getvalue())
    found = beats.measure(f)
    first_beat = found["beats"][found["bar_starts_on"]]
    # The bar's one is on a beat whose number, counted from the first kick, is 2 mod 4.
    number = round(first_beat / (beat * 1000))
    assert number % 4 == 2


def test_a_bassline_on_the_and_does_not_pull_the_grid_onto_the_and(tmp_path):
    """Kick on every beat, clap on two and four, and a bass stab on every "and": the
    bass alone says the and is the beat, and the grid used to sit there. The clap says
    otherwise, and the clap is right."""
    bpm, seconds = 128.0, 60
    x = np.zeros(int(RATE * seconds))
    beat = 60.0 / bpm
    t = np.arange(int(RATE * 0.12)) / RATE
    kick = 0.5 * np.sin(2 * np.pi * (50 + 70 * np.exp(-t * 40)) * t) * np.exp(-t * 20)
    tc = np.arange(int(RATE * 0.06)) / RATE
    rng = np.random.default_rng(3)
    clap = 0.6 * rng.standard_normal(len(tc)) * np.exp(-tc * 60)
    tb = np.arange(int(RATE * 0.22)) / RATE
    stab = 0.9 * np.sin(2 * np.pi * 55 * tb) * np.exp(-tb * 6) * (1 - np.exp(-tb * 200))
    n = int((seconds - 0.5) / beat)
    for k in range(n):
        at = int(k * beat * RATE)
        x[at:at + len(kick)] += kick
        if k % 2 == 1:
            x[at:at + len(clap)] += clap
        off = int((k + 0.5) * beat * RATE)
        x[off:off + len(stab)] += stab[: len(x) - off]
    out = io.BytesIO()
    with wave.open(out, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes((np.clip(x * 0.5, -1, 1) * 32767).astype("<i2").tobytes())
    f = tmp_path / "offbeat-bass.wav"
    f.write_bytes(out.getvalue())
    found = beats.measure(f)
    assert abs(found["bpm"] - bpm) < 1.0
    # Every beat found is on a kick (a whole number of beats from the start), not on
    # a stab halfway between.
    frac = [((b / 1000.0) / beat) % 1.0 for b in found["beats"][4:-4]]
    frac = [min(f, 1 - f) for f in frac]
    assert np.median(frac) < 0.15, f"beats sit {np.median(frac):.2f} of a beat from the kicks"


# ------------------------------------------------------------------ the tracker's word
def test_the_trackers_reading_is_one_line_despite_a_doubled_beat_or_two():
    steady = [int(500 * k) for k in range(200)]
    assert beats.tracker_line(steady)["bpm"] == pytest.approx(120, abs=0.01)
    # A beat doubled here, one missed there — the way the tracker's peaks come out.
    rough = sorted(set(steady[:50] + [steady[k] + 250 for k in range(50, 60)]
                       + steady[60:120] + steady[122:]))
    line = beats.tracker_line(rough)
    assert line is not None and line["bpm"] == pytest.approx(120, abs=0.05)
    assert line["phase_share"] > 0.9
    # The tracker changed its mind about the beat for a stretch: the tempo is still
    # its tempo, the beat is the one most of its beats are on, and it says how many.
    flipped = steady[:120] + [b + 250 for b in steady[120:160]] + steady[160:]
    line = beats.tracker_line(flipped)
    assert line["bpm"] == pytest.approx(120, abs=0.05) and 0.75 < line["phase_share"] < 0.85
    assert abs(line["at0_ms"]) < 20, "on the phase of the many, not the few"
    rng = np.random.default_rng(1)
    noise = sorted(int(x) for x in np.cumsum(rng.uniform(200, 900, 200)))
    assert beats.tracker_line(noise) is None, "no line through a reading that is noise"
    assert beats.tracker_line(steady[:20]) is None, "too few to say"


def test_the_trackers_family_overrules_a_house_lock_on_a_third(tmp_path):
    """The house read a record at four thirds of its pulse (178.66 for 134) and the
    tracker, which has heard the music, said 134: the house counts the tracker's family
    and keeps only the octave to itself."""
    audio, _ = drums(100, 30, lead=0.0, tail=0.0)
    f = tmp_path / "drums.wav"
    f.write_bytes(audio)
    x = beats._decode(f)
    env = beats._onsets(x)[0]
    assert not beats._same_family(100.0, 150.0) and beats._same_family(100.0, 200.0)
    assert beats._same_family(178.66, 89.4) and not beats._same_family(178.66, 134.0)
    counted = beats._tracker_tempo(env, x, 150.0)
    assert counted in (pytest.approx(150, abs=0.01), pytest.approx(75, abs=0.01)), \
        "the tracker's family, at whichever octave the house counts"
    # (These drums have no pulse at 150 at all, so what the beats then do is not the
    # question; that the house let go of its own count is.)
    other = {"beats_ms": [int(400 * k) for k in range(75)]}            # the tracker: 150
    found = beats.measure(f, other)
    assert found["tracker"]["steady"] and "tempo" in found["tracker"]["took"]
    assert found["bpm"] != pytest.approx(100, abs=2)
    same = {"beats_ms": [int(300 * k) for k in range(100)]}            # the tracker: 200
    found = beats.measure(f, same)
    assert found["bpm"] == pytest.approx(100, abs=0.5) and found["tracker"]["took"] == [], \
        "an octave of the house's own count is the house's to decide"
    rng = np.random.default_rng(2)
    noise = {"beats_ms": sorted(int(x) for x in np.cumsum(rng.uniform(200, 900, 100)))}
    found = beats.measure(f, noise)
    assert found["bpm"] == pytest.approx(100, abs=0.5) and not found["tracker"]["steady"], \
        "a reading that is noise is written down as that and not believed"


def test_the_trackers_beat_moves_a_grid_sitting_on_the_and(tmp_path):
    audio, hits = drums(120, 30, lead=0.0, tail=0.0)
    f = tmp_path / "drums.wav"
    f.write_bytes(audio)
    plain = beats.measure(f)
    on_drums = [float(np.min(np.abs(np.array(hits) - b / 1000.0))) for b in plain["beats"][2:-2]]
    assert max(on_drums) < 0.035
    # The tracker hears the beat on the hats, half a beat from the drums.
    other = {"beats_ms": [int(250 + 500 * k) for k in range(58)]}
    found = beats.measure(f, other)
    assert "beat" in found["tracker"]["took"]
    off_drums = [float(np.min(np.abs(np.array(hits) - b / 1000.0))) for b in found["beats"][2:-2]]
    assert min(off_drums) > 0.2, "every beat now sits half a beat from a drum"
    assert found["bpm"] == pytest.approx(120, abs=0.5)


def test_the_bar_is_decided_three_ways(monkeypatch):
    """The change rule's where the tracker agrees or is silent; the phrase rule decides
    where they disagree; the house's stands where it too is silent."""
    x = np.zeros(beats._RATE * 12, dtype=np.float32)
    at = np.arange(64) * 500.0
    low = np.zeros(2000, dtype=np.float32)
    said = {}
    monkeypatch.setattr(beats, "_beat_spectra", lambda x_, b: np.zeros((64, 32)))
    monkeypatch.setattr(beats, "_bar_starts_on_by_change", lambda x_, b, spec=None: said["change"])
    monkeypatch.setattr(beats, "_tracker_bar", lambda b, d, tolerance_ms=45: said["tracker"])
    monkeypatch.setattr(beats, "_bar_starts_on_by_phrase", lambda spec: said["phrase"])
    tracker = {"downbeats_ms": [0, 2000, 4000, 6000]}

    said.update(change=1, tracker=(1, 0.9), phrase=(3, 0.7))
    assert beats.bar_one(x, at, low, tracker)[:2] == (1, "change"), "agreed: the house's"
    said.update(change=1, tracker=(None, 0.3), phrase=(3, 0.7))
    assert beats.bar_one(x, at, low, tracker)[:2] == (1, "change"), "tracker silent: the house's"
    said.update(change=1, tracker=(3, 0.9), phrase=(3, 0.7))
    bar, by, notes = beats.bar_one(x, at, low, tracker)
    assert (bar, by) == (3, "tracker") and notes["bar_phase_tracker_said"] == 3, "the phrases side with the tracker"
    said.update(change=1, tracker=(3, 0.9), phrase=(1, 0.7))
    assert beats.bar_one(x, at, low, tracker)[:2] == (1, "change"), "the phrases side with the house"
    said.update(change=1, tracker=(3, 0.9), phrase=(2, 0.7))
    assert beats.bar_one(x, at, low, tracker)[:2] == (2, "phrase"), "the phrases say a third thing"
    said.update(change=1, tracker=(3, 0.9), phrase=(None, 0.4))
    assert beats.bar_one(x, at, low, tracker)[:2] == (1, "change"), "phrases silent: the house's stands"
    said.update(change=None, tracker=(3, 0.9), phrase=(2, 0.7))
    assert beats.bar_one(x, at, low, tracker)[:2] == (2, "phrase"), "no house reading: the phrases"
    said.update(change=None, tracker=(3, 0.9), phrase=(None, 0.4))
    assert beats.bar_one(x, at, low, tracker)[:2] == (3, "tracker"), "then the tracker"
    said.update(change=None, tracker=(None, 0.0), phrase=(None, 0.4))
    assert beats.bar_one(x, at, low, None)[1] == "bass", "then the bass"
