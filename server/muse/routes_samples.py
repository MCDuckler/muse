"""The booth's board: a person's own short sounds, and the board that holds them.

A sample is not a track. A track is the catalogue's — anyone's, searchable, analysed,
loudness-matched, taken apart by the pool. A sample is one person's: a few seconds
of sound they dropped on a pad, or cut out of a record at a bar. It lives in its own
table and its own directory, is served whole or by range like a track, and is gone
when its owner says so.

The board itself — which sound on which pad, how each plays — is one JSON document
per person (`boards`), with a revision: a desk that saves over a phone's newer copy is
told so (409) and reads again, as the queues do.

The house's sounds are samples too, marked `house`: listed to every account beside its
own, heard and fetched by anyone signed in, renamed or removed only by whoever loaded
them (`python -m muse.cli housesamples`).
"""
from __future__ import annotations

import json
import pathlib
import subprocess
import tempfile
from typing import Annotated

from fastapi import APIRouter, Body, Depends, Header, HTTPException, Request, UploadFile

from . import audiofile, catalog, db, peaks, storage
from .deps import cfg
from .deps import current_user, user_or_key

router = APIRouter(prefix="/samples")

MAX_BYTES = 20 << 20          # a sample is seconds, not a record
MAX_SECONDS = 60
SHAPE_SLICES = 128            # the shape drawn across a pad


def _dir() -> pathlib.Path:
    return cfg().data_dir / "samples"


def _public(row: dict) -> dict:
    return {
        "id": row["id"],
        "name": row["name"],
        "duration_ms": row["duration_ms"],
        "bytes": row["bytes"],
        "origin": row.get("origin") or {},
        "shape": row.get("shape") or [],
        "created_at": row["created_at"],
        "audio_url": f"/samples/{row['id']}/audio",
        "house": bool(row.get("house")),
    }


def _house(row: dict) -> dict:
    """A house sound as the shelf lists it: what a library row and a pad need, and no
    more — there are hundreds, and every board that opens asks for them."""
    o = row.get("origin") or {}
    return {
        "id": row["id"],
        "name": row["name"],
        "duration_ms": row["duration_ms"],
        "shape": row.get("shape") or [],
        "group": o.get("group"),
        "pad": o.get("pad"),
        "words": o.get("words"),
        "license": o.get("license"),
        "audio_url": f"/samples/{row['id']}/audio",
    }


def _mine(sample_id: int, user_id: int) -> dict:
    row = db.one("select * from samples where id=%s and user_id=%s", (sample_id, user_id))
    if not row:
        raise HTTPException(404, "no sample of yours by that id")
    return row


def _hearable(sample_id: int, user_id: int) -> dict:
    """Yours, or the house's."""
    row = db.one("select * from samples where id=%s and (user_id=%s or house)", (sample_id, user_id))
    if not row:
        raise HTTPException(404, "no sample by that id")
    return row


def _keep(user_id: int, src: pathlib.Path, name: str, origin: dict, house: bool = False) -> dict:
    """[src], checked and kept: probed (audio, short enough), shaped, stored by its
    hash, written down. Returns the row."""
    try:
        info = audiofile.probe(src)
    except Exception:
        raise HTTPException(415, "not audio ffmpeg can read")
    if not info.get("codec"):
        raise HTTPException(415, "no audio stream in that file")
    ms = int(info.get("duration_ms") or 0)
    if ms > MAX_SECONDS * 1000:
        raise HTTPException(413, f"a sample is at most {MAX_SECONDS} seconds")
    try:
        shape = peaks.measure(src, SHAPE_SLICES)
    except Exception:
        shape = []
    ext = src.suffix if src.suffix in (".wav", ".m4a", ".mp3", ".ogg", ".opus", ".flac") else ".m4a"
    with src.open("rb") as fh:
        digest, path, size = storage.store_stream(_dir(), fh, ext, limit=MAX_BYTES)
    return db.one(
        """insert into samples(user_id, name, sha256, path, bytes, duration_ms, shape, origin, house)
           values(%s,%s,%s,%s,%s,%s,%s,%s,%s) returning *""",
        (user_id, name.strip()[:80] or "Sample", digest, str(path), size, ms,
         json.dumps(shape), json.dumps(origin), house),
    )


@router.get("")
def mine(user: dict = Depends(current_user)):
    """Your own sounds, and the house's beside them (an app that predates the shelf reads
    only `samples` and is none the wiser)."""
    rows = db.all_("select * from samples where user_id=%s and not house order by created_at desc", (user["id"],))
    house = db.all_("select * from samples where house order by (origin->>'order')::int nulls last, id")
    return {"samples": [_public(r) for r in rows], "house": [_house(r) for r in house]}


@router.post("", status_code=201)
def upload(audio: UploadFile, name: str | None = None, user: dict = Depends(current_user)):
    """A sound of your own, as a file: counted as it comes in, probed before it is kept."""
    suffix = pathlib.Path(audio.filename or "sample").suffix.lower() or ".bin"
    with tempfile.TemporaryDirectory(prefix="muse-sample-") as tmp:
        raw = pathlib.Path(tmp) / f"in{suffix}"
        size = 0
        with raw.open("wb") as fh:
            while chunk := audio.file.read(1 << 20):
                size += len(chunk)
                if size > MAX_BYTES:
                    raise HTTPException(413, f"a sample is at most {MAX_BYTES >> 20} MB")
                fh.write(chunk)
        if not size:
            raise HTTPException(400, "empty upload")
        label = name or pathlib.Path(audio.filename or "Sample").stem
        row = _keep(user["id"], raw, label, {"kind": "upload", "filename": audio.filename})
    return _public(row)


@router.post("/cut", status_code=201)
def cut(body: dict = Body(...), user: dict = Depends(current_user)):
    """Bars cut out of a record: [track_id], from [from_ms] to [to_ms]. The desk sends
    the bar it is on, so the cut is on the beat without this knowing where the beats
    are. Cut with ffmpeg here, where the record and ffmpeg both are."""
    try:
        track_id = int(body["track_id"])
        from_ms = int(body.get("from_ms") or 0)
        to_ms = int(body["to_ms"])
    except (KeyError, TypeError, ValueError):
        raise HTTPException(400, "track_id, from_ms and to_ms, in milliseconds")
    if to_ms <= from_ms or to_ms - from_ms > MAX_SECONDS * 1000:
        raise HTTPException(400, f"a cut is between 0 and {MAX_SECONDS} seconds long")
    t = catalog.track_row(track_id)
    if not t or not t.get("path"):
        raise HTTPException(404, "not ready" if t else "no such track")
    src = pathlib.Path(t["path"])
    if not src.exists():
        raise HTTPException(410, "the record's audio is missing")
    name = body.get("name") or f"{t.get('title') or 'Record'} · {from_ms // 1000}s"
    with tempfile.TemporaryDirectory(prefix="muse-cut-") as tmp:
        out = pathlib.Path(tmp) / "cut.m4a"
        try:
            subprocess.run(
                [audiofile.FFMPEG, "-v", "error", "-y",
                 "-ss", f"{from_ms / 1000:.3f}", "-to", f"{to_ms / 1000:.3f}", "-i", str(src),
                 # A hair of fade either side, so a cut on a bar does not click.
                 "-af", f"afade=t=in:d=0.004,afade=t=out:st={max(0.0, (to_ms - from_ms) / 1000 - 0.008):.3f}:d=0.008",
                 "-c:a", "aac", "-b:a", "192k", str(out)],
                capture_output=True, timeout=60, check=True)
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as e:
            raise HTTPException(500, f"ffmpeg could not cut that: {getattr(e, 'stderr', b'')[:200]!r}")
        row = _keep(user["id"], out, str(name),
                    {"kind": "cut", "track_id": track_id, "from_ms": from_ms, "to_ms": to_ms})
    return _public(row)


@router.patch("/{sample_id}")
def rename(sample_id: int, body: dict = Body(...), user: dict = Depends(current_user)):
    name = str(body.get("name") or "").strip()
    if not name:
        raise HTTPException(400, "a name")
    _mine(sample_id, user["id"])
    row = db.one("update samples set name=%s where id=%s returning *", (name[:80], sample_id))
    return _public(row)


@router.delete("/{sample_id}")
def forget(sample_id: int, user: dict = Depends(current_user)):
    row = _mine(sample_id, user["id"])
    db.run("delete from samples where id=%s", (sample_id,))
    # The blob goes when nobody else's sample is the same bytes.
    if not db.one("select 1 from samples where sha256=%s", (row["sha256"],)):
        pathlib.Path(row["path"]).unlink(missing_ok=True)
    return {"forgotten": sample_id}


@router.get("/{sample_id}/shape")
def shape(sample_id: int, user: dict = Depends(current_user)):
    """The sound's shape across a pad: 128 levels, 0 to 255."""
    row = _hearable(sample_id, user["id"])
    return {"shape": row.get("shape") or []}


@router.get("/{sample_id}/audio")
def audio(sample_id: int, request: Request, k: str | None = None,
          authorization: Annotated[str | None, Header()] = None):
    """The sound itself, whole or by range, for a bearer token or a signed key (a
    browser's audio element has no header)."""
    user = user_or_key(k, authorization)
    row = _hearable(sample_id, user["id"])
    from .app import _range_response

    return _range_response(pathlib.Path(row["path"]), request, etag=row["sha256"])


# ------------------------------------------------------------------------ the board
board = APIRouter(prefix="/booth")


@board.get("/board")
def read_board(user: dict = Depends(current_user)):
    row = db.one("select doc, rev, updated_at from boards where user_id=%s", (user["id"],))
    if not row:
        return {"doc": None, "rev": 0}
    return {"doc": row["doc"], "rev": row["rev"], "updated_at": row["updated_at"]}


@board.put("/board")
def write_board(body: dict = Body(...), user: dict = Depends(current_user)):
    """The whole board, over the one kept — if [rev] is the one kept. A stale [rev]
    is a 409 with the board as it is: read it, merge, say again."""
    doc = body.get("doc")
    if not isinstance(doc, dict):
        raise HTTPException(400, "doc must be the board as JSON")
    try:
        rev = int(body.get("rev") or 0)
    except (TypeError, ValueError):
        raise HTTPException(400, "rev must be a number")
    if len(json.dumps(doc)) > 256 << 10:
        raise HTTPException(413, "that is a lot of board")
    kept = db.one("select rev from boards where user_id=%s", (user["id"],))
    if kept and kept["rev"] != rev:
        current = db.one("select doc, rev from boards where user_id=%s", (user["id"],))
        raise HTTPException(409, {"doc": current["doc"], "rev": current["rev"]})
    new_rev = rev + 1
    db.run(
        """insert into boards(user_id, doc, rev, updated_at) values(%s,%s,%s,now())
           on conflict (user_id) do update set doc=excluded.doc, rev=excluded.rev, updated_at=now()""",
        (user["id"], json.dumps(doc), new_rev),
    )
    return {"rev": new_rev}
