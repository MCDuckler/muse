"""Browsing your own library.

Albums and artists are not stored as entities — they are what the enrichment pipeline
wrote onto each track. Deriving them in a query keeps one source of truth: fix a
track's album and the album view fixes itself, with nothing to re-import or migrate.

"Your own" is the join to library_items on every query here. The catalog is shared —
one download serves everybody — but a library is a person's, and without that join
every account saw every track on the box.
"""
from __future__ import annotations

from fastapi import APIRouter, Body, Depends, HTTPException, Query

from . import catalog, db, discography, follows, jobs, sync
from .deps import current_user

router = APIRouter(prefix="/library")

SORTS = {
    # When *you* added it, which is not when it was first downloaded for someone else.
    "added": "li.added_at desc, t.id desc",
    "title": "lower(t.title) asc",
    "artist": "lower(coalesce(t.artists[1], '')) asc, lower(t.title) asc",
    "album": "lower(coalesce(t.album, '')) asc, lower(t.title) asc",
    "duration": "t.duration_ms desc nulls last",
}

_TRACK_SELECT = """
    select t.*, m.path, m.bytes, m.sha256, c.color as cover_color,
           c.sha256 as cover_sha
      from tracks t
      join library_items li on li.track_id = t.id and li.user_id = %s
      left join media m on m.track_id=t.id and m.role='canonical'
      left join covers c on c.id=t.cover_id
"""

# Every query below starts with the user id, because the join above does.
_MINE = "from tracks t join library_items li on li.track_id = t.id and li.user_id = %s"


@router.get("/tracks")
def all_tracks(sort: str = "added", limit: int = 200, offset: int = 0,
               ready_only: bool = False, user: dict = Depends(current_user)):
    """Everything in the library. Until now there was no way to see it at all."""
    if sort not in SORTS:
        raise HTTPException(400, f"sort must be one of {', '.join(SORTS)}")
    where = "where t.state='ready'" if ready_only else ""
    rows = db.all_(
        f"{_TRACK_SELECT} {where} order by {SORTS[sort]} limit %s offset %s",
        (user["id"], min(limit, 500), offset),
    )
    total = db.one(f"select count(*) n {_MINE} {where}", (user["id"],))["n"]
    return {"items": [catalog.public(t) for t in rows], "total": total,
            "offset": offset, "sort": sort}


@router.get("/albums")
def albums(limit: int = 200, offset: int = 0, user: dict = Depends(current_user)):
    """Grouped by album *and* artist: two records can share a title, and merging them
    would be a worse lie than showing two rows."""
    rows = db.all_(
        f"""
        select t.album as name,
               coalesce(t.artists[1], 'Unknown artist') as artist,
               count(*) as tracks,
               min(t.release_year) as year,
               max(t.id) filter (where t.cover_id is not null) as cover_track_id,
               sum(coalesce(t.duration_ms, 0)) as duration_ms
          {_MINE}
         where t.album is not null and t.album <> ''
         group by t.album, coalesce(t.artists[1], 'Unknown artist')
         order by lower(t.album)
         limit %s offset %s
        """,
        (user["id"], min(limit, 500), offset),
    )
    return {"items": [
        {**r, "cover_url": f"/tracks/{r['cover_track_id']}/cover"
         if r["cover_track_id"] else None}
        for r in rows
    ]}


@router.get("/albums/tracks")
def album_tracks(album: str, artist: str | None = None,
                 user: dict = Depends(current_user)):
    params: tuple = (user["id"], album)
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
        f"""
        select artist as name, count(*) as tracks,
               count(distinct album) filter (where album is not null) as albums,
               max(id) filter (where cover_id is not null) as cover_track_id
          from (select unnest(t.artists) as artist, t.album, t.id, t.cover_id
                  {_MINE}) x
         where artist is not null and artist <> ''
         group by artist
         order by lower(artist)
         limit %s offset %s
        """,
        (user["id"], min(limit, 1000), offset),
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
        (user["id"], artist),
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
        (user["id"], user["id"], min(limit, 500)),
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


# ------------------------------------------------------------------ the whole record
#
# A library album is the part of a record somebody happened to add. Showing that as
# "the album" is how a five-track record ends up looking like two songs and a gap. The
# release itself comes from the metadata service; what we hold is matched into it.


def _match_into(remote: list[dict], local: list[dict]) -> tuple[list[dict], list[dict]]:
    """Put each local track where it belongs on the release; return the leftovers.

    Matching on the normalised title, and on length when both sides know it: two songs
    on one record can share a title (a reprise, a live take) and the wrong one being
    marked as held is worse than neither being marked.
    """
    unused = list(local)
    merged = []
    for item in remote:
        want = discography.norm(item.get("title"))
        best, best_gap = None, None
        for cand in unused:
            if discography.norm(cand["title"]) != want:
                continue
            gap = abs((cand.get("duration_ms") or 0) - (item.get("duration_ms") or 0)) \
                if cand.get("duration_ms") and item.get("duration_ms") else 0
            if best is None or gap < best_gap:
                best, best_gap = cand, gap
        if best is not None and (best_gap is None or best_gap <= 20000):
            unused.remove(best)
            merged.append({**item, "track": catalog.public(best)})
        else:
            merged.append({**item, "track": None})
    return merged, unused


@router.get("/albums/detail")
def album_detail(album: str | None = None, artist: str | None = None,
                 remote_id: str | None = None, user: dict = Depends(current_user)):
    """The record, with the parts of it we hold marked as playable.

    Addressable two ways: by the album as the library spells it, and by the release
    itself — which is how a record nobody has any of yet (from an artist's page, or the
    feed) still opens as a page you can do something with.
    """
    release, error = None, None
    try:
        if remote_id:
            release = discography.album(remote_id)
        elif album:
            found = discography.find_album(album, artist)
            if found:
                release = discography.album(found["id"])
    except discography.Unavailable as e:
        error = str(e)

    # Local rows: the album as this library spells it, or as the release does.
    name = album or (release or {}).get("title")
    local = []
    if name:
        params: tuple = (user["id"], name)
        clause = "where lower(t.album) = lower(%s)"
        if artist:
            clause += " and coalesce(t.artists[1], 'Unknown artist') = %s"
            params += (artist,)
        local = db.all_(f"{_TRACK_SELECT} {clause} order by t.id", params)

    if not release:
        # No match, or the service is down: the library is still an album page.
        return {"album": {"name": album, "artist": artist, "source": None,
                          "unavailable": error},
                "tracks": [{"pos": n + 1, "title": r["title"],
                            "artists": r["artists"], "duration_ms": r["duration_ms"],
                            "remote_id": None, "track": catalog.public(r)}
                           for n, r in enumerate(local)],
                "extra": [], "missing": 0}

    merged, extra = _match_into(release["tracks"], local)
    return {
        "album": {
            "name": album or release["title"],
            "release_name": release["title"],
            "artist": release["artist"] or artist,
            "cover": release["cover"],
            "release_date": release["release_date"],
            "record_type": release["record_type"],
            "remote_id": release["remote_id"],
            "source": "deezer",
        },
        "tracks": merged,
        "extra": [catalog.public(r) for r in extra],
        "missing": sum(1 for m in merged if m["track"] is None),
    }


@router.post("/albums/fill")
def fill_album(body: dict = Body(...), user: dict = Depends(current_user)):
    """Fetch the parts of a record we do not have.

    Each one goes through the same matcher as a playlist import, so what arrives is the
    recording the album lists rather than the first search hit — and an ISRC is picked
    up on the way, which is what stops a second copy of a song we already hold.
    """
    album = (body.get("album") or "").strip() or None
    remote_ids = [str(i) for i in (body.get("remote_ids") or [])]
    detail = album_detail(album, body.get("artist"), body.get("remote_id"), user)
    if not detail["album"].get("remote_id"):
        raise HTTPException(404, "That record could not be found to fill in.")

    wanted = [m for m in detail["tracks"] if m["track"] is None and m.get("remote_id")
              and (not remote_ids or m["remote_id"] in remote_ids)]
    if not wanted:
        raise HTTPException(400, "nothing on that record is missing")

    # Whatever the file's own metadata ends up saying, these tracks were fetched as
    # part of this record and have to land on its page — which is grouped by the album
    # text, so that is what gets written.
    group = album or detail["album"]["name"]
    year = (detail["album"].get("release_date") or "")[:4]
    label = f"{detail['album']['artist'] or ''} · {group}".strip(" ·")

    added, review = [], 0
    for item in wanted:
        got = sync.resolve_item("deezer", {
            "remote_id": item["remote_id"],
            "title": item["title"],
            "artists": item["artists"],
            "duration_ms": item["duration_ms"],
            "isrc": discography.track_isrc(item["remote_id"]),
        }, priority=jobs.PRIORITY_NORMAL,
            batch_id=f"album:{detail['album']['remote_id']}", batch_label=label)
        if not got.get("track_id"):
            review += 1
            continue
        added.append(got["track_id"])
        db.run(
            """update tracks
                  set album = %s,
                      release_year = coalesce(release_year, %s),
                      artists = case when cardinality(artists) = 0 then %s
                                     else artists end
                where id = %s""",
            (group, int(year) if year.isdigit() else None,
             item["artists"] or [detail["album"]["artist"] or ""], got["track_id"]),
        )
    catalog.remember(user["id"], *added)
    return {"queued": len(added), "not_matched": review}


@router.get("/artists/detail")
def artist_detail(artist: str, user: dict = Depends(current_user)):
    """An artist, not just the four songs of theirs somebody added."""
    local = db.all_(
        f"{_TRACK_SELECT} where %s = any(t.artists) "
        "order by lower(coalesce(t.album,'')), t.id",
        (user["id"], artist),
    )

    found, error = None, None
    try:
        found = discography.find_artist(artist)
    except discography.Unavailable as e:
        error = str(e)

    out: dict = {
        "artist": {"name": artist, "source": None, "unavailable": error,
                   "following": False},
        "albums": [], "top": [],
        "tracks": [catalog.public(r) for r in local],
    }
    if not found:
        return out

    try:
        albums = discography.artist_albums(found["remote_id"])
        top = discography.artist_top(found["remote_id"])
    except discography.Unavailable as e:
        out["artist"]["unavailable"] = str(e)
        return out

    # How much of each record we hold, counted from the tracks already in hand rather
    # than one query per album.
    held: dict[str, int] = {}
    for row in local:
        held[discography.norm(row.get("album"))] = \
            held.get(discography.norm(row.get("album")), 0) + 1

    out["artist"] = {
        "name": found["name"], "image": found["image"], "remote_id": found["remote_id"],
        "albums": found.get("albums"), "fans": found.get("fans"),
        "source": "deezer",
        "following": follows.is_following(user["id"], "deezer", found["remote_id"]),
    }
    out["albums"] = [{**a, "have": held.get(discography.norm(a["title"]), 0)}
                     for a in albums]
    out["top"] = [{**item, "track": merged["track"]}
                  for item, merged in zip(top, _match_into(top, local)[0])]
    return out
