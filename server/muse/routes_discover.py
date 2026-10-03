"""The Discover page, in one request, and the few things it can be asked to do."""
from __future__ import annotations

from fastapi import APIRouter, Body, Depends, HTTPException

from . import discover, recommend
from .deps import current_user

router = APIRouter(prefix="/discover")


@router.get("")
def page(user: dict = Depends(current_user)):
    """Everything on the page: the lists made for you (or word that they are being
    made), stations to go back to and things to start one from, the news from who
    and what you follow, and acts to try. Each part on its own, so one that cannot
    be had leaves a gap rather than an error. Nothing here goes over the wire."""
    uid = user["id"]
    out: dict = {"lists": [], "building": False, "stations": {}, "feed": {}, "artists": [],
                 "genres": {"following": [], "suggested": []}}
    tas = recommend.taste(uid)
    try:
        out["lists"] = discover.lists_for(uid)
        if not out["lists"]:
            out["building"] = discover.ask_for(uid)
    except Exception as e:  # noqa: BLE001
        out["lists_error"] = str(e)
    try:
        out["stations"] = {"yours": discover.your_stations(uid),
                           **discover.station_starters(uid, tas)}
    except Exception as e:  # noqa: BLE001
        out["stations_error"] = str(e)
    try:
        out["feed"] = discover.feed(uid, limit=40)
    except Exception as e:  # noqa: BLE001
        out["feed_error"] = str(e)
    try:
        out["genres"] = {"following": discover.genres_of(uid),
                         "suggested": discover.suggested_genres(uid, tas, limit=8)}
    except Exception as e:  # noqa: BLE001
        out["genres_error"] = str(e)
    try:
        out["artists"] = discover.artists_to_try(uid, tas)
    except Exception as e:  # noqa: BLE001
        out["artists_error"] = str(e)
    return out


@router.get("/lists")
def lists(user: dict = Depends(current_user)):
    items = discover.lists_for(user["id"])
    return {"items": items, "building": False if items else discover.ask_for(user["id"])}


@router.get("/lists/{slug}")
def one(slug: str, user: dict = Depends(current_user)):
    entry = discover.one_list(user["id"], slug)
    if not entry:
        raise HTTPException(404, "no such list — it may not have been made yet")
    return entry


@router.post("/lists/{slug}/keep", status_code=201)
def keep(slug: str, user: dict = Depends(current_user)):
    """This list as a playlist of your own, as it stands."""
    try:
        return {"playlist_id": discover.keep(user["id"], slug)}
    except LookupError:
        raise HTTPException(404, "no such list")


@router.post("/lists/rebuild")
def rebuild(body: dict = Body(default={}), user: dict = Depends(current_user)):
    """Make them again now, in this request. `force` remakes the weekly one too."""
    return discover.build_for(user["id"], force=bool(body.get("force")))


@router.get("/genres")
def genres(q: str | None = None, user: dict = Depends(current_user)):
    """Genres: the ones you follow, the ones you seem to play, and — with `q` — the
    ones in the register that match what you typed."""
    following = discover.genres_of(user["id"])
    out = {"following": following, "suggested": [], "found": []}
    if q:
        out["found"] = discover.genre_names(q, limit=30)
    else:
        try:
            out["suggested"] = discover.suggested_genres(user["id"], limit=12)
        except Exception:  # noqa: BLE001
            out["suggested"] = []
        out["found"] = [g for g in discover.COMMON_GENRES if g not in following][:30]
    return out


@router.put("/genres/{genre}")
def follow(genre: str, user: dict = Depends(current_user)):
    try:
        return discover.follow_genre(user["id"], genre)
    except ValueError as e:
        raise HTTPException(400, str(e))


@router.delete("/genres/{genre}")
def unfollow(genre: str, user: dict = Depends(current_user)):
    discover.unfollow_genre(user["id"], genre)
    return {"genre": discover._norm(genre), "following": False}


@router.get("/feed")
def feed(limit: int = 60, user: dict = Depends(current_user)):
    return discover.feed(user["id"], limit=limit)


@router.post("/feed/seen")
def seen(body: dict = Body(...), user: dict = Depends(current_user)):
    """Looked at. Items as the feed gave them (album_id + provider, or release_mbid)."""
    return {"seen": discover.mark_seen(user["id"], body.get("items") or [])}


@router.get("/artists")
def artists(user: dict = Depends(current_user)):
    return {"items": discover.artists_to_try(user["id"])}
