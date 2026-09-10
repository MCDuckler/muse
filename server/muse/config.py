"""Config is a file on disk, not a database. There is no signup."""
from __future__ import annotations

import os
import pathlib
import tomllib
from dataclasses import dataclass, field


@dataclass(frozen=True)
class User:
    name: str
    password_hash: str


@dataclass(frozen=True)
class Config:
    dsn: str
    data_dir: pathlib.Path
    worker_secret: str
    host: str = "127.0.0.1"
    port: int = 8770
    public_url: str = "http://127.0.0.1:8770"
    users: tuple[User, ...] = field(default_factory=tuple)
    spotify: dict = field(default_factory=dict)
    ytmusic: dict = field(default_factory=dict)
    # Empty by default: the app is served from this same origin in production, so
    # nothing needs CORS. It is opt-in for a dev build or an integration test running
    # on localhost against a deployed server.
    cors_origins: tuple[str, ...] = field(default_factory=tuple)
    cors_origin_regex: str = ""

    @property
    def audio_dir(self) -> pathlib.Path:
        return self.data_dir / "audio"

    @property
    def cover_dir(self) -> pathlib.Path:
        return self.data_dir / "covers"

    @property
    def image_dir(self) -> pathlib.Path:
        """Pictures people chose: profile photos, playlist covers."""
        return self.data_dir / "images"

    def user(self, name: str) -> User | None:
        return next((u for u in self.users if u.name == name), None)


def load(path: str | os.PathLike | None = None) -> Config:
    p = pathlib.Path(path or os.environ.get("MUSE_CONFIG", "muse.toml")).expanduser()
    if not p.exists():
        raise SystemExit(
            f"no config at {p}. Copy muse.example.toml to muse.toml and add a user "
            f"with:  python -m muse.cli adduser <name>"
        )
    raw = tomllib.loads(p.read_text())
    srv, db = raw.get("server", {}), raw.get("database", {})
    data_dir = pathlib.Path(srv.get("data_dir", "~/.local/share/muse-data")).expanduser()
    cfg = Config(
        dsn=db["dsn"],
        data_dir=data_dir,
        worker_secret=raw.get("worker", {}).get("secret", ""),
        host=srv.get("host", "127.0.0.1"),
        port=int(srv.get("port", 8770)),
        public_url=srv.get("public_url", f"http://{srv.get('host','127.0.0.1')}:{srv.get('port',8770)}"),
        users=tuple(User(u["name"], u["password_hash"]) for u in raw.get("users", [])),
        cors_origins=tuple(srv.get("cors_origins", [])),
        cors_origin_regex=srv.get("cors_origin_regex", ""),
        spotify=raw.get("spotify", {}),
        ytmusic=raw.get("ytmusic", {}),
    )
    if not cfg.worker_secret:
        raise SystemExit("worker.secret is empty — the ingest worker would be unauthenticated")
    cfg.audio_dir.mkdir(parents=True, exist_ok=True)
    cfg.cover_dir.mkdir(parents=True, exist_ok=True)
    return cfg
