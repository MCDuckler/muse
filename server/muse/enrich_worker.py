"""In-process worker for `meta` jobs.

Ingest needs a residential IP; artwork does not. Running enrichment inside the API
means covers keep arriving while the laptop is asleep, and it reuses the same Postgres
job queue rather than inventing a second mechanism.
"""
from __future__ import annotations

import logging
import threading
import time

from . import enrich, jobs

log = logging.getLogger("muse.enrich")

IDLE_SLEEP = 5.0
ERROR_SLEEP = 30.0


class EnrichWorker:
    def __init__(self, cfg, name: str = "api-enrich"):
        self.cfg = cfg
        self.name = name
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None

    def start(self) -> None:
        if self._thread:
            return
        self._thread = threading.Thread(target=self._run, name=self.name, daemon=True)
        self._thread.start()
        log.info("enrichment worker started")

    def stop(self) -> None:
        self._stop.set()

    def _run(self) -> None:
        while not self._stop.is_set():
            try:
                leased = jobs.lease(self.name, kind="meta", limit=1)
            except Exception as e:                     # database restarting, say
                log.warning("lease failed: %s", e)
                self._stop.wait(ERROR_SLEEP)
                continue
            if not leased:
                self._stop.wait(IDLE_SLEEP)
                continue
            for job in leased:
                self._handle(job)

    def _handle(self, job: dict) -> None:
        track_id = job["payload"].get("track_id")
        started = time.monotonic()
        try:
            result = enrich.enrich_track(self.cfg, track_id)
            jobs.finish(job["id"])
            log.info("enriched track %s in %.1fs: %s",
                     track_id, time.monotonic() - started, result)
        except Exception as e:
            # A missing cover is not worth retrying forever; a network blip is.
            retryable = not isinstance(e, (ValueError, KeyError))
            jobs.fail(job["id"], f"{type(e).__name__}: {e}", retryable=retryable)
            log.warning("enrich failed for track %s: %s", track_id, e)
