//! A real Automix transition from rkbx_link (see the note at the top of the capture).
use wo_rkbx::capture::{self, Replay};

fn load() -> Vec<capture::Heard> {
    let path = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/data/automix_transition.cap");
    capture::read(std::io::BufReader::new(std::fs::File::open(path).unwrap())).unwrap()
}

const GLAMOROUS: &str = "Glamorous (Janis €uro Dance Edit) FREE DL";
const MANGOO: &str = "Dj Mangoo - Euro Dance (Arweenn Nostalgic Mix)";

#[test]
fn the_transition_reads_as_it_happened() {
    let mut r = Replay::new(load());

    // Glamorous alone, on deck 1, the master
    let v = r.until(150.0).view(150.0);
    assert_eq!(v.decks[1].title, GLAMOROUS);
    assert!(v.decks[1].playing && !v.decks[0].playing);
    assert_eq!((v.master, v.lead), (Some(1), Some(1)));

    // Automix brings Dj Mangoo in on deck 0: both play, Glamorous still leads
    let v = r.until(156.0).view(156.0);
    assert!(v.decks[0].playing && v.decks[1].playing);
    assert_eq!(v.decks[0].title, MANGOO);
    assert_eq!((v.master, v.lead), (Some(1), Some(1)));

    // Glamorous ends, Go Solo is loaded on deck 1: /master names Go Solo for a moment,
    // which must not count; the lead is the deck that plays
    let v = r.until(158.3).view(158.3);
    assert_eq!(v.decks[1].title, "Go Solo [Tekk]");
    assert_eq!(v.decks[1].loads, 2);
    // its phrase came just before its title, and is kept
    assert_eq!(v.decks[1].phrase, Some(wo_rkbx::PhraseKind::Intro));
    assert!(!v.decks[1].playing);
    assert_eq!(v.master, Some(1));
    assert_eq!(v.lead, Some(0));

    // and then rekordbox's master moves to deck 0 for good
    let v = r.until(160.0).view(160.0);
    assert_eq!((v.master, v.lead), (Some(0), Some(0)));
    assert!(v.decks.iter().all(|d| d.jumps == 0));
}

#[test]
fn positions_carried_on_meet_the_next_message() {
    // Before each position message, where the feed thought the deck was; Automix ramps
    // the incoming deck's tempo here, so this also tests the rate.
    let heard = load();
    let mut r = Replay::new(Vec::new());
    let mut worst = 0.0f64;
    let mut n = 0;
    for h in heard {
        let deck = match h.msg.addr.as_str() {
            "/0/time" => 0,
            "/1/time" => 1,
            _ => usize::MAX,
        };
        if deck < 2 && h.t > 148.5 {
            let v = r.feed.view(h.t);
            let d = &v.decks[deck];
            if let (true, Some(p), Some(got)) = (d.playing, d.position, h.msg.num()) {
                worst = worst.max((p - got).abs());
                n += 1;
            }
        }
        r.feed.apply(&h.msg, h.t);
    }
    eprintln!("worst carried-on error {:.1} ms over {n} checks", worst * 1000.0);
    assert!(n > 500, "{n} checks");
    // one message period is ~20 ms; rkbx_link's own sending jitters by about that
    assert!(worst < 0.030, "worst carried-on error {:.1} ms over {n}", worst * 1000.0);
}
