"""Folders for playlists, and where each playlist sits.

A library of a few hundred lists is a box of records with no dividers. The dividers
are per person: a folder is yours, and so is where a list is filed — a friend's list
kept in your library goes in your folder, not theirs. Deleting a folder takes the
divider out and leaves the records in the box.
"""
from __future__ import annotations

from fastapi import APIRouter, Body, Depends, HTTPException

from . import catalog, db
from .deps import current_user
from .routes_library import _readable

router = APIRouter(tags=["folders"])


def _own_folder(folder_id: int, user: dict) -> dict:
    row = db.one("select * from playlist_folders where id=%s and user_id=%s",
                 (folder_id, user["id"]))
    if not row:
        raise HTTPException(404, "no such folder")
    return row


def _public(row: dict, count: int = 0) -> dict:
    return {"id": row["id"], "name": row["name"], "parent_id": row.get("parent_id"),
            "pos": row["pos"], "count": count}


@router.get("/playlist-folders")
def list_folders(user: dict = Depends(current_user)):
    rows = db.all_(
        """select f.*, (select count(*) from playlist_places pl
                         where pl.folder_id = f.id and pl.user_id = f.user_id) as n
             from playlist_folders f where f.user_id=%s
            order by f.pos, lower(f.name)""",
        (user["id"],))
    return {"items": [_public(r, r["n"]) for r in rows]}


@router.post("/playlist-folders", status_code=201)
def create_folder(body: dict = Body(...), user: dict = Depends(current_user)):
    name = (body.get("name") or "").strip()
    if not name:
        raise HTTPException(400, "name required")
    parent = body.get("parent_id")
    if parent is not None:
        _own_folder(int(parent), user)
    row = db.one(
        """insert into playlist_folders(user_id, name, parent_id, pos)
           values(%s,%s,%s,(select coalesce(max(pos)+1, 0) from playlist_folders
                             where user_id=%s and parent_id is not distinct from %s))
           returning *""",
        (user["id"], name, parent, user["id"], parent))
    return _public(row)


@router.patch("/playlist-folders/{folder_id}")
def change_folder(folder_id: int, body: dict = Body(...),
                  user: dict = Depends(current_user)):
    row = _own_folder(folder_id, user)
    if "name" in body:
        name = (body.get("name") or "").strip()
        if not name:
            raise HTTPException(400, "name required")
        db.run("update playlist_folders set name=%s where id=%s", (name, folder_id))
    if "parent_id" in body:
        parent = body.get("parent_id")
        if parent is not None:
            if int(parent) == folder_id:
                raise HTTPException(400, "a folder cannot hold itself")
            _own_folder(int(parent), user)
        db.run("update playlist_folders set parent_id=%s where id=%s", (parent, folder_id))
    if "pos" in body:
        db.run("update playlist_folders set pos=%s where id=%s",
               (int(body.get("pos") or 0), folder_id))
    n = db.one("select count(*) n from playlist_places where folder_id=%s", (folder_id,))["n"]
    return _public(db.one("select * from playlist_folders where id=%s", (row["id"],)), n)


@router.delete("/playlist-folders/{folder_id}")
def delete_folder(folder_id: int, user: dict = Depends(current_user)):
    """The divider comes out; the records stay in the box."""
    _own_folder(folder_id, user)
    freed = db.one("select count(*) n from playlist_places where folder_id=%s",
                   (folder_id,))["n"]
    db.run("delete from playlist_folders where id=%s", (folder_id,))
    return {"deleted": folder_id, "freed": freed}


@router.get("/playlist-folders/{folder_id}/tracks")
def folder_tracks(folder_id: int, user: dict = Depends(current_user)):
    """Everything in the folder, list by list in the folder's order, each song once:
    what "play the folder" plays."""
    _own_folder(folder_id, user)
    rows = db.all_(
        """select distinct on (t.id) t.*, m.path, m.bytes, m.sha256,
                  c.color as cover_color, c.sha256 as cover_sha, pl.pos as list_pos, i.pos
             from playlist_places pl
             join playlists p on p.id = pl.playlist_id
             join playlist_items i on i.playlist_id = p.id
             join tracks t on t.id = i.track_id
             left join media m on m.track_id = t.id and m.role = 'canonical'
             left join covers c on c.id = t.cover_id
            where pl.user_id=%s and pl.folder_id=%s
            order by t.id, pl.pos, i.pos""",
        (user["id"], folder_id))
    rows.sort(key=lambda r: (r["list_pos"], r["pos"]))
    return {"items": [catalog.public(t) for t in rows]}


@router.post("/playlists/{playlist_id}/place")
def place_playlist(playlist_id: int, body: dict = Body(default={}),
                   user: dict = Depends(current_user)):
    """File a playlist: in a folder, or back in the box (folder_id null), and where
    in it. A list is filed per person, so a friend's list can go in your folder."""
    _readable(playlist_id, user)
    folder = body.get("folder_id")
    if folder is not None:
        _own_folder(int(folder), user)
    pos = body.get("pos")
    if pos is None:
        pos = db.one(
            """select coalesce(max(pos)+1, 0) n from playlist_places
                where user_id=%s and folder_id is not distinct from %s""",
            (user["id"], folder))["n"]
    row = db.one(
        """insert into playlist_places(user_id, playlist_id, folder_id, pos)
           values(%s,%s,%s,%s)
           on conflict (user_id, playlist_id)
           do update set folder_id=excluded.folder_id, pos=excluded.pos
           returning *""",
        (user["id"], playlist_id, folder, int(pos)))
    return {"playlist_id": playlist_id, "folder_id": row["folder_id"], "pos": row["pos"],
            "pinned": row["pinned"]}


@router.post("/playlists/{playlist_id}/pin")
def pin_playlist(playlist_id: int, body: dict = Body(default={}),
                 user: dict = Depends(current_user)):
    _readable(playlist_id, user)
    pinned = bool(body.get("pinned", True))
    row = db.one(
        """insert into playlist_places(user_id, playlist_id, pinned)
           values(%s,%s,%s)
           on conflict (user_id, playlist_id) do update set pinned=excluded.pinned
           returning *""",
        (user["id"], playlist_id, pinned))
    return {"playlist_id": playlist_id, "pinned": row["pinned"], "folder_id": row["folder_id"]}


def opened(user_id: int, playlist_id: int) -> None:
    """A list was opened: what "recently opened" is made of."""
    db.run(
        """insert into playlist_places(user_id, playlist_id, last_opened_at)
           values(%s,%s,now())
           on conflict (user_id, playlist_id) do update set last_opened_at=now()""",
        (user_id, playlist_id))
