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


def store_stream(root: pathlib.Path, src, ext: str = ".m4a") -> tuple[str, pathlib.Path, int]:
    """Write an incoming stream to a temp file, hash it, move it into place."""
    root.mkdir(parents=True, exist_ok=True)
    h = hashlib.sha256()
    size = 0
    with tempfile.NamedTemporaryFile(dir=root, delete=False) as tmp:
        tmp_path = pathlib.Path(tmp.name)
        while chunk := src.read(1 << 20):
            h.update(chunk)
            size += len(chunk)
            tmp.write(chunk)
    digest = h.hexdigest()
    dest = blob_path(root, digest, ext)
    dest.parent.mkdir(parents=True, exist_ok=True)
    if dest.exists():
        tmp_path.unlink(missing_ok=True)   # already had this exact rip
    else:
        shutil.move(tmp_path, dest)
    return digest, dest, size
