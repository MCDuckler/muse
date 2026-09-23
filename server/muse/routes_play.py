"""Lyrics and listening history — the two things a player needs that are not audio."""
from __future__ import annotations

import pathlib
import subprocess

import httpx
from fastapi import APIRouter, Body, Depends, HTTPException, Response

from . import catalog, db
from . import beats as _beats
from . import peaks as _peaks
from . import scrobble
from .deps import cfg, current_user

router = APIRouter()

LRCLIB = "https://lrclib.net/api/get"
# LRCLIB throttles hard (roughly one request per 30s on the public endpoint), so this
# is fetch-on-demand and cached forever. A miss is cached too — an instrumental will
# not gain lyrics by being asked twice.
UA = "muse/0.1 (personal music server; https://github.com/local/muse)"


@router.get("/tracks/{track_id}/peaks")
def peaks(track_id: int, response: Response, slices: int = _peaks.SLICES,
          bands: bool = False, user: dict = Depends(current_user)):
    """The song's loudness, a slice at a time, for drawing the seek bar as its shape.

    Only for a song whose audio is here: the shape of something not downloaded yet is
    not known, and the bar draws flat until it is."""
    t = catalog.track_row(track_id)
    if not t or not t.get("path"):
        raise HTTPException(404, "not ready" if t else "no such track")
    audio = pathlib.Path(t["path"])
    if not audio.exists():
        raise HTTPException(404, "the audio is missing")
    try:
        shape = _peaks.for_track(cfg().data_dir, audio, t["sha256"],
                                 slices=slices, bands=bands)
    except (subprocess.SubprocessError, OSError) as e:
        raise HTTPException(502, "could not read the audio") from e
    # The same file always has the same shape, and the file is named by its hash.
    response.headers["Cache-Control"] = "private, max-age=31536000, immutable"
    if bands:
        return {"bands": shape, "slices": len(shape["low"])}
    return {"peaks": shape, "slices": len(shape)}


@router.get("/tracks/{track_id}/analysis")
def analysis(track_id: int, response: Response, user: dict = Depends(current_user)):
    """Where the song really starts and ends, how fast it goes, and where its beats are.

    What playing one song straight into the next is done from, and what anything that
    moves with the music keeps time by. Worked out on the first ask — about half a
    second a song — and kept; see beats.py."""
    t = catalog.track_row(track_id)
    if not t or not t.get("path"):
        raise HTTPException(404, "not ready" if t else "no such track")
    audio = pathlib.Path(t["path"])
    if not audio.exists():
        raise HTTPException(404, "the audio is missing")
    try:
        found = _beats.for_track(cfg().data_dir, audio, t["sha256"])
    except (subprocess.SubprocessError, OSError) as e:
        raise HTTPException(502, "could not read the audio") from e
    if t.get("analysed_at") is None or t.get("bpm") != found.get("bpm"):
        db.run("update tracks set bpm=%s, analysed_at=now() where id=%s",
               (found.get("bpm"), track_id))
    # The same file always has the same beats, and the file is named by its hash.
    response.headers["Cache-Control"] = "private, max-age=31536000, immutable"
    return found


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
    track = catalog.track_row(track_id) if track_id else None
    if not track:
        raise HTTPException(404, "no such track")
    ms_played, completed = int(body.get("ms_played", 0)), bool(body.get("completed", False))
    row = db.one(
        """insert into listens(user_id,track_id,ms_played,completed)
           values(%s,%s,%s,%s) returning id, started_at""",
        (user["id"], track_id, ms_played, completed),
    )
    # Into a listening diary elsewhere, if this person keeps one. After the listen is
    # written and off to one side: see scrobble.after_a_listen.
    scrobble.after_a_listen(user["id"], row["id"], ms_played,
                            track.get("duration_ms"), completed)
    # The tally comes back with it, so a score can tick up at the moment the record
    # ends rather than the next time the app is opened. Counted rather than kept: the
    # listens are the record of what happened, and a number kept beside them can only
    # ever disagree with them.
    score = db.one("select count(*) n from listens where user_id=%s and completed",
                   (user["id"],))["n"]
    return {"id": row["id"], "started_at": row["started_at"], "score": score}


@router.post("/playback-log", status_code=201)
def playback_log(body: dict = Body(...), user: dict = Depends(current_user)):
    """What the audio engine did on a phone, as the phone wrote it down.

    Sent when the app comes back to the front, because the minute worth reading is the
    one it was not in front for. Only the last handful per person is kept — this is for
    answering "why did it stop" this week, not a diary.
    """
    lines = body.get("lines") or []
    if not isinstance(lines, list) or not lines:
        raise HTTPException(400, "lines required")
    text = "\n".join(str(l) for l in lines[-400:])[:60_000]
    db.run(
        """insert into playback_reports(user_id, device, build, lines)
           values(%s,%s,%s,%s)""",
        (user["id"], str(body.get("device") or "")[:120],
         str(body.get("build") or "")[:40], text),
    )
    db.run(
        """delete from playback_reports
            where user_id=%s and id not in (
                select id from playback_reports where user_id=%s
                 order by at desc limit 10)""",
        (user["id"], user["id"]),
    )
    return {"kept": True}


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
