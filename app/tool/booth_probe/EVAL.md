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
| dip dB | the deepest the mix sinks under the louder of the two records as they are, a second at a time: level the move threw away — a drop move dips on purpose over its last bars |
| kicks s | seconds in which both records' drums are heard at once with neither bass killed |
| hole | the dip over quarter seconds: a short hole |
| jump | how much the move itself steps the level at its first and last instant (the records' own steps taken out) |
| phase ms | how far the new record's kicks fall from the old one's over the overlap; near ±half a beat it is unreliable (few kicks on one side) |
| key | chroma disagreement of the two over the overlap, 0 to 1 |

The tables are played on the bars as the booth plays them (`MixStep.onBars`), and the
fader by the law the move runs (`Transition.full`: both records whole at the middle
for the stem moves, the swap and the break swap; equal power otherwise).

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

## Second pass (2026-09-24, 16 records, `eval_set.py`)

- **The stem blend's fader drifted.** Its only fader steps were 0.5 at the start and 1
  at the end, so it travelled the whole move: the old record was 8 dB down by half way
  with its bass and voice still to give. Now held at the middle until the old record
  has nothing left. And with the equal-power law every stem of a stem move sat 3 dB
  down for the fader being in the middle: the stem moves run the full law now.
- **The drop swap and the loop build were a 20 dB hole** for the eight bars before the
  drop: the new record's mid pulled 12 dB and low-passed at 3 kHz on top of its bass
  off, the old record high-passed to 4 kHz from half way. Now bass off only, and the
  thinning kept to the last quarter (16 dB → ~8 on 125 → 1301).
- **The break swap held the new record back for the whole breakdown** (half the
  fader, bass off): 13 dB under what it had to give, over a stretch of the old record
  with no drums to fight. It comes in whole but for its bass now, on the full law.
- **A grid half a beat off the drums** (1357): the house's line locked on the intro's
  "and" and never let go; the tracker's beats sat 175 ms from it for the whole body,
  and the bar's agreement was counted only over the four bars that happened to match.
  `structure.py`: the tracker's line where the house's beats fall between the
  tracker's (`_phase_off` > 0.2); the line fitted at each beat's own count so a
  half-time intro or a missed beat does not lean it over; the bar's share counted
  over all the tracker's bars.
- **An outro before the intro** (1299, 88 s: mix_out at bar 3, mix_in at bar 7) made
  every move go out at once. `analysis.sane_cues` on the way out, and
  `AutoMix.outPoint` treats such a cue as none.
- **A short intro was never checked for quiet**: `inPoint` clamped to the first
  downbeat before the quiet rule ran. Now after.
- **Fades over two voices**: a fade that is the only way (an octave apart) and lands
  two records singing throughout is halved (8 → 4 bars); every move that did not
  choose its own place can come in past the new record's voice (`_clearOfVoices`)
  where the dial minds voices.
- **The echo-out's tail was cut** by the deck stopping at the end: the record now goes
  at 0.78 of the move, the tail ringing over the last fifth under the fader.

Left as is: sub-bar steps of an 8-bar loop build or drop swap round onto the same
bar (the half-bar loop is skipped) — harmless; the renderer's phase figure on
octave pairs (its lag search is half a beat of the old record's).

## Not done

- EDM-CUE (ETH, CC BY 4.0) lists cue points for 4.7k commercial tracks whose audio is
  not distributed: our cue rules cannot be run against it. What can be checked is
  its statistic — cue points on 8/16-bar multiples — which the phrase grid gives.
- CUE-DETR as a scorer needs PyTorch and a 160 MB DETR checkpoint; without ground
  truth on our records its agreement with our cues would be the only number. Left
  until a set of hand-placed cues on our own records exists.
