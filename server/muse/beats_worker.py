"""Listening to the library for its beats, in the background.

A song is analysed the first time somebody plays it, which is right for playing it — but
it means the library only knows the tempo of what has been played since this existed,
and "sort by tempo" or "something slow" would be a list of the last week's listening.
So the rest is worked through quietly: one song at a time, newest first, with a pause
between them so that a small server stays a server and not an analysis machine. Half a
second of work every few seconds gets through five thousand songs in an evening.

Nothing depends on it having finished. A song it has not reached has no tempo yet and is
simply left out of anything that asks for one.
"""
from __future__ import annotations

import logging
import pathlib
import threading

from . import beats, db

log = logging.getLogger("muse.beats")

# Between songs when there is work, and between looks when there is none.
BETWEEN = 2.5
IDLE = 120.0


def one(data_dir: pathlib.Path) -> bool:
    """Analyse the next song that has not been, if there is one. True if there was."""
    t = db.one(
        """select t.id, m.path, m.sha256
             from tracks t
             join media m on m.track_id = t.id and m.role = 'canonical'
            where t.state = 'ready' and t.analysed_at is null and m.sha256 is not null
            order by t.id desc limit 1""")
    if not t:
        return False
    bpm = None
    try:
        found = beats.for_track(data_dir, pathlib.Path(t["path"]), t["sha256"], wait=None)
        bpm = found.get("bpm")
    except Exception as e:                               # noqa: BLE001
        # A file that cannot be read is marked as looked at all the same: it will not
        # be readable next time either, and it must not be the only song ever tried.
        log.warning("could not analyse track %s: %s", t["id"], e)
    db.run("update tracks set bpm = %s, analysed_at = now() where id = %s", (bpm, t["id"]))
    return True


class BeatsWorker:
    def __init__(self, cfg):
        self.cfg = cfg
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None

    def start(self) -> None:
        if self._thread:
            return
        self._thread = threading.Thread(target=self._run, name="beats", daemon=True)
        self._thread.start()
        log.info("beat analysis started")

    def stop(self) -> None:
        self._stop.set()

    def _run(self) -> None:
        # Not in the first minute: a server that has just come up has better things to do.
        if self._stop.wait(60):
            return
        while not self._stop.is_set():
            try:
                worked = one(self.cfg.data_dir)
            except Exception as e:                       # noqa: BLE001 — database restarting, say
                log.warning("beat analysis paused: %s", e)
                worked = False
            self._stop.wait(BETWEEN if worked else IDLE)
