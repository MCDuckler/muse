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


def test_a_record_heard_to_the_end_is_worth_a_point(client, hdr):
    """One point a record, and only for the ones actually listened to.

    Counted from the listens rather than kept as a number beside them: the listens are
    the record of what happened, and a tally kept alongside can only ever come to
    disagree with them.
    """
    track = client.post("/tracks/resolve", headers=hdr,
                        json={"video_id": "AAA"}).json()
    other = client.post("/tracks/resolve", headers=hdr,
                        json={"video_id": "BBB"}).json()

    assert client.get("/me", headers=hdr).json()["score"] == 0

    skipped = client.post("/listens", headers=hdr, json={
        "track_id": track["id"], "ms_played": 4000, "completed": False}).json()
    assert skipped["score"] == 0, "skipping through a song earns nothing"

    heard = client.post("/listens", headers=hdr, json={
        "track_id": track["id"], "ms_played": 210_000, "completed": True}).json()
    assert heard["score"] == 1

    again = client.post("/listens", headers=hdr, json={
        "track_id": other["id"], "ms_played": 190_000, "completed": True}).json()
    assert again["score"] == 2
    assert client.get("/me", headers=hdr).json()["score"] == 2


def test_the_score_is_beside_every_name(client, hdr):
    track = client.post("/tracks/resolve", headers=hdr,
                        json={"video_id": "AAA"}).json()
    client.post("/listens", headers=hdr,
                json={"track_id": track["id"], "ms_played": 200_000,
                      "completed": True})
    client.post("/accounts", headers=hdr,
                json={"name": "sam", "password": "correct-horse"})

    listed = client.get("/accounts", headers=hdr).json()["items"]
    by_name = {a["name"]: a["score"] for a in listed}
    assert by_name["chris"] == 1
    assert by_name["sam"] == 0, "everybody starts at nothing"


def test_a_second_device_does_not_double_the_score(client, hdr):
    """The tally is a count of listens, not a join across them — one more device
    signed in must not multiply what somebody has heard."""
    from muse import db

    track = client.post("/tracks/resolve", headers=hdr,
                        json={"video_id": "AAA"}).json()
    client.post("/listens", headers=hdr,
                json={"track_id": track["id"], "ms_played": 200_000,
                      "completed": True})
    me = client.get("/me", headers=hdr).json()["user_id"]
    db.run("""insert into devices(user_id, name, token_hash)
              values(%s,'another','x')""", (me,))

    listed = client.get("/accounts", headers=hdr).json()["items"]
    assert next(a for a in listed if a["id"] == me)["score"] == 1


def test_a_phone_can_hand_up_what_its_player_did(client, hdr):
    """The interesting minute is the one the app was not in front for, so the phone
    writes it down and sends it when it comes back."""
    r = client.post("/playback-log", headers=hdr, json={
        "device": "app",
        "build": "202609120143",
        "lines": ["21:00:01 app out of sight", "21:00:11 engine stopped ready"],
    })
    assert r.status_code == 201, r.text

    from muse import db
    kept = db.one("select device, build, lines from playback_reports order by id desc")
    assert kept["device"] == "app" and kept["build"] == "202609120143"
    assert "app out of sight" in kept["lines"]


def test_only_the_last_few_reports_are_kept(client, hdr):
    for n in range(14):
        client.post("/playback-log", headers=hdr, json={"lines": ["line $n"]})
    from muse import db
    assert db.one("select count(*) n from playback_reports")["n"] == 10


def test_an_empty_report_is_refused(client, hdr):
    assert client.post("/playback-log", headers=hdr,
                       json={"lines": []}).status_code == 400


def test_a_song_has_a_shape_for_its_seek_bar(client, hdr, track, monkeypatch):
    """Its loudness a slice at a time, measured once and kept."""
    from muse import peaks

    r = client.get(f"/tracks/{track['id']}/peaks", headers=hdr)
    assert r.status_code == 200
    body = r.json()
    assert body["slices"] == peaks.SLICES == len(body["peaks"])
    assert max(body["peaks"]) == 255, "the loudest slice is the top of the bar"
    assert all(0 <= v <= 255 for v in body["peaks"])
    assert "immutable" in r.headers["cache-control"]

    # The second ask reads what the first worked out: measuring again would fail here.
    def never(*a, **kw):
        raise AssertionError("measured twice")

    monkeypatch.setattr(peaks, "measure", never)
    again = client.get(f"/tracks/{track['id']}/peaks", headers=hdr).json()
    assert again["peaks"] == body["peaks"]


def test_a_song_with_no_audio_has_no_shape_yet(client, hdr):
    assert client.get("/tracks/999999/peaks", headers=hdr).status_code == 404
