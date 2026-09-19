"""The other people on this server.

The catalog has always been shared — everybody's songs sit in one library on one box —
but there was no way to see that. You could not find out who else was here, what they
listen to, or that somebody had a jam going in the next room. This is that: a list of
people, what each of them has, and the two things you can do with somebody else's
playlist, which are keep it and, if they let you, add to it.

Small and trusting on purpose. Everyone on this server was invited to it by somebody
who runs it, so a library is readable by anybody signed in; what is *not* open is
writing, which stays with whoever owns the list unless they say otherwise.
"""
from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException

from . import catalog, db
from .deps import current_user

router = APIRouter(prefix="/social")

# Favourites is a playlist in the schema and a private thing in practice: it is the
# heart on a row, not a list somebody made to be read.
FAVOURITES_KIND = "favourites"


# How fresh a queue's stamp has to be for the song at its cursor to count as "now".
#
# A playing device writes where it has got to every ten seconds — that is what keeps a
# queue resumable — so a queue touched in the last little while is a queue somebody is
# listening to. Nothing new is written for this: the fact was already on the table,
# nobody had ever read it out.
NOW = "90 seconds"
RECENTLY = "30 minutes"


def _playing() -> dict[int, dict]:
    """What each person has on, by user id.

    Their most recently touched queue, and the song its cursor is sitting on. A pause
    stamps the queue too, so this goes quiet a minute and a half after somebody stops
    rather than the moment they do — which is the right way round for a screen that
    says what the room is up to.
    """
    rows = db.all_(
        f"""select distinct on (q.user_id) q.user_id, q.name as queue,
                   q.updated_at, q.position_ms,
                   q.updated_at > now() - interval '{NOW}' as now,
                   t.*, c.color as cover_color, c.sha256 as cover_sha, m.path
              from queues q
              -- The cursor counts rows; pos is a sort key with gaps in it, so the
              -- row it names is the nth by pos rather than the one whose pos is n.
              join lateral (
                    select z.track_id from (
                           select track_id, row_number() over (order by pos) - 1 as idx
                             from queue_items where queue_id = q.id) z
                     where z.idx = q.cursor_index) i on true
              join tracks t on t.id = i.track_id
              left join covers c on c.id = t.cover_id
              left join media m on m.track_id = t.id and m.role='canonical'
             where q.updated_at > now() - interval '{RECENTLY}'
             order by q.user_id, q.updated_at desc""")
    return {
        r["user_id"]: {
            "track": catalog.public(r),
            "queue": r["queue"],
            "at": r["updated_at"],
            "now": r["now"],
        } for r in rows
    }


def _jams() -> dict[int, dict]:
    """Who has a jam going right now, by host."""
    rows = db.all_(
        """select j.id, j.code, j.host_id, j.created_at,
                  (select count(*) from jam_members m where m.jam_id = j.id) as people
             from jams j
            where j.ended_at is null"""
    )
    return {r["host_id"]: {"code": r["code"], "since": r["created_at"],
                           "people": r["people"]} for r in rows}


@router.get("/people")
def people(user: dict = Depends(current_user)):
    """Everybody here, with enough about each to be worth tapping.

    The jam is the part that has to be at a glance: a jam is a thing happening now, and
    a thing happening now is no use to anybody who has to go looking for it.
    """
    live = _jams()
    onNow = _playing()
    rows = db.all_(
        """select u.id, u.name, u.avatar_sig, u.created_at,
                  (select count(*) from library_items li where li.user_id = u.id)
                    as songs,
                  (select count(*) from playlists p
                    where p.owner_id = u.id and p.kind <> %s) as playlists,
                  (select max(d.last_seen) from devices d where d.user_id = u.id)
                    as last_seen,
                  (select max(l.started_at) from listens l where l.user_id = u.id)
                    as last_listened
             from users u
            order by lower(u.name)""",
        (FAVOURITES_KIND,),
    )
    return {
        "you": user["id"],
        "people": [{
            "id": r["id"],
            "name": r["name"],
            "avatar_url": f"/users/{r['id']}/avatar" if r["avatar_sig"] else None,
            "avatar_version": r["avatar_sig"],
            "songs": r["songs"],
            "playlists": r["playlists"],
            "last_seen": r["last_seen"],
            "last_listened": r["last_listened"],
            # What they have on. The thing a screen called People is actually for.
            "playing": onNow.get(r["id"]),
            "jam": live.get(r["id"]),
        } for r in rows],
    }


def _person(user_id: int) -> dict:
    row = db.one("select id, name, avatar_sig, created_at from users where id=%s",
                 (user_id,))
    if not row:
        raise HTTPException(404, "nobody here by that id")
    return row


@router.get("/people/{person_id}")
def person(person_id: int, user: dict = Depends(current_user)):
    """One person: who they are, what they have, and what they are in the middle of."""
    them = _person(person_id)
    live = _jams().get(person_id)
    counts = db.one(
        """select (select count(*) from library_items li where li.user_id=%s) as songs,
                  (select count(*) from playlists p
                    where p.owner_id=%s and p.kind <> %s) as playlists,
                  (select count(*) from listens l
                    where l.user_id=%s and l.completed) as played""",
        (person_id, person_id, FAVOURITES_KIND, person_id),
    )
    # What they have been listening to, which is the thing a profile is actually for.
    recent = db.all_(
        """select distinct on (l.track_id) l.track_id, l.started_at, t.*,
                  m.path, c.color as cover_color, c.sha256 as cover_sha
             from listens l
             join tracks t on t.id = l.track_id
             left join media m on m.track_id=t.id and m.role='canonical'
             left join covers c on c.id=t.cover_id
            where l.user_id=%s and l.completed
            order by l.track_id, l.started_at desc""",
        (person_id,),
    )
    recent.sort(key=lambda r: r["started_at"], reverse=True)
    return {
        "id": them["id"],
        "name": them["name"],
        "avatar_url": f"/users/{them['id']}/avatar" if them["avatar_sig"] else None,
        "avatar_version": them["avatar_sig"],
        "since": them["created_at"],
        "songs": counts["songs"],
        "playlists": counts["playlists"],
        "played": counts["played"],
        "jam": live,
        "recent": [catalog.public(t) for t in recent[:12]],
    }


@router.get("/people/{person_id}/library")
def their_library(person_id: int, limit: int = 60, offset: int = 0,
                  user: dict = Depends(current_user)):
    """What they have kept, newest first — the same rows a library page anywhere draws."""
    _person(person_id)
    rows = db.all_(
        """select t.*, m.path, m.bytes, m.sha256, c.color as cover_color,
                  c.sha256 as cover_sha, li.added_at
             from library_items li
             join tracks t on t.id = li.track_id
             left join media m on m.track_id=t.id and m.role='canonical'
             left join covers c on c.id=t.cover_id
            where li.user_id=%s
            order by li.added_at desc
            limit %s offset %s""",
        (person_id, min(limit, 200), max(offset, 0)),
    )
    total = db.one("select count(*) n from library_items where user_id=%s",
                   (person_id,))["n"]
    return {"total": total, "items": [catalog.public(t) for t in rows]}


@router.get("/people/{person_id}/playlists")
def their_playlists(person_id: int, user: dict = Depends(current_user)):
    """Their lists, and whether you have kept any of them.

    Favourites is left out: it is the heart on a row rather than a list made to be
    read, and somebody's private one is not theirs to have been asked for.
    """
    _person(person_id)
    rows = db.all_(
        """select p.*,
                  (select count(*) from playlist_items i where i.playlist_id=p.id)
                    as items,
                  (select count(*) from playlist_saves s
                    where s.playlist_id=p.id and s.user_id=%s) as saved
             from playlists p
            where p.owner_id=%s and p.kind <> %s
            order by lower(p.name)""",
        (user["id"], person_id, FAVOURITES_KIND),
    )
    from .routes_library import with_cover

    return [{**with_cover(r), "saved": bool(r["saved"]),
             "open_edit": bool(r.get("open_edit"))} for r in rows]
