"""What the booth did and what was thought of it is kept, per person."""
from __future__ import annotations


def test_a_mix_and_its_rating_are_kept(client, hdr):
    r = client.post("/booth/feedback", headers=hdr, json={
        "event": "mix", "from_track": 1, "to_track": 2, "kind": "stemBlend", "bars": 32,
        "shift": 0, "out_ms": 180000, "in_ms": 20000, "detail": {"why": "stem by stem"}})
    assert r.status_code == 200, r.text
    r = client.post("/booth/feedback", headers=hdr, json={
        "event": "rating", "from_track": 1, "to_track": 2, "kind": "stemBlend", "bars": 32, "rating": 1})
    assert r.status_code == 200
    assert client.post("/booth/feedback", headers=hdr, json={"event": "nope"}).status_code == 400
    assert client.post("/booth/feedback", headers=hdr, json={"event": "rating", "rating": 5}).status_code == 400
    got = client.get("/booth/feedback", headers=hdr).json()["feedback"]
    assert [g["event"] for g in got] == ["rating", "mix"]
    assert got[1]["detail"] == {"why": "stem by stem"} and got[0]["rating"] == 1
