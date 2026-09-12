"""Uploads are the only tracks that cannot be re-fetched, so they get the careful path."""
from __future__ import annotations

import io
import pathlib
import subprocess

import pytest

FFMPEG = "ffmpeg"


def _tone(path: pathlib.Path, seconds: float = 2.0, codec: str = "aac",
          ext: str = "m4a", freq: int = 440, title: str | None = None) -> pathlib.Path:
    out = path / f"tone.{ext}"
    cmd = [FFMPEG, "-v", "error", "-y", "-f", "lavfi",
           "-i", f"sine=frequency={freq}:duration={seconds}", "-c:a", codec]
    if title:
        cmd += ["-metadata", f"title={title}", "-metadata", "artist=Test Artist",
                "-metadata", "album=Test Album", "-metadata", "date=1999"]
    cmd.append(str(out))
    subprocess.run(cmd, check=True)
    return out


@pytest.fixture()
def tmp_audio(tmp_path):
    return tmp_path


def _post(client, hdr, path: pathlib.Path):
    with path.open("rb") as fh:
        return client.post("/uploads", headers=hdr,
                           files={"audio": (path.name, io.BytesIO(fh.read()), "audio/mp4")})


def test_upload_reads_tags_and_measures_loudness(client, hdr, tmp_audio):
    f = _tone(tmp_audio, title="Tagged Song")
    r = _post(client, hdr, f)
    assert r.status_code == 201
    body = r.json()
    assert body["title"] == "Tagged Song"
    assert body["artists"] == ["Test Artist"]
    assert body["album"] == "Test Album"
    assert body["source"] == "custom" and body["state"] == "ready"
    assert body["duplicate"] is False
    assert body["loudness_lufs"] is not None and body["gain_db"] is not None
    assert body["stream_url"]                       # playable immediately, no worker needed


def test_untagged_upload_falls_back_to_the_filename(client, hdr, tmp_audio):
    f = _tone(tmp_audio)
    body = _post(client, hdr, f).json()
    assert body["title"] == "tone"


def test_uploading_the_same_bytes_twice_is_not_two_tracks(client, hdr, tmp_audio):
    f = _tone(tmp_audio, title="Once")
    first = _post(client, hdr, f).json()
    second = _post(client, hdr, f).json()
    assert second["duplicate"] is True
    assert second["id"] == first["id"]


def test_non_native_codec_is_transcoded_and_the_original_kept(client, hdr, tmp_audio):
    """An upload cannot be re-fetched, so the file that arrived is kept next to the m4a."""
    from muse import db
    f = _tone(tmp_audio, codec="libmp3lame", ext="mp3", title="Mp3 Song")
    body = _post(client, hdr, f).json()
    rows = db.all_("select role, codec from media where track_id=%s order by role",
                   (body["id"],))
    assert {r["role"] for r in rows} == {"canonical", "original"}
    assert next(r["codec"] for r in rows if r["role"] == "canonical") == "aac"
    assert body["stream_url"]


def test_upload_rejects_a_non_audio_file(client, hdr):
    r = client.post("/uploads", headers=hdr,
                    files={"audio": ("notes.txt", io.BytesIO(b"hello there"), "text/plain")})
    assert r.status_code == 415


def test_upload_rejects_an_empty_file(client, hdr):
    r = client.post("/uploads", headers=hdr,
                    files={"audio": ("empty.m4a", io.BytesIO(b""), "audio/mp4")})
    assert r.status_code in (400, 415)


def test_upload_requires_auth(client, tmp_audio):
    f = _tone(tmp_audio)
    with f.open("rb") as fh:
        assert client.post("/uploads", files={"audio": (f.name, fh, "audio/mp4")}).status_code == 401


# ---------------- metadata edit ----------------
def test_manual_metadata_edit(client, hdr, tmp_audio):
    body = _post(client, hdr, _tone(tmp_audio)).json()
    fixed = client.patch(f"/tracks/{body['id']}", headers=hdr,
                         json={"title": "Proper Name", "artists": ["Someone Real"],
                               "release_year": 2011}).json()
    assert fixed["title"] == "Proper Name" and fixed["artists"] == ["Someone Real"]
    assert client.patch(f"/tracks/{body['id']}", headers=hdr, json={}).status_code == 400
    assert client.patch("/tracks/99999", headers=hdr, json={"title": "x"}).status_code == 404


# ---------------- offline manifest ----------------
def test_manifest_lists_only_ready_tracks_with_sizes(client, hdr, tmp_audio, complete_job):
    up = _post(client, hdr, _tone(tmp_audio, title="Offline Me")).json()
    pending = client.post("/tracks/resolve", headers=hdr, json={"video_id": "NOTYET"}).json()

    p = client.post("/playlists", headers=hdr, json={"name": "Trip"}).json()
    client.post(f"/playlists/{p['id']}/items", headers=hdr,
                json={"track_ids": [up["id"], pending["id"]]})

    m = client.get("/downloads/manifest", headers=hdr, params={"playlist_id": p["id"]}).json()
    assert m["count"] == 1                      # the pending one has nothing to download yet
    item = m["items"][0]
    assert item["track_id"] == up["id"]
    assert item["sha256"] and item["bytes"] > 0
    assert item["url"] == f"/tracks/{up['id']}/stream"
    assert "gain_db" in item                    # the device applies gain offline too
    assert m["bytes"] == item["bytes"]


def test_manifest_for_a_queue(client, hdr, tmp_audio):
    up = _post(client, hdr, _tone(tmp_audio)).json()
    q = client.post("/queues", headers=hdr, json={"name": "Now"}).json()
    client.put(f"/queues/{q['id']}", headers=hdr, json={"rev": q["rev"], "items": [up["id"]]})
    m = client.get("/downloads/manifest", headers=hdr, params={"queue_id": q["id"]}).json()
    assert m["count"] == 1 and m["bytes"] > 0   # a 2s tone rounds to 0.0 MB, bytes is the truth


def test_manifest_needs_a_target(client, hdr):
    assert client.get("/downloads/manifest", headers=hdr).status_code == 400


def test_manifest_of_someone_elses_playlist_is_empty(client, hdr, tmp_audio):
    from muse import auth
    up = _post(client, hdr, _tone(tmp_audio)).json()
    p = client.post("/playlists", headers=hdr, json={"name": "Mine"}).json()
    client.post(f"/playlists/{p['id']}/items", headers=hdr, json={"track_ids": [up["id"]]})
    tok = auth.issue_token(auth.ensure_user("nosy"), "phone", None)
    m = client.get("/downloads/manifest", headers={"Authorization": f"Bearer {tok}"},
                   params={"playlist_id": p["id"]}).json()
    assert m["count"] == 0


# ---------------- pictures people choose ----------------
def _png(colour=(200, 30, 90)) -> bytes:
    from io import BytesIO

    from PIL import Image

    buf = BytesIO()
    Image.new("RGB", (900, 600), colour).save(buf, "PNG")
    return buf.getvalue()


def test_a_profile_picture_can_be_set_seen_and_removed(client, hdr):
    """A picture is stored under a signature, so a changed one is a changed URL and
    nothing anywhere is left showing the old one."""
    up = client.post("/me/avatar", headers=hdr, content=_png())
    assert up.status_code == 200, up.text
    version = up.json()["avatar_version"]
    assert up.json()["avatar_url"] == "/users/1/avatar"

    got = client.get("/users/1/avatar", headers=hdr)
    assert got.status_code == 200 and got.headers["content-type"] == "image/jpeg"
    assert got.headers["etag"] == f'"{version}-lg"'
    assert client.get("/users/1/avatar?size=sm", headers=hdr).status_code == 200

    # A different picture is a different version.
    again = client.post("/me/avatar", headers=hdr, content=_png((10, 120, 200)))
    assert again.json()["avatar_version"] != version

    assert client.delete("/me/avatar", headers=hdr).status_code == 200
    assert client.get("/users/1/avatar", headers=hdr).status_code == 404


def test_something_that_is_not_a_picture_is_refused(client, hdr):
    r = client.post("/me/avatar", headers=hdr, content=b"this is not a png")
    assert r.status_code == 400
    assert "picture" in r.json()["detail"]


def test_a_playlist_can_be_given_a_cover_and_have_it_taken_back(client, hdr):
    p = client.post("/playlists", headers=hdr, json={"name": "Roadtrip"}).json()
    drawn = client.get("/playlists", headers=hdr).json()
    before = next(x for x in drawn if x["id"] == p["id"])
    assert before["custom_cover"] is False

    set_it = client.post(f"/playlists/{p['id']}/cover", headers=hdr, content=_png())
    assert set_it.status_code == 200, set_it.text
    listed = next(x for x in client.get("/playlists", headers=hdr).json()
                  if x["id"] == p["id"])
    assert listed["custom_cover"] is True
    assert listed["cover_version"] == set_it.json()["cover_version"], \
        "the version changes with the picture, or a cached one is shown forever"

    served = client.get(f"/playlists/{p['id']}/cover", headers=hdr)
    assert served.status_code == 200 and served.headers["content-type"] == "image/jpeg"

    client.delete(f"/playlists/{p['id']}/cover", headers=hdr)
    after = next(x for x in client.get("/playlists", headers=hdr).json()
                 if x["id"] == p["id"])
    assert after["custom_cover"] is False
    assert after["cover_version"] == before["cover_version"], \
        "and it goes back to the picture drawn from what is in it"


def test_a_photo_the_size_a_phone_takes_them(client, hdr):
    """Twelve megapixels of holiday photo, for a face drawn at forty pixels."""
    import io
    from PIL import Image

    buf = io.BytesIO()
    Image.new("RGB", (4032, 3024), (30, 90, 180)).save(buf, format="JPEG", quality=80)
    r = client.post("/me/avatar",
                    headers={**hdr, "Content-Type": "application/octet-stream"},
                    content=buf.getvalue())
    assert r.status_code == 200, r.text

    small = client.get("/users/1/avatar", params={"size": "sm"}, headers=hdr)
    assert small.status_code == 200
    assert Image.open(io.BytesIO(small.content)).size == (128, 128), "squared and shrunk"


def test_a_file_that_is_not_a_picture_says_so(client, hdr):
    r = client.post("/me/avatar",
                    headers={**hdr, "Content-Type": "application/octet-stream"},
                    content=b"this is a text file, not a face")
    assert r.status_code == 400
    assert "not a picture" in r.json()["detail"]
