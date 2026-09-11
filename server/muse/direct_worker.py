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

from . import (catalog, db, failures, follows, jobs, progress, refind,
               shazam, sources, storage)

log = logging.getLogger("muse.direct")

IDLE_SLEEP = 3.0
ERROR_SLEEP = 30.0

# How long to leave a service alone once it has said to stop asking. Long enough to be
# a real answer to a rate limit and short enough that a queue started in the morning is
# still finished by the evening.
HOLD_OFF_SECONDS = 300.0

# What runs where, and this split is the whole point of the list.
#
# It used to be one thread taking one job of each kind in turn. A library import is
# minutes of work and a download is seconds of it, so a single mirror running meant
# exactly one track downloaded per pass of the loop — measured at one a minute against
# a queue nine thousand deep, which is five months. Downloads get their own threads and
# cannot end up behind an import again.
LANES: tuple[tuple[str, tuple[str, ...]], ...] = (
    # Two, not three. These fetch from one service at a time and it is a service that
    # says 429 when it has had enough — more hands do not make a rate limit lighter.
    ("fetch", ("ingest_direct",)),
    ("fetch", ("ingest_direct",)),
    ("slow", ("mirror", "refind", "shazam_match", "follow_poll")),
)


class DirectWorker:
    def __init__(self, cfg, name: str = "api-direct", publish=None, mirror=None):
        self.cfg = cfg
        self.name = name
        self.publish = publish
        # Injected rather than imported: the mirror lives in the routes layer, and
        # importing it here would tie the worker to the web app.
        self.mirror = mirror
        self._stop = threading.Event()
        self._threads: list[threading.Thread] = []

    def start(self) -> None:
        if self._threads:
            return
        for n, (lane, kinds) in enumerate(LANES):
            # Each thread leases under its own name, so a stuck one is identifiable in
            # the job table rather than hidden behind a name three others share.
            who = f"{self.name}-{lane}{n}"
            thread = threading.Thread(
                target=self._run, args=(who, kinds), name=who, daemon=True)
            thread.start()
            self._threads.append(thread)
        log.info("direct worker started (%d lanes)", len(self._threads))

    def stop(self) -> None:
        self._stop.set()

    def _run(self, who: str, kinds: tuple[str, ...]) -> None:
        while not self._stop.is_set():
            worked = False
            for kind in kinds:
                try:
                    leased = jobs.lease(who, kind=kind, limit=1)
                except Exception as e:                 # database restarting, say
                    log.warning("lease failed: %s", e)
                    self._stop.wait(ERROR_SLEEP)
                    break
                for job in leased:
                    worked = True
                    try:
                        if kind == "refind":
                            self._refind(job)
                        elif kind == "shazam_match":
                            self._shazam(job)
                        elif kind == "mirror":
                            self._mirror(job)
                        elif kind == "follow_poll":
                            self._follow_poll(job)
                        else:
                            self._ingest(job)
                    except Exception as e:
                        # One job that goes wrong in a way nothing else caught must not
                        # take its lane down with it — the lane would stop leasing and
                        # that whole kind of work would quietly stop happening.
                        log.exception("job %s (%s) crashed: %s", job["id"], kind, e)
                        try:
                            jobs.fail(job["id"], f"{type(e).__name__}: {e}",
                                      retryable=True)
                        except Exception:
                            pass
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
            # Being told to slow down is not this track's fault.
            #
            # Bandcamp answered nine thousand queued downloads with 429 and every one
            # of them was written down as a failure and retried at once, which is a
            # very good way to stay rate-limited for the rest of the day. A wait, and
            # the attempt is not spent.
            if "429" in str(e) or "too many requests" in str(e).lower():
                jobs.hold(job["id"], HOLD_OFF_SECONDS,
                          f"{provider} asked us to slow down")
                log.info("%s is rate-limiting; holding off %ss",
                         provider, HOLD_OFF_SECONDS)
                self._stop.wait(HOLD_OFF_SECONDS)
                return
            jobs.fail(job["id"], f"{type(e).__name__}: {e}", retryable=True)
            log.warning("%s track %s crashed: %s", provider, track_id, e)

    def _refind(self, job: dict) -> None:
        """Another copy of a song whose copy has gone.

        Searching does not need the machine at home — only downloading does — so this
        runs here, and it runs by itself the moment a track's last source is proved
        dead rather than waiting for somebody to open a screen and press a button.
        """
        track_id = int(job["payload"]["track_id"])
        row = catalog.track_row(track_id)
        if not row:
            jobs.finish(job["id"])
            return
        try:
            found = refind.look(row)
        except Exception as e:
            jobs.fail(job["id"], f"{type(e).__name__}: {e}", retryable=True)
            return
        jobs.finish(job["id"])
        if found.get("found"):
            log.info("found %s again on %s", track_id, found.get("where"))
        else:
            db.run("""update tracks set state='failed',
                             fail_reason='Looked everywhere — no copy of this anywhere',
                             fail_code='no_source' where id=%s""", (track_id,))

    def _shazam(self, job: dict) -> None:
        """Find the next handful of tagged songs in the catalogue.

        A few at a time, queueing another when there are more left: a library of a
        thousand tags is a thousand searches, and one job that takes twenty minutes is
        one job that loses its lease halfway through and starts again from the top.
        """
        user_id = int(job["payload"]["user_id"])
        try:
            out = shazam.match_some(user_id)
        except Exception as e:
            jobs.fail(job["id"], f"{type(e).__name__}: {e}", retryable=True)
            return
        jobs.finish(job["id"])
        log.info("shazam: looked at %s, found %s, %s left",
                 out["looked_at"], out["found"], out["left"])
        if out["left"]:
            jobs.enqueue("shazam_match", {"user_id": user_id},
                         priority=jobs.PRIORITY_BULK)

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
