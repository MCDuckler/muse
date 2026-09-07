"""Lyrics and listening history — the two things a player needs that are not audio."""
from __future__ import annotations

import httpx
from fastapi import APIRouter, Body, Depends, HTTPException

from . import catalog, db
from .deps import current_user

router = APIRouter()

LRCLIB = "https://lrclib.net/api/get"
# LRCLIB throttles hard (roughly one request per 30s on the public endpoint), so this
# is fetch-on-demand and cached forever. A miss is cached too — an instrumental will
# not gain lyrics by being asked twice.
UA = "muse/0.1 (personal music server; https://github.com/local/muse)"


@router.get("/tracks/{track_id}/lyrics")
def lyrics(track_id: int, refresh: bool = False, user: dict = Depends(current_user)):
    t = catalog.track_row(track_id)
    if not t:
        raise HTTPException(404, "no such track")

    cached = db.one("select * from lyrics where track_id=%s", (track_id,))
    if cached and not refresh:
        return {"track_id": track_id, "synced": cached["synced"], "plain": cached["plain"],
                "source": cached["source"], "cached": True}

    params = {
        "track_name": t["title"] or "",
        "artist_name": (t["artists"] or [""])[0],
        "album_name": t["album"] or "",
        "duration": round((t["duration_ms"] or 0) / 1000),
    }
    synced = plain = None
    source = "lrclib"
    try:
        r = httpx.get(LRCLIB, params=params, headers={"User-Agent": UA}, timeout=15)
        if r.status_code == 200:
            d = r.json()
            synced, plain = d.get("syncedLyrics"), d.get("plainLyrics")
        elif r.status_code == 404:
            source = "lrclib-miss"
        else:
            raise HTTPException(502, f"lrclib returned {r.status_code}")
    except httpx.HTTPError as e:
        raise HTTPException(502, f"lrclib unreachable: {e}")

    db.run(
        """insert into lyrics(track_id,synced,plain,source) values(%s,%s,%s,%s)
           on conflict (track_id) do update set synced=excluded.synced,
                 plain=excluded.plain, source=excluded.source, fetched_at=now()""",
        (track_id, synced, plain, source),
    )
    return {"track_id": track_id, "synced": synced, "plain": plain,
            "source": source, "cached": False}


@router.post("/listens", status_code=201)
def record_listen(body: dict = Body(...), user: dict = Depends(current_user)):
    """One row per play attempt. `completed` is the client's call, not a guess from ms."""
    track_id = body.get("track_id")
    if not track_id or not catalog.track_row(track_id):
        raise HTTPException(404, "no such track")
    row = db.one(
        """insert into listens(user_id,track_id,ms_played,completed)
           values(%s,%s,%s,%s) returning id, started_at""",
        (user["id"], track_id, int(body.get("ms_played", 0)), bool(body.get("completed", False))),
    )
    return {"id": row["id"], "started_at": row["started_at"]}


@router.get("/history")
def history(limit: int = 50, user: dict = Depends(current_user)):
    rows = db.all_(
        """select distinct on (l.track_id) l.track_id, l.started_at, l.ms_played, l.completed,
                  t.*, m.path
             from listens l join tracks t on t.id=l.track_id
             left join media m on m.track_id=t.id and m.role='canonical'
            where l.user_id=%s
            order by l.track_id, l.started_at desc""",
        (user["id"],),
    )
    rows.sort(key=lambda r: r["started_at"], reverse=True)
    return [{**catalog.public(r), "last_played": r["started_at"],
             "completed": r["completed"]} for r in rows[:limit]]


@router.get("/stats")
def stats(user: dict = Depends(current_user)):
    top = db.all_(
        """select t.id, t.title, t.artists, count(*) plays,
                  sum(l.ms_played) ms
             from listens l join tracks t on t.id=l.track_id
            where l.user_id=%s and l.completed
            group by t.id order by plays desc, ms desc limit 20""",
        (user["id"],),
    )
    totals = db.one(
        """select count(*) plays, coalesce(sum(ms_played),0) ms
             from listens where user_id=%s and completed""",
        (user["id"],),
    )
    return {"top": top, "plays": totals["plays"],
            "hours": round(int(totals["ms"]) / 3_600_000, 2)}
