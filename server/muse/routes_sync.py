"""Sync endpoints. Providers that are not configured say so instead of 500ing."""
from __future__ import annotations

from fastapi import APIRouter, Body, Depends, HTTPException

from . import db, sync
from .deps import cfg, current_user

router = APIRouter(prefix="/sync")

_ADAPTERS: dict[str, sync.Adapter] = {}      # tests inject fakes here


def adapter(kind: str) -> sync.Adapter:
    if kind in _ADAPTERS:
        return _ADAPTERS[kind]
    try:
        return sync.build(kind, cfg())
    except sync.MissingCredentials as e:
        raise HTTPException(501, str(e))
    except ValueError as e:
        raise HTTPException(404, str(e))


@router.get("/providers")
def providers(user: dict = Depends(current_user)):
    out = []
    for kind in ("spotify", "ytmusic"):
        try:
            adapter(kind)
            out.append({"kind": kind, "configured": True})
        except HTTPException as e:
            out.append({"kind": kind, "configured": False, "reason": e.detail})
    return out


@router.get("/{kind}/playlists")
def remote_playlists(kind: str, user: dict = Depends(current_user)):
    return [p.__dict__ for p in adapter(kind).list_playlists()]


@router.post("/{kind}/import")
def import_playlist(kind: str, body: dict = Body(...), user: dict = Depends(current_user)):
    remote_id = body.get("remote_id")
    if not remote_id:
        raise HTTPException(400, "remote_id required")
    a = adapter(kind)
    name = body.get("name") or next(
        (p.name for p in a.list_playlists() if p.remote_id == remote_id), remote_id)
    return sync.import_playlist(user["id"], a, remote_id, name)


@router.post("/playlists/{playlist_id}/pull")
def pull(playlist_id: int, user: dict = Depends(current_user)):
    p = db.one("select * from playlists where id=%s and owner_id=%s", (playlist_id, user["id"]))
    if not p:
        raise HTTPException(404, "no such playlist")
    if not p["remote_id"] or p["kind"] == "local":
        raise HTTPException(400, "playlist is local — nothing to pull from")
    return sync.import_playlist(user["id"], adapter(p["kind"]), p["remote_id"], p["name"],
                                playlist_id=playlist_id)


@router.get("/review")
def review(kind: str | None = None, user: dict = Depends(current_user)):
    return sync.review_queue(kind)


@router.post("/review/{kind}/{remote_id}")
def decide(kind: str, remote_id: str, body: dict = Body(...),
           user: dict = Depends(current_user)):
    if not body.get("track_id") and not body.get("video_id"):
        raise HTTPException(400, "track_id or video_id required")
    return sync.override(kind, remote_id, body.get("track_id"), body.get("video_id"))
