from __future__ import annotations

import asyncio
import hashlib
import json
import logging
import mimetypes
import pathlib
import re
import subprocess
from contextlib import asynccontextmanager
from typing import Annotated
from urllib.parse import quote, urlparse

import httpx

from fastapi import (Body, Depends, FastAPI, Form, Header, HTTPException, Request,
                     UploadFile)
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse, Response, StreamingResponse

from . import beats_worker
from . import (
    auth, catalog, config, db, direct_worker, enrich_worker, failures,
               follows, jobs, progress,
               jam, routes_accounts, routes_browse, routes_downloads, routes_files,
               routes_follows, routes_jam, routes_marks,
               routes_library, routes_linked, routes_play, routes_search,
               routes_devices, routes_scrobble, routes_social,
               routes_sources,
               routes_spotify,
               routes_sync, sleeve, pool, routes_pool,
               match, storage, ytm)
from . import deps
from .deps import current_user, worker_auth

cfg: config.Config = None  # set in create_app

# ---- in-process event bus (single API process for now; Postgres LISTEN when it grows) ----
#
# Every listener is somebody's: told apart because an event can now be addressed. Most
# of them are not — a track finishing downloading is news to everybody on the box —
# but telling one of your own devices to start playing is not, and neither is the fact
# that it is playing at all.
_subscribers: set[tuple[int, asyncio.Queue]] = set()
_loop: asyncio.AbstractEventLoop | None = None


def publish(event: str, data: dict, to_user: int | None = None) -> None:
    if _loop is None:
        return
    payload = f"event: {event}\ndata: {json.dumps(data)}\n\n"

    def _fan_out():
        for who, q in list(_subscribers):
            if to_user is None or who == to_user:
                q.put_nowait(payload)

    _loop.call_soon_threadsafe(_fan_out)


# The most one upload from somebody's computer may be: a song is a few megabytes and
# an hour-long set is sixty; anything past this is not a song.
DEVICE_UPLOAD_LIMIT = 400 * 1024 * 1024


def create_app(configuration: config.Config, start_workers: bool = False) -> FastAPI:
    global cfg
    cfg = configuration
    db.init(cfg.dsn)
    deps.set_config(cfg)
    for u in cfg.users:
        # Whoever is named in the server's own config file owns the server, so they are
        # the admins. The schema names chris and joe as a starting point, but a name in
        # there only becomes a row here — on a fresh database, and in the tests, that
        # row is written after the schema has run and would never have been marked.
        auth.ensure_user(u.name, pw_hash=u.password_hash, admin=True)

    worker = (enrich_worker.EnrichWorker(cfg, publish=publish)
              if start_workers else None)
    # SoundCloud and Bandcamp are fetched here rather than at home, and big mirrors run
    # here rather than inside the request that asked for them.
    def run_mirror(payload: dict) -> dict:
        # Spotify owns its own mirroring (OAuth, tokens, its own quirks); the public
        # ones share a single path.
        if payload.get("provider") in routes_linked.linked.PROVIDERS:
            return routes_linked.run_mirror_job(payload)
        return routes_spotify.run_mirror_job(payload)

    direct = (direct_worker.DirectWorker(cfg, publish=publish, mirror=run_mirror)
              if start_workers else None)

    listener = beats_worker.BeatsWorker(cfg) if start_workers else None

    @asynccontextmanager
    async def lifespan(_: FastAPI):
        global _loop
        _loop = asyncio.get_running_loop()
        if worker:
            worker.start()
        if direct:
            direct.start()
        if listener:
            listener.start()
        if start_workers:
            # One outstanding poll job is the scheduler; it re-queues itself when it
            # runs. Asking at boot covers a box that was off when the last one was due.
            try:
                follows.ensure_scheduled(delay=60)
            except Exception as e:                     # never block startup on this
                logging.getLogger("muse").warning(
                    "could not schedule the follow poll: %s", e)
        yield
        if worker:
            worker.stop()
        if direct:
            direct.stop()
        if listener:
            listener.stop()
        _loop = None

    app = FastAPI(title="WetOwl", docs_url="/api-docs", lifespan=lifespan)
    # Per-app, not per-module: a second app instance (tests, a worker process) gets its own.
    login_limit = auth.RateLimiter(rate=0.2, burst=5)      # 1 login / 5 s, burst 5
    resolve_limit = auth.RateLimiter(rate=2.0, burst=30)   # 2 resolves / s per device

    # ---------------- auth ----------------
    @app.post("/auth/login")
    def login(request: Request, user: str = Form(...), password: str = Form(...),
              device: str = Form("unnamed"), platform: str = Form(None)):
        ip = request.client.host if request.client else "?"
        if not login_limit.allow(ip):
            raise HTTPException(429, "too many login attempts")
        entry = cfg.user(user)
        found = auth.check_login(user, password, entry.password_hash if entry else None)
        if not found:
            raise HTTPException(401, "wrong user or password")
        return {
            "token": auth.issue_token(found["id"], device, platform),
            "user": found["name"],
        }

    @app.post("/auth/redeem")
    def redeem(request: Request, code: str = Form(...), user: str = Form(...),
               password: str = Form(...), device: str = Form("unnamed"),
               platform: str = Form(None)):
        """Turn an invite into an account. This is the only route that creates a user
        without being signed in, and it needs a code someone deliberately handed out."""
        ip = request.client.host if request.client else "?"
        if not login_limit.allow(ip):
            raise HTTPException(429, "too many attempts")
        invite = db.one(
            """select code, created_by from invites
                where code=%s and used_at is null and expires_at > now()""",
            (code.strip(),),
        )
        if not invite:
            raise HTTPException(400, "that invite is not valid any more")
        try:
            account = auth.create_account(user, password, created_by=invite["created_by"])
        except ValueError as e:
            raise HTTPException(400, str(e))
        db.run("update invites set used_at=now(), used_by=%s where code=%s",
               (account["id"], invite["code"]))
        return {
            "token": auth.issue_token(account["id"], device, platform),
            "user": account["name"],
        }

    @app.post("/auth/password")
    def change_password(body: dict = Body(...), user: dict = Depends(current_user)):
        try:
            auth.set_password(user["id"], body.get("password") or "")
        except ValueError as e:
            raise HTTPException(400, str(e))
        return {"changed": True}

    @app.get("/auth/stream-key")
    def stream_key(user: dict = Depends(current_user)):
        """A browser cannot put a bearer token on an <audio> src, so it gets a
        short-lived signed key to hang off the stream URL instead."""
        key, exp = auth.stream_key(user["id"], cfg.worker_secret)
        return {"key": key, "expires_at": exp}

    @app.get("/me")
    def me(user: dict = Depends(current_user)):
        row = db.one("select id, avatar_sig from users where id=%s", (user["id"],))
        return {"user": user["name"], "device": user["device_name"],
                "user_id": user["id"],
                # Records heard all the way through, which is the only number in here
                # anybody is competing over.
                "score": db.one(
                    "select count(*) n from listens where user_id=%s and completed",
                    (user["id"],))["n"],
                # The picture, if there is one, so the app can draw it without asking
                # a second question on every start.
                "avatar_version": (row or {}).get("avatar_sig")}

    # ---------------- catalog ----------------
    @app.get("/search")
    def search(q: str, limit: int = 20, remote: bool = True, user: dict = Depends(current_user)):
        # The catalog is shared, so search reaches everything on the box — but what is
        # already in your own library comes first, and says so.
        local = db.all_(
            """select t.*, m.path, c.color as cover_color, c.sha256 as cover_sha,
                      (li.user_id is not null) as mine
                 from tracks t
                 left join media m on m.track_id=t.id and m.role='canonical'
                 left join covers c on c.id=t.cover_id
                 left join library_items li on li.track_id=t.id and li.user_id=%s
                where t.norm_title %% lower(%s) or t.title ilike %s
                order by mine desc, similarity(t.norm_title, lower(%s)) desc limit %s""",
            (user["id"], q, f"%{q}%", q, limit),
        )
        # Artists and albums, from your own library. Searching for a band and getting
        # only the four songs of theirs that happen to match the spelling is not a
        # search for the band — the way in to everything of theirs is their page.
        artists = db.all_(
            """select artist as name, count(*) as tracks
                 from (select unnest(t.artists) as artist
                         from tracks t
                         join library_items li
                           on li.track_id = t.id and li.user_id = %s) x
                where artist ilike %s
                group by artist
                order by (lower(artist) = lower(%s)) desc, count(*) desc
                limit 6""",
            (user["id"], f"%{q}%", q),
        )
        albums = db.all_(
            """select t.album as name,
                      coalesce(t.artists[1], 'Unknown artist') as artist,
                      count(*) as tracks,
                      max(t.id) filter (where t.cover_id is not null) as cover_track_id
                 from tracks t
                 join library_items li on li.track_id = t.id and li.user_id = %s
                where t.album ilike %s
                group by t.album, coalesce(t.artists[1], 'Unknown artist')
                order by (lower(t.album) = lower(%s)) desc, count(*) desc
                limit 6""",
            (user["id"], f"%{q}%", q),
        )

        out = {"local": [{**catalog.public(t), "mine": t["mine"]} for t in local],
               "artists": artists,
               "albums": [
                   {**a, "cover_url": f"/tracks/{a['cover_track_id']}/cover"
                    if a["cover_track_id"] else None}
                   for a in albums
               ],
               "remote": []}
        if remote:
            have = {t.get("provider_id") for t in db.all_(
                "select provider_id from track_sources where provider='ytmusic'")}
            hits = []
            try:
                found = ytm.search_songs(q, limit=min(limit, 10))
            except ytm.Unavailable as e:
                # YouTube answers a datacenter address with a challenge page often
                # enough that this cannot be an error: the library is right here and
                # searching it must keep working when the outside world will not talk.
                logging.getLogger("muse").warning("remote search failed: %s", e)
                out["remote_error"] = "YouTube would not answer just now"
                found = []
            for r in found:
                thumb = ytm.thumbnail_url(r.get("raw") or {})
                hits.append({
                    **{k: v for k, v in r.items() if k != "raw"},
                    "known": r["video_id"] in have,
                    # A result list of grey squares is not a search result list.
                    "cover_url": (f"/art/remote?u={quote(thumb, safe='')}"
                                  if thumb else None),
                })
            out["remote"] = hits
        return out

    @app.post("/tracks/resolve")
    def resolve(request: Request, body: dict, user: dict = Depends(current_user)):
        if not resolve_limit.allow(str(user["device_id"])):
            raise HTTPException(429, "slow down")
        video_id, query = body.get("video_id"), body.get("query")
        if not video_id and not query:
            raise HTTPException(400, "video_id or query required")

        if not video_id:
            try:
                hits = ytm.search_songs(query, limit=8)
            except ytm.Unavailable as e:
                # Not our failure and not the caller's: say so, rather than answering
                # a search with a stack trace.
                raise HTTPException(503, f"YouTube would not answer just now: {e}")
            if not hits:
                raise HTTPException(404, f"nothing on YouTube Music for {query!r}")
            # The first hit for a name is not the same thing as that song. For anything
            # the search is bad at — a German title, a small label, a word that reads
            # as an English one — it is a different record entirely, and queueing it
            # silently is worse than saying no.
            meta, confidence, _ = match.best(
                {"title": body.get("title") or query,
                 "artists": body.get("artists") or [],
                 "duration_ms": body.get("duration_ms")},
                hits)
            if not meta or confidence < match.AUTO_ACCEPT:
                # Nothing to compare against — a bare query with no artist — is the one
                # case where the first hit is all there is to go on.
                if body.get("title") or body.get("artists"):
                    raise HTTPException(
                        404,
                        f"nothing on YouTube Music that matches {query!r} closely "
                        f"enough to add without guessing")
                meta = hits[0]
            video_id = meta["video_id"]
        else:
            meta = None

        # 1. cache check — before anything touches the network
        cached = catalog.find_by_video_id(video_id)
        if cached:
            if cached["state"] == "failed":       # retry a previously failed ingest
                cached = catalog.retry(cached["id"], video_id)
            elif cached["state"] != "ready":
                # Asking for it again means you are waiting on it: move it forward.
                jobs.promote(cached["id"])
            # Asking for a song is how it becomes yours. The catalog is shared, so
            # somebody else having fetched it first must not leave it out of your
            # library — and until this, a track that was only ever downloaded (never
            # put in a queue or a playlist, which is what the triggers watch) belonged
            # to nobody and showed up under nobody's Library.
            catalog.remember(user["id"], cached["id"])
            return catalog.public(cached)

        try:
            meta = meta or ytm.song(video_id)
        except ytm.Unavailable:
            meta = None            # the id is enough to queue it; the title fills in later
        meta = meta or {"video_id": video_id, "title": video_id, "artists": [],
                        "album": None, "duration_ms": None, "raw": {}}
        meta["video_id"] = video_id
        created = catalog.create_from_ytm(meta, discovered_via=catalog.VIA_USER)
        catalog.remember(user["id"], created["id"])
        return JSONResponse(catalog.public(created), status_code=202)

    @app.get("/tracks/{track_id}")
    def get_track(track_id: int, user: dict = Depends(current_user)):
        t = catalog.track_row(track_id)
        if not t:
            raise HTTPException(404, "no such track")
        return catalog.public(t)

    # Thumbnails for things not in the library yet come from Google's image hosts.
    # Proxied rather than linked: it keeps the browser on one origin (no CORS), it
    # authenticates like everything else, and the results are cached on disk so
    # scrolling a result list twice costs nothing.
    # Google serves this artwork from several interchangeable hosts; the allowlist has
    # to cover the ones actually used, not the one that appeared in a doc example.
    _REMOTE_ART_HOSTS = (
        "lh3.googleusercontent.com",
        "yt3.googleusercontent.com",
        "yt3.ggpht.com",
        "i.ytimg.com",
        "i9.ytimg.com",
        # The other three services the search reaches. A result list of grey squares is
        # not a result list, and every one of these serves its art from one host.
        "i.scdn.co",                              # Spotify
        "mosaic.scdn.co",                         # Spotify, for a playlist's four-up
        "i1.sndcdn.com",                          # SoundCloud
        "f4.bcbits.com",                          # Bandcamp
    )

    def _by_token_or_key(authorization: str | None, k: str | None) -> dict:
        """Who is asking, for the things a browser fetches without being able to set a
        header — audio elements, <img>. Either the app's bearer token or a stream key
        signed for this listener."""
        user = None
        if authorization and authorization.lower().startswith("bearer "):
            user = auth.user_for_token(authorization.split(" ", 1)[1].strip())
        if user is None and k:
            user = auth.user_for_stream_key(k, cfg.worker_secret)
        if user is None:
            raise HTTPException(401, "missing bearer token or stream key")
        return user

    @app.get("/art/remote")
    def remote_art(u: str, k: str | None = None,
                   authorization: Annotated[str | None, Header()] = None):
        _by_token_or_key(authorization, k)

        parsed = urlparse(u)
        if parsed.scheme != "https" or parsed.hostname not in _REMOTE_ART_HOSTS:
            # An open proxy is a liability; this one only fetches album art.
            raise HTTPException(400, "not an allowed image host")

        cached = cfg.data_dir / "remote-art" / f"{hashlib.sha256(u.encode()).hexdigest()}.jpg"
        if not cached.exists():
            try:
                r = httpx.get(u, timeout=15, follow_redirects=True,
                              headers={"User-Agent": "muse/0.1"})
            except httpx.HTTPError:
                raise HTTPException(502, "could not fetch that image")
            if r.status_code != 200 or not r.headers.get("content-type", "").startswith("image/"):
                raise HTTPException(404, "no image there")
            cached.parent.mkdir(parents=True, exist_ok=True)
            cached.write_bytes(r.content)
        return Response(
            content=cached.read_bytes(),
            media_type="image/jpeg",
            headers={"Cache-Control": "private, max-age=604800"},
        )

    @app.get("/tracks/{track_id}/cover")
    def cover(track_id: int, request: Request, size: str = "lg", k: str | None = None,
              style: str = "flat", label: float | None = None,
              authorization: Annotated[str | None, Header()] = None):
        """An <img> cannot send an Authorization header either, so covers accept the
        same signed key as audio."""
        _by_token_or_key(authorization, k)

        row = db.one(
            """select c.path, c.sha256, c.color from tracks t join covers c on c.id=t.cover_id
                where t.id=%s""",
            (track_id,),
        )
        if not row:
            raise HTTPException(404, "no cover for that track")

        if style in sleeve.PARTS:
            # The record, not the file: the whole thing, or the jacket and disc apart so
            # the player can animate them. Rendered once per cover; see sleeve.py.
            colour = (row["color"] or "#8a8a8a").lstrip("#")
            rgb = tuple(int(colour[i:i + 2], 16) for i in (0, 2, 4))
            # How big the picture in the middle of the record is, where that is a
            # thing the person looking at it has an opinion about.
            face = sleeve.label_size(label) if style == "disc" and label else None
            sleeve.build(cfg.cover_dir, pathlib.Path(row["path"]), row["sha256"], rgb,
                         part=style, label=face)
            return _range_response(
                sleeve.path_for(cfg.cover_dir, row["sha256"],
                                "sm" if size == "sm" else "lg", part=style,
                                label=face),
                request,
                etag=f"{row['sha256']}-{style}-{size}"
                     f"{f'-l{face}' if face else ''}-v{sleeve.VERSION}")

        path = pathlib.Path(row["path"])
        if size == "sm":
            small = path.with_name(f"{row['sha256']}_sm.jpg")
            if small.exists():
                path = small
        return _range_response(path, request, etag=f"{row['sha256']}-{size}")

    @app.get("/tracks/{track_id}/stream")
    def stream(track_id: int, request: Request, k: str | None = None,
               authorization: Annotated[str | None, Header()] = None):
        # Either a bearer token (app) or a signed stream key (browser audio element).
        _by_token_or_key(authorization, k)

        t = catalog.track_row(track_id)
        if not t or not t.get("path"):
            raise HTTPException(404, "not ready" if t else "no such track")
        return _range_response(pathlib.Path(t["path"]), request, etag=t["sha256"])

    @app.get("/tracks/{track_id}/stem/{name}")
    def stem(track_id: int, name: str, request: Request, k: str | None = None,
             soon: bool = False,
             authorization: Annotated[str | None, Header()] = None):
        """A part of a record — its drums, the music without them, the record without
        its voice, or the voice alone — for a deck in the booth to play instead of the
        record itself. Made by a computer in the pool (pool.py) and kept here for all.
        [soon]: asked ahead of time (the automix looking down its queue), not for a
        record going on a deck now — queued behind those.

        Not made yet: the record is queued for the pool, and the asking is answered
        with "not yet, come back" — 202 and a Retry-After, no body."""
        who = _by_token_or_key(authorization, k)

        t = catalog.track_row(track_id)
        if not t or not t.get("path"):
            raise HTTPException(404, "not ready" if t else "no such track")
        if name not in pool.PARTS:
            raise HTTPException(404, f"a record has no {name}")
        if (t.get("duration_ms") or 0) > pool.UP_TO_S * 1000:
            raise HTTPException(
                404, f"too long to take apart (over {pool.UP_TO_S // 60} minutes)")
        path = pool.part_here(t["sha256"], name)
        if path is None:
            asked_by = who.get("device_id") if isinstance(who, dict) else None
            if pool.want_split(track_id, asked_by=asked_by,
                               priority=jobs.PRIORITY_QUEUE if soon else jobs.PRIORITY_NOW
                               ) is not None:
                publish("pool", {})
            return Response(status_code=202,
                            headers={"Retry-After": "10", "Cache-Control": "no-store"})
        return _range_response(path, request,
                               etag=f"{t['sha256']}-{name}-v{pool.PARTS_VERSION}")

    # ---------------- events ----------------
    @app.get("/events")
    async def events(user: dict = Depends(current_user)):
        q: asyncio.Queue = asyncio.Queue()
        who = (user["id"], q)
        _subscribers.add(who)

        async def gen():
            try:
                yield "event: hello\ndata: {}\n\n"
                while True:
                    try:
                        yield await asyncio.wait_for(q.get(), timeout=20)
                    except asyncio.TimeoutError:
                        yield ": keepalive\n\n"
            finally:
                _subscribers.discard(who)

        return StreamingResponse(gen(), media_type="text/event-stream",
                                 headers={"Cache-Control": "no-store", "X-Accel-Buffering": "no"})

    # ---------------- worker protocol ----------------
    # Somebody's computer may only touch the jobs it is holding. The house's own
    # downloader is trusted with all of them, as it always was.
    def _holds(job_id: int, device: dict | None) -> None:
        if device is None:
            return
        row = db.one("select leased_by, state from jobs where id=%s", (job_id,))
        if not row or row["leased_by"] != device["worker"]:
            raise HTTPException(403, "that job is not this device's")

    def _is_a_song(path: pathlib.Path) -> str | None:
        """Whether ffprobe can find a sound in it. What a device hands in is served to
        everybody as the song, so it has to at least be one: a file that is not audio
        would go out to every phone in the house as if it were."""
        try:
            out = subprocess.run(
                ["ffprobe", "-v", "error", "-show_entries",
                 "stream=codec_type:format=duration", "-of", "default=nw=1", str(path)],
                capture_output=True, text=True, timeout=60)
        except (OSError, subprocess.TimeoutExpired) as e:
            return f"could not look at it: {e}"
        if out.returncode != 0 or "codec_type=audio" not in out.stdout:
            return "not an audio file"
        m = re.search(r"duration=([\d.]+)", out.stdout)
        if not m or float(m.group(1)) < 0.5:
            return "no sound in it"
        return None

    def _number(info: dict, key: str, kind):
        """A number out of what a device said, or None; never something that the
        database would refuse and turn into a stack trace."""
        v = info.get(key)
        if v is None or isinstance(v, bool):
            return None
        try:
            v = kind(v)
        except (TypeError, ValueError):
            return None
        # Inside what the column holds; NaN and infinity are not numbers to it either.
        return v if v == v and abs(v) < 2**31 else None

    @app.post("/internal/jobs/lease")
    def lease(body: dict, device: dict | None = Depends(worker_auth)):
        # A device works under its own name, whatever it says its name is, and on the
        # pool's two kinds of work and no other.
        kind = body.get("kind", "ingest")
        if device is not None and kind not in ("ingest", "split"):
            raise HTTPException(403, "a computer in the pool fetches and splits, no more")
        strong = True
        if kind == "split":
            # Songs in the playlists marked to be taken apart, topped up now and then.
            pool.auto_split()
        if device is not None:
            # What it says about itself — its card, its switches — kept for the pool
            # screen, and the card decides who is handed a split first.
            if isinstance(body.get("pool"), dict):
                pool.report(device["id"], body["pool"])
            strong = pool.strong(device["id"])
        leased = jobs.lease_wait(
            device["worker"] if device else body.get("worker", "anon"),
            kind,
            int(body.get("limit", 1)),
            wait_seconds=float(body.get("wait", 0)),
            busy=int(body["busy"]) if body.get("busy") is not None else None,
            max_priority=(int(body["max_priority"])
                          if body.get("max_priority") is not None else None),
            strong=strong,
            device_id=device["id"] if device else None,
        )
        if leased and kind == "split":
            publish("pool", {})
        for j in leased:
            if kind != "ingest":
                continue
            if tid := j["payload"].get("track_id"):
                publish("track_progress",
                        {"track_id": tid, **progress.update(tid, "queued")})
        return {"jobs": [{"id": j["id"], "kind": j["kind"], "payload": j["payload"],
                          "attempts": j["attempts"], "priority": j["priority"],
                          # Passed through so the worker can say what it is working
                          # on, and so tests can assert on ordering.
                          "batch_id": j.get("batch_id"),
                          "batch_label": j.get("batch_label")} for j in leased]}

    @app.post("/internal/jobs/claim")
    def claim(body: dict, device: dict | None = Depends(worker_auth)):
        """A computer taking on, now, the song or the split its own person asked for,
        rather than leaving it to whoever in the pool is free: the song is then on the
        disk of the one who wanted it the moment it arrives. Queued first where it is
        not queued yet. Answers the job, or no job where there is nothing to do — it
        is done, or another computer already has it."""
        if device is None:
            raise HTTPException(403, "claiming is for a computer in the pool")
        kind = body.get("kind")
        try:
            track_id = int(body["track_id"])
        except (KeyError, TypeError, ValueError):
            raise HTTPException(400, "which track, as a number")
        t = catalog.track_row(track_id)
        if not t:
            raise HTTPException(404, "no such track")
        if kind == "split":
            if pool.want_split(track_id, asked_by=device["id"]) is None:
                return {"job": None, "parts": pool.parts_of(t.get("sha256") or "")}
        elif kind == "ingest":
            if t.get("state") == "ready":
                return {"job": None, "ready": True}
        else:
            raise HTTPException(400, "kind is ingest or split")
        job = jobs.claim(device["worker"], kind, track_id)
        if job is None:
            return {"job": None}
        if kind == "ingest":
            publish("track_progress",
                    {"track_id": track_id, **progress.update(track_id, "queued")})
        publish("pool", {})
        return {"job": {"id": job["id"], "kind": job["kind"], "payload": job["payload"],
                        "attempts": job["attempts"], "priority": job["priority"],
                        "batch_id": job.get("batch_id"),
                        "batch_label": job.get("batch_label")}}

    @app.post("/internal/jobs/{job_id}/parts")
    async def parts_in(job_id: int, request: Request,
                       device: dict | None = Depends(worker_auth)):
        """A split handed in: every part of the record the computer made, at once. Each
        has to be a sound as long as the record, near enough; they are kept for every
        other computer and phone (pool.py)."""
        _holds(job_id, device)
        job = db.one("select kind, payload from jobs where id=%s", (job_id,))
        if not job or job["kind"] != "split":
            raise HTTPException(404, "no such split")
        track_id = int(job["payload"]["track_id"])
        t = catalog.track_row(track_id)
        if not t or not t.get("sha256"):
            raise HTTPException(404, "no such track")
        form = await request.form()
        try:
            meta = json.loads(form.get("meta") or "{}")
        except ValueError:
            meta = {}
        kept = []
        work = cfg.data_dir / "parts" / "incoming"
        work.mkdir(parents=True, exist_ok=True)
        for name in pool.PARTS:
            up = form.get(name)
            if up is None or not hasattr(up, "file"):
                continue
            tmp = work / f"{job_id}-{name}{'.opus' if name == 'stems' else '.m4a'}"
            size = 0
            with tmp.open("wb") as out:
                while chunk := await up.read(1 << 20):
                    size += len(chunk)
                    if size > DEVICE_UPLOAD_LIMIT:
                        out.close()
                        tmp.unlink(missing_ok=True)
                        raise HTTPException(413, "too large to be a part")
                    out.write(chunk)
            if why := _is_a_song(tmp):
                tmp.unlink(missing_ok=True)
                raise HTTPException(400, f"{name} is not a part: {why}")
            pool.keep_part(cfg.data_dir, t["sha256"], name, tmp,
                           device["id"] if device else None,
                           _number(meta, "seconds", float))
            kept.append(name)
        if not kept:
            raise HTTPException(400, "no parts in that")
        if set(pool.parts_of(t["sha256"])) >= set(pool.PARTS):
            jobs.finish(job_id)
        pool.split_done(track_id)
        publish("parts_ready", {"track_id": track_id, "parts": kept})
        publish("pool", {})
        return {"ok": True, "parts": kept}

    @app.post("/internal/jobs/{job_id}/release")
    def release_job(job_id: int, body: dict | None = None,
                    device: dict | None = Depends(worker_auth)):
        """A worker shutting down gives back what it will not finish."""
        _holds(job_id, device)
        jobs.release(job_id)
        if body and (tid := body.get("track_id")):
            progress.clear(int(tid))
            pool.split_done(int(tid))
        return {"released": job_id}

    @app.post("/internal/jobs/{job_id}/progress")
    def report_progress(job_id: int, body: dict,
                        device: dict | None = Depends(worker_auth)):
        _holds(job_id, device)
        track_id = int(body["track_id"])
        if body.get("kind") == "split":
            entry = pool.split_progress(track_id, body.get("stage", "separating"),
                                        body.get("percent"))
            publish("split_progress", {"track_id": track_id, **entry})
            return {"ok": True}
        entry = progress.update(track_id, body.get("stage", "downloading"),
                                body.get("percent"), body.get("speed"))
        publish("track_progress", {"track_id": track_id, **entry})
        return {"ok": True}

    @app.post("/internal/jobs/{job_id}/complete")
    def complete(job_id: int, meta: str = Form(...), audio: UploadFile = None,
                 device: dict | None = Depends(worker_auth)):
        _holds(job_id, device)
        try:
            info = json.loads(meta)
            track_id = int(info["track_id"])
        except (ValueError, TypeError, KeyError):
            raise HTTPException(400, "meta must say which track, as a number")
        if audio is None:
            raise HTTPException(400, "audio file required")
        if device is not None:
            # The song it was given, and no other: a device says which track its upload
            # is for, and what it says has to be what the job says.
            job = db.one("select payload from jobs where id=%s", (job_id,))
            if int((job or {}).get("payload", {}).get("track_id") or -1) != track_id:
                raise HTTPException(403, "that is not the song this job was for")
        # The house's own downloader is trusted with what it hands in; somebody's
        # computer is held to a size, counted as it comes in rather than read off a
        # header it wrote itself, and to the file being a sound at all.
        try:
            digest, path, size = storage.store_stream(
                cfg.audio_dir, audio.file, ".m4a",
                limit=DEVICE_UPLOAD_LIMIT if device is not None else None,
                accept=_is_a_song if device is not None else None)
        except storage.TooBig:
            raise HTTPException(413, "too large to be a song")
        except storage.NotAccepted as e:
            raise HTTPException(400, f"that is not a song: {e}")
        codec = info.get("codec")
        db.run(
            """insert into media(track_id,sha256,codec,bitrate,bytes,path)
               values(%s,%s,%s,%s,%s,%s) on conflict (track_id,sha256) do nothing""",
            (track_id, digest, str(codec)[:32] if codec is not None else None,
             _number(info, "bitrate", int), size, str(path)),
        )
        db.run(
            """update tracks set state='ready', fail_reason=null,
                      duration_ms=coalesce(%s,duration_ms),
                      loudness_lufs=%s, gain_db=%s
                where id=%s""",
            (_number(info, "duration_ms", int), _number(info, "loudness_lufs", float),
             _number(info, "gain_db", float), track_id),
        )
        jobs.finish(job_id)
        progress.clear(track_id)
        # Artwork and canonical metadata are a separate concern from getting the audio,
        # and they must never hold up playback.
        jobs.enqueue("meta", {"track_id": track_id})
        publish("track_ready", {"track_id": track_id, "bytes": size})
        # A song in a playlist marked to be taken apart: queued for the pool now.
        if db.one("""select 1 from playlist_items i join playlists p on p.id=i.playlist_id
                      where i.track_id=%s and p.auto_split limit 1""", (track_id,)):
            pool.want_split(track_id, priority=jobs.PRIORITY_BULK)
        return {"ok": True, "sha256": digest, "bytes": size}

    @app.post("/internal/jobs/{job_id}/fail")
    def fail(job_id: int, body: dict, device: dict | None = Depends(worker_auth)):
        _holds(job_id, device)
        raw = body.get("reason", "")
        # A split that failed says nothing about the song: it stays playable, and the
        # split is tried again by somebody else (or said on the pool screen).
        split = db.one("select payload from jobs where id=%s and kind='split'", (job_id,))
        if split:
            jobs.fail(job_id, raw or "the separator failed",
                      bool(body.get("retryable", True)))
            pool.split_done(int(split["payload"]["track_id"]))
            publish("pool", {})
            return {"ok": True}
        # Named by where the song actually lives, not by where the worker happens to
        # fetch from — see failures.classify.
        heard_from = db.one("select source from tracks where id=%s",
                            (body.get("track_id"),)) if body.get("track_id") else None
        code, message, retryable = failures.classify(
            raw, (heard_from or {}).get("source"))
        # The worker's own judgement can only make a failure *less* retryable.
        retryable = retryable and bool(body.get("retryable", True))
        jobs.fail(job_id, raw or message, retryable)

        if tid := body.get("track_id"):
            progress.clear(tid)
            attempts = db.one("select attempts from jobs where id=%s", (job_id,))
            will_retry = retryable and (attempts or {}).get("attempts", 99) < jobs.MAX_ATTEMPTS
            db.run(
                """update tracks set state=%s, fail_reason=%s, fail_code=%s where id=%s""",
                ("pending" if will_retry else "failed", message, code, tid),
            )
            # A copy that is gone stays gone. Marked rather than deleted — it is still
            # the reason the track is here — but never chosen again, so asking for the
            # song reaches for a copy that might work instead of the one known not to.
            #
            # Read off the job rather than out of the request. The worker reports what
            # went wrong and which track it was, and has never sent the video id — so
            # this looked for one that was never there and marked nothing, and one
            # track failed on the same dead id ten times in a row. The server queued
            # the job; it knows perfectly well what it asked for.
            if code in failures.GONE:
                job = db.one("select payload from jobs where id=%s", (job_id,))
                video = ((job or {}).get("payload") or {}).get("video_id")
                if video:
                    db.run("""update track_sources
                                 set raw = coalesce(raw,'{}'::jsonb) || '{"dead": true}'
                               where track_id=%s and provider_id=%s""", (tid, video))
                # Nothing left that could work. A video being deleted says nothing
                # about the song, so go and look for another copy of it rather than
                # leaving somebody to notice and press a button — which is the whole
                # difference between "this isn't on YouTube any more" being true of a
                # video and being wrong about a song that plainly is.
                if jobs.best_source(int(tid)) is None:
                    jobs.enqueue("refind", {"track_id": int(tid)},
                                 priority=jobs.PRIORITY_BULK)
            publish("track_failed", {"track_id": tid, "reason": message, "code": code,
                                     "will_retry": will_retry})
        return {"ok": True, "code": code, "retryable": retryable}

    # ---------------- admin ----------------
    @app.get("/status")
    def status(user: dict = Depends(current_user)):
        """Is anything able to download right now? Without this the UI can only show a
        row spinning forever while the worker's machine is asleep."""
        worker = db.one(
            """select name, last_seen, extract(epoch from now()-last_seen) as age
                 from workers where name <> 'api-enrich'
                order by last_seen desc limit 1"""
        )
        pending = db.one(
            "select count(*) n from jobs where kind='ingest' and state in ('pending','leased')"
        )
        age = float(worker["age"]) if worker and worker["age"] is not None else None
        return {
            "ingest_worker": worker["name"] if worker else None,
            "ingest_online": age is not None and age < 90,
            "last_seen_seconds": age,
            "downloads_pending": pending["n"],
            "in_progress": progress.snapshot(),
            # How the records are being drawn. Covers are cached for a year and marked
            # immutable — correctly, because the artwork's own hash is in the URL — so
            # when the *renderer* changes there is nothing to make a client ask again.
            # Handing the number over lets the client put it in the URL, which is the
            # only thing that reaches every cache between here and the screen.
            "sleeve_version": sleeve.VERSION,
        }

    @app.get("/admin/storage")
    def storage_stats(user: dict = Depends(current_user)):
        agg = db.one("select count(*) n, coalesce(sum(bytes),0) b from media")
        covers = db.one("select count(*) n from tracks where cover_id is not null")
        states = db.all_("select state, count(*) n from tracks group by state")
        workers = db.all_("select name, last_seen, leased from workers order by last_seen desc")
        pending = db.one("select count(*) n from jobs where state in ('pending','leased')")
        return {
            "tracks": {r["state"]: r["n"] for r in states},
            "media_files": agg["n"],
            "bytes": int(agg["b"]),
            "gb": round(int(agg["b"]) / 1e9, 3),
            "covers": covers["n"],
            "jobs_outstanding": pending["n"],
            "workers": workers,
        }

    if cfg.cors_origins or cfg.cors_origin_regex:
        app.add_middleware(
            CORSMiddleware,
            allow_origins=list(cfg.cors_origins),
            allow_origin_regex=cfg.cors_origin_regex or None,
            allow_methods=["*"],
            allow_headers=["*"],
            # Range and the ETag are what let a player seek; without them exposed a
            # cross-origin audio element cannot scrub.
            expose_headers=["Content-Range", "Accept-Ranges", "ETag", "Content-Length"],
        )

    app.include_router(routes_accounts.router)
    app.include_router(routes_browse.router)
    app.include_router(routes_devices.router)
    app.include_router(routes_pool.router)
    app.include_router(routes_downloads.router)
    routes_jam.set_publisher(publish)
    routes_library.set_publisher(publish)
    app.include_router(routes_jam.router)
    app.include_router(routes_sources.router)
    app.include_router(routes_search.router)
    app.include_router(routes_scrobble.router)
    app.include_router(routes_social.router)
    app.include_router(routes_linked.router)
    app.include_router(routes_follows.router)
    app.include_router(routes_library.router)
    app.include_router(routes_marks.router)
    app.include_router(routes_sync.router)
    app.include_router(routes_spotify.router)
    app.include_router(routes_files.router)
    app.include_router(routes_play.router)
    return app


_RANGE = re.compile(r"bytes=(\d*)-(\d*)")


def _range_response(path: pathlib.Path, request: Request, etag: str | None = None) -> Response:
    """Range + ETag + immutable: content-addressed blobs never change."""
    if not path.exists():
        raise HTTPException(410, "blob missing on disk")
    size = path.stat().st_size
    media_type = mimetypes.guess_type(path.name)[0] or "audio/mp4"
    headers = {
        "Accept-Ranges": "bytes",
        "Cache-Control": "private, max-age=31536000, immutable",
    }
    if etag:
        headers["ETag"] = f'"{etag}"'
        if request.headers.get("if-none-match", "").strip('"') == etag:
            return Response(status_code=304, headers=headers)

    start, end = 0, size - 1
    status = 200
    if m := _RANGE.match(request.headers.get("range", "")):
        s, e = m.group(1), m.group(2)
        if s:
            start, end = int(s), (int(e) if e else size - 1)
        elif e:                       # suffix range: last N bytes
            start, end = max(0, size - int(e)), size - 1
        if start >= size or end < start:
            return Response(status_code=416, headers={**headers, "Content-Range": f"bytes */{size}"})
        end = min(end, size - 1)
        status = 206
        headers["Content-Range"] = f"bytes {start}-{end}/{size}"

    length = end - start + 1
    headers["Content-Length"] = str(length)

    def body():
        with path.open("rb") as f:
            f.seek(start)
            left = length
            while left > 0 and (chunk := f.read(min(1 << 18, left))):
                left -= len(chunk)
                yield chunk

    return StreamingResponse(body(), status_code=status, media_type=media_type, headers=headers)
