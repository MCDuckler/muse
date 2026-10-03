"""Discover: lists made for a person, genres to follow, a station from a genre."""
from __future__ import annotations

import pytest

from muse import auth, brainz, db, discography, discover, follows


def _me() -> int:
    return db.one("select id from users where name='chris'")["id"]


def _listen(user: int, track: int, minutes_ago: float, *, done=True, ms=200_000):
    db.run("""insert into listens(user_id, track_id, started_at, ms_played, completed)
              values(%s,%s, now() - %s * interval '1 minute', %s, %s)""",
           (user, track, minutes_ago, ms, done))


def _list(client, hdr, name, ids):
    p = client.post("/playlists", headers=hdr, json={"name": name}).json()
    client.post(f"/playlists/{p['id']}/items", headers=hdr, json={"track_ids": ids})
    return p["id"]


@pytest.fixture(autouse=True)
def _clean(client):
    """These tables have no key to a per-test row, so they outlive the truncate."""
    for t in ("genre_releases", "remote_cache", "artist_releases"):
        db.run(f"delete from {t}")
    yield


@pytest.fixture(autouse=True)
def _offline(monkeypatch):
    """No MusicBrainz, no ListenBrainz, no Deezer: each answers with nothing unless
    a test says otherwise, and nothing here goes over the wire."""
    monkeypatch.setattr(brainz, "fresh_releases", lambda days=14: [])
    monkeypatch.setattr(brainz, "similar_artists", lambda mbid, limit=30, **kw: [])
    monkeypatch.setattr(brainz, "top_recordings", lambda mbid, limit=10: [])
    monkeypatch.setattr(brainz, "tag_radio", lambda tag, count=30, popular=(35, 100): [])
    monkeypatch.setattr(brainz, "recordings", lambda mbids: {})
    monkeypatch.setattr(brainz, "artist", lambda name, **kw: None)
    monkeypatch.setattr(brainz, "all_genres", lambda: ["techno", "tech house", "house", "ambient"])
    monkeypatch.setattr(discography, "_get", lambda *a, **k: {"data": []})


@pytest.fixture()
def shelf(client, hdr):
    """Twelve songs: eight in chris's library and played, four that only the house
    has — the ones a list of finds can be made of."""
    ids = []
    for n in range(12):
        t = client.post("/tracks/resolve", headers=hdr, json={"video_id": f"DISC{n}"}).json()
        db.run("update tracks set state='ready', title=%s, artists=%s where id=%s",
               (f"Disc Song {n}", [f"Disc Artist {n % 4}"], t["id"]))
        ids.append(t["id"])
    me = _me()
    db.run("delete from library_items where user_id=%s and track_id = any(%s)", (me, ids[8:]))
    for n, t in enumerate(ids[:8]):
        for k in range(3 + (8 - n)):
            _listen(me, t, 60 * k + 10)
    # Hand-made lists that put the house's songs beside chris's: that is how they are
    # found. (The trigger that puts a listed song in a library acts on the owner, so
    # the lists belong to nobody here — they are written straight in.)
    other = auth.ensure_user("joe")
    for name, group in (("one", ids[0:3] + ids[8:10]), ("two", ids[3:6] + ids[10:12]),
                        ("three", ids[0:2] + ids[8:9])):
        p = db.one("insert into playlists(owner_id, name) values(%s,%s) returning id",
                   (other, name))
        for pos, t in enumerate(group):
            db.run("insert into playlist_items(playlist_id, pos, track_id) values(%s,%s,%s)",
                   (p["id"], pos, t))
    db.run("delete from library_items where user_id=%s", (other,))
    return ids


def test_the_page_answers_before_anything_has_been_made(client, hdr):
    r = client.get("/discover", headers=hdr)
    assert r.status_code == 200, r.text
    page = r.json()
    assert page["lists"] == []
    assert page["building"] is True, "and says the lists are on their way"
    assert db.one("select 1 from jobs where kind='discover_build' and state='pending'")
    # Asking again does not queue a second build.
    client.get("/discover", headers=hdr)
    assert db.one("select count(*) n from jobs where kind='discover_build'")["n"] == 1


def test_lists_are_made_out_of_what_somebody_plays(client, hdr, shelf):
    me = _me()
    made = discover.build_for(me, network=False)
    assert "repeat" in made["built"] and "daily" in made["built"]

    r = client.get("/discover/lists", headers=hdr)
    lists = {entry["slug"]: entry for entry in r.json()["items"]}

    repeat = lists["repeat"]
    assert [t["id"] for t in repeat["tracks"]][:3] == shelf[:3], "most played first"

    weekly = lists["weekly"]
    ids = {t["id"] for t in weekly["tracks"]}
    assert ids and ids <= set(shelf[8:]), "this week's finds are songs chris has not got"
    assert not ids & set(shelf[:8])

    mixes = [s for s in lists if s.startswith("daily:")]
    assert mixes, "four acts, played, make at least one daily mix"
    first = lists[mixes[0]]
    assert first["tracks"] and first["blurb"], "named after who is in it"
    assert "house" in lists and lists["house"]["tracks"]

    # The page now carries them, and says nothing is being built.
    page = client.get("/discover", headers=hdr).json()
    assert page["building"] is False
    assert {e["slug"] for e in page["lists"]} == set(lists)


def test_this_weeks_finds_do_not_come_round_again(client, hdr, shelf):
    me = _me()
    discover.build_for(me, network=False)
    first = {t["id"] for t in discover.one_list(me, "weekly")["tracks"]}
    assert first
    discover.build_for(me, network=False, force=True)
    again = discover.one_list(me, "weekly")
    second = {t["id"] for t in again["tracks"]} if again else set()
    assert not first & second, "what was offered once is not offered next week"


def test_the_map_brings_in_acts_nobody_here_plays(client, hdr, shelf, monkeypatch):
    """ListenBrainz says who else people who play Disc Artist 0 play; their best
    known song is found on YouTube Music and lands in the finds, with the reason."""
    from muse import ytm
    monkeypatch.setattr(brainz, "artist",
                        lambda name, **kw: {"mbid": "m-" + name, "name": name, "genres": ["techno"]})
    monkeypatch.setattr(brainz, "similar_artists",
                        lambda mbid, limit=30, **kw: [{"mbid": "m-new", "name": "Brand New Act", "score": 100}])
    monkeypatch.setattr(brainz, "top_recordings",
                        lambda mbid, limit=10: [{"recording_mbid": "r1", "title": "Unheard Song",
                                                 "artists": ["Brand New Act"]}])
    monkeypatch.setattr(ytm, "search_songs", lambda q, limit=10: [{
        "video_id": "NEWACT01", "title": "Unheard Song", "artists": ["Brand New Act"],
        "album": None, "duration_ms": 200_000, "raw": {}}])
    me = _me()
    discover.build_for(me, network=True)
    weekly = discover.one_list(me, "weekly")
    titles = {t["title"] for t in weekly["tracks"]}
    assert "Unheard Song" in titles
    new = next(t for t in weekly["tracks"] if t["title"] == "Unheard Song")
    assert weekly["why"][str(new["id"])].startswith("because you play Disc Artist")
    assert new["discovered_via"] == "discover" and new["state"] == "pending", \
        "written into the catalog and queued, not downloaded by the test"

    # The build also left behind what the page may show without asking anybody:
    # the genres this person seems to play, and acts to try.
    page = client.get("/discover", headers=hdr).json()
    assert page["genres"]["suggested"][0]["genre"] == "techno"
    assert page["artists"][0]["name"] == "Brand New Act"


def test_keeping_a_list_makes_a_playlist_of_it(client, hdr, shelf):
    me = _me()
    discover.build_for(me, network=False)
    r = client.post("/discover/lists/repeat/keep", headers=hdr)
    assert r.status_code == 201, r.text
    p = client.get(f"/playlists/{r.json()['playlist_id']}", headers=hdr).json()
    assert p["name"].startswith("On repeat")
    assert [t["id"] for t in p["items"]] == [t["id"] for t in discover.one_list(me, "repeat")["tracks"]]
    assert client.post("/discover/lists/nothing/keep", headers=hdr).status_code == 404


def test_following_a_genre_watches_its_new_records(client, hdr, monkeypatch):
    monkeypatch.setattr(brainz, "fresh_releases", lambda days=14: [
        {"release_mbid": "rel-1", "release_group_mbid": "rg-1", "title": "Warehouse",
         "artist": "Some Producer", "artist_mbids": ["a1"], "release_date": "2026-10-01",
         "record_type": "ep", "tags": ["techno", "electronic"], "listens": 40, "cover": None},
        {"release_mbid": "rel-2", "release_group_mbid": "rg-2", "title": "Lullabies",
         "artist": "A Choir", "artist_mbids": ["a2"], "release_date": "2026-10-02",
         "record_type": "album", "tags": ["classical"], "listens": 900, "cover": None},
    ])
    r = client.put("/discover/genres/Techno", headers=hdr)
    assert r.status_code == 200, r.text
    assert r.json() == {"genre": "techno", "following": True, "releases": 1}

    feed = client.get("/discover/feed", headers=hdr).json()
    assert [i["title"] for i in feed["items"]] == ["Warehouse"], "tagged techno, not the choir"
    item = feed["items"][0]
    assert item["source"] == "genre" and item["genre"] == "techno" and item["unseen"]
    assert feed["genres"] == 1

    client.post("/discover/feed/seen", headers=hdr, json={"items": [item]})
    assert client.get("/discover/feed", headers=hdr).json()["unseen"] == 0

    page = client.get("/discover", headers=hdr).json()
    assert page["genres"]["following"] == ["techno"]

    assert client.delete("/discover/genres/techno", headers=hdr).json()["following"] is False
    assert client.get("/discover/feed", headers=hdr).json()["items"] == []


def test_genres_can_be_looked_up_by_a_few_letters(client, hdr):
    found = client.get("/discover/genres", headers=hdr, params={"q": "tech"}).json()["found"]
    assert found == ["techno", "tech house"], "what starts with it first"
    assert client.put("/discover/genres/%20", headers=hdr).status_code == 400


def test_a_station_can_be_started_from_a_genre(client, hdr, monkeypatch):
    """ListenBrainz names recordings for the tag; each is found on YouTube Music and
    becomes a seed, and the station goes on from there like any other."""
    from muse import ytm
    monkeypatch.setattr(brainz, "tag_radio", lambda tag, count=30, popular=(35, 100): ["r1", "r2"])
    monkeypatch.setattr(brainz, "recordings", lambda mbids: {
        "r1": {"title": "Pulse", "artists": ["Machine One"], "album": None},
        "r2": {"title": "Drift", "artists": ["Machine Two"], "album": None},
    })
    monkeypatch.setattr(ytm, "search_songs", lambda q, limit=10: [{
        "video_id": "V" + q.split()[0].upper(), "title": q.split()[0],
        "artists": [" ".join(q.split()[1:])], "album": None, "duration_ms": 200_000, "raw": {}}])
    r = client.post("/stations", headers=hdr, json={"kind": "genre", "genre": "techno"})
    assert r.status_code == 201, r.text
    made = r.json()
    assert made["station"]["kind"] == "genre"
    assert made["name"] == "Techno radio"
    assert {i["title"] for i in made["items"][:2]} == {"Pulse", "Drift"}
    assert made["added"] > 0, "and goes on past the seeds"

    # Resolved seeds are kept, so the second time asks nobody.
    monkeypatch.setattr(brainz, "tag_radio", lambda *a, **k: pytest.fail("asked again"))
    again = client.post("/stations", headers=hdr, json={"kind": "genre", "genre": "techno"})
    assert again.status_code == 201, again.text
    assert again.json()["id"] != made["id"], "the old one was replaced, not refused"

    page = client.get("/discover", headers=hdr).json()
    assert page["stations"]["yours"][0]["name"] == "Techno radio"


def test_the_nightly_build_queues_itself_once(client):
    discover.ensure_scheduled(delay=30)
    discover.ensure_scheduled(delay=30)
    assert db.one("select count(*) n from jobs where kind='discover_build'")["n"] == 1
    assert 0 < discover.seconds_until_build() <= 86400
    # The round itself runs over everybody and every followed genre without a network.
    assert discover.run_job({}) == {"users": 1, "genres": 0}


def test_release_radar_takes_a_song_from_each_new_record(client, hdr, monkeypatch):
    from muse import ytm
    me = _me()
    monkeypatch.setattr(discography, "artist_albums", lambda remote_id, limit=60: [
        {"remote_id": "alb-1", "title": "Fresh One", "cover": None,
         "release_date": "2026-10-01", "record_type": "single", "tracks": 1}])
    monkeypatch.setattr(discography, "album", lambda album_id: {
        "remote_id": album_id, "title": "Fresh One", "artist": "Followed Act",
        "tracks": [{"pos": 1, "title": "Opening Cut", "artists": ["Followed Act"]}]})
    monkeypatch.setattr(ytm, "search_songs", lambda q, limit=10: [{
        "video_id": "FRESH1", "title": "Opening Cut", "artists": ["Followed Act"],
        "album": "Fresh One", "duration_ms": 200_000, "raw": {}}])
    follows.follow(me, {"remote_id": "art-1", "name": "Followed Act", "image": None})
    discover.build_radar(me)
    radar = discover.one_list(me, "radar")
    assert [t["title"] for t in radar["tracks"]] == ["Opening Cut"]
    assert db.one("select 1 from jobs where kind='ingest' and payload->>'track_id'=%s",
                  (str(radar["tracks"][0]["id"]),)), "queued to be fetched"
