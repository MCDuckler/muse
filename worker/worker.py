#!/usr/bin/env python3
"""muse ingest worker.

Runs where the IP is residential. Leases jobs over an outbound HTTPS call, so the
machine it lives on needs no open port, no tunnel and no static IP — which is also
why moving it from this laptop to a Pi is a `docker run` elsewhere and nothing else.

Proven invocation (see NOTES.md):
    yt-dlp --js-runtimes node -f 140 -o "<id>.%(ext)s" https://music.youtube.com/watch?v=<id>
"""
from __future__ import annotations

import json
import os
import pathlib
import platform
import re
import shutil
import subprocess
import sys
import fcntl
import signal
import tempfile
import threading
import time
from concurrent.futures import Future, ThreadPoolExecutor

import httpx

API = os.environ.get("MUSE_API", "http://127.0.0.1:8770").rstrip("/")
SECRET = os.environ.get("MUSE_WORKER_SECRET", "")
NAME = os.environ.get("MUSE_WORKER_NAME", platform.node())
YTDLP = os.environ.get("MUSE_YTDLP", str(pathlib.Path(__file__).parent / ".venv/bin/yt-dlp"))
FFMPEG = shutil.which("ffmpeg") or "ffmpeg"
FFPROBE = shutil.which("ffprobe") or "ffprobe"
POLL_SECONDS = float(os.environ.get("MUSE_POLL", "5"))
# How many songs at once. One at a time made a 1300-track import an overnight job while
# the connection sat mostly idle: a download is nearly all waiting. Three keeps the
# residential IP looking like a person rather than a scraper; raise it if you dare.
CONCURRENCY = max(1, int(os.environ.get("MUSE_CONCURRENCY", "3")))
CURRENT_SLOTS = CONCURRENCY
TARGET_LUFS = -14.0

# Contingencies, off by default — the spike downloaded fine without either.
# Set them the day downloads start failing; see NOTES.md.
COOKIES = os.environ.get("MUSE_COOKIES")           # path to cookies.txt
# always   — every request signed in (fastest while the IP is challenged)
# fallback — anonymous first, signed in only for the tracks that get challenged
# never    — anonymous only, and accept what that costs
COOKIES_MODE = os.environ.get("MUSE_COOKIES_MODE", "fallback" if COOKIES else "never")
POT_PROVIDER = os.environ.get("MUSE_POT_BASE_URL")  # bgutil provider base url

H = {"X-Worker-Secret": SECRET}

# Downloads run this many at a time, stepping down when YouTube pushes back and back
# up once it stops. Starts at whatever CONCURRENCY says.
COOLDOWN_UNTIL = 0.0
STREAK = 0
RATE_LOCK = threading.Lock()

# What this process currently has leased, so a shutdown can give it back instead of
# leaving it locked for the ten minutes a lease lasts.
INFLIGHT: dict[int, int | None] = {}
# Jobs somebody is waiting for right now, as opposed to a backfill. While one is in
# flight the worker stops taking bulk work: the line is only so wide, and a song
# somebody pressed play on should not queue behind a hundred imports for it.
URGENT_PRIORITY = 90
URGENT: set[int] = set()
INFLIGHT_LOCK = threading.Lock()
STOPPING = threading.Event()

# Errors that will still be errors in five minutes. Retrying these wastes requests
# against the one thing worth protecting: an unchallenged residential IP.
TERMINAL_ERRORS = (
    "unavailable", "not available", "private video", "removed by the uploader",
    "members-only", "age-restricted", "copyright", "does not exist",
)

# Not a property of the track: the IP has been challenged. Failing the song for this
# would mark a perfectly good track dead because we asked too fast. Give the job back,
# stop asking for a while, and download fewer at a time from here on.
BOT_CHECK = ("sign in to confirm you're not a bot", "sign in to confirm you\u2019re not a bot",
             "not a bot", "po token", "login_required")

# This one *is* about the track. It reads almost identically to a bot check — "Sign in
# to confirm your age" against "Sign in to confirm you're not a bot" — and lumping them
# together cost hours: one age-restricted video put the worker into a ten-minute
# cooldown, handed the job back, picked it up again, and did the same thing all night.
AGE_CHECK = ("confirm your age", "age-restricted", "age restricted")

# YouTube saying "slow down". It arrives as a warning while the visible error becomes
# "Video unavailable", which is how a rate limit came to permanently kill a hundred and
# fifteen perfectly good tracks: the symptom was classified, not the cause.
RATE_LIMITED = ("http error 429", "too many requests")
COOLDOWN_SECONDS = float(os.environ.get("MUSE_COOLDOWN", "600"))
_LUFS = re.compile(r"^\s*I:\s*(-?\d+\.?\d*)\s*LUFS", re.M)


def log(*a):
    print(f"[{time.strftime('%H:%M:%S')}]", *a, flush=True)


def ytdlp_args(video_id: str, out: pathlib.Path,
               cookies: pathlib.Path | None = None) -> list[str]:
    args = [
        YTDLP, "--js-runtimes", "node",       # node satisfies the JS runtime; no deno needed
        "-f", "140/bestaudio[acodec^=mp4a]/bestaudio",
        # Warnings stay on: YouTube's "HTTP Error 429" arrives as one, while the error
        # that follows it says "Video unavailable". Hiding warnings meant reading the
        # symptom and writing off tracks that were only being throttled.
        "--no-playlist",
        "-o", str(out / "%(id)s.%(ext)s"),
        # A machine-readable progress line, so the app can show a real bar instead of
        # a spinner that means "something is happening, for some length of time".
        "--newline",
        "--progress-template",
        "MUSEPROGRESS %(progress._percent_str)s %(progress._speed_str)s",
        f"https://music.youtube.com/watch?v={video_id}",
    ]
    if cookies:
        args[1:1] = ["--cookies", str(cookies)]
    if POT_PROVIDER:
        args[1:1] = ["--extractor-args", f"youtubepot-bgutilhttp:base_url={POT_PROVIDER}"]
    return args


def probe(path: pathlib.Path) -> dict:
    out = subprocess.run(
        [FFPROBE, "-v", "error", "-show_entries",
         "format=duration,bit_rate:stream=codec_name,sample_rate,channels",
         "-of", "json", str(path)],
        capture_output=True, text=True, check=True,
    ).stdout
    d = json.loads(out)
    st = (d.get("streams") or [{}])[0]
    fmt = d.get("format", {})
    return {
        "codec": st.get("codec_name"),
        "bitrate": int(fmt["bit_rate"]) if fmt.get("bit_rate") else None,
        "duration_ms": int(float(fmt["duration"]) * 1000) if fmt.get("duration") else None,
    }


def loudness(path: pathlib.Path) -> tuple[float | None, float | None]:
    """Measure only. Never bake gain into the file — the client applies it."""
    r = subprocess.run(
        [FFMPEG, "-nostats", "-hide_banner", "-i", str(path),
         "-af", "ebur128=framelog=quiet", "-f", "null", "-"],
        capture_output=True, text=True,
    )
    m = _LUFS.search(r.stderr)
    if not m:
        return None, None
    lufs = float(m.group(1))
    return lufs, round(TARGET_LUFS - lufs, 2)


def to_m4a(src: pathlib.Path) -> pathlib.Path:
    """itag 140 is already AAC in m4a, so the common path never gets here."""
    if src.suffix == ".m4a":
        return src
    dst = src.with_suffix(".m4a")
    subprocess.run([FFMPEG, "-v", "error", "-y", "-i", str(src),
                    "-c:a", "aac", "-b:a", "160k", str(dst)], check=True)
    src.unlink(missing_ok=True)
    return dst


_PERCENT = re.compile(r"MUSEPROGRESS\s+([\d.]+)%\s+(\S+)")


def cookie_copy(tmp_dir: pathlib.Path) -> pathlib.Path | None:
    """Each download gets its own copy of the cookie jar.

    yt-dlp writes refreshed cookies back to the file it was given, and several
    downloads running at once would write over each other. The master jar is only
    ever read; run-local.sh refreshes it from the browser.
    """
    if not COOKIES:
        return None
    dst = tmp_dir / "cookies.txt"
    shutil.copyfile(COOKIES, dst)
    return dst


def download_with_progress(video_id: str, tmp_dir: pathlib.Path, report,
                           signed_in: bool = False) -> tuple[int, str, bool]:
    """Run yt-dlp, forwarding progress as it goes.

    Returns (exit code, last error, was rate limited). The last part is separate because
    the 429 arrives as a warning and the error that follows says something else
    entirely.
    """
    proc = subprocess.Popen(
        ytdlp_args(video_id, tmp_dir,
                   cookies=cookie_copy(tmp_dir) if signed_in else None),
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1,
    )
    last_report, last_error, rate_limited = 0.0, "", False
    for line in proc.stdout or []:
        line = line.strip()
        if any(s in line.lower() for s in RATE_LIMITED):
            rate_limited = True
        if m := _PERCENT.match(line):
            now = time.monotonic()
            # Once a second is enough: this crosses the network to a server that then
            # fans it out to every open client.
            if now - last_report >= 1.0:
                last_report = now
                report(float(m.group(1)) / 100.0, m.group(2))
        elif line and not line.startswith("[") and "MUSEPROGRESS" not in line:
            last_error = line
        elif line.startswith("ERROR"):
            last_error = line
    proc.wait()
    return proc.returncode, last_error, rate_limited


def handle(client: httpx.Client, job: dict) -> None:
    payload = job["payload"]
    video_id, track_id = payload["video_id"], payload["track_id"]

    def report(stage: str, percent: float | None = None, speed: str | None = None):
        try:
            client.post(f"{API}/internal/jobs/{job['id']}/progress", headers=H,
                        json={"track_id": track_id, "stage": stage,
                              "percent": percent, "speed": speed}, timeout=10)
        except httpx.HTTPError:
            pass          # progress is a courtesy; never fail a download over it

    with tempfile.TemporaryDirectory(prefix="muse-") as tmp:
        tmp_dir = pathlib.Path(tmp)
        log(f"job {job['id']} track {track_id} {video_id} downloading")
        report("downloading", 0.0)
        on_progress = lambda pct, speed: report("downloading", pct, speed)   # noqa: E731

        # An account is worth spending only on the tracks that need one. Anonymous
        # first; if YouTube asks us to prove we are a person, ask again signed in.
        signed_in = COOKIES_MODE == "always"
        code, error_line, throttled = download_with_progress(
            video_id, tmp_dir, on_progress, signed_in=signed_in)
        if code != 0 and not throttled and COOKIES_MODE == "fallback" and not signed_in:
            # Ask again signed in, whatever went wrong. "Video unavailable" is what a
            # track that is merely age-gated or region-locked looks like to nobody in
            # particular, and only trying again on an explicit bot check meant a
            # hundred perfectly downloadable songs were written off in one go.
            for stale in tmp_dir.iterdir():
                stale.unlink(missing_ok=True)
            signed_in = True
            code, error_line, throttled = download_with_progress(
                video_id, tmp_dir, on_progress, signed_in=True)

        files = sorted(p for p in tmp_dir.iterdir()
                       if p.is_file() and p.suffix not in (".json", ".txt"))
        if code != 0 or not files:
            reason = (error_line or "yt-dlp failed")[:500]
            lowered = reason.lower()
            if throttled:
                # Give it back and stop asking. Nothing is wrong with the track.
                back_off("YouTube is rate-limiting this IP (HTTP 429)")
                client.post(f"{API}/internal/jobs/{job['id']}/release", headers=H,
                            json={"track_id": track_id})
                return
            if any(s in lowered for s in AGE_CHECK):
                log.info(f"job {job['id']} needs an age-verified account: {video_id}")
                client.post(f"{API}/internal/jobs/{job['id']}/fail", headers=H,
                            json={"reason": "YouTube wants an age-verified account for "
                                            "this one — it will not download here.",
                                  "retryable": False, "track_id": track_id})
                return
            if any(s in lowered for s in BOT_CHECK):
                # Nothing wrong with the track. Give it back, and slow down.
                back_off(reason)
                client.post(f"{API}/internal/jobs/{job['id']}/release", headers=H,
                            json={"track_id": track_id})
                return
            retryable = not any(s in reason.lower() for s in TERMINAL_ERRORS)
            log(f"job {job['id']} FAILED: {reason}")
            client.post(f"{API}/internal/jobs/{job['id']}/fail", headers=H,
                        json={"reason": reason, "retryable": retryable, "track_id": track_id})
            return

        if files[0].suffix != ".m4a":
            report("converting", 0.0)
        audio = to_m4a(files[0])
        report("measuring")
        info = probe(audio)
        lufs, gain = loudness(audio)
        report("uploading")
        meta = {"track_id": track_id, "video_id": video_id, **info,
                "loudness_lufs": lufs, "gain_db": gain}
        with audio.open("rb") as fh:
            resp = client.post(
                f"{API}/internal/jobs/{job['id']}/complete", headers=H,
                data={"meta": json.dumps(meta)},
                files={"audio": (audio.name, fh, "audio/mp4")}, timeout=300,
            )
        resp.raise_for_status()
        mb = resp.json()["bytes"] / 1e6
        log(f"job {job['id']} ready {mb:.1f} MB  {info['codec']} {info['bitrate']}  "
            f"{lufs} LUFS gain {gain} dB")
        went_well()
    # tmp dir is gone here: this box's disk is not the archive


def back_off(reason: str) -> None:
    """YouTube challenged us. Download fewer at once, and stop for a while."""
    global COOLDOWN_UNTIL, STREAK, CURRENT_SLOTS
    with RATE_LOCK:
        STREAK = 0
        COOLDOWN_UNTIL = time.monotonic() + COOLDOWN_SECONDS
        if CURRENT_SLOTS > 1:
            CURRENT_SLOTS -= 1
        slots = CURRENT_SLOTS
    log(f"bot check — pausing {COOLDOWN_SECONDS / 60:.0f} min, "
        f"then {slots} at a time: {reason[:120]}")


def went_well() -> None:
    """A long run of successes earns a slot back, up to what was configured."""
    global STREAK, CURRENT_SLOTS
    with RATE_LOCK:
        STREAK += 1
        if STREAK >= 60 and CURRENT_SLOTS < CONCURRENCY:
            CURRENT_SLOTS += 1
            STREAK = 0
            log(f"steady for 60 downloads — back up to {CURRENT_SLOTS} at a time")


def heartbeat(client: httpx.Client, busy: int) -> None:
    """Say we are alive while every slot is busy.

    The server marks a worker offline after 90 s without a lease, and a worker with all
    three slots full does not lease. A zero-limit lease is the same round trip, minus
    the work.
    """
    try:
        client.post(f"{API}/internal/jobs/lease", headers=H,
                    json={"worker": NAME, "kind": "ingest", "limit": 0, "busy": busy},
                    timeout=15)
    except httpx.HTTPError:
        pass


def run_job(client: httpx.Client, job: dict) -> None:
    """One job, start to finish, on its own thread. Never raises."""
    with INFLIGHT_LOCK:
        INFLIGHT[job["id"]] = job["payload"].get("track_id")
        if (job.get("priority") or 100) <= URGENT_PRIORITY:
            URGENT.add(job["id"])
    try:
        handle(client, job)
    except Exception as e:
        log(f"job {job['id']} crashed: {e}")
        try:
            client.post(f"{API}/internal/jobs/{job['id']}/fail", headers=H,
                        json={"reason": str(e)[:500], "retryable": True,
                              "track_id": job["payload"].get("track_id")})
        except httpx.HTTPError:
            pass          # the lease expires by itself; the job comes back
    finally:
        with INFLIGHT_LOCK:
            INFLIGHT.pop(job["id"], None)
            URGENT.discard(job["id"])


def take_the_lock() -> "object":
    """Refuse to start if another worker is already running.

    Two of these on one machine is not twice the speed — it is twice the requests from
    one IP, which is how YouTube starts answering 429 to all of them. It has happened
    more than once by accident: a restart that killed the supervisor and left the
    worker behind, then started a second one beside it. The lock makes that impossible
    rather than merely unlikely.
    """
    lock_path = pathlib.Path(os.environ.get("MUSE_WORKER_LOCK",
                                            "/tmp/muse-worker.lock"))
    handle = lock_path.open("a+")
    try:
        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        handle.seek(0)
        who = handle.read().strip() or "another process"
        sys.exit(f"A muse worker is already running (pid {who}). "
                 f"Stop that one first — two workers means twice the requests from "
                 f"this IP, and YouTube counts.")
    handle.seek(0)
    handle.truncate()
    handle.write(f"{os.getpid()}\n")
    handle.flush()
    return handle                        # held open: closing it would free the lock


def give_back_everything() -> None:
    """Return leased jobs on the way out, so a restart does not stall the queue."""
    with INFLIGHT_LOCK:
        jobs = dict(INFLIGHT)
    if not jobs:
        return
    log(f"releasing {len(jobs)} unfinished job(s)")
    with httpx.Client(timeout=10) as client:
        for job_id, track_id in jobs.items():
            try:
                client.post(f"{API}/internal/jobs/{job_id}/release", headers=H,
                            json={"track_id": track_id})
            except httpx.HTTPError:
                pass      # the lease still expires on its own; this is the fast path


def main() -> None:
    if not SECRET:
        sys.exit("MUSE_WORKER_SECRET is unset — the server would reject every lease")
    _lock = take_the_lock()                                     # noqa: F841
    log(f"worker {NAME} → {API}  (up to {CONCURRENCY} at a time, "
        f"cookies={COOKIES_MODE if COOKIES else 'no'}, "
        f"pot={'yes' if POT_PROVIDER else 'no'})")
    if not COOKIES:
        log("no cookies: YouTube challenges this IP after a few hundred downloads")
    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, lambda *_: STOPPING.set())
    running: set[Future] = set()
    last_beat = 0.0
    with httpx.Client(timeout=60) as client, \
            ThreadPoolExecutor(max_workers=CONCURRENCY,
                               thread_name_prefix="ingest") as pool:
        while not STOPPING.is_set():
            running = {f for f in running if not f.done()}
            with RATE_LOCK:
                cooling = max(0.0, COOLDOWN_UNTIL - time.monotonic())
                free = CURRENT_SLOTS - len(running)
            if cooling and not running:
                # Serving out a bot-check cooldown. Stay visibly alive; ask for nothing.
                if time.monotonic() - last_beat > 15:
                    last_beat = time.monotonic()
                    heartbeat(client, 0)
                time.sleep(min(cooling, 5))
                continue
            if cooling:
                free = 0
            if free <= 0:
                # Every slot busy. Do not lease what cannot be started.
                if time.monotonic() - last_beat > 15:
                    last_beat = time.monotonic()
                    heartbeat(client, len(running))
                time.sleep(1)
                continue
            with INFLIGHT_LOCK:
                waiting_on = len(URGENT)
            try:
                # Long poll: the server holds the request until work appears, so a
                # queued track starts downloading immediately instead of waiting out
                # a poll interval. Held shorter while downloads are in flight, so a
                # slot that frees up is filled promptly rather than after the wait.
                jobs = client.post(f"{API}/internal/jobs/lease", headers=H,
                                   json={"worker": NAME, "kind": "ingest",
                                         "limit": free, "busy": len(running),
                                         # Somebody is waiting: take nothing but more
                                         # of the same until they have their song.
                                         **({"max_priority": URGENT_PRIORITY}
                                            if waiting_on else {}),
                                         "wait": 5 if running else 25},
                                   timeout=40).json()["jobs"]
                last_beat = time.monotonic()
            except Exception as e:                       # server down / restarting
                log(f"lease failed: {e}")
                time.sleep(POLL_SECONDS * 2)
                continue
            if not jobs:
                continue          # the wait already happened server-side
            if len(jobs) > 1:
                log(f"leased {len(jobs)} jobs ({len(running)} already running)")
            for job in jobs:
                running.add(pool.submit(run_job, client, job))

        # Leaving the `with` would wait for every download in flight, which is the one
        # thing a shutdown should not do: hand the jobs back and go.
        give_back_everything()
        log("stopped")
        os._exit(0)


if __name__ == "__main__":
    main()
