"""Turning downloader output into something worth showing a person.

yt-dlp's messages are written for the command line: "ERROR: [youtube] dQw4: Video
unavailable. This video contains content from X, who has blocked it in your country."
Nobody needs that in a queue row — they need to know whether waiting will help.
"""
from __future__ import annotations

import re

# (code, human message, retryable) matched in order; first hit wins.
#
# The messages name the service the track actually came from. They used to say YouTube
# whatever it was, because YouTube was the only place anything came from when they were
# written — so a SoundCloud track that failed was told it "isn't available on YouTube
# any more", which is both wrong and unactionable: it never was on YouTube, and the
# copy that does exist is the one nobody tried.
_RULES: list[tuple[str, re.Pattern, str, bool]] = [
    ("unavailable", re.compile(r"video (is )?unavailable|does not exist|removed by the uploader", re.I),
     "This track isn’t on {where} any more", False),
    ("private", re.compile(r"private video|members[- ]only|join this channel", re.I),
     "This track is private", False),
    ("age_restricted", re.compile(r"age[- ]restricted|confirm your age|sign in to confirm your age", re.I),
     "Age-restricted — the downloader can’t reach it", False),
    ("geo_blocked", re.compile(r"not available in your country|blocked it in your country|geo", re.I),
     "Blocked in this region", False),
    ("bot_check", re.compile(r"sign in to confirm you.?re not a bot|LOGIN_REQUIRED", re.I),
     "{where} asked the downloader to prove it isn’t a bot", False),
    ("po_token", re.compile(r"po token|missing a url|sabr", re.I),
     "{where} changed its playback rules — the downloader needs an update", False),
    ("drm", re.compile(r"drm protected", re.I),
     "This one is only streamable from {where} itself", False),
    ("paywalled", re.compile(r"only if you buy|purchase", re.I),
     "{where} keeps this one behind the purchase", False),
    ("copyright", re.compile(r"copyright|blocked on copyright grounds", re.I),
     "Blocked for copyright", False),
    ("network", re.compile(r"timed out|timeout|connection|temporary failure|dns|reset by peer", re.I),
     "Network trouble reaching {where} — trying again", True),
    ("throttled", re.compile(r"429|too many requests|rate", re.I),
     "{where} is rate-limiting downloads — trying again shortly", True),
    ("format", re.compile(r"requested format|no video formats|unable to download json metadata", re.I),
     "No usable audio for this track", False),
]

FALLBACK = ("unknown", "The download failed", True)

# Failures that say something about the copy rather than about the moment. A source
# that answers with one of these will answer with it again for ever, so it is worth
# writing off and looking elsewhere.
GONE = frozenset({"unavailable", "private", "copyright", "geo_blocked", "drm",
                  "paywalled", "format"})

# What a person calls the place a song came from.
_NAMES = {
    "ytmusic": "YouTube",
    "youtube": "YouTube",
    "soundcloud": "SoundCloud",
    "bandcamp": "Bandcamp",
}


def where(source: str | None) -> str:
    """The service by name, or something true but vague when we do not know."""
    return _NAMES.get((source or "").lower(), "the source")


def classify(raw: str | None, source: str | None = None) -> tuple[str, str, bool]:
    """Returns (code, human message, retryable)."""
    if not raw:
        return FALLBACK
    name = where(source)
    for code, pattern, message, retryable in _RULES:
        if pattern.search(raw):
            return code, message.format(where=name), retryable
    return FALLBACK
