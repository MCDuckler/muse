"""Sets built by the house from a pool (setbuild.py): the shape followed, the rules
kept, and the routes that ask for it."""
import math
import random

import numpy as np

from muse import db, setbuild, traits


def _row(i: int, *, bpm: float, cam: str, lufs: float, artist: str, title: str | None = None,
         sound: list[float] | None = None, conf: float = 0.9, parts: bool = False,
         minutes: float = 4.0) -> dict:
    return {
        "id": i, "title": title or f"Record {i}", "artists": [artist], "album": None,
        "duration_ms": int(minutes * 60_000), "state": "ready", "fail_reason": None,
        "source": "youtube", "gain_db": 0.0, "loudness_lufs": lufs, "path": f"/x/{i}.m4a",
        "t_bpm": bpm, "camelot": cam, "key_confidence": conf, "lufs": lufs,
        "sound": sound, "sung": 0.2, "in_db": -2.0, "out_db": -2.0, "in_parts": parts,
    }


def _library(n: int = 240, seed: int = 7) -> setbuild.Pool:
    """A library of [n] records: tempos 118 to 142, every key, loudness -16 to -6,
    forty artists, sounds from a handful of families."""
    rng = random.Random(seed)
    families = [[rng.gauss(0, 1) for _ in range(12)] for _ in range(6)]
    rows = []
    for i in range(1, n + 1):
        fam = families[i % len(families)]
        rows.append(_row(
            i, bpm=round(rng.uniform(118, 142), 2),
            cam=f"{rng.randint(1, 12)}{rng.choice('AB')}",
            lufs=round(rng.uniform(-16, -6), 1),
            artist=f"Artist {rng.randint(1, 40)}",
            sound=[x + rng.gauss(0, 0.35) for x in fam],
            parts=rng.random() < 0.3,
            minutes=rng.uniform(3, 6)))
    return setbuild.assemble(rows, {}, set())


def _ids(slots):
    return [s["track"]["id"] for s in slots]


def test_the_tempo_path_is_followed():
    p = _library()
    shape = setbuild.Shape.of({"tempo": {"from": 122, "to": 138}, "energy": [[0, 0.5], [1, 0.5]]})
    slots = setbuild.build(p, shape, tracks=12)
    assert len(slots) == 12
    bpms = [s["bpm"] for s in slots]
    assert abs(bpms[0] - 122) < 3 and abs(bpms[-1] - 138) < 3
    assert np.corrcoef(range(len(bpms)), bpms)[0, 1] > 0.85, bpms


def test_the_energy_curve_is_followed():
    p = _library()
    shape = setbuild.Shape.of({"energy": [[0, 0.3], [0.75, 0.85], [1, 0.6]]})
    slots = setbuild.build(p, shape, tracks=14)
    err = [abs(s["energy"] - s["target"]) for s in slots]
    assert sum(err) / len(err) < 0.12, err
    peak = max(range(len(slots)), key=lambda i: slots[i]["energy"])
    assert peak >= len(slots) // 3, "the loud records come late, where the curve peaks"


def test_strict_keys_never_clash_and_the_artist_gap_holds():
    p = _library()
    shape = setbuild.Shape.of({"key": "strict", "variety": {"gap": 4}})
    slots = setbuild.build(p, shape, tracks=16)
    ids = _ids(slots)
    for a, b in zip(ids, ids[1:]):
        assert "keys clash" not in setbuild.words(p, p.at[a], p.at[b])
    artists = [s["track"]["artists"][0] for s in slots]
    for i, name in enumerate(artists):
        assert name not in artists[max(0, i - 4):i], (i, artists)


def test_one_song_is_played_once_whatever_its_copies():
    rows = [
        _row(1, bpm=128, cam="8A", lufs=-9, artist="A", title="Sandstorm", sound=[1, 0, 0]),
        _row(2, bpm=128, cam="8A", lufs=-9, artist="B", title="Sandstorm (Radio Edit)", sound=[1, 0, 0.01]),
        _row(3, bpm=128.2, cam="8A", lufs=-9, artist="C", title="Another Name", sound=[0.2, 1, 0]),
        _row(4, bpm=128.1, cam="8A", lufs=-9, artist="D", title="Upload Of It", sound=[0.2, 1, 0.001]),
        _row(5, bpm=127, cam="9A", lufs=-9, artist="E", sound=[0, 0, 1]),
        _row(6, bpm=129, cam="7A", lufs=-9, artist="F", sound=[0.5, 0.5, 0.5]),
    ]
    p = setbuild.assemble(rows, {}, set())
    assert p.same[p.at[1]] == p.same[p.at[2]], "the same title in another edit"
    assert p.same[p.at[3]] == p.same[p.at[4]], "two uploads that sound identical at one tempo"
    ids = _ids(setbuild.build(p, setbuild.Shape(), tracks=6))
    assert not ({1, 2} <= set(ids)) and not ({3, 4} <= set(ids))
    assert len(ids) == 4, "four songs, not six rows"


def test_pins_stay_put_and_must_plays_are_in():
    p = _library()
    shape = setbuild.Shape.of({"energy": [[0, 0.2], [1, 0.9]]})
    loud = max(p.at, key=lambda i: p.energy[p.at[i]])
    soft = min(p.at, key=lambda i: p.energy[p.at[i]])
    pinned = 17
    slots = setbuild.build(p, shape, tracks=10, pins={3: p.at[pinned]},
                           must=[p.at[loud], p.at[soft]])
    ids = _ids(slots)
    assert ids[3] == pinned and slots[3]["pinned"]
    assert loud in ids and soft in ids
    assert ids.index(soft) < ids.index(loud), "each must-play where the curve wants it"


def test_a_set_of_minutes_lasts_about_that_long():
    p = _library()
    slots = setbuild.build(p, setbuild.Shape(), minutes=60)
    played = sum(float(p.played_s[p.at[i]]) for i in _ids(slots))
    longest = float(max(p.played_s))
    assert 3600 <= played <= 3600 + longest


def test_it_follows_the_record_on_now_and_never_plays_it_again():
    p = _library()
    on = 5
    slots = setbuild.build(p, setbuild.Shape(), start=p.at[on], before=[p.at[6]], tracks=8)
    ids = _ids(slots)
    assert on not in ids and 6 not in ids
    assert slots[0]["fit"] is not None and slots[0]["why"]
    # And follows it well: better than the pool's typical pair from it.
    typical = float(np.median(setbuild._pair_from(p, p.at[on], setbuild.Shape())))
    assert slots[0]["fit"] > typical


def test_alternatives_sit_between_both_neighbours():
    p = _library()
    shape = setbuild.Shape()
    slots = setbuild.build(p, shape, tracks=6)
    ids = _ids(slots)
    got = setbuild.alternatives(p, shape, prev=p.at[ids[1]], nxt=p.at[ids[3]], k=0.5,
                                exclude={p.at[i] for i in ids}, limit=5)
    assert 1 <= len(got) <= 5
    assert not {g["track"]["id"] for g in got} & set(ids)
    artists = [g["track"]["artists"][0] for g in got]
    assert len(artists) == len(set(artists)), "an artist once"
    both = [g["fit_in"] + g["fit_out"] for g in got]
    median = float(np.median(setbuild._pair_from(p, p.at[ids[1]], shape))) * 2
    assert min(both) > median


def test_fresh_leans_to_the_hardly_played():
    rows = [_row(i, bpm=128, cam="8A", lufs=-9, artist=f"A{i}",
                 sound=[math.cos(i), math.sin(i), 0.3]) for i in range(1, 21)]
    heard = {i: (50, 200.0) for i in range(1, 11)}      # 1–10 played a lot, long ago
    p = setbuild.assemble(rows, heard, set())
    fresh = _ids(setbuild.build(p, setbuild.Shape.of({"fresh": 1.0}), tracks=5))
    familiar = _ids(setbuild.build(p, setbuild.Shape.of({"fresh": 0.0}), tracks=5))
    assert sum(i > 10 for i in fresh) >= 4
    assert sum(i <= 10 for i in familiar) >= 4


def test_the_shape_reads_what_the_app_sends():
    s = setbuild.Shape.of({"energy": [[1, 2], [0, -1], "x"], "tempo": {"from": 120, "to": 130},
                           "key": "strict", "variety": {"gap": 99, "smooth": 0.2, "fresh": 3},
                           "stems": True, "offset": 0.1})
    assert s.energy == [(0.0, 0.0), (1.0, 1.0)]
    assert s.tempo == (120, 130) and s.key == "strict" and s.gap == 12
    assert s.smooth == 0.2 and s.fresh == 1.0 and s.stems
    assert math.isclose(s.energy_at(0.5), 0.6)
    assert math.isclose(s.tempo_at(1), 130)


# ------------------------------------------------------------------ the routes
def test_a_set_from_the_library_and_from_a_playlist(client, hdr):
    ids = [client.post("/tracks/resolve", headers=hdr, json={"video_id": f"SB{i:02d}"}).json()["id"]
           for i in range(8)]
    for i, t in enumerate(ids):
        db.run("update tracks set state='ready', title=%s, artists=%s where id=%s",
               (f"Record {i}", [f"Artist {i}"], t))
        traits.remember({"id": t, "loudness_lufs": -14 + i},
                        {"bpm": 124 + i, "camelot": f"{(i % 12) + 1}A", "key_confidence": 0.9,
                         "sound": [1, i / 10, 0], "energy": [200] * 16,
                         "downbeats": [k * 1875 for k in range(16)],
                         "cues": {"mix_in_ms": 4 * 1875, "mix_out_ms": 12 * 1875}})
    setbuild.forget()
    r = client.post("/booth/set", headers=hdr, json={
        "source": {"library": True}, "length": {"tracks": 4},
        "start": {"track_id": ids[0]}, "shape": {"energy": [[0, 0.4], [1, 0.9]]}})
    assert r.status_code == 200, r.text
    body = r.json()
    got = [s["track"]["id"] for s in body["slots"]]
    assert len(got) == 4 and ids[0] not in got
    assert body["slots"][0]["fit"] is not None
    assert body["stats"]["measured"] >= 8

    # From a playlist of four of them only.
    pl = client.post("/playlists", headers=hdr, json={"name": "Warm-up"}).json()
    client.post(f"/playlists/{pl['id']}/items", headers=hdr, json={"track_ids": ids[2:6]})
    r = client.post("/booth/set", headers=hdr, json={
        "source": {"playlists": [pl["id"]]}, "length": {"tracks": 10}})
    assert r.status_code == 200, r.text
    assert set(s["track"]["id"] for s in r.json()["slots"]) == set(ids[2:6])

    r = client.post("/booth/slot", headers=hdr, json={
        "source": {"library": True}, "prev": ids[1], "next": ids[3], "k": 0.5,
        "exclude": [ids[1], ids[3]], "limit": 3})
    assert r.status_code == 200, r.text
    choices = [c["track"]["id"] for c in r.json()["choices"]]
    assert choices and ids[1] not in choices and ids[3] not in choices

    r = client.post("/booth/pool", headers=hdr, json={"source": {"playlists": [pl["id"]]}})
    assert r.status_code == 200, r.text
    assert r.json()["measured"] == 4 and r.json()["unfetched_ids"] == []

    assert client.post("/booth/set", headers=hdr, json={"source": {}}).status_code == 400
