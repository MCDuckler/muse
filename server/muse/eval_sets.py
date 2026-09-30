"""How good are the sets the house builds? Measured, not guessed.

    python -m muse.eval_sets --dsn "host=127.0.0.1 port=5433 user=muse dbname=muse_eval" --user 1

Builds sets from a person's whole library (and from a few of their playlists) to
several shapes, and the same number of records chosen two older ways — greedily,
each the best partner of the last (what KEEP GOING did), and at random — and reads
each set the same way:

    fit      mean pair score (setbuild.score, the app's SetPlanner.fit terms)
    worst    the worst pair in the set
    clash    share of pairs whose keys clash (both keys sure)
    step90   the 90th percentile tempo stretch between neighbours, in %
    far      pairs too far apart in tempo to be put in step
    curve    RMS distance of each record's loudness from where the shape wanted it
    tempo    RMS distance from the tempo path, in % (shapes with one)
    artist   an artist again within three records
    twins    the same song twice
"""
from __future__ import annotations

import argparse
import math
import random
import statistics

import numpy as np

from . import db, setbuild

SHAPES = {
    "warm-up": {"energy": [[0, 0.1], [0.7, 0.45], [1, 0.6]]},
    "build": {"energy": [[0, 0.2], [1, 0.95]]},
    "peak late": {"energy": [[0, 0.3], [0.75, 0.95], [1, 0.6]]},
    "two waves": {"energy": [[0, 0.3], [0.3, 0.85], [0.5, 0.45], [0.8, 0.95], [1, 0.6]]},
    "build 124→132": {"energy": [[0, 0.3], [1, 0.9]], "tempo": {"from": 124, "to": 132}},
    "strict keys": {"energy": [[0, 0.5], [1, 0.5]], "key": "strict"},
}


def _greedy(p: setbuild.Pool, shape: setbuild.Shape, n: int, rng: random.Random) -> list[int]:
    """Each record the best partner of the last, from a random first one."""
    first = rng.randrange(p.n)
    picks = [first]
    used = {int(p.same[first])}
    for _ in range(n - 1):
        s = setbuild._pair_from(p, picks[-1], setbuild.Shape())
        s[np.isin(p.same, list(used))] = -np.inf
        c = int(np.argmax(s))
        if not np.isfinite(s[c]):
            break
        picks.append(c)
        used.add(int(p.same[c]))
    return picks


def _random(p: setbuild.Pool, n: int, rng: random.Random) -> list[int]:
    return rng.sample(range(p.n), min(n, p.n))


def measure(p: setbuild.Pool, shape: setbuild.Shape, picks: list[int]) -> dict:
    if len(picks) < 2:
        return {}
    a, b = np.array(picks[:-1]), np.array(picks[1:])
    plain = setbuild.Shape()
    fits = setbuild.score(p, a, b, plain)
    fa, fb = p.bpm[a], p.bpm[b]
    known = np.isfinite(fa) & np.isfinite(fb)
    folded = setbuild._fold(fb, np.where(known, fa, 1.0))
    stretch = np.abs(folded / fa - 1)[known] * 100
    ca, cb = p.cam[a].astype(int), p.cam[b].astype(int)
    d = (cb - ca) % 12
    same = p.major[a] == p.major[b]
    ok = ((d == 0)) | (((d == 1) | (d == 11) | (d == 2) | (d == 7) | (d == 10) | (d == 5)) & same)
    sure = (np.minimum(p.conf[a], p.conf[b]) >= 0.3) & (ca > 0) & (cb > 0)
    clash = float(np.mean(~ok[sure])) if sure.any() else float("nan")
    total = sum(float(p.played_s[i]) for i in picks)
    t, curve, tempo = 0.0, [], []
    for i in picks:
        k = (t + float(p.played_s[i]) / 2) / total
        e = p.energy[i]
        if np.isfinite(e):
            curve.append((e - setbuild.target(p, shape, k)) ** 2)
        want = shape.tempo_at(k)
        if want is not None and np.isfinite(p.bpm[i]):
            got = float(setbuild._fold(np.array([p.bpm[i]]), np.array([want]))[0])
            tempo.append((got / want - 1) ** 2)
        t += float(p.played_s[i])
    artist = sum(1 for j, i in enumerate(picks)
                 if any(p.artists[i] & p.artists[k] for k in picks[max(0, j - 3):j]))
    twins = len(picks) - len({int(p.same[i]) for i in picks})
    return {
        "fit": float(np.mean(fits)),
        "worst": float(np.min(fits)),
        "clash": clash,
        "step90": float(np.percentile(stretch, 90)) if len(stretch) else float("nan"),
        "far": int(np.sum(stretch > setbuild.REACH * 100)),
        "curve": math.sqrt(sum(curve) / len(curve)) if curve else float("nan"),
        "tempo": math.sqrt(sum(tempo) / len(tempo)) * 100 if tempo else float("nan"),
        "artist": artist,
        "twins": twins,
    }


def _row(name: str, runs: list[dict]) -> str:
    keys = ["fit", "worst", "clash", "step90", "far", "curve", "tempo", "artist", "twins"]
    cells = []
    for k in keys:
        vals = [r[k] for r in runs if k in r and not (isinstance(r[k], float) and math.isnan(r[k]))]
        cells.append(f"{statistics.mean(vals):7.2f}" if vals else "      –")
    return f"{name:<16}" + "".join(cells)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dsn", required=True)
    ap.add_argument("--user", type=int, default=1)
    ap.add_argument("--tracks", type=int, default=16)
    ap.add_argument("--runs", type=int, default=5)
    ap.add_argument("--playlists", type=int, default=3, help="also from this many of the person's biggest playlists")
    args = ap.parse_args()
    db.init(args.dsn)
    rng = random.Random(7)
    pools = {"library": setbuild.load(args.user, True, set())}
    for r in db.all_(
            """select p.id, p.name, count(*) n from playlists p join playlist_items i on i.playlist_id = p.id
                where p.owner_id = %s and p.kind <> 'favourites' group by 1, 2 order by 3 desc limit %s""",
            (args.user, args.playlists)):
        ids = {x["track_id"] for x in db.all_("select track_id from playlist_items where playlist_id = %s", (r["id"],))}
        pools[f"list {r['name'][:18]}"] = setbuild.load(args.user, False, ids)
    head = f"{'':<16}" + "".join(f"{k:>7}" for k in
                                  ["fit", "worst", "clash", "step90", "far", "curve", "tempo", "artist", "twins"])
    for pname, p in pools.items():
        print(f"\n=== {pname}: {p.n} measured records, {len(set(p.same.tolist()))} songs")
        if p.n < args.tracks * 2:
            print("  (too few to build from)")
            continue
        for sname, sd in SHAPES.items():
            shape = setbuild.Shape.of(sd)
            built, greedy, rand = [], [], []
            for run in range(args.runs):
                start = rng.randrange(p.n)
                slots = setbuild.build(p, shape, start=start, tracks=args.tracks)
                picks = [p.at[s["track"]["id"]] for s in slots]
                built.append(measure(p, shape, [start] + picks))
                greedy.append(measure(p, shape, _greedy(p, shape, args.tracks + 1, rng)))
                rand.append(measure(p, shape, _random(p, args.tracks + 1, rng)))
            print(f"-- {sname}")
            print("   " + head)
            print("   " + _row("set builder", built))
            print("   " + _row("greedy partner", greedy))
            print("   " + _row("random", rand))


if __name__ == "__main__":
    main()
