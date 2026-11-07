"""The playback queues' songs fetched to the box without anybody asking.

A song added to a queue is fetched at once (routes_library.queue_add, replace_queue). This
is the net under that: every couple of minutes, each queue used lately is looked down from
the song playing, and any song in it still waiting for its audio — one a station's radio
put there, one from before this, one whose job was lost — gets its job, ahead of the
downloads nobody is waiting on (jobs.fetch_queues_ahead).
"""
from __future__ import annotations

import logging
import threading

from . import jobs

log = logging.getLogger("muse.queue_fetch")

EVERY = 120.0


class QueueFetcher:
    def __init__(self, cfg, first_after: float = 20.0):
        self.cfg = cfg
        self.first_after = first_after
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None

    def start(self) -> None:
        if self._thread:
            return
        self._thread = threading.Thread(target=self._run, name="queue-fetch", daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()

    def _run(self) -> None:
        if self._stop.wait(self.first_after):
            return
        while not self._stop.is_set():
            try:
                n = jobs.fetch_queues_ahead()
                if n:
                    log.info("%d songs in playback queues sent to be fetched", n)
            except Exception as e:                       # noqa: BLE001 — database restarting, say
                log.warning("looking down the queues paused: %s", e)
            self._stop.wait(EVERY)
