"""The cue check: a list of records to check by ear, spread over the tempos and the
same each time, and what was said about each kept."""
from __future__ import annotations

from muse import db


def _records(client, hdr, n: int) -> list[int]:
    me = db.one("select id from users where name='chris'")["id"]
    ids = []
    for i in range(n):
        t = client.post("/tracks/resolve", headers=hdr, json={"video_id": f"CHK{i:05d}"}).json()
        db.run("update tracks set state='ready', bpm=%s, duration_ms=240000 where id=%s",
               (90 + (i % 8) * 12, t["id"]))
        db.run("insert into library_items(user_id, track_id) values(%s,%s) on conflict do nothing",
               (me, t["id"]))
        ids.append(t["id"])
    return ids


def test_the_list_is_spread_over_the_tempos_and_the_same_each_time(client, hdr):
    _records(client, hdr, 24)
    # 90…174 in steps of 12 fills five of the six bands (none in 118–126).
    a = client.get("/booth/check?n=5", headers=hdr).json()
    b = client.get("/booth/check?n=5", headers=hdr).json()
    assert [i["track"]["id"] for i in a["items"]] == [i["track"]["id"] for i in b["items"]]
    bpms = {i["track"]["bpm"] for i in a["items"]}
    assert len(bpms) == 5, "one from each band before a second from any"
    assert a["checked"] == 0


def test_a_check_is_kept_and_can_be_taken_back(client, hdr):
    t = _records(client, hdr, 5)[0]
    r = client.put(f"/booth/check/{t}", headers=hdr, json={
        "grid": "half", "note": "the kick is on two",
        "pads": {"1": {"ms": 8000, "auto": True}, "4": {"ms": 180000, "auto": False}}})
    assert r.status_code == 200, r.text
    got = {i["track"]["id"]: i for i in client.get("/booth/check?n=5", headers=hdr).json()["items"]}
    assert got[t]["grid"] == "half" and got[t]["checked_at"] and got[t]["note"] == "the kick is on two"
    row = db.one("select pads, beats_version from cue_checks where track_id=%s", (t,))
    assert row["pads"]["4"] == {"ms": 180000, "auto": False} and row["beats_version"]
    assert client.put(f"/booth/check/{t}", headers=hdr, json={"grid": "maybe"}).status_code == 400
    assert client.put(f"/booth/check/{t}", headers=hdr, json={"pads": {"1": 5}}).status_code == 400
    assert client.put("/booth/check/999999", headers=hdr, json={"grid": "ok"}).status_code == 404
    client.delete(f"/booth/check/{t}", headers=hdr)
    got = {i["track"]["id"]: i for i in client.get("/booth/check?n=5", headers=hdr).json()["items"]}
    assert got[t]["checked_at"] is None
