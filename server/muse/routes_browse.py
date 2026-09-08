"""Browsing your own library.

Albums and artists are not stored as entities — they are what the enrichment pipeline
wrote onto each track. Deriving them in a query keeps one source of truth: fix a
track's album and the album view fixes itself, with nothing to re-import or migrate.
"""
from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, Query

from . import catalog, db
from .deps import current_user

router = APIRouter(prefix="/library")

SORTS = {
    "added": "t.created_at desc, t.id desc",
    "title": "lower(t.title) asc",
    "artist": "lower(coalesce(t.artists[1], '')) asc, lower(t.title) asc",
    "album": "lower(coalesce(t.album, '')) asc, lower(t.title) asc",
    "duration": "t.duration_ms desc nulls last",
}

_TRACK_SELECT = """
    select t.*, m.path, m.bytes, m.sha256, c.color as cover_color,
           c.sha256 as cover_sha
      from tracks t
      left join media m on m.track_id=t.id and m.role='canonical'
      left join covers c on c.id=t.cover_id
"""


@router.get("/tracks")
def all_tracks(sort: str = "added", limit: int = 200, offset: int = 0,
               ready_only: bool = False, user: dict = Depends(current_user)):
    """Everything in the library. Until now there was no way to see it at all."""
    if sort not in SORTS:
        raise HTTPException(400, f"sort must be one of {', '.join(SORTS)}")
    where = "where t.state='ready'" if ready_only else ""
    rows = db.all_(
        f"{_TRACK_SELECT} {where} order by {SORTS[sort]} limit %s offset %s",
        (min(limit, 500), offset),
    )
    total = db.one(f"select count(*) n from tracks t {where}")["n"]
    return {"items": [catalog.public(t) for t in rows], "total": total,
            "offset": offset, "sort": sort}


@router.get("/albums")
def albums(limit: int = 200, offset: int = 0, user: dict = Depends(current_user)):
    """Grouped by album *and* artist: two records can share a title, and merging them
    would be a worse lie than showing two rows."""
    rows = db.all_(
        """
        select t.album as name,
               coalesce(t.artists[1], 'Unknown artist') as artist,
               count(*) as tracks,
               min(t.release_year) as year,
               max(t.id) filter (where t.cover_id is not null) as cover_track_id,
               sum(coalesce(t.duration_ms, 0)) as duration_ms
          from tracks t
         where t.album is not null and t.album <> ''
         group by t.album, coalesce(t.artists[1], 'Unknown artist')
         order by lower(t.album)
         limit %s offset %s
        """,
        (min(limit, 500), offset),
    )
    return {"items": [
        {**r, "cover_url": f"/tracks/{r['cover_track_id']}/cover"
         if r["cover_track_id"] else None}
        for r in rows
    ]}


@router.get("/albums/tracks")
def album_tracks(album: str, artist: str | None = None,
                 user: dict = Depends(current_user)):
    params: tuple = (album,)
    clause = "where t.album = %s"
    if artist:
        clause += " and coalesce(t.artists[1], 'Unknown artist') = %s"
        params += (artist,)
    rows = db.all_(f"{_TRACK_SELECT} {clause} order by t.id", params)
    return {"items": [catalog.public(t) for t in rows]}


@router.get("/artists")
def artists(limit: int = 300, offset: int = 0, user: dict = Depends(current_user)):
    """Every credited artist, not just the first: a feature is still an appearance."""
    rows = db.all_(
        """
        select artist as name, count(*) as tracks,
               count(distinct album) filter (where album is not null) as albums,
               max(id) filter (where cover_id is not null) as cover_track_id
          from (select unnest(artists) as artist, album, id, cover_id from tracks) x
         where artist is not null and artist <> ''
         group by artist
         order by lower(artist)
         limit %s offset %s
        """,
        (min(limit, 1000), offset),
    )
    return {"items": [
        {**r, "cover_url": f"/tracks/{r['cover_track_id']}/cover"
         if r["cover_track_id"] else None}
        for r in rows
    ]}


@router.get("/artists/tracks")
def artist_tracks(artist: str, user: dict = Depends(current_user)):
    rows = db.all_(
        f"{_TRACK_SELECT} where %s = any(t.artists) order by lower(coalesce(t.album,'')), t.id",
        (artist,),
    )
    return {"items": [catalog.public(t) for t in rows]}


@router.get("/history")
def history(limit: int = 200, user: dict = Depends(current_user)):
    """With timestamps this time. A flat list with no sense of when is not a history."""
    rows = db.all_(
        f"""
        select l.started_at, l.ms_played, l.completed, x.*
          from listens l
          join lateral ({_TRACK_SELECT} where t.id = l.track_id) x on true
         where l.user_id=%s
         order by l.started_at desc
         limit %s
        """,
        (user["id"], min(limit, 500)),
    )
    return {"items": [
        {**catalog.public(r), "played_at": r["started_at"],
         "ms_played": r["ms_played"], "completed": r["completed"]}
        for r in rows
    ]}


@router.delete("/history")
def clear_history(user: dict = Depends(current_user)):
    db.run("delete from listens where user_id=%s", (user["id"],))
    return {"cleared": True}
