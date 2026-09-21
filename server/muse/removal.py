"""Taking a song out of your library — and off the server, when nobody else has it.

The catalog is shared and a library is one person's view of it, so "remove" is two
things. It always takes the song out of *your* lists: the library, your playlists, your
queues. And when that leaves nobody holding it, the track and its audio go too — a
wrong match that stays on disk is still a wrong match, still found by search, and still
what the next sync would hand back.
"""
from __future__ import annotations

import pathlib

from . import db, peaks


def _renumber(c, table: str, key: str, owner_id: int) -> None:
    """Close the gaps a delete left. Through negative positions, because (owner, pos)
    is the primary key and rows are checked one at a time as they move."""
    c.execute(
        f"""with n as (select pos, row_number() over (order by pos) - 1 as np
                         from {table} where {key}=%s)
            update {table} i set pos = -(n.np + 1)
              from n where i.{key}=%s and i.pos = n.pos""", (owner_id, owner_id))
    c.execute(f"update {table} set pos = -pos - 1 where {key}=%s and pos < 0",
              (owner_id,))


def _take_out_of_lists(c, track_ids: list[int], user_id: int | None) -> list[int]:
    """Drop the tracks from queues and playlists — one person's, or (None) everyone's.

    Returns the queues that changed, so their devices can be told.
    """
    mine_q = "and q.user_id=%s" if user_id is not None else ""
    mine_p = "and p.owner_id=%s" if user_id is not None else ""
    who = (user_id,) if user_id is not None else ()

    queues = c.execute(
        f"""select distinct q.id, q.cursor_index from queues q
              join queue_items i on i.queue_id=q.id
             where i.track_id = any(%s) {mine_q}""", (track_ids, *who)).fetchall()
    for q in queues:
        # Rows above the cursor that are going: the cursor comes up by that many, so it
        # stays on the same song. If the song under it is one of them, it lands on
        # whatever followed.
        above = c.execute(
            """select count(*) n from queue_items
                where queue_id=%s and pos < %s and track_id = any(%s)""",
            (q["id"], q["cursor_index"], track_ids)).fetchone()["n"]
        c.execute("delete from queue_items where queue_id=%s and track_id = any(%s)",
                  (q["id"], track_ids))
        _renumber(c, "queue_items", "queue_id", q["id"])
        left = c.execute("select count(*) n from queue_items where queue_id=%s",
                         (q["id"],)).fetchone()["n"]
        c.execute(
            """update queues set rev=rev+1, updated_at=now(),
                      cursor_index=greatest(least(cursor_index - %s, %s - 1), 0)
                where id=%s""", (above, left, q["id"]))

    playlists = c.execute(
        f"""select distinct p.id from playlists p
              join playlist_items i on i.playlist_id=p.id
             where i.track_id = any(%s) {mine_p}""", (track_ids, *who)).fetchall()
    for p in playlists:
        c.execute("delete from playlist_items where playlist_id=%s and track_id = any(%s)",
                  (p["id"], track_ids))
        _renumber(c, "playlist_items", "playlist_id", p["id"])
    return [q["id"] for q in queues]


def remove_from_library(user_id: int, track_ids: list[int], data_dir: pathlib.Path) -> dict:
    """Returns {removed, deleted, queues}: how many left this library, how many of
    those left the server as well, and which queues changed."""
    track_ids = sorted(set(track_ids))
    if not track_ids:
        return {"removed": 0, "deleted": 0, "queues": []}
    files: list[dict] = []
    with db.pool().connection() as c:
        held = [r["track_id"] for r in c.execute(
            "select track_id from library_items where user_id=%s and track_id = any(%s)",
            (user_id, track_ids)).fetchall()]
        if not held:
            return {"removed": 0, "deleted": 0, "queues": []}
        queues = _take_out_of_lists(c, held, user_id)
        c.execute("delete from library_items where user_id=%s and track_id = any(%s)",
                  (user_id, held))

        # Whoever else has it keeps it: the library is theirs as much as this one was.
        orphans = [r["id"] for r in c.execute(
            """select t.id from tracks t
                where t.id = any(%s)
                  and not exists (select 1 from library_items li where li.track_id=t.id)""",
            (held,)).fetchall()]
        if orphans:
            # Anything still pointing at it — a list that never made it into
            # library_items — would otherwise be left with a hole in its numbering.
            queues += _take_out_of_lists(c, orphans, None)
            # A sync never re-decides what a person decided, and "not this one" is a
            # decision: without it the next pull matches the same wrong video again.
            c.execute(
                """update matches set decided_by='human', method='removed', decided_at=now()
                    where track_id = any(%s)""", (orphans,))
            c.execute(
                """update jobs set state='failed', error='track removed', updated_at=now()
                    where state in ('pending','leased')
                      and payload ? 'track_id'
                      and (payload->>'track_id')::int = any(%s)""", (orphans,))
            files = c.execute("select sha256, path from media where track_id = any(%s)",
                              (orphans,)).fetchall()
            c.execute("delete from tracks where id = any(%s)", (orphans,))
            # Blobs are content-addressed and shared: only the ones nothing names now.
            files = [f for f in files if not c.execute(
                "select 1 from media where sha256=%s limit 1", (f["sha256"],)).fetchone()]

    # After the transaction: a file deleted for a row that then failed to go is music
    # lost, and a row gone with its file still there is only some disk.
    root = data_dir.resolve()
    for f in files:
        blob = pathlib.Path(f["path"]).resolve()
        if root in blob.parents:              # never follow a row out of the data dir
            blob.unlink(missing_ok=True)
        peaks.cache_path(data_dir, f["sha256"]).unlink(missing_ok=True)
    return {"removed": len(held), "deleted": len(orphans),
            "queues": sorted(set(queues))}
