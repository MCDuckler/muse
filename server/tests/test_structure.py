"""A record's structure for the automix: the bar put right by the tracker's word, the
sections read off the stems (a breakdown where the drums stop, a drop where they come
back, a voice where there is one), the places to come in and go out — and all of it
served on the analysis, built again when the parts arrive."""
from __future__ import annotations

import io
import json
import subprocess

import pytest

from muse import db, pool, structure


# ------------------------------------------------------------------ by rule
def test_the_bar_goes_where_the_tracker_heard_it():
    beats = [i * 500 for i in range(64)]
    # The tracker's bars on beat 2 of every four, a few of them a little off.
    downs = [beats[i] + (10 if i % 8 == 2 else 0) for i in range(2, 64, 4)]
    assert structure.bar_phase(beats, downs) == (2, 1.0)
    # Bars all over the place: no word at all.
    assert structure.bar_phase(beats, [beats[i] for i in (0, 1, 2, 3, 4, 5, 6, 7)])[0] is None
    # Too few to believe.
    assert structure.bar_phase(beats, downs[:3])[0] is None
    # Bars that fall on no beat at all count against the agreement: four on a beat and
    # forty between them is no word on the bar.
    off = [beats[i] + 250 for i in range(2, 64, 4)]
    assert structure.bar_phase(beats, downs[:4] + off[4:])[0] is None


def test_a_grid_half_a_beat_off_the_tracker_is_the_trackers_line():
    # The house's grid at 160 a minute, and the tracker's beats at the same count but
    # 180 ms later — on the drums, where the house's intro put its beats between them.
    house = [200 + i * 375 for i in range(640)]
    neural = [380 + i * 375 + (10 if i % 2 else -10) for i in range(600)]
    assert structure._phase_off(house, neural) > 0.4
    assert structure._phase_off(house, [b + 5 for b in house]) < 0.05
    line = structure._neural_line(neural, 0, 240000)
    assert abs(line[0] - 5) < 30 and abs((line[1] - line[0]) - 375) < 0.5
    assert all(abs((b - 5) % 375) < 30 or abs((b - 5) % 375) > 345 for b in line[:50])
    # A tracker that counted the intro in half time, on the wrong phase, and the body
    # right: the line is the body's.
    mixed = [200 + i * 750 for i in range(40)] + [380 + i * 375 for i in range(80, 600)]
    line = structure._neural_line(mixed, 0, 240000)
    assert abs((line[100] - 380) % 375) < 25 or abs((line[100] - 380) % 375) > 350


def test_the_neural_grid_is_fitted_at_each_beats_own_count():
    # Beats a period apart, then a stretch two apart (missed in a break), then one
    # apart again: the line keeps the period.
    beats = [i * 500 for i in range(100)] + [50000 + i * 1000 for i in range(1, 20)] + [70000 + i * 500 for i in range(1, 100)]
    grid = structure._neural_grid(beats, 0, 130000)
    assert abs((grid[1] - grid[0]) - 500) < 1
    assert abs(grid[0]) < 5


def test_sections_from_the_stems():
    # 48 bars: four of intro (no drums), sixteen sung, eight of breakdown, eight of drop
    # with the voice, eight instrumental, four of outro.
    mix = [-20.0] * 4 + [-10.0] * 16 + [-18.0] * 8 + [-9.0] * 8 + [-11.0] * 8 + [-22.0] * 4
    drums = [-90.0] * 4 + [-14.0] * 16 + [-90.0] * 8 + [-13.0] * 16 + [-90.0] * 4
    vocals = [-90.0] * 4 + [-16.0] * 16 + [-90.0] * 8 + [-15.0] * 8 + [-90.0] * 12
    got = structure.label_bars(mix, drums, vocals)
    assert [(s["label"], s["start_bar"], s["end_bar"]) for s in got] == [
        ("intro", 0, 4), ("chorus", 4, 20), ("breakdown", 20, 28), ("drop", 28, 36),
        ("inst", 36, 44), ("outro", 44, 48)]


def test_a_breakdown_that_climbs_ends_in_a_build():
    mix = [-10.0] * 16 + [-20.0, -20.0, -20.0, -20.0, -18.0, -16.0, -14.0, -12.0] + [-9.0] * 16
    drums = [-12.0] * 16 + [-90.0] * 8 + [-12.0] * 16
    got = structure.label_bars(mix, drums, None)
    labels = [(s["label"], s["start_bar"], s["end_bar"]) for s in got]
    assert ("breakdown", 16, 20) in labels and ("build", 20, 24) in labels
    assert ("drop", 24, 40) in labels


def test_a_bar_alone_joins_its_neighbour():
    mix = [-10.0] * 32
    drums = [-12.0] * 12 + [-90.0] + [-12.0] * 19
    got = structure.label_bars(mix, drums, None)
    assert len(got) == 1 and got[0]["label"] == "inst"


def test_sections_of_one_name_side_by_side_are_one():
    # An intro without drums, first sung then not: one intro.
    mix = [-20.0] * 8 + [-10.0] * 24
    drums = [-90.0] * 8 + [-12.0] * 24
    vocals = [-22.0] * 4 + [-90.0] * 28
    got = structure.label_bars(mix, drums, vocals)
    assert [(s["label"], s["start_bar"], s["end_bar"]) for s in got][:2] == [("intro", 0, 8), ("inst", 8, 32)]
    assert got[0]["vocals"] is True


def test_without_stems_only_the_mix_speaks():
    mix = [-30.0] * 4 + [-10.0] * 24 + [-30.0] * 4
    got = structure.label_bars(mix, None, None)
    assert [s["label"] for s in got] == ["intro", "inst", "outro"]


# ------------------------------------------------------------------ the whole of it
def _synth(tmp_path, name: str, exprs: list[str], seconds: int, six: bool = False):
    """A file from an expression a channel (two a stem for a six-channel stems file)."""
    out = tmp_path / name
    if six:
        inputs = []
        for e in exprs:
            inputs += ["-f", "lavfi", "-i", f"aevalsrc='{e}|{e}':s=44100:d={seconds}"]
        subprocess.run(["ffmpeg", "-v", "error", "-y", *inputs,
                        "-filter_complex", "[0][1][2]amerge=inputs=3[a]", "-map", "[a]",
                        "-c:a", "libopus", "-mapping_family", "255", "-b:a", "288k", str(out)],
                       check=True)
    else:
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i",
                        f"aevalsrc='{exprs[0]}|{exprs[0]}':s=44100:d={seconds}",
                        "-c:a", "aac", "-b:a", "160k", "-metadata", "title=Structured", str(out)],
                       check=True)
    return out


# 120 a minute: a bar every two seconds. Drums on from bar 4 to 24 and 32 to 44; the
# voice over bars 8-23 and 32-39; the bass all the way to bar 48.
_DRUMS = "if(lt(mod(t,0.5),0.03)*(between(t,8,47.99)+between(t,64,87.99)),0.8*sin(2*PI*55*t),0)"
_VOICE = "0.3*sin(2*PI*440*t)*(between(t,16,47.99)+between(t,64,79.99))"
_REST = "0.15*sin(2*PI*110*t)*lt(t,96)"
_MIX = f"({_DRUMS})+({_VOICE})+({_REST})"


@pytest.fixture()
def a_structured_record(client, hdr, tmp_path):
    f = _synth(tmp_path, "record.m4a", [_MIX], 100)
    track = client.post("/uploads", headers=hdr,
                        files={"audio": ("record.m4a", io.BytesIO(f.read_bytes()),
                                         "audio/mp4")}).json()
    stems = _synth(tmp_path, "stems.opus", [_DRUMS, _REST, _VOICE], 100, six=True)
    return track, stems


def test_the_structure_is_served_and_built_again_as_parts_arrive(
        client, hdr, a_structured_record, tmp_path, cfg):
    track, stems = a_structured_record
    sha = db.one("select sha256 from media where track_id=%s", (track["id"],))["sha256"]
    # Nothing handed in yet: the plain analysis, with what the mix alone says.
    r = client.get(f"/tracks/{track['id']}/analysis?structure=1", headers=hdr)
    assert r.status_code == 200, r.text
    first = r.json()
    assert first["structure"]["sources"] == {"beats": first["structure"]["sources"]["beats"],
                                             "bar_phase": "house", "stems": False, "neural": False}
    assert first["structure"]["drums_db"] is None
    assert first["beats"], "the click train has a pulse"

    # The tracker's beats, with the bar on beat two of four, and the stems.
    beats = [i * 500 for i in range(200)]
    downs = [beats[i] for i in range(1, 200, 4)]
    raw = json.dumps({"beats_ms": beats, "downbeats_ms": downs, "model": "test", "device": "cpu"})
    pool.keep_beats(cfg.data_dir, sha, raw.encode())
    pool.keep_part(cfg.data_dir, sha, "stems", stems, None, 1.0)
    r = client.get(f"/tracks/{track['id']}/analysis?structure=1", headers=hdr)
    assert r.status_code == 200, r.text
    got = r.json()
    s = got["structure"]
    assert s["sources"]["stems"] and s["sources"]["neural"]
    assert s["sources"]["bar_phase"] == "neural"
    # The house's bars now fall where the tracker put them.
    near = [min(abs(d - x) for x in downs) for d in got["downbeats"]]
    assert sum(1 for n in near if n <= 60) >= 0.8 * len(near), near[:8]
    labels = [x["label"] for x in s["sections"]]
    assert labels[0] == "intro" and labels[-1] == "outro", labels
    assert "breakdown" in labels and "drop" in labels, labels
    drop = next(x for x in s["sections"] if x["label"] == "drop")
    assert abs(drop["start_ms"] - 64000) <= 2500, drop
    assert s["drops_ms"] and abs(s["drops_ms"][0] - 64000) <= 2500
    assert any(x["vocals"] for x in s["sections"]), "the voice is heard"
    assert s["cues"]["outs"] and s["cues"]["ins"]
    assert len(s["drums_db"]) == len(s["bars_ms"]) == len(got["downbeats"])
    # The voice is measured on the same bars.
    v = client.get(f"/tracks/{track['id']}/vocals", headers=hdr).json()
    assert len(v["bars"]) == len(got["downbeats"])


def test_beats_handed_in_with_the_parts_are_checked(client, hdr, a_structured_record, cfg):
    track, stems = a_structured_record
    sha = db.one("select sha256 from media where track_id=%s", (track["id"],))["sha256"]
    with pytest.raises(ValueError):
        pool.keep_beats(cfg.data_dir, sha, b'{"beats_ms": [5, 4, 3], "downbeats_ms": []}')
    with pytest.raises(ValueError):
        pool.keep_beats(cfg.data_dir, sha, b"not json")
    good = json.dumps({"beats_ms": list(range(0, 5000, 500)), "downbeats_ms": [0, 2000, 4000]})
    pool.keep_beats(cfg.data_dir, sha, good.encode())
    assert pool.beats_here(cfg.data_dir, sha)["downbeats_ms"] == [0, 2000, 4000]
