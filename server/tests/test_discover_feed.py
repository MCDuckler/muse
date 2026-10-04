"""Discover, round two: playlist sort, follow import that opens labels, the feed."""
from __future__ import annotations

import pytest

from muse import brainz, db, discography, discover, follows, linked


def _me() -> int:
    return db.one("select id from users where name='chris'")["id"]


@pytest.fixture(autouse=True)
def _offline(client, monkeypatch):
    for t in ("genre_releases", "remote_cache", "artist_releases"):
        db.run(f"delete from {t}")
    monkeypatch.setattr(brainz, "artist", lambda name, **kw: None)
    monkeypatch.setattr(brainz, "fresh_releases", lambda days=14: [])
    monkeypatch.setattr(discography, "_get", lambda *a, **k: {"data": []})
    monkeypatch.setattr(discography, "artist_albums", lambda remote_id, limit=60: [])


@pytest.fixture()
def songs(client, hdr):
    ids = []
    for n in range(4):
        t = client.post("/tracks/resolve", headers=hdr, json={"video_id": f"SORT{n}"}).json()
        db.run("update tracks set state='ready', title=%s, artists=%s, release_year=%s, "
               "duration_ms=%s where id=%s",
               (["Delta", "Alpha", "Charlie", "Bravo"][n], [["Zed"], ["Ann"], ["Mo"], ["Kay"]][n],
                2000 + n, 100_000 * (4 - n), t["id"]))
        ids.append(t["id"])
    return ids


# ------------------------------------------------------------------ playlist sort
def test_a_playlist_reads_newest_added_first_and_remembers_another_order(client, hdr, songs):
    p = client.post("/playlists", headers=hdr, json={"name": "mixed"}).json()
    client.post(f"/playlists/{p['id']}/items", headers=hdr, json={"track_ids": songs[:3]})
    # Added later, so it comes first; the three added together keep their order.
    db.run("update playlist_items set added_at = now() - interval '1 day' where playlist_id=%s",
           (p["id"],))
    client.post(f"/playlists/{p['id']}/items", headers=hdr, json={"track_ids": songs[3:]})
    got = client.get(f"/playlists/{p['id']}", headers=hdr).json()
    assert got["sort"] == "added_desc"
    assert [t["id"] for t in got["items"]] == [songs[3], songs[0], songs[1], songs[2]]
    assert got["items"][0]["added_at"], "when it was added travels with the row"

    r = client.patch(f"/playlists/{p['id']}", headers=hdr, json={"sort": "title"})
    assert r.status_code == 200, r.text
    assert [t["title"] for t in r.json()["items"]] == ["Alpha", "Bravo", "Charlie", "Delta"]
    assert client.get(f"/playlists/{p['id']}", headers=hdr).json()["sort"] == "title", "kept"

    assert client.patch(f"/playlists/{p['id']}", headers=hdr,
                        json={"sort": "sideways"}).status_code == 400
    # Dragging is for the hand order only: the positions on show are not the positions
    # underneath in any other.
    assert client.post(f"/playlists/{p['id']}/move", headers=hdr,
                       json={"from": 0, "to": 2}).status_code == 400
    client.patch(f"/playlists/{p['id']}", headers=hdr, json={"sort": "manual"})
    moved = client.post(f"/playlists/{p['id']}/move", headers=hdr, json={"from": 0, "to": 2})
    assert moved.status_code == 200
    assert [t["id"] for t in moved.json()["items"]] == [songs[1], songs[2], songs[0], songs[3]]
    # And a drag did not make everything "added just now".
    client.patch(f"/playlists/{p['id']}", headers=hdr, json={"sort": "added_desc"})
    again = client.get(f"/playlists/{p['id']}", headers=hdr).json()
    assert again["items"][0]["id"] == songs[3]

    # The order is the owner's to set on any kind of list, favourites included.
    client.post(f"/favourites/{songs[0]}", headers=hdr)
    fav = client.get("/favourites", headers=hdr).json()["playlist_id"]
    assert client.patch(f"/playlists/{fav}", headers=hdr, json={"sort": "artist"}).status_code == 200


# ------------------------------------------------------------------ follow import
def test_importing_follows_adds_and_opens_labels_into_their_acts(client, hdr, monkeypatch):
    me = _me()
    # Already following one of them: it stays, and is counted as already there.
    follows.follow(me, {"remote_id": "dz-1", "name": "Alewya", "image": None})

    def find_artist(name):
        return {"dz-1": None, }.get(name) or (
            {"remote_id": "dz-1", "name": "Alewya", "image": None} if name == "Alewya" else
            {"remote_id": "dz-2", "name": "Roster Act", "image": None} if name == "Roster Act" else
            None)
    monkeypatch.setattr(discography, "find_artist", find_artist)
    monkeypatch.setattr(linked, "bandcamp_band", lambda url: {
        "name": "Ninja Tune", "is_label": url.startswith("https://ninjatune"),
        "url": url, "image": None})
    monkeypatch.setattr(linked, "bandcamp_roster", lambda url, most=60: [
        {"name": "Roster Act", "url": "https://rosteract.bandcamp.com"},
        {"name": "Only On Bandcamp", "url": "https://onlyonbandcamp.bandcamp.com"},
    ])
    monkeypatch.setattr(linked, "bandcamp_discography", lambda url, newest=40: [
        {"remote_id": f"{url}/album/one", "title": "One", "artist": "Only On Bandcamp",
         "cover": None, "record_type": "album"}])
    monkeypatch.setattr(linked, "bandcamp_record", lambda url: {
        "release_date": "2026-10-01", "tags": ["techno"], "reviews": [], "about": None})

    r = follows.import_entries(me, "bandcamp", [
        {"name": "Alewya", "url": "https://alewya.bandcamp.com", "image": None},
        {"name": "Ninja Tune", "url": "https://ninjatune.bandcamp.com", "image": None},
    ])
    assert r["already"] == 1 and r["labels"] == 1 and r["from_labels"] == 2
    assert r["followed"] == 3, "the label itself, and two acts off its roster"
    assert r["not_found"] == []

    mine = {(f["provider"], f["remote_id"]): f for f in follows.list_for(me)}
    assert ("deezer", "dz-1") in mine and ("deezer", "dz-2") in mine
    label = mine[("bandcamp", "https://ninjatune.bandcamp.com")]
    assert label["is_label"] is True
    bc = mine[("bandcamp", "https://onlyonbandcamp.bandcamp.com")]
    assert bc["is_label"] is False and bc["releases"] == 1, "its records were read off its page"

    feed = client.get("/feed", headers=hdr).json()
    assert any(i["title"] == "One" and i["provider"] == "bandcamp" for i in feed["items"])
    assert client.get("/follows/sources", headers=hdr).json() == {"items": []}

    # Importing again changes nothing and loses nothing.
    again = follows.import_entries(me, "bandcamp", [
        {"name": "Ninja Tune", "url": "https://ninjatune.bandcamp.com", "image": None}])
    assert again["followed"] == 0 and again["already"] == 3
    assert len(follows.list_for(me)) == 4


# ------------------------------------------------------------------ the feed
def test_the_feed_is_the_lists_songs_in_order_with_what_is_said_about_them(client, hdr, songs,
                                                                           monkeypatch):
    me = _me()
    discover._save(me, "weekly", "This week's finds", "", songs[:2], 0,
                   {"why": {str(songs[0]): "because you play Zed"}})
    discover._save(me, "radar", "Release radar", "", [songs[2]], 20)
    discover._save(me, "house", "House blend", "", [songs[1], songs[3]], 50)
    # Played this morning: not put in front of them again.
    db.run("insert into listens(user_id, track_id, started_at, ms_played, completed) "
           "values(%s,%s,now(),200000,true)", (me, songs[3]))

    r = client.get("/discover/cards", headers=hdr, params={"limit": 10})
    assert r.status_code == 200, r.text
    got = r.json()
    assert [c["track"]["id"] for c in got["items"]] == [songs[2], songs[0], songs[1]], \
        "the radar first, then the finds; each song once; nothing played lately"
    assert got["items"][1]["why"] == "because you play Zed"
    assert got["items"][0]["why"] == "new from somebody you follow"
    assert got["total"] == 3

    # A song from Bandcamp says what the record is tagged and who bought it and why.
    db.run("update track_sources set provider='bandcamp', raw=%s where track_id=%s",
           ('{"url": "https://x.bandcamp.com/track/one"}', songs[0]))
    monkeypatch.setattr(linked, "bandcamp_record", lambda url: {
        "release_date": None, "tags": ["ambient", "drone"], "about": "Recorded in a barn.",
        "reviews": [{"name": "zwarren824", "text": "Reminds me of Nuvema Town.",
                     "favourite": "Your Notebook", "avatar": None}]})
    card = client.get(f"/discover/cards/{songs[0]}", headers=hdr).json()
    assert card["genres"][:2] == ["ambient", "drone"]
    assert card["comments"][0]["name"] == "zwarren824" and card["comments"][0]["favourite"]
    assert card["source"] == "bandcamp"
    # Asked once; the second look is the cache.
    monkeypatch.setattr(linked, "bandcamp_record", lambda url: pytest.fail("asked again"))
    assert client.get(f"/discover/cards/{songs[0]}", headers=hdr).json()["genres"][0] == "ambient"

    # Anywhere else, Deezer's genres for the record stand in, and there are no comments.
    monkeypatch.setattr(discography, "find_album", lambda album, artist: {"id": 77})
    monkeypatch.setattr(discography, "_get", lambda path, params=None, kind="search": {
        "genres": {"data": [{"name": "Electro"}]}} if path == "/album/77" else {"data": []})
    db.run("update tracks set album='Some Record' where id=%s", (songs[1],))
    other = client.get(f"/discover/cards/{songs[1]}", headers=hdr).json()
    assert other["genres"] == ["electro"] and other["comments"] == []


# ------------------------------------------------------------------ trending
def test_what_is_trending_in_a_followed_genre_joins_the_feed(client, hdr, monkeypatch):
    from muse import sources
    me = _me()
    client.put("/discover/genres/techno", headers=hdr)
    monkeypatch.setattr(linked, "_sc_api", lambda path, **params: {"collection": [
        {"id": 901, "title": "Warehouse Pressure", "duration": 420000,
         "user": {"username": "CLOUDY"}, "permalink_url": "https://soundcloud.com/cloudy/wp"},
        {"id": 902, "title": "Hora", "duration": 400000, "user": {"username": "CLOUDY"}},
    ]} if path == "/search/tracks" else {})
    monkeypatch.setattr(discover, "bandcamp_discover", lambda tag, most=6, slice_="top": [
        {"url": "https://hainbach.bandcamp.com/album/buchla-stories", "title": "Buchla Stories",
         "artist": "Hainbach"}])
    monkeypatch.setattr(sources, "bandcamp_tracks", lambda url: [
        {"provider": "bandcamp", "provider_id": "5551", "title": "Buchla One", "artists": ["Hainbach"],
         "album": "Buchla Stories", "track_no": 1, "duration_ms": 300000,
         "url": url + "#t1", "stream": "x", "streamable": True}])

    made = discover.build_trending(me)
    assert made == ["trend:techno"]
    lst = discover.one_list(me, "trend:techno")
    assert [t["title"] for t in lst["tracks"]] == ["Warehouse Pressure", "Hora", "Buchla One"]
    assert {t["source"] for t in lst["tracks"]} == {"soundcloud", "bandcamp"}
    assert all(t["discovered_via"] == "discover" for t in lst["tracks"])
    # Queued for the box itself to fetch — these two services need no machine at home.
    assert db.one("select count(*) n from jobs where kind='ingest_direct'")["n"] == 3

    cards = client.get("/discover/cards", headers=hdr).json()
    assert cards["items"][0]["why"] == "trending in techno"
    assert cards["items"][0]["list_name"] == "Trending in techno"

    # Asked once per half day; the second build reads the cache and adds nothing twice.
    monkeypatch.setattr(linked, "_sc_api", lambda *a, **k: pytest.fail("asked again"))
    discover.build_trending(me)
    assert len(discover.one_list(me, "trend:techno")["tracks"]) == 3
    assert db.one("select count(*) n from tracks where discovered_via='discover'")["n"] == 3


def test_trending_lists_are_interleaved_in_the_feed_so_no_genre_hogs_it(client, hdr, songs):
    me = _me()
    discover._save(me, "trend:techno", "Trending in techno", "", [songs[0], songs[1]], 10)
    discover._save(me, "trend:ambient", "Trending in ambient", "", [songs[2], songs[3]], 11)
    got = client.get("/discover/cards", headers=hdr).json()
    assert [c["track"]["id"] for c in got["items"]] == [songs[0], songs[2], songs[1], songs[3]]
    assert [c["why"] for c in got["items"]][:2] == ["trending in techno", "trending in ambient"]


def test_a_labels_new_record_reaches_the_radar_and_says_whose_it_is(client, hdr, monkeypatch):
    from muse import sources
    me = _me()
    monkeypatch.setattr(linked, "bandcamp_discography", lambda url, newest=40: [
        {"remote_id": "https://djseinfeld.bandcamp.com/album/if-this-is-it", "title": "If This Is It",
         "artist": "DJ Seinfeld", "cover": None, "record_type": "album"}])
    monkeypatch.setattr(linked, "bandcamp_record", lambda url: {
        "release_date": "2026-10-02", "tags": ["house"], "reviews": [], "about": None})
    monkeypatch.setattr(sources, "bandcamp_tracks", lambda url: [
        {"provider": "bandcamp", "provider_id": "8801", "title": "If This Is It", "artists": ["DJ Seinfeld"],
         "album": "If This Is It", "track_no": 1, "duration_ms": 240000, "url": url + "#1",
         "stream": "x", "streamable": True}])
    follows.follow(me, {"remote_id": "https://ninjatune.bandcamp.com", "name": "Ninja Tune",
                        "image": None, "is_label": True}, "bandcamp")

    feed = client.get("/discover/feed", headers=hdr).json()
    row = next(i for i in feed["items"] if i["title"] == "If This Is It")
    assert row["artist"] == "DJ Seinfeld" and row["via"] == "Ninja Tune", "the act, and the label it came through"
    assert row["provider"] == "bandcamp" and row["album_id"].startswith("https://djseinfeld")

    discover.build_radar(me)
    radar = discover.one_list(me, "radar")
    assert [t["title"] for t in radar["tracks"]] == ["If This Is It"]
    song = radar["tracks"][0]
    assert song["source"] == "bandcamp" and song["discovered_via"] == "discover"
    assert radar["why"][str(song["id"])] == "new on Ninja Tune"
    cards = client.get("/discover/cards", headers=hdr).json()
    assert cards["items"][0]["why"] == "new on Ninja Tune"


# ------------------------------------------------------------------ names, pages, words
def test_two_acts_with_the_same_letters_are_not_one(client, hdr):
    from muse import routes_browse
    f = routes_browse.fold
    assert f("M.O.O.N.") != f("Moon") and f("H.E.R.") != f("Her")
    assert f("(((())))") != f("¥$") and f("🍁") != f("👁"), "symbols are not nothing"
    assert f("BICEP") == f("Bicep") == f("bicep⁠") == f(" Bicep ")
    assert f('Lee "Scratch" Perry') == f("Lee 'Scratch' Perry")
    assert f("Barry Can't Swim") == f("Barry Can’t Swim")
    assert f("L.B. Dub Corp") == f("L.B.Dub Corp") and f("Honk!") == f("Honk")
    assert f("S.O.N.S") == f("S.O.N.S.") and f(".Vril") == f("Vril")
    # And the database folds the same way.
    for a, b, same in (("M.O.O.N.", "Moon", False), ("BICEP", "bicep⁠", True),
                       ("(((())))", "¥$", False), ("Honk!", "Honk", True)):
        row = db.one("select artist_key(%s) = artist_key(%s) as same", (a, b))
        assert row["same"] is same, (a, b)
        assert db.one("select artist_key(%s) as k", (a,))["k"] == f(a), a


def test_an_artists_own_words_come_from_where_their_music_came_from(client, hdr, songs, monkeypatch):
    from muse import ytm
    # A SoundCloud act: the profile's description.
    db.run("update track_sources set provider='soundcloud', provider_id='77', raw='{}' where track_id=%s",
           (songs[1],))
    monkeypatch.setattr(linked, "_sc_api", lambda path, **k: {"user": {"id": 5}} if path == "/tracks/77"
                        else {"description": "Techno from Leipzig.", "permalink_url": "https://soundcloud.com/ann"})
    monkeypatch.setattr(ytm, "search_artists", lambda q, limit=4: pytest.fail("asked YouTube first"))
    r = client.get("/library/artists/about", headers=hdr, params={"artist": "Ann"}).json()
    assert r == {"name": "Ann", "text": "Techno from Leipzig.", "source": "soundcloud",
                 "url": "https://soundcloud.com/ann"}

    # Nothing of theirs from anywhere with words: YouTube Music's blurb, by exact name.
    monkeypatch.setattr(ytm, "search_artists", lambda q, limit=4: [
        {"browse_id": "UCx", "title": "Mo", "subscribers": None, "thumbnail": None}])
    monkeypatch.setattr(ytm, "artist", lambda b: {"name": "Mo", "description": "A duo from Oslo.", "related": []})
    r = client.get("/library/artists/about", headers=hdr, params={"artist": "Mo"}).json()
    assert r["text"] == "A duo from Oslo." and r["source"] == "youtube music"

    # A Bandcamp page named outright wins over everything.
    monkeypatch.setattr(linked, "bandcamp_band_page", lambda url: {
        "url": url, "name": "Ninja Tune", "is_label": True, "image": None,
        "about": "An independent record label in London.", "roster": [], "records": []})
    r = client.get("/library/artists/about", headers=hdr,
                   params={"artist": "Ninja Tune", "bandcamp": "https://ninjatune.bandcamp.com"}).json()
    assert r["source"] == "bandcamp" and r["text"].startswith("An independent")

    # Nobody has anything to say: still an answer, and still cached.
    monkeypatch.setattr(ytm, "search_artists", lambda q, limit=4: [])
    r = client.get("/library/artists/about", headers=hdr, params={"artist": "Kay"}).json()
    assert r["text"] is None and r["source"] is None


def test_a_labels_page_has_its_acts_and_its_records(client, hdr, monkeypatch):
    monkeypatch.setattr(linked, "bandcamp_band_page", lambda url: {
        "url": "https://ninjatune.bandcamp.com", "name": "Ninja Tune", "is_label": True,
        "image": "https://f4.bcbits.com/img/1_10.jpg", "about": "Since 1990.",
        "roster": [{"name": "Bonobo", "url": "https://bonobomusic.bandcamp.com"}],
        "records": [{"remote_id": "https://bonobomusic.bandcamp.com/album/fragments", "title": "Fragments",
                     "artist": "Bonobo", "cover": None, "record_type": "album"}]})
    r = client.get("/sources/bandcamp/band", headers=hdr, params={"url": "https://ninjatune.bandcamp.com"})
    assert r.status_code == 200, r.text
    page = r.json()
    assert page["is_label"] and page["roster"][0]["name"] == "Bonobo"
    assert page["records"][0]["title"] == "Fragments" and page["following"] is False
    follows.follow(_me(), {"remote_id": "https://ninjatune.bandcamp.com", "name": "Ninja Tune",
                           "image": None, "is_label": True}, "bandcamp")
    assert client.get("/sources/bandcamp/band", headers=hdr,
                      params={"url": "https://ninjatune.bandcamp.com"}).json()["following"] is True
    # The library's artist page points at the Bandcamp page when a follow has one.
    detail = client.get("/library/artists/detail", headers=hdr, params={"artist": "Ninja Tune"}).json()
    assert detail["artist"]["bandcamp_url"] == "https://ninjatune.bandcamp.com"
