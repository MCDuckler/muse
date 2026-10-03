"""A station: a queue that keeps going.

The radio this replaces was a button that appended five machine-picked songs to the
end of whatever you were listening to. A station is the other idea — the one every
music app means by "radio": you point at a song, a record or an artist, and that
becomes what is playing, for as long as you leave it on. It is a queue of its own, so
everything a queue can do it can do: reorder it, take songs out, keep it on the device,
save it to the library as a playlist.

Where the songs come from: recommend.py — the house's lists and sittings, how records
sound, and YouTube Music's watch playlist for the seeds, which was once the only well.
A station has *several* seeds — a record is its own tracks, an artist is what of
theirs is already here — and it is asked for more as it runs down rather than once at
the start. Each time it is asked it has heard how it went: a song listened through on
it joins the seeds, a song skipped in the first half minute steers it away from its
neighbours. And it reaches past the library as far as `fresh` says — 0 only what is
yours and here, 1 only what is new — so it no longer has to be fifty downloads.
"""
from __future__ import annotations

from . import catalog, db, discover, jobs, recommend

# How many to put in a fresh station, and how many to add each time it runs low.
#
# Every accepted candidate is a download and a file on the box for ever, so these are
# deliberately modest: a station that is never listened past its tenth song should not
# have cost fifty downloads.
FIRST = 12
MORE = 8

# Never more than this in one go, whatever is asked for.
MOST = 25

# How many different songs a station is seeded from. More than this and the watch
# playlists start to overlap anyway.
SEEDS = 4


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
           queue_id: int | None = None, since=None,
           avoid_tracks: set[int] = frozenset()) -> list[int]:
    """Find songs for a station, and put them in the catalog.

    Songs that are here play at once and songs that are not have to be fetched first,
    so the answer is laid out with the ones that are here in front and the others
    between them — a new song is never the very next one while it is still coming.
    """
    wanted = max(1, min(wanted, MOST))
    weights = {s["id"]: 1.0 for s in seeds}
    avoid: dict[int, float] = {}
    if queue_id is not None:
        heard = db.all_(
            """select l.track_id, bool_or(l.completed) as done, max(l.ms_played) as ms,
                      max(l.started_at) as at
                 from listens l
                where l.user_id = %s
                  and l.track_id in (select track_id from queue_items where queue_id = %s)
                  and (%s::timestamptz is null or l.started_at >= %s)
                group by 1 order by at desc""",
            (user_id, queue_id, since, since))
        for n, r in enumerate(heard):
            if r["done"]:
                if len([w for w in weights.values() if w < 1]) < 8:
                    weights.setdefault(r["track_id"], max(0.3, 0.7 - 0.05 * n))
            elif (r["ms"] or 0) < recommend.SKIP_MS:
                avoid[r["track_id"]] = 1.0
    picks = recommend.recommend(user_id, weights, limit=wanted, fresh=fresh,
                                exclude=set(avoid_tracks), avoid=avoid)
    if len(picks) < wanted and queue_id is not None:
        # Run dry around the seeds: walk on from the station's own latest songs, the
        # way a radio drifts — never from one that was skipped.
        latest = db.all_(
            """select track_id from queue_items where queue_id = %s
                order by pos desc limit 6""", (queue_id,))
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
                jobs.promote(p.key, priority=jobs.PRIORITY_QUEUE)
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
                discovered_via=catalog.VIA_RADIO, priority=jobs.PRIORITY_QUEUE)
            coming.append(track["id"])
    # Two that are here, then one that is coming, and so on.
    out: list[int] = []
    while here or coming:
        out.extend(here[:2])
        here = here[2:]
        if coming:
            out.append(coming.pop(0))
    return out


def already_in(queue_id: int) -> tuple[set[int], set[str]]:
    """What a queue already holds, as track ids and as YouTube Music ids."""
    tracks = {r["track_id"] for r in
              db.all_("select track_id from queue_items where queue_id=%s", (queue_id,))}
    videos = {r["provider_id"] for r in db.all_(
        """select s.provider_id from queue_items i
             join track_sources s on s.track_id = i.track_id
            where i.queue_id = %s and s.provider = 'ytmusic'""", (queue_id,))}
    return tracks, videos


def describe(queue_id: int) -> dict | None:
    """What station this queue is, if it is one."""
    row = db.one("select kind, name, seed_track, seed_text, fresh, created_at "
                 "from stations where queue_id=%s", (queue_id,))
    return dict(row) if row else None
