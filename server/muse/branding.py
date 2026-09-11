"""The picture on the home screen.

The app ships with an icon, and the icon is the kind of thing somebody wants to change
without waiting for a new build — so it is served rather than baked in. The web app's
manifest, its favicon and the iOS home-screen icon all point here, and an admin can put
a different picture behind them at any time.

Rendered once per size and kept on disk under the source picture's signature, so the
browser can be told "the same one as last time" with an ETag and nothing is re-squared
per request. The Android launcher icon is the one exception, and it cannot be anything
else: that one is inside the installed APK.
"""
from __future__ import annotations

import hashlib
import io
import pathlib

from PIL import Image, ImageOps

SHIPPED = pathlib.Path(__file__).with_name("assets") / "app_icon.png"

# What a browser, a phone and a desktop actually ask for. Anything else is served by
# the nearest one at or above it.
SIZES = (32, 64, 128, 180, 192, 256, 512, 1024)

MAX_BYTES = 12 * 1024 * 1024


class BadImage(ValueError):
    """What arrived is not a picture anything can open."""


def _dir(data_dir: pathlib.Path) -> pathlib.Path:
    out = data_dir / "branding"
    out.mkdir(parents=True, exist_ok=True)
    return out


def _source(data_dir: pathlib.Path) -> pathlib.Path:
    """The picture in use: the uploaded one if there is one, else the shipped one."""
    chosen = _dir(data_dir) / "icon.png"
    return chosen if chosen.exists() else SHIPPED


def signature(data_dir: pathlib.Path) -> str:
    """A short name for the picture in use, which changes when the picture does."""
    source = _source(data_dir)
    try:
        raw = source.read_bytes()
    except OSError:
        return "none"
    return hashlib.sha256(raw).hexdigest()[:16]


def custom(data_dir: pathlib.Path) -> bool:
    """True when somebody has chosen a picture, rather than the one it came with."""
    return (_dir(data_dir) / "icon.png").exists()


def nearest(size: int) -> int:
    for s in SIZES:
        if s >= size:
            return s
    return SIZES[-1]


def render(data_dir: pathlib.Path, size: int) -> pathlib.Path:
    """The icon at this size, rendered if it has not been asked for before."""
    want = nearest(size)
    sig = signature(data_dir)
    out = _dir(data_dir) / f"icon-{sig}-{want}.png"
    if out.exists():
        return out
    with Image.open(_source(data_dir)) as source:
        # Squared off from the middle rather than letterboxed: a launcher crops it to
        # whatever shape it likes and bars at the edges become bars in a circle.
        icon = ImageOps.fit(source.convert("RGB"), (want, want), Image.LANCZOS)
        icon.save(out, format="PNG", optimize=True)
    return out


def store(data_dir: pathlib.Path, raw: bytes) -> str:
    """Take a new picture, and answer with its signature."""
    if not raw:
        raise BadImage("that file is empty")
    if len(raw) > MAX_BYTES:
        raise BadImage("pictures have to be under 12 MB")
    try:
        with Image.open(io.BytesIO(raw)) as source:
            source.load()
            squared = ImageOps.fit(source.convert("RGB"), (1024, 1024), Image.LANCZOS)
    except BadImage:
        raise
    except Exception as e:
        raise BadImage("that file is not a picture") from e

    forget(data_dir)
    squared.save(_dir(data_dir) / "icon.png", format="PNG", optimize=True)
    return signature(data_dir)


def forget(data_dir: pathlib.Path) -> None:
    """Back to the one it came with. The rendered sizes go too, or the old picture
    keeps being served under its own signature for ever."""
    for stale in _dir(data_dir).glob("icon*.png"):
        try:
            stale.unlink()
        except OSError:
            pass
