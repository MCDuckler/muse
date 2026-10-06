"""Not for me: a song said no to is never offered again, out of every list and the feed
at once, counts against its artist, and after a couple of an act's, none of theirs is
offered at all. Taken back, it is as it was."""
from __future__ import annotations

import pytest

from muse import db, discover, recommend


def _me() -> int:
    return db.one("select id from users where name='chris'")["id"]


@pytest.fixture()
def shelf(client, hdr):
    """Eight songs here, each by somebody different, all on one list together."""
    ids = []
    for n in range(8):
        t = client.post("/tracks/resolve", headers=hdr, json={"video_id": f"NOPE{n}"}).json()
        db.run("update tracks set state='ready', title=%s, artists=%s where id=%s",
               (f"Nope Song {n}", [f"Nope Artist {n}"], t["id"]))
        ids.append(t["id"])
    p = client.post("/playlists", headers=hdr, json={"name": "together"}).json()
    client.post(f"/playlists/{p['id']}/items", headers=hdr, json={"track_ids": ids})
    return ids


def _dislike(client, hdr, tid, undo=False):
    r = client.post("/recommend/dislike", headers=hdr, json={"track_id": tid, "undo": undo})
    assert r.status_code == 200, r.text
    return r.json()["disliked"]


def test_said_no_to_is_kept_and_taken_back(client, hdr, shelf):
    assert _dislike(client, hdr, shelf[1]) is True
    assert client.get("/recommend/dislikes", headers=hdr).json()["track_ids"] == [shelf[1]]
    assert _dislike(client, hdr, shelf[1], undo=True) is False
    assert client.get("/recommend/dislikes", headers=hdr).json()["track_ids"] == []
    assert client.post("/recommend/dislike", headers=hdr,
                       json={"track_id": 999999}).status_code == 404


def test_never_offered_again_and_it_counts_against_the_artist(client, hdr, shelf):
    a, b, c, *_ = shelf
    _dislike(client, hdr, b)
    keys = [p.key for p in recommend.recommend(_me(), {a: 1.0}, network=False)]
    assert b not in keys and c in keys
    tas = recommend.taste(_me())
    assert tas.artist["nope artist 1"] < 0, "held against its act"
    assert tas.artist_disliked == {"nope artist 1": 1}


def test_a_couple_of_an_acts_and_none_of_theirs_is_offered(client, hdr, shelf):
    a, b, c, d, *_ = shelf
    db.run("update tracks set artists=%s where id = any(%s)", (["Not Again"], [b, c, d]))
    keys = [p.key for p in recommend.recommend(_me(), {a: 1.0}, network=False)]
    assert d in keys
    _dislike(client, hdr, b)
    _dislike(client, hdr, c)
    keys = [p.key for p in recommend.recommend(_me(), {a: 1.0}, network=False)]
    assert d not in keys, "the third of theirs, never said no to, is not offered either"


def test_a_song_said_no_to_seeds_nothing(client, hdr, shelf):
    a, *_ = shelf
    client.post(f"/favourites/{a}", headers=hdr, json={"favourite": True})
    assert a in recommend.taste(_me()).track
    _dislike(client, hdr, a)
    tas = recommend.taste(_me())
    assert a not in tas.track and a not in tas.active


def test_out_of_every_list_and_the_feed_at_once(client, hdr, shelf):
    me = _me()
    a, b, c, *_ = shelf
    discover._save(me, "radar", "Release radar", "", [a, b, c], 20)
    _dislike(client, hdr, b)
    row = db.one("select track_ids from made_lists where user_id=%s and slug='radar'", (me,))
    assert row["track_ids"] == [a, c], "out of the list now, not at the next build"
    discover._save(me, "radar", "Release radar", "", [a, b, c], 20)
    row = db.one("select track_ids from made_lists where user_id=%s and slug='radar'", (me,))
    assert b not in row["track_ids"], "and a list made again leaves it out"
    db.run("update made_lists set track_ids=%s where user_id=%s and slug='radar'",
           ([a, b, c], me))
    cards = client.get("/discover/cards", headers=hdr).json()["items"]
    assert b not in [c_["track"]["id"] for c_ in cards]
