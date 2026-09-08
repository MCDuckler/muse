"""Liked Songs. Not a playlist as far as Spotify is concerned, and the list most people
mean when they say "my music"."""
from __future__ import annotations

import pytest

from muse import spotify


@pytest.fixture()
def api(monkeypatch):
    """Stands in for Spotify's HTTP surface, paging included."""
    calls: list[tuple[str, dict]] = []
    pages = {
        "/me/tracks": {
            "total": 412,
            "items": [{"track": {"id": "t1", "name": "First", "duration_ms": 1000,
                                 "artists": [{"name": "Someone"}],
                                 "album": {"name": "An album"},
                                 "external_ids": {"isrc": "GBUM71505902"}}}],
            "next": "https://api.spotify.com/v1/me/tracks?offset=50",
        },
        "https://api.spotify.com/v1/me/tracks?offset=50": {
            "items": [{"track": {"id": "t2", "name": "Second", "duration_ms": 2000,
                                 "artists": [{"name": "Someone else"}],
                                 "album": {"name": "Another"}}},
                      {"track": None}],                    # removed tracks come back null
            "next": None,
        },
        "/me/playlists": {"items": [{"id": "PL1", "name": "Roadtrip",
                                     "tracks": {"total": 12},
                                     "owner": {"display_name": "chris"}}],
                          "next": None},
    }

    def fake_get(cfg, user_id, url, **params):
        calls.append((url, params))
        return pages[url]

    monkeypatch.setattr(spotify, "_get", fake_get)
    return calls


def test_liked_songs_leads_the_list(api):
    listed = spotify.playlists(None, 1)
    assert listed[0]["remote_id"] == spotify.LIKED
    assert listed[0]["name"] == "Liked Songs"
    assert listed[0]["count"] == 412, "the count comes from the total, not from paging it"
    assert [p["name"] for p in listed[1:]] == ["Roadtrip"]
    # Asking for the count must not download the library.
    assert ("/me/tracks", {"limit": 1}) in api


def test_liked_songs_read_like_any_other_playlist(api):
    items = spotify.playlist_items(None, 1, spotify.LIKED)
    assert [i["title"] for i in items] == ["First", "Second"], "and it pages"
    assert items[0]["isrc"] == "GBUM71505902"
    assert items[0]["artists"] == ["Someone"]


def test_a_removed_track_does_not_become_an_empty_row(api):
    items = spotify.playlist_items(None, 1, spotify.LIKED)
    assert all(i["title"] for i in items)


def test_a_rate_limit_is_waited_out_not_failed(monkeypatch):
    """Twelve thousand liked songs is 240 pages, and Spotify says no partway through.
    It tells us how long to wait; the only mistake would be not listening."""
    from muse import spotify

    class Response:
        def __init__(self, status, body=None, retry_after=None):
            self.status_code = status
            self._body = body or {}
            self.headers = {"Retry-After": str(retry_after)} if retry_after else {}

        def json(self):
            return self._body

        def raise_for_status(self):
            pass

    answers = [Response(429, retry_after=1), Response(200, {"items": [], "next": None})]
    waited: list[float] = []
    monkeypatch.setattr(spotify.httpx, "get", lambda *a, **k: answers.pop(0))
    monkeypatch.setattr(spotify.time, "sleep", waited.append)
    monkeypatch.setattr(spotify, "access_token", lambda cfg, uid: "tok")

    assert spotify._get(None, 1, "/me/tracks") == {"items": [], "next": None}
    assert waited == [1.0], "and it waits exactly as long as it was asked to"


def test_giving_up_on_a_rate_limit_says_it_will_resume(monkeypatch):
    from muse import spotify

    class Busy:
        status_code = 429
        headers = {"Retry-After": "1"}

    monkeypatch.setattr(spotify.httpx, "get", lambda *a, **k: Busy())
    monkeypatch.setattr(spotify.time, "sleep", lambda s: None)
    monkeypatch.setattr(spotify, "access_token", lambda cfg, uid: "tok")

    with pytest.raises(spotify.SpotifyBusy) as e:
        spotify._get(None, 1, "/me/tracks")
    assert "pick up where it left off" in str(e.value)
