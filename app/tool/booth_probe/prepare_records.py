#!/usr/bin/env python3
"""Records for the offline renderer, from the stems this computer keeps.

For each track id: the six-channel stems file (drums, bass and the rest, the voice) is
decoded to three stereo stems and their sum, the mix; the house's analysis is run on the
mix (server/muse/beats.py), the pool's tracker on it too (wetowl-separate --beats), and
the structure built from both and the stems (server/muse/structure.py) — the same
numbers the booth plans by. Out: <dir>/<id>/{drums,rest,vocals,mix}.wav and <id>.json.

  prepare_records.py <out dir> <id> [<id> ...]
  WETOWL_SEPARATE, WETOWL_ORT, WETOWL_BEATS_MODEL, WETOWL_BEATS_FRONTEND name the tracker.
"""
import json
import os
import pathlib
import subprocess
import sys
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
SERVER = HERE.parents[2] / "server"
sys.path.insert(0, str(SERVER))
from muse import beats, structure  # noqa: E402

STEMS = pathlib.Path.home() / ".local/share/io.wetowl.muse/stems"
PANS = {"drums": "c0|c1", "rest": "c2|c3", "vocals": "c4|c5"}


def decode(opus: pathlib.Path, into: pathlib.Path) -> None:
    into.mkdir(parents=True, exist_ok=True)
    for name, pan in PANS.items():
        l, r = pan.split("|")
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", str(opus),
                        "-af", f"pan=stereo|c0={l}|c1={r}", "-ar", "44100", "-c:a", "pcm_f32le",
                        str(into / f"{name}.wav")], check=True)
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", str(into / "drums.wav"), "-i", str(into / "rest.wav"),
                    "-i", str(into / "vocals.wav"), "-filter_complex", "amix=inputs=3:normalize=0",
                    "-c:a", "pcm_f32le", str(into / "mix.wav")], check=True)


def neural_beats(mix: pathlib.Path, out: pathlib.Path) -> dict | None:
    prog = os.environ.get("WETOWL_SEPARATE")
    ort, model, fe = (os.environ.get(k) for k in ("WETOWL_ORT", "WETOWL_BEATS_MODEL", "WETOWL_BEATS_FRONTEND"))
    if not all([prog, ort, model, fe]):
        return None
    r = subprocess.run([prog, "--ort", ort, "--ffmpeg", "ffmpeg", "--in", str(mix), "--threads", "6",
                        "--beats", str(out), "--beats-model", model, "--beats-frontend", fe],
                       capture_output=True, text=True)
    if not out.exists():
        print("  no beats:", r.stdout.strip()[-200:])
        return None
    return json.loads(out.read_text())


def main() -> None:
    out = pathlib.Path(sys.argv[1])
    for tid in sys.argv[2:]:
        opus = STEMS / f"{tid}-stems-v2.opus"
        if not opus.exists():
            print(tid, "has no stems here")
            continue
        d = out / tid
        print(tid, "decoding")
        decode(opus, d)
        mix = d / "mix.wav"
        print(tid, "analysing")
        timing = beats.measure(mix)
        neural = neural_beats(mix, d / "beats.json")
        lufs = subprocess.run(["ffmpeg", "-nostats", "-hide_banner", "-i", str(mix), "-af", "ebur128=framelog=quiet",
                               "-f", "null", "-"], capture_output=True, text=True).stderr
        import re
        m = re.search(r"I:\s+(-?[\d.]+) LUFS", lufs)
        track = {"id": int(tid), "sha256": f"local-{tid}", "path": str(mix),
                 "loudness_lufs": float(m.group(1)) if m else None, "title": tid, "artists": []}
        with tempfile.TemporaryDirectory() as data:
            found = structure.build(pathlib.Path(data), track, timing, neural, opus)
        (out / f"{tid}.json").write_text(json.dumps(found))
        s = found["structure"]
        print(f"  {found.get('bpm')} bpm, key {found.get('camelot')}, beats {s['sources']['beats']}, "
              f"bar {s['sources']['bar_phase']}, sections {[x['label'] for x in s['sections']]}")


if __name__ == "__main__":
    main()
