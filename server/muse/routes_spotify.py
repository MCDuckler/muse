"""Spotify playlists inside muse.

They are mirrored, not owned: listed alongside your own playlists with a tag, playable,
and deliberately not editable — editing a copy of someone else's list is a lie about
where it lives. Cloning makes a real muse playlist you can do anything to.

A song that cannot be translated is recorded rather than dropped. A mirrored playlist
that quietly comes back three tracks shorter is worse than one that says which three.
"""
from __future__ import annotations

import logging

from fastapi import APIRouter, Body, Depends, HTTPException
from fastapi.responses import HTMLResponse

from . import catalog, db, match, spotify, sync, ytm
from .deps import cfg, current_user

log = logging.getLogger("muse.spotify")
router = APIRouter(prefix="/spotify")


def _fail(e: Exception) -> HTTPException:
    if isinstance(e, spotify.NotConfigured):
        return HTTPException(501, str(e))
    if isinstance(e, spotify.NotLinked):
        return HTTPException(409, str(e))
    if isinstance(e, spotify.NotAllowed):
        # Not a gateway failure: Spotify answered, and the answer was no.
        return HTTPException(403, str(e))
    return HTTPException(502, str(e))


@router.get("/account")
def linked_account(user: dict = Depends(current_user)):
    configured = True
    reason = None
    try:
        spotify._app(cfg())
    except spotify.NotConfigured as e:
        configured, reason = False, str(e)
    return {
        "configured": configured,
        "reason": reason,
        "account": spotify.account(user["id"]),
    }


@router.get("/authorize")
def authorize(user: dict = Depends(current_user)):
    try:
        return {"url": spotify.authorize_url(cfg(), user["id"])}
    except Exception as e:
        raise _fail(e)


@router.get("/callback", include_in_schema=False)
def callback(code: str | None = None, state: str | None = None,
             error: str | None = None):
    """Spotify sends the person's browser here, so it answers in HTML — this is the
    one endpoint a human looks at directly."""
    def page(title: str, body: str, ok: bool = True) -> HTMLResponse:
        colour = "#1f7a4d" if ok else "#b3261e"
        return HTMLResponse(f"""<!doctype html><meta charset=utf-8>
<meta name=viewport content="width=device-width,initial-scale=1">
<title>{title}</title>
<style>
 body{{background:#171310;color:#f2ece4;font:16px/1.6 system-ui,sans-serif;
       display:grid;place-items:center;height:100vh;margin:0;text-align:center}}
 .card{{max-width:34ch;padding:28px}} h1{{font-size:22px;margin:0 0 8px;color:{colour}}}
 p{{color:#b6a99b;margin:0}}
</style>
<div class=card><h1>{title}</h1><p>{body}</p></div>""", status_code=200 if ok else 400)

    if error:
        return page("Not connected", f"Spotify said: {error}. You can close this tab.",
                    ok=False)
    if not code or not state:
        return page("Not connected", "That link was incomplete.", ok=False)
    try:
        user_id = spotify.consume_state(state)
        info = spotify.exchange_code(cfg(), user_id, code)
    except Exception as e:
        return page("Not connected", str(e), ok=False)
    return page("Spotify connected",
                f"Linked as {info['display_name']}. You can close this tab and go back "
                f"to muse.")


@router.delete("/account")
def unlink(user: dict = Depends(current_user)):
    spotify.unlink(user["id"])
    # The mirrors are meaningless without the account they came from.
    db.run("delete from playlists where owner_id=%s and kind='spotify'", (user["id"],))
    return {"unlinked": True}


@router.get("/playlists")
def remote_playlists(user: dict = Depends(current_user)):
    """Everything on the Spotify side, marked with whether it is already mirrored.

    An account can hold hundreds of these — this one has 460 — so the app lists them
    and you choose. Mirroring is not free: every song costs a YouTube Music lookup.
    """
    try:
        remote = spotify.playlists(cfg(), user["id"])
    except Exception as e:
        raise _fail(e)

    mirrored = {
        r["remote_id"]: r for r in db.all_(
            """select p.remote_id, p.id as playlist_id, p.last_synced_at,
                      count(distinct i.track_id) as tracks,
                      count(distinct u.pos) as unmatched
                 from playlists p
                 left join playlist_items i on i.playlist_id=p.id
                 left join playlist_unmatched u on u.playlist_id=p.id
                where p.owner_id=%s and p.kind='spotify'
                group by p.id""",
            (user["id"],),
        )
    }
    return {"items": [{**p, "mirror": mirrored.get(p["remote_id"])} for p in remote],
            "mirrored": len(mirrored)}


@router.post("/sync")
def sync_playlists(body: dict = Body(default={}), user: dict = Depends(current_user)):
    """Mirror chosen playlists, or refresh the ones already mirrored.

    Deliberately never "all of them": an account with hundreds of playlists would mean
    thousands of lookups, and almost none of it wanted.
    """
    try:
        remote = spotify.playlists(cfg(), user["id"])
    except Exception as e:
        raise _fail(e)

    wanted = body.get("remote_ids") or ([body["remote_id"]] if body.get("remote_id")
                                        else None)
    if wanted:
        remote = [p for p in remote if p["remote_id"] in set(wanted)]
    else:
        already = {r["remote_id"] for r in db.all_(
            "select remote_id from playlists where owner_id=%s and kind='spotify'",
            (user["id"],))}
        remote = [p for p in remote if p["remote_id"] in already]

    results = []
    for p in remote:
        try:
            results.append(_mirror(user["id"], p))
        except Exception as e:                       # one bad playlist is not all of them
            log.warning("mirror %s failed: %s", p["remote_id"], e)
            results.append({"name": p["name"], "error": str(e)})
    return {"playlists": results}


def _mirror(user_id: int, remote: dict) -> dict:
    row = db.one(
        """select id from playlists
            where owner_id=%s and kind='spotify' and remote_id=%s""",
        (user_id, remote["remote_id"]),
    )
    if row:
        playlist_id = row["id"]
        db.run("update playlists set name=%s, source_name=%s where id=%s",
               (remote["name"], remote.get("owner"), playlist_id))
    else:
        playlist_id = db.one(
            """insert into playlists(owner_id, name, kind, remote_id, sync_mode,
                                     source_name)
               values(%s,%s,'spotify',%s,'pull',%s) returning id""",
            (user_id, remote["name"], remote["remote_id"], remote.get("owner")),
        )["id"]

    items = spotify.playlist_items(cfg(), user_id, remote["remote_id"])
    resolved: list[int] = []
    missing: list[dict] = []

    for pos, item in enumerate(items):
        try:
            outcome = sync.resolve_item("spotify", item)
        except Exception as e:
            outcome = {"track_id": None, "confidence": 0.0, "method": f"error: {e}"}
        if outcome.get("track_id"):
            resolved.append(outcome["track_id"])
        else:
            missing.append({
                "pos": pos,
                "remote_id": item.get("remote_id"),
                "title": item.get("title"),
                "artists": item.get("artists") or [],
                "reason": _reason(outcome),
            })

    with db.pool().connection() as c:
        c.execute("delete from playlist_items where playlist_id=%s", (playlist_id,))
        for pos, track_id in enumerate(resolved):
            c.execute("""insert into playlist_items(playlist_id,pos,track_id)
                         values(%s,%s,%s) on conflict do nothing""",
                      (playlist_id, pos, track_id))
        c.execute("delete from playlist_unmatched where playlist_id=%s", (playlist_id,))
        for m in missing:
            c.execute(
                """insert into playlist_unmatched(playlist_id,pos,remote_id,title,
                                                  artists,reason)
                   values(%s,%s,%s,%s,%s,%s)""",
                (playlist_id, m["pos"], m["remote_id"], m["title"], m["artists"],
                 m["reason"]),
            )
        c.execute("update playlists set last_synced_at=now(), last_error=null "
                  "where id=%s", (playlist_id,))

    return {"playlist_id": playlist_id, "name": remote["name"],
            "total": len(items), "matched": len(resolved), "missing": len(missing)}


def _reason(outcome: dict) -> str:
    """Why a song could not be translated, in words rather than a score."""
    method = outcome.get("method") or ""
    confidence = outcome.get("confidence") or 0.0
    if method.startswith("error"):
        return "Could not reach YouTube Music to look this up"
    if method == "no-candidates" or confidence == 0.0:
        return "Nothing on YouTube Music matched this song"
    if method == "duration-mismatch":
        return "Only a different-length version was found — probably another edit"
    return f"No confident match (best guess scored {confidence:.2f})"


@router.get("/playlists/{playlist_id}/unmatched")
def unmatched(playlist_id: int, user: dict = Depends(current_user)):
    owned = db.one("select id from playlists where id=%s and owner_id=%s",
                   (playlist_id, user["id"]))
    if not owned:
        raise HTTPException(404, "no such playlist")
    return {"items": db.all_(
        """select pos, remote_id, title, artists, reason
             from playlist_unmatched where playlist_id=%s order by pos""",
        (playlist_id,),
    )}


@router.post("/playlists/{playlist_id}/unmatched/{pos}/resolve")
def resolve_missing(playlist_id: int, pos: int, body: dict = Body(...),
                    user: dict = Depends(current_user)):
    """Pick the right song by hand. A human decision is permanent: a later sync reads
    it back rather than running the matcher over it again."""
    row = db.one(
        """select u.remote_id, u.title from playlist_unmatched u
             join playlists p on p.id=u.playlist_id
            where u.playlist_id=%s and u.pos=%s and p.owner_id=%s""",
        (playlist_id, pos, user["id"]),
    )
    if not row:
        raise HTTPException(404, "nothing unmatched at that position")

    video_id, track_id = body.get("video_id"), body.get("track_id")
    if not video_id and not track_id:
        raise HTTPException(400, "video_id or track_id required")
    decision = sync.override("spotify", row["remote_id"], track_id, video_id)

    with db.pool().connection() as c:
        c.execute("delete from playlist_unmatched where playlist_id=%s and pos=%s",
                  (playlist_id, pos))
        end = c.execute("select coalesce(max(pos),-1)+1 as n from playlist_items "
                        "where playlist_id=%s", (playlist_id,)).fetchone()["n"]
        c.execute("""insert into playlist_items(playlist_id,pos,track_id)
                     values(%s,%s,%s) on conflict do nothing""",
                  (playlist_id, end, decision["track_id"]))
    return {"track_id": decision["track_id"]}


@router.get("/playlists/{playlist_id}/suggestions")
def suggestions(playlist_id: int, pos: int, user: dict = Depends(current_user)):
    """Candidates for a song that did not match, so a person can choose."""
    row = db.one(
        """select u.title, u.artists from playlist_unmatched u
             join playlists p on p.id=u.playlist_id
            where u.playlist_id=%s and u.pos=%s and p.owner_id=%s""",
        (playlist_id, pos, user["id"]),
    )
    if not row:
        raise HTTPException(404, "nothing unmatched at that position")
    query = " ".join([row["title"] or "", (row["artists"] or [""])[0]]).strip()
    hits = ytm.search_songs(query, limit=6)
    target = {"title": row["title"], "artists": row["artists"] or []}
    return {"items": [
        {k: v for k, v in h.items() if k != "raw"} | {
            "confidence": match.score(target, h)[0],
        }
        for h in hits
    ]}


@router.post("/playlists/{playlist_id}/clone")
def clone(playlist_id: int, body: dict = Body(default={}),
          user: dict = Depends(current_user)):
    """Make it yours. The copy is an ordinary playlist with no link back — editing a
    mirror would be pretending you can change someone else's list."""
    source = db.one("select * from playlists where id=%s and owner_id=%s",
                    (playlist_id, user["id"]))
    if not source:
        raise HTTPException(404, "no such playlist")

    name = (body.get("name") or f"{source['name']} (copy)").strip()
    new_id = db.one(
        "insert into playlists(owner_id,name,kind) values(%s,%s,'local') returning id",
        (user["id"], name),
    )["id"]
    with db.pool().connection() as c:
        c.execute(
            """insert into playlist_items(playlist_id,pos,track_id)
               select %s, pos, track_id from playlist_items where playlist_id=%s""",
            (new_id, playlist_id),
        )
    items = db.all_(
        """select i.pos, t.* from playlist_items i join tracks t on t.id=i.track_id
            where i.playlist_id=%s order by i.pos""",
        (new_id,),
    )
    return {"id": new_id, "name": name, "kind": "local",
            "items": [{**catalog.public(t), "pos": t["pos"]} for t in items]}
