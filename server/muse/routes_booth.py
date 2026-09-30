"""What the booth did and what was thought of it: every mix the automix made, every
time a hand steered it, and the thumb up or down after — kept so the planner's
guesses at what makes a good mix can one day be fitted to what this person likes.
Nothing here changes what the booth does; it only listens."""
from __future__ import annotations

import json

from fastapi import APIRouter, Body, Depends, HTTPException

from . import db, heavy, setbuild, traits
from .deps import current_user

router = APIRouter(prefix="/booth")

EVENTS = ("mix", "rating", "steer", "replay")


def _int(v):
    try:
        return int(v) if v is not None else None
    except (TypeError, ValueError):
        return None


@router.post("/feedback")
def feedback(body: dict = Body(...), user: dict = Depends(current_user)):
    event = body.get("event")
    if event not in EVENTS:
        raise HTTPException(400, f"event is one of {', '.join(EVENTS)}")
    rating = _int(body.get("rating"))
    if rating is not None and rating not in (-1, 0, 1):
        raise HTTPException(400, "rating is -1, 0 or 1")
    detail = body.get("detail") if isinstance(body.get("detail"), dict) else {}
    row = db.one(
        """insert into mix_feedback(user_id, device_id, event, from_track, to_track, kind, bars,
                                    shift, out_ms, in_ms, rating, detail)
           values(%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s) returning id""",
        (user["id"], user.get("device_id"), event, _int(body.get("from_track")),
         _int(body.get("to_track")), body.get("kind"), _int(body.get("bars")),
         float(body["shift"]) if body.get("shift") is not None else None,
         _int(body.get("out_ms")), _int(body.get("in_ms")), rating, json.dumps(detail)))
    return {"id": row["id"]}


@router.get("/feedback")
def feedback_list(limit: int = 200, user: dict = Depends(current_user)):
    """This person's own, newest first — for the export that fits the weights."""
    rows = db.all_(
        """select id, at, event, from_track, to_track, kind, bars, shift, out_ms, in_ms, rating, detail
             from mix_feedback where user_id=%s order by id desc limit %s""",
        (user["id"], max(1, min(2000, limit))))
    return {"feedback": [{**r, "at": r["at"].isoformat()} for r in rows]}


@router.get("/partners")
def partners(from_track: int, exclude: str = "", limit: int = 12, step: float = 0.0,
             avoid: str = "", user: dict = Depends(current_user)):
    """The records in this person's library that would follow [from_track] best, by
    what the house knows of each (track_traits): its tempo, its key, its loudness,
    how it sounds. Coarse — the app judges the handful sent back finely, with the
    voices and the moves. [exclude] is what is in the queue already, comma-separated;
    [step] the step in loudness (0 to 1 scale) the set's arc wants here; [avoid] the
    artists lately played, comma-separated."""
    ids = {int(x) for x in exclude.split(",") if x.strip().lstrip("-").isdigit()}
    return {"partners": traits.partners(
        user["id"], from_track, ids, limit=limit, wanted_step=step,
        avoid_artists={s for s in avoid.split(",") if s.strip()})}


# ------------------------------------------------------------------ sets from a pool
def _ids(v, most: int = 5000) -> list[int]:
    out = []
    for x in (v or [])[:most]:
        i = _int(x)
        if i is not None:
            out.append(i)
    return out


def _source(src: dict, user: dict) -> tuple[bool, set[int]]:
    """What a set may be made of: this person's whole library, playlists (any they may
    read), a queue of theirs, and records named outright — together."""
    from .routes_library import _own_queue, _readable
    src = src or {}
    library = bool(src.get("library"))
    ids: set[int] = set(_ids(src.get("ids")))
    for pid in _ids(src.get("playlists"), 50):
        try:
            _readable(pid, user)
        except HTTPException:
            continue
        ids |= {r["track_id"] for r in db.all_(
            "select track_id from playlist_items where playlist_id = %s", (pid,))}
    q = _int(src.get("queue"))
    if q is not None:
        _own_queue(q, user)
        ids |= {r["track_id"] for r in db.all_(
            "select track_id from queue_items where queue_id = %s", (q,))}
    if not library and not ids:
        raise HTTPException(400, "a set needs somewhere to come from: library, playlists, queue or ids")
    return library, ids


def _pool(user: dict, library: bool, ids: set[int], need: set[int]):
    p = setbuild.pool_for(user["id"], library, ids)
    missing = {i for i in need if i not in p.at}
    if missing:
        # The record on now (or a pinned one) from outside the pool: judged all the
        # same, it just is not a candidate of its own.
        p = setbuild.pool_for(user["id"], library, ids | missing)
    return p


def _busy():
    raise HTTPException(503, "the house is busy measuring records: ask again in a moment")


@router.post("/set")
def build_set(body: dict = Body(...), user: dict = Depends(current_user)):
    """A set from a pool: its records in order, each with how well it follows the one
    before and why, where along the set it plays and where the shape wanted it.

    Body: `source` {library, playlists, queue, ids}; `shape` (setbuild.Shape.of);
    `length` {tracks | minutes}; `start` {track_id, before: [ids], pitch}; `pins`
    [{id, slot}]; `must` [ids]; `exclude` [ids]."""
    library, ids = _source(body.get("source") or {}, user)
    shape = setbuild.Shape.of(body.get("shape"))
    start = body.get("start") or {}
    start_id = _int(start.get("track_id"))
    before = _ids(start.get("before"), 50)
    pins = [(_int(p.get("id")), _int(p.get("slot"))) for p in (body.get("pins") or [])
            if isinstance(p, dict)]
    pins = [(i, s) for i, s in pins if i is not None and s is not None and 0 <= s < 200]
    must = _ids(body.get("must"), 60)
    exclude = set(_ids(body.get("exclude"), 5000))
    length = body.get("length") or {}
    tracks = _int(length.get("tracks"))
    try:
        minutes = float(length.get("minutes")) if length.get("minutes") else None
    except (TypeError, ValueError):
        minutes = None
    if not tracks and not minutes:
        tracks = 12
    try:
        pitch = float(start.get("pitch") or 1.0)
    except (TypeError, ValueError):
        pitch = 1.0
    need = {i for i in [start_id, *(i for i, _ in pins), *must] if i is not None}
    try:
        with heavy.turn(f"set:{user['id']}"):
            p = _pool(user, library, ids, need)
            at = p.at
            slots = setbuild.build(
                p, shape,
                start=at.get(start_id) if start_id is not None else None,
                before=[at[i] for i in before if i in at],
                tracks=tracks, minutes=minutes,
                pins={s: at[i] for i, s in pins if i in at},
                must=[at[i] for i in must if i in at],
                exclude={at[i] for i in exclude if i in at},
                pitch=min(1.2, max(0.8, pitch)))
            stats = setbuild.stats(user["id"], library, ids, p)
    except heavy.Busy:
        _busy()
    return {"slots": slots, "stats": stats}


@router.post("/slot")
def slot_choices(body: dict = Body(...), user: dict = Depends(current_user)):
    """What else would sit in one slot of a set: records that follow `prev` and lead
    into `next` well, where the shape wants the set `k` (0 to 1) of the way in —
    never one of `exclude` (the set as it is)."""
    library, ids = _source(body.get("source") or {}, user)
    shape = setbuild.Shape.of(body.get("shape"))
    prev, nxt = _int(body.get("prev")), _int(body.get("next"))
    try:
        k = min(1.0, max(0.0, float(body.get("k") or 0)))
    except (TypeError, ValueError):
        k = 0.0
    limit = max(1, min(20, _int(body.get("limit")) or 6))
    exclude = set(_ids(body.get("exclude"), 5000))
    need = {i for i in (prev, nxt) if i is not None}
    try:
        with heavy.turn(f"set:{user['id']}"):
            p = _pool(user, library, ids, need)
            at = p.at
            out = setbuild.alternatives(
                p, shape, prev=at.get(prev) if prev is not None else None,
                nxt=at.get(nxt) if nxt is not None else None, k=k,
                exclude={at[i] for i in exclude if i in at}, limit=limit)
    except heavy.Busy:
        _busy()
    return {"choices": out}


@router.post("/pool")
def pool_stats(body: dict = Body(...), user: dict = Depends(current_user)):
    """What a pool holds for a set: how many records are named, ready and measured,
    how many were never fetched (and which, so they can be), how its tempos and
    loudnesses spread — what the set page's sliders are drawn over."""
    library, ids = _source(body.get("source") or {}, user)
    try:
        with heavy.turn(f"set:{user['id']}"):
            p = setbuild.pool_for(user["id"], library, ids)
            out = setbuild.stats(user["id"], library, ids, p)
    except heavy.Busy:
        _busy()
    if ids:
        out["unfetched_ids"] = [r["id"] for r in db.all_(
            "select id from tracks where id = any(%s) and state <> 'ready' order by id limit 2000",
            (list(ids),))]
    return out
