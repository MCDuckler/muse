"""Linking the services that do not need a consent screen, and mirroring their lists.

Spotify keeps its own module: it has OAuth, tokens to refresh and a dashboard that
decides who is allowed. These three are public reads, so they share one shape — a name,
a list of lists, and the same mirroring the Spotify side already does.
"""
from __future__ import annotations

import logging

from fastapi import APIRouter, Body, Depends, HTTPException

from . import catalog, db, jobs, linked, sync
from .deps import current_user

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
                   "bandcamp": "Bandcamp"}[p],
         "hint": {
             "deezer": "The numeric id from your profile URL",
             # Say that pasting the link works, because that is what people do.
             "soundcloud": "Paste your profile link, or the name in it",
             "bandcamp": "Paste your fan page link, or the name in it",
         }[p],
         "plays": p != "deezer",
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
        remote = linked.playlists(provider, acc["handle"])
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
    if not acc:
        raise HTTPException(409, f"No {provider} account is linked here yet.")

    wanted = body.get("remote_ids") or ([body["remote_id"]] if body.get("remote_id")
                                        else None)
    if not wanted:
        raise HTTPException(400, "remote_id or remote_ids required")

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
        items, next_offset = linked.items(provider, remote_id, offset=offset)
    except linked.RateLimited:
        jobs.enqueue("mirror", {**payload, "offset": offset},
                     priority=jobs.PRIORITY_BULK, delay_seconds=RATE_LIMIT_WAIT)
        log.info("%s is rate-limiting; resuming at %s in %s minutes",
                 provider, offset, RATE_LIMIT_WAIT // 60)
        return {"waiting": f"{provider} is rate-limiting; will resume", "from": offset}

    playlist_id = _playlist_for(user_id, provider, remote_id,
                               payload.get("name") or remote_id, payload.get("owner"))

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
