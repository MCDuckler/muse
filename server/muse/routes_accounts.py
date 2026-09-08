"""Adding people to a muse server.

The original plan said "a few server-configured users, no signup", and that still
holds: there is no public registration. What changed is that adding someone no longer
means editing a TOML file and restarting — an existing user creates the account, or
hands out a one-time invite so the other person picks their own password.
"""
from __future__ import annotations

import secrets
from datetime import datetime, timedelta, timezone

from fastapi import APIRouter, Body, Depends, HTTPException

from . import auth, db
from .deps import current_user

router = APIRouter(prefix="/accounts")

INVITE_TTL_HOURS = 48


@router.get("")
def list_accounts(user: dict = Depends(current_user)):
    return {"items": db.all_(
        """select u.id, u.name, u.created_at,
                  count(d.id) as devices,
                  max(d.last_seen) as last_seen,
                  u.pw_hash is null as needs_password
             from users u left join devices d on d.user_id=u.id
            group by u.id order by u.id"""
    ), "you": user["id"]}


@router.post("", status_code=201)
def create_account(body: dict = Body(...), user: dict = Depends(current_user)):
    """Any signed-in user can add another. With a handful of trusted people that is
    the right amount of ceremony; there are no roles to administer."""
    try:
        return auth.create_account(
            (body.get("name") or "").strip(),
            body.get("password") or "",
            created_by=user["id"],
        )
    except ValueError as e:
        raise HTTPException(400, str(e))


@router.delete("/{account_id}")
def delete_account(account_id: int, user: dict = Depends(current_user)):
    if account_id == user["id"]:
        raise HTTPException(400, "you cannot delete the account you are signed in with")
    if not db.one("select id from users where id=%s", (account_id,)):
        raise HTTPException(404, "no such account")
    if db.one("select count(*) n from users")["n"] <= 1:
        raise HTTPException(400, "a server with no accounts cannot be signed into")
    db.run("delete from users where id=%s", (account_id,))
    return {"deleted": account_id}


@router.post("/{account_id}/password")
def reset_password(account_id: int, body: dict = Body(...),
                   user: dict = Depends(current_user)):
    """Set someone else's password.

    Without this, an account that cannot sign in is only recoverable with a database
    client — which is not a thing to need at eleven at night.
    """
    if not db.one("select id from users where id=%s", (account_id,)):
        raise HTTPException(404, "no such account")
    try:
        auth.set_password(account_id, body.get("password") or "")
    except ValueError as e:
        raise HTTPException(400, str(e))
    if body.get("sign_out_devices"):
        db.run("delete from devices where user_id=%s", (account_id,))
    return {"changed": True, "account_id": account_id}


@router.post("/invites", status_code=201)
def create_invite(body: dict = Body(default={}), user: dict = Depends(current_user)):
    """A one-time code, so you never have to know someone else's password."""
    code = secrets.token_urlsafe(9)
    expires = datetime.now(timezone.utc) + timedelta(hours=INVITE_TTL_HOURS)
    db.run(
        "insert into invites(code, created_by, note, expires_at) values(%s,%s,%s,%s)",
        (code, user["id"], (body.get("note") or "").strip() or None, expires),
    )
    return {"code": code, "expires_at": expires, "valid_hours": INVITE_TTL_HOURS}


@router.get("/invites")
def list_invites(user: dict = Depends(current_user)):
    return {"items": db.all_(
        """select code, note, created_at, expires_at, used_at,
                  (select name from users where id=used_by) as used_by
             from invites where used_at is null and expires_at > now()
            order by created_at desc"""
    )}


@router.delete("/invites/{code}")
def revoke_invite(code: str, user: dict = Depends(current_user)):
    db.run("delete from invites where code=%s and used_at is null", (code,))
    return {"revoked": code}
