//! The show's own document (v1: show_store.dart, show_pool.dart, show_snapshots.dart):
//! show.json — the pool (the plan, the effects' settings, the director's temper, the
//! treatments' knobs, the finish…), the favourites, the taste, the sets.
//!
//! While v1 and v2 share the file, the whole document is kept as it was read: what v2 reads
//! it reads through typed views, what it changes it writes into that one place, and
//! everything else (the 3D text's spec, the panel, the dancers' switches, whatever v1 adds)
//! goes back out untouched.
use serde_json::{Map, Value};

use crate::faves::ShowFave;
use crate::json::{Named, f, num, obj};
use crate::plan::ShowPlan;
use crate::rig::{Quantise, RigFinish, TransformSet};
use crate::taste::{Skips, skips_from_json, skips_to_json};

/// The datamosh's share of the changes as shipped.
pub const DEFAULT_MOSH: f64 = 0.35;

/// What a set holds: the pool's setup (v1: ShowSetup).
pub const SETUP_KEYS: &[&str] = &["plan", "transform", "bias", "mosh", "darkBeat", "tune", "finish", "strength"];

/// A set: the show as the hands set it up, named (`l:…` this device's, `s:<id>` shared).
#[derive(Clone, Debug, PartialEq)]
pub struct ShowSnapshot {
    pub id: String,
    pub name: String,
    /// The setup as kept (setup keys only).
    pub setup: Map<String, Value>,
    pub rev: i64,
    pub owner: Option<String>,
    pub mine: bool,
    /// A shared one's last saver (as the house says; not kept in show.json).
    pub updated_by: Option<String>,
}

impl ShowSnapshot {
    pub fn shared(&self) -> bool {
        self.id.starts_with("s:")
    }

    pub fn from_json(j: &Value) -> Option<ShowSnapshot> {
        let j = j.as_object()?;
        Some(ShowSnapshot {
            id: j.get("id")?.as_str()?.to_owned(),
            name: j.get("name")?.as_str()?.to_owned(),
            setup: obj(j.get("setup")).cloned().unwrap_or_default(),
            rev: j.get("rev").and_then(Value::as_i64).unwrap_or(0),
            owner: j.get("owner").and_then(Value::as_str).map(str::to_owned),
            mine: j.get("mine") != Some(&Value::Bool(false)),
            updated_by: None,
        })
    }

    /// A shared one as the house lists it (`id` a number there, `s:<id>` here; its setup in
    /// `doc`).
    pub fn from_server(j: &Value) -> Option<ShowSnapshot> {
        let o = j.as_object()?;
        let id = o.get("id")?.as_i64()?;
        Some(ShowSnapshot {
            id: format!("s:{id}"),
            name: o.get("name").and_then(Value::as_str).unwrap_or_default().to_owned(),
            setup: o.get("doc").and_then(|d| obj(d.get("setup"))).cloned().unwrap_or_default(),
            rev: o.get("rev").and_then(Value::as_i64).unwrap_or(0),
            owner: o.get("owner").and_then(Value::as_str).map(str::to_owned),
            mine: o.get("mine") == Some(&Value::Bool(true)),
            updated_by: o.get("updated_by").and_then(Value::as_str).map(str::to_owned),
        })
    }

    /// Its number at the house, where it is shared.
    pub fn server_id(&self) -> Option<i64> {
        self.id.strip_prefix("s:")?.parse().ok()
    }

    /// What the house keeps of it.
    pub fn doc(&self) -> Value {
        let mut m = Map::new();
        m.insert("setup".into(), Value::Object(self.setup.clone()));
        Value::Object(m)
    }

    pub fn to_json(&self) -> Value {
        let mut m = Map::new();
        m.insert("id".into(), self.id.clone().into());
        m.insert("name".into(), self.name.clone().into());
        m.insert("setup".into(), Value::Object(self.setup.clone()));
        if self.rev != 0 {
            m.insert("rev".into(), self.rev.into());
        }
        if let Some(o) = &self.owner {
            m.insert("owner".into(), o.clone().into());
        }
        if !self.mine {
            m.insert("mine".into(), false.into());
        }
        Value::Object(m)
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct ShowDoc {
    raw: Map<String, Value>,
}

impl Default for ShowDoc {
    fn default() -> Self {
        let mut raw = Map::new();
        raw.insert("v".into(), 1.into());
        raw.insert("pool".into(), Value::Object(Map::new()));
        ShowDoc { raw }
    }
}

impl ShowDoc {
    pub fn parse(text: &str) -> Option<ShowDoc> {
        let v: Value = serde_json::from_str(text).ok()?;
        Some(ShowDoc::from_value(v))
    }

    pub fn from_value(v: Value) -> ShowDoc {
        match v {
            Value::Object(mut raw) => {
                if !raw.get("pool").is_some_and(Value::is_object) {
                    raw.insert("pool".into(), Value::Object(Map::new()));
                }
                ShowDoc { raw }
            }
            _ => ShowDoc::default(),
        }
    }

    /// The document as it goes back to disk.
    pub fn to_value(&self) -> Value {
        Value::Object(self.raw.clone())
    }

    pub fn to_string_pretty(&self) -> String {
        serde_json::to_string(&self.to_value()).unwrap()
    }

    fn pool(&self) -> &Map<String, Value> {
        self.raw.get("pool").and_then(Value::as_object).expect("a pool")
    }

    fn pool_mut(&mut self) -> &mut Map<String, Value> {
        self.raw.get_mut("pool").and_then(Value::as_object_mut).expect("a pool")
    }

    fn put(&mut self, key: &str, v: Option<Value>) {
        let p = self.pool_mut();
        match v {
            Some(v) => {
                p.insert(key.into(), v);
            }
            None => {
                p.remove(key);
            }
        }
    }

    // ---------------------------------------------------------------- the pool

    pub fn plan(&self) -> ShowPlan {
        ShowPlan::from_json(self.pool().get("plan"))
    }

    pub fn set_plan(&mut self, p: &ShowPlan) {
        let j = p.to_json();
        let empty = j.as_object().is_some_and(Map::is_empty);
        self.put("plan", (!empty).then_some(j));
    }

    pub fn transform(&self) -> TransformSet {
        TransformSet::from_json(self.pool().get("transform"))
    }

    pub fn set_transform(&mut self, t: &TransformSet) {
        self.put("transform", (*t != TransformSet::default()).then(|| t.to_json()));
    }

    /// How many of the changes are datamoshes, 0..1.
    pub fn mosh(&self) -> f64 {
        self.pool().get("mosh").and_then(Value::as_f64).map(|m| m.clamp(0.0, 1.0)).unwrap_or(DEFAULT_MOSH)
    }

    pub fn set_mosh(&mut self, m: f64) {
        self.put("mosh", (m != DEFAULT_MOSH).then(|| f(m)));
    }

    /// The director's temper, calm (-1) to busy (+1).
    pub fn bias(&self) -> f64 {
        num(self.pool().get("bias"), 0.0).clamp(-1.0, 1.0)
    }

    pub fn set_bias(&mut self, b: f64) {
        self.put("bias", (b != 0.0).then(|| f(b)));
    }

    pub fn quantise(&self) -> Quantise {
        Quantise::of(self.pool().get("quantise"), Quantise::Bar)
    }

    /// LAND ON, kept (as v1: the bar as shipped, left out).
    pub fn set_quantise(&mut self, q: Quantise) {
        self.put("quantise", (q != Quantise::Bar).then(|| Value::from(q.name())));
    }

    pub fn strength(&self) -> f64 {
        num(self.pool().get("strength"), 1.0)
    }

    pub fn dark_beat(&self) -> bool {
        self.pool().get("darkBeat") == Some(&Value::Bool(true))
    }

    /// The beat before a drop black, or not (as shipped: not, left out).
    pub fn set_dark_beat(&mut self, on: bool) {
        self.put("darkBeat", on.then_some(Value::Bool(true)));
    }

    /// The effects' knobs (the mirrors, the datamosh's grain…), kept.
    pub fn set_tune(&mut self, tune: &std::collections::BTreeMap<String, f64>) {
        self.put("tune", (!tune.is_empty()).then(|| Value::Object(tune.iter().map(|(k, v)| (k.clone(), f(*v))).collect())));
    }

    /// The treatments' knobs, by name.
    pub fn tune(&self) -> std::collections::BTreeMap<String, f64> {
        crate::json::knobs(self.pool().get("tune")).into_iter().collect()
    }

    /// The finish the hands set over every scene, if they did.
    pub fn finish(&self) -> Option<RigFinish> {
        obj(self.pool().get("finish")).map(RigFinish::from_json)
    }

    /// A finish over every scene (kept, and in a set), or None: each scene's own.
    pub fn set_finish(&mut self, fin: Option<&RigFinish>) {
        self.put("finish", fin.map(RigFinish::to_json));
    }

    /// How strong the blend is, 0..1 (as shipped: whole, left out).
    pub fn set_strength(&mut self, s: f64) {
        let s = s.clamp(0.0, 1.0);
        self.put("strength", (s != 1.0).then(|| f(s)));
    }

    /// Who dances (None or "mix": each record its own).
    pub fn dancer(&self) -> Option<String> {
        self.pool().get("dancer").and_then(Value::as_str).map(str::to_owned)
    }

    /// A dancer alone, or None: a mix.
    pub fn set_dancer(&mut self, id: Option<&str>) {
        self.put("dancer", id.filter(|d| *d != "mix").map(Value::from));
    }

    /// What the hands switched off, by key (`dancer.joe`…): v1's pool `off`.
    fn off(&self) -> Vec<String> {
        self.pool().get("off").and_then(Value::as_array).map(|a| a.iter().filter_map(|v| v.as_str().map(str::to_owned)).collect()).unwrap_or_default()
    }

    /// The dancers kept out of the mix, by id.
    pub fn dancers_off(&self) -> Vec<String> {
        self.off().iter().filter_map(|k| k.strip_prefix("dancer.").map(str::to_owned)).collect()
    }

    /// A dancer let into the mix, or kept out of it (one kept out cannot dance alone).
    pub fn set_dancer_on(&mut self, id: &str, on: bool) {
        self.set_on(&format!("dancer.{id}"), on);
        if !on && self.dancer().as_deref() == Some(id) {
            self.set_dancer(None);
        }
    }

    fn set_on(&mut self, key: &str, on: bool) {
        let mut off: Vec<String> = self.off().into_iter().filter(|k| k != key).collect();
        if !on {
            off.push(key.into());
        }
        off.sort();
        self.put("off", (!off.is_empty()).then(|| Value::Array(off.into_iter().map(Value::from).collect())));
    }

    /// The moves kept out of the dancing, by id (v1's pool `off`: `move.long22`).
    pub fn moves_off(&self) -> Vec<String> {
        self.off().iter().filter_map(|k| k.strip_prefix("move.").map(str::to_owned)).collect()
    }

    pub fn set_move_on(&mut self, id: &str, on: bool) {
        self.set_on(&format!("move.{id}"), on);
    }

    /// The pool's leanings, by key (v1's `lean`: a starred move is 2).
    fn lean(&self) -> std::collections::BTreeMap<String, f64> {
        crate::json::knobs(self.pool().get("lean")).into_iter().collect()
    }

    /// The moves starred: danced more (v1: a lean over 1.5).
    pub fn move_stars(&self) -> Vec<String> {
        self.lean().into_iter().filter(|(_, v)| *v > 1.5).filter_map(|(k, _)| k.strip_prefix("move.").map(str::to_owned)).collect()
    }

    pub fn set_move_star(&mut self, id: &str, star: bool) {
        let mut lean = self.lean();
        let key = format!("move.{id}");
        if star {
            lean.insert(key, 2.0);
        } else {
            lean.remove(&key);
        }
        self.put("lean", (!lean.is_empty()).then(|| Value::Object(lean.into_iter().map(|(k, v)| (k, f(v))).collect())));
    }

    // ---------------------------------------------------------------- favourites, taste

    /// Newest first.
    pub fn faves(&self) -> Vec<ShowFave> {
        self.raw.get("faves").and_then(Value::as_array).map(|a| a.iter().filter_map(ShowFave::from_json).collect()).unwrap_or_default()
    }

    pub fn set_faves(&mut self, faves: &[ShowFave]) {
        if faves.is_empty() {
            self.raw.remove("faves");
        } else {
            self.raw.insert("faves".into(), Value::Array(faves.iter().map(ShowFave::to_json).collect()));
        }
    }

    /// A favourite kept: newest first, any with its id before replaced.
    pub fn keep_fave(&mut self, fave: ShowFave) {
        let mut all = vec![fave.clone()];
        all.extend(self.faves().into_iter().filter(|o| o.id != fave.id));
        self.set_faves(&all);
    }

    pub fn taste(&self) -> Skips {
        skips_from_json(self.raw.get("taste"))
    }

    pub fn set_taste(&mut self, s: &Skips) {
        if s.is_empty() {
            self.raw.remove("taste");
        } else {
            self.raw.insert("taste".into(), skips_to_json(s));
        }
    }

    // ---------------------------------------------------------------- sets

    /// This device's sets.
    pub fn snapshots(&self) -> Vec<ShowSnapshot> {
        self.raw.get("snapshots").and_then(Value::as_array).map(|a| a.iter().filter_map(ShowSnapshot::from_json).collect()).unwrap_or_default()
    }

    /// The set last put on or saved as.
    pub fn snapshot(&self) -> Option<ShowSnapshot> {
        self.raw.get("snapshot").and_then(ShowSnapshot::from_json)
    }

    /// The pool's setup as a set holds it.
    pub fn setup(&self) -> Map<String, Value> {
        self.pool().iter().filter(|(k, _)| SETUP_KEYS.contains(&k.as_str())).map(|(k, v)| (k.clone(), v.clone())).collect()
    }

    /// A set put on: its setup into the pool (what it does not say, as shipped), and it the
    /// one on.
    pub fn use_set(&mut self, s: &ShowSnapshot) {
        for k in SETUP_KEYS {
            let v = s.setup.get(*k).cloned();
            self.put(k, v);
        }
        self.raw.insert("snapshot".into(), s.to_json());
    }

    /// No set: the show as shipped.
    pub fn use_shipped(&mut self) {
        for k in SETUP_KEYS {
            self.put(k, None);
        }
        self.raw.remove("snapshot");
    }

    /// The show as it is, kept as a new set of this device's, and it the one on.
    pub fn save_as(&mut self, name: &str, id: &str) -> ShowSnapshot {
        let s = ShowSnapshot { id: id.into(), name: name.trim().into(), setup: self.setup(), rev: 0, owner: None, mine: true, updated_by: None };
        let mut all: Vec<Value> = self.snapshots().iter().map(ShowSnapshot::to_json).collect();
        all.push(s.to_json());
        self.raw.insert("snapshots".into(), Value::Array(all));
        self.raw.insert("snapshot".into(), s.to_json());
        s
    }

    /// Whether the show changed since the set on was put on (with none on: since as
    /// shipped).
    pub fn changed_since_set(&self) -> bool {
        match self.snapshot() {
            Some(s) => s.setup != self.setup(),
            None => !self.setup().is_empty(),
        }
    }

    fn put_snapshots(&mut self, all: &[ShowSnapshot]) {
        self.raw.insert("snapshots".into(), Value::Array(all.iter().map(ShowSnapshot::to_json).collect()));
    }

    /// `s` the one on, as it is (its setup not put into the pool): a shared one after it was
    /// saved or followed.
    pub fn take(&mut self, s: &ShowSnapshot) {
        self.raw.insert("snapshot".into(), s.to_json());
    }

    /// The show as it is over the set on, kept here (a shared one is the house's to save).
    pub fn save_set(&mut self) -> Option<ShowSnapshot> {
        let on = self.snapshot().filter(|s| !s.shared())?;
        let next = ShowSnapshot { setup: self.setup(), ..on };
        let all: Vec<ShowSnapshot> = self.snapshots().into_iter().map(|k| if k.id == next.id { next.clone() } else { k }).collect();
        self.put_snapshots(&all);
        self.take(&next);
        Some(next)
    }

    /// One kept here renamed.
    pub fn rename_set(&mut self, id: &str, name: &str) {
        let name = name.trim();
        if name.is_empty() {
            return;
        }
        let all: Vec<ShowSnapshot> = self.snapshots().into_iter().map(|k| if k.id == id { ShowSnapshot { name: name.into(), ..k } } else { k }).collect();
        self.put_snapshots(&all);
        if let Some(on) = self.snapshot().filter(|s| s.id == id) {
            self.take(&ShowSnapshot { name: name.into(), ..on });
        }
    }

    /// One kept here forgotten (the show stays as it is; with it on, none is).
    pub fn forget_set(&mut self, id: &str) {
        let all: Vec<ShowSnapshot> = self.snapshots().into_iter().filter(|k| k.id != id).collect();
        self.put_snapshots(&all);
        if self.snapshot().is_some_and(|s| s.id == id) {
            self.raw.remove("snapshot");
        }
    }

    /// One kept here put on the house: no longer kept here, the shared one on in its place.
    pub fn shared_set(&mut self, was: &str, shared: &ShowSnapshot) {
        let on = self.snapshot().is_some_and(|s| s.id == was);
        self.forget_set(was);
        if on {
            self.take(shared);
        }
    }

    /// A shared one taken off the house: kept here as `here`.
    pub fn unshared_set(&mut self, was: &str, here: &ShowSnapshot) {
        let mut all = self.snapshots();
        all.push(here.clone());
        self.put_snapshots(&all);
        if self.snapshot().is_some_and(|s| s.id == was) {
            self.take(here);
        }
    }

    // ---------------------------------------------------------------- the favourites, by hand

    fn edit_fave(&mut self, id: &str, f: impl Fn(ShowFave) -> ShowFave) {
        let all: Vec<ShowFave> = self.faves().into_iter().map(|x| if x.id == id { f(x) } else { x }).collect();
        self.set_faves(&all);
    }

    /// One rated (0: not rated).
    pub fn rate_fave(&mut self, id: &str, stars: u8) {
        self.edit_fave(id, |x| ShowFave { stars: stars.min(5), ..x });
    }

    pub fn rename_fave(&mut self, id: &str, name: &str) {
        self.edit_fave(id, |x| ShowFave { name: name.trim().into(), ..x });
    }

    pub fn forget_fave(&mut self, id: &str) {
        let all: Vec<ShowFave> = self.faves().into_iter().filter(|x| x.id != id).collect();
        self.set_faves(&all);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::plan::PlanAxis;

    #[test]
    fn land_on_and_who_dances_are_kept_as_v1_keeps_them() {
        let mut d = ShowDoc::parse(r#"{"v":1,"pool":{"off":["scene.flock"],"dancer":"joe"}}"#).unwrap();
        assert_eq!(d.quantise(), Quantise::Bar);
        d.set_quantise(Quantise::Phrase);
        assert_eq!(d.to_value()["pool"]["quantise"], "phrase");
        d.set_quantise(Quantise::Bar);
        assert!(d.to_value()["pool"].get("quantise").is_none(), "the bar as shipped: left out");
        assert_eq!(d.dancer().as_deref(), Some("joe"));
        d.set_dancer_on("joe", false);
        assert_eq!(d.dancers_off(), vec!["joe".to_owned()]);
        assert_eq!(d.dancer(), None, "one kept out cannot dance alone");
        assert_eq!(d.to_value()["pool"]["off"], serde_json::json!(["dancer.joe", "scene.flock"]), "v1's other switches untouched");
        d.set_dancer_on("joe", true);
        d.set_dancer(Some("chris"));
        assert!(d.dancers_off().is_empty());
        assert_eq!(d.dancer().as_deref(), Some("chris"));
        d.set_dancer(Some("mix"));
        assert_eq!(d.dancer(), None);
    }

    #[test]
    fn the_moves_off_and_starred_and_the_finish_are_kept_as_v1_keeps_them() {
        let mut d = ShowDoc::parse(r#"{"v":1,"pool":{"off":["dancer.joe"],"lean":{"scene.flash":0.5}}}"#).unwrap();
        d.set_move_on("long22", false);
        d.set_move_star("hop3", true);
        assert_eq!(d.moves_off(), vec!["long22".to_owned()]);
        assert_eq!(d.move_stars(), vec!["hop3".to_owned()]);
        assert_eq!(d.dancers_off(), vec!["joe".to_owned()], "the dancers' switches untouched");
        let v = d.to_value();
        assert_eq!(v["pool"]["off"], serde_json::json!(["dancer.joe", "move.long22"]));
        assert_eq!(v["pool"]["lean"]["move.hop3"], 2.0);
        assert_eq!(v["pool"]["lean"]["scene.flash"], 0.5, "v1's other leanings untouched");
        d.set_move_on("long22", true);
        d.set_move_star("hop3", false);
        assert!(d.moves_off().is_empty() && d.move_stars().is_empty());
        // the finish over every scene, and back to each scene's own
        assert_eq!(d.finish(), None);
        let fin = RigFinish { trails: 0.4, grain: 0.0, ..Default::default() };
        d.set_finish(Some(&fin));
        assert_eq!(d.finish(), Some(fin));
        assert!(d.setup().contains_key("finish"), "in a set");
        d.set_finish(None);
        assert_eq!(d.finish(), None);
        d.set_strength(0.4);
        assert_eq!(d.strength(), 0.4);
        d.set_strength(1.0);
        assert!(d.to_value()["pool"].get("strength").is_none(), "whole as shipped: left out");
    }

    #[test]
    fn sets_are_saved_renamed_forgotten_shared_and_faves_rated() {
        let mut d = ShowDoc::default();
        assert!(!d.changed_since_set(), "as shipped");
        d.set_bias(0.5);
        assert!(d.changed_since_set(), "none on: other than as shipped");
        let club = d.save_as("Club", "l:1");
        assert!(!d.changed_since_set());
        d.set_mosh(0.2);
        assert!(d.changed_since_set());
        let saved = d.save_set().unwrap();
        assert_eq!(saved.setup.get("mosh").and_then(Value::as_f64), Some(0.2));
        assert!(!d.changed_since_set() && d.snapshots()[0].setup == saved.setup);
        d.rename_set(&club.id, "  Club night ");
        assert_eq!((d.snapshots()[0].name.as_str(), d.snapshot().unwrap().name.as_str()), ("Club night", "Club night"));
        // shared: the house's own takes its place; taken back: kept here again
        let j = serde_json::json!({"id": 7, "name": "Club night", "doc": saved.doc(), "rev": 1, "owner": "joe", "mine": true, "updated_by": "joe"});
        let shared = ShowSnapshot::from_server(&j).unwrap();
        assert_eq!((shared.id.as_str(), shared.server_id(), shared.rev, shared.setup.clone()), ("s:7", Some(7), 1, saved.setup.clone()));
        d.shared_set(&club.id, &shared);
        assert!(d.snapshots().is_empty() && d.snapshot().unwrap().id == "s:7");
        assert!(d.save_set().is_none(), "a shared one is the house's to save");
        let here = ShowSnapshot { id: "l:2".into(), rev: 0, owner: None, updated_by: None, ..shared.clone() };
        d.unshared_set("s:7", &here);
        assert_eq!(d.snapshot().unwrap().id, "l:2");
        d.forget_set("l:2");
        assert!(d.snapshots().is_empty() && d.snapshot().is_none());
        // favourites: rated, named, forgotten
        let c = crate::combos::Combo::new("black", "kinetic", "raw");
        d.keep_fave(ShowFave { id: "a".into(), at: "2026-11-07T10:00:00Z".into(), combo: c.clone(), milk: None, shot: None, type3d: None, stars: 0, name: String::new() });
        d.keep_fave(ShowFave { id: "b".into(), at: "2026-11-07T11:00:00Z".into(), combo: c, milk: None, shot: None, type3d: None, stars: 0, name: String::new() });
        d.rate_fave("a", 4);
        d.rename_fave("b", " The hexagons ");
        let f = d.faves();
        assert_eq!((f[0].id.as_str(), f[0].name.as_str(), f[1].stars), ("b", "The hexagons", 4));
        d.forget_fave("a");
        assert_eq!(d.faves().len(), 1);
    }

    #[test]
    fn what_v2_does_not_read_goes_back_out_untouched() {
        let text = r#"{"v":1,"pool":{"plan":{"levels":{"ground":{"milk":2.0}}},"type3d":{"lines":["HELLO"],"size":0.7},"tier":"high","mosh":0.5},"panel":{"tab":"rotation"},"taste":{"a|b|c|none|normal":2.0}}"#;
        let mut d = ShowDoc::parse(text).unwrap();
        assert_eq!(d.plan().shared(PlanAxis::Ground, "milk"), 2.0);
        assert_eq!(d.mosh(), 0.5);
        d.set_plan(&d.plan().with_shared(PlanAxis::Ground, "milk", Some(4.0), false, None));
        let back = d.to_value();
        assert_eq!(back["pool"]["type3d"]["lines"][0], "HELLO");
        assert_eq!(back["pool"]["tier"], "high");
        assert_eq!(back["panel"]["tab"], "rotation");
        assert_eq!(back["pool"]["plan"]["levels"]["ground"]["milk"], 4.0);
        d.set_plan(&ShowPlan::default());
        assert!(d.to_value()["pool"].get("plan").is_none(), "as shipped: left out");
    }

    #[test]
    fn a_set_saved_then_put_on_again_after_changes() {
        let mut d = ShowDoc::default();
        d.set_mosh(0.6);
        let s = d.save_as(" Club ", "l:1");
        assert_eq!(s.name, "Club");
        assert!(!d.changed_since_set());
        d.set_mosh(0.1);
        assert!(d.changed_since_set());
        d.use_set(&s);
        assert_eq!(d.mosh(), 0.6);
        d.use_shipped();
        assert_eq!(d.mosh(), DEFAULT_MOSH);
        assert!(d.snapshot().is_none());
        assert_eq!(d.snapshots().len(), 1);
    }

    #[test]
    fn this_desks_own_show_json_reads() {
        // read-only: the user's show.json, where there is one on this machine
        let Some(home) = std::env::var_os("HOME") else { return };
        let path = std::path::Path::new(&home).join(".local/share/io.wetowl.muse/show.json");
        let Ok(text) = std::fs::read_to_string(&path) else { return };
        let d = ShowDoc::parse(&text).expect("show.json");
        let raw: Value = serde_json::from_str(&text).unwrap();
        assert_eq!(d.to_value(), raw, "read and written back unchanged");
        let p = d.plan();
        // the plan v2 reads writes back as v1 wrote it
        if let Some(j) = raw["pool"].get("plan") {
            assert_eq!(&p.to_json(), j, "the plan, byte for byte");
        }
        assert_eq!(d.faves().len(), raw.get("faves").and_then(Value::as_array).map_or(0, Vec::len), "every favourite read");
    }
}
