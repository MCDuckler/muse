"""Listening together: one queue, several people, different rooms.

A jam is a live pass to somebody else's queue. The host keeps playing — their device is
the one making sound — and everyone who joins can see what is on, put something on next,
and vote to skip what nobody is enjoying. There is no separate account system for it:
the people who can join are the people who already have logins here.
"""
from __future__ import annotations

import secrets
import string

from . import db

ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"      # no I/O/0/1: these get read aloud
# How long somebody stays "here" without checking in. Long enough to reload the page,
# walk through a tunnel, or put the phone away for a minute — a jam that drops people
# the moment their browser refreshes is not a room anyone can stay in.
ONLINE_SECONDS = 300


def _code() -> str:
    return "".join(secrets.choice(ALPHABET) for _ in range(6))


def start(host_id: int, queue_id: int) -> dict:
    """Open the host's queue to other people. Starting twice returns the same jam, so
    tapping the button again is not a way to end up with two."""
    live = db.one(
        """select * from jams
            where host_id=%s and queue_id=%s and ended_at is null""",
        (host_id, queue_id),
    )
    if live:
        return live

    for _ in range(6):                    # collisions are vanishingly rare; handle anyway
        code = _code()
        if not db.one("select 1 from jams where code=%s and ended_at is null", (code,)):
            break
    jam = db.one(
        """insert into jams(code, host_id, queue_id) values(%s,%s,%s) returning *""",
        (code, host_id, queue_id),
    )
    join(jam["id"], host_id)
    return jam


def by_code(code: str) -> dict | None:
    return db.one("select * from jams where upper(code)=upper(%s) and ended_at is null",
                  (code.strip(),))


def get(jam_id: int) -> dict | None:
    return db.one("select * from jams where id=%s", (jam_id,))


def join(jam_id: int, user_id: int) -> None:
    db.run(
        """insert into jam_members(jam_id, user_id) values(%s,%s)
           on conflict (jam_id, user_id) do update set last_seen=now()""",
        (jam_id, user_id),
    )


def leave(jam_id: int, user_id: int) -> None:
    db.run("delete from jam_members where jam_id=%s and user_id=%s", (jam_id, user_id))


def end(jam_id: int) -> None:
    db.run("update jams set ended_at=now() where id=%s and ended_at is null", (jam_id,))


def touch(jam_id: int, user_id: int) -> None:
    db.run("update jam_members set last_seen=now() where jam_id=%s and user_id=%s",
           (jam_id, user_id))


def members(jam_id: int) -> list[dict]:
    rows = db.all_(
        f"""select m.user_id, u.name, m.joined_at,
                   extract(epoch from now() - m.last_seen) < {ONLINE_SECONDS} as online,
                   (j.host_id = m.user_id) as host
              from jam_members m
              join users u on u.id = m.user_id
              join jams j on j.id = m.jam_id
             where m.jam_id=%s
             order by (j.host_id = m.user_id) desc, m.joined_at""",
        (jam_id,),
    )
    return rows


def live_for(user_id: int) -> dict | None:
    """The jam this person is in, hosting or otherwise."""
    return db.one(
        """select j.* from jams j
             join jam_members m on m.jam_id = j.id
            where m.user_id=%s and j.ended_at is null
            order by j.created_at desc limit 1""",
        (user_id,),
    )


def may_touch_queue(queue_id: int, user_id: int) -> dict | None:
    """The jam that gives this person a say over that queue, if any."""
    return db.one(
        """select j.* from jams j
             join jam_members m on m.jam_id = j.id
            where j.queue_id=%s and m.user_id=%s and j.ended_at is null
            limit 1""",
        (queue_id, user_id),
    )


def invite(jam_id: int, user_id: int) -> None:
    """Add somebody to a jam without them typing anything.

    Everyone here already has an account on this server, so the code is a way of
    reaching somebody who is not in the room — not the way in. Tapping a name is.
    """
    db.run(
        """insert into jam_members(jam_id, user_id) values(%s,%s)
           on conflict (jam_id, user_id) do update set last_seen=now()""",
        (jam_id, user_id),
    )


def public(jam: dict, user_id: int) -> dict:
    people = members(jam["id"])
    return {
        "id": jam["id"],
        "code": jam["code"],
        "queue_id": jam["queue_id"],
        "host": next((p["name"] for p in people if p["host"]), None),
        "is_host": jam["host_id"] == user_id,
        "members": people,
        "listening": sum(1 for p in people if p["online"]),
        "started_at": jam["created_at"],
        "ended": jam["ended_at"] is not None,
    }


# ------------------------------------------------------------------ transport
def set_playback(jam_id: int, track_id: int | None, position_ms: int,
                 playing: bool) -> dict:
    """Record what the host's player is doing, as of now.

    Only the host writes this. `at` is the server's clock rather than the device's:
    phones disagree about the time by seconds, and the whole point of the row is to
    work out how far the music has moved since it was written.
    """
    return db.one(
        """insert into jam_playback(jam_id, track_id, position_ms, playing, at)
           values(%s,%s,%s,%s, now())
           on conflict (jam_id) do update
             set track_id=excluded.track_id, position_ms=excluded.position_ms,
                 playing=excluded.playing, at=now()
           returning *""",
        (jam_id, track_id, max(0, int(position_ms)), bool(playing)),
    )


def playback(jam_id: int) -> dict | None:
    """Where the music is, with how old that answer is."""
    row = db.one(
        """select track_id, position_ms, playing,
                  (extract(epoch from now() - at) * 1000)::int as age_ms
             from jam_playback where jam_id=%s""",
        (jam_id,),
    )
    if not row:
        return None
    return {
        "track_id": row["track_id"],
        "position_ms": row["position_ms"],
        "playing": row["playing"],
        "age_ms": max(0, row["age_ms"] or 0),
    }
