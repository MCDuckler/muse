"""The show's shared snapshots: listed to every account, saved over with a revision by
anyone, renamed and taken away by whoever shared it."""
from muse import auth


def _other():
    other = auth.ensure_user("someone", pw_hash=auth.hash_password("x"))
    return {"Authorization": f"Bearer {auth.issue_token(other, 'Their desk', 'app')}"}


RULES = {"rules": [{"scene": "milk", "weight": 0.0}, {"style": "ascii", "shot": ["dancers.fisheye"], "weight": 0.0}]}


def test_a_shared_snapshot_is_everyones_to_use_and_save_over(client, hdr):
    assert client.get("/booth/show/snapshots", headers=hdr).json() == {"snapshots": []}
    r = client.post("/booth/show/snapshots", headers=hdr, json={"name": "  Calm night  ", "doc": RULES})
    assert r.status_code == 201
    snap = r.json()
    assert snap["name"] == "Calm night" and snap["rev"] == 1 and snap["mine"] and snap["doc"] == RULES

    theirs = _other()
    listed = client.get("/booth/show/snapshots", headers=theirs).json()["snapshots"]
    assert [s["id"] for s in listed] == [snap["id"]]
    assert not listed[0]["mine"] and listed[0]["owner"] == snap["owner"]

    # Another account saves over it; a desk with the older copy is told so.
    more = {"rules": RULES["rules"] + [{"ground": "white", "weight": 2.0}]}
    saved = client.put(f"/booth/show/snapshots/{snap['id']}", headers=theirs, json={"doc": more, "rev": 1})
    assert saved.status_code == 200
    assert saved.json()["rev"] == 2 and saved.json()["updated_by"] == "someone"
    stale = client.put(f"/booth/show/snapshots/{snap['id']}", headers=hdr, json={"doc": RULES, "rev": 1})
    assert stale.status_code == 409 and stale.json()["detail"]["rev"] == 2
    assert stale.json()["detail"]["doc"] == more

    # Renamed and taken away only by whoever shared it.
    assert client.put(f"/booth/show/snapshots/{snap['id']}", headers=theirs,
                      json={"doc": more, "rev": 2, "name": "Mine now"}).status_code == 403
    renamed = client.put(f"/booth/show/snapshots/{snap['id']}", headers=hdr, json={"doc": more, "rev": 2, "name": "Calmer"})
    assert renamed.json()["name"] == "Calmer"
    assert client.delete(f"/booth/show/snapshots/{snap['id']}", headers=theirs).status_code == 403
    assert client.delete(f"/booth/show/snapshots/{snap['id']}", headers=hdr).status_code == 204
    assert client.get("/booth/show/snapshots", headers=theirs).json() == {"snapshots": []}
    assert client.put(f"/booth/show/snapshots/{snap['id']}", headers=hdr, json={"doc": more, "rev": 3}).status_code == 404


def test_a_snapshot_needs_a_name_and_rules(client, hdr):
    assert client.post("/booth/show/snapshots", headers=hdr, json={"name": " ", "doc": RULES}).status_code == 400
    assert client.post("/booth/show/snapshots", headers=hdr, json={"name": "x", "doc": "no"}).status_code == 400
    big = {"rules": [{"scene": "x" * 1000, "weight": 1.0}] * 100}
    assert client.post("/booth/show/snapshots", headers=hdr, json={"name": "x", "doc": big}).status_code == 413
    assert client.get("/booth/show/snapshots").status_code == 401
