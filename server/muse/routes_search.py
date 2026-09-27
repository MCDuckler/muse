"""One search, one list, whatever it is and wherever it lives.

The old /search stays: it is what an older app asks, and it answers in the shape that
app expects. These are the new ones — the merged list, and the two things a row in it
needs to be able to open: what is on a record, and what an artist has.
"""
from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException

from . import catalog, db, match, search, spotify, ytm
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
        # Spotify cannot be downloaded from, so what is actually added is the same song
        # found on YouTube Music — and *found* is the word that matters. It used to
        # take the first hit for "title artist" and queue it, which for anything the
        # search is bad at is a stranger's song with the right row on the screen: a
        # German punk record came back as an American folk song of nearly the same
        # name, and nothing anywhere said so. So the hit has to be recognisably the
        # song that was asked for, judged the same way an imported playlist's tracks
        # are, and when nothing clears that bar the honest answer is that it was not
        # found.
        artists = [a.strip() for a in artist.split(",") if a.strip()]
        try:
            hits = ytm.search_songs(f"{title} {artists[0] if artists else ''}".strip(),
                                    limit=8)
        except ytm.Unavailable as e:
            raise HTTPException(503, f"YouTube would not answer just now: {e}")
        want = {"title": title, "artists": artists,
                "duration_ms": body.get("duration_ms")}
        found, confidence, how = match.best(want, hits)
        if not found or confidence < match.AUTO_ACCEPT:
            # Named whatever it was, even when it scored too low to be handed back by
            # best(): "nothing was added" is an answer, and "nothing was added, the
            # closest thing was this" is one somebody can act on.
            closest = max(hits, key=lambda h: match.score(want, h)[0], default=None)
            near = (f" The closest was “{closest['title']}” by "
                    f"{', '.join(closest['artists']) or 'somebody else'}."
                    if closest else "")
            raise HTTPException(
                404,
                f"“{title}” by {artists[0] if artists else 'that artist'} is not on "
                f"YouTube Music under a name this could recognise, so nothing was "
                f"added rather than the wrong thing.{near}")
        return _take(user, found["video_id"], found)

    if place == "ytmusic":
        return _take(user, ident, None)

    if place == "youtube":
        # An ordinary video, kept as its sound. It is fetched exactly as a song is —
        # the id is a YouTube id either way — but it has no song's metadata to look up,
        # so what it is called is what the video is called and who it is by is the
        # channel, until somebody edits it.
        try:
            meta = ytm.video(ident)
        except ytm.Unavailable:
            meta = None
        meta = meta or {
            "video_id": ident, "title": title or ident,
            "artists": [a for a in [artist.split(" · ")[0].strip()] if a],
            "album": None, "duration_ms": body.get("duration_ms"), "raw": {}}
        return _take(user, ident, meta)

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


@router.get("/similar")
def similar(tracks: str, limit: int = 12, user: dict = Depends(current_user)):
    """Songs not in the library that belong beside [tracks]: YouTube Music's radio tail
    for up to four of them, taken a few from each in turn the way a station is seeded,
    with what the library already holds, near-copies of a seed, and the same song twice
    left out. Nothing is fetched by asking — a hit is fetched when it is added
    (POST /tracks/resolve). The shape of a hit is a search's remote hit, with
    `seed` naming the song it came from."""
    ids = [int(x) for x in tracks.split(",") if x.strip().lstrip("-").isdigit()][:12]
    if not ids:
        raise HTTPException(400, "tracks: a few track ids, comma-separated")
    rows = db.all_(
        """select t.*, s.provider_id from tracks t
             join track_sources s on s.track_id = t.id and s.provider = 'ytmusic'
            where t.id = any(%s)""", (ids,))
    by_id = {r["id"]: r for r in rows}
    seeds = [by_id[i] for i in ids if i in by_id][:4]
    if not seeds:
        return {"similar": [], "seeds": []}
    have = {r["provider_id"] for r in db.all_(
        "select provider_id from track_sources where provider = 'ytmusic'")}
    wells = []
    for seed in seeds:
        try:
            wells.append(ytm.watch_playlist(seed["provider_id"], limit=max(10, limit * 2)))
        except ytm.Unavailable as e:
            if not wells:
                raise HTTPException(502, str(e))
            wells.append([])
    out, seen = [], set()
    depth = 0
    limit = max(1, min(limit, 40))
    while len(out) < limit and any(depth < len(w) for w in wells):
        for well, seed in zip(wells, seeds):
            if len(out) >= limit or depth >= len(well):
                continue
            cand = well[depth]
            video = cand.get("video_id")
            if not video or video in seen or video in have:
                continue
            seen.add(video)
            conf, _ = match.score(
                {"title": seed["title"], "artists": seed["artists"], "duration_ms": seed["duration_ms"]}, cand)
            if conf >= match.AUTO_ACCEPT:
                continue
            out.append({
                "video_id": video, "title": cand.get("title") or video,
                "artists": cand.get("artists") or [], "album": cand.get("album"),
                "duration_ms": cand.get("duration_ms"), "known": False,
                "cover_url": search._art(ytm.thumbnail_url(cand.get("raw") or {})),
                "seed": {"id": seed["id"], "title": seed["title"]},
            })
        depth += 1
    return {"similar": out, "seeds": [{"id": s["id"], "title": s["title"]} for s in seeds]}
