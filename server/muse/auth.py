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


def ensure_user(name: str, pw_hash: str | None = None,
                created_by: int | None = None, admin: bool = False) -> int:
    row = db.one("select id, pw_hash, is_admin from users where name=%s", (name,))
    if row:
        # Seed a config-file account's password on first sight, but never overwrite a
        # password the person has since set for themselves.
        if pw_hash and not row["pw_hash"]:
            db.run("update users set pw_hash=%s where id=%s", (pw_hash, row["id"]))
        if admin and not row["is_admin"]:
            db.run("update users set is_admin=true where id=%s", (row["id"],))
        return row["id"]
    return db.one(
        "insert into users(name, pw_hash, created_by, is_admin) values(%s,%s,%s,%s) "
        "returning id",
        (name, pw_hash, created_by, admin),
    )["id"]


def create_account(name: str, password: str, created_by: int | None = None) -> dict:
    name = name.strip()
    if not name:
        raise ValueError("a name is required")
    if len(password) < 8:
        raise ValueError("use at least 8 characters")
    if db.one("select id from users where lower(name)=lower(%s)", (name,)):
        raise ValueError(f"there is already an account called {name!r}")
    row = db.one(
        "insert into users(name, pw_hash, created_by) values(%s,%s,%s) returning *",
        (name, hash_password(password), created_by),
    )
    return {"id": row["id"], "name": row["name"], "created_at": row["created_at"]}


def check_login(name: str, password: str, config_hash: str | None) -> dict | None:
    """The database is authoritative; the config file is the fallback that bootstraps
    the first account on a fresh install."""
    row = db.one("select id, name, pw_hash from users where lower(name)=lower(%s)",
                 (name,))
    stored = (row or {}).get("pw_hash") or config_hash
    if not stored or not verify_password(stored, password):
        return None
    user_id = row["id"] if row else ensure_user(name, config_hash)
    return {"id": user_id, "name": row["name"] if row else name}


def set_password(user_id: int, password: str) -> None:
    if len(password) < 8:
        raise ValueError("use at least 8 characters")
    db.run("update users set pw_hash=%s where id=%s", (hash_password(password), user_id))


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
