"""Playlist sync — one way in, never out.

Spotify's Development-mode API is what we get forever (extended quota needs 250k MAU),
and since 2026-03-09 that means: read your own playlists, nothing else. So Spotify is a
source of *what you listen to*, never a source of audio or metadata. Every imported item
has to be matched onto a YouTube Music track, and matching is where libraries like this
rot — so every decision is stored with its score and method, and a human override is
permanent.
"""
from __future__ import annotations

import json
from dataclasses import dataclass
from typing import Protocol

import httpx

from . import catalog, db, jobs, match, ytm


class MissingCredentials(RuntimeError):
    pass


@dataclass
class RemotePlaylist:
    remote_id: str
    name: str
    count: int | None = None


class Adapter(Protocol):
    kind: str

    def list_playlists(self) -> list[RemotePlaylist]: ...
    def playlist_items(self, remote_id: str) -> list[dict]: ...


# --------------------------------------------------------------------- Spotify
class SpotifyAdapter:
    """Development mode only. GET /playlists/{id}/tracks is 403 since March 2026;
    the replacement is /items, and it returns items only for playlists you own or
    collaborate on."""

    kind = "spotify"
    API = "https://api.spotify.com/v1"

    def __init__(self, client_id: str, client_secret: str, refresh_token: str):
        if not (client_id and client_secret and refresh_token):
            raise MissingCredentials(
                "spotify needs client_id, client_secret and refresh_token in muse.toml"
            )
        self._id, self._secret, self._refresh = client_id, client_secret, refresh_token
        self._token: str | None = None

    def _access_token(self) -> str:
        if self._token:
            return self._token
        r = httpx.post(
            "https://accounts.spotify.com/api/token",
            data={"grant_type": "refresh_token", "refresh_token": self._refresh},
            auth=(self._id, self._secret), timeout=30,
        )
        r.raise_for_status()
        self._token = r.json()["access_token"]
        return self._token

    def _get(self, url: str, **params) -> dict:
        r = httpx.get(url if url.startswith("http") else f"{self.API}{url}",
                      headers={"Authorization": f"Bearer {self._access_token()}"},
                      params=params or None, timeout=30)
        if r.status_code == 403:
            raise RuntimeError(
                "Spotify returned 403. In Development mode you can only read playlists "
                "you own or collaborate on."
            )
        r.raise_for_status()
        return r.json()

    def list_playlists(self) -> list[RemotePlaylist]:
        out, url, params = [], "/me/playlists", {"limit": 50}
        while url:
            page = self._get(url, **params)
            for p in page.get("items", []):
                out.append(RemotePlaylist(p["id"], p["name"], (p.get("tracks") or {}).get("total")))
            url, params = page.get("next"), {}
        return out

    def playlist_items(self, remote_id: str) -> list[dict]:
        out, url, params = [], f"/playlists/{remote_id}/items", {"limit": 50}
        while url:
            page = self._get(url, **params)
            for entry in page.get("items", []):
                item = entry.get("item") or entry.get("track") or {}
                if item.get("type") not in (None, "track") or not item.get("name"):
                    continue
                out.append({
                    "remote_id": item.get("id") or item.get("uri"),
                    "title": item.get("name"),
                    "artists": [a["name"] for a in item.get("artists", []) if a.get("name")],
                    "album": (item.get("album") or {}).get("name"),
                    "duration_ms": item.get("duration_ms"),
                    "isrc": (item.get("external_ids") or {}).get("isrc"),
                })
            url, params = page.get("next"), {}
        return out


# ------------------------------------------------------------------ YouTube Music
class YTMusicAdapter:
    """Audio comes from here too, so every match is exact by videoId — nothing to score."""

    kind = "ytmusic"

    def __init__(self, oauth_file: str | None):
        if not oauth_file:
            raise MissingCredentials("ytmusic sync needs an oauth file (ytmusicapi oauth)")
        from ytmusicapi import YTMusic

        self._c = YTMusic(oauth_file)

    def list_playlists(self) -> list[RemotePlaylist]:
        return [RemotePlaylist(p["playlistId"], p.get("title", "?"), p.get("count"))
                for p in self._c.get_library_playlists(limit=100)]

    def playlist_items(self, remote_id: str) -> list[dict]:
        data = self._c.get_playlist(remote_id, limit=None)
        out = []
        for t in data.get("tracks", []):
            if not t.get("videoId"):
                continue
            out.append({
                "remote_id": t["videoId"],
                "video_id": t["videoId"],          # exact: no matching needed
                "title": t.get("title"),
                "artists": [a["name"] for a in (t.get("artists") or []) if a.get("name")],
                "album": (t.get("album") or {}).get("name") if isinstance(t.get("album"), dict) else None,
                "duration_ms": (t.get("duration_seconds") or 0) * 1000 or None,
                "isrc": None,
            })
        return out


def build(kind: str, cfg) -> Adapter:
    if kind == "spotify":
        s = cfg.spotify
        return SpotifyAdapter(s.get("client_id", ""), s.get("client_secret", ""),
                              s.get("refresh_token", ""))
    if kind == "ytmusic":
        return YTMusicAdapter(cfg.ytmusic.get("oauth_file"))
    raise ValueError(f"unknown sync provider {kind!r}")


# --------------------------------------------------------------------- matching
def _record(kind: str, remote_id: str, track_id: int | None, conf: float,
            method: str, decided_by: str, item: dict | None = None) -> None:
    """The remote title is stored with the decision: a review screen that cannot say
    *which song* it is asking about is not a review screen."""
    db.run(
        """insert into matches(remote_kind,remote_id,track_id,confidence,method,decided_by,
                               remote_title,remote_artists,decided_at)
           values(%s,%s,%s,%s,%s,%s,%s,%s,now())
           on conflict (remote_kind,remote_id) do update
             set track_id=excluded.track_id, confidence=excluded.confidence,
                 method=excluded.method, decided_by=excluded.decided_by,
                 remote_title=coalesce(excluded.remote_title, matches.remote_title),
                 remote_artists=coalesce(excluded.remote_artists, matches.remote_artists),
                 decided_at=now()""",
        (kind, remote_id, track_id, conf, method, decided_by,
         (item or {}).get("title"), (item or {}).get("artists")),
    )


def existing_decision(kind: str, remote_id: str) -> dict | None:
    return db.one("select * from matches where remote_kind=%s and remote_id=%s", (kind, remote_id))


def resolve_item(kind: str, item: dict, *, priority: int | None = None,
                 batch_id: str | None = None, batch_label: str | None = None,
                 download: bool = True) -> dict:
    """Remote item -> local track (or a review entry). Never re-decides a human override."""
    remote_id = item["remote_id"]
    prior = existing_decision(kind, remote_id)
    if prior and (prior["decided_by"] == "human" or prior["track_id"]):
        return {"track_id": prior["track_id"], "confidence": prior["confidence"],
                "method": prior["method"], "verdict": "cached"}

    # An ISRC we already hold is the end of the question: it names a recording, so this
    # is the same song, whatever the two services chose to call it. No search, no
    # scoring, no second copy of a file we already have.
    known = catalog.find_by_isrc(item.get("isrc"))
    if known:
        _record(kind, remote_id, known["id"], 1.0, "isrc", "auto", item)
        return {"track_id": known["id"], "confidence": 1.0, "method": "isrc",
                "verdict": "auto"}

    # YouTube Music items carry the videoId already: exact, nothing to score.
    if item.get("video_id"):
        track = catalog.find_by_video_id(item["video_id"]) or catalog.create_from_ytm(
            {**item, "raw": item}, discovered_via=catalog.VIA_SYNC,
            priority=priority or jobs.PRIORITY_NORMAL,
            batch_id=batch_id, batch_label=batch_label, download=download)
        _record(kind, remote_id, track["id"], 1.0, "video-id", "auto", item)
        return {"track_id": track["id"], "confidence": 1.0, "method": "video-id",
                "verdict": "auto"}

    query = " ".join([item.get("title") or "", (item.get("artists") or [""])[0]]).strip()
    candidates = ytm.search_songs(query, limit=5) if query else []
    best, conf, method = match.best(item, candidates)
    verdict = match.verdict(conf)

    if best is None or verdict == "review":
        _record(kind, remote_id, None, conf, method, "auto", item)
        return {"track_id": None, "confidence": conf, "method": method, "verdict": "review",
                "candidates": [{k: v for k, v in c.items() if k != "raw"} for c in candidates]}

    track = catalog.find_by_video_id(best["video_id"]) or catalog.create_from_ytm(
        best, discovered_via=catalog.VIA_SYNC, download=download,
        priority=priority or jobs.PRIORITY_NORMAL,
        batch_id=batch_id, batch_label=batch_label)
    if item.get("isrc"):
        # Cheap to store now, and it is what recognises this recording next time.
        db.run("update tracks set isrc=coalesce(isrc, upper(%s)) where id=%s",
               (item["isrc"], track["id"]))
    _record(kind, remote_id, track["id"], conf, method, "auto", item)
    return {"track_id": track["id"], "confidence": conf, "method": method, "verdict": verdict}


def import_playlist(user_id: int, adapter: Adapter, remote_id: str,
                    name: str, playlist_id: int | None = None) -> dict:
    items = adapter.playlist_items(remote_id)
    if playlist_id is None:
        playlist_id = db.one(
            """insert into playlists(owner_id,name,kind,remote_id,sync_mode)
               values(%s,%s,%s,%s,'pull') returning id""",
            (user_id, name, adapter.kind, remote_id),
        )["id"]

    resolved, review = [], []
    for item in items:
        r = resolve_item(adapter.kind, item)
        if r["track_id"]:
            resolved.append(r["track_id"])
        else:
            review.append({"remote_id": item["remote_id"], "title": item.get("title"),
                           "artists": item.get("artists"), "confidence": r["confidence"]})

    with db.pool().connection() as c:
        c.execute("delete from playlist_items where playlist_id=%s", (playlist_id,))
        for pos, tid in enumerate(resolved):
            c.execute("""insert into playlist_items(playlist_id,pos,track_id)
                         values(%s,%s,%s) on conflict do nothing""", (playlist_id, pos, tid))
        c.execute("update playlists set last_synced_at=now() where id=%s", (playlist_id,))

    return {"playlist_id": playlist_id, "items": len(items),
            "matched": len(resolved), "needs_review": review}


def review_queue(kind: str | None = None) -> list[dict]:
    """Everything the matcher would not commit to. Not optional in the UI."""
    sql = """select m.*, t.title as matched_title, t.artists as matched_artists
               from matches m left join tracks t on t.id=m.track_id
              where m.decided_by='auto'
                and (m.track_id is null or m.confidence < %s)"""
    params: tuple = (match.AUTO_ACCEPT,)
    if kind:
        sql += " and m.remote_kind=%s"
        params += (kind,)
    return db.all_(sql + " order by m.confidence desc nulls last", params)


def override(kind: str, remote_id: str, track_id: int | None = None,
             video_id: str | None = None) -> dict:
    """A human decision is permanent and is never re-run by a later sync."""
    if track_id is None and video_id:
        found = catalog.find_by_video_id(video_id)
        if not found:
            meta = ytm.song(video_id) or {"video_id": video_id, "title": video_id,
                                          "artists": [], "album": None, "duration_ms": None}
            found = catalog.create_from_ytm(meta, discovered_via=catalog.VIA_SYNC)
        track_id = found["id"]
    _record(kind, remote_id, track_id, 1.0, "manual", "human")
    return existing_decision(kind, remote_id)
