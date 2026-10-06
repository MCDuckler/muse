"""What to play or add next, out of everything the house knows.

There used to be four answers to "what goes with this", each asking one thing:

* a station was YouTube Music's watch playlist for its seeds, fetched whole, every
  song of it a new download — the library it was started from never came into it;
* "more like this" under a playlist and in the booth's crate asked the same watch
  playlist again, live, on every look, and left out anything *anybody* here had,
  so a song a housemate had already fetched — one tap from playing — never showed;
* "would sit well" under a playlist was more by the artists already in it;
* the booth's partners (traits.py) is how well a record *mixes* after another, which
  is a different question and stays where it is.

None of them heard what was played, skipped or hearted. This asks all of the
questions at once and adds the answers up:

  lists     the house's own hand-made playlists: songs that share lists belong
            together. Mirrored libraries of thousands say nothing, so a list counts
            for less the longer it is and not at all past LIST_MOST.
  sessions  what was played around a song, by anybody here, within a sitting —
            as long as it was listened to rather than skipped past.
  radio     what YouTube Music plays after it (radio_edges): asked for once a week
            a seed, kept, and so a map of what goes with what that grows by itself.
  sound     how alike two records sound (traits.sound), for what has been analysed.
  artist    the same act, a little.

and then the person (taste): what they finish (up), skip in the first half minute
(down), heart (well up), have played in the last day and a half (not again yet), and
have waved away from here before (never) — and everything else they did that says
what they like: the lists they made, what they liked on the services they mirrored,
the lists of others they keep, the acts and genres they follow, the stations they
started, what they mixed in the booth, the sleeves they drew on, the songs they voted
to skip in a jam, and what Spotify and ListenBrainz know they play (elsewhere.py).
Each signal is scaled to its best candidate before it is added, so no one of them
drowns the rest whatever units it is counted in, and a song is only ever offered
twice by any one artist in one answer.

What comes back is in four kinds, because what can be done with a song depends on
where it is: `library` is yours and here; `waiting` is yours but never fetched (a
mirrored like, usually — the best-kept secret of a twelve-thousand-song library);
`house` is here because somebody else fetched it; `new` is not here at all.
"""
from __future__ import annotations

import datetime as dt
import json
import math
import os
import time
import unicodedata
import zoneinfo
from dataclasses import dataclass, field

from . import brainz, catalog, db, match, search, traits, ytm

# How much each question counts for when it has a good answer. Fitted on the house's
# own lists (2026-09-29): a fifth of each hand-made playlist hidden, the rest as seeds,
# how many of the hidden ones come back in ten. These weights found 249 of 720; the
# artist-overlap query this replaced found 199, and sound on its own mostly noise.
WEIGHTS = {"lists": 1.0, "sessions": 0.6, "radio": 0.5, "sound": 0.2, "artist": 1.0}

# A playlist longer than this is a library, not a choice.
LIST_MOST = 800

# Listens further apart than this are different sittings; neighbours further than
# this many songs away are not neighbours.
SITTING_S = 45 * 60
REACH = 3

# A listen shorter than this that did not finish is a skip.
SKIP_MS = 30_000

# How long an asked-for watch playlist is good for, and how many seeds may be asked
# about over the network in one answer — each is a request to YouTube Music.
RADIO_FRESH_S = 7 * 86400
RADIO_ASK = 4

# Played this recently and it is not offered again yet.
RECENT_H = 36

# Half-life of a listen, in days, for what somebody likes.
TASTE_HALF_LIFE = 45

MOST = 40
PER_ARTIST = 2


# ------------------------------------------------------------------- the person
# What each thing somebody did says about a song, a listen heard through being 1 (and
# fading with TASTE_HALF_LIFE). Listens were once all there was — and the house has only
# heard a month of anybody's, while the lists they made, what they liked on the services
# they mirrored and the acts they follow go back years.
HEART = 3.0             # a heart here
OWN_LIST = 1.0          # put on a list of their own
# What was kept rather than played counts for less: on the house's own week held out
# (2026-10-05) these weights kept what the lists found the same or a little better,
# where more of it buried what somebody actually plays under thousands of likes.
LIKED_ELSEWHERE = 0.4   # liked on Spotify, SoundCloud, YouTube or Deezer; a Bandcamp wishlist
MIRRORED = 0.25         # on another of their lists, mirrored from elsewhere
SAVED = 0.2             # on somebody else's list they keep
OPENED = 0.3            # on a list they opened this fortnight
BOOTH = 0.4             # mixed in the booth, whose decks write no listens
TOUCHED = 0.5           # drew on its sleeve, set its cues, cut a sample out of it
STATION = 0.8           # started a station from it
JAM_SKIP = -1.0         # voted to skip it in a jam
FOLLOWED = 2.5          # an act they follow, on the act's score
LABEL_ACT = 1.0         # an act on a label they follow: the label vouches, a little
DISLIKED = -2.0         # a song of theirs said no to, on the act's score
# Said no to this many of an act's songs: none of theirs is offered at all.
DISLIKES_ENOUGH = 2
STATION_ARTIST = 1.5    # an act they started a station from

# A likes list is newest first: its top is what somebody likes now, its bottom what they
# liked years ago — still them, but less so.
LIKED_HALF_RANK = 1500

# What somebody keeps without playing adds up slowly on an act: two hundred liked songs
# make a favourite, not a hundred times one.
PASSIVE_SCALE = 2.0

# Night on the person's clock: what they play then is what they play to wind down.
NIGHT_FROM, NIGHT_TO = 22, 5
HOUSE_TZ = os.environ.get("MUSE_TZ", "Europe/Berlin")

# What each service calls somebody's likes, as against a list they made.
_LIKES_IDS = ("liked-songs", "ll", "lm")
_LIKES_ENDS = ("/likes", "/wishlist", "/collection")
_LIKES_NAMES = ("liked songs", "liked music", "liked videos", "loved tracks", "lieblingssongs",
                "favourite tracks", "favorite tracks", "coups de cœur", "titres likés",
                "wishlist", "collection")
# Credits that are not an act: a compilation's, an unknown uploader's.
NOT_AN_ACT = {"various artists", "various", "va", "unknown artist", "unknown", "[unknown]",
              "anonymous", "traditional"}

SERVICE_NAMES = {"spotify": "Spotify", "soundcloud": "SoundCloud", "youtube": "YouTube",
                 "ytmusic": "YouTube Music", "deezer": "Deezer", "bandcamp": "Bandcamp"}


def is_likes(remote_id: str | None, name: str | None) -> bool:
    """A mirrored list that is somebody's likes (or a wishlist) rather than a list."""
    rid, n = (remote_id or "").lower(), (name or "").strip().lower()
    return rid in _LIKES_IDS or rid.endswith(_LIKES_ENDS) or n in _LIKES_NAMES \
        or n.endswith(" · likes")


@dataclass
class Taste:
    track: dict[int, float] = field(default_factory=dict)
    artist: dict[str, float] = field(default_factory=dict)
    recent: set[int] = field(default_factory=set)
    dismissed: set[str] = field(default_factory=set)
    library: set[int] = field(default_factory=set)
    hearted: set[int] = field(default_factory=set)
    # Listens alone: what was heard through and skipped here.
    heard: dict[int, float] = field(default_factory=dict)
    # Everything done here — listens, hearts, own lists, the booth, a drawn-on sleeve —
    # without what was kept from elsewhere: what somebody *plays*.
    active: dict[int, float] = field(default_factory=dict)
    # Listens alone, by act, so "you play a lot of" only ever says what is so.
    artist_heard: dict[str, float] = field(default_factory=dict)
    followed: set[str] = field(default_factory=set)
    # Acts on the labels somebody follows, by the label: following CloudCore is saying
    # something about Zecho and Xpress too.
    label_acts: dict[str, str] = field(default_factory=dict)
    # Said no to: the songs, and how many of each act's.
    disliked: set[int] = field(default_factory=set)
    artist_disliked: dict[str, int] = field(default_factory=dict)
    genres: dict[str, float] = field(default_factory=dict)
    # Liked on another service (which one), on a list of their own, on one of their
    # lists mirrored from another service (which one).
    liked: dict[int, str] = field(default_factory=dict)
    listed: set[int] = field(default_factory=set)
    mirrored: dict[int, str] = field(default_factory=dict)
    # Heard through at night on their clock, faded like any listen; skipped at night, less.
    night: dict[int, float] = field(default_factory=dict)
    # Acts somebody plays elsewhere, by how much (elsewhere.py).
    elsewhere: dict[str, float] = field(default_factory=dict)


def clock(user_id: int) -> dt.tzinfo:
    """The person's clock: the offset their app last said, else the house's zone."""
    row = db.one("select utc_offset_min from users where id = %s", (user_id,))
    if row and row.get("utc_offset_min") is not None:
        return dt.timezone(dt.timedelta(minutes=int(row["utc_offset_min"])))
    try:
        return zoneinfo.ZoneInfo(HOUSE_TZ)
    except (zoneinfo.ZoneInfoNotFoundError, ValueError):
        return dt.timezone.utc


def is_night(at: dt.datetime, tz: dt.tzinfo) -> bool:
    h = at.astimezone(tz).hour
    return h >= NIGHT_FROM or h < NIGHT_TO


def _fade(days, half_life: float) -> float:
    return 0.5 ** (max(0.0, float(days or 0)) / half_life)


def taste(user_id: int) -> Taste:
    """What this person likes, from what they did rather than what they said: here, in
    the booth, and on the services they brought their music in from."""
    t = Taste()
    tz = clock(user_id)

    def add(d: dict, k, v: float) -> None:
        d[k] = d.get(k, 0.0) + v

    # Listens: heard through up, skipped in the first half minute down, all fading.
    for r in db.all_(
            """select track_id, completed, ms_played, started_at,
                      extract(epoch from now() - started_at) / 86400 as days
                 from listens
                where user_id = %s and started_at > now() - interval '400 days'""",
            (user_id,)):
        decay = _fade(r["days"], TASTE_HALF_LIFE)
        ms = r["ms_played"] or 0
        if r["completed"] or ms >= 90_000:
            v = 1.0
        elif ms < SKIP_MS:
            v = -1.2
        else:
            v = 0.2
        add(t.heard, r["track_id"], v * decay)
        if float(r["days"]) * 24 < RECENT_H:
            t.recent.add(r["track_id"])
        if v != 0.2 and is_night(r["started_at"], tz):
            add(t.night, r["track_id"], (1.0 if v > 0 else -0.5) * decay)
    active = dict(t.heard)

    for r in db.all_(
            """select distinct i.track_id from playlist_items i
                 join playlists p on p.id = i.playlist_id
                where p.owner_id = %s and p.kind = 'favourites'""", (user_id,)):
        t.hearted.add(r["track_id"])
        add(active, r["track_id"], HEART)

    # Lists of their own, the newer additions counting more, never less than half.
    for r in db.all_(
            """select i.track_id, extract(epoch from now() - max(i.added_at)) / 86400 as days
                 from playlist_items i join playlists p on p.id = i.playlist_id
                where p.owner_id = %s and p.kind = 'local'
                group by 1""", (user_id,)):
        t.listed.add(r["track_id"])
        add(active, r["track_id"], OWN_LIST * max(0.5, _fade(r["days"], 180)))

    # The booth: every record mixed in, a mix thumbed up or played again.
    for r in db.all_(
            """select event, from_track, to_track, rating,
                      extract(epoch from now() - at) / 86400 as days
                 from mix_feedback
                where user_id = %s and event in ('mix', 'rating', 'replay')
                  and at > now() - interval '400 days'""", (user_id,)):
        decay = _fade(r["days"], TASTE_HALF_LIFE)
        if r["event"] == "mix":
            pairs = [(r["to_track"], BOOTH)]
        elif r["event"] == "replay" or (r["rating"] or 0) > 0:
            pairs = [(r["from_track"], BOOTH / 2), (r["to_track"], BOOTH / 2)]
        else:
            continue
        for tid, v in pairs:
            if tid:
                add(active, tid, v * decay)

    # A sleeve drawn on, cues set by hand, a sample cut out of it: somebody cared.
    for r in db.all_(
            """select track_id from sleeve_marks where author_id = %s
               union select track_id from track_cues where set_by = %s
               union select (origin->>'track_id')::int from samples
                      where user_id = %s and not house and origin->>'kind' = 'cut'
                        and origin->>'track_id' ~ '^[0-9]+$'""", (user_id, user_id, user_id)):
        if r["track_id"]:
            add(active, r["track_id"], TOUCHED)

    station_artists: dict[str, float] = {}
    for r in db.all_(
            """select kind, seed_track, seed_text,
                      extract(epoch from now() - created_at) / 86400 as days
                 from stations where owner_id = %s""", (user_id,)):
        decay = _fade(r["days"], 60)
        if r["kind"] == "track" and r["seed_track"]:
            add(active, r["seed_track"], STATION * decay)
        elif r["kind"] == "album" and r["seed_track"]:
            add(active, r["seed_track"], STATION * decay / 2)
        elif r["kind"] == "artist" and r["seed_text"]:
            add(station_artists, r["seed_text"].lower(), STATION_ARTIST * decay)
        elif r["kind"] == "genre" and r["seed_text"]:
            g = brainz.fold(r["seed_text"])
            if g:
                t.genres[g] = max(t.genres.get(g, 0.0), 0.5)

    for r in db.all_("select track_id from jam_skip_votes where user_id = %s", (user_id,)):
        add(active, r["track_id"], JAM_SKIP)

    # Kept rather than played: likes and lists from elsewhere, lists of others. A song
    # on several counts for the most it is on, not for each.
    passive: dict[int, float] = {}

    def keep(tid: int, v: float) -> None:
        if v > passive.get(tid, 0.0):
            passive[tid] = v

    for r in db.all_(
            """select i.track_id, i.pos, p.kind, p.remote_id, p.name
                 from playlist_items i join playlists p on p.id = i.playlist_id
                where p.owner_id = %s and p.kind not in ('local', 'favourites')""",
            (user_id,)):
        if is_likes(r["remote_id"], r["name"]):
            keep(r["track_id"], LIKED_ELSEWHERE
                 * (0.35 + 0.65 * 0.5 ** (max(0, r["pos"] or 0) / LIKED_HALF_RANK)))
            t.liked.setdefault(r["track_id"], r["kind"])
        else:
            keep(r["track_id"], MIRRORED)
            t.mirrored.setdefault(r["track_id"], r["kind"])
    for r in db.all_(
            """select distinct i.track_id from playlist_saves s
                 join playlist_items i on i.playlist_id = s.playlist_id
                where s.user_id = %s""", (user_id,)):
        keep(r["track_id"], SAVED)

    # Lists opened lately: what somebody is into this week, a little.
    lately: dict[int, float] = {}
    for r in db.all_(
            """select i.track_id,
                      extract(epoch from now() - max(pp.last_opened_at)) / 86400 as days
                 from playlist_places pp join playlist_items i on i.playlist_id = pp.playlist_id
                where pp.user_id = %s and pp.last_opened_at > now() - interval '14 days'
                group by 1""", (user_id,)):
        lately[r["track_id"]] = OPENED * _fade(r["days"], 7)

    t.followed = {r["name"].lower() for r in db.all_(
        "select name from artist_follows where user_id = %s and not is_label", (user_id,))}
    # Whose records the labels they follow have put out, the newest first; not the
    # label's own name on its compilations, and not "Various Artists".
    from .linked import credited_to
    for r in db.all_(
            """select r.artist, f.name as label
                 from artist_follows f
                 join artist_releases r on r.provider = f.provider and r.artist_id = f.remote_id
                where f.user_id = %s and f.is_label
                order by r.release_date desc nulls last, r.first_seen desc
                limit 400""", (user_id,)):
        act = (r["artist"] or "").strip()
        if (not act or act.lower() in NOT_AN_ACT or credited_to(r["label"], act)
                or act.lower() in t.followed):
            continue
        t.label_acts.setdefault(act.lower(), r["label"])
    for r in db.all_("select genre from genre_follows where user_id = %s", (user_id,)):
        t.genres[r["genre"]] = 1.0

    try:
        from . import elsewhere
        known = elsewhere.known(user_id)
    except Exception:  # noqa: BLE001 — what other services said is a bonus, never a need
        known = {}
    t.elsewhere = dict(known.get("artists") or {})
    for tid, v in (known.get("tracks") or {}).items():
        add(active, int(tid), float(v))
    # A genre most of somebody's top acts elsewhere are filed under, a little.
    for g, n in (known.get("genres") or {}).items():
        if n >= 2:
            t.genres[g] = max(t.genres.get(g, 0.0), 0.5)

    # A song said no to counts for nothing it was played or kept for: it seeds nothing,
    # and does not speak for its artist.
    t.disliked = {r["track_id"] for r in db.all_(
        "select track_id from track_dislikes where user_id = %s", (user_id,))}
    for signal in (active, passive, lately):
        for tid in t.disliked:
            signal.pop(tid, None)

    t.active = active
    t.track = dict(active)
    for k, v in passive.items():
        add(t.track, k, v)
    for k, v in lately.items():
        add(t.track, k, v)

    if t.track:
        kept_by: dict[str, float] = {}
        for r in db.all_("select id, artists from tracks where id = any(%s)",
                         (list(t.track),)):
            for a in r["artists"] or []:
                k = a.lower()
                if k in NOT_AN_ACT:
                    continue
                if r["id"] in active:
                    add(t.artist, k, active[r["id"]])
                if r["id"] in t.heard:
                    add(t.artist_heard, k, t.heard[r["id"]])
                if r["id"] in passive:
                    add(kept_by, k, passive[r["id"]])
        for k, v in kept_by.items():
            add(t.artist, k, PASSIVE_SCALE * math.log1p(v))
    for k in t.followed:
        add(t.artist, k, FOLLOWED)
    for k in t.label_acts:
        add(t.artist, k, LABEL_ACT)
    for k, v in station_artists.items():
        add(t.artist, k, v)
    for k, v in t.elsewhere.items():
        add(t.artist, k, v)

    # And against its artist: a little for one, nothing of theirs at all past a couple.
    if t.disliked:
        for r in db.all_("select artists from tracks where id = any(%s)", (list(t.disliked),)):
            for a in r["artists"] or []:
                k = a.lower()
                if k in NOT_AN_ACT:
                    continue
                t.artist_disliked[k] = t.artist_disliked.get(k, 0) + 1
                add(t.artist, k, DISLIKED)

    t.dismissed = {r["key"] for r in db.all_(
        "select key from rec_dismissals where user_id = %s", (user_id,))}
    t.dismissed |= {f"t:{tid}" for tid in t.disliked}
    t.library = {r["track_id"] for r in db.all_(
        "select track_id from library_items where user_id = %s", (user_id,))}
    return t


def dislike(user_id: int, track_id: int, *, undo: bool = False) -> bool:
    """Not for me — or, with [undo], it was after all. Taken out of every list made
    for them at once, so the feed does not offer it again before the next build.
    Answers whether it is disliked now."""
    if undo:
        db.run("delete from track_dislikes where user_id=%s and track_id=%s",
               (user_id, track_id))
        return False
    db.run("insert into track_dislikes(user_id, track_id) values(%s,%s) "
           "on conflict do nothing", (user_id, track_id))
    db.run("update made_lists set track_ids = array_remove(track_ids, %s) "
           "where user_id=%s and %s = any(track_ids)", (track_id, user_id, track_id))
    return True


def disliked(user_id: int) -> list[int]:
    return [r["track_id"] for r in db.all_(
        "select track_id from track_dislikes where user_id=%s order by at desc", (user_id,))]


def dismiss(user_id: int, *, track_id: int | None = None, video_id: str | None = None) -> None:
    keys = []
    if track_id:
        keys.append(f"t:{int(track_id)}")
        row = db.one("select provider_id from track_sources where track_id = %s "
                     "and provider = 'ytmusic'", (track_id,))
        if row:
            keys.append(f"v:{row['provider_id']}")
    if video_id:
        keys.append(f"v:{video_id}")
        known = catalog.find_by_video_id(video_id)
        if known:
            keys.append(f"t:{known['id']}")
    for k in keys:
        db.run("insert into rec_dismissals(user_id, key) values(%s,%s) "
               "on conflict do nothing", (user_id, k))


# ------------------------------------------------------------------ the signals
Hits = dict  # candidate -> {signal: (value, seed id)}


def _add(hits: Hits, cand, signal: str, value: float, seed: int) -> None:
    per = hits.setdefault(cand, {})
    have = per.get(signal)
    if have is None:
        per[signal] = (value, seed)
    else:
        # Summed across seeds, named after the seed that gave the most.
        best = seed if value > have[0] else have[1]
        per[signal] = (have[0] + value, best)


def _from_lists(seeds: dict[int, float], hits: Hits) -> None:
    rows = db.all_(
        """with sized as (
               select playlist_id, count(*) n from playlist_items group by 1
           )
           select a.track_id as seed, b.track_id as cand,
                  sum(1.0 / ln(2 + s.n)) as w
             from playlist_items a
             join sized s on s.playlist_id = a.playlist_id and s.n <= %s
             join playlist_items b on b.playlist_id = a.playlist_id
                                  and b.track_id <> a.track_id
            where a.track_id = any(%s)
            group by 1, 2""",
        (LIST_MOST, list(seeds)))
    for r in rows:
        _add(hits, r["cand"], "lists", float(r["w"]) * seeds[r["seed"]], r["seed"])


def _from_sessions(seeds: dict[int, float], hits: Hits) -> None:
    rows = db.all_(
        """with seq as (
               select user_id, track_id, started_at,
                      completed or ms_played >= %s as heard,
                      row_number() over (partition by user_id order by started_at) as n
                 from listens
                where started_at > now() - interval '2 years'
           )
           select a.track_id as seed, b.track_id as cand,
                  sum(1.0 / abs(b.n - a.n)) as w
             from seq a
             join seq b on b.user_id = a.user_id
                       and b.n between a.n - %s and a.n + %s and b.n <> a.n
                       and abs(extract(epoch from b.started_at - a.started_at)) < %s
            where a.track_id = any(%s) and a.heard and b.heard
              and b.track_id <> a.track_id
            group by 1, 2""",
        (SKIP_MS, REACH, REACH, SITTING_S, list(seeds)))
    for r in rows:
        _add(hits, r["cand"], "sessions", float(r["w"]) * seeds[r["seed"]], r["seed"])


def _videos_of(track_ids) -> dict[int, str]:
    return {r["track_id"]: r["provider_id"] for r in db.all_(
        """select track_id, provider_id from track_sources
            where provider = 'ytmusic' and track_id = any(%s)""", (list(track_ids),))}


def remember_radio(seed_video: str, offered: list[dict]) -> None:
    """Write down a watch playlist, replacing what was known of that seed."""
    with db.pool().connection() as c:
        c.execute("delete from radio_edges where seed_video = %s", (seed_video,))
        # A row from the seed to itself says "asked, nothing came back": it is never
        # offered (a seed is never its own answer), and it stops the same question being
        # put on every look for a song YouTube Music has no radio for.
        c.execute("""insert into radio_edges(seed_video, video, rank)
                     values(%s,%s,999)""", (seed_video, seed_video))
        for rank, cand in enumerate(offered):
            v = cand.get("video_id")
            if not v or v == seed_video:
                continue
            meta = {k: cand.get(k) for k in ("title", "artists", "album", "duration_ms")}
            meta["thumbnails"] = ((cand.get("raw") or {}).get("thumbnails") or [])[:3]
            c.execute(
                """insert into radio_edges(seed_video, video, rank, meta)
                   values(%s,%s,%s,%s) on conflict do nothing""",
                (seed_video, v, rank, json.dumps(meta)))


def ask_radio(videos: list[str], *, budget: int = RADIO_ASK) -> None:
    """Ask YouTube Music about the seeds it has not been asked about this week, a few
    at a time; the rest are answered from what was written down before."""
    if not videos or budget <= 0:
        return
    fresh = {r["seed_video"] for r in db.all_(
        """select seed_video from radio_edges
            where seed_video = any(%s)
            group by 1 having max(seen_at) > now() - %s * interval '1 second'""",
        (videos, RADIO_FRESH_S))}
    for v in [v for v in videos if v not in fresh][:budget]:
        try:
            offered = ytm.watch_playlist(v, limit=40)
        except ytm.Unavailable:
            continue
        except Exception:  # noqa: BLE001 — the network is not a reason to fail an answer
            continue
        remember_radio(v, offered)


def _from_radio(seeds: dict[int, float], hits: Hits, remote: dict[str, dict]) -> None:
    videos = _videos_of(seeds)
    if not videos:
        return
    by_video = {v: t for t, v in videos.items()}
    rows = db.all_(
        """select e.seed_video, e.video, e.rank, e.meta, s.track_id
             from radio_edges e
             left join track_sources s on s.provider = 'ytmusic' and s.provider_id = e.video
            where e.seed_video = any(%s)""", (list(by_video),))
    # And the other way: songs whose radio this seed turned up in.
    back = db.all_(
        """select e.video as seed_video, e.seed_video as video, e.rank, '{}'::jsonb as meta,
                  s.track_id
             from radio_edges e
             join track_sources s on s.provider = 'ytmusic' and s.provider_id = e.seed_video
            where e.video = any(%s)""", (list(by_video),))
    for r, factor in [(r, 1.0) for r in rows] + [(r, 0.5) for r in back]:
        seed = by_video.get(r["seed_video"])
        if seed is None:
            continue
        w = factor * seeds[seed] / math.sqrt(1 + (r["rank"] or 0))
        if r["track_id"]:
            _add(hits, r["track_id"], "radio", w, seed)
        else:
            meta = r["meta"] if isinstance(r["meta"], dict) else json.loads(r["meta"] or "{}")
            if not meta.get("title"):
                continue
            remote.setdefault(r["video"], meta)
            _add(hits, f"v:{r['video']}", "radio", w, seed)


_SOUND: tuple[float, list[int], object] | None = None


def _sound_matrix():
    """Every analysed record's sound row, normalised, held for ten minutes."""
    global _SOUND
    import numpy as np
    if _SOUND and time.monotonic() - _SOUND[0] < 600:
        return _SOUND[1], _SOUND[2]
    rows = db.all_("select track_id, sound from track_traits where sound is not null")
    ids, vecs = [], []
    for r in rows:
        v = r["sound"] if isinstance(r["sound"], list) else json.loads(r["sound"])
        if v:
            ids.append(r["track_id"])
            vecs.append(v)
    if not vecs:
        _SOUND = (time.monotonic(), [], None)
        return [], None
    width = max(len(v) for v in vecs)
    m = np.array([v + [0.0] * (width - len(v)) for v in vecs], dtype=np.float32)
    norms = np.linalg.norm(m, axis=1, keepdims=True)
    norms[norms == 0] = 1
    _SOUND = (time.monotonic(), ids, m / norms)
    return ids, _SOUND[2]


def forget_sound() -> None:
    global _SOUND
    _SOUND = None


def _from_sound(seeds: dict[int, float], hits: Hits, top: int = 60) -> None:
    import numpy as np
    ids, m = _sound_matrix()
    if m is None:
        return
    at = {t: i for i, t in enumerate(ids)}
    for seed, weight in seeds.items():
        i = at.get(seed)
        if i is None:
            continue
        sims = m @ m[i]
        order = np.argpartition(-sims, min(top, len(sims) - 1))[:top + 1]
        for j in order:
            if j == i:
                continue
            v = traits.sound_alike(float(sims[j]))
            if v > 0:
                _add(hits, ids[j], "sound", v * weight, seed)


def _from_artist(seeds: dict[int, float], rows: dict[int, dict], hits: Hits) -> None:
    """The same act, counted as often as the seeds have them: a list that is half one
    band wants more of that band than of the one it has once."""
    names: dict[str, tuple[float, int]] = {}
    for s in seeds:
        for a in (rows.get(s) or {}).get("artists") or []:
            k = a.lower()
            w, first = names.get(k, (0.0, s))
            names[k] = (w + seeds[s], first)
    if not names:
        return
    for r in db.all_(
            """select t.id, t.artists from tracks t
                where exists (select 1 from unnest(t.artists) a where lower(a) = any(%s))
                  and t.state <> 'failed'""", (list(names),)):
        best = max((names[a.lower()] for a in r["artists"] or [] if a.lower() in names),
                   default=None)
        if best:
            _add(hits, r["id"], "artist", best[0], best[1])


# ------------------------------------------------------------------ the answer
@dataclass
class Pick:
    key: object             # track id, or "v:<video id>"
    where: str              # library | waiting | house | new
    score: float
    why: str
    row: dict               # tracks row, or remote meta
    seed: int | None = None  # the seed it goes with most
    lead: str | None = None  # the question that answered it most (lists, radio, ...)


def _norm_key(title: str, artists) -> tuple[str, str]:
    t = traits._title_key(title or "")
    t = unicodedata.normalize("NFKD", t)
    first = (artists or [""])[0] if artists else ""
    return t, (first or "").lower().strip()


def _rows_for(ids) -> dict[int, dict]:
    if not ids:
        return {}
    return {r["id"]: r for r in db.all_(
        """select t.*, m.path, m.bytes, m.sha256, c.color as cover_color,
                  c.sha256 as cover_sha, s.provider_id
             from tracks t
             left join media m on m.track_id = t.id and m.role = 'canonical'
             left join covers c on c.id = t.cover_id
             left join track_sources s on s.track_id = t.id and s.provider = 'ytmusic'
            where t.id = any(%s)""", (list(ids),))}


def _genre_fit(artists: list[str], genres: dict[str, float],
               known: dict[str, dict]) -> tuple[str, float] | None:
    """The followed genre an act is filed under, and how much it is followed."""
    best: tuple[str, float] | None = None
    for name in artists[:2]:
        for g in (known.get(brainz.fold(name)) or {}).get("genres") or []:
            w = genres.get(brainz.fold(g))
            if w and (best is None or w > best[1]):
                best = (g, w)
    return best


def _phrase(signal: str, seed: dict | None, row: dict, taste_word: str | None) -> str:
    name = (seed or {}).get("title") or "this"
    name = catalog.display_title(name, (seed or {}).get("artists")) if seed else name
    if signal == "lists":
        return f"on lists with {name}"
    if signal == "sessions":
        return f"played around {name}"
    if signal == "radio":
        return f"YouTube Music plays it after {name}"
    if signal == "sound":
        return f"sounds like {name}"
    if signal == "artist":
        theirs = {a.lower() for a in (seed or {}).get("artists") or []}
        shared = [a for a in row.get("artists") or [] if a.lower() in theirs]
        return f"more {(shared or row.get('artists') or ['of the same'])[0]}"
    return taste_word or ""


def recommend(user_id: int, seeds: dict[int, float], *, limit: int = 12,
              fresh: float = 0.5, only: str | None = None,
              exclude: set[int] = frozenset(), avoid: dict[int, float] | None = None,
              network: bool = True, the_taste: Taste | None = None,
              weights: dict[str, float] | None = None) -> list[Pick]:
    """The songs that go with [seeds] (track id → how much it counts), for this person.

    [fresh] is the share of the answer given to what is not already in their library
    and here (0 = only theirs, 1 = only new to them); [only] narrows to `library` (theirs
    and here) or `new` (anything else). [avoid] is songs to steer away from — a station's
    skips — whose neighbours are marked down. [network] off answers from what is known.
    [weights] overrides WEIGHTS for this answer.
    """
    w = {**WEIGHTS, **(weights or {})}
    limit = max(1, min(limit, MOST))
    seeds = {int(k): float(v) for k, v in seeds.items() if v > 0}
    if not seeds:
        return []
    tas = the_taste or taste(user_id)
    seed_rows = _rows_for(seeds)

    if network:
        ask_radio([v for v in _videos_of(seeds).values()])

    hits: Hits = {}
    remote: dict[str, dict] = {}
    _from_lists(seeds, hits)
    _from_sessions(seeds, hits)
    _from_radio(seeds, hits, remote)
    _from_sound(seeds, hits)
    _from_artist(seeds, seed_rows, hits)

    against: Hits = {}
    if avoid:
        avoid = {int(k): float(v) for k, v in avoid.items() if v > 0}
        _from_lists(avoid, against)
        _from_sessions(avoid, against)
        _from_radio(avoid, against, {})
        _from_sound(avoid, against)

    # Scale each signal to its best candidate.
    top = {s: 0.0 for s in WEIGHTS}
    for per in hits.values():
        for s, (v, _) in per.items():
            top[s] = max(top[s], v)
    top_against = {s: 0.0 for s in WEIGHTS}
    for per in against.values():
        for s, (v, _) in per.items():
            top_against[s] = max(top_against[s], v)

    # A song YouTube offers under a video id the house does not have may still be a
    # song the house has, uploaded twice. Known by title and first artist, and then
    # offered as the one that is here.
    if remote:
        norms = list({search_norm(m.get("title") or "") for m in remote.values()})
        known_keys = {_norm_key(r["title"], r["artists"]): r["id"] for r in db.all_(
            """select id, title, artists from tracks
                where norm_title = any(%s) and state <> 'failed'""", (norms,))}
        for video, meta in list(remote.items()):
            same = known_keys.get(_norm_key(meta.get("title") or "", meta.get("artists")))
            per = hits.pop(f"v:{video}", None) if same else None
            if per:
                for s, (v, seed) in per.items():
                    _add(hits, same, s, v, seed)

    ids = [k for k in hits if isinstance(k, int)]
    rows = _rows_for(ids)
    seed_titles = {_norm_key(r["title"], r["artists"])[0] for r in seed_rows.values()}
    seed_videos = set(_videos_of(seeds).values())
    # The genres somebody follows, against what MusicBrainz said of each act when it
    # was last asked (from the cache: an answer never waits on it).
    genres_known: dict[str, dict] = {}
    if tas.genres:
        names: set[str] = set()
        for key in hits:
            row = rows.get(key) if isinstance(key, int) else remote.get(key[2:])
            names.update(((row or {}).get("artists") or [])[:2])
        genres_known = brainz.known_artists(names)

    scored: list[Pick] = []
    for key, per in hits.items():
        if key in seeds or key in exclude:
            continue
        if isinstance(key, int):
            row = rows.get(key)
            if not row or row["state"] == "failed":
                continue
            if f"t:{key}" in tas.dismissed or (row.get("provider_id") and
                                                f"v:{row['provider_id']}" in tas.dismissed):
                continue
            if row.get("provider_id") in seed_videos:
                continue
            mine = key in tas.library
            where = ("library" if row["state"] == "ready" else "waiting") if mine else \
                    ("house" if row["state"] == "ready" else "new")
        else:
            video = key[2:]
            if key in tas.dismissed or video in seed_videos:
                continue
            row = {"video_id": video, **remote.get(video, {})}
            where = "new"
        k = _norm_key(row.get("title") or "", row.get("artists"))
        if k[0] and k[0] in seed_titles:
            continue  # the same song again, another version of it

        parts = {s: w[s] * v / top[s] for s, (v, _) in per.items() if top[s] > 0 and w[s] > 0}
        score = sum(parts.values())
        # Two questions agreeing is worth more than one shouting.
        score *= 1 + 0.15 * (len(parts) - 1)

        taste_word = None
        if isinstance(key, int):
            mine_score = tas.track.get(key, 0.0)
            if mine_score <= -1.5:
                continue  # skipped, again and again
            score += 0.25 * math.tanh(mine_score / 2)
            if key in tas.recent:
                score -= 0.8
            if key in tas.hearted:
                taste_word = "one of your favourites"
            elif key in tas.liked:
                service = tas.liked[key]
                taste_word = f"you liked it on {SERVICE_NAMES.get(service, service.title())}"
            elif where == "waiting" and not tas.heard.get(key):
                taste_word = "in your library, never played here"
        artists = row.get("artists") or []
        if any(tas.artist_disliked.get(a.lower(), 0) >= DISLIKES_ENOUGH for a in artists):
            continue
        best_artist = max((tas.artist.get(a.lower(), 0.0) for a in artists), default=0.0)
        score += 0.3 * math.tanh(best_artist / 4)
        if not taste_word and artists:
            heard = max(tas.artist_heard.get(a.lower(), 0.0) for a in artists)
            followed = next((a for a in artists if a.lower() in tas.followed), None)
            on_label = next((tas.label_acts[a.lower()] for a in artists
                             if a.lower() in tas.label_acts), None)
            if heard >= 3:
                taste_word = f"you play a lot of {artists[0]}"
            elif followed:
                taste_word = f"you follow {followed}"
            elif on_label:
                taste_word = f"on {on_label}, which you follow"
        fit = _genre_fit(artists, tas.genres, genres_known) if genres_known else None
        if fit:
            score += 0.15 * fit[1]
            if not taste_word:
                taste_word = f"{fit[0]}, which you follow" if fit[1] >= 1 else fit[0]

        if against.get(key):
            pen = sum(w[s] * v / top_against[s]
                      for s, (v, _) in against[key].items() if top_against[s] > 0)
            score -= 0.6 * pen

        lead = max(parts.items(), key=lambda kv: kv[1])[0] if parts else None
        words = []
        if lead:
            words.append(_phrase(lead, seed_rows.get(per[lead][1]), row, None))
        if taste_word:
            words.append(taste_word)
        scored.append(Pick(key=key, where=where, score=score, why=" · ".join(x for x in words if x),
                           row=row, seed=per[lead][1] if lead else None, lead=lead))

    scored.sort(key=lambda p: -p.score)
    if only == "library":
        pools = [[p for p in scored if p.where == "library"]]
        wants = [limit]
    elif only == "new":
        pools = [[p for p in scored if p.where != "library"]]
        wants = [limit]
    else:
        f = max(0.0, min(1.0, fresh))
        n_new = round(limit * f)
        pools = [[p for p in scored if p.where == "library"],
                 [p for p in scored if p.where != "library"]]
        wants = [limit - n_new, n_new]

    out: list[Pick] = []
    per_artist: dict[str, int] = {}
    titles: set[tuple[str, str]] = set()

    def take(p: Pick) -> bool:
        artist = ((p.row.get("artists") or [""])[0] or "").lower()
        k = _norm_key(p.row.get("title") or "", p.row.get("artists"))
        if per_artist.get(artist, 0) >= PER_ARTIST or (k[0] and k in titles):
            return False
        per_artist[artist] = per_artist.get(artist, 0) + 1
        titles.add(k)
        out.append(p)
        return True

    leftovers: list[Pick] = []
    for pool, want in zip(pools, wants):
        got = 0
        for p in pool:
            if got >= want:
                leftovers.append(p)
                continue
            if take(p):
                got += 1
    # One pool short (nothing new to be had, or a library too small): the other fills
    # in — unless it was asked for only the one.
    if only is None and not 0 < fresh < 1:
        leftovers = []
    for p in sorted(leftovers, key=lambda p: -p.score):
        if len(out) >= limit:
            break
        take(p)
    out.sort(key=lambda p: -p.score)
    return out[:limit]


def search_norm(title: str) -> str:
    """tracks.norm_title, in Python: lower case, only letters, digits and spaces."""
    return "".join(ch for ch in title.lower() if ch.isalnum() or ch == " ")


def public(p: Pick) -> dict:
    """A pick as the app sees it: the track, or a remote hit shaped like a search's."""
    out = {"where": p.where, "score": round(p.score, 3), "why": p.why, "seed": p.seed}
    if isinstance(p.key, int):
        out["track"] = catalog.public(p.row)
    else:
        meta = p.row
        out["hit"] = {
            "video_id": meta["video_id"], "title": meta.get("title") or meta["video_id"],
            "artists": meta.get("artists") or [], "album": meta.get("album"),
            "duration_ms": meta.get("duration_ms"), "known": False,
            "cover_url": search._art(ytm.thumbnail_url({"thumbnails": meta.get("thumbnails") or []})),
        }
    return out


# ------------------------------------------------------------------ seeds from things
def seeds_of_playlist(playlist_id: int, most: int = 600) -> tuple[dict[int, float], set[int]]:
    """A list's songs as seeds — the ones added lately count more, and a very long list
    is sampled, turning over daily — and all of them as what not to offer. All of it
    where it can be: forty songs out of a list of two hundred recovered a fifth fewer."""
    rows = db.all_(
        """select track_id, pos from playlist_items where playlist_id = %s
            order by pos""", (playlist_id,))
    every = {r["track_id"] for r in rows}
    if len(rows) <= most:
        return {r["track_id"]: 1.0 for r in rows}, every
    newest = rows[-(most // 2):]
    rest = rows[:-(most // 2)]
    day = int(time.time() // 86400)
    rest.sort(key=lambda r: hash((r["track_id"], day)))
    picked = {r["track_id"]: 1.0 for r in newest}
    picked.update({r["track_id"]: 0.7 for r in rest[:most - len(newest)]})
    return picked, every


# A mix made for somebody out of what they play leans less on "more by the same":
# their favourite acts are already in their ears.
PERSON_WEIGHTS = {"artist": 0.4, "sessions": 0.9}


def seeds_of_person(user_id: int, most: int = 10, the_taste: Taste | None = None) -> dict[int, float]:
    """What somebody has been into lately, for a mix made for them: the songs heard
    through most these last weeks, and beside them — up to a third of the seeds — what
    else they did lately: hearted it, put it on a list, mixed it in the booth, started a
    station from it, liked it on another service, played it there (elsewhere.py)."""
    rows = db.all_(
        """select track_id,
                  sum(case when completed or ms_played >= 90000 then 1 else 0 end
                      * power(0.5, extract(epoch from now() - started_at) / 86400 / 14)) as w
             from listens where user_id = %s and started_at > now() - interval '60 days'
            group by 1 having sum(case when completed then 1 else 0 end) > 0
            order by w desc limit %s""", (user_id, most))
    played = {r["track_id"]: max(0.3, min(1.0, float(r["w"]))) for r in rows if r["w"]}

    lately: dict[int, float] = {}

    def put(tid: int | None, w: float) -> None:
        if tid and tid not in played and w > lately.get(tid, 0.0):
            lately[tid] = w

    for r in db.all_(
            """select i.track_id, p.kind, max(i.added_at) as at
                 from playlist_items i join playlists p on p.id = i.playlist_id
                where p.owner_id = %s and p.kind in ('favourites', 'local')
                  and i.added_at > now() - interval '30 days'
                group by 1, 2 order by at desc limit 60""", (user_id,)):
        put(r["track_id"], 0.9 if r["kind"] == "favourites" else 0.7)
    for r in db.all_(
            """select to_track from mix_feedback
                where user_id = %s and event = 'mix' and at > now() - interval '14 days'
                group by 1 order by count(*) desc, max(at) desc limit 20""", (user_id,)):
        put(r["to_track"], 0.6)
    for r in db.all_(
            """select seed_track from stations
                where owner_id = %s and kind = 'track' and created_at > now() - interval '30 days'
                order by created_at desc limit 10""", (user_id,)):
        put(r["seed_track"], 0.6)
    # The newest likes on another service, while the list is one that was read lately:
    # the top of an old copy is what somebody liked a long time ago.
    for r in db.all_(
            """select i.track_id, i.pos, p.remote_id, p.name
                 from playlist_items i join playlists p on p.id = i.playlist_id
                where p.owner_id = %s and p.kind not in ('local', 'favourites')
                  and i.pos < 10 and p.last_synced_at > now() - interval '60 days'""",
            (user_id,)):
        if is_likes(r["remote_id"], r["name"]):
            put(r["track_id"], 0.5 - 0.02 * r["pos"])
    try:
        from . import elsewhere
        for tid, w in elsewhere.lately(user_id).items():
            put(int(tid), min(0.8, float(w)))
    except Exception:  # noqa: BLE001
        pass

    room = min(len(lately), max(1, most // 3)) if lately else 0
    out = dict(sorted(played.items(), key=lambda kv: -kv[1])[:most - room])
    for tid, w in sorted(lately.items(), key=lambda kv: -kv[1]):
        if len(out) >= most:
            break
        out.setdefault(tid, w)
    if len(out) < 3:
        tas = the_taste or taste(user_id)
        for t in list(tas.hearted)[: most - len(out)]:
            out.setdefault(t, 0.8)
    return out


def rediscover(user_id: int, limit: int = 10, the_taste: Taste | None = None) -> list[int]:
    """Songs somebody loved and has not played for two months: hearted, or finished
    over and over, and then left."""
    tas = the_taste or taste(user_id)
    rows = db.all_(
        """select l.track_id, count(*) filter (where l.completed) as done,
                  max(l.started_at) as last
             from listens l join tracks t on t.id = l.track_id and t.state = 'ready'
            where l.user_id = %s
            group by 1
           having max(l.started_at) < now() - interval '60 days'
              and count(*) filter (where l.completed) >= 3""", (user_id,))
    scored = {r["track_id"]: float(r["done"]) for r in rows}
    for t in tas.hearted:
        if t not in tas.recent:
            scored.setdefault(t, 0.0)
            scored[t] += 2
    if tas.hearted:
        played_lately = {r["track_id"] for r in db.all_(
            """select distinct track_id from listens where user_id = %s
                and started_at > now() - interval '60 days'""", (user_id,))}
        for t in list(scored):
            if t in played_lately:
                del scored[t]
    ready = {r["id"] for r in db.all_(
        "select id from tracks where id = any(%s) and state = 'ready'", (list(scored),))}
    order = sorted((t for t in scored if t in ready and f"t:{t}" not in tas.dismissed),
                   key=lambda t: (-scored[t], hash((t, int(time.time() // 86400)))))
    return order[:limit]
