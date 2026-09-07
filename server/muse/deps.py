"""Auth dependencies. The config lives here so routers don't import the app module."""
from __future__ import annotations

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


def worker_auth(x_worker_secret: Annotated[str | None, Header()] = None) -> None:
    if not x_worker_secret or x_worker_secret != cfg().worker_secret:
        raise HTTPException(401, "bad worker secret")
