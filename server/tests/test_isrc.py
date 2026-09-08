"""An ISRC names a recording, not a spelling. That is what it is for here: recognising a
song that has already arrived under a different name, from a different service."""
from __future__ import annotations

import pytest

from muse import catalog, db, enrich, sync


@pytest.fixture()
def existing(client, hdr):
    """A track already in the library, with an ISRC on it."""
    t = client.post("/tracks/resolve", headers=hdr, json={"video_id": "HAVEIT"}).json()
    db.run("update tracks set isrc='GBUM71505902' where id=%s", (t["id"],))
    return t


def test_the_same_recording_is_not_downloaded_twice(client, hdr, existing, monkeypatch):
    """Arriving from another service, under another spelling, with no video id — the
    ISRC is enough to say it is the same recording."""
    def never(*a, **k):
        raise AssertionError("an ISRC we hold must not send us searching")

    monkeypatch.setattr(sync.ytm, "search_songs", never)

    out = sync.resolve_item("deezer", {
        "remote_id": "dz1", "title": "Hey Jude (Remastered 2015)",
        "artists": ["The Beatles"], "duration_ms": 429_000,
        "isrc": "GBUM71505902"})
    assert out["track_id"] == existing["id"]
    assert out["method"] == "isrc" and out["confidence"] == 1.0
    assert db.one("select count(*) n from tracks")["n"] == 1, "and no second row"


def test_case_and_spacing_do_not_hide_a_match(client, hdr, existing):
    out = sync.resolve_item("deezer", {"remote_id": "dz2", "title": "x",
                                       "artists": ["y"], "isrc": " gbum71505902 "})
    assert out["track_id"] == existing["id"]


def test_an_isrc_we_do_not_have_falls_through_to_matching(client, hdr, existing):
    """It is a shortcut, not a gate: an unknown ISRC just means the usual search."""
    out = sync.resolve_item("deezer", {"remote_id": "dz3", "title": "Test Song",
                                       "artists": ["Tester"], "duration_ms": 123_000,
                                       "isrc": "ZZZZZ0000001"})
    assert out["method"] != "isrc"


def test_a_match_made_the_hard_way_remembers_the_isrc(client, hdr):
    """So the next service to offer this recording is recognised without searching."""
    out = sync.resolve_item("spotify", {"remote_id": "sp1", "title": "Test Song",
                                        "artists": ["Tester"], "duration_ms": 123_000,
                                        "isrc": "NEWISRC00001"})
    assert out["track_id"]
    assert db.one("select isrc from tracks where id=%s",
                  (out["track_id"],))["isrc"] == "NEWISRC00001"


def test_a_track_with_no_isrc_is_never_matched_to_one(client, hdr, existing):
    assert catalog.find_by_isrc(None) is None
    assert catalog.find_by_isrc("") is None


def test_enrichment_fetches_the_isrc_deezer_search_leaves_out(monkeypatch):
    """Deezer's search payload has no ISRC; the track behind it does. That one extra
    request is what fills the library in over time."""
    calls = []

    class R:
        status_code = 200
        def raise_for_status(self): pass
        def json(self): return {"isrc": "gbum71505902"}

    monkeypatch.setattr(enrich.httpx, "get",
                        lambda url, **k: calls.append(url) or R())
    assert enrich.deezer_isrc(3135556) == "GBUM71505902"
    assert calls == ["https://api.deezer.com/track/3135556"]


def test_a_deezer_hiccup_is_not_an_enrichment_failure(monkeypatch):
    import httpx as real_httpx

    def boom(*a, **k):
        raise real_httpx.ConnectError("no")

    monkeypatch.setattr(enrich.httpx, "get", boom)
    assert enrich.deezer_isrc(1) is None
