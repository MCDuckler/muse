"""Postgres is the queue. SELECT ... FOR UPDATE SKIP LOCKED, no Redis."""
from __future__ import annotations

import json

import time

from . import db

LEASE_SECONDS = 600
MAX_ATTEMPTS = 3


# Lower runs sooner. The default sits in the middle so both directions are available.
PRIORITY_NOW = 10        # you are waiting for this one
PRIORITY_QUEUE = 50      # it is in the queue you are listening to
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


# What a direct-source row is fetched from. Selected as one expression because three
# places need the same answer and disagreeing about it is how a track ends up with a
# job that can never succeed.
REF_SQL = """coalesce(s.raw->>'url',
                      case when s.raw->>'pageUrl' is not null
                           then (s.raw->>'pageUrl') || '#' || s.provider_id end)"""


def direct_ref(provider: str, provider_id: str, url: str | None) -> str | None:
    """Where to fetch this one from, or nothing if we cannot say.

    SoundCloud is happy with a bare track id — the fetcher builds the api.soundcloud.com
    URL itself. Bandcamp is not: an id names nothing it can look up, so a row with no
    page behind it must not be queued at all. Queueing it anyway is how a song sat
    "downloading" for good: the job failed on a reference that was never going to work,
    and every retry failed the same way.
    """
    if url:
        return url
    if provider == "bandcamp":
        return None
    return provider_id or None


# The two the server fetches itself. Everything else needs the worker at home.
DIRECT = ("soundcloud", "bandcamp")


def best_source(track_id: int) -> dict | None:
    """Where to fetch this track from, given every place it is known to live.

    A source the server can fetch itself wins, and one already known to be gone is not
    considered at all.
    
    This used to be the other way round — `order by (provider = 'ytmusic') desc` — and
    it is how forty-eight SoundCloud tracks ended up failing over and over with "this
    isn't on YouTube any more". They were on SoundCloud, which is where they came from
    and which this machine can reach in a second; a YouTube source had been added
    beside it while looking for a copy of something, and from then on every attempt
    went to the copy that did not exist instead of the original that did.

    It is the better rule anyway: a direct source needs nothing but this server, and a
    YouTube one needs a laptop at home to be awake.
    """
    rows = db.all_(
        f"""select s.provider, s.provider_id, {REF_SQL} as url
             from track_sources s
            where s.track_id=%s and coalesce(s.raw->>'dead','') <> 'true'""",
        (track_id,),
    )
    best = None
    for row in rows:
        if not row["provider_id"]:
            continue
        if row["provider"] in DIRECT:
            ref = direct_ref(row["provider"], row["provider_id"], row["url"])
            if not ref:
                continue                     # named but not addressable; see direct_ref
            rank = 0
        elif row["provider"] == "ytmusic":
            ref, rank = row["provider_id"], 1
        else:
            continue
        if best is None or rank < best["rank"]:
            best = {"rank": rank, "provider": row["provider"], "ref": ref,
                    "provider_id": row["provider_id"]}
    return best


def queue(track_id: int, priority: int = PRIORITY_NORMAL,
          batch_id: str | None = None, batch_label: str | None = None) -> bool:
    """Make the job that fetches this track. Says whether there was one to make.

    Which lane depends on where the song lives: a Bandcamp or SoundCloud track is
    fetched by the server itself, and only YouTube needs the worker at home.
    """
    source = best_source(track_id)
    if source is None:
        return False
    if source["provider"] in DIRECT:
        enqueue("ingest_direct",
                {"track_id": track_id, "provider": source["provider"],
                 "ref": source["ref"]},
                priority=priority, batch_id=batch_id, batch_label=batch_label)
    else:
        enqueue("ingest", {"track_id": track_id, "video_id": source["ref"]},
                priority=priority, batch_id=batch_id, batch_label=batch_label)
    return True


def promote(track_id: int, priority: int = PRIORITY_NOW) -> bool:
    """Move a track to the front, queueing it first if nobody ever did.

    Three cases, one answer. A track waiting behind a hundred imports jumps them. A
    track from a mirrored library that was never queued at all — because twelve
    thousand liked songs are a list worth having long before they are forty gigabytes
    worth having — gets its job made now, at the front. And a track that failed gets
    another go: asking for it again is the clearest possible statement that the last
    answer was not the wanted one, and refusing on the grounds that it went badly once
    is how "download this" came to do nothing at all, silently, for everything that had
    ever been cancelled.
    """
    row = db.one(
        """update jobs set priority=%s
            where kind in ('ingest','ingest_direct') and state='pending'
              and (payload->>'track_id')::int = %s
            returning id""",
        (priority, track_id),
    )
    if row:
        return True

    track = db.one("select id, state from tracks where id=%s", (track_id,))
    if not track or track["state"] == "ready":
        return False

    # Already being fetched. Not a failure, and not a reason to fetch it twice.
    running = db.one(
        """select 1 from jobs
            where kind in ('ingest','ingest_direct') and state='leased'
              and leased_until > now()
              and (payload->>'track_id')::int = %s""",
        (track_id,),
    )
    if running:
        return True

    if track["state"] == "failed":
        db.run("""update tracks set state='pending', fail_reason=null, fail_code=null
                   where id=%s""", (track_id,))

    if queue(track_id, priority=priority):
        return True
    # Nothing addressable anywhere. Put the state back rather than leaving a track
    # sitting at "pending" with nothing on its way.
    if track["state"] == "failed":
        db.run("""update tracks set state='failed',
                         fail_reason='There is nowhere left to fetch this from',
                         fail_code='no_source' where id=%s""", (track_id,))
    return False


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


def hold(job_id: int, seconds: float, why: str) -> None:
    """Put a job back and leave it alone for a while.

    For a service that has said, in so many words, to stop asking. That is not a
    failure of the job — trying it again in ten minutes will work — and it must not
    spend one of its three attempts, or a rate limit lasting an afternoon would write
    off every track behind it as broken.

    It is also the only thing that stops the queue making the problem worse: nine
    thousand jobs each retrying a 429 immediately is a very good way to stay
    rate-limited for ever.
    """
    db.run(
        """update jobs set state='pending', leased_by=null, leased_until=null,
                  attempts=greatest(attempts-1, 0), error=%s, updated_at=now(),
                  next_attempt_at = now() + (%s || ' seconds')::interval
            where id=%s""",
        (why[:2000], seconds, job_id),
    )


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
