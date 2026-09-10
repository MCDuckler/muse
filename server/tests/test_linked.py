"""Linking the services that need no consent screen.

A Deezer profile id, a SoundCloud username and a Bandcamp fan name are public reads, so
linking one is typing a name. What matters is that a bad name says so, and that tracks
which already know where they come from skip matching entirely.
"""
from __future__ import annotations

import json

import pytest

from muse import catalog, db, linked, routes_linked, sources


def test_only_the_three_can_be_linked(client, hdr):
    listed = client.get("/linked", headers=hdr).json()["accounts"]
    assert [a["provider"] for a in listed] == ["deezer", "soundcloud", "bandcamp"]
    assert all(a["linked"] is None for a in listed), "nothing is linked to begin with"
    assert client.post("/linked/tidal", headers=hdr, json={"handle": "x"}).status_code == 404


def test_a_name_that_is_not_a_profile_says_so(client, hdr, monkeypatch):
    def refuse(handle):
        raise linked.LinkError("Bandcamp has no fan page with that name.")

    monkeypatch.setitem(linked._PROFILE, "bandcamp", refuse)
    r = client.post("/linked/bandcamp", headers=hdr, json={"handle": "nobody"})
    assert r.status_code == 400
    assert "no fan page" in r.json()["detail"]


def test_deezer_wants_the_id_not_the_name():
    with pytest.raises(linked.LinkError) as e:
        linked._deezer_profile("chris")
    assert "numeric id" in str(e.value)


def test_a_deezer_profile_url_is_accepted(monkeypatch):
    monkeypatch.setattr(linked, "_json", lambda url, data=None: {"name": "Chris"})
    got = linked._deezer_profile("https://www.deezer.com/en/profile/2529")
    assert got == {"handle": "2529", "display_name": "Chris"}


def test_linking_sticks_and_can_be_undone(client, hdr, monkeypatch):
    monkeypatch.setitem(linked._PROFILE, "soundcloud",
                        lambda h: {"handle": h, "display_name": "Tycho"})
    made = client.post("/linked/soundcloud", headers=hdr, json={"handle": "tycho"}).json()
    assert made["handle"] == "tycho" and made["display_name"] == "Tycho"

    listed = {a["provider"]: a for a in client.get("/linked", headers=hdr).json()["accounts"]}
    assert listed["soundcloud"]["linked"]["handle"] == "tycho"

    client.delete("/linked/soundcloud", headers=hdr)
    listed = {a["provider"]: a for a in client.get("/linked", headers=hdr).json()["accounts"]}
    assert listed["soundcloud"]["linked"] is None


def test_playlists_need_a_link_first(client, hdr):
    r = client.get("/linked/deezer/playlists", headers=hdr)
    assert r.status_code == 409 and "linked" in r.json()["detail"]


def test_a_soundcloud_mirror_needs_no_matching(client, hdr, monkeypatch):
    """The list hands back the track itself. Matching exists for services that only
    tell you a title and an artist — here there is nothing to guess."""
    monkeypatch.setattr(linked, "items", lambda provider, remote_id, offset=0: ([
        {"remote_id": "1", "title": "Awake", "artists": ["Tycho"], "album": None,
         "duration_ms": 283_682,
         "source": {"provider": "soundcloud", "provider_id": "115300435",
                    "url": "https://api.soundcloud.com/tracks/115300435"}},
    ], None))

    out = routes_linked.run_mirror_job(
        {"provider": "soundcloud", "user_id": 1, "remote_id": "tycho/likes",
         "name": "tycho · Likes"})
    assert out["matched"] == 1 and out["unmatched"] == 0

    listed = client.get(f"/playlists/{out['playlist_id']}", headers=hdr).json()
    assert [t["title"] for t in listed["items"]] == ["Awake"]
    assert listed["items"][0]["source"] == "soundcloud"
    # And it went to the lane the server runs itself.
    kinds = {r["kind"] for r in db.all_(
        "select distinct kind from jobs where kind in ('ingest','ingest_direct')")}
    assert kinds == {"ingest_direct"}


def test_a_big_mirror_leaves_the_audio_until_it_is_played(client, hdr, monkeypatch):
    many = [{"remote_id": str(n), "title": f"Song {n}", "artists": ["Someone"],
             "album": None, "duration_ms": 200_000} for n in range(routes_linked.BIG_MIRROR + 1)]
    monkeypatch.setattr(linked, "items",
                        lambda provider, remote_id, offset=0: (many, None))
    monkeypatch.setattr("muse.sync.resolve_item",
                        lambda *a, **k: {"track_id": None, "confidence": 0.0,
                                         "method": "stub", "verdict": "review"})

    out = routes_linked.run_mirror_job(
        {"provider": "deezer", "user_id": 1, "remote_id": "42", "name": "Big"})
    assert db.one("select download_mode from playlists where id=%s",
                  (out["playlist_id"],))["download_mode"] == "on_play", \
        "past a few hundred songs a mirror is a library, and the audio waits"


def test_a_bandcamp_collection_is_albums_not_songs(monkeypatch):
    """One request per record, and the tracklist comes with it."""
    monkeypatch.setattr(linked, "_bandcamp_blob", lambda h: {"fan_data": {"fan_id": 7}})
    monkeypatch.setattr(linked, "_json", lambda url, data=None: {
        "items": [{"item_url": "https://a.bandcamp.com/album/one"}],
        "more_available": False, "last_token": "t"})
    monkeypatch.setattr(linked.time, "sleep", lambda s: None)
    monkeypatch.setattr(sources, "bandcamp_tracks", lambda url: [
        {"provider_id": "11", "title": "Track one", "artists": ["A band"],
         "album": "One", "duration_ms": 100_000, "url": url, "streamable": True},
        {"provider_id": "12", "title": "Only if you buy it", "artists": ["A band"],
         "album": "One", "duration_ms": 100_000, "url": url, "streamable": False},
    ])

    got, resume = linked._bandcamp_items("someone/collection")
    assert [t["title"] for t in got] == ["Track one"], "what cannot be streamed is left out"
    assert got[0]["source"]["provider"] == "bandcamp"
    assert resume is None, "one record, and that was all of them"


def test_a_wishlist_of_a_thousand_records_arrives_in_runs(monkeypatch):
    """Each record is a page fetch. Asking for thirteen hundred at once is how the
    address gets blocked — which is exactly what happened to a real wishlist."""
    albums = [f"https://a.bandcamp.com/album/{n}" for n in range(100)]
    monkeypatch.setattr(linked, "_bandcamp_albums", lambda h, w: albums)
    monkeypatch.setattr(linked.time, "sleep", lambda s: None)
    fetched = []

    def one_track(url):
        fetched.append(url)
        return [{"provider_id": url[-2:], "title": f"Track {url[-2:]}",
                 "artists": ["A band"], "album": "An album", "duration_ms": 100_000,
                 "url": url, "streamable": True}]

    monkeypatch.setattr(sources, "bandcamp_tracks", one_track)

    first, resume = linked._bandcamp_items("someone/wishlist")
    assert len(first) == linked.ALBUMS_PER_RUN, "a bounded run, not the lot"
    assert resume == linked.ALBUMS_PER_RUN

    second, resume2 = linked._bandcamp_items("someone/wishlist", offset=resume)
    assert resume2 == 2 * linked.ALBUMS_PER_RUN
    assert fetched[resume] == albums[resume], "and it carries on where it stopped"


def test_being_rate_limited_keeps_what_it_got(monkeypatch):
    """Bandcamp said 429 partway through a real wishlist and the whole job failed three
    times over. Now the run stops, keeps its records, and says where to resume."""
    albums = [f"https://a.bandcamp.com/album/{n}" for n in range(10)]
    monkeypatch.setattr(linked, "_bandcamp_albums", lambda h, w: albums)
    monkeypatch.setattr(linked.time, "sleep", lambda s: None)

    def blow_up_on_the_third(url):
        if url.endswith("/2"):
            raise linked.RateLimited("429")
        return [{"provider_id": url[-1], "title": "t", "artists": ["a"], "album": "b",
                 "duration_ms": 1000, "url": url, "streamable": True}]

    monkeypatch.setattr(sources, "bandcamp_tracks", blow_up_on_the_third)
    got, resume = linked._bandcamp_items("someone/wishlist")
    assert len(got) == 2, "the two it managed are kept"
    assert resume == 2, "and it comes back to the one that was refused"


def test_a_rate_limit_reschedules_rather_than_failing(client, hdr, monkeypatch):
    from muse import routes_linked

    def busy(*a, **k):
        raise linked.RateLimited("429")

    monkeypatch.setattr(linked, "items", busy)
    out = routes_linked.run_mirror_job({"provider": "bandcamp", "user_id": 1,
                                        "remote_id": "someone/wishlist", "offset": 80})
    assert "waiting" in out and out["from"] == 80
    row = db.one("""select payload, attempts, next_attempt_at > now() later
                      from jobs where kind='mirror' order by id desc limit 1""")
    assert row["payload"]["offset"] == 80 and row["attempts"] == 0 and row["later"]


# ---------------- SoundCloud listings ----------------
def test_a_soundcloud_set_arrives_with_names(monkeypatch):
    """Every SoundCloud track mirrored before this was created blank.

    yt-dlp's flat listing answers for SoundCloud with ids and links and nothing else —
    no title, no uploader — so a whole profile came in as "Unknown artist". The web
    API answers the same question with the record.
    """
    calls = []

    def fake(path, **params):
        calls.append((path, params))
        if path == "/resolve" and params["url"].endswith("/dj-somebody"):
            return {"id": 77}
        if path == "/resolve":                       # the set itself
            return {"kind": "playlist", "tracks": [
                {"id": 1, "title": "First", "duration": 1000,
                 "user": {"username": "Someone"}},
                {"id": 2},                           # named but not described
            ]}
        if path == "/tracks":
            assert params["ids"] == "2"
            return [{"id": 2, "title": "Second", "duration": 2000,
                     "user": {"username": "Another"}}]
        raise AssertionError(path)

    monkeypatch.setattr(linked, "_sc_api", fake)
    items = linked._soundcloud_items("dj-somebody/sets/night-bus")

    assert [i["title"] for i in items] == ["First", "Second"], "and in the set's order"
    assert [i["artists"] for i in items] == [["Someone"], ["Another"]]
    assert [i["duration_ms"] for i in items] == [1000, 2000]
    assert items[0]["source"] == {"provider": "soundcloud", "provider_id": "1",
                                  "url": "https://api.soundcloud.com/tracks/1"}


def test_likes_are_unwrapped(monkeypatch):
    """A like is a wrapper around a track, and a repost is the same shape."""
    def fake(path, **params):
        if path == "/resolve":
            return {"id": 5}
        if path.endswith("/likes"):
            return {"collection": [
                {"track": {"id": 9, "title": "Liked", "duration": 3000,
                           "user": {"username": "Uploader"}}},
            ]}
        raise AssertionError(path)

    monkeypatch.setattr(linked, "_sc_api", fake)
    items = linked._soundcloud_items("dj-somebody/likes")
    assert items[0]["title"] == "Liked" and items[0]["artists"] == ["Uploader"]


def test_a_listing_that_will_not_answer_falls_back(monkeypatch):
    """The old path still works, and now names the track from its link rather than
    creating something with no name at all."""
    def refuse(path, **params):
        raise linked.LinkError("no")

    class Result:
        returncode = 0
        stdout = json.dumps({"entries": [
            {"id": 42, "url": "https://soundcloud.com/dj-somebody/night-bus-edit"},
        ]})
        stderr = ""

    monkeypatch.setattr(linked, "_sc_api", refuse)
    monkeypatch.setattr(linked.subprocess, "run", lambda *a, **k: Result())
    items = linked._soundcloud_items("dj-somebody/likes")
    assert items[0]["title"] == "night bus edit"
    assert items[0]["artists"] == ["dj-somebody"]
