"""YouTube Music lookups. Search needs no auth; the audio never comes from here."""
from __future__ import annotations

import hashlib
import json
import logging
import re
from functools import lru_cache

from . import db

log = logging.getLogger("muse.ytm")


class Unavailable(RuntimeError):
    """YouTube did not answer with an answer.

    It serves this address a challenge page from time to time — the same reason the
    audio has to be fetched from a machine at home — and the library parses that page
    as JSON and throws. Callers can carry on without it; searching what is already here
    must not stop working because somebody else's server is in a mood.
    """


@lru_cache(maxsize=1)
def _client():
    from ytmusicapi import YTMusic

    return YTMusic()


def _ask(what, *args, **kwargs):
    """One retry with a fresh session, then say so plainly.

    The client keeps a context it fetched once; when that goes stale every call comes
    back as a page instead of JSON, and only rebuilding it helps.
    """
    try:
        return what(_client(), *args, **kwargs)
    except Exception as first:
        _client.cache_clear()
        try:
            return what(_client(), *args, **kwargs)
        except Exception as second:
            log.warning("youtube music refused: %s / %s", first, second)
            raise Unavailable(str(second)) from second


def _flatten(item: dict) -> dict:
    dur = item.get("duration_seconds")
    return {
        "video_id": item.get("videoId"),
        "title": item.get("title"),
        "artists": [a["name"] for a in (item.get("artists") or []) if a.get("name")],
        "album": (item.get("album") or {}).get("name") if isinstance(item.get("album"), dict) else None,
        "duration_ms": int(dur) * 1000 if dur else None,
        "raw": item,
    }


def search_songs(query: str, limit: int = 10) -> list[dict]:
    """Songs, not videos: songs carry a real album and artist credit."""
    res = _ask(lambda c: c.search(query, filter="songs", limit=limit))
    return [_flatten(r) for r in res if r.get("videoId")]


def search_albums(query: str, limit: int = 6) -> list[dict]:
    """Records, so a search for one can be answered with the record itself."""
    res = _ask(lambda c: c.search(query, filter="albums", limit=limit))
    out = []
    for r in res:
        if not r.get("browseId"):
            continue
        out.append({
            "browse_id": r["browseId"],
            "title": r.get("title") or "",
            "artist": ", ".join(a.get("name", "") for a in (r.get("artists") or []))
                      or None,
            "year": r.get("year"),
            "thumbnail": thumbnail_url(r),
        })
    return out


def search_artists(query: str, limit: int = 4) -> list[dict]:
    res = _ask(lambda c: c.search(query, filter="artists", limit=limit))
    out = []
    for r in res:
        if not r.get("browseId"):
            continue
        out.append({
            "browse_id": r["browseId"],
            "title": r.get("artist") or r.get("title") or "",
            "subscribers": (f"{r['subscribers']} subscribers"
                            if r.get("subscribers") else None),
            "thumbnail": thumbnail_url(r),
        })
    return out


def album_tracks(browse_id: str) -> dict:
    """What is on a record, so one found in a search can be opened rather than guessed.

    Answers with the album's own details and its songs in the shape everything else
    here uses, so the same row draws a search hit and a track on a record.
    """
    data = _ask(lambda c: c.get_album(browse_id)) or {}
    tracks = []
    for t in data.get("tracks") or []:
        if not t.get("videoId"):
            continue
        tracks.append({
            "video_id": t["videoId"],
            "title": t.get("title") or "",
            "artists": [a.get("name") for a in (t.get("artists") or [])
                        if a.get("name")] or
                       [a.get("name") for a in (data.get("artists") or [])
                        if a.get("name")],
            "album": data.get("title"),
            "duration_ms": (t.get("duration_seconds") or 0) * 1000 or None,
            "raw": t,
        })
    return {
        "title": data.get("title") or "",
        "artist": ", ".join(a.get("name", "") for a in (data.get("artists") or []))
                  or None,
        "year": data.get("year"),
        "thumbnail": thumbnail_url(data),
        "tracks": tracks,
    }


def song(video_id: str) -> dict | None:
    res = _ask(lambda c: c.search(video_id, filter="songs", limit=1))
    for r in res:
        if r.get("videoId") == video_id:
            return _flatten(r)
    return None


def watch_playlist(video_id: str, limit: int = 25) -> list[dict]:
    """The radio tail for a seed track. Unauthenticated; returns ~50 candidates."""
    data = _ask(lambda c: c.get_watch_playlist(video_id, limit=limit))
    out = []
    for t in data.get("tracks", []):
        if not t.get("videoId"):
            continue
        length = t.get("length")  # "4:09"
        ms = None
        if isinstance(length, str) and ":" in length:
            parts = [int(p) for p in length.split(":")]
            ms = (parts[0] * 60 + parts[1]) * 1000 if len(parts) == 2 else \
                 (parts[0] * 3600 + parts[1] * 60 + parts[2]) * 1000
        out.append({
            "video_id": t["videoId"],
            "title": t.get("title"),
            "artists": [a["name"] for a in (t.get("artists") or []) if a.get("name")],
            "album": (t.get("album") or {}).get("name") if isinstance(t.get("album"), dict) else None,
            "duration_ms": ms,
            "raw": {"radio_seed": video_id},
        })
    return out


_GOOGLE_SIZE = re.compile(r"=w\d+-h\d+")


def thumbnail_url(raw: dict, px: int = 300) -> str | None:
    """Album art from a search payload, asked for at a useful size.

    The stored URLs are 60 or 120px because that is what YouTube Music's own list
    needs; the dimensions live in the URL, so a bigger one costs nothing.
    """
    thumbs = (raw or {}).get("thumbnails") or []
    if not thumbs:
        return None
    best = max(thumbs, key=lambda t: (t.get("width") or 0))
    url = best.get("url")
    return _GOOGLE_SIZE.sub(f"=w{px}-h{px}", url) if url else None


# ---------------------------------------------------------------- one person's library
#
# Search needs nobody's permission; "my playlists" and "songs I liked" are the opposite.
# ytmusicapi takes the same headers a signed-in browser sends, which is what the app
# asks for and what is stored — so this is the one linked service where what is kept is
# a credential rather than a public name.
class NotAllowed(RuntimeError):
    """The stored sign-in no longer works — usually expired, sometimes revoked."""


_authed_clients: dict[str, object] = {}


# What a signed-in browser sends, for a sign-in that arrives as a bare cookie.
_HEADER_BLOCK = (
    "cookie: {cookie}\n"
    "user-agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/120.0 Safari/537.36\n"
    "origin: https://music.youtube.com\n"
    "x-goog-authuser: 0\n"
    "accept-language: en-US,en;q=0.9"
)


def normalise_paste(blob: str) -> str:
    """Take whatever somebody pasted and make it something ytmusicapi will accept.

    Three things end up in that box: a token from the device flow, the whole block of
    request headers copied out of the developer tools, and — far more often, because it
    is the only part anybody can find — the cookie on its own. The last one used to be
    rejected as malformed, which is a sign-in refused for being the wrong shape rather
    than for being wrong.
    """
    text = (blob or "").strip()
    if not text or '"refresh_token"' in text or "cookie:" in text.lower():
        return text
    # A cookie is name=value pairs separated by semicolons, and a YouTube one always
    # carries one of these. Anything else is left alone to fail on its own terms.
    if "=" in text and any(k in text for k in
                           ("SAPISID", "__Secure-3PAPISID", "__Secure-1PAPISID")):
        return _HEADER_BLOCK.format(cookie=" ".join(text.split()))
    return text


def _authed(auth: str, cfg=None):
    """A client for one person's library.

    Two kinds of sign-in end up here: a token from the device flow, which refreshes
    itself and needs the OAuth client to do it, and a block of browser headers, which
    is what people paste. They are told apart by what is in them.
    """
    key = hashlib.sha256(auth.encode()).hexdigest()
    client = _authed_clients.get(key)
    if client is None:
        from ytmusicapi import YTMusic
        try:
            credentials = None
            if '"refresh_token"' in auth:
                from . import deps
                credentials = _oauth(cfg or deps.cfg())
            client = YTMusic(auth, oauth_credentials=credentials)
        except NotConfigured:
            raise
        except Exception as e:
            raise NotAllowed(f"YouTube Music would not take that sign-in: {e}") from e
        _authed_clients[key] = client
    return client


def forget_auth(auth: str) -> None:
    _authed_clients.pop(hashlib.sha256(auth.encode()).hexdigest(), None)


def playlist_id(text: str) -> str:
    """The id, from whatever somebody pasted — a link, a browse id, or the id itself."""
    value = (text or "").strip()
    if "list=" in value:
        value = value.split("list=", 1)[1].split("&", 1)[0]
    value = value.rstrip("/").rsplit("/", 1)[-1]
    return value[2:] if value.startswith("VL") else value


def _playlist_track(t: dict) -> dict | None:
    """One track from a playlist listing, in the shape a mirror expects.

    A YouTube Music item carries the video id, which is exactly what the library keys
    on — so nothing here has to be matched or guessed at.
    """
    video_id = t.get("videoId")
    if not video_id:
        return None                          # unavailable where you are, or taken down
    album = t.get("album")
    seconds = t.get("duration_seconds")
    return {
        "remote_id": video_id,
        "video_id": video_id,
        "title": (t.get("title") or "").strip(),
        "artists": [a["name"] for a in (t.get("artists") or []) if a.get("name")],
        "album": album.get("name") if isinstance(album, dict) else album,
        "duration_ms": int(seconds) * 1000 if seconds else None,
        "raw": {"videoId": video_id},
    }


def account_name(auth: str) -> str:
    """Whose library this is, for the screen that lists linked accounts."""
    try:
        info = _authed(auth).get_account_info()
        return (info or {}).get("accountName") or "YouTube Music"
    except NotAllowed:
        raise
    except Exception:
        # Not every sign-in exposes the account card; being able to read the library is
        # the thing that matters, and that is checked separately.
        return "YouTube Music"


def library_playlists(auth: str, limit: int = 200) -> list[dict]:
    """The playlists in somebody's library, with Liked Songs first."""
    try:
        rows = _authed(auth).get_library_playlists(limit=limit) or []
    except NotAllowed:
        raise
    except Exception as e:
        raise Unavailable(f"YouTube Music would not list your playlists: {e}") from e

    out = [{"remote_id": LIKED, "name": "Liked Songs", "count": None, "owner": "you",
            "image": None}]
    for row in rows:
        pid = row.get("playlistId")
        if not pid or pid == "LM":
            continue                          # Liked Songs is already at the top
        thumbs = row.get("thumbnails") or []
        out.append({
            "remote_id": pid,
            "name": (row.get("title") or "Untitled").strip(),
            "count": row.get("count"),
            "owner": (row.get("author") or [{}])[0].get("name")
            if isinstance(row.get("author"), list) else row.get("author"),
            "image": thumbs[-1]["url"] if thumbs else None,
        })
    return out


LIKED = "liked-songs"


def liked_songs(auth: str, limit: int = 5000) -> list[dict]:
    try:
        data = _authed(auth).get_liked_songs(limit=limit) or {}
    except NotAllowed:
        raise
    except Exception as e:
        raise Unavailable(f"YouTube Music would not list your liked songs: {e}") from e
    return [t for t in (_playlist_track(x) for x in data.get("tracks") or []) if t]


def playlist_tracks(remote_id: str, auth: str | None = None,
                    limit: int = 2000) -> list[dict]:
    """Everything in one playlist. Public ones need no sign-in at all."""
    if remote_id == LIKED:
        if not auth:
            raise NotAllowed("Liked Songs is private: link YouTube Music first.")
        return liked_songs(auth, limit=limit)

    pid = playlist_id(remote_id)
    client = _authed(auth) if auth else None
    try:
        data = (client.get_playlist(pid, limit=limit) if client
                else _ask(lambda c: c.get_playlist(pid, limit=limit))) or {}
    except NotAllowed:
        raise
    except Unavailable:
        raise
    except Exception as e:
        raise Unavailable(f"YouTube Music would not open that playlist: {e}") from e
    return [t for t in (_playlist_track(x) for x in data.get("tracks") or []) if t]


def playlist_name(remote_id: str, auth: str | None = None) -> str:
    if remote_id == LIKED:
        return "Liked Songs"
    pid = playlist_id(remote_id)
    try:
        client = _authed(auth) if auth else None
        data = (client.get_playlist(pid, limit=1) if client
                else _ask(lambda c: c.get_playlist(pid, limit=1))) or {}
        return (data.get("title") or "").strip() or pid
    except Exception:
        return pid


# ---------------------------------------------------------------- signing in properly
#
# Google will not let anybody sign in inside an embedded browser — a WebView that opens
# accounts.google.com is told "this browser or app may not be secure", and no user agent
# gets around it, because that is the point of the check. The way in that Google *does*
# support for something without a browser of its own is the device flow: the app shows a
# short code, the person types it into google.com/device in whatever browser they
# already trust, and the token comes back here. It also lasts, where a copied cookie
# expires.
#
# It needs an OAuth client of type "TV and Limited Input" from the Google Cloud console,
# named in muse.toml:
#
#     [ytmusic]
#     client_id = "….apps.googleusercontent.com"
#     client_secret = "…"
class NotConfigured(RuntimeError):
    """No OAuth client is set up, so the device flow cannot be offered."""


# Where an admin's pasted client is kept. The file is the other way in and stays
# authoritative: a server whose muse.toml names a client does not have to be told again
# through a screen.
CLIENT_ID_KEY = "ytmusic.client_id"
CLIENT_SECRET_KEY = "ytmusic.client_secret"


def _stored(key: str) -> str | None:
    try:
        row = db.one("select value from settings where key=%s", (key,))
    except Exception:                             # noqa: BLE001 — no database, no value
        return None
    return (row or {}).get("value") or None


def oauth_client(cfg) -> tuple[str | None, str | None, str | None]:
    """The OAuth client this server signs people in with, and where it came from."""
    from_file = (cfg.ytmusic or {}) if cfg else {}
    if from_file.get("client_id") and from_file.get("client_secret"):
        return from_file["client_id"], from_file["client_secret"], "config"
    stored_id, stored_secret = _stored(CLIENT_ID_KEY), _stored(CLIENT_SECRET_KEY)
    if stored_id and stored_secret:
        return stored_id, stored_secret, "settings"
    return None, None, None


def remember_oauth_client(client_id: str, client_secret: str) -> None:
    """Keep an admin's client, so nobody has to edit a file on the box to sign in."""
    for key, value in ((CLIENT_ID_KEY, client_id), (CLIENT_SECRET_KEY, client_secret)):
        db.run(
            """insert into settings(key, value, set_at) values(%s, %s, now())
                 on conflict (key) do update set value=excluded.value, set_at=now()""",
            (key, value))


def forget_oauth_client() -> None:
    db.run("delete from settings where key in (%s, %s)",
           (CLIENT_ID_KEY, CLIENT_SECRET_KEY))


def _oauth(cfg):
    from ytmusicapi.auth.oauth import OAuthCredentials

    client_id, client_secret, _ = oauth_client(cfg)
    if not client_id or not client_secret:
        raise NotConfigured(
            "This server has no YouTube OAuth client set up, so signing in has to be "
            "done by pasting the headers from a browser.")
    return OAuthCredentials(client_id=client_id, client_secret=client_secret)


def check_oauth_client(client_id: str, client_secret: str) -> None:
    """Ask Google whether this client can start a device sign-in at all.

    The cheapest true test there is: getting a code is the first half of the flow, and
    a client Google will not issue a code for is a client nobody can sign in with. The
    code is thrown away — it expires on its own in half an hour.
    """
    from ytmusicapi.auth.oauth import OAuthCredentials

    try:
        OAuthCredentials(client_id=client_id, client_secret=client_secret).get_code()
    except Exception as e:                        # noqa: BLE001
        raise NotAllowed(str(e))


def oauth_configured(cfg) -> bool:
    try:
        _oauth(cfg)
        return True
    except NotConfigured:
        return False


def oauth_start(cfg) -> dict:
    """Ask Google for a code to read out. First half of the device flow."""
    code = _oauth(cfg).get_code()
    return {
        "device_code": code["device_code"],
        "user_code": code["user_code"],
        "url": code.get("verification_url") or "https://google.com/device",
        "interval": code.get("interval", 5),
        "expires_in": code.get("expires_in", 1800),
    }


def oauth_finish(cfg, device_code: str) -> str:
    """Turn the code into a sign-in, once the person has typed it in.

    Answers with the blob to store. Raises NotAllowed while they have not finished —
    which is not an error, just "not yet".
    """
    token = _oauth(cfg).token_from_code(device_code)
    if "refresh_token" not in token:
        raise NotAllowed(str(token.get("error") or "not finished yet"))
    return json.dumps(token)
