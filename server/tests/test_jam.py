"""Listening together. The rules that matter: a guest can reach into the host's queue,
and only into that one."""
from __future__ import annotations

import pytest

from muse import db


@pytest.fixture()
def guest(client, hdr):
    client.post("/accounts", headers=hdr, json={"name": "sam", "password": "correct-horse"})
    token = client.post("/auth/login",
                        data={"user": "sam", "password": "correct-horse"}).json()["token"]
    return {"Authorization": f"Bearer {token}"}


@pytest.fixture()
def jam(client, hdr):
    queue = client.post("/queues", headers=hdr, json={"name": "Kitchen"}).json()
    started = client.post("/jams", headers=hdr, json={"queue_id": queue["id"]}).json()
    return {**started, "queue": queue}


def test_a_jam_hands_back_a_code_people_can_read_out(client, hdr, jam):
    assert len(jam["code"]) == 6
    assert set(jam["code"]) <= set("ABCDEFGHJKMNPQRSTUVWXYZ23456789"), \
        "no letters that get misheard when read aloud"
    assert jam["is_host"] and jam["listening"] == 1


def test_starting_twice_is_the_same_jam(client, hdr, jam):
    again = client.post("/jams", headers=hdr, json={"queue_id": jam["queue"]["id"]}).json()
    assert again["id"] == jam["id"] and again["code"] == jam["code"]


def test_a_guest_joins_and_can_put_something_on(client, hdr, guest, jam):
    joined = client.post("/jams/join", headers=guest, json={"code": jam["code"]}).json()
    assert joined["id"] == jam["id"] and joined["is_host"] is False
    assert {m["name"] for m in joined["members"]} == {"chris", "sam"}

    track = client.post("/tracks/resolve", headers=guest,
                        json={"query": "something"}).json()
    added = client.post(f"/queues/{jam['queue']['id']}/items", headers=guest,
                        json={"track_ids": [track["id"]]})
    assert added.status_code == 200

    state = client.get(f"/queues/{jam['queue']['id']}", headers=hdr).json()
    assert state["items"][0]["added_by"] == "sam", "the queue remembers who put it on"


def test_a_stranger_cannot_touch_the_queue(client, hdr, guest, jam):
    """Not being in the jam is the same as the queue not existing."""
    assert client.get(f"/queues/{jam['queue']['id']}", headers=guest).status_code == 404


def test_the_host_can_close_the_door(client, hdr, guest, jam):
    client.post("/jams/join", headers=guest, json={"code": jam["code"]})
    client.patch(f"/jams/{jam['id']}", headers=hdr, json={"guests_can_add": False})

    track = client.post("/tracks/resolve", headers=guest, json={"query": "no"}).json()
    r = client.post(f"/queues/{jam['queue']['id']}/items", headers=guest,
                    json={"track_ids": [track["id"]]})
    assert r.status_code == 403
    assert "turned off" in r.json()["detail"]
    # Reading is still fine: you can watch without being able to add.
    assert client.get(f"/queues/{jam['queue']['id']}", headers=guest).status_code == 200


def test_a_code_that_is_not_a_jam_says_so(client, guest):
    r = client.post("/jams/join", headers=guest, json={"code": "ZZZZZZ"})
    assert r.status_code == 404 and "not belong" in r.json()["detail"]


def test_skipping_takes_more_than_one_voice(client, hdr, guest, jam):
    """One person's opinion is not the room's."""
    track = client.post("/tracks/resolve", headers=hdr, json={"query": "on now"}).json()
    client.post(f"/queues/{jam['queue']['id']}/items", headers=hdr,
                json={"track_ids": [track["id"]]})
    client.post("/jams/join", headers=guest, json={"code": jam["code"]})
    # Voting is off unless the host turns it on: a guest skipping the host's music by
    # default was not what "listen together" is supposed to mean.
    client.patch(f"/jams/{jam['id']}", headers=hdr, json={"guests_can_skip": True})

    first = client.post(f"/jams/{jam['id']}/skip-vote", headers=guest, json={}).json()
    assert first["votes"] == 1 and first["passed"] is False

    again = client.post(f"/jams/{jam['id']}/skip-vote", headers=guest, json={}).json()
    assert again["votes"] == 1, "voting twice is still one voice"

    passed = client.post(f"/jams/{jam['id']}/skip-vote", headers=hdr, json={}).json()
    assert passed["passed"] is True


def test_the_host_leaving_ends_it(client, hdr, guest, jam):
    client.post("/jams/join", headers=guest, json={"code": jam["code"]})
    assert client.post(f"/jams/{jam['id']}/leave", headers=hdr).json()["ended"] is True

    assert client.get("/jams/current", headers=guest).json()["jam"] is None
    assert client.get(f"/queues/{jam['queue']['id']}", headers=guest).status_code == 404


def test_a_guest_leaving_leaves_the_jam_running(client, hdr, guest, jam):
    client.post("/jams/join", headers=guest, json={"code": jam["code"]})
    client.post(f"/jams/{jam['id']}/leave", headers=guest)
    assert client.get("/jams/current", headers=hdr).json()["jam"]["listening"] == 1


def test_current_says_what_is_playing(client, hdr, jam):
    track = client.post("/tracks/resolve", headers=hdr, json={"query": "on now"}).json()
    client.post(f"/queues/{jam['queue']['id']}/items", headers=hdr,
                json={"track_ids": [track["id"]]})
    state = client.get("/jams/current", headers=hdr).json()["jam"]
    assert state["now_playing"]["id"] == track["id"]
    assert state["code"] == jam["code"]


def test_only_the_host_changes_the_rules(client, hdr, guest, jam):
    client.post("/jams/join", headers=guest, json={"code": jam["code"]})
    r = client.patch(f"/jams/{jam['id']}", headers=guest, json={"guests_can_add": False})
    assert r.status_code == 403


def test_the_host_can_remove_someone(client, hdr, guest, jam):
    joined = client.post("/jams/join", headers=guest, json={"code": jam["code"]}).json()
    sam = next(m["user_id"] for m in joined["members"] if m["name"] == "sam")
    client.post(f"/jams/{jam['id']}/remove", headers=hdr, json={"user_id": sam})
    assert client.get("/jams/current", headers=guest).json()["jam"] is None
    assert db.one("select count(*) n from jam_members where jam_id=%s",
                  (jam["id"],))["n"] == 1


def test_a_guests_song_reaches_the_host(client, hdr, guest, jam, monkeypatch):
    """The whole point of a jam: what a guest adds has to show up on the host's device.

    The host's app finds out over the event stream, so this asserts on what is
    published — without it the song landed in the database and nothing ever told the
    machine that is playing.
    """
    from muse import routes_library

    published: list[tuple[str, dict]] = []
    monkeypatch.setattr(routes_library, "_publish",
                        lambda event, data: published.append((event, data)))

    client.post("/jams/join", headers=guest, json={"code": jam["code"]})
    track = client.post("/tracks/resolve", headers=guest, json={"query": "a song"}).json()
    client.post(f"/queues/{jam['queue']['id']}/items", headers=guest,
                json={"track_ids": [track["id"]]})

    changes = [d for e, d in published if e == "queue_changed"]
    assert changes, "adding to the queue must announce itself"
    assert changes[-1]["queue_id"] == jam["queue"]["id"]
    assert changes[-1]["by"] == "sam", "and say who did it"


def test_moving_to_the_next_track_is_announced(client, hdr, jam, monkeypatch):
    """So the people listening along see what is on now."""
    from muse import routes_library

    published: list[tuple[str, dict]] = []
    monkeypatch.setattr(routes_library, "_publish",
                        lambda event, data: published.append((event, data)))

    for n in range(2):
        t = client.post("/tracks/resolve", headers=hdr,
                        json={"video_id": f"JAM{n}"}).json()
        client.post(f"/queues/{jam['queue']['id']}/items", headers=hdr,
                    json={"track_ids": [t["id"]]})
    published.clear()

    # The position is saved every ten seconds while playing. That is not news.
    client.patch(f"/queues/{jam['queue']['id']}/cursor", headers=hdr,
                 json={"position_ms": 4000})
    assert not [d for e, d in published if e == "queue_changed"]

    # Moving to the next track is.
    client.patch(f"/queues/{jam['queue']['id']}/cursor", headers=hdr,
                 json={"cursor_index": 1, "position_ms": 0})
    moved = [d for e, d in published if e == "queue_changed"]
    assert moved and moved[-1]["cursor_moved"] is True
    assert moved[-1]["cursor_index"] == 1
