"""Reading whole records a little at a time: one record is never worked out twice at
once, only so many at a time, and a request that cannot get its turn is told to come
back rather than piling up — which is what killed the server for want of memory."""
from __future__ import annotations

import io
import subprocess
import threading
import time

from muse import beats, heavy


def test_one_record_asked_for_at_once_is_worked_out_once(tmp_path, monkeypatch):
    calls = []

    def slow(audio):
        calls.append(audio)
        time.sleep(0.3)
        return {"bpm": 120.0, "beats": []}

    monkeypatch.setattr(beats, "measure", slow)
    got = []
    threads = [threading.Thread(target=lambda: got.append(
        beats.for_track(tmp_path, tmp_path / "a.m4a", "same-sha"))) for _ in range(6)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert len(calls) == 1, "the others waited and read the answer from disk"
    assert len(got) == 6 and all(g["bpm"] == 120.0 for g in got)


def test_no_more_than_so_many_at_once(tmp_path, monkeypatch):
    running = []
    most = []

    def slow(audio):
        running.append(1)
        most.append(len(running))
        time.sleep(0.2)
        running.pop()
        return {"bpm": 1.0}

    monkeypatch.setattr(beats, "measure", slow)
    threads = [threading.Thread(target=beats.for_track,
                                args=(tmp_path, tmp_path / f"{i}.m4a", f"sha-{i}"))
               for i in range(8)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert max(most) <= heavy.AT_ONCE


def test_a_request_without_a_turn_is_told_to_come_back(client, hdr, tmp_path, monkeypatch):
    f = tmp_path / "t.m4a"
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i",
                    "sine=frequency=440:duration=3", "-c:a", "aac", str(f)], check=True)
    track = client.post("/uploads", headers=hdr, files={
        "audio": ("t.m4a", io.BytesIO(f.read_bytes()), "audio/mp4")}).json()
    # Every turn taken.
    monkeypatch.setattr(heavy, "_turns", threading.BoundedSemaphore(1))
    heavy._turns.acquire()
    real = heavy.turn
    monkeypatch.setattr(heavy, "turn", lambda key, wait=20.0: real(key, wait=0.2))
    r = client.get(f"/tracks/{track['id']}/analysis", headers=hdr)
    assert r.status_code == 503 and r.headers.get("Retry-After")
    heavy._turns.release()
