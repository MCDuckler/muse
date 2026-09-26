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
| fx dB | how loud the booth's own sound (a riser, a sweep, a gush) is at its loudest second against the records under it |
| key | chroma disagreement of the two over the overlap, 0 to 1 |

The tables are played on the bars as the booth plays them (`MixStep.onBars`), and the
fader by the law the move runs (`Transition.full`: both records whole at the middle
for the stem moves, the swap and the break swap; equal power otherwise).

What the renderer does not do: the echo's tail (the send is rendered dry), the
brake, a deck's pitch shift as it falls out of the mix (the lunar echo's last bars),
and any tempo glide after the move.

The moves that play a sound of the booth's own (`riser`, `noiseSweep`, `hydrant`) are
rendered with it: the renderer asks the app for each shot at the exact length the move
needs — `flutter test test/fx_sounds_test.dart` with `FX_OUT` and `FX_SPEC` — and
caches it under `<dir>/fx`. So the probe measures the samples the speaker gets, and
`lib/src/state/booth/fx_sounds.dart` is the only place the synthesis is written. The bands and the filter are block gains in
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

## Third pass (2026-09-25): the moves that make a sound

The booth can now play something that is neither record — a riser, a sweep, a gush, a
hit (`lib/src/state/booth/fx_sounds.dart`, `fx_channel.dart`) — and six moves were
added on top of it: `riser`, `noiseSweep`, `hydrant`, `dissolve`, `lunarEcho`,
`tremolo`. Measured on a synthetic pair (two 120 bpm records with a kick on every beat,
a chord, a voice, a quiet intro and outro, and a drop at bar 16 in the second), sixteen
bars, against the moves already here:

| kind | range dB | dip dB | hole dB | kicks s | jump dB | fx dB |
|---|---|---|---|---|---|---|
| blend | 1.7 | 1.5 | 2.8 | 0 | 0.0 | — |
| sweep | 6.9 | 6.7 | 8.6 | 0 | 0.0 | — |
| echo out | 1.9 | 1.7 | 2.8 | 0 | 0.0 | — |
| **riser** | 6.5 | 6.3 | 8.0 | 0 | 0.7 | −5.3 |
| **noise sweep** | 1.6 | 1.4 | 2.7 | 0 | 0.0 | −10.5 |
| **hydrant** | 1.0 | 0.8 | 2.0 | 0 | 0.0 | −7.6 |
| **dissolve** | 6.2 | 6.0 | 7.0 | 0 | 0.0 | — |
| **lunar echo** | 1.7 | 1.5 | 2.8 | 0 | 0.0 | — |
| **tremolo** | 6.0 | 5.8 | 6.8 | 0 | 1.3 | — |

What it found:

- **The riser's build had two kicks in it for seven and a half seconds.** Written first
  as a blend with a noise over it — the incoming waiting at a third of the fader with
  its bass merely down — it put both records' drums against each other for half the
  move, which is the one thing a build must not do. The incoming is now held right
  back, bass killed and barely on the fader, until the one. That took `drums_doubled_s`
  to zero at the cost of the dip: 4.3 → 6.3 dB, which is a build doing what a build is
  for, and still less than the `sweep` already in the set (6.7).
- **The dissolve kept its kick while it evaporated** (3.5 s of two kicks). Its low goes
  with the send now, at 0.4 of the move: a record that is disappearing has no business
  still putting a kick against the one coming in.
- **The gains are set by what a sound is for.** `fx_db` is how far under the records
  the booth's own sound sits at its loudest second. A sound that has to *cover* a join
  wants to be within about 8 dB of them (the hydrant, raised −14 → −11 dB, now −7.6;
  the louder wash also took its own dip from 1.1 to 0.8, because it fills what the
  thinned tops left); one that only decorates a change can sit 10 or 12 under and still
  be the thing everybody notices (the sweeps).
- **A swept band decides the colour, not the level.** The riser's amplitude law asked
  for a 26 dB swell and the render measured 60, with its first third under −60 dBFS —
  inaudible, and then a sound out of nowhere. A band-pass passes far less noise at
  220 Hz than at 9 kHz. The band is flattened by a follower now (`_Level`), slow enough
  that the gate's roll survives it, and the written swell is the swell that comes out.
- **One band-pass is not a band.** At 6 dB an octave either side, a "band" swept
  200 Hz → 9 kHz moved the weight of the spectrum only 3976 → 5060 Hz: it was still
  mostly broadband hiss. Two in series (`_Band`) gave 1162 → 4892 Hz over the same
  sweep — a sound that changes colour rather than one that merely gets louder.

Not measured, because the renderer does not render them: the echo's tail (the dissolve
and the lunar echo are rendered dry, so their last fifth is missing), and the lunar
echo's pitch fall. Both wait on real records with stems on this box.

## Not done

- EDM-CUE (ETH, CC BY 4.0) lists cue points for 4.7k commercial tracks whose audio is
  not distributed: our cue rules cannot be run against it. What can be checked is
  its statistic — cue points on 8/16-bar multiples — which the phrase grid gives.
- CUE-DETR as a scorer needs PyTorch and a 160 MB DETR checkpoint; without ground
  truth on our records its agreement with our cues would be the only number. Left
  until a set of hand-placed cues on our own records exists.

## Fourth pass (2026-09-26): the moves reviewed against practice, and fixed

A read of every move against what DJs do, what Mixxx/djay/rekordbox-class automix
does, and the DJ-mix papers (Kim et al. 2020, Chen et al. 2022, Vande Veire & De Bie
2018) found three bugs and five rough edges in the moves themselves. Measured on a
made-up pair this time written down — `make_pair.py` (two 64-bar records at 120, kick
on every beat, sub bass, a chord, a sung vowel, a quiet intro and outro, a drop at bar
16; A minor into E minor). It is far bassier than a record, so its dips are bigger than
the third pass's; the *differences* are the point.

| move | kicks s before → after | dip dB | hole dB | note |
|---|---|---|---|---|
| blend | 0 → 0 | 3.3 → 3.0 | 4.3 → 6.2 | EQ travelled over the beat before each step at equal power (it was one command, 40 dB in a frame; travelled in dB it was an 11 dB hole) |
| sweep | 0 → 0 | 18.8 → 16.6 | 24.4 → 21.8 | now on the full fader law |
| filterRide | 0 → 6.0 | 11.3 → 5.7 | 12.5 → 6.2 | the incoming was *silent* for half the move (low-pass at 350 Hz and bass killed); now low-pass from 1.2 kHz, bass off until 0.4 then −12 dB, released at the swap |
| announce | 0.75 → 0.5 | 17.6 → 17.6 | 26.5 → 23.5 | the outgoing's drums go with its bass at 0.56, handed over from 0.5 (they stayed to 0.8; the probe read no doubled kicks only because the bass was off) |
| stemBlend | 1.25 → 1.25 | 2.5 → 2.0 | 6.0 → 4.8 | stem handovers at equal power (`StemLevels.lerpPower`): the linear ones met at 0.5 each, 3 dB down |
| roll | 3.25 → 4.0 | 7.7 → 7.6 | 8.5 → 8.4 | a real ladder now: 2, 1, ½, ¼, ⅛ bars, the halvings on beats (`onBars`), and loops start from the bar the step is on rather than the next (`Deck.loop`) |

Not measurable here, fixed by reading: the **brake kept its pitch** (Rubber Band's whole
job; `Deck.brake` now shifts the pitch down by the rate at every step through
`pitchEngine`, and lasts two beats rather than 900 ms), and the **echo was timed to the
first record a deck ever played** (its delays are in the chain; `beforeLoad` now builds
the chain again while the deck is parked when the beat has moved more than 2 %).

The renderer mirrors the new laws (`lerp_steps(power=True)` for stems, `eq_at` for the
bands) so these numbers are the booth's, not the old renderer's.

### The booth's own sounds, made better

Old against new, the same shots (`fx_sounds_test.dart` with FX_OUT), by numbers a
speaker would notice:

| sound | rms dB | crest dB | width (S/M) | centroid start → end |
|---|---|---|---|---|
| riser 8 s | −23.3 → −20.0 | 20.2 → 16.3 | 0.81 → 0.95 | 1251 → 3830 was; 1313 → 5904 now |
| sweep up 2 s | −24.3 → −21.2 | 18.9 → 16.2 | 1.33 → 1.27 | 1219 → 6251; 933 → 6666 |
| sweep down 2 s | −33.2 → −24.0 | 27.9 → 18.6 | 1.32 → 1.33 | 2642 → 880; 2798 → 457 |
| hydrant 4 s | −20.2 → −20.6 | 16.2 → 16.7 | 1.01 → 1.00 | 3109; 5354 flat both |
| impact 2 s | −18.8 → −18.1 | 17.8 → 17.0 | 0.15 → 0.15 | sub, as before |

What changed and why: pink noise under every sweep and the riser's start, white only
as they climb (hiss alone has no body); a soft saturator on the riser and the sweeps
(denser, a crest 4 dB lower, the swell heard as one thing); a short Schroeder room on
the sweep down, the hydrant and the hit (they fall away instead of stopping); the
riser's roll has a snare-like tick on every cycle, a resonant scream over its last
third and a three-voice detuned lead with a deepening vibrato instead of one sine; the
hydrant is sprayed (its level flickers at 8–14 Hz on a slow random walk) — and *not*
saturated: driven, its resonant bursts came out as odd harmonics two octaves up
(centroid 3.1 → 5.5 kHz, crest 16 → 9 dB), so that one stays linear; the hit has a
click on its first sample and only a little drive on the sub (driven hard it was a
buzz). Spectrograms of old against new are in the session that did this; the test
file's assertions (swell, brightness, opposite sweeps, arch, decay, rest at the ends)
all still hold.
