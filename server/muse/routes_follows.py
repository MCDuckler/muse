"""Followed artists and the feed built from them."""
from __future__ import annotations

from fastapi import APIRouter, Body, Depends, HTTPException

from . import discography, follows
from .deps import current_user

router = APIRouter()


@router.get("/follows")
def list_follows(user: dict = Depends(current_user)):
    return {"items": follows.list_for(user["id"])}


@router.post("/follows", status_code=201)
def add_follow(body: dict = Body(...), user: dict = Depends(current_user)):
    """Follow by name — the artist page has one — or by an id it already resolved."""
    provider = body.get("provider") or "deezer"
    remote_id = body.get("remote_id")
    artist = None
    if remote_id:
        artist = {"remote_id": str(remote_id), "name": body.get("name") or str(remote_id),
                  "image": body.get("image")}
    elif body.get("name"):
        try:
            artist = discography.find_artist(body["name"])
        except discography.Unavailable as e:
            raise HTTPException(502, f"Could not reach the music database: {e}")
        if not artist:
            raise HTTPException(404, f"No artist called “{body['name']}” was found.")
    if not artist:
        raise HTTPException(400, "name or remote_id required")

    result = follows.follow(user["id"], artist, provider)
    return {**artist, "provider": provider, **result}


@router.delete("/follows/{remote_id}")
def remove_follow(remote_id: str, provider: str = "deezer",
                  user: dict = Depends(current_user)):
    follows.unfollow(user["id"], provider, remote_id)
    return {"following": False}


@router.get("/feed")
def feed(limit: int = 60, offset: int = 0, user: dict = Depends(current_user)):
    items = follows.feed(user["id"], limit=limit, offset=offset)
    return {"items": items,
            "unseen": sum(1 for i in items if i["unseen"]),
            "following": len(follows.list_for(user["id"]))}


@router.post("/feed/seen")
def mark_seen(body: dict = Body(...), user: dict = Depends(current_user)):
    ids = [str(i) for i in (body.get("album_ids") or [])]
    return {"seen": follows.mark_seen(user["id"], ids,
                                      body.get("provider") or "deezer")}


@router.post("/feed/refresh")
def refresh(user: dict = Depends(current_user)):
    """Check now, rather than waiting for the next scheduled pass."""
    return follows.poll()
