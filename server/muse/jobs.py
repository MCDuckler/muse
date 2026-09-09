"""Postgres is the queue. SELECT ... FOR UPDATE SKIP LOCKED, no Redis."""
from __future__ import annotations

import json

import time

from . import db

LEASE_SECONDS = 600
MAX_ATTEMPTS = 3


# Lower runs sooner. The default sits in the middle so both directions are available.
PRIORITY_NOW = 10        # you are waiting for this one
PRIORITY_NORMAL = 100    # you asked for it
PRIORITY_BULK = 500      # a playlist import filling in behind you


def enqueue(kind: str, payload: dict, priority: int = PRIORITY_NORMAL,
            batch_id: str | None = None, batch_label: str | None = None,
            delay_seconds: float = 0.0) -> int:
    """Queue a job, optionally not before a while from now.

    The delay is for work that is waiting on somebody else — a service that has asked
    us to slow down, say. That is not a failure and must not spend one of the job's
    three attempts.
    """
    row = db.one(
        """insert into jobs(kind, payload, priority, batch_id, batch_label,
                            next_attempt_at)
           values(%s,%s,%s,%s,%s, now() + (%s || ' seconds')::interval) returning id""",
        (kind, json.dumps(payload), priority, batch_id, batch_label, delay_seconds),
    )
    return row["id"]


def promote(track_id: int, priority: int = PRIORITY_NOW) -> bool:
    """Move a track to the front, queueing it first if nobody ever did.

    Two cases, one answer. A track waiting behind a hundred imports jumps them. A track
    from a mirrored library that was never queued at all — because twelve thousand liked
    songs are a list worth having long before they are forty gigabytes worth having —
    gets its job made now, at the front.
    """
    row = db.one(
        """update jobs set priority=%s
            where kind='ingest' and state='pending'
              and (payload->>'track_id')::int = %s
            returning id""",
        (priority, track_id),
    )
    if row:
        return True

    waiting = db.one(
        """select t.id, s.provider, s.provider_id, s.raw->>'url' as url
             from tracks t
             join track_sources s on s.track_id = t.id
            where t.id=%s and t.state='pending'
              and not exists (select 1 from jobs j
                               where j.kind in ('ingest','ingest_direct')
                                 and (j.payload->>'track_id')::int = t.id
                                 and j.state in ('pending','leased','done'))
            order by (s.provider = 'ytmusic') desc limit 1""",
        (track_id,),
    )
    if not waiting or not waiting["provider_id"]:
        return False

    # Which lane depends on where the song lives. A Bandcamp or SoundCloud track is
    # fetched by the server itself; only YouTube needs the worker at home. Queueing
    # everything as YouTube meant a track from a big mirror — recorded but not
    # downloaded — could never be started at all, and sat "downloading" for good.
    if waiting["provider"] in ("soundcloud", "bandcamp"):
        enqueue("ingest_direct",
                {"track_id": track_id, "provider": waiting["provider"],
                 "ref": waiting["url"] or waiting["provider_id"]},
                priority=priority)
    else:
        enqueue("ingest", {"track_id": track_id, "video_id": waiting["provider_id"]},
                priority=priority)
    return True


def promote_run(track_ids: list[int], priority: int = PRIORITY_NOW) -> int:
    """What is about to be played, in the order it will be played.

    The track under the needle is worth more than the one after it, which is worth more
    than the one after that — so they go in a step apart and keep their order among
    themselves while all of them stay ahead of any import.
    """
    promoted = 0
    for step, track_id in enumerate(track_ids[:8]):
        promoted += promote(int(track_id), priority + step)
    return promoted


def paused() -> bool:
    row = db.one("select value from settings where key='downloads_paused'")
    return bool(row and row["value"] == "1")


def set_paused(value: bool) -> None:
    db.run(
        """insert into settings(key, value, set_at) values('downloads_paused',%s,now())
           on conflict (key) do update set value=excluded.value, set_at=now()""",
        ("1" if value else "0",),
    )


def lease_wait(worker: str, kind: str = "ingest", limit: int = 1,
               wait_seconds: float = 0.0, poll: float = 0.25,
               busy: int | None = None, max_priority: int | None = None) -> list[dict]:
    """Lease, or hold the connection open until work appears.

    Polling every few seconds meant a track sat queued for up to that long before
    anything happened, which reads as "nothing is downloading". Holding the request
    open costs one idle connection and starts the download as soon as it is queued.
    """
    deadline = time.monotonic() + wait_seconds
    while True:
        got = lease(worker, kind, limit, busy=busy, max_priority=max_priority)
        if got or time.monotonic() >= deadline:
            return got
        time.sleep(poll)


def lease(worker: str, kind: str = "ingest", limit: int = 1,
          busy: int | None = None, max_priority: int | None = None) -> list[dict]:
    """Hand out up to `limit` jobs.

    `busy` is what the worker already has in flight: a worker that downloads three at a
    time leases one job at a time as slots free, and without this the recorded count
    would read as 1 while three were running.

    `max_priority` asks for urgent work only. A worker already downloading something
    somebody is waiting for uses it to leave the line free rather than filling every
    slot with a backfill that will hold the connection for the next minute.
    """
    # A pause has to stop work being handed out, not just hide it in the UI.
    if kind == "ingest" and paused():
        db.run(
            """insert into workers(name,last_seen,leased) values(%s,now(),%s)
               on conflict (name) do update set last_seen=now(), leased=excluded.leased""",
            (worker, busy or 0),
        )
        return []
    with db.pool().connection() as c:
        rows = c.execute(
            """
            with picked as (
              select id from jobs
               where kind=%s
                 and (state='pending'
                      or (state='leased' and leased_until < now()))
                 and next_attempt_at <= now()
                 and attempts < %s
                 and (%s::int is null or priority <= %s::int)
               order by priority, created_at
               for update skip locked
               limit %s
            )
            , taken as (
              update jobs j
                 set state='leased', leased_by=%s,
                     leased_until=now() + (%s || ' seconds')::interval,
                     attempts=j.attempts+1, updated_at=now()
                from picked p
               where j.id=p.id
              returning j.id, j.kind, j.payload, j.attempts, j.priority,
                        j.batch_id, j.batch_label, j.created_at
            )
            -- Ordered here, not in the CTE: an UPDATE's RETURNING comes back in
            -- whatever order the rows were touched, so a worker asking for four jobs
            -- could be handed the backfill before the song somebody is waiting for.
            select * from taken order by priority, created_at
            """,
            (kind, MAX_ATTEMPTS, max_priority, max_priority, limit, worker, LEASE_SECONDS),
        ).fetchall()
        c.execute(
            """insert into workers(name,last_seen,leased) values(%s,now(),%s)
               on conflict (name) do update set last_seen=now(), leased=excluded.leased""",
            (worker, (busy or 0) + len(rows)),
        )
    return rows


def release(job_id: int) -> None:
    """Hand a job back unstarted.

    A worker that is being shut down knows its downloads will not finish. Without this
    the job sits leased for ten minutes and burns one of its three attempts for a
    reason that had nothing to do with the track.
    """
    db.run(
        """update jobs set state='pending', leased_by=null, leased_until=null,
                  attempts=greatest(attempts-1, 0), next_attempt_at=now(),
                  updated_at=now()
            where id=%s and state='leased'""",
        (job_id,),
    )


def finish(job_id: int) -> None:
    db.run("update jobs set state='done', updated_at=now() where id=%s", (job_id,))


BACKOFF_BASE_SECONDS = 60


def fail(job_id: int, reason: str, retryable: bool = True) -> None:
    """Retries back off quadratically. A job flapping against YouTube at full speed is
    exactly what turns a working residential IP into a challenged one."""
    db.run(
        """update jobs
              set state = case when %s and attempts < %s then 'pending' else 'failed' end,
                  error=%s, leased_by=null, leased_until=null, updated_at=now(),
                  next_attempt_at = now() + (%s * attempts * attempts || ' seconds')::interval
            where id=%s""",
        (retryable, MAX_ATTEMPTS, reason[:2000], BACKOFF_BASE_SECONDS, job_id),
    )
