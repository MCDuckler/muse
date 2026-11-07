//! The sets and the favourites on the Desk (v1: show_room_snapshots.dart, show_snapshots.dart,
//! show_room_faves.dart).
//!
//! A set is the show as the hands set it up — how often everything comes, the effects, the
//! director's temper, the knobs, the finish — named, kept here or shared at the house (every
//! WetOwl account may switch to a shared one and save over it, by its revision: one saved
//! over since it was taken is said, and the hands take theirs or save ours over it). SAVE puts
//! the show over the set on, SAVE AS keeps it as a new one; switching away from changes not
//! saved puts them aside with an UNDO. A Desk on a shared set, not changed since, follows it:
//! a newer revision is taken as it is listed (every minute while the sets are looked at).
//!
//! A favourite is what was on the stage, kept with KEEP: rated one to five stars, named,
//! forgotten (with an UNDO), put on in a tap and held; its picture the stage's at that moment.
use std::path::PathBuf;
use std::sync::mpsc::{Receiver, channel};
use std::time::{Duration, Instant};

use serde_json::Value;
use wo_show::doc::{ShowDoc, ShowSnapshot};

use super::{Show, combo_words};

/// How often the shared sets are listed again while they are looked at.
const LIST_EVERY: Duration = Duration::from_secs(60);

/// What the hands do to the sets.
#[derive(Clone, Debug, PartialEq)]
pub enum SetEdit {
    /// One put on (None: the show as shipped).
    Use(Option<String>),
    /// The show over the set on.
    Save,
    /// A shared one saved over since: theirs taken, or ours saved over it.
    TakeTheirs,
    SaveOver,
    /// The show kept as a new set, by this name.
    SaveAs(String),
    Rename(String, String),
    Forget(String),
    /// One kept here shared with everyone; one this account shared taken back.
    Share(String),
    Unshare(String),
    /// The shared ones listed again.
    Reload,
    /// The last switch away from changes, or the last forgetting, undone.
    Undo,
}

/// A set as the page lists it.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct SetRow {
    pub id: String,
    pub name: String,
    pub shared: bool,
    /// A shared one: whether this account shared it, who did, who saved it last.
    pub mine: bool,
    pub owner: Option<String>,
    pub updated_by: Option<String>,
    pub on: bool,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct SetsView {
    /// This Desk's, then the shared ones.
    pub sets: Vec<SetRow>,
    /// The one on (None: as shipped), and whether the show changed since it was put on.
    pub on: Option<SetRow>,
    pub changed: bool,
    /// Signed in to the house: the shared ones are there.
    pub house: bool,
    pub loading: bool,
    pub trouble: Option<String>,
    /// A shared one saved over since it was taken: its name, who saved it.
    pub conflict: Option<(String, Option<String>)>,
    /// What UNDO would undo, in words.
    pub undo: Option<String>,
    /// What the last change said.
    pub said: Option<String>,
}

/// A favourite as the page shows it.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct FaveRow {
    pub id: String,
    /// Its name, or what it is in a few words.
    pub title: String,
    /// Everything it keeps, a line each.
    pub words: String,
    pub stars: u8,
    pub scene: String,
    /// The look, for a still where there is no picture: its figure, style, ground, mask, blend.
    pub figure: String,
    pub style: String,
    pub ground: String,
    pub mask: String,
    pub mix: String,
    /// The stage's picture as it was kept.
    pub picture: Option<PathBuf>,
    /// When it was kept (ISO 8601).
    pub at: String,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct FavesView {
    /// Newest first.
    pub faves: Vec<FaveRow>,
    /// The one on the stage, held.
    pub on: Option<String>,
    /// The scenes they are of (id, name).
    pub scenes: Vec<(String, String)>,
    /// The one just kept (KEEP), to rate there and then.
    pub kept: Option<String>,
    pub undo: Option<String>,
}

/// What a house call on a thread hands back.
enum Job {
    Listed(Result<Vec<Value>, String>),
    Saved(Result<Result<Value, Value>, String>),
    Shared(String, Result<Value, String>),
    Unshared(String, Result<(), String>),
}

/// The sets shared at the house, as last listed, and the work under way.
#[derive(Default)]
pub(crate) struct Shelf {
    shared: Vec<ShowSnapshot>,
    trouble: Option<String>,
    jobs: Vec<Receiver<Job>>,
    listed: Option<Instant>,
    conflict: Option<ShowSnapshot>,
    /// UNDO: the words, and the show as it was.
    undo: Option<(String, ShowDoc)>,
    said: Option<String>,
    /// The favourite on the stage (put on by hand, until the look changes), the one just kept.
    pub fave_on: Option<String>,
    pub kept: Option<String>,
    fave_undo: Option<(String, ShowDoc)>,
}

fn micros() -> i64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.as_micros() as i64)
}

impl Show {
    /// The faves' pictures' folder (beside show.json).
    pub(crate) fn faves_dir(&self) -> Option<PathBuf> {
        self.doc_file.as_ref().and_then(|f| f.parent()).map(|d| d.join("faves"))
    }

    /// A house call on a thread; its answer taken in by [Show::poll_sets].
    fn on_house(&mut self, f: impl FnOnce(&wo_house::House) -> Job + Send + 'static) {
        let Some(house) = self.house.clone() else {
            self.shelf.trouble = Some("not signed in to the house".into());
            return;
        };
        let (tx, rx) = channel();
        std::thread::spawn(move || {
            let _ = tx.send(f(&house));
        });
        self.shelf.jobs.push(rx);
    }

    /// The house's answers, taken in (each frame).
    pub(crate) fn poll_sets(&mut self) {
        let mut done = vec![];
        self.shelf.jobs.retain(|rx| match rx.try_recv() {
            Ok(j) => {
                done.push(j);
                false
            }
            Err(std::sync::mpsc::TryRecvError::Empty) => true,
            Err(_) => false,
        });
        for job in done {
            self.took(job);
        }
    }

    fn took(&mut self, job: Job) {
        let before = self.direct.doc.clone();
        match job {
            Job::Listed(Ok(rows)) => {
                self.shelf.shared = rows.iter().filter_map(ShowSnapshot::from_server).collect();
                self.shelf.trouble = None;
                // the one on, not changed since it was taken and saved since by someone: taken
                // again as it is now
                let d = &mut self.direct.doc;
                if let Some(on) = d.snapshot().filter(|s| s.shared())
                    && !d.changed_since_set()
                    && let Some(now) = self.shelf.shared.iter().find(|x| x.id == on.id && x.rev > on.rev)
                {
                    d.use_set(now);
                    self.shelf.said = Some(format!("{} as {} saved it", now.name, now.updated_by.as_deref().unwrap_or("someone")));
                }
            }
            Job::Listed(Err(e)) => self.shelf.trouble = Some(format!("the shared sets could not be listed: {e}")),
            Job::Saved(Ok(Ok(v))) => {
                if let Some(s) = ShowSnapshot::from_server(&v) {
                    self.listed(&s);
                    self.direct.doc.take(&s);
                    self.shelf.said = Some(format!("Saved over {} for everyone", s.name));
                }
                self.shelf.trouble = None;
            }
            Job::Saved(Ok(Err(theirs))) => {
                if let Some(s) = ShowSnapshot::from_server(&theirs) {
                    self.listed(&s);
                    self.shelf.conflict = Some(s);
                }
            }
            Job::Saved(Err(e)) => self.shelf.trouble = Some(format!("could not save it: {e}")),
            Job::Shared(was, Ok(v)) => {
                if let Some(s) = ShowSnapshot::from_server(&v) {
                    self.listed(&s);
                    self.direct.doc.shared_set(&was, &s);
                    self.shelf.said = Some(format!("{} is shared: every WetOwl account can switch to it and save over it", s.name));
                }
                self.shelf.trouble = None;
            }
            Job::Shared(_, Err(e)) => self.shelf.trouble = Some(format!("could not share it: {e}")),
            Job::Unshared(was, Ok(())) => {
                if let Some(s) = self.shelf.shared.iter().find(|x| x.id == was).cloned() {
                    let here = ShowSnapshot { id: format!("l:{}", micros()), rev: 0, owner: None, mine: true, updated_by: None, ..s };
                    self.shelf.shared.retain(|x| x.id != was);
                    self.direct.doc.unshared_set(&was, &here);
                    self.shelf.said = Some(format!("{} is no longer shared: kept on this Desk", here.name));
                }
                self.shelf.trouble = None;
            }
            Job::Unshared(_, Err(e)) => self.shelf.trouble = Some(format!("could not take it away: {e}")),
        }
        self.after_doc(before);
    }

    fn listed(&mut self, s: &ShowSnapshot) {
        match self.shelf.shared.iter_mut().find(|x| x.id == s.id) {
            Some(x) => *x = s.clone(),
            None => self.shelf.shared.insert(0, s.clone()),
        }
    }

    /// The document changed by the sets: the director told, kept.
    fn after_doc(&mut self, before: ShowDoc) {
        if self.direct.doc != before {
            self.direct.apply_doc();
            self.doc_dirty = true;
            self.page = None;
        }
    }

    pub(crate) fn set_by_id(&self, id: &str) -> Option<ShowSnapshot> {
        self.direct.doc.snapshots().into_iter().chain(self.shelf.shared.iter().cloned()).find(|s| s.id == id)
    }

    /// Switched to `to` (None: as shipped): changes not saved put aside, with an UNDO.
    pub(crate) fn use_set(&mut self, to: Option<&ShowSnapshot>) {
        let d = &mut self.direct.doc;
        let was = d.clone();
        if d.changed_since_set() {
            let words = match d.snapshot() {
                Some(s) => format!("Your changes to {} were not saved", s.name),
                None => "Your changes were put aside".to_owned(),
            };
            self.shelf.undo = Some((words, was.clone()));
        } else {
            self.shelf.undo = None;
        }
        match to {
            Some(s) => d.use_set(s),
            None => d.use_shipped(),
        }
        self.shelf.conflict = None;
        self.shelf.said = Some(format!("Set: {}", to.map_or("As shipped", |s| s.name.as_str())));
        self.after_doc(was);
    }

    /// The shared sets as last listed.
    pub(crate) fn shelf_shared(&self) -> Vec<ShowSnapshot> {
        self.shelf.shared.clone()
    }

    /// The favourite just kept (KEEP), for its picture.
    pub(crate) fn last_kept(&self) -> Option<String> {
        self.shelf.kept.clone()
    }

    pub(crate) fn edit_set(&mut self, e: SetEdit) {
        let before = self.direct.doc.clone();
        match e {
            SetEdit::Use(None) => self.use_set(None),
            SetEdit::Use(Some(id)) => {
                if let Some(s) = self.set_by_id(&id) {
                    self.use_set(Some(&s));
                }
            }
            SetEdit::Save => self.save_set(None),
            SetEdit::SaveOver => {
                let theirs = self.shelf.conflict.take();
                self.save_set(theirs.map(|t| t.rev));
            }
            SetEdit::TakeTheirs => {
                if let Some(t) = self.shelf.conflict.take() {
                    self.direct.doc.use_set(&t);
                    self.shelf.said = Some(format!("{} as {} saved it", t.name, t.updated_by.as_deref().unwrap_or("someone")));
                }
            }
            SetEdit::SaveAs(name) => {
                let name = name.trim().to_owned();
                if !name.is_empty() {
                    let s = self.direct.doc.save_as(&name, &format!("l:{}", micros()));
                    self.shelf.said = Some(format!("Kept as {}", s.name));
                }
            }
            SetEdit::Rename(id, name) => self.direct.doc.rename_set(&id, &name),
            SetEdit::Forget(id) => {
                if let Some(s) = self.direct.doc.snapshots().into_iter().find(|s| s.id == id) {
                    self.shelf.undo = Some((format!("{} forgotten (the show stays as it is)", s.name), before.clone()));
                    self.direct.doc.forget_set(&id);
                }
            }
            SetEdit::Share(id) => {
                // the show over it first, where it is on and changed
                if self.direct.doc.snapshot().is_some_and(|s| s.id == id) && self.direct.doc.changed_since_set() {
                    self.direct.doc.save_set();
                }
                if let Some(s) = self.direct.doc.snapshots().into_iter().find(|s| s.id == id) {
                    let (name, doc) = (s.name.clone(), s.doc());
                    self.on_house(move |h| Job::Shared(id, h.share_show_snapshot(&name, &doc).map_err(|e| e.to_string())));
                }
            }
            SetEdit::Unshare(id) => {
                if let Some(n) = self.shelf.shared.iter().find(|x| x.id == id && x.mine).and_then(ShowSnapshot::server_id) {
                    self.on_house(move |h| Job::Unshared(id, h.unshare_show_snapshot(n).map_err(|e| e.to_string())));
                }
            }
            SetEdit::Reload => self.list_sets(),
            SetEdit::Undo => {
                if let Some((_, doc)) = self.shelf.undo.take() {
                    self.direct.doc = doc;
                    self.shelf.said = None;
                }
            }
        }
        self.after_doc(before);
    }

    /// The show over the set on: here, or at the house (by its revision, or `over` that one).
    fn save_set(&mut self, over: Option<i64>) {
        let d = &mut self.direct.doc;
        let Some(on) = d.snapshot() else { return };
        if !on.shared() {
            if let Some(s) = d.save_set() {
                self.shelf.said = Some(format!("Saved over {}", s.name));
            }
            return;
        }
        let Some(n) = on.server_id() else { return };
        let doc = ShowSnapshot { setup: d.setup(), ..on.clone() }.doc();
        let rev = over.unwrap_or(on.rev);
        self.on_house(move |h| Job::Saved(h.save_show_snapshot(n, &doc, rev, None).map_err(|e| e.to_string())));
    }

    /// The shared ones listed again (not while another call is under way).
    fn list_sets(&mut self) {
        if !self.shelf.jobs.is_empty() || self.house.is_none() {
            return;
        }
        self.shelf.listed = Some(Instant::now());
        self.on_house(|h| Job::Listed(h.show_snapshots().map_err(|e| e.to_string())));
    }

    /// The sets as the page draws them (the shared ones listed again now and then while it
    /// does).
    pub(crate) fn sets_view(&mut self) -> SetsView {
        self.poll_sets();
        if self.shelf.listed.is_none_or(|t| t.elapsed() > LIST_EVERY) {
            self.list_sets();
        }
        let d = &self.direct.doc;
        let on = d.snapshot();
        let row = |s: &ShowSnapshot| SetRow {
            id: s.id.clone(),
            name: s.name.clone(),
            shared: s.shared(),
            mine: s.mine,
            owner: s.owner.clone(),
            updated_by: s.updated_by.clone(),
            on: on.as_ref().is_some_and(|o| o.id == s.id),
        };
        let mut sets: Vec<SetRow> = d.snapshots().iter().map(row).collect();
        sets.extend(self.shelf.shared.iter().map(row));
        // the one on, shared, not listed (yet): still shown
        if let Some(o) = on.as_ref().filter(|o| !sets.iter().any(|s| s.id == o.id)) {
            sets.push(row(o));
        }
        SetsView {
            on: on.as_ref().map(row),
            changed: d.changed_since_set(),
            house: self.house.is_some(),
            loading: !self.shelf.jobs.is_empty(),
            trouble: self.shelf.trouble.clone(),
            conflict: self.shelf.conflict.as_ref().map(|c| (c.name.clone(), c.updated_by.clone())),
            undo: self.shelf.undo.as_ref().map(|(w, _)| w.clone()),
            said: self.shelf.said.clone(),
            sets,
        }
    }

    // ---------------------------------------------------------------- the favourites

    pub(crate) fn faves_view(&mut self) -> FavesView {
        let d = &self.direct;
        // the one put on is on while its look is
        if let Some(id) = &self.shelf.fave_on
            && !d.doc.faves().iter().any(|f| &f.id == id && d.director.combo() == Some(&f.combo) || &f.id == id && d.pending().is_some_and(|l| l.combo == f.combo))
        {
            self.shelf.fave_on = None;
        }
        let dir = self.faves_dir();
        let d = &self.direct;
        let name_of = |s: &str| d.looks.get(s).map_or(s.to_owned(), |l| l.name.clone());
        let faves: Vec<FaveRow> = d
            .doc
            .faves()
            .into_iter()
            .map(|f| {
                let c = &f.combo;
                let title = if f.name.is_empty() { combo_words(c, &d.looks) } else { f.name.clone() };
                let mut words = vec![combo_words(c, &d.looks)];
                if let Some(m) = &f.milk {
                    words.push(format!("MilkDrop: {m}"));
                }
                if let Some(s) = &f.shot {
                    words.push(format!("Camera: {}", super::shot_name(s.split_once('.').map_or(s.as_str(), |x| x.1)).to_lowercase()));
                }
                words.push(format!("Kept {}", f.at.get(..16).unwrap_or(&f.at).replace('T', " ")));
                let figure = d.director.kinds.get(&c.scene).map_or("none", |k| wo_show::json::Named::name(*k)).to_owned();
                let picture = dir.as_ref().map(|p| p.join(format!("{}.png", f.id))).filter(|p| p.is_file());
                FaveRow {
                    id: f.id.clone(),
                    title,
                    words: words.join("\n"),
                    stars: f.stars,
                    scene: c.scene.clone(),
                    figure,
                    style: c.style.clone(),
                    ground: c.ground.clone(),
                    mask: wo_show::json::Named::name(c.mask).to_owned(),
                    mix: wo_show::json::Named::name(c.mix).to_owned(),
                    picture,
                    at: f.at,
                }
            })
            .collect();
        let mut scenes: Vec<(String, String)> = vec![];
        for f in &faves {
            if !scenes.iter().any(|(s, _)| *s == f.scene) {
                scenes.push((f.scene.clone(), name_of(&f.scene)));
            }
        }
        FavesView {
            on: self.shelf.fave_on.clone(),
            scenes,
            kept: self.shelf.kept.clone().filter(|k| faves.iter().any(|f| &f.id == k)),
            undo: self.shelf.fave_undo.as_ref().map(|(w, _)| w.clone()),
            faves,
        }
    }

    pub(crate) fn edit_fave(&mut self, e: FaveEdit) {
        let before = self.direct.doc.clone();
        match e {
            FaveEdit::Stars(id, n) => self.direct.doc.rate_fave(&id, n),
            FaveEdit::Rename(id, name) => self.direct.doc.rename_fave(&id, &name),
            FaveEdit::Forget(id) => {
                if let Some(f) = self.direct.doc.faves().into_iter().find(|f| f.id == id) {
                    let title = if f.name.is_empty() { combo_words(&f.combo, &self.direct.looks) } else { f.name };
                    self.shelf.fave_undo = Some((format!("{title} forgotten"), before.clone()));
                    self.direct.doc.forget_fave(&id);
                }
            }
            FaveEdit::Undo => {
                if let Some((_, doc)) = self.shelf.fave_undo.take() {
                    self.direct.doc = doc;
                }
            }
        }
        self.after_doc(before);
    }

    /// KEEP's picture: the stage's frame as it was kept, small, beside show.json.
    pub(crate) fn keep_picture(&self, id: &str, t: &wo_wire::Thumb) {
        let Some(dir) = self.faves_dir() else { return };
        let Some(img) = image::RgbaImage::from_raw(t.width as u32, t.height as u32, t.rgba.clone()) else { return };
        let w = 320u32.min(img.width());
        let h = (w as f64 * img.height() as f64 / img.width().max(1) as f64).round().max(1.0) as u32;
        let small = image::imageops::resize(&img, w, h, image::imageops::FilterType::Triangle);
        let _ = std::fs::create_dir_all(&dir);
        if let Err(e) = small.save(dir.join(format!("{id}.png"))) {
            eprintln!("a favourite's picture: {e}");
        }
    }
}

/// What the hands do to the favourites.
#[derive(Clone, Debug, PartialEq)]
pub enum FaveEdit {
    Stars(String, u8),
    Rename(String, String),
    Forget(String),
    Undo,
}

#[cfg(test)]
mod tests {
    use std::io::{BufRead, BufReader, Read, Write};
    use std::sync::{Arc, Mutex};

    use serde_json::{Value, json};

    use super::*;
    use crate::show::ShowEdit as E;

    /// A house of its own: the shared sets' four calls, in memory (no account is touched).
    fn fake_house(rows: Arc<Mutex<Vec<Value>>>) -> String {
        let l = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = l.local_addr().unwrap().port();
        std::thread::spawn(move || {
            for conn in l.incoming().flatten() {
                let mut r = BufReader::new(conn.try_clone().unwrap());
                let mut line = String::new();
                if r.read_line(&mut line).is_err() {
                    continue;
                }
                let (mut len, mut h) = (0usize, String::new());
                while r.read_line(&mut h).is_ok_and(|n| n > 0) && h.trim() != "" {
                    if let Some(v) = h.to_ascii_lowercase().strip_prefix("content-length:") {
                        len = v.trim().parse().unwrap_or(0);
                    }
                    h.clear();
                }
                let mut body = vec![0; len];
                let _ = r.read_exact(&mut body);
                let body: Value = serde_json::from_slice(&body).unwrap_or_default();
                let mut p = line.split_whitespace();
                let (method, path) = (p.next().unwrap_or(""), p.next().unwrap_or(""));
                let id: Option<i64> = path.strip_prefix("/booth/show/snapshots/").and_then(|x| x.parse().ok());
                let mut rows = rows.lock().unwrap();
                let (status, answer) = match (method, id) {
                    ("GET", None) => (200, json!({"snapshots": *rows})),
                    ("POST", None) => {
                        let n = rows.len() as i64 + 1;
                        let row = json!({"id": n, "name": body["name"], "doc": body["doc"], "rev": 0, "owner": "me", "mine": true, "updated_by": "me"});
                        rows.insert(0, row.clone());
                        (201, row)
                    }
                    ("PUT", Some(n)) => match rows.iter_mut().find(|r| r["id"] == n) {
                        Some(r) if r["rev"] != body["rev"] => (409, json!({"detail": r.clone()})),
                        Some(r) => {
                            r["doc"] = body["doc"].clone();
                            r["rev"] = (r["rev"].as_i64().unwrap() + 1).into();
                            r["updated_by"] = "me".into();
                            (200, r.clone())
                        }
                        None => (404, json!({})),
                    },
                    ("DELETE", Some(n)) => {
                        rows.retain(|r| r["id"] != n);
                        (204, Value::Null)
                    }
                    _ => (404, json!({})),
                };
                let text = if answer.is_null() { String::new() } else { answer.to_string() };
                let mut c = conn;
                let _ = write!(c, "HTTP/1.1 {status} X\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{text}", text.len());
            }
        });
        format!("http://127.0.0.1:{port}")
    }

    /// The house's answers waited for.
    fn settle(show: &mut Show) -> SetsView {
        let t = Instant::now();
        loop {
            show.poll_sets();
            if show.shelf.jobs.is_empty() {
                return show.sets_view();
            }
            assert!(t.elapsed().as_secs() < 10, "the house never answered");
            std::thread::sleep(Duration::from_millis(5));
        }
    }

    #[test]
    fn sets_are_kept_shared_saved_over_and_followed() {
        let dir = std::env::temp_dir().join(format!("wo-show-sets-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("show.json");
        std::fs::write(&file, r#"{"v":1,"pool":{}}"#).unwrap();
        let rows = Arc::new(Mutex::new(vec![]));
        let server = fake_house(rows.clone());
        let mut show = Show::new_in(None, Some(file.clone()));
        show.house = Some(wo_house::House::new(wo_house::Session { server, token: "t".into(), user: None }));
        let v = settle(&mut show);
        assert!(v.house && v.sets.is_empty() && v.on.is_none() && !v.changed);
        // kept here
        show.edit(E::Bias(0.5));
        assert!(show.sets_view().changed);
        show.edit(E::Set(SetEdit::SaveAs("Club".into())));
        let v = show.sets_view();
        assert_eq!(v.on.as_ref().map(|s| s.name.as_str()), Some("Club"));
        assert!(!v.changed && !v.sets[0].shared);
        // shared: the house's own in its place
        let local = v.sets[0].id.clone();
        show.edit(E::Mosh(0.2));
        show.edit(E::Set(SetEdit::Share(local)));
        let v = settle(&mut show);
        assert_eq!(v.sets.len(), 1);
        assert!(v.sets[0].shared && v.sets[0].mine && v.on.as_ref().is_some_and(|o| o.id == "s:1"));
        assert!(!v.changed, "the changes went with it");
        assert_eq!(rows.lock().unwrap()[0]["doc"]["setup"]["mosh"], 0.2);
        // saved over, by its revision
        show.edit(E::Bias(-0.5));
        show.edit(E::Set(SetEdit::Save));
        let v = settle(&mut show);
        assert!(!v.changed && v.conflict.is_none());
        assert_eq!(rows.lock().unwrap()[0]["rev"], 1);
        // someone saves it meanwhile: ours over a stale one is said; theirs taken
        {
            let mut r = rows.lock().unwrap();
            r[0]["rev"] = 2.into();
            r[0]["doc"]["setup"]["bias"] = 0.9.into();
            r[0]["updated_by"] = "joe".into();
        }
        show.edit(E::Bias(0.1));
        show.edit(E::Set(SetEdit::Save));
        let v = settle(&mut show);
        assert_eq!(v.conflict, Some(("Club".into(), Some("joe".into()))));
        show.edit(E::Set(SetEdit::TakeTheirs));
        assert_eq!(show.direct.doc.bias(), 0.9);
        assert!(!show.sets_view().changed);
        // followed: a newer revision, the show not changed here, taken as it is listed
        {
            let mut r = rows.lock().unwrap();
            r[0]["rev"] = 3.into();
            r[0]["doc"]["setup"]["bias"] = (-0.3).into();
        }
        show.edit(E::Set(SetEdit::Reload));
        settle(&mut show);
        assert_eq!(show.direct.doc.bias(), -0.3, "followed");
        // taken back: kept here
        show.edit(E::Set(SetEdit::Unshare("s:1".into())));
        let v = settle(&mut show);
        assert!(rows.lock().unwrap().is_empty());
        assert!(v.sets.len() == 1 && !v.sets[0].shared && v.on.is_some_and(|o| o.id.starts_with("l:")));
        // switched away from changes: put aside, with an UNDO
        show.edit(E::Bias(0.7));
        show.edit(E::Set(SetEdit::Use(None)));
        let v = show.sets_view();
        assert!(v.on.is_none() && v.undo.is_some_and(|u| u.contains("not saved")));
        assert_eq!(show.direct.doc.bias(), 0.0, "as shipped");
        show.edit(E::Set(SetEdit::Undo));
        assert_eq!(show.direct.doc.bias(), 0.7, "back");
        drop(show);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn favourites_are_rated_named_forgotten_and_kept_with_their_picture() {
        let dir = std::env::temp_dir().join(format!("wo-show-faves-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("show.json");
        std::fs::write(&file, r#"{"v":1,"pool":{}}"#).unwrap();
        let mut show = Show::new_in(None, Some(file.clone()));
        show.tick(&wo_wire::Frame::default(), None);
        show.hand(&wo_wire::Hand::Keep);
        let v = show.faves_view();
        assert_eq!(v.faves.len(), 1);
        let id = v.faves[0].id.clone();
        assert_eq!(v.kept.as_deref(), Some(id.as_str()), "just kept: rated there and then");
        let thumb = wo_wire::Thumb { width: 64, height: 36, rgba: vec![200; 64 * 36 * 4] };
        show.keep_picture(&id, &thumb);
        show.edit(E::Fave(FaveEdit::Stars(id.clone(), 4)));
        show.edit(E::Fave(FaveEdit::Rename(id.clone(), "The hexagons".into())));
        let v = show.faves_view();
        let f = &v.faves[0];
        assert_eq!((f.stars, f.title.as_str()), (4, "The hexagons"));
        assert!(f.picture.as_ref().is_some_and(|p| p.is_file()), "its picture beside show.json");
        // put on: the one on while its look is
        show.hand(&wo_wire::Hand::Fave(id.clone()));
        assert_eq!(show.faves_view().on.as_deref(), Some(id.as_str()));
        show.hand(&wo_wire::Hand::LetGo);
        show.direct.next(1);
        assert_eq!(show.faves_view().on, None);
        // forgotten, and back
        show.edit(E::Fave(FaveEdit::Forget(id.clone())));
        let v = show.faves_view();
        assert!(v.faves.is_empty() && v.undo.is_some());
        show.edit(E::Fave(FaveEdit::Undo));
        assert_eq!(show.faves_view().faves.len(), 1);
        drop(show);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
