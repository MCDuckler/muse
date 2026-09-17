"""Metadata enrichment: the step that was planned and never built.

Audio has to come from YouTube because that is where the files are, but nothing about
artwork or canonical metadata does — and unlike playback, these APIs do not care that
the server sits in a datacenter. So this runs *on the server*, in-process, instead of
waiting for the residential worker to be awake.

Sources are tried in quality order and the existing matcher decides whether a candidate
is really the same recording, so a search for a common title cannot silently attach the
wrong album's cover.
"""
from __future__ import annotations

import io
import json
import logging
import re

import httpx

from . import catalog, db, match, sources, storage

log = logging.getLogger("muse.enrich")

UA = "muse/0.1 (personal music server)"
THUMB_PX = 320
TIMEOUT = 20
# Anything smaller than this is a favicon, not album art. A 120px thumbnail looks
# fine in a list and terrible as the centrepiece of a now-playing screen.
MIN_COVER_PX = 300


# ------------------------------------------------------------------ candidates
def _deezer(title: str, artist: str) -> dict | None:
    """No key, no quota, 1000px covers, and an ISRC one hop away."""
    q = f'track:"{title}" artist:"{artist}"' if artist else title
    r = httpx.get("https://api.deezer.com/search", params={"q": q, "limit": 5},
                  headers={"User-Agent": UA}, timeout=TIMEOUT)
    r.raise_for_status()
    out = []
    for d in r.json().get("data", []):
        album = d.get("album") or {}
        out.append({
            "title": d.get("title"),
            "artists": [(d.get("artist") or {}).get("name")],
            "duration_ms": (d.get("duration") or 0) * 1000 or None,
            "album": album.get("title"),
            "cover": album.get("cover_xl") or album.get("cover_big"),
            "provider": "deezer",
            "provider_track_id": d.get("id"),
        })
    return out or None


def deezer_isrc(track_id: int | str) -> str | None:
    """The ISRC for a Deezer track. Search does not carry it; the track itself does.

    Worth the extra request: an ISRC is the one identifier that says two recordings are
    the same recording, which is what stops the same song being downloaded twice under
    two spellings and what stops a mirror attaching the wrong take.
    """
    try:
        r = httpx.get(f"https://api.deezer.com/track/{track_id}",
                      headers={"User-Agent": UA}, timeout=TIMEOUT)
        r.raise_for_status()
        return (r.json().get("isrc") or "").strip().upper() or None
    except (httpx.HTTPError, ValueError):
        return None


def _itunes(title: str, artist: str) -> list[dict] | None:
    r = httpx.get("https://itunes.apple.com/search",
                  params={"term": f"{artist} {title}".strip(), "entity": "song", "limit": 5},
                  headers={"User-Agent": UA}, timeout=TIMEOUT)
    r.raise_for_status()
    out = []
    for d in r.json().get("results", []):
        art = d.get("artworkUrl100") or ""
        out.append({
            "title": d.get("trackName"),
            "artists": [d.get("artistName")],
            "duration_ms": d.get("trackTimeMillis"),
            "album": d.get("collectionName"),
            "year": (d.get("releaseDate") or "")[:4] or None,
            # The 100px URL is a template; asking for 600 costs nothing extra.
            "cover": art.replace("100x100bb", "600x600bb") if art else None,
            "provider": "itunes",
        })
    return out or None


_GOOGLE_SIZE = re.compile(r"=w\d+-h\d+")


def _ytm_thumbnail(raw: dict, px: int = 900) -> str | None:
    """The search payload we already stored. For *song* results this is album art.

    The stored URLs are 120px because that is what a search result list needs, but the
    size lives in the URL — asking Google's image host for a bigger one is free.
    """
    thumbs = (raw or {}).get("thumbnails") or []
    if not thumbs:
        return None
    best = max(thumbs, key=lambda t: (t.get("width") or 0))
    url = best.get("url")
    return _GOOGLE_SIZE.sub(f"=w{px}-h{px}", url) if url else None


def _youtube_still(video_id: str) -> str:
    return f"https://i.ytimg.com/vi/{video_id}/maxresdefault.jpg"


# ------------------------------------------------------------------ cover fetch
def _download(url: str, min_px: int = 0) -> bytes | None:
    try:
        r = httpx.get(url, headers={"User-Agent": UA}, timeout=TIMEOUT, follow_redirects=True)
        if r.status_code != 200 or not r.content:
            return None
        if not r.headers.get("content-type", "").startswith("image/"):
            return None
        if min_px:
            from PIL import Image
            try:
                probe = Image.open(io.BytesIO(r.content))
                if min(probe.size) < min_px:
                    return None            # too small to be worth keeping
            except Exception:
                return None
        return r.content
    except httpx.HTTPError:
        return None


def dominant_colour(img) -> str:
    """A colour to build the now-playing background from.

    Not the average — averaging album art gives mud. Quantise, then prefer the most
    saturated swatch that is neither black nor white, because that is the one a person
    would name if asked what colour the cover is.
    """
    import colorsys

    small = img.convert("RGB").resize((64, 64))
    palette = small.quantize(colors=8, method=2).convert("RGB")
    counts: dict[tuple[int, int, int], int] = {}
    for px in palette.getdata():
        counts[px] = counts.get(px, 0) + 1

    best, best_score = (90, 90, 90), -1.0
    for (r, g, b), n in counts.items():
        h, l, s = colorsys.rgb_to_hls(r / 255, g / 255, b / 255)
        if l < 0.08 or l > 0.94:
            continue                       # near-black and near-white carry no hue
        share = n / 4096
        score = s * 2.2 + share + (1 - abs(l - 0.45)) * 0.6
        if score > best_score:
            best, best_score = (r, g, b), score
    return "#%02x%02x%02x" % best


def store_cover(cfg, raw_bytes: bytes, source: str) -> dict | None:
    """Content-addressed like audio, plus a small variant because lists need one."""
    from PIL import Image

    try:
        img = Image.open(io.BytesIO(raw_bytes))
        img.load()
    except Exception:
        return None
    img = img.convert("RGB")

    # A video still is 16:9 and looks like a letterboxed mistake next to real album
    # art. Album covers are square, so crop the middle out rather than pad it.
    w, h = img.size
    if w and h and abs(w / h - 1.0) > 0.1:
        side = min(w, h)
        img = img.crop(((w - side) // 2, (h - side) // 2,
                        (w - side) // 2 + side, (h - side) // 2 + side))

    full = io.BytesIO()
    img.save(full, format="JPEG", quality=88, optimize=True)
    full.seek(0)
    digest, path, size = storage.store_stream(cfg.cover_dir, full, ".jpg")

    thumb = img.copy()
    thumb.thumbnail((THUMB_PX, THUMB_PX), Image.LANCZOS)
    tbuf = io.BytesIO()
    thumb.save(tbuf, format="JPEG", quality=82, optimize=True)
    tbuf.seek(0)
    tpath = path.with_name(f"{digest}_sm.jpg")
    tpath.write_bytes(tbuf.getvalue())

    colour = dominant_colour(img)
    row = db.one("select id from covers where sha256=%s", (digest,))
    if row:
        db.run("update covers set color=%s where id=%s", (colour, row["id"]))
        return db.one("select * from covers where id=%s", (row["id"],))
    return db.one(
        """insert into covers(sha256,w,h,path,source,color) values(%s,%s,%s,%s,%s,%s)
           returning *""",
        (digest, img.width, img.height, str(path), source, colour),
    )


# ------------------------------------------------------------------ the job
def _album_of(t: dict) -> tuple[str, str] | None:
    """The record a track is on, as the library groups records: name and first credit.

    Nothing without both, because "no album" is not an album — and a cover borrowed
    across everything with an empty album name would put one record's sleeve on a
    thousand unrelated songs.
    """
    album = (t.get("album") or "").strip()
    artists = t.get("artists") or []
    artist = (artists[0] if artists else "") or ""
    return (album, artist) if album and artist else None


def _album_cover(t: dict) -> int | None:
    """A cover already held by something else on the same record."""
    where = _album_of(t)
    if not where:
        return None
    row = db.one(
        """select cover_id from tracks
            where album=%s and coalesce(artists[1],'')=%s and cover_id is not null
            order by id limit 1""",
        where)
    return row["cover_id"] if row else None


def _share_with_album(t: dict, cover_id: int) -> int:
    """Give this cover to the rest of the record, where they have none."""
    where = _album_of(t)
    if not where:
        return 0
    with db.pool().connection() as c:
        return c.execute(
            """update tracks set cover_id=%s
                where album=%s and coalesce(artists[1],'')=%s and cover_id is null""",
            (cover_id, *where)).rowcount


def enrich_track(cfg, track_id: int) -> dict:
    """Fill in album, year, ISRC and — the point of the exercise — a cover."""
    t = catalog.track_row(track_id)
    if not t:
        return {"skipped": "gone"}

    title = t["title"] or ""
    artist = (t["artists"] or [None])[0] or ""
    # Search with a cleaned title: 'Get Lucky (Radio Edit - feat. Pharrell Williams and
    # Nile Rodgers)' matches nothing on Deezer, which is why the first pass fell all the
    # way through to a 120px YouTube thumbnail.
    query_title = match.normalise(title) or title
    target = {"title": title, "artists": t["artists"] or [],
              "duration_ms": t["duration_ms"], "isrc": t["isrc"]}

    chosen: dict | None = None
    for fetch in (_deezer, _itunes):
        try:
            candidates = fetch(query_title, artist) or []
        except httpx.HTTPError as e:
            log.warning("enrich %s: %s failed: %s", track_id, fetch.__name__, e)
            continue
        best, conf, method = match.best(target, candidates)
        # Same bar as playlist import: below this a human would have to decide, and
        # nobody wants a stranger's album cover on their track.
        if best and conf >= match.AUTO_ACCEPT:
            chosen = {**best, "confidence": conf, "method": method}
            break

    # Whatever happens, a YouTube ingest can always show *something*.
    # Sources in descending order of what they actually look like at full size.
    attempts: list[tuple[str, str]] = []

    # A SoundCloud or Bandcamp upload usually has no equivalent release anywhere, so
    # searching a music database for it finds a stranger's record or nothing at all —
    # but the service serving the audio is also serving the artwork the uploader chose,
    # and that is the right cover. It goes first for those two, ahead of any match.
    own = db.one(
        """select provider, provider_id, raw from track_sources
            where track_id=%s and provider in ('soundcloud','bandcamp') limit 1""",
        (track_id,),
    )
    if own:
        raw = own["raw"] if isinstance(own["raw"], dict) else {}
        ref = (raw or {}).get("url") or own["provider_id"]
        if url := sources.artwork_url(own["provider"], ref):
            attempts.append((own["provider"], url))

    if chosen and chosen.get("cover"):
        attempts.append((chosen["provider"], chosen["cover"]))
    if t.get("provider") == "ytmusic" and t.get("provider_id"):
        raw = db.one(
            "select raw from track_sources where track_id=%s and provider='ytmusic'",
            (track_id,),
        )
        raw_payload = raw["raw"] if raw else {}
        if isinstance(raw_payload, str):
            raw_payload = json.loads(raw_payload)
        if url := _ytm_thumbnail(raw_payload):
            attempts.append(("ytmusic", url))
        attempts.append(("youtube", _youtube_still(t["provider_id"])))

    cover_bytes, cover_source = None, None
    for source, url in attempts:
        cover_bytes = _download(url, min_px=MIN_COVER_PX)
        if cover_bytes:
            cover_source = source
            break
    if cover_bytes is None and attempts:
        # Nothing met the size bar; a small cover still beats a blank square.
        for source, url in attempts:
            cover_bytes = _download(url)
            if cover_bytes:
                cover_source = source
                break

    cover = store_cover(cfg, cover_bytes, cover_source) if cover_bytes else None

    # Failing that: the record this song is on, if anything else on it has a cover.
    #
    # One song of an album shows its sleeve and the next one shows a grey square, which
    # is the same record drawn two ways in one list — and the picture is right there,
    # already fetched, filed under the track next to it. Whatever this track's own
    # lookup did, the album it belongs to is the album it belongs to.
    borrowed = None
    if not cover:
        borrowed = _album_cover(t)
        if borrowed:
            log.info("track %s takes its cover from the rest of %s",
                     track_id, t.get("album"))

    updates, params = [], []
    if cover or borrowed:
        updates.append("cover_id=%s")
        params.append(cover["id"] if cover else borrowed)
    if chosen:
        if not t["isrc"] and chosen.get("provider") == "deezer" \
                and chosen.get("provider_track_id"):
            isrc = deezer_isrc(chosen["provider_track_id"])
            if isrc:
                updates.append("isrc=%s")
                params.append(isrc)
        if chosen.get("album") and not t["album"]:
            updates.append("album=%s")
            params.append(chosen["album"])
        if chosen.get("year") and not t["release_year"]:
            updates.append("release_year=%s")
            params.append(int(chosen["year"]))
    if updates:
        params.append(track_id)
        db.run(f"update tracks set {', '.join(updates)} where id=%s", tuple(params))

    # And the other way round: a cover found here is the cover of everything else on
    # the record, so the rest of the album stops being grey squares without each one
    # having to go and look for itself.
    shared = _share_with_album(t, cover["id"]) if cover else 0

    return {
        "track_id": track_id,
        "cover": bool(cover) or bool(borrowed),
        "borrowed": bool(borrowed),
        "shared_with": shared,
        "cover_source": cover_source,
        "matched": chosen["provider"] if chosen else None,
        "confidence": chosen["confidence"] if chosen else None,
    }
