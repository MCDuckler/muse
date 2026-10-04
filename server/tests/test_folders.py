"""Folders: the divider cards in the record box, and where each list is filed."""
from __future__ import annotations

import pytest


@pytest.fixture()
def three(client, hdr):
    return [client.post("/playlists", headers=hdr, json={"name": n}).json()["id"]
            for n in ("Dub", "Disco", "Drive")]


@pytest.fixture()
def tracks(client, hdr):
    return [client.post("/tracks/resolve", headers=hdr, json={"video_id": vid}).json()["id"]
            for vid in ("AAA", "BBB", "CCC")]


def _listed(client, hdr) -> dict:
    return {p["id"]: p for p in client.get("/playlists", headers=hdr).json()}


def test_a_folder_holds_lists_and_the_list_says_where_it_sits(client, hdr, three):
    f = client.post("/playlist-folders", headers=hdr, json={"name": "Nights"}).json()
    assert f["name"] == "Nights" and f["count"] == 0 and f["parent_id"] is None

    for pid in three[:2]:
        r = client.post(f"/playlists/{pid}/place", headers=hdr, json={"folder_id": f["id"]})
        assert r.status_code == 200 and r.json()["folder_id"] == f["id"]

    listed = _listed(client, hdr)
    assert listed[three[0]]["folder_id"] == f["id"]
    assert listed[three[1]]["folder_id"] == f["id"]
    assert listed[three[2]]["folder_id"] is None
    # Filed in the order they went in.
    assert listed[three[0]]["place_pos"] < listed[three[1]]["place_pos"]

    folders = client.get("/playlist-folders", headers=hdr).json()["items"]
    assert [(x["name"], x["count"]) for x in folders] == [("Nights", 2)]


def test_a_list_moves_between_folders_and_back_to_the_box(client, hdr, three):
    a = client.post("/playlist-folders", headers=hdr, json={"name": "A"}).json()["id"]
    b = client.post("/playlist-folders", headers=hdr, json={"name": "B"}).json()["id"]
    client.post(f"/playlists/{three[0]}/place", headers=hdr, json={"folder_id": a})
    client.post(f"/playlists/{three[0]}/place", headers=hdr, json={"folder_id": b})
    assert _listed(client, hdr)[three[0]]["folder_id"] == b
    client.post(f"/playlists/{three[0]}/place", headers=hdr, json={"folder_id": None})
    assert _listed(client, hdr)[three[0]]["folder_id"] is None
    counts = {x["id"]: x["count"] for x in
              client.get("/playlist-folders", headers=hdr).json()["items"]}
    assert counts == {a: 0, b: 0}


def test_deleting_a_folder_leaves_the_lists_in_the_box(client, hdr, three):
    f = client.post("/playlist-folders", headers=hdr, json={"name": "Gone"}).json()["id"]
    for pid in three:
        client.post(f"/playlists/{pid}/place", headers=hdr, json={"folder_id": f})
    r = client.delete(f"/playlist-folders/{f}", headers=hdr)
    assert r.json() == {"deleted": f, "freed": 3}
    listed = _listed(client, hdr)
    assert all(listed[pid]["folder_id"] is None for pid in three)
    assert len(listed) >= 3, "not one playlist went with the folder"


def test_a_folder_is_renamed_and_nested_but_never_into_itself(client, hdr):
    f = client.post("/playlist-folders", headers=hdr, json={"name": "Old"}).json()["id"]
    g = client.post("/playlist-folders", headers=hdr, json={"name": "Outer"}).json()["id"]
    assert client.patch(f"/playlist-folders/{f}", headers=hdr,
                        json={"name": "New", "parent_id": g}).json()["parent_id"] == g
    assert client.patch(f"/playlist-folders/{f}", headers=hdr,
                        json={"parent_id": f}).status_code == 400
    assert client.post("/playlist-folders", headers=hdr, json={"name": "  "}).status_code == 400


def test_a_friends_list_can_be_filed_in_your_own_folder(client, hdr, three):
    client.post("/accounts", headers=hdr, json={"name": "pal", "password": "hunter2hunter2"})
    theirs = {"Authorization": "Bearer " + client.post(
        "/auth/login", data={"user": "pal", "password": "hunter2hunter2"}).json()["token"]}
    client.post(f"/playlists/{three[0]}/save", headers=theirs)
    f = client.post("/playlist-folders", headers=theirs, json={"name": "From chris"}).json()["id"]
    r = client.post(f"/playlists/{three[0]}/place", headers=theirs, json={"folder_id": f})
    assert r.status_code == 200
    assert {p["id"]: p for p in client.get("/playlists", headers=theirs).json()}[three[0]][
        "folder_id"] == f
    # Theirs is theirs: the owner's own view of the same list is unfiled, and their
    # folders are not yours to use.
    assert _listed(client, hdr)[three[0]]["folder_id"] is None
    assert client.post(f"/playlists/{three[1]}/place", headers=hdr,
                       json={"folder_id": f}).status_code == 404
    assert client.get("/playlist-folders", headers=hdr).json()["items"] == []


def test_pins_and_recently_opened(client, hdr, three):
    listed = _listed(client, hdr)
    assert listed[three[0]]["pinned"] is False and listed[three[0]]["last_opened_at"] is None

    assert client.post(f"/playlists/{three[0]}/pin", headers=hdr,
                       json={"pinned": True}).json()["pinned"] is True
    client.get(f"/playlists/{three[1]}", headers=hdr)
    listed = _listed(client, hdr)
    assert listed[three[0]]["pinned"] is True
    assert listed[three[1]]["last_opened_at"] is not None
    assert listed[three[2]]["last_opened_at"] is None
    # Pinning did not count as opening, and opening did not unfile anything.
    assert listed[three[0]]["last_opened_at"] is None

    fav = next(p for p in listed.values() if p["kind"] == "favourites")
    client.get(f"/playlists/{fav['id']}", headers=hdr)
    assert _listed(client, hdr)[fav["id"]]["last_opened_at"] is None, \
        "the heart is not a list anybody opens on purpose"


def test_playing_a_folder_plays_each_song_once_in_folder_order(client, hdr, three, tracks):
    f = client.post("/playlist-folders", headers=hdr, json={"name": "Set"}).json()["id"]
    client.post(f"/playlists/{three[1]}/items", headers=hdr,
                json={"track_ids": [tracks[1], tracks[0]]})
    client.post(f"/playlists/{three[0]}/items", headers=hdr,
                json={"track_ids": [tracks[0], tracks[2]]})
    # Disco is filed first, then Dub.
    client.post(f"/playlists/{three[1]}/place", headers=hdr, json={"folder_id": f})
    client.post(f"/playlists/{three[0]}/place", headers=hdr, json={"folder_id": f})
    got = client.get(f"/playlist-folders/{f}/tracks", headers=hdr).json()["items"]
    assert [t["id"] for t in got] == [tracks[1], tracks[0], tracks[2]]
