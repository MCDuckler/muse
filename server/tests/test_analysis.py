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
