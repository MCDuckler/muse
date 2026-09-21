"""Scrobbling: what is played here, written into a listening diary kept elsewhere.

Nothing here reaches ListenBrainz: the one function that talks to it is replaced, and
what is checked is what would have been said — and that the diary being down, or
refusing, never gets in the way of the listen itself being recorded.
"""
from __future__ import annotations

import httpx
import pytest

from muse import catalog, db, scrobble


class Said:
    """Stands in for the service, and remembers what it was told."""

    def __init__(self):
        self.calls: list[tuple[str, str, str, dict | None]] = []
        self.status = 200
        self.down = False

    def __call__(self, method, path, token, json=None):
        self.calls.append((method, path, token, json))
        if self.down:
            raise httpx.ConnectError("no route")
        body = ({"valid": token == "good-token", "user_name": "chris_lb"}
                if path.endswith("validate-token") else {"status": "ok"})
        return httpx.Response(self.status, json=body)

    @property
    def submitted(self):
        return [c[3] for c in self.calls if c[1].endswith("submit-listens")]


@pytest.fixture()
def lb(monkeypatch):
    said = Said()
    monkeypatch.setattr(scrobble, "_call", said)
    # In the request's own thread, so a test can look straight afterwards.
    monkeypatch.setattr(scrobble.threading, "Thread",
                        lambda target, args, daemon: type("T", (), {
                            "start": staticmethod(lambda: target(*args))})())
    return said


@pytest.fixture()
def song():
    return catalog.create_from_ytm({
        "video_id": "VSCR1", "title": "Low Water", "artists": ["Low Tide Radio", "A Guest"],
        "album": "Salt on the Window", "duration_ms": 200_000, "raw": {},
    }, discovered_via=catalog.VIA_USER, download=False)


def test_the_rule_for_what_counts():
    assert scrobble.counts(10_000, 200_000, True), "played to the end"
    assert scrobble.counts(100_000, 200_000, False), "half of it"
    assert scrobble.counts(240_000, 3_600_000, False), "four minutes of an hour-long set"
    assert not scrobble.counts(60_000, 200_000, False)
    assert not scrobble.counts(60_000, None, False), "no length known: only the end counts"


def test_a_token_is_checked_before_it_is_kept_and_never_handed_back(client, hdr, lb):
    bad = client.put("/scrobbling/listenbrainz", headers=hdr, json={"token": "nonsense"})
    assert bad.status_code == 400
    assert client.get("/scrobbling", headers=hdr).json()["listenbrainz"]["connected"] is False

    ok = client.put("/scrobbling/listenbrainz", headers=hdr, json={"token": "good-token"})
    assert ok.status_code == 200, ok.text
    standing = ok.json()["listenbrainz"]
    assert standing["connected"] is True and standing["name"] == "chris_lb"
    assert "good-token" not in ok.text, "the token stays on the server"


def test_a_play_that_counts_is_written_in_the_diary(client, hdr, lb, song):
    client.put("/scrobbling/listenbrainz", headers=hdr, json={"token": "good-token"})

    # A glance is not a listen.
    client.post("/listens", headers=hdr,
                json={"track_id": song["id"], "ms_played": 8_000, "completed": False})
    assert lb.submitted == []

    done = client.post("/listens", headers=hdr,
                       json={"track_id": song["id"], "ms_played": 199_000, "completed": True})
    assert done.status_code == 201
    sent = lb.submitted[-1]
    assert sent["listen_type"] == "single"
    meta = sent["payload"][0]["track_metadata"]
    assert meta["track_name"] == "Low Water"
    assert meta["artist_name"] == "Low Tide Radio, A Guest"
    assert meta["release_name"] == "Salt on the Window"
    assert meta["additional_info"]["duration_ms"] == 200_000
    assert meta["additional_info"]["submission_client"] == "WetOwl"
    assert sent["payload"][0]["listened_at"] > 1_600_000_000

    standing = client.get("/scrobbling", headers=hdr).json()["listenbrainz"]
    assert standing["sent"] == 1 and standing["owed"] == 0 and standing["error"] is None


def test_the_diary_being_down_costs_nothing_and_loses_nothing(client, hdr, lb, song):
    client.put("/scrobbling/listenbrainz", headers=hdr, json={"token": "good-token"})
    lb.down = True
    for _ in range(2):
        r = client.post("/listens", headers=hdr,
                        json={"track_id": song["id"], "ms_played": 199_000, "completed": True})
        assert r.status_code == 201, "the listen itself is still recorded"
    standing = client.get("/scrobbling", headers=hdr).json()["listenbrainz"]
    assert standing["sent"] == 0 and standing["owed"] == 2 and standing["error"]

    # Back up: the next play takes the two that were owed with it, in one go.
    lb.down = False
    client.post("/listens", headers=hdr,
                json={"track_id": song["id"], "ms_played": 199_000, "completed": True})
    assert lb.submitted[-1]["listen_type"] == "import"
    assert len(lb.submitted[-1]["payload"]) == 3
    standing = client.get("/scrobbling", headers=hdr).json()["listenbrainz"]
    assert standing["sent"] == 3 and standing["owed"] == 0


def test_nobody_is_written_about_who_did_not_ask(client, hdr, lb, song):
    client.post("/listens", headers=hdr,
                json={"track_id": song["id"], "ms_played": 199_000, "completed": True})
    assert lb.calls == []
    assert db.one("select count(*) n from scrobbles")["n"] == 0


def test_disconnecting_forgets_the_token_and_what_was_owed(client, hdr, lb, song):
    client.put("/scrobbling/listenbrainz", headers=hdr, json={"token": "good-token"})
    lb.down = True
    client.post("/listens", headers=hdr,
                json={"track_id": song["id"], "ms_played": 199_000, "completed": True})
    gone = client.delete("/scrobbling/listenbrainz", headers=hdr).json()["listenbrainz"]
    assert gone["connected"] is False and gone["owed"] == 0
    assert db.one("select listenbrainz_token t from users where name='chris'")["t"] is None
