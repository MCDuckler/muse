from __future__ import annotations

import pathlib

import psycopg
from psycopg.rows import dict_row
from psycopg_pool import ConnectionPool

_pool: ConnectionPool | None = None
SCHEMA = pathlib.Path(__file__).with_name("schema.sql")


def init(dsn: str) -> ConnectionPool:
    global _pool
    _pool = ConnectionPool(dsn, min_size=1, max_size=8, kwargs={"row_factory": dict_row}, open=True)
    with _pool.connection() as c:
        c.execute(SCHEMA.read_text())
    return _pool


def pool() -> ConnectionPool:
    if _pool is None:
        raise RuntimeError("db.init() first")
    return _pool


def close() -> None:
    global _pool
    if _pool is not None:
        _pool.close()
        _pool = None


# How many times a query is tried again when the plan under it went stale.
#
# Postgres prepares a statement after psycopg has seen it a few times, and a prepared
# `select t.*` remembers how many columns it returns. Add a column to that table while
# the pool is up and every connection holding that plan answers the next request with
# "cached plan must not change result type" — a 500, to whoever happened to be using
# the app. Adding one column here did exactly that: eight requests over fourteen
# seconds, devices/state and pool/split and a queue insert among them.
#
# It clears itself, because the failure is what makes psycopg throw the plan away. So
# the fix is simply to try again rather than hand the fault on: each attempt takes a
# connection from the pool, and the ones with a stale plan are used up by failing.
# Three is more than the pool has ever needed and is bounded either way.
_STALE_PLAN_TRIES = 3


def _stale_plan(e: Exception) -> bool:
    return isinstance(e, psycopg.errors.FeatureNotSupported) and "cached plan" in str(e)


def _tried(work):
    """[work], run against a connection, again if the plan under it had gone stale."""
    last: Exception | None = None
    for _ in range(_STALE_PLAN_TRIES):
        try:
            with pool().connection() as c:
                return work(c)
        except psycopg.errors.FeatureNotSupported as e:
            if not _stale_plan(e):
                raise
            last = e
    raise last  # type: ignore[misc]


def one(sql: str, params: tuple | dict = ()) -> dict | None:
    return _tried(lambda c: c.execute(sql, params).fetchone())


def all_(sql: str, params: tuple | dict = ()) -> list[dict]:
    return _tried(lambda c: c.execute(sql, params).fetchall())


def run(sql: str, params: tuple | dict = ()) -> None:
    _tried(lambda c: c.execute(sql, params))
