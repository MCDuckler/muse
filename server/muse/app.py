from __future__ import annotations

import asyncio
import json
import mimetypes
import pathlib
import re
from contextlib import asynccontextmanager
from typing import Annotated

from fastapi import Depends, FastAPI, Form, Header, HTTPException, Request, UploadFile
from fastapi.responses import JSONResponse, Response, StreamingResponse

from . import auth, config, db, jobs, storage, ytm

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


# ---- auth dependency ----
def current_user(authorization: Annotated[str | None, Header()] = None) -> dict:
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(401, "missing bearer token")
    user = auth.user_for_token(authorization.split(" ", 1)[1].strip())
    if not user:
        raise HTTPException(401, "unknown or revoked token")
    return user


def worker_auth(x_worker_secret: Annotated[str | None, Header()] = None) -> None:
    if not x_worker_secret or x_worker_secret != cfg.worker_secret:
        raise HTTPException(401, "bad worker secret")


# ---- track helpers ----
def _track_row(track_id: int) -> dict | None:
    return db.one(
        """select t.*, m.bytes, m.path, m.sha256, m.codec, m.bitrate,
                  s.provider, s.provider_id
             from tracks t
             left join media m on m.track_id=t.id
             left join track_sources s on s.track_id=t.id
            where t.id=%s""",
        (track_id,),
    )


def _public(t: dict) -> dict:
    return {
        "id": t["id"],
        "title": t["title"],
        "artists": t["artists"],
        "album": t["album"],
        "duration_ms": t["duration_ms"],
        "state": t["state"],
        "fail_reason": t["fail_reason"],
        "source": t["source"],
        "gain_db": t["gain_db"],
        "loudness_lufs": t["loudness_lufs"],
        "bytes": t.get("bytes"),
        "provider_id": t.get("provider_id"),
        "stream_url": f"/tracks/{t['id']}/stream" if t.get("path") else None,
    }


def create_app(configuration: config.Config) -> FastAPI:
    global cfg
    cfg = configuration
    db.init(cfg.dsn)
    for u in cfg.users:
        auth.ensure_user(u.name)

    @asynccontextmanager
    async def lifespan(_: FastAPI):
        global _loop
        _loop = asyncio.get_running_loop()
        yield
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
        if not entry or not auth.verify_password(entry.password_hash, password):
            raise HTTPException(401, "wrong user or password")
        uid = auth.ensure_user(user)
        return {"token": auth.issue_token(uid, device, platform), "user": user}

    @app.get("/me")
    def me(user: dict = Depends(current_user)):
        return {"user": user["name"], "device": user["device_name"]}

    # ---------------- catalog ----------------
    @app.get("/search")
    def search(q: str, limit: int = 20, remote: bool = True, user: dict = Depends(current_user)):
        local = db.all_(
            """select t.*, m.path from tracks t left join media m on m.track_id=t.id
                where t.norm_title %% lower(%s) or t.title ilike %s
                order by similarity(t.norm_title, lower(%s)) desc limit %s""",
            (q, f"%{q}%", q, limit),
        )
        out = {"local": [_public(t) for t in local], "remote": []}
        if remote:
            have = {t.get("provider_id") for t in db.all_(
                "select provider_id from track_sources where provider='ytmusic'")}
            out["remote"] = [
                {**r, "raw": None, "known": r["video_id"] in have}
                for r in ytm.search_songs(q, limit=min(limit, 10))
            ]
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
        existing = db.one(
            "select track_id from track_sources where provider='ytmusic' and provider_id=%s",
            (video_id,),
        )
        if existing:
            t = _track_row(existing["track_id"])
            if t["state"] == "failed":       # retry a previously failed ingest
                db.run("update tracks set state='pending', fail_reason=null where id=%s", (t["id"],))
                jobs.enqueue("ingest", {"track_id": t["id"], "video_id": video_id})
                t = _track_row(t["id"])
            return _public(t)

        meta = meta or ytm.song(video_id) or {"video_id": video_id, "title": video_id,
                                              "artists": [], "album": None, "duration_ms": None,
                                              "raw": {}}
        row = db.one(
            """insert into tracks(title,artists,album,duration_ms,source,state)
               values(%s,%s,%s,%s,'youtube','pending') returning id""",
            (meta["title"], meta["artists"], meta["album"], meta["duration_ms"]),
        )
        db.run(
            "insert into track_sources(track_id,provider,provider_id,raw) values(%s,'ytmusic',%s,%s)",
            (row["id"], video_id, json.dumps(meta.get("raw") or {})),
        )
        jobs.enqueue("ingest", {"track_id": row["id"], "video_id": video_id})
        t = _track_row(row["id"])
        return JSONResponse(_public(t), status_code=202)

    @app.get("/tracks/{track_id}")
    def get_track(track_id: int, user: dict = Depends(current_user)):
        t = _track_row(track_id)
        if not t:
            raise HTTPException(404, "no such track")
        return _public(t)

    @app.get("/tracks/{track_id}/stream")
    def stream(track_id: int, request: Request, user: dict = Depends(current_user)):
        t = _track_row(track_id)
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
        leased = jobs.lease(body.get("worker", "anon"), body.get("kind", "ingest"),
                            int(body.get("limit", 1)))
        return {"jobs": [{"id": j["id"], "kind": j["kind"], "payload": j["payload"],
                          "attempts": j["attempts"]} for j in leased]}

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
        publish("track_ready", {"track_id": track_id, "bytes": size})
        return {"ok": True, "sha256": digest, "bytes": size}

    @app.post("/internal/jobs/{job_id}/fail", dependencies=[Depends(worker_auth)])
    def fail(job_id: int, body: dict):
        reason = body.get("reason", "unknown")
        jobs.fail(job_id, reason, bool(body.get("retryable", True)))
        if tid := body.get("track_id"):
            db.run("update tracks set state='failed', fail_reason=%s where id=%s", (reason[:500], tid))
            publish("track_failed", {"track_id": tid, "reason": reason[:200]})
        return {"ok": True}

    # ---------------- admin ----------------
    @app.get("/admin/storage")
    def storage_stats(user: dict = Depends(current_user)):
        agg = db.one("select count(*) n, coalesce(sum(bytes),0) b from media")
        states = db.all_("select state, count(*) n from tracks group by state")
        workers = db.all_("select name, last_seen, leased from workers order by last_seen desc")
        pending = db.one("select count(*) n from jobs where state in ('pending','leased')")
        return {
            "tracks": {r["state"]: r["n"] for r in states},
            "media_files": agg["n"],
            "bytes": int(agg["b"]),
            "gb": round(int(agg["b"]) / 1e9, 3),
            "jobs_outstanding": pending["n"],
            "workers": workers,
        }

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
