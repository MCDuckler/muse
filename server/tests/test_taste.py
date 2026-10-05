"""What the house knows somebody likes: everything they did, not only what they played."""
from __future__ import annotations

import datetime as dt

import pytest

from muse import auth, brainz, db, elsewhere, recommend, spotify


def _me() -> int:
    return db.one("select id from users where name='chris'")["id"]


@pytest.fixture(autouse=True)
def _no_cache(client):
    """remote_cache has no key to a per-test row; what one test kept, the next would read."""
    db.run("delete from remote_cache")
    yield
    db.run("delete from remote_cache")


@pytest.fixture()
def shelf(client, hdr):
    """Eight songs, all here, each by somebody different, none in chris's library."""
    ids = []
    for n in range(8):
        t = client.post("/tracks/resolve", headers=hdr, json={"video_id": f"TASTE{n}"}).json()
        db.run("update tracks set state='ready', title=%s, artists=%s where id=%s",
               (f"Taste Song {n}", [f"Taste Artist {n}"], t["id"]))
        ids.append(t["id"])
    db.run("delete from library_items")
    return ids


def _listen(user: int, track: int, at: dt.datetime | None = None, *, minutes_ago: float = 60,
            done=True, ms=200_000):
    if at is None:
        db.run("""insert into listens(user_id, track_id, started_at, ms_played, completed)
                  values(%s,%s, now() - %s * interval '1 minute', %s, %s)""",
               (user, track, minutes_ago, ms, done))
    else:
        db.run("""insert into listens(user_id, track_id, started_at, ms_played, completed)
                  values(%s,%s,%s,%s,%s)""", (user, track, at, ms, done))


def _playlist(owner: int, name: str, ids: list[int], *, kind: str = "local",
              remote_id: str | None = None, days_ago: float = 0) -> int:
    p = db.one("insert into playlists(owner_id, name, kind, remote_id) values(%s,%s,%s,%s) "
               "returning id", (owner, name, kind, remote_id))["id"]
    for pos, t in enumerate(ids):
        db.run("""insert into playlist_items(playlist_id, pos, track_id, added_at)
                  values(%s,%s,%s, now() - %s * interval '1 day')""", (p, pos, t, days_ago))
    return p


def _queue(owner: int, name: str) -> int:
    return db.one("insert into queues(user_id, name) values(%s,%s) returning id",
                  (owner, name))["id"]


def test_likes_are_told_from_lists():
    assert recommend.is_likes("liked-songs", "Liked Songs")
    assert recommend.is_likes("chris-poy/likes", "chris-poy · Likes")
    assert recommend.is_likes("einmachtglas/wishlist", "Wishlist")
    assert recommend.is_likes("2831126424", "Lieblingssongs")
    assert not recommend.is_likes("6012971504", "Music lol")
    assert not recommend.is_likes("chris-poy/sets/mechno-techno", "mechno techno")


def test_everything_somebody_did_counts(client, hdr, shelf):
    a, b, c, d, e, f, g, h = shelf
    me = _me()
    _listen(me, a)
    _playlist(me, "Mine", [b])
    _playlist(me, "Liked Songs", [c], kind="spotify", remote_id="liked-songs")
    _playlist(me, "Some list on Spotify", [d], kind="spotify", remote_id="abc")
    other = auth.ensure_user("joe")
    theirs = _playlist(other, "Joe's", [e])
    db.run("insert into playlist_saves(user_id, playlist_id) values(%s,%s)", (me, theirs))
    db.run("""insert into mix_feedback(user_id, event, from_track, to_track)
              values(%s, 'mix', %s, %s)""", (me, a, f))
    db.run("""insert into sleeve_marks(track_id, owner_id, author_id, stroke_id, points)
              values(%s,%s,%s,'s1','{0,0,1,1}')""", (g, me, me))
    q = _queue(me, "jam")
    jam = db.one("insert into jams(code, host_id, queue_id) values('ABCD',%s,%s) returning id",
                 (me, q))["id"]
    db.run("insert into jam_skip_votes(jam_id, track_id, user_id) values(%s,%s,%s)",
           (jam, h, me))

    tas = recommend.taste(me)
    assert tas.heard[a] > 0.9 and a not in tas.liked
    assert tas.track[b] == pytest.approx(recommend.OWN_LIST, abs=0.01) and b in tas.listed
    assert tas.liked[c] == "spotify" and 0 < tas.track[c] <= recommend.LIKED_ELSEWHERE
    assert tas.track[d] == pytest.approx(recommend.MIRRORED) and tas.mirrored[d] == "spotify"
    assert tas.track[e] == pytest.approx(recommend.SAVED)
    assert tas.track[f] == pytest.approx(recommend.BOOTH, abs=0.01)
    assert tas.track[g] == pytest.approx(recommend.TOUCHED)
    assert tas.track[h] == pytest.approx(recommend.JAM_SKIP)
    # What was done here and what was kept from elsewhere, apart.
    assert c not in tas.active and d not in tas.active and b in tas.active
    assert tas.artist_heard == {"taste artist 0": pytest.approx(tas.heard[a])}


def test_acts_kept_by_the_hundred_add_up_slowly_and_follows_count(client, hdr, shelf):
    me = _me()
    # Written straight in: forty asks for a song in a row is told to slow down.
    many = [db.one("""insert into tracks(title, artists, state) values(%s, %s, 'ready')
                      returning id""", (f"Kept {n}", ["Kept Act"]))["id"] for n in range(40)]
    _playlist(me, "Liked Songs", many, kind="spotify", remote_id="liked-songs")
    db.run("""insert into artist_follows(user_id, provider, remote_id, name)
              values(%s, 'deezer', '42', 'Followed Act')""", (me,))
    db.run("insert into genre_follows(user_id, genre) values(%s, 'ambient')", (me,))
    tas = recommend.taste(me)
    kept = sum(tas.track[t] for t in many)
    assert tas.artist["kept act"] == pytest.approx(recommend.PASSIVE_SCALE * __import__("math").log1p(kept))
    assert tas.artist["kept act"] < kept / 2
    assert tas.artist["followed act"] == recommend.FOLLOWED and "followed act" in tas.followed
    assert tas.genres == {"ambient": 1.0}


def test_a_newer_like_counts_for_more_than_one_from_years_ago(client, hdr, shelf):
    me = _me()
    _playlist(me, "Liked Songs", shelf, kind="spotify", remote_id="liked-songs")
    tas = recommend.taste(me)
    assert tas.track[shelf[0]] > tas.track[shelf[-1]] > 0


def test_night_is_on_the_persons_clock(client, hdr, shelf):
    a, b, c, *_ = shelf
    me = _me()
    db.run("update users set utc_offset_min = 120 where id = %s", (me,))
    yesterday = (dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=1)).replace(
        minute=0, second=0, microsecond=0)
    _listen(me, a, yesterday.replace(hour=21))   # 23:00 on their clock: night
    _listen(me, b, yesterday.replace(hour=12))   # 14:00: day
    _listen(me, c, yesterday.replace(hour=22), done=False, ms=5_000)   # skipped at midnight
    tas = recommend.taste(me)
    assert tas.night[a] > 0.9
    assert b not in tas.night
    assert tas.night[c] < 0
    db.run("update users set utc_offset_min = -600 where id = %s", (me,))
    assert a not in recommend.taste(me).night       # 11:00 in Hawaii


def test_the_mix_seeds_take_in_what_was_done_lately(client, hdr, shelf):
    a, b, c, d, e, *_ = shelf
    me = _me()
    for t in (a, b, c):
        _listen(me, t)
    fav = db.one("select id from playlists where owner_id=%s and kind='favourites'", (me,))
    fav = fav["id"] if fav else _playlist(me, "Favourites", [], kind="favourites")
    db.run("insert into playlist_items(playlist_id, pos, track_id) values(%s, 0, %s)", (fav, d))
    q = _queue(me, "station")
    db.run("""insert into stations(queue_id, owner_id, kind, seed_track, name)
              values(%s,%s,'track',%s,'e radio')""", (q, me, e))
    seeds = recommend.seeds_of_person(me, most=6)
    assert {a, b, c} <= set(seeds) and d in seeds
    assert seeds[d] == 0.9 and len(seeds) <= 6
    # Not more than a third of them, while there is listening to go on.
    assert len(recommend.seeds_of_person(me, most=3)) == 3
    assert {a, b} & set(recommend.seeds_of_person(me, most=3))


def test_an_answer_says_where_somebody_liked_it_and_whom_they_follow(client, hdr, shelf):
    a, b, c, *_ = shelf
    me = _me()
    other = auth.ensure_user("joe")
    _playlist(other, "Their list", [a, b, c])
    _playlist(me, "Liked Songs", [b], kind="spotify", remote_id="liked-songs")
    db.run("""insert into artist_follows(user_id, provider, remote_id, name)
              values(%s, 'deezer', '7', 'Taste Artist 2')""", (me,))
    picks = {p.key: p for p in recommend.recommend(me, {a: 1.0}, limit=5, network=False)}
    assert "you liked it on Spotify" in picks[b].why
    assert "you follow Taste Artist 2" in picks[c].why
    assert picks[b].lead == "lists"


def test_a_followed_genre_lifts_what_is_filed_under_it(client, hdr, shelf):
    a, b, c, *_ = shelf
    me = _me()
    other = auth.ensure_user("joe")
    _playlist(other, "Their list", [a, b, c])
    plain = {p.key: p.score for p in recommend.recommend(me, {a: 1.0}, limit=5, network=False)}
    brainz._store("mb:artist:taste artist 2",
                  {"mbid": "x", "name": "Taste Artist 2", "genres": ["ambient", "drone"]})
    db.run("insert into genre_follows(user_id, genre) values(%s, 'ambient')", (me,))
    picks = {p.key: p for p in recommend.recommend(me, {a: 1.0}, limit=5, network=False)}
    assert picks[c].score > plain[c] and picks[b].score == pytest.approx(plain[b], abs=1e-6)
    assert "ambient, which you follow" in picks[c].why


def test_what_spotify_and_listenbrainz_know_is_kept_and_read(client, hdr, shelf, monkeypatch):
    a, b, *_ = shelf
    me = _me()
    db.run("""insert into provider_accounts(user_id, provider, access_token, refresh_token, expires_at)
              values(%s, 'spotify', 'x', 'y', now() + interval '1 hour')""", (me,))
    db.run("update users set listenbrainz_name = 'chrislb' where id = %s", (me,))
    db.run("""insert into matches(remote_kind, remote_id, track_id, confidence, method, decided_by)
              values('spotify', 'sp-a', %s, 1, 'isrc', 'auto')""", (a,))
    monkeypatch.setattr(elsewhere, "_cfg", lambda: object())
    asked = []

    def fake_get(cfg, user_id, url, **params):
        asked.append((url, params.get("time_range")))
        if url == "/me/top/artists":
            return {"items": [{"name": "Far Away Act", "genres": ["ambient", "drone"]},
                              {"name": "Second Act", "genres": ["ambient"]}]}
        if url == "/me/top/tracks":
            return {"items": [{"id": "sp-a", "name": "whatever", "artists": [{"name": "?"}]}]}
        raise spotify.NotAllowed("no scope for that")      # recently played: an old link

    monkeypatch.setattr(spotify, "_get", fake_get)

    def fake_lb(name, what, span):
        assert name == "chrislb"
        if what == "artists":
            return [{"artist_name": "Diary Act", "listen_count": 40}]
        return [{"track_name": "Taste Song 1", "artist_name": "Taste Artist 1"}]

    monkeypatch.setattr(elsewhere, "_lb", fake_lb)
    got = elsewhere.refresh(me)
    assert set(got["from"]) == {"spotify", "listenbrainz"}
    assert got["artists"]["far away act"] > got["artists"]["second act"] > 0
    assert a in got["tracks"] and b in got["tracks"]
    assert elsewhere.lately(me).get(b) and a in elsewhere.lately(me)   # short term + month
    # Kept a day: asked once.
    n = len(asked)
    elsewhere.refresh(me)
    assert len(asked) == n
    tas = recommend.taste(me)
    assert tas.artist["far away act"] > 0 and "far away act" in tas.elsewhere
    assert tas.active[a] > 0 and tas.genres.get("ambient") == 0.5


def test_a_service_that_cannot_be_asked_keeps_what_it_said_before(client, hdr, shelf, monkeypatch):
    me = _me()
    db.run("update users set listenbrainz_name = 'chrislb' where id = %s", (me,))
    monkeypatch.setattr(elsewhere, "_lb", lambda name, what, span:
                        [{"artist_name": "Diary Act"}] if what == "artists" else [])
    elsewhere.refresh(me)

    def down(name, what, span):
        raise RuntimeError("502")

    monkeypatch.setattr(elsewhere, "_lb", down)
    elsewhere.refresh(me, force=True)
    assert "diary act" in elsewhere.known(me)["artists"]


def test_an_act_with_nothing_here_is_not_one_to_start_a_station_from(client, hdr, shelf):
    from muse import discover
    a, *_ = shelf
    me = _me()
    _listen(me, a)
    db.run("""insert into artist_follows(user_id, provider, remote_id, name)
              values(%s, 'deezer', '9', 'Nowhere Act')""", (me,))
    tas = recommend.taste(me)
    assert "nowhere act" in tas.artist
    names = [x["name"] for x in discover.station_starters(me, tas)["artists"]]
    assert names == ["Taste Artist 0"]
