"""The back of a record, drawn on.

A board belongs to a song and to a person. In a jam it is the host's, so everybody in
the room draws on the same sleeve rather than each on their own copy — which is the
only thing about this that needed any thought.
"""
from __future__ import annotations

import pytest


@pytest.fixture()
def tracks(client, hdr):
    """Two records to turn over."""
    return [client.post("/tracks/resolve", headers=hdr, json={"video_id": v}).json()
            for v in ("AAA", "BBB")]


def _draw(client, hdr, track_id, stroke="a", points=None, done=False, ink=0):
    return client.post(f"/tracks/{track_id}/marks", headers=hdr, json={
        "stroke_id": stroke, "points": points or [0.1, 0.1, 0.5, 0.5],
        "done": done, "ink": ink})


def test_a_board_belongs_to_one_song(client, hdr, tracks):
    one, two = tracks[0]["id"], tracks[1]["id"]
    assert _draw(client, hdr, one).status_code == 201

    here = client.get(f"/tracks/{one}/marks", headers=hdr).json()
    assert len(here["strokes"]) == 1
    elsewhere = client.get(f"/tracks/{two}/marks", headers=hdr).json()
    assert elsewhere["strokes"] == [], "the next record has its own back"


def test_a_stroke_still_being_drawn_grows_rather_than_repeating(client, hdr, tracks):
    """Strokes are sent as they are drawn, several times a second. Each one has to be
    the same stroke getting longer, or a single line arrives as forty."""
    t = tracks[0]["id"]
    _draw(client, hdr, t, points=[0.1, 0.1, 0.2, 0.2])
    _draw(client, hdr, t, points=[0.1, 0.1, 0.2, 0.2, 0.3, 0.35])
    _draw(client, hdr, t, points=[0.1, 0.1, 0.2, 0.2, 0.3, 0.35, 0.4, 0.5], done=True)

    strokes = client.get(f"/tracks/{t}/marks", headers=hdr).json()["strokes"]
    assert len(strokes) == 1
    assert len(strokes[0]["points"]) == 8
    assert strokes[0]["done"] is True


def test_a_line_can_be_taken_back_and_the_board_cleared(client, hdr, tracks):
    t = tracks[0]["id"]
    _draw(client, hdr, t, stroke="a")
    _draw(client, hdr, t, stroke="b")

    client.delete(f"/tracks/{t}/marks/a", headers=hdr)
    left = client.get(f"/tracks/{t}/marks", headers=hdr).json()["strokes"]
    assert [s["stroke_id"] for s in left] == ["b"]

    client.delete(f"/tracks/{t}/marks", headers=hdr)
    assert client.get(f"/tracks/{t}/marks", headers=hdr).json()["strokes"] == []


def test_points_are_kept_inside_the_sleeve(client, hdr, tracks):
    t = tracks[0]["id"]
    _draw(client, hdr, t, points=[-4.0, 9.0, 0.5, 0.5])
    stroke = client.get(f"/tracks/{t}/marks", headers=hdr).json()["strokes"][0]
    assert stroke["points"][0] == 0.0 and stroke["points"][1] == 1.0


def test_a_half_pair_is_refused(client, hdr, tracks):
    r = client.post(f"/tracks/{tracks[0]['id']}/marks", headers=hdr,
                    json={"stroke_id": "a", "points": [0.1, 0.2, 0.3]})
    assert r.status_code == 400


@pytest.fixture()
def guest(client, hdr):
    client.post("/accounts", headers=hdr,
                json={"name": "sam", "password": "correct-horse"})
    token = client.post("/auth/login",
                        data={"user": "sam", "password": "correct-horse"}).json()["token"]
    return {"Authorization": f"Bearer {token}"}


@pytest.fixture()
def room(client, hdr, guest):
    queue = client.post("/queues", headers=hdr, json={"name": "Kitchen"}).json()
    started = client.post("/jams", headers=hdr, json={"queue_id": queue["id"]}).json()
    client.post("/jams/join", headers=guest, json={"code": started["code"]})
    return started


def test_in_a_jam_everybody_draws_on_the_hosts_sleeve(client, hdr, guest, room, tracks):
    """The point of the whole thing: one record going round a table, collecting
    everybody's handwriting — not everybody getting their own copy of it."""
    t = tracks[0]["id"]
    assert _draw(client, hdr, t, stroke="host").status_code == 201
    assert _draw(client, guest, t, stroke="guest", ink=3).status_code == 201

    for who in (hdr, guest):
        board = client.get(f"/tracks/{t}/marks", headers=who).json()
        assert sorted(s["stroke_id"] for s in board["strokes"]) == ["guest", "host"], \
            "both people see both lines"

    # And it is the host's board that both of them are on.
    mine = client.get(f"/tracks/{t}/marks", headers=hdr).json()
    theirs = client.get(f"/tracks/{t}/marks", headers=guest).json()
    assert mine["owner_id"] == theirs["owner_id"]


def test_a_guest_can_take_back_their_own_line_but_not_clear_the_board(
        client, hdr, guest, room, tracks):
    """The line is yours even when the sleeve is not."""
    t = tracks[0]["id"]
    _draw(client, hdr, t, stroke="host")
    _draw(client, guest, t, stroke="guest")

    assert client.delete(f"/tracks/{t}/marks/host", headers=guest).json()["removed"] == 0
    assert client.delete(f"/tracks/{t}/marks/guest", headers=guest).json()["removed"] == 1
    assert client.delete(f"/tracks/{t}/marks", headers=guest).status_code == 403

    left = client.get(f"/tracks/{t}/marks", headers=hdr).json()["strokes"]
    assert [s["stroke_id"] for s in left] == ["host"]


def test_a_private_board_stays_private(client, hdr, guest, tracks):
    """No jam, no sharing. Somebody else's sleeve is not readable by asking for it."""
    t = tracks[0]["id"]
    _draw(client, hdr, t, stroke="mine")

    me = client.get("/me", headers=hdr).json()
    r = client.get(f"/tracks/{t}/marks", headers=guest,
                   params={"owner": me["user_id"]})
    assert r.status_code == 403

    assert client.get(f"/tracks/{t}/marks", headers=guest).json()["strokes"] == []


def test_leaving_the_jam_gives_you_your_own_sleeve_back(client, hdr, guest, room,
                                                        tracks):
    t = tracks[0]["id"]
    _draw(client, guest, t, stroke="in-the-room")
    client.post(f"/jams/{room['id']}/leave", headers=guest)

    alone = client.get(f"/tracks/{t}/marks", headers=guest).json()
    assert alone["strokes"] == [], "back to a blank board of their own"
    still = client.get(f"/tracks/{t}/marks", headers=hdr).json()["strokes"]
    assert [s["stroke_id"] for s in still] == ["in-the-room"], \
        "and what they drew stays on the host's"
