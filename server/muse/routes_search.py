"""One search, one list, whatever it is and wherever it lives.

The old /search stays: it is what an older app asks, and it answers in the shape that
app expects. These are the new ones — the merged list, and the two things a row in it
needs to be able to open: what is on a record, and what an artist has.
"""
from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException

from . import catalog, search, spotify, ytm
from .deps import cfg, current_user

router = APIRouter(prefix="/search")


@router.get("/everything")
def everything(q: str, where: str = "all", kind: str = "all", lyrics: bool = False,
               limit: int = 30, user: dict = Depends(current_user)):
    """Songs, records and artists from every service at once, ranked together.

    `where` narrows it to one service, `kind` to one sort of thing, and `lyrics` asks
    the question the other way round: not what is this called, but what are the words.
    """
    if where not in ("all",) + search.PLACES:
        raise HTTPException(400, f"{where} is not somewhere this can look")
    if kind not in ("all",) + search.KINDS:
        raise HTTPException(400, f"{kind} is not a kind of thing this can find")
    return search.everything(cfg(), user["id"], q, where=where, kind=kind,
                             lyrics=lyrics, limit=min(limit, 60))


@router.get("/album")
def album(place: str, id: str, user: dict = Depends(current_user)):
    """What is on a record somebody found, before any of it is added.

    A row for an album that cannot be opened is a row that does nothing, and adding a
    whole record one song at a time out of a song search is the thing this is for.
    """
    if place == "ytmusic":
        try:
            found = ytm.album_tracks(id)
        except ytm.Unavailable as e:
            raise HTTPException(502, str(e))
        have = {t["provider_id"] for t in _known("ytmusic")}
        return {
            "title": found["title"], "artist": found["artist"], "year": found["year"],
            "cover_url": search._art(found["thumbnail"]),
            "tracks": [{
                "kind": "song", "place": "ytmusic", "id": t["video_id"],
                "title": t["title"],
                "subtitle": ", ".join(t["artists"]) or found["artist"] or "",
                "duration_ms": t["duration_ms"],
                "cover_url": search._art(found["thumbnail"]),
                "known": t["video_id"] in have,
            } for t in found["tracks"]],
        }
    if place == "spotify":
        if not spotify.account(user["id"]):
            raise HTTPException(409, "Spotify is not linked to this account")
        data = spotify._get(cfg(), user["id"], f"/albums/{id}")
        images = data.get("images") or []
        cover = search._art(images[0]["url"] if images else None)
        return {
            "title": data.get("name"), "year": (data.get("release_date") or "")[:4],
            "artist": ", ".join(a["name"] for a in (data.get("artists") or [])),
            "cover_url": cover,
            "tracks": [{
                "kind": "song", "place": "spotify", "id": t["id"],
                "title": t.get("name") or "",
                "subtitle": ", ".join(a["name"] for a in (t.get("artists") or [])),
                "duration_ms": t.get("duration_ms"),
                "cover_url": cover,
                "known": False,
            } for t in ((data.get("tracks") or {}).get("items") or [])],
        }
    raise HTTPException(400, f"{place} albums cannot be opened yet")


def _known(provider: str) -> list[dict]:
    from . import db

    return db.all_("select provider_id from track_sources where provider=%s",
                   (provider,))


@router.post("/add")
def add(body: dict, user: dict = Depends(current_user)):
    """Take a row from the list, whatever service it is from.

    One way in for all of them. A YouTube id is queued as itself; a Spotify one is
    looked for by name, because a Spotify track id is not something this server can
    ever download — the same matching a mirrored Spotify playlist already uses.
    """
    place, ident = body.get("place"), str(body.get("id") or "")
    title, artist = body.get("title") or "", body.get("subtitle") or ""
    if not place or not ident:
        raise HTTPException(400, "place and id required")

    if place == "library":
        track = catalog.track_row(int(ident))
        if not track:
            raise HTTPException(404, "no such track")
        catalog.remember(user["id"], track["id"])
        return catalog.public(track)

    if place in ("soundcloud", "bandcamp"):
        from .routes_sources import resolve as resolve_source

        return resolve_source(
            {"provider": place, "provider_id": ident, "title": title,
             "artists": [a.strip() for a in artist.split(",") if a.strip()],
             "album": body.get("album"), "duration_ms": body.get("duration_ms"),
             "url": body.get("url")},
            user)

    if place == "spotify":
        try:
            hits = ytm.search_songs(f"{title} {artist.split(',')[0]}".strip(), limit=1)
        except ytm.Unavailable as e:
            raise HTTPException(503, f"YouTube would not answer just now: {e}")
        if not hits:
            raise HTTPException(404, f"nothing to fetch for {title!r}")
        return _take(user, hits[0]["video_id"], hits[0])

    if place == "ytmusic":
        return _take(user, ident, None)

    raise HTTPException(400, f"{place} is not somewhere a song can be taken from")


def _take(user: dict, video_id: str, meta: dict | None):
    """Queue a YouTube id, or hand back what is already here for it."""
    from . import jobs

    cached = catalog.find_by_video_id(video_id)
    if cached:
        if cached["state"] == "failed":
            cached = catalog.retry(cached["id"], video_id)
        elif cached["state"] != "ready":
            jobs.promote(cached["id"])
        catalog.remember(user["id"], cached["id"])
        return catalog.public(cached)

    if meta is None:
        try:
            meta = ytm.song(video_id)
        except ytm.Unavailable:
            meta = None
    meta = meta or {"video_id": video_id, "title": video_id, "artists": [],
                    "album": None, "duration_ms": None, "raw": {}}
    meta["video_id"] = video_id
    created = catalog.create_from_ytm(meta, discovered_via=catalog.VIA_USER)
    catalog.remember(user["id"], created["id"])
    return catalog.public(created)
