//! v1's ShowEngine.tick, cut in two (plan §2.1): the Desk decides, the stage draws.
//!
//! - [Direct] runs in the Desk: from the decks (the records' facts at the ear's positions) it
//!   works out the moments, lets the director pick the scene and combination, puts the hands
//!   over the look (the effect, the finish, the blend's strength), and says it as a [Cue] —
//!   sent to every stage when it changes (with the change's progress every frame).
//! - [Play] runs in the stage: from the same decks, the room's sound as heard and the Cue, it
//!   makes each frame — the record's genome, the palette eased towards the record's, the
//!   dynamics, the hit fading — whose flat numbers the shaders read (state::common_block).
use crate::combos::Fx;
use crate::deck::{Flat, ShowAudio, ShowDeck};
use crate::director::Director;
use crate::doc::ShowDoc;
use crate::events::{EventKind, ShowEvent, events_between};
use crate::rig::{Look, ShowRig};
use crate::scenes::SceneBook;
use crate::state::{Dynamics, Genome, ShowMacros, ShowMix, ShowPalette, ShowState, palette_for};

/// How long the palette takes to come round to a new record's (seconds).
pub const PALETTE_EASE: f64 = 2.0;
/// How long a hit takes to fade (seconds).
pub const HIT_FADE: f64 = 0.35;

/// What the Desk tells the stages of the show.
#[derive(Clone, Debug, PartialEq)]
pub struct Cue {
    /// The look on (its id), and as layers with the hands over it.
    pub scene: Option<String>,
    pub rig: ShowRig,
    /// The look being left, and how far across to the one on (1: none).
    pub from: Option<String>,
    pub rig_from: Option<ShowRig>,
    pub k: f64,
    /// The datamoshes so far (the stage moshes when this goes up).
    pub mosh: i64,
    /// The hands (and the director's hits): blackout, strobe, freeze, intensity, colour…
    pub macros: ShowMacros,
    /// Why the scene on is on, in words.
    pub why: String,
    /// The MilkDrop preset on (where the stage draws MilkDrop).
    pub milk: crate::milk::MilkCue,
}

impl Cue {
    /// As the wire carries it: the rigs in v1's JSON, each with its transformation even where
    /// none is on (v1 leaves an idle one out, and reads it back as the defaults).
    pub fn to_json(&self) -> serde_json::Value {
        let rig = |r: &ShowRig| {
            let mut j = r.to_json();
            j["transform"] = r.transform.to_json();
            j
        };
        serde_json::json!({
            "scene": self.scene,
            "rig": rig(&self.rig),
            "from": self.from,
            "rigFrom": self.rig_from.as_ref().map(rig),
            "k": self.k,
            "mosh": self.mosh,
            "macros": serde_json::to_value(&self.macros).unwrap_or_default(),
            "why": self.why,
            "milk": serde_json::to_value(&self.milk).unwrap_or_default(),
        })
    }

    pub fn from_json(j: &serde_json::Value) -> Cue {
        let s = |k: &str| j.get(k).and_then(serde_json::Value::as_str).map(str::to_owned);
        let rig = |k: &str| j.get(k).and_then(serde_json::Value::as_object).map(ShowRig::from_json);
        Cue {
            scene: s("scene"),
            rig: rig("rig").unwrap_or_default(),
            from: s("from"),
            rig_from: rig("rigFrom"),
            k: j.get("k").and_then(serde_json::Value::as_f64).unwrap_or(1.0),
            mosh: j.get("mosh").and_then(serde_json::Value::as_i64).unwrap_or(0),
            macros: j.get("macros").and_then(|m| serde_json::from_value(m.clone()).ok()).unwrap_or_default(),
            why: s("why").unwrap_or_default(),
            milk: j.get("milk").and_then(|m| serde_json::from_value(m.clone()).ok()).unwrap_or_default(),
        }
    }
}

impl Default for Cue {
    fn default() -> Self {
        Cue { scene: None, rig: ShowRig::default(), from: None, rig_from: None, k: 1.0, mosh: 0, macros: ShowMacros::default(), why: String::new(), milk: Default::default() }
    }
}

/// The room as the Desk hears it this frame: the two decks, what is heard, the mix.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Room {
    pub a: ShowDeck,
    pub b: ShowDeck,
    pub audio: ShowAudio,
    pub mix: ShowMix,
}

/// Which deck has the room: the louder playing one, kept until the other is clearly louder.
pub fn master_of(current: &str, a: &ShowDeck, b: &ShowDeck) -> String {
    let (cur, oth) = if current == "B" { (b, a) } else { (a, b) };
    let loud = |d: &ShowDeck| if d.playing { d.channel.level } else { 0.0 };
    if loud(oth) > loud(cur) + 0.2 || (loud(cur) == 0.0 && loud(oth) > 0.0) { oth.name.clone() } else { cur.name.clone() }
}

/// The Desk's half: the decisions.
pub struct Direct {
    pub director: Director,
    pub looks: std::collections::BTreeMap<String, Look>,
    pub doc: ShowDoc,
    /// An effect the hands hold over whatever the combination says.
    pub held_fx: Option<Fx>,
    pub macros: ShowMacros,
    /// MilkDrop's director, where the Desk has a library of presets.
    pub milk: Option<crate::milk::MilkDirector>,
    master: String,
    prev: Option<ShowState>,
    hit_at: Option<f64>,
    clock: f64,
    last: Cue,
}

impl Direct {
    /// The director over `book`'s scenes (the Rust stage's), the plan and the temper from `doc`.
    pub fn new(book: &SceneBook, doc: ShowDoc, scores: Option<crate::scores::ComboScores>, seed: u64) -> Direct {
        let mut director = Director::new(book.metas(), seed);
        director.kinds = book.kinds();
        director.set_scores(scores);
        director.set_plan(doc.plan());
        director.mosh_share = doc.mosh();
        director.bias = doc.bias();
        Direct { director, looks: book.looks(), doc, held_fx: None, macros: ShowMacros::default(), milk: None, master: "A".into(), prev: None, hit_at: None, clock: 0.0, last: Cue::default() }
    }

    /// The effect on: the hands' held, or the combination's.
    pub fn fx_on(&self) -> Fx {
        self.held_fx.or_else(|| self.director.combo().map(|c| c.fx)).unwrap_or(Fx::None)
    }

    fn hands(&self, r: ShowRig) -> ShowRig {
        let mut out = ShowRig { transform: self.doc.transform().of(self.fx_on()), ..r };
        if let Some(f) = self.doc.finish() {
            out.finish = f;
        }
        let s = self.doc.strength();
        if s != 1.0 {
            out.blend.strength = s;
        }
        out
    }

    /// A hit the hands landed (the stage flashes, fading).
    pub fn hit(&mut self) {
        self.hit_at = Some(self.clock);
    }

    /// The performer's NEXT (`by` 1) and PREVIOUS (-1): the scene beside this one among those
    /// the director may use, cut to.
    pub fn next(&mut self, by: i64) {
        self.director.next(by, crate::director::SceneChange::Cut);
    }

    /// Another scene now, datamoshed into (the hands' MOSH).
    pub fn mosh_next(&mut self) {
        self.director.next(1, crate::director::SceneChange::Mosh);
    }

    /// The scene on held (the director picks no other), or let go.
    pub fn hold(&mut self, on: bool) {
        self.director.locked = on;
    }

    pub fn held(&self) -> bool {
        self.director.locked
    }

    /// One frame, `dt` seconds after the last: the decks as the ear hears them, the room's
    /// sound, the mix, live numbers (`milk.ok`…). The Cue, and the moments it saw.
    pub fn tick(&mut self, dt: f64, room: Room, extra: Flat) -> (Cue, Vec<ShowEvent>) {
        let Room { a, b, audio, mix } = room;
        self.clock += dt.max(0.0);
        self.master = master_of(&self.master, &a, &b);
        // the hit fading from when it landed
        self.macros.hit = self.hit_at.map(|t| (1.0 - (self.clock - t) / HIT_FADE).clamp(0.0, 1.0)).unwrap_or(0.0);
        // the beat before the drop, black (the pool's say)
        let m = if self.master == "B" { &b } else { &a };
        let dark = self.doc.dark_beat() && m.playing && m.drop_beats_away.is_some_and(|w| w > 0.0 && w <= 1.0);
        let state = ShowState { dt, a, b, master_name: self.master.clone(), audio, mix, macros: self.macros.clone(), extra, ..Default::default() };
        let mut said = events_between(self.prev.as_ref(), &state);
        let (scene, from, k) = self.director.direct(&state, &said);
        if self.director.take_hit() {
            self.hit_at = Some(self.clock);
            self.macros.hit = 1.0;
            said.push(ShowEvent::on_master(EventKind::Hit));
        }
        let rig = scene.as_ref().and_then(|s| self.looks.get(s)).map(|l| self.hands(l.in_combo(self.director.combo()))).unwrap_or_default();
        let rig_from = from.as_ref().and_then(|s| self.looks.get(s)).map(|l| self.hands(l.in_combo(self.director.from_combo())));
        let mut macros = self.macros.clone();
        if dark && !macros.blackout {
            macros.blackout = true;
        }
        // MilkDrop's preset, while the stage has MilkDrop to draw
        let mut moshes = self.director.moshes;
        let mut milk_cue = crate::milk::MilkCue::default();
        if let Some(mk) = &mut self.milk {
            if state.num("milk.ok") >= 0.5 {
                mk.frame(&state, &said, scene.as_deref() == Some("milk"));
            }
            moshes += mk.moshes;
            milk_cue = mk.cue().clone();
        }
        let cue = Cue { scene, rig, from, rig_from, k, mosh: moshes, macros, why: self.director.why.clone(), milk: milk_cue };
        self.prev = Some(state);
        self.last = cue.clone();
        (cue, said)
    }

    /// The last Cue said.
    pub fn cue(&self) -> &Cue {
        &self.last
    }
}

/// The stage's half: time into frames.
#[derive(Default)]
pub struct Play {
    dynamics: Dynamics,
    palette: Option<ShowPalette>,
    genome: Genome,
    genome_track: Option<i64>,
    master: String,
}

impl Play {
    /// One frame `dt` seconds after the last, from the decks (the stage carries them on
    /// between the Desk's frames), the room's sound (`heard`: the engine's own measure) and
    /// the Desk's Cue.
    pub fn frame(&mut self, dt: f64, room: Room, cue: &Cue, heard: bool) -> ShowState {
        let Room { a, b, audio, mix } = room;
        self.master = master_of(if self.master.is_empty() { "A" } else { &self.master }, &a, &b);
        let m = if self.master == "B" { &b } else { &a };
        if m.track_id != self.genome_track {
            self.genome_track = m.track_id;
            self.genome = m.track_id.map(|id| Genome::of(id, m.camelot.as_deref(), m.bpm, m.cover_rgb)).unwrap_or_default();
        }
        let apart = (!self.genome.is_empty()).then(|| self.genome.get("palette.apart"));
        let want = palette_for(m.cover_rgb, m.key_hue, m.section.as_deref(), cue.macros.colour + self.genome.get("palette.turn"), apart);
        let ease = if dt <= 0.0 { 1.0 } else { (dt / PALETTE_EASE).clamp(0.0, 1.0) };
        let palette = self.palette.map(|p| p.lerp(&want, ease)).unwrap_or(want);
        self.palette = Some(palette);
        let master = m.clone();
        let dyn_ = self.dynamics.frame(&audio, &master, dt, heard);
        ShowState {
            dt,
            a,
            b,
            master_name: self.master.clone(),
            audio,
            mix,
            palette,
            macros: cue.macros.clone(),
            scene: cue.scene.clone(),
            scene_from: cue.from.clone(),
            scene_k: cue.k,
            mosh: cue.mosh,
            rig: cue.rig.clone(),
            rig_from: cue.rig_from.clone(),
            genome: self.genome.clone(),
            dyn_,
            ..Default::default()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::deck::{Channel, RecordFacts, Section};
    use crate::scenes::IN_SCOPE;
    use crate::state::common_block;

    /// A 128 BPM record of 3 minutes: intro, build, drop, breakdown, drop, outro.
    fn record() -> RecordFacts {
        let period = 60_000.0 / 128.0;
        let beats: Vec<f64> = (0..384).map(|i| i as f64 * period).collect();
        let bar = 4.0 * period;
        let sec = |label: &str, from: f64, to: f64| Section { label: label.into(), start_ms: from * bar, end_ms: to * bar };
        RecordFacts {
            track_id: Some(7),
            beats_ms: beats.clone(),
            steady: Some((0.0, period)),
            downbeats_ms: beats.iter().step_by(4).copied().collect(),
            energy: (0..96).map(|i| if (32..64).contains(&i) || (80..90).contains(&i) { 230 } else { 90 }).collect(),
            drops_ms: vec![32.0 * bar, 80.0 * bar],
            sections: vec![sec("intro", 0.0, 16.0), sec("build", 16.0, 32.0), sec("drop", 32.0, 64.0), sec("breakdown", 64.0, 72.0), sec("build", 72.0, 80.0), sec("drop", 80.0, 90.0), sec("outro", 90.0, 96.0)],
            camelot: Some("8A".into()),
            ..Default::default()
        }
    }

    #[test]
    fn a_record_played_through_the_desk_decides_and_the_stage_draws() {
        let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../app/assets/show/scenes");
        let book = crate::scenes::SceneBook::from_dir(&dir).only(IN_SCOPE);
        let mut direct = Direct::new(&book, ShowDoc::default(), None, 3);
        let mut play = Play::default();
        let r = record();
        let dt = 1.0 / 30.0;
        let mut scenes_on = std::collections::BTreeSet::new();
        let (mut hits, mut drops) = (0, 0);
        let empty = || ShowDeck { name: "B".into(), ..Default::default() };
        for i in 0..(180 * 30) {
            let ms = i as f64 * dt * 1000.0;
            let a = ShowDeck::derive("A", Some(&r), true, ms, Channel::default(), ShowAudio { low: 0.5, kick: if (ms % 468.75) < 30.0 { 0.9 } else { 0.1 }, ..Default::default() });
            let (cue, said) = direct.tick(dt, Room { a: a.clone(), b: empty(), audio: a.audio, mix: ShowMix::default() }, Flat::new());
            drops += said.iter().filter(|e| e.kind == EventKind::Drop).count();
            hits += said.iter().filter(|e| e.kind == EventKind::Hit).count();
            let scene = cue.scene.clone().expect("always a scene on");
            assert!(IN_SCOPE.contains(&scene.as_str()), "{scene} is not the Rust stage's");
            scenes_on.insert(scene);
            let st = play.frame(dt, Room { a, b: empty(), ..Default::default() }, &cue, true);
            let c = common_block(&st.flat(), [0.5; 4], i as f64 * dt);
            assert!(c.iter().all(|v| v.is_finite()));
        }
        assert_eq!(drops, 2, "the two drops seen");
        assert!(hits <= 2, "a hit at most on each drop");
        assert!(scenes_on.len() >= 3, "a few scenes over three minutes: {scenes_on:?}");
        // the stage's frame follows the Desk's cue and the record
        let a = ShowDeck::derive("A", Some(&r), true, 40_000.0, Channel::default(), ShowAudio::default());
        let st = play.frame(dt, Room { a, b: empty(), ..Default::default() }, direct.cue(), true);
        assert_eq!(st.scene, direct.cue().scene);
        assert!(!st.genome.is_empty(), "the record's genome");
        assert_eq!(st.flat()["master.bar.index"], (40_000.0f64 / 1875.0).floor());
    }

    #[test]
    fn a_cue_goes_over_the_wire_and_back_whole() {
        let book = crate::scenes::SceneBook::shipped().only(IN_SCOPE);
        let mut direct = Direct::new(&book, ShowDoc::default(), None, 5);
        let r = record();
        let a = ShowDeck::derive("A", Some(&r), true, 70_000.0, Channel::default(), ShowAudio { low: 0.6, ..Default::default() });
        direct.macros.strobe = 0.5;
        direct.macros.tune.insert("ascii.cell".into(), 1.2);
        let (cue, _) = direct.tick(1.0 / 60.0, Room { a, b: ShowDeck { name: "B".into(), ..Default::default() }, ..Default::default() }, Flat::new());
        assert!(cue.scene.is_some());
        let back = Cue::from_json(&serde_json::from_str(&cue.to_json().to_string()).unwrap());
        assert_eq!(back, cue);
        // the facts too
        let facts: RecordFacts = serde_json::from_str(&serde_json::to_string(&r).unwrap()).unwrap();
        assert_eq!(facts, r);
    }

    #[test]
    fn the_hands_step_and_hold_the_scenes() {
        let book = crate::scenes::SceneBook::shipped().only(crate::scenes::DRAWN);
        let mut direct = Direct::new(&book, ShowDoc::default(), None, 5);
        let r = record();
        let room = |ms: f64| Room { a: ShowDeck::derive("A", Some(&r), true, ms, Channel::default(), ShowAudio::default()), b: ShowDeck { name: "B".into(), ..Default::default() }, ..Default::default() };
        let (c0, _) = direct.tick(1.0 / 60.0, room(1000.0), Flat::new());
        direct.next(1);
        let (c1, _) = direct.tick(1.0 / 60.0, room(1016.0), Flat::new());
        assert_ne!(c0.scene, c1.scene, "NEXT changed the scene");
        direct.next(-1);
        let (c2, _) = direct.tick(1.0 / 60.0, room(1033.0), Flat::new());
        assert_eq!(c2.scene, c0.scene, "PREVIOUS went back");
        direct.hold(true);
        for i in 0..(60 * 120) {
            let (c, _) = direct.tick(1.0 / 60.0, room(1050.0 + i as f64 * 16.67), Flat::new());
            assert_eq!(c.scene, c0.scene, "held through two minutes");
        }
        let n = direct.director.moshes;
        direct.mosh_next();
        let (c3, _) = direct.tick(1.0 / 60.0, room(200_000.0), Flat::new());
        assert_eq!(c3.mosh, n + 1, "MOSH moshed");
    }

    #[test]
    fn the_louder_deck_has_the_room_and_keeps_it() {
        let on = |name: &str, level: f64| ShowDeck { name: name.into(), playing: true, channel: Channel { level, ..Default::default() }, ..Default::default() };
        assert_eq!(master_of("A", &on("A", 0.6), &on("B", 0.7)), "A", "not clearly louder");
        assert_eq!(master_of("A", &on("A", 0.4), &on("B", 0.7)), "B");
        assert_eq!(master_of("B", &on("A", 0.0), &on("B", 0.0)), "B");
    }
}
