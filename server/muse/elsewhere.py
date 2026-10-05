"""What somebody's other services know they play.

A mirrored library says what somebody kept on Spotify; it does not say what they play
there, and the house has heard only a few weeks of anybody. Two services that know
say so, and both are asked overnight (by discover.build_for) and kept a day:

  Spotify       the account's top artists and top tracks over the last month, half
                year and years, and the last fifty songs played — the user-top-read
                and user-read-recently-played scopes. A link made before those were
                asked for is refused them, and is simply not used until it is made
                again.
  ListenBrainz  the linked name's most listened artists and recordings, this month and
                ever — the diary this house scrobbles to, and whatever else writes to it.

recommend.taste reads what was kept (`known`), never the network: an act somebody plays
elsewhere counts on the act's score, a song they play there that is in the catalog on
the song's, and the ones played lately can seed a mix (`lately`).
"""
from __future__ import annotations

import logging

import httpx

from . import brainz, db, spotify

log = logging.getLogger("muse.elsewhere")

TTL = 86400
KEY = "taste:elsewhere:{}"

# How much a place in a top list counts, by how far back the list looks. An act at the
# top of all of them is somebody's favourite; a song there is one they wore out.
ARTIST_RANGES = {"short_term": 2.5, "medium_term": 3.0, "long_term": 4.0}
TRACK_RANGES = {"short_term": 1.2, "medium_term": 0.9, "long_term": 0.6}
LB_ARTIST_RANGES = {"month": 2.5, "all_time": 3.0}
LB_TRACK_RANGES = {"month": 1.0, "all_time": 0.5}
TRACK_MOST = 1.5
TOP = 50


def _rank(n: int) -> float:
    return max(0.0, 1.0 - n / (TOP + 10))


def _cfg():
    from . import deps
    try:
        return deps.cfg()
    except RuntimeError:
        return None


# ------------------------------------------------------------------ the catalog
def _find(title: str | None, artists: list[str] | None) -> int | None:
    """A song named by another service, if the catalog has it — by name only: what is
    not here is not fetched for this."""
    from .recommend import search_norm
    if not title:
        return None
    want = [brainz.fold(a) for a in artists or [] if a]
    for r in db.all_(
            """select id, artists from tracks where norm_title = %s and state <> 'failed'
                order by (state = 'ready') desc, id limit 12""", (search_norm(title),)):
        have = [brainz.fold(a) for a in r["artists"] or []]
        if not want or any(w == h or w in h or h in w for w in want for h in have if h):
            return r["id"]
    return None


def _spotify_ids(ids: list[str]) -> dict[str, int]:
    """Spotify track ids the house has matched before (sync's matches)."""
    if not ids:
        return {}
    return {r["remote_id"]: r["track_id"] for r in db.all_(
        """select remote_id, track_id from matches
            where remote_kind = 'spotify' and remote_id = any(%s) and track_id is not null""",
        (ids,))}


# ------------------------------------------------------------------ Spotify
def _from_spotify(user_id: int) -> dict | None:
    cfg = _cfg()
    if cfg is None or not db.one(
            "select 1 from provider_accounts where user_id = %s and provider = 'spotify'",
            (user_id,)):
        return None
    out: dict = {"artists": {}, "tracks": {}, "lately": {}, "genres": {}}
    asked = 0
    for span, w in ARTIST_RANGES.items():
        try:
            page = spotify._get(cfg, user_id, "/me/top/artists", time_range=span, limit=TOP)
        except (spotify.NotLinked, spotify.NotConfigured) as e:
            log.info("spotify for %s: %s", user_id, e)
            return None              # signed out: nothing else will answer either
        except Exception as e:  # noqa: BLE001 — an old link without the scope: 403
            log.info("spotify top artists for %s: %s", user_id, e)
            continue
        asked += 1
        for n, a in enumerate(page.get("items") or []):
            name = (a.get("name") or "").lower()
            if name:
                out["artists"][name] = out["artists"].get(name, 0.0) + w * _rank(n)
            for g in a.get("genres") or []:
                g = brainz.fold(g)
                if g:
                    out["genres"][g] = out["genres"].get(g, 0) + 1
    tracks: list[tuple[dict, float, bool]] = []
    for span, w in TRACK_RANGES.items():
        try:
            page = spotify._get(cfg, user_id, "/me/top/tracks", time_range=span, limit=TOP)
        except Exception as e:  # noqa: BLE001
            log.info("spotify top tracks for %s: %s", user_id, e)
            continue
        asked += 1
        for n, item in enumerate(page.get("items") or []):
            tracks.append((item, w * _rank(n), span == "short_term"))
    try:
        page = spotify._get(cfg, user_id, "/me/player/recently-played", limit=50)
        asked += 1
        for n, entry in enumerate(page.get("items") or []):
            tracks.append(((entry or {}).get("track") or {}, 0.0, True))
    except Exception as e:  # noqa: BLE001
        log.info("spotify recently played for %s: %s", user_id, e)
    if not asked:
        return None
    known = _spotify_ids([i.get("id") for i, _, _ in tracks if i.get("id")])
    for item, w, now in tracks:
        tid = known.get(item.get("id")) or _find(
            item.get("name"), [a.get("name") for a in item.get("artists") or []])
        if not tid:
            continue
        if w:
            out["tracks"][tid] = min(TRACK_MOST, out["tracks"].get(tid, 0.0) + w)
        if now:
            out["lately"][tid] = max(out["lately"].get(tid, 0.0), 0.6)
    return out


# ------------------------------------------------------------------ ListenBrainz
def _lb(name: str, what: str, span: str) -> list[dict]:
    r = httpx.get(f"{brainz.LB}/stats/user/{name}/{what}",
                  params={"range": span, "count": TOP}, timeout=brainz.TIMEOUT,
                  headers={"User-Agent": brainz.UA})
    if r.status_code == 204:          # nothing worked out for that range yet
        return []
    r.raise_for_status()
    return ((r.json() or {}).get("payload") or {}).get(what) or []


def _from_listenbrainz(user_id: int) -> dict | None:
    row = db.one("select listenbrainz_name from users where id = %s", (user_id,))
    name = (row or {}).get("listenbrainz_name")
    if not name:
        return None
    out: dict = {"artists": {}, "tracks": {}, "lately": {}, "genres": {}}
    asked = 0
    for span, w in LB_ARTIST_RANGES.items():
        try:
            rows = _lb(name, "artists", span)
        except Exception as e:  # noqa: BLE001
            log.info("listenbrainz artists for %s: %s", name, e)
            continue
        asked += 1
        for n, a in enumerate(rows):
            k = (a.get("artist_name") or "").lower()
            if k:
                out["artists"][k] = out["artists"].get(k, 0.0) + w * _rank(n)
    for span, w in LB_TRACK_RANGES.items():
        try:
            rows = _lb(name, "recordings", span)
        except Exception as e:  # noqa: BLE001
            log.info("listenbrainz recordings for %s: %s", name, e)
            continue
        asked += 1
        for n, rec in enumerate(rows):
            tid = _find(rec.get("track_name"), [rec.get("artist_name")])
            if not tid:
                continue
            out["tracks"][tid] = min(TRACK_MOST, out["tracks"].get(tid, 0.0) + w * _rank(n))
            if span == "month":
                out["lately"][tid] = max(out["lately"].get(tid, 0.0), 0.4 + 0.4 * _rank(n))
    return out if asked else None


# ------------------------------------------------------------------ kept
def refresh(user_id: int, *, force: bool = False) -> dict:
    """Ask the services again, once a day unless [force]. What could not be asked keeps
    what was known before."""
    key = KEY.format(user_id)
    if not force and brainz._cached(key, TTL) is not None:
        return known(user_id)
    old = brainz._stale(key) or {}
    merged: dict = {"artists": {}, "tracks": {}, "lately": {}, "genres": {}, "from": []}
    for service, fn in (("spotify", _from_spotify), ("listenbrainz", _from_listenbrainz)):
        try:
            got = fn(user_id)
        except Exception as e:  # noqa: BLE001
            log.info("%s for %s: %s", service, user_id, e)
            got = None
        if got is None:
            got = (old.get("by") or {}).get(service)
        if not got:
            continue
        merged["from"].append(service)
        merged.setdefault("by", {})[service] = got
        for part in ("artists", "tracks", "genres"):
            for k, v in got.get(part, {}).items():
                merged[part][str(k)] = merged[part].get(str(k), 0) + v
        for k, v in got.get("lately", {}).items():
            merged["lately"][str(k)] = max(merged["lately"].get(str(k), 0), v)
    brainz._store(key, merged)
    return known(user_id)


def known(user_id: int) -> dict:
    """What was kept: acts and songs by weight, songs played lately, genres counted."""
    body = brainz._stale(KEY.format(user_id)) or {}
    return {"artists": {k: float(v) for k, v in (body.get("artists") or {}).items()},
            "tracks": {int(k): float(v) for k, v in (body.get("tracks") or {}).items()},
            "genres": {k: int(v) for k, v in (body.get("genres") or {}).items()},
            "from": list(body.get("from") or [])}


def lately(user_id: int) -> dict[int, float]:
    body = brainz._stale(KEY.format(user_id)) or {}
    return {int(k): float(v) for k, v in (body.get("lately") or {}).items()}
