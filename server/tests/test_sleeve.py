"""The now-playing artwork is a record, not a file. See sleeve.py for why."""
from __future__ import annotations

import io

import pytest
from PIL import Image

from muse import db, enrich, sleeve


def _png(colour=(180, 70, 40), size=(700, 700)) -> bytes:
    buf = io.BytesIO()
    Image.new("RGB", size, colour).save(buf, format="PNG")
    return buf.getvalue()


@pytest.fixture()
def track_with_cover(client, hdr, wsec, complete_job, cfg):
    t = client.post("/tracks/resolve", headers=hdr, json={"query": "test song"}).json()
    job = client.post("/internal/jobs/lease", headers=wsec,
                      json={"worker": "w"}).json()["jobs"][0]
    complete_job(job["id"], t["id"])
    cover = enrich.store_cover(cfg, _png(), "test")
    db.run("update tracks set cover_id=%s where id=%s", (cover["id"], t["id"]))
    return t


def test_the_cover_can_be_asked_for_as_a_record(client, hdr, track_with_cover):
    r = client.get(f"/tracks/{track_with_cover['id']}/cover?style=sleeve", headers=hdr)
    assert r.status_code == 200
    assert r.headers["content-type"] == "image/webp"

    img = Image.open(io.BytesIO(r.content))
    assert img.size == (sleeve.CANVAS, sleeve.CANVAS)
    assert img.mode in ("RGBA", "RGB"), "the shadow needs an alpha channel"
    # The jacket does not fill the frame: there is room for the disc and the shadow.
    corner = img.convert("RGBA").getpixel((4, 4))
    assert corner[3] < 40, "the corners must stay transparent, not paint a box"


def test_the_flat_cover_is_still_the_default(client, hdr, track_with_cover):
    r = client.get(f"/tracks/{track_with_cover['id']}/cover", headers=hdr)
    assert r.headers["content-type"] == "image/jpeg"


def test_a_record_is_rendered_once_and_kept(client, hdr, cfg, track_with_cover):
    client.get(f"/tracks/{track_with_cover['id']}/cover?style=sleeve", headers=hdr)
    sha = db.one("""select c.sha256 from tracks t join covers c on c.id=t.cover_id
                     where t.id=%s""", (track_with_cover["id"],))["sha256"]
    made = sleeve.path_for(cfg.cover_dir, sha, "lg")
    assert made.exists()
    stamp = made.stat().st_mtime_ns

    client.get(f"/tracks/{track_with_cover['id']}/cover?style=sleeve", headers=hdr)
    assert made.stat().st_mtime_ns == stamp, "a second request must not re-render"


def test_the_same_cover_always_wears_the_same_way(cfg, track_with_cover):
    """Marks are seeded from the cover's hash: a record you know stays the record you
    know, and two records never look alike."""
    src = db.one("""select c.path, c.sha256 from tracks t join covers c on c.id=t.cover_id
                     where t.id=%s""", (track_with_cover["id"],))
    import pathlib
    a = sleeve.render(pathlib.Path(src["path"]), (180, 70, 40), src["sha256"])
    b = sleeve.render(pathlib.Path(src["path"]), (180, 70, 40), src["sha256"])
    assert a.tobytes() == b.tobytes()

    other = sleeve.render(pathlib.Path(src["path"]), (180, 70, 40), "ffffffffffff")
    assert other.tobytes() != a.tobytes()


def test_a_record_needs_a_key_or_a_token(client, track_with_cover):
    assert client.get(
        f"/tracks/{track_with_cover['id']}/cover?style=sleeve").status_code == 401
