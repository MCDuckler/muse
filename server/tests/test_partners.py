"""A partner for a record from the whole library: the coarse judging the server does
over what it knows of every record, before the app judges the few it gets finely."""
from __future__ import annotations

import numpy as np

from muse import analysis, db, traits


def test_the_sound_of_a_record_is_level_free_and_leaves_quiet_bars_out():
    loud = np.tile(np.array([1.0, 2.0, 3.0, 2.0]), (8, 1))
    quiet = np.tile(np.array([0.1, 0.1, 0.1, 0.1]), (4, 1))
    spectra = np.vstack([quiet, loud])
    energy = np.array([-40.0] * 4 + [-6.0] * 8)
    s = analysis.sound_of(spectra, energy)
    assert s is not None and len(s) == 4
    assert abs(sum(s)) < 1e-6, "the level is taken off"
    twice = analysis.sound_of(spectra + 1.5, energy)  # log rows: louder is a constant on top
    assert np.allclose(s, twice, atol=1e-3), "twice as loud sounds the same"
    assert analysis.sound_of(np.zeros((0, 4))) is None


def test_the_judging_reads_tempo_key_sound_and_who_made_it():
    a = {"bpm": 128, "camelot": "8A", "key_confidence": 0.8, "lufs": -10,
         "sound": [1, 0, -1, 0], "artists": ["Ann"], "title": "One"}
    close = {**a, "artists": ["Bob"], "title": "Two"}
    far = {**close, "bpm": 100, "camelot": "2B", "sound": [-1, 0, 1, 0]}
    again = {**close, "artists": ["ann"]}
    s_close, w_close = traits.judge(a, close)
    s_far, w_far = traits.judge(a, far)
    s_again, w_again = traits.judge(a, again)
    assert s_close > s_far + 0.5
    assert "too far apart in tempo" in w_far and "keys clash" in w_far
    assert "sounds alike" in w_close
    assert s_again < s_close - 0.2 and "the same artist" in w_again
    assert traits._title_key("Veridis Quo by Daft Punk") == traits._title_key("Veridis Quo")
    assert traits._title_key("Olsvangèr - Harpie G") == traits._title_key("Harpie G (Original Mix)")
    assert abs(traits.sound_alike(0.85) - 0.5) < 1e-9 and traits.sound_alike(0.99) == 1.0 and traits.sound_alike(0.5) == 0.0
    assert traits.sync_ratio(128, 64) == 1.0, "half time is the same tempo"
    assert traits.sync_ratio(128, 160) is None


def test_partners_come_from_the_library_best_first(client, hdr):
    ids = [client.post("/tracks/resolve", headers=hdr, json={"video_id": v}).json()["id"]
           for v in ("PAA", "PBB", "PCC", "PDD")]
    for i, t in enumerate(ids):
        db.run("update tracks set state='ready', title=%s, artists=%s where id=%s",
               (f"Record {i}", [f"Artist {i}"], t))
    on, good, clash, same = ids
    rows = {
        on: {"bpm": 128, "camelot": "8A", "key_confidence": 0.9, "lufs": -10, "sound": [1, 0, -1]},
        good: {"bpm": 126, "camelot": "9A", "key_confidence": 0.9, "lufs": -11, "sound": [1, 0, -1]},
        clash: {"bpm": 128, "camelot": "2B", "key_confidence": 0.9, "lufs": -10, "sound": [-1, 0, 1]},
        same: {"bpm": 128, "camelot": "8A", "key_confidence": 0.9, "lufs": -10, "sound": [1, 0, -1]},
    }
    for t, r in rows.items():
        traits.remember({"id": t, "loudness_lufs": r["lufs"]},
                        {**r, "energy": [200] * 16, "downbeats": [i * 1875 for i in range(16)],
                         "cues": {"mix_in_ms": 4 * 1875, "mix_out_ms": 12 * 1875}})
    db.run("update tracks set artists=%s where id=%s", (["Artist 0"], same))
    got = client.get("/booth/partners", headers=hdr,
                     params={"from_track": on, "exclude": f"{clash}"}).json()["partners"]
    assert [p["track"]["id"] for p in got][:2] == [good, same]
    assert "the same artist" in got[1]["why"]
    assert clash not in [p["track"]["id"] for p in got]
    got = client.get("/booth/partners", headers=hdr,
                     params={"from_track": on, "limit": 1}).json()["partners"]
    assert len(got) == 1 and got[0]["track"]["id"] == good
    kept = db.one("select in_db, out_db, sung from track_traits where track_id=%s", (on,))
    assert kept["in_db"] is not None and kept["out_db"] is not None
