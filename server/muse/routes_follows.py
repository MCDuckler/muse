"""Followed artists and the feed built from them."""
from __future__ import annotations

from fastapi import APIRouter, Body, Depends, HTTPException

from . import discography, follows, linked
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


@router.post("/follows/import")
def import_follows(body: dict = Body(default={}), user: dict = Depends(current_user)):
    """Take the artists you already follow somewhere else.

    Nobody wants to type in eighty names they have already chosen once. Each is looked
    up in the music database so the feed has a real artist to watch rather than a
    string, and anything that cannot be found is reported rather than dropped quietly.
    """
    provider = body.get("provider") or "spotify"
    try:
        if provider == "spotify":
            from . import spotify
            from .deps import cfg
            try:
                names = spotify.followed_artists(cfg(), user["id"])
            except Exception as e:
                # The scope for this was added later, so an account linked before it
                # will be refused — which is fixable, and worth saying how.
                if "403" in str(e) or "insufficient" in str(e).lower():
                    raise HTTPException(
                        400,
                        "Spotify has not given us permission to read who you follow. "
                        "Disconnect and connect again to grant it.")
                raise
        else:
            account = next((a for a in linked.accounts(user["id"])
                            if a["provider"] == provider), None)
            if not account:
                raise HTTPException(400, f"No {provider} account is linked.")
            names = linked.following(provider, account["handle"])
    except linked.LinkError as e:
        raise HTTPException(400, str(e))
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(502, f"{provider} did not answer: {e}")

    added, already, missed = 0, 0, []
    for entry in names:
        try:
            artist = discography.find_artist(entry["name"])
        except discography.Unavailable:
            missed.append(entry["name"])
            continue
        if not artist:
            missed.append(entry["name"])
            continue
        if follows.is_following(user["id"], "deezer", artist["remote_id"]):
            already += 1
            continue
        follows.follow(user["id"], artist)
        added += 1

    return {"from": provider, "found": len(names), "followed": added,
            "already": already, "not_found": missed[:40]}


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
