//! Lists the outputs, routes as asked and plays deck A (440 Hz) in the headphones only and
//! deck B (660 Hz) on air, for checking where each goes on real (or null) sinks.
//! `route_probe [master|-] [master_ch] [cue|-|split|none] [cue_ch] [seconds]`
use wo_engine::{Channels, Cue, DeckId, Engine, Gains, Output, Route};

fn main() {
    for o in wo_engine::outputs() {
        println!("{:>2} ch{}  {}", o.channels, if o.is_default { " *" } else { "  " }, o.name);
    }
    let a: Vec<String> = std::env::args().skip(1).collect();
    let arg = |i: usize| a.get(i).cloned().unwrap_or_default();
    let name = |s: String| if s.is_empty() || s == "-" { None } else { Some(s) };
    let cue = match arg(2).as_str() {
        "none" | "" => Cue::None,
        "split" => Cue::Split,
        s => Cue::Device { name: name(s.to_owned()), ch: arg(3).parse().unwrap_or(0) },
    };
    let route = Route { master: name(arg(0)), master_ch: arg(1).parse().unwrap_or(0), cue };
    let secs: f64 = arg(4).parse().unwrap_or(3.0);
    let e = Engine::start(Some(48_000), Output::Device).expect("engine");
    println!("route {route:?}: {:?}", e.route(&route));
    println!("state {:?}", e.route_state());
    let tone = |hz: f64| {
        let n = (secs * 48_000.0) as usize + 48_000;
        let pcm: Vec<i16> = (0..n * 2).map(|i| ((std::f64::consts::TAU * hz * (i / 2) as f64 / 48_000.0).sin() * 0.3 * 32767.0) as i16).collect();
        let mut s = e.new_source(Channels::Stereo, n as i64).unwrap();
        s.append(&pcm).unwrap();
        s.finish();
        s
    };
    let (sa, sb) = (tone(440.0), tone(660.0));
    for (d, s, level) in [(0, &sa, 0.0), (1, &sb, 1.0)] {
        let deck = e.deck(DeckId::new(d).unwrap());
        deck.set_source(0, s);
        deck.set_gains(0, Gains::FULL, 0.0);
        deck.set_level(level, 0.0);
        deck.play(true);
    }
    e.deck(DeckId::new(0).unwrap()).set_cue(1.0, 0.0);
    e.set_cue_mix(0.0, 1.0);
    std::thread::sleep(std::time::Duration::from_secs_f64(secs));
    println!("state {:?}", e.route_state());
}
