"""Turning downloader output into something worth showing a person.

yt-dlp's messages are written for the command line: "ERROR: [youtube] dQw4: Video
unavailable. This video contains content from X, who has blocked it in your country."
Nobody needs that in a queue row — they need to know whether waiting will help.
"""
from __future__ import annotations

import re

# (code, human message, retryable) matched in order; first hit wins.
_RULES: list[tuple[str, re.Pattern, str, bool]] = [
    ("unavailable", re.compile(r"video (is )?unavailable|does not exist|removed by the uploader", re.I),
     "This track isn’t available on YouTube any more", False),
    ("private", re.compile(r"private video|members[- ]only|join this channel", re.I),
     "This track is private", False),
    ("age_restricted", re.compile(r"age[- ]restricted|confirm your age|sign in to confirm your age", re.I),
     "Age-restricted — the downloader can’t reach it", False),
    ("geo_blocked", re.compile(r"not available in your country|blocked it in your country|geo", re.I),
     "Blocked in this region", False),
    ("bot_check", re.compile(r"sign in to confirm you.?re not a bot|LOGIN_REQUIRED", re.I),
     "YouTube asked the downloader to prove it isn’t a bot", False),
    ("po_token", re.compile(r"po token|missing a url|sabr", re.I),
     "YouTube changed its playback rules — the downloader needs an update", False),
    ("copyright", re.compile(r"copyright|blocked on copyright grounds", re.I),
     "Blocked for copyright", False),
    ("network", re.compile(r"timed out|timeout|connection|temporary failure|dns|reset by peer", re.I),
     "Network trouble reaching YouTube — trying again", True),
    ("throttled", re.compile(r"429|too many requests|rate", re.I),
     "YouTube is rate-limiting downloads — trying again shortly", True),
    ("format", re.compile(r"requested format|no video formats", re.I),
     "No usable audio for this track", False),
]

FALLBACK = ("unknown", "The download failed", True)


def classify(raw: str | None) -> tuple[str, str, bool]:
    """Returns (code, human message, retryable)."""
    if not raw:
        return FALLBACK
    for code, pattern, message, retryable in _RULES:
        if pattern.search(raw):
            return code, message, retryable
    return FALLBACK
