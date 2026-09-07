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
import tempfile
import time

import httpx

API = os.environ.get("MUSE_API", "http://127.0.0.1:8770").rstrip("/")
SECRET = os.environ.get("MUSE_WORKER_SECRET", "")
NAME = os.environ.get("MUSE_WORKER_NAME", platform.node())
YTDLP = os.environ.get("MUSE_YTDLP", str(pathlib.Path(__file__).parent / ".venv/bin/yt-dlp"))
FFMPEG = shutil.which("ffmpeg") or "ffmpeg"
FFPROBE = shutil.which("ffprobe") or "ffprobe"
POLL_SECONDS = float(os.environ.get("MUSE_POLL", "5"))
TARGET_LUFS = -14.0

# Contingencies, off by default — the spike downloaded fine without either.
# Set them the day downloads start failing; see NOTES.md.
COOKIES = os.environ.get("MUSE_COOKIES")           # path to cookies.txt
POT_PROVIDER = os.environ.get("MUSE_POT_BASE_URL")  # bgutil provider base url

H = {"X-Worker-Secret": SECRET}

# Errors that will still be errors in five minutes. Retrying these wastes requests
# against the one thing worth protecting: an unchallenged residential IP.
TERMINAL_ERRORS = (
    "sign in to confirm", "unavailable", "not available", "po token",
    "private video", "removed by the uploader", "members-only", "age-restricted",
    "copyright", "does not exist",
)
_LUFS = re.compile(r"^\s*I:\s*(-?\d+\.?\d*)\s*LUFS", re.M)


def log(*a):
    print(f"[{time.strftime('%H:%M:%S')}]", *a, flush=True)


def ytdlp_args(video_id: str, out: pathlib.Path) -> list[str]:
    args = [
        YTDLP, "--js-runtimes", "node",       # node satisfies the JS runtime; no deno needed
        "-f", "140/bestaudio[acodec^=mp4a]/bestaudio",
        "--no-playlist", "--no-warnings", "-q",
        "-o", str(out / "%(id)s.%(ext)s"),
        "--print-json", "--no-simulate",
        f"https://music.youtube.com/watch?v={video_id}",
    ]
    if COOKIES:
        args[1:1] = ["--cookies", COOKIES]
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


def handle(client: httpx.Client, job: dict) -> None:
    payload = job["payload"]
    video_id, track_id = payload["video_id"], payload["track_id"]
    with tempfile.TemporaryDirectory(prefix="muse-") as tmp:
        tmp_dir = pathlib.Path(tmp)
        log(f"job {job['id']} track {track_id} {video_id} downloading")
        r = subprocess.run(ytdlp_args(video_id, tmp_dir), capture_output=True, text=True)
        files = sorted(p for p in tmp_dir.iterdir() if p.is_file() and p.suffix != ".json")
        if r.returncode != 0 or not files:
            reason = (r.stderr or r.stdout or "yt-dlp failed").strip().splitlines()[-1][:500]
            # A bot-check or a PO-token demand is not transient: stop retrying, surface it.
            retryable = not any(s in reason.lower() for s in TERMINAL_ERRORS)
            log(f"job {job['id']} FAILED: {reason}")
            client.post(f"{API}/internal/jobs/{job['id']}/fail", headers=H,
                        json={"reason": reason, "retryable": retryable, "track_id": track_id})
            return

        audio = to_m4a(files[0])
        info = probe(audio)
        lufs, gain = loudness(audio)
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
    # tmp dir is gone here: this box's disk is not the archive


def main() -> None:
    if not SECRET:
        sys.exit("MUSE_WORKER_SECRET is unset — the server would reject every lease")
    log(f"worker {NAME} → {API}  (cookies={'yes' if COOKIES else 'no'}, "
        f"pot={'yes' if POT_PROVIDER else 'no'})")
    with httpx.Client(timeout=60) as client:
        while True:
            try:
                jobs = client.post(f"{API}/internal/jobs/lease", headers=H,
                                   json={"worker": NAME, "kind": "ingest", "limit": 1}).json()["jobs"]
            except Exception as e:                       # server down / restarting
                log(f"lease failed: {e}")
                time.sleep(POLL_SECONDS * 2)
                continue
            if not jobs:
                time.sleep(POLL_SECONDS)
                continue
            for job in jobs:
                try:
                    handle(client, job)
                except Exception as e:
                    log(f"job {job['id']} crashed: {e}")
                    client.post(f"{API}/internal/jobs/{job['id']}/fail", headers=H,
                                json={"reason": str(e)[:500], "retryable": True,
                                      "track_id": job["payload"].get("track_id")})


if __name__ == "__main__":
    main()
