"""The pool: every desktop app in the house, fetching songs and taking records apart
for everybody.

YouTube answers a house and refuses a datacentre, and a trained separator wants a
graphics card or a minute and a half of somebody's processor — neither of which this
box has to spare. The desktops have both. So every desktop app works for the pool
unless its owner switches that off or an admin blocks it, and what one computer makes
is kept here for all of them: the song itself (see app.complete) and its parts, here.

Two kinds of work go through the same queue (jobs.py):

  * `ingest` — fetch a song from YouTube. Whoever asked for it fetches it themselves
    when they are on a desktop (they claim the job, jobs.claim), so the song is on their
    own disk the moment it arrives; everybody else's go to whichever desktop is free.
  * `split` — take a record apart into drums, music, instrumental and vocals. A computer
    with a graphics card is given it first; any other waits SPLIT_FOR_THE_CARD_SECONDS
    before it may take one, unless it is its own.

A part a phone asks for that nobody has made yet queues a split and answers "not yet";
the phone asks again and gets the part the moment a desktop has handed it in.
"""
from __future__ import annotations

import json
import logging
import pathlib
import time

from . import catalog, db, jobs

log = logging.getLogger("muse.pool")

# The separator's version, as the desktops number it: 2 is SCNet Small.
PARTS_VERSION = 2

# The parts a record comes apart into.
PARTS = ("drums", "music", "instrumental", "vocals")

# Longer than this is a DJ set or an album in one file, not a record: the separator's
# own limit, the same as the desktops'.
UP_TO_S = 12 * 60

# A computer is in the pool while it is asking for work, which it does every few
# seconds; this long without is gone.
LIVE_SECONDS = 90


def parts_dir(data_dir: pathlib.Path) -> pathlib.Path:
    return data_dir / "parts"


def part_path(data_dir: pathlib.Path, sha: str, name: str,
              version: int = PARTS_VERSION) -> pathlib.Path:
    return parts_dir(data_dir) / sha[:2] / f"{sha}-{name}-v{version}.m4a"


def part_here(sha: str, name: str) -> pathlib.Path | None:
    """The part, where one has been handed in and is still on the disk."""
    row = db.one("select path from track_parts where sha256=%s and name=%s and version=%s",
                 (sha, name, PARTS_VERSION))
    if not row:
        return None
    p = pathlib.Path(row["path"])
    return p if p.exists() else None


def parts_of(sha: str) -> list[str]:
    return [r["name"] for r in db.all_(
        "select name from track_parts where sha256=%s and version=%s order by name",
        (sha, PARTS_VERSION))]


def keep_part(data_dir: pathlib.Path, sha: str, name: str, tmp: pathlib.Path,
              device_id: int | None, seconds: float | None) -> pathlib.Path:
    """Move a part handed in into place and remember who made it."""
    dest = part_path(data_dir, sha, name)
    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp.replace(dest)
    db.run(
        """insert into track_parts(sha256, name, version, path, bytes, device_id, seconds)
           values(%s,%s,%s,%s,%s,%s,%s)
           on conflict (sha256, name, version) do update
              set path=excluded.path, bytes=excluded.bytes, device_id=excluded.device_id,
                  seconds=excluded.seconds, created_at=now()""",
        (sha, name, PARTS_VERSION, str(dest), dest.stat().st_size, device_id, seconds))
    return dest


def want_split(track_id: int, *, asked_by: int | None = None,
               priority: int = jobs.PRIORITY_NOW) -> int | None:
    """Queue the record for taking apart, unless it already is, or is done. Answers the
    job, or None where there is nothing to queue: no audio yet, too long, or its parts
    are all here."""
    t = catalog.track_row(track_id)
    if not t or not t.get("path"):
        return None
    if (t.get("duration_ms") or 0) > UP_TO_S * 1000:
        return None
    if set(parts_of(t["sha256"])) >= set(PARTS):
        return None
    open_ = db.one(
        """select id, priority from jobs
            where kind='split' and (payload->>'track_id')::int=%s
              and state in ('pending','leased')
            order by id desc limit 1""", (track_id,))
    if open_:
        # Asked for again, sooner: it moves up, and never down.
        if priority < open_["priority"]:
            db.run("update jobs set priority=%s where id=%s", (priority, open_["id"]))
        return open_["id"]
    payload = {"track_id": track_id, "sha256": t["sha256"]}
    if asked_by is not None:
        payload["asked_by"] = asked_by
    return jobs.enqueue("split", payload, priority=priority)


# ------------------------------------------------------------------ crates
# How often the queue is topped up from the playlists marked to be taken apart.
_AUTO_EVERY = 30.0
_auto_at = 0.0


def auto_split(force: bool = False, limit: int = 50) -> int:
    """Queue every song in a playlist marked auto_split that is ready, is a record
    rather than a set, has no parts yet and no split queued, running or failed. Behind
    everything anybody is waiting for (PRIORITY_BULK). Asked when a list is marked,
    when songs are added to one, and every half a minute while the pool asks for work —
    which catches songs that arrive by any other way (a mirror, a sync, a download
    finishing). Answers how many were queued."""
    global _auto_at
    now = time.monotonic()
    if not force and now - _auto_at < _AUTO_EVERY:
        return 0
    _auto_at = now
    rows = db.all_(
        """select distinct t.id
             from playlists p
             join playlist_items i on i.playlist_id = p.id
             join tracks t on t.id = i.track_id
             join media m on m.track_id = t.id and m.role = 'canonical'
            where p.auto_split and t.state = 'ready'
              and coalesce(t.duration_ms, 0) <= %s
              and (select count(distinct name) from track_parts tp
                    where tp.sha256 = m.sha256 and tp.version = %s) < %s
              and not exists (select 1 from jobs j
                               where j.kind = 'split'
                                 and (j.payload->>'track_id')::int = t.id
                                 and j.state in ('pending','leased','failed'))
            limit %s""",
        (UP_TO_S * 1000, PARTS_VERSION, len(PARTS), limit))
    n = 0
    for r in rows:
        if want_split(r["id"], priority=jobs.PRIORITY_BULK) is not None:
            n += 1
    if n:
        log.info("queued %d song%s from auto-split playlists", n, "" if n == 1 else "s")
    return n


# ------------------------------------------------------------------ progress
# Live, in memory, like the downloads' (progress.py): what a split is doing right now.
_split_progress: dict[int, dict] = {}


def split_progress(track_id: int, stage: str, percent: float | None) -> dict:
    entry = {"stage": stage,
             "percent": None if percent is None else max(0.0, min(1.0, percent)),
             "at": time.time()}
    _split_progress[track_id] = entry
    return entry


def split_done(track_id: int) -> None:
    _split_progress.pop(track_id, None)


def _progress_of(track_id: int) -> dict | None:
    e = _split_progress.get(track_id)
    if e and time.time() - e["at"] > 300:
        _split_progress.pop(track_id, None)
        return None
    return e


# ------------------------------------------------------------------ the computers
def report(device_id: int, said: dict) -> None:
    """What a computer says about itself when it asks for work: kept for the pool
    screen and for the lease."""
    keep = {k: said.get(k) for k in
            ("fetch", "split", "gpu", "gpu_name", "cores", "version", "background",
             "platform", "slots")
            if k in said}
    db.run("update devices set pool=%s::jsonb, pool_at=now() where id=%s",
           (json.dumps(keep), device_id))


def strong(device_id: int) -> bool:
    row = db.one("select pool from devices where id=%s", (device_id,)) or {}
    return bool((row.get("pool") or {}).get("gpu"))


def overview(me: int, admin: bool) -> dict:
    """Everything the pool screen shows, in one request."""
    devices = db.all_(
        f"""select d.id, d.name, d.platform, d.kind, d.pool, d.pool_at, d.pool_blocked,
                   u.name as owner, w.last_seen, w.leased,
                   coalesce(w.last_seen > now() - interval '{LIVE_SECONDS} seconds', false)
                     as live
              from devices d
              join users u on u.id = d.user_id
              left join workers w on w.name = 'device:' || d.id
             where d.pool_at is not null or d.pool_blocked
                or w.last_seen > now() - interval '{LIVE_SECONDS} seconds'
             order by live desc, d.pool_at desc nulls last""")
    done = {(r["worker"], r["kind"]): r["n"] for r in db.all_(
        """select leased_by as worker, kind, count(*) n from jobs
            where state='done' and updated_at > now() - interval '24 hours'
              and leased_by like 'device:%%'
            group by 1, 2""")}
    made = {r["device_id"]: r["n"] for r in db.all_(
        """select device_id, count(distinct sha256) n from track_parts
            where created_at > now() - interval '24 hours' group by 1""")}

    active = db.all_(
        """select id as job_id, kind, priority, leased_by, attempts,
                  (payload->>'track_id')::int as track_id, batch_label
             from jobs
            where kind in ('ingest','split') and state='leased' and leased_until > now()
            order by priority, created_at limit 40""")
    waiting = db.all_(
        """select id as job_id, kind, priority, batch_label, created_at,
                  (payload->>'track_id')::int as track_id,
                  (payload->>'asked_by')::int as asked_by
             from jobs
            where kind in ('ingest','split')
              and (state='pending' or (state='leased' and leased_until < now()))
            order by priority, created_at limit 60""")
    counts = {(r["kind"], r["state"]): r["n"] for r in db.all_(
        """select kind, case when state='leased' and leased_until < now() then 'pending'
                             else state end as state, count(*) n
             from jobs
            where kind in ('ingest','split')
              and (state in ('pending','leased')
                   or updated_at > now() - interval '24 hours')
            group by 1, 2""")}
    failed = db.all_(
        """select distinct on ((payload->>'track_id')::int) id as job_id, kind, error,
                  (payload->>'track_id')::int as track_id, updated_at
             from jobs
            where kind='split' and state='failed'
              and updated_at > now() - interval '7 days'
            order by (payload->>'track_id')::int, updated_at desc""")

    from . import progress as ingest_progress

    names = {r["id"]: r["name"] for r in devices}

    def row(r: dict) -> dict:
        track = catalog.track_row(r["track_id"]) if r.get("track_id") else None
        by = r.get("leased_by") or ""
        dev = int(by.split(":", 1)[1]) if by.startswith("device:") else None
        out = {**{k: v for k, v in r.items() if k != "leased_by"},
               "track": catalog.public(track) if track else None,
               "device_id": dev, "device": names.get(dev) if dev else None}
        if r["kind"] == "split" and r.get("track_id"):
            out["progress"] = _progress_of(r["track_id"])
        elif r.get("track_id"):
            out["progress"] = ingest_progress.get(r["track_id"])
        return out

    def device(r: dict) -> dict:
        said = r["pool"] or {}
        worker = f"device:{r['id']}"
        # An app from before the pool leases songs and says nothing about itself.
        older = r["pool"] is None
        return {
            "id": r["id"], "name": r["name"], "owner": r["owner"], "older": older,
            "platform": said.get("platform") or r["platform"], "this": r["id"] == me,
            "live": bool(r["live"]) and not r["pool_blocked"],
            "blocked": bool(r["pool_blocked"]),
            "fetch": bool(said.get("fetch", older)), "split": bool(said.get("split")),
            "background": bool(said.get("background")),
            "gpu": bool(said.get("gpu")), "gpu_name": said.get("gpu_name"),
            "cores": said.get("cores"), "version": said.get("version"),
            "busy": r["leased"] or 0, "last_seen": r["last_seen"],
            "fetched_today": done.get((worker, "ingest"), 0),
            "split_today": made.get(r["id"], 0),
        }

    return {
        "admin": admin,
        "paused": {"ingest": jobs.paused("ingest"), "split": jobs.paused("split")},
        "counts": {k: {s: counts.get((k, s), 0) for s in ("pending", "leased", "done",
                                                          "failed")}
                   for k in ("ingest", "split")},
        "devices": [device(r) for r in devices],
        "active": [row(r) for r in active],
        "waiting": [row(r) for r in waiting],
        "failed_splits": [row(r) for r in failed][:20],
        "parts_kept": (db.one("select count(distinct sha256) n from track_parts") or {})
                      .get("n", 0),
    }
