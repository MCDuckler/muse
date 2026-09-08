"""Searching and adding from the sources the server fetches itself.

YouTube Music stays where it is — it needs the worker at home. These two are answered
here, and a Bandcamp album can be pasted in whole: the page carries the record, so an
album import needs no matching and no guessing.
"""
from __future__ import annotations

from fastapi import APIRouter, Body, Depends, HTTPException

from . import catalog, jobs, sources
from .deps import current_user

router = APIRouter(prefix="/sources")


@router.get("")
def list_sources(user: dict = Depends(current_user)):
    """What can be searched, and what each is good for."""
    return {"sources": [
        {"kind": "ytmusic", "name": "YouTube Music", "searchable": True,
         "fetched_by": "worker",
         "note": "Everything, eventually — downloads run on the machine at home."},
        {"kind": "soundcloud", "name": "SoundCloud", "searchable": True,
         "fetched_by": "server",
         "note": "160 kbps AAC, and the server fetches it directly."},
        {"kind": "bandcamp", "name": "Bandcamp", "searchable": True,
         "fetched_by": "server",
         "note": "Paste an album link to take the whole record at once."},
    ]}


@router.get("/search")
def search(q: str, source: str = "soundcloud", limit: int = 8,
           user: dict = Depends(current_user)):
    if not q.strip():
        return {"items": []}
    try:
        hits = sources.search(source, q.strip(), min(limit, 20))
    except sources.SourceError as e:
        raise HTTPException(502, str(e))

    have = {}
    for h in hits:
        found = catalog.find_by_provider(h["provider"], h["provider_id"])
        have[h["provider_id"]] = catalog.public(found) if found else None
    return {"items": [{**h, "track": have.get(h["provider_id"])} for h in hits]}


@router.post("/resolve", status_code=201)
def resolve(body: dict = Body(...), user: dict = Depends(current_user)):
    """One track from one of the direct sources, queued for download here."""
    provider = body.get("provider")
    provider_id = str(body.get("provider_id") or "")
    if provider not in sources.DIRECT or not provider_id:
        raise HTTPException(400, "provider and provider_id required")

    existing = catalog.find_by_provider(provider, provider_id)
    if existing:
        if existing["state"] == "pending":
            jobs.promote(existing["id"])
        return catalog.public(existing)

    meta = {"provider_id": provider_id, "title": body.get("title") or provider_id,
            "artists": body.get("artists") or [], "album": body.get("album"),
            "duration_ms": body.get("duration_ms"), "url": body.get("url")}
    return catalog.public(catalog.create_from_source(provider, meta))


@router.get("/preview")
def preview(url: str, user: dict = Depends(current_user)):
    """What is behind this link, before anything is added.

    A Bandcamp album answers with its whole tracklist in one request, which is the
    cheapest and most accurate import in the app: the metadata is what the artist typed.
    """
    provider = sources.provider_for_url(url)
    if provider != "bandcamp":
        raise HTTPException(400, "Only Bandcamp links can be previewed for now.")
    try:
        tracks = sources.bandcamp_tracks(url)
    except sources.SourceError as e:
        raise HTTPException(400, str(e))

    for t in tracks:
        found = catalog.find_by_provider("bandcamp", t["provider_id"])
        t["track"] = catalog.public(found) if found else None
    return {
        "provider": "bandcamp",
        "album": tracks[0]["album"] if tracks else None,
        "artist": tracks[0]["artists"][0] if tracks and tracks[0]["artists"] else None,
        "tracks": tracks,
        "unavailable": sum(1 for t in tracks if not t["streamable"]),
    }


@router.post("/import", status_code=201)
def import_album(body: dict = Body(...), user: dict = Depends(current_user)):
    """Take a whole Bandcamp record, in order, as a playlist of its own."""
    url = body.get("url") or ""
    if sources.provider_for_url(url) != "bandcamp":
        raise HTTPException(400, "Only Bandcamp albums can be imported this way.")
    try:
        tracks = sources.bandcamp_tracks(url)
    except sources.SourceError as e:
        raise HTTPException(400, str(e))

    playable = [t for t in tracks if t["streamable"]]
    if not playable:
        raise HTTPException(400, "Nothing on this record streams without buying it.")

    album = playable[0]["album"] or "Bandcamp album"
    artist = playable[0]["artists"][0] if playable[0]["artists"] else None
    batch_id, label = f"bandcamp:{url}", f"Bandcamp · {album}"

    from . import db                                     # local: routes own their writes

    # Tracks first, playlist second. Making the playlist up front left an empty one
    # behind every time anything after it went wrong.
    resolved = [
        catalog.find_by_provider("bandcamp", t["provider_id"])
        or catalog.create_from_source("bandcamp", t, discovered_via=catalog.VIA_SYNC,
                                      priority=jobs.PRIORITY_BULK,
                                      batch_id=batch_id, batch_label=label)
        for t in playable
    ]

    with db.pool().connection() as c:
        playlist_id = c.execute(
            """insert into playlists(owner_id, name, kind, remote_id, sync_mode,
                                     source_name)
               values(%s,%s,'local',%s,'off',%s) returning id""",
            (user["id"], album, url, artist),
        ).fetchone()["id"]
        for pos, track in enumerate(resolved):
            c.execute("""insert into playlist_items(playlist_id,pos,track_id)
                         values(%s,%s,%s)""", (playlist_id, pos, track["id"]))

    return {"playlist_id": playlist_id, "name": album, "added": len(resolved),
            "unavailable": len(tracks) - len(playable)}
