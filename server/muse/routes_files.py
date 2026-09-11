"""Custom uploads, profile pictures, and the offline download manifest.

Uploads are the only files in the library that cannot be re-fetched, so the original
is kept alongside the canonical m4a even when it had to be transcoded.
"""
from __future__ import annotations

import pathlib
import shutil
import tempfile

from fastapi import APIRouter, Body, Depends, HTTPException, Request, UploadFile
from fastapi.responses import FileResponse

from . import audiofile, branding, catalog, db, images, storage
from .deps import cfg, current_user, user_or_key
from .routes_accounts import is_admin

router = APIRouter()

MAX_UPLOAD_BYTES = 512 * 1024 * 1024      # a 500 MB "song" is a mistake, not a song


@router.post("/uploads", status_code=201)
def upload(audio: UploadFile, user: dict = Depends(current_user)):
    suffix = pathlib.Path(audio.filename or "upload").suffix or ".bin"
    with tempfile.TemporaryDirectory(prefix="muse-up-") as tmp:
        tmp_dir = pathlib.Path(tmp)
        raw = tmp_dir / f"in{suffix}"
        size = 0
        with raw.open("wb") as fh:
            while chunk := audio.file.read(1 << 20):
                size += len(chunk)
                if size > MAX_UPLOAD_BYTES:
                    raise HTTPException(413, "file larger than 512 MB")
                fh.write(chunk)
        if not size:
            raise HTTPException(400, "empty upload")

        try:
            info = audiofile.probe(raw)
        except Exception:
            raise HTTPException(415, f"{audio.filename!r} is not audio ffmpeg can read")
        if not info.get("codec"):
            raise HTTPException(415, "no audio stream in that file")

        # Same bytes as something already here? Then it is already here.
        original_sha = storage.sha256_file(raw)
        dupe = db.one("select track_id from media where sha256=%s", (original_sha,))
        if dupe:
            return {**catalog.public(catalog.track_row(dupe["track_id"])), "duplicate": True}

        meta = audiofile.tags(raw)
        fp = audiofile.fingerprint(raw)

        canonical = raw
        if audiofile.needs_transcode(info):
            canonical = audiofile.to_m4a(raw, tmp_dir / "out.m4a")
            info = {**audiofile.probe(canonical), "transcoded_from": info["codec"]}
        lufs, gain = audiofile.loudness(canonical)

        title = meta.get("title") or pathlib.Path(audio.filename or "Unknown").stem
        row = db.one(
            """insert into tracks(title,artists,album,duration_ms,release_year,isrc,
                                  source,state,loudness_lufs,gain_db,fingerprint,discovered_via)
               values(%s,%s,%s,%s,%s,%s,'custom','ready',%s,%s,%s,'user') returning id""",
            (title, meta.get("artists") or [], meta.get("album"), info.get("duration_ms"),
             meta.get("release_year"), meta.get("isrc"), lufs, gain,
             (fp or {}).get("fingerprint")),
        )
        track_id = row["id"]

        with canonical.open("rb") as fh:
            digest, path, stored = storage.store_stream(cfg().audio_dir, fh, ".m4a")
        db.run(
            """insert into media(track_id,sha256,codec,bitrate,bytes,path,role)
               values(%s,%s,%s,%s,%s,%s,'canonical')
               on conflict (track_id,sha256) do nothing""",
            (track_id, digest, info.get("codec"), info.get("bitrate"), stored, str(path)),
        )
        if canonical is not raw:
            # Irreplaceable: keep what was actually uploaded, next to the playable copy.
            with raw.open("rb") as fh:
                o_digest, o_path, o_bytes = storage.store_stream(
                    cfg().data_dir / "originals", fh, suffix)
            db.run(
                """insert into media(track_id,sha256,codec,bitrate,bytes,path,role)
                   values(%s,%s,%s,%s,%s,%s,'original')
                   on conflict (track_id,sha256) do nothing""",
                (track_id, o_digest, info.get("transcoded_from"), None, o_bytes, str(o_path)),
            )

    return {**catalog.public(catalog.track_row(track_id)),
            "suggested": meta, "fingerprinted": bool(fp), "duplicate": False}


@router.post("/me/avatar")
async def set_avatar(request: Request, user: dict = Depends(current_user)):
    """A profile picture, from whatever the phone had."""
    raw = await request.body()
    try:
        sig = images.store(cfg().image_dir, "avatar", user["id"], raw)
    except images.BadImage as e:
        raise HTTPException(400, str(e))
    old = db.one("select avatar_sig from users where id=%s", (user["id"],))
    db.run("update users set avatar_sig=%s where id=%s", (sig, user["id"]))
    if old and old["avatar_sig"] and old["avatar_sig"] != sig:
        images.forget(cfg().image_dir, "avatar", user["id"], old["avatar_sig"])
    return {"avatar_url": f"/users/{user['id']}/avatar", "avatar_version": sig}


@router.delete("/me/avatar")
def clear_avatar(user: dict = Depends(current_user)):
    old = db.one("select avatar_sig from users where id=%s", (user["id"],))
    db.run("update users set avatar_sig=null where id=%s", (user["id"],))
    if old and old["avatar_sig"]:
        images.forget(cfg().image_dir, "avatar", user["id"], old["avatar_sig"])
    return {"avatar_url": None}


# ------------------------------------------------------------------ the app's own icon
#
# Public, and it has to be: the manifest, the favicon and the icon iOS puts on a home
# screen are all fetched by the browser itself, which has never heard of our token and
# does most of it before anybody has signed in. It is the app's own picture, shown on
# the login page regardless.
@router.get("/icon")
def app_icon(size: int = 192, v: str | None = None):
    """The icon, at whatever size was asked for."""
    path = branding.render(cfg().data_dir, max(16, min(size, 1024)))
    return FileResponse(path, media_type="image/png", headers={
        "ETag": f'"{branding.signature(cfg().data_dir)}-{path.stem.rsplit("-", 1)[-1]}"',
        # Checked before use rather than kept: this is the one picture in the app that
        # is meant to change, and a home screen holding last month's icon for a year
        # is the whole reason it is served instead of built in.
        "Cache-Control": "public, no-cache"})


@router.get("/icon.json")
def app_icon_state(user: dict = Depends(current_user)):
    """What the icon is now, for the screen that changes it."""
    return {"version": branding.signature(cfg().data_dir),
            "custom": branding.custom(cfg().data_dir),
            "url": "/icon",
            "may_change": is_admin(user["id"])}


@router.post("/icon")
async def set_app_icon(request: Request, user: dict = Depends(current_user)):
    """A different picture, for everybody. An admin's to change."""
    if not is_admin(user["id"]):
        raise HTTPException(403, "Only an admin can change the icon.")
    raw = await request.body()
    try:
        sig = branding.store(cfg().data_dir, raw)
    except branding.BadImage as e:
        raise HTTPException(400, str(e))
    return {"version": sig, "custom": True, "url": "/icon"}


@router.delete("/icon")
def clear_app_icon(user: dict = Depends(current_user)):
    """Back to the one the app came with."""
    if not is_admin(user["id"]):
        raise HTTPException(403, "Only an admin can change the icon.")
    branding.forget(cfg().data_dir)
    return {"version": branding.signature(cfg().data_dir), "custom": False,
            "url": "/icon"}


@router.get("/users/{user_id}/avatar")
def avatar(user_id: int, size: str = "lg", v: str | None = None,
           user: dict = Depends(user_or_key)):
    """Anyone signed in here can see anyone's picture: it is a name with a face on it,
    shown beside what they added to a queue and who is in a jam."""
    row = db.one("select avatar_sig from users where id=%s", (user_id,))
    sig = (row or {}).get("avatar_sig")
    if not sig:
        raise HTTPException(404, "no picture")
    path = images.path_for(cfg().image_dir, "avatar", user_id, sig,
                           "sm" if size == "sm" else "lg")
    if not path.exists():
        raise HTTPException(404, "no picture")
    return FileResponse(path, media_type="image/jpeg", headers={
        "ETag": f'"{sig}-{size}"',
        "Cache-Control": "private, max-age=31536000, immutable"})


@router.patch("/tracks/{track_id}")
def edit_track(track_id: int, body: dict = Body(...), user: dict = Depends(current_user)):
    """Manual metadata fix — tags from an uploader are a suggestion, not a fact."""
    if not catalog.track_row(track_id):
        raise HTTPException(404, "no such track")
    fields = {k: body[k] for k in
              ("title", "artists", "album", "release_year", "isrc", "mbid") if k in body}
    if not fields:
        raise HTTPException(400, "nothing to change")
    sets = ", ".join(f"{k}=%s" for k in fields)
    db.run(f"update tracks set {sets} where id=%s", (*fields.values(), track_id))
    return catalog.public(catalog.track_row(track_id))


@router.get("/downloads/manifest")
def manifest(playlist_id: int | None = None, queue_id: int | None = None,
             user: dict = Depends(current_user)):
    """What a device must fetch to have this playable offline, and how big that is."""
    if playlist_id:
        rows = db.all_(
            """select t.*, m.sha256, m.bytes from playlist_items i
                 join tracks t on t.id=i.track_id
                 join media m on m.track_id=t.id and m.role='canonical'
                 join playlists p on p.id=i.playlist_id
                where i.playlist_id=%s and p.owner_id=%s order by i.pos""",
            (playlist_id, user["id"]),
        )
    elif queue_id:
        rows = db.all_(
            """select t.*, m.sha256, m.bytes from queue_items i
                 join tracks t on t.id=i.track_id
                 join media m on m.track_id=t.id and m.role='canonical'
                 join queues q on q.id=i.queue_id
                where i.queue_id=%s and q.user_id=%s order by i.pos""",
            (queue_id, user["id"]),
        )
    else:
        raise HTTPException(400, "playlist_id or queue_id required")

    items = [{
        "track_id": r["id"], "title": r["title"], "artists": r["artists"],
        "sha256": r["sha256"], "bytes": r["bytes"], "gain_db": r["gain_db"],
        "duration_ms": r["duration_ms"], "url": f"/tracks/{r['id']}/stream",
    } for r in rows]
    return {"items": items, "count": len(items),
            "bytes": sum(i["bytes"] or 0 for i in items),
            "mb": round(sum(i["bytes"] or 0 for i in items) / 1e6, 1)}
