"""Playlist covers. Every playlist has one, and it is made of the records in it."""
from __future__ import annotations

import io

import pytest
from PIL import Image

from muse import catalog, db, enrich, playlist_art


def _png(colour, size=(700, 700)) -> bytes:
    buf = io.BytesIO()
    Image.new("RGB", size, colour).save(buf, format="PNG")
    return buf.getvalue()


def _track_with_cover(client, hdr, cfg, playlist_id: int, n: int, colour) -> dict:
    t = catalog.create_from_ytm({"video_id": f"ART{n}", "title": f"Song {n}",
                                 "artists": ["Tester"], "album": f"Album {n}",
                                 "duration_ms": 120_000})
    cover = enrich.store_cover(cfg, _png(colour), "test")
    db.run("update tracks set cover_id=%s where id=%s", (cover["id"], t["id"]))
    client.post(f"/playlists/{playlist_id}/items", headers=hdr,
                json={"track_ids": [t["id"]]})
    return t


@pytest.fixture()
def playlist_with_art(client, hdr, cfg):
    """Three tracks, each with a cover of its own."""
    p = client.post("/playlists", headers=hdr, json={"name": "Bands"}).json()
    for i, colour in enumerate([(200, 40, 30), (30, 120, 200), (240, 210, 40)]):
        _track_with_cover(client, hdr, cfg, p["id"], i, colour)
    return p


def test_every_playlist_offers_a_cover(client, hdr):
    """Including an empty one — a playlist with no art still gets a picture."""
    p = client.post("/playlists", headers=hdr, json={"name": "Empty"}).json()
    # By name: Favourites is a playlist too, and it sorts first.
    listed = next(x for x in client.get("/playlists", headers=hdr).json()
                  if x["name"] == "Empty")
    assert listed["cover_url"] == f"/playlists/{p['id']}/cover"
    assert listed["cover_version"]

    r = client.get(f"/playlists/{p['id']}/cover", headers=hdr)
    assert r.status_code == 200 and r.headers["content-type"] == "image/jpeg"
    assert Image.open(io.BytesIO(r.content)).size == (640, 640)


def test_the_cover_is_built_from_the_records_in_it(client, hdr, playlist_with_art):
    r = client.get(f"/playlists/{playlist_with_art['id']}/cover", headers=hdr)
    img = Image.open(io.BytesIO(r.content)).convert("RGB")

    # Each album occupies a slanted band, so all three colours are on the canvas.
    seen = {img.getpixel((x, 320))[:3] for x in range(40, 600, 20)}
    def near(target):
        return any(sum(abs(a - b) for a, b in zip(px, target)) < 210 for px in seen)
    assert near((200, 40, 30)) and near((30, 120, 200)) and near((240, 210, 40)), \
        "the bands must show the covers, not a wash over them"


def test_the_version_changes_when_the_playlist_does(client, hdr, cfg, playlist_with_art):
    def version():
        return next(p["cover_version"] for p in client.get("/playlists", headers=hdr).json()
                    if p["id"] == playlist_with_art["id"])

    before = version()
    assert version() == before, "the same playlist must render the same picture"

    # A track with no cover of its own changes nothing about the picture.
    plain = catalog.create_from_ytm({"video_id": "PLAIN", "title": "No art",
                                     "artists": ["Tester"], "album": None,
                                     "duration_ms": 90_000})
    client.post(f"/playlists/{playlist_with_art['id']}/items", headers=hdr,
                json={"track_ids": [plain["id"]]})
    assert version() == before

    # A fourth record does.
    _track_with_cover(client, hdr, cfg, playlist_with_art["id"], 9, (20, 200, 90))
    assert version() != before


def test_a_playlist_cover_needs_a_key_or_a_token(client, hdr):
    p = client.post("/playlists", headers=hdr, json={"name": "Private"}).json()
    assert client.get(f"/playlists/{p['id']}/cover").status_code == 401

    key = client.get("/auth/stream-key", headers=hdr).json()["key"]
    assert client.get(f"/playlists/{p['id']}/cover?k={key}").status_code == 200


def test_someone_elses_playlist_is_not_yours_to_look_at(client, hdr, playlist_with_art):
    client.post("/accounts", headers=hdr,
                json={"name": "nosy", "password": "hunter2hunter2"})
    theirs = client.post("/auth/login",
                         data={"user": "nosy", "password": "hunter2hunter2"}).json()["token"]
    assert client.get(f"/playlists/{playlist_with_art['id']}/cover",
                      headers={"Authorization": f"Bearer {theirs}"}).status_code == 404


def test_four_covers_at_most_spread_across_the_playlist(client, hdr, playlist_with_art):
    picks = playlist_art._picks(playlist_with_art["id"])
    assert len(picks) <= playlist_art.COVERS_PER_ART
    assert [p["pos"] for p in picks] == sorted(p["pos"] for p in picks)
