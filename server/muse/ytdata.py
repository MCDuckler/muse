"""YouTube's own API, for reading one person's library after a code sign-in.

YouTube Music's internal API — the one ytmusicapi speaks — serves a library only to its
own apps' sign-ins: a token from a Google project of your own gets "Request contains an
invalid argument" on every library call. The YouTube Data API is the public door to the
same account, and it takes exactly that token. A playlist made in YouTube Music is an
ordinary YouTube playlist underneath, and every item comes back with its video id, which
is what the library keys on.

What it cannot see: playlists somebody else made and you saved (they are public, so a
link still works), and the mixes YouTube Music generates. Liked Songs is every liked
video, narrowed here to the ones that are music.

The Google project needs "YouTube Data API v3" enabled. Quota is 10,000 units a day and
a page of fifty costs one, so a library of thousands of songs is a few hundred units.
"""
from __future__ import annotations

import hashlib
import json
import logging
import re
import time

import httpx

log = logging.getLogger("muse.ytdata")

API = "https://www.googleapis.com/youtube/v3"
CODE_URL = "https://oauth2.googleapis.com/device/code"
TOKEN_URL = "https://oauth2.googleapis.com/token"
SCOPE = "https://www.googleapis.com/auth/youtube.readonly"
DEVICE_GRANT = "urn:ietf:params:oauth:grant-type:device_code"
TIMEOUT = 20
PAGE = 50


class Refused(RuntimeError):
    """Google said no to the sign-in itself: revoked, expired, or never finished."""

    def __init__(self, message: str, reason: str = ""):
        super().__init__(message)
        self.reason = reason


class Failed(RuntimeError):
    """The API answered with an error that is not about the sign-in."""

    def __init__(self, message: str, reason: str = "", status: int = 0):
        super().__init__(message)
        self.reason = reason
        self.status = status


# ---------------------------------------------------------------- signing in

def start(client_id: str) -> dict:
    """Ask Google for a code to read out."""
    r = httpx.post(CODE_URL, data={"client_id": client_id, "scope": SCOPE},
                   timeout=TIMEOUT)
    body = _json(r)
    if "device_code" not in body:
        raise Refused(str(body.get("error_description") or body.get("error") or body),
                      str(body.get("error") or ""))
    return body


def finish(client_id: str, client_secret: str, device_code: str) -> dict:
    """The token, once the code has been typed in. Refused("authorization_pending")
    until then, which means "not yet" rather than "no"."""
    r = httpx.post(TOKEN_URL, data={"client_id": client_id,
                                    "client_secret": client_secret,
                                    "device_code": device_code,
                                    "grant_type": DEVICE_GRANT}, timeout=TIMEOUT)
    body = _json(r)
    if "refresh_token" not in body:
        error = str(body.get("error") or "not finished yet")
        raise Refused(error, error)
    return body


def stored(token: dict) -> str:
    """What is kept for a sign-in. Only the refresh token lasts; an access token is
    good for an hour and is asked for again when it is needed."""
    return json.dumps({"api": "youtube-data", "refresh_token": token["refresh_token"],
                       "scope": token.get("scope") or SCOPE})


def is_token(auth: str | None) -> bool:
    return bool(auth) and '"refresh_token"' in auth


_access: dict[str, tuple[str, float]] = {}


def _access_token(auth: str, client: tuple[str, str], fresh: bool = False) -> str:
    key = hashlib.sha256(auth.encode()).hexdigest()
    have = _access.get(key)
    if have and not fresh and have[1] > time.time() + 60:
        return have[0]
    client_id, client_secret = client
    r = httpx.post(TOKEN_URL, data={"client_id": client_id,
                                    "client_secret": client_secret,
                                    "refresh_token": json.loads(auth)["refresh_token"],
                                    "grant_type": "refresh_token"}, timeout=TIMEOUT)
    body = _json(r)
    if "access_token" not in body:
        _access.pop(key, None)
        error = str(body.get("error") or r.status_code)
        raise Refused(
            "The YouTube sign-in no longer works — it was revoked, or made with a "
            f"different Google client. Link YouTube again. ({error})", error)
    _access[key] = (body["access_token"], time.time() + int(body.get("expires_in", 3600)))
    return body["access_token"]


def forget(auth: str) -> None:
    _access.pop(hashlib.sha256(auth.encode()).hexdigest(), None)


# ---------------------------------------------------------------- asking

def _json(r: httpx.Response) -> dict:
    try:
        body = r.json()
    except ValueError:
        return {"error": f"HTTP {r.status_code}"}
    return body if isinstance(body, dict) else {}


def _get(auth: str, client: tuple[str, str], path: str, **params) -> dict:
    """One call, with one retry on a fresh access token if the old one was turned down."""
    for fresh in (False, True):
        token = _access_token(auth, client, fresh=fresh)
        r = httpx.get(f"{API}/{path}", params=params, timeout=TIMEOUT,
                      headers={"Authorization": f"Bearer {token}"})
        if r.status_code == 401 and not fresh:
            continue
        body = _json(r)
        if r.status_code < 400:
            return body
        error = body.get("error") if isinstance(body.get("error"), dict) else {}
        reasons = [e.get("reason", "") for e in error.get("errors") or []]
        reason = reasons[0] if reasons else str(error.get("status") or "")
        message = error.get("message") or f"HTTP {r.status_code}"
        if r.status_code == 401:
            raise Refused(f"YouTube turned the sign-in away: {message}", reason)
        if reason in ("accessNotConfigured", "SERVICE_DISABLED") or \
                "has not been used in project" in message:
            raise Failed(
                "YouTube Data API v3 is not enabled on the Google project this server "
                "signs in with. Enable it in the Google Cloud console "
                "(APIs & Services → Library), then try again.", reason, r.status_code)
        if reason in ("quotaExceeded", "dailyLimitExceeded", "rateLimitExceeded"):
            raise Failed("YouTube's daily quota for this server is used up; it resets "
                         "at midnight Pacific time.", reason, r.status_code)
        raise Failed(f"YouTube answered {r.status_code}: {message}", reason, r.status_code)
    raise AssertionError("unreachable")


def _pages(auth: str, client: tuple[str, str], path: str, limit: int, **params):
    token = None
    seen = 0
    while seen < limit:
        body = _get(auth, client, path, maxResults=min(PAGE, limit - seen),
                    **({"pageToken": token} if token else {}), **params)
        items = body.get("items") or []
        yield from items
        seen += len(items)
        token = body.get("nextPageToken")
        if not token or not items:
            return


# ---------------------------------------------------------------- a library

NO_CHANNEL = ("channelNotFound", "youtubeSignupRequired")


def account_name(auth: str, client: tuple[str, str]) -> str:
    items = _get(auth, client, "channels", part="snippet", mine="true").get("items") or []
    return (items[0]["snippet"].get("title") if items else None) or "YouTube"


def playlists(auth: str, client: tuple[str, str], limit: int = 200) -> list[dict]:
    """The playlists this account made. An account with no channel has none, rather
    than an error."""
    try:
        rows = list(_pages(auth, client, "playlists", limit,
                           part="snippet,contentDetails", mine="true"))
    except Failed as e:
        if e.reason in NO_CHANNEL:
            return []
        raise
    out = []
    for row in rows:
        snippet = row.get("snippet") or {}
        out.append({
            "remote_id": row["id"],
            "name": (snippet.get("title") or "Untitled").strip(),
            "count": (row.get("contentDetails") or {}).get("itemCount"),
            "owner": snippet.get("channelTitle"),
            "image": _thumbnail(snippet),
        })
    return out


def playlist_name(auth: str, client: tuple[str, str], playlist_id: str) -> str | None:
    items = _get(auth, client, "playlists", part="snippet", id=playlist_id).get("items")
    return ((items or [{}])[0].get("snippet") or {}).get("title")


def playlist_tracks(auth: str, client: tuple[str, str], playlist_id: str,
                    limit: int = 2000) -> list[dict]:
    """Everything in one playlist, in order. Deleted and private videos drop out on
    their own: the videos call does not return them, and they carry no song anyway."""
    video_ids = [vid for row in _pages(auth, client, "playlistItems", limit,
                                       part="contentDetails", playlistId=playlist_id)
                 if (vid := (row.get("contentDetails") or {}).get("videoId"))]
    videos = {}
    for i in range(0, len(video_ids), PAGE):
        chunk = video_ids[i:i + PAGE]
        for v in _get(auth, client, "videos", part="snippet,contentDetails",
                      id=",".join(chunk), maxResults=PAGE).get("items") or []:
            videos[v["id"]] = v
    return [t for t in (_track(videos[v]) for v in video_ids if v in videos) if t]


def liked_songs(auth: str, client: tuple[str, str], limit: int = 5000) -> list[dict]:
    """Liked videos that are music. YouTube Music's own Liked Songs is the same list
    narrowed the same way; the API only offers the unnarrowed one."""
    return [t for t in (_track(v) for v in _pages(
        auth, client, "videos", limit, part="snippet,contentDetails", myRating="like"))
        if t and t["raw"].get("music")]


def check(auth: str, client: tuple[str, str]) -> None:
    """One cheap call that fails the way a real one would."""
    playlists(auth, client, limit=1)


# ---------------------------------------------------------------- one video, as a song

_DURATION = re.compile(r"P(?:(\d+)D)?T?(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?")
_NOISE = re.compile(
    r"\s*[\(\[](?:official\s*(?:music\s*)?(?:video|audio|visuali[sz]er|lyric video)|"
    r"lyrics?(?:\s*video)?|audio|visuali[sz]er|hd|4k)[\)\]]", re.I)
MUSIC_CATEGORY = "10"


def _seconds(iso: str | None) -> int | None:
    m = _DURATION.fullmatch(iso or "")
    if not m or not any(m.groups()):
        return None
    d, h, mi, s = (int(g or 0) for g in m.groups())
    return ((d * 24 + h) * 60 + mi) * 60 + s


def _thumbnail(snippet: dict) -> str | None:
    thumbs = snippet.get("thumbnails") or {}
    for size in ("maxres", "standard", "high", "medium", "default"):
        if (thumbs.get(size) or {}).get("url"):
            return thumbs[size]["url"]
    return None


def _auto_generated(description: str) -> tuple[str, list[str], str | None] | None:
    """Title, artists and album from the description YouTube writes for a song.

    Every upload a label delivers to YouTube Music says the same thing in the same
    shape — "Provided to YouTube by …", then "Title · Artist · Artist", then the album —
    which is the one place the Data API carries a real album credit.
    """
    if not description.startswith("Provided to YouTube by"):
        return None
    parts = [p.strip() for p in description.split("\n\n") if p.strip()]
    if len(parts) < 2 or " · " not in parts[1]:
        return None
    title, *artists = [x.strip() for x in parts[1].split(" · ")]
    album = parts[2] if len(parts) > 2 and not parts[2].startswith(("℗", "©")) else None
    return title, artists, album


def _track(video: dict) -> dict | None:
    """A video, in the shape a mirror expects. Nothing is matched: the id is the song."""
    video_id = video.get("id")
    snippet = video.get("snippet") or {}
    if not video_id or not snippet:
        return None
    channel = (snippet.get("channelTitle") or "").strip()
    title = (snippet.get("title") or "").strip()
    album = None
    auto = _auto_generated(snippet.get("description") or "")
    if auto:
        title, artists, album = auto
    elif channel.endswith(" - Topic"):
        artists = [channel.removesuffix(" - Topic")]
    elif " - " in title:
        # "Artist - Song (Official Video)", the way a music video is usually named.
        artist, title = title.split(" - ", 1)
        artists = [artist.strip()]
    else:
        artists = [channel.removesuffix("VEVO").strip()] if channel else []
    seconds = _seconds((video.get("contentDetails") or {}).get("duration"))
    music = (snippet.get("categoryId") == MUSIC_CATEGORY or bool(auto)
             or channel.endswith(" - Topic"))
    return {
        "remote_id": video_id,
        "video_id": video_id,
        "title": _NOISE.sub("", title).strip() or title,
        "artists": artists,
        "album": album,
        "duration_ms": seconds * 1000 if seconds else None,
        "raw": {"videoId": video_id, "music": music},
    }
