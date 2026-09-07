"""Lyrics are cached even when missing; history is per-track, most recent first."""
from __future__ import annotations

import httpx
import pytest

from muse import routes_play


class FakeResponse:
    def __init__(self, status, payload=None):
        self.status_code, self._p = status, payload or {}

    def json(self):
        return self._p


@pytest.fixture()
def track(client, hdr, tmp_path):
    import io
    import subprocess
    f = tmp_path / "t.m4a"
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "lavfi",
                    "-i", "sine=frequency=440:duration=2", "-c:a", "aac",
                    "-metadata", "title=Lyric Song", "-metadata", "artist=Someone",
                    str(f)], check=True)
    with f.open("rb") as fh:
        return client.post("/uploads", headers=hdr,
                           files={"audio": ("t.m4a", io.BytesIO(fh.read()), "audio/mp4")}).json()


def test_lyrics_are_fetched_once_then_cached(client, hdr, track, monkeypatch):
    calls = []

    def fake_get(url, **kw):
        calls.append(kw.get("params"))
        return FakeResponse(200, {"syncedLyrics": "[00:01.00]la", "plainLyrics": "la"})

    monkeypatch.setattr(routes_play.httpx, "get", fake_get)
    first = client.get(f"/tracks/{track['id']}/lyrics", headers=hdr).json()
    assert first["synced"].startswith("[00:01") and first["cached"] is False
    second = client.get(f"/tracks/{track['id']}/lyrics", headers=hdr).json()
    assert second["cached"] is True
    assert len(calls) == 1                       # LRCLIB is rate limited; ask once
    assert calls[0]["duration"] == 2             # matching needs the duration in seconds


def test_a_miss_is_cached_too(client, hdr, track, monkeypatch):
    calls = []
    monkeypatch.setattr(routes_play.httpx, "get",
                        lambda url, **kw: (calls.append(1), FakeResponse(404))[1])
    r = client.get(f"/tracks/{track['id']}/lyrics", headers=hdr).json()
    assert r["synced"] is None and r["source"] == "lrclib-miss"
    client.get(f"/tracks/{track['id']}/lyrics", headers=hdr)
    assert len(calls) == 1                       # an instrumental stays an instrumental


def test_lyrics_upstream_failure_is_502_not_500(client, hdr, track, monkeypatch):
    def boom(url, **kw):
        raise httpx.ConnectError("nope")

    monkeypatch.setattr(routes_play.httpx, "get", boom)
    assert client.get(f"/tracks/{track['id']}/lyrics", headers=hdr).status_code == 502


def test_history_is_deduped_and_recent_first(client, hdr, track):
    other = client.post("/tracks/resolve", headers=hdr, json={"video_id": "HIST1"}).json()
    for _ in range(3):
        client.post("/listens", headers=hdr,
                    json={"track_id": track["id"], "ms_played": 2000, "completed": True})
    client.post("/listens", headers=hdr,
                json={"track_id": other["id"], "ms_played": 500, "completed": False})

    hist = client.get("/history", headers=hdr).json()
    assert [h["id"] for h in hist] == [other["id"], track["id"]]   # one row per track
    stats = client.get("/stats", headers=hdr).json()
    assert stats["plays"] == 3                                     # only completed plays count
    assert stats["top"][0]["id"] == track["id"]


def test_listen_for_unknown_track_is_404(client, hdr):
    assert client.post("/listens", headers=hdr, json={"track_id": 4242}).status_code == 404
