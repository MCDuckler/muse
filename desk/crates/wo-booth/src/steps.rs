//! What a transition does, written down as steps — ported from v1's `Booth.plan`
//! (app/lib/src/state/booth/booth.dart): each a point in the move (0 at the start, 1 at
//! the end) where the fader is, what each deck's bands, filter, stems, echo, pitch shift
//! and chop are by then, a loop caught or tightened or let go, a brake, a part swapped,
//! or a sound of the booth's own fired.
//!
//! Continuous things (the fader, the filter, the shift, the chop's depth, the stems) are
//! travelled between the steps that set them; a band is reached over the beat before
//! its step; the rest happen as the step is reached. [`on_bars`] puts every step on a
//! downbeat of the move (a halved loop on a beat).
use crate::mix::Transition;

/// A band all the way down: gone to the ear, back without a click.
pub const KILLED: f32 = -40.0;

/// The three bands in decibels (0 flat, [`KILLED`] gone).
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct EqSet {
    pub low: f32,
    pub mid: f32,
    pub high: f32,
}

impl EqSet {
    pub const FLAT: EqSet = EqSet { low: 0.0, mid: 0.0, high: 0.0 };

    pub const fn low(db: f32) -> EqSet {
        EqSet { low: db, mid: 0.0, high: 0.0 }
    }

    pub fn lerp(self, to: EqSet, t: f32) -> EqSet {
        let t = t.clamp(0.0, 1.0);
        EqSet { low: self.low + (to.low - self.low) * t, mid: self.mid + (to.mid - self.mid) * t, high: self.high + (to.high - self.high) * t }
    }

    pub fn close_to(self, o: EqSet) -> bool {
        (self.low - o.low).abs() < 0.05 && (self.mid - o.mid).abs() < 0.05 && (self.high - o.high).abs() < 0.05
    }
}

/// A stems deck's levels, 0..1: drums, bass and the rest, voice (v1's StemLevels).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Levels {
    pub drums: f32,
    pub rest: f32,
    pub vocals: f32,
}

impl Levels {
    pub const ALL: Levels = Levels { drums: 1.0, rest: 1.0, vocals: 1.0 };
    pub const NONE: Levels = Levels { drums: 0.0, rest: 0.0, vocals: 0.0 };
    pub const fn new(drums: f32, rest: f32, vocals: f32) -> Levels {
        Levels { drums, rest, vocals }
    }

    /// The same travel at equal power: each stem's energy moves evenly, so two records'
    /// drums handing over meet at 0.71 each and the room stays as loud as one of them.
    pub fn lerp_power(self, to: Levels, t: f32) -> Levels {
        let t = t.clamp(0.0, 1.0);
        let one = |a: f32, b: f32| (a * a + (b * b - a * a) * t).max(0.0).sqrt();
        Levels { drums: one(self.drums, to.drums), rest: one(self.rest, to.rest), vocals: one(self.vocals, to.vocals) }
    }

    pub fn close_to(self, o: Levels) -> bool {
        (self.drums - o.drums).abs() < 0.005 && (self.rest - o.rest).abs() < 0.005 && (self.vocals - o.vocals).abs() < 0.005
    }

    pub fn as_array(self) -> [f32; 3] {
        [self.drums, self.rest, self.vocals]
    }
}

/// What plays of a record: the whole of it, or a part of its stems.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub enum Part {
    #[default]
    Whole,
    Drums,
    /// Everything but the drums.
    Music,
    /// Everything but the voice.
    Instrumental,
    Vocals,
}

impl Part {
    pub const ALL: [Part; 5] = [Part::Whole, Part::Drums, Part::Music, Part::Instrumental, Part::Vocals];

    /// The pad's word, as v1's.
    pub fn word(self) -> &'static str {
        match self {
            Part::Whole => "WHOLE",
            Part::Drums => "DRUMS",
            Part::Music => "MUSIC",
            Part::Instrumental => "NO VOX",
            Part::Vocals => "VOCALS",
        }
    }

    /// What it is, in words.
    pub fn says(self) -> &'static str {
        match self {
            Part::Whole => "The whole record",
            Part::Drums => "The drums alone",
            Part::Music => "The music without its drums",
            Part::Instrumental => "The record without its voice",
            Part::Vocals => "The voice alone",
        }
    }

    /// v1's name for it (the house's part names, session files).
    pub fn name(self) -> Option<&'static str> {
        match self {
            Part::Whole => None,
            Part::Drums => Some("drums"),
            Part::Music => Some("music"),
            Part::Instrumental => Some("instrumental"),
            Part::Vocals => Some("vocals"),
        }
    }

    /// The stems' levels it is (mixer.dart StemLevels.of).
    pub fn levels(self) -> Levels {
        match self {
            Part::Whole => Levels::ALL,
            Part::Drums => Levels::new(1.0, 0.0, 0.0),
            Part::Music => Levels::new(0.0, 1.0, 1.0),
            Part::Instrumental => Levels::new(1.0, 1.0, 0.0),
            Part::Vocals => Levels::new(0.0, 0.0, 1.0),
        }
    }
}

/// A sound the booth makes itself (v1's fx_sounds.dart).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum FxSound {
    /// Noise and a tone climbing under a build, stopping dead on the one.
    Riser,
    /// A hit on the one: a low thump and a crack, a tail.
    Impact,
    /// Noise swept up into a change, and down away from it.
    SweepUp,
    SweepDown,
    /// A resonant wash of noise arching over the change.
    Hydrant,
}

/// A booth's sound fired as its step is reached: so long (a fraction of the move, or so
/// many beats), so loud.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct FxShot {
    pub sound: FxSound,
    /// A fraction of the move's length (when `beats` is none).
    pub span: f64,
    pub beats: Option<f64>,
    pub gain_db: f32,
}

impl FxShot {
    const fn span(sound: FxSound, span: f64, gain_db: f32) -> FxShot {
        FxShot { sound, span, beats: None, gain_db }
    }
    const fn beats(sound: FxSound, beats: f64, gain_db: f32) -> FxShot {
        FxShot { sound, span: 0.0, beats: Some(beats), gain_db }
    }
    /// Seconds, in a move `move_s` long with beats `beat_s` long.
    pub fn seconds(&self, move_s: f64, beat_s: f64) -> f64 {
        self.beats.map_or(self.span * move_s, |b| b * beat_s)
    }
}

/// A loop asked of a deck by a step.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LoopStep {
    /// Caught: so many bars from the bar.
    Bars(u32),
    /// The running loop halved.
    Halve,
    /// Let go.
    Off,
}

/// What a step does to one deck. None leaves a thing as it is.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct DeckStep {
    pub eq: Option<EqSet>,
    /// The filter, -1 (low-pass shut) .. 0 (off) .. 1 (high-pass shut): travelled to.
    pub filter: Option<f32>,
    pub looped: Option<LoopStep>,
    pub brake: bool,
    /// The part on the platter from here (a swap).
    pub part: Option<Part>,
    /// A stems deck's levels by now: travelled to at equal power.
    pub stems: Option<Levels>,
    /// The echo's send and the record's own (dry) level, 0..1.
    pub echo: Option<f32>,
    pub dry: Option<f32>,
    /// The pitch shift in semitones: travelled to (the outgoing falling away).
    pub shift: Option<f32>,
    /// The chop's depth 0..1 (travelled) and chops to a beat (held).
    pub gate: Option<f32>,
    pub gate_div: Option<u32>,
}

impl DeckStep {
    const NONE: DeckStep = DeckStep {
        eq: None,
        filter: None,
        looped: None,
        brake: false,
        part: None,
        stems: None,
        echo: None,
        dry: None,
        shift: None,
        gate: None,
        gate_div: None,
    };
    const fn eq(eq: EqSet) -> DeckStep {
        DeckStep { eq: Some(eq), ..DeckStep::NONE }
    }
    const fn filter(f: f32) -> DeckStep {
        DeckStep { filter: Some(f), ..DeckStep::NONE }
    }
    const fn stems(l: Levels) -> DeckStep {
        DeckStep { stems: Some(l), ..DeckStep::NONE }
    }
}

/// One instruction in a transition, at `at` (0..1).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Step {
    pub at: f64,
    pub crossfader: Option<f32>,
    pub from: Option<DeckStep>,
    pub to: Option<DeckStep>,
    pub fx: Option<FxShot>,
}

/// Which deck of the move.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Side {
    From,
    To,
}

impl Step {
    pub fn deck(&self, side: Side) -> Option<&DeckStep> {
        match side {
            Side::From => self.from.as_ref(),
            Side::To => self.to.as_ref(),
        }
    }
}

fn st(at: f64, crossfader: Option<f32>, from: Option<DeckStep>, to: Option<DeckStep>) -> Step {
    Step { at, crossfader, from, to, fx: None }
}

/// What `kind` does, as steps (v1's Booth.plan, recipe for recipe).
pub fn plan(kind: Transition) -> Vec<Step> {
    use Transition as T;
    let off = DeckStep { eq: Some(EqSet::FLAT), filter: Some(0.0), ..DeckStep::NONE };
    let no_bass = DeckStep::eq(EqSet::low(KILLED));
    // the bass held down for a build, the kick still there under it
    let less_bass = DeckStep::eq(EqSet::low(-18.0));
    let flat = DeckStep::eq(EqSet::FLAT);
    let x = Some;
    let d = Some;
    match kind {
        T::Blend => vec![
            st(0.0, x(0.0), None, d(no_bass)),
            st(0.5, x(0.5), d(no_bass), d(flat)),
            st(0.85, x(0.85), d(DeckStep::eq(EqSet { low: KILLED, mid: 0.0, high: KILLED })), None),
            st(1.0, x(1.0), d(off), None),
        ],
        T::Cut | T::Fade => vec![st(0.0, x(0.0), None, None), st(1.0, x(1.0), None, None)],
        T::Sweep => vec![
            st(0.0, x(0.0), d(DeckStep::filter(0.0)), d(no_bass)),
            st(0.45, x(0.35), d(DeckStep::filter(0.45)), None),
            st(0.75, x(0.7), d(DeckStep { filter: Some(0.8), eq: Some(EqSet::low(KILLED)), ..DeckStep::NONE }), d(flat)),
            st(1.0, x(1.0), d(off), None),
        ],
        T::Roll => {
            let halve = DeckStep { looped: Some(LoopStep::Halve), ..DeckStep::NONE };
            vec![
                st(0.0, x(0.0), None, d(no_bass)),
                st(0.45, x(0.45), None, d(flat)),
                st(0.5, x(0.5), d(DeckStep { looped: Some(LoopStep::Bars(2)), ..DeckStep::NONE }), None),
                st(0.75, x(0.7), d(halve), None),
                st(0.875, x(0.8), d(halve), None),
                st(0.9375, x(0.88), d(halve), None),
                st(0.96875, x(0.94), d(halve), None),
                st(1.0, x(1.0), d(DeckStep { eq: Some(EqSet::FLAT), filter: Some(0.0), looped: Some(LoopStep::Off), ..DeckStep::NONE }), None),
            ]
        }
        T::Brake => vec![
            st(0.0, x(0.0), None, d(flat)),
            st(0.7, x(0.85), None, None),
            st(0.8, x(1.0), d(DeckStep { brake: true, ..DeckStep::NONE }), None),
            st(1.0, x(1.0), d(off), None),
        ],
        T::Announce => {
            let only_voice = Levels::new(0.0, 0.0, 1.0);
            let no_voice = Levels::new(1.0, 1.0, 0.0);
            vec![
                st(0.0, x(0.5), d(DeckStep::stems(Levels::ALL)), d(DeckStep { stems: Some(Levels::NONE), eq: Some(EqSet::FLAT), ..DeckStep::NONE })),
                st(0.12, None, d(DeckStep::stems(no_voice)), d(DeckStep::stems(only_voice))),
                st(0.5, x(0.5), d(DeckStep::stems(no_voice)), d(DeckStep::stems(only_voice))),
                st(
                    0.56,
                    None,
                    d(DeckStep { eq: Some(EqSet::low(KILLED)), stems: Some(Levels::new(0.0, 1.0, 0.0)), ..DeckStep::NONE }),
                    d(DeckStep::stems(Levels::ALL)),
                ),
                st(0.8, x(0.75), d(DeckStep { filter: Some(0.5), stems: Some(Levels::new(0.0, 1.0, 0.0)), ..DeckStep::NONE }), None),
                st(1.0, x(1.0), d(DeckStep { eq: Some(EqSet::FLAT), filter: Some(0.0), stems: Some(Levels::ALL), ..DeckStep::NONE }), None),
            ]
        }
        T::AcapellaOut => {
            let only_voice = Levels::new(0.0, 0.0, 1.0);
            vec![
                st(0.0, x(0.0), d(DeckStep::stems(Levels::ALL)), d(DeckStep { stems: Some(Levels::new(1.0, 1.0, 0.0)), eq: Some(EqSet::low(KILLED)), ..DeckStep::NONE })),
                st(0.25, x(0.5), d(DeckStep::stems(Levels::new(0.0, 0.5, 1.0))), d(flat)),
                st(0.45, None, d(DeckStep::stems(only_voice)), None),
                st(0.8, x(0.5), d(DeckStep::stems(only_voice)), d(DeckStep::stems(Levels::new(1.0, 1.0, 0.0)))),
                st(0.92, x(1.0), None, d(DeckStep::stems(Levels::ALL))),
                st(1.0, x(1.0), d(DeckStep { eq: Some(EqSet::FLAT), filter: Some(0.0), stems: Some(Levels::ALL), ..DeckStep::NONE }), None),
            ]
        }
        T::StemBlend => {
            let none = Levels::NONE;
            let no_drums = Levels::new(0.0, 1.0, 1.0);
            let drums = Levels::new(1.0, 0.0, 0.0);
            vec![
                st(0.0, x(0.5), d(DeckStep::stems(Levels::ALL)), d(DeckStep { stems: Some(none), eq: Some(EqSet::FLAT), ..DeckStep::NONE })),
                st(0.19, None, d(DeckStep::stems(Levels::ALL)), d(DeckStep::stems(none))),
                st(0.25, None, d(DeckStep::stems(no_drums)), d(DeckStep::stems(drums))),
                st(0.44, None, d(DeckStep::stems(no_drums)), d(DeckStep::stems(drums))),
                st(0.5, None, d(DeckStep::stems(Levels::new(0.0, 0.0, 1.0))), d(DeckStep::stems(Levels::new(1.0, 1.0, 0.0)))),
                st(0.7, x(0.5), d(DeckStep::stems(none)), None),
                st(0.9, x(1.0), None, d(DeckStep::stems(Levels::ALL))),
                st(1.0, x(1.0), d(DeckStep { eq: Some(EqSet::FLAT), filter: Some(0.0), stems: Some(Levels::ALL), ..DeckStep::NONE }), None),
            ]
        }
        T::DropSwap => vec![
            st(0.0, x(0.0), d(DeckStep::filter(0.0)), d(less_bass)),
            st(0.5, x(0.5), d(DeckStep::filter(0.15)), None),
            st(0.75, x(0.65), d(DeckStep { filter: Some(0.4), looped: Some(LoopStep::Bars(1)), ..DeckStep::NONE }), None),
            st(0.875, None, d(DeckStep { filter: Some(0.55), looped: Some(LoopStep::Halve), ..DeckStep::NONE }), None),
            st(0.95, x(0.75), d(DeckStep { filter: Some(0.7), looped: Some(LoopStep::Halve), ..DeckStep::NONE }), None),
            st(
                1.0,
                x(1.0),
                d(DeckStep { eq: Some(EqSet::FLAT), filter: Some(0.0), looped: Some(LoopStep::Off), ..DeckStep::NONE }),
                d(DeckStep { eq: Some(EqSet::FLAT), filter: Some(0.0), ..DeckStep::NONE }),
            ),
        ],
        T::EchoOut => {
            let echo = |e: f32, dry: f32| DeckStep { echo: Some(e), dry: Some(dry), ..DeckStep::NONE };
            vec![
                st(0.0, x(0.0), None, d(no_bass)),
                st(0.5, x(0.5), d(no_bass), d(flat)),
                st(0.625, x(0.6), d(echo(0.35, 1.0)), None),
                st(0.75, x(0.6), d(echo(0.6, 1.0)), None),
                st(0.78, x(0.6), d(echo(0.0, 0.0)), None),
                st(0.875, x(0.75), None, None),
                st(1.0, x(1.0), d(DeckStep { eq: Some(EqSet::FLAT), filter: Some(0.0), echo: Some(0.0), dry: Some(1.0), ..DeckStep::NONE }), None),
            ]
        }
        T::LoopBuild => vec![
            st(0.0, x(0.0), d(DeckStep::filter(0.0)), d(less_bass)),
            st(0.5, x(0.5), d(DeckStep { filter: Some(0.15), looped: Some(LoopStep::Bars(4)), ..DeckStep::NONE }), None),
            st(0.75, x(0.65), d(DeckStep { filter: Some(0.4), looped: Some(LoopStep::Halve), ..DeckStep::NONE }), None),
            st(0.875, x(0.7), d(DeckStep { filter: Some(0.55), looped: Some(LoopStep::Halve), ..DeckStep::NONE }), None),
            st(0.9375, x(0.75), d(DeckStep { filter: Some(0.7), looped: Some(LoopStep::Halve), ..DeckStep::NONE }), None),
            st(
                1.0,
                x(1.0),
                d(DeckStep { eq: Some(EqSet::FLAT), filter: Some(0.0), looped: Some(LoopStep::Off), ..DeckStep::NONE }),
                d(DeckStep { eq: Some(EqSet::FLAT), filter: Some(0.0), ..DeckStep::NONE }),
            ),
        ],
        T::BreakSwap => vec![
            st(0.0, x(0.0), None, d(no_bass)),
            st(0.3, x(0.5), None, None),
            st(0.6, x(0.5), d(no_bass), d(flat)),
            st(0.9, x(0.7), d(DeckStep::filter(0.4)), None),
            st(1.0, x(1.0), d(off), None),
        ],
        T::FilterRide => vec![
            st(0.0, x(0.0), d(DeckStep::filter(0.0)), d(DeckStep { filter: Some(-0.5), eq: Some(EqSet::low(KILLED)), ..DeckStep::NONE })),
            st(0.4, x(0.4), d(DeckStep::filter(0.25)), d(DeckStep { filter: Some(-0.4), eq: Some(EqSet::low(-12.0)), ..DeckStep::NONE })),
            st(
                0.5,
                x(0.5),
                d(DeckStep { filter: Some(0.35), eq: Some(EqSet::low(KILLED)), ..DeckStep::NONE }),
                d(DeckStep { filter: Some(-0.3), eq: Some(EqSet::FLAT), ..DeckStep::NONE }),
            ),
            st(0.85, x(0.85), d(DeckStep::filter(0.8)), d(DeckStep::filter(0.0))),
            st(1.0, x(1.0), d(off), None),
        ],
        T::Riser => vec![
            Step { fx: Some(FxShot::span(FxSound::Riser, 1.0, -13.0)), ..st(0.0, x(0.0), d(DeckStep::filter(0.0)), d(no_bass)) },
            st(0.75, x(0.12), d(DeckStep::filter(0.2)), None),
            st(0.94, x(0.3), d(DeckStep::filter(0.55)), None),
            Step {
                fx: Some(FxShot::beats(FxSound::Impact, 8.0, -15.0)),
                ..st(
                    1.0,
                    x(1.0),
                    d(DeckStep { eq: Some(EqSet::FLAT), filter: Some(0.0), ..DeckStep::NONE }),
                    d(DeckStep { eq: Some(EqSet::FLAT), filter: Some(0.0), ..DeckStep::NONE }),
                )
            },
        ],
        T::NoiseSweep => vec![
            Step { fx: Some(FxShot::span(FxSound::SweepUp, 0.5, -14.0)), ..st(0.0, x(0.0), None, d(no_bass)) },
            Step { fx: Some(FxShot::span(FxSound::SweepDown, 0.5, -16.0)), ..st(0.5, x(0.5), d(no_bass), d(flat)) },
            st(0.85, x(0.85), d(DeckStep::eq(EqSet { low: KILLED, mid: 0.0, high: KILLED })), None),
            st(1.0, x(1.0), d(off), None),
        ],
        T::Hydrant => vec![
            Step { fx: Some(FxShot::span(FxSound::Hydrant, 1.0, -11.0)), ..st(0.0, x(0.0), None, d(no_bass)) },
            st(0.3, x(0.3), d(DeckStep::eq(EqSet { low: 0.0, mid: 0.0, high: -9.0 })), None),
            st(0.5, x(0.5), d(DeckStep::eq(EqSet { low: KILLED, mid: 0.0, high: -12.0 })), d(flat)),
            st(0.8, x(0.85), d(DeckStep::eq(EqSet { low: KILLED, mid: 0.0, high: KILLED })), None),
            st(1.0, x(1.0), d(off), None),
        ],
        T::Dissolve => vec![
            st(0.0, x(0.0), d(DeckStep { echo: Some(0.15), dry: Some(1.0), filter: Some(0.0), ..DeckStep::NONE }), d(no_bass)),
            st(0.4, x(0.4), d(DeckStep { echo: Some(0.45), dry: Some(0.85), filter: Some(-0.25), eq: Some(EqSet::low(KILLED)), ..DeckStep::NONE }), None),
            st(0.65, x(0.6), d(DeckStep { echo: Some(0.7), dry: Some(0.5), filter: Some(-0.5), ..DeckStep::NONE }), d(flat)),
            st(0.85, x(0.8), d(DeckStep { echo: Some(0.8), dry: Some(0.15), filter: Some(-0.7), ..DeckStep::NONE }), None),
            st(0.93, x(0.9), d(DeckStep { echo: Some(0.0), dry: Some(0.0), ..DeckStep::NONE }), None),
            st(1.0, x(1.0), d(DeckStep { eq: Some(EqSet::FLAT), filter: Some(0.0), echo: Some(0.0), dry: Some(1.0), ..DeckStep::NONE }), None),
        ],
        T::LunarEcho => vec![
            st(0.0, x(0.0), d(DeckStep { echo: Some(0.2), dry: Some(1.0), shift: Some(0.0), filter: Some(0.0), ..DeckStep::NONE }), d(no_bass)),
            st(0.5, x(0.5), d(DeckStep { echo: Some(0.45), dry: Some(1.0), shift: Some(0.0), eq: Some(EqSet::low(KILLED)), ..DeckStep::NONE }), d(flat)),
            st(0.75, x(0.65), d(DeckStep { echo: Some(0.75), dry: Some(1.0), shift: Some(-2.0), filter: Some(-0.2), ..DeckStep::NONE }), None),
            st(0.88, x(0.75), d(DeckStep { echo: Some(0.85), dry: Some(0.0), shift: Some(-5.0), filter: Some(-0.45), ..DeckStep::NONE }), None),
            st(
                1.0,
                x(1.0),
                d(DeckStep { eq: Some(EqSet::FLAT), filter: Some(0.0), echo: Some(0.0), dry: Some(1.0), shift: Some(0.0), ..DeckStep::NONE }),
                None,
            ),
        ],
        T::Tremolo => vec![
            st(0.0, x(0.0), d(DeckStep { gate: Some(0.0), gate_div: Some(2), ..DeckStep::NONE }), d(no_bass)),
            st(0.25, x(0.25), d(DeckStep { gate: Some(0.5), ..DeckStep::NONE }), None),
            st(0.5, x(0.5), d(DeckStep { gate: Some(0.8), eq: Some(EqSet::low(KILLED)), ..DeckStep::NONE }), d(flat)),
            st(0.75, x(0.7), d(DeckStep { gate: Some(0.95), gate_div: Some(4), ..DeckStep::NONE }), None),
            st(0.9, x(0.88), d(DeckStep::filter(0.35)), None),
            st(1.0, x(1.0), d(DeckStep { eq: Some(EqSet::FLAT), filter: Some(0.0), gate: Some(0.0), gate_div: Some(2), ..DeckStep::NONE }), None),
        ],
        T::Swap => vec![
            st(0.0, x(0.0), None, d(DeckStep { part: Some(Part::Drums), eq: Some(EqSet::FLAT), ..DeckStep::NONE })),
            st(0.4, x(0.4), d(DeckStep { part: Some(Part::Music), ..DeckStep::NONE }), None),
            st(0.7, x(0.75), None, d(DeckStep { part: Some(Part::Whole), eq: Some(EqSet::FLAT), ..DeckStep::NONE })),
            st(1.0, x(1.0), d(DeckStep { eq: Some(EqSet::FLAT), filter: Some(0.0), ..DeckStep::NONE }), None),
        ],
    }
}

/// `steps` put onto the bars of a move `bars` long: each on a downbeat, where a DJ does
/// it (0.85 of sixteen bars is bar 13.6: an EQ changed part-way through a bar). A
/// halved loop lands on a beat: the last rungs of a roll are shorter than a bar.
pub fn on_bars(steps: Vec<Step>, bars: u32) -> Vec<Step> {
    if bars <= 1 {
        return steps;
    }
    let b = bars as f64;
    steps
        .into_iter()
        .map(|s| {
            let halves = [s.from, s.to].iter().flatten().any(|d| d.looped == Some(LoopStep::Halve));
            let at = if halves { (s.at * b * 4.0).round() / (b * 4.0) } else { (s.at * b).round() / b };
            Step { at, ..s }
        })
        .collect()
}

/// Where the crossfader is at `k` (0 = the outgoing alone): travelled between the steps
/// that set it.
pub fn fader_at(steps: &[Step], k: f64) -> f32 {
    let (mut before, mut after) = (None::<&Step>, None::<&Step>);
    for s in steps.iter().filter(|s| s.crossfader.is_some()) {
        if s.at <= k {
            before = Some(s);
        } else if after.is_none() {
            after = Some(s);
        }
    }
    match (before, after) {
        (None, a) => a.and_then(|s| s.crossfader).unwrap_or(0.0),
        (Some(b), None) => b.crossfader.unwrap(),
        (Some(b), Some(a)) => {
            let span = a.at - b.at;
            let local = if span <= 0.0 { 1.0 } else { ((k - b.at) / span).clamp(0.0, 1.0) } as f32;
            b.crossfader.unwrap() + (a.crossfader.unwrap() - b.crossfader.unwrap()) * local
        }
    }
}

/// The pair of steps `k` falls between (by index) and how far between.
fn leg(steps: &[Step], k: f64) -> (usize, usize, f32) {
    let (mut prev, mut cur) = (0, steps.len() - 1);
    for i in 1..steps.len() {
        if k <= steps[i].at {
            prev = i - 1;
            cur = i;
            break;
        }
    }
    let span = steps[cur].at - steps[prev].at;
    let local = if span <= 0.0 { 1.0 } else { ((k - steps[prev].at) / span).clamp(0.0, 1.0) };
    (prev, cur, local as f32)
}

/// A travelled value of one deck at `k`: from the last set at or before the leg's start
/// to the leg's end's (held where that says nothing). None where nothing set it yet.
fn travelled(steps: &[Step], side: Side, k: f64, of: impl Fn(&DeckStep) -> Option<f32>) -> Option<f32> {
    if steps.is_empty() {
        return None;
    }
    let (prev, cur, local) = leg(steps, k);
    let a = (0..=prev).rev().find_map(|i| steps[i].deck(side).and_then(&of))?;
    let b = steps[cur].deck(side).and_then(&of).unwrap_or(a);
    Some(a + (b - a) * local)
}

pub fn filter_at(steps: &[Step], side: Side, k: f64) -> Option<f32> {
    travelled(steps, side, k, |d| d.filter)
}

pub fn shift_at(steps: &[Step], side: Side, k: f64) -> Option<f32> {
    travelled(steps, side, k, |d| d.shift)
}

pub fn gate_at(steps: &[Step], side: Side, k: f64) -> Option<f32> {
    travelled(steps, side, k, |d| d.gate)
}

/// Chops to a beat at `k`: held from the last step that set it (2: eighths).
pub fn gate_div_at(steps: &[Step], side: Side, k: f64) -> u32 {
    steps.iter().take_while(|s| s.at <= k).filter_map(|s| s.deck(side).and_then(|d| d.gate_div)).last().unwrap_or(2)
}

/// A stems deck's levels at `k`, at equal power from the last step that set them to the
/// next. The last step (at 1) is not moved towards: it puts the deck back once the fader
/// has it out, or the outgoing's voice would come back under the last bars.
pub fn stems_at(steps: &[Step], side: Side, k: f64) -> Option<Levels> {
    let (mut before, mut after) = (None::<&Step>, None::<&Step>);
    for s in steps.iter().filter(|s| s.deck(side).is_some_and(|d| d.stems.is_some())) {
        if s.at <= k {
            before = Some(s);
        } else if after.is_none() {
            after = Some(s);
        }
    }
    let a = before?.deck(side)?.stems?;
    match after {
        Some(n) if n.at < 1.0 => {
            let span = n.at - before.unwrap().at;
            let t = if span <= 0.0 { 1.0 } else { ((k - before.unwrap().at) / span).clamp(0.0, 1.0) } as f32;
            Some(a.lerp_power(n.deck(side)?.stems?, t))
        }
        _ => Some(a),
    }
}

/// The bands at `k` while one is being turned: a step's EQ is reached over the beat
/// before it (`beat_k`: one beat as a fraction of the move) from the last set (or
/// `began`). None between turns: the step sets it as it is reached.
/// Where the incoming's bass comes back, as a fraction of the move (the blends' swap).
pub fn bass_swap(steps: &[Step]) -> Option<f64> {
    let mut killed = false;
    for s in steps {
        if let Some(e) = s.to.and_then(|d| d.eq) {
            if e.low <= -30.0 {
                killed = true;
            } else if killed && e.low > -1.0 {
                return Some(s.at);
            }
        }
    }
    None
}

pub fn eq_at(steps: &[Step], side: Side, k: f64, began: EqSet, beat_k: f64) -> Option<EqSet> {
    let mut prev = None;
    let mut coming = None;
    for s in steps {
        let Some(e) = s.deck(side).and_then(|d| d.eq) else { continue };
        if s.at <= k {
            prev = Some(e);
        } else {
            coming = Some((s.at, e));
            break;
        }
    }
    let (at, e) = coming?;
    let start = at - beat_k;
    if k < start {
        return None;
    }
    Some(prev.unwrap_or(began).lerp(e, ((k - start) / beat_k) as f32))
}

impl Transition {
    /// Needs the desk's echo (and, the lunar echo, its pitch shift).
    pub fn needs_fx(self) -> bool {
        matches!(self, Transition::EchoOut | Transition::Dissolve | Transition::LunarEcho)
    }
    /// Made of a sound the booth plays itself.
    pub fn needs_sound(self) -> bool {
        matches!(self, Transition::Riser | Transition::NoiseSweep | Transition::Hydrant)
    }
    /// Made of the engine's chop.
    pub fn needs_gate(self) -> bool {
        self == Transition::Tremolo
    }
    /// Made of stems: nothing it means can be done on a deck playing the whole record.
    pub fn needs_stems(self) -> bool {
        matches!(self, Transition::Announce | Transition::AcapellaOut | Transition::StemBlend | Transition::Swap)
    }
    /// What it becomes where it cannot be done.
    pub fn plainly(self) -> Transition {
        match self {
            Transition::Riser => Transition::LoopBuild,
            Transition::Hydrant => Transition::Sweep,
            _ => Transition::Blend,
        }
    }
    /// The fader's "full" law for this move (both whole at the middle) rather than equal
    /// power: one record's worth of sound shared between two decks, or a filter move
    /// whose outgoing has given most of its energy to the high-pass already.
    pub fn full(self) -> bool {
        self.needs_stems() || matches!(self, Transition::Swap | Transition::BreakSwap | Transition::Sweep | Transition::FilterRide)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_kind_starts_and_ends_and_puts_the_outgoing_back() {
        for kind in Transition::ALL {
            let s = plan(kind);
            assert!(s.len() >= 2, "{kind:?}");
            assert_eq!(s.first().unwrap().at, 0.0, "{kind:?} starts at 0");
            assert_eq!(s.last().unwrap().at, 1.0, "{kind:?} ends at 1");
            assert!(s.windows(2).all(|w| w[0].at <= w[1].at), "{kind:?} in order");
            assert_eq!(fader_at(&s, 1.0), 1.0, "{kind:?}: across at the end");
        }
    }

    #[test]
    fn a_blend_swaps_the_bass_half_way() {
        let s = on_bars(plan(Transition::Blend), 16);
        assert_eq!(fader_at(&s, 0.0), 0.0);
        assert!((fader_at(&s, 0.25) - 0.25).abs() < 1e-6, "coming up evenly");
        assert_eq!(fader_at(&s, 0.5), 0.5);
        // the incoming's bass comes back over the beat before half way
        let beat = 1.0 / 64.0;
        assert_eq!(eq_at(&s, Side::To, 0.3, EqSet::FLAT, beat), None, "between turns: left alone");
        let mid = eq_at(&s, Side::To, 0.5 - beat / 2.0, EqSet::FLAT, beat).unwrap();
        assert!((mid.low - KILLED / 2.0).abs() < 0.5, "half way through the turn: {mid:?}");
    }

    #[test]
    fn steps_land_on_bars_and_halves_on_beats() {
        let s = on_bars(plan(Transition::Blend), 16);
        assert!((s[2].at - 14.0 / 16.0).abs() < 1e-9, "0.85 of 16 bars is bar 14 ({})", s[2].at);
        let r = on_bars(plan(Transition::Roll), 8);
        // 0.96875 of 8 bars = 31 beats: on a beat, not rounded to a bar
        assert!((r[6].at - 31.0 / 32.0).abs() < 1e-9);
    }

    #[test]
    fn travelled_values_hold_where_a_leg_says_nothing() {
        let s = plan(Transition::Sweep);
        assert_eq!(filter_at(&s, Side::From, 0.0), Some(0.0));
        let f = filter_at(&s, Side::From, 0.6).unwrap();
        assert!(f > 0.45 && f < 0.8, "on its way: {f}");
        assert_eq!(filter_at(&s, Side::To, 0.6), None, "the incoming's filter is never touched");
        // the lunar echo pulls the outgoing down five semitones by 0.88
        let l = plan(Transition::LunarEcho);
        assert_eq!(shift_at(&l, Side::From, 0.88), Some(-5.0));
        assert!(shift_at(&l, Side::From, 0.6).unwrap() < 0.0);
        // the tremolo's chop rate doubles at three quarters
        let t = plan(Transition::Tremolo);
        assert_eq!((gate_div_at(&t, Side::From, 0.5), gate_div_at(&t, Side::From, 0.8)), (2, 4));
    }

    #[test]
    fn stems_hand_over_at_equal_power_and_the_last_step_is_not_approached() {
        let s = plan(Transition::StemBlend);
        let mid = stems_at(&s, Side::To, (0.19 + 0.25) / 2.0).unwrap();
        assert!((mid.drums - 0.5f32.sqrt()).abs() < 0.01, "drums meet at 0.71: {mid:?}");
        // the outgoing between 0.7 (nothing) and 1 (all again): stays at nothing
        assert_eq!(stems_at(&s, Side::From, 0.95), Some(Levels::NONE));
        assert_eq!(stems_at(&s, Side::From, 1.0), Some(Levels::ALL));
    }

    #[test]
    fn what_needs_what() {
        assert!(Transition::StemBlend.needs_stems() && Transition::StemBlend.full());
        assert!(Transition::EchoOut.needs_fx() && Transition::Riser.needs_sound() && Transition::Tremolo.needs_gate());
        assert_eq!(Transition::Riser.plainly(), Transition::LoopBuild);
        assert!(!Transition::Blend.full());
    }
}
