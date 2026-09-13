"""Listening together. See jam.py for what a jam is.

Two halves. The queue is shared, so anyone in the room can put something on; and the
host's transport is broadcast, so every device plays the same song at the same place.
Everybody in the room works the controls — a guest's play button asks the host's player
to do it rather than doing it here, because one device has to be the clock or the room
drifts apart, but there is nothing anybody is not allowed to press.
"""
from __future__ import annotations

from fastapi import APIRouter, Body, Depends, HTTPException

from . import catalog, db, jam
from .deps import current_user

router = APIRouter(prefix="/jams")

_publish = None                    # set by app.create_app, to avoid importing it here


def set_publisher(fn) -> None:
    global _publish
    _publish = fn


def announce(jam_row: dict, what: str, extra: dict | None = None) -> None:
    if _publish:
        _publish("jam", {"jam_id": jam_row["id"], "code": jam_row["code"],
                         "queue_id": jam_row["queue_id"], "what": what, **(extra or {})})


@router.post("", status_code=201)
def start_jam(body: dict = Body(default={}), user: dict = Depends(current_user)):
    """Open a queue to other people and hand back the code they need."""
    queue_id = body.get("queue_id")
    if not queue_id:
        raise HTTPException(400, "queue_id required")
    if not db.one("select 1 from queues where id=%s and user_id=%s", (queue_id, user["id"])):
        raise HTTPException(404, "no such queue")

    row = jam.start(user["id"], int(queue_id))
    announce(row, "started")
    return jam.public(row, user["id"])


@router.post("/join")
def join_jam(body: dict = Body(...), user: dict = Depends(current_user)):
    code = (body.get("code") or "").strip()
    if not code:
        raise HTTPException(400, "code required")
    row = jam.by_code(code)
    if not row:
        raise HTTPException(404, "That code does not belong to a jam that is running.")

    # One jam at a time: joining a second would leave you queued into a room you can no
    # longer see.
    existing = jam.live_for(user["id"])
    if existing and existing["id"] != row["id"] and existing["host_id"] != user["id"]:
        jam.leave(existing["id"], user["id"])
        announce(existing, "left", {"who": user["name"]})

    jam.join(row["id"], user["id"])
    announce(row, "joined", {"who": user["name"]})
    return jam.public(row, user["id"])


@router.get("")
def running_jams(user: dict = Depends(current_user)):
    """The rooms with the lights on, so joining one is a tap rather than a code."""
    return {"items": jam.running(exclude_user=user["id"])}


@router.get("/people")
def people(user: dict = Depends(current_user)):
    """Everyone with an account here, and whether they are around.

    "Around" is a device that has been seen in the last few minutes — enough to know
    whether tapping a name will reach anybody.
    """
    return {"items": db.all_(
        """select u.id, u.name, u.avatar_sig,
                  max(d.last_seen) as last_seen,
                  max(d.last_seen) > now() - interval '5 minutes' as online
             from users u left join devices d on d.user_id = u.id
            where u.id <> %s
            group by u.id, u.name, u.avatar_sig
            order by online desc nulls last, lower(u.name)""",
        (user["id"],),
    )}


@router.post("/{jam_id}/invite")
def invite(jam_id: int, body: dict = Body(...), user: dict = Depends(current_user)):
    """Put somebody in the jam by name. Only the host hands out places."""
    row = db.one("select * from jams where id=%s and ended_at is null", (jam_id,))
    if not row:
        raise HTTPException(404, "That jam is not running.")
    if row["host_id"] != user["id"]:
        raise HTTPException(403, "Only the host can invite people.")

    invited = db.one("select id, name from users where id=%s", (body.get("user_id"),))
    if not invited:
        raise HTTPException(404, "no such person")

    jam.invite(row["id"], invited["id"])
    announce(row, "joined", {"who": invited["name"], "invited_by": user["name"]})
    return jam.public(db.one("select * from jams where id=%s", (row["id"],)), user["id"])


@router.get("/current")
def current_jam(user: dict = Depends(current_user)):
    """The jam you are in, if any — and a heartbeat, so the others can see you are
    still here."""
    row = jam.live_for(user["id"])
    if not row:
        return {"jam": None}
    jam.touch(row["id"], user["id"])
    state = jam.public(row, user["id"])
    playing = db.one(
        """select q.cursor_index, i.track_id
             from queues q
             left join queue_items i on i.queue_id=q.id and i.pos=q.cursor_index
            where q.id=%s""",
        (row["queue_id"],),
    )
    track = catalog.track_row(playing["track_id"]) if playing and playing["track_id"] else None
    state["now_playing"] = catalog.public(track) if track else None
    # Where the music actually is, so a device joining or coming back from a reload
    # lands in the right place in the right song rather than at the top of it.
    state["playback"] = jam.playback(row["id"])
    return {"jam": state}


@router.post("/{jam_id}/leave")
def leave_jam(jam_id: int, user: dict = Depends(current_user)):
    row = jam.get(jam_id)
    if not row:
        raise HTTPException(404, "no such jam")
    if row["host_id"] == user["id"]:
        # The host leaving is the jam ending: without their device there is no music.
        jam.end(jam_id)
        announce(row, "ended")
        return {"ended": True}
    jam.leave(jam_id, user["id"])
    announce(row, "left", {"who": user["name"]})
    return {"left": True}


@router.post("/{jam_id}/remove")
def remove_member(jam_id: int, body: dict = Body(...), user: dict = Depends(current_user)):
    row = jam.get(jam_id)
    if not row or row["ended_at"]:
        raise HTTPException(404, "no such jam")
    if row["host_id"] != user["id"]:
        raise HTTPException(403, "only the host can remove someone")
    target = int(body.get("user_id", 0))
    if target == row["host_id"]:
        raise HTTPException(400, "the host cannot be removed from their own jam")
    jam.leave(jam_id, target)
    announce(row, "left")
    return {"removed": target}


@router.post("/{jam_id}/playback")
def push_playback(jam_id: int, body: dict = Body(...),
                  user: dict = Depends(current_user)):
    """The host saying what its player is doing. Everyone else follows this.

    Sent when something changes — a track, a play, a pause, a seek — and every few
    seconds while music is running, which is what keeps the room from drifting apart
    over the length of a song.
    """
    row = jam.get(jam_id)
    if not row or row["ended_at"]:
        raise HTTPException(404, "no such jam")
    if row["host_id"] != user["id"]:
        raise HTTPException(403, "only the host's player sets the time")

    state = jam.set_playback(jam_id, body.get("track_id"),
                             int(body.get("position_ms") or 0),
                             bool(body.get("playing")))
    announce(row, "playback", {
        "track_id": state["track_id"],
        "position_ms": state["position_ms"],
        "playing": state["playing"],
    })
    return {"ok": True}


@router.post("/{jam_id}/queue")
def move_jam(jam_id: int, body: dict = Body(...),
             user: dict = Depends(current_user)):
    """The host putting a different queue on, with the room following.

    Only the host: a room where anybody can change what everybody is listening to by
    opening their own queue is not a room, it is a fight.
    """
    row = jam.get(jam_id)
    if not row or row["ended_at"]:
        raise HTTPException(404, "no such jam")
    if row["host_id"] != user["id"]:
        raise HTTPException(403, "only the host chooses what the room is playing")

    queue_id = int(body.get("queue_id") or 0)
    if not db.one("select 1 from queues where id=%s and user_id=%s",
                  (queue_id, user["id"])):
        raise HTTPException(404, "no such queue")
    if queue_id == row["queue_id"]:
        return jam.public(row, user["id"])

    moved = jam.move_to(jam_id, queue_id) or row
    # Announced with the *new* queue on it, which is what tells everybody else to go
    # and look at something else.
    announce(moved, "moved", {"from_queue_id": row["queue_id"]})
    return jam.public(moved, user["id"])


@router.post("/{jam_id}/control")
def control(jam_id: int, body: dict = Body(...), user: dict = Depends(current_user)):
    """Anybody in the room reaching for the transport: play, pause, next, previous, seek.

    It is a request, not the act: the host's device carries it out and then says what
    happened, so there is one answer to "where are we" rather than one per device. That
    is the only reason the host is special — not permission, timekeeping.
    """
    row = jam.get(jam_id)
    if not row or row["ended_at"]:
        raise HTTPException(404, "no such jam")
    if not db.one("select 1 from jam_members where jam_id=%s and user_id=%s",
                  (jam_id, user["id"])):
        raise HTTPException(403, "you are not in this jam")

    action = (body.get("action") or "").strip()
    if action not in ("play", "pause", "next", "previous", "seek"):
        raise HTTPException(400, "action must be play, pause, next, previous or seek")

    announce(row, "control", {
        "action": action,
        "position_ms": int(body.get("position_ms") or 0),
        "track_id": body.get("track_id"),
        "by": user["name"],
    })
    return {"asked": action}
