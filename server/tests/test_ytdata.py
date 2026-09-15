"""Reading a YouTube library with a code sign-in, through YouTube's public API.

YouTube Music's internal API refuses a token from a Google project of your own on every
library call; the Data API takes it. Google is faked here at the HTTP level, so what is
tested is what the server sends and how it reads the answers.
"""
from __future__ import annotations

import json

import httpx
import pytest

from muse import ytdata, ytm

CLIENT = ("client-id.apps.googleusercontent.com", "client-secret")
AUTH = ytdata.stored({"refresh_token": "REFRESH"})


def _song(video_id, title, channel, description="", category="10", duration="PT3M30S"):
    return {"id": video_id, "snippet": {"title": title, "channelTitle": channel,
                                        "description": description,
                                        "categoryId": category},
            "contentDetails": {"duration": duration}}


GET_LUCKY = _song("5NV6Rdv1a3I", "Get Lucky", "Daft Punk - Topic",
                  "Provided to YouTube by Columbia\n\n"
                  "Get Lucky · Daft Punk · Pharrell Williams · Nile Rodgers\n\n"
                  "Random Access Memories\n\n℗ 2013 Daft Life Limited\n\n"
                  "Released on: 2013-05-17", duration="PT6M9S")
MUSIC_VIDEO = _song("VIDEO000002", "Arctic Monkeys - Do I Wanna Know? (Official Video)",
                    "ArcticMonkeysVEVO", duration="PT4M32S")
TOPIC_ONLY = _song("VIDEO000003", "Midnight City", "M83 - Topic", category="24")
CAT_VIDEO = _song("VIDEO000004", "cat falls off table", "Somebody", category="15")


class FakeGoogle:
    """Answers the handful of calls the Data API path makes, and remembers them."""

    def __init__(self):
        self.calls = []
        self.access = "ACCESS-1"
        self.refresh_error = None
        self.reject_access = set()
        self.api_error = None

    def post(self, url, data=None, timeout=None):
        self.calls.append(("POST", url, dict(data or {})))
        if url == ytdata.CODE_URL:
            return self._answer(200, {"device_code": "DEV", "user_code": "ABCD-EFGH",
                                      "verification_url": "https://www.google.com/device",
                                      "expires_in": 1800, "interval": 5})
        if data.get("grant_type") == ytdata.DEVICE_GRANT:
            return self._answer(200, {"access_token": "ACCESS-0", "expires_in": 3599,
                                      "refresh_token": "REFRESH", "scope": ytdata.SCOPE})
        if self.refresh_error:
            return self._answer(400, {"error": self.refresh_error})
        return self._answer(200, {"access_token": self.access, "expires_in": 3599})

    def get(self, url, params=None, timeout=None, headers=None):
        params = dict(params or {})
        self.calls.append(("GET", url, params))
        if headers["Authorization"].removeprefix("Bearer ") in self.reject_access:
            return self._answer(401, {"error": {"code": 401, "message": "Invalid Credentials",
                                                "errors": [{"reason": "authError"}]}})
        if self.api_error:
            return self._answer(*self.api_error)
        path = url.removeprefix(ytdata.API + "/")
        if path == "channels":
            return self._answer(200, {"items": [{"snippet": {"title": "Joe"}}]})
        if path == "playlists":
            if params.get("id"):
                return self._answer(200, {"items": [{"snippet": {"title": "Road trip"}}]})
            page = [{"id": "PLroad", "snippet": {"title": "Road trip", "channelTitle": "Joe",
                                                  "thumbnails": {"high": {"url": "https://i/1"}}},
                     "contentDetails": {"itemCount": 3}}]
            return self._answer(200, {"items": page})
        if path == "playlistItems" and params["playlistId"] != "PLroad":
            return self._answer(404, {"error": {"code": 404, "message": "not found",
                                                "errors": [{"reason": "playlistNotFound"}]}})
        if path == "playlistItems":
            # Two pages, with a deleted video in the second.
            if not params.get("pageToken"):
                return self._answer(200, {"items": [
                    {"contentDetails": {"videoId": "5NV6Rdv1a3I"}},
                    {"contentDetails": {"videoId": "VIDEO000002"}}],
                    "nextPageToken": "P2"})
            return self._answer(200, {"items": [
                {"contentDetails": {"videoId": "DELETED0001"}},
                {"contentDetails": {"videoId": "VIDEO000003"}}]})
        if path == "videos" and params.get("myRating") == "like":
            return self._answer(200, {"items": [GET_LUCKY, CAT_VIDEO, TOPIC_ONLY]})
        if path == "videos":
            known = {v["id"]: v for v in (GET_LUCKY, MUSIC_VIDEO, TOPIC_ONLY)}
            return self._answer(200, {"items": [known[i] for i in params["id"].split(",")
                                                if i in known]})
        return self._answer(404, {"error": {"code": 404, "message": "nope",
                                            "errors": [{"reason": "notFound"}]}})

    @staticmethod
    def _answer(status, body):
        return httpx.Response(status, content=json.dumps(body).encode(),
                              headers={"content-type": "application/json"})


@pytest.fixture()
def google(monkeypatch, cfg):
    fake = FakeGoogle()
    monkeypatch.setattr(ytdata.httpx, "post", fake.post)
    monkeypatch.setattr(ytdata.httpx, "get", fake.get)
    monkeypatch.setattr(ytm, "oauth_client", lambda c: (*CLIENT, "settings"))
    ytdata._access.clear()
    # _data asks deps for the config when it is not handed one.
    from muse import deps
    monkeypatch.setattr(deps, "cfg", lambda: cfg)
    return fake


def test_a_code_sign_in_asks_only_to_read_youtube(google, cfg):
    code = ytm.oauth_start(cfg)
    assert code["user_code"] == "ABCD-EFGH"
    asked = next(c for c in google.calls if c[1] == ytdata.CODE_URL)
    assert asked[2]["scope"] == "https://www.googleapis.com/auth/youtube.readonly"

    kept = json.loads(ytm.oauth_finish(cfg, "DEV"))
    assert kept == {"api": "youtube-data", "refresh_token": "REFRESH",
                    "scope": ytdata.SCOPE}, "only what lasts is kept, not the hour-long token"


def test_playlists_come_from_the_public_api_with_liked_songs_first(google):
    rows = ytm.library_playlists(AUTH)
    assert [r["remote_id"] for r in rows] == [ytm.LIKED, "PLroad"]
    assert rows[1] == {"remote_id": "PLroad", "name": "Road trip", "count": 3,
                       "owner": "Joe", "image": "https://i/1"}
    assert ytm.account_name(AUTH) == "Joe"
    api = [c for c in google.calls if c[0] == "GET"]
    assert all(c[1].startswith(ytdata.API) for c in api), "never YouTube Music's own API"


def test_a_playlist_arrives_whole_in_order_with_songs_named_properly(google):
    tracks = ytm.playlist_tracks("https://music.youtube.com/playlist?list=PLroad", auth=AUTH)
    assert [t["video_id"] for t in tracks] == ["5NV6Rdv1a3I", "VIDEO000002", "VIDEO000003"]

    lucky, monkeys, m83 = tracks
    # The description YouTube writes for a label's upload carries the real credit.
    assert lucky["title"] == "Get Lucky"
    assert lucky["artists"] == ["Daft Punk", "Pharrell Williams", "Nile Rodgers"]
    assert lucky["album"] == "Random Access Memories"
    assert lucky["duration_ms"] == 369_000
    # A music video names itself "Artist - Song", with noise after it.
    assert monkeys["title"] == "Do I Wanna Know?"
    assert monkeys["artists"] == ["Arctic Monkeys"]
    # A Topic channel is the artist.
    assert m83["artists"] == ["M83"]
    assert ytm.playlist_name("PLroad", AUTH) == "Road trip"


def test_liked_songs_are_the_liked_videos_that_are_music(google):
    liked = ytm.playlist_tracks(ytm.LIKED, auth=AUTH)
    assert [t["video_id"] for t in liked] == ["5NV6Rdv1a3I", "VIDEO000003"]


def test_an_expired_access_token_is_refreshed_once(google):
    ytm.library_playlists(AUTH)
    google.reject_access.add("ACCESS-1")
    google.access = "ACCESS-2"
    assert ytm.account_name(AUTH) == "Joe"
    refreshes = [c for c in google.calls if c[0] == "POST"]
    assert len(refreshes) == 2


def test_a_revoked_sign_in_is_not_allowed(google):
    google.refresh_error = "invalid_grant"
    with pytest.raises(ytm.NotAllowed, match="Link YouTube again"):
        ytm.library_playlists(AUTH)


def test_the_api_switched_off_says_which_switch(google):
    google.api_error = (403, {"error": {
        "code": 403, "status": "PERMISSION_DENIED",
        "message": "YouTube Data API v3 has not been used in project 1 before or it is "
                   "disabled.",
        "errors": [{"reason": "accessNotConfigured"}]}})
    with pytest.raises(ytm.Unavailable, match="not enabled"):
        ytm.check_library_access(AUTH)


def test_an_account_without_a_channel_has_only_liked_songs(google):
    google.api_error = (404, {"error": {"code": 404, "message": "Channel not found.",
                                        "errors": [{"reason": "channelNotFound"}]}})
    assert [r["remote_id"] for r in ytm.library_playlists(AUTH)] == [ytm.LIKED]


def test_a_mix_only_youtube_music_knows_is_asked_for_publicly(google, monkeypatch):
    monkeypatch.setattr(ytm, "_ask", lambda what: {"tracks": [
        {"videoId": "MIXTRACK001", "title": "From the mix", "artists": [{"name": "X"}]}]})
    tracks = ytm.playlist_tracks("RDCLAKmix", auth=AUTH)
    assert [t["video_id"] for t in tracks] == ["MIXTRACK001"]


def test_linking_with_a_code_then_listing_goes_end_to_end(client, hdr, google):
    started = client.post("/linked/youtube/oauth", headers=hdr)
    assert started.status_code == 200, started.text
    done = client.post("/linked/youtube/oauth/finish", headers=hdr,
                       json={"device_code": started.json()["device_code"]})
    assert done.status_code == 200, done.text
    assert done.json()["display_name"] == "Joe"
    assert "REFRESH" not in done.text

    listed = client.get("/linked/youtube/playlists", headers=hdr)
    assert listed.status_code == 200, listed.text
    assert [p["name"] for p in listed.json()["items"]] == ["Liked Songs", "Road trip"]
