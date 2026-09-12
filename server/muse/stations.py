"""A station: a queue that keeps going.

The radio this replaces was a button that appended five machine-picked songs to the
end of whatever you were listening to. A station is the other idea — the one every
music app means by "radio": you point at a song, a record or an artist, and that
becomes what is playing, for as long as you leave it on. It is a queue of its own, so
everything a queue can do it can do: reorder it, take songs out, keep it on the device,
save it to the library as a playlist.

Where the songs come from: YouTube Music's watch playlist for a seed, which is the same
well the old radio drew from. What is new is that a station has *several* seeds — a
record is its own tracks, an artist is what of theirs is already here — and that it is
asked for more as it runs down rather than once at the start.
"""
from __future__ import annotations

from . import catalog, db, match, ytm

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
                album: str | None, artist: str | None) -> list[dict]:
    """The songs a station is built out of.

    One for a song; the record itself for an album; whatever of an artist is already
    in the library for an artist. Only songs with a YouTube Music id are any use —
    that id is what the watch playlist is asked for.
    """
    if kind == "track":
        row = catalog.track_row(track_id) if track_id else None
        return [row] if row and row.get("provider_id") else []

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

    with_ids = [r for r in rows if r.get("provider_id")]
    if len(with_ids) <= SEEDS:
        return with_ids
    # Spread across the record rather than the first four tracks of it.
    step = len(with_ids) / SEEDS
    return [with_ids[int(i * step)] for i in range(SEEDS)]


def name_for(kind: str, seeds: list[dict], *, album: str | None,
             artist: str | None) -> str:
    if kind == "album" and album:
        return f"{album} radio"
    if kind == "artist" and artist:
        return f"{artist} radio"
    if seeds:
        title = seeds[0].get("title") or "Radio"
        return f"{title} radio"
    return "Radio"


def gather(seeds: list[dict], *, wanted: int, avoid_tracks: set[int],
           avoid_videos: set[str]) -> list[int]:
    """Find songs for a station, and put them in the catalog.

    Taken a few from each seed in turn rather than all of one and then all of the
    next: a station seeded from a whole record should sound like the record, not like
    its first track.
    """
    wanted = max(1, min(wanted, MOST))
    added: list[int] = []
    wells = [ytm.watch_playlist(s["provider_id"], limit=wanted * 3) for s in seeds]

    depth = 0
    while len(added) < wanted and any(depth < len(w) for w in wells):
        for well, seed in zip(wells, seeds):
            if len(added) >= wanted or depth >= len(well):
                continue
            cand = well[depth]
            video = cand.get("video_id")
            if not video or video in avoid_videos:
                continue
            known = catalog.find_by_video_id(video)
            if known and known["id"] in avoid_tracks:
                avoid_videos.add(video)
                continue
            # A near-copy of the seed is not a station, it is the same song again.
            conf, _ = match.score(
                {"title": seed["title"], "artists": seed["artists"],
                 "duration_ms": seed["duration_ms"]},
                cand)
            if conf >= match.AUTO_ACCEPT:
                avoid_videos.add(video)
                continue
            track = known or catalog.create_from_ytm(
                cand, discovered_via=catalog.VIA_RADIO)
            added.append(track["id"])
            avoid_tracks.add(track["id"])
            avoid_videos.add(video)
        depth += 1
    return added


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
    row = db.one("select kind, name, seed_track, seed_text from stations "
                 "where queue_id=%s", (queue_id,))
    return dict(row) if row else None
