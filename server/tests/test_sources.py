"""Sources other than YouTube. What matters here is that the server can fetch them
itself — measured, and the reason the direct lane exists at all."""
from __future__ import annotations

import json
import pathlib

import pytest

from muse import sources


def test_a_url_says_which_source_it_is():
    assert sources.provider_for_url("https://tycho.bandcamp.com/album/awake") == "bandcamp"
    assert sources.provider_for_url("https://soundcloud.com/tycho/awake") == "soundcloud"
    assert sources.provider_for_url("https://music.youtube.com/watch?v=abc") == "youtube"
    assert sources.provider_for_url("https://example.com/song.mp3") is None


def test_youtube_is_not_a_direct_source():
    """It refuses datacenter IPs, so queueing it here would only fill the lane with
    failures. That is the whole reason a worker runs at home."""
    assert "youtube" not in sources.DIRECT
    with pytest.raises(sources.SourceError):
        sources.fetch("youtube", "abc", pathlib.Path("/tmp"), lambda *a, **k: None)


def _page(tracks: list[dict], artist="Tycho", album="Awake") -> str:
    blob = json.dumps({"artist": artist, "current": {"title": album},
                       "trackinfo": tracks}).replace('"', "&quot;")
    return f'<html><script data-tralbum="{blob}"></script></html>'


def test_a_bandcamp_album_is_one_request(monkeypatch):
    """The page carries the whole record — every track, its number, its length and a
    stream URL — which is why an album import needs no matching step at all."""
    tracks = [
        {"id": 1, "track_num": 1, "title": "Awake", "duration": 284.0,
         "title_link": "/track/awake", "file": {"mp3-128": "https://t4.bcbits.com/x"}},
        {"id": 2, "track_num": 2, "title": "Montana", "duration": 326.0,
         "title_link": "/track/montana", "file": {"mp3-128": "https://t4.bcbits.com/y"}},
    ]
    monkeypatch.setattr(sources, "_get_page", lambda url: _page(tracks))

    got = sources.bandcamp_tracks("https://tycho.bandcamp.com/album/awake")
    assert [t["title"] for t in got] == ["Awake", "Montana"]
    assert got[0]["album"] == "Awake" and got[0]["artists"] == ["Tycho"]
    assert got[0]["duration_ms"] == 284_000
    assert got[0]["url"] == "https://tycho.bandcamp.com/track/awake"
    assert all(t["streamable"] for t in got)


def test_a_track_you_have_to_buy_says_so(monkeypatch, tmp_path):
    """About one Bandcamp track in fifty. It should read as a fact about the record,
    not as a download that failed."""
    monkeypatch.setattr(sources, "_get_page", lambda url: _page(
        [{"id": 9, "title": "Bonus", "duration": 100.0, "file": {}}]))

    with pytest.raises(sources.SourceError) as e:
        sources.fetch("bandcamp", "https://x.bandcamp.com/track/bonus", tmp_path,
                      lambda *a, **k: None)
    assert "buy" in str(e.value)


def test_a_page_that_is_not_bandcamp_says_so(monkeypatch):
    monkeypatch.setattr(sources, "_get_page", lambda url: "<html>nope</html>")
    with pytest.raises(sources.SourceError) as e:
        sources.bandcamp_tracks("https://example.com")
    assert "does not look like" in str(e.value)


def test_soundcloud_search_reads_what_yt_dlp_returns(monkeypatch):
    payload = {"entries": [
        {"id": 115300435, "title": "Awake", "uploader": "Tycho", "duration": 283.682},
        {"id": 219779256, "title": "Awake (edit)", "uploader": "Someone", "duration": 30.0},
    ]}

    class R:
        returncode = 0
        stdout = json.dumps(payload)
        stderr = ""

    monkeypatch.setattr(sources, "_run", lambda *a, **k: R())
    got = sources.search("soundcloud", "tycho awake", limit=2)
    assert [g["provider_id"] for g in got] == ["115300435", "219779256"]
    assert got[0]["duration_ms"] == 283_682, "durations come through, so matching can " \
        "tell a track from a thirty-second preview"
    assert got[0]["artists"] == ["Tycho"]


def test_gain_is_measured_against_the_same_target_as_everything_else():
    assert sources.loudness_gain(-17.4) == 3.4
    assert sources.loudness_gain(None) is None


def test_importing_an_album_makes_a_playlist_of_it(client, hdr, monkeypatch):
    """The record arrives whole and in order, with the artist's own metadata — no
    search, no matching, nothing to get wrong."""
    tracks = [
        {"id": 1, "track_num": 1, "title": "Awake", "duration": 284.0,
         "title_link": "/track/awake", "file": {"mp3-128": "https://t4.bcbits.com/x"}},
        {"id": 2, "track_num": 2, "title": "Montana", "duration": 326.0,
         "title_link": "/track/montana", "file": {"mp3-128": "https://t4.bcbits.com/y"}},
        {"id": 3, "track_num": 3, "title": "Bought only", "duration": 10.0,
         "title_link": "/track/bought", "file": {}},
    ]
    monkeypatch.setattr(sources, "_get_page", lambda url: _page(tracks))

    r = client.post("/sources/import", headers=hdr,
                    json={"url": "https://tycho.bandcamp.com/album/awake"}).json()
    assert r["name"] == "Awake" and r["added"] == 2
    assert r["unavailable"] == 1, "the one you have to buy is reported, not queued"

    listed = client.get(f"/playlists/{r['playlist_id']}", headers=hdr).json()
    assert [i["title"] for i in listed["items"]] == ["Awake", "Montana"]
    assert listed["items"][0]["source"] == "bandcamp"


def test_an_album_that_only_sells_is_not_an_import(client, hdr, monkeypatch):
    monkeypatch.setattr(sources, "_get_page", lambda url: _page(
        [{"id": 1, "title": "Only for sale", "duration": 100.0, "file": {}}]))
    r = client.post("/sources/import", headers=hdr,
                    json={"url": "https://x.bandcamp.com/album/y"})
    assert r.status_code == 400 and "buying" in r.json()["detail"]


def test_direct_tracks_are_queued_for_the_server_not_the_laptop(client, hdr, monkeypatch):
    """The whole point of the second lane: these never reach the residential worker."""
    monkeypatch.setattr(sources, "_get_page", lambda url: _page(
        [{"id": 5, "track_num": 1, "title": "Awake", "duration": 284.0,
          "title_link": "/track/awake", "file": {"mp3-128": "https://t4.bcbits.com/x"}}]))
    client.post("/sources/import", headers=hdr,
                json={"url": "https://tycho.bandcamp.com/album/awake"})

    from muse import db
    kinds = {r["kind"] for r in db.all_(
        "select distinct kind from jobs where kind in ('ingest', 'ingest_direct')")}
    assert kinds == {"ingest_direct"}, kinds
