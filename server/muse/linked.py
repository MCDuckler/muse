"""Accounts on other services, and the playlists they hold.

Spotify needed OAuth because everything about a Spotify account is private. These three
do not: a Deezer profile id, a SoundCloud username and a Bandcamp fan name are all
public reads, so linking one is typing a name rather than a round trip through a consent
screen. Nothing here can post, follow, or spend money — it can only read what anybody
with the link could read.
"""
from __future__ import annotations

import datetime as dt
import html
import json
import logging
import re
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request

from . import db, sources

PROVIDERS = ("deezer", "soundcloud", "bandcamp", "youtube")


log = logging.getLogger("muse.linked")


class LinkError(RuntimeError):
    """Something to show the person who typed the name."""


class RateLimited(RuntimeError):
    """Asked to slow down. Not a failure — come back to it."""


# A wishlist can be over a thousand records, and each one is a page fetch. Taken in
# runs, with a pause between requests: a burst of a thousand is how a 429 happens, and
# a mirror that gets itself blocked is worse than a slow one.
ALBUMS_PER_RUN = 40
PAUSE_BETWEEN = 0.35


_HANDLE_OK = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")

# The share sheet does not hand out profile links, it hands out short ones. Following
# the redirect is the only way to find out whose profile it is.
_SHORTENERS = ("on.soundcloud.com", "soundcloud.app.goo.gl", "bandcamp.com/redirect")


def _follow_short_link(url: str) -> str:
    """Where a share link actually points. The link itself if it cannot be followed."""
    try:
        req = urllib.request.Request(url, method="HEAD",
                                     headers={"User-Agent": sources.UA})
        with urllib.request.urlopen(req, timeout=20) as r:
            return r.geturl() or url
    except Exception as e:
        log.info("could not follow %s: %s", url, e)
        return url


def _handle_from(raw: str, host: str, what: str) -> str:
    """The name out of whatever was pasted into the box.

    Nobody types a bare handle. They paste the address bar, or the share sheet's URL
    with its tracking parameters still attached, or the page they were actually on —
    soundcloud.com/someone/likes. The handle is the *first* path segment; the previous
    code took the last, so pasting a profile URL linked an account called "likes", and
    a share link linked one called "you?si=3f2...". Both came back as "no public
    profile with that name".
    """
    text = (raw or "").strip()
    if any(s in text for s in _SHORTENERS):
        text = _follow_short_link(text if "://" in text else "https://" + text)
    if "://" in text or host in text:
        parsed = urllib.parse.urlsplit(text if "://" in text else "https://" + text)
        segments = [s for s in parsed.path.split("/") if s]
        text = segments[0] if segments else ""
    text = text.split("?")[0].split("#")[0].strip().strip("/").lstrip("@").strip()
    if not text or not _HANDLE_OK.match(text):
        raise LinkError(f"That does not look like a {what} name. "
                        f"Paste your profile link, or the name in it.")
    return text


def _json(url: str, data: dict | None = None) -> dict:
    body = json.dumps(data).encode() if data is not None else None
    req = urllib.request.Request(url, data=body, headers={
        "User-Agent": sources.UA,
        **({"Content-Type": "application/json"} if data is not None else {}),
    })
    try:
        return json.loads(urllib.request.urlopen(req, timeout=30).read())
    except urllib.error.HTTPError as e:
        if e.code == 429:
            raise RateLimited(str(e)) from e
        raise


# ---------------------------------------------------------------- Deezer
def _deezer_profile(handle: str) -> dict:
    """A profile id, or the tail of a profile URL."""
    handle = handle.strip().rstrip("/")
    if "deezer.com" in handle:
        handle = handle.rsplit("/", 1)[-1].split("?")[0]
    if not handle.isdigit():
        raise LinkError("Deezer needs the numeric id from your profile URL, "
                        "like deezer.com/en/profile/2529.")
    me = _json(f"https://api.deezer.com/user/{handle}")
    if me.get("error"):
        raise LinkError("Deezer does not know that profile id.")
    return {"handle": handle, "display_name": me.get("name") or handle}


def _deezer_playlists(handle: str) -> list[dict]:
    out, url = [], f"https://api.deezer.com/user/{handle}/playlists?limit=100"
    while url:
        page = _json(url)
        if page.get("error"):
            raise LinkError("Deezer will not show that profile's playlists. "
                            "They are only readable while the profile is public.")
        for p in page.get("data", []):
            out.append({"remote_id": str(p["id"]), "name": p.get("title") or "Untitled",
                        "count": p.get("nb_tracks"), "owner": (p.get("creator") or {}).get("name"),
                        "image": p.get("picture_medium")})
        url = page.get("next")
    return out


def _deezer_items(remote_id: str) -> list[dict]:
    out, url = [], f"https://api.deezer.com/playlist/{remote_id}/tracks?limit=100"
    while url:
        page = _json(url)
        if page.get("error"):
            raise LinkError("That Deezer playlist is not readable.")
        for t in page.get("data", []):
            out.append({
                "remote_id": str(t["id"]),
                "title": t.get("title") or "",
                "artists": [(t.get("artist") or {}).get("name")] if t.get("artist") else [],
                "album": (t.get("album") or {}).get("title"),
                "duration_ms": int((t.get("duration") or 0) * 1000) or None,
                # Deezer gives an ISRC per track, which is exact where a title is a guess.
                "isrc": t.get("isrc"),
            })
        url = page.get("next")
    return out


# ---------------------------------------------------------------- SoundCloud
def _soundcloud_profile(handle: str) -> dict:
    handle = _handle_from(handle, "soundcloud.com", "SoundCloud")
    quoted = urllib.parse.quote(handle)
    # The profile itself first: most people here have never uploaded anything, and a
    # listener's page is the one that has to work. /tracks and /likes are only a
    # fallback for the odd account whose root page will not resolve.
    problem = ""
    for path in ("", "/tracks", "/likes"):
        r = subprocess.run([sources.YTDLP, "--flat-playlist", "-J",
                            "--playlist-items", "1",
                            f"https://soundcloud.com/{quoted}{path}"],
                           capture_output=True, text=True, timeout=120)
        data = json.loads(r.stdout or "null") if r.returncode == 0 else None
        if isinstance(data, dict) and data.get("id"):
            # The listing is titled "Name (All)"; the name is the part worth keeping.
            name = data.get("uploader") or re.sub(r"\s*\((All|Tracks|Likes)\)$", "",
                                                  data.get("title") or "") or handle
            return {"handle": handle, "display_name": name}
        problem = (r.stderr or "").strip().splitlines()[-1] if r.stderr.strip() else problem

    if "429" in problem or "rate" in problem.lower():
        raise LinkError("SoundCloud is asking us to slow down. Try again in a minute.")
    log.warning("soundcloud link failed for %r: %s", handle, problem[:300])
    raise LinkError(f"SoundCloud has no public profile called “{handle}”. "
                    "It is the name in your profile link, not your display name.")


def _soundcloud_playlists(handle: str) -> list[dict]:
    """The three standing lists, and then the playlists they actually made.

    A profile's own sets were missing entirely, so the only things that could be
    mirrored were likes, uploads and reposts — which is not what most people mean by
    their SoundCloud playlists.
    """
    out = [
        {"remote_id": f"{handle}/likes", "name": "Likes",
         "count": None, "owner": handle, "image": None},
        {"remote_id": f"{handle}/tracks", "name": "Tracks",
         "count": None, "owner": handle, "image": None},
        {"remote_id": f"{handle}/reposts", "name": "Reposts",
         "count": None, "owner": handle, "image": None},
    ]
    r = subprocess.run([sources.YTDLP, "--flat-playlist", "-J",
                        f"https://soundcloud.com/{urllib.parse.quote(handle)}/sets"],
                       capture_output=True, text=True, timeout=180)
    if r.returncode != 0:
        log.info("no sets for %s: %s", handle, (r.stderr or "").strip()[:200])
        return out
    try:
        data = json.loads(r.stdout or "{}") or {}
    except json.JSONDecodeError:
        return out
    for entry in data.get("entries") or []:
        url = entry.get("url") or ""
        # The remote id is the part after soundcloud.com/, which is what _soundcloud_items
        # puts back together — one shape for a set and for a standing list.
        remote = url.split("soundcloud.com/", 1)[-1].strip("/") if url else ""
        if not remote or not entry.get("title"):
            continue
        out.append({"remote_id": remote, "name": entry["title"],
                    "count": entry.get("playlist_count"), "owner": handle,
                    "image": entry.get("thumbnail")})
    return out


def _sc_item(track: dict) -> dict | None:
    """One SoundCloud track, in the shape a mirror run expects."""
    if not track or not track.get("id"):
        return None
    who = (track.get("user") or {}).get("username")
    return {
        "remote_id": str(track["id"]),
        "title": (track.get("title") or "").strip(),
        # The uploader is who SoundCloud says made it. Not always the artist a shop
        # would print — a label account, a mix series — but it is a name, and a name is
        # what "Unknown artist" was standing in for.
        "artists": [who] if who else [],
        "album": None,
        "duration_ms": track.get("duration") or None,
        # Straight from SoundCloud, so no matching step: this *is* the recording.
        "source": {"provider": "soundcloud", "provider_id": str(track["id"]),
                   "url": f"https://api.soundcloud.com/tracks/{track['id']}"},
    }


def sc_tracks_by_id(ids: list[str]) -> dict[str, dict]:
    """Fill in tracks that a listing named but did not describe.

    A SoundCloud playlist hands back the first few tracks in full and the rest as bare
    ids; asking for fifty at a time is one request rather than fifty.
    """
    found: dict[str, dict] = {}
    for start in range(0, len(ids), 50):
        batch = ids[start:start + 50]
        if not batch:
            continue
        try:
            for track in _sc_api("/tracks", ids=",".join(batch)) or []:
                found[str(track.get("id"))] = track
        except LinkError:
            break
    return found


def _soundcloud_items_api(handle: str, which: str, limit: int) -> list[dict]:
    """A listing, through SoundCloud's own web API.

    yt-dlp's flat listing is one request for a whole profile, which is why it was used
    — but for SoundCloud it answers with nothing except ids and links: no title, no
    uploader. Every track mirrored from here was therefore created blank, which is what
    "Unknown artist" was. The web app's own API answers the same question with the
    whole record.
    """
    profile = _sc_api("/resolve", url=f"https://soundcloud.com/{handle}")
    user_id = profile.get("id")
    if not user_id:
        raise LinkError("SoundCloud has no profile with that name.")

    raw: list[dict] = []
    if which.startswith("sets/"):
        playlist = _sc_api("/resolve", url=f"https://soundcloud.com/{handle}/{which}")
        listed = playlist.get("tracks") or []
        thin = [str(t["id"]) for t in listed if t.get("id") and not t.get("title")]
        filled = sc_tracks_by_id(thin) if thin else {}
        for track in listed:
            whole = track if track.get("title") else filled.get(str(track.get("id")))
            if whole:
                raw.append(whole)
    elif which in ("likes", "reposts", "tracks", ""):
        path = {
            "likes": f"/users/{user_id}/likes",
            "reposts": f"/stream/users/{user_id}/reposts",
            "tracks": f"/users/{user_id}/tracks",
            "": f"/users/{user_id}/tracks",
        }[which]
        offset = 0
        while len(raw) < limit:
            page = _sc_api(path, limit=min(100, limit - len(raw)), offset=offset)
            items = page.get("collection") or []
            for entry in items:
                # Likes and reposts wrap the track; a plain listing is the track.
                track = entry.get("track") if isinstance(entry, dict) and "track" in entry \
                    else entry
                if track and track.get("kind", "track") == "track":
                    raw.append(track)
            if len(items) < 1:
                break
            offset += len(items)
            if len(items) < 100:
                break
    else:
        raise LinkError(f"Nothing to read at soundcloud.com/{handle}/{which}")

    out = []
    for track in raw[:limit]:
        item = _sc_item(track)
        if item and item["title"]:
            out.append(item)
    if not out:
        raise LinkError("SoundCloud listed nothing there.")
    return out


def _soundcloud_items(remote_id: str, limit: int = 200) -> list[dict]:
    handle, _, which = remote_id.partition("/")
    try:
        return _soundcloud_items_api(handle, which, limit)
    except LinkError as e:
        log.info("soundcloud api listing failed for %s (%s); falling back to yt-dlp",
                 remote_id, e)
    except Exception as e:                        # noqa: BLE001 - any web app change
        log.info("soundcloud api listing broke on %s: %s", remote_id, e)

    # The old way, kept as the fallback. It knows the ids and the links, which is
    # enough to fetch the audio; the titles are filled in from the links so a track is
    # never created with no name at all.
    r = subprocess.run([sources.YTDLP, "--no-warnings", "--flat-playlist", "-J",
                        "--playlist-items", f"1-{limit}",
                        f"https://soundcloud.com/{remote_id}"],
                       capture_output=True, text=True, timeout=300)
    if r.returncode != 0:
        raise LinkError((r.stderr or "SoundCloud would not list that").strip()[:200])
    data = json.loads(r.stdout or "{}")
    out = []
    for e in data.get("entries") or []:
        if not e.get("id"):
            continue
        link = e.get("url") or ""
        slug = link.rstrip("/").rsplit("/", 1)[-1] if link else ""
        who = e.get("uploader") or (link.split("soundcloud.com/", 1)[-1].split("/")[0]
                                    if "soundcloud.com/" in link else None)
        out.append({
            "remote_id": str(e["id"]),
            # A slug is a poor title, and a better one arrives with the file itself —
            # but it is a name, and the row is no longer nameless.
            "title": e.get("title") or slug.replace("-", " ").strip(),
            "artists": [who] if who else [],
            "album": None,
            "duration_ms": int((e.get("duration") or 0) * 1000) or None,
            "source": {"provider": "soundcloud", "provider_id": str(e["id"]),
                       "url": f"https://api.soundcloud.com/tracks/{e['id']}"},
        })
    return out


def repair_soundcloud(limit: int = 1000, apply: bool = True) -> dict:
    """Give names back to tracks mirrored while the listing had none.

    Everything SoundCloud added before this ran was created from a listing that carried
    only ids and links, so the rows have no title and no artist — "Unknown artist", on a
    song whose name SoundCloud knows perfectly well. This asks for those tracks by id
    and writes back what comes.
    """
    rows = db.all_(
        """select t.id, ts.provider_id
             from tracks t
             join track_sources ts on ts.track_id = t.id and ts.provider = 'soundcloud'
            where t.source = 'soundcloud'
              and (coalesce(t.title, '') = '' or coalesce(array_length(t.artists, 1), 0) = 0)
            order by t.id desc limit %s""",
        (limit,),
    )
    if not rows:
        return {"looked_at": 0, "named": 0, "still_unknown": 0}

    by_provider = {str(r["provider_id"]): r["id"] for r in rows}
    found = sc_tracks_by_id(list(by_provider))
    named = 0
    for provider_id, track_id in by_provider.items():
        track = found.get(provider_id)
        item = _sc_item(track) if track else None
        if not item or not item["title"]:
            continue
        named += 1
        if apply:
            db.run(
                """update tracks
                      set title = %s,
                          artists = case when coalesce(array_length(artists,1),0) = 0
                                         then %s else artists end,
                          duration_ms = coalesce(duration_ms, %s)
                    where id = %s""",
                (item["title"], item["artists"], item["duration_ms"], track_id),
            )
    return {"looked_at": len(rows), "named": named,
            "still_unknown": len(rows) - named}


# ---------------------------------------------------------------- Bandcamp
_BLOB = re.compile(r'id="pagedata"[^>]*data-blob="([^"]+)"')


def _bandcamp_blob(username: str) -> dict:
    page = sources._get_page(f"https://bandcamp.com/{urllib.parse.quote(username)}")
    m = _BLOB.search(page)
    if not m:
        raise LinkError("Bandcamp has no fan page with that name.")
    return json.loads(html.unescape(m.group(1)))


def _bandcamp_profile(handle: str) -> dict:
    handle = _handle_from(handle, "bandcamp.com", "Bandcamp fan")
    blob = _bandcamp_blob(handle)
    fan = blob.get("fan_data") or {}
    if not fan.get("fan_id"):
        raise LinkError("Bandcamp has no fan page with that name.")
    return {"handle": handle, "display_name": fan.get("name") or handle,
            "extra": {"fan_id": fan["fan_id"]}}


def _bandcamp_playlists(handle: str) -> list[dict]:
    blob = _bandcamp_blob(handle)
    counts = blob.get("collection_count")
    return [
        {"remote_id": f"{handle}/collection", "name": "Collection",
         "count": counts, "owner": handle, "image": None},
        {"remote_id": f"{handle}/wishlist", "name": "Wishlist",
         "count": (blob.get("wishlist_data") or {}).get("item_count"),
         "owner": handle, "image": None},
    ]


def _bandcamp_albums(handle: str, which: str) -> list[str]:
    """Every record in a collection or wishlist, as page URLs."""
    blob = _bandcamp_blob(handle)
    fan = (blob.get("fan_data") or {}).get("fan_id")
    endpoint = "wishlist_items" if which == "wishlist" else "collection_items"
    urls, token = [], "9999999999::a::"
    while True:
        page = _json(f"https://bandcamp.com/api/fancollection/1/{endpoint}",
                     {"fan_id": fan, "older_than_token": token, "count": 100})
        items = page.get("items") or []
        urls += [it["item_url"] for it in items if it.get("item_url")]
        token = page.get("last_token") or token
        if not items or not page.get("more_available"):
            return urls
        time.sleep(PAUSE_BETWEEN)


def _bandcamp_items(remote_id: str, offset: int = 0) -> tuple[list[dict], int | None]:
    """A run of records from a collection or wishlist, and where to carry on.

    A Bandcamp collection is albums, not songs, and each album page carries its own
    tracklist — so this is one request per record rather than one per song, and the
    metadata is what the artist typed. It is also why this has to be taken in runs: a
    wishlist of thirteen hundred records is thirteen hundred page fetches, and asking
    for them all at once gets the address blocked.
    """
    handle, _, which = remote_id.partition("/")
    albums = _bandcamp_albums(handle, which)
    run = albums[offset:offset + ALBUMS_PER_RUN]

    out = []
    for n, url in enumerate(run):
        if n:
            time.sleep(PAUSE_BETWEEN)
        try:
            for track in sources.bandcamp_tracks(url):
                if not track["streamable"]:
                    continue
                out.append({
                    "remote_id": track["provider_id"],
                    "title": track["title"],
                    "artists": track["artists"],
                    "album": track["album"],
                    "duration_ms": track["duration_ms"],
                    "source": {"provider": "bandcamp",
                               "provider_id": track["provider_id"],
                               "url": track["url"]},
                })
        except RateLimited:
            # Stop here and keep what we have; the rest is a later run's problem.
            log.info("bandcamp asked us to slow down at record %s", offset + n)
            return out, offset + n
        except sources.SourceError:
            continue                      # one odd record is not the collection

    done = offset + len(run)
    return out, (done if done < len(albums) else None)


# ---------------------------------------------------------------- YouTube Music
#
# The odd one out. The others are public reads — a name is enough — but nothing about a
# YouTube account is public, so this one keeps a credential: the headers a signed-in
# browser sends, which is what ytmusicapi takes. Public playlists still need none of
# that, so a link is only required for your own library and your liked songs.
def _youtube_profile(auth: str) -> dict:
    from . import ytm

    blob = ytm.normalise_paste(auth)
    if not blob:
        raise LinkError(
            "Paste the cookie from a signed-in music.youtube.com, or the whole block "
            "of request headers.")
    try:
        # The listing is the real test: a sign-in that cannot read the library is no
        # use however well-formed it looks.
        ytm.library_playlists(blob, limit=1)
        name = ytm.account_name(blob)
    except ytm.NotAllowed as e:
        raise LinkError(str(e))
    except ytm.Unavailable as e:
        raise LinkError(str(e))
    return {"handle": name, "display_name": name, "secret": blob}


def _youtube_playlists(auth: str) -> list[dict]:
    from . import ytm

    return ytm.library_playlists(auth)


def _youtube_items(remote_id: str, auth: str | None = None) -> list[dict]:
    from . import ytm

    return ytm.playlist_tracks(remote_id, auth=auth)


# ---------------------------------------------------------------- who they follow
# SoundCloud's own web app talks to an API that needs a key, and the key is sitting in
# the JavaScript it serves. That is how their site works, so it is how this works — with
# the key cached until it stops being accepted and fetched again when it does. It is not
# a documented interface and it can be taken away; when it is, this says so rather than
# quietly reporting that you follow nobody.
_SC_API = "https://api-v2.soundcloud.com"
_sc_client_id: str | None = None


def _soundcloud_key(refresh: bool = False) -> str:
    global _sc_client_id
    if _sc_client_id and not refresh:
        return _sc_client_id
    page = sources._get_page("https://soundcloud.com/discover")
    scripts = re.findall(r'src="(https://a-v2\.sndcdn\.com/assets/[^"]+\.js)"', page)
    for src in reversed(scripts):                 # the key lives in a late bundle
        found = re.search(r'client_id\s*[:=]\s*"([A-Za-z0-9]{20,})"',
                          sources._get_page(src))
        if found:
            _sc_client_id = found.group(1)
            return _sc_client_id
    raise LinkError("SoundCloud changed its web app; following cannot be read.")


def _sc_api(path: str, **params) -> dict:
    """One call, retried once with a fresh key — the old one expires eventually."""
    for attempt in (0, 1):
        key = _soundcloud_key(refresh=attempt == 1)
        query = urllib.parse.urlencode({**params, "client_id": key})
        try:
            return _json(f"{_SC_API}{path}?{query}")
        except urllib.error.HTTPError as e:
            if e.code in (401, 403) and attempt == 0:
                continue
            raise LinkError(f"SoundCloud said no: {e.code}")
    raise LinkError("SoundCloud would not answer.")


def _soundcloud_following(handle: str) -> list[dict]:
    profile = _sc_api("/resolve", url=f"https://soundcloud.com/{handle}")
    user_id = profile.get("id")
    if not user_id:
        raise LinkError("SoundCloud has no profile with that name.")

    out, offset = [], 0
    while len(out) < 400:
        page = _sc_api(f"/users/{user_id}/followings", limit=100, offset=offset)
        people = page.get("collection") or []
        for person in people:
            name = (person.get("username") or "").strip()
            if name:
                out.append({"name": name, "image": person.get("avatar_url")})
        if len(people) < 100:
            break
        offset += len(people)
        time.sleep(PAUSE_BETWEEN)
    return out


def _deezer_following(handle: str) -> list[dict]:
    """Deezer publishes a profile's favourite artists, which is what following is there."""
    out, url = [], f"https://api.deezer.com/user/{handle}/artists?limit=100"
    while url and len(out) < 400:
        page = _json(url)
        if page.get("error"):
            raise LinkError("Deezer will not show that profile's artists. "
                            "They are only readable while the profile is public.")
        for artist in page.get("data") or []:
            if artist.get("name"):
                out.append({"name": artist["name"], "image": artist.get("picture_medium")})
        url = page.get("next")
    return out


def bandcamp_image(image_id, size: int = 10) -> str | None:
    """A Bandcamp image by id. 10 is a 1200px square, 2 a 350px one."""
    return f"https://f4.bcbits.com/img/{image_id}_{size}.jpg" if image_id else None


def bandcamp_art(art_id, size: int = 2) -> str | None:
    return f"https://f4.bcbits.com/img/a{art_id}_{size}.jpg" if art_id else None


def _band_url(entry: dict) -> str | None:
    hints = entry.get("url_hints") or {}
    if hints.get("custom_domain"):
        return f"https://{hints['custom_domain']}"
    if hints.get("subdomain"):
        return f"https://{hints['subdomain']}.bandcamp.com"
    return None


def _bandcamp_following(handle: str) -> list[dict]:
    """Every band a fan follows.

    The fan page's own blob caches the first forty-five or so; the rest are behind the
    same paged API the collection uses. A follow is a band id, a name and the band's
    page — which is what tells a label from an act, later, one page at a time.
    """
    blob = _bandcamp_blob(handle)
    fan = (blob.get("fan_data") or {}).get("fan_id")
    out: list[dict] = []
    seen: set = set()

    def take(entry: dict) -> None:
        name = (entry or {}).get("name")
        if not name or entry.get("band_id") in seen:
            return
        seen.add(entry.get("band_id"))
        out.append({"name": name, "image": bandcamp_image(entry.get("image_id")),
                    "url": _band_url(entry), "band_id": entry.get("band_id")})

    for entry in ((blob.get("item_cache") or {}).get("following_bands") or {}).values():
        take(entry)
    token = "9999999999:9999999999"
    for _ in range(40):                       # 4,000 follows is enough for anybody
        if not fan:
            break
        try:
            page = _json("https://bandcamp.com/api/fancollection/1/following_bands",
                         {"fan_id": fan, "older_than_token": token, "count": 100})
        except RateLimited:
            break
        for entry in page.get("followeers") or []:
            take(entry)
        token = page.get("last_token") or token
        if not page.get("more_available"):
            break
        time.sleep(PAUSE_BETWEEN)
    return out


_BAND = re.compile(r'data-band="([^"]+)"')
_ROSTER = re.compile(
    r'<a[^>]+href="(?P<url>https?://[^"]+)"[^>]*>(?:(?!</a>).)*?'
    r'<div class="artists-grid-name">\s*(?P<name>[^<]+?)\s*</div>', re.S)
_CLIENT_ITEMS = re.compile(r'data-client-items="([^"]+)"')
# One record drawn into a music page's grid: its link, then its title, with the act
# that made it in a span of its own when that is not the page itself. The picture is
# in the src, or in data-original for one drawn lazily.
_GRID_ITEM = re.compile(
    r'<li data-item-id="(?P<kind>album|track)-\d+"(?:(?!</li>).)*?<a href="(?P<href>[^"]+)"'
    r'(?:(?!</li>).)*?<p class="title">(?P<title>.*?)</p>', re.S)
_GRID_ART = re.compile(r'/img/a(\d+)_')
_OVERRIDE = re.compile(r'<span class="artist-override">\s*(.*?)\s*</span>', re.S)
# Past this many other acts on a page's records — and with them behind at least half of
# the records — the page is a label whatever it calls itself: Analog Africa and Klasse
# Wrecks are both "artist" accounts on Bandcamp. The half is for an act with a few
# collaborations and an alias or two, which is not a label (bvdub: 2 of 24).
LABEL_ACTS = 3
_TAG = re.compile(r'<a class="tag"[^>]*>\s*([^<]+?)\s*</a>')
_COLLECTORS = re.compile(r'id="collectors-data" data-blob="([^"]+)"')


def bandcamp_band(url: str) -> dict:
    """What a Bandcamp page is: its name, whether it is a label, its picture.

    Cached a month in remote_cache: a page does not stop being a label, and an import
    of three hundred follows is three hundred of these.
    """
    key = f"bc:band:{url.rstrip('/').lower()}"
    row = db.one("select body from remote_cache where key=%s and fetched_at > now() - "
                 "interval '30 days'", (key,))
    if row:
        return row["body"]
    page, _ = sources.fetch_page(url.rstrip("/") + "/music")
    m = _BAND.search(page)
    band = json.loads(html.unescape(m.group(1))) if m else {}
    out = {"name": band.get("name"), "is_label": bool(band.get("is_label")),
           "band_id": band.get("id"), "url": url.rstrip("/"),
           "image": bandcamp_image(band.get("image_id") or band.get("bio_image_id"))}
    db.run("""insert into remote_cache(key, body, fetched_at) values(%s,%s,now())
              on conflict (key) do update set body=excluded.body, fetched_at=now()""",
           (key, json.dumps(out)))
    return out


def bandcamp_roster(url: str, most: int = 60) -> list[dict]:
    """The acts on a label, from its artists page."""
    page, _ = sources.fetch_page(url.rstrip("/") + "/artists")
    out, seen = [], set()
    for m in _ROSTER.finditer(page):
        name = html.unescape(m.group("name")).strip()
        link = html.unescape(m.group("url")).split("?")[0].rstrip("/")
        if not name or link in seen:
            continue
        seen.add(link)
        out.append({"name": name, "url": link})
        if len(out) >= most:
            break
    return out


def bandcamp_discography(url: str, newest: int = 40) -> list[dict]:
    """A band's records, newest first, as its music page lists them: title, artist
    (a label's items each say whose), the page, the art. No dates — those are on the
    record's own page, one fetch each, so the caller asks only about what is new."""
    return bandcamp_music(url, newest=newest)["records"]


def bandcamp_music(url: str, newest: int = 40) -> dict:
    """A Bandcamp page's records, newest first, and whether it acts as a label.

    The music page draws its first dozen or so records into the page and hands the rest
    to its script as JSON, so both are read, in that order. Reading only the JSON — as
    this once did — found nothing on a page short enough to have none, and skipped the
    newest records of every page that had some. The JSON's links are mostly relative,
    and are made whole here: "/album/r4" names a record on every label at once. A page
    with one record sends /music straight to it, which is read as a list of one.
    """
    page, final = sources.fetch_page(url.rstrip("/") + "/music")
    m = _BAND.search(page)
    band = json.loads(html.unescape(m.group(1))) if m else {}
    records: list[dict] = []
    seen: set[str] = set()

    def add(href: str | None, title: str | None, artist: str | None, art_id,
            kind: str | None) -> None:
        if not href or not title:
            return
        link = urllib.parse.urljoin(final, html.unescape(href)).split("?")[0].split("#")[0]
        if link in seen:
            return
        seen.add(link)
        records.append({"remote_id": link, "title": " ".join(title.split()),
                        "artist": " ".join(artist.split()) if artist else None,
                        "cover": bandcamp_art(art_id), "record_type": kind or "album"})

    start = page.find('<ol id="music-grid"')
    if start >= 0:
        end = page.find("</ol>", start)
        grid = page[start:end if end > 0 else None]
        for li in _GRID_ITEM.finditer(grid):
            title = li.group("title")
            override = _OVERRIDE.search(title)
            art = _GRID_ART.search(li.group(0))
            add(li.group("href"), html.unescape(re.sub(r"<[^>]+>", "", title.split("<br")[0])),
                html.unescape(override.group(1)) if override else None,
                art.group(1) if art else None, li.group("kind"))
        cm = _CLIENT_ITEMS.search(grid)
        for it in json.loads(html.unescape(cm.group(1))) if cm else []:
            add(it.get("page_url"), it.get("title"), it.get("artist"), it.get("art_id"),
                it.get("type"))
    elif "/album/" in final or "/track/" in final:
        t = sources._TRALBUM.search(page)
        data = json.loads(html.unescape(t.group(1))) if t else {}
        current = data.get("current") or {}
        add(final, current.get("title"), data.get("artist"), data.get("art_id"),
            "track" if "/track/" in final else "album")

    name = (band.get("name") or "").lower()
    others = [r["artist"].lower() for r in records
              if r["artist"] and r["artist"].lower() != name]
    label_like = len(set(others)) >= LABEL_ACTS and 2 * len(others) >= len(records)
    return {"name": band.get("name"),
            "is_label": bool(band.get("is_label")) or label_like,
            "records": records[:newest]}


def bandcamp_record(url: str) -> dict:
    """One record's page: its release date, its tags, and who bought it and said why.

    The date and tags are in the page; the "supported by" box is a second JSON blob
    on it, with each fan's few words and their favourite track. All three things the
    Discover feed shows under a song, from the one page.
    """
    page = sources._get_page(url)
    m = sources._TRALBUM.search(page)
    data = json.loads(html.unescape(m.group(1))) if m else {}
    current = data.get("current") or {}
    stamp = current.get("release_date") or data.get("album_release_date")
    released = None
    if stamp:
        try:
            released = dt.datetime.strptime(stamp[:11], "%d %b %Y").date().isoformat()
        except ValueError:
            released = None
    reviews = []
    cm = _COLLECTORS.search(page)
    if cm:
        try:
            blob = json.loads(html.unescape(cm.group(1)))
        except ValueError:
            blob = {}
        for r in blob.get("reviews") or []:
            if not (r.get("why") or "").strip():
                continue
            reviews.append({"name": r.get("name") or r.get("username") or "somebody",
                            "text": r["why"].strip(), "favourite": r.get("fav_track_title"),
                            "avatar": bandcamp_image(r.get("image_id"), 2)})
    tags = []
    for t in _TAG.findall(page):
        t = html.unescape(t).strip().lower()
        if t and t not in tags:
            tags.append(t)
    return {"title": current.get("title"), "artist": data.get("artist"),
            "release_date": released, "tags": tags, "reviews": reviews,
            "about": (current.get("about") or "").strip() or None,
            "cover": bandcamp_art(data.get("art_id"), 10)}


def soundcloud_track(track_id: str) -> dict:
    """A SoundCloud track's genre and tags, and its latest comments."""
    t = _sc_api(f"/tracks/{track_id}")
    tags = []
    if t.get("genre"):
        tags.append(t["genre"].lower())
    for tag in re.findall(r'"([^"]+)"|(\S+)', t.get("tag_list") or ""):
        word = (tag[0] or tag[1]).strip().lower()
        if word and word not in tags:
            tags.append(word)
    comments = []
    try:
        page = _sc_api(f"/tracks/{track_id}/comments", threaded=0, limit=12, sort="newest")
        for c in page.get("collection") or []:
            text = (c.get("body") or "").strip()
            if text:
                comments.append({"name": (c.get("user") or {}).get("username") or "somebody",
                                 "text": text, "favourite": None,
                                 "avatar": (c.get("user") or {}).get("avatar_url")})
    except LinkError:
        pass
    return {"tags": tags, "reviews": comments, "about": (t.get("description") or "").strip() or None,
            "url": t.get("permalink_url")}


_FOLLOWING = {"soundcloud": _soundcloud_following,
              "bandcamp": _bandcamp_following,
              "deezer": _deezer_following}


def following(provider: str, handle: str) -> list[dict]:
    """Who this account follows over there."""
    fetch = _FOLLOWING.get(provider)
    if not fetch:
        raise LinkError(f"{provider} does not say who you follow.")
    return fetch(handle)


# ---------------------------------------------------------------- registry
_PROFILE = {"deezer": _deezer_profile, "soundcloud": _soundcloud_profile,
            "bandcamp": _bandcamp_profile, "youtube": _youtube_profile}
_PLAYLISTS = {"deezer": _deezer_playlists, "soundcloud": _soundcloud_playlists,
              "bandcamp": _bandcamp_playlists, "youtube": _youtube_playlists}
_ITEMS = {"deezer": _deezer_items, "soundcloud": _soundcloud_items,
          "bandcamp": _bandcamp_items, "youtube": _youtube_items}


def check(provider: str, handle: str) -> dict:
    if provider not in _PROFILE:
        raise LinkError(f"{provider} cannot be linked")
    return _PROFILE[provider](handle)


def playlists(provider: str, handle: str, user_id: int | None = None) -> list[dict]:
    # YouTube reads a library rather than a public page, so it is asked with the stored
    # sign-in and not with the name on the account.
    if provider == "youtube":
        return _PLAYLISTS[provider](_secret(user_id, provider) or handle)
    return _PLAYLISTS[provider](handle)


def items(provider: str, remote_id: str, offset: int = 0,
          user_id: int | None = None) -> tuple[list[dict], int | None]:
    """A run of tracks, and where to resume — None when that was all of them."""
    if provider == "bandcamp":
        return _bandcamp_items(remote_id, offset)
    if provider == "youtube":
        # A public playlist needs no sign-in; your own library does.
        return _youtube_items(remote_id, _secret(user_id, provider)), None
    return _ITEMS[provider](remote_id), None


# ---------------------------------------------------------------- storage
def link(user_id: int, provider: str, profile: dict) -> dict:
    """Remember an account. A profile may carry a `secret` — YouTube's sign-in does —
    and that is kept apart from the name, so listing accounts can never hand it out."""
    db.run(
        """insert into provider_accounts(user_id, provider, account_id, display_name,
                                         access_token)
           values(%s,%s,%s,%s,%s)
           on conflict (user_id, provider)
           do update set account_id=excluded.account_id,
                         display_name=excluded.display_name,
                         access_token=excluded.access_token, linked_at=now()""",
        (user_id, provider, profile["handle"], profile.get("display_name"),
         profile.get("secret")),
    )
    return account(user_id, provider)


def _secret(user_id: int | None, provider: str) -> str | None:
    """The credential behind a linked account, for the code that needs it. Never part
    of anything an endpoint returns."""
    if user_id is None:
        return None
    row = db.one(
        "select access_token from provider_accounts where user_id=%s and provider=%s",
        (user_id, provider),
    )
    return (row or {}).get("access_token")


def unlink(user_id: int, provider: str) -> None:
    db.run("delete from provider_accounts where user_id=%s and provider=%s",
           (user_id, provider))


def account(user_id: int, provider: str) -> dict | None:
    return db.one(
        """select provider, account_id as handle, display_name, linked_at
             from provider_accounts where user_id=%s and provider=%s""",
        (user_id, provider),
    )


def accounts(user_id: int) -> list[dict]:
    return db.all_(
        """select provider, account_id as handle, display_name, linked_at
             from provider_accounts where user_id=%s order by provider""",
        (user_id,),
    )


_BIO = re.compile(r'<p id="bio-text"[^>]*>(.*?)</p>', re.S)
_BIO_PIC = re.compile(r'class="[^"]*bio-pic[^"]*"[^>]*>.*?<img[^>]+src="(https://f\d\.bcbits\.com/img/[^"]+)"', re.S)


def _plain(fragment: str) -> str:
    text = re.sub(r"<br\s*/?>", "\n", fragment)
    text = re.sub(r"<[^>]+>", "", text)
    return re.sub(r"\n{3,}", "\n\n", html.unescape(text)).strip()


def bandcamp_band_page(url: str) -> dict:
    """A Bandcamp page whole: who it is, whether it is a label, its picture and its
    own few words about itself, the acts on it if it is a label, and its records.
    Three fetches at most; kept a day, since a page is looked at more than once."""
    root = url.rstrip("/").split("?")[0]
    key = f"bc:page:{root.lower()}"
    row = db.one("select body from remote_cache where key=%s and fetched_at > now() - "
                 "interval '1 day'", (key,))
    if row:
        return row["body"]
    band = bandcamp_band(root)
    front = sources._get_page(root + "/")
    bio = _BIO.search(front)
    pic = _BIO_PIC.search(front)
    out = {
        "url": root, "name": band.get("name"), "is_label": bool(band.get("is_label")),
        "image": (pic.group(1) if pic else None) or band.get("image"),
        "about": _plain(bio.group(1)) if bio else None,
        "roster": bandcamp_roster(root) if band.get("is_label") else [],
        "records": bandcamp_discography(root, newest=60),
    }
    db.run("""insert into remote_cache(key, body, fetched_at) values(%s,%s,now())
              on conflict (key) do update set body=excluded.body, fetched_at=now()""",
           (key, json.dumps(out)))
    return out


def bandcamp_root_of(track_url: str | None) -> str | None:
    """The band's page from one of its track or album pages: the host is the band."""
    m = re.match(r"(https?://[^/]+)/(track|album)/", track_url or "")
    return m.group(1) if m else None


def about_artist(name: str, *, bandcamp_url: str | None = None) -> dict:
    """An artist's own few words about themselves, from where their music came from
    first and anywhere else that has them after: the Bandcamp page's bio, the SoundCloud
    profile's description, YouTube Music's artist blurb. Kept a week."""
    from . import routes_browse
    key = f"about:{routes_browse.fold(name)}"
    row = db.one("select body from remote_cache where key=%s and fetched_at > now() - "
                 "interval '7 days'", (key,))
    if row:
        return row["body"]
    text, source, url = None, None, None
    # Where their songs here came from, most first.
    rows = db.all_(
        """select s.provider, s.provider_id, s.raw, count(*) n
             from tracks t join track_sources s on s.track_id = t.id
            where s.provider in ('bandcamp', 'soundcloud')
              and exists (select 1 from unnest(t.artists) a where artist_key(a) = artist_key(%s))
            group by 1, 2, 3 order by n desc limit 6""", (name,))
    tried: set[str] = set()
    sources_ = []
    if bandcamp_url:
        sources_.append(("bandcamp", bandcamp_url))
    for r in rows:
        raw = r["raw"] if isinstance(r["raw"], dict) else json.loads(r["raw"] or "{}")
        if r["provider"] == "bandcamp":
            root = bandcamp_root_of(raw.get("url") or raw.get("pageUrl"))
            if root:
                sources_.append(("bandcamp", root))
        else:
            sources_.append(("soundcloud", r["provider_id"]))
    sources_.append(("ytmusic", name))
    for kind, ref in sources_:
        if (kind, ref) in tried:
            continue
        tried.add((kind, ref))
        try:
            if kind == "bandcamp":
                page = bandcamp_band_page(ref)
                if page.get("about"):
                    text, source, url = page["about"], "bandcamp", page["url"]
            elif kind == "soundcloud":
                t = _sc_api(f"/tracks/{ref}")
                user = t.get("user") or {}
                if user.get("id"):
                    u = _sc_api(f"/users/{user['id']}")
                    if (u.get("description") or "").strip():
                        text, source, url = u["description"].strip(), "soundcloud", u.get("permalink_url")
            else:
                from . import ytm
                want = routes_browse.fold(name)
                for hit in ytm.search_artists(name, limit=3):
                    if routes_browse.fold(hit["title"]) != want:
                        continue
                    a = ytm.artist(hit["browse_id"])
                    if (a.get("description") or "").strip():
                        text, source = a["description"].strip(), "youtube music"
                        url = f"https://music.youtube.com/channel/{hit['browse_id']}"
                    break
        except Exception as e:  # noqa: BLE001 — the next place may have it
            log.info("about %s via %s: %s", name, kind, e)
        if text:
            break
    out = {"name": name, "text": text, "source": source, "url": url}
    db.run("""insert into remote_cache(key, body, fetched_at) values(%s,%s,now())
              on conflict (key) do update set body=excluded.body, fetched_at=now()""",
           (key, json.dumps(out)))
    return out
