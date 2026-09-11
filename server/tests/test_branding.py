"""The picture on the home screen, and who may change it."""
from __future__ import annotations

import io

from PIL import Image


def a_picture(colour: tuple[int, int, int], size: int = 300) -> bytes:
    buf = io.BytesIO()
    Image.new("RGB", (size, size + 40), colour).save(buf, format="PNG")
    return buf.getvalue()


def test_the_icon_is_served_without_signing_in(client):
    """The browser fetches the manifest, the favicon and the home-screen icon itself,
    long before anybody has signed in, and it has never heard of our token."""
    r = client.get("/icon", params={"size": 192})
    assert r.status_code == 200, r.text
    assert r.headers["content-type"] == "image/png"
    assert Image.open(io.BytesIO(r.content)).size == (192, 192)


def test_any_size_is_answered_by_the_nearest_one_above(client):
    assert Image.open(io.BytesIO(client.get("/icon", params={"size": 40}).content)) \
        .size == (64, 64)
    assert Image.open(io.BytesIO(client.get("/icon", params={"size": 2000}).content)) \
        .size == (1024, 1024)


def test_an_admin_changes_it_and_everybody_sees_the_new_one(client, hdr):
    was = client.get("/icon.json", headers=hdr).json()
    assert was["custom"] is False and was["may_change"] is True

    r = client.post("/icon", headers={**hdr, "Content-Type": "application/octet-stream"},
                    content=a_picture((10, 200, 90)))
    assert r.status_code == 200, r.text
    assert r.json()["custom"] is True
    assert r.json()["version"] != was["version"], "a new picture is a new version"

    icon = Image.open(io.BytesIO(client.get("/icon", params={"size": 192}).content))
    assert icon.size == (192, 192)
    # Squared off from the middle, not letterboxed: a launcher crops it to whatever
    # shape it likes and bars at the edges become bars in a circle.
    assert icon.getpixel((96, 96))[1] > 150

    # And back again.
    client.delete("/icon", headers=hdr)
    now = client.get("/icon.json", headers=hdr).json()
    assert now["custom"] is False
    assert now["version"] == was["version"], "the one it came with, unchanged"


def test_only_an_admin_may_change_it(client, hdr):
    client.post("/accounts", headers=hdr,
                json={"name": "sam", "password": "correct-horse"})
    token = client.post("/auth/login",
                        data={"user": "sam", "password": "correct-horse"}).json()["token"]
    theirs = {"Authorization": f"Bearer {token}"}

    assert client.get("/icon.json", headers=theirs).json()["may_change"] is False
    assert client.post("/icon", headers={**theirs,
                                         "Content-Type": "application/octet-stream"},
                       content=a_picture((200, 10, 10))).status_code == 403
    assert client.delete("/icon", headers=theirs).status_code == 403


def test_a_file_that_is_not_a_picture_is_refused(client, hdr):
    r = client.post("/icon", headers={**hdr, "Content-Type": "application/octet-stream"},
                    content=b"this is not a png")
    assert r.status_code == 400
    assert "picture" in r.json()["detail"]
