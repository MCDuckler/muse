//! A stick's record matched to the same song in the house, for the show: rekordbox's grid
//! stays the deck's (the CDJ's and the controller's), the house's analysis gives what a
//! stick has not (its sections and drops, each bar's loudness, where it sings), moved onto
//! the stick's time.
//!
//! Found by the `wetowl:<id>` a record's comment carries (the WetOwl app's downloads), else
//! by the house's own search: the title (and the artist's words) the same, the length within
//! three seconds. Lined up by the beat (the grids' tempo the same, the house's beats moved
//! onto the stick's) and then by the bar: the whole-beat shift where the two loudness curves
//! agree best; a match whose curves do not agree is left.
use wo_booth::Timing;
use wo_booth::planner::VocalMap;
use wo_house::House;

use crate::library::{self, Analysed};
use crate::records::Record;

/// Seconds the house's record may differ in length from the stick's.
const LENGTH_SLACK: f64 = 3.0;
/// How alike the two loudness curves must be, lined up (Pearson's r).
const AGREE: f64 = 0.5;

/// The words of a title or name: lower case, letters and digits only.
fn words(s: &str) -> Vec<String> {
    s.split(|c: char| !c.is_alphanumeric()).filter(|w| !w.is_empty()).map(str::to_lowercase).collect()
}

/// The house's id a record's comment names (`wetowl:123`).
fn tagged(comment: &str) -> Option<i64> {
    let at = comment.find("wetowl:")?;
    comment[at + 7..].chars().take_while(char::is_ascii_digit).collect::<String>().parse().ok()
}

/// How well a house record's title and artists answer the stick's, 0..1: the share of the
/// stick's words (its title, and its artist's) the house's have.
pub(crate) fn likeness(stick_title: &str, stick_artist: &str, title: &str, artists: &[String]) -> f64 {
    let theirs: std::collections::HashSet<String> = words(title).into_iter().chain(artists.iter().flat_map(|a| words(a))).collect();
    let t = words(stick_title);
    if t.is_empty() {
        return 0.0;
    }
    let title_share = t.iter().filter(|w| theirs.contains(*w)).count() as f64 / t.len() as f64;
    let a = words(stick_artist);
    let artist_share = if a.is_empty() { 1.0 } else { a.iter().filter(|w| theirs.contains(*w)).count() as f64 / a.len() as f64 };
    // an uploader for the artist (a label, a channel) is common: the title weighs most
    0.75 * title_share + 0.25 * artist_share
}

/// Where the stick's records the house has are kept: `<stick>/<rekordbox id>/<bytes>` → the
/// house's id (each record sent once).
fn kept_file() -> Option<std::path::PathBuf> {
    wo_house::folders::config().map(|d| d.join("wetowl-desk").join("stick-house.json"))
}

fn kept() -> std::collections::HashMap<String, i64> {
    kept_file().and_then(|f| std::fs::read(f).ok()).and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default()
}

fn keep(key: &str, id: i64) {
    let Some(f) = kept_file() else { return };
    let mut all = kept();
    all.insert(key.to_owned(), id);
    if let Some(dir) = f.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    if let Ok(b) = serde_json::to_vec_pretty(&all) {
        let tmp = f.with_extension("json.tmp");
        if std::fs::write(&tmp, b).is_ok() {
            let _ = std::fs::rename(tmp, f);
        }
    }
}

/// The house's record for a stick's, and its analysis (on a worker: asks the house): one
/// sent before, else the same song the house has, else the stick's file sent to it now (it
/// analyses it; the next time it is the one sent before). The stick is only read.
pub(crate) fn find_or_send(house: &House, r: &Record) -> Option<(i64, Analysed)> {
    let crate::records::Audio::Usb { path, .. } = &r.audio else { return find(house, r) };
    let bytes = std::fs::metadata(path).ok()?.len();
    let key = format!("{}/{}", r.id, bytes);
    if let Some(&id) = kept().get(&key)
        && let Ok(a) = library::analyse(house, id)
    {
        return Some((id, a));
    }
    if let Some(found) = find(house, r) {
        keep(&key, found.0);
        return Some(found);
    }
    let t = house.upload(path).map_err(|e| eprintln!("{}: sending it to the house: {e}", r.title)).ok()?;
    keep(&key, t.id);
    library::analyse(house, t.id).ok().map(|a| (t.id, a))
}

/// The house's record for a stick's, and its analysis (on a worker: asks the house).
pub(crate) fn find(house: &House, r: &Record) -> Option<(i64, Analysed)> {
    let id = match tagged(&r.tags.comment) {
        Some(id) => id,
        None => {
            let mut asked = vec![r.title.clone()];
            // "Artist - Title" as one title: the part after the dash on its own as well
            if let Some((_, t)) = r.title.split_once(" - ") {
                asked.push(t.to_owned());
            }
            let mut best: Option<(f64, i64)> = None;
            for q in asked {
                for t in house.search(&q).ok()?.into_iter().filter(|t| t.ready()) {
                    let long = t.duration_ms.map(|ms| (ms as f64 / 1000.0 - r.seconds as f64).abs() <= LENGTH_SLACK).unwrap_or(false);
                    let like = likeness(&r.title, &r.artist, &t.title, &t.artists);
                    if long && like >= 0.8 && best.is_none_or(|b| like > b.0) {
                        best = Some((like, t.id));
                    }
                }
                if best.is_some() {
                    break;
                }
            }
            best?.1
        }
    };
    library::analyse(house, id).ok().map(|a| (id, a))
}

/// Each bar's value of `per_bar` (by `t`'s grid's bars from its bar one) at time `at`.
fn bar_at(t: &Timing, per_bar: &[u8], at: f64) -> Option<u8> {
    let beats = &t.grid.beats;
    let first = *beats.get(t.grid.bar_one)?;
    let spb = t.grid.spb()?;
    if at < first {
        return None;
    }
    let i = ((at - first) / (4.0 * spb)) as usize;
    per_bar.get(i).copied()
}

fn median(mut v: Vec<f64>) -> Option<f64> {
    if v.is_empty() {
        return None;
    }
    v.sort_by(f64::total_cmp);
    Some(v[v.len() / 2])
}

fn pearson(a: &[f64], b: &[f64]) -> f64 {
    let n = a.len().min(b.len());
    if n < 8 {
        return 0.0;
    }
    let (ma, mb) = (a[..n].iter().sum::<f64>() / n as f64, b[..n].iter().sum::<f64>() / n as f64);
    let (mut sab, mut saa, mut sbb) = (0.0, 0.0, 0.0);
    for i in 0..n {
        let (x, y) = (a[i] - ma, b[i] - mb);
        sab += x * y;
        saa += x * x;
        sbb += y * y;
    }
    if saa <= 1e-9 || sbb <= 1e-9 { 0.0 } else { sab / (saa * sbb).sqrt() }
}

/// How far the house's time is behind the stick's (stick time = house time + offset), or
/// none where the two do not line up: `stick` is the stick record's timing (its grid and
/// its bars' loudness), `house` the house's.
pub(crate) fn offset(stick: &Timing, house: &Timing) -> Option<f64> {
    let (s_spb, h_spb) = (stick.grid.spb()?, house.grid.spb()?);
    // the same tempo (an edit or another version is not the same record)
    if (s_spb / h_spb - 1.0).abs() > 0.004 {
        return None;
    }
    // by the beat: each house beat's way to the stick's nearest, within half a beat
    let sb = &stick.grid.beats;
    let fine = median(
        house.grid.beats.iter().take(256).filter_map(|&h| {
            let i = sb.partition_point(|&s| s < h);
            [i.checked_sub(1), Some(i)].into_iter().flatten().filter_map(|j| sb.get(j)).map(|&s| s - h).min_by(|a, b| a.abs().total_cmp(&b.abs()))
        }).filter(|d| d.abs() <= s_spb / 2.0).collect(),
    )?;
    if stick.energy.is_empty() || house.energy.is_empty() {
        // nothing to weigh the bars by: the same file, as it starts
        return (fine.abs() < 0.25).then_some(fine);
    }
    // by the bar: the whole beats' shift where the loudness agrees best
    let downs: Vec<f64> = sb.iter().skip(stick.grid.bar_one).step_by(4).copied().collect();
    let theirs: Vec<f64> = stick.energy.iter().map(|&e| e as f64).collect();
    let mut tried: Vec<(f64, f64)> = vec![];
    for k in -16..=16 {
        let off = fine + k as f64 * s_spb;
        let (mut a, mut b) = (vec![], vec![]);
        for (i, &d) in downs.iter().enumerate() {
            if let (Some(&x), Some(y)) = (theirs.get(i), bar_at(house, &house.energy, d + 2.0 * s_spb - off)) {
                a.push(x);
                b.push(y as f64);
            }
        }
        tried.push((pearson(&a, &b), off));
    }
    let top = tried.iter().map(|t| t.0).fold(f64::MIN, f64::max);
    if top < AGREE {
        return None;
    }
    // bars' loudness cannot tell the beats in a bar apart: of the shifts as good, the one
    // that lays the house's downbeats on the stick's (then the smallest)
    let bar = 4.0 * s_spb;
    let (s_one, h_one) = (*sb.get(stick.grid.bar_one)?, *house.grid.beats.get(house.grid.bar_one)?);
    let off_bar = |off: f64| {
        let d = (h_one + off - s_one).rem_euclid(bar);
        d.min(bar - d)
    };
    tried
        .into_iter()
        .filter(|t| t.0 >= top - 0.02)
        .min_by(|a, b| off_bar(a.1).total_cmp(&off_bar(b.1)).then(a.1.abs().total_cmp(&b.1.abs())))
        .map(|t| t.1)
}

/// The house's analysis laid on the stick's timing, `off` seconds later: what the show reads
/// (sections, drops, the bars' loudness, the voice, the mix points), rekordbox's grid kept.
pub(crate) fn lay_on(stick: &mut Timing, house: &Timing, off: f64) {
    let at = |t: f64| t + off;
    // the house's shape where it has one (a song just sent may have only its beats yet):
    // else the stick's own, from rekordbox's waveform, stays
    if !house.sections.is_empty() {
        stick.sections = house.sections.iter().map(|s| wo_booth::mix::Section { label: s.label.clone(), start: at(s.start).max(0.0), end: at(s.end) }).filter(|s| s.end > s.start).collect();
        stick.phrases = house.phrases.iter().map(|&p| at(p)).filter(|&p| p >= 0.0).collect();
        stick.drops = house.drops.iter().map(|&p| at(p)).filter(|&p| p >= 0.0).collect();
        stick.show_drops = house.show_drops.iter().map(|&p| at(p)).filter(|&p| p >= 0.0).collect();
    }
    stick.markers = house.markers.iter().map(|&p| at(p)).filter(|&p| p >= 0.0).collect();
    stick.mix_in = house.mix_in.map(at);
    stick.mix_out = house.mix_out.map(at);
    stick.sound_end = house.sound_end.map(at);
    stick.outs = house.outs.iter().map(|p| wo_booth::mix::Place { at: at(p.at), why: p.why.clone() }).collect();
    stick.ins = house.ins.iter().map(|p| wo_booth::mix::Place { at: at(p.at), why: p.why.clone() }).collect();
    stick.bars_db = house.bars_db.iter().map(|&(t, db)| (at(t), db)).collect();
    stick.voice = house.voice.or(stick.voice);
    stick.ends = house.ends.clone();
    if stick.camelot.is_none() {
        stick.camelot = house.camelot.clone();
    }
    // each of the stick's bars: the house's bar playing in its middle
    let spb = stick.grid.spb().unwrap_or(0.5);
    let downs: Vec<f64> = stick.grid.beats.iter().skip(stick.grid.bar_one).step_by(4).copied().collect();
    if !house.energy.is_empty() {
        stick.energy = downs.iter().map(|&d| bar_at(house, &house.energy, d + 2.0 * spb - off).unwrap_or(0)).collect();
    }
}

/// The house's vocal map laid on the stick's bars, `off` seconds later.
pub(crate) fn vocals_on(stick: &Timing, house: &Timing, v: &VocalMap, off: f64) -> VocalMap {
    let spb = stick.grid.spb().unwrap_or(0.5);
    let downs: Vec<f64> = stick.grid.beats.iter().skip(stick.grid.bar_one).step_by(4).copied().collect();
    VocalMap {
        bars: v.bars.as_ref().map(|b| downs.iter().map(|&d| bar_at(house, b, d + 2.0 * spb - off).unwrap_or(0)).collect()),
        hook: v.hook.as_ref().map(|(w, at)| (w.clone(), at.iter().map(|t| t + off).collect())),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use wo_booth::Grid;

    fn timing(first: f64, spb: f64, energy: Vec<u8>) -> Timing {
        let beats: Vec<f64> = (0..(energy.len() * 4 + 4)).map(|i| first + i as f64 * spb).collect();
        let mut t = Timing::from_grid(Grid::new(beats, 0), 300.0);
        t.energy = energy;
        t
    }

    #[test]
    fn names_alike_and_tags() {
        assert!(likeness("Ambrukt - Kalap", "BUTO BAYANG", "Kalap", &["Ambrukt".into()]) >= 0.75);
        assert!(likeness("Torta", "Issa Party", "Torta", &["Issa Party".into()]) >= 0.99);
        assert!(likeness("Torta", "Issa Party", "Tortuga", &["Someone".into()]) < 0.3);
        assert_eq!(tagged("fav wetowl:4521 x"), Some(4521));
        assert_eq!(tagged("nothing"), None);
    }

    #[test]
    fn lined_up_by_the_beat_and_the_bar() {
        // the house's file starts 1.3 s later (a longer lead-in): its bars a beat and a bit on
        let shape: Vec<u8> = (0..64).map(|i| if (16..32).contains(&i) || (40..56).contains(&i) { 250 } else if i % 8 == 0 { 140 } else { 80 }).collect();
        let stick = timing(0.05, 0.5, shape.clone());
        let mut house = timing(0.05 + 1.3, 0.5, shape);
        house.sections = vec![wo_booth::mix::Section { label: "drop".into(), start: 0.05 + 1.3 + 32.0, end: 0.05 + 1.3 + 64.0 }];
        house.show_drops = vec![0.05 + 1.3 + 32.0];
        let off = offset(&stick, &house).expect("lined up");
        assert!((off + 1.3).abs() < 0.02, "the house's time 1.3 s on: {off}");
        let mut s = stick.clone();
        lay_on(&mut s, &house, off);
        assert!((s.show_drops[0] - (0.05 + 32.0)).abs() < 0.02, "the drop on the stick's bar 16: {:?}", s.show_drops);
        assert_eq!(s.energy[16], 250);
        assert_eq!(s.energy[0], 140);
        // another tempo: not the same record
        let other = timing(0.05, 0.47, vec![100; 64]);
        assert!(offset(&stick, &other).is_none());
    }

    /// The stick at WO_PROBE_STICK against the house signed in on this computer: how many of
    /// its records are found and line up (asks the house; run by hand).
    #[test]
    #[ignore]
    fn probe_a_stick_against_the_house() {
        let Ok(root) = std::env::var("WO_PROBE_STICK") else { return };
        let house = House::new(wo_house::Session::saved().or_else(wo_house::Session::from_wetowl_app).expect("signed in on this computer"));
        let stick = wo_usb::Stick::open(std::path::Path::new(&root)).expect("a stick");
        let (mut found, mut lined, mut n) = (0, 0, 0);
        for t in &stick.tracks {
            n += 1;
            let r = Record::from_usb(&stick.name, t);
            let Some((id, a)) = find(&house, &r) else {
                eprintln!("  -    {}", r.title);
                continue;
            };
            found += 1;
            let s = crate::library::analyse_usb(t.anlz.as_deref(), t.seconds as f64).expect("its analysis");
            let mut st = s.timing.clone();
            let w = &s.waves;
            let all: Vec<f32> = w.iter().map(|c| c.bands.iter().map(|&b| b as f32).sum()).collect();
            st.energy = crate::phrases::bar_energy(&all, &st.grid.beats, st.grid.bar_one);
            match offset(&st, &a.timing) {
                Some(off) => {
                    lined += 1;
                    eprintln!("  ok   {} → {id} ({off:+.3} s, {} sections, {} drops)", r.title, a.timing.sections.len(), a.timing.show_drops.len());
                }
                None => eprintln!("  off  {} → {id}", r.title),
            }
        }
        eprintln!("{n} records: {found} found in the house, {lined} lined up");
    }

    /// What the house's search answers for a few titles, `|` between (run by hand).
    #[test]
    #[ignore]
    fn probe_the_house_search() {
        let Ok(q) = std::env::var("WO_PROBE_Q") else { return };
        let house = House::new(wo_house::Session::saved().or_else(wo_house::Session::from_wetowl_app).expect("signed in"));
        for q in q.split('|') {
            let got = house.search(q);
            eprintln!("{q:?}: {:?}", got.as_ref().map(|g| g.len()).map_err(|e| e.to_string()));
            for t in got.unwrap_or_default().iter().take(4) {
                eprintln!("    {} — {:?} · {:?} ms · {}", t.title, t.artists, t.duration_ms, t.state);
            }
        }
    }
}
