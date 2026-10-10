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


def followscheck(apply: bool = False) -> None:
    """Follows brought over from Bandcamp that went to a Deezer act of the same name
    rather than to the page: put back on the page (follows.recheck). Everybody with a
    Bandcamp account linked; prints what changes, and changes it only with --apply."""
    from . import config, db, follows, linked

    db.init(config.load().dsn)
    users = db.all_("select id, name from users order by id")
    for u in users:
        account = next((a for a in linked.accounts(u["id"]) if a["provider"] == "bandcamp"),
                       None)
        if not account:
            continue
        try:
            entries = linked.following("bandcamp", account["handle"])
        except Exception as e:  # noqa: BLE001
            print(f"{u['name']}: could not read who they follow: {e}")
            continue
        changed = follows.recheck(u["id"], entries, apply=apply)
        if apply and changed:
            from . import discover
            discover.ask_for(u["id"])
        print(f"{u['name']}: {len(entries)} followed on Bandcamp, {len(changed)} to put right")
        for c in changed:
            print(f"   {c['deezer']} (deezer {c['deezer_id']}) -> "
                  f"{c['bandcamp'] or 'unfollowed'}  [{c['why']}]")
    if not apply:
        print("dry run — pass --apply to write it")


def markdead(apply: bool = False) -> None:
    """Write off copies that have already been proved gone.

    New failures mark their own source, but the ones that happened before that rule
    existed left nothing behind — so a track that has failed on the same dead video id
    eight times will reach for it a ninth. This reads those failures back out of the
    job log and marks the sources they name, which is what makes asking for those songs
    again reach for a copy that might work.
    """
    from . import config, db, failures

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
    db.close()


def covers(apply: bool = False) -> None:
    """Find the songs with no artwork and go and get some.

    Two passes, cheapest first. A track on a record that something else has a cover for
    takes that cover — the picture is already here, filed under the song next to it,
    and one song of an album drawn as a grey square beside its own sleeve is the same
    record drawn two ways in one list. Whatever is still bare afterwards is queued for
    enrichment, which goes and looks: nine thousand Bandcamp tracks arrived through a
    mirror that never asked anybody for their artwork.
    """
    from . import config, db, jobs

    db.init(config.load().dsn)
    bare = db.one("select count(*) n from tracks where cover_id is null")["n"]
    shareable = db.one(
        """select count(*) n from tracks t
            where t.cover_id is null and t.album is not null and t.album <> ''
              and exists (select 1 from tracks o
                           where o.album = t.album
                             and coalesce(o.artists[1],'') = coalesce(t.artists[1],'')
                             and o.cover_id is not null)""")["n"]
    print(f"{bare} tracks with no cover, {shareable} of them on a record that has one")
    if not apply:
        print("dry run — pass --apply to write it")
        db.close()
        return

    with db.pool().connection() as c:
        took = c.execute(
            """update tracks t set cover_id = (
                    select o.cover_id from tracks o
                     where o.album = t.album
                       and coalesce(o.artists[1],'') = coalesce(t.artists[1],'')
                       and o.cover_id is not null
                     order by o.id limit 1)
                where t.cover_id is null and t.album is not null and t.album <> ''
                  and coalesce(t.artists[1],'') <> ''
                  and exists (select 1 from tracks o
                               where o.album = t.album
                                 and coalesce(o.artists[1],'')
                                     = coalesce(t.artists[1],'')
                                 and o.cover_id is not null)""").rowcount
    print(f"{took} took a cover from the rest of their record")

    # Everything still bare, behind whatever else is waiting: this is a long tail of
    # web requests and nobody is sitting watching it.
    rest = db.all_("select id from tracks where cover_id is null order by id")
    for row in rest:
        jobs.enqueue("meta", {"track_id": row["id"]}, priority=jobs.PRIORITY_BULK)
    print(f"{len(rest)} queued for enrichment")
    db.close()


def mirrorcovers(apply: bool = False) -> None:
    """Give every mirrored playlist the face it has on its service.

    Mirrors made before the linked services kept pictures, and Spotify mirrors made from
    a listing that carried none, were drawn from their records instead. Ask each service
    once per account for its listing (Spotify: once per playlist, the listing being the
    thing that is stripped) and take whatever picture it names.
    """
    from . import config, db, deps, linked, playlist_covers, spotify

    conf = config.load()
    db.init(conf.dsn)
    deps.set_config(conf)
    rows = db.all_(
        """select id, owner_id, kind, remote_id, name, cover_sig, cover_src
             from playlists
            where kind not in ('local', 'favourites') and remote_id is not null
            order by owner_id, kind, lower(name)""")
    print(f"{len(rows)} mirrored playlists, "
          f"{sum(1 for r in rows if not r['cover_sig'])} with no picture of their own")

    listings: dict[tuple[int, str], dict[str, str | None]] = {}

    def picture(row: dict) -> str | None:
        if row["kind"] == "spotify":
            if row["remote_id"] == spotify.LIKED:
                return None
            try:
                return spotify.playlist(conf, row["owner_id"], row["remote_id"]).get("image")
            except Exception as e:                # noqa: BLE001 - one list, not the run
                print(f"  ! spotify would not say for {row['name']}: {e}")
                return None
        key = (row["owner_id"], row["kind"])
        if key not in listings:
            acc = linked.account(row["owner_id"], row["kind"])
            try:
                lists = linked.playlists(row["kind"], acc["handle"],
                                         user_id=row["owner_id"]) if acc else []
            except Exception as e:                # noqa: BLE001 - one service, not the run
                print(f"  ! {row['kind']} would not list for user {row['owner_id']}: {e}")
                lists = []
            listings[key] = {l["remote_id"]: l.get("image") for l in lists}
        return listings[key].get(row["remote_id"])

    took = offered = 0
    for row in rows:
        url = picture(row)
        if not url:
            continue
        offered += 1
        if url == row["cover_src"] and row["cover_sig"]:
            continue
        print(f"  {row['kind']:10} {row['name'][:48]:48} {url[:60]}")
        if apply and playlist_covers.take(row["id"], url):
            took += 1
    print(f"{offered} have a picture over there"
          + (f"; {took} taken" if apply else "; dry run — pass --apply to take them"))
    db.close()


def traits_index(measure: bool = False) -> None:
    """The planner's index of every ready record (track_traits) from the analyses on
    disk — and with --measure, the analysis of every record that has none yet, which
    is half a second a record and the whole library's worth of them."""
    import pathlib

    from . import beats, config, db, traits
    from . import analysis as _analysis

    cfg = config.load()
    db.init(cfg.dsn)
    rows = db.all_(
        """select t.*, m.path, m.sha256 from tracks t
             join media m on m.track_id = t.id and m.role = 'canonical'
            where t.state = 'ready' order by t.id""")
    kept = missing = older = 0
    for t in rows:
        audio = pathlib.Path(t["path"] or "")
        cached = beats.cache_path(cfg.data_dir, t["sha256"])
        if not cached.exists() and not measure:
            # Measured by an earlier version only: that still says how steady its pulse
            # is and how hard its beats hit (the sleep mix's pulse and punch), which
            # are filled in where they are missing — the rest waits for --measure.
            if _older_pulse(cfg.data_dir, t["id"], t["sha256"]):
                older += 1
            missing += 1
            continue
        if not audio.exists():
            missing += 1
            continue
        try:
            found = beats.for_track(cfg.data_dir, audio, t["sha256"])
            if found.get("cues") and found.get("downbeats"):
                found["cues"] = _analysis.sane_cues(found["cues"], found["downbeats"])
            if "sound" not in found and found.get("downbeats"):
                found = beats.with_sound(cfg.data_dir, audio, t["sha256"], found)
            traits.remember(t, found)
            kept += 1
        except Exception as e:  # noqa: BLE001
            print(f"  {t['id']} {t['title']!r}: {e}")
            missing += 1
    print(f"{kept} indexed, {missing} without an analysis"
          + ("" if measure else " (--measure to work them out)")
          + (f"; pulse and punch from an older one for {older}" if older else ""))


def _older_pulse(data_dir, track_id: int, sha: str) -> bool:
    """Pulse and punch from the newest earlier analysis of a record, where its traits
    row has none."""
    import json

    from . import beats, db

    for v in range(beats.VERSION - 1, 0, -1):
        p = data_dir / "beats" / f"{sha}-v{v}.json"
        if not p.exists():
            continue
        try:
            found = json.loads(p.read_text())
        except (OSError, ValueError):
            return False
        if found.get("confidence") is None:
            return False
        db.run("""update track_traits set pulse = %s, punch = %s
                   where track_id = %s and pulse is null""",
               (found.get("confidence"), found.get("contrast"), track_id))
        return True
    return False


def housesamples(folder: str, owner: str, apply: bool = False) -> None:
    """Loads a sound library onto the house's shelf: every account's board can then hear
    it and put it on a pad. The folder is one `wetowl-board-sounds` builds — a
    manifest.json naming each sound, its file, its bank and how a pad should first hold
    it. Run again, it adds what is new and leaves alone what is there (same bytes);
    a sound the manifest renamed or regrouped is updated in place.

    Prints what it would do and changes nothing unless asked.
    """
    import hashlib
    import json
    import pathlib

    from . import config, db, deps
    from .routes_samples import _keep

    cfg = config.load()
    deps.set_config(cfg)
    db.init(cfg.dsn)
    who = db.one("select id from users where name=%s", (owner,))
    if not who:
        sys.exit(f"no user {owner!r}")
    root = pathlib.Path(folder)
    manifest = json.loads((root / "manifest.json").read_text())
    groups = {c["key"]: c["label"] for c in manifest["categories"]}
    shelf = {r["sha256"]: r for r in db.all_("select id, sha256, name, origin from samples where house")}
    added = renamed = same = 0
    for n, s in enumerate(manifest["sounds"]):
        f = root / s["file"]
        digest = hashlib.sha256(f.read_bytes()).hexdigest()
        origin = {
            "kind": "house", "pack": manifest.get("name"), "key": s["id"], "order": n,
            "group": groups.get(s["cat"], s["cat"]), "cat": s["cat"],
            "pad": {"name": s["name"], **s.get("pad", {})},
            "license": s.get("license"), "license_name": s.get("license_name"), "author": s.get("author"),
            "source": (s.get("source") or {}).get("url"), "words": (s.get("text") or "")[:240] or None,
        }
        kept = shelf.get(digest)
        if kept:
            if kept["name"] != s["title"] or kept["origin"] != origin:
                renamed += 1
                if apply:
                    db.run("update samples set name=%s, origin=%s where id=%s",
                           (s["title"][:80], json.dumps(origin), kept["id"]))
            else:
                same += 1
            continue
        added += 1
        if not apply:
            if added <= 20:
                print(f"  + {s['id']:<22} {s['title']}")
            continue
        row = _keep(who["id"], f, s["title"], origin, house=True)
        print(f"  + {s['id']:<22} -> sample {row['id']}", flush=True)
    print(f"{added} to add, {renamed} to update, {same} already on the shelf"
          + ("" if apply else " — nothing changed; --apply to do it"))


def pulse_backfill() -> None:
    """The pulse (pulse.py) of every ready record that has none yet, for the show —
    with the stems where the record is in parts. A few seconds a record, in the
    house's turns (heavy.py), so it can run beside the house."""
    import pathlib

    from . import config, db, pool, pulse

    cfg = config.load()
    db.init(cfg.dsn)
    rows = db.all_(
        """select t.id, t.title, m.path, m.sha256 from tracks t
             join media m on m.track_id = t.id and m.role = 'canonical'
            where t.state = 'ready' order by t.id""")
    made = had = missing = 0
    for t in rows:
        audio = pathlib.Path(t["path"] or "")
        stems = pool.part_here(t["sha256"], "stems")
        if pulse.cache_path(cfg.data_dir, t["sha256"], stems is not None).exists():
            had += 1
            continue
        if not audio.exists():
            missing += 1
            continue
        try:
            pulse.for_track(cfg.data_dir, audio, t["sha256"], stems)
            made += 1
        except Exception as e:  # noqa: BLE001
            print(f"  {t['id']} {t['title']!r}: {e}")
            missing += 1
    print(f"{made} measured, {had} already there, {missing} could not be")


def fixnames(apply: bool = False) -> None:
    """Every ready record named by its video id or credited to nobody, asked of
    YouTube again (enrich._names) — now, rather than on its next meta job."""
    from . import config, db, enrich

    cfg = config.load()
    db.init(cfg.dsn)
    rows = db.all_(
        """select t.id, t.title, t.artists from tracks t
             join track_sources s on s.track_id=t.id and s.provider='ytmusic'
            where t.state='ready' and (t.title = s.provider_id
                   or coalesce(array_length(t.artists,1),0)=0)
            order by t.id""")
    print(f"{len(rows)} records named by their id or by nobody")
    if not apply:
        for r in rows[:40]:
            print(f"  {r['id']} {r['title']!r} {r['artists']}")
        print("(--apply to ask YouTube for their names)")
        return
    named = 0
    for r in rows:
        t = enrich._names({"id": r["id"], "title": r["title"], "artists": r["artists"], "album": None})
        if t.get("title") != r["title"] or t.get("artists") != r["artists"]:
            named += 1
            print(f"  {r['id']}: {t.get('title')!r} by {t.get('artists')}")
    print(f"{named} of {len(rows)} named")


def cuebench() -> None:
    """The house against the cue check (booth CHECK page): how far its in and out are
    from where the DJ left pads 1 and 4, in bars, and what the grid was said to be.
    A pad left where the booth put it counts as the booth's place being right."""
    import collections
    import pathlib

    from . import beats, config, db

    cfg = config.load()
    db.init(cfg.dsn)
    rows = db.all_(
        """select c.track_id, c.grid, c.pads, c.beats_version, u.name, t.title, m.path, m.sha256
             from cue_checks c join users u on u.id = c.user_id
             join tracks t on t.id = c.track_id
             left join media m on m.track_id = t.id and m.role = 'canonical'
            order by c.checked_at""")
    grids = collections.Counter(r["grid"] or "none" for r in rows)
    print(f"{len(rows)} records checked; grid: " +
          ", ".join(f"{k} {v}" for k, v in grids.most_common()))
    off = {"in": collections.Counter(), "out": collections.Counter()}
    kept = {"in": 0, "out": 0}

    def bucket(bars: float) -> str:
        b = abs(bars)
        return ("on" if b < 0.5 else "≤4" if b <= 4 else "≤8" if b <= 8
                else "≤16" if b <= 16 else ">16")

    for r in rows:
        if not r["path"] or not pathlib.Path(r["path"]).exists():
            continue
        found = beats.for_track(cfg.data_dir, pathlib.Path(r["path"]), r["sha256"])
        cues, bpm = found.get("cues") or {}, found.get("bpm")
        if not cues or not bpm:
            continue
        bar = 240000 / bpm
        for n, side, key in (("1", "in", "mix_in_ms"), ("4", "out", "mix_out_ms")):
            p = (r["pads"] or {}).get(n)
            if not p:
                continue
            kept[side] += p.get("auto", False)
            bars = (cues[key] - p["ms"]) / bar
            off[side][bucket(bars)] += 1
            if abs(bars) > 8:
                print(f"  {side:3} {bars:+6.1f} bars  {r['title']}  ({r['name']})")
    for side in ("in", "out"):
        n = sum(off[side].values())
        if n:
            print(f"{side}: {n} pads, booth's own kept {kept[side]}; house off by " +
                  ", ".join(f"{k} {off[side][k]}" for k in ("on", "≤4", "≤8", "≤16", ">16")))


def main() -> None:
    match sys.argv[1:]:
        case ["cuebench"]:
            cuebench()
        case ["fixnames"]:
            fixnames()
        case ["fixnames", "--apply"]:
            fixnames(apply=True)
        case ["pulse", "--backfill"]:
            pulse_backfill()
        case ["traits"]:
            traits_index()
        case ["traits", "--measure"]:
            traits_index(measure=True)
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
        case ["followscheck"]:
            followscheck()
        case ["followscheck", "--apply"]:
            followscheck(apply=True)
        case ["markdead"]:
            markdead()
        case ["markdead", "--apply"]:
            markdead(apply=True)
        case ["covers"]:
            covers()
        case ["covers", "--apply"]:
            covers(apply=True)
        case ["mirrorcovers"]:
            mirrorcovers()
        case ["mirrorcovers", "--apply"]:
            mirrorcovers(apply=True)
        case ["housesamples", folder, owner]:
            housesamples(folder, owner)
        case ["housesamples", folder, owner, "--apply"]:
            housesamples(folder, owner, apply=True)
        case _:
            sys.exit("usage: python -m muse.cli [adduser <name> | secret "
                     "| splitartists [--apply] | fixsoundcloud [--apply] "
                     "| fixspotifynames [--apply] | markdead [--apply] "
                     "| covers [--apply] | traits [--measure] | pulse --backfill | fixnames [--apply] "
                     "| housesamples <folder> <owner> [--apply] | cuebench]")


if __name__ == "__main__":
    main()
