# Measuring the Auto DJ offline

Three scripts render a transition the way the booth would play it and put numbers on
it, with nothing but the stems this computer already keeps (`~/.local/share/
io.wetowl.muse/stems/<id>-stems-v2.opus`) and the server's own analysis code.

```
# 1. Records: decode the stems, run the house's analysis and the pool's tracker,
#    build the structure — the same numbers the booth plans by.
WETOWL_SEPARATE=<wetowl-separate> WETOWL_ORT=<libonnxruntime.so> \
WETOWL_BEATS_MODEL=<beat-this-final0.onnx> WETOWL_BEATS_FRONTEND=<frontend.json> \
  ../server/.venv/bin/python tool/booth_probe/prepare_records.py <dir> 1039 2028 ...

# 2. The booth's transition tables, from the code (once per change to Booth.plan):
CURVES_OUT=$PWD/tool/booth_probe/transitions.json flutter test test/curves_dump_test.dart

# 3. Every move between two records, rendered (<dir>/<a>-<b>-<kind>.wav) and measured:
../server/.venv/bin/python tool/booth_probe/eval_pairs.py <dir> 1039 2028
# or one move, with the levels second by second:
../server/.venv/bin/python tool/booth_probe/render_transition.py <dir> 1039 2028 blend 16 --debug
```

The numbers:

| column | what it is |
|---|---|
| voices s | seconds in which both records' voices are heard at once (each over -30 dBFS after the move's levels) |
| range dB | how far the level strays from the record before, over the move |
| dip dB | the deepest it sinks below that level — a drop move dips on purpose while the new record waits |
| phase ms | how far the new record's kicks fall from the old one's over the overlap; near ±half a beat it is unreliable (few kicks on one side) |
| key | chroma disagreement of the two over the overlap, 0 to 1 |

What the renderer does not do: the echo's tail (the send is rendered dry), the
brake, and any tempo glide after the move. The bands and the filter are block gains in
the frequency domain, not the chain's IIR filters — close enough to hear a kill.

## What it found so far (2026-09-24, 1039 ↔ 2028)

- Stem moves keep their word: stem blend and announce put no two voices together where
  a blend, a sweep or an echo-out lay 11 s of them over each other.
- A record with a long, thin intro (2028: 53 s at -17 dB) parked the ordinary way made
  a blend into a hole. The in point now moves later when those bars are quiet
  (`AutoMix.inPoint`, `quietBars`); a 7 dB step remains and cannot be turned up.
- The out point has to respect the length of the move (a 17 s outro under a 32 s
  move): the renderer mirrors `AutoMix.outPoint` for that.

## Not done

- EDM-CUE (ETH, CC BY 4.0) lists cue points for 4.7k commercial tracks whose audio is
  not distributed: our cue rules cannot be run against it. What can be checked is
  its statistic — cue points on 8/16-bar multiples — which the phrase grid gives.
- CUE-DETR as a scorer needs PyTorch and a 160 MB DETR checkpoint; without ground
  truth on our records its agreement with our cues would be the only number. Left
  until a set of hand-placed cues on our own records exists.
