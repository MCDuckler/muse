"""Following an artist, and the releases that follow from it.

Following is per person; what an artist has put out is a fact about the artist, so the
releases are shared and the feed is the join. That way ten people following the same
band cost one poll, not ten.

A new follow backfills the artist's records so the feed has something in it straight
away, but marks the back catalogue as already seen — following somebody should not
bury the feed under sixty-five albums from the last twenty years.
"""
from __future__ import annotations

import logging

from . import db, discography, jobs

log = logging.getLogger("muse.follows")

# How recent a record has to be, at the moment you follow someone, to count as news.
FRESH_DAYS = 60
# Every followed artist, this often. Deezer's answers are cached for half that, so a
# poll that finds nothing new is mostly a database read.
POLL_SECONDS = 6 * 3600


def list_for(user_id: int) -> list[dict]:
    return db.all_(
        """select f.provider, f.remote_id, f.name, f.image, f.created_at,
                  (select count(*) from artist_releases r
                    where r.provider=f.provider and r.artist_id=f.remote_id) as releases
             from artist_follows f
            where f.user_id=%s
            order by lower(f.name)""",
        (user_id,),
    )


def is_following(user_id: int, provider: str, remote_id: str) -> bool:
    return db.one(
        "select 1 from artist_follows where user_id=%s and provider=%s and remote_id=%s",
        (user_id, provider, remote_id),
    ) is not None


def follow(user_id: int, artist: dict, provider: str = "deezer") -> dict:
    db.run(
        """insert into artist_follows(user_id, provider, remote_id, name, image)
           values(%s,%s,%s,%s,%s)
           on conflict (user_id, provider, remote_id)
             do update set name=excluded.name, image=excluded.image""",
        (user_id, provider, artist["remote_id"], artist["name"], artist.get("image")),
    )
    found = refresh_artist(provider, artist["remote_id"], artist["name"])
    # Everything already out stays out of the feed; only what lands from here on, and
    # what is genuinely recent, is news.
    db.run(
        """insert into feed_seen(user_id, provider, album_id)
           select %s, provider, album_id from artist_releases
            where provider=%s and artist_id=%s
              and (release_date is null
                   or release_date < current_date - %s * interval '1 day')
           on conflict do nothing""",
        (user_id, provider, artist["remote_id"], FRESH_DAYS),
    )
    return {"following": True, "releases": found}


def unfollow(user_id: int, provider: str, remote_id: str) -> None:
    db.run(
        "delete from artist_follows where user_id=%s and provider=%s and remote_id=%s",
        (user_id, provider, remote_id),
    )


def refresh_artist(provider: str, remote_id: str, name: str) -> int:
    """Write down what this artist has released. Returns how many records are known."""
    try:
        albums = discography.artist_albums(remote_id)
    except discography.Unavailable as e:
        log.info("could not refresh %s: %s", name, e)
        return 0
    for a in albums:
        db.run(
            """insert into artist_releases(provider, artist_id, album_id, title, artist,
                                           cover, release_date, record_type, tracks)
               values(%s,%s,%s,%s,%s,%s,%s,%s,%s)
               on conflict (provider, album_id) do update
                 set title=excluded.title, cover=excluded.cover,
                     release_date=excluded.release_date, tracks=excluded.tracks""",
            (provider, remote_id, a["remote_id"], a["title"] or "", name, a.get("cover"),
             a.get("release_date") or None, a.get("record_type"), a.get("tracks")),
        )
    db.run("update artist_follows set checked_at=now() where provider=%s and remote_id=%s",
           (provider, remote_id))
    return len(albums)


def feed(user_id: int, limit: int = 60, offset: int = 0) -> list[dict]:
    """Releases from the artists this person follows, newest first.

    "New" is per person and means not yet scrolled past — which is why the album a
    follow brought in yesterday stays marked until it has actually been looked at.
    """
    return db.all_(
        """select r.provider, r.album_id, r.title, r.artist, r.artist_id, r.cover,
                  r.release_date, r.record_type, r.tracks, r.first_seen,
                  (s.album_id is null) as unseen,
                  exists (select 1
                            from library_items li
                            join tracks t on t.id = li.track_id
                           where li.user_id = f.user_id
                             and lower(t.album) = lower(r.title)) as in_library
             from artist_follows f
             join artist_releases r
               on r.provider = f.provider and r.artist_id = f.remote_id
             left join feed_seen s
               on s.user_id = f.user_id and s.provider = r.provider
              and s.album_id = r.album_id
            where f.user_id = %s
            order by r.release_date desc nulls last, r.first_seen desc
            limit %s offset %s""",
        (user_id, min(limit, 200), offset),
    )


def mark_seen(user_id: int, album_ids: list[str], provider: str = "deezer") -> int:
    if not album_ids:
        return 0
    db.run(
        """insert into feed_seen(user_id, provider, album_id)
           select %s, %s, unnest(%s::text[]) on conflict do nothing""",
        (user_id, provider, album_ids),
    )
    return len(album_ids)


# ------------------------------------------------------------------ the poll
def poll(schedule_next: bool = True) -> dict:
    """Check every followed artist once, then ask to be run again later.

    A job that re-queues itself is the whole scheduler here: there is no cron on this
    box, and one row in the jobs table is easier to see and to stop than a thread.
    """
    artists = db.all_(
        """select distinct provider, remote_id, min(name) as name
             from artist_follows group by provider, remote_id""",
    )
    checked = 0
    for a in artists:
        refresh_artist(a["provider"], a["remote_id"], a["name"])
        checked += 1
    if schedule_next:
        ensure_scheduled(delay=POLL_SECONDS)
    return {"artists": checked}


def ensure_scheduled(delay: float = POLL_SECONDS) -> None:
    """One poll job outstanding at a time, however many times this is called."""
    pending = db.one(
        "select 1 from jobs where kind='follow_poll' and state in ('pending','leased')")
    if pending:
        return
    jobs.enqueue("follow_poll", {}, priority=jobs.PRIORITY_BULK, delay_seconds=delay)
