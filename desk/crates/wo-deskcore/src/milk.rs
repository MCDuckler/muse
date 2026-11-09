//! MilkDrop's library on this computer (v1: milk_library.dart's files): where the presets are
//! (the WetOwl app's folder where it has one, shared while v1 keeps it, else the Desk's own),
//! the shipped ones written out once, the hands' own and imported folders read, the notes on
//! them (favourites, off, skips, the last on) read and written back. The choosing is
//! wo_show::milk's.
use std::path::{Path, PathBuf};

use wo_show::milk::{MilkLibrary, MilkNotes, MilkPreset, rating_of};

include!(concat!(env!("OUT_DIR"), "/milk_presets.rs"));

/// The library's folder: WETOWL_MILK_HOME, the WetOwl app's (`…/io.wetowl.muse/milk`) where it
/// is there, else the Desk's own data folder's.
pub fn home() -> Option<PathBuf> {
    if let Some(h) = std::env::var_os("WETOWL_MILK_HOME") {
        return Some(PathBuf::from(h));
    }
    let v1 = crate::records::fetched_dir().and_then(|f| f.parent().map(|p| p.join("milk"))).filter(|d| d.is_dir());
    v1.or_else(|| wo_house::folders::data().map(|d| d.join("wetowl-desk").join("milk")))
}

/// The shipped presets into `home/shipped`, unless they are there already (the count as the
/// stamp, as v1 writes it).
pub fn write_shipped(home: &Path) -> std::io::Result<()> {
    let dir = home.join("shipped");
    std::fs::create_dir_all(&dir)?;
    for d in ["mine", "textures"] {
        std::fs::create_dir_all(home.join(d))?;
    }
    let stamp = dir.join(".stamp");
    let want = SHIPPED_MILK.len().to_string();
    if std::fs::read_to_string(&stamp).is_ok_and(|s| s == want) {
        return Ok(());
    }
    for (name, bytes) in SHIPPED_MILK {
        std::fs::write(dir.join(name), bytes)?;
    }
    std::fs::write(stamp, want)
}

fn walk(dir: &Path, collection: &str, out: &mut Vec<MilkPreset>) {
    let Ok(rd) = std::fs::read_dir(dir) else { return };
    for e in rd.flatten() {
        let p = e.path();
        if p.is_dir() {
            walk(&p, collection, out);
        } else if p.extension().is_some_and(|x| x.eq_ignore_ascii_case("milk")) {
            let head = std::fs::read(&p).map(|b| String::from_utf8_lossy(&b[..b.len().min(400)]).into_owned()).unwrap_or_default();
            out.push(MilkPreset::of(&p.to_string_lossy(), collection, rating_of(&head)));
        }
    }
}

/// Everything on disk under `home` (shipped, mine) and in the imported folders, with the notes.
pub fn library(home: &Path) -> MilkLibrary {
    let notes = std::fs::read_to_string(home.join("notes.json")).map(|t| MilkNotes::parse(&t)).unwrap_or_default();
    let mut found = vec![];
    walk(&home.join("shipped"), "shipped", &mut found);
    walk(&home.join("mine"), "mine", &mut found);
    for (name, dir) in &notes.imported {
        walk(Path::new(dir), name, &mut found);
    }
    MilkLibrary::new(found, notes)
}

/// The notes written back.
pub fn save_notes(home: &Path, notes: &MilkNotes) {
    let _ = std::fs::write(home.join("notes.json"), notes.to_json().to_string());
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_shipped_presets_go_out_once_and_read_back_with_their_ratings() {
        let home = std::env::temp_dir().join(format!("wo-milk-home-{}", std::process::id()));
        write_shipped(&home).unwrap();
        let lib = library(&home);
        assert_eq!(lib.presets.len(), SHIPPED_MILK.len());
        assert!(SHIPPED_MILK.len() > 500);
        assert!(lib.presets.iter().any(|p| p.rating != 3.0), "some rate themselves");
        // the second time, nothing is written (the stamp)
        let t0 = std::fs::metadata(home.join("shipped/.stamp")).unwrap().modified().unwrap();
        write_shipped(&home).unwrap();
        assert_eq!(std::fs::metadata(home.join("shipped/.stamp")).unwrap().modified().unwrap(), t0);
        let mut notes = lib.notes.clone();
        notes.favourites.insert(lib.presets[0].full_name());
        save_notes(&home, &notes);
        assert!(library(&home).is_favourite(&lib.presets[0]));
        let _ = std::fs::remove_dir_all(&home);
    }
}
