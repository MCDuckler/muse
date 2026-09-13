"""One search, one list.

Four lists one under another answered "what does each service have"; the question
somebody is actually asking is "where is this song". These are about the merged list:
that everything in it is the same shape, that it says where each row came from, that
one service cannot own the screen, and that asking by the words in a song works.
"""
from __future__ import annotations

import pytest

from muse import catalog, db, search, ytm


def _song(title: str, artists: list[str], album: str | None = None) -> dict:
    return catalog.create_from_ytm({
        "video_id": f"V{abs(hash(title)) % 10**9}", "title": title,
        "artists": artists, "album": album, "duration_ms": 180_000, "raw": {},
    }, discovered_via=catalog.VIA_USER)


@pytest.fixture()
def mine(client, hdr):
    """A small library belonging to whoever the tests log in as."""
    me = db.one("select id from users where name='chris'")["id"]
    made = [
        _song("Bohemian Rhapsody", ["Queen"], "A Night at the Opera"),
        _song("Under Pressure", ["Queen", "David Bowie"], "Hot Space"),
        _song("Chandelier", ["Sia"], "1000 Forms of Fear"),
    ]
    for t in made:
        catalog.remember(me, t["id"])
    # One of them has artwork, so the rows that borrow a cover from a song — a record,
    # an artist — have one to borrow.
    cover = db.one(
        """insert into covers(sha256, path, color)
               values('deadbeef', 'covers/de/deadbeef.jpg', '#223344')
             on conflict (sha256) do update set color=excluded.color
             returning id""")
    db.run("update tracks set cover_id=%s where id=%s", (cover["id"], made[0]["id"]))
    return made


def test_everything_answers_in_one_shape(client, hdr, mine, monkeypatch):
    monkeypatch.setattr(ytm, "search_albums", lambda q, limit=6: [])
    monkeypatch.setattr(ytm, "search_artists", lambda q, limit=4: [])
    items = client.get("/search/everything", headers=hdr,
                       params={"q": "Bohemian"}).json()["items"]
    assert items, "the library has one"
    for row in items:
        # Every row is drawable without knowing what kind of thing it is.
        assert row["kind"] in ("song", "album", "artist")
        assert row["place"] in search.PLACES
        assert row["title"] and "subtitle" in row and "cover_url" in row
        assert "score" in row
    assert items[0]["title"] == "Bohemian Rhapsody"
    assert items[0]["place"] == "library"


def test_records_and_artists_are_found_too_not_only_songs(client, hdr, mine,
                                                          monkeypatch):
    monkeypatch.setattr(ytm, "search_songs", lambda q, limit=10: [])
    monkeypatch.setattr(ytm, "search_albums", lambda q, limit=6: [])
    monkeypatch.setattr(ytm, "search_artists", lambda q, limit=4: [])

    albums = client.get("/search/everything", headers=hdr,
                        params={"q": "Night at the Opera", "kind": "album"}).json()
    assert [a["title"] for a in albums["items"]] == ["A Night at the Opera"]
    assert albums["items"][0]["cover_url"], "a record shows a cover of one of its songs"

    artists = client.get("/search/everything", headers=hdr,
                         params={"q": "Queen", "kind": "artist"}).json()
    assert artists["items"][0]["title"] == "Queen"
    assert artists["items"][0]["subtitle"] == "2 songs"


def test_no_one_service_can_fill_the_screen(client, hdr, mine, monkeypatch):
    """A service with twenty near-identical uploads of one song is not a reason for it
    to own the list."""
    monkeypatch.setattr(ytm, "search_songs", lambda q, limit=10: [
        {"video_id": f"YT{n}", "title": "Bohemian Rhapsody", "artists": ["Queen"],
         "album": None, "duration_ms": 355_000, "raw": {}} for n in range(20)])
    monkeypatch.setattr(ytm, "search_albums", lambda q, limit=6: [])
    monkeypatch.setattr(ytm, "search_artists", lambda q, limit=4: [])

    items = client.get("/search/everything", headers=hdr,
                       params={"q": "Bohemian Rhapsody"}).json()["items"]
    from collections import Counter
    each = Counter(i["place"] for i in items)
    assert each["ytmusic"] <= search.PER_PLACE
    assert each["library"] >= 1, "and what is already here is still in there"


def test_narrowing_to_one_service_lets_it_have_the_room(client, hdr, monkeypatch):
    monkeypatch.setattr(ytm, "search_songs", lambda q, limit=10: [
        {"video_id": f"YT{n}", "title": f"Take {n}", "artists": ["Someone"],
         "album": None, "duration_ms": 100_000, "raw": {}} for n in range(limit)])
    items = client.get("/search/everything", headers=hdr,
                       params={"q": "Take", "where": "ytmusic",
                               "kind": "song"}).json()["items"]
    assert len(items) > search.PER_PLACE
    assert {i["place"] for i in items} == {"ytmusic"}


def test_somewhere_that_does_not_exist_is_refused(client, hdr):
    assert client.get("/search/everything", headers=hdr,
                      params={"q": "x", "where": "tidal"}).status_code == 400
    assert client.get("/search/everything", headers=hdr,
                      params={"q": "x", "kind": "podcasts"}).status_code == 400


def test_one_service_being_down_is_not_a_failed_search(client, hdr, mine, monkeypatch):
    def sulk(q, limit=10):
        raise ytm.Unavailable("a challenge page")

    monkeypatch.setattr(ytm, "search_songs", sulk)
    monkeypatch.setattr(ytm, "search_albums", lambda q, limit=6: [])
    monkeypatch.setattr(ytm, "search_artists", lambda q, limit=4: [])
    said = client.get("/search/everything", headers=hdr,
                      params={"q": "Bohemian"}).json()
    assert said["items"], "the library is right here"
    assert "ytmusic" in said["notes"]


# ---------------------------------------------------------------- by the words in it
def test_the_words_of_a_song_find_it_here(client, hdr, mine, monkeypatch):
    monkeypatch.setattr(ytm, "search_songs", lambda q, limit=10: [])
    db.run("""insert into lyrics(track_id, synced, plain, source)
              values(%s, null, %s, 'test')""",
           (mine[0]["id"], "Is this the real life?\nIs this just fantasy?"))

    said = client.get("/search/everything", headers=hdr,
                      params={"q": "just fantasy", "lyrics": "true"}).json()
    assert said["items"][0]["title"] == "Bohemian Rhapsody"
    # And it says why it is a result, which a list of songs with no visible connection
    # to what was typed does not.
    assert said["items"][0]["lyric"] == "Is this just fantasy?"


def test_the_words_find_songs_nobody_here_owns_yet(client, hdr, monkeypatch):
    """The point of it: a song you have not added is exactly what you are looking for."""
    monkeypatch.setattr(ytm, "search_songs", lambda q, limit=10: [
        {"video_id": "YTNEW", "title": "Bohemian Rhapsody", "artists": ["Queen"],
         "album": None, "duration_ms": 355_000, "raw": {}}])
    monkeypatch.setattr(search, "_confirm_lyrics",
                        lambda hits, q: hits and hits[0].update(
                            {"lyric": "Is this just fantasy?", "confirmed": True}))

    items = client.get("/search/everything", headers=hdr,
                       params={"q": "just fantasy", "lyrics": "true"}).json()["items"]
    assert items[0]["place"] == "ytmusic"
    assert items[0]["known"] is False
    assert items[0]["lyric"] == "Is this just fantasy?"


def test_a_line_across_two_lines_is_still_found():
    plain = "Caught in a landslide\nNo escape from reality"
    assert search._the_line(plain, "landslide no escape") == \
        "Caught in a landslide / No escape from reality"
    assert search._the_line(plain, "nothing like that") is None


# ---------------------------------------------------------------- adding the right one
#
# Spotify cannot be downloaded from, so what is actually added is the same song found
# on YouTube Music — and *found* is the word that matters. Taking the first hit for
# "title artist" is fine until the search is bad at something, and then it is a
# stranger's song with the right row on the screen.
def test_a_spotify_row_is_only_added_when_the_hit_is_that_song(client, hdr,
                                                               monkeypatch):
    from muse import ytm

    monkeypatch.setattr(ytm, "search_songs", lambda q, limit=10: [
        {"video_id": "RIGHT", "title": "Alice und Sarah", "artists": ["Broilers"],
         "album": None, "duration_ms": 200_000, "raw": {}},
        {"video_id": "WRONG", "title": "Alice and Sarah",
         "artists": ["Orion Rigel Dommisse"], "album": None,
         "duration_ms": 240_000, "raw": {}},
    ])
    r = client.post("/search/add", headers=hdr, json={
        "place": "spotify", "id": "sp1", "title": "Alice und Sarah",
        "subtitle": "Broilers", "duration_ms": 200_000})
    assert r.status_code in (200, 201, 202), r.text
    from muse import db

    where = db.one("select provider_id from track_sources where track_id=%s",
                   (r.json()["id"],))
    assert where["provider_id"] == "RIGHT", "the one that was asked for"


def test_nothing_is_added_when_no_hit_is_the_song(client, hdr, monkeypatch):
    """A German punk record came back as an American folk song of nearly the same
    name, and nothing anywhere said so. Saying no is the honest answer."""
    from muse import ytm

    monkeypatch.setattr(ytm, "search_songs", lambda q, limit=10: [
        {"video_id": "NOPE", "title": "Alice and Sarah",
         "artists": ["Orion Rigel Dommisse"], "album": None,
         "duration_ms": 240_000, "raw": {}},
        {"video_id": "ALSONOPE", "title": "Sooraj Dooba Hain",
         "artists": ["Aditi Singh Sharma"], "album": None,
         "duration_ms": 210_000, "raw": {}},
    ])
    r = client.post("/search/add", headers=hdr, json={
        "place": "spotify", "id": "sp2", "title": "Alice und Sarah",
        "subtitle": "Broilers", "duration_ms": 200_000})
    assert r.status_code == 404
    assert "not on youtube music" in r.json()["detail"].lower()
    assert "closest" in r.json()["detail"].lower(), "and it says what it nearly took"


def test_a_youtube_row_is_still_taken_by_its_own_id(client, hdr, monkeypatch):
    """Nothing to judge: the row came from YouTube Music and carries its id."""
    from muse import ytm

    monkeypatch.setattr(ytm, "song", lambda vid: {
        "video_id": vid, "title": "Whatever", "artists": ["Someone"],
        "album": None, "duration_ms": 100_000, "raw": {}})
    r = client.post("/search/add", headers=hdr, json={
        "place": "ytmusic", "id": "EXACTID", "title": "Whatever",
        "subtitle": "Someone"})
    assert r.status_code in (200, 201, 202), r.text
    from muse import db

    assert db.one("select provider_id from track_sources where track_id=%s",
                  (r.json()["id"],))["provider_id"] == "EXACTID"
