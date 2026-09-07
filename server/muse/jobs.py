"""Postgres is the queue. SELECT ... FOR UPDATE SKIP LOCKED, no Redis."""
from __future__ import annotations

import json

import time

from . import db

LEASE_SECONDS = 600
MAX_ATTEMPTS = 3


def enqueue(kind: str, payload: dict) -> int:
    row = db.one(
        "insert into jobs(kind,payload) values(%s,%s) returning id",
        (kind, json.dumps(payload)),
    )
    return row["id"]


def lease_wait(worker: str, kind: str = "ingest", limit: int = 1,
               wait_seconds: float = 0.0, poll: float = 0.25) -> list[dict]:
    """Lease, or hold the connection open until work appears.

    Polling every few seconds meant a track sat queued for up to that long before
    anything happened, which reads as "nothing is downloading". Holding the request
    open costs one idle connection and starts the download as soon as it is queued.
    """
    deadline = time.monotonic() + wait_seconds
    while True:
        got = lease(worker, kind, limit)
        if got or time.monotonic() >= deadline:
            return got
        time.sleep(poll)


def lease(worker: str, kind: str = "ingest", limit: int = 1) -> list[dict]:
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
               order by created_at
               for update skip locked
               limit %s
            )
            update jobs j
               set state='leased', leased_by=%s,
                   leased_until=now() + (%s || ' seconds')::interval,
                   attempts=j.attempts+1, updated_at=now()
              from picked p
             where j.id=p.id
            returning j.id, j.kind, j.payload, j.attempts
            """,
            (kind, MAX_ATTEMPTS, limit, worker, LEASE_SECONDS),
        ).fetchall()
        c.execute(
            """insert into workers(name,last_seen,leased) values(%s,now(),%s)
               on conflict (name) do update set last_seen=now(), leased=excluded.leased""",
            (worker, len(rows)),
        )
    return rows


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
