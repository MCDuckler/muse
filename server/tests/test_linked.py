"""Linking the services that need no consent screen.

A Deezer profile id, a SoundCloud username and a Bandcamp fan name are public reads, so
linking one is typing a name. What matters is that a bad name says so, and that tracks
which already know where they come from skip matching entirely.
"""
from __future__ import annotations

import json

import pytest

from muse import catalog, db, linked, routes_linked, sources


def test_only_the_three_can_be_linked(client, hdr):
    listed = client.get("/linked", headers=hdr).json()["accounts"]
    assert [a["provider"] for a in listed] == ["deezer", "soundcloud", "bandcamp"]
    assert all(a["linked"] is None for a in listed), "nothing is linked to begin with"
    assert client.post("/linked/tidal", headers=hdr, json={"handle": "x"}).status_code == 404


def test_a_name_that_is_not_a_profile_says_so(client, hdr, monkeypatch):
    def refuse(handle):
        raise linked.LinkError("Bandcamp has no fan page with that name.")

    monkeypatch.setitem(linked._PROFILE, "bandcamp", refuse)
    r = client.post("/linked/bandcamp", headers=hdr, json={"handle": "nobody"})
    assert r.status_code == 400
    assert "no fan page" in r.json()["detail"]


def test_deezer_wants_the_id_not_the_name():
    with pytest.raises(linked.LinkError) as e:
        linked._deezer_profile("chris")
    assert "numeric id" in str(e.value)


def test_a_deezer_profile_url_is_accepted(monkeypatch):
    monkeypatch.setattr(linked, "_json", lambda url, data=None: {"name": "Chris"})
    got = linked._deezer_profile("https://www.deezer.com/en/profile/2529")
    assert got == {"handle": "2529", "display_name": "Chris"}


def test_linking_sticks_and_can_be_undone(client, hdr, monkeypatch):
    monkeypatch.setitem(linked._PROFILE, "soundcloud",
                        lambda h: {"handle": h, "display_name": "Tycho"})
    made = client.post("/linked/soundcloud", headers=hdr, json={"handle": "tycho"}).json()
    assert made["handle"] == "tycho" and made["display_name"] == "Tycho"

    listed = {a["provider"]: a for a in client.get("/linked", headers=hdr).json()["accounts"]}
    assert listed["soundcloud"]["linked"]["handle"] == "tycho"

    client.delete("/linked/soundcloud", headers=hdr)
    listed = {a["provider"]: a for a in client.get("/linked", headers=hdr).json()["accounts"]}
    assert listed["soundcloud"]["linked"] is None


def test_playlists_need_a_link_first(client, hdr):
    r = client.get("/linked/deezer/playlists", headers=hdr)
    assert r.status_code == 409 and "linked" in r.json()["detail"]


def test_a_soundcloud_mirror_needs_no_matching(client, hdr, monkeypatch):
    """The list hands back the track itself. Matching exists for services that only
    tell you a title and an artist — here there is nothing to guess."""
    monkeypatch.setattr(linked, "items", lambda provider, remote_id: [
        {"remote_id": "1", "title": "Awake", "artists": ["Tycho"], "album": None,
         "duration_ms": 283_682,
         "source": {"provider": "soundcloud", "provider_id": "115300435",
                    "url": "https://api.soundcloud.com/tracks/115300435"}},
    ])

    out = routes_linked.run_mirror_job(
        {"provider": "soundcloud", "user_id": 1, "remote_id": "tycho/likes",
         "name": "tycho · Likes"})
    assert out["matched"] == 1 and out["unmatched"] == 0

    listed = client.get(f"/playlists/{out['playlist_id']}", headers=hdr).json()
    assert [t["title"] for t in listed["items"]] == ["Awake"]
    assert listed["items"][0]["source"] == "soundcloud"
    # And it went to the lane the server runs itself.
    kinds = {r["kind"] for r in db.all_(
        "select distinct kind from jobs where kind in ('ingest','ingest_direct')")}
    assert kinds == {"ingest_direct"}


def test_a_big_mirror_leaves_the_audio_until_it_is_played(client, hdr, monkeypatch):
    many = [{"remote_id": str(n), "title": f"Song {n}", "artists": ["Someone"],
             "album": None, "duration_ms": 200_000} for n in range(routes_linked.BIG_MIRROR + 1)]
    monkeypatch.setattr(linked, "items", lambda provider, remote_id: many)
    monkeypatch.setattr("muse.sync.resolve_item",
                        lambda *a, **k: {"track_id": None, "confidence": 0.0,
                                         "method": "stub", "verdict": "review"})

    out = routes_linked.run_mirror_job(
        {"provider": "deezer", "user_id": 1, "remote_id": "42", "name": "Big"})
    assert out["download_mode"] == "on_play"


def test_a_bandcamp_collection_is_albums_not_songs(monkeypatch):
    """One request per record, and the tracklist comes with it."""
    monkeypatch.setattr(linked, "_bandcamp_blob", lambda h: {"fan_data": {"fan_id": 7}})
    monkeypatch.setattr(linked, "_json", lambda url, data=None: {
        "items": [{"item_url": "https://a.bandcamp.com/album/one"}],
        "more_available": False, "last_token": "t"})
    monkeypatch.setattr(sources, "bandcamp_tracks", lambda url: [
        {"provider_id": "11", "title": "Track one", "artists": ["A band"],
         "album": "One", "duration_ms": 100_000, "url": url, "streamable": True},
        {"provider_id": "12", "title": "Only if you buy it", "artists": ["A band"],
         "album": "One", "duration_ms": 100_000, "url": url, "streamable": False},
    ])

    got = linked._bandcamp_items("someone/collection")
    assert [t["title"] for t in got] == ["Track one"], "what cannot be streamed is left out"
    assert got[0]["source"]["provider"] == "bandcamp"
