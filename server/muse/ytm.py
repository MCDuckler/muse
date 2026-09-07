"""YouTube Music lookups. Search needs no auth; the audio never comes from here."""
from __future__ import annotations

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
