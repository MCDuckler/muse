"""A query whose plan went stale under it is asked again, not handed on as a fault.

Postgres prepares a statement once psycopg has seen it a few times, and a prepared
`select *` remembers the shape of what it returns. Adding a column to that table while
the pool is up makes every connection holding that plan answer the next request with
"cached plan must not change result type". On the live server that was eight requests
over fourteen seconds — devices/state, pool/split, a queue insert — every one of them a
500 to whoever was using the app at the time.
"""
from __future__ import annotations

import pytest

from muse import db


@pytest.fixture()
def probe(cfg):
    # The pool, against the throwaway database: these are about the pool itself, so
    # they set it up rather than going through the app that usually does.
    db.init(cfg.dsn)
    db.run("drop table if exists _plan_probe")
    db.run("create table _plan_probe (id int)")
    db.run("insert into _plan_probe values (1)")
    yield
    db.run("drop table if exists _plan_probe")


def test_a_query_survives_its_table_gaining_a_column(probe):
    # Seen often enough that psycopg prepares it. Under the threshold nothing is
    # prepared and there is no stale plan to survive, so this loop is the test.
    for _ in range(12):
        assert db.all_("select * from _plan_probe") == [{"id": 1}]

    db.run("alter table _plan_probe add column extra text")

    # Every one of these answers. Without the retry the first is a FeatureNotSupported
    # and whoever asked for it gets a 500.
    for _ in range(6):
        rows = db.all_("select * from _plan_probe")
        assert rows == [{"id": 1, "extra": None}]


def test_a_real_fault_is_still_a_fault(probe):
    """The retry is for one error and must not swallow the rest: a query that is
    simply wrong has to say so the first time, not three times over."""
    import psycopg

    with pytest.raises(psycopg.errors.UndefinedColumn):
        db.all_("select nosuchcolumn from _plan_probe")
