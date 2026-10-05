"""A station: a playlist the machine writes, and keeps writing."""
from __future__ import annotations

import pytest

from muse import db, stations


@pytest.fixture()
def tracks(client, hdr):
    """Three songs in the library, each with a YouTube Music id to be seeded from."""
    return [client.post("/tracks/resolve", headers=hdr, json={"video_id": v}).json()
            for v in ("AAA", "BBB", "CCC")]


def test_a_station_from_a_song_is_a_playlist_of_its_own(client, hdr, tracks):
    """Not five songs on the end of what was playing, and not a queue either: a list
    to look through, play from anywhere, and find again in the library."""
    seed = tracks[0]
    r = client.post("/stations", headers=hdr,
                    json={"kind": "track", "track_id": seed["id"]})
    assert r.status_code == 201, r.text
    made = r.json()

    assert made["kind"] == "station"
    assert made["items"], "a station with nothing in it is not a station"
    assert made["items"][0]["id"] == seed["id"], "it starts with what it was made from"
    assert made["added"] > 0, "and goes on with what belongs next to it"
    assert made["station"]["kind"] == "track" and made["station"]["id"]
    assert made["name"].endswith("radio")
    assert made["editable"], "yours to take songs out of"
    assert made["sort"] == "manual", "in the order it was written"

    # In the library with the rest, as a playlist of its kind.
    listed = client.get("/playlists", headers=hdr).json()
    mine = [p for p in listed if p["id"] == made["id"]]
    assert mine and mine[0]["kind"] == "station"
    # And the page says what station it is.
    page = client.get(f"/playlists/{made['id']}", headers=hdr).json()
    assert page["station"]["kind"] == "track"


def test_a_new_song_is_written_down_but_not_fetched_until_played(client, hdr, tracks, monkeypatch):
    """Thirty songs to look at should not be thirty downloads: a song the station
    found out in the world is in the catalog, pending, with no job for it — the queue
    made from the station asks for it when it is played."""
    from muse import ytm
    tail = [
        {"video_id": f"OUT{n}", "title": f"Out {n}", "artists": [f"Someone {n}"],
         "album": None, "duration_ms": 200_000 + n, "raw": {}}
        for n in range(20)
    ]
    monkeypatch.setattr(ytm, "watch_playlist", lambda vid, limit=25: tail)
    made = client.post("/stations", headers=hdr,
                       json={"kind": "track", "track_id": tracks[0]["id"], "fresh": 1.0}).json()
    new = [i for i in made["items"] if i["title"].startswith("Out ")]
    assert new, "it reached past the library"
    assert all(i["state"] == "pending" for i in new)
    jobs = db.one("select count(*) n from jobs where kind like 'ingest%%' and state='pending' "
                  "and (payload->>'track_id')::int = any(%s)", ([i["id"] for i in new],))["n"]
    assert jobs == 0, "nothing fetched for looking"

    # Played: the queue made from it is prioritised, and the fetching starts.
    q = client.post("/queues", headers=hdr,
                    json={"name": made["name"], "station_id": made["station"]["id"]}).json()
    assert q["station"]["id"] == made["station"]["id"], "the queue remembers its station"
    client.put(f"/queues/{q['id']}", headers=hdr,
               json={"rev": q["rev"], "items": [i["id"] for i in made["items"]]})
    r = client.post(f"/queues/{q['id']}/prioritise", headers=hdr)
    assert r.status_code == 200 and r.json()["queued"] + r.json()["moved"] >= len(new)


def test_it_is_asked_for_more_as_it_runs_down(client, hdr, tracks, monkeypatch):
    from muse import ytm

    made = client.post("/stations", headers=hdr,
                       json={"kind": "track", "track_id": tracks[0]["id"]}).json()
    was = len(made["items"])
    had = {i["id"] for i in made["items"]}
    sid = made["station"]["id"]

    # The queue playing it, so the new songs land there too.
    q = client.post("/queues", headers=hdr, json={"name": made["name"], "station_id": sid}).json()
    client.put(f"/queues/{q['id']}", headers=hdr,
               json={"rev": q["rev"], "items": [i["id"] for i in made["items"]]})

    # A well that does not run dry, the way the real one does not.
    round_two = [
        {"video_id": f"LATER{n}", "title": f"Later {n}", "artists": [f"Someone {n}"],
         "album": None, "duration_ms": 200_000 + n, "raw": {}}
        for n in range(20)
    ]
    monkeypatch.setattr(ytm, "watch_playlist", lambda vid, limit=25: round_two)

    more = client.post(f"/stations/{sid}/extend", headers=hdr,
                       json={"count": 5, "queue_id": q["id"]})
    assert more.status_code == 200, more.text
    grown = more.json()
    assert grown["added"] == 5
    assert len(grown["playlist"]["items"]) == was + 5
    assert len(grown["queue"]["items"]) == was + 5, "and on the end of the queue"
    assert {i["origin"] for i in grown["queue"]["items"][was:]} == {"radio"}

    # Nothing it already had: a station that repeats itself is a playlist with a bug.
    ids = [i["id"] for i in grown["playlist"]["items"]]
    assert len(ids) == len(set(ids))
    assert had.issubset(set(ids)), "and nothing it had is taken away"

    # Without a queue: only the playlist grows.
    alone = client.post(f"/stations/{sid}/extend", headers=hdr, json={"count": 3}).json()
    assert alone["queue"] is None and len(alone["playlist"]["items"]) == was + 5 + alone["added"]


def test_a_station_can_be_written_again(client, hdr, tracks, monkeypatch):
    from muse import ytm
    first = [
        {"video_id": f"ONE{n}", "title": f"One {n}", "artists": [f"A {n}"],
         "album": None, "duration_ms": 200_000, "raw": {}} for n in range(12)]
    monkeypatch.setattr(ytm, "watch_playlist", lambda vid, limit=25: first)
    made = client.post("/stations", headers=hdr,
                       json={"kind": "track", "track_id": tracks[0]["id"], "fresh": 1.0}).json()
    before = {i["id"] for i in made["items"]}
    second = [
        {"video_id": f"TWO{n}", "title": f"Two {n}", "artists": [f"B {n}"],
         "album": None, "duration_ms": 200_000, "raw": {}} for n in range(12)]
    monkeypatch.setattr(ytm, "watch_playlist", lambda vid, limit=25: second)
    # The world has moved on since (the engine keeps what YouTube Music said for a
    # week; here there is nothing else to draw on but that).
    db.run("delete from radio_edges")
    r = client.post(f"/stations/{made['station']['id']}/refresh", headers=hdr)
    assert r.status_code == 200, r.text
    again = r.json()
    assert again["items"][0]["id"] == tracks[0]["id"], "the seed stays"
    after = {i["id"] for i in again["items"]}
    assert after != before and again["added"] > 0
    assert any(i["title"].startswith("Two ") for i in again["items"])


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


def test_only_a_station_can_be_extended_or_tuned(client, hdr):
    assert client.post("/stations/999/extend", headers=hdr, json={}).status_code == 404
    assert client.patch("/stations/999", headers=hdr, json={"fresh": 1}).status_code == 404
    assert client.post("/stations/999/refresh", headers=hdr).status_code == 404


def test_a_station_is_tuned_from_its_page(client, hdr, tracks):
    made = client.post("/stations", headers=hdr,
                       json={"kind": "track", "track_id": tracks[0]["id"]}).json()
    r = client.patch(f"/stations/{made['station']['id']}", headers=hdr, json={"fresh": 1})
    assert r.status_code == 200 and r.json()["station"]["fresh"] == 1.0


def test_the_same_station_started_twice_is_written_again(client, hdr, tracks):
    one = client.post("/stations", headers=hdr,
                      json={"kind": "track", "track_id": tracks[0]["id"]}).json()
    two = client.post("/stations", headers=hdr,
                      json={"kind": "track", "track_id": tracks[0]["id"]}).json()
    assert two["id"] != one["id"] and two["name"] == one["name"]
    listed = client.get("/playlists", headers=hdr).json()
    assert [p["id"] for p in listed if p["name"] == one["name"]] == [two["id"]]


def test_only_so_many_stations_are_kept(client, hdr, tracks, monkeypatch):
    monkeypatch.setattr(stations, "KEEP", 2)
    ids = []
    for t in tracks:
        made = client.post("/stations", headers=hdr,
                           json={"kind": "track", "track_id": t["id"]}).json()
        ids.append(made["id"])
    listed = {p["id"] for p in client.get("/playlists", headers=hdr).json()}
    assert ids[0] not in listed and {ids[1], ids[2]} <= listed, "the oldest went"


def test_songs_can_be_taken_out_of_a_station(client, hdr, tracks):
    made = client.post("/stations", headers=hdr,
                       json={"kind": "track", "track_id": tracks[0]["id"]}).json()
    last = made["items"][-1]
    r = client.delete(f"/playlists/{made['id']}/items/{last['pos']}", headers=hdr)
    assert r.status_code in (200, 204), r.text
    page = client.get(f"/playlists/{made['id']}", headers=hdr).json()
    assert last["id"] not in {i["id"] for i in page["items"]}


def test_an_ordinary_queue_says_it_is_not_a_station(client, hdr):
    q = client.post("/queues", headers=hdr, json={"name": "Mine"}).json()
    assert client.get(f"/queues/{q['id']}", headers=hdr).json()["station"] is None
    assert db.one("select count(*) n from stations")["n"] == 0


def test_a_station_of_the_old_shape_becomes_a_playlist(client, hdr, tracks):
    """A queue that *was* a station, from before: carried over to a playlist at
    start-up, the queue left playing and pointed at it."""
    user = db.one("select id from users limit 1")["id"]
    q = db.one("insert into queues(user_id, name) values(%s, 'Old radio') returning id", (user,))
    for n, t in enumerate(tracks):
        db.run("insert into queue_items(queue_id, pos, track_id) values(%s,%s,%s)",
               (q["id"], n, t["id"]))
    db.run("""insert into stations(owner_id, queue_id, kind, seed_track, name, fresh)
              values(%s,%s,'track',%s,'Old radio',0.5)""", (user, q["id"], tracks[0]["id"]))
    assert stations.adopt_queues() == 1
    assert stations.adopt_queues() == 0, "once"
    queue = client.get(f"/queues/{q['id']}", headers=hdr).json()
    assert queue["station"]["playlist_id"], "the queue plays the station it was"
    page = client.get(f"/playlists/{queue['station']['playlist_id']}", headers=hdr).json()
    assert [i["id"] for i in page["items"]] == [t["id"] for t in tracks]
    assert page["kind"] == "station"


def test_similar_offers_what_the_library_has_not_got(client, hdr, tracks, monkeypatch):
    """Beside a few songs: the radio tail, minus what is held, minus the seed itself,
    each once — and nothing fetched for looking."""
    seed = tracks[0]
    held = tracks[1]
    from muse import catalog, ytm
    held_vid = catalog.track_row(held["id"])["provider_id"]
    tail = [
        {"video_id": held_vid, "title": "Already here", "artists": ["X"], "duration_ms": 200000, "raw": {}},
        {"video_id": "NEWONE0001", "title": "New one", "artists": ["Y"], "duration_ms": 210000, "raw": {}},
        {"video_id": "NEWONE0001", "title": "New one", "artists": ["Y"], "duration_ms": 210000, "raw": {}},
        {"video_id": "NEWTWO0002", "title": "New two", "artists": ["Z"], "duration_ms": 190000, "raw": {}},
    ]
    monkeypatch.setattr(ytm, "watch_playlist", lambda vid, limit=25: tail)
    before = client.get("/library/tracks", headers=hdr).json()
    r = client.get("/search/similar", headers=hdr, params={"tracks": f"{seed['id']},{held['id']}", "limit": 10})
    assert r.status_code == 200, r.text
    got = r.json()
    assert [h["video_id"] for h in got["similar"]] == ["NEWONE0001", "NEWTWO0002"]
    assert got["similar"][0]["seed"]["id"] == seed["id"] and got["similar"][0]["known"] is False
    assert len(got["seeds"]) == 2
    after = client.get("/library/tracks", headers=hdr).json()
    assert before == after, "looking fetched nothing"
    assert client.get("/search/similar", headers=hdr, params={"tracks": "x"}).status_code == 400
