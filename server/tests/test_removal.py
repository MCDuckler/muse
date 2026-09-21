"""Removing a song: out of your lists always, off the server when nobody else has it."""
from __future__ import annotations

import pathlib

import pytest

from muse import auth, db


@pytest.fixture()
def ready(client, hdr, wsec, complete_job):
    """A track with real audio on disk."""
    def _make(video_id: str, nbytes: int = 4096) -> dict:
        t = client.post("/tracks/resolve", headers=hdr, json={"video_id": video_id}).json()
        job = client.post("/internal/jobs/lease", headers=wsec,
                          json={"worker": "w"}).json()["jobs"][0]
        complete_job(job["id"], t["id"], nbytes)
        return t
    return _make


def _blobs(track_id: int) -> list[pathlib.Path]:
    return [pathlib.Path(r["path"]) for r in
            db.all_("select path from media where track_id=%s", (track_id,))]


def test_a_removed_song_is_gone_from_the_server_and_the_disk(client, hdr, ready):
    wrong, right = ready("WRONG1", 4096), ready("RIGHT1", 5000)
    blobs = _blobs(wrong["id"])
    assert blobs and all(b.exists() for b in blobs)

    done = client.post("/library/remove", headers=hdr,
                       json={"track_ids": [wrong["id"]]}).json()
    assert done == {"removed": 1, "deleted": 1}
    assert db.one("select 1 from tracks where id=%s", (wrong["id"],)) is None
    assert not any(b.exists() for b in blobs), "the audio goes with it"
    assert all(b.exists() for b in _blobs(right["id"])), "and only its own audio"
    assert client.get(f"/tracks/{wrong['id']}", headers=hdr).status_code == 404


def test_it_leaves_queues_and_playlists_without_a_hole(client, hdr, ready):
    a, b, c = ready("QA"), ready("QB"), ready("QC")
    q = client.post("/queues", headers=hdr, json={"name": "Now"}).json()
    client.put(f"/queues/{q['id']}", headers=hdr, json={
        "rev": q["rev"], "items": [a["id"], b["id"], a["id"], c["id"]]})
    client.patch(f"/queues/{q['id']}/cursor", headers=hdr, json={"cursor_index": 3})
    p = client.post("/playlists", headers=hdr, json={"name": "Mix"}).json()
    client.post(f"/playlists/{p['id']}/items", headers=hdr,
                json={"track_ids": [a["id"], b["id"], c["id"]]})

    client.post("/library/remove", headers=hdr, json={"track_ids": [a["id"]]})

    after = client.get(f"/queues/{q['id']}", headers=hdr).json()
    assert [i["id"] for i in after["items"]] == [b["id"], c["id"]]
    assert [i["pos"] for i in after["items"]] == [0, 1]
    assert after["items"][after["cursor_index"]]["id"] == c["id"], \
        "what was playing is still what is playing"
    assert after["rev"] > q["rev"]
    mix = client.get(f"/playlists/{p['id']}", headers=hdr).json()
    assert [i["id"] for i in mix["items"]] == [b["id"], c["id"]]


def test_somebody_elses_copy_survives(client, hdr, ready):
    shared = ready("SHARED1")
    other = auth.ensure_user("someone-else")
    theirs = {"Authorization": f"Bearer {auth.issue_token(other, 'phone', None)}"}
    q = client.post("/queues", headers=theirs, json={"name": "Now"}).json()
    client.put(f"/queues/{q['id']}", headers=theirs,
               json={"rev": q["rev"], "items": [shared["id"]]})

    done = client.post("/library/remove", headers=hdr,
                       json={"track_ids": [shared["id"]]}).json()
    assert done == {"removed": 1, "deleted": 0}
    assert all(b.exists() for b in _blobs(shared["id"]))
    kept = client.get(f"/queues/{q['id']}", headers=theirs).json()
    assert [i["id"] for i in kept["items"]] == [shared["id"]]
    mine = client.get("/library/tracks", headers=hdr).json()
    assert shared["id"] not in [t["id"] for t in mine.get("items", mine)]


def test_a_sync_does_not_bring_the_wrong_match_back(client, hdr, ready):
    from muse import sync
    wrong = ready("TESTVIDEO001")
    sync._record("spotify", "sp:1", wrong["id"], 0.9, "fuzzy", "auto",
                 {"title": "Test Song", "artists": ["Tester"]})
    client.post("/library/remove", headers=hdr, json={"track_ids": [wrong["id"]]})
    again = sync.resolve_item("spotify", {"remote_id": "sp:1", "title": "Test Song",
                                          "artists": ["Tester"]})
    assert again["track_id"] is None and again["verdict"] == "cached"


def test_it_wants_a_list_of_ids(client, hdr):
    assert client.post("/library/remove", headers=hdr, json={}).status_code == 400
    assert client.post("/library/remove", headers=hdr,
                       json={"track_ids": ["x"]}).status_code == 400
