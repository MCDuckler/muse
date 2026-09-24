"""What a song is made of, beyond its beats — checked against sound whose answer is known.

A chord in a key has to come back as that key. A song that is quiet for its first
phrases and loud after has to say where the intro ends; one that goes quiet again at
the end has to say where the outro starts. And sound with no pulse gets no bars, no
phrases and no cues, rather than invented ones.
"""
from __future__ import annotations

import io
import wave

import numpy as np
import pytest

from muse import analysis, beats

RATE = 22050


def _wav(x: np.ndarray) -> bytes:
    out = io.BytesIO()
    with wave.open(out, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes((np.clip(x, -1, 1) * 32767).astype("<i2").tobytes())
    return out.getvalue()


def _note(hz: float, seconds: float, amp: float = 0.2) -> np.ndarray:
    t = np.arange(int(RATE * seconds)) / RATE
    # A few harmonics, the way a plucked string has them.
    return amp * sum(np.sin(2 * np.pi * hz * k * t) / k for k in (1, 2, 3))


def _midi(n: int) -> float:
    return 440.0 * 2 ** ((n - 69) / 12)


@pytest.mark.parametrize("tonic,mode,camelot", [
    (60, "major", "8B"),     # C major
    (57, "minor", "8A"),     # A minor
    (67, "major", "9B"),     # G major
    (62, "minor", "7A"),     # D minor
])
def test_a_chord_progression_comes_back_in_its_key(tmp_path, tonic, mode, camelot):
    steps = [0, 2, 4, 5, 7, 9, 11] if mode == "major" else [0, 2, 3, 5, 7, 8, 10]
    # I, IV, V, I: the tonic's chord most, which is what a key is.
    chords = [[0, 2, 4], [3, 5, 0], [4, 6, 1], [0, 2, 4]]
    x = np.zeros(0)
    for _ in range(4):
        for chord in chords:
            notes = sum(_note(_midi(tonic + steps[d % 7] + 12 * (d // 7)), 1.0) for d in chord)
            x = np.concatenate([x, notes])
    f = tmp_path / "chords.wav"
    f.write_bytes(_wav(x))
    found = beats.measure(f)
    assert found["key"] == f"{analysis.NAMES[tonic % 12]} {mode}"
    assert found["camelot"] == camelot
    assert found["key_confidence"] > 0


def test_noise_has_no_key():
    rng = np.random.default_rng(1)
    flat = analysis.key_of(rng.random(12) * 0.01 + 100)
    assert flat["key"] is None


def _song(bpm: float, bars: int, loud_from_bar: int, quiet_from_bar: int | None) -> np.ndarray:
    """A drum pattern that is quiet for its first bars, loud after, and quiet again."""
    rng = np.random.default_rng(7)
    beat = 60.0 / bpm
    n = int(RATE * beat * 4 * bars) + RATE
    x = np.zeros(n)
    t = np.arange(int(RATE * 0.25)) / RATE
    kick = np.sin(2 * np.pi * (55 + 60 * np.exp(-t * 30)) * t) * np.exp(-t * 14)
    snare = rng.standard_normal(int(RATE * 0.1)) * np.exp(-np.arange(int(RATE * 0.1)) / (RATE * 0.03)) * 0.5
    for k in range(bars * 4):
        bar = k // 4
        gain = 0.25 if bar < loud_from_bar or (quiet_from_bar is not None and bar >= quiet_from_bar) else 1.0
        at = int(k * beat * RATE)
        x[at:at + len(kick)] += kick[: n - at] * gain
        if k % 2:
            x[at:at + len(snare)] += snare[: n - at] * gain
    return x * 0.6


def test_the_intro_and_the_outro_are_found(tmp_path):
    x = _song(128, bars=48, loud_from_bar=8, quiet_from_bar=40)
    f = tmp_path / "song.wav"
    f.write_bytes(_wav(x))
    found = beats.measure(f)
    assert found["bpm"] == pytest.approx(128, abs=0.5)
    assert len(found["downbeats"]) >= 40
    assert 0 in [0] and found["phrases"][0] == found["downbeats"][0]
    bar = 60.0 / 128 * 4 * 1000
    # The intro ends at bar 8 and the outro starts at bar 40, to within a bar.
    assert found["cues"]["mix_in_ms"] == pytest.approx(8 * bar, abs=bar * 1.5)
    assert found["cues"]["mix_out_ms"] == pytest.approx(40 * bar, abs=bar * 1.5)
    levels = found["energy"]
    assert max(levels[:6]) < 200 and min(levels[10:36]) > 150, \
        "each bar's loudness follows the song"


def test_sound_with_no_pulse_has_no_bars(tmp_path):
    rng = np.random.default_rng(3)
    t = np.arange(RATE * 25) / RATE
    wash = rng.standard_normal(len(t)) * 0.2 * (0.5 + 0.5 * np.sin(2 * np.pi * t / 11.3))
    f = tmp_path / "wash.wav"
    f.write_bytes(_wav(wash))
    found = beats.measure(f)
    assert found["beats"] == []
    assert "downbeats" not in found and "cues" not in found
    assert found["key"] is None, "noise is in no key"


def test_a_drop_is_found_where_the_song_opens_up(tmp_path):
    # Quiet for eight bars, everything at once from bar 8, quiet again at 40: the
    # drop is bar 8 and there is only one of it.
    x = _song(128, bars=48, loud_from_bar=8, quiet_from_bar=40)
    f = tmp_path / "drop.wav"
    f.write_bytes(_wav(x))
    found = beats.measure(f)
    bar = 60.0 / 128 * 4 * 1000
    assert found["drops"], "a song that opens up has a drop"
    assert found["drops"][0] == pytest.approx(8 * bar, abs=bar * 1.5)
    assert len(found["drops"]) == 1, "one drop, not one per bar of it"


def test_a_song_that_never_opens_up_has_no_drop():
    # Flat from end to end: nothing to point at, and none invented.
    assert analysis.drops([200] * 40, [0, 16, 32]) == []
    assert analysis.drops([], []) == []


def test_a_slow_swell_is_not_a_drop():
    # Ten bars of creeping upwards is a build, not a drop.
    rising = [int(255 * (0.4 + 0.5 * i / 32)) for i in range(32)]
    assert analysis.drops(rising, [0, 16]) == []


def test_the_beats_run_from_the_first_sound(tmp_path):
    # The tracker finds its first beat a few beats in; a record on one grid was on it
    # from the start, and its first bar is its first bar.
    x = _song(128, bars=24, loud_from_bar=0, quiet_from_bar=None)
    f = tmp_path / "song.wav"
    f.write_bytes(_wav(x))
    found = beats.measure(f)
    beat = 60000 / 128
    assert found["beats"][0] < beat / 2, "the first beat is the first kick"
    assert found["downbeats"][0] < beat / 2


def test_the_four_bar_markers_follow_the_record_not_its_first_bar(tmp_path):
    # Quiet for ten bars — a two-bar pickup and an eight-bar intro — loud from bar 10,
    # quiet again from 42: its sections start two bars into a grid counted from the
    # top, and so do the markers.
    x = _song(128, bars=52, loud_from_bar=10, quiet_from_bar=42)
    f = tmp_path / "song.wav"
    f.write_bytes(_wav(x))
    found = beats.measure(f)
    bar = 60.0 / 128 * 4 * 1000
    marks = found["four_bars"]
    assert any(abs(m - 10 * bar) < 60 for m in marks), marks
    assert any(abs(m - 42 * bar) < 60 for m in marks), marks
    assert all(abs(((m / bar) - 2) / 4 - round(((m / bar) - 2) / 4)) < 0.05 for m in marks), \
        "every four bars from bar 2"


def test_the_grid_moves_where_the_sections_do():
    # Sections every eight bars from the top, then one of six (from bar 16 to 22), and
    # every eight bars from there: the markers move with them at bar 22.
    strength = np.zeros(48)
    for b in (8, 16, 22, 30, 38):
        strength[b] = 3.0
    marks = analysis.four_bars(strength)
    assert [m for m in marks if m < 22] == [0, 4, 8, 12, 16, 20]
    assert [m for m in marks if m >= 22] == [22, 26, 30, 34, 38, 42, 46]


def test_one_fill_a_bar_early_does_not_move_the_grid():
    strength = np.zeros(48)
    for b in (8, 16, 24, 40):
        strength[b] = 3.0
    strength[31] = 3.4          # a fill, the loudest change of all, a bar early
    marks = analysis.four_bars(strength)
    assert marks == list(range(0, 48, 4))


def test_a_grid_that_starts_late_is_found_from_the_start():
    # A record whose sections all start on bar 3, 11, 19 …: the markers run from bar 3.
    strength = np.zeros(40)
    for b in (3, 11, 19, 27, 35):
        strength[b] = 2.5
    assert analysis.four_bars(strength)[:3] == [3, 7, 11]
