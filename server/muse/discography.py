"""What a record and an artist actually contain, rather than what we happen to hold.

An album page built only from the library shows the four songs somebody once added and
calls that the album. The rest of the record exists; we just have not downloaded it. So
the shape of a release comes from a metadata service and the library is matched into
it — every track in its place, the ones we have playable, the ones we do not offered.

Deezer, for the same reasons enrichment already uses it: no key, no quota, real covers,
release dates, and an ISRC one hop away — which is the identifier that says the song we
would download is the song the album lists.
"""
from __future__ import annotations

import json
import logging
import re
import unicodedata

import httpx

from . import db

log = logging.getLogger("muse.discography")

BASE = "https://api.deezer.com"
UA = "muse/0.1 (personal music server)"
TIMEOUT = 20

# How long an answer stays good. A tracklist is finished the day it is published; an
# artist's list of records is not, but it does not change hourly either.
TTL = {
    "album": 30 * 24 * 3600,
    "artist": 7 * 24 * 3600,
    "albums": 12 * 3600,
    "top": 3 * 24 * 3600,
    "search": 7 * 24 * 3600,
}


class Unavailable(RuntimeError):
    """The service did not answer. The page still has a library to show."""


def _cached(key: str, ttl: int) -> dict | None:
    row = db.one(
        "select body from remote_cache where key=%s and fetched_at > now() - %s * interval '1 second'",
        (key, ttl),
    )
    return row["body"] if row else None


def _store(key: str, body: dict) -> None:
    db.run(
        """insert into remote_cache(key, body, fetched_at) values(%s,%s,now())
           on conflict (key) do update set body=excluded.body, fetched_at=now()""",
        (key, json.dumps(body)),
    )


def _get(path: str, params: dict | None = None, *, kind: str = "search") -> dict:
    key = path + ("?" + "&".join(f"{k}={v}" for k, v in sorted((params or {}).items()))
                  if params else "")
    hit = _cached(key, TTL.get(kind, 3600))
    if hit is not None:
        return hit
    try:
        r = httpx.get(BASE + path, params=params or {},
                      headers={"User-Agent": UA}, timeout=TIMEOUT)
        r.raise_for_status()
        body = r.json()
    except Exception as e:                       # network, 403, malformed — same answer
        stale = db.one("select body from remote_cache where key=%s", (key,))
        if stale:
            log.info("deezer %s failed (%s); using what we had", path, e)
            return stale["body"]
        raise Unavailable(str(e)) from e
    if isinstance(body, dict) and body.get("error"):
        raise Unavailable(str(body["error"].get("message") or body["error"]))
    _store(key, body)
    return body


# ------------------------------------------------------------------ matching
def norm(s: str | None) -> str:
    """Compare titles the way a person would: ignoring case, accents and decoration.

    "Awake (Deluxe Version)" and "Awake" are the same record with a different cut, and a
    library that spells one of them with an en dash should still find the other.
    """
    text = unicodedata.normalize("NFKD", (s or "").lower())
    text = "".join(c for c in text if not unicodedata.combining(c))
    # A bracketed aside that only says which pressing this is — "(2017 Remaster)",
    # "(Deluxe Version)" — is not part of the record's name. One that says what it is —
    # "(Live)", "(Remixes)" — is, and stays.
    text = re.sub(r"[\[(][^\])]*\b(deluxe|remaster(ed)?|expanded|anniversary|bonus|"
                  r"explicit|edition|version)\b[^\])]*[\])]", " ", text)
    text = re.sub(r"[^a-z0-9]+", " ", text)
    return text.strip()


def _score_album(candidate: dict, album: str, artist: str | None) -> float:
    title, want = norm(candidate.get("title")), norm(album)
    if not title or not want:
        return 0.0
    score = 1.0 if title == want else (0.6 if want in title or title in want else 0.0)
    if artist:
        # Wrong artist is not a weaker match, it is a different record. Searching for
        # Bowie's "Heroes" returns a page of one-track covers by other people, and
        # every one of them has the title exactly right.
        theirs = norm((candidate.get("artist") or {}).get("name"))
        mine = norm(artist)
        if theirs == mine:
            score += 0.5
        elif theirs and (mine in theirs or theirs in mine):
            score += 0.2
        elif theirs == "various artists":
            score += 0.0
        else:
            return 0.0
    # A single and the album it came from share a title and an artist. The record is
    # almost always what somebody means by the album page, so it wins the tie.
    kind = candidate.get("record_type")
    score += {"album": 0.15, "ep": 0.05}.get(kind, 0.0)
    if kind == "single":
        score -= 0.1
    # And within the same kind, the fuller listing — but not the deluxe reissue over
    # the record itself, so a title that stays close to what was asked for wins first.
    score += min((candidate.get("nb_tracks") or 0), 30) / 1000.0
    score -= min(abs(len(candidate.get("title") or "") - len(album)), 40) / 1000.0
    return score


# ------------------------------------------------------------------ lookups
def _quotable(s: str | None) -> str:
    """Deezer's field syntax is quote-delimited, so a title that contains a quote —
    "Heroes", "s/t" — ends the term early and matches something else entirely."""
    return re.sub(r'["\\]', " ", s or "").strip()


def find_album(album: str, artist: str | None) -> dict | None:
    """The release this library album is a part of."""
    if not album:
        return None
    # Both phrasings, always. The fielded form is precise when it works, but Deezer
    # answers album:"Heroes" artist:"David Bowie" with ten one-track covers by other
    # people and none of Bowie's records; the plain words find the album first.
    queries = [f'album:"{_quotable(album)}"'
               + (f' artist:"{_quotable(artist)}"' if artist else "")]
    plain = f"{_quotable(album)} {_quotable(artist)}".strip()
    if plain:
        queries.append(plain)

    seen, data = set(), []
    for q in queries:
        for c in _get("/search/album", {"q": q, "limit": 10},
                      kind="search").get("data") or []:
            if c.get("id") in seen:
                continue
            seen.add(c.get("id"))
            data.append(c)

    best, best_score = None, 0.0
    for c in data:
        s = _score_album(c, album, artist)
        if s > best_score:
            best, best_score = c, s
    return best if best_score >= 0.6 else None


def album(album_id: str | int) -> dict:
    """A record and its running order."""
    raw = _get(f"/album/{album_id}", kind="album")
    tracks = []
    for pos, t in enumerate((raw.get("tracks") or {}).get("data") or [], start=1):
        tracks.append({
            "pos": pos,
            "remote_id": str(t.get("id")),
            "title": t.get("title"),
            "artists": [(t.get("artist") or {}).get("name")]
                       if (t.get("artist") or {}).get("name") else [],
            "duration_ms": (t.get("duration") or 0) * 1000 or None,
        })
    return {
        "remote_id": str(raw.get("id")),
        "title": raw.get("title"),
        "artist": (raw.get("artist") or {}).get("name"),
        "cover": raw.get("cover_xl") or raw.get("cover_big"),
        "release_date": raw.get("release_date"),
        "record_type": raw.get("record_type"),
        "total": raw.get("nb_tracks") or len(tracks),
        "tracks": tracks,
    }


def find_artist(name: str) -> dict | None:
    if not name:
        return None
    data = _get("/search/artist", {"q": _quotable(name), "limit": 8},
                kind="search").get("data") or []
    want = norm(name)
    exact = [a for a in data if norm(a.get("name")) == want]
    pick = max(exact or data, key=lambda a: a.get("nb_fan") or 0, default=None)
    if not pick:
        return None
    return {
        "remote_id": str(pick.get("id")),
        "name": pick.get("name"),
        "image": pick.get("picture_xl") or pick.get("picture_big")
                 or pick.get("picture_medium"),
        "albums": pick.get("nb_album"),
        "fans": pick.get("nb_fan"),
    }


def artist_albums(artist_id: str | int, limit: int = 60) -> list[dict]:
    """Everything they have put out, newest first."""
    data = _get(f"/artist/{artist_id}/albums", {"limit": limit},
                kind="albums").get("data") or []
    out = [{
        "remote_id": str(a.get("id")),
        "title": a.get("title"),
        "cover": a.get("cover_big") or a.get("cover_medium"),
        "release_date": a.get("release_date"),
        "record_type": a.get("record_type"),
        "tracks": a.get("nb_tracks"),
    } for a in data]
    out.sort(key=lambda a: a.get("release_date") or "", reverse=True)
    return out


def artist_top(artist_id: str | int, limit: int = 15) -> list[dict]:
    data = _get(f"/artist/{artist_id}/top", {"limit": limit},
                kind="top").get("data") or []
    return [{
        "remote_id": str(t.get("id")),
        "title": t.get("title"),
        "artists": [(t.get("artist") or {}).get("name")]
                   if (t.get("artist") or {}).get("name") else [],
        "album": (t.get("album") or {}).get("title"),
        "cover": (t.get("album") or {}).get("cover_medium"),
        "duration_ms": (t.get("duration") or 0) * 1000 or None,
    } for t in data]


def track_isrc(track_id: str | int) -> str | None:
    """Worth one request when we are about to download something: an ISRC is what says
    the file we fetch is the recording the album lists."""
    try:
        return (_get(f"/track/{track_id}", kind="album") or {}).get("isrc")
    except Unavailable:
        return None
