"""Managing downloads, rather than merely having them.

A single track queued behind a spinner was fine. A mirrored playlist is a hundred and
twenty of them, and then the questions change: how far along is it, what is stuck, can
I stop it, and can I make the song I actually want to hear jump the queue. Those are
the only questions this module answers.
"""
from __future__ import annotations

from fastapi import APIRouter, Body, Depends, HTTPException

from . import catalog, db, jobs, progress
from .deps import current_user

router = APIRouter(prefix="/downloads")


@router.get("")
def overview(user: dict = Depends(current_user)):
    """Everything about the download queue in one request, because a screen that has
    to make five is a screen that flickers."""
    counts = {r["state"]: r["n"] for r in db.all_(
        """select state, count(*) n from jobs
            where kind='ingest'
              and (state <> 'done' or created_at > now() - interval '30 days')
            group by state"""
    )}

    active = db.all_(
        """select j.id as job_id, j.batch_label, (j.payload->>'track_id')::int as track_id
             from jobs j
            where j.kind='ingest' and j.state='leased'
            order by j.priority, j.created_at limit 10"""
    )
    waiting = db.all_(
        """select j.id as job_id, j.priority, j.batch_label,
                  (j.payload->>'track_id')::int as track_id
             from jobs j
            where j.kind='ingest' and j.state='pending'
            order by j.priority, j.created_at limit 40"""
    )
    failed = db.all_(
        """select j.id as job_id, j.error, j.attempts, j.batch_label,
                  (j.payload->>'track_id')::int as track_id
             from jobs j
            where j.kind='ingest' and j.state='failed'
            order by j.updated_at desc limit 40"""
    )

    # A batch is how a person thinks about an import: one row, one progress bar.
    batches = db.all_(
        """select batch_id, max(batch_label) as label,
                  count(*) as total,
                  count(*) filter (where state='done') as done,
                  count(*) filter (where state='failed') as failed,
                  count(*) filter (where state in ('pending','leased')) as remaining,
                  min(created_at) as started
             from jobs
            where kind='ingest' and batch_id is not null
            group by batch_id
           having count(*) filter (where state in ('pending','leased')) > 0
               or min(created_at) > now() - interval '2 hours'
            order by (min(created_at) > now() - interval '1 hour') desc,
                     count(*) filter (where state in ('pending','leased')) desc,
                     min(created_at) desc
            limit 30"""
    )
    # What you just started belongs at the top; after that, the biggest remainder,
    # because that is the import actually holding up the queue.
    batches_total = db.one(
        """select count(*) n from (
               select batch_id from jobs
                where kind='ingest' and batch_id is not null
                group by batch_id
               having count(*) filter (where state in ('pending','leased')) > 0
                   or min(created_at) > now() - interval '2 hours') s"""
    )["n"]

    def decorate(rows: list[dict]) -> list[dict]:
        out = []
        for r in rows:
            track = catalog.track_row(r["track_id"]) if r.get("track_id") else None
            out.append({**r, "track": catalog.public(track) if track else None,
                        "progress": progress.get(r["track_id"]) if r.get("track_id") else None})
        return out

    worker = db.one(
        """select name, extract(epoch from now()-last_seen) as age
             from workers where name <> 'api-enrich'
            order by last_seen desc limit 1"""
    )
    age = float(worker["age"]) if worker and worker["age"] is not None else None

    return {
        "paused": jobs.paused(),
        "worker": {"name": worker["name"] if worker else None,
                   "online": age is not None and age < 90,
                   "seconds_since_seen": age},
        "counts": {
            "waiting": counts.get("pending", 0),
            "downloading": counts.get("leased", 0),
            "done": counts.get("done", 0),
            "failed": counts.get("failed", 0),
        },
        "active": decorate(active),
        "waiting": decorate(waiting),
        "failed": decorate(failed),
        "batches": batches,
        "batches_total": batches_total,
    }


@router.post("/pause")
def pause(body: dict = Body(default={}), user: dict = Depends(current_user)):
    """Stop handing out work. In-flight downloads finish; nothing new starts."""
    jobs.set_paused(bool(body.get("paused", True)))
    return {"paused": jobs.paused()}


@router.post("/retry-failed")
def retry_failed(body: dict = Body(default={}), user: dict = Depends(current_user)):
    """Put failures back in the queue.

    Attempts are reset, because a person choosing "try again" is new information: the
    network came back, or the worker's machine woke up.
    """
    batch = (body or {}).get("batch_id")
    where = "kind='ingest' and state='failed'"
    params: tuple = ()
    if batch:
        where += " and batch_id=%s"
        params = (batch,)
    rows = db.all_(
        f"""update jobs set state='pending', attempts=0, error=null,
                   next_attempt_at=now(), updated_at=now()
             where {where}
            returning (payload->>'track_id')::int as track_id""",
        params,
    )
    for r in rows:
        if r["track_id"]:
            db.run("""update tracks set state='pending', fail_reason=null,
                             fail_code=null where id=%s""", (r["track_id"],))
    return {"retrying": len(rows)}


@router.post("/cancel")
def cancel(body: dict = Body(...), user: dict = Depends(current_user)):
    """Stop things that have not started.

    A batch you regret is the common case, so a whole batch can go at once; `all` empties
    the queue outright, for when a mirror pulled in far more than you meant it to.
    """
    batch, track_id = body.get("batch_id"), body.get("track_id")
    if not batch and not track_id and not body.get("all"):
        raise HTTPException(400, "batch_id, track_id or all required")

    where = "kind='ingest' and state='pending'"
    params: tuple = ()
    if batch:
        where += " and batch_id=%s"
        params += (batch,)
    if track_id:
        where += " and (payload->>'track_id')::int = %s"
        params += (int(track_id),)

    rows = db.all_(
        f"""update jobs set state='cancelled', updated_at=now()
             where {where}
            returning (payload->>'track_id')::int as track_id""",
        params,
    )
    for r in rows:
        if r["track_id"]:
            progress.clear(r["track_id"])
            db.run(
                """update tracks set state='failed', fail_reason='Download cancelled',
                          fail_code='cancelled' where id=%s and state <> 'ready'""",
                (r["track_id"],),
            )
    return {"cancelled": len(rows)}


@router.post("/promote")
def promote(body: dict = Body(...), user: dict = Depends(current_user)):
    """Jump the queue for something you are waiting on right now."""
    track_id = body.get("track_id")
    if not track_id:
        raise HTTPException(400, "track_id required")
    return {"promoted": jobs.promote(int(track_id))}
