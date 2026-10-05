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
                  "image": body.get("image"), "is_label": bool(body.get("is_label"))}
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
    _rebuild(user["id"])
    return {**artist, "provider": provider, **result}


def _rebuild(user_id: int) -> None:
    """Their Discover lists made again, soon: who somebody follows is what the radar and
    the feed are made of, and a follow should not wait for the night to count."""
    from . import discover
    try:
        discover.ask_for(user_id)
    except Exception:  # noqa: BLE001 — the nightly build makes them anyway
        pass


@router.delete("/follows/{remote_id}")
def remove_follow(remote_id: str, provider: str = "deezer",
                  user: dict = Depends(current_user)):
    follows.unfollow(user["id"], provider, remote_id)
    _rebuild(user["id"])
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
            except (spotify.NotLinked, spotify.NotAllowed, spotify.NotConfigured) as e:
                # These say something the person reading them can act on — link the
                # account, ask to be added to the app — so they are their own answer
                # rather than "the service did not respond".
                raise HTTPException(400, str(e))
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

    got = follows.import_entries(user["id"], provider, names,
                                 expand_labels=body.get("expand_labels", True))
    if got.get("followed"):
        _rebuild(user["id"])
    return got


@router.get("/follows/sources")
def sources(user: dict = Depends(current_user)):
    """Where follows can be imported from: the services this account has linked."""
    out = []
    try:
        from . import spotify
        if spotify.account(user["id"]):
            out.append({"provider": "spotify", "label": "Spotify"})
    except Exception:  # noqa: BLE001 — not configured, not linked: not a source
        pass
    labels = {"soundcloud": "SoundCloud", "bandcamp": "Bandcamp", "deezer": "Deezer"}
    for a in linked.accounts(user["id"]):
        if a["provider"] in labels:
            out.append({"provider": a["provider"], "label": labels[a["provider"]],
                        "handle": a.get("display_name") or a.get("handle")})
    return {"items": out}


@router.get("/feed")
def feed(limit: int = 60, offset: int = 0, user: dict = Depends(current_user)):
    items = follows.feed(user["id"], limit=limit, offset=offset)
    return {"items": items,
            "unseen": sum(1 for i in items if i["unseen"]),
            "following": len(follows.list_for(user["id"]))}


@router.post("/feed/seen")
def mark_seen(body: dict = Body(...), user: dict = Depends(current_user)):
    """Looked at. `items` say where each record is from — a Bandcamp record's id is its
    page — and a bare `album_ids` is the older form, all from one `provider`."""
    seen = 0
    by_provider: dict[str, list[str]] = {}
    for i in body.get("items") or []:
        if i.get("album_id"):
            by_provider.setdefault(i.get("provider") or "deezer", []).append(str(i["album_id"]))
    ids = [str(i) for i in (body.get("album_ids") or [])]
    if ids:
        by_provider.setdefault(body.get("provider") or "deezer", []).extend(ids)
    for provider, album_ids in by_provider.items():
        seen += follows.mark_seen(user["id"], album_ids, provider)
    return {"seen": seen}


@router.post("/feed/refresh")
def refresh(user: dict = Depends(current_user)):
    """Check now, rather than waiting for the next scheduled pass."""
    return follows.poll()
