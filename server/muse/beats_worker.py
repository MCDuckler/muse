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

from . import beats, db, traits

log = logging.getLogger("muse.beats")

# Between songs when there is work, and between looks when there is none.
BETWEEN = 2.5
IDLE = 120.0


def one(data_dir: pathlib.Path) -> bool:
    """Analyse the next song that has not been, if there is one. True if there was."""
    # Never looked at, or looked at by an older reading than the one running now.
    #
    # The second half is what makes a change to [beats] reach a library rather than
    # only the songs somebody happens to play afterwards. The measurement is cached
    # under its version ([beats.cache_path]), so a bump already means the next reading
    # is a fresh one — but nothing was asking for it: this query only ever looked at
    # songs with no reading at all, and every song in the library has one. A whole
    # library would have kept the tempo an older version gave it for ever.
    #
    # Never-analysed first, so a song somebody just added is not queued behind five
    # thousand re-readings.
    t = db.one(
        """select t.id, t.loudness_lufs, m.path, m.sha256
             from tracks t
             join media m on m.track_id = t.id and m.role = 'canonical'
            where t.state = 'ready' and m.sha256 is not null
              and (t.analysed_at is null or t.beats_version is distinct from %s)
            order by t.analysed_at is not null, t.id desc limit 1""",
        (beats.VERSION,))
    if not t:
        return False
    bpm = None
    try:
        found = beats.for_track(data_dir, pathlib.Path(t["path"]), t["sha256"], wait=None)
        bpm = found.get("bpm")
        # Its row in the booth's index too, so a record fetched today is one a set
        # built from the library can choose — not only once somebody has opened it.
        try:
            traits.remember(t, found)
        except Exception as e:                           # noqa: BLE001
            log.warning("could not index track %s for the booth: %s", t["id"], e)
    except Exception as e:                               # noqa: BLE001
        # A file that cannot be read is marked as looked at all the same: it will not
        # be readable next time either, and it must not be the only song ever tried.
        log.warning("could not analyse track %s: %s", t["id"], e)
    db.run("update tracks set bpm = %s, analysed_at = now(), beats_version = %s where id = %s",
           (bpm, beats.VERSION, t["id"]))
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
