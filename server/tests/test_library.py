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
    assert origins == [(tracks[0]["id"], "user"),
                       (tracks[2]["id"], "user"),      # above the radio tail
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
    assert client.get("/playlists", headers=hdr).json()[0]["items"] == 3
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
