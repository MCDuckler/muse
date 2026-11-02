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
        })
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

    pub fn strength(&self) -> f64 {
        num(self.pool().get("strength"), 1.0)
    }

    pub fn dark_beat(&self) -> bool {
        self.pool().get("darkBeat") == Some(&Value::Bool(true))
    }

    /// The treatments' knobs, by name.
    pub fn tune(&self) -> std::collections::BTreeMap<String, f64> {
        crate::json::knobs(self.pool().get("tune")).into_iter().collect()
    }

    /// The finish the hands set over every scene, if they did.
    pub fn finish(&self) -> Option<RigFinish> {
        obj(self.pool().get("finish")).map(RigFinish::from_json)
    }

    /// Who dances (None or "mix": each record its own).
    pub fn dancer(&self) -> Option<String> {
        self.pool().get("dancer").and_then(Value::as_str).map(str::to_owned)
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
        let s = ShowSnapshot { id: id.into(), name: name.trim().into(), setup: self.setup(), rev: 0, owner: None, mine: true };
        let mut all: Vec<Value> = self.snapshots().iter().map(ShowSnapshot::to_json).collect();
        all.push(s.to_json());
        self.raw.insert("snapshots".into(), Value::Array(all));
        self.raw.insert("snapshot".into(), s.to_json());
        s
    }

    /// Whether the show changed since the set on was put on.
    pub fn changed_since_set(&self) -> bool {
        self.snapshot().is_some_and(|s| s.setup != self.setup())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::plan::PlanAxis;

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
