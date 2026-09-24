"""The pool screen's questions: who is working, on what, and what is waiting — and
the few things a person can do about it. See pool.py for what the pool is."""
from __future__ import annotations

from fastapi import APIRouter, Body, Depends, HTTPException

from . import db, jobs, pool
from .deps import current_user

router = APIRouter(prefix="/pool")


def _is_admin(user: dict) -> bool:
    from .routes_accounts import is_admin

    return is_admin(user["id"])


@router.get("")
def overview(user: dict = Depends(current_user)):
    return pool.overview(user["device_id"], _is_admin(user))


@router.post("/pause")
def pause(body: dict = Body(...), user: dict = Depends(current_user)):
    """Stop handing out one kind of work, or start again. An admin's."""
    if not _is_admin(user):
        raise HTTPException(403, "only an admin pauses the pool")
    kind = body.get("kind")
    if kind not in ("ingest", "split"):
        raise HTTPException(400, "kind is ingest or split")
    jobs.set_paused(bool(body.get("paused")), kind)
    _changed()
    return {"kind": kind, "paused": jobs.paused(kind)}


@router.post("/devices/{device_id}/block")
def block(device_id: int, body: dict = Body(...), user: dict = Depends(current_user)):
    """Keep one computer out of the pool, or let it back in. An admin's; whatever it
    was holding goes back in the queue for somebody else."""
    if not _is_admin(user):
        raise HTTPException(403, "only an admin blocks a computer")
    if not db.one("select 1 from devices where id=%s", (device_id,)):
        raise HTTPException(404, "no such device")
    blocked = bool(body.get("blocked"))
    db.run("update devices set pool_blocked=%s where id=%s", (blocked, device_id))
    if blocked:
        db.run("""update jobs set state='pending', leased_by=null, leased_until=null
                   where state='leased' and leased_by=%s""", (f"device:{device_id}",))
    _changed()
    return {"device_id": device_id, "blocked": blocked}


@router.post("/split/{track_id}")
def split(track_id: int, user: dict = Depends(current_user)):
    """Have a record taken apart by the pool, now. What the booth asks when it wants a
    record's parts and nobody has made them."""
    job = pool.want_split(track_id, asked_by=user["device_id"])
    _changed()
    return {"job_id": job, "parts": _parts(track_id)}


@router.get("/split/{track_id}")
def split_state(track_id: int, user: dict = Depends(current_user)):
    """Where one record is on its way to being in parts: the parts kept, and the split
    that is waiting or running — who has it and how far through it is."""
    job = db.one(
        """select id, state, leased_by, leased_until > now() as live, priority,
                  extract(epoch from now() - created_at)::int as waited_s, error
             from jobs
            where kind='split' and (payload->>'track_id')::int=%s
            order by id desc limit 1""", (track_id,))
    out = None
    if job:
        by = job["leased_by"] or ""
        dev = int(by.split(":", 1)[1]) if by.startswith("device:") else None
        name = db.one("select name from devices where id=%s", (dev,)) if dev else None
        state = job["state"]
        if state == "leased" and not job["live"]:
            state = "pending"
        out = {"id": job["id"], "state": state, "waited_s": job["waited_s"],
               "device_id": dev if state == "leased" else None,
               "device": (name or {}).get("name") if state == "leased" else None,
               "progress": pool._progress_of(track_id) if state == "leased" else None,
               "error": job["error"] if state == "failed" else None}
    return {"parts": _parts(track_id), "job": out}


@router.get("/parts/{track_id}")
def parts(track_id: int, user: dict = Depends(current_user)):
    """Which parts of a record are kept here."""
    return {"parts": _parts(track_id)}


def _parts(track_id: int) -> list[str]:
    from . import catalog

    t = catalog.track_row(track_id)
    return pool.parts_of(t["sha256"]) if t and t.get("sha256") else []


@router.post("/jobs/{job_id}/cancel")
def cancel(job_id: int, user: dict = Depends(current_user)):
    """Take a waiting split out of the queue. Anybody may cancel a split they asked
    for; an admin, any."""
    row = db.one("select kind, state, payload from jobs where id=%s", (job_id,))
    if not row or row["kind"] != "split":
        raise HTTPException(404, "no such split")
    mine = (row["payload"] or {}).get("asked_by") == user["device_id"]
    if not (mine or _is_admin(user)):
        raise HTTPException(403, "not your split to cancel")
    db.run("update jobs set state='cancelled', leased_by=null, leased_until=null, "
           "updated_at=now() where id=%s and state in ('pending','leased','failed')",
           (job_id,))
    _changed()
    return {"cancelled": job_id}


@router.post("/jobs/{job_id}/retry")
def retry(job_id: int, user: dict = Depends(current_user)):
    row = db.one("select kind, payload from jobs where id=%s", (job_id,))
    if not row or row["kind"] != "split":
        raise HTTPException(404, "no such split")
    db.run("update jobs set state='pending', attempts=0, error=null, "
           "next_attempt_at=now(), updated_at=now() where id=%s", (job_id,))
    _changed()
    return {"retried": job_id}


def _changed() -> None:
    from .app import publish

    publish("pool", {})
