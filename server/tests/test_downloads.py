"""Managing a download queue, not just having one.

One track behind a spinner was fine. A mirrored playlist is a hundred and twenty, and
then the questions are: how far along, what is stuck, can I stop it, and can the song I
actually want jump the queue.
"""
from __future__ import annotations

import pytest

from muse import catalog, db, jobs


@pytest.fixture()
def queued(client, hdr):
    """Three ordinary requests and a ten-track import behind them."""
    tracks = []
    for n in range(3):
        tracks.append(client.post("/tracks/resolve", headers=hdr,
                                  json={"video_id": f"USER{n}"}).json()["id"])
    for n in range(10):
        db.run(
            """insert into jobs(kind, payload, priority, batch_id, batch_label)
               values('ingest',
                      jsonb_build_object('track_id', %s::int, 'video_id', %s::text),
                      %s, 'spotify:PL1', 'Spotify · Road trip')""",
            (tracks[0], f"BULK{n}", jobs.PRIORITY_BULK),
        )
    return tracks


def test_the_overview_answers_everything_in_one_request(client, hdr, queued):
    d = client.get("/downloads", headers=hdr).json()
    assert d["counts"]["waiting"] == 13
    assert d["paused"] is False
    assert len(d["batches"]) == 1
    batch = d["batches"][0]
    assert batch["label"] == "Spotify · Road trip"
    assert batch["total"] == 10 and batch["remaining"] == 10 and batch["done"] == 0
    assert d["waiting"][0]["track"] is not None, "rows carry the track, not just an id"


def test_an_import_waits_behind_what_you_asked_for(client, hdr, queued, wsec):
    """A hundred-track import must not stand in front of the song you just added."""
    leased = client.post("/internal/jobs/lease", headers=wsec,
                         json={"worker": "w", "limit": 3}).json()["jobs"]
    assert len(leased) == 3
    assert all(j["batch_id"] is None for j in leased), "user requests go first"


def test_playing_something_still_downloading_moves_it_forward(client, hdr, queued,
                                                              wsec):
    # Bury a track behind the bulk import.
    db.run("""update jobs set priority=%s where (payload->>'track_id')::int = %s""",
           (jobs.PRIORITY_BULK + 1, queued[2]))
    assert client.post("/downloads/promote", headers=hdr,
                       json={"track_id": queued[2]}).json()["promoted"] == 1

    first = client.post("/internal/jobs/lease", headers=wsec,
                        json={"worker": "w"}).json()["jobs"][0]
    assert first["payload"]["track_id"] == queued[2]


def test_resolving_a_pending_track_again_promotes_it(client, hdr, queued):
    """Asking for it a second time means you are waiting on it."""
    db.run("""update jobs set priority=%s where (payload->>'track_id')::int = %s""",
           (jobs.PRIORITY_BULK, queued[1]))
    client.post("/tracks/resolve", headers=hdr, json={"video_id": "USER1"})
    row = db.one("""select priority from jobs where kind='ingest'
                     and (payload->>'track_id')::int = %s""", (queued[1],))
    assert row["priority"] == jobs.PRIORITY_NOW


def test_pausing_stops_work_being_handed_out(client, hdr, queued, wsec):
    client.post("/downloads/pause", headers=hdr, json={"paused": True})
    assert client.get("/downloads", headers=hdr).json()["paused"] is True
    assert client.post("/internal/jobs/lease", headers=wsec,
                       json={"worker": "w"}).json()["jobs"] == []

    # and the worker still counts as alive while paused, so the UI does not claim it
    # has gone away
    status = client.get("/status", headers=hdr).json()
    assert status["ingest_worker"] == "w"

    client.post("/downloads/pause", headers=hdr, json={"paused": False})
    assert client.post("/internal/jobs/lease", headers=wsec,
                       json={"worker": "w"}).json()["jobs"] != []


def test_a_whole_batch_can_be_cancelled(client, hdr, queued):
    r = client.post("/downloads/cancel", headers=hdr,
                    json={"batch_id": "spotify:PL1"}).json()
    assert r["cancelled"] == 10
    after = client.get("/downloads", headers=hdr).json()
    assert after["counts"]["waiting"] == 3, "the tracks you asked for survive"
    assert after["batches"] == [] or after["batches"][0]["remaining"] == 0


def test_cancelling_one_track_leaves_the_rest(client, hdr, queued):
    assert client.post("/downloads/cancel", headers=hdr,
                       json={"track_id": queued[1]}).json()["cancelled"] == 1
    assert client.get("/downloads", headers=hdr).json()["counts"]["waiting"] == 12
    assert client.get(f"/tracks/{queued[1]}", headers=hdr).json()["fail_code"] == "cancelled"


def test_cancel_needs_something_to_cancel(client, hdr):
    assert client.post("/downloads/cancel", headers=hdr, json={}).status_code == 400


def test_failures_can_be_retried_in_bulk(client, hdr, queued, wsec):
    job = client.post("/internal/jobs/lease", headers=wsec,
                      json={"worker": "w"}).json()["jobs"][0]
    client.post(f"/internal/jobs/{job['id']}/fail", headers=wsec,
                json={"reason": "This video is unavailable", "track_id": queued[0]})
    assert client.get("/downloads", headers=hdr).json()["counts"]["failed"] == 1

    assert client.post("/downloads/retry-failed", headers=hdr,
                       json={}).json()["retrying"] == 1
    after = client.get("/downloads", headers=hdr).json()
    assert after["counts"]["failed"] == 0
    # a person choosing "try again" is new information, so the attempt count resets
    assert db.one("select attempts from jobs where id=%s", (job["id"],))["attempts"] == 0
    assert client.get(f"/tracks/{queued[0]}", headers=hdr).json()["state"] == "pending"


def test_retrying_can_be_limited_to_one_batch(client, hdr, queued, wsec):
    job = client.post("/internal/jobs/lease", headers=wsec,
                      json={"worker": "w"}).json()["jobs"][0]
    client.post(f"/internal/jobs/{job['id']}/fail", headers=wsec,
                json={"reason": "boom", "track_id": queued[0], "retryable": False})
    assert client.post("/downloads/retry-failed", headers=hdr,
                       json={"batch_id": "spotify:PL1"}).json()["retrying"] == 0
    assert client.post("/downloads/retry-failed", headers=hdr,
                       json={}).json()["retrying"] == 1


def test_emptying_the_whole_queue(client, hdr, queued):
    """A mirror that pulled in far more than you meant it to has one way out."""
    assert client.post("/downloads/cancel", headers=hdr,
                       json={"all": True}).json()["cancelled"] == 13
    assert client.get("/downloads", headers=hdr).json()["counts"]["waiting"] == 0


def test_batches_say_how_many_there_are(client, hdr, queued):
    over = client.get("/downloads", headers=hdr).json()
    assert over["batches_total"] == len(over["batches"]) >= 1


def test_a_worker_can_take_several_at_once(client, hdr, queued, wsec):
    """Downloads are nearly all waiting, so the worker runs a few in parallel."""
    got = client.post("/internal/jobs/lease", headers=wsec,
                      json={"worker": "w", "limit": 3}).json()["jobs"]
    assert len(got) == 3, "a lease of three must hand out three"
    assert len({j["id"] for j in got}) == 3, "and never the same job twice"
    assert client.get("/downloads", headers=hdr).json()["counts"]["downloading"] == 3

    # The next lease is for the one slot that freed up, and says what is still running.
    more = client.post("/internal/jobs/lease", headers=wsec,
                       json={"worker": "w", "limit": 1, "busy": 2}).json()["jobs"]
    assert len(more) == 1
    assert db.one("select leased from workers where name='w'")["leased"] == 3


def test_a_full_worker_still_says_it_is_alive(client, hdr, wsec, queued):
    """Every slot busy means no lease, and no lease used to mean 'offline'."""
    client.post("/internal/jobs/lease", headers=wsec,
                json={"worker": "w", "limit": 0, "busy": 3})
    over = client.get("/downloads", headers=hdr).json()
    assert over["worker"]["online"] is True
    assert over["counts"]["downloading"] == 0, "a heartbeat must not take work"


def test_an_abandoned_lease_is_waiting_again(client, hdr, queued, wsec):
    """A worker killed mid-download must not leave 'downloading' rows behind."""
    got = client.post("/internal/jobs/lease", headers=wsec,
                      json={"worker": "w", "limit": 2}).json()["jobs"]
    db.run("update jobs set leased_until = now() - interval '1 minute' where id=%s",
           (got[0]["id"],))
    counts = client.get("/downloads", headers=hdr).json()["counts"]
    assert counts["downloading"] == 1, "only the live lease counts as downloading"
    assert counts["waiting"] == 12, "the abandoned one is waiting again"


def test_a_shutting_down_worker_gives_its_jobs_back(client, hdr, queued, wsec):
    """Restarting the worker must not park two tracks for the ten minutes a lease lasts."""
    job = client.post("/internal/jobs/lease", headers=wsec,
                      json={"worker": "w", "limit": 1}).json()["jobs"][0]
    assert client.post(f"/internal/jobs/{job['id']}/release", headers=wsec,
                       json={"track_id": queued[0]}).status_code == 200
    row = db.one("select state, attempts from jobs where id=%s", (job["id"],))
    assert row["state"] == "pending"
    assert row["attempts"] == 0, "an attempt nobody made must not count against it"
    assert client.get("/downloads", headers=hdr).json()["counts"]["waiting"] == 13


def test_retrying_only_what_is_worth_retrying(client, hdr, queued, wsec):
    """A challenged IP is worth another go; a deleted video is not."""
    two = client.post("/internal/jobs/lease", headers=wsec,
                      json={"worker": "w", "limit": 2}).json()["jobs"]
    client.post(f"/internal/jobs/{two[0]['id']}/fail", headers=wsec,
                json={"reason": "Sign in to confirm you’re not a bot",
                      "track_id": two[0]["payload"]["track_id"], "retryable": False})
    client.post(f"/internal/jobs/{two[1]['id']}/fail", headers=wsec,
                json={"reason": "Video unavailable",
                      "track_id": two[1]["payload"]["track_id"], "retryable": False})

    assert client.post("/downloads/retry-failed", headers=hdr,
                       json={"fail_code": "bot_check"}).json()["retrying"] == 1
    assert client.get("/downloads", headers=hdr).json()["counts"]["failed"] == 1


def test_what_is_about_to_play_jumps_too(client, hdr, queued, wsec):
    """Not just the song under the needle: by the time it ends, the next one wants to
    have been downloaded already."""
    db.run("update jobs set priority=%s", (jobs.PRIORITY_BULK,))
    run = [queued[2], queued[1]]
    assert client.post("/downloads/promote", headers=hdr,
                       json={"track_ids": run}).json()["promoted"] == 2

    got = client.post("/internal/jobs/lease", headers=wsec,
                      json={"worker": "w", "limit": 4}).json()["jobs"]
    assert [j["payload"]["track_id"] for j in got[:2]] == run, \
        "they keep their playing order, and both come before the import"


def test_a_worker_can_ask_for_urgent_work_only(client, hdr, queued, wsec):
    """A worker already downloading something somebody is waiting for leaves the line
    free rather than filling every slot with a backfill."""
    db.run("update jobs set priority=%s", (jobs.PRIORITY_BULK,))
    client.post("/downloads/promote", headers=hdr, json={"track_ids": [queued[1]]})

    urgent = client.post("/internal/jobs/lease", headers=wsec,
                         json={"worker": "w", "limit": 5,
                               "max_priority": jobs.PRIORITY_NOW + 8}).json()["jobs"]
    assert [j["payload"]["track_id"] for j in urgent] == [queued[1]]
    assert urgent[0]["priority"] <= jobs.PRIORITY_NOW + 8, "the lease says how urgent it is"


def test_playing_a_track_nobody_queued_queues_it(client, hdr):
    """A big mirror records the list without the audio. Pressing play is what asks for
    the file, and it must not need a job to already exist."""
    track = client.post("/tracks/resolve", headers=hdr,
                        json={"video_id": "LIBRARY1"}).json()
    db.run("delete from jobs where kind='ingest'")          # as if it was never queued

    assert client.post("/downloads/promote", headers=hdr,
                       json={"track_ids": [track["id"]]}).json()["promoted"] == 1
    row = db.one("""select priority, state from jobs
                     where kind='ingest' and (payload->>'track_id')::int=%s""",
                 (track["id"],))
    assert row["state"] == "pending" and row["priority"] == jobs.PRIORITY_NOW, \
        "and it goes to the front, because somebody is waiting for it"


def test_a_track_already_downloaded_is_not_queued_again(client, hdr, wsec, complete_job):
    track = client.post("/tracks/resolve", headers=hdr, json={"video_id": "DONE1"}).json()
    job = client.post("/internal/jobs/lease", headers=wsec,
                      json={"worker": "w"}).json()["jobs"][0]
    complete_job(job["id"], track["id"])

    assert client.post("/downloads/promote", headers=hdr,
                       json={"track_ids": [track["id"]]}).json()["promoted"] == 0
    assert db.one("""select count(*) n from jobs where kind='ingest'
                      and (payload->>'track_id')::int=%s""", (track["id"],))["n"] == 1


def test_pausing_needs_you_to_say_which_way(client, hdr):
    """A bodyless POST used to mean "pause everything", so any probe of this endpoint
    could stop the queue — and a queue that has silently stopped looks broken."""
    assert client.post("/downloads/pause", headers=hdr, json={}).status_code == 400
    assert jobs.paused() is False

    assert client.post("/downloads/pause", headers=hdr,
                       json={"paused": True}).json()["paused"] is True
    assert client.post("/downloads/pause", headers=hdr,
                       json={"paused": False}).json()["paused"] is False


def test_a_dead_video_is_not_a_dead_song(client, hdr, wsec, monkeypatch):
    """Deleted uploads are the biggest single reason a mirror has holes in it. The song
    is usually still there under another one."""
    from muse import routes_downloads, ytm

    track = client.post("/tracks/resolve", headers=hdr,
                        json={"video_id": "GONE1"}).json()
    job = client.post("/internal/jobs/lease", headers=wsec,
                      json={"worker": "w"}).json()["jobs"][0]
    client.post(f"/internal/jobs/{job['id']}/fail", headers=wsec,
                json={"reason": "Video unavailable", "track_id": track["id"],
                      "retryable": False})

    seen = {}
    monkeypatch.setattr(ytm, "search_songs", lambda q, limit=10: seen.setdefault(
        "q", q) and None or [
            {"video_id": "GONE1", "title": "Song GONE1", "artists": ["Tester"],
             "album": None, "duration_ms": 60_000, "raw": {}},
            {"video_id": "ALIVE1", "title": "Song GONE1", "artists": ["Tester"],
             "album": None, "duration_ms": 60_000, "raw": {}},
        ])

    out = client.post("/downloads/refind", headers=hdr, json={}).json()
    assert out["found"] == 1, out
    assert out["details"][0]["where"] == "youtube"

    # The dead id must not be handed back, and the track is queued again.
    assert db.one("""select count(*) n from track_sources
                      where track_id=%s and provider_id='ALIVE1'""",
                  (track["id"],))["n"] == 1
    assert client.get(f"/tracks/{track['id']}", headers=hdr).json()["state"] == "pending"


def test_refind_says_so_when_there_is_nothing(client, hdr, wsec, monkeypatch):
    from muse import sources, ytm

    track = client.post("/tracks/resolve", headers=hdr, json={"video_id": "GONE2"}).json()
    job = client.post("/internal/jobs/lease", headers=wsec,
                      json={"worker": "w"}).json()["jobs"][0]
    client.post(f"/internal/jobs/{job['id']}/fail", headers=wsec,
                json={"reason": "Video unavailable", "track_id": track["id"],
                      "retryable": False})

    monkeypatch.setattr(ytm, "search_songs", lambda q, limit=10: [])
    monkeypatch.setattr(sources, "search", lambda *a, **k: [])
    out = client.post("/downloads/refind", headers=hdr, json={}).json()
    assert out["found"] == 0 and out["still_missing"] == 1
    assert client.get(f"/tracks/{track['id']}", headers=hdr).json()["state"] == "failed", \
        "a track nothing was found for stays failed rather than looking queued"


def test_playing_a_bandcamp_track_queues_it_where_it_can_be_fetched(client, hdr):
    """A big mirror records the list without the audio. Pressing play on one of those
    must queue it in the lane that can actually get it — queueing everything as YouTube
    meant a Bandcamp track sat "downloading" for good, because nothing could start it."""
    track = catalog.create_from_source(
        "bandcamp",
        {"provider_id": "77", "title": "Urlaub in Italien", "artists": ["Deine Familie"],
         "album": "An album", "duration_ms": 200_000,
         "url": "https://deinefamilie.bandcamp.com/track/urlaub-in-italien"},
        download=False)
    assert db.one("""select count(*) n from jobs
                      where (payload->>'track_id')::int=%s""",
                  (track["id"],))["n"] == 1, "only the metadata job, no audio yet"

    assert client.post("/downloads/promote", headers=hdr,
                       json={"track_ids": [track["id"]]}).json()["promoted"] == 1

    job = db.one("""select kind, payload, priority from jobs
                     where kind in ('ingest','ingest_direct')
                       and (payload->>'track_id')::int=%s""", (track["id"],))
    assert job["kind"] == "ingest_direct", "the server fetches Bandcamp itself"
    assert job["payload"]["provider"] == "bandcamp"
    assert job["payload"]["ref"].endswith("/track/urlaub-in-italien")
    assert job["priority"] == jobs.PRIORITY_NOW


def test_getting_a_whole_playlist_uses_the_right_lane_per_track(client, hdr):
    playlist = client.post("/playlists", headers=hdr, json={"name": "Mixed"}).json()
    bc = catalog.create_from_source(
        "bandcamp", {"provider_id": "88", "title": "One", "artists": ["A"],
                     "duration_ms": 1000, "url": "https://a.bandcamp.com/track/one"},
        download=False)
    yt = catalog.create_from_ytm(
        {"video_id": "YTONE", "title": "Two", "artists": ["B"], "album": None,
         "duration_ms": 1000}, download=False)
    client.post(f"/playlists/{playlist['id']}/items", headers=hdr,
                json={"track_ids": [bc["id"], yt["id"]]})

    assert client.post(f"/playlists/{playlist['id']}/download",
                       headers=hdr).json()["queued"] == 2
    kinds = {r["kind"] for r in db.all_(
        """select kind from jobs where kind in ('ingest','ingest_direct')""")}
    assert kinds == {"ingest", "ingest_direct"}, kinds


def test_a_song_is_fetched_from_somewhere_this_machine_can_reach(client, hdr):
    """A source the server can fetch itself beats one that needs the worker at home.

    The rule used to be the other way round, and it is how forty-eight SoundCloud
    tracks came to fail over and over with "this isn't on YouTube any more". They were
    on SoundCloud — which is where they came from and which this machine reaches in a
    second — but a YouTube source had been added beside it while looking for a copy of
    something else, and from then on every attempt went to the copy that did not exist
    instead of the original that did.
    """
    from muse import catalog, db, jobs

    track = catalog.create_from_source("soundcloud", {
        "provider_id": "555", "title": "Both places", "artists": [],
        "url": "https://soundcloud.com/a/both-places",
    }, download=False)
    # The other source, of the kind refind adds.
    db.run("""insert into track_sources(track_id,provider,provider_id,raw)
              values(%s,'ytmusic','deadbeef','{}'::jsonb)""", (track["id"],))

    assert jobs.promote(track["id"]) is True
    job = db.one("""select kind, payload->>'ref' as ref from jobs
                     where (payload->>'track_id')::int=%s
                       and kind in ('ingest','ingest_direct')""", (track["id"],))
    assert job["kind"] == "ingest_direct", "fetched here, not queued for the laptop"
    assert job["ref"] == "https://soundcloud.com/a/both-places"


def test_a_track_that_failed_can_be_asked_for_again(client, hdr):
    """Asking for a song is the clearest possible statement that the last answer was
    not the wanted one.

    Promote only ever looked at tracks that were still `pending`, so everything that
    had failed — including everything ever cancelled — could not be started by any
    means the app offered. The button did nothing, silently, for good.
    """
    from muse import catalog, db, jobs

    track = catalog.create_from_source("bandcamp", {
        "provider_id": "777", "title": "Gone wrong", "artists": [],
        "url": "https://band.bandcamp.com/track/gone-wrong",
    }, download=False)
    db.run("""update tracks set state='failed', fail_reason='Download cancelled',
                     fail_code='cancelled' where id=%s""", (track["id"],))

    assert jobs.promote(track["id"]) is True
    assert db.one("select state from tracks where id=%s", (track["id"],))["state"] \
        == "pending"
    assert db.one("""select 1 from jobs where kind='ingest_direct'
                      and (payload->>'track_id')::int=%s""", (track["id"],))


def test_a_song_with_nowhere_left_says_so_rather_than_nothing(client, hdr):
    from muse import catalog, db, jobs

    track = catalog.create_from_source("bandcamp", {
        "provider_id": "888", "title": "Nowhere", "artists": [],
    }, download=False)
    db.run("update track_sources set raw='{}'::jsonb where track_id=%s", (track["id"],))
    db.run("update tracks set state='failed' where id=%s", (track["id"],))

    assert jobs.promote(track["id"]) is False
    row = db.one("select state, fail_code from tracks where id=%s", (track["id"],))
    assert row["state"] == "failed", "not left sitting at pending with nothing coming"
    assert row["fail_code"] == "no_source"

    r = client.post("/downloads/promote", headers=hdr,
                    json={"track_ids": [track["id"]]})
    assert r.status_code == 200
    assert r.json()["promoted"] == 0
    assert r.json()["stuck"] == [track["id"]], "the caller is told which one"


def test_a_failure_names_the_service_the_song_came_from(client, hdr):
    """"This track isn't available on YouTube any more" on a SoundCloud track is both
    wrong and unactionable: it never was on YouTube."""
    from muse import failures

    code, message, retry = failures.classify(
        "ERROR: [soundcloud] 12: Video unavailable", "soundcloud")
    assert code == "unavailable" and not retry
    assert "SoundCloud" in message and "YouTube" not in message

    _, youtube, _ = failures.classify(
        "ERROR: [youtube] ab: Video unavailable", "ytmusic")
    assert "YouTube" in youtube

    # And where nobody said, it does not invent one.
    _, vague, _ = failures.classify("ERROR: Video unavailable", None)
    assert "YouTube" not in vague and "SoundCloud" not in vague


def test_the_failures_screen_shows_failures_that_are_still_true(client, hdr):
    """A song found on the ninth attempt and playing perfectly used to show the eight
    dead ids underneath it in red.

    The screen listed every job that had ever failed, for ever, so it was a history of
    attempts rather than a list of things needing attention — and the one real failure
    was lost among them.
    """
    from muse import catalog, db, jobs

    fine = catalog.create_from_source("soundcloud", {
        "provider_id": "1", "title": "Found in the end", "artists": [],
        "url": "https://soundcloud.com/a/found",
    }, download=False)
    broken = catalog.create_from_source("soundcloud", {
        "provider_id": "2", "title": "Still broken", "artists": [],
        "url": "https://soundcloud.com/a/broken",
    }, download=False)

    for track in (fine, broken):
        job = jobs.enqueue("ingest", {"track_id": track["id"], "video_id": "dead"})
        db.run("""update jobs set state='failed', error='ERROR: [youtube] dead: Video unavailable'
                   where id=%s""", (job,))
        db.run("update tracks set state='failed' where id=%s", (track["id"],))

    # The first one was found somewhere else since, and plays.
    db.run("update tracks set state='ready' where id=%s", (fine["id"],))

    listed = client.get("/downloads", headers=hdr).json()["failed"]
    ids = [row["track_id"] for row in listed]
    assert broken["id"] in ids
    assert fine["id"] not in ids, "a song that plays is not a failure"

    # And what it says is a sentence about the song, not yt-dlp's output.
    row = next(r for r in listed if r["track_id"] == broken["id"])
    assert "ERROR:" not in (row["error"] or "")


def test_a_copy_that_is_gone_is_not_reached_for_again(client, hdr):
    """One track collected nine YouTube ids and kept trying the dead ones."""
    from muse import catalog, db, jobs

    track = catalog.create_from_source("soundcloud", {
        "provider_id": "live", "title": "Two copies", "artists": [],
        "url": "https://soundcloud.com/a/live",
    }, download=False)
    db.run("""insert into track_sources(track_id,provider,provider_id,raw)
              values(%s,'ytmusic','gone','{"dead": true}'::jsonb)""", (track["id"],))

    best = jobs.best_source(track["id"])
    assert best is not None and best["provider"] == "soundcloud"

    # And when the only copy left is a dead one, there is nothing to try.
    db.run("""update track_sources set raw = raw || '{"dead": true}'
               where track_id=%s and provider='soundcloud'""", (track["id"],))
    assert jobs.best_source(track["id"]) is None


def test_a_dead_copy_is_written_off_from_the_job_that_proved_it(client, hdr, wsec):
    """The worker says what went wrong and which track; it has never said which video.

    So the rule that writes off a dead copy looked for a video id that was never in the
    request and marked nothing — and one track failed on the same dead id ten times in
    a row, because every attempt reached for the copy already known not to work. The
    server queued the job. It knows what it asked for.
    """
    from muse import db, jobs

    track = client.post("/tracks/resolve", headers=hdr,
                        json={"video_id": "GONE1"}).json()
    job = db.one("""select id from jobs where kind='ingest'
                     and (payload->>'track_id')::int=%s""", (track["id"],))["id"]

    client.post(f"/internal/jobs/{job}/fail", headers=wsec,
                json={"reason": "ERROR: [youtube] GONE1: Video unavailable",
                      "retryable": False, "track_id": track["id"]})

    dead = db.one("""select raw->>'dead' as dead from track_sources
                      where track_id=%s and provider_id='GONE1'""", (track["id"],))
    assert dead["dead"] == "true"
    assert jobs.best_source(track["id"]) is None, "nothing left worth trying"


def test_a_song_whose_last_copy_dies_goes_looking_by_itself(client, hdr, wsec):
    """A video being deleted says nothing about the song.

    "This track isn't on YouTube any more" is true of a video and wrong about a song
    that plainly is still there — so when the last source dies the search starts on its
    own rather than waiting for somebody to notice and press a button.
    """
    from muse import db

    track = client.post("/tracks/resolve", headers=hdr,
                        json={"video_id": "GONE2"}).json()
    job = db.one("""select id from jobs where kind='ingest'
                     and (payload->>'track_id')::int=%s""", (track["id"],))["id"]

    client.post(f"/internal/jobs/{job}/fail", headers=wsec,
                json={"reason": "ERROR: [youtube] GONE2: Video unavailable",
                      "retryable": False, "track_id": track["id"]})

    queued = db.one("""select 1 from jobs where kind='refind'
                        and (payload->>'track_id')::int=%s""", (track["id"],))
    assert queued, "it went looking"


def test_a_copy_that_merely_timed_out_is_not_written_off(client, hdr, wsec):
    """Only failures about the copy. A network that dropped says nothing about whether
    the video is there, and writing it off would throw away a good source."""
    from muse import db

    track = client.post("/tracks/resolve", headers=hdr,
                        json={"video_id": "SLOW1"}).json()
    job = db.one("""select id from jobs where kind='ingest'
                     and (payload->>'track_id')::int=%s""", (track["id"],))["id"]

    client.post(f"/internal/jobs/{job}/fail", headers=wsec,
                json={"reason": "ERROR: unable to download: connection timed out",
                      "retryable": True, "track_id": track["id"]})

    dead = db.one("""select raw->>'dead' as dead from track_sources
                      where track_id=%s and provider_id='SLOW1'""", (track["id"],))
    assert dead["dead"] is None
