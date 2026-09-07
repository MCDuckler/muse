"""Matching a remote track (Spotify item, radio entry) to a local one.

Bad auto-matches are how a library like this rots, so every decision carries a score and
a method, and anything under AUTO_ACCEPT is meant to be seen by a human before it sticks.
"""
from __future__ import annotations

import re
import unicodedata

AUTO_ACCEPT = 0.85     # write it and move on
NEEDS_REVIEW = 0.60    # below this, never auto-attach
DURATION_TOLERANCE_MS = 3_000

# Everything labels disagree about while meaning the same recording.
_NOISE = re.compile(
    r"""\s*[\(\[]\s*(feat\.?|ft\.?|with\s|remaster|remastered|\d{4}\s+remaster|
        official\s+(music\s+)?video|official\s+audio|lyric[s]?\s*video|audio|video|
        radio\s+edit|single\s+version|album\s+version|explicit|clean|hd|hq|visualizer)
        [^\)\]]*[\)\]]""",
    re.I | re.X,
)
_TRAILING = re.compile(
    r"\s+-\s+(feat\.?|ft\.?|remaster(ed)?|radio\s+edit|single\s+version|album\s+version|"
    r"official\s+.*|.*\bversion\b|.*\bremaster\b.*)\s*$",
    re.I,
)
_PUNCT = re.compile(r"[^0-9a-z\s]")
_SPACE = re.compile(r"\s+")


def normalise(text: str | None) -> str:
    if not text:
        return ""
    t = unicodedata.normalize("NFKD", text)
    t = "".join(c for c in t if not unicodedata.combining(c)).lower()
    t = _NOISE.sub(" ", t)
    t = _TRAILING.sub("", t)
    t = _PUNCT.sub(" ", t)
    return _SPACE.sub(" ", t).strip()


def _tokens(text: str) -> set[str]:
    return set(normalise(text).split())


def title_similarity(a: str | None, b: str | None) -> float:
    ta, tb = _tokens(a or ""), _tokens(b or "")
    if not ta or not tb:
        return 0.0
    if normalise(a) == normalise(b):
        return 1.0
    return len(ta & tb) / len(ta | tb)


def artist_overlap(a: list[str] | None, b: list[str] | None) -> float:
    """One shared artist is usually enough — credits differ wildly between services."""
    sa = {normalise(x) for x in (a or []) if x}
    sb = {normalise(x) for x in (b or []) if x}
    if not sa or not sb:
        return 0.5                     # unknown, not wrong
    if sa & sb:
        return 1.0
    for x in sa:                       # "daft punk" vs "daft punk, pharrell williams"
        if any(x and (x in y or y in x) for y in sb):
            return 0.8
    return 0.0


FAR_APART_MS = 30_000
FAR_APART_CAP = 0.55                    # below NEEDS_REVIEW: a human decides


def duration_score(a_ms: int | None, b_ms: int | None) -> float:
    if not a_ms or not b_ms:
        return 0.5
    delta = abs(a_ms - b_ms)
    if delta <= DURATION_TOLERANCE_MS:
        return 1.0
    if delta <= 10_000:
        return 0.6
    if delta <= FAR_APART_MS:
        return 0.25
    return 0.0                          # a different edit, or a different recording


def score(remote: dict, candidate: dict) -> tuple[float, str]:
    """Returns (confidence, method). ISRC beats every heuristic."""
    r_isrc, c_isrc = (remote.get("isrc") or "").upper(), (candidate.get("isrc") or "").upper()
    if r_isrc and c_isrc:
        return (1.0, "isrc") if r_isrc == c_isrc else (0.0, "isrc-mismatch")

    t = title_similarity(remote.get("title"), candidate.get("title"))
    a = artist_overlap(remote.get("artists"), candidate.get("artists"))
    d = duration_score(remote.get("duration_ms"), candidate.get("duration_ms"))
    raw = round(0.5 * t + 0.3 * a + 0.2 * d, 3)
    if d == 0.0:
        # Same title and artist but minutes apart is a radio edit against an album
        # version, or an extended mix — the right song and the wrong recording.
        # Cap it under NEEDS_REVIEW so it is never attached silently.
        return min(raw, FAR_APART_CAP), "duration-mismatch"
    return raw, "heuristic"


def best(remote: dict, candidates: list[dict]) -> tuple[dict | None, float, str]:
    ranked = sorted(((score(remote, c), c) for c in candidates),
                    key=lambda x: x[0][0], reverse=True)
    if not ranked:
        return None, 0.0, "no-candidates"
    (conf, method), cand = ranked[0]
    return (cand if conf >= NEEDS_REVIEW else None), conf, method


def verdict(confidence: float) -> str:
    if confidence >= AUTO_ACCEPT:
        return "auto"
    if confidence >= NEEDS_REVIEW:
        return "flagged"
    return "review"
