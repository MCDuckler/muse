//! The Stage's wire on a real Desk, silently: a stage connecting as the v1 window does
//! hears hello and then a frame each tick — the playing deck, where its ear is, what
//! the engine heard of it — the hands it is sent, and its picture comes back.
use std::thread::sleep;
use std::time::{Duration, Instant};

use tungstenite::Message;
use wo_deskcore::{Desk, ShowHand};

#[test]
fn a_stage_reads_the_desk() {
    let empty = std::env::temp_dir().join(format!("wo-stage-{}", std::process::id()));
    std::fs::create_dir_all(&empty).unwrap();
    // SAFETY: before any thread reads the environment.
    unsafe {
        std::env::set_var("WO_AUDIO", "off");
        std::env::set_var("WO_CONTROLLERS", "off");
        std::env::set_var("WO_RECORDS", &empty);
    }
    let mut d = Desk::open(true);
    assert_eq!(d.stage().stages, 0);
    let url = d.stage_url().unwrap();
    let (mut ws, _) = tungstenite::connect(&url).unwrap();
    let tungstenite::stream::MaybeTlsStream::Plain(tcp) = ws.get_ref() else { unreachable!() };
    tcp.set_read_timeout(Some(Duration::from_millis(20))).unwrap();
    assert_eq!(ws.read().unwrap().to_text().unwrap(), r#"{"t":"hello","v":1,"from":"desk"}"#);

    // frames, tick by tick; the playing deck's ear moves on, and the engine hears it
    // (once the record is made: the first frames are silence)
    let heard = |f: &serde_json::Value| f["d"]["heard"]["master"]["low"].as_f64().unwrap_or(0.0) > 0.0;
    let mut frames = vec![];
    let t0 = Instant::now();
    while (frames.len() < 20 || !frames.iter().any(heard)) && t0.elapsed() < Duration::from_secs(10) {
        d.tick();
        if let Ok(Message::Text(t)) = ws.read() {
            assert!(t.starts_with(r#"{"t":"desk""#), "{t}");
            frames.push(serde_json::from_str::<serde_json::Value>(&t).unwrap());
        }
        sleep(Duration::from_millis(5));
    }
    assert!(frames.len() >= 20, "{} frames", frames.len());
    assert_eq!(d.stage().stages, 1);
    let a = |f: &serde_json::Value| f["d"]["a"].clone();
    let (first, last) = (a(&frames[0]), a(&frames[frames.len() - 1]));
    assert_eq!(last["playing"], true);
    let moved = last["positionMs"].as_f64().unwrap() - first["positionMs"].as_f64().unwrap();
    assert!(moved > 100.0, "the ear moved {moved} ms");
    assert!(last["rate"].as_f64().unwrap() > 0.9);
    assert!(last["level"].as_f64().unwrap() > 0.5, "A has the room");
    assert!(frames.iter().any(heard), "the engine heard nothing");
    assert!(frames.iter().any(|f| f["d"]["a"]["heard"]["low"].as_f64().unwrap_or(0.0) > 0.0), "nothing heard of A");
    assert_eq!(frames[frames.len() - 1]["d"]["heard"]["spectrum"].as_array().map(Vec::len), Some(32));
    assert_eq!(a(&frames[0]).get("trackId"), None, "a synthesised record is none of the house's");

    // the hands reach the stage
    d.show(ShowHand::Blackout(true));
    let mut hands = None;
    for _ in 0..50 {
        if let Ok(Message::Text(t)) = ws.read()
            && t.starts_with(r#"{"t":"hands""#) {
                hands = Some(t.to_string());
                break;
            }
    }
    assert_eq!(hands.as_deref(), Some(r#"{"t":"hands","do":"blackout","on":true}"#));
    assert!(d.stage().blackout);

    // and the picture comes back, with what is on
    let mut pic = vec![2, 0, 1, 0];
    pic.extend([10, 20, 30, 255, 40, 50, 60, 255]);
    ws.send(Message::binary(pic)).unwrap();
    ws.send(Message::text(r#"{"t":"shown","scene":"tunnel","held":true}"#)).unwrap();
    let t0 = Instant::now();
    while d.stage().scene.is_none() && t0.elapsed() < Duration::from_secs(3) {
        sleep(Duration::from_millis(10));
    }
    let v = d.stage();
    assert_eq!((v.scene.as_deref(), v.held), (Some("tunnel"), true));
    let (_, thumb) = d.stage_thumb().unwrap();
    assert_eq!((thumb.width, thumb.height, thumb.rgba[4]), (2, 1, 40));
}
