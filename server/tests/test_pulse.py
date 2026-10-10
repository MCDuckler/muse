"""The pulse: where a kick lands in it, which band a hat lands in, and that the bytes
come back out the way they went in. How loud each comes out is a matter of scale; where
and in which channel is not."""
import numpy as np

from muse import pulse


def _record(seconds: float = 4.0) -> np.ndarray:
    """A kick (a 55 Hz burst) every half second and a hat (a burst of noise) a quarter
    of a second after each, at the pulse's own rate."""
    rate = pulse._RATE
    t = np.arange(int(seconds * rate)) / rate
    x = np.zeros_like(t, dtype=np.float32)
    rng = np.random.default_rng(1)
    for beat in np.arange(0.0, seconds, 0.5):
        at = (t >= beat) & (t < beat + 0.12)
        x[at] += (np.sin(2 * np.pi * 55 * t[at]) * np.exp(-(t[at] - beat) * 30)).astype(np.float32)
        hat = (t >= beat + 0.25) & (t < beat + 0.28)
        x[hat] += (rng.standard_normal(int(hat.sum())) * 0.3).astype(np.float32)
    return x


def test_a_frame_is_twenty_milliseconds():
    found = pulse.features(_record(4.0))
    assert set(found) == set(pulse.CHANNELS)
    assert all(len(v) == 200 for v in found.values())


def test_the_kick_lands_on_the_beat():
    kick = pulse.features(_record(4.0))["kick"]
    # The loudest frame of each half second is the one the kick starts in, give or
    # take a frame for the window's lean.
    for beat in range(8):
        frames = kick[beat * 25:(beat + 1) * 25]
        assert int(np.argmax(frames)) <= 1, f"beat {beat}: kick at frame {np.argmax(frames)}"


def test_the_hat_is_air_and_the_kick_is_sub():
    found = pulse.features(_record(2.0))
    sub, air = found["sub"], found["air"]
    # At the kick (frame 0 of each half second) the sub is up and the air is not; at the
    # hat (frame 12 or 13) the other way round.
    assert sub[0] > 5 * air[0]
    assert air[13] > 5 * sub[13]


def test_the_bytes_come_back_as_they_went():
    found = {name: pulse.to_bytes(v) for name, v in pulse.features(_record(1.0)).items()}
    packed = pulse.pack(found)
    assert packed["hz"] == pulse.HZ and packed["n"] == 50
    assert packed["channels"] == list(pulse.CHANNELS)
    back = pulse.unpack(packed)
    for name in pulse.CHANNELS:
        assert np.array_equal(back[name], found[name]), name


def test_the_top_is_the_record_s_own_loud_and_not_one_click():
    v = np.ones(1000, np.float32)
    v[500] = 100.0  # one click
    b = pulse.to_bytes(v)
    assert b[0] == 255, "the record's usual level is its full scale"
    assert b[500] == 255
