"""How loud each record is, as this box measured it.

Every record is measured here — EBU R128 through ffmpeg: its integrated loudness, the gain
that brings it to TARGET_LUFS, and its true peak (how far a quiet record can be turned up
before it clips). The players and the booth turn records by `gain_db` so one song does not
come in four decibels louder than the last; nothing is baked into the file.

A record is measured as soon as it is added, whoever added it — a computer in the pool
says what it measured, and that stands until the box has measured the file itself. One
fetched (streamed, put on a deck) that the box has not measured yet is measured at once,
ahead of everything else. And the rest of the library is worked through quietly, one record
at a time at the lowest priority, so a library from before this, or one measured by
somebody else's computer, comes to be measured the same way: the box's numbers, the box's
version of the measure (VERSION), for every record.
"""
from __future__ import annotations

import collections
import logging
import pathlib
import re
import shutil
import subprocess
import threading

from . import db

log = logging.getLogger("muse.loudness")

TARGET_LUFS = -14.0
# The measure's version: a change to how it is taken (or what is kept) bumps it, and the
# library is measured again by it.
VERSION = 1

FFMPEG = shutil.which("ffmpeg") or "ffmpeg"
NICE = shutil.which("nice")
_LUFS = re.compile(r"^\s*I:\s*(-?\d+(?:\.\d+)?)\s*LUFS", re.M)
_PEAK = re.compile(r"True peak:\s*\n\s*Peak:\s*(-?(?:\d+(?:\.\d+)?|inf))\s*dBFS", re.M)

# Between records while the library is worked through, and between looks when it is done.
BETWEEN = 0.5
IDLE = 300.0


def gain_for(lufs: float | None) -> float | None:
    return None if lufs is None else round(TARGET_LUFS - lufs, 2)


def measure(path: pathlib.Path, nice: bool = False, timeout: float = 600) -> dict | None:
    """The record at [path] measured: {lufs, gain_db, true_peak_db}; None where ffmpeg
    cannot read it or hears nothing to measure (silence has no integrated loudness)."""
    cmd = [FFMPEG, "-nostats", "-hide_banner", "-i", str(path),
           "-af", "ebur128=framelog=quiet:peak=true", "-f", "null", "-"]
    if nice and NICE:
        cmd = [NICE, "-n", "19", *cmd]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except (subprocess.TimeoutExpired, OSError) as e:
        log.warning("could not measure %s: %s", path, e)
        return None
    m = _LUFS.search(r.stderr or "")
    if not m:
        return None
    lufs = float(m.group(1))
    # Below the gate there is nothing to measure: ffmpeg says -70.
    if lufs <= -70:
        return None
    p = _PEAK.search(r.stderr or "")
    peak = float(p.group(1)) if p and p.group(1) != "inf" else None
    if peak is not None and peak == float("-inf"):
        peak = None
    return {"lufs": round(lufs, 2), "gain_db": gain_for(lufs), "true_peak_db": None if peak is None else round(peak, 2)}


def remember(track_id: int, m: dict | None) -> None:
    """What the box measured, kept on the record — or, where nothing could be measured,
    that it was tried (the provisional numbers left as they are, and not tried again
    until the measure changes)."""
    if m is None:
        db.run("update tracks set loudness_at = now(), loudness_version = %s where id = %s", (VERSION, track_id))
        return
    db.run(
        """update tracks set loudness_lufs = %s, gain_db = %s, true_peak_db = %s,
                  loudness_at = now(), loudness_version = %s
            where id = %s""",
        (m["lufs"], m["gain_db"], m["true_peak_db"], VERSION, track_id))


def measure_track(track_id: int, nice: bool = True) -> bool:
    """The record's own file measured and the numbers kept. False where it has no file."""
    t = db.one(
        """select m.path from tracks t join media m on m.track_id = t.id and m.role = 'canonical'
            where t.id = %s and t.state = 'ready'""", (track_id,))
    if not t or not t.get("path"):
        return False
    remember(track_id, measure(pathlib.Path(t["path"]), nice=nice))
    return True


# ------------------------------------------------------------------ soon, and the rest

_soon: collections.OrderedDict[int, None] = collections.OrderedDict()
_lock = threading.Lock()
_wake = threading.Event()


def soon(track_id: int) -> None:
    """[track_id] measured ahead of everything else (just added, or fetched unmeasured)."""
    with _lock:
        _soon[track_id] = None
        _soon.move_to_end(track_id)
    _wake.set()


def unmeasured(t: dict | None) -> bool:
    """Whether a record (a tracks row) has not been measured by this box's measure yet."""
    return bool(t) and t.get("loudness_version") != VERSION


def _next_soon() -> int | None:
    with _lock:
        if not _soon:
            return None
        k, _ = _soon.popitem(last=False)
        return k


def one() -> bool:
    """Measure the next record: one asked for soon, else the newest the box has not
    measured. True if there was one."""
    k = _next_soon()
    if k is not None:
        measure_track(k, nice=False)
        return True
    t = db.one(
        """select t.id from tracks t
             join media m on m.track_id = t.id and m.role = 'canonical'
            where t.state = 'ready' and (t.loudness_version is null or t.loudness_version < %s)
            order by t.id desc limit 1""", (VERSION,))
    if not t:
        return False
    if not measure_track(t["id"], nice=True):
        remember(t["id"], None)
    return True


class LoudnessWorker:
    def __init__(self, cfg, start_after: float = 30.0):
        self.cfg = cfg
        self.start_after = start_after
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None

    def start(self) -> None:
        if self._thread:
            return
        self._thread = threading.Thread(target=self._run, name="loudness", daemon=True)
        self._thread.start()
        log.info("loudness measuring started")

    def stop(self) -> None:
        self._stop.set()
        _wake.set()

    def _run(self) -> None:
        # The ones asked for soon at once; the sweep not in the first half minute
        _wake.wait(self.start_after)
        while not self._stop.is_set():
            _wake.clear()
            try:
                worked = one()
            except Exception as e:                       # noqa: BLE001 — database restarting, say
                log.warning("loudness measuring paused: %s", e)
                worked = False
            with _lock:
                pending = bool(_soon)
            if pending:
                continue
            _wake.wait(BETWEEN if worked else IDLE)
