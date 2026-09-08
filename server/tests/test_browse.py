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
