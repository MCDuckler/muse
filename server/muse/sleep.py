"""The sleep mix: something to fall asleep to, made of what somebody plays.

The sleep playlists every service has are the same list for everybody — rain, a
piano, a cello. This one is the calm end of a person's own music, with a few songs
from the house and further out that sound like it, laid out to wind down: the
familiar first, then quieter, and the stillest last, an hour or so in all. Made every
night with the other lists (discover.build_for), a little different each time.

How calm a record is comes from what the analysis heard (traits.py): how loud it is,
whether it has a pulse at all and how hard its beats hit, and how fast it goes. Loud
alone would not do — a record mastered in 1985 is ten decibels quieter than one
mastered last year without being any calmer — and a song nobody can sleep to hits
hard on every beat at any volume. Measured on the house's records (2026-10-05), that
tells the still apart from the rest well and a quiet ballad from quiet rock badly, so
only the clearly calm are taken, and what people said about a record moves it: lists
named for sleep, night or ambient (somebody's "Schlafmix", "Electronic, no beat") and
lists named for the club; the genres the music database files its act under; a title
that says so. What somebody likes comes from recommend.taste: what they play and keep,
and what they already play at night.

A record the analysis has not heard yet (one fetched for this list) is let in only
when it is close to the calmest of the person's own songs and says nothing loud about
itself, a few at most, in the middle — and judged by its sound from the next night on.
"""
from __future__ import annotations

import datetime as dt
import logging
import math
import random
import re

from . import db, recommend, traits

log = logging.getLogger("muse.sleep")

SLUG = "sleep"
NAME = "Sleep mix"
ORDINAL = 35

# Calm enough to fall asleep to (energy, 0 still to 1 driving), and calm enough to
# open with — a little more pulse is fine while somebody is still awake, for a song
# of their own they like.
CALM_MAX = 0.26
OPENING_MAX = 0.32

# How long: an hour or a little more, never past this many songs.
MINUTES = 60
MINUTES_MOST = 80
MOST = 24
LEAST = 8

# Of the list: songs the person plays, and the share the house, the new ones and the
# less calm openers may take.
HOUSE_SHARE = 0.35
NEW_MOST = 3
OPENING_SHARE = 0.3

# Songs, not talks: anything shorter is a clip or a jingle, anything longer a set.
SHORTEST_MS = 100_000
LONGEST_MS = 15 * 60_000

# Last night's list, a little less likely tonight: about half of it changes each day.
AGAIN = 0.12

# Words a talk, a tutorial or a set is called by and a song is not ("Chain Reaction",
# "Trailer Trash", "Breakdown", "Inside Out" and "#1 Crush" are songs): a hashtag, a
# "behind the scenes", somebody's studio from the inside.
_TALK = re.compile(
    r"#[a-z]|^inside\b[^(]*\w['’]|\b(explained|tutorial|how to|unboxing|reaction video|"
    r"reacts to|interview|podcast|documentary|official trailer|subscribers|dj set|"
    r"live set|boiler room|full album|sample pack|sound design|making of|beat for|asmr|"
    r"audiobook|chapter \d+|fl studio|ableton|studio tour|in the studio|"
    r"behind the scenes|masterclass|walkthrough)\b", re.I)
# Channels rather than musicians: what they upload is talk about music.
_CHANNELS = {"resident advisor", "boiler room", "npr music", "kexp", "cercle", "colors",
             "mixmag", "dj mag", "red bull music academy", "the needle drop"}
_LOUD = re.compile(
    r"\b(remix|edit|bootleg|vip|rework|flip|sped up|speed up|nightcore|hardstyle|"
    r"bass boosted|rave|club mix|extended mix|hardcore|gabber|phonk|drill)\b", re.I)
_STILL = re.compile(
    r"\b(sleep|lullaby|ambient|piano|nocturne|rain|calm|quiet|still|drift|dream|"
    r"meditation|reverie|adagio|largo|interlude|reprise|lento|moon|night)\b", re.I)

# What a list is called, when it says how its songs feel. Postgres regular expressions,
# matched without case: a list named for sleep or the night, and one named for the club.
CALM_LISTS = (r"(schlaf|sleep|ambient|no beat|slow|n[äa]chtlich|m[äa]chtlich|night|nacht|"
              r"hintergrund|background|chill|calm|ruhe|ruhig|relax|entspann|lo-?fi|piano|"
              r"klavier|rain|regen|dream|traum|abend|evening|sanft|soft|quiet|leise|zen|"
              r"meditat|cozy|gem[üu]tlich|lullaby|mellow|sooth)")
LOUD_LISTS = (r"(party|club|rave|hard|peak|banger|gym|workout|hype|techno|aufleg|"
              r"warehouse|schranz|acid|drum|jungle|breakbeat|bass|festival|pump)")

# Genres, as MusicBrainz files an act (brainz.fold'ed), that say calm or loud.
CALM_GENRES = {"ambient", "dark ambient", "drone", "modern classical", "classical",
               "contemporary classical", "neoclassical", "new age", "piano", "lo fi",
               "lofi", "downtempo", "chillout", "chill out", "trip hop", "dream pop",
               "slowcore", "folk", "contemporary folk", "singer songwriter", "chamber pop",
               "bossa nova", "jazz", "cool jazz", "soundtrack", "film score", "minimalism",
               "field recording", "acoustic", "ambient pop", "sleep", "meditation"}
LOUD_GENRES = {"metal", "heavy metal", "hard rock", "punk", "punk rock", "hardcore",
               "hardcore punk", "techno", "hard techno", "drum and bass", "dubstep", "trap",
               "drill", "grime", "gabber", "hardstyle", "industrial", "thrash metal", "rave",
               "breakbeat hardcore", "big beat", "neurofunk", "jungle", "edm", "electro house",
               "gangsta rap", "hardcore hip hop", "nu metal", "metalcore", "dancehall",
               "eurodance", "happy hardcore", "speedcore", "phonk"}

# How far each moves a record's energy.
OWN_CALM_LIST, CALM_LIST, LOUD_LIST = -0.10, -0.06, 0.08
CALM_GENRE, LOUD_GENRE = -0.06, 0.10
STILL_TITLE = -0.06


# ------------------------------------------------------------------ the record
def energy(row: dict) -> float | None:
    """How much a record drives, 0 still to 1 driving: its loudness, how hard its beats
    hit, how sure the tracker was of a pulse, its tempo. None when nothing was heard."""
    lufs, punch, pulse = row.get("lufs"), row.get("punch"), row.get("pulse")
    bpm = row.get("bpm") or row.get("t_bpm")
    if lufs is None and pulse is None and punch is None:
        return None
    loud = min(1.0, max(0.0, (lufs + 20) / 14)) if lufs is not None else 0.6
    if pulse is None and punch is None:
        # Measured before the tracker said how sure it was: a tempo is a pulse.
        hit, sure = (0.5, 0.6) if bpm else (0.2, 0.2)
    else:
        sure = min(1.0, max(0.0, ((pulse or 0.0) - 0.15) / 0.6))
        # Beats were laid down, so there is a pulse, however unsure the tracker was of
        # its tempo: a band that drifts is still a drum kit (Guns N' Roses read 0.16).
        if bpm:
            sure = max(sure, 0.5)
        hit = min(1.0, max(0.0, (punch - 4.5) / 5.5)) if punch else 0.0
    fast = min(1.0, max(0.0, (bpm - 70) / 90)) if bpm else 0.2
    e = 0.30 * loud + 0.35 * hit + 0.20 * sure + 0.15 * fast
    # Sung all the way through is a little less restful than mostly not.
    if row.get("sung") is not None:
        e += 0.05 * (float(row["sung"]) - 0.3)
    return round(min(1.0, max(0.0, e)), 3)


def is_song(title: str | None, duration_ms: int | None, artists=None) -> bool:
    """A song rather than a talk, a tutorial, a set or a jingle."""
    if title and _TALK.search(title):
        return False
    if any((a or "").strip().lower() in _CHANNELS for a in artists or []):
        return False
    if duration_ms and not SHORTEST_MS <= duration_ms <= LONGEST_MS:
        return False
    return True


def _rows(user_id: int | None = None) -> dict[int, dict]:
    """Every record that plays now and has been heard, with how much it drives — moved
    by what people said of it (`_said`)."""
    out = {}
    for r in db.all_(
            """select t.id, t.title, t.artists, t.duration_ms, t.bpm as t_bpm,
                      x.bpm, x.lufs, x.pulse, x.punch, x.sung, x.camelot, x.key_confidence
                 from tracks t join track_traits x on x.track_id = t.id
                where t.state = 'ready'"""):
        if not is_song(r["title"], r["duration_ms"], r["artists"]):
            continue
        e = energy(r)
        if e is not None:
            out[r["id"]] = {**r, "energy": e, "heard": e}
    for t, v in _said(user_id, out).items():
        if t in out:
            out[t]["energy"] = round(min(1.0, max(0.0, out[t]["energy"] + v)), 3)
    return out


def _said(user_id: int | None, rows: dict[int, dict]) -> dict[int, float]:
    """What people said about how calm each record is, as a nudge to its energy: the
    lists it is on and what they are called, its act's genres, its title."""
    from . import brainz
    calm: dict[int, float] = {}
    loud: dict[int, float] = {}
    for r in db.all_(
            """with named as (
                   select i.track_id, p.owner_id = %s as own,
                          p.name ~* %s and p.name !~* %s as calm, p.name ~* %s as loud
                     from playlist_items i join playlists p on p.id = i.playlist_id
                    where p.name ~* %s or p.name ~* %s)
               select track_id, bool_or(calm and own) as own_calm, bool_or(calm) as calm,
                      bool_or(loud) as loud
                 from named group by 1""",
            (user_id or 0, CALM_LISTS, LOUD_LISTS, LOUD_LISTS, CALM_LISTS, LOUD_LISTS)):
        if r["calm"]:
            calm[r["track_id"]] = OWN_CALM_LIST if r["own_calm"] else CALM_LIST
        if r["loud"]:
            loud[r["track_id"]] = LOUD_LIST
    known = brainz.known_artists({(r["artists"] or [""])[0] for r in rows.values()
                                  if r["artists"]})
    for t, r in rows.items():
        genres = {brainz.fold(g) for g in
                  (known.get(brainz.fold((r["artists"] or [""])[0])) or {}).get("genres") or []}
        if genres & LOUD_GENRES:
            loud[t] = loud.get(t, 0.0) + LOUD_GENRE
        elif genres & CALM_GENRES:
            calm[t] = calm.get(t, 0.0) + CALM_GENRE
        if _STILL.search(r["title"] or ""):
            calm[t] = calm.get(t, 0.0) + STILL_TITLE
    return {t: calm.get(t, 0.0) + loud.get(t, 0.0) for t in set(calm) | set(loud)}


# ------------------------------------------------------------------ the person
def _sounds():
    """The house's sound rows (normalised, recommend's cache) and where each one is."""
    ids, m = recommend._sound_matrix()
    return ({t: i for i, t in enumerate(ids)}, m) if m is not None else ({}, None)


def _centroid(tas: recommend.Taste, rows: dict[int, dict], at: dict, m):
    """What somebody's calmer music sounds like: the sound of the songs they like most,
    the calmer half of them where there are enough."""
    import numpy as np
    liked = sorted(((t, v) for t, v in tas.track.items() if v > 0 and t in at),
                   key=lambda kv: -kv[1])[:300]
    if not liked:
        return None
    calm = [(t, v) for t, v in liked if t in rows and rows[t]["energy"] <= 0.5]
    use = calm if len(calm) >= 10 else liked
    v = sum(m[at[t]] * min(3.0, w) for t, w in use)
    n = float(np.linalg.norm(v))
    return v / n if n > 0 else None


def _why(t: int, tas: recommend.Taste) -> str:
    if tas.night.get(t, 0) > 0.3:
        return "you play it at night"
    if t in tas.hearted:
        return "one of your favourites"
    if t in tas.liked:
        service = tas.liked[t]
        return f"you liked it on {recommend.SERVICE_NAMES.get(service, service.title())}"
    if t in tas.listed:
        return "on one of your lists"
    if t in tas.mirrored:
        service = tas.mirrored[t]
        return f"on your {recommend.SERVICE_NAMES.get(service, service.title())} lists"
    return ""


# ------------------------------------------------------------------ the list
def build(user_id: int, tas: recommend.Taste | None = None, *, network: bool = True,
          save=None) -> list[int]:
    """Make somebody's sleep mix and keep it with their other lists. [save] is
    discover._save (passed in: discover imports this)."""
    tas = tas or recommend.taste(user_id)
    rows = _rows(user_id)
    at, m = _sounds()
    centre = _centroid(tas, rows, at, m) if m is not None else None
    fit_all = (m @ centre) if centre is not None else None
    before = {r for r in (db.one(
        "select track_ids from made_lists where user_id = %s and slug = %s",
        (user_id, SLUG)) or {}).get("track_ids") or []}
    today = random.Random(f"{user_id}:{dt.date.today()}")

    def fit(t: int) -> float:
        if fit_all is None or t not in at:
            return 0.0
        return traits.sound_alike(float(fit_all[at[t]]))

    def score(t: int, r: dict, related: float = 0.0) -> float:
        calm = max(0.0, (OPENING_MAX - r["energy"]) / OPENING_MAX)
        mine = tas.track.get(t, 0.0)
        like = math.tanh(max(0.0, mine) / 2)
        act = max((tas.artist.get(a.lower(), 0.0) for a in r["artists"] or []), default=0.0)
        night = math.tanh(max(0.0, tas.night.get(t, 0.0)) / 1.5)
        # Everything here is calm enough already: what the person loves counts most.
        s = (0.25 * calm + 0.35 * like + 0.10 * math.tanh(max(0.0, act) / 6)
             + 0.15 * night + 0.15 * max(related, fit(t)))
        if t in before:
            s -= AGAIN
        return s + today.random() * 0.02

    def skipped(t: int) -> bool:
        return tas.track.get(t, 0.0) <= -1.0 or f"t:{t}" in tas.dismissed

    # The person's own calm songs — and, to open with, a few a little less calm that
    # they like.
    yours = {t: score(t, r) for t, r in rows.items()
             if t in tas.library and not skipped(t)
             and (r["energy"] <= CALM_MAX
                  or (r["energy"] <= OPENING_MAX and tas.active.get(t, 0.0) >= 1.0))}

    # What goes with the calmest of them — the house's records that are calm too, and
    # a few that are not here yet.
    whys: dict[int, str] = {}
    house: dict[int, float] = {}
    new: list[tuple[recommend.Pick, float]] = []
    seeds = {t: s for t, s in sorted(yours.items(), key=lambda kv: -kv[1])[:8]
             if rows[t]["energy"] <= CALM_MAX}
    if seeds:
        try:
            picks = recommend.recommend(user_id, seeds, limit=40, fresh=0.6, network=network,
                                        the_taste=tas, weights=recommend.PERSON_WEIGHTS)
        except Exception as e:  # noqa: BLE001 — the list stands on the person's songs alone
            log.info("sleep picks for %s: %s", user_id, e)
            picks = []
        top = max((p.score for p in picks), default=1.0) or 1.0
        for p in picks:
            related = max(0.0, p.score / top)
            if isinstance(p.key, int) and p.key in rows:
                r = rows[p.key]
                if p.key in yours:
                    yours[p.key] = max(yours[p.key], score(p.key, r, related))
                elif r["energy"] <= CALM_MAX and not skipped(p.key):
                    house[p.key] = score(p.key, r, related)
                    if p.why:
                        whys[p.key] = p.why
            elif len(new) < NEW_MOST * 2 and _new_enough(p, seeds, rows):
                new.append((p, related))
    # The rest of the house's calm records, the ones that sound like what this person
    # likes first, whether or not the recommender found them: a person with three songs
    # still gets a mix. (The stillest have no sound row — no bars to read it from — and
    # come in on their calm alone.)
    for t, r in rows.items():
        if t not in yours and t not in house and r["energy"] <= CALM_MAX and not skipped(t):
            house[t] = score(t, r) - 0.05

    chosen = _choose(yours, house, rows)
    # A few new ones, fetched now, in the middle of the list.
    brought: list[int] = []
    if network and new and len(chosen) >= LEAST:
        from .discover import _bring_in
        for p, related in sorted(new, key=lambda pr: -pr[1])[:NEW_MOST]:
            t = _bring_in(p)
            if t and t not in chosen:
                brought.append(t)
                whys[t] = p.why or "new to you"
    out = _arrange(chosen, brought, rows, at, m, tas)
    if len(out) < LEAST:
        db.run("delete from made_lists where user_id = %s and slug = %s", (user_id, SLUG))
        return []
    for t in out:
        whys.setdefault(t, _why(t, tas) or (
            "" if t in yours else
            "from the house — it sounds like what you play" if fit(t) >= 0.5 else
            "from the house's calmest"))
    minutes = round(sum((rows.get(t) or {}).get("duration_ms") or 210_000 for t in out) / 60_000)
    if save:
        save(user_id, SLUG, NAME,
             f"The calm end of what you play, slowing down as it goes — {minutes} minutes.",
             out, ORDINAL,
             {"why": {str(t): w for t, w in whys.items() if t in out and w},
              "minutes": minutes,
              "energy": [round((rows.get(t) or {}).get("energy", 0.25), 2) for t in out]})
    return out


def _new_enough(p: recommend.Pick, seeds: dict[int, float], rows: dict[int, dict]) -> bool:
    """A song nobody here has heard is let in only where YouTube Music plays it after
    one of the calmest of somebody's own songs, and only when it is by the same act or
    says it is still — its radio drifts to anything, a calm seed's included (Marina's
    "Are You Satisfied?" after Penelope Scott, 2026-10-05) — and nothing about it says
    it is loud."""
    meta = p.row or {}
    title = meta.get("title") or ""
    if not is_song(title, meta.get("duration_ms"), meta.get("artists")) or _LOUD.search(title):
        return False
    if p.lead != "radio" or p.seed not in seeds or rows[p.seed]["energy"] > CALM_MAX * 0.7:
        return False
    theirs = {(a or "").lower() for a in rows[p.seed]["artists"] or []}
    same = any((a or "").lower() in theirs for a in meta.get("artists") or [])
    return same or bool(_STILL.search(title))


def _choose(yours: dict[int, float], house: dict[int, float],
            rows: dict[int, dict]) -> list[int]:
    """The songs, about an hour of them: the person's own first, best first, until
    they fill all but the house's share of the hour; the house's then, best first; and
    whatever is left of either while it is short. Never more than two by one act, and
    only a few of the less calm openers."""
    out: list[int] = []
    per_artist: dict[str, int] = {}
    ms = 0
    openers = 0

    def take(t: int) -> bool:
        nonlocal ms, openers
        if t in out:
            return False
        first = ((rows[t]["artists"] or [""])[0] or "").lower()
        if per_artist.get(first, 0) >= 2:
            return False
        opener = rows[t]["energy"] > CALM_MAX
        if opener and openers >= round(MOST * OPENING_SHARE):
            return False
        openers += opener
        per_artist[first] = per_artist.get(first, 0) + 1
        out.append(t)
        ms += rows[t]["duration_ms"] or 210_000
        return True

    theirs = sorted(yours, key=lambda t: -yours[t])
    others = sorted(house, key=lambda t: -house[t])
    hour = MINUTES * 60_000
    for t in theirs:
        if ms >= hour * (1 - HOUSE_SHARE) or len(out) >= MOST * (1 - HOUSE_SHARE):
            break
        take(t)
    for pool in (others, theirs):
        for t in pool:
            if ms >= hour or len(out) >= MOST:
                break
            take(t)
    return out


def _arrange(chosen: list[int], brought: list[int], rows: dict[int, dict], at: dict, m,
             tas: recommend.Taste) -> list[int]:
    """Laid out to wind down: the most driving of them first and the stillest last, in
    three stretches, each one walked from song to the song that sounds most like it —
    so the mix drifts rather than jumps. A song still being fetched goes in the middle,
    never first."""
    if not chosen:
        return list(brought)
    by_energy = sorted(chosen, key=lambda t: -rows[t]["energy"])
    n = len(by_energy)
    cuts = [0, max(1, round(n * 0.3)), max(2, round(n * 0.7)), n]
    stretches = [by_energy[cuts[i]:cuts[i + 1]] for i in range(3)]
    stretches[1] = stretches[1] + brought

    def like(a: int, b: int) -> float:
        if m is None or a not in at or b not in at:
            return 0.0
        s = float(m[at[a]] @ m[at[b]])
        ra, rb = rows.get(a) or {}, rows.get(b) or {}
        k = traits.key_term(ra.get("camelot"), rb.get("camelot"),
                            ra.get("key_confidence") or 0, rb.get("key_confidence") or 0)
        return traits.sound_alike(s) + 0.3 * k

    out: list[int] = []
    for i, part in enumerate(stretches):
        left = [t for t in part if t not in out]
        if not left:
            continue
        if not out:
            # Open on one they know and like, playing now.
            ready = [t for t in left if t in rows]
            first = max(ready or left, key=lambda t: (tas.track.get(t, 0.0), -left.index(t)))
        else:
            prev = out[-1]
            first = max(left, key=lambda t: like(prev, t))
        out.append(first)
        left.remove(first)
        if i == 2:
            # The last stretch goes by calm alone, the stillest last.
            left.sort(key=lambda t: -rows[t]["energy"] if t in rows else 0)
            out.extend(left)
            continue
        while left:
            prev = out[-1]
            nxt = max(left, key=lambda t: like(prev, t))
            out.append(nxt)
            left.remove(nxt)
    return out
