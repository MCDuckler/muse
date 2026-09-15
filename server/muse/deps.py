"""Auth dependencies. The config lives here so routers don't import the app module."""
from __future__ import annotations

import hmac
from typing import Annotated

from fastapi import Header, HTTPException

from . import auth, config

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


def worker_auth(x_worker_secret: Annotated[str | None, Header()] = None) -> None:
    # Constant time, like the stream key's signature: `!=` stops at the first byte
    # that differs, and how long that takes says how much of a guess was right.
    if not x_worker_secret or not hmac.compare_digest(
            x_worker_secret.encode(), cfg().worker_secret.encode()):
        raise HTTPException(401, "bad worker secret")
