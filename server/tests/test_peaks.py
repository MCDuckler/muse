"""The shape drawn under a record, and where each slice of it sits in time.

The drawing lays the slices end to end across the whole record. So the slices have to
*be* end to end across the whole record: a shape that stops short of the end is a shape
stretched to fit, and everything in it slides later and later through the song — which
puts the picture off the beat grid drawn on the same strip, worse the further in you
are. That is the one property worth a test here; how loud a slice comes out is a matter
of taste, but where it is is not.
"""
import array

from muse import peaks


def _sliced(n_samples: int, slices: int, loud_from: float) -> list[int]:
    """A silent record that turns loud at [loud_from] through it, cut into [slices]."""
    at = int(n_samples * loud_from)
    s = array.array("h", [0] * at + [12000] * (n_samples - at))
    return peaks._levels(s, slices)


def _first_loud(levels: list[int]) -> int:
    return next(i for i, v in enumerate(levels) if v > 0)


def test_the_slices_reach_the_end_of_the_record():
    # 30000 slices of a four-minute record at 11 kHz: the deck's strip, at its finest.
    # The old slicing used len // slices samples a slice, which is that division rounded
    # down, and 2_449_259 // 30_000 is 81 where the slice is 81.6 long — so the slices
    # together covered 99.3% of the file and the last 1.7 seconds were never drawn.
    n, slices = 2_449_259, 30_000
    levels = _sliced(n, slices, 0.999)
    assert levels[-1] > 0, "the last slice has to be the end of the record"


def test_a_change_is_where_it_happened_and_not_later():
    # A tenth of a beat, at 130 bpm, is 46 ms — a fiftieth of a four-minute record's
    # last slice. Half a beat out is a picture that argues with its own grid.
    n, slices = 2_449_259, 30_000
    for where in (0.1, 0.5, 0.75, 0.95):
        levels = _sliced(n, slices, where)
        assert abs(_first_loud(levels) - round(where * slices)) <= 1, (
            f"the change at {where:.0%} landed at slice {_first_loud(levels)}, "
            f"not {round(where * slices)}"
        )


def test_every_slice_is_asked_about():
    # No slice left empty by the arithmetic, however the length divides: an empty slice
    # in the middle of a record is a gap in the shape.
    for n in (999, 1000, 1001, 4096, 11_025):
        levels = peaks._levels(array.array("h", [9000] * n), 160)
        assert len(levels) == 160
        assert min(levels) > 0, f"a slice came out empty for {n} samples"


def test_the_three_bands_are_measured_against_each_other():
    # What a coloured waveform draws is the *ratio* between the bands, and the ratio is
    # the first thing lost by scaling each band to its own loudest: a record with a
    # whisper of air and a wall of bass came back with both at full, and printed white.
    quiet, loud = [10.0] * 50 + [20.0] * 50, [100.0] * 50 + [200.0] * 50
    top = max(max(quiet), max(loud))
    a, b = peaks._to_255(quiet, top), peaks._to_255(loud, top)
    assert max(a) < max(b) / 2, "the quieter band has to come back quieter"
    # And each on its own, which is what it used to do, says they are the same:
    assert max(peaks._to_255(quiet)) == max(peaks._to_255(loud)) == 255


def test_the_lift_is_the_measured_one():
    # Not a knob to be turned by eye. See the comment on _LIFT: the numbers come from
    # the 99th percentile of each band over fourteen records of the house.
    assert peaks._LIFT["low"] == 1.0
    assert 1.1 < peaks._LIFT["mid"] < 1.5
    assert 4.0 < peaks._LIFT["high"] < 6.0


def test_the_cache_path_says_which_shape_it_is():
    # Otherwise a shape measured the old way is served for ever against a new grid.
    import pathlib

    p = peaks.cache_path(pathlib.Path("/data"), "abc", 1600, bands=True)
    assert f"-v{peaks.VERSION}" in p.name
    assert p.name.endswith("-bands.json")
