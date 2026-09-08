"""Managing a download queue, not just having one.

One track behind a spinner was fine. A mirrored playlist is a hundred and twenty, and
then the questions are: how far along, what is stuck, can I stop it, and can the song I
actually want jump the queue.
"""
from __future__ import annotations

import pytest

from muse import db, jobs


@pytest.fixture()
def queued(client, hdr):
    """Three ordinary requests and a ten-track import behind them."""
    tracks = []
    for n in range(3):
        tracks.append(client.post("/tracks/resolve", headers=hdr,
                                  json={"video_id": f"USER{n}"}).json()["id"])
    for n in range(10):
        db.run(
            """insert into jobs(kind, payload, priority, batch_id, batch_label)
               values('ingest',
                      jsonb_build_object('track_id', %s::int, 'video_id', %s::text),
                      %s, 'spotify:PL1', 'Spotify · Road trip')""",
            (tracks[0], f"BULK{n}", jobs.PRIORITY_BULK),
        )
    return tracks


def test_the_overview_answers_everything_in_one_request(client, hdr, queued):
    d = client.get("/downloads", headers=hdr).json()
    assert d["counts"]["waiting"] == 13
    assert d["paused"] is False
    assert len(d["batches"]) == 1
    batch = d["batches"][0]
    assert batch["label"] == "Spotify · Road trip"
    assert batch["total"] == 10 and batch["remaining"] == 10 and batch["done"] == 0
    assert d["waiting"][0]["track"] is not None, "rows carry the track, not just an id"


def test_an_import_waits_behind_what_you_asked_for(client, hdr, queued, wsec):
    """A hundred-track import must not stand in front of the song you just added."""
    leased = client.post("/internal/jobs/lease", headers=wsec,
                         json={"worker": "w", "limit": 3}).json()["jobs"]
    assert len(leased) == 3
    assert all(j["batch_id"] is None for j in leased), "user requests go first"


def test_playing_something_still_downloading_moves_it_forward(client, hdr, queued,
                                                              wsec):
    # Bury a track behind the bulk import.
    db.run("""update jobs set priority=%s where (payload->>'track_id')::int = %s""",
           (jobs.PRIORITY_BULK + 1, queued[2]))
    assert client.post("/downloads/promote", headers=hdr,
                       json={"track_id": queued[2]}).json()["promoted"] is True

    first = client.post("/internal/jobs/lease", headers=wsec,
                        json={"worker": "w"}).json()["jobs"][0]
    assert first["payload"]["track_id"] == queued[2]


def test_resolving_a_pending_track_again_promotes_it(client, hdr, queued):
    """Asking for it a second time means you are waiting on it."""
    db.run("""update jobs set priority=%s where (payload->>'track_id')::int = %s""",
           (jobs.PRIORITY_BULK, queued[1]))
    client.post("/tracks/resolve", headers=hdr, json={"video_id": "USER1"})
    row = db.one("""select priority from jobs where kind='ingest'
                     and (payload->>'track_id')::int = %s""", (queued[1],))
    assert row["priority"] == jobs.PRIORITY_NOW


def test_pausing_stops_work_being_handed_out(client, hdr, queued, wsec):
    client.post("/downloads/pause", headers=hdr, json={"paused": True})
    assert client.get("/downloads", headers=hdr).json()["paused"] is True
    assert client.post("/internal/jobs/lease", headers=wsec,
                       json={"worker": "w"}).json()["jobs"] == []

    # and the worker still counts as alive while paused, so the UI does not claim it
    # has gone away
    status = client.get("/status", headers=hdr).json()
    assert status["ingest_worker"] == "w"

    client.post("/downloads/pause", headers=hdr, json={"paused": False})
    assert client.post("/internal/jobs/lease", headers=wsec,
                       json={"worker": "w"}).json()["jobs"] != []


def test_a_whole_batch_can_be_cancelled(client, hdr, queued):
    r = client.post("/downloads/cancel", headers=hdr,
                    json={"batch_id": "spotify:PL1"}).json()
    assert r["cancelled"] == 10
    after = client.get("/downloads", headers=hdr).json()
    assert after["counts"]["waiting"] == 3, "the tracks you asked for survive"
    assert after["batches"] == [] or after["batches"][0]["remaining"] == 0


def test_cancelling_one_track_leaves_the_rest(client, hdr, queued):
    assert client.post("/downloads/cancel", headers=hdr,
                       json={"track_id": queued[1]}).json()["cancelled"] == 1
    assert client.get("/downloads", headers=hdr).json()["counts"]["waiting"] == 12
    assert client.get(f"/tracks/{queued[1]}", headers=hdr).json()["fail_code"] == "cancelled"


def test_cancel_needs_something_to_cancel(client, hdr):
    assert client.post("/downloads/cancel", headers=hdr, json={}).status_code == 400


def test_failures_can_be_retried_in_bulk(client, hdr, queued, wsec):
    job = client.post("/internal/jobs/lease", headers=wsec,
                      json={"worker": "w"}).json()["jobs"][0]
    client.post(f"/internal/jobs/{job['id']}/fail", headers=wsec,
                json={"reason": "This video is unavailable", "track_id": queued[0]})
    assert client.get("/downloads", headers=hdr).json()["counts"]["failed"] == 1

    assert client.post("/downloads/retry-failed", headers=hdr,
                       json={}).json()["retrying"] == 1
    after = client.get("/downloads", headers=hdr).json()
    assert after["counts"]["failed"] == 0
    # a person choosing "try again" is new information, so the attempt count resets
    assert db.one("select attempts from jobs where id=%s", (job["id"],))["attempts"] == 0
    assert client.get(f"/tracks/{queued[0]}", headers=hdr).json()["state"] == "pending"


def test_retrying_can_be_limited_to_one_batch(client, hdr, queued, wsec):
    job = client.post("/internal/jobs/lease", headers=wsec,
                      json={"worker": "w"}).json()["jobs"][0]
    client.post(f"/internal/jobs/{job['id']}/fail", headers=wsec,
                json={"reason": "boom", "track_id": queued[0], "retryable": False})
    assert client.post("/downloads/retry-failed", headers=hdr,
                       json={"batch_id": "spotify:PL1"}).json()["retrying"] == 0
    assert client.post("/downloads/retry-failed", headers=hdr,
                       json={}).json()["retrying"] == 1


def test_emptying_the_whole_queue(client, hdr, queued):
    """A mirror that pulled in far more than you meant it to has one way out."""
    assert client.post("/downloads/cancel", headers=hdr,
                       json={"all": True}).json()["cancelled"] == 13
    assert client.get("/downloads", headers=hdr).json()["counts"]["waiting"] == 0


def test_batches_say_how_many_there_are(client, hdr, queued):
    over = client.get("/downloads", headers=hdr).json()
    assert over["batches_total"] == len(over["batches"]) >= 1
