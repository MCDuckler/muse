"""What the booth's planner reads of a record when it looks for a partner across the
whole library — and the looking.

The planner in the app (set_planner.dart) judges a pair by tempo, key, loudness, how
they sound and who made them; it can only judge what it has been sent, and it has the
queue. For "what in the whole library would follow this best" the same judging is
done here, coarsely, over one row a record (track_traits, kept whenever a record's
analysis is served), and the handful that come out on top are sent back for the app
to judge finely — with the words, the voices and the moves it has and this does not.
"""
from __future__ import annotations

import json
import math
import re

from . import catalog, db

# How far the automix pulls a record's tempo (Booth.bridgeReach in the app).
REACH = 0.16


def _rel_db(level: int) -> float:
    """A bar's loudness as analysis.energy_levels wrote it (0 to 255, the loudest bar
    255) back to dB against the loudest bar."""
    lv = max(1, level) / 255.0
    return 20 * math.log10(lv ** (1 / 0.7))


def _edge_db(found: dict, at_ms: int | None, before: bool) -> float | None:
    """How loud the record is over the eight bars into (or out of) [at_ms], in dB
    against its loudest bar, from the energy the analysis read bar by bar."""
    energy = found.get("energy") or []
    downs = found.get("downbeats") or []
    if at_ms is None or len(energy) < 4 or len(downs) < 4:
        return None
    bar = 0
    for i, d in enumerate(downs):
        if d <= at_ms:
            bar = i
    lo, hi = (max(0, bar - 8), bar) if before else (bar, min(len(energy), bar + 8))
    if hi <= lo:
        lo, hi = max(0, bar - 4), min(len(energy), bar + 4)
    heard = [_rel_db(v) for v in energy[lo:hi] if v > 0]
    return sum(heard) / len(heard) if heard else None


def of(track: dict, found: dict) -> dict:
    """The traits row for a record from its analysis (beats.py + analysis.py, and the
    structure where there is one)."""
    structure = found.get("structure") or {}
    sections = structure.get("sections") or []
    sung = None
    if sections:
        bars = sum(int(s.get("end_bar", 0)) - int(s.get("start_bar", 0)) for s in sections)
        voiced = sum(int(s.get("end_bar", 0)) - int(s.get("start_bar", 0))
                     for s in sections if s.get("vocals"))
        sung = voiced / bars if bars > 0 else None
    cues = found.get("cues") or {}
    return {
        "track_id": track["id"],
        "bpm": found.get("bpm"),
        "camelot": found.get("camelot"),
        "key_confidence": float(found.get("key_confidence") or 0),
        "lufs": track.get("loudness_lufs") if track.get("loudness_lufs") is not None
                else structure.get("lufs"),
        "sound": found.get("sound"),
        "sung": sung,
        "in_db": _edge_db(found, cues.get("mix_in_ms"), before=False),
        "out_db": _edge_db(found, cues.get("mix_out_ms"), before=True),
    }


def remember(track: dict, found: dict) -> None:
    """Keep the record's traits, written over whatever was there."""
    row = of(track, found)
    db.run(
        """insert into track_traits(track_id, bpm, camelot, key_confidence, lufs, sound,
                                    sung, in_db, out_db, updated_at)
           values(%(track_id)s, %(bpm)s, %(camelot)s, %(key_confidence)s, %(lufs)s,
                  %(sound)s, %(sung)s, %(in_db)s, %(out_db)s, now())
           on conflict (track_id) do update set
             bpm=excluded.bpm, camelot=excluded.camelot,
             key_confidence=excluded.key_confidence, lufs=excluded.lufs,
             sound=excluded.sound, sung=excluded.sung, in_db=excluded.in_db,
             out_db=excluded.out_db, updated_at=now()""",
        {**row, "sound": json.dumps(row["sound"]) if row["sound"] is not None else None})


# ------------------------------------------------------------------ the judging
def sync_ratio(from_bpm: float, to_bpm: float, reach: float = REACH) -> float | None:
    """The pull that puts [to_bpm] in step with [from_bpm], half or double time being
    the same tempo; None beyond [reach]. Booth.syncRatio in the app."""
    if from_bpm <= 0 or to_bpm <= 0:
        return None
    target = to_bpm
    while target / from_bpm > math.sqrt(2):
        target /= 2
    while target / from_bpm < 1 / math.sqrt(2):
        target *= 2
    ratio = target / from_bpm
    return None if abs(ratio - 1) > reach else ratio


def tempo_term(a: float | None, b: float | None) -> float:
    if a is None or b is None:
        return 0.25
    ratio = sync_ratio(a, b)
    if ratio is None:
        return 0.0
    t = 0.5 * max(0.0, 1 - abs(ratio - 1) / REACH) + 0.1
    raw = b / a
    if raw > math.sqrt(2) or raw < 1 / math.sqrt(2):
        t *= 0.5
    return t


_WHEEL = {(0, True): 1.0, (0, False): 0.9, (1, True): 0.85, (11, True): 0.85,
          (2, True): 0.6, (7, True): 0.55, (10, True): 0.4, (5, True): 0.35}


def key_term(ca: str | None, cb: str | None, conf_a: float, conf_b: float) -> float:
    """SetPlanner.keyMove's score, 0 to 1, 0.5 for nothing to say."""
    if not ca or not cb or len(ca) < 2 or len(cb) < 2:
        return 0.5
    try:
        na, nb = int(ca[:-1]), int(cb[:-1])
    except ValueError:
        return 0.5
    same = ca[-1] == cb[-1]
    d = (nb - na) % 12
    score = _WHEEL.get((d, same), 0.15)
    w = min(1.0, max(0.0, (min(conf_a, conf_b) - 0.1) / 0.4))
    return 0.5 + (score - 0.5) * w


def energy01(lufs: float | None) -> float | None:
    return None if lufs is None else min(1.0, max(0.0, (lufs + 20) / 14))


def cosine(a, b) -> float | None:
    if not a or not b or len(a) != len(b):
        return None
    dot = sum(x * y for x, y in zip(a, b))
    na = math.sqrt(sum(x * x for x in a))
    nb = math.sqrt(sum(y * y for y in b))
    return dot / (na * nb) if na > 0 and nb > 0 else None


def _title_key(title: str) -> str:
    t = re.sub(r"[\(\[].*?[\)\]]", "", (title or "").lower())
    return re.sub(r"[^a-z0-9]+", " ", t).strip()


def judge(a: dict, b: dict, wanted_step: float = 0.0) -> tuple[float, list[str]]:
    """How well record [b] (its traits and its tracks row) follows [a]: the score
    and a few words — the same terms the app's planner adds up, without the voices
    and the moves it has and this does not."""
    words: list[str] = []
    score = tempo_term(a.get("bpm"), b.get("bpm"))
    if a.get("bpm") and b.get("bpm") and sync_ratio(a["bpm"], b["bpm"]) is None:
        words.append("too far apart in tempo")
    k = key_term(a.get("camelot"), b.get("camelot"),
                 a.get("key_confidence") or 0, b.get("key_confidence") or 0)
    score += 0.3 * k
    if k >= 0.8:
        words.append(f"{a.get('camelot')}→{b.get('camelot')}")
    elif k <= 0.3:
        words.append("keys clash")
    ea, eb = energy01(a.get("lufs")), energy01(b.get("lufs"))
    if ea is not None and eb is not None:
        step = eb - ea
        score += 0.2 * max(0.0, 1 - abs(step - wanted_step) / 0.3)
    sim = cosine(a.get("sound"), b.get("sound"))
    if sim is not None:
        score += 0.2 * max(0.0, sim)
        if sim > 0.7:
            words.append("sounds alike")
    if a.get("out_db") is not None and b.get("in_db") is not None \
            and a.get("lufs") is not None and b.get("lufs") is not None:
        d = abs((a["lufs"] + a["out_db"]) - (b["lufs"] + b["in_db"]))
        score += 0.15 * max(0.0, 1 - d / 12)
    if (a.get("sung") or 0) > 0.5 and (b.get("sung") or 0) > 0.5:
        score -= 0.05
    names = {s.lower() for s in (a.get("artists") or [])}
    if any(s.lower() in names for s in (b.get("artists") or [])):
        score -= 0.3
        words.append("the same artist")
    if _title_key(a.get("title", "")) == _title_key(b.get("title", "")):
        score -= 0.5
        words.append("the same song")
    return score, words


def _rows(user_id: int, ids: list[int] | None = None) -> list[dict]:
    where = "and t.id = any(%s)" if ids is not None else ""
    return db.all_(
        f"""select t.*, m.path, m.bytes, m.sha256, c.color as cover_color, c.sha256 as cover_sha,
                   x.bpm as t_bpm, x.camelot, x.key_confidence, x.lufs, x.sound, x.sung,
                   x.in_db, x.out_db
              from track_traits x
              join tracks t on t.id = x.track_id
              join library_items li on li.track_id = t.id and li.user_id = %s
              left join media m on m.track_id = t.id and m.role = 'canonical'
              left join covers c on c.id = t.cover_id
             where t.state = 'ready' {where}""",
        (user_id, ids) if ids is not None else (user_id,))


def _traits(row: dict) -> dict:
    sound = row.get("sound")
    if isinstance(sound, str):
        sound = json.loads(sound)
    return {**row, "bpm": row.get("t_bpm") if row.get("t_bpm") is not None else row.get("bpm"),
            "sound": sound}


def partners(user_id: int, from_id: int, exclude: set[int], limit: int = 12,
             wanted_step: float = 0.0, avoid_artists: set[str] = frozenset()) -> list[dict]:
    """The records in this person's library that would follow [from_id] best, by
    what is known of each — best first, never one in [exclude], with the same artist
    as any in [avoid_artists] (the records lately played) marked down."""
    got = _rows(user_id, [from_id])
    if not got:
        return []
    a = _traits(got[0])
    avoid = {s.lower() for s in avoid_artists}
    out = []
    for row in _rows(user_id):
        if row["id"] == from_id or row["id"] in exclude:
            continue
        b = _traits(row)
        score, words = judge(a, b, wanted_step)
        if avoid and any(s.lower() in avoid for s in (b.get("artists") or [])) \
                and "the same artist" not in words:
            score -= 0.2
            words.append("an artist heard lately")
        out.append((score, words, row))
    out.sort(key=lambda x: -x[0])
    return [{"track": catalog.public(row), "fit": round(score, 3), "why": " · ".join(words)}
            for score, words, row in out[:max(1, min(limit, 50))]]
