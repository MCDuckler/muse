"""Sync is one-way and the matcher's mistakes must be visible, not silent."""
from __future__ import annotations

import pytest

from muse import routes_sync, sync, ytm


class FakeSpotify:
    """Stands in for Spotify: no video ids, so every item has to be matched."""

    kind = "spotify"

    def __init__(self, items):
        self._items = items

    def list_playlists(self):
        return [sync.RemotePlaylist("SPL1", "Roadtrip", len(self._items))]

    def playlist_items(self, remote_id):
        return list(self._items)


EXACT = {"remote_id": "sp1", "title": "Test Song", "artists": ["Tester"],
         "album": "Test Album", "duration_ms": 123_000, "isrc": None}
WRONG_LENGTH = {"remote_id": "sp2", "title": "Test Song", "artists": ["Tester"],
                "album": "Test Album", "duration_ms": 400_000, "isrc": None}
UNKNOWN = {"remote_id": "sp3", "title": "Something Nobody Has", "artists": ["Ghost"],
           "album": None, "duration_ms": 200_000, "isrc": None}


@pytest.fixture()
def fake(client, monkeypatch):
    """ytm.search_songs answers with one plausible candidate per query."""
    def _search(q, limit=10):
        if "ghost" in q.lower():
            return []
        return [{"video_id": "TESTVIDEO001", "title": "Test Song", "artists": ["Tester"],
                 "album": "Test Album", "duration_ms": 123_000, "raw": {}}]

    monkeypatch.setattr(ytm, "search_songs", _search)

    def _install(items):
        routes_sync._ADAPTERS["spotify"] = FakeSpotify(items)
        return routes_sync._ADAPTERS["spotify"]

    yield _install
    routes_sync._ADAPTERS.clear()


def test_unconfigured_provider_is_501_not_500(client, hdr):
    r = client.get("/sync/spotify/playlists", headers=hdr)
    assert r.status_code == 501
    assert "refresh_token" in r.json()["detail"]
    prov = {p["kind"]: p["configured"] for p in client.get("/sync/providers", headers=hdr).json()}
    assert prov == {"spotify": False, "ytmusic": False}


def test_import_matches_and_flags(client, hdr, fake):
    fake([EXACT, WRONG_LENGTH, UNKNOWN])
    r = client.post("/sync/spotify/import", headers=hdr, json={"remote_id": "SPL1"}).json()
    assert r["items"] == 3
    assert r["matched"] == 1                    # only the exact one is committed
    review_ids = {x["remote_id"] for x in r["needs_review"]}
    assert review_ids == {"sp2", "sp3"}         # wrong length and no candidate at all

    pl = client.get(f"/playlists/{r['playlist_id']}", headers=hdr).json()
    assert pl["kind"] == "spotify" and pl["sync_mode"] == "pull"
    assert len(pl["items"]) == 1


def test_review_queue_surfaces_unmatched(client, hdr, fake):
    fake([EXACT, WRONG_LENGTH, UNKNOWN])
    client.post("/sync/spotify/import", headers=hdr, json={"remote_id": "SPL1"})
    review = client.get("/sync/review", headers=hdr).json()
    assert {r["remote_id"] for r in review} == {"sp2", "sp3"}
    assert all(r["track_id"] is None for r in review)
    # the screen can actually name what it is asking about
    assert {r["remote_title"] for r in review} == {"Test Song", "Something Nobody Has"}
    assert all(r["remote_artists"] for r in review)


def test_manual_override_sticks_across_a_resync(client, hdr, fake):
    fake([EXACT, WRONG_LENGTH, UNKNOWN])
    first = client.post("/sync/spotify/import", headers=hdr, json={"remote_id": "SPL1"}).json()
    good = client.get(f"/playlists/{first['playlist_id']}", headers=hdr).json()["items"][0]

    decided = client.post("/sync/review/spotify/sp2", headers=hdr,
                          json={"track_id": good["id"]}).json()
    assert decided["decided_by"] == "human" and decided["track_id"] == good["id"]

    again = client.post(f"/sync/playlists/{first['playlist_id']}/pull", headers=hdr).json()
    assert again["matched"] == 2                 # the override is honoured
    assert {x["remote_id"] for x in again["needs_review"]} == {"sp3"}

    still = client.get("/sync/review", headers=hdr).json()
    assert "sp2" not in {r["remote_id"] for r in still}   # a human decided; never re-asked


def test_pull_refuses_a_local_playlist(client, hdr):
    p = client.post("/playlists", headers=hdr, json={"name": "Mine"}).json()
    assert client.post(f"/sync/playlists/{p['id']}/pull", headers=hdr).status_code == 400


def test_ytmusic_items_match_exactly_by_video_id(client, hdr):
    """Audio comes from YouTube Music, so its own playlists need no scoring at all."""
    r = sync.resolve_item("ytmusic", {"remote_id": "vid9", "video_id": "vid9",
                                      "title": "Whatever", "artists": ["Someone"],
                                      "album": None, "duration_ms": 1000})
    assert r["method"] == "video-id" and r["confidence"] == 1.0 and r["track_id"]


def test_resync_does_not_duplicate_tracks(client, hdr, fake):
    fake([EXACT])
    a = client.post("/sync/spotify/import", headers=hdr, json={"remote_id": "SPL1"}).json()
    b = client.post(f"/sync/playlists/{a['playlist_id']}/pull", headers=hdr).json()
    pl = client.get(f"/playlists/{a['playlist_id']}", headers=hdr).json()
    assert b["matched"] == 1 and len(pl["items"]) == 1
