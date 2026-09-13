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
    assert [a["provider"] for a in listed] == ["deezer", "soundcloud", "bandcamp",
                                               "youtube"]
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
    monkeypatch.setattr(linked, "items",
                        lambda provider, remote_id, offset=0, user_id=None: ([
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
                        lambda provider, remote_id, offset=0, user_id=None: (many, None))
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


# ---------------- YouTube Music ----------------
def test_a_public_youtube_playlist_needs_no_account(client, hdr, monkeypatch):
    """Nothing about a YouTube account is public, so linking one keeps a credential —
    but a playlist somebody sent you is public, and mirroring that needs nothing."""
    from muse import ytm

    monkeypatch.setattr(ytm, "playlist_tracks", lambda rid, auth=None, limit=2000: [
        {"remote_id": "vid1", "video_id": "vid1", "title": "One",
         "artists": ["Somebody"], "album": None, "duration_ms": 1000},
    ])
    monkeypatch.setattr(ytm, "playlist_name", lambda rid, auth=None: "Sent to me")

    queued = client.post("/linked/youtube/sync", headers=hdr,
                         json={"remote_id": "PLwhatever"})
    assert queued.status_code == 200, queued.text

    out = routes_linked.run_mirror_job({"provider": "youtube", "user_id": 1,
                                        "remote_id": "PLwhatever"})
    assert out["matched"] == 1
    listed = client.get("/playlists", headers=hdr).json()
    assert any(p["name"] == "Sent to me" for p in listed), \
        "a playlist mirrored from a link keeps its name, not its id"


def test_your_own_youtube_library_needs_linking(client, hdr):
    r = client.post("/linked/youtube/sync", headers=hdr,
                    json={"remote_ids": ["liked-songs"]})
    assert r.status_code == 409
    assert "linked" in r.json()["detail"]


def test_a_youtube_sign_in_is_never_handed_back(client, hdr, monkeypatch):
    """The stored credential is the one thing here that must not leave the server."""
    from muse import linked as linked_mod

    monkeypatch.setitem(linked_mod._PROFILE, "youtube",
                        lambda auth: {"handle": "Chris", "display_name": "Chris",
                                      "secret": "cookie: SECRET-VALUE"})
    made = client.post("/linked/youtube", headers=hdr,
                       json={"handle": "cookie: SECRET-VALUE"})
    assert made.status_code == 200, made.text
    assert "SECRET" not in made.text

    listed = client.get("/linked", headers=hdr)
    assert "SECRET" not in listed.text
    assert linked_mod._secret(1, "youtube") == "cookie: SECRET-VALUE"


def test_signing_in_to_youtube_with_a_code(client, hdr, monkeypatch):
    """Google refuses an embedded browser — "this browser or app may not be secure" —
    so the way in is the device flow: a code read out here, typed in over there."""
    from muse import ytm

    monkeypatch.setattr(ytm, "oauth_start", lambda cfg: {
        "device_code": "DEV-123", "user_code": "ABCD-EFGH",
        "url": "https://google.com/device", "interval": 5, "expires_in": 1800,
    })
    started = client.post("/linked/youtube/oauth", headers=hdr)
    assert started.status_code == 200, started.text
    assert started.json()["user_code"] == "ABCD-EFGH"

    # Still working through the pages over there: not an error, just not yet.
    def not_yet(cfg, device_code):
        raise ytm.NotAllowed("authorization_pending")

    monkeypatch.setattr(ytm, "oauth_finish", not_yet)
    waiting = client.post("/linked/youtube/oauth/finish", headers=hdr,
                          json={"device_code": "DEV-123"})
    assert waiting.status_code == 409

    monkeypatch.setattr(ytm, "oauth_finish",
                        lambda cfg, device_code: '{"refresh_token": "SECRET"}')
    monkeypatch.setattr(ytm, "account_name", lambda auth: "Chris")
    done = client.post("/linked/youtube/oauth/finish", headers=hdr,
                       json={"device_code": "DEV-123"})
    assert done.status_code == 200, done.text
    assert done.json()["display_name"] == "Chris"
    assert "SECRET" not in done.text, "the token never leaves the server"

    from muse import linked as linked_mod
    assert linked_mod._secret(1, "youtube") == '{"refresh_token": "SECRET"}'


def test_without_an_oauth_client_the_app_is_told_to_paste(client, hdr):
    """No credentials configured is a 409 with an explanation, not a broken button."""
    r = client.post("/linked/youtube/oauth", headers=hdr)
    assert r.status_code == 409
    assert "pasting" in r.json()["detail"]
    listed = client.get("/linked", headers=hdr).json()["accounts"]
    assert next(a for a in listed if a["provider"] == "youtube")["sign_in"] == "paste"



# ---------------------------------------------------------------- signing in with a code
#
# Google will not sign anybody in inside an app's own browser, so the way in is the
# device flow — which needs an OAuth client this server owns. It can come from
# muse.toml, or be pasted in by an admin, which is what these are about.
def test_a_server_with_no_oauth_client_says_so(client, hdr):
    """Which sign-in screen somebody is shown comes from this."""
    said = client.get("/linked/youtube/oauth/client", headers=hdr).json()
    assert said["configured"] is False
    assert said["ends_with"] is None
    youtube = next(a for a in client.get("/linked", headers=hdr).json()["accounts"]
                   if a["provider"] == "youtube")
    assert youtube["sign_in"] == "paste"


def test_only_an_admin_can_give_the_server_a_client(client, hdr):
    from muse import auth

    tok = auth.issue_token(auth.ensure_user("ordinary"), "phone", None)
    r = client.put("/linked/youtube/oauth/client",
                   headers={"Authorization": f"Bearer {tok}"},
                   json={"client_id": "x.apps.googleusercontent.com",
                         "client_secret": "y"})
    assert r.status_code == 403


def test_a_client_is_checked_with_google_before_it_is_kept(client, hdr, monkeypatch):
    """A client id with a typo in it would otherwise become a sign-in screen that
    fails for everybody a week later, with nothing on screen to say why."""
    from muse import ytm

    def refuse(client_id, client_secret):
        raise ytm.NotAllowed("invalid_client")

    monkeypatch.setattr(ytm, "check_oauth_client", refuse)
    r = client.put("/linked/youtube/oauth/client", headers=hdr,
                   json={"client_id": "wrong", "client_secret": "wrong"})
    assert r.status_code == 400
    assert "would not take" in r.json()["detail"]
    assert client.get("/linked/youtube/oauth/client",
                      headers=hdr).json()["configured"] is False


def test_a_client_google_accepts_is_kept_and_never_handed_back(client, hdr, monkeypatch):
    from muse import ytm

    monkeypatch.setattr(ytm, "check_oauth_client", lambda *a: None)
    r = client.put("/linked/youtube/oauth/client", headers=hdr,
                   json={"client_id": "123-abcdef.apps.googleusercontent.com",
                         "client_secret": "shhh"})
    assert r.status_code == 200
    assert "shhh" not in r.text, "a secret that goes in never comes back out"

    said = client.get("/linked/youtube/oauth/client", headers=hdr).json()
    assert said["configured"] is True
    assert said["from"] == "settings"
    assert said["ends_with"] == "seruserconten"[-12:] or len(said["ends_with"]) == 12

    # And the service list now offers the code rather than a paste.
    youtube = next(a for a in client.get("/linked", headers=hdr).json()["accounts"]
                   if a["provider"] == "youtube")
    assert youtube["sign_in"] == "code"

    client.delete("/linked/youtube/oauth/client", headers=hdr)
    assert client.get("/linked/youtube/oauth/client",
                      headers=hdr).json()["configured"] is False
