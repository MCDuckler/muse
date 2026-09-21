"""Connecting a listening diary, and seeing whether it is being written in."""
from __future__ import annotations

from fastapi import APIRouter, Body, Depends, HTTPException

from . import db, scrobble
from .deps import current_user

router = APIRouter(prefix="/scrobbling")


@router.get("")
def where_it_stands(user: dict = Depends(current_user)):
    return scrobble.standing(user["id"])


@router.put("/listenbrainz")
def connect(body: dict = Body(...), user: dict = Depends(current_user)):
    """A token from listenbrainz.org/settings, checked before it is kept."""
    token = (body.get("token") or "").strip()
    if not token or len(token) > 200:
        raise HTTPException(400, "paste the user token from your ListenBrainz settings")
    try:
        name = scrobble.whose(token)
    except scrobble.Refused as e:
        raise HTTPException(400, str(e)) from e
    db.run("update users set listenbrainz_token=%s, listenbrainz_name=%s where id=%s",
           (token, name, user["id"]))
    return scrobble.standing(user["id"])


@router.delete("/listenbrainz")
def disconnect(user: dict = Depends(current_user)):
    """Stop, and forget the token. What was already sent stays sent; what was still owed
    is dropped, because there is nowhere left to send it."""
    db.run("update users set listenbrainz_token=null, listenbrainz_name=null where id=%s",
           (user["id"],))
    db.run("delete from scrobbles where user_id=%s and sent_at is null", (user["id"],))
    return scrobble.standing(user["id"])
