"""A station: a queue that keeps going."""
from __future__ import annotations

import pytest

from muse import db


@pytest.fixture()
def tracks(client, hdr):
    """Three songs in the library, each with a YouTube Music id to be seeded from."""
    return [client.post("/tracks/resolve", headers=hdr, json={"video_id": v}).json()
            for v in ("AAA", "BBB", "CCC")]


def test_a_station_from_a_song_is_a_queue_of_its_own(client, hdr, tracks):
    """Not five songs on the end of what was playing — that was the old radio, and it
    is the difference between "add some more" and "put this on"."""
    seed = tracks[0]
    r = client.post("/stations", headers=hdr,
                    json={"kind": "track", "track_id": seed["id"]})
    assert r.status_code == 201, r.text
    made = r.json()

    assert made["items"], "a station with nothing in it is not a station"
    assert made["items"][0]["id"] == seed["id"], "it starts with what it was made from"
    assert made["added"] > 0, "and goes on with what belongs next to it"
    assert made["station"]["kind"] == "track"
    assert made["name"].endswith("radio")

    # Everything after the seed is machine-picked, and tagged as such so the queue can
    # still be cleared of it.
    assert {i["origin"] for i in made["items"][1:]} == {"radio"}


def test_it_is_asked_for_more_as_it_runs_down(client, hdr, tracks, monkeypatch):
    from muse import ytm

    made = client.post("/stations", headers=hdr,
                       json={"kind": "track", "track_id": tracks[0]["id"]}).json()
    was = len(made["items"])
    had = {i["id"] for i in made["items"]}

    # A well that does not run dry, the way the real one does not.
    round_two = [
        {"video_id": f"LATER{n}", "title": f"Later {n}", "artists": ["Someone"],
         "album": None, "duration_ms": 200_000 + n, "raw": {}}
        for n in range(20)
    ]
    monkeypatch.setattr(ytm, "watch_playlist", lambda vid, limit=25: round_two)

    more = client.post(f"/stations/{made['id']}/extend", headers=hdr, json={"count": 5})
    assert more.status_code == 200, more.text
    grown = more.json()
    assert grown["added"] == 5
    assert len(grown["items"]) == was + 5

    # Nothing it already had: a station that repeats itself is a playlist with a bug.
    ids = [i["id"] for i in grown["items"]]
    assert len(ids) == len(set(ids))
    assert had.issubset(set(ids)), "and nothing it had is taken away"


def test_a_station_from_a_record(client, hdr, tracks):
    # Put the three of them on one record, which is what an album station is seeded
    # from — several songs off it rather than only the first.
    for t in tracks:
        client.patch(f"/tracks/{t['id']}", headers=hdr,
                     json={"album": "Test Album", "artists": ["Tester"]})

    r = client.post("/stations", headers=hdr,
                    json={"kind": "album", "album": "Test Album"})
    assert r.status_code == 201, r.text
    made = r.json()
    assert made["station"]["kind"] == "album"
    assert made["station"]["seed_text"] == "Test Album"
    assert made["name"] == "Test Album radio"


def test_a_station_needs_something_to_start_from(client, hdr):
    r = client.post("/stations", headers=hdr,
                    json={"kind": "album", "album": "A record nobody has"})
    assert r.status_code == 400
    assert "station" in r.json()["detail"].lower()


def test_only_a_station_can_be_extended(client, hdr):
    q = client.post("/queues", headers=hdr, json={"name": "Just a queue"}).json()
    assert client.post(f"/stations/{q['id']}/extend", headers=hdr,
                       json={}).status_code == 404


def test_a_station_can_be_saved_to_the_library(client, hdr, tracks):
    """Saving is what a queue already does; a station is a queue, so it comes free."""
    made = client.post("/stations", headers=hdr,
                       json={"kind": "track", "track_id": tracks[0]["id"]}).json()
    saved = client.post(f"/queues/{made['id']}/save-as-playlist", headers=hdr,
                        json={"name": made["name"]})
    assert saved.status_code in (200, 201), saved.text
    assert saved.json()["name"] == made["name"]
    listed = client.get("/playlists", headers=hdr).json()
    assert any(p["name"] == made["name"] for p in listed)


def test_an_ordinary_queue_says_it_is_not_a_station(client, hdr):
    q = client.post("/queues", headers=hdr, json={"name": "Mine"}).json()
    assert client.get(f"/queues/{q['id']}", headers=hdr).json()["station"] is None
    assert db.one("select count(*) n from stations")["n"] == 0
