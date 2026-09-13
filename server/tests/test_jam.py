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


def test_the_room_shares_the_queue_both_ways(client, hdr, guest, jam):
    """There is no door to close any more: a jam is a queue everybody in it can use."""
    client.post("/jams/join", headers=guest, json={"code": jam["code"]})
    track = client.post("/tracks/resolve", headers=guest, json={"query": "theirs"}).json()
    added = client.post(f"/queues/{jam['queue']['id']}/items", headers=guest,
                        json={"track_ids": [track["id"]]})
    assert added.status_code == 200, added.text
    # And the host sees it, because it is one queue and not two.
    host_sees = client.get(f"/queues/{jam['queue']['id']}", headers=hdr).json()
    assert track["id"] in [i["id"] for i in host_sees["items"]]


def test_a_code_that_is_not_a_jam_says_so(client, guest):
    r = client.post("/jams/join", headers=guest, json={"code": "ZZZZZZ"})
    assert r.status_code == 404 and "not belong" in r.json()["detail"]

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


# ---------------- the transport ----------------
def test_the_room_hears_where_the_host_is(client, hdr, guest, jam):
    """A jam used to share a queue and nothing else, so two people in it were listening
    to the same list at different points in it. The host's player says where the music
    is; everybody else reads it."""
    track = client.post("/tracks/resolve", headers=hdr, json={"query": "on now"}).json()
    client.post("/jams/join", headers=guest, json={"code": jam["code"]})

    pushed = client.post(f"/jams/{jam['id']}/playback", headers=hdr,
                         json={"track_id": track["id"], "position_ms": 45_000,
                               "playing": True})
    assert pushed.status_code == 200, pushed.text

    seen = client.get("/jams/current", headers=guest).json()["jam"]["playback"]
    assert seen["track_id"] == track["id"]
    assert seen["playing"] is True
    assert seen["position_ms"] == 45_000
    # Stamped by the server, so a device reading it late knows how late it is.
    assert 0 <= seen["age_ms"] < 5_000


def test_only_the_host_sets_the_time(client, hdr, guest, jam):
    client.post("/jams/join", headers=guest, json={"code": jam["code"]})
    r = client.post(f"/jams/{jam['id']}/playback", headers=guest,
                    json={"position_ms": 1000, "playing": True})
    assert r.status_code == 403


def test_everybody_in_the_room_works_the_controls(client, hdr, guest, jam):
    """A jam has no rules any more: whoever is in it can play, pause and skip."""
    client.post("/jams/join", headers=guest, json={"code": jam["code"]})
    for action in ("pause", "play", "next", "previous"):
        r = client.post(f"/jams/{jam['id']}/control", headers=guest,
                        json={"action": action})
        assert r.status_code == 200, f"{action}: {r.text}"
    assert client.post(f"/jams/{jam['id']}/control", headers=hdr,
                       json={"action": "next"}).status_code == 200


def test_a_stranger_cannot_reach_the_controls(client, hdr, guest, jam):
    r = client.post(f"/jams/{jam['id']}/control", headers=guest, json={"action": "play"})
    assert r.status_code == 403


def test_an_invented_action_is_refused(client, hdr, jam):
    r = client.post(f"/jams/{jam['id']}/control", headers=hdr, json={"action": "eject"})
    assert r.status_code == 400


def test_the_rooms_with_the_lights_on_are_listed(client, hdr, guest, jam):
    """Everybody here already has an account, so nobody should have to be read a code
    by somebody sitting next to them."""
    listed = client.get("/jams", headers=guest).json()["items"]
    assert len(listed) == 1
    room = listed[0]
    assert room["host"] == "chris"
    assert room["code"] == jam["code"]
    assert room["listening"] == 1, "the host is in it"
    assert room["joined"] is False, "and this person is not"

    client.post("/jams/join", headers=guest, json={"code": jam["code"]})
    after = client.get("/jams", headers=guest).json()["items"][0]
    assert after["joined"] is True and after["listening"] == 2


def test_what_is_playing_is_part_of_choosing(client, hdr, guest, jam):
    track = client.post("/tracks/resolve", headers=hdr, json={"query": "on now"}).json()
    client.post(f"/queues/{jam['queue']['id']}/items", headers=hdr,
                json={"track_ids": [track["id"]]})
    client.patch(f"/queues/{jam['queue']['id']}/cursor", headers=hdr,
                 json={"cursor_index": 0})

    room = client.get("/jams", headers=guest).json()["items"][0]
    assert room["playing"] == track["title"]
    assert room["queue"] == "Kitchen"


def test_a_jam_that_has_ended_is_not_offered(client, hdr, guest, jam):
    client.post(f"/jams/{jam['id']}/leave", headers=hdr)      # the host leaving ends it
    assert client.get("/jams", headers=guest).json()["items"] == []


def test_the_room_follows_the_host_to_another_queue(client, hdr):
    """A host putting a different queue on is the room moving, not the room ending.

    Without this the jam kept the queue it was opened with: the host listened to what
    they had chosen and everybody else watched a list nobody was playing.
    """
    from muse import auth, db

    first = client.post("/queues", headers=hdr, json={"name": "First"}).json()
    second = client.post("/queues", headers=hdr, json={"name": "Second"}).json()
    made = client.post("/jams", headers=hdr, json={"queue_id": first["id"]}).json()

    guest = auth.ensure_user("guest")
    ghdr = {"Authorization": f"Bearer {auth.issue_token(guest, 'phone', None)}"}
    client.post("/jams/join", headers=ghdr, json={"code": made["code"]})

    moved = client.post(f"/jams/{made['id']}/queue", headers=hdr,
                        json={"queue_id": second["id"]})
    assert moved.status_code == 200, moved.text
    assert moved.json()["queue_id"] == second["id"]

    # And what a guest is told when they ask where the room is.
    theirs = client.get("/jams/current", headers=ghdr).json()["jam"]
    assert theirs["queue_id"] == second["id"]
    assert db.one("select queue_id from jams where id=%s",
                  (made["id"],))["queue_id"] == second["id"]


def test_only_the_host_moves_the_room(client, hdr):
    """A room anybody can change by opening their own queue is not a room."""
    from muse import auth

    queue = client.post("/queues", headers=hdr, json={"name": "Host's"}).json()
    made = client.post("/jams", headers=hdr, json={"queue_id": queue["id"]}).json()

    guest = auth.ensure_user("interloper")
    ghdr = {"Authorization": f"Bearer {auth.issue_token(guest, 'phone', None)}"}
    client.post("/jams/join", headers=ghdr, json={"code": made["code"]})
    mine = client.post("/queues", headers=ghdr, json={"name": "Mine"}).json()

    r = client.post(f"/jams/{made['id']}/queue", headers=ghdr,
                    json={"queue_id": mine["id"]})
    assert r.status_code == 403


def test_the_host_cannot_move_the_room_to_somebody_elses_queue(client, hdr):
    from muse import auth

    queue = client.post("/queues", headers=hdr, json={"name": "Host's"}).json()
    made = client.post("/jams", headers=hdr, json={"queue_id": queue["id"]}).json()

    other = auth.ensure_user("elsewhere")
    ohdr = {"Authorization": f"Bearer {auth.issue_token(other, 'phone', None)}"}
    theirs = client.post("/queues", headers=ohdr, json={"name": "Theirs"}).json()

    r = client.post(f"/jams/{made['id']}/queue", headers=hdr,
                    json={"queue_id": theirs["id"]})
    assert r.status_code == 404
