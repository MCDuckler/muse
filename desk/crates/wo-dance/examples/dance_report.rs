//! How a record is danced, measured: the choreography run over the house's analysis of a
//! record (GET /tracks/{id}/analysis?structure=1, saved as JSON), a line per slot — the
//! section, how loud, the mood, the lead's move, how fast its capture is played and how fast
//! the body really moves (the key joints' mean speed, m/s).
//!   cargo run --release -p wo-dance --example dance_report -- <analysis.json> [dance dir] [dancer]
use std::path::PathBuf;
use wo_dance::clock::Troupe;
use wo_dance::sim::{Company, DanceSim};
use wo_show::deck::{RecordFacts, Section, ShowAudio, ShowDeck};
use wo_show::state::ShowState;

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let a: serde_json::Value = serde_json::from_slice(&std::fs::read(&args[0]).expect("the analysis")).expect("json");
    let dir = args.get(1).map(PathBuf::from).unwrap_or_else(|| PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../app/assets/show/dance"));
    let co = Company::load(&dir).expect("the dancers");
    let f = |v: &serde_json::Value| v.as_f64().unwrap_or(0.0);
    let list = |v: &serde_json::Value| v.as_array().cloned().unwrap_or_default();
    let beats: Vec<f64> = list(&a["beats"]).iter().map(f).collect();
    let bar_one = a["bar_starts_on"].as_i64().unwrap_or(0);
    let st = &a["structure"];
    // both passes' drops, as the Desk gives the show (wo_house::all_drops)
    let mut drops: Vec<serde_json::Value> = list(&st["drops_ms"]);
    for e in list(&a["drops"]) {
        if !drops.iter().any(|d| (f(d) - f(&e)).abs() <= 6000.0) {
            drops.push(e);
        }
    }
    drops.sort_by(|x, y| f(x).total_cmp(&f(y)));
    let facts = RecordFacts {
        track_id: Some(a["id"].as_i64().unwrap_or(24146)),
        downbeats_ms: beats.iter().enumerate().filter(|(i, _)| (*i as i64) >= bar_one && (*i as i64 - bar_one) % 4 == 0).map(|(_, b)| *b).collect(),
        beats_ms: beats.clone(),
        bar_starts_on: bar_one % 4,
        energy: list(&a["energy"]).iter().map(|e| f(e).clamp(0.0, 255.0) as u8).collect(),
        drops_ms: drops.iter().map(f).collect(),
        voice: {
            // as wo_house::voice_over_drums: the voice's share of the drummed sections
            let secs = if st["vocals_db"].is_array() { list(&st["sections"]) } else { vec![] };
            let known: Vec<&serde_json::Value> = secs.iter().filter(|x| x["vocals"].is_boolean()).collect();
            let drummed: Vec<&serde_json::Value> = known.iter().copied().filter(|x| x["drums"] == true).collect();
            let over = if drummed.is_empty() { known } else { drummed };
            let len = |x: &&serde_json::Value| f(&x["end_ms"]) - f(&x["start_ms"]);
            let total: f64 = over.iter().map(len).sum();
            (total > 0.0).then(|| over.iter().filter(|x| x["vocals"] == true).map(len).sum::<f64>() / total)
        },
        sections: list(&st["sections"]).iter().map(|s| Section { label: s["label"].as_str().unwrap_or("").into(), start_ms: f(&s["start_ms"]), end_ms: f(&s["end_ms"]) }).collect(),
        ..Default::default()
    };
    let who = args.get(2).cloned();
    if let Ok(spec) = std::env::var("POOL") {
        // POOL=<bpm>,<intensity>: what a techno record at that tempo would dance, with the weights
        let v: Vec<f64> = spec.split(',').filter_map(|x| x.parse().ok()).collect();
        let (bpm, level) = (v[0], v[1]);
        let rig = &co.rigs[0].1;
        let bank: Vec<usize> = (0..rig.moves.len()).collect();
        let mood = if level >= 0.85 { wo_dance::clock::Mood::Rage } else if level < 0.2 { wo_dance::clock::Mood::Sleep } else { wo_dance::clock::Mood::Vibe };
        let fl = wo_dance::clock::flavour(24146, bpm, mood, false, true, level);
        let pool = wo_dance::clock::pool(&rig.moves, &bank, level, &fl, bpm, &[], true, level < 0.2, false, 0.0);
        let own: Vec<usize> = wo_dance::clock::own_moves(&pool, &rig.moves, 24146).iter().map(|e| e.0).collect();
        let total: f64 = pool.iter().map(|e| e.1).sum();
        for (i, w) in pool.iter().take(24) {
            let m = &rig.moves[*i];
            let (r, fit) = wo_dance::clock::playing(bpm, m, level, true, level < 0.2);
            println!("{:<28} {:<7} {:<5} share {:>5.1}% rate {:.2} fit {:.2} pulse {:.2} m/s {:.2} {}", m.id, m.style, m.tier, 100.0 * w / total, r, fit, m.pulse, wo_dance::clock::speed(bpm, m, r), if own.contains(i) { "OWN" } else { "" });
        }
        return;
    }
    if std::env::var_os("MOVES").is_some() {
        // every move: how fast it is at its own tempo, and what it bounces like
        let mut ms: Vec<&wo_dance::Move> = co.rigs[0].1.moves.iter().filter(|m| m.duo.is_none()).collect();
        ms.sort_by(|a, b| (b.travel * b.bpm).total_cmp(&(a.travel * a.bpm)));
        for m in ms {
            println!("{:<30} {:<7} {:<5} bpm {:>5.0} pulse {:.2} m/beat {:.2} m/s {:.2} hands {:.2}", m.id, m.style, m.tier, m.bpm, m.pulse, m.travel, m.travel * m.bpm / 60.0, m.hands_up);
        }
        return;
    }
    let mut sim = DanceSim::default();
    sim.forced_troupe = Some(Troupe::Solo);
    let rig = &co.rigs[0].1;
    let keys: Vec<usize> = ["Hips", "Head", "Hand_L", "Hand_R", "LowerArm_L", "LowerArm_R", "Foot_L", "Foot_R", "LowerLeg_L", "LowerLeg_R"].iter().filter_map(|n| rig.bone(n)).collect();
    let dt = 1.0 / 60.0;
    let end = beats.last().copied().unwrap_or(0.0);
    let (mut was, mut row): (Option<Vec<[f64; 3]>>, Option<(i64, String)>) = (None, None);
    let (mut sum, mut n, mut total, mut frames) = (0.0, 0usize, 0.0, 0usize);
    let mut by_section: Vec<(String, f64, usize)> = vec![];
    println!("voice over the drums: {:?}", facts.voice);
    println!("{:>6} {:>4} {:<10} {:>4} {:<5} {:<28} {:<7} {:<5} {:>5} {:>4} {:>5} {:>6}", "time", "slot", "section", "loud", "mood", "move", "style", "tier", "bpm", "rate", "speed", "m/s");
    let mut t = 0.0;
    while t * 1000.0 < end {
        let mut deck = ShowDeck::derive("A", Some(&facts), true, t * 1000.0, Default::default(), ShowAudio::SILENCE);
        deck.audio.low = 0.7;
        let mut state = ShowState { a: deck, dt, ..Default::default() };
        state.macros.dancer = who.clone();
        // the low end heard as loud as the bar is (the beat's pump goes by it)
        state.extra.insert("dyn.band.low".into(), state.a.energy);
        let s = sim.frame(&co, &state, dt, 1280.0, 720.0);
        let lead = s.bodies.iter().find(|b| b.lead).expect("a lead");
        let now: Vec<[f64; 3]> = keys.iter().map(|&k| [lead.world[k][3], lead.world[k][7], lead.world[k][11]]).collect();
        if let Some(w) = &was {
            let v = now.iter().zip(w).map(|(p, q)| ((p[0] - q[0]).powi(2) + (p[1] - q[1]).powi(2) + (p[2] - q[2]).powi(2)).sqrt()).sum::<f64>() / now.len() as f64 / dt;
            sum += v;
            n += 1;
            total += v;
            frames += 1;
            let sec = state.a.section.clone().unwrap_or_default();
            match by_section.last_mut() {
                Some(l) if l.0 == sec => {
                    l.1 += v;
                    l.2 += 1;
                }
                _ => by_section.push((sec, v, 1)),
            }
        }
        was = Some(now);
        let slot = (s.beats / 16.0).floor() as i64;
        let (mv, rate) = sim.lead_now().unwrap_or((0, 1.0));
        let m = &rig.moves[mv];
        let key = (slot, m.id.clone());
        if row.as_ref() != Some(&key) {
            if row.is_some() && n > 0 {
                println!(" {:>6.2}", sum / n as f64);
            }
            (sum, n) = (0.0, 0);
            let bpm = state.a.bpm.unwrap_or(0.0);
            print!(
                "{:>6.1} {:>4} {:<10} {:>4.2} {:<5} {:<28} {:<7} {:<5} {:>5.0} {:>4.1} {:>5.2}",
                t,
                slot,
                state.a.section.clone().unwrap_or_default(),
                state.a.energy,
                format!("{:?}", s.mood),
                m.id,
                m.style,
                m.tier,
                m.bpm,
                rate,
                bpm * rate / m.bpm
            );
            row = Some(key);
        }
        t += dt;
    }
    if n > 0 {
        println!(" {:>6.2}", sum / n as f64);
    }
    println!("\nby section (key joints' mean speed, m/s):");
    for (s, v, k) in &by_section {
        println!("  {:<10} {:>5.1} s  {:>5.2}", s, *k as f64 * dt, v / *k as f64);
    }
    println!("  whole record {:>5.2}", total / frames.max(1) as f64);
}
