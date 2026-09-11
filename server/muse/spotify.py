"""Linking a Spotify account to a muse user.

Tokens belong to a person, not to a config file: they expire, they are refreshed, and
each muse user links their own. What stays in the config is the app registration —
the client id and secret that identify *this* installation to Spotify.

Development mode is the permanent state of affairs here (extended quota needs 250k
monthly users), which decides the whole shape: read-only, and only playlists the
authenticated person owns or collaborates on.
"""
from __future__ import annotations

import base64
import logging
import secrets
import time
from urllib.parse import urlencode

import httpx

from . import db

log = logging.getLogger("muse.spotify")

AUTH_URL = "https://accounts.spotify.com/authorize"
TOKEN_URL = "https://accounts.spotify.com/api/token"
API = "https://api.spotify.com/v1"

# Read-only. muse never writes to Spotify, and asking for less is the difference
# between a scary consent screen and a boring one.
SCOPES = ("playlist-read-private playlist-read-collaborative user-library-read "
          "user-follow-read")

_states: dict[str, tuple[int, float]] = {}
STATE_TTL = 600


class NotLinked(RuntimeError):
    pass


class SpotifyBusy(RuntimeError):
    """Rate-limited. Not a failure of ours, and not permanent."""


class NotAllowed(RuntimeError):
    """Spotify accepted the sign-in and then refused the data.

    In Development mode this nearly always means one thing: the Spotify account is not
    listed under User Management in the app's dashboard. Spotify authorises anyone and
    only refuses at the API, which makes it look like a muse bug.
    """


class NotConfigured(RuntimeError):
    pass


def _app(cfg) -> tuple[str, str, str]:
    s = cfg.spotify or {}
    client_id, secret, redirect = (
        s.get("client_id", ""), s.get("client_secret", ""), s.get("redirect_uri", ""))
    if not (client_id and secret and redirect):
        raise NotConfigured(
            "Spotify is not set up on this server. Create an app at "
            "developer.spotify.com, then put client_id, client_secret and "
            "redirect_uri in muse.toml under [spotify]."
        )
    return client_id, secret, redirect


def authorize_url(cfg, user_id: int) -> str:
    client_id, _, redirect = _app(cfg)
    state = secrets.token_urlsafe(24)
    _states[state] = (user_id, time.time() + STATE_TTL)
    return f"{AUTH_URL}?" + urlencode({
        "client_id": client_id,
        "response_type": "code",
        "redirect_uri": redirect,
        "scope": SCOPES,
        "state": state,
        "show_dialog": "false",
    })


def consume_state(state: str) -> int:
    """One use, ten minutes. A replayed callback must not link someone else's account."""
    now = time.time()
    for key, (_, expires) in list(_states.items()):
        if expires < now:
            _states.pop(key, None)
    entry = _states.pop(state, None)
    if entry is None:
        raise RuntimeError("that sign-in link has expired — start again from settings")
    return entry[0]


def _basic(cfg) -> dict:
    client_id, secret, _ = _app(cfg)
    token = base64.b64encode(f"{client_id}:{secret}".encode()).decode()
    return {"Authorization": f"Basic {token}"}


def exchange_code(cfg, user_id: int, code: str) -> dict:
    _, _, redirect = _app(cfg)
    r = httpx.post(TOKEN_URL, headers=_basic(cfg), timeout=30, data={
        "grant_type": "authorization_code",
        "code": code,
        "redirect_uri": redirect,
    })
    r.raise_for_status()
    payload = r.json()
    me = httpx.get(f"{API}/me", timeout=30,
                   headers={"Authorization": f"Bearer {payload['access_token']}"})
    profile = me.json() if me.status_code == 200 else {}
    _store(user_id, payload, profile)
    return {"display_name": profile.get("display_name") or profile.get("id")}


def _store(user_id: int, payload: dict, profile: dict | None = None) -> None:
    db.run(
        """insert into provider_accounts(user_id, provider, display_name, account_id,
                                         access_token, refresh_token, expires_at)
           values(%s,'spotify',%s,%s,%s,%s, now() + (%s || ' seconds')::interval)
           on conflict (user_id, provider) do update
             set access_token=excluded.access_token,
                 refresh_token=coalesce(excluded.refresh_token,
                                        provider_accounts.refresh_token),
                 expires_at=excluded.expires_at,
                 display_name=coalesce(excluded.display_name,
                                       provider_accounts.display_name),
                 account_id=coalesce(excluded.account_id, provider_accounts.account_id)""",
        (user_id,
         (profile or {}).get("display_name") or (profile or {}).get("id"),
         (profile or {}).get("id"),
         payload["access_token"],
         payload.get("refresh_token"),
         int(payload.get("expires_in", 3600))),
    )


def account(user_id: int) -> dict | None:
    return db.one(
        """select display_name, account_id, linked_at,
                  expires_at < now() as expired
             from provider_accounts where user_id=%s and provider='spotify'""",
        (user_id,),
    )


def unlink(user_id: int) -> None:
    db.run("delete from provider_accounts where user_id=%s and provider='spotify'",
           (user_id,))


def access_token(cfg, user_id: int) -> str:
    """A valid token, refreshing it if the stored one has aged out."""
    row = db.one(
        """select access_token, refresh_token,
                  expires_at < now() + interval '60 seconds' as stale
             from provider_accounts where user_id=%s and provider='spotify'""",
        (user_id,),
    )
    if not row:
        raise NotLinked("no Spotify account is linked")
    if not row["stale"]:
        return row["access_token"]

    r = httpx.post(TOKEN_URL, headers=_basic(cfg), timeout=30, data={
        "grant_type": "refresh_token",
        "refresh_token": row["refresh_token"],
    })
    if r.status_code >= 400:
        raise NotLinked("Spotify sign-in has expired — link the account again")
    payload = r.json()
    _store(user_id, payload)
    return payload["access_token"]


# A library of twelve thousand songs is 240 pages, and Spotify starts saying no partway
# through. It tells us how long to wait; the only mistake would be not listening.
RATE_LIMIT_TRIES = 5
MAX_BACKOFF = 60.0


def _get(cfg, user_id: int, url: str, **params) -> dict:
    for attempt in range(RATE_LIMIT_TRIES):
        r = httpx.get(url if url.startswith("http") else f"{API}{url}",
                      headers={"Authorization": f"Bearer {access_token(cfg, user_id)}"},
                      params=params or None, timeout=30)
        if r.status_code != 429:
            break
        wait = min(float(r.headers.get("Retry-After") or 2 ** attempt), MAX_BACKOFF)
        log.info("spotify asked us to wait %.0fs (attempt %d)", wait, attempt + 1)
        time.sleep(wait)
    if r.status_code == 429:
        raise SpotifyBusy(
            "Spotify is rate-limiting this account. The import will pick up where it "
            "left off — try again in a few minutes.")
    if r.status_code == 403:
        raise NotAllowed(
            "Spotify signed you in but will not share your library. In Development "
            "mode it only serves accounts added under User Management in the app's "
            "dashboard — ask whoever set up this server to add your Spotify account "
            "there. (It can also mean the playlist belongs to someone else: only "
            "playlists you own or collaborate on are readable.)"
        )
    if r.status_code == 401:
        raise NotLinked("Spotify sign-in has expired — link the account again")
    r.raise_for_status()
    return r.json()


def playlists(cfg, user_id: int) -> list[dict]:
    """Everything mirrorable, with the two worth finding at the top.

    Liked Songs first — it is the list most people mean when they say "my music", and
    it is not in /me/playlists at all. Then whatever Shazam keeps here, because that is
    the other list somebody actually wants and it is otherwise a needle in a haystack:
    Shazam cannot be asked what has been tagged, but connect it to Spotify and it
    maintains a playlist for ever, which makes mirroring that playlist the whole of
    "sync my Shazams" — and one account here has four hundred and fifty-six playlists
    to find it among.
    """
    liked = _get(cfg, user_id, "/me/tracks", limit=1)
    out: list[dict] = [{
        "remote_id": LIKED,
        "name": "Liked Songs",
        "count": liked.get("total"),
        "owner": "you",
        "image": None,
    }]
    url, params = "/me/playlists", {"limit": 50}
    while url:
        page = _get(cfg, user_id, url, **params)
        for p in page.get("items", []):
            if not p:
                continue
            images = p.get("images") or []
            # Development mode returns a stripped object: no `tracks` and no `images`.
            # Reporting "0 songs" for a full playlist is worse than reporting nothing,
            # so the count stays null until the playlist is actually read.
            total = (p.get("tracks") or {}).get("total")
            out.append({
                "remote_id": p["id"],
                "name": (p.get("name") or "Untitled").strip(),
                "count": total,
                "owner": (p.get("owner") or {}).get("display_name"),
                "image": images[0]["url"] if images else None,
            })
        url, params = page.get("next"), {}

    # Shazam's own list, straight after Liked Songs.
    #
    # Matched on the word rather than on the exact title: Spotify names it in the
    # account's own language — this one has both "My Shazam Tracks" and "Meine
    # Shazam-Titel" — and the brand is the one part that is never translated.
    liked_first, shazam, rest = out[:1], [], []
    for entry in out[1:]:
        if "shazam" in entry["name"].lower():
            entry["shazam"] = True
            shazam.append(entry)
        else:
            rest.append(entry)
    return liked_first + shazam + rest


def playlist(cfg, user_id: int, remote_id: str) -> dict:
    """One playlist's own description of itself.

    A mirror queued from a name the app already knew carries it along; one queued from
    an id alone does not, and a playlist row cannot be nameless — so it used to be
    named after the id, which is how a library filled up with 3J2c5PZcDg3ciEqtMfddGB.
    """
    p = _get(cfg, user_id, f"/playlists/{remote_id}",
             fields="name,owner(display_name),tracks(total),images")
    images = p.get("images") or []
    return {
        "remote_id": remote_id,
        "name": (p.get("name") or "").strip() or "Untitled",
        "owner": (p.get("owner") or {}).get("display_name"),
        "count": (p.get("tracks") or {}).get("total"),
        # Spotify's own art for the list — a mosaic it made, or a picture somebody
        # uploaded. Either way it is what that playlist looks like to its owner.
        "image": images[0]["url"] if images else None,
    }


# Liked Songs is not a playlist as far as the API is concerned — it lives behind
# /me/tracks and has no id. It is one to a person, so a fixed sentinel stands in for the
# id everywhere a playlist id would go.
LIKED = "liked-songs"


def saved_tracks(cfg, user_id: int, offset: int = 0,
                 pages: int | None = None) -> tuple[list[dict], int | None]:
    """Hearted songs, newest first — Spotify's own order.

    Returns a page-run and where to carry on from, because twelve thousand of them is
    240 requests and Spotify starts saying no partway through. Stopping and resuming
    beats starting again.
    """
    out: list[dict] = []
    url, params = "/me/tracks", {"limit": 50, "offset": offset}
    fetched = 0
    # Where to carry on from is counted in *entries seen*, not entries kept. A local
    # file or a podcast in the middle of somebody's liked songs is skipped, and resuming
    # at "offset + how many we kept" then starts again short of where it stopped — the
    # next run re-reads ground it has already read, writes over the same positions, and
    # the import sits at twelve hundred songs for ever while every job reports success.
    seen = 0
    while url:
        page = _get(cfg, user_id, url, **params)
        for entry in page.get("items", []):
            seen += 1
            item = (entry or {}).get("track") or {}
            if not item.get("name") or item.get("type") not in (None, "track"):
                continue
            out.append(_track(item))
        url, params = page.get("next"), {}
        fetched += 1
        if pages is not None and fetched >= pages:
            return out, (offset + seen) if url else None
    return out, None


def followed_artists(cfg, user_id: int, limit: int = 50) -> list[dict]:
    """The artists this account follows on Spotify.

    Needs the user-follow-read scope, which older links were not asked for — an account
    linked before this returns nothing until it is linked again, and says so rather
    than looking empty.
    """
    out: list[dict] = []
    after = None
    while True:
        params = {"type": "artist", "limit": min(limit, 50)}
        if after:
            params["after"] = after
        page = (_get(cfg, user_id, "/me/following", **params) or {}).get("artists") or {}
        for a in page.get("items") or []:
            if a.get("name"):
                out.append({"name": a["name"], "image": (a.get("images") or [{}])[0].get("url")})
        after = (page.get("cursors") or {}).get("after")
        if not after or not page.get("items"):
            return out


def _track(item: dict) -> dict:
    return {
        "remote_id": item.get("id") or item.get("uri"),
        "title": item["name"],
        "artists": [a["name"] for a in item.get("artists", []) if a.get("name")],
        "album": (item.get("album") or {}).get("name"),
        "duration_ms": item.get("duration_ms"),
        "isrc": (item.get("external_ids") or {}).get("isrc"),
    }


def playlist_items(cfg, user_id: int, remote_id: str) -> list[dict]:
    if remote_id == LIKED:
        return saved_tracks(cfg, user_id)[0]
    """`/tracks` has been 403 since March 2026; `/items` is the replacement, and it
    renames the payload's fields as well as the path."""
    out, url, params = [], f"/playlists/{remote_id}/items", {"limit": 50}
    while url:
        page = _get(cfg, user_id, url, **params)
        for entry in page.get("items", []):
            item = (entry or {}).get("item") or (entry or {}).get("track") or {}
            if not item or item.get("type") not in (None, "track"):
                continue
            if not item.get("name"):
                continue
            out.append(_track(item))
        url, params = page.get("next"), {}
    return out
