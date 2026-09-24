#!/usr/bin/env python3
"""Every move between two prepared records, rendered and measured: a table.

  eval_pairs.py <dir> <idA> <idB> [kinds...]
Moves that land on a drop are cued so the new record's first drop (from the stems)
falls on the move's last beat; the break swap goes out at the old record's first
breakdown after its first minute.
"""
import json
import pathlib
import subprocess
import sys

HERE = pathlib.Path(__file__).resolve().parent
DEFAULT = ["blend", "sweep", "filterRide", "echoOut", "stemBlend", "dropSwap", "loopBuild", "breakSwap", "announce", "acapellaOut"]
BARS = {"blend": 16, "sweep": 16, "filterRide": 32, "echoOut": 16, "stemBlend": 32, "dropSwap": 16,
        "loopBuild": 16, "breakSwap": 16, "announce": 16, "acapellaOut": 16, "roll": 8}


def main():
    d = pathlib.Path(sys.argv[1]); a, b = sys.argv[2], sys.argv[3]
    kinds = sys.argv[4:] or DEFAULT
    A = json.loads((d / f"{a}.json").read_text()); B = json.loads((d / f"{b}.json").read_text())
    bar_a = 4 * 60000 / A["bpm"]
    ratio = A["bpm"] / B["bpm"]
    while ratio > 2 ** 0.5: ratio /= 2
    while ratio < 2 ** -0.5: ratio *= 2
    drops_b = B["structure"].get("drops_ms") or B.get("drops") or []
    breaks_a = [s for s in A["structure"]["sections"] if s["label"] == "breakdown" and s["start_ms"] > 60000]
    print(f"{a} ({A['bpm']} {A.get('camelot')}) -> {b} ({B['bpm']} {B.get('camelot')}), stretch x{ratio:.3f}")
    print(f"{'move':12} {'bars':>4} {'voices s':>8} {'kicks s':>7} {'range dB':>8} {'dip dB':>6} {'hole':>5} {'jump':>9} {'phase ms':>8} {'key':>5}")
    for kind in kinds:
        bars = BARS.get(kind, 16)
        extra = []
        if kind in ("dropSwap", "loopBuild", "roll", "breakSwap"):
            if not drops_b:
                print(f"{kind:12} (no drop in B)"); continue
            extra += ["--in", str(int(drops_b[0] - bar_a / ratio * bars))]
        if kind == "breakSwap":
            if not breaks_a:
                print(f"{kind:12} (no breakdown in A)"); continue
            bars = max(8, min(32, breaks_a[0]["end_bar"] - breaks_a[0]["start_bar"]))
            extra = ["--in", str(int(drops_b[0] - bar_a / ratio * bars)), "--out", str(breaks_a[0]["start_ms"])]
        r = subprocess.run([sys.executable, str(HERE / "render_transition.py"), str(d), a, b, kind, str(bars), *extra,
                            "--wav", str(d / f"{a}-{b}-{kind}.wav")], capture_output=True, text=True)
        if r.returncode != 0:
            print(f"{kind:12} failed: {r.stderr.strip()[-300:]}"); continue
        m = json.loads(r.stdout.strip().splitlines()[-1])
        print(f"{kind:12} {bars:4} {m['vocal_overlap_s']:8.2f} {m['drums_doubled_s']:7.2f} {m['loudness_range_db']:8.1f} {m['dip_db']:6.1f} {m['hole_db']:5.1f} "
              f"{m['start_jump_db']:4.1f}/{m['end_jump_db']:4.1f} {m['phase_error_ms']:8.1f} {m['key_clash']:5.2f}")


if __name__ == "__main__":
    main()
