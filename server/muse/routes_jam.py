"""Listening together. See jam.py for what a jam is.

The host's device is the one making sound; everything here is about letting other
people reach into the queue it is playing from.
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
    if track:
        votes = db.one(
            "select count(*) n from jam_skip_votes where jam_id=%s and track_id=%s",
            (row["id"], track["id"]),
        )["n"]
        state["skip_votes"] = votes
    return {"jam": state}


@router.patch("/{jam_id}")
def update_jam(jam_id: int, body: dict = Body(...), user: dict = Depends(current_user)):
    """Whether guests can add, and whether they can vote to skip. Host's call."""
    row = jam.get(jam_id)
    if not row or row["ended_at"]:
        raise HTTPException(404, "no such jam")
    if row["host_id"] != user["id"]:
        raise HTTPException(403, "only the host can change how the jam works")

    fields = {k: bool(v) for k, v in body.items()
              if k in ("guests_can_add", "guests_can_skip")}
    if not fields:
        raise HTTPException(400, "nothing to change")
    for key, value in fields.items():
        db.run(f"update jams set {key}=%s where id=%s", (value, jam_id))
    row = jam.get(jam_id)
    announce(row, "settings")
    return jam.public(row, user["id"])


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


@router.post("/{jam_id}/skip-vote")
def skip_vote(jam_id: int, body: dict = Body(default={}),
              user: dict = Depends(current_user)):
    """Ask for the current track to be dropped. Enough asks and it is."""
    row = jam.get(jam_id)
    if not row or row["ended_at"]:
        raise HTTPException(404, "no such jam")
    if not db.one("select 1 from jam_members where jam_id=%s and user_id=%s",
                  (jam_id, user["id"])):
        raise HTTPException(403, "you are not in this jam")
    if not row["guests_can_skip"] and row["host_id"] != user["id"]:
        raise HTTPException(403, "the host has turned voting off for this jam")

    track_id = body.get("track_id")
    if not track_id:
        playing = db.one(
            """select i.track_id from queues q
                 join queue_items i on i.queue_id=q.id and i.pos=q.cursor_index
                where q.id=%s""",
            (row["queue_id"],),
        )
        track_id = playing["track_id"] if playing else None
    if not track_id:
        raise HTTPException(400, "nothing is playing to skip")

    result = jam.vote_skip(jam_id, int(track_id), user["id"])
    announce(row, "skip-vote", {"track_id": int(track_id), **result})
    if result["passed"]:
        # The host's player is what actually skips; it is listening for this.
        announce(row, "skip", {"track_id": int(track_id)})
        jam.clear_votes(jam_id, int(track_id))
    return result
