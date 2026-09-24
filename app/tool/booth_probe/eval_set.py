#!/usr/bin/env python3
"""A whole set, every transition rendered and measured — the worst ones first.

  SET_DIR=<dir> SET_OUT=<dir>/set-plan.json [SET_ARC=build] [SET_STYLE=bold] \\
      flutter test test/plan_set_test.dart
  eval_set.py <dir> [<dir>/set-plan.json]

The plan is what the booth itself would do with these records (test/plan_set_test.dart:
the set planner's order, the transition planner's move for each pair); each move is
rendered with render_transition.py and its numbers printed, sorted so the transitions
most worth listening to come first (two voices at once, a hole in the level, a beat
out of step).
"""
import json
import pathlib
import subprocess
import sys

HERE = pathlib.Path(__file__).resolve().parent


def main():
    d = pathlib.Path(sys.argv[1])
    plan = json.loads(pathlib.Path(sys.argv[2] if len(sys.argv) > 2 else d / "set-plan.json").read_text())
    print(f"set: {' → '.join(str(i) for i in plan['order'])}  ({plan['arc']}, {plan['style']})")
    rows = []
    for m in plan["moves"]:
        args = [sys.executable, str(HERE / "render_transition.py"), str(d), str(m["from"]), str(m["to"]), m["kind"],
                str(m["bars"]), "--out", str(m["out_ms"]), "--in", str(m["in_ms"]), "--shift", str(m["shift"]),
                "--wav", str(d / f"set-{m['from']}-{m['to']}.wav")]
        r = subprocess.run(args, capture_output=True, text=True)
        if r.returncode != 0:
            print(f"{m['from']}→{m['to']} {m['kind']}: failed: {r.stderr.strip()[-200:]}")
            continue
        got = json.loads(r.stdout.strip().splitlines()[-1])
        got["why"] = m["why"]
        got["fit_why"] = m["fit_why"]
        # Worth a listen: voices doubled, a hole, a beat out.
        got["concern"] = got["vocal_overlap_s"] / 4 + max(0, got["dip_db"] - 6) / 6 + min(1, abs(got["phase_error_ms"]) / 60)
        rows.append(got)
    rows.sort(key=lambda g: -g["concern"])
    print(f"{'pair':>12} {'move':14} {'bars':>4} {'voices':>6} {'dip':>5} {'phase':>6} {'key':>5}  why")
    for g in rows:
        print(f"{g['a']:>5}→{g['b']:<6} {g['kind']:14} {g['bars']:4} {g['vocal_overlap_s']:6.1f} {g['dip_db']:5.1f} "
              f"{g['phase_error_ms']:6.0f} {g['key_clash']:5.2f}  {g['why']} — {g['fit_why']}")


if __name__ == "__main__":
    main()
