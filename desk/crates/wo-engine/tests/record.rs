//! REC: what the master puts out is what is kept, sample for sample, from REC on.
use wo_engine::{Channels, DeckId, Engine, Gains, Output};

#[test]
fn the_recording_is_the_master() {
    let e = Engine::start(Some(48_000), Output::Offline).unwrap();
    let a = DeckId::new(0).unwrap();
    let n = 48_000 * 3;
    let pcm: Vec<i16> = (0..n).flat_map(|i| {
        let v = ((i as f64 * 330.0 * std::f64::consts::TAU / 48_000.0).sin() * 9000.0) as i16;
        [v, v]
    }).collect();
    let mut src = e.new_source(Channels::Stereo, n as i64).unwrap();
    src.append(&pcm).unwrap();
    src.finish();
    let deck = e.deck(a);
    deck.set_source(0, &src);
    deck.set_gains(0, Gains::FULL, 0.0);
    deck.set_level(1.0, 0.0);
    deck.play(true);
    let mut m = vec![0f32; 960];
    let mut outs: [Option<&mut [f32]>; 4] = [None, None, None, None];
    e.render(&mut m, &mut outs).unwrap();
    e.record(true);
    let mut heard = vec![];
    for _ in 0..100 {
        let mut outs: [Option<&mut [f32]>; 4] = [None, None, None, None];
        e.render(&mut m, &mut outs).unwrap();
        heard.extend_from_slice(&m);
    }
    e.record(false);
    let mut kept = vec![0f32; heard.len() + 1000];
    let (frames, lost) = e.record_read(&mut kept);
    assert_eq!(lost, 0);
    assert_eq!(frames * 2, heard.len(), "every frame from REC on");
    assert_eq!(&kept[..frames * 2], &heard[..], "the master itself");
    assert!(heard.iter().any(|v| v.abs() > 0.05), "something played");
}
