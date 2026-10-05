"""How a song's fetch ends on this box, whoever did the fetching.

The server fetches some songs itself — SoundCloud and Bandcamp directly
(direct_worker.py), YouTube through somebody's phone (exits.py) — and every one of them
ends the same way: looked at, measured, kept and announced, or written down as having
gone wrong in words a person can act on. One copy of each ending, so the ways in cannot
drift apart.
"""
from __future__ import annotations

import pathlib

from . import db, failures, jobs, progress, sources, storage


def land(cfg, job_id: int, track_id: int, path: pathlib.Path, publish=None,
         report=None) -> dict:
    """A fetched file on this disk becomes the song: measured, kept, marked ready, its
    artwork and metadata queued, and everybody told."""
    if report:
        report("measuring")
    info = sources.probe(path)
    lufs, gain = sources.loudness(path)
    if report:
        report("storing")
    with path.open("rb") as fh:
        digest, stored, size = storage.store_stream(
            cfg.audio_dir, fh, path.suffix or ".m4a")
    db.run(
        """insert into media(track_id,sha256,codec,bitrate,bytes,path)
           values(%s,%s,%s,%s,%s,%s)
           on conflict (track_id,sha256) do nothing""",
        (track_id, digest, info.get("codec"), info.get("bitrate"), size, str(stored)),
    )
    db.run(
        """update tracks set state='ready', fail_reason=null, fail_code=null,
                  duration_ms=coalesce(%s,duration_ms),
                  loudness_lufs=%s, gain_db=%s
            where id=%s""",
        (info.get("duration_ms"), lufs, gain, track_id),
    )
    jobs.finish(job_id)
    progress.clear(track_id)
    # Artwork and canonical metadata are a separate concern from getting the audio,
    # and they must never hold up playback.
    jobs.enqueue("meta", {"track_id": track_id})
    if publish:
        publish("track_ready", {"track_id": track_id, "bytes": size})
    # A song in a playlist marked to be taken apart: queued for the pool now, as it is
    # when a computer hands one in.
    if db.one("""select 1 from playlist_items i join playlists p on p.id=i.playlist_id
                  where i.track_id=%s and p.auto_split limit 1""", (track_id,)):
        from . import pool                       # pool reaches back here through exits
        pool.want_split(track_id, priority=jobs.PRIORITY_BULK)
    return {**info, "sha256": digest, "bytes": size}


def failed(job_id: int, track_id: int | None, raw: str, retryable: bool = True,
           publish=None) -> tuple[str, bool]:
    """A fetch that did not work: the job retried or written off, the song told why.

    Answers the failure's code and whether it will be tried again."""
    # Named by where the song actually lives, not by where it happened to be fetched
    # from — see failures.classify.
    heard_from = (db.one("select source from tracks where id=%s", (track_id,))
                  if track_id else None)
    code, message, classified = failures.classify(raw, (heard_from or {}).get("source"))
    # The fetcher's own judgement can only make a failure *less* retryable.
    retryable = classified and retryable
    jobs.fail(job_id, raw or message, retryable)
    if not track_id:
        return code, retryable

    progress.clear(track_id)
    attempts = db.one("select attempts from jobs where id=%s", (job_id,))
    will_retry = retryable and (attempts or {}).get("attempts", 99) < jobs.MAX_ATTEMPTS
    db.run("update tracks set state=%s, fail_reason=%s, fail_code=%s where id=%s",
           ("pending" if will_retry else "failed", message, code, track_id))
    # A copy that is gone stays gone. Marked rather than deleted — it is still the reason
    # the track is here — but never chosen again, so asking for the song reaches for a
    # copy that might work instead of the one known not to.
    #
    # Read off the job rather than out of the request. The worker reports what went
    # wrong and which track it was, and has never sent the video id — so this looked for
    # one that was never there and marked nothing, and one track failed on the same dead
    # id ten times in a row. The server queued the job; it knows perfectly well what it
    # asked for.
    if code in failures.GONE:
        job = db.one("select payload from jobs where id=%s", (job_id,))
        video = ((job or {}).get("payload") or {}).get("video_id")
        if video:
            db.run("""update track_sources
                         set raw = coalesce(raw,'{}'::jsonb) || '{"dead": true}'
                       where track_id=%s and provider_id=%s""", (track_id, video))
        # Nothing left that could work. A video being deleted says nothing about the
        # song, so go and look for another copy of it rather than leaving somebody to
        # notice and press a button — which is the whole difference between "this isn't
        # on YouTube any more" being true of a video and being wrong about a song that
        # plainly is.
        if jobs.best_source(int(track_id)) is None:
            jobs.enqueue("refind", {"track_id": int(track_id)},
                         priority=jobs.PRIORITY_BULK)
    if publish:
        publish("track_failed", {"track_id": track_id, "reason": message, "code": code,
                                 "will_retry": will_retry})
    return code, retryable
