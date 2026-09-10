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
        case _:
            sys.exit("usage: python -m muse.cli [adduser <name> | secret "
                     "| splitartists [--apply] | fixsoundcloud [--apply]]")


if __name__ == "__main__":
    main()
