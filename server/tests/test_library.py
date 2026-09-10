"""Queues are the product. Order is versioned, the cursor is not, radio is capped."""
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


# ---------------- radio ----------------
def test_radio_is_capped_and_marked(client, hdr, tracks):
    q = client.post("/queues", headers=hdr, json={"name": "Now"}).json()
    client.put(f"/queues/{q['id']}", headers=hdr,
               json={"rev": q["rev"], "items": [tracks[0]["id"]]})
    r = client.post(f"/queues/{q['id']}/radio", headers=hdr,
                    json={"seed_track_id": tracks[0]["id"], "count": 4}).json()
    assert r["radio_added"] == 4                      # not the 12 candidates offered
    tail = [i for i in r["items"] if i["origin"] == "radio"]
    assert len(tail) == 4
    assert all(i["discovered_via"] == "radio" for i in tail)   # findable for cleanup later
    assert r["items"][0]["origin"] == "user"                    # seed still on top


def test_radio_respects_the_hard_cap(client, hdr, tracks):
    q = client.post("/queues", headers=hdr, json={"name": "Now"}).json()
    r = client.post(f"/queues/{q['id']}/radio", headers=hdr,
                    json={"seed_track_id": tracks[0]["id"], "count": 99}).json()
    assert r["radio_added"] == 10                      # RADIO_MAX, never the whole watchlist


def test_radio_skips_tracks_already_queued(client, hdr, tracks):
    q = client.post("/queues", headers=hdr, json={"name": "Now"}).json()
    first = client.post(f"/queues/{q['id']}/radio", headers=hdr,
                        json={"seed_track_id": tracks[0]["id"], "count": 3}).json()
    second = client.post(f"/queues/{q['id']}/radio", headers=hdr,
                         json={"seed_track_id": tracks[0]["id"], "count": 3}).json()
    ids = [i["id"] for i in second["items"]]
    assert len(ids) == len(set(ids))                   # no duplicates in the queue
    assert second["radio_skipped"] >= first["radio_added"]


def test_radio_needs_a_seed_with_a_source(client, hdr):
    q = client.post("/queues", headers=hdr, json={"name": "Now"}).json()
    assert client.post(f"/queues/{q['id']}/radio", headers=hdr, json={}).status_code == 400


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
