"""Every record measured by the box: a record handed in by a computer keeps that computer's
numbers only until the box has measured the file itself (at once); one fetched unmeasured is
measured ahead of the rest; the library is worked through; true peak with it."""
from __future__ import annotations

import pathlib
import subprocess

from muse import catalog, db, loudness

from test_api import _ready_track


def _tone(path: pathlib.Path, volume_db: float, seconds: int = 4) -> pathlib.Path:
    subprocess.run(
        ["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i", f"sine=frequency=440:duration={seconds}",
         "-af", f"volume={volume_db}dB", "-c:a", "aac", "-b:a", "128k", str(path)],
        check=True)
    return path


def _silence(path: pathlib.Path) -> pathlib.Path:
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i", "anullsrc=r=44100:cl=stereo", "-t", "3", "-c:a", "aac", str(path)], check=True)
    return path


def test_a_record_is_measured_with_its_true_peak(tmp_path):
    quiet = loudness.measure(_tone(tmp_path / "quiet.m4a", 0.0))
    loud = loudness.measure(_tone(tmp_path / "loud.m4a", 12.0))
    assert quiet and loud
    assert abs((loud["lufs"] - quiet["lufs"]) - 12.0) < 0.5, (quiet, loud)
    for m in (quiet, loud):
        assert m["gain_db"] == round(loudness.TARGET_LUFS - m["lufs"], 2)
        assert m["true_peak_db"] is not None and m["lufs"] < m["true_peak_db"] < 1.0
    assert loudness.measure(_silence(tmp_path / "silence.m4a")) is None, "nothing to measure"
    assert loudness.measure(tmp_path / "not-there.m4a") is None


def test_a_handed_in_record_is_measured_by_the_box_and_a_fetched_one_at_once(client, hdr, wsec, complete_job, tmp_path):
    loudness._soon.clear()
    tid = _ready_track(client, hdr, wsec, complete_job)
    t = catalog.track_row(tid)
    # the computer's numbers stand for now; the box is to measure it at once
    assert (t["loudness_lufs"], t["gain_db"], t["loudness_version"]) == (-10.6, -3.4, None)
    assert list(loudness._soon) == [tid]
    # (the test's handed-in bytes are not a sound: a real one in their place)
    pathlib.Path(t["path"]).write_bytes(_tone(tmp_path / "real.m4a", 6.0).read_bytes())
    assert loudness.one()
    t = catalog.track_row(tid)
    assert t["loudness_version"] == loudness.VERSION and t["loudness_at"] is not None
    assert t["loudness_lufs"] != -10.6 and t["true_peak_db"] is not None
    assert t["gain_db"] == round(loudness.TARGET_LUFS - t["loudness_lufs"], 2)
    assert catalog.public(t)["true_peak_db"] == t["true_peak_db"], "the clients are told"
    assert not loudness.one(), "nothing left to measure"
    # fetched once measured: nothing asked
    assert client.get(f"/tracks/{tid}/stream", headers=hdr).status_code == 200
    assert not loudness._soon
    # fetched while the box has not measured it (a library from before, a newer measure):
    # measured ahead of the rest
    db.run("update tracks set loudness_version = null where id = %s", (tid,))
    client.get(f"/tracks/{tid}/stream", headers=hdr)
    assert list(loudness._soon) == [tid]
    loudness._soon.clear()
    # and the library worked through without asking
    assert loudness.one()
    assert catalog.track_row(tid)["loudness_version"] == loudness.VERSION


def test_a_record_that_cannot_be_measured_keeps_its_numbers_and_is_not_tried_again(client, hdr, wsec, complete_job):
    loudness._soon.clear()
    tid = _ready_track(client, hdr, wsec, complete_job)
    assert loudness.one()                         # the handed-in bytes are no sound
    t = catalog.track_row(tid)
    assert (t["loudness_lufs"], t["gain_db"]) == (-10.6, -3.4), "the computer's numbers left"
    assert t["loudness_version"] == loudness.VERSION
    assert not loudness.one()
