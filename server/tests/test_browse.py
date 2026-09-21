"""Browsing the library. Albums and artists are derived from track metadata, so the
edge cases are about grouping, not storage."""
from __future__ import annotations

import pytest

from muse import db


@pytest.fixture()
def library(client, hdr, wsec, complete_job):
    """A small library with shared albums, shared names and a featured artist."""
    made = []
    for n, (title, artists, album, year) in enumerate([
        ("Alpha", ["Bowie"], "Low", 1977),
        ("Beta", ["Bowie"], "Low", 1977),
        ("Gamma", ["Bowie", "Eno"], "Heroes", 1977),
        ("Delta", ["Other Band"], "Low", 2001),          # same album name, different act
        ("Epsilon", ["Eno"], None, None),                # no album at all
    ]):
        t = client.post("/tracks/resolve", headers=hdr,
                        json={"video_id": f"VID{n}"}).json()
        job = client.post("/internal/jobs/lease", headers=wsec,
                          json={"worker": "w"}).json()["jobs"][0]
        complete_job(job["id"], t["id"])
        db.run(
            "update tracks set title=%s, artists=%s, album=%s, release_year=%s where id=%s",
            (title, artists, album, year, t["id"]),
        )
        made.append(t["id"])
    return made


def test_all_tracks_can_finally_be_listed(client, hdr, library):
    r = client.get("/library/tracks", headers=hdr).json()
    assert r["total"] >= 5
    titles = [t["title"] for t in r["items"]]
    assert "Alpha" in titles and "Epsilon" in titles


@pytest.mark.parametrize("sort,first_key", [
    ("title", lambda t: t["title"]),
    ("artist", lambda t: (t["artists"] or [""])[0]),
    ("album", lambda t: t["album"] or ""),
])
def test_sorting(client, hdr, library, sort, first_key):
    items = client.get("/library/tracks", headers=hdr,
                       params={"sort": sort}).json()["items"]
    keys = [first_key(t).lower() for t in items]
    assert keys == sorted(keys), f"{sort} is not ordered"


def test_an_unknown_sort_is_refused_rather_than_ignored(client, hdr):
    assert client.get("/library/tracks", headers=hdr,
                      params={"sort": "vibes"}).status_code == 400


def test_albums_group_by_album_and_artist(client, hdr, library):
    """Two records can share a title; merging them would be a worse lie than two rows."""
    albums = client.get("/library/albums", headers=hdr).json()["items"]
    lows = [a for a in albums if a["name"] == "Low"]
    assert len(lows) == 2, "same album name, different artists, two entries"
    bowie_low = next(a for a in lows if a["artist"] == "Bowie")
    assert bowie_low["tracks"] == 2 and bowie_low["year"] == 1977

    # A track with no album is not an album called "None".
    assert all(a["name"] for a in albums)


def test_album_tracks_can_be_narrowed_by_artist(client, hdr, library):
    both = client.get("/library/albums/tracks", headers=hdr,
                      params={"album": "Low"}).json()["items"]
    just_bowie = client.get("/library/albums/tracks", headers=hdr,
                            params={"album": "Low", "artist": "Bowie"}).json()["items"]
    assert len(both) == 3 and len(just_bowie) == 2


def test_artists_count_every_credit_not_just_the_first(client, hdr, library):
    """A feature is still an appearance: Eno is credited on Gamma and Epsilon."""
    artists = {a["name"]: a for a in client.get("/library/artists", headers=hdr).json()["items"]}
    assert artists["Bowie"]["tracks"] == 3
    assert artists["Eno"]["tracks"] == 2
    assert artists["Bowie"]["albums"] == 2


def test_artist_tracks_include_features(client, hdr, library):
    items = client.get("/library/artists/tracks", headers=hdr,
                       params={"artist": "Eno"}).json()["items"]
    assert {t["title"] for t in items} == {"Gamma", "Epsilon"}


def test_one_artist_however_the_name_was_typed(client, hdr, library, wsec,
                                               complete_job):
    """The same act arrives spelled several ways, because each song's credit comes
    from whoever uploaded it: "BICEP" and "Bicep", "S.P.Y" and "S.PY", a name with two
    invisible characters welded to the end. Three rows with a third of the records
    each is an artist page missing most of their music."""
    for n, artist in enumerate(["BICEP", "Bicep", "bicep\u2060"]):
        t = client.post("/tracks/resolve", headers=hdr,
                        json={"video_id": f"SPELL{n}"}).json()
        job = client.post("/internal/jobs/lease", headers=wsec,
                          json={"worker": "w"}).json()["jobs"][0]
        complete_job(job["id"], t["id"])
        db.run("update tracks set title=%s, artists=%s where id=%s",
               (f"Spelled {n}", [artist], t["id"]))

    listed = client.get("/library/artists", headers=hdr).json()
    rows = [a for a in listed["items"] if a["name"].lower().startswith("bicep")]
    assert len(rows) == 1, rows
    assert rows[0]["tracks"] == 3
    # Shown the way most of the library spells it, not flattened into a key.
    assert rows[0]["name"] in ("BICEP", "Bicep")

    # And the page collects all three, whichever spelling was asked for.
    for asked in ("BICEP", "bicep", "Bicep\u2060"):
        items = client.get("/library/artists/tracks", headers=hdr,
                           params={"artist": asked}).json()["items"]
        assert len(items) == 3, asked


def test_a_long_list_says_how_much_more_there_is(client, hdr, library):
    """Without a total the app asks once, draws two hundred of ten thousand records
    and has no way of telling that was not all of them."""
    artists = client.get("/library/artists", headers=hdr,
                         params={"limit": 1, "offset": 0}).json()
    assert len(artists["items"]) == 1
    assert artists["total"] >= 3
    assert artists["offset"] == 0

    albums = client.get("/library/albums", headers=hdr, params={"limit": 1}).json()
    assert len(albums["items"]) == 1
    assert albums["total"] >= 3

    # And a second page carries on rather than repeating the first.
    first = client.get("/library/artists", headers=hdr,
                       params={"limit": 1, "offset": 0}).json()["items"][0]["name"]
    second = client.get("/library/artists", headers=hdr,
                        params={"limit": 1, "offset": 1}).json()["items"][0]["name"]
    assert first != second


def test_a_long_list_can_be_narrowed(client, hdr, library):
    """Ten thousand records cannot be scrolled through, so they can be searched."""
    albums = client.get("/library/albums", headers=hdr,
                        params={"q": "low"}).json()
    assert {a["name"] for a in albums["items"]} == {"Low"}
    assert albums["total"] == 2, "two records share that title, by different acts"

    # The artist's name works as well as the record's.
    by_artist = client.get("/library/albums", headers=hdr,
                           params={"q": "other band"}).json()["items"]
    assert [a["artist"] for a in by_artist] == ["Other Band"]

    # And an artist is found however either side of it is spelled.
    artists = client.get("/library/artists", headers=hdr,
                         params={"q": "bow ie"}).json()
    assert [a["name"] for a in artists["items"]] == ["Bowie"]
    assert artists["total"] == 1

    assert client.get("/library/artists", headers=hdr,
                      params={"q": "nobody"}).json()["items"] == []


def test_lists_can_be_ordered_by_something_other_than_the_alphabet(
        client, hdr, library):
    most = client.get("/library/artists", headers=hdr,
                      params={"sort": "tracks"}).json()["items"]
    assert most[0]["name"] == "Bowie", "three tracks beats two"

    records = client.get("/library/albums", headers=hdr,
                         params={"sort": "tracks"}).json()["items"]
    assert records[0]["tracks"] >= records[-1]["tracks"]

    assert client.get("/library/albums", headers=hdr,
                      params={"sort": "sideways"}).status_code == 400


def test_what_was_played_counted_over_a_stretch_of_time(client, hdr, library):
    """One row per listen has been written down since the first day and the only
    question anybody could ask of it was "what did I play recently"."""
    for _ in range(3):
        client.post("/listens", headers=hdr,
                    json={"track_id": library[0], "ms_played": 200_000,
                          "completed": True})
    client.post("/listens", headers=hdr,
                json={"track_id": library[2], "ms_played": 30_000, "completed": True})
    # Started and abandoned: it happened, but it is not a play.
    client.post("/listens", headers=hdr,
                json={"track_id": library[3], "ms_played": 4_000, "completed": False})

    stats = client.get("/library/stats", headers=hdr, params={"since": "month"}).json()
    assert stats["totals"]["plays"] == 4
    assert stats["totals"]["started"] == 5
    assert stats["totals"]["minutes"] == 11        # 3×200s + 30s + 4s
    assert stats["totals"]["tracks"] == 3

    top = stats["songs"][0]
    assert top["title"] == "Alpha" and top["plays"] == 3
    assert [a["name"] for a in stats["artists"]][0] == "Bowie"
    assert stats["albums"][0]["name"] == "Low"
    assert stats["step"] == "day" and len(stats["shape"]) == 1
    # Who this is about, and who else could be asked.
    assert stats["who"]["name"] == "chris"
    assert "chris" in [p["name"] for p in stats["people"]]


def test_stats_can_be_asked_about_a_stretch_or_about_somebody_else(client, hdr,
                                                                   library):
    client.post("/listens", headers=hdr,
                json={"track_id": library[0], "ms_played": 200_000,
                      "completed": True})
    year = client.get("/library/stats", headers=hdr, params={"since": "year"}).json()
    assert year["totals"]["plays"] == 1
    assert year["step"] == "month", "a year is drawn by month, not by day"

    # Somebody else on the same box, who has played nothing.
    from muse import auth
    other_id = auth.ensure_user("joe", pw_hash=auth.hash_password("x"))
    theirs = client.get("/library/stats", headers=hdr,
                        params={"who": other_id}).json()
    assert theirs["who"]["name"] == "joe"
    assert theirs["totals"]["plays"] == 0 and theirs["songs"] == []

    assert client.get("/library/stats", headers=hdr,
                      params={"since": "decade"}).status_code == 400
    assert client.get("/library/stats", headers=hdr,
                      params={"who": 9999}).status_code == 404


def test_the_charts_know_where_a_song_was_last_week(client, hdr, library):
    """A chart is only a chart if it moves: this week's place against last week's, a
    new entry when a song was not on last week's at all, and how many weeks it has
    been on one."""
    alpha, beta, gamma = library[0], library[1], library[2]

    def play(track, times, days_ago):
        for _ in range(times):
            client.post("/listens", headers=hdr,
                        json={"track_id": track, "ms_played": 200_000,
                              "completed": True})
        db.run("""update listens set started_at = now() - make_interval(days => %s)
                   where track_id = %s and started_at > now() - interval '1 minute'""",
               (days_ago, track))

    # Last week: beta at the top, gamma second. Three weeks ago: beta again.
    play(beta, 5, 9)
    play(gamma, 3, 10)
    play(beta, 2, 22)
    # This week: alpha arrives, beta holds on below it, gamma is gone.
    play(alpha, 4, 1)
    play(beta, 2, 2)

    chart = client.get("/library/stats", headers=hdr, params={"since": "week"}).json()
    songs = {s["id"]: s for s in chart["songs"]}

    assert [s["id"] for s in chart["songs"]] == [alpha, beta]
    assert songs[alpha]["rank"] == 1
    assert songs[alpha]["last_rank"] is None, "not on last week's chart: a new entry"
    assert songs[alpha]["charts"] == 1
    assert songs[beta]["rank"] == 2 and songs[beta]["last_rank"] == 1, "down one"
    assert songs[beta]["charts"] == 3, "this week, last week and three weeks ago"

    # Everything-ever has no last week to compare with.
    ever = client.get("/library/stats", headers=hdr, params={"since": "all"}).json()
    assert all(s["last_rank"] is None and s["charts"] == 0 for s in ever["songs"])


def test_lists_that_fill_themselves_in(client, hdr, library):
    """Questions about the library, answered when asked: never played, most played,
    not heard in a while. Only songs that can actually play."""
    alpha, beta, gamma = library[0], library[1], library[2]
    db.run("update tracks set state='ready' where id = any(%s)", ([alpha, beta, gamma],))

    def play(track, times, days_ago=0):
        for _ in range(times):
            client.post("/listens", headers=hdr,
                        json={"track_id": track, "ms_played": 200_000, "completed": True})
        db.run("""update listens set started_at = now() - make_interval(days => %s)
                   where track_id = %s and started_at > now() - interval '1 minute'""",
               (days_ago, track))

    play(alpha, 3)               # played lately
    play(beta, 2, days_ago=60)   # played, and then left alone

    lists = {l["id"]: l for l in
             client.get("/library/smart", headers=hdr).json()["lists"]}
    assert lists["most"]["count"] == 2
    assert lists["forgotten"]["count"] == 1
    assert lists["never"]["count"] >= 1

    def ids(kind):
        return [t["id"] for t in
                client.get(f"/library/smart/{kind}", headers=hdr).json()["items"]]

    assert ids("most")[:2] == [alpha, beta]
    assert ids("forgotten") == [beta]
    assert gamma in ids("never") and alpha not in ids("never")

    # A song that still needs fetching is not offered as something to put on.
    db.run("update tracks set state='pending' where id=%s", (gamma,))
    assert gamma not in ids("never")

    assert client.get("/library/smart/nonsense", headers=hdr).status_code == 404


def test_taking_a_record_with_you(client, hdr, library, monkeypatch):
    """Most of this library has never been downloaded, because a mirrored collection
    records the list and leaves the files until something is played. A playlist could
    ask for all of it; a record could not."""
    from muse import jobs

    asked = []
    monkeypatch.setattr(jobs, "queue",
                        lambda tid, **kw: asked.append(tid) or True)
    db.run("update tracks set state='pending' where album='Low'")

    out = client.post("/library/fetch", headers=hdr,
                      json={"album": "Low", "artist": "Bowie"}).json()
    assert out["queued"] == 2, 'the two Bowie songs on it, not the other act\'s'
    assert len(asked) == 2
    assert out["about_mb"] >= 0

    # Twice is not twice the queue: the second press finds them already on their way.
    db.run("""insert into jobs(kind,payload,state)
              select 'ingest', jsonb_build_object('track_id', id), 'pending'
                from tracks where album='Low' and %s""", (True,))
    asked.clear()
    again = client.post("/library/fetch", headers=hdr,
                        json={"album": "Low", "artist": "Bowie"}).json()
    assert again["queued"] == 0 and asked == []


def test_fetching_an_artist_or_a_handful_of_rows(client, hdr, library, monkeypatch):
    from muse import jobs

    asked = []
    monkeypatch.setattr(jobs, "queue", lambda tid, **kw: asked.append(tid) or True)
    db.run("update tracks set state='pending'")

    by_artist = client.post("/library/fetch", headers=hdr,
                            json={"artist": "eno"}).json()
    assert by_artist["queued"] == 2, 'a feature is still an appearance'

    asked.clear()
    picked = client.post("/library/fetch", headers=hdr,
                         json={"track_ids": [library[0]]}).json()
    assert picked["queued"] == 1 and asked == [library[0]]

    assert client.post("/library/fetch", headers=hdr, json={}).status_code == 400


def test_history_carries_timestamps_and_can_be_cleared(client, hdr, library):
    client.post("/listens", headers=hdr,
                json={"track_id": library[0], "ms_played": 30_000, "completed": True})
    hist = client.get("/library/history", headers=hdr).json()["items"]
    assert hist and hist[0]["played_at"], "a history with no when is not a history"
    assert hist[0]["ms_played"] == 30_000

    client.delete("/library/history", headers=hdr)
    assert client.get("/library/history", headers=hdr).json()["items"] == []


# ---------------- playlists ----------------
def test_a_playlist_can_be_renamed(client, hdr):
    p = client.post("/playlists", headers=hdr, json={"name": "Untitled"}).json()
    renamed = client.patch(f"/playlists/{p['id']}", headers=hdr,
                           json={"name": "Sunday"}).json()
    assert renamed["name"] == "Sunday"
    assert client.patch(f"/playlists/{p['id']}", headers=hdr,
                        json={"name": "  "}).status_code == 400


def test_a_playlist_can_be_reordered(client, hdr, library):
    p = client.post("/playlists", headers=hdr, json={"name": "Mix"}).json()
    client.post(f"/playlists/{p['id']}/items", headers=hdr,
                json={"track_ids": library[:3]})
    moved = client.post(f"/playlists/{p['id']}/move", headers=hdr,
                        json={"from": 0, "to": 2}).json()
    assert [i["id"] for i in moved["items"]] == [library[1], library[2], library[0]]
    assert [i["pos"] for i in moved["items"]] == [0, 1, 2]
    assert client.post(f"/playlists/{p['id']}/move", headers=hdr,
                       json={"from": 0, "to": 9}).status_code == 400


# ---------------- mirrored playlists ----------------
@pytest.fixture()
def mirrored(client, hdr, library):
    """A playlist that mirrors Spotify, made directly: linking a real account needs an
    app registration, and the rules below hold regardless of how the row got there."""
    pid = db.one(
        """insert into playlists(owner_id, name, kind, remote_id, sync_mode, source_name)
           values((select id from users limit 1), 'From Spotify', 'spotify', 'SP1',
                  'pull', 'someone') returning id"""
    )["id"]
    db.run("insert into playlist_items(playlist_id,pos,track_id) values(%s,0,%s)",
           (pid, library[0]))
    db.run("""insert into playlist_unmatched(playlist_id,pos,remote_id,title,artists,reason)
              values(%s,1,'sp-x','Missing Song',%s,'Nothing on YouTube Music matched this song')""",
           (pid, ["Someone"]))
    return pid


def test_a_mirrored_playlist_is_listed_with_its_source(client, hdr, mirrored):
    rows = client.get("/playlists", headers=hdr).json()
    mine = next(r for r in rows if r["id"] == mirrored)
    assert mine["kind"] == "spotify"
    assert mine["source_name"] == "someone"
    assert mine["unmatched"] == 1, "the app must be able to say what is missing"


def test_a_mirrored_playlist_is_playable_but_not_editable(client, hdr, mirrored,
                                                          library):
    full = client.get(f"/playlists/{mirrored}", headers=hdr).json()
    assert full["editable"] is False
    assert len(full["items"]) == 1, "what did match is there to play"

    # every edit route refuses, and says what to do instead
    assert client.post(f"/playlists/{mirrored}/items", headers=hdr,
                       json={"track_ids": [library[1]]}).status_code == 409
    assert client.patch(f"/playlists/{mirrored}", headers=hdr,
                        json={"name": "Mine now"}).status_code == 409
    assert client.delete(f"/playlists/{mirrored}/items/0", headers=hdr).status_code == 409
    r = client.post(f"/playlists/{mirrored}/move", headers=hdr,
                    json={"from": 0, "to": 0})
    assert r.status_code == 409 and "copy" in r.json()["detail"].lower()


def test_the_songs_that_could_not_be_translated_are_listed(client, hdr, mirrored):
    items = client.get(f"/spotify/playlists/{mirrored}/unmatched",
                       headers=hdr).json()["items"]
    assert len(items) == 1
    assert items[0]["title"] == "Missing Song"
    assert "matched" in items[0]["reason"], "a reason in words, not a score"


def test_cloning_makes_an_ordinary_editable_playlist(client, hdr, mirrored, library):
    copy = client.post(f"/spotify/playlists/{mirrored}/clone", headers=hdr,
                       json={"name": "My version"}).json()
    assert copy["kind"] == "local" and copy["name"] == "My version"
    assert [i["id"] for i in copy["items"]] == [library[0]]

    # and the copy really is editable
    assert client.post(f"/playlists/{copy['id']}/items", headers=hdr,
                       json={"track_ids": [library[1]]}).status_code == 200
    # while the original is untouched
    assert len(client.get(f"/playlists/{mirrored}", headers=hdr).json()["items"]) == 1


def test_an_unmatched_song_can_be_resolved_by_hand(client, hdr, mirrored, library):
    r = client.post(f"/spotify/playlists/{mirrored}/unmatched/1/resolve", headers=hdr,
                    json={"track_id": library[2]})
    assert r.status_code == 200

    full = client.get(f"/playlists/{mirrored}", headers=hdr).json()
    assert library[2] in [i["id"] for i in full["items"]]
    assert full["unmatched"] == 0
    assert client.get(f"/spotify/playlists/{mirrored}/unmatched",
                      headers=hdr).json()["items"] == []


def test_spotify_says_what_is_missing_when_it_is_not_configured(client, hdr):
    r = client.get("/spotify/account", headers=hdr).json()
    assert r["configured"] is False
    assert "developer.spotify.com" in r["reason"], "tell the operator what to do"
    assert client.get("/spotify/authorize", headers=hdr).status_code == 501


def test_syncing_nothing_specific_refreshes_only_what_is_mirrored(client, hdr,
                                                                  mirrored,
                                                                  monkeypatch):
    """An account can hold hundreds of playlists — this user's has 460. Mirroring all
    of them would be thousands of lookups and almost none of it wanted."""
    from muse import routes_spotify, spotify

    listed = [
        {"remote_id": "SP1", "name": "From Spotify", "count": None, "owner": "someone"},
        {"remote_id": "SP2", "name": "Not chosen", "count": None, "owner": "someone"},
    ]
    monkeypatch.setattr(spotify, "playlists", lambda cfg, uid: listed)
    assert routes_spotify.run_mirror_job                 # the worker's entry point

    def queued():
        rows = db.all_("""select payload->>'remote_id' as remote_id from jobs
                           where kind='mirror' order by id""")
        return [r["remote_id"] for r in rows]

    client.post("/spotify/sync", headers=hdr, json={})
    assert queued() == ["SP1"], "only the playlist already mirrored gets refreshed"

    db.run("delete from jobs where kind='mirror'")
    client.post("/spotify/sync", headers=hdr, json={"remote_id": "SP2"})
    assert queued() == ["SP2"], "and an explicit choice is honoured"


def test_remote_playlists_say_which_are_mirrored(client, hdr, mirrored, monkeypatch):
    from muse import spotify

    monkeypatch.setattr(spotify, "playlists", lambda cfg, uid: [
        {"remote_id": "SP1", "name": "From Spotify", "count": None, "owner": "someone"},
        {"remote_id": "SP2", "name": "Not chosen", "count": None, "owner": "someone"},
    ])
    items = client.get("/spotify/playlists", headers=hdr).json()["items"]
    by_id = {i["remote_id"]: i for i in items}
    assert by_id["SP1"]["mirror"]["playlist_id"] == mirrored
    assert by_id["SP1"]["mirror"]["unmatched"] == 1
    assert by_id["SP2"]["mirror"] is None


def test_a_decade_is_a_list_that_fills_itself_in(client, hdr, library):
    """Nobody files a song under the nineties. The year it came out does that, and the
    shelves offered are only the ones with something on them."""
    alpha, beta, gamma = library[0], library[1], library[2]
    db.run("update tracks set state='ready' where id = any(%s)", ([alpha, beta, gamma],))
    db.run("update tracks set release_year=1994 where id=%s", (alpha,))
    db.run("update tracks set release_year=1999 where id=%s", (beta,))
    db.run("update tracks set release_year=2016 where id=%s", (gamma,))
    client.post("/listens", headers=hdr,
                json={"track_id": beta, "ms_played": 200_000, "completed": True})

    decades = client.get("/library/smart", headers=hdr).json()["decades"]
    by_id = {d["id"]: d for d in decades}
    assert by_id["d1990"]["count"] == 2 and by_id["d1990"]["short"] == "90s"
    assert by_id["d2010"]["count"] == 1
    assert "d1980" not in by_id, "nothing from the eighties, so no shelf for it"
    assert [d["id"] for d in decades] == sorted(by_id, reverse=True), "newest first"

    nineties = client.get("/library/smart/d1990", headers=hdr).json()
    assert nineties["name"] == "The 1990s"
    assert [t["id"] for t in nineties["items"]] == [beta, alpha], "what you play, first"

    assert client.get("/library/smart/d1995", headers=hdr).status_code == 404
    assert client.get("/library/smart/d1990;drop", headers=hdr).status_code == 404


def test_the_letters_say_where_in_the_list_they_start(client, hdr, library):
    """Dragging down the side of a long list goes to a letter, and a letter is a row
    number in exactly the order the list itself is paged in."""
    for what in ("albums", "artists"):
        listed = client.get(f"/library/{what}", headers=hdr,
                            params={"limit": 500, "sort": "name"}).json()["items"]
        letters = client.get(f"/library/{what}/index", headers=hdr).json()["letters"]
        assert letters, what
        assert sum(l["count"] for l in letters) == len(listed), "every row under one letter"
        for l in letters:
            first = listed[l["offset"]]["name"]
            initial = first[:1].upper()
            assert (initial if "A" <= initial <= "Z" else "#") == l["letter"], (what, l, first)
            if l["offset"] > 0 and l["letter"] != "#":
                before = listed[l["offset"] - 1]["name"][:1].upper()
                assert before != l["letter"], "the first of its letter, not one in the middle"
