"""A station: a playlist the machine writes, and keeps writing.

The radio this replaces was a button that appended five machine-picked songs to the
end of whatever you were listening to. Then a station was a queue of its own — twelve
songs, eight more as it ran down — which was the right idea and the wrong shape: a
queue is where you are, not something to look through. You could not see what was
coming, start it from its tenth song, or find it again in the library, and opening one
threw out what was playing.

So a station is now a *playlist*, of the kind "station": thirty songs to look through
before putting any of them on, played like any other list (from the top, shuffled, or
from the song you tapped), filed in the library with the rest, and asked for more or
written again from scratch whenever you like. What makes it a station rather than a
list somebody made is that the machine wrote it and will go on writing it: a queue
made from one remembers it (queues.station_id) and is topped up from it as it is
listened through, and a song listened through there joins the seeds, a song skipped in
its first half minute steers it away.

Where the songs come from: recommend.py — the house's lists and sittings, how records
sound, and YouTube Music's watch playlist for the seeds. A station has *several*
seeds — a record is its own tracks, an artist is what of theirs is already here — and
reaches past the library as far as `fresh` says: 0 only what is yours and here, 1 only
what is new. A new song is written down but not fetched until the station is played:
thirty songs to look at should not be thirty downloads.
"""
from __future__ import annotations

import logging

from . import catalog, db, discover, jobs, recommend

log = logging.getLogger("muse.stations")

KIND = "station"

# How many to write into a new station, and how many more each time it is asked.
FIRST = 30
MORE = 20

# Never more than this in one go, whatever is asked for.
MOST = 40

# How many different songs a station is seeded from. More than this and the watch
# playlists start to overlap anyway.
SEEDS = 4

# How many stations a person keeps. Every station is a playlist in the library, and
# one started from every song that was ever good is a library of stations; the oldest
# untouched go, unless pinned.
KEEP = 24


def seed_tracks(kind: str, *, user_id: int, track_id: int | None,
                album: str | None, artist: str | None,
                genre: str | None = None) -> list[dict]:
    """The songs a station is built out of.

    One for a song; the record itself for an album; whatever of an artist is already
    in the library for an artist; for a genre, what the world plays under that name,
    found or fetched (discover.genre_seeds).
    """
    if kind == "genre":
        return discover.genre_seeds(genre or "", user_id, most=SEEDS)
    if kind == "track":
        row = catalog.track_row(track_id) if track_id else None
        return [row] if row else []

    if kind == "album":
        rows = db.all_(
            """select t.*, s.provider_id
                 from tracks t
                 join library_items li on li.track_id = t.id and li.user_id = %s
                 left join track_sources s
                   on s.track_id = t.id and s.provider = 'ytmusic'
                where t.album = %s
                  -- cast, or Postgres cannot tell what type a null parameter is
                  and (%s::text is null or coalesce(t.artists[1], '') = %s)
                order by t.id""",
            (user_id, album, artist, artist),
        )
    elif kind == "artist":
        rows = db.all_(
            """select t.*, s.provider_id
                 from tracks t
                 join library_items li on li.track_id = t.id and li.user_id = %s
                 left join track_sources s
                   on s.track_id = t.id and s.provider = 'ytmusic'
                where %s = any(t.artists)
                order by (select count(*) from listens l where l.track_id = t.id) desc,
                         t.id
                limit 40""",
            (user_id, artist),
        )
    else:
        raise ValueError(f"a station cannot be made from {kind!r}")

    # The ones YouTube Music knows first, as they can be asked about there too; but a
    # record it does not know still has the house's own lists and its sound to go on.
    with_ids = [r for r in rows if r.get("provider_id")] or rows
    if len(with_ids) <= SEEDS:
        return with_ids
    # Spread across the record rather than the first four tracks of it.
    step = len(with_ids) / SEEDS
    return [with_ids[int(i * step)] for i in range(SEEDS)]


def name_for(kind: str, seeds: list[dict], *, album: str | None,
             artist: str | None, genre: str | None = None) -> str:
    if kind == "genre" and genre:
        return f"{genre.title()} radio"
    if kind == "album" and album:
        return f"{album} radio"
    if kind == "artist" and artist:
        return f"{artist} radio"
    if seeds:
        title = seeds[0].get("title") or "Radio"
        return f"{title} radio"
    return "Radio"


def gather(seeds: list[dict], *, user_id: int, wanted: int, fresh: float = 0.5,
           playlist_id: int | None = None, since=None,
           avoid_tracks: set[int] = frozenset()) -> list[int]:
    """Find songs for a station, and put them in the catalog.

    Songs that are here play at once and songs that are not have to be fetched first,
    so the answer is laid out with the ones that are here in front and the others
    between them — a new song is never the very next one while it is still coming.
    The ones that are not here are written down, not fetched: the queue made from the
    station asks for them when it is played (prioritise_queue).
    """
    wanted = max(1, min(wanted, MOST))
    weights = {s["id"]: 1.0 for s in seeds}
    avoid: dict[int, float] = {}
    if playlist_id is not None:
        heard = db.all_(
            """select l.track_id, bool_or(l.completed) as done, max(l.ms_played) as ms,
                      max(l.started_at) as at
                 from listens l
                where l.user_id = %s
                  and l.track_id in (select track_id from playlist_items where playlist_id = %s)
                  and (%s::timestamptz is null or l.started_at >= %s)
                group by 1 order by at desc""",
            (user_id, playlist_id, since, since))
        for n, r in enumerate(heard):
            if r["done"]:
                if len([w for w in weights.values() if w < 1]) < 8:
                    weights.setdefault(r["track_id"], max(0.3, 0.7 - 0.05 * n))
            elif (r["ms"] or 0) < recommend.SKIP_MS:
                avoid[r["track_id"]] = 1.0
    picks = recommend.recommend(user_id, weights, limit=wanted, fresh=fresh,
                                exclude=set(avoid_tracks), avoid=avoid)
    if len(picks) < wanted and playlist_id is not None:
        # Run dry around the seeds: walk on from the station's own latest songs, the
        # way a radio drifts — never from one that was skipped.
        latest = db.all_(
            """select track_id from playlist_items where playlist_id = %s
                order by pos desc limit 6""", (playlist_id,))
        walk = {r["track_id"]: 0.5 for r in latest
                if r["track_id"] not in avoid and r["track_id"] not in weights}
        if walk:
            taken = {p.key for p in picks if isinstance(p.key, int)}
            more = recommend.recommend(
                user_id, walk, limit=wanted - len(picks), fresh=fresh,
                exclude=set(avoid_tracks) | taken | set(weights), avoid=avoid)
            have = {p.key for p in picks}
            picks += [p for p in more if p.key not in have]
    here, coming = [], []
    for p in picks:
        if isinstance(p.key, int):
            if p.where not in ("library", "house"):
                coming.append(p.key)
            else:
                here.append(p.key)
        else:
            meta = p.row
            known = catalog.find_by_video_id(meta["video_id"])
            track = known or catalog.create_from_ytm(
                {"video_id": meta["video_id"], "title": meta.get("title") or meta["video_id"],
                 "artists": meta.get("artists") or [], "album": meta.get("album"),
                 "duration_ms": meta.get("duration_ms"),
                 "raw": {"thumbnails": meta.get("thumbnails") or []}},
                discovered_via=catalog.VIA_RADIO, priority=jobs.PRIORITY_BULK, download=False)
            coming.append(track["id"])
    # Two that are here, then one that is coming, and so on.
    out: list[int] = []
    while here or coming:
        out.extend(here[:2])
        here = here[2:]
        if coming:
            out.append(coming.pop(0))
    return out


# ------------------------------------------------------------------ the playlist
def _append(playlist_id: int, track_ids: list[int]) -> int:
    """Put [track_ids] on the end of the playlist, skipping any already on it."""
    if not track_ids:
        return 0
    have = {r["track_id"] for r in db.all_(
        "select track_id from playlist_items where playlist_id=%s", (playlist_id,))}
    fresh_ids = [t for t in dict.fromkeys(track_ids) if t not in have]
    if not fresh_ids:
        return 0
    last = db.one("select coalesce(max(pos), -1) as pos from playlist_items where playlist_id=%s",
                  (playlist_id,))["pos"]
    with db.pool().connection() as c:
        c.cursor().executemany(
            "insert into playlist_items(playlist_id, pos, track_id) values(%s,%s,%s)",
            [(playlist_id, last + 1 + n, t) for n, t in enumerate(fresh_ids)])
    return len(fresh_ids)


def held(playlist_id: int) -> set[int]:
    """What a station already holds, as track ids."""
    return {r["track_id"] for r in
            db.all_("select track_id from playlist_items where playlist_id=%s", (playlist_id,))}


def by_id(station_id: int, user_id: int | None = None) -> dict | None:
    row = db.one(
        """select s.*, p.name as playlist_name from stations s
             join playlists p on p.id = s.playlist_id
            where s.id = %s and (%s::int is null or s.owner_id = %s)""",
        (station_id, user_id, user_id))
    return dict(row) if row else None


def by_playlist(playlist_id: int) -> dict | None:
    """What station this playlist is, if it is one — the few facts the page shows."""
    row = db.one("select id, kind, seed_track, seed_text, fresh, created_at, updated_at "
                 "from stations where playlist_id=%s", (playlist_id,))
    return dict(row) if row else None


def describe_queue(queue_id: int) -> dict | None:
    """What station this queue plays, if it plays one: made from a station's playlist
    (queues.station_id), or a station of the old shape that *was* a queue."""
    row = db.one(
        """select s.id, s.kind, s.name, s.seed_track, s.seed_text, s.fresh, s.created_at,
                  s.playlist_id
             from stations s
             join queues q on q.station_id = s.id or (s.queue_id = q.id and s.playlist_id is null)
            where q.id = %s
            order by (q.station_id = s.id) desc limit 1""", (queue_id,))
    return dict(row) if row else None


def seeds_of(station: dict, user_id: int) -> list[dict]:
    kind = station["kind"]
    seeds = seed_tracks(
        kind, user_id=user_id, track_id=station["seed_track"],
        album=station["seed_text"] if kind == "album" else None,
        artist=station["seed_text"] if kind == "artist" else None,
        genre=station["seed_text"] if kind == "genre" else None)
    if not seeds:
        # The record it was made from has been taken out of the library since.
        seed = catalog.track_row(station["seed_track"]) if station["seed_track"] else None
        seeds = [seed] if seed else []
    return seeds


def create(user_id: int, kind: str, *, track_id: int | None, album: str | None,
           artist: str | None, genre: str | None, fresh: float) -> dict | None:
    """A new station as a playlist of its own: the seeds first, so a station from a
    song starts with that song, then what belongs next to them. Starting the same
    station twice writes it again rather than making a second. None where there is
    nothing to build it from. Returns {"playlist_id", "station_id", "added"}."""
    seeds = seed_tracks(kind, user_id=user_id, track_id=track_id,
                        album=album, artist=artist, genre=genre)
    if not seeds:
        return None
    name = name_for(kind, seeds, album=album, artist=artist, genre=genre)
    db.run("delete from playlists where owner_id=%s and name=%s and kind=%s",
           (user_id, name, KIND))
    playlist = db.one(
        """insert into playlists(owner_id, name, kind, sort, download_mode)
           values(%s,%s,%s,'manual','on_play') returning id""",
        (user_id, name, KIND))
    station = db.one(
        """insert into stations(owner_id, playlist_id, kind, seed_track, seed_text, name, fresh)
           values(%s,%s,%s,%s,%s,%s,%s) returning id""",
        (user_id, playlist["id"], kind, seeds[0]["id"],
         {"album": album, "artist": artist, "genre": genre}.get(kind), name, fresh))
    _append(playlist["id"], [s["id"] for s in seeds][:SEEDS])
    found = gather(seeds, user_id=user_id, wanted=FIRST, fresh=fresh,
                   avoid_tracks=held(playlist["id"]))
    added = _append(playlist["id"], found)
    prune(user_id)
    return {"playlist_id": playlist["id"], "station_id": station["id"], "added": added}


def extend(station: dict, user_id: int, wanted: int = MORE) -> list[int]:
    """More of the same on the end of the station: what it has heard of how it went
    since it was written (gather) steers it. The ids put on, in order."""
    seeds = seeds_of(station, user_id)
    if not seeds:
        return []
    found = gather(seeds, user_id=user_id, wanted=wanted, fresh=station["fresh"],
                   playlist_id=station["playlist_id"], since=station["created_at"],
                   avoid_tracks=held(station["playlist_id"]))
    have = held(station["playlist_id"])
    found = [t for t in found if t not in have]
    _append(station["playlist_id"], found)
    touch(station["id"])
    return found


def refresh(station: dict, user_id: int) -> int:
    """The station written again: everything but its seeds goes, and what belongs next
    to them is found afresh — a different answer, since the ones just taken out are
    kept away from, and what was listened through meanwhile counts."""
    seeds = seeds_of(station, user_id)
    pid = station["playlist_id"]
    seed_ids = {s["id"] for s in seeds}
    was = held(pid)
    db.run("delete from playlist_items where playlist_id=%s and not (track_id = any(%s))",
           (pid, list(seed_ids)))
    if not seeds:
        return 0
    found = gather(seeds, user_id=user_id, wanted=FIRST, fresh=station["fresh"],
                   playlist_id=pid, since=station["created_at"],
                   avoid_tracks=was)
    if len(found) < FIRST // 2:
        # Too few left outside what it had: the old ones may come back rather than a
        # station of six.
        found += gather(seeds, user_id=user_id, wanted=FIRST - len(found),
                        fresh=station["fresh"], playlist_id=pid,
                        avoid_tracks=seed_ids | set(found))
    added = _append(pid, found)
    touch(station["id"])
    return added


def tune(station_id: int, fresh: float) -> None:
    db.run("update stations set fresh=%s, updated_at=now() where id=%s", (fresh, station_id))


def touch(station_id: int) -> None:
    db.run("update stations set updated_at=now() where id=%s", (station_id,))


def prune(user_id: int) -> int:
    """The oldest untouched stations beyond KEEP go, unless pinned in the library."""
    rows = db.all_(
        """select s.playlist_id from stations s
             left join playlist_places pl on pl.playlist_id = s.playlist_id and pl.user_id = s.owner_id
            where s.owner_id = %s and s.playlist_id is not null
              and coalesce(pl.pinned, false) = false
            order by s.updated_at desc offset %s""", (user_id, KEEP))
    for r in rows:
        db.run("delete from playlists where id=%s", (r["playlist_id"],))
    return len(rows)


def adopt_queues() -> int:
    """Stations of the old shape — a queue with the station's name — become playlists,
    once, at start-up: the queue's songs in its order, the queue left as it was and
    pointed at the station it now plays."""
    old = db.all_(
        """select s.id, s.queue_id, s.owner_id, s.name from stations s
            where s.playlist_id is null and s.queue_id is not null""")
    for s in old:
        try:
            db.run("delete from playlists where owner_id=%s and name=%s and kind=%s",
                   (s["owner_id"], s["name"], KIND))
            playlist = db.one(
                """insert into playlists(owner_id, name, kind, sort, download_mode)
                   values(%s,%s,%s,'manual','on_play') returning id""",
                (s["owner_id"], s["name"], KIND))
            with db.pool().connection() as c:
                c.execute(
                    """insert into playlist_items(playlist_id, pos, track_id)
                       select %s, row_number() over (order by pos) - 1, track_id
                         from queue_items where queue_id = %s""",
                    (playlist["id"], s["queue_id"]))
            db.run("update stations set playlist_id=%s where id=%s", (playlist["id"], s["id"]))
            db.run("update queues set station_id=%s where id=%s", (s["id"], s["queue_id"]))
        except Exception as e:                           # noqa: BLE001
            log.warning("could not carry station %s over to a playlist: %s", s["id"], e)
    if old:
        log.info("%d stations carried over to playlists", len(old))
    return len(old)
