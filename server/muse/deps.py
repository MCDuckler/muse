"""Auth dependencies. The config lives here so routers don't import the app module."""
from __future__ import annotations

import hmac
from typing import Annotated

from fastapi import Header, HTTPException

from . import auth, config, db

_cfg: config.Config | None = None


def set_config(cfg: config.Config) -> None:
    global _cfg
    _cfg = cfg


def cfg() -> config.Config:
    if _cfg is None:
        raise RuntimeError("deps.set_config() first")
    return _cfg


def current_user(authorization: Annotated[str | None, Header()] = None) -> dict:
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(401, "missing bearer token")
    user = auth.user_for_token(authorization.split(" ", 1)[1].strip())
    if not user:
        raise HTTPException(401, "unknown or revoked token")
    return user


def user_or_key(k: str | None = None,
               authorization: Annotated[str | None, Header()] = None) -> dict:
    """For things an <img> asks for directly.

    An image element cannot send an Authorization header, so a signed key in the query
    string is the second way in — the same one audio streaming already uses.
    """
    user = None
    if authorization and authorization.lower().startswith("bearer "):
        user = auth.user_for_token(authorization.split(" ", 1)[1].strip())
    if user is None and k:
        user = auth.user_for_stream_key(k, cfg().worker_secret)
    if user is None:
        raise HTTPException(401, "missing bearer token or stream key")
    return user


def worker_auth(x_worker_secret: Annotated[str | None, Header()] = None,
                authorization: Annotated[str | None, Header()] = None) -> dict | None:
    """Who is asking for work: the house's own downloader, or somebody's computer.

    Two ways in. The secret is the old one — the machine the server's owner runs, which
    is trusted with everything and answers to no name but the one it gives. The other is
    a signed-in device an admin has allowed to fetch: it proves itself with the token it
    already has, so the secret never has to leave the server, and what comes back here
    says which device it is — it works under that name and no other, and may only touch
    the jobs it holds.

    Returns None for the first and the device for the second.
    """
    if x_worker_secret:
        # Constant time, like the stream key's signature: `!=` stops at the first byte
        # that differs, and how long that takes says how much of a guess was right.
        if hmac.compare_digest(x_worker_secret.encode(), cfg().worker_secret.encode()):
            return None
        raise HTTPException(401, "bad worker secret")
    if authorization and authorization.lower().startswith("bearer "):
        who = auth.user_for_token(authorization.split(" ", 1)[1].strip())
        if who:
            device = db.one("select id, name, can_ingest from devices where id=%s",
                            (who["device_id"],))
            if device and device["can_ingest"]:
                return {"id": device["id"], "name": device["name"],
                        "user_id": who["id"], "worker": f"device:{device['id']}"}
            raise HTTPException(403, "this device has not been allowed to fetch music")
    raise HTTPException(401, "bad worker secret")
