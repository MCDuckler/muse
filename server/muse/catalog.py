"""Track rows: how they are read, shaped for clients, and created from a provider hit."""
from __future__ import annotations

import json
import re

from . import artists, db, jobs, progress

# Where a track came into the library. Radio pulls in songs nobody asked for, so they
# stay identifiable for a future cleanup.
VIA_USER, VIA_RADIO, VIA_SYNC = "user", "radio", "sync"

# Markers a video platform adds that say nothing about the recording. Deliberately
# conservative: "(Radio Edit)" and "(feat. …)" stay, because those distinguish one
# recording from another and dropping them would be a lie about what is playing.
_NOISE = re.compile(
    r"\s*[\(\[]\s*(official\s+(music\s+)?video|official\s+audio|lyrics?\s*video"
    r"|visualizer|audio only|hd|hq|4k)\s*[^\)\]]*[\)\]]",
    re.I,
)
_TRAILING = re.compile(r"\s*[-–]\s*(official\s+.*|.*\bvisualizer\b.*)$", re.I)


def display_title(raw: str | None) -> str:
    if not raw:
        return ""
    return _TRAILING.sub("", _NOISE.sub("", raw)).strip() or raw


def track_row(track_id: int) -> dict | None:
    return db.one(
        """select t.*, m.bytes, m.path, m.sha256, m.codec, m.bitrate,
                  s.provider, s.provider_id, c.color as cover_color,
                  c.sha256 as cover_sha
             from tracks t
             left join media m on m.track_id=t.id and m.role='canonical'
             left join track_sources s on s.track_id=t.id
             left join covers c on c.id=t.cover_id
            where t.id=%s""",
        (track_id,),
    )


def public(t: dict) -> dict:
    return {
        "id": t["id"],
        "title": t["title"],
        "display_title": display_title(t["title"]),
        "cover_url": f"/tracks/{t['id']}/cover" if t.get("cover_id") else None,
        "cover_color": t.get("cover_color"),
        # Changes when the artwork does, so a client that cached the old image by URL
        # does not keep showing it.
        "cover_version": (t.get("cover_sha") or "")[:8] or None,
        "artists": t["artists"],
        "album": t["album"],
        "duration_ms": t["duration_ms"],
        "state": t["state"],
        "fail_reason": t["fail_reason"],
        "fail_code": t.get("fail_code"),
        # Live ingest state, so a row can show what is happening rather than a spinner
        # that means "something, for some length of time".
        "progress": progress.get(t["id"]),
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


def credits(names) -> list[str]:
    """The artists in a credit, one per entry.

    "Hugh Hardie, Kyan" arriving as a single string makes the pair a third artist with
    one record to their name. muse.artists does the splitting, and the checking that
    stops "Fujiya & Miyagi" becoming two people.
    """
    return artists.split_all(names, verify=artists.deezer_verifier())


def create_from_source(provider: str, meta: dict, discovered_via: str = VIA_USER,
                       priority: int = jobs.PRIORITY_NORMAL,
                       batch_id: str | None = None,
                       batch_label: str | None = None,
                       download: bool = True) -> dict:
    """A track from somewhere the server fetches itself: SoundCloud, Bandcamp.

    Same shape as the YouTube path, different lane. The job goes to `ingest_direct`,
    which runs in this process rather than on the machine at home, because these two
    do not care that the request comes from a datacenter.
    """
    row = db.one(
        """insert into tracks(title,artists,album,duration_ms,source,state,
                              discovered_via,isrc)
           values(%s,%s,%s,%s,%s,'pending',%s,%s) returning id""",
        (meta["title"], credits(meta.get("artists")), meta.get("album"),
         meta.get("duration_ms"), provider, discovered_via,
         (meta.get("isrc") or None)),
    )
    db.run(
        "insert into track_sources(track_id,provider,provider_id,raw) values(%s,%s,%s,%s)",
        (row["id"], provider, meta["provider_id"], json.dumps(meta.get("raw") or meta)),
    )
    if download:
        jobs.enqueue("ingest_direct",
                     {"track_id": row["id"], "provider": provider,
                      "ref": meta.get("url") or meta["provider_id"]},
                     priority=priority, batch_id=batch_id, batch_label=batch_label)
    jobs.enqueue("meta", {"track_id": row["id"]}, batch_id=batch_id)
    return track_row(row["id"])


def remember(user_id: int, *track_ids: int) -> None:
    """Put a track in someone's library.

    Adding to a playlist or a queue does this by itself — the database does it, so no
    caller can forget — but a track resolved straight from a search belongs to whoever
    asked for it before it has landed anywhere.
    """
    ids = [t for t in track_ids if t]
    if not ids:
        return
    db.run(
        """insert into library_items(user_id, track_id)
           select %s, unnest(%s::int[]) on conflict do nothing""",
        (user_id, ids),
    )


def find_by_isrc(isrc: str | None) -> dict | None:
    """The same recording, whatever it was called on the way in.

    An ISRC is assigned to a recording, not to a release or a spelling, so this is what
    lets a song already in the library be recognised when it arrives again from another
    service — no second download, no second row, no wrong take.
    """
    if not isrc:
        return None
    row = db.one(
        """select id from tracks where isrc = upper(%s)
            order by (state='ready') desc, id limit 1""",
        (isrc.strip(),),
    )
    return track_row(row["id"]) if row else None


def find_by_provider(provider: str, provider_id: str) -> dict | None:
    row = db.one(
        """select track_id from track_sources
            where provider=%s and provider_id=%s order by track_id limit 1""",
        (provider, provider_id),
    )
    return track_row(row["track_id"]) if row else None


def create_from_ytm(meta: dict, discovered_via: str = VIA_USER,
                    priority: int = jobs.PRIORITY_NORMAL,
                    batch_id: str | None = None,
                    batch_label: str | None = None,
                    download: bool = True) -> dict:
    """New track row in `pending`, and usually the ingest job with it.

    `download=False` records the track without queueing the audio. A library of twelve
    thousand liked songs is a list worth having long before it is forty gigabytes worth
    having, so those arrive when somebody actually plays them.
    """
    row = db.one(
        """insert into tracks(title,artists,album,duration_ms,source,state,
                              discovered_via,isrc)
           values(%s,%s,%s,%s,'youtube','pending',%s,%s) returning id""",
        (meta["title"], credits(meta["artists"]), meta["album"], meta["duration_ms"],
         discovered_via, (meta.get("isrc") or None)),
    )
    db.run(
        "insert into track_sources(track_id,provider,provider_id,raw) values(%s,'ytmusic',%s,%s)",
        (row["id"], meta["video_id"], json.dumps(meta.get("raw") or {})),
    )
    if download:
        jobs.enqueue("ingest", {"track_id": row["id"], "video_id": meta["video_id"]},
                     priority=priority, batch_id=batch_id, batch_label=batch_label)
    # Artwork does not depend on the audio, and a queue row with a cover while it
    # downloads is far better than a grey square that fills in minutes later.
    jobs.enqueue("meta", {"track_id": row["id"]}, batch_id=batch_id)
    return track_row(row["id"])


def retry(track_id: int, video_id: str) -> dict:
    db.run("update tracks set state='pending', fail_reason=null where id=%s", (track_id,))
    jobs.enqueue("ingest", {"track_id": track_id, "video_id": video_id})
    return track_row(track_id)
