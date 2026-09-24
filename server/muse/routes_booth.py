"""What the booth did and what was thought of it: every mix the automix made, every
time a hand steered it, and the thumb up or down after — kept so the planner's
guesses at what makes a good mix can one day be fitted to what this person likes.
Nothing here changes what the booth does; it only listens."""
from __future__ import annotations

import json

from fastapi import APIRouter, Body, Depends, HTTPException

from . import db
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
