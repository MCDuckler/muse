"""Going to look for another copy of a song whose copy has gone.

A video being deleted says nothing about the song. Kept apart from the screen that
started it because it is not really a screen's job: a track whose last source has just
been proved dead should go looking by itself, and the thing that notices that is the
worker, not somebody opening the downloads page.
"""
from __future__ import annotations

import json

from . import catalog, db, jobs, match, sources, ytm


def look(track: dict) -> dict:
    """Look for another copy of a song whose copy has gone.

    A video being deleted says nothing about the song. This searches for it again —
    somewhere else on YouTube first, then SoundCloud, which the server can fetch itself
    — and only reports failure once nothing anywhere is a confident match. The dead id
    is excluded by name, or the same search would hand it straight back.
    """
    # Everywhere this song has already been looked for, whether or not it worked. A
    # search that can hand back an id already on the track will do exactly that, and
    # one track collected nine of them that way.
    dead = {r["provider_id"] for r in db.all_(
        "select provider_id from track_sources where track_id=%s", (track["id"],))}
    # Copies written off along the way, so a second search does not resurrect one.
    dead |= {r["tried"] for r in db.all_(
        """select payload->>'video_id' as tried from jobs
            where kind='ingest' and state='failed'
              and (payload->>'track_id')::int = %s""", (track["id"],))
        if r["tried"]}
    want = {"title": track["title"], "artists": track["artists"] or [],
            "duration_ms": track["duration_ms"], "isrc": track.get("isrc")}
    query = " ".join([track["title"] or "", (track["artists"] or [""])[0]]).strip()
    if not query:
        return {"found": False, "reason": "nothing to search for"}

    try:
        # Twenty rather than eight. The copy that died is usually the best match there
        # is — it was, when it was chosen — so excluding it takes the top result off
        # the list and everything after it is what is left. Eight of those is mostly
        # karaoke; twenty reaches the other real uploads.
        candidates = [c for c in ytm.search_songs(query, limit=20)
                      if c.get("video_id") not in dead]
    except Exception:
        candidates = []
    best, conf, method = match.best(want, candidates)
    if best and conf >= match.AUTO_ACCEPT:
        db.run("""insert into track_sources(track_id,provider,provider_id,raw)
                  values(%s,'ytmusic',%s,%s)
                  on conflict do nothing""",
               (track["id"], best["video_id"], json.dumps(best.get("raw") or {})))
        db.run("""update tracks set state='pending', fail_reason=null, fail_code=null
                   where id=%s""", (track["id"],))
        jobs.enqueue("ingest", {"track_id": track["id"], "video_id": best["video_id"]},
                     priority=jobs.PRIORITY_BULK)
        return {"found": True, "where": "youtube", "confidence": round(conf, 2),
                "method": method}

    try:
        hits = [h for h in sources.search("soundcloud", query, limit=12)
                if h["provider_id"] not in dead]
    except sources.SourceError:
        hits = []
    best, conf, method = match.best(want, [{**h, "video_id": None} for h in hits])
    if best and conf >= match.AUTO_ACCEPT:
        db.run("""insert into track_sources(track_id,provider,provider_id,raw)
                  values(%s,'soundcloud',%s,%s)
                  on conflict do nothing""",
               (track["id"], best["provider_id"], json.dumps({})))
        db.run("""update tracks set state='pending', fail_reason=null, fail_code=null,
                          source='soundcloud' where id=%s""", (track["id"],))
        jobs.enqueue("ingest_direct",
                     {"track_id": track["id"], "provider": "soundcloud",
                      "ref": best.get("url") or best["provider_id"]},
                     priority=jobs.PRIORITY_BULK)
        return {"found": True, "where": "soundcloud", "confidence": round(conf, 2),
                "method": method}

    return {"found": False, "reason": "nothing close enough anywhere"}
