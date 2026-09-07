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


def one(sql: str, params: tuple | dict = ()) -> dict | None:
    with pool().connection() as c:
        return c.execute(sql, params).fetchone()


def all_(sql: str, params: tuple | dict = ()) -> list[dict]:
    with pool().connection() as c:
        return c.execute(sql, params).fetchall()


def run(sql: str, params: tuple | dict = ()) -> None:
    with pool().connection() as c:
        c.execute(sql, params)
