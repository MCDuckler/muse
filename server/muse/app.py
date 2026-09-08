from __future__ import annotations

import asyncio
import hashlib
import json
import mimetypes
import pathlib
import re
from contextlib import asynccontextmanager
from typing import Annotated
from urllib.parse import quote, urlparse

import httpx

from fastapi import (Body, Depends, FastAPI, Form, Header, HTTPException, Request,
                     UploadFile)
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse, Response, StreamingResponse

from . import (auth, catalog, config, db, enrich_worker, failures, jobs, progress,
               jam, routes_accounts, routes_browse, routes_downloads, routes_files,
               routes_jam,
               routes_library, routes_play, routes_spotify, routes_sync, sleeve,
               storage, ytm)
from . import deps
from .deps import current_user, worker_auth

cfg: config.Config = None  # set in create_app

# ---- in-process event bus (single API process for now; Postgres LISTEN when it grows) ----
_subscribers: set[asyncio.Queue] = set()
_loop: asyncio.AbstractEventLoop | None = None


def publish(event: str, data: dict) -> None:
    if _loop is None:
        return
    payload = f"event: {event}\ndata: {json.dumps(data)}\n\n"

    def _fan_out():
        for q in list(_subscribers):
            q.put_nowait(payload)

    _loop.call_soon_threadsafe(_fan_out)


def create_app(configuration: config.Config, start_workers: bool = False) -> FastAPI:
    global cfg
    cfg = configuration
    db.init(cfg.dsn)
    deps.set_config(cfg)
    for u in cfg.users:
        auth.ensure_user(u.name, pw_hash=u.password_hash)

    worker = (enrich_worker.EnrichWorker(cfg, publish=publish)
              if start_workers else None)

    @asynccontextmanager
    async def lifespan(_: FastAPI):
        global _loop
        _loop = asyncio.get_running_loop()
        if worker:
            worker.start()
        yield
        if worker:
            worker.stop()
        _loop = None

    app = FastAPI(title="muse", docs_url="/api-docs", lifespan=lifespan)
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
        return {"user": user["name"], "device": user["device_name"]}

    # ---------------- catalog ----------------
    @app.get("/search")
    def search(q: str, limit: int = 20, remote: bool = True, user: dict = Depends(current_user)):
        local = db.all_(
            """select t.*, m.path, c.color as cover_color, c.sha256 as cover_sha
                 from tracks t
                 left join media m on m.track_id=t.id and m.role='canonical'
                 left join covers c on c.id=t.cover_id
                where t.norm_title %% lower(%s) or t.title ilike %s
                order by similarity(t.norm_title, lower(%s)) desc limit %s""",
            (q, f"%{q}%", q, limit),
        )
        out = {"local": [catalog.public(t) for t in local], "remote": []}
        if remote:
            have = {t.get("provider_id") for t in db.all_(
                "select provider_id from track_sources where provider='ytmusic'")}
            hits = []
            for r in ytm.search_songs(q, limit=min(limit, 10)):
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
            hits = ytm.search_songs(query, limit=1)
            if not hits:
                raise HTTPException(404, f"nothing on YouTube Music for {query!r}")
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
            return catalog.public(cached)

        meta = meta or ytm.song(video_id) or {"video_id": video_id, "title": video_id,
                                              "artists": [], "album": None, "duration_ms": None,
                                              "raw": {}}
        meta["video_id"] = video_id
        created = catalog.create_from_ytm(meta, discovered_via=catalog.VIA_USER)
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
    )

    @app.get("/art/remote")
    def remote_art(u: str, k: str | None = None,
                   authorization: Annotated[str | None, Header()] = None):
        user = None
        if authorization and authorization.lower().startswith("bearer "):
            user = auth.user_for_token(authorization.split(" ", 1)[1].strip())
        if user is None and k:
            user = auth.user_for_stream_key(k, cfg.worker_secret)
        if user is None:
            raise HTTPException(401, "missing bearer token or stream key")

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
              style: str = "flat",
              authorization: Annotated[str | None, Header()] = None):
        """An <img> cannot send an Authorization header either, so covers accept the
        same signed key as audio."""
        user = None
        if authorization and authorization.lower().startswith("bearer "):
            user = auth.user_for_token(authorization.split(" ", 1)[1].strip())
        if user is None and k:
            user = auth.user_for_stream_key(k, cfg.worker_secret)
        if user is None:
            raise HTTPException(401, "missing bearer token or stream key")

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
            sleeve.build(cfg.cover_dir, pathlib.Path(row["path"]), row["sha256"], rgb,
                         part=style)
            return _range_response(
                sleeve.path_for(cfg.cover_dir, row["sha256"],
                                "sm" if size == "sm" else "lg", part=style),
                request, etag=f"{row['sha256']}-{style}-{size}")

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
        user = None
        if authorization and authorization.lower().startswith("bearer "):
            user = auth.user_for_token(authorization.split(" ", 1)[1].strip())
        if user is None and k:
            user = auth.user_for_stream_key(k, cfg.worker_secret)
        if user is None:
            raise HTTPException(401, "missing bearer token or stream key")

        t = catalog.track_row(track_id)
        if not t or not t.get("path"):
            raise HTTPException(404, "not ready" if t else "no such track")
        return _range_response(pathlib.Path(t["path"]), request, etag=t["sha256"])

    # ---------------- events ----------------
    @app.get("/events")
    async def events(user: dict = Depends(current_user)):
        q: asyncio.Queue = asyncio.Queue()
        _subscribers.add(q)

        async def gen():
            try:
                yield "event: hello\ndata: {}\n\n"
                while True:
                    try:
                        yield await asyncio.wait_for(q.get(), timeout=20)
                    except asyncio.TimeoutError:
                        yield ": keepalive\n\n"
            finally:
                _subscribers.discard(q)

        return StreamingResponse(gen(), media_type="text/event-stream",
                                 headers={"Cache-Control": "no-store", "X-Accel-Buffering": "no"})

    # ---------------- worker protocol ----------------
    @app.post("/internal/jobs/lease", dependencies=[Depends(worker_auth)])
    def lease(body: dict):
        leased = jobs.lease_wait(
            body.get("worker", "anon"),
            body.get("kind", "ingest"),
            int(body.get("limit", 1)),
            wait_seconds=float(body.get("wait", 0)),
            busy=int(body["busy"]) if body.get("busy") is not None else None,
            max_priority=(int(body["max_priority"])
                          if body.get("max_priority") is not None else None),
        )
        for j in leased:
            if tid := j["payload"].get("track_id"):
                publish("track_progress",
                        {"track_id": tid, **progress.update(tid, "queued")})
        return {"jobs": [{"id": j["id"], "kind": j["kind"], "payload": j["payload"],
                          "attempts": j["attempts"], "priority": j["priority"],
                          # Passed through so the worker can say what it is working
                          # on, and so tests can assert on ordering.
                          "batch_id": j.get("batch_id"),
                          "batch_label": j.get("batch_label")} for j in leased]}

    @app.post("/internal/jobs/{job_id}/release", dependencies=[Depends(worker_auth)])
    def release_job(job_id: int, body: dict | None = None):
        """A worker shutting down gives back what it will not finish."""
        jobs.release(job_id)
        if body and (tid := body.get("track_id")):
            progress.clear(int(tid))
        return {"released": job_id}

    @app.post("/internal/jobs/{job_id}/progress", dependencies=[Depends(worker_auth)])
    def report_progress(job_id: int, body: dict):
        track_id = int(body["track_id"])
        entry = progress.update(track_id, body.get("stage", "downloading"),
                                body.get("percent"), body.get("speed"))
        publish("track_progress", {"track_id": track_id, **entry})
        return {"ok": True}

    @app.post("/internal/jobs/{job_id}/complete", dependencies=[Depends(worker_auth)])
    def complete(job_id: int, meta: str = Form(...), audio: UploadFile = None):
        info = json.loads(meta)
        track_id = int(info["track_id"])
        if audio is None:
            raise HTTPException(400, "audio file required")
        digest, path, size = storage.store_stream(cfg.audio_dir, audio.file, ".m4a")
        db.run(
            """insert into media(track_id,sha256,codec,bitrate,bytes,path)
               values(%s,%s,%s,%s,%s,%s) on conflict (track_id,sha256) do nothing""",
            (track_id, digest, info.get("codec"), info.get("bitrate"), size, str(path)),
        )
        db.run(
            """update tracks set state='ready', fail_reason=null,
                      duration_ms=coalesce(%s,duration_ms),
                      loudness_lufs=%s, gain_db=%s
                where id=%s""",
            (info.get("duration_ms"), info.get("loudness_lufs"), info.get("gain_db"), track_id),
        )
        jobs.finish(job_id)
        progress.clear(track_id)
        # Artwork and canonical metadata are a separate concern from getting the audio,
        # and they must never hold up playback.
        jobs.enqueue("meta", {"track_id": track_id})
        publish("track_ready", {"track_id": track_id, "bytes": size})
        return {"ok": True, "sha256": digest, "bytes": size}

    @app.post("/internal/jobs/{job_id}/fail", dependencies=[Depends(worker_auth)])
    def fail(job_id: int, body: dict):
        raw = body.get("reason", "")
        code, message, retryable = failures.classify(raw)
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
    app.include_router(routes_downloads.router)
    routes_jam.set_publisher(publish)
    routes_library.set_publisher(publish)
    app.include_router(routes_jam.router)
    app.include_router(routes_library.router)
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
