"""Content-addressed blobs: two playlists pointing at the same rip cost one file."""
from __future__ import annotations

import hashlib
import pathlib
import shutil
import tempfile


def sha256_file(path: pathlib.Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def blob_path(root: pathlib.Path, digest: str, ext: str) -> pathlib.Path:
    return root / digest[:2] / f"{digest}{ext}"


class TooBig(ValueError):
    """More than [limit] bytes came in."""


class NotAccepted(ValueError):
    """The file that came in is not what it was said to be."""


def store_stream(root: pathlib.Path, src, ext: str = ".m4a", *, limit: int | None = None,
                 accept=None) -> tuple[str, pathlib.Path, int]:
    """Write an incoming stream to a temp file, hash it, move it into place.

    `limit` is counted as the bytes come in, not read off a header the sender wrote.
    `accept(path)` is asked about the whole file before it is kept and answers with what
    is wrong or None; a file it turns down is deleted, and never lands where it would be
    served from.
    """
    root.mkdir(parents=True, exist_ok=True)
    h = hashlib.sha256()
    size = 0
    with tempfile.NamedTemporaryFile(dir=root, delete=False) as tmp:
        tmp_path = pathlib.Path(tmp.name)
        while chunk := src.read(1 << 20):
            size += len(chunk)
            if limit is not None and size > limit:
                tmp.close()
                tmp_path.unlink(missing_ok=True)
                raise TooBig(f"more than {limit} bytes")
            h.update(chunk)
            tmp.write(chunk)
    if accept is not None and (why := accept(tmp_path)):
        tmp_path.unlink(missing_ok=True)
        raise NotAccepted(why)
    digest = h.hexdigest()
    dest = blob_path(root, digest, ext)
    dest.parent.mkdir(parents=True, exist_ok=True)
    if dest.exists():
        tmp_path.unlink(missing_ok=True)   # already had this exact rip
    else:
        shutil.move(tmp_path, dest)
    return digest, dest, size
