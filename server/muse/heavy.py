"""Work that reads a whole record into memory — its beats, its waveform, its voice —
done a little at a time.

Each is a few hundred megabytes while it runs (a four minute record's beats: 230 MB at
its peak), and each was done on the request that asked for it, in as many threads at
once as there were requests. A booth looking down a long queue asked for dozens at a
time, and the server grew past its eight gigabytes and was killed — eight times in an
afternoon, each a burst of 502s that lost whatever was being handed in.

So: at most [AT_ONCE] at a time, and one record never twice at once (the second to
ask waits for the first's answer, which is then on disk). A request that cannot get
its turn soon is told to come back (Busy → 503 with Retry-After) rather than held.
"""
from __future__ import annotations

import contextlib
import threading

AT_ONCE = 2

_turns = threading.BoundedSemaphore(AT_ONCE)
_records = [threading.Lock() for _ in range(64)]


class Busy(Exception):
    """Every turn is taken and has been for a while: ask again shortly."""


@contextlib.contextmanager
def turn(key: str, wait: float | None = 20.0):
    """Hold one of the turns, and the lock of [key], for the work in the block.
    [wait] None waits for as long as it takes (the background worker)."""
    record = _records[hash(key) % len(_records)]
    if not record.acquire(timeout=-1 if wait is None else wait):
        raise Busy(key)
    try:
        if not _turns.acquire(timeout=-1 if wait is None else wait):
            raise Busy(key)
        try:
            yield
        finally:
            _turns.release()
    finally:
        record.release()
