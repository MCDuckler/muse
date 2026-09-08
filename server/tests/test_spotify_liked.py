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
