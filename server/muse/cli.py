"""muse admin CLI — there is no signup, users are added here and land in muse.toml.

Also the one-off jobs that are not worth an endpoint: rewriting the artist credits
already in the library, for instance.
"""
from __future__ import annotations

import getpass
import secrets
import sys

from . import artists, auth


def adduser(name: str) -> None:
    pw = getpass.getpass(f"password for {name}: ")
    if pw != getpass.getpass("again: "):
        sys.exit("passwords differ")
    print("\nAdd this to muse.toml:\n")
    print("[[users]]")
    print(f'name = "{name}"')
    print(f'password_hash = "{auth.hash_password(pw)}"')


def secret() -> None:
    print(secrets.token_urlsafe(32))


def splitartists(apply: bool = False) -> None:
    """Split credits already in the library: "Hugh Hardie, Kyan" into two artists.

    Prints what it would do and changes nothing unless asked, because it cannot be
    undone: once "Fujiya & Miyagi" is two rows there is no way to tell it was ever one.
    """
    from . import config, db

    cfg = config.load()
    db.init(cfg.dsn)
    verify = artists.deezer_verifier()

    rows = db.all_(
        r"""select id, artists from tracks
             where exists (select 1 from unnest(artists) a
                            where a ~ '[,;&+]|\s(feat\.?|ft\.?|featuring|x|vs\.?)\s')
             order by id""",
    )
    print(f"{len(rows)} tracks with a credit that might be more than one artist\n")

    changed = 0
    for row in rows:
        before = row["artists"] or []
        after = artists.split_all(before, verify=verify)
        if after == before:
            continue
        changed += 1
        if changed <= 40 or apply:
            print(f"  {row['id']:>6}  {before}  ->  {after}")
        if apply:
            db.run("update tracks set artists=%s where id=%s", (after, row["id"]))

    print(f"\n{changed} tracks {'updated' if apply else 'would change'}")
    if not apply:
        print("run with --apply to write them")
    db.close()


def fixsoundcloud(apply: bool = False) -> None:
    """Name the SoundCloud tracks that were mirrored before the listing knew names."""
    from . import config, db, linked

    cfg = config.load()
    db.init(cfg.dsn)
    result = linked.repair_soundcloud(apply=apply)
    print(f"{result['looked_at']} nameless tracks, {result['named']} "
          f"{'named' if apply else 'could be named'}, "
          f"{result['still_unknown']} SoundCloud would not describe")
    if not apply:
        print("run with --apply to write them")
    db.close()


def fixspotifynames(apply: bool = False) -> None:
    """Rename the Spotify playlists that ended up named after their own id."""
    from . import config, db, spotify

    cfg = config.load()
    db.init(cfg.dsn)
    rows = db.all_(
        """select id, owner_id, name, remote_id from playlists
            where kind = 'spotify' and name = remote_id order by id""",
    )
    print(f"{len(rows)} playlists named after their id\n")
    fixed = 0
    for row in rows:
        try:
            remote = spotify.playlist(cfg, row["owner_id"], row["remote_id"])
        except Exception as e:                    # noqa: BLE001
            print(f"  {row['remote_id']}: {e}")
            continue
        print(f"  {row['remote_id']}  ->  {remote['name']}")
        fixed += 1
        if apply:
            db.run("update playlists set name=%s, source_name=coalesce(source_name,%s) "
                   "where id=%s", (remote["name"], remote.get("owner"), row["id"]))
    print(f"\n{fixed} {'renamed' if apply else 'could be renamed'}")
    if not apply:
        print("run with --apply to write them")
    db.close()


def markdead(apply: bool = False) -> None:
    """Write off copies that have already been proved gone.

    New failures mark their own source, but the ones that happened before that rule
    existed left nothing behind — so a track that has failed on the same dead video id
    eight times will reach for it a ninth. This reads those failures back out of the
    job log and marks the sources they name, which is what makes asking for those songs
    again reach for a copy that might work.
    """
    from . import config, failures

    db.init(config.load().dsn)
    rows = db.all_(
        """select distinct (j.payload->>'track_id')::int as track_id,
                  j.payload->>'video_id' as provider_id, j.error
             from jobs j
            where j.kind='ingest' and j.state='failed'
              and j.payload->>'video_id' is not null"""
    )
    gone = [r for r in rows if failures.classify(r["error"])[0] in failures.GONE]
    print(f"{len(rows)} failed youtube jobs, {len(gone)} of them for good")
    if not apply:
        print("dry run — pass --apply to write it")
        return
    marked = 0
    for row in gone:
        marked += len(db.all_(
            """update track_sources
                  set raw = coalesce(raw,'{}'::jsonb) || '{"dead": true}'
                where track_id=%s and provider_id=%s
                  and coalesce(raw->>'dead','') <> 'true'
               returning track_id""",
            (row["track_id"], row["provider_id"])))
    print(f"marked {marked} sources dead")


def main() -> None:
    match sys.argv[1:]:
        case ["adduser", name]:
            adduser(name)
        case ["secret"]:
            secret()
        case ["splitartists"]:
            splitartists()
        case ["splitartists", "--apply"]:
            splitartists(apply=True)
        case ["fixsoundcloud"]:
            fixsoundcloud()
        case ["fixsoundcloud", "--apply"]:
            fixsoundcloud(apply=True)
        case ["fixspotifynames"]:
            fixspotifynames()
        case ["fixspotifynames", "--apply"]:
            fixspotifynames(apply=True)
        case ["markdead"]:
            markdead()
        case ["markdead", "--apply"]:
            markdead(apply=True)
        case _:
            sys.exit("usage: python -m muse.cli [adduser <name> | secret "
                     "| splitartists [--apply] | fixsoundcloud [--apply] "
                     "| fixspotifynames [--apply] | markdead [--apply]]")


if __name__ == "__main__":
    main()
