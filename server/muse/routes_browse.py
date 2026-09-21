"""Browsing your own library.

Albums and artists are not stored as entities — they are what the enrichment pipeline
wrote onto each track. Deriving them in a query keeps one source of truth: fix a
track's album and the album view fixes itself, with nothing to re-import or migrate.

"Your own" is the join to library_items on every query here. The catalog is shared —
one download serves everybody — but a library is a person's, and without that join
every account saw every track on the box.
"""
from __future__ import annotations

import re

from fastapi import APIRouter, Body, Depends, HTTPException, Query

from . import catalog, db, discography, follows, jobs, sync
from .deps import current_user

router = APIRouter(prefix="/library")

SORTS = {
    # When *you* added it, which is not when it was first downloaded for someone else.
    "added": "li.added_at desc, t.id desc",
    "title": "lower(t.title) asc",
    "artist": "lower(coalesce(t.artists[1], '')) asc, lower(t.title) asc",
    "album": "lower(coalesce(t.album, '')) asc, lower(t.title) asc",
    "duration": "t.duration_ms desc nulls last",
}

_TRACK_SELECT = """
    select t.*, m.path, m.bytes, m.sha256, c.color as cover_color,
           c.sha256 as cover_sha
      from tracks t
      join library_items li on li.track_id = t.id and li.user_id = %s
      left join media m on m.track_id=t.id and m.role='canonical'
      left join covers c on c.id=t.cover_id
"""

# Every query below starts with the user id, because the join above does.
_MINE = "from tracks t join library_items li on li.track_id = t.id and li.user_id = %s"

# One artist, however their name was typed.
#
# The same act arrives spelled several ways — "BICEP" and "Bicep", "S.P.Y" and "S.PY",
# "Girls Of The Internet" with two invisible characters stuck to the end — because the
# name comes from whoever uploaded each song. Left alone that is three artists with a
# third of the records each, and an artist page that is missing most of their music.
#
# So names are compared with everything that is not a letter or a digit removed, which
# is what a person does when they read two spellings as the same name. Zero-width
# characters go the same way, being punctuation to Postgres. What is *shown* is the
# spelling most of the tracks use, so the list reads the way the library does rather
# than in some flattened form nobody typed.
def _key(column: str) -> str:
    return f"lower(regexp_replace({column}, '[^[:alnum:]]+', '', 'g'))"


ARTIST_KEY = _key("artist")


def fold(text: str) -> str:
    """The same folding as [_key], done here rather than in the query.

    A pattern cannot be folded by the database: "%bicep%" put through it comes out as
    "bicep" with the wildcards eaten, and matches only an artist called exactly that.
    """
    return re.sub(r"[^\w]+|_", "", text or "", flags=re.UNICODE).lower()
# Any of a track's credits being this artist, whatever either spelling looks like.
ONE_ARTIST = f"exists (select 1 from unnest(t.artists) a where {_key('a')} = {_key('%s')})"


@router.get("/tracks")
def all_tracks(sort: str = "added", limit: int = 200, offset: int = 0,
               ready_only: bool = False, user: dict = Depends(current_user)):
    """Everything in the library. Until now there was no way to see it at all."""
    if sort not in SORTS:
        raise HTTPException(400, f"sort must be one of {', '.join(SORTS)}")
    where = "where t.state='ready'" if ready_only else ""
    rows = db.all_(
        f"{_TRACK_SELECT} {where} order by {SORTS[sort]} limit %s offset %s",
        (user["id"], min(limit, 500), offset),
    )
    total = db.one(f"select count(*) n {_MINE} {where}", (user["id"],))["n"]
    return {"items": [catalog.public(t) for t in rows], "total": total,
            "offset": offset, "sort": sort}


# What a sort's letters are the first letters *of*: the column it orders by first.
_LETTERED = {
    "title": "t.title",
    "artist": "coalesce(t.artists[1], '')",
    "album": "coalesce(t.album, '')",
}


@router.get("/tracks/index")
def all_tracks_index(sort: str = "title", ready_only: bool = False,
                     user: dict = Depends(current_user)):
    """The letters of the songs list, in whichever alphabetical order it is in.

    Sorted by artist they are the artists' initials, by record the records'. The orders
    that are not alphabetical — newest, longest — have no letters, and say so.
    """
    if sort not in _LETTERED:
        raise HTTPException(400, f"only {', '.join(_LETTERED)} have letters")
    where = "where t.state='ready'" if ready_only else ""
    return {"sort": sort, "letters": _letters(
        f"""select {_LETTERED[sort]} as name,
                   row_number() over (order by {SORTS[sort]}) as rn
              {_MINE} {where}""",
        (user["id"],))}


# Lists that fill themselves in.
#
# A playlist is something somebody made. These are the other kind: a question about
# the library and what has been played from it, asked again every time the list is
# opened. Each is a name, a line saying what it is, and the SQL that answers it — a
# `where` over the library's songs with the listener's plays joined on as `p`.
#
# Only songs that can play now: a list made for putting on should not be mostly songs
# that need fetching first.
SMART = {
    "never": {
        "name": "Never played",
        "blurb": "In your library, downloaded, and not once put on",
        "where": "p.plays is null",
        "order": "li.added_at desc",
    },
    "most": {
        "name": "Most played",
        "blurb": "What you have played most, of everything, ever",
        "where": "p.plays >= 2",
        "order": "p.plays desc, p.last_at desc",
    },
    "forgotten": {
        "name": "Not heard in a while",
        "blurb": "Played more than once, and not for a month",
        "where": "p.plays >= 2 and p.last_at < now() - interval '30 days'",
        "order": "p.plays desc, p.last_at asc",
    },
    "fresh": {
        "name": "New this month",
        "blurb": "Added to your library in the last thirty days",
        "where": "li.added_at > now() - interval '30 days'",
        "order": "li.added_at desc",
    },
    "once": {
        "name": "Played once",
        "blurb": "Heard the whole way through exactly once: worth a second go?",
        "where": "p.plays = 1",
        "order": "p.last_at desc",
    },
}

_DECADE = re.compile(r"d((?:19|20)\d0)")


def _smart_spec(kind: str) -> dict | None:
    """One of the named lists, or a decade: `d1990` is everything from the nineties.

    A decade is a list that fills itself in like the others — nobody files a song under
    one — so it is answered the same way. What you have played most of it comes first:
    a decade is somewhere to go and put something on, not a catalogue to read.
    """
    if kind in SMART:
        return SMART[kind]
    m = _DECADE.fullmatch(kind)
    if not m:
        return None
    start = int(m.group(1))
    return {
        "name": f"The {start}s",
        "blurb": f"Everything here that came out between {start} and {start + 9}",
        "where": f"t.release_year between {start} and {start + 9}",
        "order": "p.plays desc nulls last, t.release_year, lower(coalesce(t.album, ''))",
    }


_SMART_FROM = """
      from tracks t
      join library_items li on li.track_id = t.id and li.user_id = %s
      left join (select track_id, count(*) filter (where completed) plays,
                        max(started_at) last_at
                   from listens where user_id = %s group by track_id) p
             on p.track_id = t.id
"""


@router.get("/smart")
def smart_lists(user: dict = Depends(current_user)):
    """The lists there are, and how many songs each would have right now."""
    counts = db.one(
        "select " + ", ".join(
            f"count(*) filter (where {spec['where']}) as {key}"
            for key, spec in SMART.items())
        + _SMART_FROM + " where t.state = 'ready'",
        (user["id"], user["id"]))
    # And the decades there is anything from. Only the ones with something in them: a
    # shelf marked "1950s" with nothing on it is not a way of browsing.
    decades = db.all_(
        """select (t.release_year / 10) * 10 as start, count(*) as n
             from tracks t
             join library_items li on li.track_id = t.id and li.user_id = %s
            where t.state = 'ready' and t.release_year between 1900 and 2099
            group by 1 order by 1 desc""",
        (user["id"],))
    return {
        "lists": [
            {"id": key, "name": spec["name"], "blurb": spec["blurb"], "count": counts[key]}
            for key, spec in SMART.items()],
        "decades": [
            {"id": f"d{d['start']}", "name": f"The {d['start']}s",
             "short": f"{d['start'] % 100:02d}s", "count": d["n"],
             "blurb": _smart_spec(f"d{d['start']}")["blurb"]}
            for d in decades],
    }


@router.get("/smart/{kind}")
def smart_list(kind: str, limit: int = 200, user: dict = Depends(current_user)):
    """One of them, answered now."""
    spec = _smart_spec(kind)
    if spec is None:
        raise HTTPException(404, "no such list")
    rows = db.all_(
        f"""select t.*, m.path, m.bytes, m.sha256, c.color as cover_color,
                   c.sha256 as cover_sha
            {_SMART_FROM}
              left join media m on m.track_id = t.id and m.role = 'canonical'
              left join covers c on c.id = t.cover_id
             where t.state = 'ready' and {spec['where']}
             order by {spec['order']}, t.id
             limit %s""",
        (user["id"], user["id"], max(1, min(limit, 500))))
    return {"id": kind, "name": spec["name"], "blurb": spec["blurb"],
            "items": [catalog.public(t) for t in rows]}


# How a list of records or of artists can be ordered. Named rather than free text: an
# order is a handful of sensible answers, not a column somebody types in.
ALBUM_SORTS = {
    "name": "lower(t.album) asc",
    "artist": "lower(coalesce(t.artists[1], '')) asc, lower(t.album) asc",
    "year": "min(t.release_year) desc nulls last, lower(t.album) asc",
    "tracks": "count(*) desc, lower(t.album) asc",
    "added": "max(li.added_at) desc, lower(t.album) asc",
}

ARTIST_SORTS = {
    "name": "lower(b.name) asc",
    "tracks": "count(distinct c.id) desc, lower(b.name) asc",
    "albums": "count(distinct c.album) desc, lower(b.name) asc",
}


@router.get("/albums")
def albums(limit: int = 200, offset: int = 0, q: str | None = None,
           sort: str = "name", user: dict = Depends(current_user)):
    """Grouped by album *and* artist: two records can share a title, and merging them
    would be a worse lie than showing two rows.

    `q` narrows to records whose name or artist contains it, which is the only way
    through ten thousand of them that is not scrolling.
    """
    if sort not in ALBUM_SORTS:
        raise HTTPException(400, f"sort must be one of {', '.join(ALBUM_SORTS)}")
    like = f"%{(q or '').strip()}%"
    narrow = ""
    params: tuple = (user["id"],)
    if (q or "").strip():
        narrow = ("and (t.album ilike %s "
                  "or coalesce(t.artists[1],'') ilike %s)")
        params += (like, like)
    rows = db.all_(
        f"""
        select t.album as name,
               coalesce(t.artists[1], 'Unknown artist') as artist,
               count(*) as tracks,
               min(t.release_year) as year,
               max(t.id) filter (where t.cover_id is not null) as cover_track_id,
               sum(coalesce(t.duration_ms, 0)) as duration_ms
          {_MINE}
         where t.album is not null and t.album <> '' {narrow}
         group by t.album, coalesce(t.artists[1], 'Unknown artist')
         order by {ALBUM_SORTS[sort]}
         limit %s offset %s
        """,
        params + (min(limit, 500), offset),
    )
    # How many there are in all, so a list that arrives a page at a time knows whether
    # it has reached the end — without that the app asked once, drew two hundred of ten
    # thousand records, and had no way of telling that was not all of them.
    total = db.one(
        f"""select count(*) n from (select 1 {_MINE}
             where t.album is not null and t.album <> '' {narrow}
             group by t.album, coalesce(t.artists[1], 'Unknown artist')) g""",
        params)["n"]
    return {"items": [
        {**r, "cover_url": f"/tracks/{r['cover_track_id']}/cover"
         if r["cover_track_id"] else None}
        for r in rows
    ], "total": total, "offset": offset}


def _letters(numbered_sql: str, params: tuple) -> list[dict]:
    """Where each letter starts in a list sorted by name.

    `numbered_sql` is the list itself — the same rows in the same order, each with its
    name and its place (`rn`, from one) — so the offsets are offsets into exactly what
    the list endpoint pages through. Anything that does not start with a letter is
    filed under '#', wherever the database's idea of alphabetical order puts it.
    """
    rows = db.all_(
        f"""select ch, min(rn) - 1 as "offset", count(*) as n from (
                select rn, case when upper(left(name, 1)) between 'A' and 'Z'
                                then upper(left(name, 1)) else '#' end as ch
                  from ({numbered_sql}) numbered) lettered
             group by ch order by min(rn)""",
        params)
    return [{"letter": r["ch"], "offset": r["offset"], "count": r["n"]} for r in rows]


@router.get("/albums/index")
def albums_index(user: dict = Depends(current_user)):
    """The letters of the records list, for dragging down the side of it.

    Two thousand records is a long way to scroll to reach the Ts. This says that T
    starts at row 1,640, and the list goes there.
    """
    return {"letters": _letters(
        f"""select t.album as name,
                   row_number() over (order by {ALBUM_SORTS['name']}) as rn
              {_MINE}
             where t.album is not null and t.album <> ''
             group by t.album, coalesce(t.artists[1], 'Unknown artist')""",
        (user["id"],))}


@router.get("/albums/tracks")
def album_tracks(album: str, artist: str | None = None,
                 user: dict = Depends(current_user)):
    params: tuple = (user["id"], album)
    clause = "where t.album = %s"
    if artist:
        clause += " and coalesce(t.artists[1], 'Unknown artist') = %s"
        params += (artist,)
    rows = db.all_(f"{_TRACK_SELECT} {clause} order by t.id", params)
    return {"items": [catalog.public(t) for t in rows]}


@router.get("/artists")
def artists(limit: int = 300, offset: int = 0, q: str | None = None,
            sort: str = "name", user: dict = Depends(current_user)):
    """Every credited artist, not just the first: a feature is still an appearance.

    `q` narrows to the ones whose name contains it — matched the same way two spellings
    of one name are, so searching "bicep" finds "BICEP".
    """
    if sort not in ARTIST_SORTS:
        raise HTTPException(400, f"sort must be one of {', '.join(ARTIST_SORTS)}")
    asked = fold(q or "")
    narrow = f"where {_key('b.name')} like %s" if asked else ""
    rows = db.all_(
        f"""
        with credits as (
            select unnest(t.artists) as artist, t.album, t.id, t.cover_id {_MINE}
        ), spelled as (
            select {ARTIST_KEY} as k, artist, count(*) as n
              from credits where artist is not null and artist <> ''
             group by 1, 2
        ), best as (
            -- The spelling most of the tracks use, and among equals the plainest one:
            -- shortest first, so a name with an invisible character welded to the end
            -- loses to the same name without it.
            select k, (array_agg(artist order by n desc, length(artist), artist))[1]
                      as name
              from spelled group by k
        )
        select b.name, count(distinct c.id) as tracks,
               count(distinct c.album) filter (where c.album is not null) as albums,
               max(c.id) filter (where c.cover_id is not null) as cover_track_id
          from credits c
          join best b on b.k = {_key("c.artist")}
         {narrow}
         group by b.k, b.name
         order by {ARTIST_SORTS[sort]}
         limit %s offset %s
        """,
        (user["id"],) + ((f"%{asked}%",) if asked else ())
        + (min(limit, 1000), offset),
    )
    total = db.one(
        f"""select count(distinct {ARTIST_KEY}) n
              from (select unnest(t.artists) as artist {_MINE}) x
             where artist is not null and artist <> ''
               {f"and {ARTIST_KEY} like %s" if asked else ""}""",
        (user["id"],) + ((f"%{asked}%",) if asked else ()))["n"]
    return {"items": [
        {**r, "cover_url": f"/tracks/{r['cover_track_id']}/cover"
         if r["cover_track_id"] else None}
        for r in rows
    ], "total": total, "offset": offset}


@router.get("/artists/index")
def artists_index(user: dict = Depends(current_user)):
    """The letters of the artists list. The same artists in the same order as the list
    itself: the same spellings folded together, the same one of them chosen."""
    return {"letters": _letters(
        f"""
        with credits as (
            select unnest(t.artists) as artist, t.id {_MINE}
        ), spelled as (
            select {ARTIST_KEY} as k, artist, count(*) as n
              from credits where artist is not null and artist <> ''
             group by 1, 2
        ), best as (
            select k, (array_agg(artist order by n desc, length(artist), artist))[1]
                      as name
              from spelled group by k
        )
        select b.name, row_number() over (order by {ARTIST_SORTS['name']}) as rn
          from best b""",
        (user["id"],))}


@router.get("/artists/tracks")
def artist_tracks(artist: str, user: dict = Depends(current_user)):
    rows = db.all_(
        f"{_TRACK_SELECT} where {ONE_ARTIST} "
        "order by lower(coalesce(t.album,'')), t.id",
        (user["id"], artist),
    )
    return {"items": [catalog.public(t) for t in rows]}


@router.post("/fetch")
def fetch(body: dict = Body(default={}), user: dict = Depends(current_user)):
    """Get the audio for a set of songs that have none yet.

    Most of this library has never been downloaded — eighteen thousand of twenty-two
    thousand rows are a name and a place to get it from — because a mirrored collection
    records the list and leaves the files until something is played. A playlist could
    already ask for all of it; a record, an artist and a handful of rows picked out of
    a list could not, which meant "take this album on the train" was a matter of playing
    each song for a second.

    Answers with what it queued and roughly what that will cost, because a thousand
    songs is four gigabytes and somebody about to leave the house should be told.
    """
    ids = [int(i) for i in (body.get("track_ids") or [])][:2000]
    album = (body.get("album") or "").strip()
    artist = (body.get("artist") or "").strip()

    if album:
        where, params = "where t.album = %s", (user["id"], album)
        if artist:
            where += " and coalesce(t.artists[1],'') = %s"
            params += (artist,)
        ids = [r["id"] for r in db.all_(f"select t.id {_MINE} {where}", params)]
    elif artist:
        ids = [r["id"] for r in db.all_(
            f"select t.id {_MINE} where {ONE_ARTIST}", (user["id"], artist))]
    if not ids:
        raise HTTPException(400, "nothing to fetch: give track_ids, an album or an artist")

    # Only the ones that need it, and not the ones already on their way: pressing this
    # twice should not double the queue.
    waiting = db.all_(
        """select id, duration_ms from tracks
            where id = any(%s) and state in ('pending','failed')
              and not exists (select 1 from jobs j
                               where j.kind in ('ingest','ingest_direct')
                                 and (j.payload->>'track_id')::int = tracks.id
                                 and (j.state='pending'
                                      or (j.state='leased' and j.leased_until > now())))""",
        (ids,))

    queued = unfetchable = 0
    minutes = 0
    label = album or artist or "Picked songs"
    for row in waiting:
        db.run("""update tracks set state='pending', fail_reason=null, fail_code=null
                   where id=%s and state='failed'""", (row["id"],))
        if jobs.queue(row["id"], priority=jobs.PRIORITY_BULK,
                      batch_id=f"fetch:{label}", batch_label=label):
            queued += 1
            minutes += (row["duration_ms"] or 0) / 60_000
        else:
            unfetchable += 1
            db.run("""update tracks set state='failed',
                             fail_reason='There is nowhere left to fetch this from',
                             fail_code='no_source' where id=%s""", (row["id"],))
    # About a megabyte a minute at the bitrate everything here is kept in. A number
    # somebody can act on beats a number that is exactly right.
    return {"queued": queued, "unfetchable": unfetchable,
            "already_here": len(ids) - len(waiting),
            "about_mb": round(minutes * 0.94)}


# ------------------------------------------------------------------ what was played
#
# Every play is already written down, one row per listen, and until now the only thing
# read out of it was "recently played" and a single lifetime tally. What nobody could
# ask was the ordinary question — what have I actually been listening to this month —
# which is a grouping and a date, both of which the table can answer.
PERIODS = {
    "week": "7 days",
    "month": "30 days",
    "year": "365 days",
    "all": None,
}

# The same stretches in seconds, for cutting the past into charts of equal length.
_SPAN = {"week": 7 * 86400, "month": 30 * 86400, "year": 365 * 86400}

# How far back "weeks on chart" looks: half a year of weeklies, two years of monthlies.
_LOOKBACK = {"week": 26, "month": 24, "year": 5}


def _chart_runs(whose: int, since: str, limit: int, ids: list[int]) -> dict[int, dict]:
    """Where each of these songs stood on the last chart, and how many charts it has
    been on.

    A chart is a stretch of the same length as the one asked about, counted back from
    now: this week, the week before, the one before that. Each is ranked the way the
    main list is — plays, then starts, then time — and a song "on the chart" is one in
    its top `limit`. So a song's movement is its place on this chart against its place
    on the last one, and its weeks on chart are the number of charts it made.
    """
    span = _SPAN.get(since)
    if span is None or not ids:
        return {}
    rows = db.all_(
        """with b as (
             select l.track_id,
                    floor(extract(epoch from (now() - l.started_at)) / %s)::int as chart,
                    count(*) filter (where l.completed) plays,
                    count(*) started,
                    coalesce(sum(l.ms_played), 0) ms
               from listens l
              where l.user_id = %s
                and l.started_at > now() - make_interval(secs => %s)
              group by 1, 2
           ), r as (
             select track_id, chart,
                    row_number() over (partition by chart
                                       order by plays desc, started desc, ms desc) as rank
               from b
           )
           select track_id,
                  min(rank) filter (where chart = 1) as last_rank,
                  count(*) filter (where rank <= %s) as charts
             from r
            where track_id = any(%s)
            group by track_id""",
        (span, whose, span * _LOOKBACK[since], limit, ids))
    return {r["track_id"]: r for r in rows}


@router.get("/stats")
def stats(since: str = "month", who: int | None = None, limit: int = 25,
          user: dict = Depends(current_user)):
    """How much of what, for one account over one stretch of time.

    `who` is any account on this box, because the catalog is shared and the People
    screen already says who has how much — this is the same fact, counted properly.
    """
    if since not in PERIODS:
        raise HTTPException(400, f"since must be one of {', '.join(PERIODS)}")
    whose = who or user["id"]
    person = db.one("select id, name from users where id=%s", (whose,))
    if not person:
        raise HTTPException(404, "no such account")

    window = PERIODS[since]
    when = "" if window is None else f"and l.started_at > now() - interval '{window}'"
    limit = max(1, min(limit, 100))
    args: tuple = (whose,)

    totals = db.one(
        f"""select count(*) started,
                   count(*) filter (where l.completed) plays,
                   coalesce(sum(l.ms_played),0) ms,
                   count(distinct l.track_id) tracks,
                   min(l.started_at) first_at, max(l.started_at) last_at
              from listens l where l.user_id=%s {when}""", args)

    songs = db.all_(
        f"""select t.id, t.title, t.artists, t.album,
                   count(*) filter (where l.completed) plays,
                   count(*) started,
                   coalesce(sum(l.ms_played),0) ms,
                   max(l.started_at) last_at,
                   case when t.cover_id is not null
                        then '/tracks/' || t.id || '/cover' end as cover_url
              from listens l join tracks t on t.id = l.track_id
             where l.user_id=%s {when}
             group by t.id
             order by plays desc, started desc, ms desc
             limit %s""", args + (limit,))

    # Where each song was last time, and how long it has been charting.
    runs = _chart_runs(whose, since, limit, [r["id"] for r in songs])
    for i, row in enumerate(songs):
        run = runs.get(row["id"])
        last = run["last_rank"] if run else None
        # Off the last chart altogether is a new entry, however many plays it had.
        row["last_rank"] = last if last is not None and last <= limit else None
        row["charts"] = int(run["charts"]) if run else (1 if since in _SPAN else 0)
        row["rank"] = i + 1

    artists = db.all_(
        f"""select artist as name, count(*) filter (where completed) plays,
                   coalesce(sum(ms_played),0) ms,
                   count(distinct track_id) tracks
              from (select unnest(t.artists) as artist, l.completed, l.ms_played,
                           l.track_id
                      from listens l join tracks t on t.id = l.track_id
                     where l.user_id=%s {when}) x
             where artist is not null and artist <> ''
             group by {_key("artist")}, artist
             order by plays desc, ms desc
             limit %s""", args + (limit,))

    albums = db.all_(
        f"""select t.album as name,
                   coalesce(t.artists[1], 'Unknown artist') as artist,
                   count(*) filter (where l.completed) plays,
                   coalesce(sum(l.ms_played),0) ms
              from listens l join tracks t on t.id = l.track_id
             where l.user_id=%s and t.album is not null and t.album <> '' {when}
             group by t.album, coalesce(t.artists[1], 'Unknown artist')
             order by plays desc, ms desc
             limit %s""", args + (limit,))

    # A shape for the stretch, so "this year" is a year rather than one number: by day
    # for the short windows, by month for the long ones.
    step = "day" if since in ("week", "month") else "month"
    shape = db.all_(
        f"""select date_trunc('{step}', l.started_at) at,
                   count(*) filter (where l.completed) plays,
                   coalesce(sum(l.ms_played),0) ms
              from listens l where l.user_id=%s {when}
             group by 1 order by 1""", args)

    return {
        "who": {"id": person["id"], "name": person["name"]},
        "since": since,
        "people": db.all_("select id, name from users order by lower(name)"),
        "totals": {
            "plays": totals["plays"], "started": totals["started"],
            "minutes": round(int(totals["ms"]) / 60_000),
            "tracks": totals["tracks"],
            "first_at": totals["first_at"], "last_at": totals["last_at"],
        },
        "songs": songs, "artists": artists, "albums": albums,
        "shape": [{"at": r["at"], "plays": r["plays"],
                   "minutes": round(int(r["ms"]) / 60_000)} for r in shape],
        "step": step,
    }


@router.get("/history")
def history(limit: int = 200, user: dict = Depends(current_user)):
    """With timestamps this time. A flat list with no sense of when is not a history."""
    rows = db.all_(
        f"""
        select l.started_at, l.ms_played, l.completed, x.*
          from listens l
          join lateral ({_TRACK_SELECT} where t.id = l.track_id) x on true
         where l.user_id=%s
         order by l.started_at desc
         limit %s
        """,
        (user["id"], user["id"], min(limit, 500)),
    )
    return {"items": [
        {**catalog.public(r), "played_at": r["started_at"],
         "ms_played": r["ms_played"], "completed": r["completed"]}
        for r in rows
    ]}


@router.delete("/history")
def clear_history(user: dict = Depends(current_user)):
    db.run("delete from listens where user_id=%s", (user["id"],))
    return {"cleared": True}


# ------------------------------------------------------------------ the whole record
#
# A library album is the part of a record somebody happened to add. Showing that as
# "the album" is how a five-track record ends up looking like two songs and a gap. The
# release itself comes from the metadata service; what we hold is matched into it.


def _match_into(remote: list[dict], local: list[dict]) -> tuple[list[dict], list[dict]]:
    """Put each local track where it belongs on the release; return the leftovers.

    Matching on the normalised title, and on length when both sides know it: two songs
    on one record can share a title (a reprise, a live take) and the wrong one being
    marked as held is worse than neither being marked.
    """
    unused = list(local)
    merged = []
    for item in remote:
        want = discography.norm(item.get("title"))
        best, best_gap = None, None
        for cand in unused:
            if discography.norm(cand["title"]) != want:
                continue
            gap = abs((cand.get("duration_ms") or 0) - (item.get("duration_ms") or 0)) \
                if cand.get("duration_ms") and item.get("duration_ms") else 0
            if best is None or gap < best_gap:
                best, best_gap = cand, gap
        if best is not None and (best_gap is None or best_gap <= 20000):
            unused.remove(best)
            merged.append({**item, "track": catalog.public(best)})
        else:
            merged.append({**item, "track": None})
    return merged, unused


@router.get("/albums/detail")
def album_detail(album: str | None = None, artist: str | None = None,
                 remote_id: str | None = None, user: dict = Depends(current_user)):
    """The record, with the parts of it we hold marked as playable.

    Addressable two ways: by the album as the library spells it, and by the release
    itself — which is how a record nobody has any of yet (from an artist's page, or the
    feed) still opens as a page you can do something with.
    """
    release, error = None, None
    try:
        if remote_id:
            release = discography.album(remote_id)
        elif album:
            found = discography.find_album(album, artist)
            if found:
                release = discography.album(found["id"])
    except discography.Unavailable as e:
        error = str(e)

    # Local rows: the album as this library spells it, or as the release does.
    name = album or (release or {}).get("title")
    local = []
    if name:
        params: tuple = (user["id"], name)
        clause = "where lower(t.album) = lower(%s)"
        if artist:
            clause += " and coalesce(t.artists[1], 'Unknown artist') = %s"
            params += (artist,)
        local = db.all_(f"{_TRACK_SELECT} {clause} order by t.id", params)

    notes = _liner_notes(user["id"], [r["id"] for r in local], name,
                         (release or {}).get("artist") or artist
                         or (local[0]["artists"][0] if local and local[0]["artists"] else None))

    if not release:
        # No match, or the service is down: the library is still an album page.
        return {"notes": notes,
                "album": {"name": album, "artist": artist, "source": None,
                          "unavailable": error},
                "tracks": [{"pos": n + 1, "title": r["title"],
                            "artists": r["artists"], "duration_ms": r["duration_ms"],
                            "remote_id": None, "track": catalog.public(r)}
                           for n, r in enumerate(local)],
                "extra": [], "missing": 0}

    merged, extra = _match_into(release["tracks"], local)
    return {
        "notes": notes,
        "album": {
            "name": album or release["title"],
            "release_name": release["title"],
            "artist": release["artist"] or artist,
            "cover": release["cover"],
            "release_date": release["release_date"],
            "record_type": release["record_type"],
            "remote_id": release["remote_id"],
            "source": "deezer",
        },
        "tracks": merged,
        "extra": [catalog.public(r) for r in extra],
        "missing": sum(1 for m in merged if m["track"] is None),
    }


def _liner_notes(user_id: int, track_ids: list[int], album: str | None,
                 artist: str | None) -> dict:
    """What goes under a record's tracklist: what this house has made of it.

    How often you have played it and when last, who else here plays it, and what else
    by the same artist is already on your shelf. All of it from what the library and the
    listens already know — nothing is looked up anywhere, so it is there when the
    metadata service is not.
    """
    plays = {"plays": 0, "last": None}
    house: list[dict] = []
    if track_ids:
        plays = db.one(
            """select count(*) filter (where completed) as plays, max(started_at) as last
                 from listens where user_id = %s and track_id = any(%s)""",
            (user_id, track_ids))
        house = db.all_(
            """select u.id, u.name, count(*) as plays
                 from listens l join users u on u.id = l.user_id
                where l.track_id = any(%s) and l.completed and l.user_id <> %s
                group by u.id, u.name order by count(*) desc, u.name limit 4""",
            (track_ids, user_id))
    more: list[dict] = []
    if artist:
        more = db.all_(
            f"""select t.album as name,
                       coalesce(t.artists[1], 'Unknown artist') as artist,
                       count(*) as tracks, min(t.release_year) as year,
                       max(t.id) filter (where t.cover_id is not null) as cover_track_id
                  {_MINE}
                 where t.album is not null and t.album <> ''
                   and {_key("coalesce(t.artists[1], '')")} = {_key('%s')}
                   and lower(t.album) <> lower(%s)
                 group by t.album, coalesce(t.artists[1], 'Unknown artist')
                 order by min(t.release_year) desc nulls last, lower(t.album)
                 limit 12""",
            (user_id, artist, album or ""))
    return {
        "plays": plays["plays"] or 0,
        "last_played": plays["last"],
        "house": [{"id": h["id"], "name": h["name"], "plays": h["plays"]} for h in house],
        "more": [{"name": m["name"], "artist": m["artist"], "tracks": m["tracks"],
                  "year": m["year"],
                  "cover_url": f"/tracks/{m['cover_track_id']}/cover"
                  if m["cover_track_id"] else None} for m in more],
    }


@router.post("/albums/fill")
def fill_album(body: dict = Body(...), user: dict = Depends(current_user)):
    """Fetch the parts of a record we do not have.

    Each one goes through the same matcher as a playlist import, so what arrives is the
    recording the album lists rather than the first search hit — and an ISRC is picked
    up on the way, which is what stops a second copy of a song we already hold.
    """
    album = (body.get("album") or "").strip() or None
    remote_ids = [str(i) for i in (body.get("remote_ids") or [])]
    detail = album_detail(album, body.get("artist"), body.get("remote_id"), user)
    if not detail["album"].get("remote_id"):
        raise HTTPException(404, "That record could not be found to fill in.")

    wanted = [m for m in detail["tracks"] if m["track"] is None and m.get("remote_id")
              and (not remote_ids or m["remote_id"] in remote_ids)]
    if not wanted:
        raise HTTPException(400, "nothing on that record is missing")

    # Whatever the file's own metadata ends up saying, these tracks were fetched as
    # part of this record and have to land on its page — which is grouped by the album
    # text, so that is what gets written.
    group = album or detail["album"]["name"]
    year = (detail["album"].get("release_date") or "")[:4]
    label = f"{detail['album']['artist'] or ''} · {group}".strip(" ·")

    added, review = [], 0
    for item in wanted:
        got = sync.resolve_item("deezer", {
            "remote_id": item["remote_id"],
            "title": item["title"],
            "artists": item["artists"],
            "duration_ms": item["duration_ms"],
            "isrc": discography.track_isrc(item["remote_id"]),
        }, priority=jobs.PRIORITY_NORMAL,
            batch_id=f"album:{detail['album']['remote_id']}", batch_label=label)
        if not got.get("track_id"):
            review += 1
            continue
        added.append(got["track_id"])
        db.run(
            """update tracks
                  set album = %s,
                      release_year = coalesce(release_year, %s),
                      artists = case when cardinality(artists) = 0 then %s
                                     else artists end
                where id = %s""",
            (group, int(year) if year.isdigit() else None,
             item["artists"] or [detail["album"]["artist"] or ""], got["track_id"]),
        )
    catalog.remember(user["id"], *added)
    return {"queued": len(added), "not_matched": review}


def _artist_notes(user_id: int, artist: str, local: list[dict]) -> dict:
    """An artist as this house knows them, from the library and the listens alone.

    "Best known" is what the world plays of theirs; this is what *you* play of theirs,
    which is a different list and the one that says something. With it: how much you
    and the others here have them on, and who they turn up alongside in your library —
    every credit on a song counts, so a feature is a connection.
    """
    ids = [r["id"] for r in local]
    if not ids:
        return {"plays": 0, "last_played": None, "top": [], "house": [], "with": []}
    mine = {r["track_id"]: r["plays"] for r in db.all_(
        """select track_id, count(*) as plays from listens
            where user_id = %s and completed and track_id = any(%s)
            group by track_id""", (user_id, ids))}
    last = db.one(
        "select max(started_at) as at from listens where user_id=%s and track_id = any(%s)",
        (user_id, ids))["at"]
    house = db.all_(
        """select u.id, u.name, count(*) as plays
             from listens l join users u on u.id = l.user_id
            where l.track_id = any(%s) and l.completed and l.user_id <> %s
            group by u.id, u.name order by count(*) desc, u.name limit 4""",
        (ids, user_id))
    top = sorted((r for r in local if mine.get(r["id"])),
                 key=lambda r: (-mine[r["id"]], r["id"]))[:5]

    # Everybody credited beside them, folded the way the artists list folds spellings.
    me = fold(artist)
    beside: dict[str, dict] = {}
    for r in local:
        for name in r.get("artists") or []:
            k = fold(name)
            if not k or k == me:
                continue
            entry = beside.setdefault(k, {"name": name, "songs": 0})
            entry["songs"] += 1
    return {
        "plays": sum(mine.values()),
        "last_played": last,
        "top": [{"plays": mine[r["id"]], "track": catalog.public(r)} for r in top],
        "house": [{"id": h["id"], "name": h["name"], "plays": h["plays"]} for h in house],
        "with": sorted(beside.values(), key=lambda e: (-e["songs"], e["name"].lower()))[:10],
    }


@router.get("/artists/detail")
def artist_detail(artist: str, user: dict = Depends(current_user)):
    """An artist, not just the four songs of theirs somebody added."""
    local = db.all_(
        f"{_TRACK_SELECT} where {ONE_ARTIST} "
        "order by lower(coalesce(t.album,'')), t.id",
        (user["id"], artist),
    )

    found, error = None, None
    try:
        found = discography.find_artist(artist)
    except discography.Unavailable as e:
        error = str(e)

    out: dict = {
        "artist": {"name": artist, "source": None, "unavailable": error,
                   "following": False},
        "albums": [], "top": [],
        "tracks": [catalog.public(r) for r in local],
        "yours": _artist_notes(user["id"], artist, local),
    }
    if not found:
        return out

    try:
        albums = discography.artist_albums(found["remote_id"])
        top = discography.artist_top(found["remote_id"])
    except discography.Unavailable as e:
        out["artist"]["unavailable"] = str(e)
        return out

    # How much of each record we hold, counted from the tracks already in hand rather
    # than one query per album.
    held: dict[str, int] = {}
    for row in local:
        held[discography.norm(row.get("album"))] = \
            held.get(discography.norm(row.get("album")), 0) + 1

    out["artist"] = {
        "name": found["name"], "image": found["image"], "remote_id": found["remote_id"],
        "albums": found.get("albums"), "fans": found.get("fans"),
        "source": "deezer",
        "following": follows.is_following(user["id"], "deezer", found["remote_id"]),
    }
    out["albums"] = [{**a, "have": held.get(discography.norm(a["title"]), 0)}
                     for a in albums]
    out["top"] = [{**item, "track": merged["track"]}
                  for item, merged in zip(top, _match_into(top, local)[0])]
    return out
