"""A mix kept on a playlist: what the booth did between its songs, handed back as it
was written, and taken off again."""
from __future__ import annotations


def test_a_playlist_keeps_a_mix_and_gives_it_back(client, hdr):
    playlist = client.post("/playlists", headers=hdr, json={"name": "Saturday"}).json()
    assert playlist.get("mix") is None
    mix = {"version": 1,
           "transitions": [{"from": 1, "to": 2, "kind": "blend", "bars": 16,
                            "out_ms": 160000, "in_ms": 469, "tempo": 1.02}]}
    kept = client.patch(f"/playlists/{playlist['id']}", headers=hdr, json={"mix": mix}).json()
    assert kept["mix"] == mix
    again = client.get(f"/playlists/{playlist['id']}", headers=hdr).json()
    assert again["mix"] == mix, "as it was written"

    renamed = client.patch(f"/playlists/{playlist['id']}", headers=hdr, json={"name": "Sat"}).json()
    assert renamed["name"] == "Sat" and renamed["mix"] == mix, "a rename leaves the mix"

    plain = client.patch(f"/playlists/{playlist['id']}", headers=hdr, json={"mix": None}).json()
    assert plain["mix"] is None


def test_a_mix_has_to_be_an_object(client, hdr):
    playlist = client.post("/playlists", headers=hdr, json={"name": "X"}).json()
    r = client.patch(f"/playlists/{playlist['id']}", headers=hdr, json={"mix": "no"})
    assert r.status_code == 400
    r = client.patch(f"/playlists/{playlist['id']}", headers=hdr, json={})
    assert r.status_code == 400
