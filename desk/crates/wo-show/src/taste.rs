//! The hands' taste, learnt from what they do (v1: show_taste.dart): a combination skipped
//! with NEXT in its first bars comes less (its kin — same scene, style and background — a
//! little less); a favourite rated three stars or more brings its kind round more often.
use crate::combos::Combo;
use crate::faves::ShowFave;

/// A NEXT within this many bars of a combination coming on says "not this".
pub const SKIP_BARS: u32 = 4;

/// How many combinations' skips are kept; the oldest go first.
pub const KEPT: usize = 400;

/// Skips by combination key, in the order they were last skipped (oldest first).
pub type Skips = Vec<(String, f64)>;

/// `skips` with one more for `c`, the oldest dropped past [KEPT].
pub fn skipped(skips: &Skips, c: &Combo) -> Skips {
    let k = c.key();
    let had = skips.iter().find(|(x, _)| *x == k).map(|(_, v)| *v).unwrap_or(0.0);
    let mut out: Skips = skips.iter().filter(|(x, _)| *x != k).cloned().collect();
    out.push((k, had + 1.0));
    while out.len() > KEPT {
        out.remove(0);
    }
    out
}

fn kin(key: &str) -> String {
    key.split('|').take(3).collect::<Vec<_>>().join("|")
}

/// How much the hands lean on `c`: under 1 for the skipped, over 1 for the kind of their
/// best favourites.
pub fn lean(c: &Combo, skips: &Skips, faves: &[ShowFave]) -> f64 {
    let mut k = 1.0;
    if !skips.is_empty() {
        let key = c.key();
        let own = skips.iter().find(|(x, _)| *x == key).map(|(_, v)| *v).unwrap_or(0.0);
        let kin_of = kin(&key);
        let family: f64 = skips.iter().filter(|(x, _)| *x != key && kin(x) == kin_of).map(|(_, v)| *v).sum();
        k /= 1.0 + own + 0.25 * family;
    }
    let mut lift = 1.0;
    for f in faves {
        if f.stars < 3 || f.combo.scene != c.scene || f.combo.style != c.style {
            continue;
        }
        let more = if f.combo.ground == c.ground { 0.25 } else { 0.1 };
        lift += more * (f.stars as f64 - 2.0);
    }
    k * lift.clamp(1.0, 3.0)
}

/// Skips from show.json's map (v1 keeps insertion order; JSON object order is kept here too).
pub fn skips_from_json(v: Option<&serde_json::Value>) -> Skips {
    v.and_then(serde_json::Value::as_object).map(|m| m.iter().filter_map(|(k, v)| v.as_f64().map(|x| (k.clone(), x))).collect()).unwrap_or_default()
}

pub fn skips_to_json(s: &Skips) -> serde_json::Value {
    serde_json::Value::Object(s.iter().map(|(k, v)| (k.clone(), crate::json::f(*v))).collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_skip_and_its_kin_and_a_favourite() {
        let c = Combo::new("milk", "kinetic", "raw");
        let kin = Combo { mix: crate::combos::Mix::Add, ..c.clone() };
        let s = skipped(&skipped(&vec![], &c), &kin);
        assert!((lean(&c, &s, &[]) - 1.0 / (1.0 + 1.0 + 0.25)).abs() < 1e-9);
        let fave = ShowFave { id: "a".into(), at: "x".into(), combo: c.clone(), milk: None, shot: None, type3d: None, stars: 5, name: String::new() };
        assert!((lean(&c, &vec![], &[fave]) - 1.75).abs() < 1e-9);
        // the oldest go first
        let mut many: Skips = vec![];
        for i in 0..(KEPT + 5) {
            many = skipped(&many, &Combo::new("milk", &format!("s{i}"), "raw"));
        }
        assert_eq!(many.len(), KEPT);
        assert!(many[0].0.contains("|s5|"));
    }
}
