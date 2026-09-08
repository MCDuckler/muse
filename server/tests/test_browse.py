"""Browsing the library. Albums and artists are derived from track metadata, so the
edge cases are about grouping, not storage."""
from __future__ import annotations

import pytest

from muse import db


@pytest.fixture()
def library(client, hdr, wsec, complete_job):
    """A small library with shared albums, shared names and a featured artist."""
    made = []
    for n, (title, artists, album, year) in enumerate([
        ("Alpha", ["Bowie"], "Low", 1977),
        ("Beta", ["Bowie"], "Low", 1977),
        ("Gamma", ["Bowie", "Eno"], "Heroes", 1977),
        ("Delta", ["Other Band"], "Low", 2001),          # same album name, different act
        ("Epsilon", ["Eno"], None, None),                # no album at all
    ]):
        t = client.post("/tracks/resolve", headers=hdr,
                        json={"video_id": f"VID{n}"}).json()
        job = client.post("/internal/jobs/lease", headers=wsec,
                          json={"worker": "w"}).json()["jobs"][0]
        complete_job(job["id"], t["id"])
        db.run(
            "update tracks set title=%s, artists=%s, album=%s, release_year=%s where id=%s",
            (title, artists, album, year, t["id"]),
        )
        made.append(t["id"])
    return made


def test_all_tracks_can_finally_be_listed(client, hdr, library):
    r = client.get("/library/tracks", headers=hdr).json()
    assert r["total"] >= 5
    titles = [t["title"] for t in r["items"]]
    assert "Alpha" in titles and "Epsilon" in titles


@pytest.mark.parametrize("sort,first_key", [
    ("title", lambda t: t["title"]),
    ("artist", lambda t: (t["artists"] or [""])[0]),
    ("album", lambda t: t["album"] or ""),
])
def test_sorting(client, hdr, library, sort, first_key):
    items = client.get("/library/tracks", headers=hdr,
                       params={"sort": sort}).json()["items"]
    keys = [first_key(t).lower() for t in items]
    assert keys == sorted(keys), f"{sort} is not ordered"


def test_an_unknown_sort_is_refused_rather_than_ignored(client, hdr):
    assert client.get("/library/tracks", headers=hdr,
                      params={"sort": "vibes"}).status_code == 400


def test_albums_group_by_album_and_artist(client, hdr, library):
    """Two records can share a title; merging them would be a worse lie than two rows."""
    albums = client.get("/library/albums", headers=hdr).json()["items"]
    lows = [a for a in albums if a["name"] == "Low"]
    assert len(lows) == 2, "same album name, different artists, two entries"
    bowie_low = next(a for a in lows if a["artist"] == "Bowie")
    assert bowie_low["tracks"] == 2 and bowie_low["year"] == 1977

    # A track with no album is not an album called "None".
    assert all(a["name"] for a in albums)


def test_album_tracks_can_be_narrowed_by_artist(client, hdr, library):
    both = client.get("/library/albums/tracks", headers=hdr,
                      params={"album": "Low"}).json()["items"]
    just_bowie = client.get("/library/albums/tracks", headers=hdr,
                            params={"album": "Low", "artist": "Bowie"}).json()["items"]
    assert len(both) == 3 and len(just_bowie) == 2


def test_artists_count_every_credit_not_just_the_first(client, hdr, library):
    """A feature is still an appearance: Eno is credited on Gamma and Epsilon."""
    artists = {a["name"]: a for a in client.get("/library/artists", headers=hdr).json()["items"]}
    assert artists["Bowie"]["tracks"] == 3
    assert artists["Eno"]["tracks"] == 2
    assert artists["Bowie"]["albums"] == 2


def test_artist_tracks_include_features(client, hdr, library):
    items = client.get("/library/artists/tracks", headers=hdr,
                       params={"artist": "Eno"}).json()["items"]
    assert {t["title"] for t in items} == {"Gamma", "Epsilon"}


def test_history_carries_timestamps_and_can_be_cleared(client, hdr, library):
    client.post("/listens", headers=hdr,
                json={"track_id": library[0], "ms_played": 30_000, "completed": True})
    hist = client.get("/library/history", headers=hdr).json()["items"]
    assert hist and hist[0]["played_at"], "a history with no when is not a history"
    assert hist[0]["ms_played"] == 30_000

    client.delete("/library/history", headers=hdr)
    assert client.get("/library/history", headers=hdr).json()["items"] == []


# ---------------- playlists ----------------
def test_a_playlist_can_be_renamed(client, hdr):
    p = client.post("/playlists", headers=hdr, json={"name": "Untitled"}).json()
    renamed = client.patch(f"/playlists/{p['id']}", headers=hdr,
                           json={"name": "Sunday"}).json()
    assert renamed["name"] == "Sunday"
    assert client.patch(f"/playlists/{p['id']}", headers=hdr,
                        json={"name": "  "}).status_code == 400


def test_a_playlist_can_be_reordered(client, hdr, library):
    p = client.post("/playlists", headers=hdr, json={"name": "Mix"}).json()
    client.post(f"/playlists/{p['id']}/items", headers=hdr,
                json={"track_ids": library[:3]})
    moved = client.post(f"/playlists/{p['id']}/move", headers=hdr,
                        json={"from": 0, "to": 2}).json()
    assert [i["id"] for i in moved["items"]] == [library[1], library[2], library[0]]
    assert [i["pos"] for i in moved["items"]] == [0, 1, 2]
    assert client.post(f"/playlists/{p['id']}/move", headers=hdr,
                       json={"from": 0, "to": 9}).status_code == 400


# ---------------- mirrored playlists ----------------
@pytest.fixture()
def mirrored(client, hdr, library):
    """A playlist that mirrors Spotify, made directly: linking a real account needs an
    app registration, and the rules below hold regardless of how the row got there."""
    pid = db.one(
        """insert into playlists(owner_id, name, kind, remote_id, sync_mode, source_name)
           values((select id from users limit 1), 'From Spotify', 'spotify', 'SP1',
                  'pull', 'someone') returning id"""
    )["id"]
    db.run("insert into playlist_items(playlist_id,pos,track_id) values(%s,0,%s)",
           (pid, library[0]))
    db.run("""insert into playlist_unmatched(playlist_id,pos,remote_id,title,artists,reason)
              values(%s,1,'sp-x','Missing Song',%s,'Nothing on YouTube Music matched this song')""",
           (pid, ["Someone"]))
    return pid


def test_a_mirrored_playlist_is_listed_with_its_source(client, hdr, mirrored):
    rows = client.get("/playlists", headers=hdr).json()
    mine = next(r for r in rows if r["id"] == mirrored)
    assert mine["kind"] == "spotify"
    assert mine["source_name"] == "someone"
    assert mine["unmatched"] == 1, "the app must be able to say what is missing"


def test_a_mirrored_playlist_is_playable_but_not_editable(client, hdr, mirrored,
                                                          library):
    full = client.get(f"/playlists/{mirrored}", headers=hdr).json()
    assert full["editable"] is False
    assert len(full["items"]) == 1, "what did match is there to play"

    # every edit route refuses, and says what to do instead
    assert client.post(f"/playlists/{mirrored}/items", headers=hdr,
                       json={"track_ids": [library[1]]}).status_code == 409
    assert client.patch(f"/playlists/{mirrored}", headers=hdr,
                        json={"name": "Mine now"}).status_code == 409
    assert client.delete(f"/playlists/{mirrored}/items/0", headers=hdr).status_code == 409
    r = client.post(f"/playlists/{mirrored}/move", headers=hdr,
                    json={"from": 0, "to": 0})
    assert r.status_code == 409 and "copy" in r.json()["detail"].lower()


def test_the_songs_that_could_not_be_translated_are_listed(client, hdr, mirrored):
    items = client.get(f"/spotify/playlists/{mirrored}/unmatched",
                       headers=hdr).json()["items"]
    assert len(items) == 1
    assert items[0]["title"] == "Missing Song"
    assert "matched" in items[0]["reason"], "a reason in words, not a score"


def test_cloning_makes_an_ordinary_editable_playlist(client, hdr, mirrored, library):
    copy = client.post(f"/spotify/playlists/{mirrored}/clone", headers=hdr,
                       json={"name": "My version"}).json()
    assert copy["kind"] == "local" and copy["name"] == "My version"
    assert [i["id"] for i in copy["items"]] == [library[0]]

    # and the copy really is editable
    assert client.post(f"/playlists/{copy['id']}/items", headers=hdr,
                       json={"track_ids": [library[1]]}).status_code == 200
    # while the original is untouched
    assert len(client.get(f"/playlists/{mirrored}", headers=hdr).json()["items"]) == 1


def test_an_unmatched_song_can_be_resolved_by_hand(client, hdr, mirrored, library):
    r = client.post(f"/spotify/playlists/{mirrored}/unmatched/1/resolve", headers=hdr,
                    json={"track_id": library[2]})
    assert r.status_code == 200

    full = client.get(f"/playlists/{mirrored}", headers=hdr).json()
    assert library[2] in [i["id"] for i in full["items"]]
    assert full["unmatched"] == 0
    assert client.get(f"/spotify/playlists/{mirrored}/unmatched",
                      headers=hdr).json()["items"] == []


def test_spotify_says_what_is_missing_when_it_is_not_configured(client, hdr):
    r = client.get("/spotify/account", headers=hdr).json()
    assert r["configured"] is False
    assert "developer.spotify.com" in r["reason"], "tell the operator what to do"
    assert client.get("/spotify/authorize", headers=hdr).status_code == 501


def test_syncing_nothing_specific_refreshes_only_what_is_mirrored(client, hdr,
                                                                  mirrored,
                                                                  monkeypatch):
    """An account can hold hundreds of playlists — this user's has 460. Mirroring all
    of them would be thousands of lookups and almost none of it wanted."""
    from muse import routes_spotify, spotify

    listed = [
        {"remote_id": "SP1", "name": "From Spotify", "count": None, "owner": "someone"},
        {"remote_id": "SP2", "name": "Not chosen", "count": None, "owner": "someone"},
    ]
    monkeypatch.setattr(spotify, "playlists", lambda cfg, uid: listed)
    touched = []
    monkeypatch.setattr(routes_spotify, "_mirror",
                        lambda uid, p: touched.append(p["remote_id"]) or {"name": p["name"]})

    client.post("/spotify/sync", headers=hdr, json={})
    assert touched == ["SP1"], "only the playlist already mirrored gets refreshed"

    touched.clear()
    client.post("/spotify/sync", headers=hdr, json={"remote_id": "SP2"})
    assert touched == ["SP2"], "and an explicit choice is honoured"


def test_remote_playlists_say_which_are_mirrored(client, hdr, mirrored, monkeypatch):
    from muse import spotify

    monkeypatch.setattr(spotify, "playlists", lambda cfg, uid: [
        {"remote_id": "SP1", "name": "From Spotify", "count": None, "owner": "someone"},
        {"remote_id": "SP2", "name": "Not chosen", "count": None, "owner": "someone"},
    ])
    items = client.get("/spotify/playlists", headers=hdr).json()["items"]
    by_id = {i["remote_id"]: i for i in items}
    assert by_id["SP1"]["mirror"]["playlist_id"] == mirrored
    assert by_id["SP1"]["mirror"]["unmatched"] == 1
    assert by_id["SP2"]["mirror"] is None
