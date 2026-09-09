from __future__ import annotations

import io
import json
import pathlib
import sys

import psycopg
import pytest
from fastapi.testclient import TestClient

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

from muse import app as app_mod          # noqa: E402
from muse import auth, config, db, ytm   # noqa: E402

BASE_DSN = "host=127.0.0.1 port=5433 user=muse dbname=postgres"
TEST_DB = "muse_test"
TEST_DSN = BASE_DSN.replace("dbname=postgres", f"dbname={TEST_DB}")


@pytest.fixture(scope="session", autouse=True)
def _fresh_db():
    c = psycopg.connect(BASE_DSN, autocommit=True)
    c.execute(f"drop database if exists {TEST_DB} with (force)")
    c.execute(f"create database {TEST_DB}")
    c.close()
    yield
    db.close()


@pytest.fixture()
def cfg(tmp_path) -> config.Config:
    return config.Config(
        dsn=TEST_DSN,
        data_dir=tmp_path,
        worker_secret="test-secret",
        users=(config.User("chris", auth.hash_password("devpass")),),
    )


@pytest.fixture()
def client(cfg, monkeypatch):
    # No network in tests: the catalog is ours, YouTube Music is not.
    monkeypatch.setattr(ytm, "search_songs", lambda q, limit=10: [{
        "video_id": "TESTVIDEO001", "title": "Test Song", "artists": ["Tester"],
        "album": "Test Album", "duration_ms": 123_000, "raw": {"stub": True},
    }])
    monkeypatch.setattr(ytm, "watch_playlist", lambda vid, limit=25: [
        {"video_id": f"RADIO{n}", "title": f"Radio Track {n}", "artists": ["Someone"],
         "album": None, "duration_ms": 180_000 + n, "raw": {"radio_seed": vid}}
        for n in range(12)
    ])
    monkeypatch.setattr(ytm, "song", lambda vid: {
        "video_id": vid, "title": f"Song {vid}", "artists": ["Tester"],
        "album": None, "duration_ms": 60_000, "raw": {},
    })
    application = app_mod.create_app(cfg)
    with db.pool().connection() as c:
        # Accounts are per-test too, now that they live in the database: leaving them
        # behind made "create an account" fail as a duplicate in every later test.
        # settings included: a test that pauses downloads used to leave them paused,
        # and every later test that leased a job silently got nothing.
        for t in ("queue_items", "queues", "playlist_items", "playlist_unmatched",
                  "playlists", "listens", "media", "track_sources", "tracks", "jobs",
                  "devices", "workers", "invites", "provider_accounts", "settings",
                  "users"):
            c.execute(f"truncate {t} restart identity cascade")
    for u in cfg.users:                       # re-seed what muse.toml declares
        # Admin, for the same reason create_app does it: whoever the server's own
        # config names owns the server. The truncate above wipes the row create_app
        # made, so this has to say it too.
        auth.ensure_user(u.name, pw_hash=u.password_hash, admin=True)
    with TestClient(application) as tc:
        yield tc
    db.close()


@pytest.fixture()
def token(client) -> str:
    r = client.post("/auth/login", data={"user": "chris", "password": "devpass", "device": "pytest"})
    assert r.status_code == 200, r.text
    return r.json()["token"]


@pytest.fixture()
def hdr(token) -> dict:
    return {"Authorization": f"Bearer {token}"}


@pytest.fixture()
def wsec() -> dict:
    return {"X-Worker-Secret": "test-secret"}


def fake_audio(nbytes: int = 4096) -> io.BytesIO:
    return io.BytesIO(b"\x00\x00\x00\x20ftypM4A " + b"m" * (nbytes - 12))


@pytest.fixture()
def complete_job(client, wsec):
    """Stand in for the worker: hand the server a finished blob for a leased job."""

    def _complete(job_id: int, track_id: int, nbytes: int = 4096):
        return client.post(
            f"/internal/jobs/{job_id}/complete",
            headers=wsec,
            data={"meta": json.dumps({"track_id": track_id, "codec": "aac", "bitrate": 129000,
                                      "duration_ms": 123000, "loudness_lufs": -10.6,
                                      "gain_db": -3.4})},
            files={"audio": ("t.m4a", fake_audio(nbytes), "audio/mp4")},
        )

    return _complete
