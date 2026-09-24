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


def _rows(user_id: int, me: int) -> list[dict]:
    # Only what has been heard from this month, and the one asking. Every browser
    # that ever signed in is a row here, and a list of every laptop you have used
    # since spring is not an answer to "where shall this play".
    # The device's own columns are named apart from the track's: `t.*` has an `id`
    # and a `name` of its own, and a row where the song's id has quietly replaced the
    # device's is a device that thinks it is the one you are holding.
    return db.all_(
        f"""select d.id as device, d.name as device_name, d.platform, d.kind,
                   d.last_seen, d.playing, d.position_ms, d.state_at, d.queue_id,
                   d.item_id as device_item,
                   (extract(epoch from now() - d.state_at) * 1000)::int as age_ms,
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
               and (coalesce(d.last_seen, now()) > now() - interval '30 days' or d.id = %s)
             order by d.last_seen desc nulls last""",
        (user_id, me))


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
        # How old that position is, by the server's clock: a screen showing where another
        # device has got to carries it forward by this much and then by its own clock.
        "age_ms": max(0, row["age_ms"] or 0),
        "item_id": row["device_item"],
        "queue": row["queue"],
        "queue_id": row["queue_id"],
        "last_seen": row["last_seen"],
        "state_at": row["state_at"],
        "track": catalog.public(row) if row["has_track"] else None,
    }


@router.get("")
def devices(user: dict = Depends(current_user)):
    """Everything this account listens on, and what each one is doing."""
    rows = _rows(user["id"], user["device_id"])
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
    position_ms = int(body.get("position_ms") or 0)
    db.run(
        """update devices
              set playing=%s, track_id=%s, queue_id=%s, position_ms=%s, item_id=%s,
                  state_at=now(), last_seen=now(),
                  kind=coalesce(%s, kind)
            where id=%s""",
        (playing, body.get("track_id"), body.get("queue_id"), position_ms,
         body.get("item_id"), body.get("kind"), user["device_id"]),
    )
    from .app import publish

    # The other screens of this account — with everything that was said, not only that
    # something was. A screen working this device as a remote control draws its seek
    # bar from this, and one that had to go and ask again after every report was always
    # a round trip behind the music.
    #
    # The song itself goes too. A screen that had only its id went back for the list
    # and then for the queue before it could show anything: two round trips between
    # the phone starting a song and the desk saying so. With the song in hand the desk
    # says so at once and fetches the queue behind it.
    track = _track(body.get("track_id"))
    queue = db.one("select name from queues where id=%s", (body.get("queue_id"),)) \
        if body.get("queue_id") else None
    publish("devices", {"device_id": user["device_id"], "playing": playing,
                        "track_id": body.get("track_id"),
                        "queue_id": body.get("queue_id"),
                        "queue": queue["name"] if queue else None,
                        "item_id": body.get("item_id"),
                        "position_ms": position_ms,
                        "track": track},
            to_user=user["id"])
    return {"ok": True}


def _track(track_id) -> dict | None:
    if not track_id:
        return None
    row = db.one(
        """select t.*, c.color as cover_color, c.sha256 as cover_sha, m.path
             from tracks t
             left join covers c on c.id = t.cover_id
             left join media m on m.track_id = t.id and m.role = 'canonical'
            where t.id = %s""",
        (track_id,))
    return catalog.public(row) if row else None


# ------------------------------------------------------------------ fetching music
#
# A computer on a home connection can fetch what the server cannot: YouTube answers a
# house and refuses a datacentre. Every desktop is in the pool unless an admin blocks it
# (pool.py, routes_pool.py); these are the older questions about it, kept for apps from
# before the pool.

def _workers() -> dict[str, dict]:
    return {w["name"]: w for w in db.all_(
        """select name, last_seen, leased,
                  last_seen > now() - interval '90 seconds' as live
             from workers""")}


@router.get("/ingest")
def my_ingest(user: dict = Depends(current_user)):
    """Whether this device may fetch music, and whether it has asked to."""
    # Every computer is in the pool now unless an admin blocked it (pool.py); there is
    # nothing to ask for any more, and an app from before the pool reads "allowed".
    d = db.one("select pool_blocked from devices where id=%s", (user["device_id"],)) or {}
    return {"allowed": not d.get("pool_blocked"), "asked": True,
            "worker": f"device:{user['device_id']}"}


@router.post("/ingest/ask")
def ask_to_ingest(user: dict = Depends(current_user)):
    """Offer this computer. An admin's own device is simply allowed."""
    return my_ingest(user)


@router.delete("/ingest")
def stop_ingesting(user: dict = Depends(current_user)):
    """Take the offer back. Whatever this device was holding is given back too."""
    db.run("""update jobs set state='pending', leased_by=null, leased_until=null
               where state='leased' and leased_by=%s""", (f"device:{user['device_id']}",))
    return my_ingest(user)


@router.get("/workers")
def workers(user: dict = Depends(current_user)):
    """Everything that fetches music, and everything asking to: for an admin."""
    from .routes_accounts import _admin

    _admin(user)
    known = _workers()
    rows = db.all_(
        """select d.id, d.name, d.platform, d.kind, not d.pool_blocked as can_ingest,
                  d.pool_at as ingest_asked_at, u.name as owner
             from devices d join users u on u.id = d.user_id
            where d.pool_at is not null or d.pool_blocked
            order by d.pool_blocked, d.pool_at desc nulls last""")
    devices_ = []
    for r in rows:
        w = known.pop(f"device:{r['id']}", None) or {}
        devices_.append({
            "device_id": r["id"], "name": r["name"], "owner": r["owner"],
            "kind": r["kind"] or r["platform"],
            "allowed": bool(r["can_ingest"]), "asked_at": r["ingest_asked_at"],
            "live": bool(w.get("live")), "busy": w.get("leased") or 0,
            "last_seen": w.get("last_seen"),
        })
    # Whatever is left signs in with the server's own secret: the house's downloader.
    house = [{"name": n, "live": bool(w["live"]), "busy": w["leased"] or 0,
              "last_seen": w["last_seen"]}
             for n, w in sorted(known.items()) if not n.startswith("device:")]
    return {"devices": devices_, "house": house}


@router.post("/{device_id}/ingest")
def allow_ingest(device_id: int, body: dict = Body(...),
                 user: dict = Depends(current_user)):
    """An admin saying yes, or no, to somebody's computer."""
    from .routes_accounts import _admin

    _admin(user)
    if not db.one("select 1 from devices where id=%s", (device_id,)):
        raise HTTPException(404, "no such device")
    allowed = bool(body.get("allowed"))
    db.run("update devices set pool_blocked=%s where id=%s", (not allowed, device_id))
    if not allowed:
        db.run("""update jobs set state='pending', leased_by=null, leased_until=null
                   where state='leased' and leased_by=%s""", (f"device:{device_id}",))
    return {"device_id": device_id, "allowed": allowed}


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


@router.delete("/{device_id}")
def forget(device_id: int, user: dict = Depends(current_user)):
    """Forget one of your devices: gone from the list, and signed out.

    Its token goes with the row, so a browser on a machine you no longer have is no
    longer a way in. Not the device asking — that is what signing out is for.
    """
    if device_id == user["device_id"]:
        raise HTTPException(400, "sign out instead of forgetting the device you are on")
    if not db.one("select id from devices where id=%s and user_id=%s",
                  (device_id, user["id"])):
        raise HTTPException(404, "no device of yours by that id")
    db.run("delete from devices where id=%s", (device_id,))
    from .app import publish

    publish("devices", {"device_id": device_id, "forgotten": True}, to_user=user["id"])
    return {"forgotten": device_id}


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
