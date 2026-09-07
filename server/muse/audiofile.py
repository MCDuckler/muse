"""Everything we learn from a file on disk: format, loudness, tags, fingerprint."""
from __future__ import annotations

import json
import pathlib
import re
import shutil
import subprocess

FFMPEG = shutil.which("ffmpeg") or "ffmpeg"
FFPROBE = shutil.which("ffprobe") or "ffprobe"
FPCALC = shutil.which("fpcalc")          # chromaprint; optional
TARGET_LUFS = -14.0
_LUFS = re.compile(r"^\s*I:\s*(-?\d+\.?\d*)\s*LUFS", re.M)

# Formats we serve as-is. Everything else is transcoded, because iOS AVPlayer
# cannot play Ogg/Opus and the client must never care where a track came from.
NATIVE_CODECS = {"aac", "alac"}


def probe(path: pathlib.Path) -> dict:
    out = subprocess.run(
        [FFPROBE, "-v", "error", "-show_entries",
         "format=duration,bit_rate,format_name:stream=codec_name,sample_rate,channels",
         "-of", "json", str(path)],
        capture_output=True, text=True, check=True,
    ).stdout
    d = json.loads(out)
    st = next((s for s in d.get("streams", []) if s.get("codec_name")), {})
    fmt = d.get("format", {})
    return {
        "codec": st.get("codec_name"),
        "sample_rate": int(st["sample_rate"]) if st.get("sample_rate") else None,
        "channels": st.get("channels"),
        "bitrate": int(fmt["bit_rate"]) if fmt.get("bit_rate") else None,
        "duration_ms": int(float(fmt["duration"]) * 1000) if fmt.get("duration") else None,
        "container": fmt.get("format_name"),
    }


def loudness(path: pathlib.Path) -> tuple[float | None, float | None]:
    """Measured, never applied: the client gets `gain_db` and decides."""
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


def tags(path: pathlib.Path) -> dict:
    """Whatever the uploader's own tagger wrote. Trusted as a suggestion, not a fact."""
    try:
        import mutagen
    except ImportError:
        return {}
    f = mutagen.File(path, easy=True)
    if not f:
        return {}
    g = lambda k: (f.get(k) or [None])[0]  # noqa: E731
    year = g("date") or g("originaldate")
    return {
        "title": g("title"),
        "artists": [a for a in (f.get("artist") or []) if a],
        "album": g("album"),
        "release_year": int(str(year)[:4]) if year and str(year)[:4].isdigit() else None,
        "isrc": g("isrc"),
    }


def fingerprint(path: pathlib.Path) -> dict | None:
    """Chromaprint. Stored even without an AcoustID key — it is cheap and it is the only
    way to identify a badly tagged upload later."""
    if not FPCALC:
        return None
    r = subprocess.run([FPCALC, "-json", str(path)], capture_output=True, text=True)
    if r.returncode != 0:
        return None
    try:
        d = json.loads(r.stdout)
        return {"duration": d.get("duration"), "fingerprint": d.get("fingerprint")}
    except json.JSONDecodeError:
        return None


def to_m4a(src: pathlib.Path, dest: pathlib.Path, bitrate: str = "160k") -> pathlib.Path:
    subprocess.run([FFMPEG, "-v", "error", "-y", "-i", str(src),
                    "-vn", "-c:a", "aac", "-b:a", bitrate, str(dest)], check=True)
    return dest


def needs_transcode(info: dict) -> bool:
    return (info.get("codec") or "").lower() not in NATIVE_CODECS
