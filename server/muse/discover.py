"""Discover: the page that has something for you before you ask.

Everything on it already existed in pieces — stations (stations.py), the recommender
behind them (recommend.py), the artists you follow and the records they put out
(follows.py) — and each piece was a button somewhere else. This gathers them into
the one page every music app has, and adds the three things that were missing:

  lists    made for one person and kept, not recomputed on every look: this week's
           finds (songs new to you), the daily mixes (your library sorted into the
           three or four kinds of thing you actually play, each with a little that is
           new), the release radar (what came out this fortnight by who you follow),
           and the cheap ones that are still the most played buttons on any service —
           on repeat, the time capsule, the house blend. Built overnight by the same
           self-queueing job the follow poll uses, and on demand the first time.
  genres   a second thing to follow besides an artist. Nothing here had a genre;
           MusicBrainz gives an artist its genres and ListenBrainz gives a genre its
           new records and its radio, so now "techno" is something the feed can
           watch and a station can be started from.
  the map  the house's own data says what of ours goes together; it cannot name a
           band nobody here has played. ListenBrainz can (brainz.py), and this week's
           finds lean on it for exactly that.
"""
from __future__ import annotations

import datetime as dt
import json
import logging
import random
import time

import json as _json
import urllib.request

from . import brainz, catalog, db, discography, follows, jobs, linked, recommend, sources, ytm

log = logging.getLogger("muse.discover")

_publish = None


def set_publisher(fn) -> None:
    global _publish
    _publish = fn


# A machine-made list counts as a discovery, not a download somebody asked for.
VIA_DISCOVER = "discover"

# How long each list is good for before the overnight job makes it again.
WEEKLY_SLUG = "weekly"
LIST_LENGTH = {"weekly": 25, "daily": 30, "radar": 30, "repeat": 30, "again": 30, "house": 30}
DAILY_MIXES_MOST = 4
RADAR_DAYS = 14
# Not offered in this week's finds again for this long after it was offered once.
HISTORY_WEEKS = 8
# Network budget for one person's weekly list: artists asked about, songs resolved.
WEEKLY_NEW_ARTISTS = 6
WEEKLY_FROM_THE_MAP = 10

# A nightly build, a little after four in the morning, box time.
BUILD_HOUR = 4
BUILD_MINUTE = 20

# How many genres one person can follow. Past this it is not following, it is all.
GENRES_MOST = 40


# ------------------------------------------------------------------ small helpers
def _norm(s: str | None) -> str:
    return brainz.fold(s)


def _rows(ids: list[int]) -> list[dict]:
    """Track rows as the app sees them, in the order given, without the failed."""
    if not ids:
        return []
    rows = recommend._rows_for(ids)
    return [catalog.public(rows[i]) for i in ids if i in rows and rows[i]["state"] != "failed"]


def _find_song(title: str, artist: str | None) -> dict | None:
    """A song already in the catalog, by what it is called and who by."""
    if not title:
        return None
    norm = recommend.search_norm(title)
    rows = db.all_(
        """select id, artists, state from tracks
            where norm_title = %s and state <> 'failed'
            order by (state = 'ready') desc, id""", (norm,))
    want = _norm(artist)
    for r in rows:
        if not want or any(_norm(a) == want or want in _norm(a) or _norm(a) in want
                           for a in r["artists"] or []):
            return catalog.track_row(r["id"])
    return None


def resolve_song(title: str, artist: str | None, *, album: str | None = None,
                 priority: int = jobs.PRIORITY_BULK) -> dict | None:
    """The catalog's track for a song named from outside: the one already here if it
    is, else YouTube Music's best match, written into the catalog and queued. None
    when nothing fits — a guess that is the wrong song is worse than a gap."""
    known = _find_song(title, artist)
    if known:
        return known
    q = f"{title} {artist or ''}".strip()
    try:
        hits = ytm.search_songs(q, limit=5)
    except Exception:  # noqa: BLE001 — the network is not a reason to stop building
        return None
    want_t, want_a = _norm(title), _norm(artist)
    best = None
    for h in hits:
        t = _norm(h.get("title"))
        names = [_norm(a) for a in h.get("artists") or []]
        title_ok = t == want_t or want_t in t or t in want_t
        artist_ok = not want_a or any(a == want_a or want_a in a or a in want_a for a in names)
        if title_ok and artist_ok:
            best = h
            break
    if not best:
        return None
    found = catalog.find_by_video_id(best["video_id"])
    if found:
        return found
    try:
        return catalog.create_from_ytm(
            {"video_id": best["video_id"], "title": best.get("title") or title,
             "artists": best.get("artists") or ([artist] if artist else []),
             "album": best.get("album") or album, "duration_ms": best.get("duration_ms"),
             "raw": best.get("raw") or {}},
            discovered_via=VIA_DISCOVER, priority=priority)
    except Exception as e:  # noqa: BLE001
        log.info("could not add %s: %s", q, e)
        return None


def _bring_in(p: recommend.Pick, priority: int = jobs.PRIORITY_BULK) -> int | None:
    """A pick as a track id, writing a remote one into the catalog."""
    if isinstance(p.key, int):
        return p.key
    meta = p.row
    known = catalog.find_by_video_id(meta["video_id"])
    if known:
        return known["id"]
    try:
        made = catalog.create_from_ytm(
            {"video_id": meta["video_id"], "title": meta.get("title") or meta["video_id"],
             "artists": meta.get("artists") or [], "album": meta.get("album"),
             "duration_ms": meta.get("duration_ms"),
             "raw": {"thumbnails": meta.get("thumbnails") or []}},
            discovered_via=VIA_DISCOVER, priority=priority)
        return made["id"]
    except Exception as e:  # noqa: BLE001
        log.info("could not add %s: %s", meta.get("title"), e)
        return None


def _top_artists(tas: recommend.Taste, most: int = 12) -> list[str]:
    """Who this person plays most, by the taste score, nicest spelling kept."""
    if not tas.artist:
        return []
    names = sorted(tas.artist.items(), key=lambda kv: -kv[1])
    out = []
    for k, v in names:
        if v <= 0:
            break
        out.append(k)
        if len(out) >= most:
            break
    if not out:
        return []
    spelled = {}
    for r in db.all_(
            """select a, count(*) n from tracks t, unnest(t.artists) a
                where lower(a) = any(%s) group by a order by n desc""", (out,)):
        spelled.setdefault(r["a"].lower(), r["a"])
    return [spelled.get(k, k) for k in out]


def _artist_entry(name: str, *, ask: bool = True) -> dict | None:
    try:
        return brainz.artist(name, ask=ask)
    except Exception:  # noqa: BLE001
        return None


# ------------------------------------------------------------------ genres
def genres_of(user_id: int) -> list[str]:
    return [r["genre"] for r in db.all_(
        "select genre from genre_follows where user_id=%s order by genre", (user_id,))]


def follow_genre(user_id: int, genre: str) -> dict:
    g = _norm(genre)
    if not g or len(g) > 60:
        raise ValueError("that is not a genre")
    have = genres_of(user_id)
    if g not in have and len(have) >= GENRES_MOST:
        raise ValueError(f"following {GENRES_MOST} genres is following everything")
    db.run("insert into genre_follows(user_id, genre) values(%s,%s) on conflict do nothing",
           (user_id, g))
    # Something in the feed straight away, from what ListenBrainz already told us this
    # morning. Only the records people are actually playing arrive unread: a genre
    # that came in as two dozen unread singles by nobody would be marked read whole.
    try:
        found = refresh_genre(g, resolve=False)
    except Exception as e:  # noqa: BLE001
        log.info("could not fill genre %s: %s", g, e)
        found = 0
    db.run(
        """insert into feed_seen(user_id, provider, album_id)
           select %s, 'mb', release_mbid from genre_releases
            where genre=%s and listens < 5
           on conflict do nothing""", (user_id, g))
    return {"genre": g, "following": True, "releases": found}


def unfollow_genre(user_id: int, genre: str) -> None:
    db.run("delete from genre_follows where user_id=%s and genre=%s", (user_id, _norm(genre)))


def genre_names(q: str | None = None, limit: int = 30) -> list[str]:
    """Genres to pick from: MusicBrainz's list, narrowed by what was typed."""
    try:
        names = brainz.all_genres()
    except brainz.Unavailable:
        names = COMMON_GENRES
    needle = _norm(q)
    if not needle:
        return names[:limit]
    starts = [n for n in names if _norm(n).startswith(needle)]
    within = [n for n in names if needle in _norm(n) and n not in starts]
    return (starts + within)[:limit]


# The ones worth offering when MusicBrainz cannot be asked, and the ones put first.
COMMON_GENRES = [
    "house", "techno", "deep house", "drum and bass", "ambient", "electronic", "hip hop",
    "trap", "r&b", "soul", "funk", "disco", "jazz", "indie rock", "indie pop", "pop",
    "rock", "punk", "metal", "folk", "country", "classical", "reggae", "dub", "afrobeats",
    "latin", "k-pop", "synth-pop", "lo-fi", "garage", "uk garage", "trance", "dubstep",
    "breakbeat", "downtempo", "trip hop", "shoegaze", "post-punk", "grime", "blues",
]


def suggested_genres(user_id: int, tas: recommend.Taste | None = None,
                     limit: int = 10, *, ask: bool = False) -> list[dict]:
    """Genres this person plays without having named them: the genres MusicBrainz
    gives their most played artists, counted across them. [ask] goes to MusicBrainz
    for artists not looked up yet — the overnight build does; a page does not."""
    tas = tas or recommend.taste(user_id)
    have = set(genres_of(user_id))
    votes: dict[str, list[str]] = {}
    for name in _top_artists(tas, most=15):
        entry = _artist_entry(name, ask=ask)
        if not entry:
            continue
        for g in entry.get("genres") or []:
            votes.setdefault(g, []).append(entry["name"])
    out = []
    for g, who in sorted(votes.items(), key=lambda kv: (-len(kv[1]), kv[0])):
        if g in have:
            continue
        out.append({"genre": g, "why": "from " + ", ".join(who[:3])})
        if len(out) >= limit:
            break
    return out


def refresh_genre(genre: str, *, resolve: bool = True, most: int = 24) -> int:
    """Write down what came out lately in a genre. Returns how many records are kept.

    ListenBrainz's fortnight of releases carries the tags people put on each record;
    a record tagged with the genre is news for it. The ones most listened to come
    first — the fortnight has fifteen hundred releases in it and most are nobody's
    news. With [resolve], the record is also looked up on Deezer, which is what lets
    it open as an album page."""
    g = _norm(genre)
    releases = brainz.fresh_releases(RADAR_DAYS)
    tagged = [r for r in releases if any(g == t or g == _norm(t) for t in r["tags"])]
    tagged.sort(key=lambda r: (-r["listens"], r["release_date"] or ""))
    kept = 0
    for r in tagged[:most]:
        if not r.get("release_mbid"):
            continue
        db.run(
            """insert into genre_releases(genre, release_mbid, release_group_mbid, title,
                                          artist, artist_mbids, release_date, record_type,
                                          listens, cover)
               values(%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)
               on conflict (genre, release_mbid) do update
                 set listens=excluded.listens, cover=coalesce(excluded.cover,
                     genre_releases.cover), title=excluded.title""",
            (g, r["release_mbid"], r.get("release_group_mbid"), r["title"] or "",
             r["artist"] or "", r.get("artist_mbids") or [], r.get("release_date") or None,
             r.get("record_type"), r["listens"], r.get("cover")))
        kept += 1
    if resolve:
        _resolve_genre_releases(g)
    # Older than the window: gone from the news, like a paper.
    db.run("""delete from genre_releases where genre=%s and release_date <
              current_date - %s * interval '1 day'""", (g, RADAR_DAYS * 2))
    return kept


def _resolve_genre_releases(genre: str, most: int = 12) -> None:
    """Deezer ids for the most listened records of a genre, so they open as pages."""
    rows = db.all_(
        """select release_mbid, title, artist from genre_releases
            where genre=%s and deezer_album_id is null and looked_up_at is null
            order by listens desc limit %s""", (genre, most))
    for r in rows:
        found = None
        try:
            found = discography.find_album(r["title"], r["artist"])
        except discography.Unavailable:
            return
        db.run(
            """update genre_releases set deezer_album_id=%s, looked_up_at=now(),
                      cover=coalesce(%s, cover)
                where genre=%s and release_mbid=%s""",
            (str(found["id"]) if found else None,
             (found or {}).get("cover_big") or (found or {}).get("cover_medium"),
             genre, r["release_mbid"]))


# ------------------------------------------------------------------ the feed
def feed(user_id: int, limit: int = 60) -> dict:
    """New records for this person: by the artists they follow, and in the genres
    they follow, newest first, the ones not yet looked at marked."""
    by_artist = follows.feed(user_id, limit=limit)
    items = []
    for r in by_artist:
        items.append({
            "source": "artist", "provider": r["provider"], "album_id": r["album_id"],
            "title": r["title"], "artist": r["artist"], "cover": r["cover"],
            "release_date": r["release_date"].isoformat() if r["release_date"] else None,
            "record_type": r["record_type"], "tracks": r["tracks"],
            "unseen": r["unseen"], "in_library": r["in_library"], "genre": None,
            "release_mbid": None,
            # A record that came through a label: the row says so, since the act's
            # name on it may be nobody you follow.
            "via": r["via"] if r.get("is_label") else None,
        })
    genres = genres_of(user_id)
    if genres:
        followed_artists = {_norm(r["artist"]) for r in by_artist}
        rows = db.all_(
            """select g.*, (s.album_id is null) as unseen
                 from genre_releases g
                 left join feed_seen s on s.user_id=%s and s.provider='mb'
                                      and s.album_id=g.release_mbid
                where g.genre = any(%s)
                order by g.release_date desc nulls last, g.listens desc
                limit %s""", (user_id, genres, limit))
        seen_mbids = set()
        for r in rows:
            if r["release_mbid"] in seen_mbids or _norm(r["artist"]) in followed_artists:
                continue
            seen_mbids.add(r["release_mbid"])
            items.append({
                "source": "genre", "provider": "deezer" if r["deezer_album_id"] else "mb",
                "album_id": r["deezer_album_id"], "title": r["title"], "artist": r["artist"],
                "cover": r["cover"],
                "release_date": r["release_date"].isoformat() if r["release_date"] else None,
                "record_type": r["record_type"], "tracks": None, "unseen": r["unseen"],
                "in_library": False, "genre": r["genre"], "release_mbid": r["release_mbid"],
            })
    items.sort(key=lambda i: (i["release_date"] or ""), reverse=True)
    items = items[:limit]
    return {"items": items, "unseen": sum(1 for i in items if i["unseen"]),
            "following": len(follows.list_for(user_id)), "genres": len(genres)}


def mark_seen(user_id: int, items: list[dict]) -> int:
    """Looked at: Deezer records by album id, ListenBrainz ones by release id."""
    n = 0
    deezer = [str(i["album_id"]) for i in items if i.get("album_id") and i.get("provider") == "deezer"]
    mb = [str(i["release_mbid"]) for i in items if i.get("release_mbid")]
    if deezer:
        n += follows.mark_seen(user_id, deezer, "deezer")
    if mb:
        n += follows.mark_seen(user_id, mb, "mb")
    return n


# ------------------------------------------------------------------ stations
def your_stations(user_id: int, limit: int = 12) -> list[dict]:
    return [dict(r) for r in db.all_(
        """select s.queue_id, s.name, s.kind, s.seed_text, s.fresh, s.created_at,
                  q.cursor_index, q.updated_at,
                  (select count(*) from queue_items i where i.queue_id = s.queue_id) as count,
                  (select t.id from queue_items i join tracks t on t.id = i.track_id
                     where i.queue_id = s.queue_id and t.cover_id is not null
                     order by i.pos limit 1) as cover_track
             from stations s join queues q on q.id = s.queue_id
            where s.owner_id = %s
            order by q.updated_at desc limit %s""", (user_id, limit))]


def station_starters(user_id: int, tas: recommend.Taste | None = None) -> dict:
    """Things a station can be started from, for this person: the artists they play,
    a few songs, and the genres they follow with a few they might."""
    tas = tas or recommend.taste(user_id)
    artists = []
    for name in _top_artists(tas, most=10):
        row = db.one(
            """select t.id, t.cover_id from tracks t
                join library_items li on li.track_id = t.id and li.user_id = %s
               where %s = any(t.artists) and t.cover_id is not null
               order by (select count(*) from listens l where l.track_id = t.id) desc
               limit 1""", (user_id, name))
        artists.append({"name": name, "cover_track": row["id"] if row else None})
    songs = []
    seeds = recommend.seeds_of_person(user_id, most=6, the_taste=tas)
    if seeds:
        songs = _rows(list(seeds))
    genres = genres_of(user_id)
    extra = [g["genre"] for g in suggested_genres(user_id, tas, limit=6)] if len(genres) < 8 else []
    return {"artists": artists, "tracks": songs,
            "genres": [{"genre": g, "following": True} for g in genres]
                      + [{"genre": g, "following": False} for g in extra]}


def genre_seeds(genre: str, user_id: int, most: int = 6) -> list[dict]:
    """Songs a station for a genre starts from.

    ListenBrainz's radio by tag names recordings; Deezer's genre radios name tracks.
    Either way the song has to be a track here, so each is found in the catalog or
    fetched. Resolved seeds are kept a day: the second person to want techno gets it
    at once, and the overnight job does not re-ask.
    """
    g = _norm(genre)
    key = f"genre-seeds:{g}"
    cached = brainz._cached(key, 86400)
    ids: list[int] = list(cached or [])
    if not ids:
        named: list[tuple[str, str | None, str | None]] = []
        try:
            mbids = brainz.tag_radio(g, count=20)
            meta = brainz.recordings(mbids) if mbids else {}
            for m in mbids:
                r = meta.get(m)
                if r and r.get("title"):
                    named.append((r["title"], (r.get("artists") or [None])[0], r.get("album")))
        except brainz.Unavailable:
            pass
        if len(named) < most:
            named += _deezer_radio_songs(g)
        seen: set[tuple[str, str]] = set()
        for title, artist, album in named:
            k = (_norm(title), _norm(artist))
            if k in seen:
                continue
            seen.add(k)
            t = resolve_song(title, artist, album=album, priority=jobs.PRIORITY_QUEUE)
            if t:
                ids.append(t["id"])
            if len(ids) >= most * 2:
                break
        if ids:
            brainz._store(key, ids)
    rows = recommend._rows_for(ids)
    out = [rows[i] for i in ids if i in rows and rows[i]["state"] != "failed"]
    # What is already here plays at once, so it goes first; then a spread of the rest.
    out.sort(key=lambda r: (r["state"] != "ready", ids.index(r["id"])))
    return out[:most]


def _deezer_radio_songs(genre: str, most: int = 25) -> list[tuple[str, str | None, str | None]]:
    """Deezer's radio of this name — "Techno", "Die 80er" — as named songs."""
    try:
        groups = discography._get("/radio/genres", kind="top").get("data") or []
    except discography.Unavailable:
        return []
    want = _norm(genre)
    radio = None
    for group in groups:
        for r in group.get("radios") or []:
            name = _norm(r.get("title"))
            if name == want or (len(want) > 3 and (want in name or name in want)):
                radio = r
                break
        if radio:
            break
    if not radio:
        return []
    try:
        tracks = discography._get(f"/radio/{radio['id']}/tracks", {"limit": most},
                                  kind="top").get("data") or []
    except discography.Unavailable:
        return []
    return [(t.get("title"), (t.get("artist") or {}).get("name"),
             (t.get("album") or {}).get("title")) for t in tracks if t.get("title")]


# ------------------------------------------------------------------ artists to try
def artists_to_try(user_id: int, tas: recommend.Taste | None = None,
                   limit: int = 12, *, ask: bool = False) -> list[dict]:
    """Acts nobody here has played that people who play your acts also play.
    [ask] as for suggested_genres: only the overnight build goes over the wire."""
    tas = tas or recommend.taste(user_id)
    # "Played here" means in somebody's library — not merely in the catalog, where
    # the overnight build itself leaves the one song of theirs it just found.
    have = {r["a"] for r in db.all_(
        """select distinct lower(a) as a from tracks t
             join library_items li on li.track_id = t.id, unnest(t.artists) a""")}
    scored: dict[str, dict] = {}
    for name in _top_artists(tas, most=6):
        entry = _artist_entry(name, ask=ask)
        if not entry:
            continue
        try:
            similar = brainz.similar_artists(entry["mbid"], limit=25, ask=ask)
        except brainz.Unavailable:
            continue
        top = similar[0]["score"] if similar else 1
        for s in similar:
            if s["name"].lower() in have:
                continue
            rec = scored.setdefault(s["mbid"], {"name": s["name"], "mbid": s["mbid"],
                                                "score": 0.0, "because": []})
            rec["score"] += s["score"] / max(top, 1)
            rec["because"].append(entry["name"])
    out = sorted(scored.values(), key=lambda r: -r["score"])[:limit]
    return [{"name": r["name"], "mbid": r["mbid"],
             "because": "people who play " + " and ".join(r["because"][:2]) + " play this"}
            for r in out]


# ------------------------------------------------------------------ made lists
def lists_for(user_id: int, *, tracks: bool = True) -> list[dict]:
    rows = db.all_(
        """select slug, name, blurb, built_at, track_ids, meta from made_lists
            where user_id=%s order by ordinal""", (user_id,))
    out = []
    for r in rows:
        meta = r["meta"] if isinstance(r["meta"], dict) else json.loads(r["meta"] or "{}")
        entry = {"slug": r["slug"], "name": r["name"], "blurb": r["blurb"],
                 "built_at": r["built_at"], "count": len(r["track_ids"] or []),
                 "kind": r["slug"].split(":")[0], **{k: meta[k] for k in ("why",) if k in meta}}
        if tracks:
            entry["tracks"] = _rows(list(r["track_ids"] or []))
            entry["count"] = len(entry["tracks"])
        out.append(entry)
    return out


def one_list(user_id: int, slug: str) -> dict | None:
    for entry in lists_for(user_id):
        if entry["slug"] == slug:
            return entry
    return None


def _save(user_id: int, slug: str, name: str, blurb: str, ids: list[int],
          ordinal: int, meta: dict | None = None) -> None:
    db.run(
        """insert into made_lists(user_id, slug, name, blurb, track_ids, ordinal, meta, built_at)
           values(%s,%s,%s,%s,%s,%s,%s,now())
           on conflict (user_id, slug) do update
             set name=excluded.name, blurb=excluded.blurb, track_ids=excluded.track_ids,
                 ordinal=excluded.ordinal, meta=excluded.meta, built_at=now()""",
        (user_id, slug, name, blurb, ids, ordinal, json.dumps(meta or {})))


def _built_at(user_id: int, slug: str):
    row = db.one("select built_at from made_lists where user_id=%s and slug=%s", (user_id, slug))
    return row["built_at"] if row else None


def _this_monday() -> dt.datetime:
    now = dt.datetime.now(dt.timezone.utc)
    monday = (now - dt.timedelta(days=now.weekday())).replace(hour=0, minute=0, second=0,
                                                              microsecond=0)
    return monday


def build_weekly(user_id: int, tas: recommend.Taste, *, network: bool = True) -> list[int]:
    """This week's finds: songs new to you, out of what you have been playing.

    Two wells. The house's recommender knows what of *ours* goes with what you play,
    and offers the songs in it you have not got — a housemate's records, what
    YouTube Music plays after yours. And ListenBrainz knows the acts that people who
    play your acts also play, which nothing here could know; their most listened
    songs come in beside, one in three. Nothing offered in the last two months comes
    round again, and nothing you have waved away ever does.
    """
    want = LIST_LENGTH["weekly"]
    seeds = recommend.seeds_of_person(user_id, most=16, the_taste=tas)
    hearted = [t for t in tas.hearted if t not in seeds]
    random.Random(int(time.time() // 604800)).shuffle(hearted)
    for t in hearted[:8]:
        seeds[t] = 0.6
    offered = {r["track_id"] for r in db.all_(
        """select track_id from made_history
            where user_id=%s and offered_at > now() - %s * interval '1 week'""",
        (user_id, HISTORY_WEEKS))}
    picks: list[recommend.Pick] = []
    if seeds:
        picks = recommend.recommend(user_id, seeds, limit=want + 10, only="new",
                                    exclude=offered, network=network, the_taste=tas,
                                    weights=recommend.PERSON_WEIGHTS)
    from_house = [t for t in (_bring_in(p) for p in picks) if t and t not in offered]

    from_map: list[int] = []
    why: dict[int, str] = {}
    if network:
        have = {a.lower() for a in tas.artist}
        for name in _top_artists(tas, most=WEEKLY_NEW_ARTISTS):
            entry = _artist_entry(name)
            if not entry:
                continue
            try:
                similar = brainz.similar_artists(entry["mbid"], limit=20)
            except brainz.Unavailable:
                continue
            new_acts = [s for s in similar if s["name"].lower() not in have][:3]
            for act in new_acts:
                try:
                    songs = brainz.top_recordings(act["mbid"], limit=3)
                except brainz.Unavailable:
                    continue
                for s in songs[:2]:
                    t = resolve_song(s["title"], (s.get("artists") or [act["name"]])[0])
                    if not t or t["id"] in offered or t["id"] in from_house:
                        continue
                    if f"t:{t['id']}" in tas.dismissed or t["id"] in tas.library:
                        continue
                    from_map.append(t["id"])
                    why[t["id"]] = f"because you play {entry['name']}"
                    break
                if len(from_map) >= WEEKLY_FROM_THE_MAP:
                    break
            if len(from_map) >= WEEKLY_FROM_THE_MAP:
                break

    out: list[int] = []
    seen: set[int] = set()
    house, mapped = list(from_house), list(from_map)
    while (house or mapped) and len(out) < want:
        for _ in range(2):
            if house:
                t = house.pop(0)
                if t not in seen:
                    seen.add(t)
                    out.append(t)
        if mapped:
            t = mapped.pop(0)
            if t not in seen:
                seen.add(t)
                out.append(t)
    if out:
        db.run(
            """insert into made_history(user_id, track_id)
               select %s, unnest(%s::int[]) on conflict (user_id, track_id)
               do update set offered_at = now()""", (user_id, out))
    whys = {str(k): v for k, v in why.items() if k in seen}
    for p in picks:
        if isinstance(p.key, int) and p.key in seen and p.why:
            whys.setdefault(str(p.key), p.why)
    _save(user_id, WEEKLY_SLUG, "This week's finds",
          "Songs you have not got, out of what you have been playing — and a few acts "
          "nobody here has played yet.", out, 0, {"why": whys})
    return out


def _mix_seeds(user_id: int, tas: recommend.Taste) -> dict[str, list[int]]:
    """The acts somebody plays most, each with their songs in the library that
    the person has actually played through."""
    scored = {t: v for t, v in tas.track.items() if v > 0 and t in tas.library}
    if not scored:
        return {}
    rows = db.all_(
        """select id, artists from tracks where id = any(%s) and state <> 'failed'""",
        (list(scored),))
    by_artist: dict[str, list[int]] = {}
    for r in rows:
        for a in (r["artists"] or [])[:1]:
            by_artist.setdefault(a, []).append(r["id"])
    for a in by_artist:
        by_artist[a].sort(key=lambda t: -scored[t])
    ranked = sorted(by_artist.items(), key=lambda kv: -sum(scored[t] for t in kv[1]))
    return {a: ids for a, ids in ranked[:10] if len(ids) >= 2}


def build_daily_mixes(user_id: int, tas: recommend.Taste, *, network: bool = True) -> list[str]:
    """Daily mixes: the library sorted into the kinds of thing this person plays.

    Each of the acts they play most is asked what of theirs and what else of the
    library goes with it; acts whose answers overlap are one kind of thing, and
    each kind becomes a mix — their songs, what goes with them, and a fifth that is
    new. Four at most, and none where there is not enough to tell apart."""
    seeds_by_artist = _mix_seeds(user_id, tas)
    db.run("delete from made_lists where user_id=%s and slug like 'daily:%%'", (user_id,))
    if not seeds_by_artist:
        return []
    answers: dict[str, tuple[set[int], list[recommend.Pick]]] = {}
    for artist, ids in seeds_by_artist.items():
        picks = recommend.recommend(user_id, {t: 1.0 for t in ids[:6]}, limit=30,
                                    fresh=0.2, network=network, the_taste=tas)
        answers[artist] = ({t for t in ids} | {p.key for p in picks if isinstance(p.key, int)},
                           picks)
    groups: list[list[str]] = []
    for artist in answers:
        placed = False
        for g in groups:
            mine = answers[artist][0]
            theirs = set().union(*(answers[a][0] for a in g))
            overlap = len(mine & theirs) / max(1, min(len(mine), len(theirs)))
            if overlap >= 0.3:
                g.append(artist)
                placed = True
                break
        if not placed:
            groups.append([artist])
    groups = [g for g in groups
              if len(set().union(*(answers[a][0] for a in g))) >= 6]
    slugs = []
    for n, g in enumerate(groups[:DAILY_MIXES_MOST], start=1):
        out: list[int] = []
        seen: set[int] = set()
        # Their own songs first, a few per act, then what goes with them in score order.
        for a in g:
            for t in seeds_by_artist[a][:4]:
                if t not in seen:
                    seen.add(t)
                    out.append(t)
        pool = sorted((p for a in g for p in answers[a][1]), key=lambda p: -p.score)
        for p in pool:
            t = _bring_in(p)
            if t and t not in seen:
                seen.add(t)
                out.append(t)
            if len(out) >= LIST_LENGTH["daily"]:
                break
        random.Random(f"{user_id}:{n}:{dt.date.today()}").shuffle(out)
        # The first song should be one that plays now.
        ready = {r["id"] for r in db.all_(
            "select id from tracks where id = any(%s) and state='ready'", (out,))}
        out.sort(key=lambda t: t not in ready)
        slug = f"daily:{n}"
        who = g[:3]
        _save(user_id, slug, f"Daily mix {n}",
              ", ".join(who) + (" and more" if len(seen) > len(who) else ""), out, n,
              {"artists": g})
        slugs.append(slug)
    return slugs


def build_radar(user_id: int, *, network: bool = True) -> list[int]:
    """Release radar: a song from each record that came out this fortnight by the
    artists, labels and genres you follow.

    A Deezer record is opened by its id and its songs found or fetched by name; a
    Bandcamp record — an act's, or one of a label's — is its own page, and the song is
    taken straight off it, in which case the box fetches it itself."""
    out: list[int] = []
    why: dict[int, str] = {}
    # A record reachable through both an act and its label is the act's: the act's
    # follow sorts first and `distinct on` keeps it. Newest first after that.
    rows = db.all_(
        """select distinct on (r.provider, r.album_id)
                  r.provider, r.album_id, r.title, r.artist, r.record_type, r.release_date,
                  f.name as via, f.is_label
             from artist_follows f
             join artist_releases r on r.provider = f.provider and r.artist_id = f.remote_id
            where f.user_id = %s
              and r.release_date >= current_date - %s * interval '1 day'
            order by r.provider, r.album_id, f.is_label""", (user_id, RADAR_DAYS))
    rows.sort(key=lambda r: r["release_date"] or dt.date.min, reverse=True)
    if network:
        for r in rows[:30]:
            reason = (f"new on {r['via']}" if r.get("is_label")
                      else f"new from {r['via'] or r['artist']}")
            found_ids: list[int] = []
            if r["provider"] == "bandcamp":
                try:
                    tracks = [t for t in sources.bandcamp_tracks(r["album_id"]) if t["streamable"]]
                except Exception as e:  # noqa: BLE001 — one page that will not load
                    log.info("radar: %s: %s", r["album_id"], e)
                    tracks = []
                for t in tracks[:1]:
                    known = catalog.find_by_provider("bandcamp", t["provider_id"])
                    if not known:
                        try:
                            known = catalog.create_from_source(
                                "bandcamp", {**t, "raw": t},
                                discovered_via=VIA_DISCOVER, priority=jobs.PRIORITY_BULK)
                        except Exception as e:  # noqa: BLE001
                            log.info("radar: could not add %s: %s", t["title"], e)
                            continue
                    if known and known["state"] != "failed":
                        found_ids.append(known["id"])
            else:
                try:
                    album = discography.album(r["album_id"])
                except discography.Unavailable:
                    break
                tracks = album.get("tracks") or []
                take = tracks[:2] if (r["record_type"] or "") == "album" else tracks[:1]
                for t in take:
                    found = resolve_song(t["title"], (t.get("artists") or [r["artist"]])[0],
                                         album=album.get("title"))
                    if found:
                        found_ids.append(found["id"])
            for t in found_ids:
                if t not in out:
                    out.append(t)
                    why[t] = reason
            if len(out) >= LIST_LENGTH["radar"]:
                break
        genres = genres_of(user_id)
        if genres and len(out) < LIST_LENGTH["radar"]:
            for r in db.all_(
                    """select distinct on (release_mbid) release_mbid, deezer_album_id, title, artist
                         from genre_releases where genre = any(%s)
                          and release_date >= current_date - %s * interval '1 day'
                        order by release_mbid, listens desc""", (genres, RADAR_DAYS)):
                if not r["deezer_album_id"]:
                    continue
                try:
                    album = discography.album(r["deezer_album_id"])
                except discography.Unavailable:
                    break
                tracks = album.get("tracks") or []
                if tracks:
                    found = resolve_song(tracks[0]["title"],
                                         (tracks[0].get("artists") or [r["artist"]])[0],
                                         album=album.get("title"))
                    if found and found["id"] not in out:
                        out.append(found["id"])
                if len(out) >= LIST_LENGTH["radar"]:
                    break
    _save(user_id, "radar", "Release radar",
          "What came out this fortnight by the artists, labels and genres you follow.",
          out, 20, {"why": why})
    return out


def build_repeat(user_id: int) -> list[int]:
    ids = [r["track_id"] for r in db.all_(
        """select l.track_id from listens l join tracks t on t.id = l.track_id
            where l.user_id=%s and l.started_at > now() - interval '30 days'
              and t.state = 'ready' and (l.completed or l.ms_played >= 90000)
            group by 1 order by count(*) desc, max(l.started_at) desc limit %s""",
        (user_id, LIST_LENGTH["repeat"]))]
    _save(user_id, "repeat", "On repeat", "What you have played most this month.", ids, 30)
    return ids


def build_again(user_id: int, tas: recommend.Taste) -> list[int]:
    ids = recommend.rediscover(user_id, limit=LIST_LENGTH["again"], the_taste=tas)
    _save(user_id, "again", "Time capsule",
          "Songs you wore out and then forgot about.", ids, 40)
    return ids


def build_house(user_id: int, tas: recommend.Taste, *, network: bool = True) -> list[int]:
    """The house blend: what everybody here has been playing, made to fit you."""
    rows = db.all_(
        """select track_id, count(distinct user_id) as people, count(*) as plays
             from listens where started_at > now() - interval '45 days'
              and (completed or ms_played >= 90000)
            group by 1 order by people desc, plays desc limit 14""")
    seeds = {r["track_id"]: 0.6 + 0.4 * min(1.0, r["people"] / 3) for r in rows}
    ids: list[int] = []
    if seeds:
        picks = recommend.recommend(user_id, seeds, limit=LIST_LENGTH["house"] - 6, fresh=0.3,
                                    network=network, the_taste=tas,
                                    weights=recommend.PERSON_WEIGHTS)
        ids = [t for t in (_bring_in(p) for p in picks) if t]
        top = [t for t in seeds if t not in ids and t not in tas.recent][:6]
        ids = top + ids
    people = db.one("select count(distinct user_id) as n from listens "
                    "where started_at > now() - interval '45 days'")["n"]
    _save(user_id, "house", "House blend",
          f"What the {people} of you have been playing, made to fit you.", ids, 50)
    return ids


def build_for(user_id: int, *, network: bool = True, force: bool = False) -> dict:
    """Every list for one person. The weekly one only once a week unless forced;
    the rest every time, since they are a morning's work at most."""
    tas = recommend.taste(user_id)
    built = []
    weekly_at = _built_at(user_id, WEEKLY_SLUG)
    if force or weekly_at is None or weekly_at < _this_monday():
        try:
            build_weekly(user_id, tas, network=network)
            built.append(WEEKLY_SLUG)
        except Exception as e:  # noqa: BLE001 — one list failing is not all of them
            log.exception("weekly for %s failed: %s", user_id, e)
    for name, fn in (("daily", lambda: build_daily_mixes(user_id, tas, network=network)),
                     ("radar", lambda: build_radar(user_id, network=network)),
                     ("trending", lambda: build_trending(user_id, tas) if network else []),
                     ("repeat", lambda: build_repeat(user_id)),
                     ("again", lambda: build_again(user_id, tas)),
                     ("house", lambda: build_house(user_id, tas, network=network))):
        try:
            fn()
            built.append(name)
        except Exception as e:  # noqa: BLE001
            log.exception("%s for %s failed: %s", name, user_id, e)
    # Lists with nothing in them are not shown; an empty radar is no news, not a page.
    db.run("delete from made_lists where user_id=%s and cardinality(track_ids) = 0", (user_id,))
    # And the lookups the page itself is not allowed to make: who these acts are to
    # MusicBrainz, and who goes with them — asked now, read from the cache by day.
    if network:
        try:
            suggested_genres(user_id, tas, ask=True)
            artists_to_try(user_id, tas, ask=True)
        except Exception as e:  # noqa: BLE001
            log.info("could not warm the map for %s: %s", user_id, e)
    if _publish:
        try:
            _publish("discover_ready", {"user_id": user_id, "built": built}, to_user=user_id)
        except Exception:  # noqa: BLE001
            pass
    return {"built": built}


def keep(user_id: int, slug: str) -> int:
    """A made list as a playlist of your own, as it is this minute."""
    entry = one_list(user_id, slug)
    if not entry:
        raise LookupError(slug)
    stamp = dt.date.today().strftime("%-d %b")
    name = f"{entry['name']} · {stamp}"
    row = db.one("insert into playlists(owner_id, name) values(%s,%s) returning id",
                 (user_id, name))
    ids = [t["id"] for t in entry["tracks"]]
    if ids:
        db.run(
            """insert into playlist_items(playlist_id, pos, track_id)
               select %s, n, t from unnest(%s::int[]) with ordinality as u(t, n)""",
            (row["id"], ids))
    return row["id"]


# ------------------------------------------------------------------ the job
def poll() -> dict:
    """Everybody's lists, and every followed genre's news, once."""
    genres = {r["genre"] for r in db.all_("select distinct genre from genre_follows")}
    for g in sorted(genres):
        try:
            refresh_genre(g)
        except Exception as e:  # noqa: BLE001
            log.info("genre %s: %s", g, e)
    users = db.all_("select id from users order by id")
    done = 0
    for u in users:
        try:
            build_for(u["id"])
            done += 1
        except Exception as e:  # noqa: BLE001
            log.exception("discover for %s failed: %s", u["id"], e)
    return {"users": done, "genres": len(genres)}


def seconds_until_build() -> float:
    now = dt.datetime.now()
    at = now.replace(hour=BUILD_HOUR, minute=BUILD_MINUTE, second=0, microsecond=0)
    if at <= now:
        at += dt.timedelta(days=1)
    return (at - now).total_seconds()


def ensure_scheduled(delay: float | None = None) -> None:
    """One build job outstanding at a time. See follows.ensure_scheduled."""
    pending = db.one(
        "select 1 from jobs where kind='discover_build' and state in ('pending','leased')")
    if pending:
        return
    jobs.enqueue("discover_build", {}, priority=jobs.PRIORITY_BULK,
                 delay_seconds=delay if delay is not None else seconds_until_build())


def ask_for(user_id: int) -> bool:
    """A build for one person now, if none is on its way. Returns whether one is."""
    row = db.one(
        """select 1 from jobs where kind='discover_build' and state in ('pending','leased')
            and (payload->>'user_id' = %s or next_attempt_at <= now() + interval '2 minutes')""",
        (str(user_id),))
    if row:
        return True
    jobs.enqueue("discover_build", {"user_id": user_id}, priority=jobs.PRIORITY_QUEUE)
    return True


def run_job(payload: dict) -> dict:
    """What the worker calls: one person's lists, or the nightly round."""
    if payload.get("user_id"):
        return build_for(int(payload["user_id"]))
    return poll()


# ------------------------------------------------------------------ the feed
# What a card can say under the song: the tags the record carries where it came from
# (Bandcamp and SoundCloud both have them), the genres Deezer and MusicBrainz file the
# record and the act under, and what people said — Bandcamp's "supported by" box and
# SoundCloud's comments. Kept a week; a card is looked at more than once.
CARD_TTL = 7 * 86400
COMMENTS_MOST = 5


def cards(user_id: int, offset: int = 0, limit: int = 20) -> dict:
    """The songs the page would put in front of this person, one after another: new
    records by who and what they follow first, then this week's finds, then the daily
    mixes and the house blend — nothing they have played lately, and each song once."""
    lists = {entry["slug"]: entry for entry in lists_for(user_id, tracks=False)}
    recent = {r["track_id"] for r in db.all_(
        """select distinct track_id from listens where user_id=%s
            and started_at > now() - interval '36 hours'""", (user_id,))}
    rows = db.all_("select slug, track_ids, meta from made_lists where user_id=%s "
                   "order by ordinal", (user_id,))
    by_slug = {r["slug"]: r for r in rows}
    # The radar first, then the finds; then what is trending in each followed genre,
    # a song from each in turn so no one genre takes the whole stretch; then the mixes.
    trend = [slug for slug in by_slug if slug.startswith("trend:")]
    order: list[list[str]] = [["radar"], [WEEKLY_SLUG], trend,
                              ["daily:1", "daily:2", "daily:3", "daily:4"], ["house"], ["again"]]
    picked: list[tuple[int, str, str]] = []
    seen: set[int] = set()
    for group in order:
        lanes = []
        for slug in group:
            row = by_slug.get(slug)
            if not row:
                continue
            meta = row["meta"] if isinstance(row["meta"], dict) else json.loads(row["meta"] or "{}")
            lanes.append((slug, list(row["track_ids"] or []), meta.get("why") or {}))
        # Round robin across the group's lists (one list is simply its own order).
        while any(ids for _, ids, _ in lanes):
            for slug, ids, whys in lanes:
                if not ids:
                    continue
                t = ids.pop(0)
                if t in seen or t in recent:
                    continue
                seen.add(t)
                picked.append((t, slug, whys.get(str(t)) or ""))
    total = len(picked)
    page = picked[offset:offset + limit]
    tracks = recommend._rows_for([t for t, _, _ in page])
    items = []
    for t, slug, why in page:
        row = tracks.get(t)
        if not row or row["state"] == "failed":
            continue
        entry = lists.get(slug) or {}
        items.append({"track": catalog.public(row), "list": slug,
                      "list_name": entry.get("name") or slug,
                      "why": why or _card_why(slug, entry)})
    return {"items": items, "total": total, "offset": offset}


def _card_why(slug: str, entry: dict) -> str:
    kind = slug.split(":")[0]
    if kind == "trend":
        return "trending in " + slug.partition(":")[2]
    return {"radar": "new from somebody you follow", "weekly": "new to you this week",
            "daily": "from " + (entry.get("name") or "a daily mix"),
            "house": "what the house is playing", "again": "one you wore out and forgot"}.get(kind, "")


def card_details(track_id: int) -> dict:
    """Genres and comments for a song, from wherever it came from. Cached a week."""
    key = f"card:{track_id}"
    cached = brainz._cached(key, CARD_TTL)
    if cached is not None:
        return cached
    row = db.one(
        """select t.id, t.title, t.artists, t.album, s.provider, s.provider_id, s.raw
             from tracks t left join track_sources s on s.track_id = t.id
            where t.id = %s order by (s.provider = 'ytmusic') limit 1""", (track_id,))
    if not row:
        return {"genres": [], "comments": [], "about": None, "source": None, "url": None}
    raw = row["raw"] if isinstance(row["raw"], dict) else json.loads(row["raw"] or "{}")
    genres: list[str] = []
    comments: list[dict] = []
    about = None
    url = None
    try:
        if row["provider"] == "bandcamp" and (raw.get("url") or raw.get("pageUrl")):
            url = (raw.get("url") or raw.get("pageUrl")).split("#")[0]
            rec = linked.bandcamp_record(url)
            genres = rec["tags"]
            comments = rec["reviews"]
            about = rec.get("about")
        elif row["provider"] == "soundcloud" and row["provider_id"]:
            sc = linked.soundcloud_track(row["provider_id"])
            genres = sc["tags"]
            comments = sc["reviews"]
            about = sc.get("about")
            url = sc.get("url")
    except Exception as e:  # noqa: BLE001 — a page that will not load leaves the card plain
        log.info("card %s: %s", track_id, e)
    if not genres:
        genres = _deezer_genres(row["album"], (row["artists"] or [None])[0])
    first = (row["artists"] or [None])[0]
    if first:
        entry = _artist_entry(first, ask=False)
        for g in (entry or {}).get("genres") or []:
            if g not in genres:
                genres.append(g)
    out = {"genres": genres[:10], "comments": comments[:COMMENTS_MOST], "about": about,
           "source": row["provider"], "url": url}
    brainz._store(key, out)
    return out


def _deezer_genres(album: str | None, artist: str | None) -> list[str]:
    """The genres Deezer files a record under — a short list, but one every record
    on it has, which is more than can be said for anywhere else."""
    if not album:
        return []
    try:
        found = discography.find_album(album, artist)
        if not found:
            return []
        raw = discography._get(f"/album/{found['id']}", kind="album")
    except discography.Unavailable:
        return []
    return [g["name"].lower() for g in ((raw.get("genres") or {}).get("data") or [])
            if g.get("name")]


# ------------------------------------------------------------------ trending by genre
# What is being played this week in a genre, from the two places that say so and
# serve the audio themselves: SoundCloud's search, asked for last week's most played
# under the genre, and Bandcamp's discover page, asked for the tag's best sellers.
# Both land as tracks the box fetches itself (no residential worker needed).
TREND_GENRES_MOST = 8
TREND_PER_GENRE = 12
TREND_TTL = 12 * 3600


def trending_named(genre: str) -> list[dict]:
    """Songs trending in a genre, named: provider, provider_id, title, artists, url,
    album. Kept half a day in remote_cache."""
    g = _norm(genre)
    key = f"trend:{g}"
    cached = brainz._cached(key, TREND_TTL)
    if cached is not None:
        return cached
    out: list[dict] = []
    try:
        page = linked._sc_api("/search/tracks", q="", limit=TREND_PER_GENRE, sort="popular",
                              **{"filter.genre_or_tag": g, "filter.created_at": "last_week"})
        for t in page.get("collection") or []:
            item = linked._sc_item(t)
            if item and item["title"]:
                out.append({"provider": "soundcloud", "provider_id": item["remote_id"],
                            "title": item["title"], "artists": item["artists"], "album": None,
                            "duration_ms": item["duration_ms"],
                            "url": item["source"]["url"], "page": t.get("permalink_url")})
    except Exception as e:  # noqa: BLE001
        log.info("soundcloud trending %s: %s", g, e)
    try:
        for a in bandcamp_discover(g, most=6):
            try:
                tracks = [t for t in sources.bandcamp_tracks(a["url"]) if t["streamable"]]
            except Exception:  # noqa: BLE001
                continue
            if not tracks:
                continue
            t = tracks[0]
            out.append({"provider": "bandcamp", "provider_id": t["provider_id"],
                        "title": t["title"], "artists": t["artists"], "album": t["album"],
                        "duration_ms": t["duration_ms"], "url": t["url"], "page": a["url"]})
    except Exception as e:  # noqa: BLE001
        log.info("bandcamp trending %s: %s", g, e)
    brainz._store(key, out)
    return out


def bandcamp_discover(tag: str, most: int = 6, slice_: str = "top") -> list[dict]:
    """Bandcamp's discover page for a tag: its best sellers ("top") or new arrivals."""
    body = _json.dumps({"tag_norm_names": [tag.replace(" ", "-")], "geoname_id": 0,
                        "slice": slice_, "time_facet_id": None, "cursor": "*",
                        "size": most, "include_result_types": ["a", "t"]}).encode()
    req = urllib.request.Request("https://bandcamp.com/api/discover/1/discover_web", data=body,
                                 headers={"Content-Type": "application/json",
                                          "User-Agent": sources.UA})
    data = _json.loads(urllib.request.urlopen(req, timeout=30).read())
    out = []
    for r in data.get("results") or []:
        url = (r.get("item_url") or "").split("?")[0]
        if url:
            out.append({"url": url, "title": r.get("title"), "artist": r.get("band_name")})
    return out


def trending_tracks(genre: str, user_id: int) -> list[int]:
    """Trending songs in a genre as tracks here, found or brought in."""
    ids: list[int] = []
    for item in trending_named(genre):
        known = catalog.find_by_provider(item["provider"], item["provider_id"])
        if not known:
            try:
                known = catalog.create_from_source(
                    item["provider"],
                    {"provider_id": item["provider_id"], "title": item["title"],
                     "artists": item["artists"], "album": item["album"],
                     "duration_ms": item["duration_ms"], "url": item["url"],
                     "raw": {k: v for k, v in item.items() if k != "page"}},
                    discovered_via=VIA_DISCOVER, priority=jobs.PRIORITY_BULK)
            except Exception as e:  # noqa: BLE001
                log.info("could not add %s: %s", item["title"], e)
                continue
        if known and known["state"] != "failed" and known["id"] not in ids:
            ids.append(known["id"])
    return ids


def build_trending(user_id: int, tas: recommend.Taste | None = None) -> list[str]:
    """A list per genre this person follows — or, following none yet, the few they
    seem to play — of what is trending in it this week."""
    genres = genres_of(user_id)[:TREND_GENRES_MOST]
    if not genres:
        tas = tas or recommend.taste(user_id)
        genres = [g["genre"] for g in suggested_genres(user_id, tas, limit=3)]
    db.run("delete from made_lists where user_id=%s and slug like 'trend:%%'", (user_id,))
    slugs = []
    for n, g in enumerate(genres):
        ids = trending_tracks(g, user_id)
        if not ids:
            continue
        slug = f"trend:{g}"
        _save(user_id, slug, f"Trending in {g}",
              f"What is being played this week in {g}, on SoundCloud and Bandcamp.",
              ids, 10 + n, {"genre": g})
        slugs.append(slug)
    return slugs
