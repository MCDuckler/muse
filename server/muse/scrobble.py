"""Scrobbling: what is played here, written into a listening diary kept elsewhere.

ListenBrainz first, because it asks for nothing but a token the person pastes in. A play
worth reporting goes into an outbox and is sent from there — a handful at a time, in the
background, after the listen itself has been recorded — so the diary being slow or down
never gets between somebody and the next song, and what could not be sent tonight goes
with tomorrow's first play.

What counts is ListenBrainz's own rule, which is Last.fm's before it: the whole song, or
four minutes of it, or half of it, whichever comes first.
"""
from __future__ import annotations

import logging
import threading

import httpx

from . import db

log = logging.getLogger("muse.scrobble")

API = "https://api.listenbrainz.org"
CLIENT = "WetOwl"

# Tried this many times and then left alone: a listen the service keeps refusing is a
# listen with something wrong with it, not one to retry for ever.
GIVE_UP_AFTER = 8
BATCH = 50


class Refused(Exception):
    """The service said no, in words worth passing on."""


def _call(method: str, path: str, token: str, json: dict | None = None) -> httpx.Response:
    return httpx.request(method, f"{API}{path}", json=json, timeout=15,
                         headers={"Authorization": f"Token {token}"})


def whose(token: str) -> str:
    """The account a token belongs to — which is also how a token is checked."""
    try:
        r = _call("GET", "/1/validate-token", token)
    except httpx.HTTPError as e:
        raise Refused(f"ListenBrainz could not be reached: {e}") from e
    data = r.json() if r.headers.get("content-type", "").startswith("application/json") else {}
    if r.status_code != 200 or not data.get("valid"):
        raise Refused("ListenBrainz does not know that token")
    return data.get("user_name") or "you"


def counts(ms_played: int, duration_ms: int | None, completed: bool) -> bool:
    if completed:
        return True
    if ms_played >= 240_000:
        return True
    return bool(duration_ms) and ms_played * 2 >= duration_ms


def owe(user_id: int, listen_id: int) -> None:
    db.run("insert into scrobbles(listen_id, user_id) values(%s,%s) on conflict do nothing",
           (listen_id, user_id))


def _as_listen(row: dict) -> dict:
    info = {"media_player": CLIENT, "submission_client": CLIENT}
    if row["duration_ms"]:
        info["duration_ms"] = row["duration_ms"]
    if row["isrc"]:
        info["isrc"] = row["isrc"]
    if len(row["artists"] or []) > 1:
        info["artist_names"] = list(row["artists"])
    meta = {
        "artist_name": ", ".join(row["artists"] or []) or "Unknown artist",
        "track_name": row["title"],
        "additional_info": info,
    }
    if row["album"]:
        meta["release_name"] = row["album"]
    return {"listened_at": int(row["started_at"].timestamp()), "track_metadata": meta}


def send_what_is_owed(user_id: int) -> int:
    """Everything still owed for one person, oldest first. Returns how many went."""
    account = db.one("select listenbrainz_token as token from users where id=%s", (user_id,))
    token = (account or {}).get("token")
    if not token:
        return 0
    owed = db.all_(
        """select s.listen_id, l.started_at, t.title, t.artists, t.album,
                  t.duration_ms, t.isrc
             from scrobbles s
             join listens l on l.id = s.listen_id
             join tracks t on t.id = l.track_id
            where s.user_id = %s and s.sent_at is null and s.attempts < %s
            order by l.started_at limit %s""",
        (user_id, GIVE_UP_AFTER, BATCH))
    if not owed:
        return 0
    ids = [r["listen_id"] for r in owed]
    error = None
    try:
        r = _call("POST", "/1/submit-listens", token,
                  {"listen_type": "import" if len(owed) > 1 else "single",
                   "payload": [_as_listen(r) for r in owed]})
        if r.status_code != 200:
            error = f"{r.status_code}: {r.text[:200]}"
    except httpx.HTTPError as e:
        error = str(e)[:200]

    if error:
        log.warning("scrobble for user %s not sent: %s", user_id, error)
        db.run("update scrobbles set attempts = attempts + 1, error = %s "
               "where listen_id = any(%s)", (error, ids))
        return 0
    db.run("update scrobbles set sent_at = now(), error = null where listen_id = any(%s)",
           (ids,))
    return len(ids)


def after_a_listen(user_id: int, listen_id: int, ms_played: int,
                   duration_ms: int | None, completed: bool) -> None:
    """Called once the listen itself is safely written. Never raises, never waits."""
    try:
        if not counts(ms_played, duration_ms, completed):
            return
        has = db.one("select listenbrainz_token is not null as on from users where id=%s",
                     (user_id,))
        if not has or not has["on"]:
            return
        owe(user_id, listen_id)
        threading.Thread(target=_quietly, args=(user_id,), daemon=True).start()
    except Exception:                      # noqa: BLE001 — a diary never breaks a play
        log.exception("could not queue a scrobble")


def _quietly(user_id: int) -> None:
    try:
        send_what_is_owed(user_id)
    except Exception:                      # noqa: BLE001
        log.exception("scrobbling failed")


def standing(user_id: int) -> dict:
    """Where things stand, for the settings page. The token itself never leaves."""
    u = db.one("select listenbrainz_token is not null as on, listenbrainz_name as name "
               "from users where id=%s", (user_id,)) or {}
    tally = db.one(
        """select count(*) filter (where sent_at is not null) as sent,
                  count(*) filter (where sent_at is null and attempts < %s) as owed,
                  max(sent_at) as last_sent,
                  (array_agg(error order by listen_id desc)
                     filter (where error is not null and sent_at is null))[1] as error
             from scrobbles where user_id=%s""",
        (GIVE_UP_AFTER, user_id))
    return {"listenbrainz": {
        "connected": bool(u.get("on")),
        "name": u.get("name"),
        "sent": tally["sent"], "owed": tally["owed"],
        "last_sent": tally["last_sent"], "error": tally["error"],
    }}
