"""A phone opening the door to YouTube for the server (exits.py).

Two halves are checked. The tunnel: bytes go both ways through a phone without either
side holding more than a window of them, and only to YouTube on 443 with a valid ticket.
The phone here is a stand-in written the way exit_tunnel.dart works. The runner: what
happens to a song when the server can pull it itself, when YouTube makes it come through
the phone, when the phone's data says no, when YouTube pushes back, and when the phone
goes away mid-fetch.
"""
from __future__ import annotations

import asyncio
import base64
import hashlib
import json
import pathlib
import shutil
import struct
import subprocess

import pytest

from muse import db, exits, jobs


# ------------------------------------------------------------------ the tunnel
class Phone:
    """The phone's half of the conversation, done the way exit_tunnel.dart does it."""

    def __init__(self, origin_port: int, refuse: tuple[str, ...] = ()):
        self.origin_port = origin_port
        self.refuse = refuse
        # Seconds spent on each chunk from the server before it is passed on: a phone's
        # upload is the slow side, and a fast stand-in never makes the server wait.
        self.slow = 0.0
        self.inbox: asyncio.Queue = asyncio.Queue()
        self.ex: exits.Exit | None = None
        self.links: dict[int, dict] = {}
        self.most_unacked = 0
        self.opened: list[str] = []

    async def send_bytes(self, data: bytes) -> None:     # the server, talking to us
        await self.inbox.put(data)

    async def close(self, code: int = 1000) -> None:
        pass

    async def run(self) -> None:
        while True:
            data = await self.inbox.get()
            kind, sid = exits._HEAD.unpack_from(data)
            payload = data[exits._HEAD.size:]
            if kind == exits.OPEN:
                host = payload[2:].decode()
                self.opened.append(host)
                if host in self.refuse:
                    await self.ex.take(exits.frame(exits.REFUSED, sid, b"not on my list"))
                    continue
                r, w = await asyncio.open_connection("127.0.0.1", self.origin_port)
                link = self.links[sid] = {"r": r, "w": w, "unacked": 0,
                                          "credit": asyncio.Event()}
                await self.ex.take(exits.frame(exits.OPENED, sid))
                link["task"] = asyncio.create_task(self._pump(sid, link))
            elif kind == exits.DATA and sid in self.links:
                if self.slow:
                    await asyncio.sleep(self.slow)
                w = self.links[sid]["w"]
                w.write(payload)
                await w.drain()
                await self.ex.take(exits.frame(exits.CREDIT, sid,
                                               struct.pack("!I", len(payload))))
            elif kind == exits.CREDIT and sid in self.links:
                link = self.links[sid]
                link["unacked"] -= struct.unpack("!I", payload)[0]
                link["credit"].set()
            elif kind == exits.CLOSE and sid in self.links:
                self.links.pop(sid)["w"].close()

    async def _pump(self, sid: int, link: dict) -> None:
        while chunk := await link["r"].read(65536):
            while link["unacked"] >= exits.WINDOW:
                link["credit"].clear()
                await link["credit"].wait()
            await self.ex.take(exits.frame(exits.DATA, sid, chunk))
            link["unacked"] += len(chunk)
            self.most_unacked = max(self.most_unacked, link["unacked"])
        if self.links.pop(sid, None) is not None:
            await self.ex.take(exits.frame(exits.CLOSE, sid))


async def _origin(reader, writer):
    """Stands in for YouTube: GET n answers n bytes; PUT n reads n and answers their hash."""
    line = (await reader.readline()).decode().split()
    if line and line[0] == "GET":
        n = int(line[1])
        writer.write(bytes(i % 251 for i in range(n)))
    elif line and line[0] == "PUT":
        body = await reader.readexactly(int(line[1]))
        writer.write(hashlib.sha256(body).hexdigest().encode())
    await writer.drain()
    writer.close()


async def _through(port: int, key: str | None, target: str):
    r, w = await asyncio.open_connection("127.0.0.1", port)
    head = f"CONNECT {target} HTTP/1.1\r\nHost: {target}\r\n"
    if key:
        head += ("Proxy-Authorization: Basic "
                 + base64.b64encode(f"exit:{key}".encode()).decode() + "\r\n")
    w.write((head + "\r\n").encode())
    await w.drain()
    status = (await r.readuntil(b"\r\n\r\n")).split(b"\r\n")[0].decode()
    return status, r, w


def _tunnel(test):
    """Run `test(port, phone, exit)` with a proxy, a phone and a pretend YouTube."""
    async def main():
        origin = await asyncio.start_server(_origin, "127.0.0.1", 0)
        port = await exits.start_proxy()
        phone = Phone(origin.sockets[0].getsockname()[1], refuse=("music.youtube.com",))
        ex = exits.Exit(phone, {"id": 990, "user_id": 1, "name": "test phone"}, "192.0.2.7")
        phone.ex = ex
        runner = asyncio.create_task(phone.run())
        try:
            await asyncio.wait_for(test(port, phone, ex), 30)
        finally:
            runner.cancel()
            await ex.shut()
            await exits.stop_proxy()
            origin.close()
    asyncio.run(main())


def test_a_song_comes_down_through_the_phone_a_window_at_a_time():
    async def test(port, phone, ex):
        ticket = ex.ticket()
        status, r, w = await _through(port, ticket.key, "www.youtube.com:443")
        assert status.endswith("200 Connection established")
        w.write(b"GET 1500000\n")
        await w.drain()
        got = await r.read()                     # to the end: the phone closes it
        assert got == bytes(i % 251 for i in range(1_500_000))
        # Never more in flight than a window and the chunk that crossed it.
        assert phone.most_unacked <= exits.WINDOW + 65536
        assert ticket.down == 1_500_000 and ticket.up == len(b"GET 1500000\n")
    _tunnel(test)


def test_and_goes_up_through_it_as_well_no_faster_than_the_phone_takes_it():
    async def test(port, phone, ex):
        phone.slow = 0.01
        most = [0]
        push = ex.push

        async def watched(st, chunk):
            ok = await push(st, chunk)
            most[0] = max(most[0], st.unacked)
            return ok
        ex.push = watched
        ticket = ex.ticket()
        body = bytes(range(256)) * 3000          # 768 KB, three windows
        status, r, w = await _through(port, ticket.key, "rr1---sn-x.googlevideo.com:443")
        assert "200" in status
        w.write(f"PUT {len(body)}\n".encode() + body)
        await w.drain()
        assert (await r.read()).decode() == hashlib.sha256(body).hexdigest()
        assert exits.WINDOW <= most[0] <= exits.WINDOW + exits.CHUNK, \
            "it filled the window and went no further"
    _tunnel(test)


def test_only_youtube_only_443_only_with_a_ticket():
    async def test(port, phone, ex):
        key = ex.ticket().key
        assert (await _through(port, key, "example.com:443"))[0].split()[1] == "403"
        assert (await _through(port, key, "www.youtube.com:80"))[0].split()[1] == "403"
        assert (await _through(port, "made-up", "www.youtube.com:443"))[0].split()[1] == "407"
        assert (await _through(port, None, "www.youtube.com:443"))[0].split()[1] == "407"
        # The phone keeps its own list and the server takes no for an answer.
        assert (await _through(port, key, "music.youtube.com:443"))[0].split()[1] == "502"
        assert phone.opened == ["music.youtube.com"], "nothing else reached the phone"
    _tunnel(test)


def test_a_phone_that_goes_away_closes_what_was_open_through_it():
    async def test(port, phone, ex):
        ticket = ex.ticket()
        status, r, w = await _through(port, ticket.key, "www.youtube.com:443")
        assert "200" in status
        await ex.shut()
        assert await asyncio.wait_for(r.read(), 5) == b""
        assert (await _through(port, ticket.key, "www.youtube.com:443"))[0].split()[1] == "407"
    _tunnel(test)


def test_what_yt_dlp_says_is_sorted_into_what_to_do():
    j = lambda s: exits.judge(s)[0]  # noqa: E731
    assert j("ERROR: [youtube] x: Sign in to confirm you’re not a bot") == "back_off"
    assert j("WARNING: HTTP Error 429: Too Many Requests\nERROR: Video unavailable") == "back_off"
    assert j("ERROR: [youtube] x: Sign in to confirm your age") == "needs_age"
    assert j("ERROR: [youtube] x: Video unavailable. This video has been removed") == "dead"
    assert j("ERROR: Unable to download webpage: Tunnel connection failed: 502") == "tunnel"
    assert j("ERROR: something new and strange") == "retry"


# ------------------------------------------------------------------ the runner
@pytest.fixture(scope="module")
def a_song(tmp_path_factory) -> pathlib.Path:
    if not shutil.which("ffmpeg"):
        pytest.skip("no ffmpeg here")
    out = tmp_path_factory.mktemp("song") / "tone.m4a"
    subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i",
                    "sine=frequency=440:duration=1", "-c:a", "aac", "-b:a", "48k", str(out)],
                   capture_output=True, check=True)
    return out


class FakeYtdlp:
    """yt-dlp as the runner sees it: the answer to the question, and then the file, or
    not, depending on whether it came straight from YouTube or through the phone."""

    def __init__(self, song: pathlib.Path, ask="ok", direct="ok", relay="ok", during=None):
        self.song, self.ask, self.direct, self.relay = song, ask, direct, relay
        self.during = during
        self.calls: list[str] = []

    def __call__(self, args, timeout, on_line=None):
        if "-J" in args:
            self.calls.append("ask")
            assert "--proxy" in args, "the question always goes through the phone"
            if self.during:
                self.during()
            if self.ask != "ok":
                return 1, "", self.ask
            return 0, json.dumps({"id": "x", "formats": []}), ""
        through = "--proxy" in args
        self.calls.append("relay" if through else "direct")
        assert args[args.index("-f") + 1] == exits.FORMAT, "the same choice again"
        said = self.relay if through else self.direct
        if said != "ok":
            return 1, "", said
        out = pathlib.Path(args[args.index("-o") + 1]).parent
        shutil.copy(self.song, out / "x.m4a")
        if on_line:
            on_line("MUSEPROGRESS 100.0% 1.2MiB/s\n")
        return 0, "", ""


@pytest.fixture()
def phone(client, hdr, token, monkeypatch):
    """An exit for the device the test is signed in on, and a song it wants."""
    from muse import auth
    device = db.one("select id from devices where token_hash=%s",
                    (auth.token_hash(token),))["id"]
    ex = exits.Exit(None, {"id": device, "user_id": 1, "name": "pytest"}, "192.0.2.7")
    ex.state = {"network": "wifi", "mobile_data": True, "platform": "android"}
    monkeypatch.setitem(exits._exits, device, ex)
    exits._cooling.clear()
    exits._direct_lately.clear()
    monkeypatch.setattr(exits, "_direct_asked", 0)
    yield ex
    exits._cooling.clear()
    exits._direct_lately.clear()


def _song(client, hdr, vid):
    return client.post("/tracks/resolve", headers=hdr, json={"video_id": vid}).json()["id"]


def _claim(ex, tid):
    job = jobs.claim(f"exit:{ex.device_id}", "ingest", tid)
    assert job is not None
    return job


def _last_row():
    return db.one("select * from exit_fetches order by id desc limit 1")


def test_the_server_pulls_it_itself_when_youtube_lets_it(client, hdr, phone, a_song,
                                                         monkeypatch):
    tid = _song(client, hdr, "EXIT0000001")
    fake = FakeYtdlp(a_song)
    monkeypatch.setattr(exits, "ytdlp", fake)
    assert exits.fetch(phone, _claim(phone, tid)) == "ready"
    assert fake.calls == ["ask", "direct"], "the song never crossed the phone"
    t = db.one("select state, loudness_lufs from tracks where id=%s", (tid,))
    assert t["state"] == "ready" and t["loudness_lufs"] is not None, "measured here"
    assert db.one("select count(*) n from media where track_id=%s", (tid,))["n"] == 1
    row = _last_row()
    assert row["outcome"] == "ready" and row["direct"] and not row["relayed"]
    assert db.one("select count(*) n from jobs where kind='meta'")["n"] >= 1


def test_through_the_phone_when_youtube_insists(client, hdr, phone, a_song, monkeypatch):
    tid = _song(client, hdr, "EXIT0000002")
    fake = FakeYtdlp(a_song, direct="ERROR: unable to download video data: HTTP Error 403: Forbidden")
    monkeypatch.setattr(exits, "ytdlp", fake)
    assert exits.fetch(phone, _claim(phone, tid)) == "ready"
    assert fake.calls == ["ask", "direct", "relay"]
    row = _last_row()
    assert row["relayed"] and row["direct"] is False


def test_the_server_stops_asking_itself_once_youtube_keeps_saying_no(client, hdr, phone,
                                                                      a_song, monkeypatch):
    refused = "ERROR: unable to download video data: HTTP Error 403: Forbidden"
    fake = FakeYtdlp(a_song, direct=refused)
    monkeypatch.setattr(exits, "ytdlp", fake)
    for n in range(12):
        tid = _song(client, hdr, f"EXIT00002{n:02d}")
        assert exits.fetch(phone, _claim(phone, tid)) == "ready"
    asked = fake.calls.count("direct")
    # Five to learn, then once in every ten.
    assert asked == 6, fake.calls
    assert fake.calls.count("relay") == 12
    assert db.one("select count(*) n from exit_fetches where direct is null")["n"] == 6

    # And once it works again, it is asked every time.
    fake.direct = "ok"
    exits._direct_lately.append(True)
    tid = _song(client, hdr, "EXIT0000299")
    before = fake.calls.count("direct")
    assert exits.fetch(phone, _claim(phone, tid)) == "ready"
    assert fake.calls.count("direct") == before + 1 and fake.calls[-1] == "direct"


def test_on_a_phones_data_a_computer_at_home_goes_first(client, hdr, phone, a_song,
                                                        monkeypatch):
    tid = _song(client, hdr, "EXIT0000003")
    phone.state.update(network="cellular", mobile_data=True)
    # A desktop in the pool, fetching.
    db.run("insert into users(name) values('dee') on conflict do nothing")
    other = db.one("""insert into devices(user_id, name, token_hash, pool)
                      values((select id from users where name='dee'), 'desk', 'h-desk',
                             '{"fetch": true}'::jsonb) returning id""")["id"]
    db.run("insert into workers(name, last_seen) values(%s, now())", (f"device:{other}",))
    fake = FakeYtdlp(a_song, direct="ERROR: HTTP Error 403: Forbidden")
    monkeypatch.setattr(exits, "ytdlp", fake)
    job = _claim(phone, tid)
    assert exits.fetch(phone, job) == "handed_back"
    assert fake.calls == ["ask", "direct"], "nothing came through the phone"
    j = db.one("select state, attempts from jobs where id=%s", (job["id"],))
    assert j["state"] == "pending" and j["attempts"] == 0, "given back unspent"

    # Without that computer, the phone's data carries it: the person said it may.
    db.run("delete from workers where name=%s", (f"device:{other}",))
    assert exits.fetch(phone, _claim(phone, tid)) == "ready"


def test_a_phone_told_not_to_use_its_data_does_not(client, hdr, phone, a_song, monkeypatch):
    tid = _song(client, hdr, "EXIT0000004")
    phone.state.update(network="cellular", mobile_data=False)
    monkeypatch.setattr(exits, "ytdlp", FakeYtdlp(a_song, direct="ERROR: HTTP Error 403"))
    assert exits.fetch(phone, _claim(phone, tid)) == "handed_back"
    assert db.one("select state from tracks where id=%s", (tid,))["state"] != "ready"


def test_youtube_pushing_back_cools_that_address_not_the_song(client, hdr, phone, a_song,
                                                              monkeypatch):
    tid = _song(client, hdr, "EXIT0000005")
    monkeypatch.setattr(exits, "ytdlp", FakeYtdlp(
        a_song, ask="ERROR: [youtube] EXIT0000005: Sign in to confirm you're not a bot"))
    job = _claim(phone, tid)
    assert exits.fetch(phone, job) == "cooling"
    assert db.one("select state, attempts from jobs where id=%s",
                  (job["id"],)) == {"state": "pending", "attempts": 0}
    assert exits.cooling(phone) > 500
    # And nothing more is asked through it while it cools.
    assert exits.want(phone.device_id, [tid]) == 0
    # Another phone in the same house is the same address to YouTube.
    neighbour = exits.Exit(None, {"id": 1, "user_id": 1}, "192.0.2.7")
    assert exits.cooling(neighbour) > 0


def test_a_song_that_is_gone_is_written_off(client, hdr, phone, a_song, monkeypatch):
    tid = _song(client, hdr, "EXIT0000006")
    monkeypatch.setattr(exits, "ytdlp", FakeYtdlp(
        a_song, ask="ERROR: [youtube] EXIT0000006: Video unavailable"))
    job = _claim(phone, tid)
    assert exits.fetch(phone, job) == "failed"
    assert db.one("select state from jobs where id=%s", (job["id"],))["state"] == "failed"
    t = db.one("select state, fail_code from tracks where id=%s", (tid,))
    assert t == {"state": "failed", "fail_code": "unavailable"}


def test_a_phone_that_goes_away_mid_question_gives_the_song_back(client, hdr, phone,
                                                                 a_song, monkeypatch):
    tid = _song(client, hdr, "EXIT0000007")
    monkeypatch.setattr(exits, "ytdlp", FakeYtdlp(
        a_song, ask="ERROR: Unable to download webpage: Connection reset by peer",
        during=phone.gone.set))
    job = _claim(phone, tid)
    assert exits.fetch(phone, job) == "lost"
    assert db.one("select state, attempts from jobs where id=%s",
                  (job["id"],)) == {"state": "pending", "attempts": 0}


class _Now:
    """The runner's thread pool, run on the spot so a test can watch it."""

    def submit(self, fn, *args):
        fn(*args)


def test_what_a_phone_is_about_to_play_is_fetched_through_it(client, hdr, phone, a_song,
                                                             monkeypatch):
    ids = [_song(client, hdr, f"EXIT00001{n:02d}") for n in range(3)]
    fake = FakeYtdlp(a_song)
    monkeypatch.setattr(exits, "ytdlp", fake)
    monkeypatch.setattr(exits, "_pool", _Now())
    r = client.post("/downloads/promote", headers=hdr, json={"track_ids": ids})
    assert r.status_code == 200 and r.json()["through_this_device"] >= 1
    assert {t["state"] for t in db.all_("select state from tracks where id = any(%s)",
                                        (ids,))} == {"ready"}
    assert fake.calls.count("ask") == 3
    # Once tried, not asked again at the next change of song.
    assert exits.want(phone.device_id, ids) == 0


def test_a_device_without_an_open_door_changes_nothing(client, hdr, monkeypatch):
    tid = _song(client, hdr, "EXIT0000008")
    called = []
    monkeypatch.setattr(exits, "ytdlp", lambda *a, **k: called.append(a))
    r = client.post("/downloads/promote", headers=hdr, json={"track_ids": [tid]})
    assert r.json()["through_this_device"] == 0 and not called


# ------------------------------------------------------------------ the door itself
def test_the_door_opens_for_a_signed_in_device(client, hdr, token):
    from muse import auth
    device = db.one("select id from devices where token_hash=%s",
                    (auth.token_hash(token),))["id"]
    with client.websocket_connect("/internal/exit", headers=hdr) as ws:
        kind, sid = exits._HEAD.unpack_from(said := ws.receive_bytes())
        assert (kind, sid) == (exits.HELLO, 0)
        assert json.loads(said[exits._HEAD.size:])["ok"] is True
        ws.send_bytes(exits.frame(exits.HELLO, 0, json.dumps(
            {"network": "cellular", "mobile_data": False, "platform": "ios",
             "ignored": "yes"}).encode()))
        # The status the app reads, and the pool screen, both know.
        for _ in range(50):
            ex = exits.exit_for(device)
            if ex and ex.state:
                break
            client.get("/status", headers=hdr)
        assert ex.state == {"network": "cellular", "mobile_data": False, "platform": "ios"}
        assert client.get("/status", headers=hdr).json()["fetching_through_here"] is True
        pooled = client.get("/pool", headers=hdr).json()["exits"]
        assert [e["device_id"] for e in pooled] == [device]
        assert pooled[0]["network"] == "cellular"
    for _ in range(50):
        if exits.exit_for(device) is None:
            break
        client.get("/status", headers=hdr)
    assert exits.exit_for(device) is None, "closed with the socket"


def test_the_door_stays_shut_without_a_token_or_for_a_blocked_device(client, hdr, token):
    from starlette.websockets import WebSocketDisconnect

    from muse import auth
    with pytest.raises(WebSocketDisconnect):
        with client.websocket_connect("/internal/exit",
                                      headers={"Authorization": "Bearer nonsense"}) as ws:
            ws.receive_bytes()
    device = db.one("select id from devices where token_hash=%s",
                    (auth.token_hash(token),))["id"]
    db.run("update devices set pool_blocked=true where id=%s", (device,))
    with client.websocket_connect("/internal/exit", headers=hdr) as ws:
        said = ws.receive_bytes()
        assert json.loads(said[exits._HEAD.size:])["ok"] is False
        with pytest.raises(WebSocketDisconnect):
            ws.receive_bytes()
    assert exits.exit_for(device) is None
