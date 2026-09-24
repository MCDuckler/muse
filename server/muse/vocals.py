"""Where the voice is in a record, and what it sings — for the booth's automix.

Two sources, each checked against the other:

  * the **voice itself**, from the vocals part a computer in the pool made (pool.py):
    how loud the voice is in every bar, 0 to 255 — where the singing is, where it is
    not, which is what a mix is timed around (two voices at once is the one clash
    everybody hears);
  * the **words**, from the synced lyrics LRCLIB has for the song: its lines and when
    they come, and its hook — the line sung most often, a line with the song's title
    in it first. A record "announcing itself" over the one before it does it with this.

The lyrics are timed to the song as released, and many records here are remixes and
edits of it: so the lines are only kept with their times where, moved by some offset,
they fall where the voice actually is. Otherwise the words are kept without times.
"""
from __future__ import annotations

import json
import logging
import pathlib
import re
import subprocess
import threading
import time

import numpy as np

from . import pool

log = logging.getLogger("muse.vocals")

VERSION = 2
_RATE = 11025

# LRCLIB answers about one request in thirty seconds; asked faster it stops answering.
_LYRICS_EVERY = 31.0
_lyrics_at = 0.0
_lyrics_lock = threading.Lock()


def cache_path(data_dir: pathlib.Path, sha: str, downbeats: list[int] | None = None) -> pathlib.Path:
    # Per bar grid: the bars the levels are counted on move when the tracker moves them.
    on = f"-b{downbeats[0]}" if downbeats else ""
    return data_dir / "beats" / f"{sha}-vocals-v{VERSION}{on}.json"


def _mono(path: pathlib.Path, pan: str | None = None) -> np.ndarray:
    raw = subprocess.run(
        ["ffmpeg", "-v", "error", "-i", str(path),
         *(["-af", f"pan=mono|c0={pan}"] if pan else ["-ac", "1"]),
         "-ar", str(_RATE), "-f", "s16le", "-"],
        capture_output=True, timeout=120, check=True).stdout
    return np.frombuffer(raw[: len(raw) // 2 * 2], dtype="<i2").astype(np.float32) / 32768.0


def _bar_rms(x: np.ndarray, bounds: list[int]) -> list[float]:
    out = []
    for a, b in zip(bounds[:-1], bounds[1:]):
        seg = x[int(a * _RATE / 1000):int(b * _RATE / 1000)]
        out.append(float(np.sqrt(np.mean(seg * seg))) if len(seg) else 0.0)
    return out


# The voice's share of the record in a bar, in dB, that is 0 and 255: a sung bar is a
# tenth of the record's loudness and more (-13 dB is the booth's "sung", 118); what a
# separator leaves of the band in the voice of an instrumental is -25 dB and under.
_SHARE_NONE = -24.0
# And quieter than this, whatever its share, it is not a voice anybody hears.
_SILENT_DB = -50.0


def bar_levels(vocals: pathlib.Path, record: pathlib.Path, downbeats_ms: list[int],
               pan: str | None = None) -> list[int]:
    """How much of each bar is the voice, 0 to 255: its share of the record's own
    loudness there. Measured against the record rather than against the voice's own
    loudest bar — that made the separator's faint leftovers in an instrumental read
    as singing from start to end."""
    if len(downbeats_ms) < 2:
        return []
    v, m = _mono(vocals, pan), _mono(record)
    if len(v) == 0 or len(m) == 0:
        return []
    bounds = list(downbeats_ms) + [downbeats_ms[-1] + (downbeats_ms[-1] - downbeats_ms[-2])]
    out = []
    for rv, rm in zip(_bar_rms(v, bounds), _bar_rms(m, bounds)):
        if rv <= 0 or 20 * np.log10(rv) < _SILENT_DB:
            out.append(0)
            continue
        share = 20 * np.log10(min(1.0, rv / max(rm, 1e-6)))
        out.append(int(round(255 * max(0.0, 1 - share / _SHARE_NONE))))
    return out


_LINE = re.compile(r"\[(\d+):(\d+(?:\.\d+)?)\](.*)")


def parse_lrc(synced: str | None) -> list[tuple[int, str]]:
    lines = []
    for raw in (synced or "").splitlines():
        m = _LINE.match(raw.strip())
        if not m:
            continue
        text = m.group(3).strip()
        if not text:
            continue
        lines.append((int((int(m.group(1)) * 60 + float(m.group(2))) * 1000), text))
    return lines


def _norm(s: str) -> str:
    return re.sub(r"[^a-z0-9 ]+", "", s.lower()).strip()


def hook_of(lines: list[tuple[int, str]], title: str) -> dict | None:
    """The line sung most often — a line with the title's words in it first — and every
    time it comes."""
    if not lines:
        return None
    count: dict[str, list[int]] = {}
    text_of: dict[str, str] = {}
    for ms, text in lines:
        k = _norm(text)
        if len(k.split()) < 2:
            continue
        count.setdefault(k, []).append(ms)
        text_of[k] = text
    if not count:
        return None
    title_words = {w for w in _norm(re.sub(r"\(.*?\)|\[.*?\]", "", title)).split() if len(w) > 2}

    def score(k: str) -> tuple:
        titled = bool(title_words) and title_words <= set(k.split())
        return (len(count[k]) >= 2 and titled, len(count[k]), titled)

    best = max(count, key=score)
    if len(count[best]) < 2 and not score(best)[2]:
        return None
    return {"text": text_of[best], "at": count[best]}


def align(lines: list[tuple[int, str]], bars: list[int], downbeats: list[int]) -> int | None:
    """The offset, in ms, that puts the lyrics' lines where the voice is — or None where
    no offset does it well enough to believe (a remix, an edit, another song)."""
    if len(lines) < 4 or not bars or len(downbeats) < 2:
        return None
    sung = np.array(bars) >= 90
    if sung.sum() < 4:
        return None
    db = np.array(downbeats)

    def fit(off: int) -> float:
        idx = np.searchsorted(db, np.array([ms + off for ms, _ in lines]), side="right") - 1
        ok = (idx >= 0) & (idx < len(bars))
        if ok.sum() < len(lines) * 0.8:
            return 0.0
        return float(sung[idx[ok]].mean())

    offsets = range(-60000, 60001, 250)
    scores = [(fit(o), -abs(o), o) for o in offsets]
    best = max(scores)
    # Most lines on sung bars, and clearly better than lines put anywhere at all.
    chance = float(sung.mean())
    if best[0] < 0.8 or best[0] < chance + 0.2:
        return None
    return best[2]


def lyrics_for(track: dict) -> tuple[str | None, str]:
    """The synced lyrics kept for [track], fetching them the first time where LRCLIB may
    be asked now. (text, source)."""
    from . import db
    from .routes_play import LRCLIB, UA

    row = db.one("select synced, source from lyrics where track_id=%s", (track["id"],))
    if row:
        return row["synced"], row["source"] or ""
    global _lyrics_at
    with _lyrics_lock:
        if time.monotonic() - _lyrics_at < _LYRICS_EVERY:
            return None, "later"
        _lyrics_at = time.monotonic()
    import httpx

    params = {"track_name": track.get("title") or "",
              "artist_name": (track.get("artists") or [""])[0],
              "album_name": track.get("album") or "",
              "duration": round((track.get("duration_ms") or 0) / 1000)}
    synced = plain = None
    source = "lrclib"
    try:
        r = httpx.get(LRCLIB, params=params, headers={"User-Agent": UA}, timeout=15)
        if r.status_code == 200:
            d = r.json()
            synced, plain = d.get("syncedLyrics"), d.get("plainLyrics")
        elif r.status_code == 404:
            source = "lrclib-miss"
        else:
            return None, "later"
    except httpx.HTTPError:
        return None, "later"
    db.run("""insert into lyrics(track_id,synced,plain,source) values(%s,%s,%s,%s)
              on conflict (track_id) do nothing""", (track["id"], synced, plain, source))
    return synced, source


def for_track(data_dir: pathlib.Path, track: dict, downbeats: list[int]) -> dict:
    """The voice and the words of [track], kept once the voice has been measured."""
    sha = track["sha256"]
    cached = cache_path(data_dir, sha, downbeats)
    bars = None
    try:
        bars = json.loads(cached.read_text())["bars"]
    except (OSError, ValueError, KeyError):
        # The voice's own part, or the voice out of the six-channel stems file.
        vocals, pan = pool.part_here(sha, "vocals"), None
        if vocals is None:
            vocals, pan = pool.part_here(sha, "stems"), "0.5*c4+0.5*c5"
        if vocals is not None:
            from . import heavy
            try:
                with heavy.turn(f"{sha}-vocals"):
                    bars = bar_levels(vocals, pathlib.Path(track["path"]), downbeats, pan)
                cached.parent.mkdir(parents=True, exist_ok=True)
                cached.write_text(json.dumps({"bars": bars}))
            except (subprocess.SubprocessError, OSError) as e:
                log.warning("could not measure the voice of %s: %s", sha[:12], e)
    synced, source = lyrics_for(track)
    lines = parse_lrc(synced)
    offset = align(lines, bars or [], downbeats) if lines else None
    hook = hook_of(lines, track.get("title") or "")
    timed = offset is not None
    out = {
        "bars": bars,
        "lyrics": source if lines else (source if source == "later" else None),
        "timed": timed,
        "lines": [{"ms": ms + offset if timed else None, "text": text} for ms, text in lines],
        "hook": None,
    }
    if hook:
        out["hook"] = {"text": hook["text"],
                       "at": [ms + offset for ms in hook["at"]] if timed else []}
    return out
