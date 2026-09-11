"""The list Shazam keeps in Spotify, where somebody can actually find it.

Shazam cannot be asked what has been tagged — it has no API for that — but connected
to Spotify it maintains a playlist for ever. Mirroring that playlist is the whole of
"sync my Shazams", so the only thing that needed building was a way to find it: one
account here has four hundred and fifty-six playlists and two of them are Shazam's.
"""
from __future__ import annotations

from muse import spotify


def _pages(names: list[str]):
    """Stand in for Spotify: one page of playlists and the Liked Songs count."""
    def fake(cfg, user_id, url, **params):
        if url == "/me/tracks":
            return {"total": 11993}
        return {
            "items": [
                {"id": f"id{i}", "name": name, "owner": {"display_name": "Chris"},
                 "tracks": {"total": 3}, "images": []}
                for i, name in enumerate(names)
            ],
            "next": None,
        }
    return fake


def test_shazams_come_straight_after_liked_songs(monkeypatch):
    monkeypatch.setattr(spotify, "_get", _pages(
        ["In the sun", "My Shazam Tracks", "Busfahren", "Das alte Lied"]))
    got = spotify.playlists(None, 1)

    assert got[0]["name"] == "Liked Songs"
    assert got[1]["name"] == "My Shazam Tracks", \
        "otherwise it is a needle in a haystack of four hundred"
    assert got[1]["shazam"] is True
    assert all(not p.get("shazam") for p in got[2:])


def test_it_is_found_whatever_language_spotify_named_it_in(monkeypatch):
    """Spotify names it in the account's own language — this account has both an
    English one and a German one — and the brand is the part never translated."""
    monkeypatch.setattr(spotify, "_get", _pages(
        ["Busfahren", "Meine Shazam-Titel", "Mis pistas de Shazam", "Alice"]))
    got = spotify.playlists(None, 1)

    assert [p["name"] for p in got[1:3]] == \
        ["Meine Shazam-Titel", "Mis pistas de Shazam"]
    assert all(p["shazam"] for p in got[1:3])


def test_the_rest_keep_the_order_spotify_gave_them(monkeypatch):
    """Only two things move. Somebody's own ordering of four hundred playlists is not
    ours to rearrange."""
    monkeypatch.setattr(spotify, "_get", _pages(["One", "Two", "Three"]))
    got = spotify.playlists(None, 1)
    assert [p["name"] for p in got] == ["Liked Songs", "One", "Two", "Three"]


def test_a_playlist_merely_mentioning_the_word_is_not_pretended_to_be_more(monkeypatch):
    """It is flagged, and flagged is all: the row says what it is and mirroring it is
    the same manual thing as any other. Nothing here decides on somebody's behalf."""
    monkeypatch.setattr(spotify, "_get", _pages(["shazam party 2019"]))
    got = spotify.playlists(None, 1)
    assert got[1]["shazam"] is True
    assert got[1]["remote_id"] == "id0", "still just a playlist you can mirror"
