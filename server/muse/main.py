from __future__ import annotations

import uvicorn

from . import config
from .app import create_app

cfg = config.load()
app = create_app(cfg, start_workers=True)


def run() -> None:
    uvicorn.run(app, host=cfg.host, port=cfg.port, log_level="info")


if __name__ == "__main__":
    run()
