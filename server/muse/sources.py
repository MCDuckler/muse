"""Where audio can come from, and how to get it.

muse started YouTube-shaped: one provider, one id, one worker on a residential line
because YouTube refuses datacenter IPs. Two of the three sources added since do not care
where the request comes from — measured, not assumed — so they are fetched by the server
itself and never touch the machine at home.

Each provider answers two questions: what does a search for this turn up, and how do I
get the audio for one of them.
"""
from __future__ import annotations

import html
import json
import logging
import math
import pathlib
import re
import subprocess
import urllib.parse
import urllib.request

# Providers the server can fetch on its own. YouTube is deliberately absent: it needs
# the residential worker, and pretending otherwise just fills the queue with failures.
DIRECT = ("soundcloud", "bandcamp")

YTDLP = "yt-dlp"

# Bandcamp serves two different pages depending on who is asking. A detailed desktop
# user agent gets a slimmer, script-rendered one with no `data-tralbum` blob in it; a
# plain one gets the classic page that carries the whole record as JSON. Measured, and
# the reason the plain string comes first.
UAS = ("Mozilla/5.0",
       "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) "
       "Chrome/140 Safari/537.36")
UA = UAS[0]


class SourceError(RuntimeError):
    """Something the person who pressed the button should be told about."""


log = logging.getLogger("muse.sources")


def _run(args: list[str], timeout: int = 180) -> subprocess.CompletedProcess:
    return subprocess.run(args, capture_output=True, text=True, timeout=timeout)


def _get(url: str, timeout: int = 30) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    return urllib.request.urlopen(req, timeout=timeout).read()


# ---------------------------------------------------------------- SoundCloud
def _soundcloud_search(query: str, limit: int) -> list[dict]:
    r = _run([YTDLP, "--no-warnings", "--flat-playlist", "-J",
              f"scsearch{limit}:{query}"])
    if r.returncode != 0:
        raise SourceError((r.stderr or "SoundCloud search failed").strip()[:300])
    data = json.loads(r.stdout or "{}")
    out = []
    for e in data.get("entries") or []:
        if not e.get("id"):
            continue
        out.append({
            "provider": "soundcloud",
            "provider_id": str(e["id"]),
            "title": e.get("title") or "",
            "artists": [e["uploader"]] if e.get("uploader") else [],
            "album": None,
            "duration_ms": int((e.get("duration") or 0) * 1000) or None,
            "url": f"https://api.soundcloud.com/tracks/{e['id']}",
        })
    return out


def artwork_url(provider: str, ref: str) -> str | None:
    """The cover the uploader put on it.

    Searching Deezer for a SoundCloud upload finds a stranger's record or nothing at
    all, and most of these have no equivalent release anywhere — but the service that
    is serving the audio is also serving the artwork, and that artwork is the right one.
    """
    try:
        if provider == "bandcamp":
            blob = bandcamp_page(ref)
            art = (blob.get("current") or {}).get("art_id") or blob.get("art_id")
            return f"https://f4.bcbits.com/img/a{art}_10.jpg" if art else None

        url = ref if ref.startswith("http") else f"https://api.soundcloud.com/tracks/{ref}"
        r = _run([YTDLP, "--no-warnings", "--no-playlist", "-J", url], timeout=120)
        if r.returncode != 0:
            return None
        data = json.loads(r.stdout or "{}") or {}
        thumb = data.get("thumbnail")
        # SoundCloud serves several sizes under one name; the original is worth having
        # for a now-playing screen and costs nothing extra.
        if isinstance(thumb, str) and "-large." in thumb:
            thumb = thumb.replace("-large.", "-original.")
        return thumb
    except Exception as e:                       # never let artwork break an ingest
        log.info("no artwork for %s %s: %s", provider, ref, e)
        return None


def _soundcloud_fetch(ref: str, out_dir: pathlib.Path, report) -> dict:
    url = ref if ref.startswith("http") else f"https://api.soundcloud.com/tracks/{ref}"
    report("downloading", 0.0)
    r = _run([YTDLP, "--no-warnings", "--no-playlist",
              # 160k AAC where it exists, which is better than anything YouTube gives us
              # and already the container we call canonical.
              "-f", "hls_aac_160k/hls_aac_96k/http_mp3_0_0/bestaudio",
              "-o", str(out_dir / "%(id)s.%(ext)s"), url], timeout=600)
    if r.returncode != 0:
        raise SourceError((r.stderr or "download failed").strip().splitlines()[-1][:300])
    files = [p for p in out_dir.iterdir() if p.is_file()]
    if not files:
        raise SourceError("SoundCloud returned no audio")
    return {"path": files[0]}


# ---------------------------------------------------------------- Bandcamp
_TRALBUM = re.compile(r'data-tralbum="([^"]+)"')


def _get_page(url: str) -> str:
    """Fetch a page, trying each user agent until one gives us the data blob."""
    last = b""
    for ua in UAS:
        req = urllib.request.Request(url, headers={"User-Agent": ua})
        last = urllib.request.urlopen(req, timeout=30).read()
        text = last.decode("utf-8", "replace")
        if _TRALBUM.search(text):
            return text
    return last.decode("utf-8", "replace")


def bandcamp_page(url: str) -> dict:
    """The JSON a Bandcamp page carries about itself.

    An album page holds the whole record — every track, its number, its length and a
    direct stream URL — which makes importing an album one request rather than one per
    song, with the metadata the artist typed rather than a guess.

    We parse it ourselves because yt-dlp's Bandcamp extractor is currently broken on
    pages that plainly contain this, and because the shape has been stable for years.
    """
    page = _get_page(url)
    m = _TRALBUM.search(page)
    if not m:
        raise SourceError("That Bandcamp page does not look like an album or a track.")
    return json.loads(html.unescape(m.group(1)))


def bandcamp_tracks(url: str) -> list[dict]:
    """Every track on a Bandcamp page, streamable or not."""
    data = bandcamp_page(url)
    artist = data.get("artist") or ""
    album = (data.get("current") or {}).get("title")
    root = re.match(r"https?://[^/]+", url)
    out = []
    for t in data.get("trackinfo") or []:
        stream = (t.get("file") or {}).get("mp3-128")
        path = t.get("title_link") or ""
        out.append({
            "provider": "bandcamp",
            "provider_id": str(t.get("id") or t.get("track_id") or path),
            "title": t.get("title") or "",
            "artists": [a for a in [t.get("artist") or artist] if a],
            "album": album,
            "track_no": t.get("track_num"),
            "duration_ms": int((t.get("duration") or 0) * 1000) or None,
            "url": f"{root.group(0)}{path}" if root and path else url,
            "stream": stream,
            # About one track in fifty: streamed only if you buy the record.
            "streamable": bool(stream),
        })
    return out


def _bandcamp_search(query: str, limit: int) -> list[dict]:
    body = json.dumps({"search_text": query, "search_filter": "t",
                       "full_page": False, "fan_id": None}).encode()
    req = urllib.request.Request(
        "https://bandcamp.com/api/bcsearch_public_api/1/autocomplete_elastic",
        data=body, headers={"Content-Type": "application/json", "User-Agent": UA})
    data = json.loads(urllib.request.urlopen(req, timeout=30).read())
    out = []
    for r in (data.get("auto") or {}).get("results", [])[:limit]:
        if not r.get("item_url_path"):
            continue
        out.append({
            "provider": "bandcamp",
            "provider_id": str(r.get("id") or r["item_url_path"]),
            "title": r.get("name") or "",
            "artists": [r["band_name"]] if r.get("band_name") else [],
            "album": r.get("album_name"),
            # The search index does not carry durations; the page does, and that is one
            # request away at the point where it matters.
            "duration_ms": None,
            "url": r["item_url_path"],
        })
    return out


def _bandcamp_fetch(ref: str, out_dir: pathlib.Path, report) -> dict:
    # A reference may name the track within the page it lives on: "<album url>#<id>".
    # Bandcamp's own links are per-track, but an import from somewhere else often knows
    # only the record and which track on it — and taking the first streamable one there
    # would quietly fetch the wrong song.
    page, _, wanted = ref.partition("#")
    tracks = bandcamp_tracks(page)
    track = None
    if wanted:
        track = next((t for t in tracks
                      if t["provider_id"] == wanted and t["streamable"]), None)
    track = track \
        or next((t for t in tracks if t["url"] == ref and t["streamable"]), None) \
        or (None if wanted else next((t for t in tracks if t["streamable"]), None))
    if not track:
        raise SourceError(
            "This one streams only if you buy it — Bandcamp keeps the file behind the "
            "purchase.")

    report("downloading", 0.0)
    dest = out_dir / f"{track['provider_id']}.mp3"
    req = urllib.request.Request(track["stream"], headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=120) as r, dest.open("wb") as fh:
        total = int(r.headers.get("Content-Length") or 0)
        got = 0
        while chunk := r.read(256 * 1024):
            fh.write(chunk)
            got += len(chunk)
            if total:
                report("downloading", min(1.0, got / total))
    if dest.stat().st_size < 1024:
        raise SourceError("Bandcamp returned an empty file")
    # MP3 as it came. Transcoding 128 kbps to AAC is a second lossy pass for nothing, and
    # every client we have plays MP3.
    return {"path": dest, "meta": track}


# ---------------------------------------------------------------- registry
_SEARCH = {"soundcloud": _soundcloud_search, "bandcamp": _bandcamp_search}
_FETCH = {"soundcloud": _soundcloud_fetch, "bandcamp": _bandcamp_fetch}


def search(provider: str, query: str, limit: int = 8) -> list[dict]:
    if provider not in _SEARCH:
        raise SourceError(f"{provider} cannot be searched")
    return _SEARCH[provider](query, limit)


def fetch(provider: str, ref: str, out_dir: pathlib.Path, report) -> dict:
    if provider not in _FETCH:
        raise SourceError(f"{provider} is not fetched by the server")
    return _FETCH[provider](ref, out_dir, report)


def provider_for_url(url: str) -> str | None:
    host = (urllib.parse.urlparse(url).hostname or "").lower()
    if host.endswith("bandcamp.com"):
        return "bandcamp"
    if host.endswith("soundcloud.com"):
        return "soundcloud"
    if host.endswith(("youtube.com", "youtu.be", "music.youtube.com")):
        return "youtube"
    return None


def loudness_gain(lufs: float | None, target: float = -14.0) -> float | None:
    """Same rule as the residential worker: measure, never bake it in."""
    return None if lufs is None else round(target - lufs, 2)


def probe(path: pathlib.Path, ffprobe: str = "ffprobe") -> dict:
    r = _run([ffprobe, "-v", "error", "-show_entries",
              "format=duration,bit_rate:stream=codec_name,sample_rate,channels",
              "-of", "json", str(path)])
    if r.returncode != 0:
        return {}
    d = json.loads(r.stdout or "{}")
    st = (d.get("streams") or [{}])[0]
    fmt = d.get("format", {})
    return {
        "codec": st.get("codec_name"),
        "bitrate": int(fmt["bit_rate"]) if fmt.get("bit_rate") else None,
        "duration_ms": int(float(fmt["duration"]) * 1000) if fmt.get("duration") else None,
    }


_LUFS = re.compile(r"^\s*I:\s*(-?\d+\.?\d*)\s*LUFS", re.M)


def loudness(path: pathlib.Path, ffmpeg: str = "ffmpeg") -> tuple[float | None, float | None]:
    r = _run([ffmpeg, "-nostats", "-hide_banner", "-i", str(path),
              "-af", "ebur128=framelog=quiet", "-f", "null", "-"], timeout=300)
    m = _LUFS.search(r.stderr or "")
    if not m:
        return None, None
    lufs = float(m.group(1))
    return lufs, loudness_gain(lufs)
