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
