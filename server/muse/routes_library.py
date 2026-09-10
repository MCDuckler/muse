"""Playlists, queues and radio.

A queue is a first-class object, not "the" queue: several named queues per user, each
with its own items, cursor and repeat, so switching between them resumes where each one
was. Shuffle is not among them: it is something you do to a queue, once, rather than a
mode the queue is in. Order is versioned with `rev` and conflicts are refused; the cursor is not,
because the device that is playing is the authority on where playback is.
"""
from __future__ import annotations

import random

from fastapi import APIRouter, Body, Depends, HTTPException, Request
from fastapi.encoders import jsonable_encoder
from fastapi.responses import FileResponse

from . import catalog, db, jam, jobs, match, playlist_art, ytm
from .deps import cfg, current_user, user_or_key

router = APIRouter()

_publish = None                    # set by app.create_app, to avoid importing it here


def set_publisher(fn) -> None:
    global _publish
    _publish = fn


def announce_queue(queue_id: int, user: dict, cursor_moved: bool = False) -> None:
    """Tell every device this queue changed.

    Without this a jam was one-way: a guest's song landed in the host's queue on the
    server and the host's player never heard about it. It matters outside a jam too —
    the same person adding something from a laptop while a phone is playing.
    """
    if not _publish:
        return
    row = db.one("select rev, cursor_index, position_ms from queues where id=%s",
                 (queue_id,))
    if not row:
        return
    # position_ms too: in a jam the host's device is the one making sound, and without
    # it a guest's seek bar is drawing their own silent player.
    _publish("queue_changed", {"queue_id": queue_id, "rev": row["rev"],
                               "cursor_index": row["cursor_index"],
                               "position_ms": row["position_ms"],
                               "by": user.get("name"), "cursor_moved": cursor_moved})

RADIO_MAX = 10          # never pull a whole 50-track watch playlist: each one is a download
RADIO_DEFAULT = 5


# ------------------------------------------------------------------ playlists
def with_cover(playlist: dict) -> dict:
    """Every playlist has a cover, whether or not anyone gave it one.

    The version is a hash of the art it is made from, so the client can cache the image
    forever and still see it change the moment the playlist does.
    """
    sig = playlist_art.signature(playlist["id"], playlist["name"])
    return {**playlist,
            "cover_url": f"/playlists/{playlist['id']}/cover",
            "cover_version": sig}


@router.get("/playlists")
def list_playlists(user: dict = Depends(current_user)):
    # Favourites is not a playlist somebody made, so it is not one somebody has to
    # make: it exists from the first time you look, empty, rather than appearing out
    # of nowhere the first time a heart is pressed.
    favourites_id(user["id"])
    rows = db.all_(
        """select p.*, count(distinct i.track_id) as items,
                  count(distinct u.pos) as unmatched
             from playlists p
             left join playlist_items i on i.playlist_id=p.id
             left join playlist_unmatched u on u.playlist_id=p.id
            where p.owner_id=%s
            group by p.id
            -- Favourites first, then the ones made here, then the mirrors.
            order by (p.kind <> %s), (p.kind <> 'local'), lower(p.name)""",
        (user["id"], FAVOURITES_KIND),
    )
    return [with_cover(r) for r in rows]


@router.post("/playlists/{playlist_id}/download")
def download_playlist(playlist_id: int, user: dict = Depends(current_user)):
    """Fetch the audio for everything in a playlist that has none yet.

    A big mirror records the list and leaves the files until something is played. This
    is the other answer: take all of it, at import priority so it fills in behind
    whatever you are listening to now.
    """
    p = _own_playlist(playlist_id, user)
    waiting = db.all_(
        """select distinct on (t.id) t.id, s.provider, s.provider_id,
                  s.raw->>'url' as url
             from playlist_items i
             join tracks t on t.id = i.track_id
             join track_sources s on s.track_id = t.id
            where i.playlist_id=%s and t.state='pending'
              and not exists (select 1 from jobs j
                               where j.kind in ('ingest','ingest_direct')
                                 and (j.payload->>'track_id')::int = t.id
                                 and j.state in ('pending','leased','done'))
            order by t.id, (s.provider = 'ytmusic') desc""",
        (playlist_id,),
    )
    for row in waiting:
        # Same rule as pressing play: the lane depends on where the song lives.
        if row["provider"] in ("soundcloud", "bandcamp"):
            jobs.enqueue("ingest_direct",
                         {"track_id": row["id"], "provider": row["provider"],
                          "ref": row["url"] or row["provider_id"]},
                         priority=jobs.PRIORITY_BULK,
                         batch_id=f"playlist:{playlist_id}", batch_label=p["name"])
        else:
            jobs.enqueue("ingest", {"track_id": row["id"],
                                    "video_id": row["provider_id"]},
                         priority=jobs.PRIORITY_BULK,
                         batch_id=f"playlist:{playlist_id}", batch_label=p["name"])
    db.run("update playlists set download_mode='all' where id=%s", (playlist_id,))
    return {"queued": len(waiting)}


@router.get("/playlists/{playlist_id}/cover")
def playlist_cover(playlist_id: int, request: Request, size: str = "lg",
                   v: str | None = None, user: dict = Depends(user_or_key)):
    """Art built from the records in the playlist. See playlist_art for what it looks
    like and why it is not a 2×2 grid."""
    p = db.one("select * from playlists where id=%s and owner_id=%s",
               (playlist_id, user["id"]))
    if not p:
        raise HTTPException(404, "no such playlist")
    sig = playlist_art.signature(playlist_id, p["name"])
    playlist_art.build(cfg().cover_dir, playlist_id, p["name"], sig)
    path = playlist_art.path_for(cfg().cover_dir, playlist_id, sig,
                                 "sm" if size == "sm" else "lg")
    return FileResponse(
        path, media_type="image/jpeg",
        headers={"ETag": f'"{sig}-{size}"',
                 # Immutable is safe because the signature is in the URL the client
                 # asks for; a changed playlist is a changed URL.
                 "Cache-Control": "private, max-age=31536000, immutable"},
    )


# A backup from another player is one file: a list of playlists naming track ids, and
# a list of what those ids are. Almost everything in one is already here — the ids are
# Bandcamp's own, and so are ours — so an import is mostly a lookup.
BIG_IMPORT = 400


@router.post("/playlists/import", status_code=201)
def import_playlists(body: dict = Body(...), user: dict = Depends(current_user)):
    """Playlists from a backup file exported by another player.

    Only bcplayer's format for now, which is the one that was asked for: a JSON file
    with the playlists and a catalogue of the tracks they name. The ids in it are
    Bandcamp's, which is what makes this cheap — a track already in the library is
    found rather than fetched, and only what is genuinely new is queued.
    """
    fmt = (body.get("format") or "bcplayer").strip().lower()
    if fmt != "bcplayer":
        raise HTTPException(400, f"{fmt} backups are not something I can read yet.")

    data = body.get("data") if isinstance(body.get("data"), dict) else body
    lists = data.get("playlists")
    if not isinstance(lists, list) or not lists:
        raise HTTPException(400, "That file has no playlists in it.")

    known: dict[str, dict] = {}
    for entry in data.get("tracks") or []:
        if not isinstance(entry, dict):
            continue
        key = str(entry.get("id") or f"t{entry.get('trackId')}")
        known[key] = entry
        known[str(entry.get("trackId"))] = entry

    # Past a few hundred new songs an import is a library rather than a list: record
    # what is in it and fetch the audio when somebody plays it, as a big mirror does.
    fresh = sum(1 for l in lists for t in (l.get("tracks") or [])
                if not catalog.find_by_provider("bandcamp", _bc_id(t, known)))
    download = fresh <= BIG_IMPORT

    made = []
    for entry in lists:
        name = (entry.get("name") or "").strip() or "Untitled"
        ids = [t for t in (entry.get("tracks") or []) if t]
        made.append(_import_one(user["id"], name, ids, known, download))
    return {"format": fmt, "playlists": made,
            "tracks": sum(m["added"] for m in made),
            "missing": sum(m["missing"] for m in made),
            "audio": "queued" if download else "on play"}


def _bc_id(key, known: dict) -> str:
    """The Bandcamp track id, whichever way the file spells it."""
    entry = known.get(str(key)) or {}
    return str(entry.get("trackId") or str(key).lstrip("t"))


def _import_one(user_id: int, name: str, ids: list, known: dict,
                download: bool) -> dict:
    """One playlist from the file, replacing the last import of the same name."""
    row = db.one(
        """select id from playlists
            where owner_id=%s and lower(name)=lower(%s) and kind in ('local','import')
            order by id limit 1""",
        (user_id, name),
    )
    if row:
        playlist_id = row["id"]
        db.run("delete from playlist_items where playlist_id=%s", (playlist_id,))
        db.run("delete from playlist_unmatched where playlist_id=%s", (playlist_id,))
    else:
        playlist_id = db.one(
            "insert into playlists(owner_id,name,kind) values(%s,%s,'local') returning id",
            (user_id, name),
        )["id"]

    added = missing = 0
    for key in ids:
        provider_id = _bc_id(key, known)
        track = catalog.find_by_provider("bandcamp", provider_id)
        if not track:
            entry = known.get(str(key)) or known.get(provider_id)
            if not entry or not entry.get("pageUrl"):
                # Named in a playlist and described nowhere: nothing to look up and
                # nothing to fetch, so say so rather than dropping it silently.
                db.run("""insert into playlist_unmatched(playlist_id,pos,remote_id,
                                                        title,artists,reason)
                          values(%s,%s,%s,%s,%s,'not in the backup file')
                          on conflict do nothing""",
                       (playlist_id, added + missing, str(key), None, []))
                missing += 1
                continue
            track = catalog.create_from_source("bandcamp", {
                "provider_id": provider_id,
                "title": (entry.get("title") or "").strip() or provider_id,
                "artists": [a for a in [entry.get("artist")] if a],
                "album": entry.get("album"),
                "duration_ms": entry.get("durationMs"),
                # The page holds the whole record, so the reference names the track on
                # it — see _bandcamp_fetch.
                "url": f"{entry['pageUrl']}#{provider_id}",
                "raw": entry,
            }, discovered_via=catalog.VIA_USER, priority=jobs.PRIORITY_BULK,
                batch_id=f"bcplayer:{user_id}", batch_label="Imported playlists",
                download=download)
        db.run("""insert into playlist_items(playlist_id,pos,track_id)
                  values(%s,%s,%s) on conflict do nothing""",
               (playlist_id, added, track["id"]))
        catalog.remember(user_id, track["id"])
        added += 1

    return {"id": playlist_id, "name": name, "added": added, "missing": missing}


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


def _editable(playlist_id: int, user: dict) -> dict:
    """A mirrored playlist is a view of someone else's list.

    Letting it be edited would either lie (the change vanishes on the next sync) or
    corrupt the mirror. Cloning is the honest answer, and the message says so.
    """
    row = _own_playlist(playlist_id, user)
    if row["kind"] != "local":
        raise HTTPException(
            409,
            f"This playlist mirrors {row['kind']} and cannot be edited here. "
            f"Make a copy of it first.",
        )
    return row


@router.get("/playlists/{playlist_id}")
def get_playlist(playlist_id: int, user: dict = Depends(current_user)):
    p = _own_playlist(playlist_id, user)
    items = db.all_(
        """select i.pos, t.*, m.path, m.bytes, m.sha256, c.color as cover_color,
                    c.sha256 as cover_sha
             from playlist_items i
             join tracks t on t.id=i.track_id
             left join media m on m.track_id=t.id and m.role='canonical'
             left join covers c on c.id=t.cover_id
            where i.playlist_id=%s order by i.pos""",
        (playlist_id,),
    )
    # Position travels with the row: removing or reordering is by position, and the
    # client should not have to assume the list index matches.
    unmatched = db.one(
        "select count(*) n from playlist_unmatched where playlist_id=%s", (playlist_id,)
    )["n"]
    return {**with_cover(p), "unmatched": unmatched, "editable": p["kind"] == "local",
            "download_mode": p.get("download_mode", "all"),
            "items": [{**catalog.public(t), "pos": t["pos"]} for t in items]}


@router.post("/playlists/{playlist_id}/items")
def add_items(playlist_id: int, body: dict = Body(...), user: dict = Depends(current_user)):
    _editable(playlist_id, user)
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


@router.patch("/playlists/{playlist_id}")
def rename_playlist(playlist_id: int, body: dict = Body(...),
                    user: dict = Depends(current_user)):
    _editable(playlist_id, user)
    name = (body.get("name") or "").strip()
    if not name:
        raise HTTPException(400, "name required")
    db.run("update playlists set name=%s where id=%s", (name, playlist_id))
    return get_playlist(playlist_id, user)


@router.post("/playlists/{playlist_id}/move")
def move_playlist_item(playlist_id: int, body: dict = Body(...),
                       user: dict = Depends(current_user)):
    _editable(playlist_id, user)
    src, dst = body.get("from"), body.get("to")
    if src is None or dst is None:
        raise HTTPException(400, "from and to are required")
    rows = db.all_("select pos, track_id from playlist_items where playlist_id=%s "
                   "order by pos", (playlist_id,))
    if not (0 <= src < len(rows)) or not (0 <= dst < len(rows)):
        raise HTTPException(400, "position out of range")
    item = rows.pop(src)
    rows.insert(dst, item)
    with db.pool().connection() as c:
        c.execute("delete from playlist_items where playlist_id=%s", (playlist_id,))
        for i, r in enumerate(rows):
            c.execute("insert into playlist_items(playlist_id,pos,track_id) "
                      "values(%s,%s,%s)", (playlist_id, i, r["track_id"]))
    return get_playlist(playlist_id, user)


@router.delete("/playlists/{playlist_id}")
def delete_playlist(playlist_id: int, user: dict = Depends(current_user)):
    row = _own_playlist(playlist_id, user)
    if row["kind"] == FAVOURITES_KIND:
        # It is not a playlist somebody made, it is where the heart button puts things.
        # Deleting it would take the hearts with it and then quietly come back empty.
        raise HTTPException(400, "Favourites cannot be deleted. Unheart songs instead.")
    db.run("delete from playlists where id=%s", (playlist_id,))
    return {"deleted": playlist_id}


# ------------------------------------------------------------------ favourites
FAVOURITES_KIND = "favourites"


def favourites_id(user_id: int) -> int:
    """The one playlist nobody has to make and nobody can delete."""
    row = db.one("select id from playlists where owner_id=%s and kind=%s",
                 (user_id, FAVOURITES_KIND))
    if row:
        return row["id"]
    return db.one(
        """insert into playlists(owner_id, name, kind, sync_mode)
           values(%s,'Favourites',%s,'off') returning id""",
        (user_id, FAVOURITES_KIND),
    )["id"]


@router.get("/favourites")
def favourites(user: dict = Depends(current_user)):
    """The ids, so a screen full of hearts is one request rather than one per song."""
    playlist_id = favourites_id(user["id"])
    rows = db.all_("select track_id from playlist_items where playlist_id=%s",
                   (playlist_id,))
    return {"playlist_id": playlist_id, "track_ids": [r["track_id"] for r in rows]}


@router.post("/favourites/{track_id}")
def set_favourite(track_id: int, body: dict = Body(default={}),
                  user: dict = Depends(current_user)):
    """Heart or unheart. Without a body it toggles, which is what a tap means."""
    playlist_id = favourites_id(user["id"])
    have = db.one("select pos from playlist_items where playlist_id=%s and track_id=%s",
                  (playlist_id, track_id))
    wanted = body.get("favourite")
    if wanted is None:
        wanted = have is None

    if wanted and have is None:
        at = (db.one("select coalesce(max(pos),-1) p from playlist_items where playlist_id=%s",
                     (playlist_id,))["p"]) + 1
        db.run("""insert into playlist_items(playlist_id,pos,track_id) values(%s,%s,%s)
                  on conflict do nothing""", (playlist_id, at, track_id))
    elif not wanted and have is not None:
        db.run("delete from playlist_items where playlist_id=%s and track_id=%s",
               (playlist_id, track_id))
    return {"track_id": track_id, "favourite": bool(wanted), "playlist_id": playlist_id}


# ------------------------------------------------------------------ queues
def _queue_state(queue_id: int) -> dict:
    q = db.one("select * from queues where id=%s", (queue_id,))
    # The media join is not optional: without it every row comes back with no
    # stream_url, the client reads that as "not ready yet", and nothing in the queue
    # is playable no matter how ready the track actually is.
    items = db.all_(
        """select i.pos, i.origin, u.name as added_by, t.*, m.path, m.bytes, m.sha256,
                  c.color as cover_color, c.sha256 as cover_sha
             from queue_items i
             join tracks t on t.id=i.track_id
             left join users u on u.id = i.added_by
             left join media m on m.track_id=t.id and m.role='canonical'
             left join covers c on c.id=t.cover_id
            where i.queue_id=%s order by i.pos""",
        (queue_id,),
    )
    return {**q, "items": [{**catalog.public(t), "origin": t["origin"], "pos": t["pos"],
                            # Only interesting in a jam, and harmless otherwise: it is
                            # how "who put this on" gets answered without asking.
                            "added_by": t["added_by"]}
                           for t in items]}


def _own_queue(queue_id: int, user: dict, *, adding: bool = False) -> dict:
    """Your own queue — or one you have been let into.

    A jam is exactly this: the host's queue, opened to the people who joined. Everyone
    in the room reads it and adds to it — a shared queue nobody but the host may touch
    is just somebody else's playlist with an audience.
    """
    row = db.one("select * from queues where id=%s and user_id=%s", (queue_id, user["id"]))
    if row:
        return row

    if jam.may_touch_queue(queue_id, user["id"]):
        return db.one("select * from queues where id=%s", (queue_id,))
    raise HTTPException(404, "no such queue")


@router.get("/queues")
def list_queues(user: dict = Depends(current_user)):
    """Your queues, and the one you are listening to with somebody else.

    A jam's queue belongs to the host, so a guest's list did not contain the thing they
    were actually listening to — and the moment anything reopened a queue for them,
    they were quietly back on their own with the app still saying they were in a jam.
    It is in the list now, named for whose it is.
    """
    return db.all_(
        """select q.*, count(i.track_id) as items, null::text as shared_from
             from queues q left join queue_items i on i.queue_id=q.id
            where q.user_id=%s group by q.id
            union all
           select q.*, count(i.track_id) as items, h.name as shared_from
             from jams j
             join jam_members m on m.jam_id = j.id and m.user_id = %s
             join queues q on q.id = j.queue_id
             join users h on h.id = j.host_id
             left join queue_items i on i.queue_id = q.id
            where j.ended_at is null and q.user_id <> %s
            group by q.id, h.name
            order by updated_at desc""",
        (user["id"], user["id"], user["id"]),
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


@router.patch("/queues/{queue_id}")
def update_queue_settings(queue_id: int, body: dict = Body(...),
                          user: dict = Depends(current_user)):
    """Name, shuffle and repeat — deliberately separate from the item list.

    These used to share the PUT, which reads items from `body.get("items") or []`, so a
    client sending only `{"shuffle": true}` emptied the queue. Settings and order are
    different operations with different risks and now have different endpoints.
    """
    _own_queue(queue_id, user)
    if "repeat" in body and body["repeat"] not in ("off", "one", "all"):
        raise HTTPException(400, "repeat must be off, one or all")
    db.run(
        """update queues set name=coalesce(%s,name), shuffle=coalesce(%s,shuffle),
                  repeat=coalesce(%s,repeat), updated_at=now()
            where id=%s""",
        (body.get("name"), body.get("shuffle"), body.get("repeat"), queue_id),
    )
    return _queue_state(queue_id)


@router.put("/queues/{queue_id}")
def replace_queue(queue_id: int, body: dict = Body(...), user: dict = Depends(current_user)):
    """Full order replace. `rev` must match or the caller gets 409 plus the live state."""
    q = _own_queue(queue_id, user)
    if "items" not in body:
        # Never infer "empty" from "unspecified": that is how a settings update used to
        # erase a queue. Callers that mean to empty it send an explicit [].
        raise HTTPException(400, "items is required — use PATCH for name/shuffle/repeat")
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
    announce_queue(queue_id, user)
    return _queue_state(queue_id)


@router.patch("/queues/{queue_id}/cursor")
def move_cursor(queue_id: int, body: dict = Body(...), user: dict = Depends(current_user)):
    """Cheap and frequent, so it does not bump `rev`: on a conflict the playing device wins."""
    _own_queue(queue_id, user)
    was = db.one("select cursor_index from queues where id=%s", (queue_id,))["cursor_index"]
    db.run(
        """update queues set cursor_index=coalesce(%s,cursor_index),
                  position_ms=coalesce(%s,position_ms), updated_at=now()
            where id=%s""",
        (body.get("cursor_index"), body.get("position_ms"), queue_id),
    )
    q = db.one("select id,name,cursor_index,position_ms,rev from queues where id=%s", (queue_id,))
    # Position is saved every ten seconds; only a change of track is news.
    if body.get("cursor_index") is not None and body["cursor_index"] != was:
        announce_queue(queue_id, user, cursor_moved=True)
    return q


def _shift_positions(c, queue_id: int, from_pos: int, delta: int) -> None:
    """Move every row at or after `from_pos` along by `delta`.

    (queue_id, pos) is a primary key and Postgres checks it row by row, so the obvious
    `set pos = pos + 1` collides with the row still sitting in the slot the first one is
    moving into. That is why "play next" answered 500 rather than putting a song next:
    it only ever shifted anything when there was something to shift past. Parking the
    whole block far above the queue first gives every row an empty slot to land in on
    the way back.
    """
    if delta == 0:
        return
    park = 1_000_000
    c.execute("update queue_items set pos = pos + %s where queue_id=%s and pos >= %s",
              (park, queue_id, from_pos))
    c.execute("update queue_items set pos = pos - %s where queue_id=%s and pos >= %s",
              (park - delta, queue_id, park))


@router.post("/queues/{queue_id}/items")
def queue_add(queue_id: int, body: dict = Body(...), user: dict = Depends(current_user)):
    """`next` inserts above the autoplay/radio tail, not blindly at the top."""
    _own_queue(queue_id, user, adding=True)
    ids = body.get("track_ids") or []
    if not ids:
        raise HTTPException(400, "track_ids required")
    mode = body.get("mode", "end")           # end | next
    rows = db.all_("select pos, origin from queue_items where queue_id=%s order by pos",
                   (queue_id,))
    cursor = db.one("select cursor_index from queues where id=%s", (queue_id,))["cursor_index"]

    if mode == "next":
        # Straight after the song playing, and after anything else already queued up
        # this way — so three "play next" in a row play in the order they were pressed.
        #
        # It used to walk past every user-added row after the cursor, which in a queue
        # somebody had built by hand is all of them: "play next" put the song at the
        # very end, which is the one place it was not supposed to go.
        after = cursor
        for r in rows:
            if r["pos"] <= cursor:
                continue
            if r["origin"] == "next":
                after = r["pos"]
            else:
                break
        insert_at = after + 1
    else:
        insert_at = (rows[-1]["pos"] + 1) if rows else 0

    with db.pool().connection() as c:
        _shift_positions(c, queue_id, insert_at, len(ids))
        for n, tid in enumerate(ids):
            c.execute(
                """insert into queue_items(queue_id,pos,track_id,origin,added_by)
                   values(%s,%s,%s,%s,%s)""",
                (queue_id, insert_at + n, tid,
                 body.get("origin") or ("next" if mode == "next" else "user"),
                 user["id"]))
        c.execute("update queues set rev=rev+1, updated_at=now() where id=%s", (queue_id,))
    announce_queue(queue_id, user)
    return _queue_state(queue_id)


@router.delete("/queues/{queue_id}/items/{pos}")
def remove_item(queue_id: int, pos: int, user: dict = Depends(current_user)):
    """Remove one track.

    Re-sending the whole list to drop a single row races with anything else touching
    the queue, and it is why fixing a queue used to need a terminal.
    """
    _own_queue(queue_id, user)
    with db.pool().connection() as c:
        gone = c.execute(
            "delete from queue_items where queue_id=%s and pos=%s returning track_id",
            (queue_id, pos),
        ).fetchone()
        if not gone:
            raise HTTPException(404, "no item at that position")
        _shift_positions(c, queue_id, pos + 1, -1)
        # Keep the cursor pointing at the same *track*: removing something above the
        # current one must not skip playback forward.
        c.execute(
            """update queues
                  set cursor_index = case
                        when cursor_index > %s then cursor_index - 1
                        else cursor_index end,
                      rev = rev + 1, updated_at = now()
                where id=%s""",
            (pos, queue_id),
        )
    announce_queue(queue_id, user)
    return _queue_state(queue_id)


@router.post("/queues/{queue_id}/move")
def move_item(queue_id: int, body: dict = Body(...), user: dict = Depends(current_user)):
    """Reorder by dragging. Positions are rewritten in one statement per row so the
    list can never end up with a gap or a duplicate position."""
    _own_queue(queue_id, user)
    src, dst = body.get("from"), body.get("to")
    if src is None or dst is None:
        raise HTTPException(400, "from and to are required")

    rows = db.all_("select pos, track_id, origin, added_by from queue_items "
                   "where queue_id=%s order by pos", (queue_id,))
    if not (0 <= src < len(rows)) or not (0 <= dst < len(rows)):
        raise HTTPException(400, "position out of range")

    item = rows.pop(src)
    rows.insert(dst, item)
    cursor = db.one("select cursor_index from queues where id=%s",
                    (queue_id,))["cursor_index"]
    playing = None
    if 0 <= cursor < len(rows):
        # Follow the track that was playing rather than the index it happened to have.
        original = db.all_("select track_id from queue_items where queue_id=%s "
                           "order by pos", (queue_id,))
        if cursor < len(original):
            playing = original[cursor]["track_id"]

    with db.pool().connection() as c:
        c.execute("delete from queue_items where queue_id=%s", (queue_id,))
        for i, r in enumerate(rows):
            c.execute("insert into queue_items(queue_id,pos,track_id,origin,added_by) "
                      "values(%s,%s,%s,%s,%s)",
                      (queue_id, i, r["track_id"], r["origin"], r["added_by"]))
        new_cursor = next((i for i, r in enumerate(rows) if r["track_id"] == playing),
                          cursor)
        c.execute("update queues set rev=rev+1, cursor_index=%s, updated_at=now() "
                  "where id=%s", (new_cursor, queue_id))
    announce_queue(queue_id, user)
    return _queue_state(queue_id)


@router.post("/queues/{queue_id}/shuffle")
def shuffle_queue(queue_id: int, body: dict = Body(default={}),
                  user: dict = Depends(current_user)):
    """Shuffle what is coming, once.

    Not a mode. A shuffle you can switch on is a promise about every song after this
    one for as long as it is on, which means the queue on screen is not the order you
    will hear — and turning it off does not put anything back. This rearranges the
    rows themselves, after the one playing, and then it is over: what the list says is
    what happens.
    """
    _own_queue(queue_id, user)
    cursor = db.one("select cursor_index from queues where id=%s",
                    (queue_id,))["cursor_index"]
    rows = db.all_("select pos, track_id, origin, added_by from queue_items "
                   "where queue_id=%s order by pos", (queue_id,))
    keep = [r for r in rows if r["pos"] <= cursor]
    rest = [r for r in rows if r["pos"] > cursor]
    if len(rest) < 2:
        return _queue_state(queue_id)

    random.shuffle(rest)
    with db.pool().connection() as c:
        c.execute("delete from queue_items where queue_id=%s", (queue_id,))
        for i, r in enumerate(keep + rest):
            c.execute("""insert into queue_items(queue_id,pos,track_id,origin,added_by)
                         values(%s,%s,%s,%s,%s)""",
                      (queue_id, i, r["track_id"], r["origin"], r["added_by"]))
        c.execute("update queues set rev=rev+1, updated_at=now() where id=%s",
                  (queue_id,))
    announce_queue(queue_id, user)
    return _queue_state(queue_id)


@router.post("/queues/{queue_id}/clear")
def clear_queue(queue_id: int, body: dict = Body(default={}),
                user: dict = Depends(current_user)):
    """Clear everything, or just the machine-picked tail — the point of tagging radio
    tracks with an origin in the first place."""
    _own_queue(queue_id, user)
    origin = (body or {}).get("origin")
    with db.pool().connection() as c:
        if origin:
            c.execute("delete from queue_items where queue_id=%s and origin=%s",
                      (queue_id, origin))
        else:
            c.execute("delete from queue_items where queue_id=%s", (queue_id,))
        rows = c.execute("select pos from queue_items where queue_id=%s order by pos",
                         (queue_id,)).fetchall()
        for i, r in enumerate(rows):
            c.execute("update queue_items set pos=%s where queue_id=%s and pos=%s",
                      (i - len(rows), queue_id, r["pos"]))
        c.execute("update queue_items set pos = pos + %s where queue_id=%s and pos < 0",
                  (len(rows), queue_id))
        c.execute("""update queues set rev=rev+1, updated_at=now(),
                            cursor_index=least(cursor_index, greatest(%s-1, 0))
                      where id=%s""", (len(rows), queue_id))
    announce_queue(queue_id, user)
    return _queue_state(queue_id)


@router.delete("/playlists/{playlist_id}/items/{pos}")
def remove_playlist_item(playlist_id: int, pos: int,
                         user: dict = Depends(current_user)):
    _editable(playlist_id, user)
    with db.pool().connection() as c:
        gone = c.execute(
            "delete from playlist_items where playlist_id=%s and pos=%s returning track_id",
            (playlist_id, pos),
        ).fetchone()
        if not gone:
            raise HTTPException(404, "no item at that position")
        c.execute("update playlist_items set pos = pos - 1 where playlist_id=%s and pos > %s",
                  (playlist_id, pos))
    return get_playlist(playlist_id, user)


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
