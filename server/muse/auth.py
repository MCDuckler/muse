"""Argon2 passwords from the config file, opaque per-device bearer tokens in the DB."""
from __future__ import annotations

import hashlib
import secrets
import time

from argon2 import PasswordHasher
from argon2.exceptions import VerifyMismatchError

from . import db

_ph = PasswordHasher()
TOKEN_BYTES = 32


def hash_password(pw: str) -> str:
    return _ph.hash(pw)


def verify_password(stored_hash: str, pw: str) -> bool:
    try:
        return _ph.verify(stored_hash, pw)
    except (VerifyMismatchError, Exception):
        return False


def token_hash(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


def ensure_user(name: str) -> int:
    row = db.one("select id from users where name=%s", (name,))
    if row:
        return row["id"]
    return db.one("insert into users(name) values(%s) returning id", (name,))["id"]


def issue_token(user_id: int, device_name: str, platform: str | None) -> str:
    token = secrets.token_urlsafe(TOKEN_BYTES)
    db.run(
        "insert into devices(user_id,name,platform,token_hash) values(%s,%s,%s,%s)",
        (user_id, device_name, platform, token_hash(token)),
    )
    return token


def user_for_token(token: str) -> dict | None:
    row = db.one(
        """select u.id, u.name, d.id as device_id, d.name as device_name
             from devices d join users u on u.id=d.user_id
            where d.token_hash=%s""",
        (token_hash(token),),
    )
    if row:
        db.run("update devices set last_seen=now() where id=%s", (row["device_id"],))
    return row


class RateLimiter:
    """Token bucket per key. The API is internet-facing; login must not be free."""

    def __init__(self, rate: float, burst: int):
        self.rate, self.burst = rate, burst
        self._buckets: dict[str, tuple[float, float]] = {}

    def allow(self, key: str) -> bool:
        now = time.monotonic()
        tokens, last = self._buckets.get(key, (float(self.burst), now))
        tokens = min(self.burst, tokens + (now - last) * self.rate)
        if tokens < 1.0:
            self._buckets[key] = (tokens, now)
            return False
        self._buckets[key] = (tokens - 1.0, now)
        return True
