# When a DJ mixes, and when ours does

The booth knows twenty-one ways to get out of a record. What decides whether a set
sounds like a DJ made it is not which of them it picks — it is *when*: where in the old
record it leaves, where in the new one it lands, how long it takes, and how often it
does the clever thing rather than the plain one.

This note is what could be found out about that, and where our planner
(`app/lib/src/state/booth/planner.dart`, `automix.dart`) agrees and disagrees with it.
It is research, not a change: every gap at the end is a claim with a number behind it,
and none of them has been acted on yet.

## 1. What DJs actually do, measured

The best evidence is not what DJs say, it is 1,557 real mixes taken apart. Kim et al.
aligned mixes from 1001Tracklists against the original tracks with subsequence DTW and
recovered where every track entered and left: 24,202 tracks and **20,765 transitions**,
1,570 hours. What that record says:

| | |
|---|---|
| Transition lengths | The histogram **peaks at every 32 beats** — a phrase. Transitions cluster on 32, 64, 128 beats. |
| Tempo | **86.1%** of tracks are stretched less than 5%, **94.5%** less than 10%, **98.6%** less than 20%. The distribution is double-exponential, piled at zero. |
| Key | **Only 2.5% of tracks are transposed at all**, and of those **94.3% by a single semitone**. |
| Cue agreement | Across different DJs playing the same track: **23.6%** of cue-point pairs agree exactly, **40.4%** within one measure, **73.6%** within 8, **86.2%** within 16. |
| Which cue reads as the boundary | A listener's sense of "the next track started" lands on the **cue-in** 52% of the time, the cue-out 30%, the middle of the transition 18%. |

Two of those are worth restating because they cut against what an automatic system is
tempted to do.

**DJs do not pitch records to fit; they pick records that fit.** 97.5% of tracks go out
at the key they were made in. Key lock is on and left on. Harmonic mixing, in practice,
is a *selection* problem solved before the record is on the deck — not a correction
applied during the mix.

**Cue points are a property of the track, not of the night.** Different DJs, different
sets, different years: 86% agree within 16 bars on where a given record is entered and
left. That is a strong signal that a track has a small number of right answers and they
can be found once and kept.

There is one asymmetry in the paper worth noting: the cue-**out** distribution "shows
more distinctive peaks around every 32 beats" than the cue-in does. DJs are stricter
about leaving on the phrase than about arriving on it.

## 2. The rules DJs give when you ask them

Zehren, Alunno and Bientinesi interviewed professional DJs and reduced what they said to
three rules for a *switch point* — the moment the next record becomes the one you are
listening to. Their implementation of these scored ~96% usable points on 134 expert-
annotated tracks.

- **Novelty.** A switch point marks a position of high novelty in rhythmic density,
  loudness, timbre and/or harmony.
- **Sections.** A switch point *always* occurs on the downbeat at the start of a period.
  In EDM that is every four bars: "every period of four bars anticipates the potential
  start of a new music section."
- **Salience.** The section following the switch has to be able to stand on its own in
  the mix — a new melody, a new bassline, a new drum pattern. Something the room's
  attention can land on.

And an admission in their own text that matters more than the rules: a DJ often wants to
switch **four or eight bars before** the new record shows any novelty, to build
anticipation. The switch point is where the new record *takes over*; the mix starts
before it.

The machine-learning work agrees on the length. DJtransGAN (Chen et al., ICASSP 2022),
trained on real mixes, **fixes its transition region at eight bars** and picks its cue
points as "the first downbeat of the last eight bars" of the outgoing track and "the last
downbeat of the first eight bars" of the incoming. It filters candidate pairs to **≤5 BPM
apart and ≤2 semitones apart** rather than stretching or transposing them into place.

## 3. When to use which move

The practice literature is less precise but consistent about the conditions:

- **Intro over outro, 16–32 bars** is the default and the failsafe — it works without
  knowing either record well. Start the incoming 32 beats before the outgoing's phrase
  ends.
- **Long blends** suit house and techno, where the percussion gives room to layer.
  **Short moves and cuts** suit hip-hop, pop and open-format, where the records are
  vocal-led and recognisable, and where a long blend blurs both.
- **Respect the chorus.** Mix out of a chorus, not through it: the room should get the
  payoff before the record leaves. For pop with a 16-count intro and a 32–64-count
  chorus, time the new record's verse to start as the old chorus ends.
- **Two vocals at once is the thing everybody hears.** Vocal-to-vocal is possible but
  wants cleaner phrasing and harder EQ.
- **Breakdowns are free room** — one record strips back, the other walks in.
- **Vary it.** All cuts is frantic; all long blends is flat.

At the set level the shape is: open at **60–70% of peak energy**, build, peak where
anticipation is highest, then down to a close. Within a sustained high, the skill is
micro-variation — small dips, brief breakdowns, texture changes — rather than eleven
records at ten.

## 4. What our auto DJ does now

**Where it leaves** (`AutoMix.outPoint`). The analysis's `mix_out` cue, or `end − length`
where there is none; never so late that the move runs past the end of the sound; snapped
to the phrase grid. A `mix_out` that lands before `mix_in` is treated as no cue at all.

**Where it lands** (`AutoMix.inPoint`). `(drop or mix_in) − bars`, clamped to the first
downbeat, so that the new record's drop or first full section falls on the move's last
beat. If those bars are quiet — 8 dB under the record's loud bars, by the structure —
it comes in later instead, because a record parked in near-silence makes a blend into a
hole. Then snapped to the four-bar marker grid and onto the steady grid.

**Which move** (`Planner.options`). Places first — the outro, the old record's own
breakdown, the stretch it last sings; the new record's intro end, its drop, its hook —
then every move that can join them, each scored for fit, weighted by three dials
(length, risk, vocals), penalised for bars of two voices at once, for a key clash, and
for having been used lately, plus a little chance so a set is not one move eleven times.

**How long.** 8, 16, 32 or 64 bars from the dials; `AutoMix.choose`'s older rules also
produce 1, 2, 4 and 12.

## 5. Where we differ

Ranked by how much the evidence supports acting, and honest about which are guesses.
The first two have since been acted on; the rest have not.

**1. We transpose far more than DJs do.** `_shiftToFit` offers ±1 *and* ±2 semitones,
and `considerMended` puts a shifted variant of the blend, the stem blend and the echo
out on the table as a routine alternative whenever the keys clash and the desk can
shift. The measured rate in real mixes is 2.5% of tracks, and 94.3% of those move by a
single semitone. The move that matches practice is to pick a record that fits — which
`SetPlanner` already does — and to treat a shift as a rare last resort of one semitone,
not as the standing second option on every clash. *Strongest evidence of
anything here.*

> **Done.** `_shiftToFit` now offers one semitone either way and no more, and the
> penalty on a shifted candidate went from ×0.9 to ×0.55 — enough that the unshifted
> option's own clash penalty beats it in the ordinary case, which is the way round the
> measurement says it should be.

**2. The tempo penalty is the wrong shape.** `bridgeReach` is ±16%, and `SetPlanner.tempo`
scores linearly across it: 8% costs half of what 16% costs. The real distribution is
double-exponential — 86% under 5%, and everything past 10% is the last 5% of transitions.
A linear penalty treats an 8% stretch as ordinary when it is already unusual. The reach
itself is defensible as a hard limit; the curve inside it is not.

> **Done.** The term is now a Gaussian falling away from a 5% "comfortable" figure —
> where the unusual fifth of real transitions begins — instead of a straight line
> across the reach. A 5% stretch now scores what 10% used to (0.284 against 0.287);
> 16% is unchanged at the floor. The reach still says what is possible.

**3. Two bar counts are not phrase multiples.** `AutoMix.choose` returns `bars: 12` for a
sweep and `bars: 2`/`bars: 4` for fades. The measured histogram peaks every 32 beats —
8 bars. Twelve bars is three four-bar periods, so it is not *wrong* by Rule 2, but it is
not where real transitions sit either. Worth checking whether 8 or 16 sounds better in
the same slot.

**4. Nothing respects the chorus.** We leave at `mix_out` whatever the record was doing.
The one place we consider what the old record last sang is `_lastSung`, and only for the
a cappella out. A vocal record left in the middle of its last chorus is a specific,
audible mistake that we have no rule against.

**5. Salience is only half-checked.** `quietBars` is a loudness test: don't come in on a
thin intro. Rule 3 is stronger — the section after the switch should have something in
it worth listening to. We have the structure (`drops_ms`, sections, the vocal map) to ask
"is there novelty here", and we only ask "is it loud enough".

**6. Cue points are recomputed, never kept.** 86% of real cue choices on a track agree
within 16 bars across different DJs. That says a record has a right answer worth finding
once and storing — and worth correcting by hand once, for good. We recompute per move
and keep nothing.

**7. The set's arc does not reach the move.** `EnergyArc` shapes which records are
chosen; `StyleAxes.risk` shapes which moves. They are independent, so a cool-down can
still be handed a drop swap. The practice literature treats the two as one decision.

## 6. What this does not settle

- Everything in §1 is EDM and EDM-adjacent, from 1001Tracklists. A library of anything
  else — the chorus rule, the short-intro pop case — is covered only by §3, which is
  practitioner advice rather than measurement.
- None of it says how *often* to use a trick against a blend. "Vary it" is as precise as
  the sources get, and our recency penalty (−0.4 for the move just made, −0.12 for one
  in the last four) is a guess that nothing here confirms or refutes.
- The offline probe can measure whether a move is clean. It cannot measure whether it was
  the right move to make there. That gap is why the above is a reading list and not a
  patch.

## Sources

- Kim, Choi, Sacks, Yang, Nam, *A Computational Analysis of Real-World DJ Mixes using
  Mix-To-Track Subsequence Alignment*, ISMIR 2020 — <https://archives.ismir.net/ismir2020/paper/000352.pdf>
- Zehren, Alunno, Bientinesi, *Automatic Detection of Cue Points for DJ Mixing*,
  2020 — <https://arxiv.org/abs/2007.08411>; expanded as *Automatic Detection of Cue
  Points for the Emulation of DJ Mixing*, Computer Music Journal 46(3)
- Chen, Hung, Yang et al., *Automatic DJ Transitions with Differentiable Audio Effects
  and Generative Adversarial Networks*, ICASSP 2022 — <https://arxiv.org/abs/2110.06525>
- DJ TechTools, *Phrasing The Perfect Mix* — <https://djtechtools.com/2009/01/26/phrasing-the-perfect-mix/>
- Vibes, *Types of DJ Transitions: 9 Moves and When to Use Each* — <https://vibesdj.io/learn/techniques/track-transition-techniques>
- EDM Ghost Production, *Warm-Up, Peak-Time & Closing Sets* — <https://edm-ghost-production.com/dj-knowledge-base/warm-up-peak-time-closing-sets>
