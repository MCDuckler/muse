"""The back of a record, drawn on.

Turn a sleeve over in the player and the bare board is a surface. What is drawn there
stays with the record, and it belongs to whoever owns the board — yours is yours, and
in a jam it is the host's, so everybody in the room draws on the same sleeve rather
than each on their own copy of it. That is the whole idea: a record going round a
table collects everybody's handwriting.

Strokes arrive as they are drawn rather than when the finger lifts, so a line appears
on somebody else's screen while it is still being made. Each carries the client's own
id for it, so the same stroke growing is an update rather than forty strokes.
"""
from __future__ import annotations

from fastapi import APIRouter, Body, Depends, HTTPException

from . import db, jam
from .deps import current_user

router = APIRouter(prefix="/tracks/{track_id}/marks")

# A line long enough to be a drawing and short enough to be a message. Past this the
# client starts a new stroke, which looks identical and keeps every write small.
MAX_POINTS = 1200

# Colours are an index rather than a value: the palette is the client's business, and a
# board drawn on today should still look right when the palette is prettier.
INKS = 8


def board_owner(user: dict) -> tuple[int, int | None]:
    """Whose board this device is drawing on, and which room it belongs to.

    In a jam it is the host's — for the host that is their own, and for everybody else
    it is somebody else's, which is exactly the difference that makes it shared.
    """
    room = jam.live_for(user["id"])
    if not room:
        return user["id"], None
    return room["host_id"], room["id"]


def _may_read(user: dict, owner_id: int) -> int | None:
    """The room this board is being read through, or nothing if it is your own."""
    if owner_id == user["id"]:
        return None
    room = jam.live_for(user["id"])
    if not room or room["host_id"] != owner_id:
        raise HTTPException(403, "that board belongs to somebody else")
    return room["id"]


@router.get("")
def marks(track_id: int, owner: int | None = None, user: dict = Depends(current_user)):
    """Everything on this record's back."""
    owner_id = owner if owner is not None else board_owner(user)[0]
    _may_read(user, owner_id)
    rows = db.all_(
        """select m.stroke_id, m.ink, m.width, m.points, m.done,
                  m.author_id, u.name as author, u.avatar_sig as author_avatar
             from sleeve_marks m join users u on u.id = m.author_id
            where m.owner_id=%s and m.track_id=%s
            order by m.id""",
        (owner_id, track_id),
    )
    return {"owner_id": owner_id, "track_id": track_id,
            "strokes": [dict(r) for r in rows]}


@router.post("", status_code=201)
def draw(track_id: int, body: dict = Body(...), user: dict = Depends(current_user)):
    """One stroke, or the part of one drawn so far.

    Sent whole every time rather than as a difference: a stroke is a few dozen numbers,
    and "here is the line as it stands" cannot arrive out of order or land twice, which
    is worth far more than the handful of bytes it costs.
    """
    stroke_id = str(body.get("stroke_id") or "").strip()
    points = body.get("points")
    if not stroke_id or not isinstance(points, list) or len(points) < 2:
        raise HTTPException(400, "stroke_id and at least one point required")
    if len(points) % 2:
        raise HTTPException(400, "points are x,y pairs")
    if len(points) > MAX_POINTS * 2:
        raise HTTPException(400, "that stroke is too long — start another")

    owner_id, room = board_owner(user)
    flat = [max(0.0, min(1.0, float(v))) for v in points]
    ink = max(0, min(INKS - 1, int(body.get("ink") or 0)))
    width = max(0.15, min(4.0, float(body.get("width") or 1.0)))
    done = bool(body.get("done"))

    db.run(
        """insert into sleeve_marks(track_id, owner_id, author_id, stroke_id,
                                    ink, width, points, done)
           values(%s,%s,%s,%s,%s,%s,%s,%s)
           on conflict (owner_id, track_id, stroke_id) do update
             set points=excluded.points, done=excluded.done,
                 ink=excluded.ink, width=excluded.width""",
        (track_id, owner_id, user["id"], stroke_id, ink, width, flat, done),
    )

    from .app import publish
    publish("sleeve_mark", {
        "track_id": track_id, "owner_id": owner_id, "jam_id": room,
        "stroke_id": stroke_id, "ink": ink, "width": width, "points": flat,
        "done": done, "author_id": user["id"], "author": user["name"],
        "author_avatar": user.get("avatar_sig"),
    })
    return {"ok": True, "owner_id": owner_id}


@router.delete("/{stroke_id}")
def undo(track_id: int, stroke_id: str, user: dict = Depends(current_user)):
    """Take back a line. Your own, wherever you drew it — including on somebody else's
    board, because the line is yours even when the sleeve is not."""
    owner_id, room = board_owner(user)
    gone = db.all_(
        """delete from sleeve_marks
            where owner_id=%s and track_id=%s and stroke_id=%s and author_id=%s
           returning stroke_id""",
        (owner_id, track_id, stroke_id, user["id"]),
    )
    if gone:
        from .app import publish
        publish("sleeve_erase", {"track_id": track_id, "owner_id": owner_id,
                                 "jam_id": room, "stroke_id": stroke_id})
    return {"removed": len(gone)}


@router.delete("")
def wipe(track_id: int, user: dict = Depends(current_user)):
    """Clear the board. Only the person whose board it is — in a jam, the host."""
    owner_id, room = board_owner(user)
    if owner_id != user["id"]:
        raise HTTPException(403, "the host's board is the host's to clear")
    gone = db.all_(
        "delete from sleeve_marks where owner_id=%s and track_id=%s returning id",
        (owner_id, track_id),
    )
    from .app import publish
    publish("sleeve_wiped", {"track_id": track_id, "owner_id": owner_id,
                             "jam_id": room})
    return {"removed": len(gone)}
