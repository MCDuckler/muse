"""Songs Shazam recognised, and what became of them here.

Importing is cheap and matching is not, so the two are separate: the file lands in a
moment, and the work of finding each song in the catalogue happens behind it. A tag is
kept whether or not anything answers to it — a song recognised in a bar at two in the
morning is worth having written down even when nothing here matches it, and a match
that fails today may well succeed once the library has grown.
"""
from __future__ import annotations

from fastapi import APIRouter, Body, Depends, HTTPException

from . import catalog, db, jobs, shazam
from .deps import current_user

router = APIRouter(prefix="/shazams")


def _public(row: dict) -> dict:
    track = catalog.track_row(row["track_id"]) if row.get("track_id") else None
    return {
        "id": row["id"],
        "title": row["title"],
        "artist": row["artist"],
        "tagged_at": row["tagged_at"],
        "url": row["url"],
        "confidence": row["confidence"],
        "looked_at": row["looked_at"],
        "track": catalog.public(track) if track else None,
    }


@router.get("")
def listing(limit: int = 500, unmatched: bool = False,
            user: dict = Depends(current_user)):
    """Everything tagged, newest first — which is the order anybody remembers them in."""
    where = "s.user_id=%s" + (" and s.track_id is null" if unmatched else "")
    rows = db.all_(
        f"""select * from shazams s
             where {where}
             order by s.tagged_at desc nulls last, s.id desc
             limit %s""",
        (user["id"], min(limit, 2000)),
    )
    counts = db.one(
        """select count(*) as total,
                  count(*) filter (where track_id is not null) as matched,
                  count(*) filter (where looked_at is null) as waiting
             from shazams where user_id=%s""",
        (user["id"],),
    )
    return {"items": [_public(r) for r in rows], **counts}


@router.post("/import", status_code=201)
def import_library(body: dict = Body(...), user: dict = Depends(current_user)):
    """A Shazam library export.

    Shazam has no way to be asked what somebody has tagged — there is no API for your
    own library — but the web player will hand the whole thing over as a CSV, and that
    is the same shape as every other import here.
    """
    text = body.get("csv")
    if not isinstance(text, str) or not text.strip():
        raise HTTPException(400, "send the exported file as `csv`")

    tags = shazam.read(text)
    if not tags:
        raise HTTPException(
            400, "Nothing in that file looked like a Shazam library — it wants the "
                 "CSV from shazam.com, not a screenshot of it.")

    added = 0
    for tag in tags:
        row = db.one(
            """insert into shazams(user_id, tag_key, title, artist, tagged_at, url)
               values(%s,%s,%s,%s,%s,%s)
               on conflict (user_id, tag_key) do nothing
               returning id""",
            (user["id"], tag["tag_key"], tag["title"], tag["artist"],
             tag["tagged_at"], tag["url"]),
        )
        if row:
            added += 1

    # The looking-up happens behind this. Searching for a few hundred songs one at a
    # time is a minute of work, and nobody should watch a progress bar to find out that
    # their own history imported.
    if added:
        jobs.enqueue("shazam_match", {"user_id": user["id"]},
                     priority=jobs.PRIORITY_BULK)
    return {"read": len(tags), "added": added,
            "already_here": len(tags) - added}


@router.post("/match", status_code=202)
def look_again(user: dict = Depends(current_user)):
    """Go through the ones that found nothing, again.

    Worth offering because the answer changes: a song nothing matched last month is a
    song the catalogue may well have now.
    """
    db.run("""update shazams set looked_at=null
               where user_id=%s and track_id is null""", (user["id"],))
    jobs.enqueue("shazam_match", {"user_id": user["id"]},
                 priority=jobs.PRIORITY_BULK)
    return {"ok": True}


@router.delete("/{shazam_id}")
def forget(shazam_id: int, user: dict = Depends(current_user)):
    gone = db.all_("delete from shazams where id=%s and user_id=%s returning id",
                   (shazam_id, user["id"]))
    return {"removed": len(gone)}
