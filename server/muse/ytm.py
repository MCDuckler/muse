"""YouTube Music lookups. Search needs no auth; the audio never comes from here."""
from __future__ import annotations

import re
from functools import lru_cache


@lru_cache(maxsize=1)
def _client():
    from ytmusicapi import YTMusic

    return YTMusic()


def _flatten(item: dict) -> dict:
    dur = item.get("duration_seconds")
    return {
        "video_id": item.get("videoId"),
        "title": item.get("title"),
        "artists": [a["name"] for a in (item.get("artists") or []) if a.get("name")],
        "album": (item.get("album") or {}).get("name") if isinstance(item.get("album"), dict) else None,
        "duration_ms": int(dur) * 1000 if dur else None,
        "raw": item,
    }


def search_songs(query: str, limit: int = 10) -> list[dict]:
    """Songs, not videos: songs carry a real album and artist credit."""
    res = _client().search(query, filter="songs", limit=limit)
    return [_flatten(r) for r in res if r.get("videoId")]


def song(video_id: str) -> dict | None:
    res = _client().search(video_id, filter="songs", limit=1)
    for r in res:
        if r.get("videoId") == video_id:
            return _flatten(r)
    return None


def watch_playlist(video_id: str, limit: int = 25) -> list[dict]:
    """The radio tail for a seed track. Unauthenticated; returns ~50 candidates."""
    data = _client().get_watch_playlist(video_id, limit=limit)
    out = []
    for t in data.get("tracks", []):
        if not t.get("videoId"):
            continue
        length = t.get("length")  # "4:09"
        ms = None
        if isinstance(length, str) and ":" in length:
            parts = [int(p) for p in length.split(":")]
            ms = (parts[0] * 60 + parts[1]) * 1000 if len(parts) == 2 else \
                 (parts[0] * 3600 + parts[1] * 60 + parts[2]) * 1000
        out.append({
            "video_id": t["videoId"],
            "title": t.get("title"),
            "artists": [a["name"] for a in (t.get("artists") or []) if a.get("name")],
            "album": (t.get("album") or {}).get("name") if isinstance(t.get("album"), dict) else None,
            "duration_ms": ms,
            "raw": {"radio_seed": video_id},
        })
    return out


_GOOGLE_SIZE = re.compile(r"=w\d+-h\d+")


def thumbnail_url(raw: dict, px: int = 300) -> str | None:
    """Album art from a search payload, asked for at a useful size.

    The stored URLs are 60 or 120px because that is what YouTube Music's own list
    needs; the dimensions live in the URL, so a bigger one costs nothing.
    """
    thumbs = (raw or {}).get("thumbnails") or []
    if not thumbs:
        return None
    best = max(thumbs, key=lambda t: (t.get("width") or 0))
    url = best.get("url")
    return _GOOGLE_SIZE.sub(f"=w{px}-h{px}", url) if url else None
