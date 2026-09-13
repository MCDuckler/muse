"""Linking the services that do not need a consent screen, and mirroring their lists.

Spotify keeps its own module: it has OAuth, tokens to refresh and a dashboard that
decides who is allowed. These three are public reads, so they share one shape — a name,
a list of lists, and the same mirroring the Spotify side already does.
"""
from __future__ import annotations

import logging

from fastapi import APIRouter, Body, Depends, HTTPException

from . import catalog, db, jobs, linked, sync, ytm
from .deps import cfg, current_user
from .routes_accounts import is_admin

log = logging.getLogger("muse.linked")
router = APIRouter(prefix="/linked")

# Same rule as a Spotify mirror: past this many songs a list is a library, and the audio
# waits until something is played.
BIG_MIRROR = 400
RATE_LIMIT_WAIT = 900                                # a quarter of an hour, then resume


def _known(provider: str) -> None:
    if provider not in linked.PROVIDERS:
        raise HTTPException(404, f"{provider} is not one of the services muse can link")


@router.get("")
def list_accounts(user: dict = Depends(current_user)):
    """Every service, linked or not, so the screen can be built from one request."""
    have = {a["provider"]: a for a in linked.accounts(user["id"])}
    return {"accounts": [
        {"provider": p,
         "label": {"deezer": "Deezer", "soundcloud": "SoundCloud",
                   "bandcamp": "Bandcamp", "youtube": "YouTube Music"}[p],
         "hint": {
             "deezer": "The numeric id from your profile URL",
             # Say that pasting the link works, because that is what people do.
             "soundcloud": "Paste your profile link, or the name in it",
             "bandcamp": "Paste your fan page link, or the name in it",
             # The only one that needs a credential rather than a name: nothing about
             # a YouTube account is public, including the list of your own playlists.
             "youtube": "Sign in with a code, or paste the headers from a browser",
         }[p],
         "plays": p not in ("deezer", "youtube"),
         # How signing in works here. "code" is Google's device flow — the app shows a
         # short code and the person types it into a browser they already trust, which
         # is the only way in Google supports for something without a browser of its
         # own; an embedded one is refused as "not secure" whatever it claims to be.
         "sign_in": ("code" if p == "youtube" and ytm.oauth_configured(cfg())
                     else "name" if p != "youtube" else "paste"),
         "linked": have.get(p)}
        for p in linked.PROVIDERS]}


@router.post("/{provider}")
def link_account(provider: str, body: dict = Body(...), user: dict = Depends(current_user)):
    _known(provider)
    handle = (body.get("handle") or "").strip()
    if not handle:
        raise HTTPException(400, "handle required")
    try:
        profile = linked.check(provider, handle)
    except linked.LinkError as e:
        raise HTTPException(400, str(e))
    except Exception as e:
        raise HTTPException(502, f"{provider} did not answer: {e}")
    return linked.link(user["id"], provider, profile)


@router.get("/youtube/oauth/client")
def youtube_oauth_client(user: dict = Depends(current_user)):
    """Whether this server can sign people in with a code, and where that came from.

    Readable by anybody — it decides which of the two sign-in screens they are shown —
    but only ever says whether a client is set, never what it is.
    """
    client_id, _, where = ytm.oauth_client(cfg())
    return {
        "configured": bool(client_id),
        "from": where,
        # Whether this person can do anything about it. For everybody else the answer
        # to "why can I not sign in" is "ask whoever runs this".
        "may_set": is_admin(user["id"]),
        # The tail of it, so an admin can tell one client from another without the
        # server ever handing back a credential.
        "ends_with": client_id[-12:] if client_id else None,
    }


@router.put("/youtube/oauth/client")
def set_youtube_oauth_client(body: dict = Body(...),
                             user: dict = Depends(current_user)):
    """Give this server an OAuth client, from a screen rather than a file on the box.

    Checked with Google before it is kept: a client id with a typo in it would
    otherwise turn into a sign-in screen that fails for everybody a week later, with
    nothing to say why.
    """
    if not is_admin(user["id"]):
        raise HTTPException(403, "only an admin can set this")
    client_id = (body.get("client_id") or "").strip()
    client_secret = (body.get("client_secret") or "").strip()
    if not client_id or not client_secret:
        raise HTTPException(400, "client_id and client_secret required")
    try:
        ytm.check_oauth_client(client_id, client_secret)
    except ytm.NotAllowed as e:
        raise HTTPException(400, f"Google would not take that client: {e}")
    except Exception as e:                        # noqa: BLE001
        raise HTTPException(502, f"Google did not answer: {e}")
    ytm.remember_oauth_client(client_id, client_secret)
    return {"configured": True, "from": "settings", "ends_with": client_id[-12:]}


@router.delete("/youtube/oauth/client")
def clear_youtube_oauth_client(user: dict = Depends(current_user)):
    if not is_admin(user["id"]):
        raise HTTPException(403, "only an admin can clear this")
    ytm.forget_oauth_client()
    client_id, _, where = ytm.oauth_client(cfg())
    return {"configured": bool(client_id), "from": where}


@router.post("/youtube/oauth")
def youtube_oauth_start(user: dict = Depends(current_user)):
    """Begin signing in to YouTube Music: a code to read out, and where to type it."""
    try:
        return ytm.oauth_start(cfg())
    except ytm.NotConfigured as e:
        raise HTTPException(409, str(e))
    except Exception as e:                        # noqa: BLE001
        raise HTTPException(502, f"Google would not start a sign-in: {e}")


@router.post("/youtube/oauth/finish")
def youtube_oauth_finish(body: dict = Body(...), user: dict = Depends(current_user)):
    """Finish it, once the code has been typed in over there.

    A 409 means "not yet" rather than "no": the app asks again while somebody is still
    working through the pages on the other device.
    """
    device_code = (body.get("device_code") or "").strip()
    if not device_code:
        raise HTTPException(400, "device_code required")
    try:
        secret = ytm.oauth_finish(cfg(), device_code)
    except ytm.NotAllowed as e:
        # "access_denied" from Google is almost never somebody pressing cancel: it is
        # a consent screen still in Testing, which only serves the accounts listed on
        # it. Say that, because the message Google sends says nothing at all.
        if "access_denied" in str(e):
            raise HTTPException(
                403,
                "Google turned that account away. The sign-in this server uses is "
                "still in Testing, which only works for accounts listed on its "
                "consent screen — whoever set it up needs to publish the consent "
                "screen (Google Cloud console → APIs & Services → OAuth consent "
                "screen → Publish app), or add this account under Test users.")
        raise HTTPException(409, str(e))
    except ytm.NotConfigured as e:
        raise HTTPException(409, str(e))
    except Exception as e:                        # noqa: BLE001
        raise HTTPException(502, f"Google would not finish the sign-in: {e}")

    name = ytm.account_name(secret)
    return linked.link(user["id"], "youtube",
                       {"handle": name, "display_name": name, "secret": secret})


@router.delete("/{provider}")
def unlink_account(provider: str, user: dict = Depends(current_user)):
    _known(provider)
    linked.unlink(user["id"], provider)
    return {"unlinked": provider}


@router.get("/{provider}/playlists")
def list_playlists(provider: str, user: dict = Depends(current_user)):
    _known(provider)
    acc = linked.account(user["id"], provider)
    if not acc:
        raise HTTPException(409, f"No {provider} account is linked here yet.")
    try:
        remote = linked.playlists(provider, acc["handle"], user_id=user["id"])
    except linked.LinkError as e:
        raise HTTPException(400, str(e))

    mirrored = {r["remote_id"]: r for r in db.all_(
        """select remote_id, id as playlist_id, last_synced_at,
                  (select count(*) from playlist_items i where i.playlist_id=p.id) items
             from playlists p where owner_id=%s and kind=%s""",
        (user["id"], provider))}
    return {"items": [{**p, "mirror": mirrored.get(p["remote_id"])} for p in remote]}


@router.post("/{provider}/sync")
def sync_playlists(provider: str, body: dict = Body(default={}),
                   user: dict = Depends(current_user)):
    """Queue a mirror. The worker does the work — a collection can be hundreds of
    records, and that is not something to hold a request open for."""
    _known(provider)
    acc = linked.account(user["id"], provider)
    # A YouTube playlist somebody sent you is public: it can be mirrored without
    # linking anything. Your own library cannot, and says so.
    if not acc and not (provider == "youtube" and body.get("remote_id")):
        raise HTTPException(409, f"No {provider} account is linked here yet.")

    wanted = body.get("remote_ids") or ([body["remote_id"]] if body.get("remote_id")
                                        else None)
    if not wanted:
        raise HTTPException(400, "remote_id or remote_ids required")

    if provider == "youtube":
        # People paste links, not ids.
        from . import ytm
        wanted = [ytm.playlist_id(r) or r for r in wanted]

    for remote_id in wanted:
        jobs.enqueue("mirror", {"provider": provider, "user_id": user["id"],
                                "remote_id": remote_id,
                                "name": body.get("name") or remote_id})
    return {"queued": wanted}


def run_mirror_job(payload: dict) -> dict:
    """What the worker runs for one of these.

    Taken in runs, because a Bandcamp wishlist can be thirteen hundred records and each
    one is a page fetch. Each run keeps what it got and queues the next, so being cut
    off — by a rate limit, a restart, anything — costs a run rather than the lot.
    """
    provider = payload["provider"]
    user_id = int(payload["user_id"])
    remote_id = payload["remote_id"]
    offset = int(payload.get("offset") or 0)

    try:
        items, next_offset = linked.items(provider, remote_id, offset=offset,
                                          user_id=user_id)
    except linked.RateLimited:
        jobs.enqueue("mirror", {**payload, "offset": offset},
                     priority=jobs.PRIORITY_BULK, delay_seconds=RATE_LIMIT_WAIT)
        log.info("%s is rate-limiting; resuming at %s in %s minutes",
                 provider, offset, RATE_LIMIT_WAIT // 60)
        return {"waiting": f"{provider} is rate-limiting; will resume", "from": offset}

    # A mirror queued from a link alone carries no name, and a playlist row cannot be
    # nameless — which is how a library fills up with lists called PLxOdPtLRV6i.
    name = (payload.get("name") or "").strip()
    if name in ("", remote_id) and provider == "youtube":
        from . import ytm
        name = ytm.playlist_name(remote_id, linked._secret(user_id, provider))
    playlist_id = _playlist_for(user_id, provider, remote_id,
                                name or remote_id, payload.get("owner"))

    # The first run decides how this list behaves; later runs add to it. Past a few
    # hundred songs a mirror is a library, and the audio waits until something is played.
    if offset == 0:
        big = next_offset is not None or len(items) > BIG_MIRROR
        db.run("update playlists set download_mode=%s where id=%s",
               ("on_play" if big else "all", playlist_id))
        with db.pool().connection() as c:
            c.execute("delete from playlist_items where playlist_id=%s", (playlist_id,))
            c.execute("delete from playlist_unmatched where playlist_id=%s", (playlist_id,))
    download = db.one("select download_mode from playlists where id=%s",
                      (playlist_id,))["download_mode"] == "all"

    batch_id = f"{provider}:{remote_id}"
    label = f"{provider.title()} · {payload.get('name') or remote_id}"
    added, unmatched = _add_items(playlist_id, provider, items, batch_id, label, download)

    if next_offset is not None:
        jobs.enqueue("mirror", {**payload, "offset": next_offset},
                     priority=jobs.PRIORITY_BULK)
    else:
        db.run("update playlists set last_synced_at=now() where id=%s", (playlist_id,))

    return {"playlist_id": playlist_id, "from": offset, "matched": added,
            "unmatched": unmatched, "resumes_at": next_offset}


def _playlist_for(user_id: int, provider: str, remote_id: str, name: str,
                  owner: str | None) -> int:
    row = db.one("""select id from playlists
                     where owner_id=%s and kind=%s and remote_id=%s""",
                 (user_id, provider, remote_id))
    if row:
        db.run("update playlists set name=%s where id=%s", (name, row["id"]))
        return row["id"]
    return db.one(
        """insert into playlists(owner_id, name, kind, remote_id, sync_mode, source_name)
           values(%s,%s,%s,%s,'pull',%s) returning id""",
        (user_id, name, provider, remote_id, owner),
    )["id"]


def _add_items(playlist_id: int, provider: str, items: list[dict], batch_id: str,
               label: str, download: bool) -> tuple[int, int]:
    """Append a run of tracks to the end of the playlist."""
    start = db.one("select coalesce(max(pos) + 1, 0) n from playlist_items "
                   "where playlist_id=%s", (playlist_id,))["n"]
    added = unmatched = 0
    for item in items:
        src = item.get("source")
        try:
            if src:
                # SoundCloud and Bandcamp hand back the track itself, so there is
                # nothing to match: this is the recording, not a guess at it.
                track = catalog.find_by_provider(src["provider"], src["provider_id"]) \
                    or catalog.find_by_isrc(item.get("isrc"))
                if not track:
                    track = catalog.create_from_source(
                        src["provider"], {**item, **src},
                        discovered_via=catalog.VIA_SYNC, priority=jobs.PRIORITY_BULK,
                        batch_id=batch_id, batch_label=label, download=download)
                track_id = track["id"]
            else:
                outcome = sync.resolve_item(provider, item, priority=jobs.PRIORITY_BULK,
                                            batch_id=batch_id, batch_label=label,
                                            download=download)
                track_id = outcome.get("track_id")
        except Exception as e:                       # one bad row is not the playlist
            log.warning("%s item failed: %s", provider, e)
            track_id = None

        if not track_id:
            db.run("""insert into playlist_unmatched(playlist_id,pos,remote_id,title,
                                                     artists,reason)
                      values(%s,%s,%s,%s,%s,'no confident match')
                      on conflict do nothing""",
                   (playlist_id, start + added + unmatched, item.get("remote_id"),
                    item.get("title"), item.get("artists") or []))
            unmatched += 1
            continue
        db.run("""insert into playlist_items(playlist_id,pos,track_id)
                  values(%s,%s,%s) on conflict (playlist_id,pos) do nothing""",
               (playlist_id, start + added + unmatched, track_id))
        added += 1
    return added, unmatched
