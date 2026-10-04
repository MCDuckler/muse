"""The face a playlist shows: the picture it has elsewhere, kept here.

A mirrored playlist is recognisable by its art before it is readable by its name, and
the art muse draws for a playlist with no cover (see playlist_art) is for playlists that
have none. So whichever service a list comes from, its own picture is fetched once and
stored like any chosen cover — under the playlist's id, named by its signature — and it
survives and caches the same way.

Both mirror paths (Spotify, and the linked services) used to do this differently: the
Spotify one fetched the picture, the linked ones never did. This is the one place.
"""
from __future__ import annotations

import logging
import shutil
import urllib.request

from . import db, images
from .deps import cfg

log = logging.getLogger("muse.covers")


def take(playlist_id: int, url: str | None) -> bool:
    """Keep the playlist's own picture, if it has one. True when the cover changed.

    The address it came from is kept beside the signature: a mirror is refreshed every
    so often, and the same address need not be downloaded again to find out it is the
    same picture. A different address — Spotify remakes its mosaics — is.
    """
    if not url:
        return False
    row = db.one("select cover_sig, cover_src from playlists where id=%s", (playlist_id,))
    if not row:
        return False
    if row["cover_sig"] and row["cover_src"] == url and \
            images.path_for(cfg().image_dir, "playlist", playlist_id,
                            row["cover_sig"]).exists():
        return False
    try:
        with urllib.request.urlopen(url, timeout=20) as r:
            raw = r.read(images.MAX_BYTES + 1)
        sig = images.store(cfg().image_dir, "playlist", playlist_id, raw)
    except Exception as e:                        # noqa: BLE001 - art is not the point
        log.info("could not take the cover for playlist %s: %s", playlist_id, e)
        return False
    db.run("update playlists set cover_sig=%s, cover_src=%s where id=%s",
           (sig, url, playlist_id))
    if row["cover_sig"] and row["cover_sig"] != sig:
        images.forget(cfg().image_dir, "playlist", playlist_id, row["cover_sig"])
    return row["cover_sig"] != sig


def copy(from_id: int, to_id: int) -> bool:
    """A copy of a playlist keeps its face. True when there was one to keep.

    The files are copied rather than re-stored: the signature is of the bytes that
    arrived, and the copy should be the same picture at the same version.
    """
    source = db.one("select cover_sig, cover_src from playlists where id=%s", (from_id,))
    if not source or not source["cover_sig"]:
        return False
    sig = source["cover_sig"]
    root = cfg().image_dir
    copied = 0
    for size in images.SIZES:
        here = images.path_for(root, "playlist", from_id, sig, size)
        if here.exists():
            shutil.copyfile(here, images.path_for(root, "playlist", to_id, sig, size))
            copied += 1
    if not copied:
        # The row says there is a picture and the disk says there is not: the copy is
        # better off drawing its own than pointing at nothing.
        return False
    db.run("update playlists set cover_sig=%s, cover_src=%s where id=%s",
           (sig, source["cover_src"], to_id))
    return True
