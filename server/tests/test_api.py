"""What must not regress: auth, the cache rule, the worker protocol, Range serving."""
from __future__ import annotations

import json


# ---------------- auth ----------------
def test_login_and_me(client, hdr):
    assert client.get("/me", headers=hdr).json()["user"] == "chris"


def test_wrong_password_is_401(client):
    r = client.post("/auth/login", data={"user": "chris", "password": "nope"})
    assert r.status_code == 401


def test_unknown_user_is_401(client):
    r = client.post("/auth/login", data={"user": "ghost", "password": "devpass"})
    assert r.status_code == 401


def test_no_token_is_401(client):
    assert client.get("/me").status_code == 401
    assert client.get("/me", headers={"Authorization": "Bearer garbage"}).status_code == 401


def test_internal_requires_worker_secret(client):
    assert client.post("/internal/jobs/lease", json={"worker": "x"}).status_code == 401
    r = client.post("/internal/jobs/lease", json={"worker": "x"},
                    headers={"X-Worker-Secret": "wrong"})
    assert r.status_code == 401


# ---------------- resolve / cache rule ----------------
def test_resolve_creates_pending_track_and_job(client, hdr, wsec):
    r = client.post("/tracks/resolve", headers=hdr, json={"query": "test song"})
    assert r.status_code == 202
    body = r.json()
    assert body["state"] == "pending" and body["stream_url"] is None

    leased = client.post("/internal/jobs/lease", headers=wsec,
                         json={"worker": "w", "kind": "ingest", "limit": 5}).json()["jobs"]
    assert len(leased) == 1
    assert leased[0]["payload"]["track_id"] == body["id"]


def test_second_resolve_is_a_cache_hit(client, hdr, wsec, complete_job):
    first = client.post("/tracks/resolve", headers=hdr, json={"query": "test song"}).json()
    job = client.post("/internal/jobs/lease", headers=wsec, json={"worker": "w"}).json()["jobs"][0]
    assert complete_job(job["id"], first["id"]).status_code == 200

    again = client.post("/tracks/resolve", headers=hdr, json={"video_id": "TESTVIDEO001"})
    assert again.status_code == 200                      # not 202: nothing was queued
    assert again.json()["state"] == "ready"
    assert again.json()["id"] == first["id"]             # same row, not a duplicate
    assert client.post("/internal/jobs/lease", headers=wsec,
                       json={"worker": "w"}).json()["jobs"] == []


def test_resolve_needs_something_to_resolve(client, hdr):
    assert client.post("/tracks/resolve", headers=hdr, json={}).status_code == 400


# ---------------- worker protocol ----------------
def test_lease_is_exclusive(client, hdr, wsec):
    client.post("/tracks/resolve", headers=hdr, json={"query": "test song"})
    a = client.post("/internal/jobs/lease", headers=wsec, json={"worker": "a"}).json()["jobs"]
    b = client.post("/internal/jobs/lease", headers=wsec, json={"worker": "b"}).json()["jobs"]
    assert len(a) == 1 and b == []          # SKIP LOCKED: two workers never take one job


def test_complete_marks_ready_and_stores_bytes(client, hdr, wsec, complete_job):
    t = client.post("/tracks/resolve", headers=hdr, json={"query": "test song"}).json()
    job = client.post("/internal/jobs/lease", headers=wsec, json={"worker": "w"}).json()["jobs"][0]
    r = complete_job(job["id"], t["id"], nbytes=8192)
    assert r.status_code == 200 and r.json()["bytes"] == 8192

    got = client.get(f"/tracks/{t['id']}", headers=hdr).json()
    assert got["state"] == "ready" and got["gain_db"] == -3.4 and got["bytes"] == 8192
    assert got["stream_url"] == f"/tracks/{t['id']}/stream"


def test_failed_job_marks_track_failed_with_reason(client, hdr, wsec):
    t = client.post("/tracks/resolve", headers=hdr, json={"query": "test song"}).json()
    job = client.post("/internal/jobs/lease", headers=wsec, json={"worker": "w"}).json()["jobs"][0]
    client.post(f"/internal/jobs/{job['id']}/fail", headers=wsec,
                json={"reason": "This video is unavailable", "retryable": False,
                      "track_id": t["id"]})
    got = client.get(f"/tracks/{t['id']}", headers=hdr).json()
    assert got["state"] == "failed" and "unavailable" in got["fail_reason"]
    # terminal failure is not handed back out to a worker
    assert client.post("/internal/jobs/lease", headers=wsec,
                       json={"worker": "w"}).json()["jobs"] == []


def test_failed_track_can_be_retried_by_resolving_again(client, hdr, wsec):
    t = client.post("/tracks/resolve", headers=hdr, json={"query": "test song"}).json()
    job = client.post("/internal/jobs/lease", headers=wsec, json={"worker": "w"}).json()["jobs"][0]
    client.post(f"/internal/jobs/{job['id']}/fail", headers=wsec,
                json={"reason": "boom", "retryable": False, "track_id": t["id"]})
    again = client.post("/tracks/resolve", headers=hdr, json={"video_id": "TESTVIDEO001"})
    assert again.json()["state"] == "pending"
    assert len(client.post("/internal/jobs/lease", headers=wsec,
                           json={"worker": "w"}).json()["jobs"]) == 1


# ---------------- streaming ----------------
def _ready_track(client, hdr, wsec, complete_job, nbytes=4096):
    t = client.post("/tracks/resolve", headers=hdr, json={"query": "test song"}).json()
    job = client.post("/internal/jobs/lease", headers=wsec, json={"worker": "w"}).json()["jobs"][0]
    complete_job(job["id"], t["id"], nbytes=nbytes)
    return t["id"]


def test_stream_full_and_headers(client, hdr, wsec, complete_job):
    tid = _ready_track(client, hdr, wsec, complete_job)
    r = client.get(f"/tracks/{tid}/stream", headers=hdr)
    assert r.status_code == 200
    assert r.headers["accept-ranges"] == "bytes"
    assert "immutable" in r.headers["cache-control"]
    assert len(r.content) == 4096


def test_stream_range_and_etag(client, hdr, wsec, complete_job):
    tid = _ready_track(client, hdr, wsec, complete_job)
    r = client.get(f"/tracks/{tid}/stream", headers={**hdr, "Range": "bytes=0-99"})
    assert r.status_code == 206
    assert r.headers["content-range"] == "bytes 0-99/4096"
    assert len(r.content) == 100

    suffix = client.get(f"/tracks/{tid}/stream", headers={**hdr, "Range": "bytes=-64"})
    assert suffix.headers["content-range"] == "bytes 4032-4095/4096"

    etag = client.get(f"/tracks/{tid}/stream", headers=hdr).headers["etag"]
    assert client.get(f"/tracks/{tid}/stream",
                      headers={**hdr, "If-None-Match": etag}).status_code == 304
    assert client.get(f"/tracks/{tid}/stream",
                      headers={**hdr, "Range": "bytes=99999-"}).status_code == 416


def test_stream_of_pending_track_is_404(client, hdr):
    t = client.post("/tracks/resolve", headers=hdr, json={"query": "test song"}).json()
    assert client.get(f"/tracks/{t['id']}/stream", headers=hdr).status_code == 404


def test_stream_requires_auth(client, hdr, wsec, complete_job):
    tid = _ready_track(client, hdr, wsec, complete_job)
    assert client.get(f"/tracks/{tid}/stream").status_code == 401


# ---------------- storage / dedupe ----------------
def test_identical_rips_share_one_blob(client, hdr, wsec, complete_job):
    ids = []
    for vid in ("VIDA", "VIDB"):
        t = client.post("/tracks/resolve", headers=hdr, json={"video_id": vid}).json()
        job = client.post("/internal/jobs/lease", headers=wsec, json={"worker": "w"}).json()["jobs"][0]
        r = complete_job(job["id"], t["id"])
        ids.append(r.json()["sha256"])
    assert ids[0] == ids[1]                       # content-addressed: one file on disk
    stats = client.get("/admin/storage", headers=hdr).json()
    assert stats["media_files"] == 2 and stats["tracks"]["ready"] == 2
