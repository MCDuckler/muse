"""Sets, built by the house from a pool of records.

The app's set planner (set_planner.dart) orders what it is given and judges each pair
finely, with the voices and the moves. The question here comes before that one: of
everything in a pool — the queue, a few playlists, the whole library — which records
make a set of this length and this shape (its energy over time, its tempo from and
to, how strict about keys, how varied, how familiar), and in what order.

Coarse, like traits.partners: one row a record (track_traits), every candidate judged
at once with numpy, a beam over the slots. The terms and their weights are the app's
SetPlanner.fit, so the two agree about what a good pair is; the app then judges the
chosen few again with everything it has that this does not.
"""
from __future__ import annotations

import json
import math
import threading
import time
from dataclasses import dataclass, field

import numpy as np

from . import catalog, db, traits
from .pool import PARTS_VERSION

# How far the automix pulls a record's tempo (Booth.bridgeReach), and the stretch
# that is still ordinary (SetPlanner.tempo: 86 % of real transitions stretch less).
REACH = traits.REACH
COMFORTABLE = 0.05

# A record in a set plays for about its length less the overlap either side.
OVERLAP_S = 30.0

KEYS = ("strict", "loose", "any")


# ------------------------------------------------------------------ the shape
@dataclass
class Shape:
    """How the set should go.

    [energy] is the curve its loudness follows over its time: (k, e) points, k from 0
    (the start) to 1 (the end), e from 0 (soft, -20 LUFS) to 1 (a wall, -6). [tempo]
    is where its tempo starts and ends, or None for no wish. [key]: strict (no clash
    at all), loose (a clash costs), any. [gap]: no artist again within that many
    records. [smooth]: 0 each record unlike the last, 0.5 as the planner judges, 1 each
    like the last. [fresh]: 0 the records played most, 1 the ones hardly played.
    [stems]: records already in parts first (the moves that need them).
    """

    energy: list[tuple[float, float]] = field(default_factory=lambda: [(0.0, 0.5), (1.0, 0.5)])
    tempo: tuple[float, float] | None = None
    key: str = "loose"
    gap: int = 3
    smooth: float = 0.5
    fresh: float = 0.5
    stems: bool = False
    offset: float = 0.0
    # The curve read against this pool's own spread of loudness (0 its softest record,
    # 1 its loudest) rather than against -20..-6 LUFS: a pool of techno is loud from
    # end to end, and "a warm-up" in it is its softer records, not silence.
    relative: bool = True
    # "More like this": a record whose sound the next records lean towards (a pool
    # index, set by whoever resolved the track id).
    anchor: int | None = None

    @classmethod
    def of(cls, d: dict | None) -> "Shape":
        d = d or {}
        s = cls()
        pts = []
        for p in d.get("energy") or []:
            try:
                k, e = float(p[0]), float(p[1])
            except (TypeError, ValueError, IndexError):
                continue
            pts.append((min(1.0, max(0.0, k)), min(1.0, max(0.0, e))))
        if pts:
            pts.sort()
            s.energy = pts
        t = d.get("tempo")
        if isinstance(t, dict) and t.get("from") and t.get("to"):
            try:
                a, b = float(t["from"]), float(t["to"])
                if 40 <= a <= 250 and 40 <= b <= 250:
                    s.tempo = (a, b)
            except (TypeError, ValueError):
                pass
        if d.get("key") in KEYS:
            s.key = d["key"]
        variety = d.get("variety") or {}
        try:
            s.gap = int(min(12, max(0, int(variety.get("gap", d.get("gap", s.gap))))))
        except (TypeError, ValueError):
            pass
        for name in ("smooth", "fresh"):
            v = variety.get(name, d.get(name))
            if v is not None:
                try:
                    setattr(s, name, min(1.0, max(0.0, float(v))))
                except (TypeError, ValueError):
                    pass
        s.stems = bool(d.get("stems", False))
        s.relative = bool(d.get("relative", True))
        try:
            s.offset = min(0.5, max(-0.5, float(d.get("offset", 0.0))))
        except (TypeError, ValueError):
            pass
        return s

    def energy_at(self, k: float) -> float:
        """Where the curve wants the set's loudness [k] of the way through it."""
        xs = [p[0] for p in self.energy]
        ys = [p[1] for p in self.energy]
        e = float(np.interp(min(1.0, max(0.0, k)), xs, ys))
        return min(1.0, max(0.0, e + self.offset))

    def tempo_at(self, k: float) -> float | None:
        if self.tempo is None:
            return None
        a, b = self.tempo
        # Evenly in ratio: a tenth up feels the same at 120 as at 140.
        return a * (b / a) ** min(1.0, max(0.0, k))


# ------------------------------------------------------------------ the pool
@dataclass
class Pool:
    """Every record a set may be made of, as arrays: one entry a record."""

    rows: list[dict]
    ids: np.ndarray
    at: dict[int, int]
    bpm: np.ndarray
    cam: np.ndarray
    major: np.ndarray
    conf: np.ndarray
    energy: np.ndarray
    lufs: np.ndarray
    out_edge: np.ndarray
    in_edge: np.ndarray
    sung: np.ndarray
    played_s: np.ndarray
    familiar: np.ndarray
    recent: np.ndarray
    hearted: np.ndarray
    parts: np.ndarray
    sound: np.ndarray
    has_sound: np.ndarray
    artists: list[frozenset[str]]
    by_artist: dict[str, np.ndarray]
    same: np.ndarray
    energy_q: np.ndarray = field(default_factory=lambda: np.linspace(0, 1, 101))

    @property
    def n(self) -> int:
        return len(self.rows)


def _f(v) -> float:
    try:
        return float(v) if v is not None else math.nan
    except (TypeError, ValueError):
        return math.nan


def _camelot(c: str | None) -> tuple[int, bool]:
    if not c or len(c) < 2:
        return 0, False
    try:
        n = int(c[:-1])
    except ValueError:
        return 0, False
    return (n if 1 <= n <= 12 else 0), c[-1].upper() == "B"


def _rows(user_id: int, library: bool, ids: set[int]) -> list[dict]:
    return db.all_(
        """select t.*, m.path, m.bytes, m.sha256, c.color as cover_color, c.sha256 as cover_sha,
                  x.bpm as t_bpm, x.camelot, x.key_confidence, x.lufs, x.sound, x.sung,
                  x.in_db, x.out_db,
                  exists(select 1 from track_parts tp
                          where tp.sha256 = m.sha256 and tp.name = 'stems'
                            and tp.version = %s) as in_parts
             from track_traits x
             join tracks t on t.id = x.track_id
             left join media m on m.track_id = t.id and m.role = 'canonical'
             left join covers c on c.id = t.cover_id
            where t.state = 'ready'
              and ((%s and exists(select 1 from library_items li
                                   where li.user_id = %s and li.track_id = t.id))
                   or t.id = any(%s))""",
        (PARTS_VERSION, library, user_id, list(ids)))


def _listened(user_id: int) -> dict[int, tuple[int, float]]:
    """Each record's listens by this person, and how many hours since the last."""
    return {r["track_id"]: (int(r["n"]), float(r["hours"])) for r in db.all_(
        """select track_id, count(*) n,
                  extract(epoch from now() - max(started_at)) / 3600 as hours
             from listens where user_id = %s group by track_id""", (user_id,))}


def _hearted(user_id: int) -> set[int]:
    return {r["track_id"] for r in db.all_(
        """select i.track_id from playlist_items i join playlists p on p.id = i.playlist_id
            where p.owner_id = %s and p.kind = 'favourites'""", (user_id,))}


def load(user_id: int, library: bool, ids: set[int]) -> Pool:
    """The pool: the records of this person's library (with [library]) and those
    named in [ids] that are ready and have been measured."""
    return assemble(_rows(user_id, library, ids), _listened(user_id), _hearted(user_id))


def assemble(rows: list[dict], heard: dict[int, tuple[int, float]], hearts: set[int]) -> Pool:
    """The pool from its rows (tracks joined with track_traits), each record's listens
    (count, hours since the last) and the hearted ones."""
    n = len(rows)
    bpm = np.full(n, np.nan)
    cam = np.zeros(n, dtype=np.int16)
    major = np.zeros(n, dtype=bool)
    conf = np.zeros(n)
    lufs = np.full(n, np.nan)
    out_edge = np.full(n, np.nan)
    in_edge = np.full(n, np.nan)
    sung = np.full(n, np.nan)
    played = np.zeros(n)
    listens = np.zeros(n)
    recent = np.zeros(n, dtype=bool)
    hearted = np.zeros(n, dtype=bool)
    parts = np.zeros(n, dtype=bool)
    sounds: list[list[float] | None] = []
    artists: list[frozenset[str]] = []
    for i, r in enumerate(rows):
        b = _f(r.get("t_bpm") if r.get("t_bpm") is not None else r.get("bpm"))
        bpm[i] = b if b > 0 else np.nan
        cam[i], major[i] = _camelot(r.get("camelot"))
        conf[i] = _f(r.get("key_confidence")) if r.get("key_confidence") is not None else 0.0
        lufs[i] = _f(r.get("lufs"))
        lf = lufs[i]
        out_edge[i] = lf + _f(r.get("out_db"))
        in_edge[i] = lf + _f(r.get("in_db"))
        sung[i] = _f(r.get("sung"))
        dur = (r.get("duration_ms") or 0) / 1000
        played[i] = max(60.0, dur - OVERLAP_S) if dur > 0 else 180.0
        cnt, hours = heard.get(r["id"], (0, math.inf))
        listens[i] = cnt
        recent[i] = hours < 36
        hearted[i] = r["id"] in hearts
        parts[i] = bool(r.get("in_parts"))
        s = r.get("sound")
        if isinstance(s, str):
            try:
                s = json.loads(s)
            except ValueError:
                s = None
        sounds.append(s if isinstance(s, list) and s else None)
        artists.append(frozenset(a.lower() for a in (r.get("artists") or []) if a))
    dim = max((len(s) for s in sounds if s), default=0)
    sound = np.zeros((n, max(1, dim)), dtype=np.float32)
    has_sound = np.zeros(n, dtype=bool)
    for i, s in enumerate(sounds):
        if s and len(s) == dim:
            v = np.asarray(s, dtype=np.float32)
            norm = float(np.linalg.norm(v))
            if norm > 0:
                sound[i] = v / norm
                has_sound[i] = True
    energy = np.clip((lufs + 20) / 14, 0, 1)
    top = max(1.0, float(listens.max()) if n else 1.0)
    familiar = np.log1p(listens) / math.log1p(top)
    by_artist: dict[str, list[int]] = {}
    for i, a in enumerate(artists):
        for name in a:
            by_artist.setdefault(name, []).append(i)
    p = Pool(rows=rows, ids=np.array([r["id"] for r in rows], dtype=np.int64),
             at={r["id"]: i for i, r in enumerate(rows)}, bpm=bpm, cam=cam, major=major,
             conf=conf, energy=energy, lufs=lufs, out_edge=out_edge, in_edge=in_edge,
             sung=sung, played_s=played, familiar=familiar, recent=recent, hearted=hearted,
             parts=parts, sound=sound, has_sound=has_sound, artists=artists,
             by_artist={k: np.array(v, dtype=np.int64) for k, v in by_artist.items()},
             same=np.arange(n))
    p.same = _twins(p)
    known = energy[np.isfinite(energy)]
    if len(known) >= 5:
        p.energy_q = np.percentile(known, np.arange(101))
    return p


def _twins(p: Pool) -> np.ndarray:
    """A group for each record, shared by the ones that are the same song: the same
    title (another edit, a re-upload), or two rows that sound all but identical at
    the same tempo — the library holds a few thousand pairs of those. A set plays one
    of a group at most."""
    group = np.arange(p.n)

    def find(i: int) -> int:
        while group[i] != i:
            group[i] = group[group[i]]
            i = group[i]
        return i

    def join(i: int, j: int) -> None:
        a, b = find(i), find(j)
        if a != b:
            group[max(a, b)] = min(a, b)

    by_title: dict[str, int] = {}
    for i, r in enumerate(p.rows):
        k = traits._title_key(r.get("title") or "")
        if not k:
            continue
        if k in by_title:
            join(by_title[k], i)
        else:
            by_title[k] = i
    # Sound twins, looked for only among records a hair apart in tempo — and against
    # the first of each group, not every member: "alike" is not transitive, and chained
    # it made one song of a whole crate of records that each sound like the next.
    known = np.where(p.has_sound & np.isfinite(p.bpm))[0]
    if len(known) > 1:
        order = known[np.argsort(p.bpm[known])]
        firsts: list[int] = []
        for i in order:
            i = int(i)
            while firsts and p.bpm[i] - p.bpm[firsts[0]] > 0.5:
                firsts.pop(0)
            if firsts:
                sims = p.sound[firsts] @ p.sound[i]
                best = int(np.argmax(sims))
                if sims[best] >= 0.985:
                    join(firsts[best], i)
                    continue
            firsts.append(i)
    return np.array([find(i) for i in range(p.n)])


_cache: dict[tuple, tuple[float, Pool]] = {}
_cache_lock = threading.Lock()
CACHE_S = 300


def pool_for(user_id: int, library: bool, ids: set[int]) -> Pool:
    """The pool, kept for a few minutes: a set built, then built again with one dial
    turned, reads the library once."""
    key = (user_id, library, hash(frozenset(ids)), len(ids))
    now = time.monotonic()
    with _cache_lock:
        hit = _cache.get(key)
        if hit and now - hit[0] < CACHE_S:
            return hit[1]
    p = load(user_id, library, ids)
    with _cache_lock:
        _cache[key] = (now, p)
        if len(_cache) > 8:
            for k in sorted(_cache, key=lambda k: _cache[k][0])[:len(_cache) - 8]:
                _cache.pop(k, None)
    return p


def forget() -> None:
    with _cache_lock:
        _cache.clear()


# ------------------------------------------------------------------ judging a pair
def _fold(b: np.ndarray, a: np.ndarray) -> np.ndarray:
    """[b] moved by octaves to within a half-octave of [a]: half and double time are
    the same tempo said twice."""
    with np.errstate(divide="ignore", invalid="ignore"):
        k = np.round(np.log2(b / a))
    k = np.where(np.isfinite(k), k, 0)
    return b / np.power(2.0, k)


def score(p: Pool, a: np.ndarray, b: np.ndarray, shape: Shape, pitch: float = 1.0,
          wanted: np.ndarray | float | None = None) -> np.ndarray:
    """How well each record b[i] follows a[i] — SetPlanner.fit's terms, pair by pair,
    all at once. [pitch] is the pitch the records in [a] play at; [wanted] the step in
    loudness the curve asks for from each a[i] (0 to 1 scale)."""
    fa = p.bpm[a] * pitch
    fb = p.bpm[b]
    known = np.isfinite(fa) & np.isfinite(fb)
    folded = _fold(fb, np.where(known, fa, 1.0))
    with np.errstate(divide="ignore", invalid="ignore"):
        ratio = folded / fa
        raw = fb / fa
    off = np.abs(ratio - 1)
    tempo = 0.5 * np.exp(-(off / COMFORTABLE) ** 2) + 0.1
    tempo = np.where(off > REACH, 0.0, tempo)
    octave = (raw > math.sqrt(2)) | (raw < 1 / math.sqrt(2))
    tempo = np.where(octave, tempo * 0.5, tempo)
    total = np.where(known, tempo, 0.25)

    # The wheel as DJs read it, weighed towards "nothing to say" as either key is less
    # sure (SetPlanner.keyMove).
    ca, cb = p.cam[a].astype(np.int32), p.cam[b].astype(np.int32)
    same = p.major[a] == p.major[b]
    d = (cb - ca) % 12
    wheel = np.full(len(b), 0.15)
    wheel[(d == 0) & same] = 1.0
    wheel[(d == 0) & ~same] = 0.9
    wheel[((d == 1) | (d == 11)) & same] = 0.85
    wheel[(d == 2) & same] = 0.6
    wheel[(d == 7) & same] = 0.55
    wheel[(d == 10) & same] = 0.4
    wheel[(d == 5) & same] = 0.35
    w = np.clip((np.minimum(p.conf[a], p.conf[b]) - 0.1) / 0.4, 0, 1)
    both = (ca > 0) & (cb > 0)
    key = np.where(both, 0.5 + (wheel - 0.5) * w, 0.5)
    clash = both & (wheel <= 0.15) & (w >= 0.5)
    if shape.key == "any":
        total = total + 0.15
    else:
        total = total + 0.3 * key
        if shape.key == "strict":
            total = total - 2.0 * clash

    ea, eb = p.energy[a], p.energy[b]
    step = eb - ea
    want = 0.0 if wanted is None else wanted
    en = 0.2 * np.clip(1 - np.abs(step - want) / 0.3, 0, 1)
    total = total + np.where(np.isfinite(step), en, 0.0)

    # How alike they sound: 0.75 to 0.95 is the scale that tells records apart. The
    # dial leans it towards records alike (1) or unlike (0).
    sims = np.einsum("ij,ij->i", p.sound[a], p.sound[b])
    alike = np.clip((sims - 0.75) / 0.2, 0, 1)
    w_like = 0.4 * shape.smooth
    w_diff = max(0.0, 0.4 * (1 - shape.smooth) - 0.2)
    snd = w_like * alike + w_diff * (1 - alike)
    total = total + np.where(p.has_sound[a] & p.has_sound[b], snd, 0.0)

    # The seam: how loud [a] goes out against how loud [b] comes in.
    seam_d = np.abs(p.out_edge[a] - p.in_edge[b])
    total = total + np.where(np.isfinite(seam_d), 0.15 * np.clip(1 - seam_d / 12, 0, 1), 0.0)

    total = total - 0.05 * ((np.nan_to_num(p.sung[a]) > 0.5) & (np.nan_to_num(p.sung[b]) > 0.5))
    return total


def _pair_from(p: Pool, a: int, shape: Shape, pitch: float = 1.0, wanted: float | None = None):
    idx = np.arange(p.n)
    s = score(p, np.full(p.n, a), idx, shape, pitch=pitch, wanted=wanted)
    # The same artist again straight away.
    names = p.artists[a]
    for name in names:
        hit = p.by_artist.get(name)
        if hit is not None:
            s[hit] -= 0.3
    return s


def _into(p: Pool, cands: np.ndarray, b: int, shape: Shape) -> np.ndarray:
    s = score(p, cands, np.full(len(cands), b), shape)
    names = p.artists[b]
    for i, c in enumerate(cands):
        if names & p.artists[int(c)]:
            s[i] -= 0.3
    return s


def _solo(p: Pool, shape: Shape) -> np.ndarray:
    """What a record brings whatever it follows: how familiar or fresh it is against
    what was asked, its heart, whether it was played a moment ago, its parts."""
    f = shape.fresh
    s = 0.15 * (f * (1 - p.familiar) + (1 - f) * p.familiar)
    s = s + 0.08 * (1 - f) * p.hearted
    s = s - 0.5 * p.recent
    s = s + (0.08 if shape.stems else 0.03) * p.parts
    return s


def target(p: Pool, shape: Shape, k: float) -> float:
    """The loudness (0 to 1, -20..-6 LUFS) the shape wants [k] of the way in: its curve,
    read against the pool's own spread where it is relative."""
    e = shape.energy_at(k)
    if not shape.relative:
        return e
    return float(np.interp(e * 100, np.arange(101), p.energy_q))


def curve(p: Pool, shape: Shape, points: int = 21) -> list[float]:
    """The target over the whole set, for drawing."""
    return [round(target(p, shape, i / (points - 1)), 3) for i in range(points)]


def _aim(p: Pool, shape: Shape, k: float) -> np.ndarray:
    """How far each record is from where the shape wants the set [k] of the way in:
    its loudness against the curve, its tempo against the tempo path."""
    want = target(p, shape, k)
    s = np.where(np.isfinite(p.energy), -0.4 * np.abs(p.energy - want), -0.1)
    if shape.anchor is not None and p.has_sound[shape.anchor]:
        sims = p.sound @ p.sound[shape.anchor]
        s = s + np.where(p.has_sound, 0.3 * np.clip((sims - 0.75) / 0.2, 0, 1), 0.0)
    t = shape.tempo_at(k)
    if t is not None:
        folded = _fold(p.bpm, np.full(p.n, t))
        miss = np.abs(folded / t - 1)
        # Asked for, a tempo path is meant: four percent off it costs as much as a
        # clash of keys.
        s = s + np.where(np.isfinite(miss), -0.6 * np.clip(miss / 0.04, 0, 1), -0.3)
    return s


# ------------------------------------------------------------------ words
def words(p: Pool, a: int, b: int, pitch: float = 1.0) -> str:
    out: list[str] = []
    fa, fb = p.bpm[a] * pitch, p.bpm[b]
    if np.isfinite(fa) and np.isfinite(fb):
        folded = float(_fold(np.array([fb]), np.array([fa]))[0])
        ratio = folded / fa
        raw = fb / fa
        if abs(ratio - 1) > REACH:
            out.append("too far apart in tempo")
        elif raw > math.sqrt(2) or raw < 1 / math.sqrt(2):
            out.append("double time" if raw > 1 else "half time")
        else:
            pct = abs(1 / ratio - 1) * 100
            out.append("the same tempo" if pct < 0.5
                       else f"{pct:.0f} % {'faster' if 1 / ratio > 1 else 'slower'}")
    ca, cb = int(p.cam[a]), int(p.cam[b])
    if ca and cb and min(p.conf[a], p.conf[b]) > 0.1:
        same = p.major[a] == p.major[b]
        d = (cb - ca) % 12
        name = {(0, True): "the same key", (0, False): "relative major and minor",
                (1, True): "a fifth apart", (11, True): "a fifth apart",
                (2, True): "a tone up: a boost", (7, True): "a semitone up: a boost",
                (10, True): "a tone down", (5, True): "a semitone down"}.get((d, bool(same)),
                                                                              "keys clash")
        la = "B" if p.major[a] else "A"
        lb = "B" if p.major[b] else "A"
        out.append(f"{name} ({ca}{la}→{cb}{lb})")
    if np.isfinite(p.lufs[a]) and np.isfinite(p.lufs[b]):
        db_ = p.lufs[b] - p.lufs[a]
        out.append("as loud" if abs(db_) < 1.5
                   else f"{abs(db_):.0f} dB {'louder' if db_ > 0 else 'softer'}")
    if p.has_sound[a] and p.has_sound[b]:
        sim = float(p.sound[a] @ p.sound[b])
        if sim > 0.93:
            out.append("sounds alike")
        elif sim < 0.6:
            out.append("a different sound")
    if p.artists[a] & p.artists[b]:
        out.append("the same artist again")
    return " · ".join(out)


# ------------------------------------------------------------------ building
@dataclass
class Path:
    score: float
    picks: list[int]
    elapsed: float
    groups: frozenset[int]


def _length(p: Pool, tracks: int | None, minutes: float | None) -> tuple[int, float]:
    """How many slots, and the set's time in seconds (for where along the curve each
    slot sits)."""
    typical = float(np.median(p.played_s)) if p.n else 200.0
    if minutes:
        total = float(minutes) * 60
        n = int(math.ceil(total / max(60.0, typical))) + 2
    else:
        n = int(tracks or 12)
        total = n * typical
    return max(1, min(80, n)), max(60.0, total)


def build(p: Pool, shape: Shape, *, start: int | None = None, before: list[int] = (),
          tracks: int | None = None, minutes: float | None = None,
          pins: dict[int, int] | None = None, must: list[int] = (),
          exclude: set[int] = frozenset(), width: int = 8, topk: int = 32,
          pitch: float = 1.0) -> list[dict]:
    """The set: slot by slot, the record, how well it follows the one before and why,
    where along the set it plays. Indices are the pool's; [start] is the record the
    set follows (the one on now), [before] what was played before it (not again).
    [pins] fixes a record to a slot; [must] are records the set must have, put where
    they fit the shape best."""
    if p.n == 0:
        return []
    n, total = _length(p, tracks, minutes)
    pins = dict(pins or {})
    # Musts become pins, each at the free slot whose place on the curve fits it best,
    # loudest last among equals — so they spread out rather than bunch.
    typical = total / n
    for m in sorted(set(must) - set(pins.values()), key=lambda i: np.nan_to_num(p.energy[i], nan=0.5)):
        best, cost = None, math.inf
        for s in range(n):
            if s in pins:
                continue
            k = (s + 0.5) * typical / total
            e = p.energy[m]
            c = abs((e if np.isfinite(e) else 0.5) - target(p, shape, k))
            t = shape.tempo_at(k)
            if t is not None and np.isfinite(p.bpm[m]):
                c += abs(float(_fold(np.array([p.bpm[m]]), np.array([t]))[0]) / t - 1) * 3
            if c < cost:
                best, cost = s, c
        if best is None:
            best = n
            n += 1
        pins[best] = m
    n = max(n, max(pins) + 1 if pins else 0)
    reserved = set(pins.values())
    solo = _solo(p, shape)
    blocked = np.zeros(p.n, dtype=bool)
    for i in exclude:
        blocked[i] = True
    for i in before:
        blocked[p.same == p.same[i]] = True
    if start is not None:
        blocked[p.same == p.same[start]] = True
    for i in reserved:
        blocked[i] = True

    first_groups = frozenset()
    beam = [Path(0.0, [], 0.0, first_groups)]
    for s in range(n):
        grown: list[Path] = []
        for path in beam:
            last = path.picks[-1] if path.picks else start
            k = (path.elapsed + typical / 2) / total
            if minutes and path.elapsed >= total:
                grown.append(path)
                continue
            if s in pins:
                c = pins[s]
                gain = 0.3 if last is None else float(
                    score(p, np.array([last]), np.array([c]), shape,
                          pitch=pitch if not path.picks else 1.0)[0])
                grown.append(Path(path.score + gain + float(solo[c]), path.picks + [c],
                                  path.elapsed + float(p.played_s[c]), path.groups | {int(p.same[c])}))
                continue
            aim = _aim(p, shape, k)
            if last is None:
                vec = 0.3 + aim + solo
            else:
                ea = p.energy[last]
                wanted = target(p, shape, k) - ea if np.isfinite(ea) else None
                vec = _pair_from(p, last, shape, pitch=pitch if not path.picks else 1.0,
                                 wanted=wanted) + aim + solo
            mask = blocked.copy()
            if path.groups:
                mask |= np.isin(p.same, np.fromiter(path.groups, dtype=np.int64))
            # An artist heard within the gap, less the further back it was.
            if shape.gap > 0:
                recent = ([start] if start is not None else []) + path.picks
                for dist, i in enumerate(reversed(recent[-shape.gap:])):
                    for name in p.artists[i]:
                        hit = p.by_artist.get(name)
                        if hit is not None:
                            vec[hit] -= 0.3 * (shape.gap - dist) / shape.gap
            vec = np.where(mask, -np.inf, vec)
            live = np.isfinite(vec)
            if not live.any():
                grown.append(path)
                continue
            count = min(topk, int(live.sum()))
            top = np.argpartition(-vec, count - 1)[:count]
            top = top[np.isfinite(vec[top])]
            # The slot before a pinned one: judged also by how it leads into the pin.
            if s + 1 in pins:
                vec_top = vec[top] + _into(p, top, pins[s + 1], shape)
            else:
                vec_top = vec[top]
            for c, v in zip(top, vec_top):
                c = int(c)
                grown.append(Path(path.score + float(v), path.picks + [c],
                                  path.elapsed + float(p.played_s[c]),
                                  path.groups | {int(p.same[c])}))
        grown.sort(key=lambda x: -x.score)
        # Paths that end on the same record with the same records used are the same
        # path for what comes next: only the best of them is kept.
        kept: list[Path] = []
        seen: set[tuple] = set()
        for g in grown:
            sig = (g.picks[-1] if g.picks else -1, g.groups)
            if sig in seen:
                continue
            seen.add(sig)
            kept.append(g)
            if len(kept) >= width:
                break
        beam = kept
    best = beam[0].picks if beam else []
    if minutes:
        # Trimmed to the time asked for: the record that crosses it is the last.
        out, t = [], 0.0
        for i in best:
            out.append(i)
            t += float(p.played_s[i])
            if t >= total:
                break
        best = out
    return _describe(p, shape, best, start=start, pins=pins, total=total, pitch=pitch)


def _describe(p: Pool, shape: Shape, picks: list[int], *, start: int | None,
              pins: dict[int, int], total: float, pitch: float = 1.0) -> list[dict]:
    out = []
    t = 0.0
    pinned = set(pins.values())
    set_total = sum(float(p.played_s[i]) for i in picks) or total
    for s, i in enumerate(picks):
        prev = picks[s - 1] if s > 0 else start
        k = (t + float(p.played_s[i]) / 2) / set_total
        fit = None
        why = ""
        if prev is not None:
            fit = float(score(p, np.array([prev]), np.array([i]), shape,
                              pitch=pitch if s == 0 else 1.0)[0])
            if p.artists[prev] & p.artists[i]:
                fit -= 0.3
            why = words(p, prev, i, pitch=pitch if s == 0 else 1.0)
        e = p.energy[i]
        out.append({
            "track": catalog.public(p.rows[i]),
            "fit": None if fit is None else round(fit, 3),
            "why": why,
            "energy": None if not np.isfinite(e) else round(float(e), 3),
            "target": round(target(p, shape, k), 3),
            "tempo_target": None if shape.tempo_at(k) is None else round(shape.tempo_at(k), 1),
            "bpm": None if not np.isfinite(p.bpm[i]) else round(float(p.bpm[i]), 2),
            "camelot": p.rows[i].get("camelot"),
            "parts": bool(p.parts[i]),
            "pinned": i in pinned,
            "at_ms": int(t * 1000),
        })
        t += float(p.played_s[i])
    return out


def alternatives(p: Pool, shape: Shape, *, prev: int | None, nxt: int | None, k: float,
                 exclude: set[int] = frozenset(), limit: int = 6) -> list[dict]:
    """Records that would sit in one slot: fit after [prev], fit before [nxt], where
    the shape wants the set [k] of the way in — never one in [exclude] or the same song
    as one, one artist at most once."""
    if p.n == 0:
        return []
    vec = _aim(p, shape, k) + _solo(p, shape)
    if prev is not None:
        ea = p.energy[prev]
        wanted = target(p, shape, k) - ea if np.isfinite(ea) else None
        vec = vec + _pair_from(p, prev, shape, wanted=wanted)
    else:
        vec = vec + 0.3
    blocked = np.zeros(p.n, dtype=bool)
    for i in exclude:
        blocked |= p.same == p.same[i]
    for i in (prev, nxt):
        if i is not None:
            blocked |= p.same == p.same[i]
    vec = np.where(blocked, -np.inf, vec)
    count = min(max(limit * 8, 40), int(np.isfinite(vec).sum()))
    if count <= 0:
        return []
    top = np.argpartition(-vec, count - 1)[:count]
    top = top[np.isfinite(vec[top])]
    total = vec[top] + (_into(p, top, nxt, shape) if nxt is not None else 0.3)
    order = top[np.argsort(-total)]
    out, names = [], set()
    for i in order:
        i = int(i)
        if p.artists[i] & names:
            continue
        names |= p.artists[i]
        fit_in = None if prev is None else float(score(p, np.array([prev]), np.array([i]), shape)[0])
        fit_out = None if nxt is None else float(score(p, np.array([i]), np.array([nxt]), shape)[0])
        out.append({
            "track": catalog.public(p.rows[i]),
            "fit_in": None if fit_in is None else round(fit_in, 3),
            "fit_out": None if fit_out is None else round(fit_out, 3),
            "why": words(p, prev, i) if prev is not None else "",
            "energy": None if not np.isfinite(p.energy[i]) else round(float(p.energy[i]), 3),
            "bpm": None if not np.isfinite(p.bpm[i]) else round(float(p.bpm[i]), 2),
            "camelot": p.rows[i].get("camelot"),
            "parts": bool(p.parts[i]),
        })
        if len(out) >= limit:
            break
    return out


# ------------------------------------------------------------------ what the pool holds
def stats(user_id: int, library: bool, ids: set[int], p: Pool) -> dict:
    """How much of what was asked for can be in a set: rows named, ready, measured —
    and what was asked for but never fetched, which could be."""
    if library:
        row = db.one(
            """select count(*) n,
                      count(*) filter (where t.state = 'ready') ready
                 from library_items li join tracks t on t.id = li.track_id
                where li.user_id = %s""", (user_id,)) or {"n": 0, "ready": 0}
        named, ready = int(row["n"]), int(row["ready"])
    else:
        named, ready = 0, 0
    unfetched = 0
    if ids:
        row = db.one(
            """select count(*) n,
                      count(*) filter (where state = 'ready') ready,
                      count(*) filter (where state <> 'ready') waiting
                 from tracks where id = any(%s)""", (list(ids),)) or {}
        if not library:
            named, ready = int(row.get("n") or 0), int(row.get("ready") or 0)
        unfetched = int(row.get("waiting") or 0)
    bpms = p.bpm[np.isfinite(p.bpm)]
    hist, edges = np.histogram(bpms, bins=np.arange(60, 202, 2)) if len(bpms) else (np.zeros(0), np.zeros(0))
    energies = p.energy[np.isfinite(p.energy)]
    ehist, _ = np.histogram(energies, bins=np.linspace(0, 1, 21)) if len(energies) else (np.zeros(0), None)
    return {
        "named": named,
        "ready": ready,
        "measured": p.n,
        "songs": int(len(set(p.same.tolist()))) if p.n else 0,
        "unmeasured": max(0, ready - p.n) if library or ids else 0,
        "unfetched": unfetched,
        "in_parts": int(p.parts.sum()),
        "bpm": {"from": 60, "step": 2, "counts": [int(x) for x in hist]},
        "energy": {"counts": [int(x) for x in ehist]},
    }
