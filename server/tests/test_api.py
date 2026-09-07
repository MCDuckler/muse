"""What must not regress: auth, the cache rule, the worker protocol, Range serving."""
from __future__ import annotations

import pytest

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
    assert got["state"] == "failed"
    assert got["fail_code"] == "unavailable"
    # The row shows a sentence, not the downloader's console output.
    assert "available" in got["fail_reason"] and "ERROR" not in got["fail_reason"]
    # terminal failure is not handed back out to a worker
    assert client.post("/internal/jobs/lease", headers=wsec,
                       json={"worker": "w"}).json()["jobs"] == []


def test_failed_track_can_be_retried_by_resolving_again(client, hdr, wsec):
    t = client.post("/tracks/resolve", headers=hdr, json={"query": "test song"}).json()
    job = client.post("/internal/jobs/lease", headers=wsec, json={"worker": "w"}).json()["jobs"][0]
    client.post(f"/internal/jobs/{job['id']}/fail", headers=wsec,
                json={"reason": "This video is unavailable", "retryable": False,
                      "track_id": t["id"]})
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


# ---------------- stream keys (browser audio cannot send headers) ----------------
def test_stream_key_authenticates_without_a_header(client, hdr, wsec, complete_job):
    t = client.post("/tracks/resolve", headers=hdr, json={"query": "test song"}).json()
    job = client.post("/internal/jobs/lease", headers=wsec, json={"worker": "w"}).json()["jobs"][0]
    complete_job(job["id"], t["id"])

    key = client.get("/auth/stream-key", headers=hdr).json()["key"]
    r = client.get(f"/tracks/{t['id']}/stream", params={"k": key})   # no Authorization
    assert r.status_code == 200
    assert client.get(f"/tracks/{t['id']}/stream").status_code == 401


def test_a_forged_or_expired_stream_key_is_refused(client, hdr, wsec, complete_job):
    import time as _t

    from muse import auth as _auth

    t = client.post("/tracks/resolve", headers=hdr, json={"query": "test song"}).json()
    job = client.post("/internal/jobs/lease", headers=wsec, json={"worker": "w"}).json()["jobs"][0]
    complete_job(job["id"], t["id"])

    good = client.get("/auth/stream-key", headers=hdr).json()["key"]
    uid, exp, sig = good.split(".")

    forged = f"{uid}.{int(exp) + 99999}.{sig}"            # extended expiry, stale signature
    assert client.get(f"/tracks/{t['id']}/stream", params={"k": forged}).status_code == 401

    expired, _ = _auth.stream_key(int(uid), "test-secret", ttl=-10)
    assert client.get(f"/tracks/{t['id']}/stream", params={"k": expired}).status_code == 401

    other_secret, _ = _auth.stream_key(int(uid), "not-the-secret")
    assert client.get(f"/tracks/{t['id']}/stream", params={"k": other_secret}).status_code == 401
    assert int(_t.time()) > 0


# ---------------- failure messages a person can act on ----------------
@pytest.mark.parametrize("raw,code,retryable", [
    ("ERROR: [youtube] abc: This video is unavailable", "unavailable", False),
    ("ERROR: [youtube] abc: Private video. Sign in if you've been granted access",
     "private", False),
    ("Sign in to confirm you’re not a bot. Use --cookies-from-browser", "bot_check", False),
    ("ERROR: unable to download: HTTP Error 429: Too Many Requests", "throttled", True),
    ("ERROR: [youtube] abc: Connection reset by peer", "network", True),
    ("ERROR: Video unavailable. The uploader has not made this video available in "
     "your country", "unavailable", False),
    ("ERROR: [youtube] abc: Requested format is not available", "format", False),
    ("something nobody has seen before", "unknown", True),
])
def test_failures_are_classified(raw, code, retryable):
    from muse import failures

    got_code, message, got_retryable = failures.classify(raw)
    assert got_code == code
    assert got_retryable is retryable
    assert message and not message.startswith("ERROR"), "must not echo the raw output"


def test_a_missing_reason_still_produces_a_message():
    from muse import failures

    code, message, retryable = failures.classify(None)
    assert code == "unknown" and message and retryable is True


# ---------------- live download state ----------------
def test_progress_is_reported_and_reaches_the_track(client, hdr, wsec):
    t = client.post("/tracks/resolve", headers=hdr, json={"query": "test song"}).json()
    job = client.post("/internal/jobs/lease", headers=wsec, json={"worker": "w"}).json()["jobs"][0]

    client.post(f"/internal/jobs/{job['id']}/progress", headers=wsec,
                json={"track_id": t["id"], "stage": "downloading", "percent": 0.42,
                      "speed": "1.2MiB/s"})
    got = client.get(f"/tracks/{t['id']}", headers=hdr).json()
    assert got["progress"]["stage"] == "downloading"
    assert got["progress"]["percent"] == 0.42
    assert got["progress"]["label"] == "Downloading"

    status = client.get("/status", headers=hdr).json()
    assert str(t["id"]) in {str(k) for k in status["in_progress"]}


def test_progress_is_cleared_when_the_download_finishes(client, hdr, wsec,
                                                        complete_job):
    t = client.post("/tracks/resolve", headers=hdr, json={"query": "test song"}).json()
    job = client.post("/internal/jobs/lease", headers=wsec, json={"worker": "w"}).json()["jobs"][0]
    client.post(f"/internal/jobs/{job['id']}/progress", headers=wsec,
                json={"track_id": t["id"], "stage": "uploading", "percent": 0.9})
    complete_job(job["id"], t["id"])
    assert client.get(f"/tracks/{t['id']}", headers=hdr).json()["progress"] is None


def test_status_reports_whether_anything_can_download(client, hdr, wsec):
    before = client.get("/status", headers=hdr).json()
    assert before["ingest_online"] is False, "no worker has checked in yet"

    client.post("/internal/jobs/lease", headers=wsec, json={"worker": "laptop"})
    after = client.get("/status", headers=hdr).json()
    assert after["ingest_worker"] == "laptop" and after["ingest_online"] is True


def test_a_retryable_failure_leaves_the_track_pending(client, hdr, wsec):
    """A track that will be tried again must not look permanently broken."""
    t = client.post("/tracks/resolve", headers=hdr, json={"query": "test song"}).json()
    job = client.post("/internal/jobs/lease", headers=wsec, json={"worker": "w"}).json()["jobs"][0]
    r = client.post(f"/internal/jobs/{job['id']}/fail", headers=wsec,
                    json={"reason": "HTTP Error 429: Too Many Requests",
                          "track_id": t["id"]}).json()
    assert r["code"] == "throttled" and r["retryable"] is True
    got = client.get(f"/tracks/{t['id']}", headers=hdr).json()
    assert got["state"] == "pending", "it is going to be retried, so it is not failed"
    assert got["fail_code"] == "throttled"


def test_metadata_is_queued_as_soon_as_the_track_exists(client, hdr, wsec):
    """Artwork should not wait for the audio: a downloading row can still have a cover."""
    client.post("/tracks/resolve", headers=hdr, json={"query": "test song"})
    meta = client.post("/internal/jobs/lease", headers=wsec,
                       json={"worker": "w", "kind": "meta"}).json()["jobs"]
    assert len(meta) == 1


# ---------------- artwork before anything is downloaded ----------------
def test_search_results_carry_artwork(client, hdr, monkeypatch):
    from muse import ytm

    monkeypatch.setattr(ytm, "search_songs", lambda q, limit=10: [{
        "video_id": "REMOTE1", "title": "Remote Song", "artists": ["Someone"],
        "album": "An Album", "duration_ms": 200_000,
        "raw": {"thumbnails": [
            {"url": "https://lh3.googleusercontent.com/abc=w120-h120-l90-rj",
             "width": 120, "height": 120}
        ]},
    }])
    hits = client.get("/search", headers=hdr, params={"q": "remote"}).json()["remote"]
    assert hits[0]["cover_url"].startswith("/art/remote?u=")
    assert "raw" not in hits[0], "the provider payload is not the client's business"


@pytest.mark.parametrize("host", [
    "lh3.googleusercontent.com", "yt3.googleusercontent.com", "yt3.ggpht.com",
    "i.ytimg.com",
])
def test_the_art_proxy_accepts_the_hosts_youtube_actually_uses(client, hdr, host,
                                                               monkeypatch):
    """The first allowlist missed yt3.googleusercontent.com, which is the host every
    real search result used — so every cover 400'd."""
    class _Img:
        status_code = 200
        headers = {"content-type": "image/jpeg"}
        content = b"\xff\xd8\xff\xe0jpegish"

    from muse import app as app_mod

    monkeypatch.setattr(app_mod.httpx, "get", lambda *a, **k: _Img())
    r = client.get("/art/remote", headers=hdr, params={"u": f"https://{host}/abc"})
    assert r.status_code == 200 and r.headers["content-type"] == "image/jpeg"


def test_the_art_proxy_only_serves_image_hosts(client, hdr):
    bad = client.get("/art/remote", headers=hdr,
                     params={"u": "https://example.com/secret.png"})
    assert bad.status_code == 400, "an open proxy is a liability"
    assert client.get("/art/remote", headers=hdr,
                      params={"u": "http://lh3.googleusercontent.com/x"}).status_code == 400
    assert client.get("/art/remote",
                      params={"u": "https://lh3.googleusercontent.com/x"}).status_code == 401


def test_thumbnail_urls_are_upgraded_to_a_useful_size():
    from muse import ytm

    url = ytm.thumbnail_url({"thumbnails": [
        {"url": "https://lh3.googleusercontent.com/abc=w60-h60-l90-rj", "width": 60}]})
    assert "=w300-h300" in url
    assert ytm.thumbnail_url({}) is None
