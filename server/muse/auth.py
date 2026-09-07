"""Argon2 passwords from the config file, opaque per-device bearer tokens in the DB."""
from __future__ import annotations

import hashlib
import hmac
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


# ---------------------------------------------------------------- stream keys
# A browser's <audio> element cannot send an Authorization header, so the stream URL
# has to carry its own proof. This is a short-lived HMAC over the user id — not the
# device token itself, which would then sit in every proxy log for as long as it lives.
STREAM_KEY_TTL = 12 * 3600


def stream_key(user_id: int, secret: str, ttl: int = STREAM_KEY_TTL) -> tuple[str, int]:
    exp = int(time.time()) + ttl
    body = f"{user_id}.{exp}"
    sig = hmac.new(secret.encode(), body.encode(), hashlib.sha256).hexdigest()[:32]
    return f"{body}.{sig}", exp


def user_for_stream_key(key: str, secret: str) -> dict | None:
    try:
        uid_s, exp_s, sig = key.split(".")
        uid, exp = int(uid_s), int(exp_s)
    except (ValueError, AttributeError):
        return None
    if exp < time.time():
        return None
    expected = hmac.new(secret.encode(), f"{uid}.{exp}".encode(), hashlib.sha256).hexdigest()[:32]
    if not hmac.compare_digest(expected, sig):
        return None
    return db.one("select id, name from users where id=%s", (uid,))
