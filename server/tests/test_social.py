"""The other people on this server.

The catalog has always been shared and there was no way to see that. These are about
the three things this adds: seeing who else is here (and that one of them has a jam
going), keeping somebody else's playlist, and being let in to add to one.
"""
from __future__ import annotations

import pytest

from muse import auth, catalog, db


@pytest.fixture()
def joe(client):
    """Somebody else, with a library and a list of their own."""
    them = auth.ensure_user("joe")
    track = catalog.create_from_ytm({
        "video_id": "VJOE1", "title": "Their Song", "artists": ["A Band"],
        "album": None, "duration_ms": 180_000, "raw": {},
    }, discovered_via=catalog.VIA_USER)
    catalog.remember(them, track["id"])
    playlist = db.one(
        "insert into playlists(owner_id,name,kind) values(%s,'Joe picks','local') "
        "returning *", (them,))
    db.run("insert into playlist_items(playlist_id,pos,track_id) values(%s,0,%s)",
           (playlist["id"], track["id"]))
    return {"id": them, "track": track, "playlist": playlist,
            "hdr": {"Authorization":
                    f"Bearer {auth.issue_token(them, 'joes phone', None)}"}}


def test_everybody_here_is_listed_with_what_they_have(client, hdr, joe):
    said = client.get("/social/people", headers=hdr).json()
    names = {p["name"]: p for p in said["people"]}
    assert "joe" in names and "chris" in names
    assert names["joe"]["songs"] == 1
    assert names["joe"]["playlists"] == 1
    assert names["joe"]["jam"] is None
    assert said["you"] == db.one("select id from users where name='chris'")["id"]


def test_what_somebody_has_on_right_now(client, hdr, joe):
    """A playing device writes where it has got to every ten seconds, which is what
    makes a queue resumable — and, read the other way round, what everybody else is
    listening to. Nothing new is written for this."""
    queue = db.one(
        "insert into queues(user_id,name,cursor_index) values(%s,'Joe drives',0) "
        "returning *", (joe["id"],))
    # Two songs, and the cursor on the second: positions are a sort key with gaps in
    # them, so the row the cursor names is the nth by position, not the one whose
    # position is n.
    other = catalog.create_from_ytm({
        "video_id": "VJOE2", "title": "The Other One", "artists": ["A Band"],
        "album": None, "duration_ms": 200_000, "raw": {},
    }, discovered_via=catalog.VIA_USER)
    db.run("insert into queue_items(queue_id,pos,track_id) values(%s,5,%s),(%s,9,%s)",
           (queue["id"], joe["track"]["id"], queue["id"], other["id"]))
    db.run("update queues set cursor_index=1, updated_at=now() where id=%s",
           (queue["id"],))

    people = {p["name"]: p
              for p in client.get("/social/people", headers=hdr).json()["people"]}
    on = people["joe"]["playing"]
    assert on is not None, 'the screen called People is for what people are doing'
    assert on["track"]["title"] == "The Other One"
    assert on["queue"] == "Joe drives"
    assert on["now"] is True

    # Nobody is listening to a queue nobody has touched since breakfast.
    db.run("update queues set updated_at=now() - interval '2 hours' where id=%s",
           (queue["id"],))
    people = {p["name"]: p
              for p in client.get("/social/people", headers=hdr).json()["people"]}
    assert people["joe"]["playing"] is None

    # And one touched a few minutes ago is what they were on, not what they are on.
    db.run("update queues set updated_at=now() - interval '5 minutes' where id=%s",
           (queue["id"],))
    people = {p["name"]: p
              for p in client.get("/social/people", headers=hdr).json()["people"]}
    assert people["joe"]["playing"]["now"] is False


def test_a_jam_shows_without_having_to_be_looked_for(client, hdr, joe):
    """A jam is a thing happening now, and a thing happening now is no use to anybody
    who has to go looking for it."""
    queue = client.post("/queues", headers=joe["hdr"],
                        json={"name": "Joe's queue"}).json()
    jam = client.post("/jams", headers=joe["hdr"],
                      json={"queue_id": queue["id"]}).json()

    people = client.get("/social/people", headers=hdr).json()["people"]
    theirs = next(p for p in people if p["name"] == "joe")
    assert theirs["jam"]["code"] == jam["code"]
    assert theirs["jam"]["people"] >= 1

    # And on their profile, where the way in is.
    profile = client.get(f"/social/people/{joe['id']}", headers=hdr).json()
    assert profile["jam"]["code"] == jam["code"]


def test_their_library_can_be_looked_through(client, hdr, joe):
    said = client.get(f"/social/people/{joe['id']}/library", headers=hdr).json()
    assert said["total"] == 1
    assert said["items"][0]["title"] == "Their Song"


def test_their_playlists_are_listed_but_not_their_favourites(client, hdr, joe):
    # Favourites is the heart on a row, not a list made to be read.
    client.post(f"/favourites/{joe['track']['id']}", headers=joe["hdr"], json={})
    lists = client.get(f"/social/people/{joe['id']}/playlists", headers=hdr).json()
    assert [p["name"] for p in lists] == ["Joe picks"]
    assert lists[0]["saved"] is False


def test_saving_somebody_elses_playlist_keeps_it_theirs(client, hdr, joe):
    pid = joe["playlist"]["id"]
    assert client.post(f"/playlists/{pid}/save", headers=hdr).status_code == 201

    mine = client.get("/playlists", headers=hdr).json()
    kept = next(p for p in mine if p["id"] == pid)
    assert kept["saved"] is True
    assert kept["owner_name"] == "joe", "whose it is travels with it"

    # A save, not a copy: what is on it is whatever is on it now.
    opened = client.get(f"/playlists/{pid}", headers=hdr).json()
    assert opened["mine"] is False
    assert opened["saved"] is True
    assert [i["title"] for i in opened["items"]] == ["Their Song"]
    assert opened["editable"] is False, "somebody else's list is read-only by default"

    client.delete(f"/playlists/{pid}/save", headers=hdr)
    assert all(p["id"] != pid for p in client.get("/playlists", headers=hdr).json())


def test_you_cannot_save_your_own(client, hdr):
    mine = client.post("/playlists", headers=hdr, json={"name": "Mine"}).json()
    assert client.post(f"/playlists/{mine['id']}/save",
                       headers=hdr).status_code == 409


def test_somebody_elses_list_cannot_be_written_to_until_they_say_so(
        client, hdr, joe):
    pid = joe["playlist"]["id"]
    r = client.post(f"/playlists/{pid}/items", headers=hdr,
                    json={"track_ids": [joe["track"]["id"]]})
    assert r.status_code == 403
    assert "somebody else's" in r.json()["detail"].lower()


def test_the_owner_can_let_others_add_to_it(client, hdr, joe):
    pid = joe["playlist"]["id"]
    assert client.post(f"/playlists/{pid}/open-edit", headers=joe["hdr"],
                       json={"open_edit": True}).json()["open_edit"] is True

    mine = catalog.create_from_ytm({
        "video_id": "VMINE1", "title": "My Song", "artists": ["Someone"],
        "album": None, "duration_ms": 120_000, "raw": {},
    }, discovered_via=catalog.VIA_USER)
    r = client.post(f"/playlists/{pid}/items", headers=hdr,
                    json={"track_ids": [mine["id"]]})
    assert r.status_code == 200, r.text
    assert client.get(f"/playlists/{pid}", headers=hdr).json()["editable"] is True

    # And taking it back closes it again.
    client.post(f"/playlists/{pid}/open-edit", headers=joe["hdr"],
                json={"open_edit": False})
    assert client.post(f"/playlists/{pid}/items", headers=hdr,
                       json={"track_ids": [mine["id"]]}).status_code == 403


def test_only_the_owner_decides_who_may_edit(client, hdr, joe):
    """Including somebody who has been let in, who could otherwise hand it round."""
    pid = joe["playlist"]["id"]
    client.post(f"/playlists/{pid}/open-edit", headers=joe["hdr"],
                json={"open_edit": True})
    assert client.post(f"/playlists/{pid}/open-edit", headers=hdr,
                       json={"open_edit": False}).status_code == 404


def test_nobody_can_read_somebody_elses_favourites(client, hdr, joe):
    client.post(f"/favourites/{joe['track']['id']}", headers=joe["hdr"], json={})
    theirs = db.one("select id from playlists where owner_id=%s and kind='favourites'",
                    (joe["id"],))
    assert client.get(f"/playlists/{theirs['id']}", headers=hdr).status_code == 404
