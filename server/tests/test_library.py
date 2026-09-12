"""Queues are the product. Order is versioned, the cursor is not."""
from __future__ import annotations

import pytest


@pytest.fixture()
def tracks(client, hdr):
    """Three ready-ish tracks to arrange."""
    out = []
    for vid in ("AAA", "BBB", "CCC"):
        out.append(client.post("/tracks/resolve", headers=hdr, json={"video_id": vid}).json())
    return out


# ---------------- queues ----------------
def test_queues_are_named_and_separate(client, hdr, tracks):
    a = client.post("/queues", headers=hdr, json={"name": "Now"}).json()
    b = client.post("/queues", headers=hdr, json={"name": "Sleep"}).json()
    assert a["id"] != b["id"]

    client.put(f"/queues/{a['id']}", headers=hdr,
               json={"rev": a["rev"], "items": [t["id"] for t in tracks]})
    client.put(f"/queues/{b['id']}", headers=hdr,
               json={"rev": b["rev"], "items": [tracks[0]["id"]]})

    assert len(client.get(f"/queues/{a['id']}", headers=hdr).json()["items"]) == 3
    assert len(client.get(f"/queues/{b['id']}", headers=hdr).json()["items"]) == 1
    assert {q["name"] for q in client.get("/queues", headers=hdr).json()} == {"Now", "Sleep"}


def test_duplicate_queue_name_is_409(client, hdr):
    client.post("/queues", headers=hdr, json={"name": "Now"})
    assert client.post("/queues", headers=hdr, json={"name": "Now"}).status_code == 409


def test_replace_bumps_rev_and_stale_rev_conflicts(client, hdr, tracks):
    q = client.post("/queues", headers=hdr, json={"name": "Now"}).json()
    first = client.put(f"/queues/{q['id']}", headers=hdr,
                       json={"rev": q["rev"], "items": [tracks[0]["id"]]}).json()
    assert first["rev"] == q["rev"] + 1

    stale = client.put(f"/queues/{q['id']}", headers=hdr,
                       json={"rev": q["rev"], "items": [tracks[1]["id"]]})
    assert stale.status_code == 409
    # the loser is handed the live state so it can merge instead of guessing
    assert stale.json()["detail"]["current"]["items"][0]["id"] == tracks[0]["id"]


def test_cursor_does_not_bump_rev(client, hdr, tracks):
    q = client.post("/queues", headers=hdr, json={"name": "Now"}).json()
    q = client.put(f"/queues/{q['id']}", headers=hdr,
                   json={"rev": q["rev"], "items": [t["id"] for t in tracks]}).json()
    moved = client.patch(f"/queues/{q['id']}/cursor", headers=hdr,
                         json={"cursor_index": 2, "position_ms": 45_000}).json()
    assert moved["cursor_index"] == 2 and moved["position_ms"] == 45_000
    assert moved["rev"] == q["rev"]          # the playing device wins, no conflict


def test_cursor_is_clamped_when_the_queue_shrinks(client, hdr, tracks):
    q = client.post("/queues", headers=hdr, json={"name": "Now"}).json()
    q = client.put(f"/queues/{q['id']}", headers=hdr,
                   json={"rev": q["rev"], "items": [t["id"] for t in tracks]}).json()
    client.patch(f"/queues/{q['id']}/cursor", headers=hdr, json={"cursor_index": 2})
    shrunk = client.put(f"/queues/{q['id']}", headers=hdr,
                        json={"rev": q["rev"], "items": [tracks[0]["id"]]}).json()
    assert shrunk["cursor_index"] == 0


def test_play_next_inserts_above_the_radio_tail(client, hdr, tracks):
    q = client.post("/queues", headers=hdr, json={"name": "Now"}).json()
    q = client.put(f"/queues/{q['id']}", headers=hdr, json={
        "rev": q["rev"],
        "items": [{"track_id": tracks[0]["id"], "origin": "user"},
                  {"track_id": tracks[1]["id"], "origin": "radio"}],
    }).json()
    after = client.post(f"/queues/{q['id']}/items", headers=hdr,
                        json={"track_ids": [tracks[2]["id"]], "mode": "next"}).json()
    origins = [(i["id"], i["origin"]) for i in after["items"]]
    # "next" is its own origin: it is what keeps a run of play-nexts in the order the
    # button was pressed, and it is still above the radio tail.
    assert origins == [(tracks[0]["id"], "user"),
                       (tracks[2]["id"], "next"),      # above the radio tail
                       (tracks[1]["id"], "radio")]


def test_save_queue_as_playlist(client, hdr, tracks):
    q = client.post("/queues", headers=hdr, json={"name": "Gym"}).json()
    client.put(f"/queues/{q['id']}", headers=hdr,
               json={"rev": q["rev"], "items": [t["id"] for t in tracks]})
    p = client.post(f"/queues/{q['id']}/save-as-playlist", headers=hdr, json={}).json()
    assert p["name"] == "Gym"
    assert [i["id"] for i in p["items"]] == [t["id"] for t in tracks]


def test_queue_of_another_user_is_404(client, hdr, cfg):
    q = client.post("/queues", headers=hdr, json={"name": "Now"}).json()
    from muse import auth
    other = auth.ensure_user("someone-else")
    tok = auth.issue_token(other, "phone", None)
    r = client.get(f"/queues/{q['id']}", headers={"Authorization": f"Bearer {tok}"})
    assert r.status_code == 404


# ---------------- playlists ----------------
def test_playlist_crud(client, hdr, tracks):
    p = client.post("/playlists", headers=hdr, json={"name": "Roadtrip"}).json()
    full = client.post(f"/playlists/{p['id']}/items", headers=hdr,
                       json={"track_ids": [t["id"] for t in tracks]}).json()
    assert [i["id"] for i in full["items"]] == [t["id"] for t in tracks]
    # By name, not by position: the favourites list is a playlist too and it sorts
    # first, so index 0 is not the one just made.
    listed = client.get("/playlists", headers=hdr).json()
    assert next(x for x in listed if x["name"] == "Roadtrip")["items"] == 3
    assert client.delete(f"/playlists/{p['id']}", headers=hdr).status_code == 200
    assert client.get(f"/playlists/{p['id']}", headers=hdr).status_code == 404


def test_playlist_needs_a_name(client, hdr):
    assert client.post("/playlists", headers=hdr, json={"name": "  "}).status_code == 400


# Radio moved out and became a station — a queue that keeps going rather than a tail
# on the end of another one. See test_stations.py; what remains here is that the queue
# still knows which of its rows a machine chose, because that is what "clear the radio
# tracks" acts on and what "play next" has to insert above.


def test_queued_and_playlisted_tracks_carry_a_stream_url(client, hdr, wsec, complete_job):
    """Without the media join these come back looking unplayable, and the client
    correctly refuses to play them — which reads as "playback is broken"."""
    t = client.post("/tracks/resolve", headers=hdr, json={"video_id": "PLAYABLE1"}).json()
    job = client.post("/internal/jobs/lease", headers=wsec, json={"worker": "w"}).json()["jobs"][0]
    complete_job(job["id"], t["id"])

    q = client.post("/queues", headers=hdr, json={"name": "Now"}).json()
    filled = client.put(f"/queues/{q['id']}", headers=hdr,
                        json={"rev": q["rev"], "items": [t["id"]]}).json()
    assert filled["items"][0]["state"] == "ready"
    assert filled["items"][0]["stream_url"] == f"/tracks/{t['id']}/stream"

    p = client.post("/playlists", headers=hdr, json={"name": "Mix"}).json()
    full = client.post(f"/playlists/{p['id']}/items", headers=hdr,
                       json={"track_ids": [t["id"]]}).json()
    assert full["items"][0]["stream_url"] == f"/tracks/{t['id']}/stream"

    # and a track that genuinely has no media must still report itself as pending
    pending = client.post("/tracks/resolve", headers=hdr, json={"video_id": "NOTREADY1"}).json()
    client.post(f"/queues/{q['id']}/items", headers=hdr, json={"track_ids": [pending["id"]]})
    got = client.get(f"/queues/{q['id']}", headers=hdr).json()
    unready = [i for i in got["items"] if i["id"] == pending["id"]][0]
    assert unready["stream_url"] is None and unready["state"] == "pending"


# ---------------- settings vs order (a settings PUT used to wipe the queue) ----------
def test_settings_update_does_not_touch_the_items(client, hdr, tracks):
    q = client.post("/queues", headers=hdr, json={"name": "Now"}).json()
    q = client.put(f"/queues/{q['id']}", headers=hdr,
                   json={"rev": q["rev"], "items": [t["id"] for t in tracks]}).json()

    patched = client.patch(f"/queues/{q['id']}", headers=hdr,
                           json={"shuffle": True, "repeat": "all"}).json()
    assert patched["shuffle"] is True and patched["repeat"] == "all"
    assert len(patched["items"]) == 3, "settings must never clear the queue"


def test_put_without_items_is_refused(client, hdr, tracks):
    q = client.post("/queues", headers=hdr, json={"name": "Now"}).json()
    client.put(f"/queues/{q['id']}", headers=hdr,
               json={"rev": q["rev"], "items": [tracks[0]["id"]]})
    r = client.put(f"/queues/{q['id']}", headers=hdr, json={"shuffle": True})
    assert r.status_code == 400
    assert len(client.get(f"/queues/{q['id']}", headers=hdr).json()["items"]) == 1


def test_emptying_a_queue_still_works_when_explicit(client, hdr, tracks):
    q = client.post("/queues", headers=hdr, json={"name": "Now"}).json()
    q = client.put(f"/queues/{q['id']}", headers=hdr,
                   json={"rev": q["rev"], "items": [tracks[0]["id"]]}).json()
    cleared = client.put(f"/queues/{q['id']}", headers=hdr,
                         json={"rev": q["rev"], "items": []}).json()
    assert cleared["items"] == []


def test_repeat_mode_is_validated(client, hdr):
    q = client.post("/queues", headers=hdr, json={"name": "Now"}).json()
    assert client.patch(f"/queues/{q['id']}", headers=hdr,
                        json={"repeat": "sideways"}).status_code == 400


# ---------------- item-level queue editing ----------------
@pytest.fixture()
def filled_queue(client, hdr, tracks):
    q = client.post("/queues", headers=hdr, json={"name": "Now"}).json()
    return client.put(f"/queues/{q['id']}", headers=hdr,
                      json={"rev": q["rev"], "items": [t["id"] for t in tracks]}).json()


def test_removing_an_item_compacts_positions(client, hdr, tracks, filled_queue):
    left = client.delete(f"/queues/{filled_queue['id']}/items/1", headers=hdr).json()
    assert [i["id"] for i in left["items"]] == [tracks[0]["id"], tracks[2]["id"]]
    assert [i["pos"] for i in left["items"]] == [0, 1], "no gaps in the order"
    assert left["rev"] > filled_queue["rev"]


def test_removing_above_the_cursor_does_not_skip_playback(client, hdr, tracks,
                                                          filled_queue):
    qid = filled_queue["id"]
    client.patch(f"/queues/{qid}/cursor", headers=hdr, json={"cursor_index": 2})
    after = client.delete(f"/queues/{qid}/items/0", headers=hdr).json()
    assert after["cursor_index"] == 1, "the same track must still be current"
    assert after["items"][after["cursor_index"]]["id"] == tracks[2]["id"]


def test_removing_a_missing_position_is_404(client, hdr, filled_queue):
    assert client.delete(f"/queues/{filled_queue['id']}/items/99",
                         headers=hdr).status_code == 404


def test_moving_an_item_keeps_the_current_track_current(client, hdr, tracks,
                                                        filled_queue):
    qid = filled_queue["id"]
    client.patch(f"/queues/{qid}/cursor", headers=hdr, json={"cursor_index": 0})
    moved = client.post(f"/queues/{qid}/move", headers=hdr,
                        json={"from": 0, "to": 2}).json()
    assert [i["id"] for i in moved["items"]] == [
        tracks[1]["id"], tracks[2]["id"], tracks[0]["id"]]
    assert moved["items"][moved["cursor_index"]]["id"] == tracks[0]["id"], \
        "dragging the playing track must not change what is playing"


def test_move_validates_its_range(client, hdr, filled_queue):
    qid = filled_queue["id"]
    assert client.post(f"/queues/{qid}/move", headers=hdr,
                       json={"from": 0, "to": 9}).status_code == 400
    assert client.post(f"/queues/{qid}/move", headers=hdr, json={}).status_code == 400


def test_clearing_only_the_radio_tail(client, hdr, tracks, filled_queue):
    qid = filled_queue["id"]
    client.post(f"/queues/{qid}/items", headers=hdr,
                json={"track_ids": [tracks[0]["id"]], "origin": "radio"})
    cleared = client.post(f"/queues/{qid}/clear", headers=hdr,
                          json={"origin": "radio"}).json()
    assert len(cleared["items"]) == 3
    assert all(i["origin"] == "user" for i in cleared["items"])
    assert [i["pos"] for i in cleared["items"]] == [0, 1, 2]


def test_clearing_everything(client, hdr, filled_queue):
    cleared = client.post(f"/queues/{filled_queue['id']}/clear", headers=hdr,
                          json={}).json()
    assert cleared["items"] == [] and cleared["cursor_index"] == 0


def test_removing_a_playlist_item(client, hdr, tracks):
    p = client.post("/playlists", headers=hdr, json={"name": "Mix"}).json()
    client.post(f"/playlists/{p['id']}/items", headers=hdr,
                json={"track_ids": [t["id"] for t in tracks]})
    left = client.delete(f"/playlists/{p['id']}/items/0", headers=hdr).json()
    assert [i["id"] for i in left["items"]] == [tracks[1]["id"], tracks[2]["id"]]


def test_play_next_lands_next_and_keeps_its_order(client, hdr, tracks):
    """"Play next" must put a song after the one playing, not at the end.

    It never did: the positions are a primary key, and shifting a block of rows up with
    one `set pos = pos + 1` collides with the row still sitting in the slot the first
    one is moving into. The queue only shifted anything when there was something to
    shift past, so the failure was invisible until somebody used the feature.
    """
    a, b, c = tracks
    q = client.post("/queues", headers=hdr, json={"name": "Now"}).json()
    client.post(f"/queues/{q['id']}/items", headers=hdr,
                json={"track_ids": [a["id"], b["id"], c["id"]]})
    client.patch(f"/queues/{q['id']}/cursor", headers=hdr, json={"cursor_index": 0})

    first = client.post(f"/queues/{q['id']}/items", headers=hdr,
                        json={"track_ids": [c["id"]], "mode": "next"})
    assert first.status_code == 200, first.text
    second = client.post(f"/queues/{q['id']}/items", headers=hdr,
                         json={"track_ids": [b["id"]], "mode": "next"})
    assert second.status_code == 200, second.text

    items = second.json()["items"]
    assert [i["pos"] for i in items] == [0, 1, 2, 3, 4], "positions stay contiguous"
    # Straight after the playing track, and in the order the button was pressed.
    assert items[1]["id"] == c["id"]
    assert items[2]["id"] == b["id"]
    assert items[1]["origin"] == "next"


def test_removing_from_the_middle_closes_the_gap(client, hdr, tracks):
    """The same shift, downwards: it has the same collision if it is done row by row."""
    a, b, c = tracks
    q = client.post("/queues", headers=hdr, json={"name": "Now"}).json()
    client.post(f"/queues/{q['id']}/items", headers=hdr,
                json={"track_ids": [a["id"], b["id"], c["id"]]})
    gone = client.delete(f"/queues/{q['id']}/items/0", headers=hdr)
    assert gone.status_code == 200, gone.text
    items = gone.json()["items"]
    assert [i["pos"] for i in items] == [0, 1]
    assert [i["id"] for i in items] == [b["id"], c["id"]]


# ---------------- importing a backup from another player ----------------
BACKUP = {
    "version": 1,
    "playlists": [
        {"name": "Acid", "tracks": ["t111", "t222"]},
        {"name": "Ambient", "tracks": ["t222", "t999"]},
    ],
    "tracks": [
        {"id": "t111", "trackId": 111, "title": "First", "artist": "A Band",
         "album": "A Record", "durationMs": 1000,
         "pageUrl": "https://band.bandcamp.com/album/a-record"},
        {"id": "t222", "trackId": 222, "title": "Second", "artist": "A Band",
         "album": "A Record", "durationMs": 2000,
         "pageUrl": "https://band.bandcamp.com/album/a-record"},
    ],
}


def test_a_backup_becomes_playlists(client, hdr):
    """The ids in a bcplayer backup are Bandcamp's own, and so are ours: an import is
    mostly a lookup, and only what is genuinely new is queued for fetching."""
    r = client.post("/playlists/import", headers=hdr, json=BACKUP)
    assert r.status_code == 201, r.text
    body = r.json()
    assert [p["name"] for p in body["playlists"]] == ["Acid", "Ambient"]
    assert body["tracks"] == 3, "two in the first, one findable in the second"
    assert body["missing"] == 1, "t999 is named by a playlist and described nowhere"

    listed = client.get("/playlists", headers=hdr).json()
    acid = next(p for p in listed if p["name"] == "Acid")
    assert acid["items"] == 2

    # The track that was created carries what the file knew about it, and a reference
    # that names it on the page it shares with the rest of the record.
    made = client.get(f"/playlists/{acid['id']}", headers=hdr).json()["items"]
    assert [t["title"] for t in made] == ["First", "Second"]
    assert all(t["source"] == "bandcamp" for t in made)


def test_a_backup_queues_songs_the_catalog_already_knows_of(client, hdr, monkeypatch):
    """A song already in the catalog but never downloaded still has to be fetched.

    This is what a backup import mostly *is*: the ids in it are Bandcamp's, a wishlist
    mirror already recorded thousands of them, and every one of those matched. Counting
    a match as "nothing to do" meant twenty-five playlists arrived with no audio behind
    a single song in them, and no way to ask for any.
    """
    from muse import catalog, jobs

    # A track already known here, listed but never fetched — exactly what a mirror
    # leaves behind.
    known = catalog.create_from_source("bandcamp", {
        "provider_id": "111", "title": "First", "artists": ["A Band"],
        "url": "https://band.bandcamp.com/track/first",
    }, download=False)
    assert known["state"] == "pending"

    r = client.post("/playlists/import", headers=hdr, json=BACKUP)
    assert r.status_code == 201, r.text

    queued = jobs.db.all_(
        """select payload->>'ref' as ref from jobs
            where kind='ingest_direct' and (payload->>'track_id')::int = %s""",
        (known["id"],))
    assert len(queued) == 1, "the song that was only listed is now actually queued"
    assert queued[0]["ref"] == "https://band.bandcamp.com/track/first"


def test_a_playlist_says_how_many_of_its_songs_have_no_audio(client, hdr):
    """The number the "Get all" button hangs on. `download_mode` says what was meant to
    happen at import; this says what is true now."""
    client.post("/playlists/import", headers=hdr, json=BACKUP)
    listed = client.get("/playlists", headers=hdr).json()
    acid = next(p for p in listed if p["name"] == "Acid")
    full = client.get(f"/playlists/{acid['id']}", headers=hdr).json()
    assert full["waiting"] == 2, "neither has been downloaded"


def test_a_bandcamp_track_with_no_page_is_not_queued_to_fail(client, hdr):
    """An id on its own names nothing Bandcamp can look up.

    Queueing it anyway produced a job that failed on every attempt, and a song that sat
    "downloading" for good. Better to leave it alone and say nothing was queued.
    """
    from muse import catalog, jobs, db

    track = catalog.create_from_source("bandcamp", {
        "provider_id": "555", "title": "Nowhere", "artists": [],
    }, download=False)
    db.run("update track_sources set raw='{}'::jsonb where track_id=%s", (track["id"],))

    assert jobs.promote(track["id"]) is False
    assert db.all_("""select 1 from jobs where kind='ingest_direct'
                       and (payload->>'track_id')::int = %s""", (track["id"],)) == []


def test_a_track_imported_from_a_backup_can_be_queued_later(client, hdr):
    """The page it lives on travels with the row.

    A backup file calls it `pageUrl`; the fetcher wants "<page>#<id>". Losing that on
    the way in left the track with a bare numeric id as its only reference, which is
    not a URL and never becomes one.
    """
    from muse import catalog, jobs, db

    track = catalog.create_from_source("bandcamp", {
        "provider_id": "777", "title": "On A Record", "artists": [],
        "url": "https://band.bandcamp.com/album/a-record#777",
        "raw": {"pageUrl": "https://band.bandcamp.com/album/a-record",
                "trackId": 777},
    }, download=False)

    assert jobs.promote(track["id"]) is True
    ref = db.one("""select payload->>'ref' as ref from jobs
                     where kind='ingest_direct'
                       and (payload->>'track_id')::int = %s""", (track["id"],))["ref"]
    assert ref == "https://band.bandcamp.com/album/a-record#777"


def test_importing_the_same_file_twice_does_not_double_it(client, hdr):
    client.post("/playlists/import", headers=hdr, json=BACKUP)
    again = client.post("/playlists/import", headers=hdr, json=BACKUP)
    assert again.status_code == 201
    listed = client.get("/playlists", headers=hdr).json()
    assert len([p for p in listed if p["name"] == "Acid"]) == 1
    assert next(p for p in listed if p["name"] == "Acid")["items"] == 2


def test_a_backup_from_something_else_says_so(client, hdr):
    r = client.post("/playlists/import", headers=hdr,
                    json={"format": "winamp", "playlists": [{"name": "x"}]})
    assert r.status_code == 400
    assert "winamp" in r.json()["detail"]


def test_a_file_with_no_playlists_is_refused(client, hdr):
    r = client.post("/playlists/import", headers=hdr, json={"tracks": []})
    assert r.status_code == 400


def test_shuffling_rearranges_what_is_coming_and_leaves_the_rest(client, hdr, tracks):
    """Shuffle is a thing you do, not a mode you are in.

    What is playing stays playing and what has already gone by stays where it was; only
    the songs still to come are rearranged — and then it is over, so the list on screen
    is the order that will be heard.
    """
    q = client.post("/queues", headers=hdr, json={"name": "Now"}).json()
    ids = [t["id"] for t in tracks]
    # Six rows, so a shuffle that changed nothing would be a one-in-many accident.
    client.post(f"/queues/{q['id']}/items", headers=hdr, json={"track_ids": ids + ids})
    client.patch(f"/queues/{q['id']}/cursor", headers=hdr, json={"cursor_index": 1})

    before = [i["id"] for i in client.get(f"/queues/{q['id']}", headers=hdr).json()["items"]]
    shuffled = client.post(f"/queues/{q['id']}/shuffle", headers=hdr, json={})
    assert shuffled.status_code == 200, shuffled.text
    after = [i["id"] for i in shuffled.json()["items"]]

    assert after[:2] == before[:2], "the song playing and the ones behind it stay put"
    assert sorted(after[2:]) == sorted(before[2:]), "the same songs, rearranged"
    assert [i["pos"] for i in shuffled.json()["items"]] == list(range(6))


def test_shuffling_a_queue_with_nothing_coming_is_harmless(client, hdr, tracks):
    q = client.post("/queues", headers=hdr, json={"name": "Now"}).json()
    client.post(f"/queues/{q['id']}/items", headers=hdr,
                json={"track_ids": [tracks[0]["id"]]})
    r = client.post(f"/queues/{q['id']}/shuffle", headers=hdr, json={})
    assert r.status_code == 200
    assert len(r.json()["items"]) == 1


def test_a_selection_moves_as_one_block(client, hdr, tracks):
    """Dragging one row of a selection brings the rest with it, in their own order and
    without disturbing anything between them."""
    q = client.post("/queues", headers=hdr, json={"name": "Now"}).json()
    ids = [t["id"] for t in tracks]              # three distinct tracks
    client.post(f"/queues/{q['id']}/items", headers=hdr,
                json={"track_ids": ids + ids})   # six rows: A B C A B C

    moved = client.post(f"/queues/{q['id']}/move", headers=hdr,
                        json={"from": [3, 5], "to": 0})
    assert moved.status_code == 200, moved.text
    got = [i["id"] for i in moved.json()["items"]]
    assert got == [ids[0], ids[2], ids[0], ids[1], ids[2], ids[1]], \
        "the two picked rows land at the top, in the order they were in"
    assert [i["pos"] for i in moved.json()["items"]] == list(range(6))


def test_moving_a_block_past_itself_is_not_an_error(client, hdr, tracks):
    q = client.post("/queues", headers=hdr, json={"name": "Now"}).json()
    ids = [t["id"] for t in tracks]
    client.post(f"/queues/{q['id']}/items", headers=hdr, json={"track_ids": ids})
    r = client.post(f"/queues/{q['id']}/move", headers=hdr,
                    json={"from": [0, 1], "to": 2})
    assert r.status_code == 200
    assert [i["id"] for i in r.json()["items"]] == [ids[2], ids[0], ids[1]]


def test_an_import_can_be_rehearsed_first(client, hdr):
    """A backup is somebody's whole listening history, and putting one in the wrong
    account is easy to do and tedious to undo. So it can be asked first."""
    before = client.get("/playlists", headers=hdr).json()

    rehearsal = client.post("/playlists/import", headers=hdr,
                            json={**BACKUP, "dry_run": True})
    assert rehearsal.status_code == 201, rehearsal.text
    said = rehearsal.json()
    assert said["dry_run"] is True
    assert [p["name"] for p in said["playlists"]] == ["Acid", "Ambient"]
    assert said["tracks"] == 3 and said["missing"] == 1
    assert said["fetch"] == 2, "two songs are not here yet and would be fetched"

    after = client.get("/playlists", headers=hdr).json()
    assert [p["id"] for p in after] == [p["id"] for p in before], \
        "a rehearsal writes nothing at all"

    # And what it said is what happens.
    real = client.post("/playlists/import", headers=hdr, json=BACKUP).json()
    assert real["tracks"] == said["tracks"]
    assert real["missing"] == said["missing"]


def test_a_rehearsal_says_which_playlists_it_would_replace(client, hdr):
    client.post("/playlists/import", headers=hdr, json=BACKUP)
    again = client.post("/playlists/import", headers=hdr,
                        json={**BACKUP, "dry_run": True}).json()
    assert again["replaces"] == 2, "both would be written over, not added beside"
    assert all(p["replaces"] for p in again["playlists"])


def test_which_playlists_already_hold_these_songs(client, hdr, tracks):
    """The tick-boxes in the add-to-playlist sheet, in one request.

    Three states have to come out of this: a list with all of them, a list with some,
    and a list with none — and "none" means absent from the answer rather than zero,
    which is what lets the sheet draw an empty box without knowing every playlist.
    """
    ids = [t["id"] for t in tracks]
    everything = client.post("/playlists", headers=hdr, json={"name": "All"}).json()
    some = client.post("/playlists", headers=hdr, json={"name": "Some"}).json()
    none = client.post("/playlists", headers=hdr, json={"name": "None"}).json()
    client.post(f"/playlists/{everything['id']}/items", headers=hdr,
                json={"track_ids": ids})
    client.post(f"/playlists/{some['id']}/items", headers=hdr,
                json={"track_ids": ids[:1]})

    held = client.post("/playlists/holding", headers=hdr,
                       json={"track_ids": ids}).json()["holding"]
    assert held[str(everything["id"])] == len(ids)
    assert held[str(some["id"])] == 1
    assert str(none["id"]) not in held


def test_holding_only_answers_for_your_own_playlists(client, hdr, tracks):
    ids = [t["id"] for t in tracks]
    mine = client.post("/playlists", headers=hdr, json={"name": "Mine"}).json()
    client.post(f"/playlists/{mine['id']}/items", headers=hdr, json={"track_ids": ids})

    client.post("/accounts", headers=hdr,
                json={"name": "sam", "password": "correct-horse"})
    token = client.post("/auth/login",
                        data={"user": "sam", "password": "correct-horse"}).json()["token"]
    theirs = {"Authorization": f"Bearer {token}"}
    held = client.post("/playlists/holding", headers=theirs,
                       json={"track_ids": ids}).json()["holding"]
    assert str(mine["id"]) not in held


def test_taking_songs_off_a_playlist_by_id(client, hdr, tracks):
    """Unticking a list in the sheet: it knows the songs, never the positions."""
    ids = [t["id"] for t in tracks]
    p = client.post("/playlists", headers=hdr, json={"name": "Mix"}).json()
    client.post(f"/playlists/{p['id']}/items", headers=hdr, json={"track_ids": ids})
    left = client.post(f"/playlists/{p['id']}/items/remove", headers=hdr,
                       json={"track_ids": [ids[0], ids[2]]}).json()
    assert [i["id"] for i in left["items"]] == [ids[1]]


def test_favourites_can_be_added_to_from_the_playlist_sheet(client, hdr, tracks):
    """Favourites is a list songs go into, whoever asked.

    The heart wrote to it and the playlist sheet was refused with a 409 about mirroring
    — one list behaving two ways depending on which button was pressed.
    """
    favourites = next(p for p in client.get("/playlists", headers=hdr).json()
                      if p["kind"] == "favourites")
    track = tracks[0]["id"]
    assert client.post(f"/playlists/{favourites['id']}/items", headers=hdr,
                       json={"track_ids": [track]}).status_code == 200
    assert track in client.get("/favourites", headers=hdr).json()["track_ids"]
    client.post(f"/playlists/{favourites['id']}/items/remove", headers=hdr,
                json={"track_ids": [track]})
    assert track not in client.get("/favourites", headers=hdr).json()["track_ids"]


def test_a_mirrored_playlist_still_refuses_both_ways(client, hdr, tracks):
    mirror = client.post("/playlists", headers=hdr,
                         json={"name": "Theirs", "kind": "spotify"}).json()
    ids = [tracks[0]["id"]]
    assert client.post(f"/playlists/{mirror['id']}/items", headers=hdr,
                       json={"track_ids": ids}).status_code == 409
    assert client.post(f"/playlists/{mirror['id']}/items/remove", headers=hdr,
                       json={"track_ids": ids}).status_code == 409


def test_a_very_long_queue_is_sent_in_a_slice(client, hdr, tracks):
    """Somebody's mirrored favourites is fourteen thousand songs. Sent whole it is
    seven megabytes of JSON and fourteen thousand objects for a browser to hold, which
    on a phone is the page being killed and on a laptop is a lock-up every time
    anything about the queue changes."""
    from muse import routes_library

    q = client.post("/queues", headers=hdr, json={"name": "Everything"}).json()
    # Longer than the window, built out of the three tracks over and over.
    many = [tracks[i % len(tracks)]["id"]
            for i in range(routes_library.QUEUE_WINDOW + 200)]
    client.put(f"/queues/{q['id']}", headers=hdr,
               json={"rev": q["rev"], "items": many})

    got = client.get(f"/queues/{q['id']}", headers=hdr).json()
    assert got["total"] == len(many), "it still says how long it really is"
    assert len(got["items"]) == routes_library.QUEUE_WINDOW
    assert got["window_from"] == 0, "at the start, the slice starts at the start"

    # Where you are decides which slice: ask for one around the far end.
    far = client.get(f"/queues/{q['id']}", headers=hdr,
                     params={"around": len(many) - 10}).json()
    assert far["window_from"] == len(many) - routes_library.QUEUE_WINDOW
    assert far["items"][-1]["pos"] == many.__len__() - 1, "and it reaches the end"

    # The cursor does the same thing without being asked.
    client.patch(f"/queues/{q['id']}/cursor", headers=hdr,
                 json={"cursor_index": len(many) - 5})
    followed = client.get(f"/queues/{q['id']}", headers=hdr).json()
    assert followed["window_from"] > 0


def test_a_short_queue_is_sent_whole(client, hdr, tracks):
    q = client.post("/queues", headers=hdr, json={"name": "Short"}).json()
    client.put(f"/queues/{q['id']}", headers=hdr,
               json={"rev": q["rev"], "items": [t["id"] for t in tracks]})
    got = client.get(f"/queues/{q['id']}", headers=hdr).json()
    assert got["total"] == 3 and got["window_from"] == 0
    assert len(got["items"]) == 3
