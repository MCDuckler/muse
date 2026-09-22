"""One search across everything, answering in one shape.

Search used to be four lists one under another: your library, then YouTube Music, then
SoundCloud, then Bandcamp. On a phone the third of those is off the bottom of the
screen, which is the same as not being there — and the question somebody is actually
asking is "where is this song", not "what does SoundCloud have".

So: one ranked list of one kind of thing. Every row — a song in your library, an album
on YouTube Music, an artist on Spotify — is the same shape, carries a picture, and says
which service it came from. Narrowing to one service is still a tap away; it just is not
the only way to read the results any more.
"""
from __future__ import annotations

import difflib
import logging
import re
from concurrent.futures import ThreadPoolExecutor
from urllib.parse import quote

from . import catalog, db, sources, spotify, ytm

log = logging.getLogger("muse.search")

# Where results can come from. "library" is this box; the rest are somebody else's.
PLACES = ("library", "ytmusic", "youtube", "spotify", "soundcloud", "bandcamp")
KINDS = ("song", "album", "artist", "video")

# How much a result is worth before anything is known about how well it matches.
#
# The library first: a song you already have is one tap from playing, and one you do not
# is a download. Then the two that can be searched for anything, then the two that are
# good when they have it.
# A plain video last of all: when the same thing exists as a proper song, the song is the
# better copy — tagged, the right length, no talking at the start.
WEIGHT = {"library": 0.32, "ytmusic": 0.12, "spotify": 0.10,
          "soundcloud": 0.04, "bandcamp": 0.04, "youtube": 0.0}

# Nothing from one service may fill the list when everything was asked for.
PER_PLACE = 8


def _norm(s: str | None) -> str:
    return re.sub(r"[^a-z0-9 ]+", " ", (s or "").lower()).strip()


def _score(q: str, title: str, subtitle: str, place: str, known: bool) -> float:
    """How well this row answers the question, from 0 to about 1.5.

    Similarity against the title first, and against "title artist" second, so that
    typing a band's name does not rank every song of theirs above the one song actually
    called that.
    """
    want, got, both = _norm(q), _norm(title), _norm(f"{title} {subtitle}")
    if not want:
        return 0.0
    best = max(
        difflib.SequenceMatcher(None, want, got).ratio(),
        difflib.SequenceMatcher(None, want, both).ratio() * 0.96,
    )
    if got == want:
        best = 1.0
    elif got.startswith(want) or want in got:
        best = max(best, 0.86)
    elif want in both:
        best = max(best, 0.74)
    return best + WEIGHT.get(place, 0) + (0.06 if known else 0)


def _art(url: str | None) -> str | None:
    """Somebody else's picture, addressed through this server.

    A result list of grey squares is not a result list, and a browser fetching art
    straight off four other origins is four more places that can be slow or blocked.
    """
    return f"/art/remote?u={quote(url, safe='')}" if url else None


# ---------------------------------------------------------------- this box
def _library_songs(user_id: int, q: str, limit: int) -> list[dict]:
    rows = db.all_(
        """select t.*, m.path, c.color as cover_color, c.sha256 as cover_sha,
                  (li.user_id is not null) as mine
             from tracks t
             left join media m on m.track_id=t.id and m.role='canonical'
             left join covers c on c.id=t.cover_id
             left join library_items li on li.track_id=t.id and li.user_id=%s
            where t.norm_title %% lower(%s) or t.title ilike %s
                  or exists (select 1 from unnest(t.artists) a where a ilike %s)
            order by mine desc, similarity(t.norm_title, lower(%s)) desc limit %s""",
        (user_id, q, f"%{q}%", f"%{q}%", q, limit),
    )
    out = []
    for t in rows:
        pub = catalog.public(t)
        out.append({
            "kind": "song", "place": "library", "id": str(t["id"]),
            "title": pub["display_title"] or pub["title"],
            "subtitle": ", ".join(pub["artists"] or []) or "Unknown artist",
            "cover_url": pub["cover_url"], "duration_ms": pub["duration_ms"],
            "track": pub, "known": True, "mine": bool(t["mine"]),
        })
    return out


def _library_albums(user_id: int, q: str, limit: int) -> list[dict]:
    rows = db.all_(
        """select t.album as name,
                  coalesce(t.artists[1], 'Unknown artist') as artist,
                  count(*) as tracks,
                  max(t.id) filter (where t.cover_id is not null) as cover_track_id
             from tracks t
             join library_items li on li.track_id = t.id and li.user_id = %s
            where t.album ilike %s
            group by t.album, coalesce(t.artists[1], 'Unknown artist')
            order by (lower(t.album) = lower(%s)) desc, count(*) desc
            limit %s""",
        (user_id, f"%{q}%", q, limit),
    )
    return [{
        "kind": "album", "place": "library", "id": a["name"],
        "title": a["name"], "subtitle": a["artist"],
        "cover_url": (f"/tracks/{a['cover_track_id']}/cover"
                      if a["cover_track_id"] else None),
        "tracks": a["tracks"], "artist": a["artist"], "known": True,
    } for a in rows if a["name"]]


def _library_artists(user_id: int, q: str, limit: int) -> list[dict]:
    # One row per artist however their name was typed — see routes_browse.ARTIST_KEY.
    # Two spellings of the same act used to take two of the six artist rows a search
    # has, each with half the songs.
    from .routes_browse import ARTIST_KEY

    rows = db.all_(
        f"""select mode() within group (order by artist) as name,
                  count(distinct t.id) as tracks,
                  max(t.id) filter (where t.cover_id is not null) as cover_track_id
             from (select unnest(t.artists) as artist, t.id, t.cover_id
                     from tracks t
                     join library_items li
                       on li.track_id = t.id and li.user_id = %s) t(artist, id, cover_id)
            where artist ilike %s
            group by {ARTIST_KEY}
            order by (lower(mode() within group (order by artist)) = lower(%s)) desc,
                     count(distinct t.id) desc
            limit %s""",
        (user_id, f"%{q}%", q, limit),
    )
    return [{
        "kind": "artist", "place": "library", "id": a["name"], "title": a["name"],
        "subtitle": f"{a['tracks']} song{'s' if a['tracks'] != 1 else ''}",
        "cover_url": (f"/tracks/{a['cover_track_id']}/cover"
                      if a["cover_track_id"] else None),
        "tracks": a["tracks"], "known": True,
    } for a in rows if a["name"]]


# ---------------------------------------------------------------- somebody else's
def _known_video_ids() -> set[str]:
    return {t["provider_id"] for t in db.all_(
        "select provider_id from track_sources where provider='ytmusic'")}


def _ytm_songs(q: str, limit: int) -> list[dict]:
    have = _known_video_ids()
    out = []
    for r in ytm.search_songs(q, limit=limit):
        raw = r.get("raw") or {}
        out.append({
            "kind": "song", "place": "ytmusic", "id": r["video_id"],
            "title": r["title"],
            "subtitle": ", ".join(r.get("artists") or []) or "Unknown artist",
            "cover_url": _art(ytm.thumbnail_url(raw)),
            "duration_ms": r.get("duration_ms"),
            "album": r.get("album"),
            "known": r["video_id"] in have,
        })
    return out


def _video_hit(r: dict, have: set[str]) -> dict:
    who = ", ".join(r.get("artists") or []) or "YouTube"
    return {
        "kind": "video", "place": "youtube", "id": r["video_id"],
        "title": r["title"],
        "subtitle": " · ".join(x for x in (who, f"{r['views']} views" if r.get("views") else None) if x),
        "cover_url": _art(ytm.thumbnail_url(r.get("raw") or {})),
        "duration_ms": r.get("duration_ms"),
        "known": r["video_id"] in have,
        "url": f"https://www.youtube.com/watch?v={r['video_id']}",
    }


def _yt_videos(q: str, limit: int) -> list[dict]:
    """Ordinary YouTube videos, to be kept as their sound: see ytm.search_videos."""
    have = _known_video_ids()
    return [_video_hit(r, have) for r in ytm.search_videos(q, limit=limit)]


def _pasted(q: str) -> dict | None:
    """A YouTube link, answered with the one video it points at."""
    video_id = ytm.video_id_in(q)
    if not video_id:
        return None
    found = ytm.video(video_id)
    if not found:
        return None
    return _video_hit(found, _known_video_ids())


def _ytm_albums(q: str, limit: int) -> list[dict]:
    out = []
    for r in ytm.search_albums(q, limit=limit):
        out.append({
            "kind": "album", "place": "ytmusic", "id": r["browse_id"],
            "title": r["title"], "subtitle": r["artist"] or "Unknown artist",
            "cover_url": _art(r.get("thumbnail")), "year": r.get("year"),
            "artist": r.get("artist"), "known": False,
        })
    return out


def _ytm_artists(q: str, limit: int) -> list[dict]:
    return [{
        "kind": "artist", "place": "ytmusic", "id": r["browse_id"],
        "title": r["title"], "subtitle": r.get("subscribers") or "Artist",
        "cover_url": _art(r.get("thumbnail")), "known": False,
    } for r in ytm.search_artists(q, limit=limit)]


def _spotify_hits(cfg, user_id: int, q: str, kinds: tuple[str, ...],
                  limit: int) -> list[dict]:
    """Spotify, but only for somebody who has linked it — it has no public search."""
    if not spotify.account(user_id):
        return []
    # Only the kinds Spotify has a name for. Asking for "video" raised a KeyError
    # inside the leg, and the search page printed the exception's class name beside a
    # green dot on every search that included videos — which is every search.
    named = {"song": "track", "album": "album", "artist": "artist"}
    types = ",".join(named[k] for k in kinds if k in named)
    if not types:
        return []
    data = spotify._get(cfg, user_id, "/search", q=q, type=types, limit=limit)
    out: list[dict] = []
    for t in ((data.get("tracks") or {}).get("items") or []):
        images = ((t.get("album") or {}).get("images") or [])
        out.append({
            "kind": "song", "place": "spotify", "id": t["id"],
            "title": t.get("name") or "",
            "subtitle": ", ".join(a["name"] for a in (t.get("artists") or []))
                        or "Unknown artist",
            "cover_url": _art(images[0]["url"] if images else None),
            "duration_ms": t.get("duration_ms"),
            "album": (t.get("album") or {}).get("name"),
            "known": False,
        })
    for a in ((data.get("albums") or {}).get("items") or []):
        images = a.get("images") or []
        out.append({
            "kind": "album", "place": "spotify", "id": a["id"],
            "title": a.get("name") or "",
            "subtitle": ", ".join(x["name"] for x in (a.get("artists") or []))
                        or "Unknown artist",
            "cover_url": _art(images[0]["url"] if images else None),
            "year": (a.get("release_date") or "")[:4] or None,
            "artist": (a.get("artists") or [{}])[0].get("name"),
            "known": False,
        })
    for a in ((data.get("artists") or {}).get("items") or []):
        images = a.get("images") or []
        out.append({
            "kind": "artist", "place": "spotify", "id": a["id"],
            "title": a.get("name") or "", "subtitle": "Artist",
            "cover_url": _art(images[0]["url"] if images else None),
            "known": False,
        })
    return out


def _source_songs(place: str, q: str, limit: int) -> list[dict]:
    out = []
    for h in sources.search(place, q, limit):
        found = catalog.find_by_provider(h["provider"], h["provider_id"])
        out.append({
            "kind": "song", "place": place, "id": h["provider_id"],
            "title": h.get("title") or "",
            "subtitle": ", ".join(h.get("artists") or []) or "Unknown artist",
            "cover_url": _art(h.get("cover_url")),
            "duration_ms": h.get("duration_ms"),
            "url": h.get("url"),
            "track": catalog.public(found) if found else None,
            "known": found is not None,
        })
    return out


# ---------------------------------------------------------------- by the words in it
#
# YouTube Music's own index covers lyrics — "is this the real life is this just fantasy"
# answers with Bohemian Rhapsody — which is what makes finding a song nobody here owns
# possible at all. What it does not do is say *why* a result is a result, and a list of
# songs with no visible connection to what was typed reads as a broken search. So the
# words are confirmed against the lyrics themselves, and the line they were found in is
# what the row says.
LYRIC_CHECKS = 6


def _the_line(plain: str | None, q: str) -> str | None:
    """The line the words are in, if they are in there."""
    if not plain:
        return None
    want = _norm(q)
    if not want:
        return None
    for line in plain.splitlines():
        if want in _norm(line):
            return line.strip()
    # Across a line break: the phrase is there, just not on one line of it.
    if want in _norm(plain.replace("\n", " ")):
        lines = [l.strip() for l in plain.splitlines() if l.strip()]
        for i in range(len(lines) - 1):
            if want in _norm(f"{lines[i]} {lines[i + 1]}"):
                return f"{lines[i]} / {lines[i + 1]}"
    return None


def _library_by_lyrics(user_id: int, q: str, limit: int) -> list[dict]:
    """Songs here whose words this server already has. Exact, and free."""
    rows = db.all_(
        """select t.*, m.path, c.color as cover_color, c.sha256 as cover_sha,
                  l.plain, (li.user_id is not null) as mine
             from lyrics l
             join tracks t on t.id = l.track_id
             left join media m on m.track_id=t.id and m.role='canonical'
             left join covers c on c.id=t.cover_id
             left join library_items li on li.track_id=t.id and li.user_id=%s
            where l.plain ilike %s
            order by (li.user_id is not null) desc
            limit %s""",
        (user_id, f"%{q}%", limit),
    )
    out = []
    for t in rows:
        pub = catalog.public(t)
        out.append({
            "kind": "song", "place": "library", "id": str(t["id"]),
            "title": pub["display_title"] or pub["title"],
            "subtitle": ", ".join(pub["artists"] or []) or "Unknown artist",
            "cover_url": pub["cover_url"], "duration_ms": pub["duration_ms"],
            "track": pub, "known": True, "mine": bool(t["mine"]),
            "lyric": _the_line(t["plain"], q), "confirmed": True,
        })
    return out


def _confirm_lyrics(hits: list[dict], q: str) -> None:
    """Ask lrclib whether the words really are in these songs, and keep the line."""
    import httpx

    def look(hit: dict) -> None:
        try:
            r = httpx.get("https://lrclib.net/api/search",
                          params={"track_name": hit["title"],
                                  "artist_name": hit["subtitle"].split(",")[0]},
                          headers={"User-Agent": "muse (https://github.com/)"},
                          timeout=8)
            if r.status_code != 200:
                return
            for record in (r.json() or [])[:2]:
                line = _the_line(record.get("plainLyrics"), q)
                if line:
                    hit["lyric"] = line
                    hit["confirmed"] = True
                    return
        except Exception as e:                    # noqa: BLE001
            log.debug("lyric check failed for %s: %s", hit.get("title"), e)

    with ThreadPoolExecutor(max_workers=4) as pool:
        list(pool.map(look, hits[:LYRIC_CHECKS]))


def by_lyrics(user_id: int, q: str, limit: int) -> tuple[list[dict], dict]:
    """Songs whose words these are — here first, then everywhere else."""
    notes: dict[str, str] = {}
    here = _library_by_lyrics(user_id, q, limit)
    seen = {(_norm(h["title"]), _norm(h["subtitle"])) for h in here}

    out = list(here)
    try:
        away = _ytm_songs(q, min(limit, 12))
    except ytm.Unavailable as e:
        notes["ytmusic"] = "YouTube would not answer just now"
        log.warning("lyric search: %s", e)
        away = []
    away = [h for h in away
            if (_norm(h["title"]), _norm(h["subtitle"])) not in seen]
    _confirm_lyrics(away, q)
    # Confirmed first, then whatever the provider's own index thought — it knows things
    # about lyrics that lrclib has never heard of, and dropping those would make the
    # feature worse than the search it replaces.
    away.sort(key=lambda h: (not h.get("confirmed"), ))
    out += away
    for i, hit in enumerate(out):
        hit["score"] = (2.0 if hit.get("confirmed") else 1.0) - i * 0.001
    return out[:limit], notes


# ---------------------------------------------------------------- everything at once
def everything(cfg, user_id: int, q: str, *, where: str = "all", kind: str = "all",
               lyrics: bool = False, limit: int = 30) -> dict:
    q = (q or "").strip()
    if not q:
        return {"items": [], "notes": {}}
    if lyrics:
        items, notes = by_lyrics(user_id, q, limit)
        return {"items": items, "notes": notes}

    # A link is not a question. Somebody who pastes one wants that video, not whatever
    # a search for the text of its address turns up.
    if ytm.video_id_in(q):
        hit, error = _safely(lambda: [h for h in [_pasted(q)] if h])
        return {"items": hit,
                "notes": {"youtube": error} if error else
                         ({} if hit else {"youtube": "That link did not lead to a video"})}

    places = PLACES if where in ("all", "") else (where,)
    kinds = KINDS if kind in ("all", "") else (kind,)
    # Asked for on its own, a place is allowed to fill the screen.
    each = limit if where not in ("all", "") else max(6, limit // 3)
    notes: dict[str, str] = {}
    jobs: dict[str, callable] = {}

    if "library" in places:
        if "song" in kinds:
            jobs["library:song"] = lambda: _library_songs(user_id, q, each)
        if "album" in kinds:
            jobs["library:album"] = lambda: _library_albums(user_id, q, 6)
        if "artist" in kinds:
            jobs["library:artist"] = lambda: _library_artists(user_id, q, 6)
    if "ytmusic" in places:
        if "song" in kinds:
            jobs["ytmusic:song"] = lambda: _ytm_songs(q, each)
        if "album" in kinds:
            jobs["ytmusic:album"] = lambda: _ytm_albums(q, 5)
        if "artist" in kinds:
            jobs["ytmusic:artist"] = lambda: _ytm_artists(q, 3)
    if "youtube" in places and "video" in kinds:
        # A handful beside everything else; the screen, when they are what was asked for.
        jobs["youtube:video"] = lambda: _yt_videos(
            q, each if (kind == "video" or where == "youtube") else 5)
    if "spotify" in places:
        jobs["spotify:all"] = lambda: _spotify_hits(cfg, user_id, q, kinds, 6)
    for place in ("soundcloud", "bandcamp"):
        if place in places and "song" in kinds:
            jobs[f"{place}:song"] = (
                lambda p=place: _source_songs(p, q, min(each, 10)))

    found: list[dict] = []
    # In parallel, because three of these are somebody else's server and the slowest
    # one decides how long a search takes if they are asked in turn.
    with ThreadPoolExecutor(max_workers=max(1, len(jobs))) as pool:
        for name, result in zip(jobs, pool.map(lambda f: _safely(f), jobs.values())):
            rows, error = result
            if error:
                notes[name.split(":")[0]] = error
            found += rows

    # The same video is often filed as a song as well. The song is the better copy of it,
    # so the video is only listed when there is no such song in the list.
    songs = {h["id"] for h in found if h["place"] == "ytmusic" and h["kind"] == "song"}
    found = [h for h in found if not (h["kind"] == "video" and h["id"] in songs)]

    for hit in found:
        hit["score"] = _score(q, hit["title"], hit.get("subtitle") or "",
                              hit["place"], hit.get("known", False))
    found.sort(key=lambda h: h["score"], reverse=True)

    if where in ("all", ""):
        # A mixed list stays mixed: one service having twenty near-identical uploads of
        # a song is not a reason for it to own the screen.
        kept, seen = [], {}
        for hit in found:
            n = seen.get(hit["place"], 0)
            if n >= PER_PLACE:
                continue
            seen[hit["place"]] = n + 1
            kept.append(hit)
        found = kept

    return {"items": found[:limit], "notes": notes}


def _safely(fn) -> tuple[list[dict], str | None]:
    """One leg of a search failing is not a failed search."""
    try:
        return fn(), None
    except ytm.Unavailable:
        return [], "YouTube would not answer just now"
    except sources.SourceError as e:
        return [], str(e)
    except Exception as e:                        # noqa: BLE001
        # The class name goes to the log, where it means something; the screen gets a
        # sentence, because "KeyError" beside a coloured dot is not one.
        log.warning("search leg failed: %s: %s", type(e).__name__, e)
        return [], "Could not be searched just now"
