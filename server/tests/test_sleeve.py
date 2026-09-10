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


def test_the_record_comes_apart_for_the_player(client, hdr, track_with_cover):
    """The player animates the jacket and the disc separately, so it asks for each."""
    for part in ("jacket", "disc"):
        r = client.get(f"/tracks/{track_with_cover['id']}/cover?style={part}", headers=hdr)
        assert r.status_code == 200, part
        assert r.headers["content-type"] == "image/webp"
        img = Image.open(io.BytesIO(r.content)).convert("RGBA")
        assert img.size == (sleeve.CANVAS, sleeve.CANVAS)
        assert img.getpixel((img.width // 2, img.height // 2))[3] == 255, \
            f"the {part} must be solid where it exists"


def test_a_disc_is_round_and_a_jacket_is_not(client, hdr, track_with_cover):
    def corner(part):
        r = client.get(f"/tracks/{track_with_cover['id']}/cover?style={part}", headers=hdr)
        return Image.open(io.BytesIO(r.content)).convert("RGBA").getpixel((10, 10))[3]

    assert corner("disc") < 20, "a disc has nothing in the corners of its canvas"
    assert corner("jacket") > 200, "a jacket does"


def test_a_cover_is_rebuilt_out_of_flat_facets(client, hdr):
    """The point of the render: a few hundred flat planes, not a filtered photograph.

    Measured as flatness rather than as colour count. A low-poly render is piecewise
    constant — walk across it and the colour under you changes only when you cross an
    edge — and that is true whatever the picture was. A filter over a photograph, which
    is what the old wear pass was, is not.
    """
    import random

    from PIL import Image

    rng = random.Random(4)
    art = Image.new("RGB", (400, 400))
    # Noise: no two neighbouring pixels alike, so any flatness in the output is the
    # render's doing and not the source's.
    art.putdata([(rng.randrange(256), rng.randrange(256), rng.randrange(256))
                 for _ in range(400 * 400)])

    def flatness(im: Image.Image) -> float:
        px = im.convert("RGB").load()
        w, h = im.size
        same = 0
        for y in range(0, h, 3):
            for x in range(0, w - 1, 3):
                a, b = px[x, y], px[x + 1, y]
                if max(abs(a[i] - b[i]) for i in range(3)) <= 4:
                    same += 1
        return same / ((h // 3) * ((w - 1) // 3))

    out = sleeve.facet(art, 400, sleeve.edition("abc123abc123"))
    # Noise is the worst case for this: every part of the picture reads as detail, so
    # the facets end up as small as they ever get. Even then most of the render is
    # flat, and the source has none of it — which is the difference being asserted.
    assert flatness(art) < 0.05, "the source really is noise"
    assert flatness(out) > 0.45, f"only {flatness(out):.0%} of it is flat"


def test_a_cover_keeps_its_own_colours(client, hdr, tmp_path):
    """Faceted, not repainted. A red record stays red."""
    from PIL import Image

    art = Image.new("RGB", (400, 400), (196, 44, 40))
    out = sleeve.facet(art, 400, sleeve.edition("abc123abc123"))
    r, g, b = out.convert("RGB").resize((1, 1), Image.BILINEAR).getpixel((0, 0))
    assert r > g + 60 and r > b + 60, f"still red, got {(r, g, b)}"


def test_two_records_are_not_the_same_record(client, hdr):
    """Condition, stock and the odd punched corner come from the cover's own hash."""
    editions = [sleeve.edition(f"{n:012x}") for n in range(60)]
    assert len({e["condition"] for e in editions}) == 3
    assert any(e["cut_out"] for e in editions)
    # Every copy is lit from its own direction. Two records lit identically look
    # printed; two lit differently look like objects on a shelf.
    assert len({e["light"] for e in editions}) > 50
    assert sleeve.edition("abc123abc123")["condition"] == \
        sleeve.edition("abc123abc123")["condition"]
