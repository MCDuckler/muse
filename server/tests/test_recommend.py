"""What goes with what: one engine behind stations, playlists, the crate and the cover."""
from __future__ import annotations

import pytest

from muse import auth, db, recommend, ytm


def _me() -> int:
    return db.one("select id from users where name='chris'")["id"]


@pytest.fixture()
def shelf(client, hdr):
    """Eight songs in the library, all here, each by somebody different."""
    ids = []
    for n in range(8):
        t = client.post("/tracks/resolve", headers=hdr, json={"video_id": f"SHELF{n}"}).json()
        db.run("update tracks set state='ready', title=%s, artists=%s where id=%s",
               (f"Shelf Song {n}", [f"Shelf Artist {n}"], t["id"]))
        ids.append(t["id"])
    return ids


def _listen(user: int, track: int, minutes_ago: float, *, done=True, ms=200_000):
    db.run("""insert into listens(user_id, track_id, started_at, ms_played, completed)
              values(%s,%s, now() - %s * interval '1 minute', %s, %s)""",
           (user, track, minutes_ago, ms, done))


def _list(client, hdr, name, ids):
    p = client.post("/playlists", headers=hdr, json={"name": name}).json()
    client.post(f"/playlists/{p['id']}/items", headers=hdr, json={"track_ids": ids})
    return p["id"]


def test_songs_that_share_hand_made_lists_go_together(client, hdr, shelf):
    a, b, c, *_ = shelf
    _list(client, hdr, "one", [a, b])
    _list(client, hdr, "two", [a, b, c])
    picks = recommend.recommend(_me(), {a: 1.0}, limit=5, network=False)
    keys = [p.key for p in picks]
    assert keys[:2] == [b, c], "twice together beats once"
    assert picks[0].where == "library"
    assert "on lists with" in picks[0].why


def test_a_mirrored_library_says_nothing_about_what_goes_with_what(client, hdr, shelf,
                                                                   monkeypatch):
    a, b, *_ = shelf
    monkeypatch.setattr(recommend, "LIST_MOST", 1)
    _list(client, hdr, "everything", [a, b])
    picks = recommend.recommend(_me(), {a: 1.0}, network=False)
    assert b not in [p.key for p in picks]


def test_what_was_played_around_a_song_goes_with_it_but_not_what_was_skipped(client, shelf):
    a, b, c, d, *_ = shelf
    me = _me()
    _listen(me, a, 30)
    _listen(me, b, 26)
    _listen(me, c, 22, done=False, ms=5_000)     # skipped: says nothing
    _listen(me, d, 60 * 24 * 3)                   # another day entirely
    keys = [p.key for p in recommend.recommend(me, {a: 1.0}, network=False)]
    assert keys and keys[0] == b
    assert c not in keys and d not in keys


def test_youtube_music_is_asked_once_a_week_and_what_it_said_is_kept(client, hdr, shelf,
                                                                     monkeypatch):
    asked = []

    def radio(video, limit=25):
        asked.append(video)
        return [{"video_id": f"NEW{n}", "title": f"New Song {n}", "artists": [f"New Act {n}"],
                 "album": None, "duration_ms": 200_000, "raw": {"thumbnails": []}}
                for n in range(6)]
    monkeypatch.setattr(ytm, "watch_playlist", radio)
    first = recommend.recommend(_me(), {shelf[0]: 1.0}, only="new")
    again = recommend.recommend(_me(), {shelf[0]: 1.0}, only="new")
    assert asked == ["SHELF0"], "the second look is answered from the disk"
    assert [p.key for p in first] == [p.key for p in again]
    assert first[0].key == "v:NEW0", "YouTube Music's own order, best first"
    assert first[0].where == "new" and "plays it after" in first[0].why
    shown = recommend.public(first[0])
    assert shown["hit"]["video_id"] == "NEW0" and shown["hit"]["title"] == "New Song 0"


def test_a_song_the_house_has_under_another_id_is_offered_as_that(client, hdr, shelf,
                                                                  monkeypatch):
    monkeypatch.setattr(ytm, "watch_playlist", lambda v, limit=25: [
        {"video_id": "OTHERUPLOAD", "title": "Shelf Song 3", "artists": ["Shelf Artist 3"],
         "album": None, "duration_ms": 200_000, "raw": {}}])
    picks = recommend.recommend(_me(), {shelf[0]: 1.0})
    assert [p.key for p in picks][:1] == [shelf[3]]


def test_what_somebody_else_fetched_is_offered_as_the_house(client, hdr, shelf, monkeypatch):
    theirs = client.post("/tracks/resolve", headers=hdr, json={"video_id": "THEIRS"}).json()
    db.run("update tracks set state='ready', title='Their Song', artists=%s where id=%s",
           (["Their Act"], theirs["id"]))
    db.run("delete from library_items where track_id=%s", (theirs["id"],))
    monkeypatch.setattr(ytm, "watch_playlist", lambda v, limit=25: [
        {"video_id": "THEIRS", "title": "Their Song", "artists": ["Their Act"],
         "album": None, "duration_ms": 200_000, "raw": {}}])
    picks = recommend.recommend(_me(), {shelf[0]: 1.0}, only="new")
    assert picks and picks[0].key == theirs["id"] and picks[0].where == "house"
    # And an app from before /recommend is still offered it, by its YouTube Music id.
    old = client.get("/search/similar", headers=hdr,
                     params={"tracks": str(shelf[0])}).json()["similar"]
    assert old[0]["video_id"] == "THEIRS" and old[0]["known"] is True


def test_waved_away_is_never_offered_again(client, hdr, shelf):
    a, b, c, *_ = shelf
    _list(client, hdr, "one", [a, b, c])
    assert client.post("/recommend/dismiss", headers=hdr,
                       json={"track_id": b}).status_code == 200
    keys = [p.key for p in recommend.recommend(_me(), {a: 1.0}, network=False)]
    assert b not in keys and c in keys


def test_what_was_just_played_waits_and_what_is_hearted_rises(client, hdr, shelf):
    a, b, c, d, *_ = shelf
    _list(client, hdr, "one", [a, b, c, d])
    me = _me()
    _listen(me, b, 10)                     # just heard
    client.post(f"/favourites/{d}", headers=hdr, json={"favourite": True})
    keys = [p.key for p in recommend.recommend(me, {a: 1.0}, network=False)]
    assert keys[0] == d
    assert keys[-1] == b


def test_no_more_than_two_by_anybody(client, hdr, shelf):
    db.run("update tracks set artists=%s where id = any(%s)", (["Prolific"], shelf[1:]))
    _list(client, hdr, "one", shelf)
    picks = recommend.recommend(_me(), {shelf[0]: 1.0}, limit=8, network=False)
    assert len(picks) == 2


def test_fresh_shares_the_answer_between_yours_and_new(client, hdr, shelf, monkeypatch):
    monkeypatch.setattr(ytm, "watch_playlist", lambda v, limit=25: [
        {"video_id": f"FRESH{n}", "title": f"Fresh {n}", "artists": [f"Fresh Act {n}"],
         "album": None, "duration_ms": 200_000, "raw": {}} for n in range(10)])
    _list(client, hdr, "one", shelf)
    me = _me()
    half = recommend.recommend(me, {shelf[0]: 1.0}, limit=6, fresh=0.5)
    assert sum(p.where == "new" for p in half) == 3
    mine = recommend.recommend(me, {shelf[0]: 1.0}, limit=6, fresh=0.0)
    assert all(p.where == "library" for p in mine)
    new = recommend.recommend(me, {shelf[0]: 1.0}, limit=6, only="new")
    assert all(p.where == "new" for p in new) and len(new) == 6


def test_the_endpoint_answers_for_a_playlist_leaving_out_what_is_in_it(client, hdr, shelf):
    a, b, c, *_ = shelf
    pid = _list(client, hdr, "mine", [a, b])
    _list(client, hdr, "other", [a, b, c])
    r = client.get("/recommend", headers=hdr, params={"playlist": pid, "fresh": 0})
    assert r.status_code == 200, r.text
    items = r.json()["items"]
    assert items[0]["track"]["id"] == c and items[0]["where"] == "library"
    assert all(i["track"]["id"] not in (a, b) for i in items if "track" in i)
    # The old question under a playlist is the same answer, from the library.
    old = client.get(f"/playlists/{pid}/suggested", headers=hdr).json()["items"]
    assert old[0]["id"] == c


def test_the_cover_has_a_mix_and_songs_loved_then_left(client, hdr, shelf):
    a, b, c, d, *_ = shelf
    me = _me()
    _list(client, hdr, "one", [a, b])
    # A list made long ago: put on one this month, b would be a seed of the mix itself.
    db.run("update playlist_items set added_at = now() - interval '60 days'")
    _listen(me, a, 60)
    for n in range(3):
        _listen(me, d, 60 * 24 * (90 + n))
    got = client.get("/recommend/home", headers=hdr).json()["sections"]
    by = {s["id"]: s for s in got}
    assert by["mix"]["items"][0]["track"]["id"] == b
    assert [i["track"]["id"] for i in by["again"]["items"]] == [d]


def test_a_station_leans_towards_what_was_listened_through_and_away_from_skips(
        client, hdr, shelf):
    a, b, c, d, e, f, g, h = shelf
    # b goes with e, c goes with f: two directions the station could take.
    _list(client, hdr, "be", [b, e])
    _list(client, hdr, "cf", [c, f])
    _list(client, hdr, "seed", [a, b, c])
    made = client.post("/stations", headers=hdr,
                       json={"kind": "track", "track_id": a, "fresh": 0}).json()
    have = [i["id"] for i in made["items"]]
    assert have[0] == a and b in have and c in have
    assert made["station"]["fresh"] == 0
    db.run("update stations set created_at = now() - interval '1 hour'")
    me = _me()
    _listen(me, b, 1)                              # heard through
    _listen(me, c, 0.5, done=False, ms=4_000)      # skipped at once
    grown = client.post(f"/stations/{made['id']}/extend", headers=hdr,
                        json={"count": 1}).json()
    assert grown["items"][-1]["id"] == e


def test_a_station_can_be_turned_towards_new_songs(client, hdr, shelf):
    made = client.post("/stations", headers=hdr,
                       json={"kind": "track", "track_id": shelf[0]}).json()
    tuned = client.patch(f"/stations/{made['id']}", headers=hdr, json={"fresh": 1})
    assert tuned.status_code == 200, tuned.text
    assert tuned.json()["station"]["fresh"] == 1


def test_a_station_puts_what_is_here_before_what_is_coming(client, hdr, shelf):
    _list(client, hdr, "one", shelf)
    made = client.post("/stations", headers=hdr,
                       json={"kind": "track", "track_id": shelf[0], "fresh": 0.5}).json()
    after = made["items"][1:]
    assert after[0]["state"] == "ready" and after[1]["state"] == "ready"
    assert any(i["state"] != "ready" for i in after), "and some of it new"


def test_someone_elses_listening_counts_for_the_house_not_their_taste(client, hdr, shelf):
    a, b, *_ = shelf
    other = auth.ensure_user("joe", pw_hash=auth.hash_password("x"))
    other_id = other["id"] if isinstance(other, dict) else db.one(
        "select id from users where name='joe'")["id"]
    _listen(other_id, a, 30)
    _listen(other_id, b, 27)
    keys = [p.key for p in recommend.recommend(_me(), {a: 1.0}, network=False)]
    assert keys[:1] == [b]
    assert recommend.taste(_me()).track == {}
