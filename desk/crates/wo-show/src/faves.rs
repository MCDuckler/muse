//! The favourites (v1: show_faves.dart): what was on the stage at a moment, kept as it was —
//! the combination, the MilkDrop preset under it, the camera's framing, the 3D text as it was —
//! rated one to five stars. Kept in show.json newest first, each one's picture beside it.
use serde_json::Value;

use crate::combos::Combo;
use crate::json::Obj;
use crate::rig::Figure;

#[derive(Clone, Debug, PartialEq)]
pub struct ShowFave {
    pub id: String,
    /// When, as v1 wrote it (ISO 8601, UTC).
    pub at: String,
    pub combo: Combo,
    /// The MilkDrop preset on (its full name).
    pub milk: Option<String>,
    /// The figure's framing as `figure.shot`.
    pub shot: Option<String>,
    /// The 3D text as it was (kept whole until the 3D text is the stage's: P8).
    pub type3d: Option<Value>,
    /// 0 (not rated) to 5.
    pub stars: u8,
    pub name: String,
}

impl ShowFave {
    pub fn to_json(&self) -> Value {
        let mut m = Obj::new();
        m.insert("id".into(), self.id.clone().into());
        m.insert("at".into(), self.at.clone().into());
        m.insert("c".into(), self.combo.key().into());
        if let Some(x) = &self.milk {
            m.insert("milk".into(), x.clone().into());
        }
        if let Some(x) = &self.shot {
            m.insert("shot".into(), x.clone().into());
        }
        if let Some(x) = &self.type3d {
            m.insert("type3d".into(), x.clone());
        }
        if self.stars > 0 {
            m.insert("stars".into(), self.stars.into());
        }
        if !self.name.is_empty() {
            m.insert("name".into(), self.name.clone().into());
        }
        Value::Object(m)
    }

    pub fn from_json(j: &Value) -> Option<ShowFave> {
        let j = j.as_object()?;
        let id = j.get("id")?.as_str()?.to_owned();
        let combo = Combo::from_key(j.get("c")?.as_str()?)?;
        Some(ShowFave {
            id,
            at: crate::json::text(j.get("at")).unwrap_or_else(|| "1970-01-01T00:00:00.000Z".into()),
            combo,
            milk: j.get("milk").and_then(Value::as_str).map(str::to_owned),
            shot: j.get("shot").and_then(Value::as_str).map(str::to_owned),
            type3d: j.get("type3d").filter(|v| v.is_object()).cloned(),
            stars: j.get("stars").and_then(Value::as_f64).map(|s| s.clamp(0.0, 5.0) as u8).unwrap_or(0),
            name: j.get("name").and_then(Value::as_str).unwrap_or_default().to_owned(),
        })
    }

    /// A new one's id: the moment, to the millisecond, and a little more (base 36).
    pub fn new_id(epoch_micros: i64) -> String {
        format!("{}{}", radix36((epoch_micros / 1000) as u64), radix36((epoch_micros % 1000) as u64))
    }
}

fn radix36(mut n: u64) -> String {
    if n == 0 {
        return "0".into();
    }
    let d = b"0123456789abcdefghijklmnopqrstuvwxyz";
    let mut s = vec![];
    while n > 0 {
        s.push(d[(n % 36) as usize]);
        n /= 36;
    }
    s.reverse();
    String::from_utf8(s).unwrap()
}

/// The figures whose framing a favourite keeps: the dancers' and the birds'.
pub fn has_camera(f: Figure) -> bool {
    matches!(f, Figure::Dancers | Figure::Birds)
}
