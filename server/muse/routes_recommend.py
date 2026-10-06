"""What goes with what, asked from anywhere in the app. See recommend.py.

One question with a few ways in — a handful of songs, a playlist, a queue — and one
shape of answer, so the playlist page, the booth's crate, the cover and a station all
offer the same thing for the same reasons.
"""
from __future__ import annotations

from fastapi import APIRouter, Body, Depends, HTTPException

from . import catalog, db, recommend
from .deps import current_user
from .routes_library import _own_queue, _readable

router = APIRouter(prefix="/recommend")


def _ids(text: str | None) -> list[int]:
    return [int(x) for x in (text or "").split(",") if x.strip().isdigit()]


@router.get("")
def recommend_for(seeds: str | None = None, playlist: int | None = None,
                  queue: int | None = None, fresh: float = 0.5, only: str | None = None,
                  exclude: str | None = None, limit: int = 12,
                  user: dict = Depends(current_user)):
    """Songs that go with [seeds] (track ids), a [playlist] or a [queue] — what is on
    and the next few. [fresh] 0 to 1 is how much of the answer is not already yours
    and here; [only] `library` or `new` narrows it. Never anything in [exclude], in the
    playlist or in the queue."""
    if only not in (None, "", "library", "new"):
        raise HTTPException(400, "only: library or new")
    weights: dict[int, float] = {int(i): 1.0 for i in _ids(seeds)[:12]}
    avoid: set[int] = set(_ids(exclude))
    if playlist is not None:
        _readable(playlist, user)
        more, every = recommend.seeds_of_playlist(playlist)
        for k, v in more.items():
            weights.setdefault(k, v)
        avoid |= every
    if queue is not None:
        _own_queue(queue, user)
        cursor = db.one("select cursor_index from queues where id=%s", (queue,))["cursor_index"]
        rows = db.all_("select pos, track_id from queue_items where queue_id=%s order by pos",
                       (queue,))
        for r in rows:
            if cursor <= r["pos"] <= cursor + 3:
                weights.setdefault(r["track_id"], 1.0 if r["pos"] == cursor else 0.6)
        avoid |= {r["track_id"] for r in rows}
    if not weights:
        raise HTTPException(400, "seeds, a playlist or a queue to go on")
    picks = recommend.recommend(user["id"], weights, limit=limit, fresh=fresh,
                                only=only or None, exclude=avoid)
    seed_rows = db.all_("select id, title from tracks where id = any(%s)", (list(weights),))
    return {"items": [recommend.public(p) for p in picks],
            "seeds": [{"id": r["id"], "title": r["title"]} for r in seed_rows]}


@router.get("/home")
def for_home(limit: int = 12, user: dict = Depends(current_user)):
    """The cover's pages of what to play: a mix from what has been played and liked
    lately, and songs loved once and not played for a while. A page with nothing on it
    is left out."""
    tas = recommend.taste(user["id"])
    sections = []
    seeds = recommend.seeds_of_person(user["id"], the_taste=tas)
    if seeds:
        picks = recommend.recommend(user["id"], seeds, limit=limit, fresh=0.4,
                                    the_taste=tas, weights=recommend.PERSON_WEIGHTS)
        if picks:
            sections.append({"id": "mix", "name": "Made for you",
                             "blurb": "Out of what you have played lately — some yours, some new.",
                             "items": [recommend.public(p) for p in picks]})
    back = recommend.rediscover(user["id"], limit=10, the_taste=tas)
    if back:
        rows = recommend._rows_for(back)
        items = [{"where": "library", "score": 0, "why": "loved, then left",
                  "track": catalog.public(rows[t])} for t in back if t in rows]
        if items:
            sections.append({"id": "again", "name": "Back in the box",
                             "blurb": "Songs you wore out and then forgot.",
                             "items": items})
    return {"sections": sections}


@router.post("/dislike")
def dislike(body: dict = Body(...), user: dict = Depends(current_user)):
    """Not for me, said about a song: never offered again, and held against its
    artist when the lists are made. {"undo": true} takes it back."""
    try:
        track_id = int(body["track_id"])
    except (KeyError, TypeError, ValueError):
        raise HTTPException(400, "which track, as a number")
    if not catalog.track_row(track_id):
        raise HTTPException(404, "no such track")
    return {"track_id": track_id,
            "disliked": recommend.dislike(user["id"], track_id, undo=bool(body.get("undo")))}


@router.get("/dislikes")
def dislikes(user: dict = Depends(current_user)):
    return {"track_ids": recommend.disliked(user["id"])}


@router.post("/dismiss")
def dismiss(body: dict = Body(...), user: dict = Depends(current_user)):
    """Not for me: never offered to this person again."""
    track_id, video_id = body.get("track_id"), body.get("video_id")
    if not track_id and not video_id:
        raise HTTPException(400, "track_id or video_id")
    recommend.dismiss(user["id"], track_id=track_id, video_id=video_id)
    return {"ok": True}
