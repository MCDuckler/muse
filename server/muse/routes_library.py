"""Playlists, queues and radio.

A queue is a first-class object, not "the" queue: several named queues per user, each
with its own items, cursor, shuffle and repeat, so switching between them resumes where
each one was. Order is versioned with `rev` and conflicts are refused; the cursor is not,
because the device that is playing is the authority on where playback is.
"""
from __future__ import annotations

from fastapi import APIRouter, Body, Depends, HTTPException
from fastapi.encoders import jsonable_encoder

from . import catalog, db, match, ytm
from .deps import current_user

router = APIRouter()

RADIO_MAX = 10          # never pull a whole 50-track watch playlist: each one is a download
RADIO_DEFAULT = 5


# ------------------------------------------------------------------ playlists
@router.get("/playlists")
def list_playlists(user: dict = Depends(current_user)):
    return db.all_(
        """select p.*, count(i.track_id) as items
             from playlists p left join playlist_items i on i.playlist_id=p.id
            where p.owner_id=%s group by p.id order by p.name""",
        (user["id"],),
    )


@router.post("/playlists", status_code=201)
def create_playlist(body: dict = Body(...), user: dict = Depends(current_user)):
    name = (body.get("name") or "").strip()
    if not name:
        raise HTTPException(400, "name required")
    row = db.one(
        "insert into playlists(owner_id,name,kind) values(%s,%s,%s) returning *",
        (user["id"], name, body.get("kind", "local")),
    )
    return row


def _own_playlist(playlist_id: int, user: dict) -> dict:
    row = db.one("select * from playlists where id=%s and owner_id=%s", (playlist_id, user["id"]))
    if not row:
        raise HTTPException(404, "no such playlist")
    return row


@router.get("/playlists/{playlist_id}")
def get_playlist(playlist_id: int, user: dict = Depends(current_user)):
    p = _own_playlist(playlist_id, user)
    items = db.all_(
        """select i.pos, t.*, m.path, m.bytes, m.sha256
             from playlist_items i
             join tracks t on t.id=i.track_id
             left join media m on m.track_id=t.id and m.role='canonical'
            where i.playlist_id=%s order by i.pos""",
        (playlist_id,),
    )
    return {**p, "items": [catalog.public(t) for t in items]}


@router.post("/playlists/{playlist_id}/items")
def add_items(playlist_id: int, body: dict = Body(...), user: dict = Depends(current_user)):
    _own_playlist(playlist_id, user)
    ids = body.get("track_ids") or []
    if not ids:
        raise HTTPException(400, "track_ids required")
    start = (db.one("select coalesce(max(pos),-1) p from playlist_items where playlist_id=%s",
                    (playlist_id,))["p"]) + 1
    with db.pool().connection() as c:
        for n, tid in enumerate(ids):
            c.execute(
                """insert into playlist_items(playlist_id,pos,track_id) values(%s,%s,%s)
                   on conflict do nothing""",
                (playlist_id, start + n, tid),
            )
    return get_playlist(playlist_id, user)


@router.delete("/playlists/{playlist_id}")
def delete_playlist(playlist_id: int, user: dict = Depends(current_user)):
    _own_playlist(playlist_id, user)
    db.run("delete from playlists where id=%s", (playlist_id,))
    return {"deleted": playlist_id}


# ------------------------------------------------------------------ queues
def _queue_state(queue_id: int) -> dict:
    q = db.one("select * from queues where id=%s", (queue_id,))
    # The media join is not optional: without it every row comes back with no
    # stream_url, the client reads that as "not ready yet", and nothing in the queue
    # is playable no matter how ready the track actually is.
    items = db.all_(
        """select i.pos, i.origin, t.*, m.path, m.bytes, m.sha256
             from queue_items i
             join tracks t on t.id=i.track_id
             left join media m on m.track_id=t.id and m.role='canonical'
            where i.queue_id=%s order by i.pos""",
        (queue_id,),
    )
    return {**q, "items": [{**catalog.public(t), "origin": t["origin"], "pos": t["pos"]}
                           for t in items]}


def _own_queue(queue_id: int, user: dict) -> dict:
    row = db.one("select * from queues where id=%s and user_id=%s", (queue_id, user["id"]))
    if not row:
        raise HTTPException(404, "no such queue")
    return row


@router.get("/queues")
def list_queues(user: dict = Depends(current_user)):
    return db.all_(
        """select q.*, count(i.track_id) as items
             from queues q left join queue_items i on i.queue_id=q.id
            where q.user_id=%s group by q.id order by q.updated_at desc""",
        (user["id"],),
    )


@router.post("/queues", status_code=201)
def create_queue(body: dict = Body(...), user: dict = Depends(current_user)):
    name = (body.get("name") or "").strip()
    if not name:
        raise HTTPException(400, "name required")
    existing = db.one("select id from queues where user_id=%s and name=%s", (user["id"], name))
    if existing:
        raise HTTPException(409, f"a queue named {name!r} already exists")
    q = db.one("insert into queues(user_id,name) values(%s,%s) returning *", (user["id"], name))
    return _queue_state(q["id"])


@router.get("/queues/{queue_id}")
def get_queue(queue_id: int, user: dict = Depends(current_user)):
    _own_queue(queue_id, user)
    return _queue_state(queue_id)


@router.put("/queues/{queue_id}")
def replace_queue(queue_id: int, body: dict = Body(...), user: dict = Depends(current_user)):
    """Full order replace. `rev` must match or the caller gets 409 plus the live state."""
    q = _own_queue(queue_id, user)
    rev = body.get("rev")
    if rev is not None and int(rev) != q["rev"]:
        # Hand the loser the live state so it can merge, instead of guessing what changed.
        # jsonable_encoder because the error path does not get FastAPI's response encoding.
        raise HTTPException(409, jsonable_encoder(
            {"reason": "stale rev", "current": _queue_state(queue_id)}))

    items = body.get("items") or []
    with db.pool().connection() as c:
        c.execute("delete from queue_items where queue_id=%s", (queue_id,))
        for pos, it in enumerate(items):
            tid = it["track_id"] if isinstance(it, dict) else it
            origin = it.get("origin", "user") if isinstance(it, dict) else "user"
            c.execute("insert into queue_items(queue_id,pos,track_id,origin) values(%s,%s,%s,%s)",
                      (queue_id, pos, tid, origin))
        c.execute(
            """update queues set rev=rev+1, updated_at=now(),
                      name=coalesce(%s,name), shuffle=coalesce(%s,shuffle),
                      repeat=coalesce(%s,repeat),
                      cursor_index=least(coalesce(%s,cursor_index), greatest(%s-1,0))
                where id=%s""",
            (body.get("name"), body.get("shuffle"), body.get("repeat"),
             body.get("cursor_index"), len(items), queue_id),
        )
    return _queue_state(queue_id)


@router.patch("/queues/{queue_id}/cursor")
def move_cursor(queue_id: int, body: dict = Body(...), user: dict = Depends(current_user)):
    """Cheap and frequent, so it does not bump `rev`: on a conflict the playing device wins."""
    _own_queue(queue_id, user)
    db.run(
        """update queues set cursor_index=coalesce(%s,cursor_index),
                  position_ms=coalesce(%s,position_ms), updated_at=now()
            where id=%s""",
        (body.get("cursor_index"), body.get("position_ms"), queue_id),
    )
    q = db.one("select id,name,cursor_index,position_ms,rev from queues where id=%s", (queue_id,))
    return q


@router.post("/queues/{queue_id}/items")
def queue_add(queue_id: int, body: dict = Body(...), user: dict = Depends(current_user)):
    """`next` inserts above the autoplay/radio tail, not blindly at the top."""
    _own_queue(queue_id, user)
    ids = body.get("track_ids") or []
    if not ids:
        raise HTTPException(400, "track_ids required")
    mode = body.get("mode", "end")           # end | next
    rows = db.all_("select pos, origin from queue_items where queue_id=%s order by pos",
                   (queue_id,))
    cursor = db.one("select cursor_index from queues where id=%s", (queue_id,))["cursor_index"]

    if mode == "next":
        after = cursor
        for r in rows:
            if r["pos"] > cursor and r["origin"] == "user":
                after = r["pos"]
            elif r["pos"] > cursor:
                break
        insert_at = after + 1
    else:
        insert_at = (rows[-1]["pos"] + 1) if rows else 0

    with db.pool().connection() as c:
        c.execute("""update queue_items set pos = pos + %s
                      where queue_id=%s and pos >= %s""",
                  (len(ids), queue_id, insert_at))
        for n, tid in enumerate(ids):
            c.execute("insert into queue_items(queue_id,pos,track_id,origin) values(%s,%s,%s,%s)",
                      (queue_id, insert_at + n, tid, body.get("origin", "user")))
        c.execute("update queues set rev=rev+1, updated_at=now() where id=%s", (queue_id,))
    return _queue_state(queue_id)


@router.delete("/queues/{queue_id}")
def delete_queue(queue_id: int, user: dict = Depends(current_user)):
    _own_queue(queue_id, user)
    db.run("delete from queues where id=%s", (queue_id,))
    return {"deleted": queue_id}


@router.post("/queues/{queue_id}/save-as-playlist", status_code=201)
def save_as_playlist(queue_id: int, body: dict = Body(...), user: dict = Depends(current_user)):
    q = _own_queue(queue_id, user)
    name = (body.get("name") or q["name"]).strip()
    p = db.one("insert into playlists(owner_id,name) values(%s,%s) returning *",
               (user["id"], name))
    with db.pool().connection() as c:
        c.execute(
            """insert into playlist_items(playlist_id,pos,track_id)
               select %s, pos, track_id from queue_items where queue_id=%s""",
            (p["id"], queue_id),
        )
    return get_playlist(p["id"], user)


# ------------------------------------------------------------------ radio
@router.post("/queues/{queue_id}/radio")
def radio(queue_id: int, body: dict = Body(...), user: dict = Depends(current_user)):
    """Append a capped autoplay tail seeded from a track.

    YouTube Music hands back ~50 candidates; every one we accept is a download and disk
    forever, so the cap is deliberate and the tail is refilled on demand instead.
    """
    _own_queue(queue_id, user)
    seed_id = body.get("seed_track_id")
    count = max(1, min(int(body.get("count", RADIO_DEFAULT)), RADIO_MAX))
    seed = catalog.track_row(seed_id) if seed_id else None
    if not seed or not seed.get("provider_id"):
        raise HTTPException(400, "seed_track_id must be a track with a YouTube Music source")

    have_ids = {r["track_id"] for r in
                db.all_("select track_id from queue_items where queue_id=%s", (queue_id,))}
    have_videos = {r["provider_id"] for r in db.all_(
        """select s.provider_id from queue_items i
             join track_sources s on s.track_id=i.track_id
            where i.queue_id=%s""", (queue_id,))}

    added, skipped = [], 0
    for cand in ytm.watch_playlist(seed["provider_id"], limit=RADIO_MAX * 4):
        if len(added) >= count:
            break
        if not cand["video_id"] or cand["video_id"] in have_videos:
            skipped += 1
            continue
        known = catalog.find_by_video_id(cand["video_id"])
        if known and known["id"] in have_ids:
            skipped += 1
            continue
        # Radio candidates come from a seed, so a near-duplicate of the seed is not radio.
        conf, _ = match.score({"title": seed["title"], "artists": seed["artists"],
                               "duration_ms": seed["duration_ms"]}, cand)
        if conf >= match.AUTO_ACCEPT:
            skipped += 1
            continue
        track = known or catalog.create_from_ytm(cand, discovered_via=catalog.VIA_RADIO)
        added.append(track["id"])
        have_videos.add(cand["video_id"])

    if added:
        queue_add(queue_id, {"track_ids": added, "mode": "end", "origin": "radio"}, user)
    return {**_queue_state(queue_id), "radio_added": len(added), "radio_skipped": skipped}
