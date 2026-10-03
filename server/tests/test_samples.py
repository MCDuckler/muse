"""The board's own sounds: a person's, short, served whole or by range, cut out of a
record on the server where the record is; and the board itself, one document with a
revision that two screens cannot quietly overwrite."""
from __future__ import annotations

import io
import pathlib
import subprocess

from muse import catalog, db


def _tone(path: pathlib.Path, seconds: float = 1.5, ext: str = "wav") -> pathlib.Path:
    out = path / f"hit.{ext}"
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "lavfi",
                    "-i", f"sine=frequency=220:duration={seconds}", str(out)], check=True)
    return out


def _upload(client, hdr, path, name=None):
    with path.open("rb") as fh:
        return client.post("/samples" + (f"?name={name}" if name else ""), headers=hdr,
                           files={"audio": (path.name, io.BytesIO(fh.read()), "audio/wav")})


def test_a_sample_is_kept_listed_shaped_served_and_forgotten(client, hdr, tmp_path):
    r = _upload(client, hdr, _tone(tmp_path), name="Air horn")
    assert r.status_code == 201, r.text
    s = r.json()
    assert s["name"] == "Air horn"
    assert 1400 <= s["duration_ms"] <= 1600
    assert len(s["shape"]) == 128 and max(s["shape"]) == 255

    mine = client.get("/samples", headers=hdr).json()["samples"]
    assert [m["id"] for m in mine] == [s["id"]]

    whole = client.get(s["audio_url"], headers=hdr)
    assert whole.status_code == 200 and whole.headers["accept-ranges"] == "bytes"
    part = client.get(s["audio_url"], headers={**hdr, "Range": "bytes=0-99"})
    assert part.status_code == 206 and len(part.content) == 100

    renamed = client.patch(f"/samples/{s['id']}", headers=hdr, json={"name": "Horn"}).json()
    assert renamed["name"] == "Horn"

    gone = client.delete(f"/samples/{s['id']}", headers=hdr)
    assert gone.status_code == 200
    assert client.get("/samples", headers=hdr).json()["samples"] == []
    assert client.get(s["audio_url"], headers=hdr).status_code == 404


def test_a_sample_is_its_owners_and_not_a_track(client, hdr, tmp_path):
    from muse import auth
    s = _upload(client, hdr, _tone(tmp_path)).json()
    other = auth.ensure_user("someone", pw_hash=auth.hash_password("x"))
    token = auth.issue_token(other, "Their phone", "app")
    theirs = {"Authorization": f"Bearer {token}"}
    assert client.get("/samples", headers=theirs).json()["samples"] == []
    assert client.get(s["audio_url"], headers=theirs).status_code == 404
    assert client.delete(f"/samples/{s['id']}", headers=theirs).status_code == 404
    assert db.one("select count(*) as n from tracks")["n"] == 0


def test_what_is_not_audio_or_too_long_is_refused(client, hdr, tmp_path):
    r = client.post("/samples", headers=hdr,
                    files={"audio": ("notes.txt", io.BytesIO(b"hello"), "text/plain")})
    assert r.status_code == 415
    r = _upload(client, hdr, _tone(tmp_path, seconds=61))
    assert r.status_code == 413


def test_bars_cut_out_of_a_record(client, hdr, tmp_path):
    song = catalog.create_from_ytm({
        "video_id": "VCUT1", "title": "Long One", "artists": ["A Band"],
        "album": None, "duration_ms": 8000, "raw": {},
    }, discovered_via=catalog.VIA_USER, download=False)
    # Give it audio the way a finished fetch would.
    from muse import storage
    from muse.deps import cfg
    with _tone(tmp_path, seconds=8, ext="m4a").open("rb") as fh:
        digest, path, size = storage.store_stream(cfg().audio_dir, fh, ".m4a")
    db.run("insert into media(track_id,sha256,codec,bitrate,bytes,path,role) values(%s,%s,'aac',128,%s,%s,'canonical')",
           (song["id"], digest, size, str(path)))

    r = client.post("/samples/cut", headers=hdr,
                    json={"track_id": song["id"], "from_ms": 2000, "to_ms": 4000, "name": "Bar 2"})
    assert r.status_code == 201, r.text
    s = r.json()
    assert s["name"] == "Bar 2"
    assert 1900 <= s["duration_ms"] <= 2100
    assert s["origin"] == {"kind": "cut", "track_id": song["id"], "from_ms": 2000, "to_ms": 4000}

    assert client.post("/samples/cut", headers=hdr,
                       json={"track_id": song["id"], "from_ms": 4000, "to_ms": 3000}).status_code == 400
    assert client.post("/samples/cut", headers=hdr,
                       json={"track_id": 999999, "from_ms": 0, "to_ms": 1000}).status_code == 404


def test_the_board_is_one_document_with_a_revision(client, hdr):
    assert client.get("/booth/board", headers=hdr).json() == {"doc": None, "rev": 0}
    doc = {"banks": [{"name": "A", "pads": [None] * 16}], "level": 0.8}
    r = client.put("/booth/board", headers=hdr, json={"doc": doc, "rev": 0})
    assert r.status_code == 200 and r.json()["rev"] == 1
    got = client.get("/booth/board", headers=hdr).json()
    assert got["doc"] == doc and got["rev"] == 1

    # A screen saving over a copy it read before the last save is told so, with the
    # board as it is.
    stale = client.put("/booth/board", headers=hdr, json={"doc": {**doc, "level": 0.2}, "rev": 0})
    assert stale.status_code == 409
    assert stale.json()["detail"]["rev"] == 1
    fresh = client.put("/booth/board", headers=hdr, json={"doc": {**doc, "level": 0.2}, "rev": 1})
    assert fresh.json()["rev"] == 2
    assert client.put("/booth/board", headers=hdr, json={"doc": "no", "rev": 2}).status_code == 400


def test_the_house_shelf_is_everyones_to_hear_and_its_keepers_to_change(client, hdr, tmp_path):
    """A house sound is listed to every account beside its own, heard and fetched by
    anyone signed in, and renamed or removed only by whoever loaded it."""
    from muse import auth
    from muse.routes_samples import _keep
    keeper = auth.user_for_token(hdr["Authorization"].split(" ", 1)[1])["id"]
    horn = _keep(keeper, _tone(tmp_path), "Air horn (canned)", {
        "kind": "house", "order": 0, "group": "Horns & sirens",
        "pad": {"name": "Air Horn", "colour": "orange", "mode": "oneShot", "choke": 0, "duck": 0},
        "words": None, "license": "cc0"}, house=True)
    other = auth.ensure_user("someone", pw_hash=auth.hash_password("x"))
    theirs = {"Authorization": f"Bearer {auth.issue_token(other, 'Their phone', 'app')}"}

    listed = client.get("/samples", headers=theirs).json()
    assert listed["samples"] == []
    assert [h["id"] for h in listed["house"]] == [horn["id"]]
    h = listed["house"][0]
    assert h["group"] == "Horns & sirens" and h["pad"]["name"] == "Air Horn" and len(h["shape"]) == 128

    # The keeper's own list is their own sounds: the shelf is beside it, not in it.
    assert client.get("/samples", headers=hdr).json()["samples"] == []

    assert client.get(h["audio_url"], headers=theirs).status_code == 200
    assert client.get(f"/samples/{horn['id']}/shape", headers=theirs).status_code == 200
    assert client.patch(f"/samples/{horn['id']}", headers=theirs, json={"name": "Mine now"}).status_code == 404
    assert client.delete(f"/samples/{horn['id']}", headers=theirs).status_code == 404
    assert client.get(h["audio_url"], headers=theirs).status_code == 200
