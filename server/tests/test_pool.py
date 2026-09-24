"""The pool: every desktop fetching songs and taking records apart for the house.

What is checked: a part nobody has made is queued and answered "not yet"; a computer
with a graphics card is handed the split first, and one without only after it has
waited for one — unless it is its own; a split handed in is kept and served to
everybody, phones included; a failed split leaves the song alone; a computer can claim
the song its own person asked for; and the pool screen says who is doing what.
"""
from __future__ import annotations

import io
import subprocess

import pytest

from muse import auth, db, jobs, pool


@pytest.fixture()
def a_record(client, hdr, tmp_path):
    f = tmp_path / "t.m4a"
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "lavfi",
                    "-i", "sine=frequency=440:duration=3", "-c:a", "aac",
                    "-metadata", "title=Some Record", str(f)], check=True)
    return client.post("/uploads", headers=hdr,
                       files={"audio": ("t.m4a", io.BytesIO(f.read_bytes()),
                                        "audio/mp4")}).json()


@pytest.fixture()
def a_part(tmp_path) -> bytes:
    f = tmp_path / "p.m4a"
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "lavfi",
                    "-i", "sine=frequency=220:duration=3", "-c:a", "aac", str(f)],
                   check=True)
    return f.read_bytes()


def _computer(client, hdr, name: str) -> dict:
    client.post("/accounts", headers=hdr, json={"name": name, "password": "correct-horse"})
    token = client.post("/auth/login",
                        data={"user": name, "password": "correct-horse"}).json()["token"]
    h = {"Authorization": f"Bearer {token}"}
    device = db.one("select id from devices where token_hash=%s",
                    (auth.token_hash(token),))["id"]
    return {"hdr": h, "device": device}


def _lease_split(client, who, gpu: bool):
    return client.post("/internal/jobs/lease", headers=who["hdr"], json={
        "kind": "split", "limit": 1,
        "pool": {"fetch": True, "split": True, "gpu": gpu, "cores": 8}}).json()["jobs"]


def test_a_part_nobody_has_made_is_queued_and_not_yet(client, hdr, a_record):
    r = client.get(f"/tracks/{a_record['id']}/stem/drums", headers=hdr)
    assert r.status_code == 202 and r.headers.get("Retry-After")
    queued = db.all_("select kind, state from jobs where kind='split'")
    assert queued == [{"kind": "split", "state": "pending"}]
    # Asked again: the same split, not a second one.
    client.get(f"/tracks/{a_record['id']}/stem/vocals", headers=hdr)
    assert len(db.all_("select 1 from jobs where kind='split'")) == 1


def test_the_graphics_card_is_asked_first(client, hdr, a_record):
    weak = _computer(client, hdr, "weak")
    strong = _computer(client, hdr, "strong")
    client.post(f"/pool/split/{a_record['id']}", headers=hdr)
    assert _lease_split(client, weak, gpu=False) == [], "it waits for a card"
    got = _lease_split(client, strong, gpu=True)
    assert len(got) == 1 and got[0]["kind"] == "split"


def test_without_a_card_it_is_taken_once_it_has_waited(client, hdr, a_record):
    weak = _computer(client, hdr, "weak2")
    client.post(f"/pool/split/{a_record['id']}", headers=hdr)
    db.run("update jobs set created_at = now() - interval '%s seconds' where kind='split'"
           % (jobs.SPLIT_FOR_THE_CARD_SECONDS + 1))
    assert len(_lease_split(client, weak, gpu=False)) == 1


def test_its_own_split_it_may_always_claim(client, hdr, a_record):
    weak = _computer(client, hdr, "weak3")
    client.post(f"/pool/split/{a_record['id']}", headers=weak["hdr"])
    assert _lease_split(client, weak, gpu=False) == [], "from the pool, it waits like anyone"
    got = client.post("/internal/jobs/claim", headers=weak["hdr"],
                      json={"kind": "split", "track_id": a_record["id"]}).json()["job"]
    assert got["kind"] == "split"


def test_a_split_handed_in_is_kept_for_everybody(client, hdr, a_record, a_part):
    strong = _computer(client, hdr, "maker")
    client.post(f"/pool/split/{a_record['id']}", headers=hdr)
    job = _lease_split(client, strong, gpu=True)[0]
    files = {n: (f"{n}.m4a", io.BytesIO(a_part), "audio/mp4") for n in pool.PARTS}
    r = client.post(f"/internal/jobs/{job['id']}/parts", headers=strong["hdr"],
                    data={"meta": '{"seconds": 12.5}'}, files=files)
    assert r.status_code == 200, r.text
    assert sorted(r.json()["parts"]) == sorted(pool.PARTS)
    assert db.one("select state from jobs where id=%s", (job["id"],))["state"] == "done"
    for n in pool.PARTS:
        got = client.get(f"/tracks/{a_record['id']}/stem/{n}", headers=hdr)
        assert got.status_code == 200 and got.content == a_part
    assert client.get(f"/pool/parts/{a_record['id']}", headers=hdr).json()["parts"] \
        == sorted(pool.PARTS)
    # Kept, it is not queued again.
    assert pool.want_split(a_record["id"]) is None
    seen = client.get("/pool", headers=hdr).json()
    me = next(d for d in seen["devices"] if d["id"] == strong["device"])
    assert me["gpu"] is True and me["split_today"] == 1


def test_what_is_handed_in_has_to_be_a_sound(client, hdr, a_record):
    strong = _computer(client, hdr, "liar")
    client.post(f"/pool/split/{a_record['id']}", headers=hdr)
    job = _lease_split(client, strong, gpu=True)[0]
    r = client.post(f"/internal/jobs/{job['id']}/parts", headers=strong["hdr"],
                    files={"drums": ("d.m4a", io.BytesIO(b"x" * 100), "audio/mp4")})
    assert r.status_code == 400
    assert pool.parts_of(db.one("select sha256 from media")["sha256"]) == []


def test_a_failed_split_leaves_the_song_alone(client, hdr, a_record):
    strong = _computer(client, hdr, "failer")
    client.post(f"/pool/split/{a_record['id']}", headers=hdr)
    job = _lease_split(client, strong, gpu=True)[0]
    client.post(f"/internal/jobs/{job['id']}/fail", headers=strong["hdr"],
                json={"reason": "out of memory", "track_id": a_record["id"],
                      "retryable": False})
    assert db.one("select state from tracks where id=%s", (a_record["id"],))["state"] == "ready"
    assert db.one("select state from jobs where id=%s", (job["id"],))["state"] == "failed"


def test_a_computer_claims_what_its_own_person_asked_for(client, hdr):
    desk = _computer(client, hdr, "desk")
    track = client.post("/tracks/resolve", headers=desk["hdr"],
                        json={"video_id": "POOL0000001"}).json()
    r = client.post("/internal/jobs/claim", headers=desk["hdr"],
                    json={"kind": "ingest", "track_id": track["id"]}).json()
    assert r["job"]["payload"]["track_id"] == track["id"]
    row = db.one("select leased_by, state from jobs where id=%s", (r["job"]["id"],))
    assert row == {"leased_by": f"device:{desk['device']}", "state": "leased"}
    # Already taken: nobody else gets it, and a second claim gets nothing.
    other = _computer(client, hdr, "other")
    assert client.post("/internal/jobs/claim", headers=other["hdr"],
                       json={"kind": "ingest", "track_id": track["id"]}).json()["job"] is None


def test_an_admin_pauses_one_kind_of_work(client, hdr, a_record):
    strong = _computer(client, hdr, "paused")
    client.post(f"/pool/split/{a_record['id']}", headers=hdr)
    assert client.post("/pool/pause", headers=strong["hdr"],
                       json={"kind": "split", "paused": True}).status_code == 403
    client.post("/pool/pause", headers=hdr, json={"kind": "split", "paused": True})
    assert _lease_split(client, strong, gpu=True) == []
    client.post("/pool/pause", headers=hdr, json={"kind": "split", "paused": False})
    assert len(_lease_split(client, strong, gpu=True)) == 1


def test_one_records_split_says_who_has_it(client, hdr, a_record):
    strong = _computer(client, hdr, "teller")
    client.post(f"/pool/split/{a_record['id']}", headers=hdr)
    before = client.get(f"/pool/split/{a_record['id']}", headers=hdr).json()
    assert before["job"]["state"] == "pending" and before["parts"] == []
    _lease_split(client, strong, gpu=True)
    during = client.get(f"/pool/split/{a_record['id']}", headers=hdr).json()["job"]
    assert during["state"] == "leased" and during["device_id"] == strong["device"]


def test_a_playlist_marked_to_be_taken_apart_queues_its_songs(client, hdr, a_record, tmp_path):
    pl = client.post("/playlists", headers=hdr, json={"name": "Crate"}).json()
    client.post(f"/playlists/{pl['id']}/items", headers=hdr, json={"track_ids": [a_record["id"]]})
    assert db.all_("select 1 from jobs where kind='split'") == [], "not marked: nothing"
    r = client.post(f"/playlists/{pl['id']}/auto-split", headers=hdr, json={"auto_split": True})
    assert r.json() == {"auto_split": True, "queued": 1}
    assert client.get(f"/playlists/{pl['id']}", headers=hdr).json()["auto_split"] is True
    # A song added afterwards is queued as it is added.
    f = tmp_path / "second.m4a"
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "lavfi",
                    "-i", "sine=frequency=330:duration=3", "-c:a", "aac",
                    "-metadata", "title=Second", str(f)], check=True)
    second = client.post("/uploads", headers=hdr,
                         files={"audio": ("s.m4a", io.BytesIO(f.read_bytes()),
                                          "audio/mp4")}).json()
    client.post(f"/playlists/{pl['id']}/items", headers=hdr, json={"track_ids": [second["id"]]})
    queued = {r["t"] for r in db.all_(
        "select (payload->>'track_id')::int t from jobs where kind='split'")}
    assert queued == {a_record["id"], second["id"]}
    assert all(r["priority"] == jobs.PRIORITY_BULK
               for r in db.all_("select priority from jobs where kind='split'"))


def test_somebody_elses_playlist_is_not_theirs_to_mark(client, hdr, a_record):
    pl = client.post("/playlists", headers=hdr, json={"name": "Mine"}).json()
    other = _computer(client, hdr, "nosy")
    client.post(f"/playlists/{pl['id']}/open-edit", headers=hdr, json={"open_edit": True})
    r = client.post(f"/playlists/{pl['id']}/auto-split", headers=other["hdr"],
                    json={"auto_split": True})
    assert r.status_code == 403


def test_a_computer_on_an_older_app_is_still_listed(client, hdr):
    old = _computer(client, hdr, "oldapp")
    client.post("/internal/jobs/lease", headers=old["hdr"], json={})  # no pool report
    seen = client.get("/pool", headers=hdr).json()["devices"]
    me = next(d for d in seen if d["id"] == old["device"])
    assert me["live"] and me["older"] and me["fetch"]
