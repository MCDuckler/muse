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
import re

from . import db, discography, jobs, linked

log = logging.getLogger("muse.follows")

# How recent a record has to be, at the moment you follow someone, to count as news.
FRESH_DAYS = 60
# Every followed artist, this often. Deezer's answers are cached for half that, so a
# poll that finds nothing new is mostly a database read.
POLL_SECONDS = 6 * 3600


def list_for(user_id: int) -> list[dict]:
    return db.all_(
        """select f.provider, f.remote_id, f.name, f.image, f.created_at, f.is_label,
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
    """Follow — on Deezer by its artist id, on Bandcamp by the band's page. A label is
    followed the same way as an act; `is_label` is remembered so the list can say."""
    db.run(
        """insert into artist_follows(user_id, provider, remote_id, name, image, is_label)
           values(%s,%s,%s,%s,%s,%s)
           on conflict (user_id, provider, remote_id)
             do update set name=excluded.name, image=coalesce(excluded.image, artist_follows.image),
                           is_label=excluded.is_label""",
        (user_id, provider, artist["remote_id"], artist["name"], artist.get("image"),
         bool(artist.get("is_label"))),
    )
    found = refresh_artist(provider, artist["remote_id"], artist["name"],
                           new_follower=user_id)
    _old_news_seen(user_id, provider, artist["remote_id"])
    return {"following": True, "releases": found}


def _old_news_seen(user_id: int, provider: str, remote_id: str) -> None:
    """Everything already out stays out of the feed; only what lands from here on, and
    what is genuinely recent, is news."""
    db.run(
        """insert into feed_seen(user_id, provider, album_id)
           select %s, provider, album_id from artist_releases
            where provider=%s and artist_id=%s
              and (release_date is null
                   or release_date < current_date - %s * interval '1 day')
           on conflict do nothing""",
        (user_id, provider, remote_id, FRESH_DAYS),
    )


def unfollow(user_id: int, provider: str, remote_id: str) -> None:
    db.run(
        "delete from artist_follows where user_id=%s and provider=%s and remote_id=%s",
        (user_id, provider, remote_id),
    )


# A Bandcamp follow is the band's page; its records are what that page lists. The
# music page says nothing about dates, so each record not seen before costs one more
# page — bounded, so a label with six hundred records does not cost six hundred.
BANDCAMP_NEWEST = 12
BANDCAMP_DATES_PER_POLL = 6

# A page that would not load is asked again rather than left for the next poll, six
# hours away: an import reads dozens of pages in a row, Bandcamp answers that with 429,
# and every follow refused that way used to sit there with no records until then.
RETRY_SECONDS = 15 * 60
RETRIES = 3


def _retry_later(provider: str, remote_id: str, name: str, *, tries: int,
                 new_follower: int | None) -> None:
    if tries >= RETRIES:
        return
    jobs.enqueue("follow_refresh",
                 {"provider": provider, "remote_id": remote_id, "name": name,
                  "tries": tries + 1, "new_follower": new_follower},
                 priority=jobs.PRIORITY_BULK, delay_seconds=RETRY_SECONDS * (tries + 1))


def refresh_later(payload: dict) -> int:
    """What the worker runs for a retried refresh. A follow whose first read failed
    gets its back catalogue marked as seen once it has one, as it would have then."""
    found = refresh_artist(payload["provider"], payload["remote_id"], payload["name"],
                           tries=int(payload.get("tries") or 0),
                           new_follower=payload.get("new_follower"))
    if payload.get("new_follower"):
        _old_news_seen(int(payload["new_follower"]), payload["provider"],
                       payload["remote_id"])
    return found


def _refresh_bandcamp(url: str, name: str, *, is_label: bool = False, tries: int = 0,
                      new_follower: int | None = None) -> int:
    # A label puts out several records a week where an act puts out one a year, so a
    # label's page is read further back and more of its new dates are asked for.
    newest = BANDCAMP_NEWEST * (3 if is_label else 1)
    dates = BANDCAMP_DATES_PER_POLL * (2 if is_label else 1)
    try:
        music = linked.bandcamp_music(url, newest=newest)
    except Exception as e:  # noqa: BLE001 — a page that will not load is not news
        log.info("could not refresh %s: %s", name, e)
        _retry_later("bandcamp", url, name, tries=tries, new_follower=new_follower)
        return 0
    records = music["records"]
    if music["is_label"] != is_label:
        # Many acts on one page's records is a label, whatever the page calls itself:
        # the feed then says whose label a record came out on. Read again each time, so
        # a page that was taken for one and is not stops being called one.
        db.run("update artist_follows set is_label=%s "
               "where provider='bandcamp' and remote_id=%s", (music["is_label"], url))
    # By the record, not by whose page listed it: a record on both an act's page and
    # its label's is one row, and asking its date again on every poll of the other
    # page spent the few dates a poll may ask for.
    known = {r["album_id"]: r for r in db.all_(
        "select album_id, release_date from artist_releases where provider='bandcamp' "
        "and album_id = any(%s)", ([a["remote_id"] for a in records],))}
    asked = 0
    for a in records:
        released = (known.get(a["remote_id"]) or {}).get("release_date")
        # New records first in line, then ones a past poll had no budget left for: a
        # record without a date is in no radar and sorts below everything in the feed.
        if released is None and asked < dates:
            asked += 1
            try:
                released = linked.bandcamp_record(a["remote_id"]).get("release_date")
            except Exception:  # noqa: BLE001
                released = None
        db.run(
            """insert into artist_releases(provider, artist_id, album_id, title, artist,
                                           cover, release_date, record_type, tracks)
               values('bandcamp',%s,%s,%s,%s,%s,%s,%s,null)
               on conflict (provider, album_id) do update
                 set title=excluded.title, cover=excluded.cover,
                     release_date=coalesce(excluded.release_date, artist_releases.release_date)""",
            (url, a["remote_id"], a["title"] or "", a.get("artist") or name, a.get("cover"),
             released, a.get("record_type")))
    db.run("update artist_follows set checked_at=now() where provider='bandcamp' and remote_id=%s",
           (url,))
    return len(records)


def refresh_artist(provider: str, remote_id: str, name: str, *, tries: int = 0,
                   new_follower: int | None = None) -> int:
    """Write down what this artist has released. Returns how many records are known."""
    if provider == "bandcamp":
        label = db.one("select bool_or(is_label) as l from artist_follows "
                       "where provider='bandcamp' and remote_id=%s", (remote_id,))
        return _refresh_bandcamp(remote_id, name, is_label=bool(label and label["l"]),
                                 tries=tries, new_follower=new_follower)
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
                  f.name as via, f.is_label,
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
def poll() -> dict:
    """Check every followed artist once.

    The caller queues the next run, once this one is finished and no longer counts as
    outstanding. A job that re-queues itself is the whole scheduler here: there is no
    cron on this box, and one row in the jobs table is easier to see and to stop than
    a thread.
    """
    artists = db.all_(
        """select distinct provider, remote_id, min(name) as name
             from artist_follows group by provider, remote_id""",
    )
    checked = 0
    for a in artists:
        refresh_artist(a["provider"], a["remote_id"], a["name"])
        checked += 1
    return {"artists": checked}


def ensure_scheduled(delay: float = POLL_SECONDS) -> None:
    """One poll job outstanding at a time, however many times this is called."""
    pending = db.one(
        "select 1 from jobs where kind='follow_poll' and state in ('pending','leased')")
    if pending:
        return
    jobs.enqueue("follow_poll", {}, priority=jobs.PRIORITY_BULK, delay_seconds=delay)


# ------------------------------------------------------------------ importing
# A label's roster can run to a hundred acts; this many of them, and the label itself.
ROSTER_MOST = 40


def _titles(band: dict | None, by: str | None = None) -> list[str]:
    """The records on a Bandcamp page that are its own act's — or, on a label's page,
    those credited to one act on it."""
    if not band:
        return []
    who = by or band.get("name") or ""
    return [r["title"] for r in band.get("records") or []
            if r.get("title") and (linked.credited_to(who, r.get("artist"))
                                   if by or r.get("artist") else True)]


def _record_key(title: str | None) -> str:
    """A record's name with what varies between shops taken off: anything in brackets,
    a "feat." and who follows it, and an EP or LP after the name."""
    t = re.sub(r"[\[(][^\])]*[\])]", " ", (title or "").lower())
    t = re.sub(r"\b(feat|ft|featuring)\b.*$", " ", t)
    t = discography.norm(t)
    return re.sub(r"\s+(e p|ep|l p|lp|single)$", "", t).strip()


def same_act(artist: dict, titles: list[str]) -> bool:
    """Whether a Deezer artist found by name is the act a Bandcamp page is: the two have
    a record in common. The name alone says nothing — there are a Cloudcore on Deezer
    with three singles and a CloudCore on Bandcamp that is a label — and a page that
    cannot show it is the same act is followed as itself, which is never wrong."""
    want = {_record_key(t) for t in titles} - {""}
    if not want:
        return False
    try:
        theirs = discography.artist_albums(artist["remote_id"], limit=100)
    except Exception:  # noqa: BLE001 — unknown is not yes
        return False
    for a in theirs:
        key = _record_key(a.get("title"))
        if not key:
            continue
        if key in want or any(len(k) >= 6 and len(key) >= 6 and (k in key or key in k)
                              for k in want):
            return True
    return False


def recheck(user_id: int, entries: list[dict], *, apply: bool = False) -> list[dict]:
    """Follows brought over from Bandcamp before same_act, put right: where the person
    follows a Deezer act named like a page they follow on Bandcamp, and that act shares
    no record with what the page has of its own, the Deezer follow becomes the page.
    Never an unfollow without the page put in its place, and an act with nothing on its
    page to compare is left as it is. Answers what was (or with apply=False, would be)
    changed."""
    changed = []

    def wrong(name: str, titles: list[str], *, label: bool) -> dict | None:
        d = db.one("""select remote_id, name from artist_follows
                       where user_id=%s and provider='deezer'
                         and artist_key(name) = artist_key(%s)""", (user_id, name))
        if not d:
            return None
        if not titles and not label:
            # Nothing on the page to tell them apart by is not proof they differ.
            return None
        if titles and same_act({"remote_id": d["remote_id"]}, titles):
            return None
        return d

    def swap(d: dict, page: dict | None, why: str) -> None:
        changed.append({"deezer": d["name"], "deezer_id": d["remote_id"],
                        "bandcamp": (page or {}).get("remote_id"), "why": why})
        if not apply:
            return
        unfollow(user_id, "deezer", d["remote_id"])
        if page and not is_following(user_id, "bandcamp", page["remote_id"]):
            follow(user_id, page, "bandcamp")

    for entry in entries:
        name, url = entry.get("name"), entry.get("url")
        if not name or not url:
            continue
        try:
            band = linked.bandcamp_band(url)
        except Exception:  # noqa: BLE001
            continue
        label = bool(band.get("is_label"))
        page = {"remote_id": url.rstrip("/"), "name": band.get("name") or name,
                "image": entry.get("image") or band.get("image"), "is_label": label}
        if d := wrong(name, _titles(band), label=label):
            swap(d, page, "a label, and none of its records theirs" if label
                 else "no record in common")
    return changed


def import_entries(user_id: int, provider: str, entries: list[dict], *,
                   expand_labels: bool = True) -> dict:
    """Follow everybody in [entries] who is not followed already. Nothing is unfollowed.

    Each name is looked up on Deezer first, which is where release dates and album
    pages come from; a Bandcamp page that Deezer does not know is followed as itself,
    and a Bandcamp *label* — a page whose records are by many acts — is opened into
    the acts on its roster, each followed on their own, and followed itself as well so
    its compilations still arrive.

    From Bandcamp, a Deezer act of the same name is only taken for the page when the
    two have a record in common (same_act): otherwise the page itself is followed.
    """
    added, already, missed, labels, from_labels = 0, 0, [], 0, 0

    def take(name: str, *, url: str | None = None, image: str | None = None,
             is_label: bool = False, titles: list[str] | None = None) -> bool:
        nonlocal added, already
        artist = None
        if not is_label:
            try:
                artist = discography.find_artist(name)
            except discography.Unavailable:
                artist = None
            if artist and provider == "bandcamp" and not same_act(artist, titles or []):
                artist = None
        if artist:
            key = ("deezer", artist["remote_id"])
        elif url and provider == "bandcamp":
            artist = {"remote_id": url, "name": name, "image": image, "is_label": is_label}
            key = ("bandcamp", url)
        else:
            missed.append(name)
            return False
        if is_following(user_id, *key):
            already += 1
            return True
        follow(user_id, artist, key[0])
        added += 1
        return True

    for entry in entries:
        name, url = entry.get("name"), entry.get("url")
        if not name:
            continue
        band = None
        if provider == "bandcamp" and url:
            try:
                band = linked.bandcamp_band(url)
            except Exception:  # noqa: BLE001 — treated as an act, below
                band = None
        if band and band.get("is_label"):
            labels += 1
            take(name, url=url, image=entry.get("image") or band.get("image"), is_label=True)
            if not expand_labels:
                continue
            for act in linked.bandcamp_acts(url, band)[:ROSTER_MOST]:
                # What the label put out by them is what tells them from a namesake.
                if take(act["name"], url=act.get("url") or None,
                        titles=_titles(band, by=act["name"])):
                    from_labels += 1
            continue
        take(name, url=url, image=entry.get("image"), titles=_titles(band))

    return {"from": provider, "found": len(entries), "followed": added, "already": already,
            "labels": labels, "from_labels": from_labels, "not_found": missed[:40]}
