"""Lists elsewhere: public SoundCloud sets, YouTube Music playlists and Bandcamp records
found by a search, opened before anything is added, and taken whole as a mirror.

Nothing here reaches the real services: each leg's own call is replaced.
"""
from __future__ import annotations

import io
import json

import pytest

from muse import catalog, db, linked, search, sources, ytm


@pytest.fixture(autouse=True)
def quiet_elsewhere(monkeypatch):
    """Only the legs a test turns on answer; the rest find nothing."""
    monkeypatch.setattr(ytm, "search_videos", lambda q, limit=10: [])
    monkeypatch.setattr(ytm, "search_songs", lambda q, limit=10: [])
    monkeypatch.setattr(ytm, "search_albums", lambda q, limit=6: [])
    monkeypatch.setattr(ytm, "search_artists", lambda q, limit=4: [])
    monkeypatch.setattr(ytm, "search_playlists", lambda q, limit=6: [])
    monkeypatch.setattr(sources, "search", lambda p, q, limit=8: [])
    monkeypatch.setattr(linked, "_sc_api", lambda path, **kw: {"collection": []})
    monkeypatch.setattr(search, "_bc_albums", lambda q, limit: [])


def test_public_lists_are_found_with_where_they_are(client, hdr, monkeypatch):
    monkeypatch.setattr(linked, "_sc_api", lambda path, **kw: {"collection": [{
        "title": "Hard techno mix", "track_count": 38, "is_album": False,
        "permalink_url": "https://soundcloud.com/someone/sets/hard-techno-mix",
        "artwork_url": "https://i1.sndcdn.com/artworks-x-large.jpg",
        "user": {"username": "someone"}}]} if path == "/search/playlists" else {})
    monkeypatch.setattr(ytm, "search_playlists", lambda q, limit=6: [{
        "playlist_id": "PLabc", "title": "Techno Bunker", "author": "YouTube Music",
        "count": 50, "thumbnail": None}])
    items = client.get("/search/everything", headers=hdr,
                       params={"q": "techno", "kind": "playlist"}).json()["items"]
    by = {(i["place"], i["kind"]): i for i in items}
    sc = by[("soundcloud", "playlist")]
    assert sc["id"] == "someone/sets/hard-techno-mix" and sc["tracks"] == 38
    assert sc["subtitle"] == "someone" and "t300x300" in sc["cover_url"]
    yt = by[("ytmusic", "playlist")]
    assert yt["id"] == "PLabc" and yt["url"].endswith("list=PLabc")


def test_bandcamp_records_come_from_its_album_search(client, hdr, monkeypatch):
    monkeypatch.undo()
    monkeypatch.setattr(ytm, "search_playlists", lambda q, limit=6: [])
    monkeypatch.setattr(linked, "_sc_api", lambda path, **kw: {"collection": []})
    answer = {"auto": {"results": [
        {"type": "b", "name": "A band", "item_url_root": "https://x.bandcamp.com"},
        {"type": "a", "name": "Boiler Room Moscow", "band_name": "Octave One",
         "item_url_path": "https://octaveone.bandcamp.com/album/boiler-room-moscow",
         "img": "https://f4.bcbits.com/img/1_3.jpg"}]}}
    monkeypatch.setattr(search.urllib.request, "urlopen",
                        lambda req, timeout=20: io.BytesIO(json.dumps(answer).encode()))
    rows = search._bc_albums("boiler room", 5)
    assert [r["title"] for r in rows] == ["Boiler Room Moscow"]
    assert rows[0]["id"] == rows[0]["url"] and rows[0]["kind"] == "album"
    assert rows[0]["subtitle"] == "Octave One"


def test_a_soundcloud_set_opens_to_its_songs(client, hdr, monkeypatch):
    monkeypatch.setattr(linked, "_soundcloud_items", lambda remote, limit=200: [{
        "remote_id": "111", "title": "Track one", "artists": ["dj"], "album": None,
        "duration_ms": 200_000,
        "source": {"provider": "soundcloud", "provider_id": "111",
                   "url": "https://api.soundcloud.com/tracks/111"}}])
    got = client.get("/search/album", headers=hdr, params={
        "place": "soundcloud", "id": "someone/sets/hard-techno-mix",
        "kind": "playlist"}).json()
    assert got["title"] == "hard techno mix"
    assert got["tracks"][0] == {
        "kind": "song", "place": "soundcloud", "id": "111", "title": "Track one",
        "subtitle": "dj", "album": None, "duration_ms": 200_000,
        "url": "https://api.soundcloud.com/tracks/111", "track": None, "known": False}


def test_a_bandcamp_record_opens_and_says_what_needs_buying(client, hdr, monkeypatch):
    url = "https://octaveone.bandcamp.com/album/boiler-room-moscow"
    monkeypatch.setattr(sources, "bandcamp_tracks", lambda u: [
        {"provider": "bandcamp", "provider_id": "1", "title": "Blackwater",
         "artists": ["Octave One"], "album": "Boiler Room Moscow", "duration_ms": 1000,
         "url": url + "#1", "stream": "s", "streamable": True},
        {"provider": "bandcamp", "provider_id": "2", "title": "Locked",
         "artists": ["Octave One"], "album": "Boiler Room Moscow", "duration_ms": 1000,
         "url": url + "#2", "stream": None, "streamable": False}])
    got = client.get("/search/album", headers=hdr,
                     params={"place": "bandcamp", "id": url}).json()
    assert got["title"] == "Boiler Room Moscow" and got["artist"] == "Octave One"
    assert "unavailable" not in got["tracks"][0]
    assert got["tracks"][1]["unavailable"] == "only if bought"


def test_a_youtube_music_playlist_opens_and_knows_what_is_here(client, hdr, monkeypatch):
    here = catalog.create_from_ytm({"video_id": "AAAAAAAAAAA", "title": "Here",
                                    "artists": ["x"], "album": None,
                                    "duration_ms": 1000, "raw": {}})
    assert here
    monkeypatch.setattr(ytm, "playlist_tracks", lambda pid, auth=None, limit=2000: [
        {"video_id": "AAAAAAAAAAA", "title": "Here", "artists": ["x"], "album": None,
         "duration_ms": 1000},
        {"video_id": "BBBBBBBBBBB", "title": "New", "artists": ["y"], "album": None,
         "duration_ms": 1000}])
    monkeypatch.setattr(ytm, "playlist_name", lambda pid, auth=None: "Techno Bunker")
    got = client.get("/search/album", headers=hdr,
                     params={"place": "ytmusic", "id": "PLabc", "kind": "playlist"}).json()
    assert got["title"] == "Techno Bunker"
    assert [t["known"] for t in got["tracks"]] == [True, False]


@pytest.mark.parametrize("body,provider,remote", [
    ({"place": "soundcloud", "id": "someone/sets/mix", "title": "Mix"},
     "soundcloud", "someone/sets/mix"),
    ({"place": "bandcamp", "id": "https://a.bandcamp.com/album/b", "kind": "album"},
     "bandcamp", "https://a.bandcamp.com/album/b"),
    ({"place": "ytmusic", "id": "VLPLabc", "kind": "playlist"}, "youtube", "PLabc"),
])
def test_a_list_is_taken_whole_as_a_mirror(client, hdr, body, provider, remote):
    r = client.post("/search/take", headers=hdr, json=body)
    assert r.status_code == 200, r.text
    assert r.json()["provider"] == provider and r.json()["remote_id"] == remote
    job = db.one("select payload from jobs where kind='mirror' "
                 "order by id desc limit 1")["payload"]
    assert job["provider"] == provider and job["remote_id"] == remote


def test_a_youtube_music_record_is_taken_by_its_playlist(client, hdr, monkeypatch):
    monkeypatch.setattr(ytm, "album_tracks", lambda b: {
        "title": "Record", "tracks": [], "playlist_id": "OLAK5uy_x"})
    r = client.post("/search/take", headers=hdr,
                    json={"place": "ytmusic", "id": "MPREb_x", "kind": "album"}).json()
    assert r["remote_id"] == "OLAK5uy_x" and r["name"] == "Record"


def test_not_a_bandcamp_address_is_refused(client, hdr):
    r = client.post("/search/take", headers=hdr,
                    json={"place": "bandcamp", "id": "https://evil.example/album/x"})
    assert r.status_code == 400


def test_a_bandcamp_record_mirrors_its_streamable_tracks(monkeypatch):
    monkeypatch.setattr(sources, "bandcamp_tracks", lambda u: [
        {"provider_id": "1", "title": "A", "artists": ["x"], "album": "R",
         "duration_ms": 1, "url": u + "#1", "streamable": True},
        {"provider_id": "2", "title": "B", "artists": ["x"], "album": "R",
         "duration_ms": 1, "url": u + "#2", "streamable": False}])
    items, more = linked.items("bandcamp", "https://a.bandcamp.com/album/r")
    assert more is None and [i["remote_id"] for i in items] == ["1"]
    assert items[0]["source"]["provider"] == "bandcamp"
