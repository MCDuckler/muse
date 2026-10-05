"""A phone opening the door to YouTube for the server.

YouTube answers "where is this song's audio?" only when asked from a home or a mobile
connection, never from this datacenter (sources.py). The audio itself is another
matter: measured on 2026-10-04, this box could pull it from the address a home
connection was given about half the time, and got 403 the other half. So a phone does
not fetch anything. It keeps one WebSocket open, the server's own yt-dlp asks its
question *through* that phone, and then the server pulls the audio itself. The audio
only comes through the phone again when YouTube insists, and only for songs that
phone's person asked for.

That way everything that breaks when YouTube changes something stays here, where one
upgrade of yt-dlp mends every phone at once. The question costs the phone about 370 KB
and the song 4 MB.

Measured the same afternoon, the box was let pull the audio 0 times in 30, so most
songs do come through the phone. A phone that says it can ("pulls") is then sent the
address YouTube gave, fetches the song itself, plays it from its own disk at once and
hands the house its copy (pulled() below). That is one trip down and one up, not down,
up and down again.

Three parts:

- Exit: one connected phone. Each frame on its WebSocket belongs to a TCP connection
  the phone opened on the server's behalf, to YouTube's hosts and nowhere else. The
  phone keeps its own copy of that list.
- The proxy: an HTTP CONNECT proxy on loopback that yt-dlp is pointed at. The password
  in its Proxy-Authorization is a ticket, and the ticket names the exit.
- The runner: songs fetched through an exit. Resolve, pull, land.
"""
from __future__ import annotations

import asyncio
import base64
import collections
import ipaddress
import json
import logging
import pathlib
import re
import secrets
import shutil
import struct
import subprocess
import tempfile
import threading
import time
from concurrent.futures import ThreadPoolExecutor

from fastapi import (APIRouter, File, Form, Header, HTTPException, UploadFile, WebSocket,
                     WebSocketDisconnect)
from starlette.concurrency import run_in_threadpool

from . import audiofile, auth, db, jobs, landing, progress

log = logging.getLogger("muse.exits")

router = APIRouter()

# ------------------------------------------------------------------ the frames
#
# A frame is one binary WebSocket message: its type (1 byte), the stream it belongs to
# (4 bytes, big-endian), then the payload. Stream 0 is the conversation about the exit
# itself. app/lib/src/worker/exit_tunnel.dart is the other half and has to agree.
HELLO, OPEN, OPENED, REFUSED, DATA, CLOSE, CREDIT, PULL = range(8)
_HEAD = struct.Struct("!BI")

# How much one side may send on a stream before hearing it has arrived. Without a limit
# the faster side would queue a whole song in memory waiting for the slower one. The
# slower one is a phone's upload.
WINDOW = 256 * 1024
CHUNK = 64 * 1024
OPEN_TIMEOUT = 20.0
MAX_STREAMS = 6

# What a phone will connect to for the server: YouTube and nothing else. The phone's
# own copy of this list is the one that counts (exit_tunnel.dart). This copy only saves
# asking for something the phone would refuse anyway.
_ALLOWED = re.compile(
    r"^(?:[a-z0-9-]+\.)*(?:youtube\.com|googlevideo\.com|ytimg\.com"
    r"|youtubei\.googleapis\.com)$")


def allowed(host: str, port: int) -> bool:
    return port == 443 and bool(_ALLOWED.match(host.lower()))


def frame(kind: int, stream: int, payload: bytes = b"") -> bytes:
    return _HEAD.pack(kind, stream) + payload


class _Stream:
    """One TCP connection, with yt-dlp at this end and the phone at the other."""

    def __init__(self, sid: int, writer: asyncio.StreamWriter, ticket: Ticket | None):
        self.sid = sid
        self.writer = writer
        self.ticket = ticket
        self.opened: asyncio.Future = asyncio.get_running_loop().create_future()
        self.refused = ""
        self.credit = asyncio.Event()
        self.credit.set()
        self.unacked = 0
        self.closed = False


class Exit:
    """One phone with its door open."""

    def __init__(self, ws, device: dict, ip: str):
        self.ws = ws
        self.device_id: int = device["id"]
        self.user_id: int = device["user_id"]
        self.name: str = device.get("name") or ""
        self.owner: str = device.get("user") or ""
        self.ip = ip
        self.state: dict = {}
        self.since = time.time()
        # The loop its WebSocket lives on, for orders sent from the runner's threads.
        self.loop: asyncio.AbstractEventLoop | None = None
        self._streams: dict[int, _Stream] = {}
        self._next = 1
        self._send_lock = asyncio.Lock()
        # Read from the runner's threads, so a threading.Event, not an asyncio one.
        self.gone = threading.Event()
        self.lock = threading.Lock()
        self.wanted: collections.deque[int] = collections.deque()
        self.working: set[int] = set()
        self.tried: dict[int, float] = {}

    # -- frames out
    async def send(self, kind: int, stream: int, payload: bytes = b"") -> None:
        async with self._send_lock:
            await self.ws.send_bytes(frame(kind, stream, payload))

    # -- frames in
    async def take(self, data: bytes) -> None:
        if len(data) < _HEAD.size:
            return
        kind, sid = _HEAD.unpack_from(data)
        payload = data[_HEAD.size:]
        if sid == 0:
            if kind == HELLO:
                try:
                    said = json.loads(payload or b"{}")
                except ValueError:
                    return
                if isinstance(said, dict):
                    self.state.update({k: said[k] for k in _SAID if k in said})
            return
        st = self._streams.get(sid)
        if st is None:
            return
        if kind == OPENED:
            if not st.opened.done():
                st.opened.set_result(True)
        elif kind == REFUSED:
            st.refused = payload.decode(errors="replace")[:200] or "refused"
            if not st.opened.done():
                st.opened.set_result(False)
        elif kind == DATA:
            if st.closed:
                return
            try:
                st.writer.write(payload)
                await st.writer.drain()
            except (ConnectionError, OSError):
                await self.end(sid, tell=True)
                return
            if st.ticket:
                st.ticket.down += len(payload)
            await self.send(CREDIT, sid, struct.pack("!I", len(payload)))
        elif kind == CREDIT and len(payload) >= 4:
            (n,) = struct.unpack_from("!I", payload)
            st.unacked = max(0, st.unacked - n)
            if st.unacked < WINDOW:
                st.credit.set()
        elif kind == CLOSE:
            await self.end(sid, tell=False)

    # -- streams
    async def open(self, host: str, port: int, writer: asyncio.StreamWriter,
                   ticket: Ticket | None = None) -> _Stream:
        if self.gone.is_set():
            raise Refused("the phone has gone")
        if len(self._streams) >= MAX_STREAMS:
            raise Refused("too many at once")
        sid = self._next
        self._next += 1
        st = self._streams[sid] = _Stream(sid, writer, ticket)
        await self.send(OPEN, sid, struct.pack("!H", port) + host.encode())
        try:
            ok = await asyncio.wait_for(asyncio.shield(st.opened), OPEN_TIMEOUT)
        except asyncio.TimeoutError:
            await self.end(sid, tell=True)
            raise Refused("the phone did not answer")
        if not ok:
            self._streams.pop(sid, None)
            raise Refused(st.refused)
        return st

    async def push(self, st: _Stream, chunk: bytes) -> bool:
        """yt-dlp's bytes, out to the phone: no more than a window ahead of it."""
        while st.unacked >= WINDOW and not st.closed:
            st.credit.clear()
            await st.credit.wait()
        if st.closed:
            return False
        await self.send(DATA, st.sid, chunk)
        st.unacked += len(chunk)
        if st.ticket:
            st.ticket.up += len(chunk)
        return True

    async def end(self, sid: int, tell: bool) -> None:
        st = self._streams.pop(sid, None)
        if st is None:
            return
        st.closed = True
        st.credit.set()
        if not st.opened.done():
            st.opened.set_result(False)
        try:
            st.writer.close()
        except Exception:
            pass
        if tell and not self.gone.is_set():
            try:
                await self.send(CLOSE, sid)
            except Exception:
                pass

    async def shut(self) -> None:
        self.gone.set()
        for sid in list(self._streams):
            await self.end(sid, tell=False)

    # -- for the runner
    def ticket(self) -> Ticket:
        t = Ticket(self)
        _tickets[t.key] = t
        return t

    @property
    def network(self) -> str:
        return str(self.state.get("network") or "unknown")


# What a phone says about itself, kept; anything else it sends is ignored.
_SAID = ("network", "mobile_data", "platform", "build", "pulls")


class Refused(Exception):
    pass


class Ticket:
    """One song's right to use one exit, and what crossed the phone while it did."""

    def __init__(self, ex: Exit):
        self.exit = ex
        self.key = secrets.token_urlsafe(18)
        self.up = 0
        self.down = 0

    @property
    def proxy(self) -> str:
        return f"http://exit:{self.key}@127.0.0.1:{_proxy_port}"

    def done(self) -> None:
        _tickets.pop(self.key, None)


_exits: dict[int, Exit] = {}          # device id → its open door; the newest one wins
_tickets: dict[str, Ticket] = {}
_proxy: asyncio.base_events.Server | None = None
_proxy_port: int | None = None


def exit_for(device_id: int | None) -> Exit | None:
    ex = _exits.get(device_id) if device_id is not None else None
    return ex if ex is not None and not ex.gone.is_set() else None


# ------------------------------------------------------------------ the door
def _device_for(authorization: str | None) -> dict | None:
    if not authorization or not authorization.lower().startswith("bearer "):
        return None
    who = auth.user_for_token(authorization.split(" ", 1)[1].strip())
    if not who:
        return None
    dev = db.one("select id, name, pool_blocked from devices where id=%s",
                 (who["device_id"],))
    if not dev:
        return None
    return {"id": dev["id"], "name": dev["name"], "blocked": dev["pool_blocked"],
            "user_id": who["id"], "user": who["name"]}


def _client_ip(ws: WebSocket) -> str:
    # Caddy is the only way in and writes the header itself, so its first entry is the
    # phone's address as the internet sees it.
    said = ws.headers.get("x-forwarded-for", "").split(",")[0].strip()
    return said or (ws.client.host if ws.client else "")


@router.websocket("/internal/exit")
async def door(ws: WebSocket):
    device = await run_in_threadpool(_device_for, ws.headers.get("authorization"))
    if device is None:
        # Closed before it is accepted, so the handshake itself is turned down.
        await ws.close(code=4401)
        return
    await ws.accept()
    if device["blocked"]:
        await ws.send_bytes(frame(HELLO, 0, json.dumps(
            {"ok": False, "why": "an admin has kept this device out of the pool"}).encode()))
        await ws.close(code=4403)
        return
    ex = Exit(ws, device, _client_ip(ws))
    ex.loop = asyncio.get_running_loop()
    old = _exits.get(ex.device_id)
    _exits[ex.device_id] = ex
    if old is not None:
        await old.shut()
        try:
            await old.ws.close(code=4000)
        except Exception:
            pass
    log.info("exit open: device %s (%s) from %s", ex.device_id, ex.owner, ex.ip)
    await ex.send(HELLO, 0, json.dumps({"ok": True, "streams": MAX_STREAMS}).encode())
    try:
        while True:
            msg = await ws.receive()
            if msg["type"] == "websocket.disconnect":
                break
            data = msg.get("bytes")
            if data:
                await ex.take(data)
    except WebSocketDisconnect:
        pass
    finally:
        if _exits.get(ex.device_id) is ex:
            del _exits[ex.device_id]
        await ex.shut()
        log.info("exit closed: device %s", ex.device_id)


# ------------------------------------------------------------------ the proxy
async def _serve(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
    def answer(status: str) -> None:
        writer.write(f"HTTP/1.1 {status}\r\nContent-Length: 0\r\n\r\n".encode())

    try:
        head = await asyncio.wait_for(reader.readuntil(b"\r\n\r\n"), 10)
    except (asyncio.TimeoutError, asyncio.IncompleteReadError, asyncio.LimitOverrunError,
            ConnectionError):
        writer.close()
        return
    lines = head.decode("latin-1").split("\r\n")
    try:
        method, target, _ = lines[0].split(" ", 2)
        host, port_s = target.rsplit(":", 1)
        port = int(port_s)
    except ValueError:
        answer("400 Bad Request")
        writer.close()
        return
    headers = {}
    for line in lines[1:]:
        if ":" in line:
            k, v = line.split(":", 1)
            headers[k.strip().lower()] = v.strip()
    ticket = None
    auth_said = headers.get("proxy-authorization", "")
    if auth_said.lower().startswith("basic "):
        try:
            _, key = base64.b64decode(auth_said[6:]).decode().split(":", 1)
            ticket = _tickets.get(key)
        except (ValueError, UnicodeDecodeError):
            ticket = None
    if method != "CONNECT":
        answer("405 Method Not Allowed")
        writer.close()
        return
    if ticket is None or ticket.exit.gone.is_set():
        answer("407 Proxy Authentication Required")
        writer.close()
        return
    host = host.strip("[]")
    if not allowed(host, port):
        log.info("exit: not asking a phone for %s:%s", host, port)
        answer("403 Forbidden")
        writer.close()
        return
    ex = ticket.exit
    try:
        st = await ex.open(host, port, writer, ticket)
    except Exception as e:           # refused, or the phone went while it was asked
        log.info("exit %s refused %s:%s: %s", ex.device_id, host, port, e)
        answer("502 Bad Gateway")
        writer.close()
        return
    writer.write(b"HTTP/1.1 200 Connection established\r\n\r\n")
    try:
        await writer.drain()
        while chunk := await reader.read(CHUNK):
            if not await ex.push(st, chunk):
                break
    except Exception:
        # yt-dlp hung up, or the phone did: either way this stream is over, and the
        # other end hears so from end() below.
        pass
    finally:
        await ex.end(st.sid, tell=True)


async def start_proxy(port: int = 0) -> int:
    """The proxy yt-dlp is pointed at, on loopback only: nothing outside this container
    can reach it, and inside it only a ticket gets anywhere."""
    global _proxy, _proxy_port
    if _proxy is not None:
        return _proxy_port or 0
    _proxy = await asyncio.start_server(_serve, "127.0.0.1", port)
    _proxy_port = _proxy.sockets[0].getsockname()[1]
    return _proxy_port


async def stop_proxy() -> None:
    global _proxy, _proxy_port
    # The doors first: shutting one ends every stream through it, which is what lets
    # the proxy's connections finish. wait_closed() waits for all of them.
    for ex in list(_exits.values()):
        await ex.shut()
    _exits.clear()
    if _proxy is not None:
        _proxy.close()
        try:
            await asyncio.wait_for(_proxy.wait_closed(), 5)
        except (asyncio.TimeoutError, Exception):
            pass
    _proxy, _proxy_port = None, None


# ------------------------------------------------------------------ the runner
_cfg = None
_publish = None

# yt-dlp processes at once, for everybody. The box has 8 GB that the API, the database
# and Caddy share, and one of these is 100–200 MB.
_slots = threading.BoundedSemaphore(2)
_pool = ThreadPoolExecutor(max_workers=6, thread_name_prefix="exit")
PER_EXIT = 2
# A song tried through a phone and not got is not tried through it again for this long.
# The look-ahead asks again at every change of song.
TRIED_WINDOW = 300.0
# Challenged by YouTube: that address is left alone for this long, the same ten minutes
# a desktop gives it (ytdlp.dart).
COOL_SECONDS = 600.0
_cooling: dict[str, float] = {}

# Whether this box has been let pull the audio itself lately, newest last. Measured on
# 2026-10-04: 1 of 2 by hand in the morning, 0 of 30 through a phone that afternoon. A
# refusal costs a second of somebody's wait, so it is only asked while it has been
# working, and now and then in case it has started to again.
_direct_lately: collections.deque[bool] = collections.deque(maxlen=20)
_direct_asked = 0
DIRECT_NOW_AND_THEN = 10

YTDLP = "yt-dlp"
FORMAT = "140/bestaudio[acodec^=mp4a]/bestaudio"
_VIDEO_ID = re.compile(r"^[A-Za-z0-9_-]{11}$")
_PERCENT = re.compile(r"MUSEPROGRESS\s+([\d.]+)%\s+(\S+)")

# yt-dlp's words, sorted by what to do about them. Ported from ytdlp.dart, which
# explains each line. The only change is that a challenge is now about one address
# rather than about this one computer.
_TERMINAL = ("unavailable", "not available", "private video", "removed by the uploader",
             "members-only", "age-restricted", "copyright", "does not exist")
_BOT = ("sign in to confirm you're not a bot", "sign in to confirm you’re not a bot",
        "not a bot", "po token", "login_required")
_AGE = ("confirm your age", "age-restricted", "age restricted")
_RATE = ("http error 429", "too many requests")
# Not about the song at all: the way through the phone broke.
_TUNNEL = ("tunnel connection failed", "unable to connect to proxy", "proxyerror",
           "connection reset", "remote end closed connection", "connection aborted")


def configure(cfg, publish) -> None:
    global _cfg, _publish
    _cfg, _publish = cfg, publish


def judge(output: str) -> tuple[str, str]:
    """What yt-dlp's output says to do (back_off / needs_age / dead / tunnel / retry),
    and the line that says it."""
    lines = [ln.strip() for ln in output.splitlines() if ln.strip()]
    errors = [ln for ln in lines
              if ln.startswith("ERROR") or (not ln.startswith("[")
                                            and "MUSEPROGRESS" not in ln
                                            and not ln.startswith("WARNING"))]
    last = errors[-1] if errors else (lines[-1] if lines else "yt-dlp failed")
    everything = output.lower()
    said = last.lower()
    if any(r in everything for r in _RATE):
        return "back_off", last
    if any(a in said for a in _AGE):
        return "needs_age", last
    if any(b in said for b in _BOT):
        return "back_off", last
    if any(t in said for t in _TUNNEL):
        return "tunnel", last
    if any(t in said for t in _TERMINAL):
        return "dead", last
    return "retry", last


def _ip_key(ip: str) -> str:
    """The address YouTube judges: a whole /64 for IPv6, which is one household."""
    try:
        addr = ipaddress.ip_address(ip)
    except ValueError:
        return ip
    if addr.version == 6:
        return str(ipaddress.ip_network(f"{ip}/64", strict=False))
    return ip


def cooling(ex: Exit) -> float:
    """Seconds until this phone's address may ask YouTube anything again."""
    left = _cooling.get(_ip_key(ex.ip), 0) - time.time()
    return left if left > 0 else 0.0


def _cool(ex: Exit) -> None:
    _cooling[_ip_key(ex.ip)] = time.time() + COOL_SECONDS


def desktop_fetching() -> bool:
    """Whether a computer in the pool is fetching for it right now."""
    return bool(db.one(
        """select 1 from workers w join devices d on w.name = 'device:' || d.id
            where w.last_seen > now() - interval '90 seconds'
              and not d.pool_blocked
              and coalesce((d.pool->>'fetch')::boolean, true)
            limit 1"""))


def worth_asking_directly() -> bool:
    global _direct_asked
    _direct_asked += 1
    return (len(_direct_lately) < 5 or any(_direct_lately)
            or _direct_asked % DIRECT_NOW_AND_THEN == 0)


def may_relay(ex: Exit) -> bool:
    """Whether a song may come through the phone, when the server cannot pull it."""
    if ex.network in ("wifi", "ethernet"):
        return True
    if not ex.state.get("mobile_data", True):
        return False
    # On a phone's own data, a computer at home that can fetch it is the better way:
    # it costs nobody's data plan.
    return not desktop_fetching()


def want(device_id: int | None, track_ids: list[int]) -> int:
    """The songs a device is about to play, in playing order: fetched through its own
    door, if it has one open. Answers how many were started."""
    _sweep()
    ex = exit_for(device_id)
    if ex is None or _cfg is None or cooling(ex):
        return 0
    with ex.lock:
        ex.wanted = collections.deque(int(t) for t in track_ids[:8])
    return _kick(ex)


def _kick(ex: Exit) -> int:
    started = 0
    while True:
        with ex.lock:
            busy = len(ex.working) + _pulling_for(ex)
            if ex.gone.is_set() or busy >= PER_EXIT or not ex.wanted:
                return started
            tid = ex.wanted.popleft()
            if tid in ex.working or time.time() - ex.tried.get(tid, 0) < TRIED_WINDOW:
                continue
            ex.working.add(tid)          # held while the database is asked
        job = None
        try:
            if not cooling(ex):
                job = jobs.claim(f"exit:{ex.device_id}", "ingest", tid)
        except Exception as e:
            log.warning("exit claim for %s failed: %s", tid, e)
        if job is None:
            with ex.lock:
                ex.working.discard(tid)
            continue
        with ex.lock:
            ex.tried[tid] = time.time()
        _say(tid, "asking")
        _pool.submit(_work, ex, job)
        started += 1


def _work(ex: Exit, job: dict) -> None:
    tid = int(job["payload"]["track_id"])
    try:
        with _slots:
            fetch(ex, job)
    except Exception as e:
        log.exception("exit fetch of track %s crashed: %s", tid, e)
        _hand_back(job, tid)
    finally:
        with ex.lock:
            ex.working.discard(tid)
        if not ex.gone.is_set():
            _kick(ex)


def _say(track_id: int, stage: str, percent: float | None = None,
         speed: str | None = None) -> None:
    entry = progress.update(track_id, stage, percent, speed)
    if _publish:
        _publish("track_progress", {"track_id": track_id, **entry})


def _hand_back(job: dict, track_id: int) -> None:
    """Given back unspent, for a computer in the pool or another try."""
    try:
        jobs.release(job["id"])
    except Exception:
        pass
    _say(track_id, "queued")
    if _publish:
        _publish("pool", {})


def _record(ex: Exit, track_id: int, outcome: str, ticket: Ticket | None = None,
            resolve_ms: int | None = None, direct: bool | None = None,
            relayed: bool | None = None, error: str | None = None,
            phone_pulled: bool | None = None, extra_bytes: int = 0) -> None:
    try:
        db.run(
            """insert into exit_fetches(device_id, track_id, network, outcome,
                                        resolve_ms, direct, relayed, exit_bytes, error,
                                        phone_pulled)
               values(%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)""",
            (ex.device_id, track_id, ex.network, outcome, resolve_ms, direct, relayed,
             ((ticket.up + ticket.down) if ticket else 0) + extra_bytes or None,
             error[:500] if error else None, phone_pulled))
    except Exception as e:                       # the song matters more than the count
        log.warning("could not record an exit fetch: %s", e)


def ytdlp(args: list[str], timeout: float, on_line=None) -> tuple[int, str, str]:
    """Run yt-dlp: (exit code, stdout, stderr). With `on_line`, stderr and stdout are
    read as they come, for the progress lines; stdout is then not kept."""
    if on_line is None:
        try:
            r = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
        except subprocess.TimeoutExpired:
            return 124, "", "ERROR: yt-dlp took too long"
        return r.returncode, r.stdout, r.stderr
    p = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                         text=True, bufsize=1)
    timer = threading.Timer(timeout, p.kill)
    timer.start()
    said = []
    try:
        assert p.stdout is not None
        for line in p.stdout:
            on_line(line)
            said.append(line)
            if len(said) > 400:
                del said[:200]
        code = p.wait()
    finally:
        timer.cancel()
    return code, "", "".join(said)


def _js() -> list[str]:
    # The runtime yt-dlp solves YouTube's puzzles with. Without one it says formats
    # may be missing, and the missing one is usually the one wanted.
    for name in ("deno", "node"):
        if shutil.which(name):
            return ["--js-runtimes", name]
    return []


def _cache_dir() -> list[str]:
    if _cfg is None:
        return []
    return ["--cache-dir", str(pathlib.Path(_cfg.data_dir) / "cache" / "yt-dlp")]


def _pull(info: pathlib.Path, out: pathlib.Path, track_id: int,
          proxy: str | None) -> tuple[pathlib.Path | None, str]:
    args = [YTDLP, *_cache_dir(), "--load-info-json", str(info),
            # The same choice again: from a saved answer yt-dlp chooses afresh, and
            # left to itself it fetched the video too, 110 MB of it.
            "-f", FORMAT, "--no-playlist", "--retries", "1", "--fragment-retries", "1",
            "--socket-timeout", "20", "--newline",
            "--progress-template",
            "MUSEPROGRESS %(progress._percent_str)s %(progress._speed_str)s",
            "-o", str(out / "%(id)s.%(ext)s")]
    if proxy:
        args += ["--proxy", proxy]
    stage = "relaying" if proxy else "downloading"
    last = [0.0]

    def heard(line: str) -> None:
        m = _PERCENT.search(line)
        if m and time.monotonic() - last[0] >= 1.0:
            last[0] = time.monotonic()
            try:
                _say(track_id, stage, float(m.group(1)) / 100, m.group(2))
            except ValueError:
                pass

    code, _, said = ytdlp(args, timeout=600 if proxy else 180, on_line=heard)
    files = sorted(f for f in out.iterdir()
                   if f.is_file() and f.suffix not in (".json", ".part", ".ytdl", ".txt"))
    if code != 0 or not files:
        for f in out.iterdir():
            if f.suffix in (".part", ".ytdl"):
                f.unlink(missing_ok=True)
        return None, said
    return files[0], said


def fetch(ex: Exit, job: dict) -> str:
    """One song through one phone. Answers how it went: ready, handed_back, cooling,
    failed or lost."""
    payload = job["payload"]
    track_id = int(payload["track_id"])
    video_id = str(payload.get("video_id") or "")
    if not _VIDEO_ID.match(video_id):
        landing.failed(job["id"], track_id, "not a YouTube video id", False, _publish)
        return "failed"
    ticket = ex.ticket()
    resolve_ms = None
    direct = relayed = None
    refused = None                   # what YouTube said when the server asked itself
    try:
        with tempfile.TemporaryDirectory(prefix="muse-exit-") as tmp_s:
            tmp = pathlib.Path(tmp_s)
            _say(track_id, "asking")
            started = time.monotonic()
            code, out, err = ytdlp(
                [YTDLP, *_js(), *_cache_dir(), "--no-playlist", "-f", FORMAT, "-J",
                 "--socket-timeout", "20", "--proxy", ticket.proxy,
                 f"https://music.youtube.com/watch?v={video_id}"],
                timeout=120)
            resolve_ms = int((time.monotonic() - started) * 1000)
            if ex.gone.is_set():
                _hand_back(job, track_id)
                _record(ex, track_id, "lost", ticket, resolve_ms)
                return "lost"
            if code != 0 or not out.strip():
                return _after_failure(ex, job, track_id, err, ticket, resolve_ms)
            info = tmp / "info.json"
            info.write_text(out)

            # The server pulls it itself when YouTube lets it: no phone in the way.
            got, said = None, ""
            # Always asked when the phone may not carry it: then it is the only way.
            if worth_asking_directly() or not may_relay(ex):
                got, said = _pull(info, tmp, track_id, None)
                direct = got is not None
                _direct_lately.append(direct)
                if got is None:
                    refused = judge(said)[1]
            if got is None:
                if not may_relay(ex):
                    _hand_back(job, track_id)
                    _record(ex, track_id, "handed_back", ticket, resolve_ms, direct,
                            False, refused)
                    return "handed_back"
                # A phone that fetches for itself is told where the song is, and the
                # song never has to come back down to it from here.
                order = _order(job, track_id, info) if ex.state.get("pulls") else None
                if order is not None and _hand_over(ex, job, track_id, info, order,
                                                    ticket, resolve_ms, direct, refused):
                    return "pulling"
                return _relay(ex, job, track_id, info, tmp, ticket, resolve_ms, direct,
                              refused)
            return _arrived(ex, job, track_id, got, ticket, resolve_ms, direct, None,
                            refused)
    finally:
        ticket.done()


def _arrived(ex: Exit, job: dict, track_id: int, got: pathlib.Path, ticket: Ticket,
             resolve_ms: int | None, direct: bool | None, relayed: bool | None,
             refused: str | None) -> str:
    if got.suffix != ".m4a":
        _say(track_id, "converting")
        to = got.with_suffix(".m4a")
        audiofile.to_m4a(got, to)
        got = to
    landing.land(_cfg, job["id"], track_id, got, _publish,
                 lambda stage: _say(track_id, stage))
    _record(ex, track_id, "ready", ticket, resolve_ms, direct, relayed, refused)
    log.info("track %s via exit %s: %s, %d KB across the phone", track_id,
             ex.device_id, "direct" if direct else "relayed",
             (ticket.up + ticket.down) // 1024)
    return "ready"


def _relay(ex: Exit, job: dict, track_id: int, info: pathlib.Path, tmp: pathlib.Path,
           ticket: Ticket, resolve_ms: int | None, direct: bool | None,
           refused: str | None) -> str:
    """The song through the phone, from the answer it already helped get."""
    got, said = _pull(info, tmp, track_id, ticket.proxy)
    if got is None:
        if ex.gone.is_set():
            _hand_back(job, track_id)
            _record(ex, track_id, "lost", ticket, resolve_ms, direct, True)
            return "lost"
        return _after_failure(ex, job, track_id, said, ticket, resolve_ms,
                              direct=direct, relayed=True)
    return _arrived(ex, job, track_id, got, ticket, resolve_ms, direct, True, refused)


def _after_failure(ex: Exit, job: dict, track_id: int, said: str, ticket: Ticket,
                   resolve_ms: int | None, direct: bool | None = None,
                   relayed: bool | None = None) -> str:
    if ex.gone.is_set():
        _hand_back(job, track_id)
        _record(ex, track_id, "lost", ticket, resolve_ms, direct, relayed)
        return "lost"
    verdict, line = judge(said)
    if verdict == "back_off":
        _cool(ex)
        log.info("YouTube pushed back on exit %s (%s): %s", ex.device_id,
                 _ip_key(ex.ip), line)
        _hand_back(job, track_id)
        _record(ex, track_id, "cooling", ticket, resolve_ms, direct, relayed, line)
        return "cooling"
    if verdict == "tunnel":
        _hand_back(job, track_id)
        _record(ex, track_id, "lost", ticket, resolve_ms, direct, relayed, line)
        return "lost"
    if verdict == "needs_age":
        line = ("YouTube wants an age-verified account for this one — it will not "
                "download here.")
    landing.failed(job["id"], track_id, line, verdict == "retry", _publish)
    _record(ex, track_id, "failed", ticket, resolve_ms, direct, relayed, line)
    return "failed"


# ------------------------------------------------------------------ the phone pulls it
#
# A song handed to a phone to fetch itself: its job stays leased to that phone's exit
# while it does, and what yt-dlp found is kept, so a pull that fails can still come
# through the phone the old way.
PULL_SECONDS = 360.0
_YOUTUBE_MEDIA = re.compile(r"^https://[a-z0-9.-]+\.googlevideo\.com/")


class _Handed:
    def __init__(self, ex: Exit, job: dict, track_id: int, info: pathlib.Path,
                 resolve_ms: int | None, direct: bool | None, refused: str | None,
                 crossed: int):
        self.ex, self.job, self.track_id, self.info = ex, job, track_id, info
        self.resolve_ms, self.direct, self.refused = resolve_ms, direct, refused
        self.crossed = crossed
        self.at = time.time()


_handed: dict[int, _Handed] = {}
_handed_lock = threading.Lock()


def _pulling_for(ex: Exit) -> int:
    with _handed_lock:
        return sum(1 for h in _handed.values() if h.ex is ex)


def _order(job: dict, track_id: int, info: pathlib.Path) -> dict | None:
    """What a phone needs to fetch the format yt-dlp chose: one plain HTTPS address on
    YouTube's media hosts, and the headers to ask with. None for anything else (a
    playlist of pieces, say), which then comes through the phone the old way."""
    try:
        d = json.loads(info.read_text())
    except (OSError, ValueError):
        return None
    if d.get("requested_formats") or d.get("protocol") not in ("https", "http"):
        return None
    url = d.get("url") or ""
    if not _YOUTUBE_MEDIA.match(url):
        return None
    return {"job": job["id"], "track": track_id, "url": url,
            "headers": d.get("http_headers") or {},
            "bytes": d.get("filesize") or d.get("filesize_approx"),
            "ext": d.get("ext"), "acodec": d.get("acodec"),
            "chunk": (d.get("downloader_options") or {}).get("http_chunk_size")}


def _tell_phone(ex: Exit, kind: int, what: dict) -> bool:
    """A frame to the phone from one of the runner's threads."""
    if ex.loop is None or ex.gone.is_set():
        return False
    try:
        asyncio.run_coroutine_threadsafe(
            ex.send(kind, 0, json.dumps(what).encode()), ex.loop).result(timeout=10)
        return True
    except Exception as e:
        log.info("could not tell exit %s: %s", ex.device_id, e)
        return False


def _hand_over(ex: Exit, job: dict, track_id: int, info: pathlib.Path, order: dict,
               ticket: Ticket, resolve_ms: int | None, direct: bool | None,
               refused: str | None) -> bool:
    keep = pathlib.Path(_cfg.data_dir) / "cache" / "exit-pulls"
    keep.mkdir(parents=True, exist_ok=True)
    kept = keep / f"{job['id']}.json"
    shutil.copy(info, kept)
    h = _Handed(ex, job, track_id, kept, resolve_ms, direct, refused,
                ticket.up + ticket.down)
    with _handed_lock:
        _handed[job["id"]] = h
    if not _tell_phone(ex, PULL, order):
        with _handed_lock:
            _handed.pop(job["id"], None)
        kept.unlink(missing_ok=True)
        return False
    _say(track_id, "pulling")
    return True


def _take_handed(job_id: int, device_id: int) -> _Handed | None:
    with _handed_lock:
        h = _handed.get(job_id)
        if h is None or h.ex.device_id != device_id:
            return None
        return _handed.pop(job_id)


def _sweep() -> None:
    """Songs a phone was sent to fetch and never brought back: given back."""
    now = time.time()
    with _handed_lock:
        stale = [j for j, h in _handed.items() if now - h.at > PULL_SECONDS]
        gone = [_handed.pop(j) for j in stale]
    for h in gone:
        h.info.unlink(missing_ok=True)
        _hand_back(h.job, h.track_id)
        _record(h.ex, h.track_id, "lost", None, h.resolve_ms, h.direct, False,
                "the phone never brought it back", True, h.crossed)


def _device_or_401(authorization: str | None) -> dict:
    device = _device_for(authorization)
    if device is None:
        raise HTTPException(401, "missing or unknown token")
    if device["blocked"]:
        raise HTTPException(403, "an admin has kept this device out of the pool")
    return device


# The most a song from a phone may be: an hour-long set is about 60 MB.
PHONE_UPLOAD_LIMIT = 200 * 1024 * 1024


@router.post("/internal/exit/jobs/{job_id}/audio")
def pulled(job_id: int, audio: UploadFile = File(...), meta: str = Form("{}"),
           authorization: str | None = Header(None)):
    """A song a phone fetched itself, handed in. Put right where it needs it (YouTube's
    pieces into one plain m4a, by copying, never re-encoding), measured here, kept and
    announced like any other."""
    device = _device_or_401(authorization)
    h = _take_handed(job_id, device["id"])
    if h is None:
        raise HTTPException(409, "not a song this device was sent to fetch")
    try:
        with tempfile.TemporaryDirectory(prefix="muse-pulled-") as tmp_s:
            tmp = pathlib.Path(tmp_s)
            raw = tmp / "raw.m4a"
            size = 0
            with raw.open("wb") as out:
                while chunk := audio.file.read(1 << 20):
                    size += len(chunk)
                    if size > PHONE_UPLOAD_LIMIT:
                        raise HTTPException(413, "too large to be a song")
                    out.write(chunk)
            fixed = tmp / "song.m4a"
            r = subprocess.run(
                [audiofile.FFMPEG, "-v", "error", "-y", "-i", str(raw), "-vn", "-c", "copy",
                 "-movflags", "+faststart", "-f", "mp4", str(fixed)],
                capture_output=True, text=True, timeout=120)
            try:
                info = audiofile.probe(fixed) if r.returncode == 0 else {}
            except (subprocess.SubprocessError, ValueError, OSError):
                info = {}
            if not info.get("codec") or (info.get("duration_ms") or 0) < 500:
                raise HTTPException(400, "that is not a song")
            if audiofile.needs_transcode(info):
                to = tmp / "song-aac.m4a"
                audiofile.to_m4a(fixed, to)
                fixed = to
            landing.land(_cfg, job_id, h.track_id, fixed, _publish,
                         lambda stage: _say(h.track_id, stage))
    except HTTPException:
        # Not taken: the song is given back for somebody else, rather than left
        # waiting for a phone that has already said what it had.
        _hand_back(h.job, h.track_id)
        _record(h.ex, h.track_id, "failed", None, h.resolve_ms, h.direct, False,
                "the phone handed in something that was not the song", True, h.crossed)
        raise
    except Exception as e:
        log.exception("keeping track %s from phone %s failed: %s", h.track_id,
                      device["id"], e)
        _hand_back(h.job, h.track_id)
        raise HTTPException(500, "could not keep it") from e
    finally:
        h.info.unlink(missing_ok=True)
    try:
        said = json.loads(meta or "{}")
    except ValueError:
        said = {}
    fetched = said.get("bytes") if isinstance(said.get("bytes"), int) else size
    _record(h.ex, h.track_id, "ready", None, h.resolve_ms, h.direct, False, h.refused,
            True, h.crossed + fetched + size)
    log.info("track %s pulled by phone %s itself, %d KB", h.track_id, device["id"],
             size // 1024)
    return {"ok": True}


@router.post("/internal/exit/jobs/{job_id}/failed")
def pull_failed(job_id: int, body: dict | None = None,
                authorization: str | None = Header(None)):
    """The phone could not fetch it itself: through the phone the old way, from the same
    answer, where its data allows; else given back."""
    device = _device_or_401(authorization)
    h = _take_handed(job_id, device["id"])
    if h is None:
        raise HTTPException(409, "not a song this device was sent to fetch")
    why = str((body or {}).get("why") or "the phone could not fetch it")[:300]
    log.info("phone %s could not pull track %s itself: %s", device["id"], h.track_id, why)
    if h.ex.gone.is_set() or not may_relay(h.ex):
        h.info.unlink(missing_ok=True)
        _hand_back(h.job, h.track_id)
        _record(h.ex, h.track_id, "handed_back", None, h.resolve_ms, h.direct, False,
                why, False, h.crossed)
        return {"ok": True, "then": "handed_back"}
    _pool.submit(_relay_later, h, why)
    return {"ok": True, "then": "through_the_phone"}


def _relay_later(h: _Handed, why: str) -> None:
    ex = h.ex
    with ex.lock:
        ex.working.add(h.track_id)
    try:
        with _slots:
            ticket = ex.ticket()
            try:
                with tempfile.TemporaryDirectory(prefix="muse-exit-") as tmp_s:
                    _relay(ex, h.job, h.track_id, h.info, pathlib.Path(tmp_s), ticket,
                           h.resolve_ms, h.direct, why)
            finally:
                ticket.done()
    except Exception as e:
        log.exception("relay after a failed pull of %s crashed: %s", h.track_id, e)
        _hand_back(h.job, h.track_id)
    finally:
        h.info.unlink(missing_ok=True)
        with ex.lock:
            ex.working.discard(h.track_id)


# ------------------------------------------------------------------ for the pool screen
def overview() -> list[dict]:
    _sweep()
    today = {r["device_id"]: r for r in db.all_(
        """select device_id,
                  count(*) filter (where outcome = 'ready') as ready,
                  count(*) filter (where outcome = 'ready' and direct) as direct,
                  count(*) filter (where outcome = 'ready' and relayed) as relayed,
                  count(*) filter (where outcome = 'ready' and phone_pulled) as pulled,
                  coalesce(sum(exit_bytes), 0) as bytes
             from exit_fetches
            where at > now() - interval '24 hours'
            group by 1""")}
    out = []
    for ex in list(_exits.values()):
        if ex.gone.is_set():
            continue
        t = today.get(ex.device_id) or {}
        out.append({
            "device_id": ex.device_id, "name": ex.name, "owner": ex.owner,
            "platform": ex.state.get("platform"), "network": ex.network,
            "mobile_data": bool(ex.state.get("mobile_data", True)),
            "since": ex.since, "working": len(ex.working),
            "cooling": round(cooling(ex)),
            "fetched_today": t.get("ready", 0), "direct_today": t.get("direct", 0),
            "relayed_today": t.get("relayed", 0), "pulled_today": t.get("pulled", 0),
            "pulling": _pulling_for(ex), "bytes_today": int(t.get("bytes", 0)),
        })
    return out
