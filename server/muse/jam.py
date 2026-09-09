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


def vote_skip(jam_id: int, track_id: int, user_id: int) -> dict:
    """One vote each, and a skip when more than half of the people here want it."""
    db.run(
        """insert into jam_skip_votes(jam_id, track_id, user_id) values(%s,%s,%s)
           on conflict do nothing""",
        (jam_id, track_id, user_id),
    )
    votes = db.one(
        "select count(*) n from jam_skip_votes where jam_id=%s and track_id=%s",
        (jam_id, track_id),
    )["n"]
    present = db.one(
        f"""select count(*) n from jam_members
             where jam_id=%s
               and extract(epoch from now() - last_seen) < {ONLINE_SECONDS}""",
        (jam_id,),
    )["n"] or 1
    needed = max(2, present // 2 + 1)
    return {"votes": votes, "needed": needed, "present": present,
            "passed": votes >= needed}


def clear_votes(jam_id: int, track_id: int | None = None) -> None:
    if track_id is None:
        db.run("delete from jam_skip_votes where jam_id=%s", (jam_id,))
    else:
        db.run("delete from jam_skip_votes where jam_id=%s and track_id=%s",
               (jam_id, track_id))


def public(jam: dict, user_id: int) -> dict:
    people = members(jam["id"])
    return {
        "id": jam["id"],
        "code": jam["code"],
        "queue_id": jam["queue_id"],
        "host": next((p["name"] for p in people if p["host"]), None),
        "is_host": jam["host_id"] == user_id,
        "guests_can_add": jam["guests_can_add"],
        "guests_can_skip": jam["guests_can_skip"],
        "members": people,
        "listening": sum(1 for p in people if p["online"]),
        "started_at": jam["created_at"],
        "ended": jam["ended_at"] is not None,
    }
