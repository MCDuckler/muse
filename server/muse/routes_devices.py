"""The devices one account listens on, and moving the music between them.

One person, several things to listen on — a phone, a browser at a desk, a tablet on a
shelf — and until now they shared a queue and nothing else. Two of them could play the
same music at once, neither aware of the other; leaving the desk meant finding your
place again on the phone by hand; and a phone left playing in another room could only
be stopped by going to it.

So a device says what it is doing, every few seconds while it plays and whenever that
changes, and any other device of the same account can read that and ask it to do
something: pause, skip, or hand the music over from where it has got to. The asking
goes down the event stream the app is already listening to, addressed to the one
device it is for — see app.publish.

Nothing here decides anything about playback. A command is a message; what it means is
the player's business, on the device that receives it.
"""
from __future__ import annotations

import logging

from fastapi import APIRouter, Body, Depends, HTTPException

from . import catalog, db
from .deps import current_user

log = logging.getLogger("muse.devices")
router = APIRouter(prefix="/devices")

# How recently a device has to have spoken for what it said to be worth believing.
#
# It reports every ten seconds while it is playing, so a minute is five missed reports:
# long enough to survive a phone's radio going quiet in a lift, short enough that a
# laptop closed an hour ago is not still offering to play you something.
LIVE = "60 seconds"

ACTIONS = ("play", "pause", "next", "previous", "seek", "take", "stop")


def _rows(user_id: int) -> list[dict]:
    # The device's own columns are named apart from the track's: `t.*` has an `id`
    # and a `name` of its own, and a row where the song's id has quietly replaced the
    # device's is a device that thinks it is the one you are holding.
    return db.all_(
        f"""select d.id as device, d.name as device_name, d.platform, d.kind,
                   d.last_seen, d.playing, d.position_ms, d.state_at, d.queue_id,
                   d.track_id as has_track,
                   d.state_at > now() - interval '{LIVE}' as live,
                   q.name as queue,
                   t.*, c.color as cover_color, c.sha256 as cover_sha, m.path
              from devices d
              left join queues q on q.id = d.queue_id
              left join tracks t on t.id = d.track_id
              left join covers c on c.id = t.cover_id
              left join media m on m.track_id = t.id and m.role = 'canonical'
             where d.user_id = %s
             order by d.last_seen desc nulls last""",
        (user_id,))


def _public(row: dict, me: int) -> dict:
    return {
        "id": row["device"],
        "name": row["device_name"],
        "platform": row["platform"],
        "kind": row["kind"],
        "this": row["device"] == me,
        # Whether it has said anything lately. A device that has not is listed — it is
        # still one of yours — but nothing it last said is offered as news.
        "live": bool(row["live"]),
        "playing": bool(row["playing"]) and bool(row["live"]),
        "position_ms": row["position_ms"],
        "queue": row["queue"],
        "queue_id": row["queue_id"],
        "last_seen": row["last_seen"],
        "state_at": row["state_at"],
        "track": catalog.public(row) if row["has_track"] else None,
    }


@router.get("")
def devices(user: dict = Depends(current_user)):
    """Everything this account listens on, and what each one is doing."""
    rows = _rows(user["id"])
    return {
        "this": user["device_id"],
        "devices": [_public(r, user["device_id"]) for r in rows],
    }


@router.post("/state")
def report(body: dict = Body(default={}), user: dict = Depends(current_user)):
    """This device, saying what it is doing.

    Sent while playing and whenever something changes. It is the only write here: a
    command tells another device what to do, and *that* device reports the result in
    the ordinary way, so what a screen shows is always something a device said about
    itself rather than something another one assumed.
    """
    playing = bool(body.get("playing"))
    db.run(
        """update devices
              set playing=%s, track_id=%s, queue_id=%s, position_ms=%s,
                  state_at=now(), last_seen=now(),
                  kind=coalesce(%s, kind)
            where id=%s""",
        (playing, body.get("track_id"), body.get("queue_id"),
         int(body.get("position_ms") or 0), body.get("kind"), user["device_id"]),
    )
    from .app import publish

    # The other screens of this account, so a picker that is open updates itself.
    publish("devices", {"device_id": user["device_id"], "playing": playing},
            to_user=user["id"])
    return {"ok": True}


@router.patch("/{device_id}")
def rename(device_id: int, body: dict = Body(...), user: dict = Depends(current_user)):
    """A name you chose, rather than the one the browser gave itself."""
    name = (body.get("name") or "").strip()
    if not name:
        raise HTTPException(400, "a device needs a name")
    if not db.one("select id from devices where id=%s and user_id=%s",
                  (device_id, user["id"])):
        raise HTTPException(404, "no device of yours by that id")
    db.run("update devices set name=%s where id=%s", (name[:60], device_id))
    from .app import publish

    publish("devices", {"device_id": device_id, "renamed": True}, to_user=user["id"])
    return {"id": device_id, "name": name[:60]}


@router.post("/{device_id}/command")
def command(device_id: int, body: dict = Body(...),
            user: dict = Depends(current_user)):
    """Ask one of your devices to do something.

    `take` is the one that matters: it hands the music over — this queue, this song,
    this many milliseconds in — to the device named, which starts playing it there.
    Whoever was playing stops, because the point of moving music between rooms is that
    it is in one of them.
    """
    action = (body.get("action") or "").strip()
    if action not in ACTIONS:
        raise HTTPException(400, f"action must be one of {', '.join(ACTIONS)}")
    target = db.one("select id, name from devices where id=%s and user_id=%s",
                    (device_id, user["id"]))
    if not target:
        raise HTTPException(404, "no device of yours by that id")

    order = {
        "to": device_id,
        "from": user["device_id"],
        "action": action,
        "queue_id": body.get("queue_id"),
        "track_id": body.get("track_id"),
        "position_ms": int(body.get("position_ms") or 0),
    }
    from .app import publish

    publish("device_command", order, to_user=user["id"])
    log.info("device %s asked device %s to %s", user["device_id"], device_id, action)

    # Taking the music away from whoever had it is part of taking it: said here rather
    # than left to the two devices to agree on, so a phone that is asleep in a pocket
    # still stops when the desk takes over.
    if action == "take":
        db.run("update devices set playing=false where user_id=%s and id<>%s",
               (user["id"], device_id))
        publish("device_command",
                {"to": None, "from": user["device_id"], "action": "yield",
                 "except": device_id},
                to_user=user["id"])
    return {"sent": action, "to": target["name"]}
