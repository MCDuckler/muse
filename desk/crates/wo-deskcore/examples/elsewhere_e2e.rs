//! The crate's search from elsewhere, end to end against a house: a search, a SoundCloud
//! song got (the house fetches it), a YouTube Music song got (fetched here where yt-dlp
//! is installed), a list opened, and one taken whole. Run it signed in as a throwaway
//! account only (XDG_CONFIG_HOME at a folder whose wetowl-desk/session.json is that
//! account's): it adds songs and a playlist to whoever is signed in.
//! `elsewhere_e2e <query> [list query]`
use std::thread::sleep;
use std::time::{Duration, Instant};

use wo_deskcore::{Desk, Shelf};

fn wait(d: &mut Desk, secs: u64, mut done: impl FnMut(&mut Desk) -> bool) -> bool {
    let t0 = Instant::now();
    while t0.elapsed() < Duration::from_secs(secs) {
        d.tick();
        for s in d.take_elsewhere_said() {
            println!("  said: {s}");
        }
        if done(d) {
            return true;
        }
        sleep(Duration::from_millis(250));
    }
    false
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let q = args.first().cloned().unwrap_or_else(|| "dax j".into());
    let lq = args.get(1).cloned().unwrap_or_else(|| "hard techno".into());
    let mut d = Desk::open(false);
    assert!(d.house().is_some(), "not signed in");
    println!("signed in as {:?}", d.house().map(|h| h.1.map(str::to_owned)));
    println!("tools: {:?}", d.fetch_tools());

    d.open_shelf(Shelf::Search(q.clone()));
    assert!(wait(&mut d, 60, |d| !d.library().found_loading), "the search answered");
    let found = d.library().found.clone();
    println!("“{q}”: {} rows from elsewhere, notes {:?}", found.len(), d.library().found_notes);
    let sc = found.iter().find(|f| f.place == "soundcloud" && f.plays() && !f.known).cloned();
    let yt = found.iter().find(|f| f.place == "ytmusic" && f.plays() && !f.known).cloned();
    for f in [&sc, &yt].into_iter().flatten() {
        println!("get {} · {} — {}", f.place, f.title, f.subtitle);
        d.get_found(f);
    }
    let ok = wait(&mut d, 420, |d| {
        [&sc, &yt].into_iter().flatten().all(|f| d.getting(f).is_some_and(|v| v.ready || v.error.is_some()))
    });
    for f in [&sc, &yt].into_iter().flatten() {
        println!("  {} → {:?}", f.place, d.getting(f).map(|v| (v.words, v.here, v.ready, v.error)));
    }
    println!("songs done in time: {ok}");

    // a list: opened, then taken whole ("-": not this time)
    if lq == "-" {
        return;
    }
    d.open_shelf(Shelf::Search(lq.clone()));
    assert!(wait(&mut d, 60, |d| !d.library().found_loading));
    let lists: Vec<_> = d.library().found.iter().filter(|f| f.is_list() && f.place != "library").cloned().collect();
    println!("“{lq}”: {} lists", lists.len());
    let small = lists.iter().filter(|f| f.place == "bandcamp").min_by_key(|f| f.tracks.unwrap_or(99)).or(lists.first()).cloned();
    if let Some(f) = small {
        d.open_found(&f);
        assert!(wait(&mut d, 60, |d| !d.library().found_loading));
        println!("opened {} · {}: {} songs, error {:?}", f.place, f.title, d.library().found.len(), d.library().error);
        let before = d.library().playlists.len();
        d.take_found_list(&f);
        let made = wait(&mut d, 90, |d| d.library().playlists.len() > before || d.library().playlists.iter().any(|p| p.name == f.title));
        println!("taken as a playlist: {made} ({} playlists now)", d.library().playlists.len());
    }
}
