"""In-process worker for the sources the server can fetch itself.

YouTube refuses datacenter IPs, which is why a worker runs at home. SoundCloud and
Bandcamp do not — measured from this box, not assumed — so their downloads run here,
where there is no upload leg and no nine-megabit ceiling between the file and the disk.

It also runs `mirror` jobs, because importing twelve thousand liked songs is not
something to do inside an HTTP request, and the `follow_poll` that asks what the
artists people follow have put out lately.
"""
from __future__ import annotations

import logging
import pathlib
import tempfile
import threading
import time

from . import db, failures, follows, jobs, progress, sources, storage

log = logging.getLogger("muse.direct")

IDLE_SLEEP = 3.0
ERROR_SLEEP = 30.0
KINDS = ("ingest_direct", "mirror", "follow_poll")


class DirectWorker:
    def __init__(self, cfg, name: str = "api-direct", publish=None, mirror=None):
        self.cfg = cfg
        self.name = name
        self.publish = publish
        # Injected rather than imported: the mirror lives in the routes layer, and
        # importing it here would tie the worker to the web app.
        self.mirror = mirror
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None

    def start(self) -> None:
        if self._thread:
            return
        self._thread = threading.Thread(target=self._run, name=self.name, daemon=True)
        self._thread.start()
        log.info("direct worker started")

    def stop(self) -> None:
        self._stop.set()

    def _run(self) -> None:
        while not self._stop.is_set():
            worked = False
            for kind in KINDS:
                try:
                    leased = jobs.lease(self.name, kind=kind, limit=1)
                except Exception as e:                 # database restarting, say
                    log.warning("lease failed: %s", e)
                    self._stop.wait(ERROR_SLEEP)
                    break
                for job in leased:
                    worked = True
                    if kind == "mirror":
                        self._mirror(job)
                    elif kind == "follow_poll":
                        self._follow_poll(job)
                    else:
                        self._ingest(job)
            if not worked:
                self._stop.wait(IDLE_SLEEP)

    # ------------------------------------------------------------- followed artists
    def _follow_poll(self, job: dict) -> None:
        try:
            result = follows.poll()
            log.info("follow poll: %s artists", result.get("artists"))
        except Exception as e:
            log.warning("follow poll failed: %s", e)
            jobs.fail(job["id"], str(e))
            return                       # a retryable failure is itself the next one
        # Finish first, then queue the next: "is one already outstanding?" would
        # otherwise see this job, still leased, and decide there was nothing to do —
        # which is how the poll ran once per restart and never again.
        jobs.finish(job["id"])
        follows.ensure_scheduled()

    # ------------------------------------------------------------------ audio
    def _ingest(self, job: dict) -> None:
        payload = job["payload"]
        track_id = int(payload["track_id"])
        provider = payload.get("provider") or "soundcloud"
        ref = payload.get("ref") or payload.get("url") or payload.get("video_id")

        def report(stage: str, percent: float | None = None):
            entry = progress.update(track_id, stage, percent)
            if self.publish:
                self.publish("track_progress", {"track_id": track_id, **entry})

        started = time.monotonic()
        try:
            with tempfile.TemporaryDirectory(prefix="muse-direct-") as tmp:
                got = sources.fetch(provider, ref, pathlib.Path(tmp), report)
                path: pathlib.Path = got["path"]

                report("measuring")
                info = sources.probe(path)
                lufs, gain = sources.loudness(path)

                report("storing")
                with path.open("rb") as fh:
                    digest, stored, size = storage.store_stream(
                        self.cfg.audio_dir, fh, path.suffix or ".m4a")

            db.run(
                """insert into media(track_id,sha256,codec,bitrate,bytes,path)
                   values(%s,%s,%s,%s,%s,%s)
                   on conflict (track_id,sha256) do nothing""",
                (track_id, digest, info.get("codec"), info.get("bitrate"), size,
                 str(stored)),
            )
            db.run(
                """update tracks set state='ready', fail_reason=null, fail_code=null,
                          duration_ms=coalesce(%s,duration_ms),
                          loudness_lufs=%s, gain_db=%s
                    where id=%s""",
                (info.get("duration_ms"), lufs, gain, track_id),
            )
            jobs.finish(job["id"])
            progress.clear(track_id)
            jobs.enqueue("meta", {"track_id": track_id})
            if self.publish:
                self.publish("track_ready", {"track_id": track_id, "bytes": size})
            log.info("fetched %s track %s in %.1fs (%s, %.1f MB)", provider, track_id,
                     time.monotonic() - started, info.get("codec"), size / 1e6)
        except sources.SourceError as e:
            # Something about this track, not about the network: do not keep asking.
            #
            # Put through the same classifier as a YouTube failure, so what a person
            # reads is the same kind of sentence and names the right service — yt-dlp's
            # own words ("This video is DRM protected") are about neither the track nor
            # anywhere it lives.
            progress.clear(track_id)
            code, message, _ = failures.classify(str(e), provider)
            jobs.fail(job["id"], str(e), retryable=False)
            db.run("update tracks set state='failed', fail_reason=%s, fail_code=%s "
                   "where id=%s",
                   (message if code != "unknown" else str(e)[:500], code, track_id))
            # Written off, so the next attempt reaches for a different copy. See the
            # worker-report path in app.py for the same rule.
            if code in failures.GONE:
                db.run("""update track_sources
                             set raw = coalesce(raw,'{}'::jsonb) || '{"dead": true}'
                           where track_id=%s and provider=%s""", (track_id, provider))
            log.warning("%s track %s failed: %s", provider, track_id, e)
        except Exception as e:
            progress.clear(track_id)
            jobs.fail(job["id"], f"{type(e).__name__}: {e}", retryable=True)
            log.warning("%s track %s crashed: %s", provider, track_id, e)

    # ------------------------------------------------------------------ mirrors
    def _mirror(self, job: dict) -> None:
        if not self.mirror:
            jobs.fail(job["id"], "no mirror handler installed", retryable=False)
            return
        payload = job["payload"]
        started = time.monotonic()
        try:
            result = self.mirror(payload)
            jobs.finish(job["id"])
            if self.publish:
                self.publish("mirror_done", {**payload, **(result or {})})
            log.info("mirrored %s in %.0fs: %s", payload.get("remote_id"),
                     time.monotonic() - started, result)
        except Exception as e:
            jobs.fail(job["id"], f"{type(e).__name__}: {e}", retryable=True)
            log.warning("mirror %s failed: %s", payload.get("remote_id"), e)
