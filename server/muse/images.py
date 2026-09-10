"""Pictures people choose themselves: a profile photo, a cover for a playlist.

Everything else here draws its own art — a record has a sleeve, a playlist without one
gets a picture made from the records in it. This is the other case: somebody has a
picture in mind and wants it used. What arrives is whatever their phone had, so it is
squared off, shrunk to something a list can draw quickly, and written under a name that
carries a signature — which is what lets a client cache it forever and still see it
change the moment it does.
"""
from __future__ import annotations

import hashlib
import io
import pathlib

from PIL import Image, ImageOps

# Big enough to look right as a full-screen header on a phone, small enough that a list
# of forty of them is not a download.
SIZES = {"lg": 640, "sm": 128}

MAX_BYTES = 12 * 1024 * 1024


class BadImage(ValueError):
    """What arrived is not a picture anything can open."""


def store(directory: pathlib.Path, kind: str, owner_id: int, raw: bytes) -> str:
    """Square it, shrink it, write it, and answer with its signature."""
    if not raw:
        raise BadImage("that file is empty")
    if len(raw) > MAX_BYTES:
        raise BadImage("pictures have to be under 12 MB")
    try:
        source = Image.open(io.BytesIO(raw))
        source.load()
    except Exception as e:
        raise BadImage("that file is not a picture") from e

    # The signature is of the bytes that arrived, so re-uploading the same picture is
    # the same URL and nothing has to be re-fetched.
    sig = hashlib.sha256(raw).hexdigest()[:12]
    directory.mkdir(parents=True, exist_ok=True)

    # A photo carries its rotation in the metadata; without this a portrait picture
    # arrives on its side.
    squared = ImageOps.exif_transpose(source).convert("RGB")
    squared = ImageOps.fit(squared, (max(SIZES.values()),) * 2,
                           method=Image.LANCZOS, centering=(0.5, 0.4))
    for name, px in SIZES.items():
        out = squared if px == max(SIZES.values()) else squared.resize(
            (px, px), Image.LANCZOS)
        out.save(path_for(directory, kind, owner_id, sig, name), "JPEG",
                 quality=88, optimize=True)
    return sig


def path_for(directory: pathlib.Path, kind: str, owner_id: int, sig: str,
             size: str = "lg") -> pathlib.Path:
    return directory / f"{kind}-{owner_id}-{sig}-{size}.jpg"


def forget(directory: pathlib.Path, kind: str, owner_id: int, sig: str) -> None:
    for size in SIZES:
        path_for(directory, kind, owner_id, sig, size).unlink(missing_ok=True)
