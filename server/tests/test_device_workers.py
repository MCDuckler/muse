"""Somebody's computer fetching music for the house.

The downloader used to be one machine holding the server's own secret, which also signs
every stream key and so can never leave the server. A device is instead allowed to fetch
by an admin and proves itself with the token it already has. What is checked: it cannot
fetch until it is allowed, it works under its own name whatever it claims, it may only
touch the jobs it holds, and taking the permission away gives its work back.
"""
from __future__ import annotations

import io
import json

import pytest

from muse import auth, db


@pytest.fixture()
def sam(client, hdr):
    """Somebody who is not an admin, on a desktop of theirs."""
    client.post("/accounts", headers=hdr, json={"name": "sam", "password": "correct-horse"})
    token = client.post("/auth/login",
                        data={"user": "sam", "password": "correct-horse"}).json()["token"]
    h = {"Authorization": f"Bearer {token}"}
    device = db.one("select id from devices where token_hash=%s", (auth.token_hash(token),))["id"]
    return {"hdr": h, "device": device}


def _queue_a_song(client, hdr, vid="DEVW0000001"):
    return client.post("/tracks/resolve", headers=hdr, json={"video_id": vid}).json()


def test_a_device_cannot_fetch_until_an_admin_says_so(client, hdr, sam):
    _queue_a_song(client, hdr)
    refused = client.post("/internal/jobs/lease", headers=sam["hdr"], json={"worker": "x"})
    assert refused.status_code == 403

    asked = client.post("/devices/ingest/ask", headers=sam["hdr"]).json()
    assert asked == {"allowed": False, "asked": True, "worker": f"device:{sam['device']}"}
    assert client.post("/internal/jobs/lease", headers=sam["hdr"],
                       json={"worker": "x"}).status_code == 403, "asking is not being told yes"

    # Only an admin says yes — and sees who is asking.
    assert client.post(f"/devices/{sam['device']}/ingest", headers=sam["hdr"],
                       json={"allowed": True}).status_code == 403
    listed = client.get("/devices/workers", headers=hdr).json()["devices"]
    assert [(d["owner"], d["allowed"]) for d in listed] == [("sam", False)]
    assert client.post(f"/devices/{sam['device']}/ingest", headers=hdr,
                       json={"allowed": True}).status_code == 200

    got = client.post("/internal/jobs/lease", headers=sam["hdr"],
                      json={"worker": "whatever-it-likes"}).json()["jobs"]
    assert len(got) == 1
    row = db.one("select leased_by from jobs where id=%s", (got[0]["id"],))
    assert row["leased_by"] == f"device:{sam['device']}", "its own name, not the one it gave"


def test_an_admins_own_computer_is_simply_allowed(client, hdr):
    assert client.post("/devices/ingest/ask", headers=hdr).json()["allowed"] is True


def test_a_device_touches_only_the_jobs_it_holds(client, hdr, wsec, sam):
    client.post(f"/devices/{sam['device']}/ingest", headers=hdr, json={"allowed": True})
    _queue_a_song(client, hdr, "DEVW0000002")
    theirs = client.post("/internal/jobs/lease", headers=wsec,
                         json={"worker": "laptop"}).json()["jobs"][0]

    # The house's downloader has this one. Sam's computer may not finish, fail, release
    # or report on it.
    tid = theirs["payload"]["track_id"]
    assert client.post(f"/internal/jobs/{theirs['id']}/fail", headers=sam["hdr"],
                       json={"reason": "nope", "track_id": tid}).status_code == 403
    assert client.post(f"/internal/jobs/{theirs['id']}/release", headers=sam["hdr"],
                       json={"track_id": tid}).status_code == 403
    assert client.post(f"/internal/jobs/{theirs['id']}/progress", headers=sam["hdr"],
                       json={"track_id": tid, "percent": 50}).status_code == 403
    done = client.post(f"/internal/jobs/{theirs['id']}/complete", headers=sam["hdr"],
                       data={"meta": json.dumps({"track_id": tid})},
                       files={"audio": ("a.m4a", io.BytesIO(b"x" * 64), "audio/mp4")})
    assert done.status_code == 403
    assert db.one("select state from tracks where id=%s", (tid,))["state"] != "ready"


def test_a_device_cannot_file_its_upload_under_another_song(client, hdr, sam):
    client.post(f"/devices/{sam['device']}/ingest", headers=hdr, json={"allowed": True})
    wanted = _queue_a_song(client, hdr, "DEVW0000003")
    other = _queue_a_song(client, hdr, "DEVW0000004")
    jobs_ = client.post("/internal/jobs/lease", headers=sam["hdr"],
                        json={"limit": 1}).json()["jobs"]
    job = jobs_[0]
    not_this = other["id"] if job["payload"]["track_id"] == wanted["id"] else wanted["id"]
    r = client.post(f"/internal/jobs/{job['id']}/complete", headers=sam["hdr"],
                    data={"meta": json.dumps({"track_id": not_this})},
                    files={"audio": ("a.m4a", io.BytesIO(b"x" * 64), "audio/mp4")})
    assert r.status_code == 403

    ok = client.post(f"/internal/jobs/{job['id']}/complete", headers=sam["hdr"],
                     data={"meta": json.dumps({"track_id": job["payload"]["track_id"],
                                               "codec": "aac", "bitrate": 128000,
                                               "duration_ms": 1000})},
                     files={"audio": ("a.m4a", io.BytesIO(b"x" * 64), "audio/mp4")})
    assert ok.status_code == 200, ok.text


def test_taking_the_permission_away_gives_the_work_back(client, hdr, sam):
    client.post(f"/devices/{sam['device']}/ingest", headers=hdr, json={"allowed": True})
    _queue_a_song(client, hdr, "DEVW0000005")
    job = client.post("/internal/jobs/lease", headers=sam["hdr"], json={}).json()["jobs"][0]

    client.post(f"/devices/{sam['device']}/ingest", headers=hdr, json={"allowed": False})
    assert db.one("select state, leased_by from jobs where id=%s", (job["id"],)) == \
        {"state": "pending", "leased_by": None}
    assert client.post("/internal/jobs/lease", headers=sam["hdr"], json={}).status_code == 403


def test_the_houses_own_downloader_works_as_it_always_did(client, hdr, wsec):
    _queue_a_song(client, hdr, "DEVW0000006")
    got = client.post("/internal/jobs/lease", headers=wsec, json={"worker": "laptop"}).json()
    assert len(got["jobs"]) == 1
    assert client.post("/internal/jobs/lease", headers={"X-Worker-Secret": "wrong"},
                       json={}).status_code == 401
    house = client.get("/devices/workers", headers=hdr).json()["house"]
    assert [w["name"] for w in house] == ["laptop"]
