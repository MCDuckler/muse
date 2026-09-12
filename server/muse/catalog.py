"""Track rows: how they are read, shaped for clients, and created from a provider hit."""
from __future__ import annotations

import json
import re
import unicodedata

from . import artists, db, jobs, progress

# Where a track came into the library. Radio pulls in songs nobody asked for, so they
# stay identifiable for a future cleanup.
VIA_USER, VIA_RADIO, VIA_SYNC = "user", "radio", "sync"

# Markers a video platform adds that say nothing about the recording. Deliberately
# conservative: "(Radio Edit)" and "(feat. …)" stay, because those distinguish one
# recording from another and dropping them would be a lie about what is playing.
_NOISE = re.compile(
    r"\s*[\(\[]\s*(official\s+(music\s+)?video|official\s+audio|lyrics?\s*video"
    r"|visualizer|audio only|hd|hq|4k)\s*[^\)\]]*[\)\]]",
    re.I,
)
_TRAILING = re.compile(r"\s*[-–]\s*(official\s+.*|.*\bvisualizer\b.*)$", re.I)

# A dash, a pipe, or the fancier dashes a video platform's title might use.
_SPLIT = r"\s*[-–—|]\s*"
# What a channel calls itself when it is really an artist's release channel.
_CHANNEL = re.compile(r"\s*[-–—]\s*(topic|official|vevo)\s*$", re.I)


def _same(a: str, b: str) -> bool:
    """Loosely the same name: case, spacing, punctuation and accents aside.

    Accents especially — a video's title spells the artist "Tiesto" about as often as
    the library spells it "Tiësto", and a comparison that calls those two different
    names leaves the artist in the title of exactly the songs most likely to have it.
    """
    def flat(s: str) -> str:
        bare = unicodedata.normalize("NFKD", s)
        bare = "".join(c for c in bare if not unicodedata.combining(c))
        return re.sub(r"[^0-9a-z]+", "", bare.lower())
    return bool(flat(a)) and flat(a) == flat(b)


def _without_the_artist(title: str, artists: list[str] | None) -> str:
    """Drop a leading "Artist - " from a title that is already filed under Artist.

    Uploads name themselves that way because on a video platform there is nowhere else
    to put it. Here there is: the artist is on the row underneath, so the title saying
    it again is the same word twice — and worse, it is the half of the line that gets
    cut when there is not room, so the song's own name is the part that disappears.

    Only when the front of the title really is the artist this track is filed under.
    A song genuinely called "Hurricane - Part Two" keeps its name, and so does
    "Beethoven: Symphony No. 5", because a colon is not one of the separators here.
    """
    if not title or not artists:
        return title

    names: list[str] = []
    for a in artists:
        if not a:
            continue
        names.append(a)
        # "Somebody - Topic" is a channel, and the name in front of it is the artist.
        shorter = _CHANNEL.sub("", a)
        if shorter != a:
            names.append(shorter)
    # Everybody at once as well: a title may name the pair the track is filed under.
    if len(artists) > 1:
        names += [j.join(artists) for j in (", ", " & ", " and ", " x ", " X ")]

    # Every place the title could be cut, not only the first: an artist's own name may
    # have a dash in it, and cutting at the first one would never match it.
    def cut(text: str) -> str | None:
        # From the last possible cut back to the first, so the longest name that
        # matches wins: an artist called "Somebody - Topic" has to beat "Somebody".
        for sep in reversed(list(re.finditer(_SPLIT, text))):
            head = text[:sep.start()].strip()
            tail = text[sep.end():].strip()
            if tail and any(_same(head, n) for n in names):
                return tail
        return None

    # Twice at most: "Artist - Artist - Song" happens, three deep does not.
    for _ in range(2):
        shorter = cut(title)
        if shorter is None:
            break
        title = shorter
    return title


def display_title(raw: str | None, artists: list[str] | None = None) -> str:
    if not raw:
        return ""
    cleaned = _TRAILING.sub("", _NOISE.sub("", raw)).strip() or raw
    return _without_the_artist(cleaned, artists) or cleaned


def track_row(track_id: int) -> dict | None:
    return db.one(
        """select t.*, m.bytes, m.path, m.sha256, m.codec, m.bitrate,
                  s.provider, s.provider_id, c.color as cover_color,
                  c.sha256 as cover_sha
             from tracks t
             left join media m on m.track_id=t.id and m.role='canonical'
             left join track_sources s on s.track_id=t.id
             left join covers c on c.id=t.cover_id
            where t.id=%s""",
        (track_id,),
    )


def public(t: dict) -> dict:
    return {
        "id": t["id"],
        "title": t["title"],
        "display_title": display_title(t["title"], t.get("artists")),
        "cover_url": f"/tracks/{t['id']}/cover" if t.get("cover_id") else None,
        "cover_color": t.get("cover_color"),
        # Changes when the artwork does, so a client that cached the old image by URL
        # does not keep showing it.
        "cover_version": (t.get("cover_sha") or "")[:8] or None,
        "artists": t["artists"],
        "album": t["album"],
        "duration_ms": t["duration_ms"],
        "state": t["state"],
        "fail_reason": t["fail_reason"],
        "fail_code": t.get("fail_code"),
        # Live ingest state, so a row can show what is happening rather than a spinner
        # that means "something, for some length of time".
        "progress": progress.get(t["id"]),
        "source": t["source"],
        "discovered_via": t.get("discovered_via"),
        "gain_db": t["gain_db"],
        "loudness_lufs": t["loudness_lufs"],
        "bytes": t.get("bytes"),
        "provider_id": t.get("provider_id"),
        "stream_url": f"/tracks/{t['id']}/stream" if t.get("path") else None,
    }


def find_by_video_id(video_id: str) -> dict | None:
    row = db.one(
        "select track_id from track_sources where provider='ytmusic' and provider_id=%s",
        (video_id,),
    )
    return track_row(row["track_id"]) if row else None


def credits(names) -> list[str]:
    """The artists in a credit, one per entry.

    "Hugh Hardie, Kyan" arriving as a single string makes the pair a third artist with
    one record to their name. muse.artists does the splitting, and the checking that
    stops "Fujiya & Miyagi" becoming two people.
    """
    return artists.split_all(names, verify=artists.deezer_verifier())


def create_from_source(provider: str, meta: dict, discovered_via: str = VIA_USER,
                       priority: int = jobs.PRIORITY_NORMAL,
                       batch_id: str | None = None,
                       batch_label: str | None = None,
                       download: bool = True) -> dict:
    """A track from somewhere the server fetches itself: SoundCloud, Bandcamp.

    Same shape as the YouTube path, different lane. The job goes to `ingest_direct`,
    which runs in this process rather than on the machine at home, because these two
    do not care that the request comes from a datacenter.
    """
    row = db.one(
        """insert into tracks(title,artists,album,duration_ms,source,state,
                              discovered_via,isrc)
           values(%s,%s,%s,%s,%s,'pending',%s,%s) returning id""",
        (meta["title"], credits(meta.get("artists")), meta.get("album"),
         meta.get("duration_ms"), provider, discovered_via,
         (meta.get("isrc") or None)),
    )
    # The page URL travels with the row, whatever shape the metadata arrived in. A
    # backup file from another player calls it `pageUrl`; keeping `url` beside it is
    # what lets this track be queued again months later without going back to the file.
    raw = dict(meta.get("raw") or meta)
    if meta.get("url") and not raw.get("url"):
        raw["url"] = meta["url"]
    db.run(
        "insert into track_sources(track_id,provider,provider_id,raw) values(%s,%s,%s,%s)",
        (row["id"], provider, meta["provider_id"], json.dumps(raw)),
    )
    if download:
        jobs.enqueue("ingest_direct",
                     {"track_id": row["id"], "provider": provider,
                      "ref": meta.get("url") or meta["provider_id"]},
                     priority=priority, batch_id=batch_id, batch_label=batch_label)
    jobs.enqueue("meta", {"track_id": row["id"]}, batch_id=batch_id)
    return track_row(row["id"])


def remember(user_id: int, *track_ids: int) -> None:
    """Put a track in someone's library.

    Adding to a playlist or a queue does this by itself — the database does it, so no
    caller can forget — but a track resolved straight from a search belongs to whoever
    asked for it before it has landed anywhere.
    """
    ids = [t for t in track_ids if t]
    if not ids:
        return
    db.run(
        """insert into library_items(user_id, track_id)
           select %s, unnest(%s::int[]) on conflict do nothing""",
        (user_id, ids),
    )


def find_by_isrc(isrc: str | None) -> dict | None:
    """The same recording, whatever it was called on the way in.

    An ISRC is assigned to a recording, not to a release or a spelling, so this is what
    lets a song already in the library be recognised when it arrives again from another
    service — no second download, no second row, no wrong take.
    """
    if not isrc:
        return None
    row = db.one(
        """select id from tracks where isrc = upper(%s)
            order by (state='ready') desc, id limit 1""",
        (isrc.strip(),),
    )
    return track_row(row["id"]) if row else None


def find_by_provider(provider: str, provider_id: str) -> dict | None:
    row = db.one(
        """select track_id from track_sources
            where provider=%s and provider_id=%s order by track_id limit 1""",
        (provider, provider_id),
    )
    return track_row(row["track_id"]) if row else None


def create_from_ytm(meta: dict, discovered_via: str = VIA_USER,
                    priority: int = jobs.PRIORITY_NORMAL,
                    batch_id: str | None = None,
                    batch_label: str | None = None,
                    download: bool = True) -> dict:
    """New track row in `pending`, and usually the ingest job with it.

    `download=False` records the track without queueing the audio. A library of twelve
    thousand liked songs is a list worth having long before it is forty gigabytes worth
    having, so those arrive when somebody actually plays them.
    """
    row = db.one(
        """insert into tracks(title,artists,album,duration_ms,source,state,
                              discovered_via,isrc)
           values(%s,%s,%s,%s,'youtube','pending',%s,%s) returning id""",
        (meta["title"], credits(meta["artists"]), meta["album"], meta["duration_ms"],
         discovered_via, (meta.get("isrc") or None)),
    )
    db.run(
        "insert into track_sources(track_id,provider,provider_id,raw) values(%s,'ytmusic',%s,%s)",
        (row["id"], meta["video_id"], json.dumps(meta.get("raw") or {})),
    )
    if download:
        jobs.enqueue("ingest", {"track_id": row["id"], "video_id": meta["video_id"]},
                     priority=priority, batch_id=batch_id, batch_label=batch_label)
    # Artwork does not depend on the audio, and a queue row with a cover while it
    # downloads is far better than a grey square that fills in minutes later.
    jobs.enqueue("meta", {"track_id": row["id"]}, batch_id=batch_id)
    return track_row(row["id"])


def retry(track_id: int, video_id: str) -> dict:
    db.run("update tracks set state='pending', fail_reason=null where id=%s", (track_id,))
    jobs.enqueue("ingest", {"track_id": track_id, "video_id": video_id})
    return track_row(track_id)
