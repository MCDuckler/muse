"""Track rows: how they are read, shaped for clients, and created from a provider hit."""
from __future__ import annotations

import json

from . import db, jobs

# Where a track came into the library. Radio pulls in songs nobody asked for, so they
# stay identifiable for a future cleanup.
VIA_USER, VIA_RADIO, VIA_SYNC = "user", "radio", "sync"


def track_row(track_id: int) -> dict | None:
    return db.one(
        """select t.*, m.bytes, m.path, m.sha256, m.codec, m.bitrate,
                  s.provider, s.provider_id
             from tracks t
             left join media m on m.track_id=t.id and m.role='canonical'
             left join track_sources s on s.track_id=t.id
            where t.id=%s""",
        (track_id,),
    )


def public(t: dict) -> dict:
    return {
        "id": t["id"],
        "title": t["title"],
        "artists": t["artists"],
        "album": t["album"],
        "duration_ms": t["duration_ms"],
        "state": t["state"],
        "fail_reason": t["fail_reason"],
        "source": t["source"],
        "discovered_via": t.get("discovered_via"),
        "gain_db": t["gain_db"],
        "loudness_lufs": t["loudness_lufs"],
        "bytes": t.get("bytes"),
        "provider_id": t.get("provider_id"),
        "stream_url": f"/tracks/{t['id']}/stream" if t.get("path") else None,
    }


def find_by_video_id(video_id: str) -> dict | None:
    row = db.one(
        "select track_id from track_sources where provider='ytmusic' and provider_id=%s",
        (video_id,),
    )
    return track_row(row["track_id"]) if row else None


def create_from_ytm(meta: dict, discovered_via: str = VIA_USER) -> dict:
    """New track row in `pending` plus the ingest job. Never downloads inline."""
    row = db.one(
        """insert into tracks(title,artists,album,duration_ms,source,state,discovered_via)
           values(%s,%s,%s,%s,'youtube','pending',%s) returning id""",
        (meta["title"], meta["artists"], meta["album"], meta["duration_ms"], discovered_via),
    )
    db.run(
        "insert into track_sources(track_id,provider,provider_id,raw) values(%s,'ytmusic',%s,%s)",
        (row["id"], meta["video_id"], json.dumps(meta.get("raw") or {})),
    )
    jobs.enqueue("ingest", {"track_id": row["id"], "video_id": meta["video_id"]})
    return track_row(row["id"])


def retry(track_id: int, video_id: str) -> dict:
    db.run("update tracks set state='pending', fail_reason=null where id=%s", (track_id,))
    jobs.enqueue("ingest", {"track_id": track_id, "video_id": video_id})
    return track_row(track_id)
