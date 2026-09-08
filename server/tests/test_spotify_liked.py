"""Liked Songs. Not a playlist as far as Spotify is concerned, and the list most people
mean when they say "my music"."""
from __future__ import annotations

import pytest

from muse import db, spotify


@pytest.fixture()
def api(monkeypatch):
    """Stands in for Spotify's HTTP surface, paging included."""
    calls: list[tuple[str, dict]] = []
    pages = {
        "/me/tracks": {
            "total": 412,
            "items": [{"track": {"id": "t1", "name": "First", "duration_ms": 1000,
                                 "artists": [{"name": "Someone"}],
                                 "album": {"name": "An album"},
                                 "external_ids": {"isrc": "GBUM71505902"}}}],
            "next": "https://api.spotify.com/v1/me/tracks?offset=50",
        },
        "https://api.spotify.com/v1/me/tracks?offset=50": {
            "items": [{"track": {"id": "t2", "name": "Second", "duration_ms": 2000,
                                 "artists": [{"name": "Someone else"}],
                                 "album": {"name": "Another"}}},
                      {"track": None}],                    # removed tracks come back null
            "next": None,
        },
        "/me/playlists": {"items": [{"id": "PL1", "name": "Roadtrip",
                                     "tracks": {"total": 12},
                                     "owner": {"display_name": "chris"}}],
                          "next": None},
    }

    def fake_get(cfg, user_id, url, **params):
        calls.append((url, params))
        return pages[url]

    monkeypatch.setattr(spotify, "_get", fake_get)
    return calls


def test_liked_songs_leads_the_list(api):
    listed = spotify.playlists(None, 1)
    assert listed[0]["remote_id"] == spotify.LIKED
    assert listed[0]["name"] == "Liked Songs"
    assert listed[0]["count"] == 412, "the count comes from the total, not from paging it"
    assert [p["name"] for p in listed[1:]] == ["Roadtrip"]
    # Asking for the count must not download the library.
    assert ("/me/tracks", {"limit": 1}) in api


def test_liked_songs_read_like_any_other_playlist(api):
    items = spotify.playlist_items(None, 1, spotify.LIKED)
    assert [i["title"] for i in items] == ["First", "Second"], "and it pages"
    assert items[0]["isrc"] == "GBUM71505902"
    assert items[0]["artists"] == ["Someone"]


def test_a_removed_track_does_not_become_an_empty_row(api):
    items = spotify.playlist_items(None, 1, spotify.LIKED)
    assert all(i["title"] for i in items)


def test_a_rate_limit_is_waited_out_not_failed(monkeypatch):
    """Twelve thousand liked songs is 240 pages, and Spotify says no partway through.
    It tells us how long to wait; the only mistake would be not listening."""
    from muse import db, spotify

    class Response:
        def __init__(self, status, body=None, retry_after=None):
            self.status_code = status
            self._body = body or {}
            self.headers = {"Retry-After": str(retry_after)} if retry_after else {}

        def json(self):
            return self._body

        def raise_for_status(self):
            pass

    answers = [Response(429, retry_after=1), Response(200, {"items": [], "next": None})]
    waited: list[float] = []
    monkeypatch.setattr(spotify.httpx, "get", lambda *a, **k: answers.pop(0))
    monkeypatch.setattr(spotify.time, "sleep", waited.append)
    monkeypatch.setattr(spotify, "access_token", lambda cfg, uid: "tok")

    assert spotify._get(None, 1, "/me/tracks") == {"items": [], "next": None}
    assert waited == [1.0], "and it waits exactly as long as it was asked to"


def test_giving_up_on_a_rate_limit_says_it_will_resume(monkeypatch):
    from muse import db, spotify

    class Busy:
        status_code = 429
        headers = {"Retry-After": "1"}

    monkeypatch.setattr(spotify.httpx, "get", lambda *a, **k: Busy())
    monkeypatch.setattr(spotify.time, "sleep", lambda s: None)
    monkeypatch.setattr(spotify, "access_token", lambda cfg, uid: "tok")

    with pytest.raises(spotify.SpotifyBusy) as e:
        spotify._get(None, 1, "/me/tracks")
    assert "pick up where it left off" in str(e.value)


def test_a_huge_library_arrives_in_runs_that_resume(client, hdr, monkeypatch):
    """Spotify will not serve twelve thousand songs in one sitting, so the import takes
    them in runs — and each run keeps what it got."""
    from muse import jobs, routes_spotify, spotify, sync

    page = [{"remote_id": f"sp{n}", "title": f"Song {n}", "artists": ["Someone"],
             "album": None, "duration_ms": 200_000} for n in range(50)]

    def saved(cfg, user_id, offset=0, pages=None):
        # Two runs' worth, then the end.
        return (page, offset + 50) if offset == 0 else (page[:10], None)

    monkeypatch.setattr(spotify, "saved_tracks", saved)
    made: list[int] = []
    monkeypatch.setattr(sync, "resolve_item",
                        lambda *a, **k: {"track_id": _fake_track(made)})

    first = routes_spotify.run_mirror_job(
        {"user_id": 1, "remote_id": spotify.LIKED, "name": "Liked Songs"})
    assert first["added"] == 50 and first["resumes_at"] == 50

    # The next run is queued, and carries where to carry on from.
    queued = db.one("""select payload from jobs
                        where kind='mirror' order by id desc limit 1""")["payload"]
    assert queued["offset"] == 50

    listed = client.get(f"/playlists/{first['playlist_id']}", headers=hdr).json()
    assert len(listed["items"]) == 50, "a run that is cut off has still imported 50"
    assert listed["download_mode"] == "on_play", "and the audio waits to be asked for"

    second = routes_spotify.run_mirror_job(
        {"user_id": 1, "remote_id": spotify.LIKED, "offset": 50})
    assert second["added"] == 10 and second["resumes_at"] is None
    listed = client.get(f"/playlists/{first['playlist_id']}", headers=hdr).json()
    assert len(listed["items"]) == 60, "and the second run adds to the first"


def _fake_track(made: list[int]) -> int:
    """A track row to point a playlist item at."""
    row = db.one(
        """insert into tracks(title,artists,source,state,discovered_via)
           values(%s,'{}','youtube','pending','sync') returning id""",
        (f"Track {len(made)}",))
    made.append(row["id"])
    return row["id"]


def test_naming_a_playlist_queues_it_without_asking_spotify(client, hdr, monkeypatch):
    """A rate-limited account could not start the very import that would have waited
    the limit out, because queueing it listed the playlists first."""
    from muse import spotify

    def refuse(*a, **k):
        raise AssertionError("queueing must not call Spotify")

    monkeypatch.setattr(spotify, "playlists", refuse)
    r = client.post("/spotify/sync", headers=hdr, json={"remote_id": spotify.LIKED})
    assert r.status_code == 200
    assert db.one("""select count(*) n from jobs
                      where kind='mirror' and payload->>'remote_id'=%s""",
                  (spotify.LIKED,))["n"] == 1


def test_being_told_to_slow_down_is_not_a_failure(client, hdr, monkeypatch):
    """A rate limit must not spend one of the job's three attempts — it comes back."""
    from muse import routes_spotify, spotify

    def busy(*a, **k):
        raise spotify.SpotifyBusy("slow down")

    monkeypatch.setattr(spotify, "saved_tracks", busy)
    out = routes_spotify.run_mirror_job(
        {"user_id": 1, "remote_id": spotify.LIKED, "offset": 250})
    assert "waiting" in out and out["from"] == 250

    row = db.one("""select payload, attempts, next_attempt_at > now() as later
                      from jobs where kind='mirror' order by id desc limit 1""")
    assert row["payload"]["offset"] == 250, "it resumes where it stopped"
    assert row["attempts"] == 0, "and starts with all its attempts intact"
    assert row["later"], "just not right away"
