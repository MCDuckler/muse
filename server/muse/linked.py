"""Accounts on other services, and the playlists they hold.

Spotify needed OAuth because everything about a Spotify account is private. These three
do not: a Deezer profile id, a SoundCloud username and a Bandcamp fan name are all
public reads, so linking one is typing a name rather than a round trip through a consent
screen. Nothing here can post, follow, or spend money — it can only read what anybody
with the link could read.
"""
from __future__ import annotations

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

PROVIDERS = ("deezer", "soundcloud", "bandcamp")


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
    handle = handle.strip().strip("/").split("/")[-1] if "soundcloud.com" in handle \
        else handle.strip().strip("/")
    r = subprocess.run([sources.YTDLP, "--no-warnings", "--flat-playlist", "-J",
                        "--playlist-items", "1",
                        f"https://soundcloud.com/{urllib.parse.quote(handle)}/tracks"],
                       capture_output=True, text=True, timeout=120)
    if r.returncode != 0:
        raise LinkError("SoundCloud has no public profile with that name.")
    data = json.loads(r.stdout or "{}")
    # The listing is titled "Name (Tracks)"; the name is the part worth keeping.
    name = data.get("uploader") or re.sub(r"\s*\(Tracks\)$", "",
                                          data.get("title") or "") or handle
    return {"handle": handle, "display_name": name}


def _soundcloud_playlists(handle: str) -> list[dict]:
    """The three lists a public profile actually has."""
    return [
        {"remote_id": f"{handle}/likes", "name": f"{handle} · Likes",
         "count": None, "owner": handle, "image": None},
        {"remote_id": f"{handle}/tracks", "name": f"{handle} · Tracks",
         "count": None, "owner": handle, "image": None},
        {"remote_id": f"{handle}/reposts", "name": f"{handle} · Reposts",
         "count": None, "owner": handle, "image": None},
    ]


def _soundcloud_items(remote_id: str, limit: int = 200) -> list[dict]:
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
        out.append({
            "remote_id": str(e["id"]),
            "title": e.get("title") or "",
            "artists": [e["uploader"]] if e.get("uploader") else [],
            "album": None,
            "duration_ms": int((e.get("duration") or 0) * 1000) or None,
            # Straight from SoundCloud, so no matching step: this *is* the track.
            "source": {"provider": "soundcloud", "provider_id": str(e["id"]),
                       "url": f"https://api.soundcloud.com/tracks/{e['id']}"},
        })
    return out


# ---------------------------------------------------------------- Bandcamp
_BLOB = re.compile(r'id="pagedata"[^>]*data-blob="([^"]+)"')


def _bandcamp_blob(username: str) -> dict:
    page = sources._get_page(f"https://bandcamp.com/{urllib.parse.quote(username)}")
    m = _BLOB.search(page)
    if not m:
        raise LinkError("Bandcamp has no fan page with that name.")
    return json.loads(html.unescape(m.group(1)))


def _bandcamp_profile(handle: str) -> dict:
    handle = handle.strip().strip("/").split("/")[-1]
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
        {"remote_id": f"{handle}/collection", "name": f"{handle} · Collection",
         "count": counts, "owner": handle, "image": None},
        {"remote_id": f"{handle}/wishlist", "name": f"{handle} · Wishlist",
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


# ---------------------------------------------------------------- registry
_PROFILE = {"deezer": _deezer_profile, "soundcloud": _soundcloud_profile,
            "bandcamp": _bandcamp_profile}
_PLAYLISTS = {"deezer": _deezer_playlists, "soundcloud": _soundcloud_playlists,
              "bandcamp": _bandcamp_playlists}
_ITEMS = {"deezer": _deezer_items, "soundcloud": _soundcloud_items,
          "bandcamp": _bandcamp_items}


def check(provider: str, handle: str) -> dict:
    if provider not in _PROFILE:
        raise LinkError(f"{provider} cannot be linked")
    return _PROFILE[provider](handle)


def playlists(provider: str, handle: str) -> list[dict]:
    return _PLAYLISTS[provider](handle)


def items(provider: str, remote_id: str,
          offset: int = 0) -> tuple[list[dict], int | None]:
    """A run of tracks, and where to resume — None when that was all of them."""
    if provider == "bandcamp":
        return _bandcamp_items(remote_id, offset)
    return _ITEMS[provider](remote_id), None


# ---------------------------------------------------------------- storage
def link(user_id: int, provider: str, profile: dict) -> dict:
    db.run(
        """insert into provider_accounts(user_id, provider, account_id, display_name)
           values(%s,%s,%s,%s)
           on conflict (user_id, provider)
           do update set account_id=excluded.account_id,
                         display_name=excluded.display_name, linked_at=now()""",
        (user_id, provider, profile["handle"], profile.get("display_name")),
    )
    return account(user_id, provider)


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
