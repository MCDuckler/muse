"""The show's shared snapshots: the combination selector's rules, named, for every account.

A snapshot is the booth's combination rules as they were when it was taken (the app
keeps its own on the device: show.json). One shared here is listed to every account
signed in, which may switch its show to it and save over it — with the revision, as a
board: a desk saving over a copy older than the one kept is told so (409) with the
snapshot as it is, and reads again. Only whoever shared it renames it away from
everyone or takes it away.

The document is the app's, kept as it comes (`{"rules": [...]}`), only its size
checked: the app reads what it understands of it.
"""
from __future__ import annotations

import json

from fastapi import APIRouter, Body, Depends, HTTPException

from . import db
from .deps import current_user

router = APIRouter(prefix="/booth/show/snapshots")

MAX_DOC = 64 << 10
MAX_NAME = 60


def _public(row: dict, user_id: int) -> dict:
    return {
        "id": row["id"],
        "name": row["name"],
        "doc": row["doc"],
        "rev": row["rev"],
        "owner": row["owner"],
        "mine": row["user_id"] == user_id,
        "updated_by": row["updated_by_name"],
        "updated_at": row["updated_at"].isoformat() if row["updated_at"] else None,
    }


_SELECT = """select s.*, o.name as owner, u.name as updated_by_name
             from show_snapshots s join users o on o.id = s.user_id
             left join users u on u.id = s.updated_by"""


def _row(snapshot_id: int) -> dict:
    row = db.one(_SELECT + " where s.id=%s", (snapshot_id,))
    if not row:
        raise HTTPException(404, "no such snapshot")
    return row


def _name(body: dict) -> str:
    name = body.get("name")
    if not isinstance(name, str) or not name.strip():
        raise HTTPException(400, "a snapshot needs a name")
    return name.strip()[:MAX_NAME]


def _doc(body: dict) -> dict:
    doc = body.get("doc")
    if not isinstance(doc, dict):
        raise HTTPException(400, "doc must be the snapshot as JSON")
    if len(json.dumps(doc)) > MAX_DOC:
        raise HTTPException(413, "that is a lot of rules")
    return doc


@router.get("")
def listed(user: dict = Depends(current_user)):
    """Every shared snapshot, the newest saved first."""
    rows = db.all_(_SELECT + " order by s.updated_at desc, s.id desc")
    return {"snapshots": [_public(r, user["id"]) for r in rows]}


@router.post("", status_code=201)
def share(body: dict = Body(...), user: dict = Depends(current_user)):
    row = db.one(
        """insert into show_snapshots(user_id, name, doc, updated_by) values(%s,%s,%s,%s)
           returning id""",
        (user["id"], _name(body), json.dumps(_doc(body)), user["id"]),
    )
    return _public(_row(row["id"]), user["id"])


@router.put("/{snapshot_id}")
def save(snapshot_id: int, body: dict = Body(...), user: dict = Depends(current_user)):
    """The rules (and the name, its keeper only) over the ones kept — if [rev] is the
    one kept. A stale [rev] is a 409 with the snapshot as it is."""
    kept = _row(snapshot_id)
    try:
        rev = int(body.get("rev") or 0)
    except (TypeError, ValueError):
        raise HTTPException(400, "rev must be a number")
    if kept["rev"] != rev:
        raise HTTPException(409, _public(kept, user["id"]))
    doc = _doc(body)
    name = kept["name"]
    if "name" in body and body["name"] != kept["name"]:
        if kept["user_id"] != user["id"]:
            raise HTTPException(403, "only whoever shared it renames it")
        name = _name(body)
    db.run(
        """update show_snapshots set doc=%s, name=%s, rev=rev+1, updated_by=%s, updated_at=now()
           where id=%s""",
        (json.dumps(doc), name, user["id"], snapshot_id),
    )
    return _public(_row(snapshot_id), user["id"])


@router.delete("/{snapshot_id}", status_code=204)
def unshare(snapshot_id: int, user: dict = Depends(current_user)):
    kept = _row(snapshot_id)
    if kept["user_id"] != user["id"]:
        raise HTTPException(403, "only whoever shared it takes it away")
    db.run("delete from show_snapshots where id=%s", (snapshot_id,))
