//! Follow mode without rekordbox: a recorded rkbx_link feed (wo-rkbx's capture format) is
//! sent over UDP, on its own clock, to a Desk that follows it; once a second it says what
//! each deck has, where it is against rekordbox, and the mix. Needs the records' audio and
//! rekordbox's library on this computer (the capture's titles must be in it).
//!
//! `follow_replay [capture] [--skip <from>-<to>]` (default: wo-rkbx's Automix fixture,
//! skipping its gap 1–147.5 s); `follow_replay --live <seconds>`: rekordbox itself (rkbx_link
//! sending to its usual port), nothing replayed.
use std::net::UdpSocket;
use std::time::{Duration, Instant};

fn main() {
    // no house, no set taken up again, no sound card
    unsafe {
        std::env::set_var("WO_HOUSE", "off");
        std::env::set_var("WO_RESUME", "off");
    }
    let a: Vec<String> = std::env::args().skip(1).collect();
    let fixture = concat!(env!("CARGO_MANIFEST_DIR"), "/../wo-rkbx/tests/data/automix_transition.cap");
    let path = a.first().filter(|p| !p.starts_with("--")).cloned().unwrap_or_else(|| fixture.into());
    let skip = a.windows(2).find(|w| w[0] == "--skip").and_then(|w| w[1].split_once('-').and_then(|(x, y)| Some((x.parse::<f64>().ok()?, y.parse::<f64>().ok()?))));
    let skip = skip.or((path == fixture).then_some((1.0, 147.5)));
    let live: Option<f64> = a.windows(2).find(|w| w[0] == "--live").and_then(|w| w[1].parse().ok());
    let heard = if live.is_some() { vec![] } else { wo_rkbx::capture::read(std::io::BufReader::new(std::fs::File::open(&path).expect("the capture"))).expect("a capture") };
    // its clock, the gap taken out
    let at = |t: f64| match skip {
        Some((x, y)) if t >= y => t - (y - x),
        _ => t,
    };
    let port = UdpSocket::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port();
    let addr = if live.is_some() { wo_rkbx::listen::DEFAULT_ADDR.to_owned() } else { format!("127.0.0.1:{port}") };
    let mut desk = wo_deskcore::Desk::open_following(wo_deskcore::FollowOptions { addr: addr.clone(), ..Default::default() }).expect("following");
    // the library first, as at a gig (rkbx_link starts after)
    let t0 = Instant::now();
    while desk.following().unwrap().library.is_none() && t0.elapsed() < Duration::from_secs(20) {
        desk.tick();
        std::thread::sleep(Duration::from_millis(16));
    }
    println!("library: {:?} records in {} ms", desk.following().unwrap().library, t0.elapsed().as_millis());
    let tx = UdpSocket::bind("127.0.0.1:0").unwrap();
    let end = live.unwrap_or_else(|| heard.last().map_or(0.0, |h| at(h.t)) + 1.0);
    let start = Instant::now();
    let mut next = 0;
    let mut said = 0.0;
    let mut worst = [0.0f64; 2];
    let mut start_worst = [0.0f64; 2];
    // any tick, playing or not, once the first records are in (a load's own glitch shows here)
    let mut any_worst = [0.0f64; 2];
    let mut playing_since: [Option<f64>; 2] = [None; 2];
    while start.elapsed().as_secs_f64() < end {
        let now = start.elapsed().as_secs_f64();
        while let Some(h) = heard.get(next).filter(|h| at(h.t) <= now) {
            let _ = tx.send_to(&wo_rkbx::osc::encode(&h.msg), &addr);
            next += 1;
        }
        desk.tick();
        let fv = desk.following().unwrap();
        // the drift in a deck's first second of playing, and after
        for d in 0..2 {
            if let (true, Some(ms)) = (now > 4.0, fv.decks[d].drift_ms) {
                any_worst[d] = any_worst[d].max(ms.abs());
            }
            if !fv.decks[d].playing {
                playing_since[d] = None;
                continue;
            }
            let since = *playing_since[d].get_or_insert(now);
            if let Some(ms) = fv.decks[d].drift_ms {
                let w = if now - since < 1.0 { &mut start_worst[d] } else { &mut worst[d] };
                *w = w.max(ms.abs());
            }
        }
        if now - said >= 1.0 {
            said = now;
            let s = desk.snapshot();
            let mut line = format!("{now:5.1}s lead={:?} x={:.2} master={}", fv.lead, desk.crossfader(), desk.master());
            for d in 0..2 {
                let f = &fv.decks[d];
                let v = &s.decks[d];
                let form = desk.form(d);
                line.push_str(&format!(
                    " | {d}: {:?} {} found={:?} at {:.2}s drift={} decoded={:.0}% sections={}",
                    v.record.title,
                    if v.playing { "▶" } else { "■" },
                    f.found,
                    v.heard,
                    f.drift_ms.map_or("-".into(), |m| format!("{m:+.0}ms")),
                    v.decoded * 100.0,
                    form.sections.len()
                ));
            }
            println!("{line}");
        }
        std::thread::sleep(Duration::from_millis(16));
    }
    println!("worst drift, a deck's first second of playing: deck 0 {:.0} ms, deck 1 {:.0} ms", start_worst[0], start_worst[1]);
    println!("worst drift, settled (after that second): deck 0 {:.0} ms, deck 1 {:.0} ms", worst[0], worst[1]);
    println!("worst drift on any tick after 4 s: deck 0 {:.0} ms, deck 1 {:.0} ms", any_worst[0], any_worst[1]);
}
