//! Against the real house, read-only, with the WetOwl app's sign-in on this computer.
//! Opt-in: `cargo test -p wo-house --test live -- --ignored`.
use wo_house::{House, Session};

#[test]
#[ignore]
fn reads_the_house() {
    let Some(session) = Session::from_wetowl_app() else {
        eprintln!("no WetOwl app sign-in on this computer: skipped");
        return;
    };
    let house = House::new(session);
    let page = house.tracks("added", 0, 5).expect("a page of the library");
    eprintln!("library: {} ready records; first {:?}", page.total, page.items.first().map(|t| &t.title));
    assert!(page.total > 0 && page.items.iter().all(|t| t.ready()));
    let found = house.search("watch this").expect("search");
    eprintln!("search 'watch this': {} found", found.len());
    let lists = house.playlists().expect("playlists");
    eprintln!("playlists: {} (first {:?}, {} records)", lists.len(), lists.first().map(|l| &l.name), lists.first().map(|l| l.items).unwrap_or(0));
    if let Some(l) = lists.iter().find(|l| l.items > 0) {
        let full = house.playlist(l.id).expect("a playlist");
        eprintln!("playlist {:?}: {} records", full.name, full.items.len());
    }
    let id = page.items[0].id;
    let a = house.analysis(id).expect("an analysis");
    let g = a.grid();
    eprintln!("analysis of {id}: {} beats, {:.2} bpm, {:?}, pads {:?}", g.beats.len(), 60.0 / g.spb().unwrap_or(1.0), a.camelot, a.auto_pads());
    assert!(g.beats.len() > 16);
    eprintln!("hand pads: {:?}", house.hand_pads(id).expect("pads"));
}
