"""Songs added to somebody's playback queue are fetched to the box at once, ahead of the
downloads nobody is waiting on — however they got there (added, a whole queue sent, a
station's radio) — and the net under it finds any left waiting."""
from __future__ import annotations

from muse import catalog, db, jobs


def _radio(n: int) -> int:
    """A song a station's radio wrote down without fetching it (download=False)."""
    return catalog.create_from_ytm(
        {"video_id": f"RADIOQ{n:05d}", "title": f"Radio {n}", "artists": ["Air"], "album": None,
         "duration_ms": 200_000, "raw": {}},
        discovered_via=catalog.VIA_RADIO, priority=jobs.PRIORITY_BULK, download=False)["id"]


def _ingest_of(track_id: int) -> dict | None:
    return db.one("""select id, priority, state from jobs where kind='ingest'
                      and (payload->>'track_id')::int=%s order by id desc limit 1""", (track_id,))


def _queue(client, hdr) -> int:
    r = client.post("/queues", headers=hdr, json={"name": "Listening"})
    assert r.status_code == 201, r.text
    return r.json()["id"]


def test_a_song_added_to_the_queue_is_fetched_ahead_of_the_rest(client, hdr, wsec):
    # somebody's search, asked for first: an ordinary download
    asked = client.post("/tracks/resolve", headers=hdr, json={"query": "test song"}).json()["id"]
    assert _ingest_of(asked)["priority"] == jobs.PRIORITY_NORMAL
    radio = _radio(1)
    assert _ingest_of(radio) is None, "the radio wrote it down, nothing fetched yet"
    q = _queue(client, hdr)
    r = client.post(f"/queues/{q}/items", headers=hdr, json={"track_ids": [radio]})
    assert r.status_code == 200, r.text
    assert _ingest_of(radio)["priority"] == jobs.PRIORITY_QUEUE
    # the pool takes the queue's song first, though the other was asked for earlier
    leased = client.post("/internal/jobs/lease", headers=wsec, json={"worker": "w"}).json()["jobs"]
    assert leased[0]["payload"]["track_id"] == radio
    # added again (on its way): not a second job
    client.post(f"/queues/{q}/items", headers=hdr, json={"track_ids": [radio]})
    assert db.one("select count(*) as n from jobs where kind='ingest' and (payload->>'track_id')::int=%s", (radio,))["n"] == 1


def test_a_whole_queue_sent_and_a_bulk_download_moved_up(client, hdr):
    a, b = _radio(2), _radio(3)
    # b already waits behind an import
    jobs.queue(b, priority=jobs.PRIORITY_BULK)
    assert _ingest_of(b)["priority"] == jobs.PRIORITY_BULK
    q = _queue(client, hdr)
    rev = client.get(f"/queues/{q}", headers=hdr).json()["rev"]
    r = client.put(f"/queues/{q}", headers=hdr, json={"rev": rev, "items": [a, {"track_id": b, "origin": "radio"}]})
    assert r.status_code == 200, r.text
    assert _ingest_of(a)["priority"] == jobs.PRIORITY_QUEUE
    assert _ingest_of(b)["priority"] == jobs.PRIORITY_QUEUE, "moved up, not made twice"
    assert db.one("select count(*) as n from jobs where kind='ingest' and (payload->>'track_id')::int=%s", (b,))["n"] == 1


def test_the_net_finds_a_queues_songs_left_waiting_but_not_those_played_or_failed(client, hdr):
    q = _queue(client, hdr)
    behind, ahead, failed = _radio(4), _radio(5), _radio(6)
    db.run("update tracks set state='failed' where id=%s", (failed,))
    with db.pool().connection() as c:
        for pos, t in enumerate([behind, ahead, failed]):
            c.execute("insert into queue_items(queue_id,pos,track_id,origin) values(%s,%s,%s,'radio')", (q, pos, t))
        c.execute("update queues set cursor_index=1, updated_at=now() where id=%s", (q,))
    assert jobs.fetch_queues_ahead() == 1
    assert _ingest_of(ahead)["priority"] == jobs.PRIORITY_QUEUE
    assert _ingest_of(behind) is None, "already played past"
    assert _ingest_of(failed) is None, "a failed one is the hands' to ask again"
    assert jobs.fetch_queues_ahead() == 0, "nothing twice"
