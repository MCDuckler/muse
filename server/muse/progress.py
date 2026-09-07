"""Live ingest progress.

Kept in memory rather than in Postgres: it changes several times a second, it is
worthless once the download finishes, and writing it to disk would cost more than the
download itself. The API is a single process, so a plain dict is the whole mechanism.
"""
from __future__ import annotations

import time

# stage -> what the person waiting is actually being told
STAGES = {
    "queued": "Waiting for the downloader",
    "downloading": "Downloading",
    "converting": "Converting",
    "measuring": "Checking loudness",
    "uploading": "Saving",
}

_state: dict[int, dict] = {}
STALE_AFTER = 300


def update(track_id: int, stage: str, percent: float | None = None,
           speed: str | None = None) -> dict:
    entry = {
        "stage": stage,
        "label": STAGES.get(stage, stage),
        "percent": None if percent is None else max(0.0, min(1.0, percent)),
        "speed": speed,
        "at": time.time(),
    }
    _state[track_id] = entry
    return entry


def clear(track_id: int) -> None:
    _state.pop(track_id, None)


def get(track_id: int) -> dict | None:
    entry = _state.get(track_id)
    if entry and time.time() - entry["at"] > STALE_AFTER:
        # A worker that died mid-download should not leave a bar frozen at 60% forever.
        _state.pop(track_id, None)
        return None
    return entry


def snapshot() -> dict[int, dict]:
    return {tid: e for tid in list(_state) if (e := get(tid))}
