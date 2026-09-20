"""One account, several things to listen on, and moving the music between them.

What is checked here is the shape of it: a device says what it is doing, the others can
read that, and asking one of them to take over is a message addressed to that device
and to nobody else's account.
"""
from __future__ import annotations

import pytest

from muse import app as app_mod
from muse import auth, catalog, db


@pytest.fixture()
def desk(client):
    """A second device of the same person: the browser at their desk."""
    me = db.one("select id from users where name='chris'")["id"]
    token = auth.issue_token(me, "The desk", "web")
    # By its token rather than "the newest row": the fixtures that log in are resolved
    # in whatever order the test asks for them, and the newest row is sometimes the
    # test's own session.
    return {"hdr": {"Authorization": f"Bearer {token}"},
            "id": db.one("select id from devices where token_hash=%s",
                         (auth.token_hash(token),))["id"]}


@pytest.fixture()
def song():
    return catalog.create_from_ytm({
        "video_id": "VDEV1", "title": "Something On", "artists": ["A Band"],
        "album": None, "duration_ms": 200_000, "raw": {},
    }, discovered_via=catalog.VIA_USER, download=False)


def test_a_device_says_what_it_is_doing_and_the_others_can_read_it(
        client, hdr, desk, song):
    queue = client.post("/queues", headers=hdr, json={"name": "Evening"}).json()
    said = client.post("/devices/state", headers=desk["hdr"], json={
        "playing": True, "track_id": song["id"], "queue_id": queue["id"],
        "position_ms": 42_000, "kind": "browser",
    })
    assert said.status_code == 200

    mine = client.get("/devices", headers=hdr).json()
    others = {d["name"]: d for d in mine["devices"]}
    assert others["The desk"]["playing"] is True
    assert others["The desk"]["track"]["title"] == "Something On"
    assert others["The desk"]["queue"] == "Evening"
    assert others["The desk"]["position_ms"] == 42_000
    assert others["The desk"]["this"] is False
    assert others["The desk"]["live"] is True

    # And the desk knows which one it is itself.
    theirs = client.get("/devices", headers=desk["hdr"]).json()
    assert theirs["this"] == desk["id"]
    assert next(d for d in theirs["devices"] if d["id"] == desk["id"])["this"] is True


def test_a_device_that_has_gone_quiet_is_not_offering_to_play_anything(
        client, hdr, desk, song):
    client.post("/devices/state", headers=desk["hdr"],
                json={"playing": True, "track_id": song["id"]})
    db.run("update devices set state_at = now() - interval '10 minutes' where id=%s",
           (desk["id"],))

    listed = {d["name"]: d for d in client.get("/devices", headers=hdr).json()["devices"]}
    assert listed["The desk"]["live"] is False
    assert listed["The desk"]["playing"] is False, \
        'a laptop closed an hour ago is not still playing'


def test_handing_the_music_over_is_addressed_to_one_device(client, hdr, desk, song,
                                                           monkeypatch):
    sent = []
    monkeypatch.setattr(app_mod, "publish",
                        lambda event, data, to_user=None: sent.append(
                            (event, data, to_user)))
    me = db.one("select id from users where name='chris'")["id"]
    queue = client.post("/queues", headers=hdr, json={"name": "Evening"}).json()
    # The phone is playing; the desk is asked to take over from where it got to.
    client.post("/devices/state", headers=hdr, json={
        "playing": True, "track_id": song["id"], "queue_id": queue["id"],
        "position_ms": 61_000})
    sent.clear()

    out = client.post(f"/devices/{desk['id']}/command", headers=hdr, json={
        "action": "take", "queue_id": queue["id"], "track_id": song["id"],
        "position_ms": 61_000,
    })
    assert out.status_code == 200
    assert out.json()["to"] == "The desk"

    orders = [d for (e, d, u) in sent if e == "device_command"]
    assert orders[0]["to"] == desk["id"]
    assert orders[0]["action"] == "take"
    assert orders[0]["position_ms"] == 61_000
    assert all(u == me for (_, _, u) in sent), \
        'somebody else\'s browser has no business hearing this'

    # Whoever had the music lets go of it: the point of moving it between rooms is
    # that it is in one of them.
    assert orders[1]["action"] == "yield" and orders[1]["except"] == desk["id"]
    assert db.one("select playing from devices where id<>%s and user_id=%s",
                  (desk["id"], me))["playing"] is False


def test_you_cannot_send_orders_to_somebody_elses_device(client, hdr):
    them = auth.ensure_user("joe")
    auth.issue_token(them, "Joe's phone", "android")
    theirs = db.one("select id from devices where user_id=%s", (them,))["id"]

    refused = client.post(f"/devices/{theirs}/command", headers=hdr,
                          json={"action": "pause"})
    assert refused.status_code == 404
    assert client.patch(f"/devices/{theirs}", headers=hdr,
                        json={"name": "Mine now"}).status_code == 404


def test_a_device_can_be_given_a_name_you_chose(client, hdr, desk):
    named = client.patch(f"/devices/{desk['id']}", headers=hdr,
                         json={"name": "Study iMac"})
    assert named.status_code == 200
    listed = [d["name"] for d in client.get("/devices", headers=hdr).json()["devices"]]
    assert "Study iMac" in listed and "The desk" not in listed
    assert client.patch(f"/devices/{desk['id']}", headers=hdr,
                        json={"name": "   "}).status_code == 400


def test_nonsense_is_not_an_action(client, hdr, desk):
    assert client.post(f"/devices/{desk['id']}/command", headers=hdr,
                       json={"action": "explode"}).status_code == 400
