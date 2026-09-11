"""Songs Shazam recognised, brought over here.

There is no way to ask Shazam what somebody has tagged — it has no API for your own
library — but it will hand the whole thing over as a CSV from the web player, and that
is the same shape as every other import here: a list of names and a time each one
happened.

Parsing is deliberately forgiving. The file has a title line before the header, the
column names have moved about between versions, and a person exporting their library is
not going to enjoy being told their file is the wrong shape. Anything with a title and
an artist in it is a tag.
"""
from __future__ import annotations

import csv
import io
import re
from datetime import datetime, timezone

# What the columns have been called, in the order they are looked for.
_TITLE = ("title", "track", "song", "name")
_ARTIST = ("artist", "artists", "artist name")
_WHEN = ("tagtime", "tag time", "date", "time", "taggedat", "tagged at")
_URL = ("url", "link", "shazam url")
_KEY = ("trackkey", "track key", "key", "id", "trackid")


def _column(header: list[str], names: tuple[str, ...]) -> int | None:
    tidy = [re.sub(r"[^a-z ]", "", h.strip().lower()) for h in header]
    for name in names:
        if name in tidy:
            return tidy.index(name)
    return None


def _when(raw: str | None) -> datetime | None:
    """Shazam writes UTC in a handful of shapes and none of them are ISO."""
    if not raw:
        return None
    text = raw.strip().replace("UTC", "").strip()
    for shape in ("%Y-%m-%d %H:%M:%S", "%Y-%m-%dT%H:%M:%S", "%d/%m/%Y %H:%M:%S",
                  "%Y-%m-%d %H:%M", "%Y-%m-%d"):
        try:
            return datetime.strptime(text[:len(shape) + 4], shape).replace(
                tzinfo=timezone.utc)
        except ValueError:
            continue
    return None


def read(text: str) -> list[dict]:
    """Every tag in an exported library, in the order the file lists them.

    A row with no title is not a tag, whatever else is on it — that is the file's own
    header, or the blank line at the end, or the line that says "Shazam Library".
    """
    rows = list(csv.reader(io.StringIO(text)))
    header = None
    columns: dict[str, int | None] = {}
    out: list[dict] = []

    for row in rows:
        if not row or not any(cell.strip() for cell in row):
            continue
        if header is None:
            # The first row that names both a title and an artist is the header. Until
            # then everything is preamble, whatever it says.
            title_at = _column(row, _TITLE)
            artist_at = _column(row, _ARTIST)
            if title_at is not None and artist_at is not None:
                header = row
                columns = {
                    "title": title_at,
                    "artist": artist_at,
                    "when": _column(row, _WHEN),
                    "url": _column(row, _URL),
                    "key": _column(row, _KEY),
                }
            continue

        def cell(which: str) -> str | None:
            at = columns.get(which)
            if at is None or at >= len(row):
                return None
            value = row[at].strip()
            return value or None

        title = cell("title")
        if not title:
            continue
        artist = cell("artist")
        url = cell("url")
        key = cell("key")
        if not key:
            # No id in this export. The song and the moment together are as good — two
            # tags of the same song seconds apart are one tag as far as anybody cares,
            # and the same song tagged on two different nights is two.
            when = cell("when") or ""
            key = f"{title.lower()}|{(artist or '').lower()}|{when[:16]}"
        out.append({
            "tag_key": key[:200],
            "title": title[:300],
            "artist": artist[:300] if artist else None,
            "tagged_at": _when(cell("when")),
            "url": url[:500] if url else None,
        })
    return out


def match_some(user_id: int, limit: int = 40) -> dict:
    """Find the next few unlooked-at tags in the catalogue.

    A few at a time rather than all of them: each one is a search, a library of a
    thousand tags is a thousand searches, and a job that takes twenty minutes is a job
    that gets its lease taken away halfway through. Whatever is left queues another.
    """
    from . import db, match, sync

    rows = db.all_(
        """select id, title, artist from shazams
            where user_id=%s and track_id is null and looked_at is null
            order by tagged_at desc nulls last, id desc limit %s""",
        (user_id, limit),
    )
    found = 0
    for row in rows:
        item = {
            "remote_id": f"shazam:{row['id']}",
            "title": row["title"],
            "artists": [row["artist"]] if row["artist"] else [],
            "duration_ms": None,
            "isrc": None,
        }
        try:
            # The same machinery every other import uses: an ISRC we already hold ends
            # the question, and otherwise it is a scored search with a threshold. A tag
            # is a title and an artist and nothing else, so there is no reason for this
            # to be its own kind of guess.
            outcome = sync.resolve_item("shazam", item, download=False)
        except Exception:
            # A search that failed is not an answer. Left unlooked-at so it is tried
            # again rather than written off as "nothing matches".
            continue
        confidence = outcome.get("confidence")
        db.run(
            """update shazams set track_id=%s, confidence=%s, looked_at=now()
                where id=%s""",
            (outcome.get("track_id"), confidence, row["id"]),
        )
        if outcome.get("track_id"):
            found += 1

    left = db.one(
        """select count(*) n from shazams
            where user_id=%s and track_id is null and looked_at is null""",
        (user_id,),
    )["n"]
    return {"looked_at": len(rows), "found": found, "left": left,
            "threshold": match.AUTO_ACCEPT}
