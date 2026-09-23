"""Taking a record apart — checked against sound that was put together on purpose.

Every case here is built so the right answer is arithmetic rather than opinion: a
tone placed dead centre has to leave when the middle is taken out, one placed in the
sides has to stay, and a record split into hits and notes has to add back up to the
record it came from.
"""
from __future__ import annotations

import io
import time
import wave

import numpy as np
import pytest

from muse import stems

RATE = stems.RATE


def _tone(hz: float, seconds: float, amp: float = 0.3) -> np.ndarray:
    t = np.arange(int(RATE * seconds)) / RATE
    return (amp * np.sin(2 * np.pi * hz * t)).astype(np.float32)


def _at(x: np.ndarray, hz: float) -> float:
    """How much of [x] is at [hz], as an amplitude."""
    spectrum = np.abs(np.fft.rfft(x * np.hanning(len(x))))
    bin_ = int(round(hz * len(x) / RATE))
    return float(spectrum[max(0, bin_ - 1):bin_ + 2].max()) * 4 / len(x)


def _above(x: np.ndarray, hz: float) -> float:
    """The energy in [x] above [hz]."""
    spectrum = np.abs(np.fft.rfft(x))
    freqs = np.fft.rfftfreq(len(x), 1.0 / RATE)
    return float(np.sum(spectrum[freqs > hz] ** 2))


# ------------------------------------------------------------------ the middle of it
def _record() -> np.ndarray:
    """Four seconds with a voice-ish tone dead centre, a bass note centre, and a
    counter-melody entirely in the sides."""
    voice, bass, wide = _tone(1000, 4.0), _tone(60, 4.0), _tone(3000, 4.0)
    return np.stack([voice + bass + wide, voice + bass - wide], axis=1)


def test_what_is_in_the_middle_goes():
    out = stems.without_voice(_record())
    mid = (out[:, 0] + out[:, 1]) / 2
    assert _at(mid, 1000) < 0.02 * _at(_record()[:, 0], 1000), \
        "a tone dead centre in a voice's band is gone"


def test_the_sides_are_kept_whole():
    before = _record()
    out = stems.without_voice(before)
    side_before = (before[:, 0] - before[:, 1]) / 2
    side_after = (out[:, 0] - out[:, 1]) / 2
    assert _at(side_after, 3000) == pytest.approx(_at(side_before, 3000), rel=0.05), \
        "what was only ever in the sides is untouched"


def test_the_bottom_end_stays():
    """The kick and the bass are in the middle too. A record with those taken out is
    not an instrumental, so the band stops short of them."""
    before = _record()
    out = stems.without_voice(before)
    mid_before = (before[:, 0] + before[:, 1]) / 2
    mid_after = (out[:, 0] + out[:, 1]) / 2
    assert _at(mid_after, 60) > 0.9 * _at(mid_before, 60)


def test_a_mono_record_is_honest_about_itself():
    """No middle to subtract, so what is left is what the arithmetic says: the bottom
    and the top, and no claim to have found a voice."""
    one = _tone(1000, 4.0) + _tone(60, 4.0)
    out = stems.without_voice(np.stack([one, one], axis=1))
    assert _at(out[:, 0], 1000) < 0.02 * _at(one, 1000)
    assert _at(out[:, 0], 60) > 0.9 * _at(one, 60)


# ------------------------------------------------------------------ hits and notes
def _band() -> np.ndarray:
    """A held note with a hit on top of it every quarter of a second."""
    x = _tone(440, 4.0, amp=0.3)
    rng = np.random.default_rng(5)
    tick = int(RATE * 0.02)
    hit = (rng.standard_normal(tick) * np.exp(-np.arange(tick) / (RATE * 0.004))).astype(np.float32)
    for k in range(16):
        at = int(k * 0.25 * RATE)
        x[at:at + tick] += hit * 0.8
    return x


def test_the_note_lands_in_the_music_and_the_hits_in_the_drums():
    drums, music = stems.hits_and_notes(_band())
    inside = slice(RATE // 2, -RATE // 2)     # away from the ends, where there is no overlap
    assert _at(music[inside], 440) > 5 * _at(drums[inside], 440), "the held note is a note"
    assert _above(drums[inside], 6000) > 5 * _above(music[inside], 6000), "the hits are hits"


def test_the_two_halves_add_back_up_to_the_record():
    x = _band()
    drums, music = stems.hits_and_notes(x)
    inside = slice(RATE // 2, -RATE // 2)
    back = (drums + music)[inside]
    error = float(np.sqrt(np.mean((back - x[inside]) ** 2)))
    assert error < 0.02 * float(np.sqrt(np.mean(x[inside] ** 2))), \
        "nothing is lost between the two, and nothing is invented"


def test_a_snippet_shorter_than_one_window_is_silence_not_a_crash():
    tiny = _tone(440, 0.01)
    drums, music = stems.hits_and_notes(tiny)
    assert len(drums) == len(tiny) and not drums.any()
    assert len(music) == len(tiny) and not music.any()
    assert stems.without_voice(np.stack([tiny, tiny], axis=1)).shape == (len(tiny), 2)


def test_a_long_record_is_not_held_in_memory_all_at_once():
    """Longer than one block of frames, so the seams between blocks are exercised: a
    boundary must not be audible, which here means the halves still add up across it."""
    seconds = stems._BLOCK * stems._HOP / RATE * 2.5
    x = _tone(440, seconds) + _tone(90, seconds, amp=0.2)
    drums, music = stems.hits_and_notes(x)
    inside = slice(RATE // 2, -RATE // 2)
    error = float(np.sqrt(np.mean(((drums + music) - x)[inside] ** 2)))
    assert error < 0.02 * float(np.sqrt(np.mean(x[inside] ** 2)))


# ------------------------------------------------------------------ keeping them
def _wav(path, x: np.ndarray) -> None:
    out = io.BytesIO()
    with wave.open(out, "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes((np.clip(x, -1, 1) * 32767).astype("<i2").tobytes())
    path.write_bytes(out.getvalue())


def test_it_is_made_in_the_background_and_kept(tmp_path):
    song = tmp_path / "song.wav"
    _wav(song, _record()[:RATE * 2])
    data = tmp_path / "data"

    with pytest.raises(stems.NotReady):
        stems.for_track(data, song, "abc", "instrumental")
    # Asking again while it is being made does not start a second one.
    with pytest.raises(stems.NotReady):
        stems.for_track(data, song, "abc", "instrumental")

    where = stems.cache_path(data, "abc", "instrumental")
    for _ in range(300):
        if where.exists():
            break
        time.sleep(0.1)
    assert where.exists() and where.stat().st_size > 0
    assert not stems.underway("abc", "instrumental")
    assert list(data.glob("stems/*.tmp.m4a")) == [], "no half-written file left behind"
    # And now it is simply there.
    assert stems.for_track(data, song, "abc", "instrumental") == where


def test_asking_for_the_drums_gets_the_music_too(tmp_path):
    """Splitting a record gives both halves. Keeping only the half that was asked for
    would mean doing the whole thing again for the other one."""
    song = tmp_path / "band.wav"
    _wav(song, np.stack([_band(), _band()], axis=1))
    data = tmp_path / "data"

    with pytest.raises(stems.NotReady):
        stems.for_track(data, song, "def", "drums")
    for _ in range(600):
        if not stems.underway("def", "drums"):
            break
        time.sleep(0.1)
    assert stems.cache_path(data, "def", "drums").exists()
    assert stems.for_track(data, song, "def", "music").exists(), \
        "the other half was kept, so nobody waits for it twice"


def test_there_is_no_such_part(tmp_path):
    with pytest.raises(ValueError):
        stems.make(tmp_path / "nothing.wav", "vocals")


# ------------------------------------------------------------------ over the wire
@pytest.fixture()
def a_record(client, hdr, tmp_path):
    import io
    import subprocess
    f = tmp_path / "t.m4a"
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "lavfi",
                    "-i", "sine=frequency=440:duration=3", "-c:a", "aac",
                    "-metadata", "title=Some Record", str(f)], check=True)
    with f.open("rb") as fh:
        return client.post("/uploads", headers=hdr,
                           files={"audio": ("t.m4a", io.BytesIO(fh.read()), "audio/mp4")}).json()


def test_a_part_is_asked_for_and_then_served(client, hdr, a_record):
    """The first ask starts the work and is told to come back; the one after it is
    the sound itself."""
    first = client.get(f"/tracks/{a_record['id']}/stem/instrumental", headers=hdr)
    assert first.status_code == 202
    assert first.headers.get("Retry-After")

    for _ in range(600):
        r = client.get(f"/tracks/{a_record['id']}/stem/instrumental", headers=hdr)
        if r.status_code != 202:
            break
        time.sleep(0.1)
    assert r.status_code == 200, r.text
    assert r.headers["content-type"].startswith("audio/")
    assert len(r.content) > 0


def test_a_record_has_no_vocals_part(client, hdr, a_record):
    r = client.get(f"/tracks/{a_record['id']}/stem/vocals", headers=hdr)
    assert r.status_code == 404
    assert "vocals" in r.text


def test_a_part_needs_a_token_or_a_key(client, a_record):
    assert client.get(f"/tracks/{a_record['id']}/stem/drums").status_code == 401


def test_a_set_is_not_a_record(client, hdr, a_record):
    """Past the cap the answer is no, not a part that runs out before the record
    does — which on a deck in front of a room is silence."""
    from muse import db
    db.run("update tracks set duration_ms=%s where id=%s",
           (stems.UP_TO_S * 1000 + 1, a_record["id"]))
    r = client.get(f"/tracks/{a_record['id']}/stem/drums", headers=hdr)
    assert r.status_code == 404
    assert "too long" in r.text
