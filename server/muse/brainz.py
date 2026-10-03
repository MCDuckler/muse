"""MusicBrainz and ListenBrainz: the world's map of what goes with what.

The house's own recommender (recommend.py) knows twenty-five thousand songs and five
people's habits. That is enough to say what of *ours* goes with what, and nothing
like enough to say what is out there: a band nobody here has played can never come
up. These two services can. ListenBrainz keeps the listening of a few hundred
thousand people and publishes what falls out of it with no key and no quota beyond
manners — artists listened to in the same sitting, the recordings most played of an
artist, the records released this fortnight with their tags, radio by tag — and
MusicBrainz is the register that gives an artist an id and a genre.

Every answer is kept in `remote_cache` for days, because none of this changes by the
hour and both services ask to be asked gently (MusicBrainz: one request a second, by
address). A service that does not answer is not an error here: the caller gets what
was known, or nothing, and the page still has the house to go on.
"""
from __future__ import annotations

import json
import logging
import threading
import time
import unicodedata
import urllib.parse

import httpx

from . import db

log = logging.getLogger("muse.brainz")

LB = "https://api.listenbrainz.org/1"
LABS = "https://labs.api.listenbrainz.org"
MB = "https://musicbrainz.org/ws/2"
CAA = "https://coverartarchive.org"
UA = "wetowl/0.1 (https://github.com/MCDuckler/muse)"
TIMEOUT = 25

# The ListenBrainz Labs datasets are named after how they were made; these were the
# ones served in October 2026 and are checked against the listing when they stop.
SIMILAR_ARTISTS_ALGO = ("session_based_days_7500_session_300_contribution_5_threshold_10"
                        "_limit_100_filter_True_skip_30")

TTL = {
    "fresh": 6 * 3600,            # released this fortnight: twice a day is plenty
    "similar": 7 * 86400,
    "top": 7 * 86400,
    "tag": 86400,                 # radio by tag turns over, but not hourly
    "recording": 30 * 86400,      # a recording's name and artist do not change
    "artist": 30 * 86400,
    "genres": 30 * 86400,
}


class Unavailable(RuntimeError):
    """The service did not answer. Whatever asked carries on without it."""


# ------------------------------------------------------------------ the cache
def _cached(key: str, ttl: int):
    row = db.one(
        "select body from remote_cache where key=%s and fetched_at > now() - %s * interval '1 second'",
        (key, ttl))
    return row["body"] if row else None


def _stale(key: str):
    row = db.one("select body from remote_cache where key=%s", (key,))
    return row["body"] if row else None


def _store(key: str, body) -> None:
    db.run(
        """insert into remote_cache(key, body, fetched_at) values(%s,%s,now())
           on conflict (key) do update set body=excluded.body, fetched_at=now()""",
        (key, json.dumps(body)))


# MusicBrainz counts requests by address and declines everything over one a second;
# this process is the only one on this address, so one lock is the whole budget.
_mb_lock = threading.Lock()
_mb_last = 0.0
MB_GAP = 1.1


def _gently():
    """Wait out MusicBrainz's one-a-second before the next request to it."""
    global _mb_last
    with _mb_lock:
        wait = _mb_last + MB_GAP - time.monotonic()
        if wait > 0:
            time.sleep(wait)
        _mb_last = time.monotonic()


def _get(url: str, params: dict | None = None, *, kind: str, key: str | None = None):
    """A JSON answer, from the cache while it is fresh, from the service otherwise,
    and from the cache however old when the service is down."""
    key = key or (url + ("?" + urllib.parse.urlencode(sorted((params or {}).items()))
                         if params else ""))
    hit = _cached(key, TTL.get(kind, 3600))
    if hit is not None:
        return hit
    try:
        if url.startswith(MB):
            _gently()
        r = httpx.get(url, params=params or {}, timeout=TIMEOUT,
                      headers={"User-Agent": UA, "Accept": "application/json"})
        r.raise_for_status()
        body = r.json()
    except Exception as e:                       # network, 5xx, a page instead of JSON
        old = _stale(key)
        if old is not None:
            log.info("%s failed (%s); using what we had", url, e)
            return old
        raise Unavailable(f"{url}: {e}") from e
    _store(key, body)
    return body


def _text(url: str, params: dict | None = None, *, kind: str) -> str:
    key = url + "?" + urllib.parse.urlencode(sorted((params or {}).items()))
    hit = _cached(key, TTL.get(kind, 3600))
    if hit is not None:
        return hit["text"]
    try:
        _gently()
        r = httpx.get(url, params=params or {}, timeout=TIMEOUT, headers={"User-Agent": UA})
        r.raise_for_status()
        text = r.text
    except Exception as e:
        old = _stale(key)
        if old is not None:
            return old["text"]
        raise Unavailable(f"{url}: {e}") from e
    _store(key, {"text": text})
    return text


def fold(s: str | None) -> str:
    """Names compared the way a person would: no case, no accents, one space."""
    text = unicodedata.normalize("NFKD", (s or "").lower())
    text = "".join(c for c in text if not unicodedata.combining(c))
    return " ".join("".join(c if c.isalnum() else " " for c in text).split())


# ------------------------------------------------------------------ ListenBrainz
def fresh_releases(days: int = 14) -> list[dict]:
    """What came out in the last [days] days, everywhere, with the tags people have
    put on it and how many ListenBrainz listens it has had so far."""
    body = _get(f"{LB}/explore/fresh-releases/",
                {"days": min(max(int(days), 1), 90), "future": "false"}, kind="fresh")
    payload = body.get("payload", body) if isinstance(body, dict) else {}
    out = []
    for r in payload.get("releases") or []:
        out.append({
            "release_mbid": r.get("release_mbid"),
            "release_group_mbid": r.get("release_group_mbid"),
            "title": r.get("release_name"),
            "artist": r.get("artist_credit_name"),
            "artist_mbids": r.get("artist_mbids") or [],
            "release_date": r.get("release_date"),
            "record_type": (r.get("release_group_primary_type") or "").lower() or None,
            "tags": [t.lower() for t in (r.get("release_tags") or []) if t],
            "listens": int(r.get("listen_count") or 0),
            "cover": cover_url(r.get("caa_release_mbid"), r.get("caa_id")),
        })
    return out


def cover_url(caa_release_mbid: str | None, caa_id=None) -> str | None:
    if not caa_release_mbid:
        return None
    if caa_id:
        return f"{CAA}/release/{caa_release_mbid}/{caa_id}-250.jpg"
    return f"{CAA}/release/{caa_release_mbid}/front-250"


def similar_artists(artist_mbid: str, limit: int = 30, *, ask: bool = True) -> list[dict]:
    """Artists people listen to in the same sitting as this one, most often first.
    With [ask] off, only what was asked before: nothing goes over the wire."""
    key = f"lb:similar:{artist_mbid}"
    if not ask:
        body = _stale(key)
        if body is None:
            return []
    else:
        body = _get(f"{LABS}/similar-artists/json",
                    {"artist_mbids": artist_mbid, "algorithm": SIMILAR_ARTISTS_ALGO},
                    kind="similar", key=key)
    rows = body if isinstance(body, list) else []
    return [{"mbid": r.get("artist_mbid"), "name": r.get("name"),
             "score": int(r.get("score") or 0)}
            for r in rows[:limit] if r.get("artist_mbid") and r.get("name")]


def top_recordings(artist_mbid: str, limit: int = 10) -> list[dict]:
    """An artist's most listened recordings, as ListenBrainz counts them."""
    body = _get(f"{LB}/popularity/top-recordings-for-artist/{artist_mbid}",
                kind="top", key=f"lb:top:{artist_mbid}")
    rows = body if isinstance(body, list) else []
    return [{"recording_mbid": r.get("recording_mbid"),
             "title": r.get("recording_name"),
             "artist": r.get("artist_name"),
             "artists": [a.get("artist_credit_name") for a in (r.get("artists") or [])
                         if a.get("artist_credit_name")] or
                        ([r.get("artist_name")] if r.get("artist_name") else []),
             "length_ms": r.get("length"),
             "cover": cover_url(r.get("caa_release_mbid"), r.get("caa_id"))}
            for r in rows[:limit] if r.get("recording_name")]


def tag_radio(tag: str, count: int = 30, popular: tuple[int, int] = (35, 100)) -> list[str]:
    """Recording ids for a radio by tag: what ListenBrainz would play for "techno".
    [popular] is the band of popularity to draw from, 0 obscure to 100 everybody."""
    body = _get(f"{LB}/lb-radio/tags",
                {"tag": tag, "operator": "OR", "pop_begin": popular[0],
                 "pop_end": popular[1], "count": count},
                kind="tag", key=f"lb:tag:{fold(tag)}:{popular[0]}-{popular[1]}:{count}")
    rows = body if isinstance(body, list) else []
    return [r["recording_mbid"] for r in rows if r.get("recording_mbid")]


def recordings(mbids: list[str]) -> dict[str, dict]:
    """Names for recording ids, fifty at a time: title, artist credit, release."""
    out: dict[str, dict] = {}
    todo = [m for m in dict.fromkeys(mbids) if m]
    for i in range(0, len(todo), 50):
        chunk = todo[i:i + 50]
        body = _get(f"{LB}/metadata/recording/",
                    {"recording_mbids": ",".join(chunk), "inc": "artist release"},
                    kind="recording", key="lb:rec:" + ",".join(chunk))
        if not isinstance(body, dict):
            continue
        for mbid, m in body.items():
            rec = m.get("recording") or {}
            art = m.get("artist") or {}
            rel = m.get("release") or {}
            names = [a.get("name") for a in (art.get("artists") or []) if a.get("name")]
            out[mbid] = {
                "title": rec.get("name"),
                "artists": names or ([art.get("name")] if art.get("name") else []),
                "album": rel.get("name"),
                "length_ms": rec.get("length"),
                "cover": cover_url(rel.get("caa_release_mbid"), rel.get("caa_id")),
            }
    return out


# ------------------------------------------------------------------ MusicBrainz
def artist(name: str, *, ask: bool = True) -> dict | None:
    """The MusicBrainz entry for an artist by name, with its genres: the id that lets
    ListenBrainz be asked about them. The best-scored exact name wins; a name that
    only matches loosely is not taken, since "Low" is not "Low Roar".

    With [ask] off, only what was asked before. MusicBrainz allows one request a
    second, so a page that is being looked at never asks; the overnight build does.
    """
    want = fold(name)
    if not want:
        return None
    key = f"mb:artist:{want}"
    hit = _stale(key) if not ask else _cached(key, TTL["artist"])
    if hit is not None:
        return hit or None
    if not ask:
        return None
    try:
        found = _get(f"{MB}/artist", {"query": f'artist:"{name}"', "fmt": "json",
                                      "limit": 5}, kind="artist", key=key + ":q")
    except Unavailable:
        return None
    rows = [a for a in (found.get("artists") or []) if fold(a.get("name")) == want]
    if not rows:
        rows = [a for a in (found.get("artists") or [])
                if any(fold(al.get("name")) == want for al in a.get("aliases") or [])]
    if not rows:
        _store(key, {})
        return None
    rows.sort(key=lambda a: -int(a.get("score") or 0))
    pick = rows[0]
    try:
        full = _get(f"{MB}/artist/{pick['id']}", {"inc": "genres", "fmt": "json"},
                    kind="artist", key=key + ":full")
    except Unavailable:
        full = {}
    genres = sorted(full.get("genres") or [], key=lambda g: -int(g.get("count") or 0))
    out = {"mbid": pick["id"], "name": pick.get("name") or name,
           "genres": [g["name"].lower() for g in genres if g.get("name")][:8]}
    _store(key, out)
    return out


def all_genres() -> list[str]:
    """Every genre MusicBrainz knows, about two thousand names, one line each."""
    text = _text(f"{MB}/genre/all", {"fmt": "txt"}, kind="genres")
    return [line.strip() for line in text.splitlines() if line.strip()]
