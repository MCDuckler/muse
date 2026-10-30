//! The bake-off's Slint Desk: ui/desk.slint filled from wo-deskcore once a frame.
//! A frame drawn asks for the next update (rendering notifier → a zero timer), so the
//! booth moves at the display's rate. `--bench 30 [--out DIR]` measures it.
use std::cell::RefCell;
use std::fmt::Write as _;
use std::rc::Rc;
use std::time::{Duration, Instant};

use slint::{Color, ComponentHandle, Image, ModelRc, Rgba8Pixel, SharedPixelBuffer, SharedString, VecModel};
use wo_deskcore::bench::Bench;
use wo_deskcore::theme::{self, Rgba};
use wo_deskcore::{Desk, MIX_BARS, PadKind, Row, Snapshot};

slint::include_modules!();

fn color(v: Rgba) -> Color {
    Color::from_argb_u8(v[3], v[0], v[1], v[2])
}

fn image(b: wo_deskcore::Backdrop) -> Image {
    let mut buf = SharedPixelBuffer::<Rgba8Pixel>::new(b.width, b.height);
    buf.make_mut_bytes().copy_from_slice(&b.rgba);
    Image::from_rgba8(buf)
}

fn model<T: Clone + 'static>(v: Vec<T>) -> ModelRc<T> {
    ModelRc::new(VecModel::from(v))
}

/// Premultiplied "over" of `c` (straight RGB, alpha `a`) onto one pixel.
fn over(p: &mut Rgba8Pixel, c: Rgba, a: f32) {
    let k = 1.0 - a;
    p.r = (c[0] as f32 * a + p.r as f32 * k) as u8;
    p.g = (c[1] as f32 * a + p.g as f32 * k) as u8;
    p.b = (c[2] as f32 * a + p.b as f32 * k) as u8;
    p.a = (255.0 * a + p.a as f32 * k) as u8;
}

/// A waveform drawn here, a pixel column at a time: beat and bar lines, the three bands
/// mirrored around the middle, the part already played dimmed. One image a frame.
fn wave_image(cols: &[[f32; 3]], l: &wo_deskcore::Lines, tint: Rgba, tint2: Rgba, w: usize, h: usize, past: bool) -> Image {
    let mut buf = SharedPixelBuffer::<Rgba8Pixel>::new(w as u32, h as u32);
    let px = buf.make_mut_slice();
    let mid = h as f32 / 2.0;
    let scale = h as f32 / 112.0;
    let column = |px: &mut [Rgba8Pixel], x: usize, y0: f32, y1: f32, c: Rgba, a: f32| {
        let (y0, y1) = (y0.max(0.0) as usize, (y1.ceil() as usize).min(h));
        for y in y0..y1 {
            over(&mut px[y * w + x], c, a);
        }
    };
    for (xs, a) in [(&l.beats, 0.10), (&l.bars, 0.30)] {
        for &x in xs.iter() {
            let x = x.round() as usize;
            if x < w {
                column(px, x, 0.0, h as f32, [255; 4], a);
            }
        }
    }
    for (x, c) in cols.iter().enumerate().take(w) {
        for (k, (amp, color, a)) in [(50.0, tint, 0.92), (30.0, tint2, 0.9), (16.0, theme::HIGH, 0.85)].into_iter().enumerate() {
            let half = c[k] * amp * scale;
            column(px, x, mid - half, mid + half, color, a);
        }
        if past && x < w / 2 {
            column(px, x, 0.0, h as f32, theme::GROUND, 0.42);
        }
    }
    Image::from_rgba8_premultiplied(buf)
}

fn lines(xs: impl Iterator<Item = f32>, h: f32) -> SharedString {
    let mut s = String::new();
    for x in xs {
        let _ = write!(s, "M{x:.1} 0 L{x:.1} {h} ");
    }
    s.into()
}

fn mmss(s: f64) -> String {
    let s = s.max(0.0);
    format!("{}:{:04.1}", (s / 60.0) as u32, s % 60.0)
}

fn pad_name(k: PadKind) -> &'static str {
    match k {
        PadKind::Intro => "INTRO",
        PadKind::Drop => "DROP",
        PadKind::Break => "BREAK",
        PadKind::Out => "OUT",
    }
}

fn level(peak: f32) -> f32 {
    (1.0 + 20.0 * peak.max(1e-6).log10() / 48.0).clamp(0.0, 1.0)
}

fn deck_data(desk: &Desk, s: &Snapshot, d: usize, wave_w: f32) -> DeckData {
    let v = &s.decks[d];
    let (cols, l) = desk.waveform(d, v.heard, wave_w, 1.0, 110.0);
    let ow = (wave_w - 120.0).max(10.0);
    let ov = desk.overview(d, ow as usize);
    let len = v.length.max(1.0);
    let pads: Vec<PadData> = v
        .pads
        .iter()
        .enumerate()
        .map(|(i, p)| match p {
            Some(p) => PadData { n: p.n.to_string().into(), name: pad_name(p.kind).into(), tint: color(theme::pad(p.kind)), set: true },
            None => PadData { n: (i + 1).to_string().into(), name: "".into(), tint: color(theme::FAINT), set: false },
        })
        .collect();
    let state = if v.master { "MASTER · PLAYING" } else if v.synced { "SYNC · IN STEP" } else if v.playing { "PLAYING" } else { "PARKED" };
    let pitch = (v.rate - 1.0) * 100.0;
    DeckData {
        letter: ["A", "B"][d].into(),
        tint: color(theme::DECKS[d]),
        tint2: color(theme::TINTS[d]),
        title: v.record.title.as_str().into(),
        artist: v.record.artist.as_str().into(),
        initials: v.record.initials().into(),
        sleeve: color(theme::sleeve(v.record.id)),
        bpm: format!("{:.2}", v.bpm).into(),
        pitch: format!("{pitch:+.2}%").into(),
        key: if v.record.key.is_empty() { "—".into() } else { v.record.key.as_str().into() },
        left: format!("−{}", mmss(v.length - v.heard)).into(),
        gone: mmss(v.heard).into(),
        state: state.into(),
        playing: v.playing,
        synced: v.synced,
        master: v.master,
        keylock: v.keylock,
        gain: v.gain,
        hi: v.eq[2],
        mid: v.eq[1],
        low: v.eq[0],
        filter: v.filter,
        fader: v.fader,
        level: level(v.peak),
        pitch_pos: ((v.rate - 1.0) / 0.08).clamp(-1.0, 1.0) as f32,
        pads1: model(pads[..4].to_vec()),
        pads2: model(pads[4..].to_vec()),
        wave: wave_image(&cols, &l, theme::DECKS[d], theme::TINTS[d], wave_w as usize, 112, true),
        flags: model(
            l.pads
                .iter()
                .map(|(x, p)| FlagData { x: *x, label: format!("{} {}", p.n, pad_name(p.kind)).into(), tint: color(theme::pad(p.kind)) })
                .collect(),
        ),
        overview: wave_image(&ov.iter().map(|c| [c[0] + 0.1, 0.0, 0.0]).collect::<Vec<_>>(), &Default::default(), theme::DECKS[d], theme::DECKS[d], ow as usize, 22, false),
        played: (v.heard / len).clamp(0.0, 1.0) as f32,
        cues: lines(v.pads.iter().flatten().map(|p| (ow as f64 * p.at / len) as f32), 22.0),
        remain: format!("−{}", mmss(v.length - v.heard)).into(),
    }
}

fn row_data(i: usize, r: &Row) -> RowData {
    let on = r.on_deck;
    RowData {
        i: (i + 1).to_string().into(),
        title: r.record.title.as_str().into(),
        artist: r.record.artist.as_str().into(),
        bpm: format!("{:.2}", r.record.bpm).into(),
        key: r.record.key.as_str().into(),
        time: format!("{}:{:02}", r.record.seconds / 60, r.record.seconds % 60).into(),
        fits: r.fits as i32,
        initials: r.record.initials().into(),
        sleeve: color(theme::sleeve(r.record.id)),
        deck: on.map(|d| ["A", "B"][d]).unwrap_or("").into(),
        deck_tint: color(theme::DECKS[on.unwrap_or(0)]),
        ink: color(if on.is_some() { theme::FAINT } else if r.record.playable() { theme::TEXT } else { theme::MUTED }),
        on_deck: on.is_some(),
    }
}

struct State {
    desk: Desk,
    bench: Option<Bench>,
    search: String,
    rows: Vec<Row>,
    rows_key: String,
    rows_model: Rc<VecModel<RowData>>,
    last_work: f32,
    finishing: bool,
    /// Slint's own drawing time per frame (rendering notifier: before → after).
    render_started: Option<Instant>,
    render_ms: Vec<f32>,
}

/// One frame's update: the Auto DJ advanced, every property set from a fresh snapshot.
fn update(ui: &AppWindow, st: &mut State) {
    let t0 = Instant::now();
    st.desk.tick();
    let s = st.desk.snapshot();
    // Before the window has a size the property reads 0 (or less): draw for the usual 1920.
    let w = match ui.get_wave_width() { w if w >= 64.0 => w, _ => 1894.0 };
    ui.set_deck_a(deck_data(&st.desk, &s, 0, w));
    ui.set_deck_b(deck_data(&st.desk, &s, 1, w));
    let master = s.decks.iter().position(|d| d.master).unwrap_or(0);
    ui.set_master_bpm(format!("{:.2}", s.master_bpm).into());
    ui.set_master_name(["DECK A", "DECK B"][master].into());
    ui.set_master_tint(color(theme::DECKS[master]));
    let set = s.set_seconds as u64;
    ui.set_set_time(format!("{}:{:02}:{:02}", set / 3600, set / 60 % 60, set % 60).into());
    ui.set_auto(s.auto);
    ui.set_load(s.load.average as f32);
    ui.set_load_text(format!("{:.0}%", s.load.average * 100.0).into());
    ui.set_crossfader(s.crossfader);
    match s.decks.iter().find(|d| d.synced) {
        Some(f) => {
            ui.set_phase_on(true);
            ui.set_phase_text(format!("{:+.1} ms", f.phase_ms).into());
            ui.set_phase_pos((f.phase_ms as f32 / 20.0).clamp(-1.0, 1.0));
        }
        None => ui.set_phase_on(false),
    }
    let (from, to) = s.mix.map(|m| (m.from, m.to)).unwrap_or((master, 1 - master));
    ui.set_mixing(s.mix.is_some());
    ui.set_mix_from(color(theme::DECKS[from]));
    ui.set_mix_to(color(theme::DECKS[to]));
    ui.set_mix_from_letter(["A", "B"][from].into());
    ui.set_mix_to_letter(["A", "B"][to].into());
    let bar = s.mix.map(|m| m.bar).unwrap_or(0.0);
    ui.set_mix_status(if s.mix.is_some() { format!("bar {:.0} / {:.0}", bar.floor() + 1.0, MIX_BARS) } else { "next soon".into() }.into());
    ui.set_mix_progress((bar / MIX_BARS).min(1.0) as f32);
    // The crate only when what it shows changed: the search, the decks, the tempo.
    let key = format!("{}|{}|{}|{:.0}", st.search, s.decks[0].record.id, s.decks[1].record.id, s.master_bpm);
    if key != st.rows_key {
        st.rows = st.desk.rows(&st.search, s.master_bpm);
        st.rows_model.set_vec(st.rows.iter().enumerate().map(|(i, r)| row_data(i, r)).collect::<Vec<_>>());
        st.rows_key = key;
        ui.set_next(model(
            s.up_next
                .iter()
                .take(4)
                .map(|r| NextData {
                    title: r.title.as_str().into(),
                    artist: r.artist.as_str().into(),
                    meta: format!("{:.0} · {}", r.bpm, r.key).into(),
                    initials: r.initials().into(),
                    sleeve: color(theme::sleeve(r.id)),
                })
                .collect(),
        ));
    }
    ui.window().request_redraw();
    st.last_work = t0.elapsed().as_secs_f32() * 1000.0;
}

fn main() -> Result<(), slint::PlatformError> {
    // femtovg (OpenGL) unless WO_RENDERER=skia: the bake-off measures both.
    let skia = std::env::var("WO_RENDERER").as_deref() == Ok("skia");
    slint::BackendSelector::new().backend_name("winit".into()).renderer_name(if skia { "skia" } else { "femtovg" }.into()).select()?;
    let ui = AppWindow::new()?;
    ui.set_backdrop(image(wo_deskcore::backdrop::backdrop(480, 270)));
    ui.set_ball(image(wo_deskcore::backdrop::ball()));
    let rows_model = Rc::new(VecModel::<RowData>::default());
    ui.set_rows(ModelRc::from(rows_model.clone()));
    let st = Rc::new(RefCell::new(State {
        desk: Desk::open(),
        bench: Bench::from_args(if skia { "slint-skia" } else { "slint-femtovg" }),
        search: String::new(),
        rows: vec![],
        rows_key: String::new(),
        rows_model,
        last_work: 0.0,
        finishing: false,
        render_started: None,
        render_ms: vec![],
    }));

    macro_rules! with {
        ($st:ident, $body:expr) => {{
            let $st = st.clone();
            $body
        }};
    }
    ui.on_play(with!(st, move |d| st.borrow_mut().desk.toggle_play(d as usize)));
    ui.on_sync(with!(st, move |d| st.borrow_mut().desk.toggle_sync(d as usize)));
    ui.on_keylock(with!(st, move |d| st.borrow_mut().desk.toggle_keylock(d as usize)));
    ui.on_pad(with!(st, move |d, i| st.borrow_mut().desk.jump_to_pad(d as usize, i as usize)));
    ui.on_knob(with!(st, move |d, k, v| {
        let desk = &mut st.borrow_mut().desk;
        let d = d as usize;
        match k {
            0 => desk.set_gain(d, v),
            1 => desk.set_eq(d, 2, v),
            2 => desk.set_eq(d, 1, v),
            3 => desk.set_eq(d, 0, v),
            _ => desk.set_filter(d, v),
        }
    }));
    ui.on_fader(with!(st, move |d, v| st.borrow_mut().desk.set_fader(d as usize, v)));
    ui.on_crossfade(with!(st, move |v| {
        let mut s = st.borrow_mut();
        s.desk.set_auto(false);
        s.desk.set_crossfader(v);
    }));
    ui.on_toggle_auto(with!(st, move || {
        let mut s = st.borrow_mut();
        let on = s.desk.snapshot().auto;
        s.desk.set_auto(!on);
    }));
    ui.on_search_edited(with!(st, move |text| st.borrow_mut().search = text.to_string()));
    ui.on_load_row(with!(st, move |i| {
        let mut s = st.borrow_mut();
        let Some(row) = s.rows.get(i as usize).cloned() else { return };
        let snap = s.desk.snapshot();
        if row.record.playable() && row.on_deck.is_none() && snap.mix.is_none() {
            let free = snap.decks.iter().position(|d| !d.master).unwrap_or(1);
            s.desk.load(free, row.record);
        }
    }));

    update(&ui, &mut st.borrow_mut());
    let weak = ui.as_weak();
    let st2 = st.clone();
    ui.window()
        .set_rendering_notifier(move |state, _| {
            // take_snapshot() renders too, from inside the update that holds the state: skip it.
            let Ok(mut s) = st2.try_borrow_mut() else { return };
            if matches!(state, slint::RenderingState::BeforeRendering) {
                s.render_started = Some(Instant::now());
                return;
            }
            if !matches!(state, slint::RenderingState::AfterRendering) {
                return;
            }
            if let Some(t) = s.render_started.take() {
                s.render_ms.push(t.elapsed().as_secs_f32() * 1000.0);
            }
            drop(s);
            let (weak, st) = (weak.clone(), st2.clone());
            slint::Timer::single_shot(Duration::ZERO, move || {
                let Some(ui) = weak.upgrade() else { return };
                let mut s = st.borrow_mut();
                let work = s.last_work;
                let done = match s.bench.as_mut() {
                    Some(b) => {
                        let size = ui.window().size();
                        b.size = (size.width, size.height);
                        b.frame(work)
                    }
                    None => false,
                };
                if done && !s.finishing {
                    s.finishing = true;
                    let shot = ui.window().take_snapshot().ok();
                    let report = s.bench.as_mut().unwrap().finish(shot.as_ref().map(|b| (b.width(), b.height(), b.as_bytes())));
                    println!("{report}");
                    let mut r = s.render_ms.clone();
                    r.sort_by(|a, b| a.total_cmp(b));
                    if !r.is_empty() {
                        println!("slint render ms: p50 {:.2} p95 {:.2} max {:.2}", r[r.len() / 2], r[r.len() * 95 / 100], r[r.len() - 1]);
                    }
                    let _ = slint::quit_event_loop();
                    return;
                }
                update(&ui, &mut s);
            });
        })
        .map_err(|e| slint::PlatformError::Other(format!("{e:?}")))?;
    ui.run()
}
