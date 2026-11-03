//! The dance's arithmetic apart from any drawing (v1: show_dance.dart DanceClock, DanceFrame,
//! DanceModels; show_meme.dart MemeClock's moods; stage_camera.dart CameraSweep). Every
//! choice is hashed from the record and the slot, so a record dances the same way twice.
use wo_show::combos::pick_by_weight;
use wo_show::deck::ShowDeck;
use wo_show::treat::meme_hash;

use crate::{Move, Rig};

/// The record's mood two bars at a time (show_meme.dart).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Mood {
    Sleep,
    Wake,
    Rage,
    Vibe,
}

/// The mood of deck `m`, `since_drop` beats after the last drop.
pub fn mood(m: &ShowDeck, since_drop: Option<f64>) -> Mood {
    if !m.playing {
        return Mood::Sleep;
    }
    let away = m.drop_beats_away;
    let s = m.section.as_deref();
    if since_drop.is_some_and(|d| (0.0..64.0).contains(&d)) {
        return Mood::Rage;
    }
    if away.is_some_and(|a| a > 0.0 && a <= 16.0) {
        return Mood::Wake;
    }
    if s == Some("build") || m.build_k > 0.35 {
        return Mood::Wake;
    }
    if m.breakdown || matches!(s, Some("breakdown" | "break")) {
        return Mood::Sleep;
    }
    if s == Some("drop") {
        return Mood::Rage;
    }
    if m.energy < 0.3 && matches!(s, None | Some("intro" | "outro")) {
        return Mood::Sleep;
    }
    // a record the analysis found no drops in still gets its rage where it is loudest
    if away.is_none() && since_drop.is_none() && m.energy > 0.85 && matches!(s, None | Some("chorus")) {
        return Mood::Rage;
    }
    Mood::Vibe
}

/// How hot the rage is, 0..1: all of it for the first eight bars after the drop, then a
/// phrase of groove and a phrase of chaos by turns.
pub fn heat(m: &ShowDeck, since_drop: Option<f64>) -> f64 {
    if since_drop.is_some_and(|d| (0.0..32.0).contains(&d)) {
        return 1.0;
    }
    let phrase = (m.bar_index.unwrap_or(0) as f64 / 8.0).floor() as i64;
    if phrase % 2 == 0 { 0.55 } else { 1.0 }
}

/// How near the drop a build is, 0..1.
pub fn wake_k(m: &ShowDeck) -> f64 {
    match m.drop_beats_away {
        Some(a) if a > 0.0 => (1.0 - a / 24.0).clamp(0.0, 1.0),
        _ => m.build_k.clamp(0.0, 1.0),
    }
}

macro_rules! names {
    ($(#[$m:meta])* $name:ident { $($v:ident = $s:literal),+ $(,)? }) => {
        $(#[$m])*
        #[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
        pub enum $name { $($v),+ }
        impl $name {
            pub const ALL: &'static [$name] = &[$($name::$v),+];
            pub fn name(self) -> &'static str { match self { $($name::$v => $s),+ } }
            pub fn by_name(s: &str) -> Option<$name> { match s { $($s => Some($name::$v),)+ _ => None } }
        }
    };
}

names!(
    /// Who dances: alone, or with others. Grid, ring and army are the big sets; a couple
    /// the lead and a partner dancing a duet's two halves, couples three of them.
    Troupe { Solo = "solo", Duo = "duo", Trio = "trio", Line = "line", Crowd = "crowd", Grid = "grid", Ring = "ring", Army = "army", Couple = "couple", Couples = "couples" }
);
names!(
    /// What the company does with the lead's dancing in a slot.
    Routine { Unison = "unison", Wave = "wave", Canon = "canon", Split = "split", Answer = "answer" }
);
names!(
    /// Where the camera is: in front, a few ways framed; three extreme wide angles; two fisheyes.
    Shot {
        Full = "full", Front = "front", Medium = "medium", Close = "close", Wide = "wide", ExtremeLow = "extremeLow", ExtremeHigh = "extremeHigh",
        ExtremeFront = "extremeFront", Fisheye = "fisheye", FisheyeLow = "fisheyeLow"
    }
);
names!(
    /// How the dancer scene renders the dancers.
    Art {
        Mono = "mono", Trails = "trails", Ascii = "ascii", Dither = "dither", Chrono = "chrono", Contour = "contour", Halftone = "halftone",
        Thermal = "thermal", Lines = "lines", Fluid = "fluid", Viewports = "viewports", Plain = "plain", Disco = "disco", Crt = "crt", Slit = "slit",
        Dust = "dust"
    }
);

impl Art {
    /// dance_fx.frag's mode for the renderings it finishes.
    pub fn fx_mode(self) -> Option<u32> {
        Some(match self {
            Art::Ascii => 1,
            Art::Dither => 2,
            Art::Contour => 3,
            Art::Halftone => 4,
            Art::Thermal => 5,
            Art::Lines => 6,
            Art::Crt => 8,
            _ => return None,
        })
    }

    /// The renderings the Rust stage draws (not the fluid: that needs the fluid's sim).
    pub fn drawn(self) -> bool {
        self != Art::Fluid
    }
}

/// `salt` as v1's `salt % 9973` (a Dart int's modulo is never negative).
fn s9973(salt: i64) -> f64 {
    salt.rem_euclid(9973) as f64
}

/// Track beats in a slot: one choice of move, troupe and shot — four bars.
pub const SLOT_BEATS: f64 = 16.0;

/// How far `beats` is past the record's beat a move danced at `rate` counts from: the beat,
/// or at half time (and slower) the first of its pair.
pub fn since_beat(beats: f64, rate: f64) -> f64 {
    let period = if rate < 1.0 { 1.0 / rate } else { 1.0 };
    beats - (beats / period).floor() * period
}

/// How many moves of a tier a record dances: its own few.
pub const VOCABULARY: usize = 5;

fn id_hash(id: &str) -> i64 {
    let mut h: i64 = 0x811c9dc5;
    for c in id.encode_utf16() {
        h = ((h ^ c as i64).wrapping_mul(0x01000193)) & 0x7fffffff;
    }
    h
}

/// `pool` narrowed to the record's own [VOCABULARY]: a weighted draw without putting back, by
/// the record's and the move's dice.
pub fn own_moves(pool: &[(usize, f64)], moves: &[Move], salt: i64) -> Vec<(usize, f64)> {
    if pool.len() <= VOCABULARY {
        return pool.to_vec();
    }
    let mut keyed: Vec<(usize, f64, f64)> = pool
        .iter()
        .map(|&(m, w)| (m, w, meme_hash(s9973(salt), (id_hash(&moves[m].id) % 99991) as f64, 13.0).clamp(1e-9, 1.0).powf(1.0 / w)))
        .collect();
    keyed.sort_by(|a, b| b.2.total_cmp(&a.2));
    let mut out: Vec<(usize, f64)> = keyed.into_iter().take(VOCABULARY).map(|(m, w, _)| (m, w)).collect();
    out.sort_by(|a, b| b.1.total_cmp(&a.1));
    out
}

/// Capture beats danced per track beat: 1, or half/double time far off the capture's tempo;
/// a sleeping record at half again.
pub fn rate(track_bpm: f64, move_bpm: f64, sleep: bool) -> f64 {
    let q = track_bpm / move_bpm;
    let r = if q > 1.45 { 0.5 } else if q < 0.7 { 2.0 } else { 1.0 };
    if sleep { r / 2.0 } else { r }
}

/// How true `m` dances to a record at `track_bpm`, 0..1 (`width` in octaves).
pub fn tempo_fit(track_bpm: f64, m: &Move, width: f64) -> f64 {
    let played = track_bpm * rate(track_bpm, m.bpm, false);
    let l = (played / m.bpm).ln() / std::f64::consts::LN_2;
    (-l * l / (2.0 * width * width)).exp()
}

/// How far a pumping move may be stretched on techno.
pub const TECHNO_STRETCH: f64 = 0.32;

/// Which tier the mood dances: 0 low, 1 mid, 2 high.
pub fn tier(mood: Mood, wake_k: f64, energy: f64, dice: f64) -> usize {
    match mood {
        Mood::Sleep => 0,
        Mood::Rage => 2,
        Mood::Wake => {
            if wake_k > 0.66 {
                2
            } else if wake_k > 0.2 || dice < 0.5 {
                1
            } else {
                0
            }
        }
        Mood::Vibe => {
            if energy > 0.75 && dice < 0.35 {
                2
            } else if energy < 0.35 && dice < 0.4 {
                0
            } else {
                1
            }
        }
    }
}

/// A record to dance to as to techno: four to the floor at a club's tempo, few words.
pub fn techno(bpm: f64, vocal: f64) -> bool {
    (118.0..=160.0).contains(&bpm) && vocal < 0.4
}

/// How much a record leans on each style (by [STYLES]' order).
pub fn flavour(salt: i64, bpm: f64, mood: Mood, hook: bool, techno: bool) -> [f64; 7] {
    let calm = if mood == Mood::Sleep { 1.6 } else { 0.04 };
    // groove party toon swing latin folk calm
    if techno {
        return [3.0, if hook { 0.1 } else { 0.02 }, 0.04, 0.08, 0.25, 0.2, calm];
    }
    let mut w = [1.2, if hook { 0.25 } else { 0.02 }, 0.04, 0.25, 0.45, 0.4, calm];
    // latin folk swing groove
    let leaning = [4usize, 5, 3, 0];
    let a = leaning[((meme_hash(s9973(salt), 11.0, 5.0) * 4.0).floor() as usize) % 4];
    let b = leaning[((meme_hash(s9973(salt), 13.0, 7.0) * 4.0).floor() as usize) % 4];
    w[a] *= 4.0;
    w[b] *= 1.6;
    if (112.0..=136.0).contains(&bpm) {
        w[3] *= 1.5;
    }
    if bpm < 110.0 {
        w[4] *= 1.5;
    }
    if bpm > 150.0 {
        w[5] *= 1.4;
    }
    w
}

/// The moves of `bank` (indices into `moves`) worth dancing next, best first with their
/// weights: the tier's, by the record's flavour, by tempo, the recent ones held back. `duo`:
/// the duets' lead halves alone.
#[allow(clippy::too_many_arguments)]
pub fn pool(moves: &[Move], bank: &[usize], tier: usize, flavour: &[f64; 7], bpm: f64, recent: &[String], techno: bool, duo: bool) -> Vec<(usize, f64)> {
    let mut out = vec![];
    for &i in bank {
        let m = &moves[i];
        if if duo { m.duo.is_none() || m.part != 0 } else { m.duo.is_some() } {
            continue;
        }
        let d = m.tier_ix().abs_diff(tier);
        let fit = tempo_fit(bpm, m, if techno && m.pulse >= Rig::MIN_PULSE_SHIFT { TECHNO_STRETCH } else { 0.16 });
        // an unknown style reads as a groove, as v1 reads it
        let style = flavour[crate::style_ix(&m.style)];
        let mut w = (match d {
            0 => 1.0,
            1 => 0.12,
            _ => 0.015,
        }) * style
            * if techno { (0.1 + fit) * (0.15 + 3.0 * m.pulse * m.pulse) } else { 0.2 + fit };
        if let Some(r) = recent.iter().position(|id| *id == m.id) {
            w *= if r == recent.len() - 1 { 0.0 } else { 0.15 };
        }
        if w > 0.0 {
            out.push((i, w));
        }
    }
    out.sort_by(|a, b| b.1.total_cmp(&a.1));
    out
}

/// One of `pool` by its weights, by the dice `d`.
pub fn draw(pool: &[(usize, f64)], d: f64) -> Option<usize> {
    if pool.is_empty() {
        return None;
    }
    let total: f64 = pool.iter().map(|e| e.1).sum();
    let mut x = d * total;
    for &(m, w) in pool {
        x -= w;
        if x <= 0.0 {
            return Some(m);
        }
    }
    pool.last().map(|e| e.0)
}

/// The beats of a move a dancer may step into it on: the bar's halves.
pub fn entries(m: &Move) -> Vec<usize> {
    (0..m.beats).step_by(2).collect()
}

pub fn is_big(t: Troupe) -> bool {
    matches!(t, Troupe::Grid | Troupe::Ring | Troupe::Army)
}

pub fn is_paired(t: Troupe) -> bool {
    matches!(t, Troupe::Couple | Troupe::Couples)
}

/// Who dances slot `slot` in `mood`; `big` where the big sets may.
pub fn troupe(mood: Mood, salt: i64, slot: i64, heat: f64, big: bool) -> Troupe {
    use Troupe::*;
    let d = meme_hash(s9973(salt), slot as f64, 23.0);
    let by = |odds: &[(f64, Troupe)]| odds.iter().find(|o| d < o.0).unwrap_or(odds.last().unwrap()).1;
    if big {
        return match mood {
            Mood::Sleep => by(&[(0.55, Solo), (0.8, Duo), (1.0, Ring)]),
            Mood::Wake => by(&[(0.3, Solo), (0.5, Duo), (0.7, Trio), (0.85, Army), (1.0, Ring)]),
            Mood::Rage if heat < 0.7 => by(&[(0.25, Trio), (0.45, Line), (0.75, Army), (1.0, Grid)]),
            Mood::Rage => by(&[(0.35, Grid), (0.6, Army), (0.75, Crowd), (0.9, Ring), (1.0, Line)]),
            Mood::Vibe => by(&[(0.2, Solo), (0.35, Duo), (0.5, Trio), (0.65, Ring), (0.82, Army), (1.0, Grid)]),
        };
    }
    match mood {
        Mood::Sleep => by(&[(0.75, Solo), (1.0, Duo)]),
        Mood::Wake => by(&[(0.45, Solo), (0.75, Duo), (1.0, Trio)]),
        Mood::Rage if heat < 0.7 => by(&[(0.2, Solo), (0.5, Duo), (0.8, Trio), (1.0, Line)]),
        Mood::Rage => by(&[(0.1, Solo), (0.3, Trio), (0.6, Line), (1.0, Crowd)]),
        Mood::Vibe => by(&[(0.3, Solo), (0.6, Duo), (0.85, Trio), (1.0, Line)]),
    }
}

/// The company as couples now and then (likelier on a latin record), never asleep.
pub fn paired(t: Troupe, mood: Mood, flavour: &[f64; 7], salt: i64, slot: i64) -> Troupe {
    if mood == Mood::Sleep {
        return t;
    }
    let total: f64 = flavour.iter().sum();
    let latin = if total > 0.0 { flavour[4] / total } else { 0.0 };
    let d = meme_hash(s9973(salt), slot as f64, 59.0);
    match t {
        Troupe::Duo if d < 0.2 + latin => Troupe::Couple,
        Troupe::Trio | Troupe::Line | Troupe::Crowd if d < 0.08 + 0.5 * latin => Troupe::Couples,
        Troupe::Army | Troupe::Grid if d < 0.06 + 0.25 * latin => Troupe::Couples,
        _ => t,
    }
}

/// The company's routine for slot `slot`.
pub fn routine(t: Troupe, salt: i64, slot: i64) -> Routine {
    use Routine::*;
    let d = meme_hash(s9973(salt), slot as f64, 67.0);
    let pick: &[Routine] = match t {
        Troupe::Solo | Troupe::Couple => &[Unison],
        Troupe::Duo => &[Unison, Unison, Unison, Canon, Split],
        Troupe::Couples => &[Unison, Unison, Canon, Answer, Unison],
        Troupe::Trio => &[Unison, Unison, Unison, Canon, Split, Answer],
        Troupe::Line => &[Unison, Wave, Unison, Unison, Canon, Split, Answer],
        Troupe::Crowd => &[Unison, Unison, Split, Wave, Unison, Answer],
        Troupe::Grid | Troupe::Army | Troupe::Ring => &[Unison, Unison, Wave, Unison, Split, Answer, Unison],
    };
    pick[((d * pick.len() as f64).floor() as usize) % pick.len()]
}

/// Which of a small set's formations slot `slot` stands in (0 the one it walked in as).
pub fn formation(t: Troupe, salt: i64, slot: i64) -> usize {
    let count = match t {
        Troupe::Duo => 3,
        Troupe::Trio | Troupe::Line | Troupe::Couples => 4,
        _ => 1,
    };
    if count == 1 {
        return 0;
    }
    // Dart's ~/ truncates toward naught, as Rust's / does
    let d = meme_hash(s9973(salt), (slot / 2) as f64, 71.0);
    if d < 0.45 { 0 } else { 1 + (((d - 0.45) / 0.55 * (count - 1) as f64).floor() as usize).min(count - 2) }
}

fn extreme_odds(mood: Mood) -> f64 {
    match mood {
        Mood::Rage => 0.55,
        Mood::Wake => 0.4,
        Mood::Vibe => 0.35,
        Mood::Sleep => 0.0,
    }
}

const EXTREMES: [Shot; 6] = [Shot::ExtremeLow, Shot::Fisheye, Shot::ExtremeFront, Shot::FisheyeLow, Shot::ExtremeHigh, Shot::Fisheye];

/// The framings the mood and the troupe allow, as often as each comes.
fn candidates(mood: Mood, troupe: Troupe) -> &'static [Shot] {
    use Shot::*;
    if matches!(troupe, Troupe::Line | Troupe::Crowd | Troupe::Couples) {
        return &[Wide, Wide, Wide, Full];
    }
    if is_big(troupe) {
        return &[Front, Front, Front, Full, Full];
    }
    match mood {
        Mood::Sleep => &[Full, Front],
        Mood::Wake => &[Front, Medium],
        Mood::Rage => &[Full, Front, Medium, Close],
        Mood::Vibe => &[Full, Front, Full, Medium, Close],
    }
}

/// The camera for cut `cut` in `mood`; `art`: the stylised stage (its extreme angles);
/// `weight` leans each framing (the hands' rules).
pub fn shot(mood: Mood, salt: i64, cut: i64, troupe: Troupe, art: bool, weight: Option<&dyn Fn(Shot) -> f64>) -> Shot {
    let d = meme_hash(s9973(salt), cut as f64, 41.0);
    let w = |s: Shot| weight.map_or(1.0, |f| f(if art && s == Shot::Full { Shot::Front } else { s }));
    if art {
        let e = meme_hash(s9973(salt), cut as f64, 43.0);
        if e < extreme_odds(mood)
            && let Some(x) = pick_by_weight(&EXTREMES.map(|s| (s, w(s))), d)
        {
            return x;
        }
    }
    let c: Vec<(Shot, f64)> = candidates(mood, troupe).iter().map(|&s| (s, w(s))).collect();
    pick_by_weight(&c, d)
        .or_else(|| pick_by_weight(&[Shot::Front, Shot::Medium, Shot::Wide, Shot::Close].map(|s| (s, w(s))), d))
        .unwrap_or(Shot::Front)
}

/// The stylised stage's rendering for its `n`th section in `mood`: never `not` again; the
/// image treatments are the conductor's (the frame's rig), so this picks the stage's own.
pub fn art(mood: Mood, salt: i64, n: i64, not: Option<Art>) -> Art {
    use Art::*;
    let list: &[Art] = match mood {
        Mood::Sleep => &[Mono, Ascii, Dither, Contour, Lines, Fluid, Plain],
        Mood::Wake => &[Ascii, Dither, Trails, Mono, Halftone, Thermal, Lines, Viewports, Plain, Disco],
        Mood::Rage => &[Trails, Chrono, Mono, Thermal, Halftone, Fluid, Viewports, Plain, Disco],
        Mood::Vibe => Art::ALL,
    };
    let pool: Vec<Art> = list.iter().copied().filter(|a| a.fx_mode().is_none() && *a != Slit && a.drawn()).collect();
    if pool.is_empty() {
        return not.unwrap_or(Plain);
    }
    let d = meme_hash(s9973(salt), n as f64, 97.0);
    let mut a = pick_by_weight(&pool.iter().map(|&a| (a, 1.0)).collect::<Vec<_>>(), d).unwrap_or(pool[((d * pool.len() as f64).floor() as usize) % pool.len()]);
    if Some(a) == not && pool.len() > 1 {
        a = pool[(pool.iter().position(|x| *x == a).unwrap() + 1) % pool.len()];
    }
    a
}

/// How many beats a camera holds.
pub fn hold(mood: Mood) -> i64 {
    match mood {
        Mood::Rage => 8,
        Mood::Sleep => 32,
        _ => 16,
    }
}

/// How many beats a figure's camera holds a framing, shortened by the camera's `drive`.
pub fn cut_hold(hold: i64, drive: f64) -> i64 {
    if drive > 0.75 {
        hold.min(4)
    } else if drive > 0.4 {
        hold.min(8)
    } else {
        hold
    }
}

impl std::ops::Add for V3 {
    type Output = V3;
    fn add(self, o: V3) -> V3 {
        V3::new(self.x + o.x, self.y + o.y, self.z + o.z)
    }
}

impl std::ops::Sub for V3 {
    type Output = V3;
    fn sub(self, o: V3) -> V3 {
        V3::new(self.x - o.x, self.y - o.y, self.z - o.z)
    }
}

impl std::ops::Mul<f64> for V3 {
    type Output = V3;
    fn mul(self, k: f64) -> V3 {
        V3::new(self.x * k, self.y * k, self.z * k)
    }
}

/// A point, metres.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct V3 {
    pub x: f64,
    pub y: f64,
    pub z: f64,
}

impl V3 {
    pub const fn new(x: f64, y: f64, z: f64) -> V3 {
        V3 { x, y, z }
    }
    pub fn dot(self, o: V3) -> f64 {
        self.x * o.x + self.y * o.y + self.z * o.z
    }
    pub fn cross(self, o: V3) -> V3 {
        V3::new(self.y * o.z - self.z * o.y, self.z * o.x - self.x * o.z, self.x * o.y - self.y * o.x)
    }
    pub fn length(self) -> f64 {
        self.dot(self).sqrt()
    }
    pub fn unit(self) -> V3 {
        let l = self.length();
        if l < 1e-9 { V3::new(0.0, 0.0, 1.0) } else { self * (1.0 / l) }
    }
}

/// A camera: where it is, what it looks at, how wide, on a `w`×`h` picture (v1's DanceCam).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Cam {
    pub eye: V3,
    pub target: V3,
    pub w: f64,
    pub h: f64,
    /// The vertical field of view, radians; the horizon's tip.
    pub fov: f64,
    pub roll: f64,
    /// The picture's centre off the middle, a share of its size.
    pub shift: (f64, f64),
    /// How much of a fisheye the lens is, 0..1.
    pub fisheye: f64,
    pub f: V3,
    pub right: V3,
    pub up: V3,
    pub focal: f64,
    pub cx: f64,
    pub cy: f64,
}

impl Cam {
    pub const NEAR: f64 = 0.05;

    pub fn new(eye: V3, target: V3, w: f64, h: f64, fov: f64, roll: f64) -> Cam {
        Cam::with(eye, target, w, h, fov, roll, (0.0, 0.0), 0.0)
    }

    #[allow(clippy::too_many_arguments)]
    pub fn with(eye: V3, target: V3, w: f64, h: f64, fov: f64, roll: f64, shift: (f64, f64), fisheye: f64) -> Cam {
        let f = (target - eye).unit();
        let mut r = f.cross(V3::new(0.0, 0.0, 1.0));
        if r.length() < 1e-6 {
            r = V3::new(1.0, 0.0, 0.0);
        }
        r = r.unit();
        let mut u = r.cross(f);
        if roll != 0.0 {
            let (c, s) = (roll.cos(), roll.sin());
            let (r2, u2) = (r * c + u * s, u * c - r * s);
            r = r2;
            u = u2;
        }
        let focal = if fisheye > 0.5 { h / fov } else { h / 2.0 / (fov / 2.0).tan() };
        Cam { eye, target, w, h, fov, roll, shift, fisheye, f, right: r, up: u, focal, cx: w / 2.0 + shift.0 * w, cy: h / 2.0 + shift.1 * h }
    }

    /// The screen point of `p` and its depth; depth under NEAR is behind the camera.
    pub fn project(&self, p: V3) -> (f64, f64, f64) {
        let d = p - self.eye;
        let z = d.dot(self.f);
        let (x, y) = (d.dot(self.right), d.dot(self.up));
        if self.fisheye > 0.0 {
            let rho = (x * x + y * y).sqrt();
            let theta = rho.atan2(z);
            let r = self.focal * ((1.0 - self.fisheye) * theta.min(1.3).tan() + self.fisheye * theta);
            let k = if rho < 1e-9 { 0.0 } else { r / rho };
            return (self.cx + k * x, self.cy - k * y, if z > Self::NEAR { (rho * rho + z * z).sqrt() } else { Self::NEAR * 0.5 });
        }
        let iz = 1.0 / z.max(Self::NEAR);
        (self.cx + self.focal * x * iz, self.cy - self.focal * y * iz, z)
    }
}

/// Where a dancer stands: on the floor at (x, y), turned by `yaw`, maybe mirrored, scaled,
/// lifted (v1's DanceSpot).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Spot {
    pub x: f64,
    pub y: f64,
    pub yaw: f64,
    pub mirror: bool,
    pub scale: f64,
    pub lift: f64,
}

impl Default for Spot {
    fn default() -> Self {
        Spot { x: 0.0, y: 0.0, yaw: 0.0, mirror: false, scale: 1.0, lift: 0.0 }
    }
}

impl Spot {
    pub const fn at(x: f64, y: f64, mirror: bool) -> Spot {
        Spot { x, y, yaw: 0.0, mirror, scale: 1.0, lift: 0.0 }
    }
}

/// What a sweep does to a shot this frame (stage_camera.dart SweepMove).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SweepMove {
    pub yaw: f64,
    pub dist: f64,
    pub rise: f64,
    pub roll: f64,
}

pub const NO_SWEEP: SweepMove = SweepMove { yaw: 0.0, dist: 1.0, rise: 0.0, roll: 0.0 };

/// A camera placed: round the dancer by `yaw`, at `height`, `dist` away, looking at `aim`
/// high, `fov` wide, tipped by `roll`, looking `ahead` behind the lead (v1's DanceFrame).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Frame {
    pub yaw: f64,
    pub height: f64,
    pub dist: f64,
    pub aim: f64,
    pub fov: f64,
    pub roll: f64,
    pub ahead: f64,
}

/// The straight lens a fisheye shot is drawn through (120°), and the fisheye's angle at the
/// picture's top edge.
pub const FISHEYE_FOV: f64 = 2.094;
pub const FISHEYE_EDGE: f64 = 1.25;

pub fn is_fisheye(s: Shot) -> bool {
    matches!(s, Shot::Fisheye | Shot::FisheyeLow)
}

impl Frame {
    const fn new(yaw: f64, height: f64, dist: f64, aim: f64, fov: f64, roll: f64, ahead: f64) -> Frame {
        Frame { yaw, height, dist, aim, fov, roll, ahead }
    }

    pub fn of(s: Shot, t: Troupe) -> Frame {
        match s {
            Shot::ExtremeLow => return Frame::new(0.16, 0.12, 0.72, 1.35, 1.95, 0.07, 0.0),
            Shot::ExtremeHigh => return Frame::new(-0.14, 1.95, 0.62, 1.2, 1.92, -0.05, 0.0),
            Shot::ExtremeFront => return Frame::new(0.0, 1.3, 0.58, 1.15, 1.95, 0.0, 0.0),
            Shot::Fisheye => return Frame::new(0.06, 1.25, 0.72, 1.05, FISHEYE_FOV, 0.1, 0.0),
            Shot::FisheyeLow => return Frame::new(0.14, 0.18, 0.66, 1.25, FISHEYE_FOV, 0.06, 0.0),
            _ => {}
        }
        if is_big(t) {
            let ahead = match t {
                Troupe::Grid => 3.2,
                Troupe::Army => 2.6,
                _ => 0.6,
            };
            return if s == Shot::Full { Frame::new(0.2, 7.0, 10.5, 0.3, 0.6, 0.0, ahead) } else { Frame::new(0.0, 6.2, 10.0, 0.4, 0.6, 0.0, ahead) };
        }
        let wide = match t {
            Troupe::Solo => 1.0,
            Troupe::Duo | Troupe::Trio | Troupe::Couple => 1.3,
            _ => 1.6,
        };
        match s {
            Shot::Full => Frame::new(0.3, 1.3, 4.4 * wide, 0.95, 0.62, 0.0, 0.0),
            Shot::Front => Frame::new(0.0, 1.2, 4.1 * wide, 0.95, 0.62, 0.0, 0.0),
            Shot::Medium => Frame::new(0.15, 1.3, 3.3, 1.02, 0.6, 0.0, 0.0),
            Shot::Close => Frame::new(0.1, 1.45, 2.5, 1.2, 0.6, 0.0, 0.0),
            _ => Frame::new(0.1, 1.6, 4.6 * wide, 0.85, 0.62, 0.0, 0.0),
        }
    }

    pub fn lerp(a: &Frame, b: &Frame, t: f64) -> Frame {
        let l = |x: f64, y: f64| x + (y - x) * t;
        Frame::new(l(a.yaw, b.yaw), l(a.height, b.height), l(a.dist, b.dist), l(a.aim, b.aim), l(a.fov, b.fov), l(a.roll, b.roll), l(a.ahead, b.ahead))
    }

    /// Where a sweep has taken this framing: never below the floor.
    pub fn swept(&self, s: SweepMove) -> Frame {
        if s == NO_SWEEP {
            return *self;
        }
        Frame::new(self.yaw + s.yaw, (self.height + s.rise * self.dist).max(0.08), self.dist * s.dist, self.aim, self.fov, self.roll + s.roll, self.ahead)
    }

    pub fn turned(&self, by: f64, closer: f64, roll: f64) -> Frame {
        Frame::new(self.yaw + by, self.height, self.dist * closer, self.aim, self.fov, self.roll + roll, self.ahead)
    }

    pub fn cam(&self, w: f64, h: f64, shake: f64) -> Cam {
        let eye = V3::new(self.yaw.sin() * self.dist, self.ahead - self.yaw.cos() * self.dist, self.height);
        Cam::new(eye, V3::new(0.0, self.ahead, self.aim + shake * 0.01), w, h, self.fov, self.roll)
    }
}

/// The dancers to pick from (`assets/show/dance/<id>/`).
pub const MODELS: &[&str] = &["chris", "joe"];
pub const MIX: &str = "mix";

/// Who may dance in a mix: all but those switched `off` (all off is none off).
pub fn models_on(off: &[String]) -> Vec<&'static str> {
    let on: Vec<&str> = MODELS.iter().copied().filter(|m| !off.iter().any(|o| o == m)).collect();
    if on.is_empty() { MODELS.to_vec() } else { on }
}

/// The lead for record `salt` when the panel says `choice`.
pub fn lead(choice: Option<&str>, salt: i64, off: &[String]) -> &'static str {
    if let Some(c) = choice
        && let Some(m) = MODELS.iter().find(|m| **m == c)
    {
        return m;
    }
    let p = models_on(off);
    p[((meme_hash(s9973(salt), 17.0, 29.0) * p.len() as f64).floor() as usize) % p.len()]
}

/// Member `i`'s model: the lead's, or in a mix one of the others on.
pub fn member(choice: Option<&str>, salt: i64, i: usize, off: &[String]) -> &'static str {
    if choice.is_some_and(|c| c != MIX) {
        return lead(choice, salt, off);
    }
    let first = lead(choice, salt, off);
    let others: Vec<&str> = models_on(off).into_iter().filter(|m| *m != first).collect();
    if others.is_empty() {
        return first;
    }
    others[((meme_hash(s9973(salt), 31.0 + i as f64, 37.0) * others.len() as f64).floor() as usize) % others.len()]
}

/// The ways a shot travels.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SweepKind {
    Arc,
    Push,
    Pull,
    Crane,
    Spiral,
    Fly,
}

/// The camera on the move through a shot, in a loud part (stage_camera.dart CameraSweep).
#[derive(Clone, Debug)]
pub struct Sweep {
    pub kind: Option<SweepKind>,
    at: f64,
    hold: f64,
    side: f64,
    amount: f64,
    k: f64,
    close: bool,
    whip: bool,
}

impl Default for Sweep {
    fn default() -> Self {
        Sweep { kind: None, at: 0.0, hold: 16.0, side: 1.0, amount: 0.0, k: 0.0, close: false, whip: false }
    }
}

impl Sweep {
    /// Whether the camera is moving at all.
    pub fn moving(&self) -> bool {
        self.kind.is_some() && self.amount * self.k > 0.01
    }

    /// A new shot at `beats`, held about `hold` beats: its travel by the dice `d`, as far as
    /// the `drive` then. `close`: up at the figure already; `over`: over a crowd; `drop`: the
    /// drop's own cut.
    #[allow(clippy::too_many_arguments)]
    pub fn cut(&mut self, beats: f64, hold: i64, drive: f64, d: f64, close: bool, over: bool, drop: bool) {
        self.at = beats;
        self.hold = hold.max(2) as f64;
        self.close = close;
        self.whip = drop;
        self.side = if ((d * 7919.0).floor() as i64) % 2 == 0 { 1.0 } else { -1.0 };
        self.amount = if drive < 0.12 { 0.0 } else { drive.powf(0.8) };
        if self.amount == 0.0 {
            self.kind = None;
            return;
        }
        let w = [
            (SweepKind::Arc, 1.0),
            (SweepKind::Push, if close { 0.0 } else { 1.0 }),
            (SweepKind::Pull, 0.7),
            (SweepKind::Crane, 0.8),
            (SweepKind::Spiral, if drive > 0.6 { 1.2 } else { 0.2 }),
            (SweepKind::Fly, if over && !close { 0.6 + drive } else { 0.0 }),
        ];
        let mut at = d * w.iter().map(|x| x.1).sum::<f64>();
        self.kind = Some(SweepKind::Fly);
        for (k, x) in w {
            if at < x {
                self.kind = Some(k);
                break;
            }
            at -= x;
        }
        self.k = (drive * 1.2).min(1.0);
    }

    /// Where the shot has travelled at `beats`.
    pub fn at(&mut self, beats: f64, drive: f64, dt: f64) -> SweepMove {
        let Some(kind) = self.kind else { return NO_SWEEP };
        self.k += ((drive * 1.2).min(1.0) - self.k) * (dt * 1.5).min(1.0);
        let a = self.amount * self.k * (self.hold / 8.0).min(1.0).sqrt();
        let s = self.side;
        let p = ((beats - self.at) / self.hold).clamp(0.0, 1.0);
        let e = 0.5 * p + 0.5 * p * p * (3.0 - 2.0 * p);
        let c = 2.0 * e - 1.0;
        let pi = std::f64::consts::PI;
        let (mut yaw, mut dist, mut rise, mut roll) = (0.0, 1.0, 0.0, 0.0);
        let _ = yaw;
        match kind {
            SweepKind::Arc => {
                yaw = s * 0.5 * a * c;
                dist = 1.0 - 0.08 * a * (pi * e).sin();
            }
            SweepKind::Push => {
                dist = 1.0 + a * (0.3 - 0.55 * e);
                rise = -0.05 * a * e;
                yaw = s * 0.08 * a * c;
            }
            SweepKind::Pull => {
                dist = 1.0 + a * (-0.15 + 0.5 * e);
                rise = 0.16 * a * e;
                yaw = s * 0.12 * a * e;
            }
            SweepKind::Crane => {
                rise = a * if s > 0.0 { -0.1 + 0.34 * e } else { 0.24 - 0.34 * e };
                yaw = s * 0.15 * a * c;
            }
            SweepKind::Spiral => {
                yaw = s * 0.95 * a * c;
                dist = 1.0 + a * (0.25 - 0.45 * e);
                roll = s * 0.05 * a * c;
            }
            SweepKind::Fly => {
                dist = 1.0 - 0.55 * a * e;
                rise = -0.3 * a * e;
                yaw = s * 0.2 * a * c;
            }
        }
        if self.whip {
            yaw += s * 0.8 * a * (-(beats - self.at).clamp(0.0, 99.0) * 1.6).exp();
        }
        if self.close {
            dist = dist.max(1.0);
        }
        SweepMove { yaw, dist, rise, roll }
    }
}

/// The camera's hand on a 3D figure's finished picture (v1: stage_camera.dart StageCamera):
/// only as much as the record is intense — on the drop a punch and a shake settling over a few
/// beats, through a build a slow push in; the picture scaled to cover what the shake and the
/// tilt would bare. (v1 reads the kick and the snare by the names `kick` and `snare`, which
/// nothing in the show's state sets: they are naught there, so here too — the punch on the kick
/// and the snare's tick of the horizon do not move v1's picture either.)
#[derive(Clone, Debug, Default)]
pub struct PictureCam {
    drop_at: Option<f64>,
    away_was: Option<f64>,
    push: f64,
}

/// A move of the finished picture: a scale about the middle, a shift (a share of the picture's
/// size), a roll (radians).
pub const STILL: [f32; 4] = [1.0, 0.0, 0.0, 0.0];

impl PictureCam {
    /// This frame's move for `st`, `dt` seconds on: still for a figure that is not a camera's.
    pub fn frame(&mut self, st: &wo_show::state::ShowState, dt: f64) -> [f32; 4] {
        use wo_show::rig::Figure;
        if !matches!(st.rig.figure.kind, Figure::Dancers | Figure::Birds | Figure::Turntable | Figure::Type3d) {
            self.drop_at = None;
            self.push = 0.0;
            return STILL;
        }
        let m = st.master();
        let Some(beat_index) = m.beat_index.filter(|_| m.playing) else { return STILL };
        let beats = beat_index as f64 + m.beat_phase;
        let drive = wo_show::director::drive(m);
        let kick = st.num("kick").clamp(0.0, 1.0);
        let snare = st.num("snare").clamp(0.0, 1.0);
        // the drop: when it lands, remembered a few beats
        let away = m.drop_beats_away;
        if let Some(a) = away
            && a <= 0.0
            && a > -2.5
            && self.away_was.is_none_or(|w| w > 0.0)
        {
            self.drop_at = Some(beats + a);
        }
        self.away_was = away;
        if self.drop_at.is_some_and(|d| beats - d > 12.0 || beats < d - 1.0) {
            self.drop_at = None;
        }
        let burst = self.drop_at.map_or(0.0, |d| (-(beats - d) / 2.2).exp());
        // a build: in slowly as it climbs; let go of at once on the drop
        let building = !m.breakdown && (m.section.as_deref() == Some("build") || away.is_some_and(|a| a > 0.0 && a < 32.0));
        let want = if building { m.build_k.clamp(0.0, 1.0) } else { 0.0 };
        self.push = if burst > 0.5 { 0.0 } else { self.push + (want - self.push) * (dt * if want > self.push { 0.8 } else { 3.0 }).min(1.0) };
        // the shake: two drifting sines a few times a beat, settling with the burst
        let s = beats * std::f64::consts::TAU;
        let shake = burst * 0.012;
        let dx = shake * ((s * 1.7).sin() + 0.6 * (s * 4.3 + 1.1).sin());
        let dy = shake * ((s * 2.1).cos() + 0.5 * (s * 3.7 + 2.3).sin());
        let side = if beat_index % 2 == 0 { 1.0 } else { -1.0 };
        let roll = 0.014 * snare * drive * side + 0.02 * burst * (s * 1.3).sin();
        let zoom = 1.0 + 0.045 * kick * drive + 0.1 * burst + 0.07 * self.push;
        let cover = 1.0 + 1.9 * roll.abs() + 2.2 * dx.abs().max(dy.abs());
        [(zoom * cover) as f32, dx as f32, dy as f32, roll as f32]
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn mv(id: &str, tier: &str, bpm: f64) -> Move {
        serde_json::from_value(serde_json::json!({"id": id, "tier": tier, "style": "groove", "energy": 1.0, "bpm": bpm, "beats": 8, "offset": 0})).unwrap()
    }

    #[test]
    fn on_the_beat_and_at_the_right_rate() {
        assert!((4.0 + since_beat(123.4, 1.0) - 4.4).abs() < 1e-9);
        assert!((since_beat(123.4, 0.5) * 0.5 - 0.7).abs() < 1e-9);
        assert!((since_beat(123.4, 2.0) - 0.4).abs() < 1e-9);
        assert_eq!(rate(186.0, 93.0, false), 0.5);
        assert_eq!(rate(128.0, 93.0, false), 1.0);
        assert_eq!(rate(60.0, 129.0, false), 2.0);
        assert_eq!(rate(128.0, 129.0, true), 0.5);
        let m = mv("a", "mid", 124.0);
        assert!((tempo_fit(124.0, &m, 0.16) - 1.0).abs() < 1e-9);
        assert!((tempo_fit(62.0, &m, 0.16) - 1.0).abs() < 1e-9);
        assert!(tempo_fit(140.0, &m, 0.16) < tempo_fit(128.0, &m, 0.16));
    }

    #[test]
    fn the_drop_dances_big_sleep_calm() {
        assert_eq!(tier(Mood::Rage, 0.0, 0.5, 0.0), 2);
        assert_eq!(tier(Mood::Sleep, 0.0, 0.5, 0.0), 0);
        assert_eq!(tier(Mood::Wake, 0.9, 0.5, 0.0), 2);
        assert_eq!(tier(Mood::Wake, 0.4, 0.5, 0.0), 1);
        assert!(flavour(1, 120.0, Mood::Sleep, false, false)[6] > flavour(1, 120.0, Mood::Vibe, false, false)[6] * 10.0);
        let fl = flavour(7, 128.0, Mood::Vibe, false, true);
        assert!(fl[0] > fl[1] * 50.0);
        assert!(techno(128.0, 0.1) && !techno(95.0, 0.1));
    }

    #[test]
    fn the_pool_tier_first_the_last_move_out() {
        let moves: Vec<Move> = (0..4).map(|i| mv(&format!("h{i}"), "high", 120.0)).chain([mv("l0", "low", 120.0), mv("m0", "mid", 120.0)]).collect();
        let bank: Vec<usize> = (0..moves.len()).collect();
        let fl = flavour(4242, 124.0, Mood::Rage, false, false);
        let p = pool(&moves, &bank, 2, &fl, 124.0, &["h1".into()], false, false);
        assert_eq!(moves[p[0].0].tier, "high");
        assert!(!p.iter().any(|e| moves[e.0].id == "h1"));
        assert_eq!(draw(&p, 0.37), draw(&p, 0.37));
        assert!(!pool(&moves, &[4], 2, &fl, 124.0, &[], false, false).is_empty(), "a tier the bank lacks falls back");
        let m = mv("x", "mid", 120.0);
        assert_eq!(entries(&m), vec![0, 2, 4, 6]);
    }

    #[test]
    fn couples_routines_formations_the_same_for_the_same_slot() {
        let mut latin = flavour(3, 100.0, Mood::Vibe, false, false);
        latin[4] = 6.0;
        let n = (0..200).filter(|&n| paired(Troupe::Duo, Mood::Vibe, &latin, 3, n) == Troupe::Couple).count();
        assert!(n > 60, "{n}");
        assert!((0..50).all(|n| paired(Troupe::Duo, Mood::Sleep, &latin, 3, n) == Troupe::Duo));
        assert_eq!(paired(Troupe::Solo, Mood::Rage, &latin, 3, 1), Troupe::Solo);
        let rs: std::collections::HashSet<Routine> = (0..100).map(|n| routine(Troupe::Line, 3, n)).collect();
        assert_eq!(rs.len(), Routine::ALL.len());
        assert!((0..50).all(|n| routine(Troupe::Couple, 3, n) == Routine::Unison));
        let fs: std::collections::HashSet<usize> = (0..100).map(|n| formation(Troupe::Line, 3, n)).collect();
        assert!(fs.len() > 2);
        assert_eq!(formation(Troupe::Line, 3, 10), formation(Troupe::Line, 3, 11));
        assert_eq!(formation(Troupe::Grid, 3, 10), 0);
    }

    #[test]
    fn troupe_and_camera_one_for_the_mood() {
        let quiet: std::collections::HashSet<Troupe> = (0..40).map(|n| troupe(Mood::Sleep, 9, n, 1.0, false)).collect();
        assert!(quiet.iter().all(|t| matches!(t, Troupe::Solo | Troupe::Duo)));
        assert!((0..200).filter(|&n| troupe(Mood::Rage, 9, n, 1.0, false) != Troupe::Solo).count() > 160);
        for s in Shot::ALL {
            assert!(Frame::of(*s, Troupe::Solo).yaw.abs() < 0.35);
        }
        assert!(hold(Mood::Sleep) > hold(Mood::Rage));
        let ex = |s: &Shot| matches!(s, Shot::ExtremeLow | Shot::ExtremeHigh | Shot::ExtremeFront | Shot::Fisheye | Shot::FisheyeLow);
        let drop = (0..200).map(|n| shot(Mood::Rage, 9, n, Troupe::Solo, true, None)).filter(ex).count();
        assert!((50..=130).contains(&drop), "{drop}");
        assert_eq!((0..100).map(|n| shot(Mood::Sleep, 9, n, Troupe::Solo, true, None)).filter(ex).count(), 0);
        assert_eq!((0..100).map(|n| shot(Mood::Rage, 9, n, Troupe::Solo, false, None)).filter(ex).count(), 0);
        let none = |_: Shot| 0.0;
        assert!((0..50).all(|n| shot(Mood::Rage, 9, n, Troupe::Solo, true, Some(&none)) == Shot::Front));
        let close = |s: Shot| if s == Shot::Close { 10.0 } else { 1.0 };
        assert!((0..200).filter(|&n| shot(Mood::Vibe, 9, n, Troupe::Solo, false, Some(&close)) == Shot::Close).count() > 100);
        for e in [Shot::ExtremeLow, Shot::ExtremeHigh, Shot::ExtremeFront, Shot::Fisheye, Shot::FisheyeLow] {
            let f = Frame::of(e, Troupe::Grid);
            assert!(f.fov > 1.8 && f.dist < 1.0);
        }
        for n in 0..30 {
            let a = art(Mood::Vibe, 5, n, None);
            assert_ne!(art(Mood::Vibe, 5, n + 1, Some(a)), a);
            assert!(a.drawn() && a.fx_mode().is_none());
        }
        assert!((0..60).any(|n| art(Mood::Rage, 5, n, None) == Art::Disco));
    }

    #[test]
    fn dancers_switched_off_never_in_a_mix() {
        let off = vec!["chris".to_owned()];
        for salt in 0..400 {
            assert_eq!(lead(Some(MIX), salt, &off), "joe");
            for i in 0..6 {
                assert_eq!(member(Some(MIX), salt, i, &off), "joe");
            }
            let l = lead(Some(MIX), salt, &[]);
            assert_ne!(member(Some(MIX), salt, 0, &[]), l);
        }
        assert_eq!(lead(Some("chris"), 7, &off), "chris");
        assert_eq!(models_on(&MODELS.iter().map(|s| s.to_string()).collect::<Vec<_>>()), MODELS.to_vec());
    }

    #[test]
    fn the_picture_punches_in_on_the_drop_and_settles() {
        let mut c = PictureCam::default();
        let mut st = wo_show::state::ShowState::default();
        st.rig.figure.kind = wo_show::rig::Figure::Dancers;
        st.a.playing = true;
        st.a.section = Some("drop".into());
        st.a.energy = 1.0;
        let at = |c: &mut PictureCam, st: &mut wo_show::state::ShowState, beat: f64, away: f64| {
            st.a.beat_index = Some(beat.floor() as i64);
            st.a.beat_phase = beat.fract();
            st.a.drop_beats_away = Some(away);
            c.frame(st, 1.0 / 60.0)
        };
        assert_eq!(at(&mut c, &mut st, 10.0, 2.0), STILL.map(|v| if v == 1.0 { 1.0 } else { v }).map(|v| v), "before the drop: still but for the build");
        let hit = at(&mut c, &mut st, 12.0, 0.0);
        assert!(hit[0] > 1.09, "a punch in on the drop: {hit:?}");
        let later = at(&mut c, &mut st, 22.0, -10.0);
        assert!(later[0] < 1.02, "settled: {later:?}");
        st.rig.figure.kind = wo_show::rig::Figure::Kinetic;
        assert_eq!(at(&mut c, &mut st, 23.0, -11.0), STILL, "a shader scene's picture is its own");
    }

    #[test]
    fn a_quiet_part_holds_the_camera_still_a_loud_one_travels() {
        let mut s = Sweep::default();
        s.cut(0.0, 16, 0.05, 0.3, false, false, false);
        assert_eq!(s.at(4.0, 0.05, 1.0 / 60.0), NO_SWEEP);
        s.cut(0.0, 16, 1.0, 0.3, true, false, false);
        for i in 0..64 {
            let m = s.at(i as f64 * 0.25, 1.0, 1.0 / 60.0);
            assert!(m.dist >= 1.0, "a close shot never pushes in");
        }
        assert_eq!(cut_hold(16, 0.9), 4);
        assert_eq!(cut_hold(16, 0.5), 8);
        assert_eq!(cut_hold(16, 0.1), 16);
    }
}
