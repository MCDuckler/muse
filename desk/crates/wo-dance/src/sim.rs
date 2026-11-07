//! The dancers, a frame at a time (v1: show_dance.dart DanceSim's choreography): a slot every
//! four bars, a drop or a new section a slot of its own; the lead's move and the company's
//! own, stepped into at the beat whose pose and motion are nearest what the dancer is doing
//! (what is left of the old pose carried out of the new move); the troupe walking in and
//! off, its routine and formation; a section that comes round again danced as before; the
//! camera cut to another framing and travelling through it in a loud part; everyone bobbing
//! on the beat. What it gives the renderer: the camera, and every body's skinning and spot.
use std::collections::HashMap;

use wo_show::state::ShowState;
use wo_show::treat::meme_hash;

use crate::carry::Carry;
use crate::clock::{self, Art, Cam, Frame, Mood, Routine, Shot, Spot, Sweep, Troupe, V3};
use crate::{M34, Pose, Rig};

/// The dancers' rigs, by model (the first is the scan every other falls back on).
pub struct Company {
    pub rigs: Vec<(&'static str, Rig)>,
}

impl Company {
    /// Every model in `dir` (`<dir>/<model>/dancer.json`…) that loads; None if none does.
    pub fn load(dir: &std::path::Path) -> Option<Company> {
        let rigs: Vec<(&'static str, Rig)> = clock::MODELS.iter().filter_map(|m| Rig::load(&dir.join(m)).ok().map(|r| (*m, r))).collect();
        (!rigs.is_empty()).then_some(Company { rigs })
    }

    /// `name`'s rig, or the scan's where it is not here.
    pub fn rig(&self, name: &str) -> (&'static str, &Rig) {
        let (n, r) = self.rigs.iter().find(|(n, _)| *n == name).unwrap_or(&self.rigs[0]);
        (n, r)
    }
}

/// How much bigger a model is drawn, so every dancer stands about a person's height.
pub(crate) fn scale_of(rig: &Rig) -> f64 {
    if rig.height > 0.3 { (1.75 / rig.height).clamp(0.8, 1.2) } else { 1.0 }
}

/// One line of dancing: a move playing from an anchor, the one before it (danced on by anyone
/// a beat or so behind), and what is left of the pose it was in when it changed.
#[derive(Clone, Debug)]
pub(crate) struct Track {
    mv: Option<usize>,
    prev: Option<usize>,
    at: f64,
    phase: f64,
    rate: f64,
    p_at: f64,
    p_phase: f64,
    p_rate: f64,
    blend_len: f64,
    carry: [Option<Carry>; 2],
}

impl Default for Track {
    fn default() -> Self {
        Track { mv: None, prev: None, at: 0.0, phase: 0.0, rate: 1.0, p_at: 0.0, p_phase: 0.0, p_rate: 1.0, blend_len: 0.0, carry: [None, None] }
    }
}

impl Track {
    fn beat_of(&self, beats: f64) -> f64 {
        self.phase + (beats - self.at) * self.rate
    }

    fn switch_to(&mut self, m: usize, beats: f64, entry: f64, rate: f64, blend: f64) {
        self.prev = self.mv;
        self.p_at = self.at;
        self.p_phase = self.phase;
        self.p_rate = self.rate;
        self.mv = Some(m);
        self.at = beats;
        // on the record's beat: the entry beat is where the record's beat began
        self.phase = entry + clock::since_beat(beats, rate) * rate;
        self.rate = rate;
        self.blend_len = if self.prev.is_none() { 0.0 } else { blend };
    }

    /// The same move on at a new rate, kept on the beat.
    fn retime(&mut self, beats: f64, rate: f64) {
        if self.mv.is_none() || rate == self.rate {
            return;
        }
        let into = clock::since_beat(beats, rate) * rate;
        self.phase = (self.beat_of(beats) - into).round() + into;
        self.at = beats;
        self.rate = rate;
    }

    /// The pose at track beat `beats`: the lead's half, or with `partner` the partner's.
    pub(crate) fn pose(&self, rig: &Rig, beats: f64, partner: bool) -> Option<Pose> {
        let m0 = self.mv?;
        let pick = |m: usize| {
            let m = m.min(rig.moves.len() - 1);
            if partner { rig.partner_of(m) } else { m }
        };
        if let Some(p0) = self.prev
            && self.blend_len > 0.0
            && beats < self.at
        {
            // someone behind the lead, not there yet: still in the move before
            return Some(rig.sample(pick(p0), self.p_phase + (beats - self.p_at) * self.p_rate));
        }
        let mut out = rig.sample(pick(m0), self.beat_of(beats));
        if self.blend_len > 0.0
            && let Some(c) = &self.carry[usize::from(partner)]
        {
            c.apply(&mut out, beats - self.at);
        }
        Some(out)
    }
}

/// What a member dances: the lead's line or the company's own, `delay` beats behind, the
/// partner's half of a duet; in call and answer (`group` ≥ 0) the four-beat turns from `at`.
#[derive(Clone, Copy, Debug, PartialEq)]
struct Line {
    own: bool,
    delay: f64,
    partner: bool,
    group: i64,
    at: f64,
}

const LEAD_LINE: Line = Line { own: false, delay: 0.0, partner: false, group: -1, at: 0.0 };

#[derive(Clone, Debug)]
struct Member {
    spot: Spot,
    spot_was: Option<Spot>,
    spot_at: f64,
    line: Line,
    was: Option<Line>,
    line_at: f64,
    rank: i64,
    group: i64,
    /// Where it comes in from (an offset on the floor), how far in it is.
    from: (f64, f64),
    in_k: f64,
    leaving: bool,
}

impl Member {
    fn new(spot: Spot, delay: f64, own: bool, partner: bool, rank: i64, group: i64, from: (f64, f64)) -> Member {
        Member { spot, spot_was: None, spot_at: -99.0, line: Line { own, delay, partner, group: -1, at: 0.0 }, was: None, line_at: -99.0, rank, group, from, in_k: 0.0, leaving: false }
    }

    fn dance(&mut self, l: Line, beats: f64) {
        if l == self.line {
            return;
        }
        self.was = Some(self.line);
        self.line_at = beats;
        self.line = l;
    }

    /// Off to `s` (keeping which way round it dances).
    fn move_to(&mut self, s: Spot, beats: f64) {
        if self.spot.x == s.x && self.spot.y == s.y {
            return;
        }
        self.spot_was = Some(self.spot_now(beats));
        self.spot_at = beats;
        self.spot = Spot { x: s.x, y: s.y, yaw: s.yaw, mirror: self.spot.mirror, scale: self.spot.scale, lift: 0.0 };
    }

    /// Where it stands at `beats` (gliding to a new place for two beats).
    fn spot_now(&self, beats: f64) -> Spot {
        let Some(w) = self.spot_was else { return self.spot };
        let k = ((beats - self.spot_at) / 2.0).clamp(0.0, 1.0);
        if k >= 1.0 {
            return self.spot;
        }
        let e = k * k * (3.0 - 2.0 * k);
        let s = self.spot;
        Spot { x: w.x + (s.x - w.x) * e, y: w.y + (s.y - w.y) * e, yaw: w.yaw + (s.yaw - w.yaw) * e, mirror: s.mirror, scale: s.scale, lift: 0.0 }
    }
}

/// A body to draw this frame.
#[derive(Clone, Debug)]
pub struct Body {
    pub model: &'static str,
    /// Which of the model's meshes: 0 the lead's whole scan, 1 the company's lighter one.
    pub mesh: usize,
    /// Each bone in the world (from Rig::solve) and its skinning matrix.
    pub world: Vec<M34>,
    pub skin: Vec<M34>,
    pub spot: Spot,
    /// How far from the camera (the far ones are drawn first).
    pub depth: f64,
    pub lead: bool,
}

/// What the dancers are this frame.
#[derive(Clone, Debug)]
pub struct Scene {
    pub cam: Cam,
    pub frame: Frame,
    pub shot: Shot,
    pub troupe: Troupe,
    pub art: Art,
    /// Far first.
    pub bodies: Vec<Body>,
    pub mood: Mood,
    pub beats: f64,
    pub since_drop: Option<f64>,
    pub heat: f64,
    pub wake_k: f64,
    pub kick: f64,
    pub playing: bool,
    /// Seconds the dance has run (the clock of its own looks).
    pub t: f64,
    /// Nothing about the picture changed since the last frame but the poses.
    pub still: bool,
}

struct Booked {
    mv: usize,
    entry: i64,
    troupe: Troupe,
    slot: i64,
}

/// The dancers' choreography, frame by frame.
pub struct DanceSim {
    pub(crate) paint: crate::paint::PaintState,
    t: f64,
    drop_at: Option<f64>,
    away_was: Option<f64>,
    section_was: Option<String>,
    slot: i64,
    cut: i64,
    pub(crate) lead: Track,
    alt: Track,
    recent: Vec<String>,
    troupe: Troupe,
    members: Vec<Member>,
    shot: Shot,
    sweep: Sweep,
    art: Option<Art>,
    styled_was: Option<String>,
    section_slot: i64,
    book: HashMap<String, Booked>,
    book_salt: Option<i64>,
    frames: u64,
    alt_due: Option<(usize, [f64; 7], bool, bool)>,
    alt_due_frame: u32,
    troupe_drawn: Option<Troupe>,
    size_was: Option<(f64, f64)>,
    art_was: Option<Art>,
    /// A rendering, a company, a framing forced from outside (WETOWL_DANCE_ART/TROUPE/SHOT).
    pub forced_art: Option<Art>,
    pub forced_troupe: Option<Troupe>,
    pub forced_shot: Option<Shot>,
    /// The big sets dance (the quality tier's say).
    pub big: bool,
    /// The hands' say on the moves (the Cue's): kept out, starred, one asked for.
    moves_off: Vec<String>,
    moves_star: Vec<String>,
    audition: Option<(u32, String)>,
    /// The last asking served (danced, or given up on), and the slots one waited.
    audition_served: u32,
    audition_waits: u32,
    /// The framings' levels in the scene on (the ones not 1).
    shots: std::collections::BTreeMap<String, f64>,
}

impl Default for DanceSim {
    fn default() -> Self {
        DanceSim {
            paint: Default::default(),
            t: 0.0,
            drop_at: None,
            away_was: None,
            section_was: None,
            slot: -999,
            cut: -999,
            lead: Track::default(),
            alt: Track::default(),
            recent: vec![],
            troupe: Troupe::Solo,
            members: vec![],
            shot: Shot::Full,
            sweep: Sweep::default(),
            art: None,
            styled_was: None,
            section_slot: -1,
            book: HashMap::new(),
            book_salt: None,
            frames: 0,
            alt_due: None,
            alt_due_frame: 0,
            troupe_drawn: None,
            size_was: None,
            art_was: None,
            forced_art: None,
            forced_troupe: None,
            forced_shot: None,
            big: true,
            moves_off: vec![],
            moves_star: vec![],
            audition: None,
            audition_served: 0,
            audition_waits: 0,
            shots: Default::default(),
        }
    }
}

impl DanceSim {
    /// With the environment's forcings (WETOWL_DANCE_ART, _TROUPE, _SHOT), for a look at one.
    pub fn from_env() -> DanceSim {
        let get = |k: &str| std::env::var(k).ok();
        DanceSim {
            forced_art: get("WETOWL_DANCE_ART").and_then(|a| Art::by_name(&a)),
            forced_troupe: get("WETOWL_DANCE_TROUPE").and_then(|a| Troupe::by_name(&a)),
            forced_shot: get("WETOWL_DANCE_SHOT").and_then(|a| Shot::by_name(&a)),
            ..Default::default()
        }
    }

    /// One frame `dt` seconds on, for a `w`×`h` picture.
    pub fn frame(&mut self, co: &Company, st: &ShowState, dt: f64, w: f64, h: f64) -> Scene {
        let (_, rig) = co.rig(clock::MODELS[0]);
        self.t += dt;
        // the hands' say: the moves off and starred, a move asked for, the framings' levels
        if self.moves_off != st.macros.moves_off {
            self.moves_off.clone_from(&st.macros.moves_off);
        }
        if self.moves_star != st.macros.moves_star {
            self.moves_star.clone_from(&st.macros.moves_star);
        }
        self.audition = st.macros.audition.clone().map(|a| (st.macros.audition_n, a));
        if self.shots != st.macros.shots {
            self.shots.clone_from(&st.macros.shots);
        }
        let m = st.master();
        let playing = m.playing && m.beat_index.is_some();
        let bpm = m.bpm.filter(|b| *b > 1.0).unwrap_or(120.0);
        let beats = if !playing {
            self.t * bpm / 60.0
        } else {
            match (m.bar_index, m.beat_in_bar) {
                (Some(bar), Some(b)) => (bar * 4 + b) as f64 + m.beat_phase,
                _ => m.beat_index.unwrap_or(0) as f64 + m.beat_phase,
            }
        };
        let salt = m.track_id.unwrap_or(0);

        // the drop, remembered past the deck's two beats
        let away = m.drop_beats_away;
        if playing {
            if let Some(a) = away
                && a <= 0.0
                && a > -2.5
                && self.away_was.is_none_or(|w| w > 0.0)
            {
                self.drop_at = Some(beats + a);
            }
            if m.section.as_deref() == Some("drop") && self.section_was.as_deref() != Some("drop") && self.drop_at.is_none_or(|d| beats - d > 8.0) {
                self.drop_at = Some(beats);
            }
            if self.drop_at.is_some_and(|d| beats - d < -1.0 || beats - d > 64.0) {
                self.drop_at = None;
            }
        }
        let section_turned = playing && self.section_was.is_some() && m.section != self.section_was;
        self.away_was = away;
        self.section_was = m.section.clone();
        let since = self.drop_at.map(|d| beats - d);
        let mood = if playing { clock::mood(m, since) } else { Mood::Sleep };
        let heat = if mood == Mood::Rage { clock::heat(m, since) } else { 0.0 };
        let wake_k = if mood == Mood::Wake { clock::wake_k(m) } else { 0.0 };
        let kick = st.num("dyn.hit.kick");

        let choice = st.macros.dancer.as_deref();
        let off = &st.macros.dancers_off;
        let (lead_name, lead_rig) = co.rig(clock::lead(choice, salt, off));
        let hero_scale = scale_of(lead_rig);

        // ---- the choreography: a slot every four bars; a drop or a new section one of its own
        let n = (beats / clock::SLOT_BEATS).floor() as i64;
        let drop_now = since.is_some_and(|s| (0.0..0.5).contains(&s)) && self.lead.mv.is_none_or(|i| rig.moves[i].tier_ix() != 2);
        let section_now = section_turned && self.section_slot != n;
        let sleep = mood == Mood::Sleep;
        let styled = st.rig.figure.style.clone();
        let let_go = styled.is_none() && self.styled_was.is_some();
        self.styled_was = styled.clone();
        if self.art.is_none() || drop_now || section_now || let_go {
            self.art = Some(self.forced_art.unwrap_or_else(|| clock::art(mood, salt ^ st.macros.seed, n, if let_go { None } else { self.art })));
        }
        // the hands' own rendering, from the frame (the show's rig): on at once
        if let Some(want) = styled.as_deref().and_then(Art::by_name).filter(|a| a.drawn()) {
            self.art = Some(want);
        }
        let art = self.art.unwrap_or(Art::Plain);
        if self.lead.mv.is_none() || n != self.slot || drop_now || section_now {
            if section_now {
                self.section_slot = n;
            }
            let keep = self.lead.mv.is_some() && !drop_now && !section_now && sleep && self.lead.rate < 1.0 && n % 2 != 0;
            let tier = clock::tier(mood, wake_k, m.energy, meme_hash(salt.rem_euclid(9973) as f64, n as f64, 3.0));
            let techno = clock::techno(bpm, m.vocal);
            let flavour = clock::flavour(salt, bpm, mood, m.hook && m.vocal > 0.3, techno);
            let mut troupe = if drop_now { clock::troupe(Mood::Rage, salt, n + 1, 1.0, self.big) } else { clock::troupe(mood, salt, n, heat, self.big) };
            troupe = match art {
                Art::Chrono | Art::Viewports => Troupe::Solo,
                _ => troupe,
            };
            if !keep {
                troupe = clock::paired(troupe, mood, &flavour, salt, n);
            }
            // a section come round again: as it was danced before (its first eight slots)
            if self.book_salt != Some(salt) {
                self.book.clear();
                self.book_salt = Some(salt);
            }
            let in_section = n - self.section_slot;
            let book_key = (playing && self.section_slot >= 0 && in_section < 8).then(|| m.section.as_ref().map(|s| format!("{s}|{in_section}"))).flatten();
            let again = book_key.as_ref().and_then(|k| self.book.get(k)).map(|b| (b.mv, b.entry, b.troupe, b.slot));
            if let Some((_, _, t, _)) = again {
                troupe = t;
            }
            if let Some(t) = self.forced_troupe {
                troupe = t;
            }
            if keep && clock::is_paired(self.troupe) {
                troupe = self.troupe;
            }
            if !keep {
                let blend = if drop_now { 0.0 } else if sleep { 2.0 } else { 1.0 };
                if let Some((mv, entry, _, _)) = again {
                    self.replay(rig, mv, entry, bpm, beats, sleep, blend);
                } else {
                    let duo = clock::is_paired(troupe) && rig.has_duets();
                    self.step(rig, false, tier, &flavour, bpm, beats, salt, n, sleep, blend, techno, duo);
                }
                // the others' own line on the next frame: the slot's work split in two
                self.alt_due = Some((tier, flavour, techno, drop_now));
            }
            // no duet to dance: a partner becomes a second dancer
            if clock::is_paired(troupe) && self.lead.mv.is_none_or(|i| rig.moves[i].duo.is_none()) {
                troupe = if troupe == Troupe::Couple { Troupe::Duo } else { Troupe::Line };
            }
            let dealt = again.map(|a| a.3).unwrap_or(n);
            if let (Some(k), None, false, Some(mv)) = (&book_key, again, keep, self.lead.mv) {
                self.book.insert(k.clone(), Booked { mv, entry: self.lead.phase.round() as i64, troupe, slot: n });
            }
            self.set_troupe(troupe, salt, dealt, drop_now);
            self.routine(troupe, salt, dealt, n, beats);
            self.slot = n;
        }
        if let Some((tier, flavour, techno, dropped)) = self.alt_due {
            let ready = self.alt_due_frame > 0 || drop_now;
            self.alt_due_frame += 1;
            if ready {
                self.step(rig, true, tier, &flavour, bpm, beats, salt + 977, n, sleep, if dropped { 0.0 } else { 1.0 }, techno, false);
                self.alt_due = None;
                self.alt_due_frame = 0;
            }
        }
        if let Some(i) = self.lead.mv {
            self.lead.retime(beats, clock::rate(bpm, rig.moves[i].bpm, sleep));
        }
        if let Some(i) = self.alt.mv {
            self.alt.retime(beats, clock::rate(bpm, rig.moves[i].bpm, sleep));
        }

        // ---- the camera: cut to another framing after a while, on a drop and a new section;
        // in a loud part each shot travels
        let drive = wo_show::director::drive(m);
        let hold = clock::cut_hold(clock::hold(mood), drive);
        let cut_n = hold * 100000 + (beats / hold as f64).floor() as i64;
        let (shot_was, troupe_was) = (self.shot, self.troupe_drawn);
        if cut_n != self.cut || drop_now || section_now {
            self.cut = cut_n;
            let levels = &self.shots;
            let weight = |s: Shot| levels.get(s.name()).copied().unwrap_or(1.0);
            self.shot = self.forced_shot.unwrap_or_else(|| clock::shot(mood, salt, cut_n, self.troupe, true, (!levels.is_empty()).then_some(&weight as &dyn Fn(Shot) -> f64)));
            // the silhouettes, the text and the dots read best square on
            if self.shot == Shot::Full {
                self.shot = Shot::Front;
            }
            let close = !matches!(self.shot, Shot::Front | Shot::Wide | Shot::Medium);
            let d = meme_hash(salt.rem_euclid(9973) as f64, cut_n as f64, 331.0);
            self.sweep.cut(beats, hold, if playing { drive } else { 0.0 }, d, close, clock::is_big(self.troupe), drop_now);
        }
        let frame = Frame::of(self.shot, self.troupe).swept(self.sweep.at(beats, if playing { drive } else { 0.0 }, dt));
        let still = self.shot == shot_was && Some(self.troupe) == troupe_was && Some((w, h)) == self.size_was && Some(art) == self.art_was && !self.sweep.moving();
        self.troupe_drawn = Some(self.troupe);
        self.size_was = Some((w, h));
        self.art_was = Some(art);
        let cam = frame.cam(w, h, 0.0);

        // ---- the troupe's poses; everyone bobs on the beat (but asleep), as deep as the low end is loud
        let on_beat = if playing { (-(beats - beats.floor()) * 7.0).exp() * (st.num("dyn.band.low") * 1.4).clamp(0.0, 1.0) } else { kick };
        let bob = if sleep { 0.0 } else { (if clock::techno(bpm, m.vocal) { 0.034 } else { 0.022 }) * on_beat.max(if playing { 0.0 } else { kick }) };
        let mut bodies = vec![];
        let mut pose = self.lead.pose(lead_rig, beats, false).unwrap_or_else(|| lead_rig.sample(0, beats));
        pose.hips[2] -= bob / hero_scale;
        let world = lead_rig.solve(&pose);
        let hero_spot = Spot { scale: hero_scale, ..Default::default() };
        bodies.push(Body {
            model: lead_name,
            mesh: 0,
            skin: lead_rig.skinning(&world),
            world,
            spot: hero_spot,
            depth: cam.project(V3::new(0.0, 0.0, 1.0)).2,
            lead: true,
        });
        // poses worked out this frame, by model and line (on the GPU a grid is a handful of poses)
        let mut shared: HashMap<String, usize> = HashMap::new();
        shared.insert(format!("{lead_name}|{LEAD_LINE:?}"), 0);
        let rate = dt * bpm / 60.0;
        for i in 0..self.members.len() {
            let mb = &mut self.members[i];
            mb.in_k = (mb.in_k + if mb.leaving { -1.0 } else { 1.0 } * rate).clamp(0.0, 1.0);
            if mb.in_k <= 0.0 && mb.leaving {
                continue;
            }
            let (ma, mr) = co.rig(clock::member(choice, salt, i, off));
            let sc = scale_of(mr);
            let e = mb.in_k * mb.in_k * (3.0 - 2.0 * mb.in_k);
            let s = mb.spot_now(beats);
            let spot = Spot { x: s.x + mb.from.0 * (1.0 - e), y: s.y + mb.from.1 * (1.0 - e), yaw: s.yaw, mirror: s.mirror, scale: s.scale * sc, lift: 0.0 };
            let easing = mb.was.is_some() && beats - mb.line_at < 1.0;
            let (line, was, line_at) = (mb.line, mb.was, mb.line_at);
            let key = (!easing).then(|| format!("{ma}|{line:?}"));
            let mesh = if mr.meshes.len() > 1 { 1 } else { 0 };
            let depth = cam.project(V3::new(spot.x, spot.y, 1.0)).2;
            if let Some(&twin) = key.as_ref().and_then(|k| shared.get(k)) {
                let b: &Body = &bodies[twin];
                let (world, skin) = (b.world.clone(), b.skin.clone());
                bodies.push(Body { model: ma, mesh, world, skin, spot, depth, lead: false });
                continue;
            }
            let mut p = self.line_pose(mr, line, beats);
            if easing && let Some(was) = was {
                // out of what it danced before, over a beat
                let mut wp = self.line_pose(mr, was, beats);
                let k = beats - line_at;
                wp.blend_toward(&p, k * k * (3.0 - 2.0 * k));
                p = wp;
            }
            p.hips[2] -= bob / sc;
            let world = mr.solve(&p);
            if let Some(k) = key {
                shared.insert(k, bodies.len());
            }
            bodies.push(Body { model: ma, mesh, skin: mr.skinning(&world), world, spot, depth, lead: false });
        }
        self.members.retain(|mb| !(mb.leaving && mb.in_k <= 0.0));
        bodies.sort_by(|a, b| b.depth.total_cmp(&a.depth));
        self.frames += 1;
        Scene { cam, frame, shot: self.shot, troupe: self.troupe, art, bodies, mood, beats, since_drop: since, heat, wake_k, kick, playing, t: self.t, still }
    }

    /// A member's pose for line `l` at `beats`: in call and answer a turn held still is the
    /// pose the turn began in; out of one, eased back into the steps over ¾ of a beat.
    fn line_pose(&self, mr: &Rig, l: Line, beats: f64) -> Pose {
        let track = if l.own && self.alt.mv.is_some() { &self.alt } else { &self.lead };
        let t = beats - l.delay;
        let get = |at: f64| track.pose(mr, at, l.partner).unwrap_or_else(|| mr.sample(0, at));
        if l.group >= 0 {
            let w = ((t - l.at) / 4.0).floor() as i64;
            let w0 = l.at + w as f64 * 4.0;
            if (w + l.group) % 2 != 0 {
                return get(w0);
            }
            let k = (t - w0) / 0.75;
            if w > 0 && k < 1.0 {
                let mut held = get(w0 - 4.0);
                held.blend_toward(&get(t), k * k * (3.0 - 2.0 * k));
                return held;
            }
        }
        get(t)
    }

    /// The company's routine and places: `slot` the slot it is dealt for, `now` the slot it
    /// is danced in.
    fn routine(&mut self, t: Troupe, salt: i64, slot: i64, now: i64, beats: f64) {
        let r = clock::routine(t, salt, slot);
        let at = now as f64 * clock::SLOT_BEATS;
        let big = clock::is_big(t);
        for mb in self.members.iter_mut().filter(|m| !m.leaving) {
            let p = mb.line.partner;
            let l = if p && mb.rank == 0 {
                // the lead's partner dances with the lead, whatever the others do
                Line { partner: true, ..LEAD_LINE }
            } else {
                match r {
                    Routine::Unison => Line { partner: p, ..LEAD_LINE },
                    Routine::Wave => Line { delay: (mb.rank as f64 * if big { 0.125 } else { 0.25 }).min(1.5), partner: p, ..LEAD_LINE },
                    Routine::Canon => Line { delay: if mb.rank % 2 != 0 { 1.0 } else { 2.0 }, partner: p, ..LEAD_LINE },
                    Routine::Split => Line { own: mb.group == 1, partner: p, ..LEAD_LINE },
                    Routine::Answer => Line { partner: p, group: mb.group, at, ..LEAD_LINE },
                }
            };
            mb.dance(l, beats);
        }
        let f = clock::formation(t, salt, slot);
        let Some(spots) = formation_spots(t, f) else { return };
        let live: Vec<usize> = (0..self.members.len()).filter(|&i| !self.members[i].leaving).collect();
        if spots.len() != live.len() {
            return;
        }
        for (k, i) in live.into_iter().enumerate() {
            self.members[i].move_to(spots[k], beats);
        }
    }

    /// A new move on the lead's track (or the company's own, `alt`): one of the pool, stepped
    /// into at the beat whose pose and motion are nearest what the dancer is doing.
    #[allow(clippy::too_many_arguments)]
    fn step(&mut self, rig: &Rig, alt: bool, tier: usize, flavour: &[f64; 7], bpm: f64, beats: f64, salt: i64, slot: i64, sleep: bool, blend: f64, techno: bool, duo: bool) {
        // the moves switched off are out (all of them off: none is)
        let on: Vec<usize> = (0..rig.moves.len()).filter(|&i| !self.moves_off.contains(&rig.moves[i].id)).collect();
        let bank: Vec<usize> = if on.is_empty() { (0..rig.moves.len()).collect() } else { on };
        let track = if alt { &self.alt } else { &self.lead };
        let recent: Vec<String> = if alt { track.mv.map(|i| vec![rig.moves[i].id.clone()]).unwrap_or_default() } else { self.recent.clone() };
        let mut pool = clock::pool(&rig.moves, &bank, tier, flavour, bpm, &recent, techno, duo);
        // the record's own few moves (the same whatever was danced last), the starred too
        let star = |i: usize| self.moves_star.contains(&rig.moves[i].id);
        let own: Vec<usize> = clock::own_moves(&clock::pool(&rig.moves, &bank, tier, flavour, bpm, &[], techno, duo), &rig.moves, salt).into_iter().map(|e| e.0).collect();
        let mine: Vec<(usize, f64)> = pool.iter().copied().filter(|e| own.contains(&e.0) || star(e.0)).collect();
        if !mine.is_empty() {
            pool = mine;
        }
        if !self.moves_star.is_empty() {
            for e in &mut pool {
                if star(e.0) {
                    e.1 *= 2.5;
                }
            }
        }
        // a move asked for by hand: the lead dances it now, whatever the dice say — at a slot
        // for its company (a duet's for a duet), given up on after a few that are not
        if !alt
            && let Some((n, id)) = self.audition.clone()
            && n != self.audition_served
        {
            match rig.moves.iter().position(|m| m.id == id) {
                Some(i) if duo == rig.moves[i].duo.is_some() => {
                    pool = vec![(i, 1.0)];
                    (self.audition_served, self.audition_waits) = (n, 0);
                }
                Some(_) => {
                    self.audition_waits += 1;
                    if self.audition_waits > 4 {
                        (self.audition_served, self.audition_waits) = (n, 0);
                    }
                }
                None => self.audition_served = n,
            }
        }
        if pool.is_empty() {
            return;
        }
        const H: f64 = 0.25;
        let now = track.pose(rig, beats, false);
        let was = track.pose(rig, beats - H, false);
        let had = now.is_some() && was.is_some();
        let from = now.as_ref().filter(|_| had).map(|p| rig.key_joints(p));
        let from_was = was.as_ref().filter(|_| had).map(|p| rig.key_joints(p));
        let mut picks: Vec<usize> = vec![];
        for k in 0..5 {
            if picks.len() >= 4 {
                break;
            }
            if let Some(mv) = clock::draw(&pool, meme_hash(salt.rem_euclid(9973) as f64, (slot * 7 + k) as f64, 7.0))
                && !picks.contains(&mv)
            {
                picks.push(mv);
            }
        }
        if pool.len() == 1 && !picks.contains(&pool[0].0) {
            picks.push(pool[0].0);
        }
        let (mut best, mut best_e, mut best_score, mut best_d) = (None, 0usize, f64::INFINITY, 0.0);
        for (order, &mv) in picks.iter().enumerate() {
            let rate = clock::rate(bpm, rig.moves[mv].bpm, sleep);
            for e in clock::entries(&rig.moves[mv]) {
                let (mut d, mut dv) = (0.0, 0.0);
                if let (Some(from), Some(from_was)) = (&from, &from_was) {
                    let to = rig.key_joints(&rig.sample(mv, e as f64));
                    d = Rig::pose_distance(from, &to);
                    let to_was = rig.key_joints(&rig.sample(mv, e as f64 - H * rate));
                    dv = Rig::motion_distance(from, from_was, &to, &to_was) / H;
                }
                let score = d + 0.08 * dv + order as f64 * 0.04 + e as f64 * 0.002;
                if score < best_score {
                    (best, best_e, best_score, best_d) = (Some(mv), e, score, d);
                }
            }
        }
        let Some(best) = best else { return };
        self.enter(rig, alt, best, best_e as i64, best_d, bpm, beats, sleep, blend, alt, if had { now } else { None });
    }

    /// The track into `best` at its beat `entry`, `dist` metres from the pose it is in (`now`):
    /// what is left of the old pose fades out of the new move over `blend` beats.
    #[allow(clippy::too_many_arguments)]
    fn enter(&mut self, rig: &Rig, alt: bool, best: usize, entry: i64, dist: f64, bpm: f64, beats: f64, sleep: bool, blend: f64, quiet: bool, now: Option<Pose>) {
        let had = now.is_some();
        let rate = clock::rate(bpm, rig.moves[best].bpm, sleep);
        let len = if blend <= 0.0 { 0.0 } else { blend * (0.8 + 2.5 * dist).clamp(0.8, 1.8) };
        const HC: f64 = 1.0 / 16.0;
        let track = if alt { &mut self.alt } else { &mut self.lead };
        let pair = rig.moves[best].duo.is_some() || track.mv.is_some_and(|i| rig.moves[i].duo.is_some());
        let partner = (pair && len > 0.0 && had).then(|| (track.pose(rig, beats, true), track.pose(rig, beats - HC, true)));
        let was = (len > 0.0 && had).then(|| track.pose(rig, beats - HC, false)).flatten();
        track.switch_to(best, beats, entry as f64, rate, len);
        if len > 0.0
            && let (Some(now), Some(was)) = (&now, &was)
        {
            let carry = |track: &mut Track, part: usize, a: &Pose, a_was: &Pose| {
                let mv = if part == 1 { rig.partner_of(best) } else { best };
                let to = rig.sample(mv, entry as f64);
                let to_was = rig.sample(mv, entry as f64 - HC * rate);
                track.carry[part].get_or_insert_with(|| Carry::new(rig.bones())).start(a, a_was, &to, &to_was, HC, len);
            };
            carry(track, 0, now, was);
            match partner {
                Some((Some(p), Some(pw))) => carry(track, 1, &p, &pw),
                _ => {
                    if let Some(c) = &mut track.carry[1] {
                        c.len = 0.0;
                    }
                }
            }
        }
        if !quiet {
            self.recent.push(rig.moves[best].id.clone());
            if self.recent.len() > 5 {
                self.recent.remove(0);
            }
        }
    }

    /// The lead back into `mv` at its beat `entry`, as danced the last time the record was here.
    #[allow(clippy::too_many_arguments)]
    fn replay(&mut self, rig: &Rig, mv: usize, entry: i64, bpm: f64, beats: f64, sleep: bool, blend: f64) {
        let now = self.lead.pose(rig, beats, false);
        let d = now.as_ref().map_or(0.0, |p| Rig::pose_distance(&rig.key_joints(p), &rig.key_joints(&rig.sample(mv, entry as f64))));
        self.enter(rig, false, mv, entry, d, bpm, beats, sleep, blend, false, now);
    }

    /// The troupe for a slot: the others walk in from the wings (or are simply there, on a
    /// drop's cut) and walk off when the dancer goes back to dancing alone.
    fn set_troupe(&mut self, t: Troupe, salt: i64, slot: i64, instant: bool) {
        if t == self.troupe && self.members.iter().any(|m| !m.leaving) == (t != Troupe::Solo) {
            return;
        }
        self.troupe = t;
        for mb in &mut self.members {
            mb.leaving = true;
            if instant {
                mb.in_k = 0.0;
            }
        }
        let mut add = vec![];
        let sign = |x: f64| if x > 0.0 { 1.0 } else if x < 0.0 { -1.0 } else { 0.0 };
        match t {
            Troupe::Solo => {}
            Troupe::Duo => add.push(Member::new(formation_spots(t, 0).unwrap()[0], 0.0, false, false, 1, 1, (4.0, 0.0))),
            Troupe::Trio => {
                let f = formation_spots(t, 0).unwrap();
                add.push(Member::new(f[0], 0.0, false, false, 1, 1, (-4.0, 1.0)));
                add.push(Member::new(f[1], 0.0, false, false, 1, 1, (4.0, 1.0)));
            }
            Troupe::Line => {
                let f = formation_spots(t, 0).unwrap();
                for k in 1..=4 {
                    let sp = f[k - 1];
                    // the inner pair answers the outer one
                    add.push(Member::new(sp, 0.25 * k as f64, false, false, k as i64, if k <= 2 { 0 } else { 1 }, (sign(sp.x) * 5.0, 0.0)));
                }
            }
            Troupe::Grid => {
                // seven across, five deep, the lead in the front middle
                for row in 0..5i64 {
                    for col in -3..=3i64 {
                        if row == 0 && col == 0 {
                            continue;
                        }
                        let (x, y) = (col as f64 * 1.35, row as f64 * 1.6);
                        add.push(Member::new(Spot::at(x, y, col % 2 != 0), 0.0, false, false, row + col.abs(), row % 2, (sign(x) * 6.0 + 0.01, row as f64 * 0.5)));
                    }
                }
            }
            Troupe::Ring => {
                for i in 0..12i64 {
                    let a = std::f64::consts::PI * 2.0 * i as f64 / 12.0 + std::f64::consts::FRAC_PI_2;
                    let (x, y) = (a.cos() * 3.3, a.sin() * 3.3 + 0.6);
                    add.push(Member::new(Spot::at(x, y, i % 2 != 0), 0.0, false, false, i.min(12 - i) + 1, i % 2, (x * 0.6, y * 0.6 + 4.0)));
                }
            }
            Troupe::Army => {
                for row in 1..=3i64 {
                    for k in 0..8i64 {
                        let x = (k as f64 - 3.5) * 1.25 + if row % 2 != 0 { 0.3 } else { -0.3 };
                        let y = row as f64 * 1.7;
                        add.push(Member::new(Spot::at(x, y, k % 2 != 0), 0.0, false, false, row * 2 + (x.abs() / 1.25).round() as i64, row % 2, (sign(x) * 7.0, 0.0)));
                    }
                }
            }
            Troupe::Crowd => {
                for i in 0..6i64 {
                    let a = std::f64::consts::PI * (0.15 + 0.7 * i as f64 / 5.0);
                    let r = 2.2 + 0.5 * meme_hash(salt.rem_euclid(9973) as f64, (slot * 3 + i) as f64, 61.0);
                    let (x, y) = (-a.cos() * r, a.sin() * r * 0.8 + 0.4);
                    let spot = Spot { x, y, yaw: -x * 0.12, mirror: i % 2 != 0, ..Default::default() };
                    add.push(Member::new(spot, if i % 2 == 0 { 0.0 } else { 0.5 }, i % 3 == 1, false, i + 1, if i % 3 == 1 { 1 } else { 0 }, (sign(x) * 5.0, 2.0)));
                }
            }
            Troupe::Couple => add.push(Member::new(Spot::default(), 0.0, false, true, 0, -1, (4.0, 0.3))),
            Troupe::Couples => {
                let f = formation_spots(t, 0).unwrap();
                add.push(Member::new(f[0], 0.0, false, true, 0, -1, (4.0, 0.3)));
                for k in 0..4 {
                    let sp = f[k + 1];
                    add.push(Member::new(sp, 0.0, false, k % 2 != 0, 1, if k < 2 { 0 } else { 1 }, (sign(sp.x) * 5.0, 0.5)));
                }
            }
        }
        if instant {
            for s in &mut add {
                s.in_k = 1.0;
            }
            self.members.retain(|m| !m.leaving);
        }
        self.members.extend(add);
    }
}

/// A small set's places in formation `f` (0 the one it walks in as), in the order the troupe
/// makes its members; None where it has only the one.
fn formation_spots(t: Troupe, f: usize) -> Option<Vec<Spot>> {
    let pairs = |xy: &[(f64, f64)]| xy.iter().flat_map(|&(x, y)| [Spot::at(-x, y, false), Spot::at(x, y, true)]).collect::<Vec<_>>();
    Some(match t {
        Troupe::Duo => vec![[Spot::at(1.3, 0.6, true), Spot::at(-1.3, 0.6, true), Spot::at(0.9, 1.3, true)][f % 3]],
        Troupe::Trio => pairs(&[[(1.4, 1.1)], [(0.9, 1.8)], [(1.9, 0.3)], [(0.65, 2.0)]][f % 4]),
        Troupe::Line => {
            let rows = [[(1.2, 0.15), (2.4, 0.3)], [(1.1, 1.0), (2.2, 2.0)], [(1.0, 1.6), (2.6, 1.6)], [(1.4, 0.9), (0.7, 2.1)]][f % 4];
            rows.iter()
                .enumerate()
                .flat_map(|(i, &(x, y))| [Spot::at(-x, y + 0.15 * i as f64, false), Spot::at(x, y + 0.15 * i as f64 + 0.15, true)])
                .collect()
        }
        Troupe::Couples => {
            let (x, y) = [(2.7, 1.5), (2.2, 2.5), (3.1, 0.5), (1.6, 2.2)][f % 4];
            vec![Spot::default(), Spot::at(-x, y, true), Spot::at(-x, y, true), Spot::at(x, y, false), Spot::at(x, y, false)]
        }
        _ => return None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use wo_show::deck::ShowDeck;

    fn company() -> Option<Company> {
        let co = Company::load(&std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../app/assets/show/dance")).expect("the shipped dancers");
        assert_eq!(co.rigs.len(), 2, "both dancers load");
        Some(co)
    }

    fn deck(beat: f64, section: &str) -> ShowDeck {
        let b = beat.floor() as i64;
        ShowDeck {
            name: "A".into(),
            track_id: Some(4242),
            playing: true,
            bpm: Some(124.0),
            beat_index: Some(b),
            beat_phase: beat - b as f64,
            beat_in_bar: Some(b % 4),
            bar_index: Some(b / 4),
            section: Some(section.into()),
            energy: 0.8,
            ..Default::default()
        }
    }

    #[test]
    fn a_record_dances_the_same_way_twice() {
        let Some(co) = company() else { return };
        let run = || {
            let mut sim = DanceSim::default();
            let mut out = vec![];
            for f in 0..600 {
                let beat = 64.0 + f as f64 * 124.0 / 60.0 / 60.0;
                let st = ShowState { a: deck(beat, if beat < 72.0 { "verse" } else { "drop" }), dt: 1.0 / 60.0, ..Default::default() };
                let s = sim.frame(&co, &st, 1.0 / 60.0, 1280.0, 720.0);
                out.push((s.troupe, s.shot, s.bodies.len(), (s.bodies[0].world[0][11] * 1e6).round() as i64));
            }
            out
        };
        let (a, b) = (run(), run());
        assert_eq!(a, b);
        // the drop at beat 72: company joins at some point
        assert!(a.iter().any(|x| x.2 > 1), "someone joins the lead");
    }

    #[test]
    fn every_troupe_stands_its_company() {
        let Some(co) = company() else { return };
        for (t, n) in [(Troupe::Solo, 1), (Troupe::Duo, 2), (Troupe::Trio, 3), (Troupe::Line, 5), (Troupe::Crowd, 7), (Troupe::Grid, 35), (Troupe::Ring, 13), (Troupe::Army, 25), (Troupe::Couple, 2), (Troupe::Couples, 6)] {
            let mut sim = DanceSim { forced_troupe: Some(t), ..Default::default() };
            let mut s = None;
            for f in 0..240 {
                let st = ShowState { a: deck(10.0 + f as f64 * 0.035, "verse"), dt: 1.0 / 60.0, ..Default::default() };
                s = Some(sim.frame(&co, &st, 1.0 / 60.0, 1280.0, 720.0));
            }
            let s = s.unwrap();
            assert_eq!(s.bodies.len(), n, "{t:?}");
            // standing on the floor, every one: the hips above it, the head over the hips
            for b in &s.bodies {
                let (_, rig) = co.rig(b.model);
                let hips = b.world[rig.bone("Hips").unwrap()][11];
                let head = b.world[rig.bone("Head").unwrap()][11];
                assert!(hips > 0.5 && head > hips + 0.3, "{t:?}: hips {hips} head {head}");
            }
            // far first
            assert!(s.bodies.windows(2).all(|w| w[0].depth >= w[1].depth));
        }
    }

    /// The lead's moves over `slots` slots (a quarter beat a frame), and the framings cut to.
    fn danced(co: &Company, macros: &wo_show::state::ShowMacros, slots: usize) -> (Vec<String>, Vec<Shot>) {
        let mut sim = DanceSim { forced_troupe: Some(Troupe::Solo), ..Default::default() };
        let (mut moves, mut shots) = (vec![], vec![]);
        for f in 0..slots * 64 {
            let st = ShowState { a: deck(32.0 + f as f64 * 0.25, "verse"), dt: 1.0 / 60.0, macros: macros.clone(), ..Default::default() };
            let s = sim.frame(co, &st, 1.0 / 60.0, 1280.0, 720.0);
            let id = &co.rigs[0].1.moves[sim.lead.mv.unwrap()].id;
            if moves.last() != Some(id) {
                moves.push(id.clone());
            }
            if shots.last() != Some(&s.shot) {
                shots.push(s.shot);
            }
        }
        (moves, shots)
    }

    #[test]
    fn the_hands_keep_moves_out_ask_for_one_and_lean_the_framings() {
        let Some(co) = company() else { return };
        let plain = wo_show::state::ShowMacros::default();
        let (before, shots) = danced(&co, &plain, 12);
        assert!(before.len() > 3 && shots.len() > 1, "{before:?} {shots:?}");
        // the moves danced, off: none of them again
        let off = wo_show::state::ShowMacros { moves_off: before.clone(), ..Default::default() };
        let (after, _) = danced(&co, &off, 12);
        assert!(after.iter().all(|m| !before.contains(m)), "{before:?} then {after:?}");
        // a solo move asked for: the lead dances it at the next slot
        let asked = co.rigs[0].1.moves.iter().find(|m| m.duo.is_none() && !before.contains(&m.id)).unwrap().id.clone();
        let ask = wo_show::state::ShowMacros { audition: Some(asked.clone()), audition_n: 1, ..Default::default() };
        let (moves, _) = danced(&co, &ask, 2);
        assert!(moves.contains(&asked), "{asked} in {moves:?}");
        assert_eq!(moves.iter().filter(|m| **m == asked).count(), 1, "danced once for one asking: {moves:?}");
        // the close framing alone
        let levels = ["front", "medium", "wide", "extremeLow", "extremeHigh", "extremeFront", "fisheye", "fisheyeLow", "full"].iter().map(|s| (s.to_string(), 0.0)).collect();
        let close = wo_show::state::ShowMacros { shots: levels, ..Default::default() };
        let (_, shots) = danced(&co, &close, 6);
        assert_eq!(shots, vec![Shot::Close], "close alone");
    }

    #[test]
    fn steps_land_on_the_beat_at_any_tempo() {
        let Some(co) = company() else { return };
        for bpm in [96.0, 124.0, 174.0] {
            let mut sim = DanceSim { forced_troupe: Some(Troupe::Solo), ..Default::default() };
            let mut st = ShowState { a: deck(40.0, "verse"), dt: 1.0 / 60.0, ..Default::default() };
            st.a.bpm = Some(bpm);
            sim.frame(&co, &st, 1.0 / 60.0, 1280.0, 720.0);
            let m = sim.lead.mv.unwrap();
            let r = clock::rate(bpm, co.rigs[0].1.moves[m].bpm, false);
            // the track's beat moves at the move's rate per record beat
            let (b0, b1) = (sim.lead.beat_of(40.0), sim.lead.beat_of(41.0));
            assert!((b1 - b0 - r).abs() < 1e-9, "{bpm}: {r}");
        }
    }
}
