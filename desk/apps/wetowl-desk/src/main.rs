//! WetOwl Desk: the glass booth of the Look board (design/tokens.json), painted by hand over
//! the live stage, blurred, driven by wo-deskcore. `--bench 30 [--out DIR]` measures it;
//! `--stage` opens the show's window from the start; `--page show` opens on the Show page,
//! `--page kit` on the kit's gallery (every control in every state); `--overlay keys` or
//! `--overlay settings` (or `milk`: MilkDrop's library) opens with that over it, `--show-tab dancers`
//! the Show page's card on that tab, `--show-room rotation` its left on the rotation, `--size
//! 1440x860` at that size (screenshots).
//!
//! The Desk keeps time on a thread of its own (the Auto DJ, the controllers, the stage's
//! frames), so the set goes on while the window is hidden — behind a full-screen stage,
//! say, where a compositor stops drawing it. The window takes the Desk for a frame, and
//! draws only when something moves: a record playing, a control easing, the clock's thread
//! telling it a controller or the house changed something.
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, mpsc};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use eframe::egui::{self, Color32, ColorImage, Rect, TextureHandle, TextureOptions, pos2};
use wo_deskcore::bench::Bench;
use wo_deskcore::{Desk, Prefs, ShowHand};

mod booth;
mod gallery;
mod overlays;
mod paint;
mod plan;
mod rotation;
mod scene;
mod stills;
mod set_page;
#[cfg(test)]
mod pages;
mod show;
mod ui;

use paint::fonts;
use ui::motion::{self, Ease};
use ui::tokens::Tone;

/// What is over the page.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Overlay {
    Keys,
    Settings,
    /// PLAN A SET.
    Set,
}

/// How the crate is sorted: by fit (the booth's own order), title, artist, tempo or key;
/// and the other way round.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub(crate) enum Sort {
    #[default]
    Fits,
    Title,
    Artist,
    Bpm,
    Key,
}

pub(crate) struct App {
    desk: Arc<Mutex<Desk>>,
    clock: Option<(Arc<AtomicBool>, JoinHandle<()>)>,
    /// The stage's picture, and which of its pictures it is.
    pub(crate) stage_pic: Option<(u64, TextureHandle)>,
    /// The light behind the glass.
    glass: Glass,
    ball: TextureHandle,
    search: String,
    bench: Option<Bench>,
    shot: Option<mpsc::Receiver<Arc<ColorImage>>>,
    /// CUE held, per deck (CUE acts on press and on release).
    cue_held: [bool; 2],
    /// The Auto DJ card's tab: the move (0), what is coming (1), the log (2).
    auto_tab: usize,
    /// The plan view over the waveforms (P).
    plan_open: bool,
    /// The set being shaped on the set page.
    set_shape: wo_deskcore::set::SetShape,
    /// The crate's "Fits the master" pressed (opened once the frame is drawn).
    fits_asked: bool,
    /// The nudge held, per deck.
    nudge_held: [i8; 2],
    /// The search as typed, when typing last changed it, what the house was last asked.
    search_at: Option<std::time::Instant>,
    searched: String,
    /// The sign-in form: house address, name, password; and whether the WetOwl app's
    /// sign-in is here to use.
    form: (String, String, String),
    app_sign_in: bool,
    /// The crate row a controller's browse is on.
    pub(crate) cursor: usize,
    /// The booth, the Show page (K), or the kit's gallery.
    pub(crate) page: show::Page,
    /// The stage's last word, and since when it shows.
    pub(crate) said: (u32, Option<Instant>),
    /// The strobe held down on the page.
    pub(crate) strobe: bool,
    /// The Show page's card under PERFORM: the hands (0), the dancers (1), the sets (2), the screen (3).
    pub(crate) show_tab: usize,
    /// The Show page's left: the stage (0), the rotation (1).
    pub(crate) show_room: usize,
    /// A scene's page open over the rotation, and the page's own state.
    pub(crate) show_scene: Option<String>,
    pub(crate) scene_ui: scene::SceneUi,
    /// MilkDrop's library open on the Show page, and what is searched for in it.
    pub(crate) milk_list: bool,
    pub(crate) milk_query: String,
    pub(crate) prefs: Prefs,
    pub(crate) sleeves: ui::Sleeves,
    pub(crate) toasts: ui::Toasts,
    pub(crate) overlay: Option<Overlay>,
    /// The overlay last up (drawn while it fades out).
    pub(crate) overlay_was: Option<Overlay>,
    pub(crate) sort: (Sort, bool),
    /// Each pad's presses, counted (a press flashes it).
    pub(crate) pad_fired: [[u64; 8]; 2],
    /// The waveforms' zoom: pixels a beat.
    pub(crate) zoom: f32,
    /// What the toasts last said of: the crate's trouble, the sign-in, the stage's trouble.
    seen: (Option<String>, bool, Option<String>),
}

/// The live stage behind the glass: its pictures blurred, crossfaded over [motion::GENTLE];
/// the still stage frame where no stage shows (or the settings ask for the still).
struct Glass {
    tex: [TextureHandle; 2],
    /// The texture drawn over the other, fading in since `at`.
    front: usize,
    at: Instant,
    still: ColorImage,
    on_still: bool,
    /// The stage picture the light last came from.
    from: u64,
}

impl Glass {
    fn new(ctx: &egui::Context) -> Glass {
        let b = wo_deskcore::backdrop::backdrop(480, 270);
        let still = ColorImage::from_rgba_unmultiplied([b.width as usize, b.height as usize], &b.rgba);
        let tex = [ctx.load_texture("glass 0", still.clone(), TextureOptions::LINEAR), ctx.load_texture("glass 1", still.clone(), TextureOptions::LINEAR)];
        Glass { tex, front: 0, at: Instant::now() - Duration::from_secs(1), still, on_still: true, from: 0 }
    }

    /// A new light, faded over the old (the stage's every [motion::GENTLE] at most, so each
    /// crossfade finishes: 10 pictures a second read as light moving, not flicker).
    fn update(&mut self, desk: &Desk, prefs: &Prefs) {
        let live = (!prefs.still_backdrop).then(|| desk.stage_thumb()).flatten().filter(|_| desk.stage().stages > 0);
        let due = self.at.elapsed().as_secs_f32() >= motion::GENTLE;
        let img = match live {
            Some((n, pic)) if due && n != self.from => {
                self.from = n;
                self.on_still = false;
                wo_deskcore::backdrop::live(&pic.rgba, pic.width as u32, pic.height as u32, 96, 54)
                    .map(|b| ColorImage::from_rgba_unmultiplied([b.width as usize, b.height as usize], &b.rgba))
            }
            None if due && !self.on_still => {
                self.on_still = true;
                Some(self.still.clone())
            }
            _ => None,
        };
        if let Some(img) = img {
            self.front = 1 - self.front;
            self.tex[self.front].set(img, TextureOptions::LINEAR);
            self.at = Instant::now();
        }
    }

    fn draw(&self, ctx: &egui::Context, p: &egui::Painter, full: Rect, light: f32) {
        let k = Ease::InOut.at(self.at.elapsed().as_secs_f32() / motion::GENTLE);
        if k < 1.0 {
            ctx.request_repaint();
        }
        let uv = Rect::from_min_max(pos2(0.0, 0.0), pos2(1.0, 1.0));
        // the still a little dimmer: no show is on
        let light = light * if self.on_still { 0.85 } else { 1.0 };
        let tint = |a: f32| Color32::from_rgba_unmultiplied((255.0 * light) as u8, (255.0 * light) as u8, (255.0 * light) as u8, (255.0 * a) as u8);
        // the light before only while the new one fades in: each full-window picture is
        // fill the GPU shares with the stage
        if k < 1.0 {
            p.image(self.tex[1 - self.front].id(), full, uv, tint(1.0));
        }
        p.image(self.tex[self.front].id(), full, uv, tint(k));
    }
}

impl App {
    fn new(cc: &eframe::CreationContext<'_>) -> Self {
        // --bench plays and mixes by itself; a desk opened by hand stays quiet
        let bench = Bench::from_args(if glow() { "egui-glow" } else { "egui-wgpu" });
        let mut desk = Desk::open(bench.is_some());
        // --stage: the show's window from the start
        if std::env::args().any(|a| a == "--stage") {
            desk.open_stage();
        }
        let arg = |name: &str| std::env::args().collect::<Vec<_>>().windows(2).find(|w| w[0] == name).map(|w| w[1].clone());
        let mut app = App::with(&cc.egui_ctx, desk, bench, true);
        // --page show: open on the Show page (screenshots, a show-only night)
        app.page = match arg("--page").as_deref() {
            Some("show") => show::Page::Show,
            Some("kit") => show::Page::Kit,
            _ => show::Page::Booth,
        };
        app.overlay = match arg("--overlay").as_deref() {
            Some("keys") => Some(Overlay::Keys),
            Some("settings") => Some(Overlay::Settings),
            Some("set") => Some(Overlay::Set),
            _ => None,
        };
        // --plan: the plan view over the waveforms (screenshots)
        app.plan_open = std::env::args().any(|a| a == "--plan");
        // --overlay milk: MilkDrop's library open on the Show page (a Rust stage's)
        if arg("--overlay").as_deref() == Some("milk") {
            app.page = show::Page::Show;
            app.milk_list = true;
        }
        // --show-tab hands|dancers|sets|screen: the Show page's card on that tab; --show-room
        // stage|rotation: its left (screenshots)
        if let Some(t) = arg("--show-tab") {
            app.show_tab = ["hands", "dancers", "sets", "screen"].iter().position(|n| *n == t).unwrap_or(0);
        }
        if let Some(t) = arg("--show-room") {
            app.show_room = ["stage", "rotation"].iter().position(|n| *n == t).unwrap_or(0);
        }
        // --show-scene <id>: that scene's page over the rotation (screenshots)
        if let Some(id) = arg("--show-scene") {
            app.show_room = 1;
            app.show_scene = Some(id);
            app.scene_ui.scroll = arg("--scroll").and_then(|y| y.parse().ok());
        }
        app
    }

    /// The Desk's window over `desk`, its clock on its own thread or (`clock` false: tests)
    /// ticked by whoever draws it.
    fn with(ctx: &egui::Context, desk: Desk, bench: Option<Bench>, clock: bool) -> Self {
        fonts(ctx);
        ui::style(ctx);
        let prefs = Prefs::read();
        motion::set_reduced(ctx, prefs.reduced_motion);
        let tex = |name: &str, b: wo_deskcore::Backdrop| {
            ctx.load_texture(name, ColorImage::from_rgba_unmultiplied([b.width as usize, b.height as usize], &b.rgba), TextureOptions::LINEAR)
        };
        let desk = Arc::new(Mutex::new(desk));
        App {
            clock: clock.then(|| keep_time(desk.clone(), ctx.clone())),
            desk,
            stage_pic: None,
            glass: Glass::new(ctx),
            ball: tex("ball", wo_deskcore::backdrop::ball()),
            search: String::new(),
            bench,
            shot: None,
            cue_held: [false; 2],
            auto_tab: 0,
            plan_open: false,
            set_shape: Default::default(),
            fits_asked: false,
            nudge_held: [0; 2],
            search_at: None,
            searched: String::new(),
            form: (wo_house::DEFAULT_SERVER.to_owned(), String::new(), String::new()),
            app_sign_in: Desk::app_sign_in_here(),
            cursor: 0,
            page: show::Page::Booth,
            said: (0, None),
            strobe: false,
            show_tab: 0,
            show_room: 0,
            show_scene: None,
            scene_ui: Default::default(),
            milk_list: false,
            milk_query: String::new(),
            prefs,
            sleeves: Default::default(),
            toasts: Default::default(),
            overlay: None,
            overlay_was: None,
            sort: (Sort::Fits, false),
            pad_fired: [[0; 8]; 2],
            zoom: 110.0,
            seen: (None, false, None),
        }
    }

    /// What the toasts say: the crate's trouble when it comes, a sign-in, the stage's
    /// trouble.
    fn news(&mut self, desk: &Desk) {
        let lib = desk.library();
        if lib.error != self.seen.0 {
            if let Some(e) = &lib.error {
                self.toasts.say(e.clone(), Tone::Danger);
            }
            self.seen.0 = lib.error.clone();
        }
        let signed = desk.house().is_some();
        if signed != self.seen.1 {
            if signed && let Some((server, user)) = desk.house() {
                let host = server.trim_start_matches("https://").to_owned();
                self.toasts.say(match user {
                    Some(u) => format!("Signed in to {host} as {u}"),
                    None => format!("Signed in to {host}"),
                }, Tone::Ok);
            } else if !signed {
                self.sleeves.clear();
            }
            self.seen.1 = signed;
        }
        let trouble = desk.stage().trouble;
        if trouble != self.seen.2 {
            if let Some(t) = &trouble {
                self.toasts.say(t.clone(), Tone::Warm);
            }
            self.seen.2 = trouble;
        }
    }

    pub(crate) fn save_prefs(&mut self, ctx: &egui::Context) {
        motion::set_reduced(ctx, self.prefs.reduced_motion);
        self.prefs.save();
    }
}

impl eframe::App for App {
    fn ui(&mut self, ui: &mut egui::Ui, _frame: &mut eframe::Frame) {
        let t0 = Instant::now();
        let (full, moving, stage) = self.frame(ui);
        let work = t0.elapsed().as_secs_f32() * 1000.0;
        if let Some(b) = &mut self.bench {
            b.size = (full.width() as u32, full.height() as u32);
            if self.shot.is_none() && b.frame(work) {
                let (tx, rx) = mpsc::channel();
                ui.ctx().send_viewport_cmd(egui::ViewportCommand::Screenshot(egui::ScreenshotCallback::new(move |img| {
                    let _ = tx.send(img);
                })));
                self.shot = Some(rx);
            }
            if let Some(rx) = &self.shot
                && let Ok(img) = rx.try_recv() {
                    let rgba: Vec<u8> = img.pixels.iter().flat_map(|c| c.to_srgba_unmultiplied()).collect();
                    println!("{}", b.finish(Some((img.size[0] as u32, img.size[1] as u32, &rgba))));
                    ui.ctx().send_viewport_cmd(egui::ViewportCommand::Close);
                }
            ui.ctx().request_repaint();
        } else if moving {
            ui.ctx().request_repaint();
        } else {
            ui.ctx().request_repaint_after(Duration::from_millis(if stage { 100 } else { 250 }));
        }
    }
}

impl App {
    /// One frame of the window: the keys, the pictures, the page and what is over it. The
    /// window's rect, whether anything moves (a frame wanted at once) and whether a stage
    /// shows (a picture ten times a second).
    pub(crate) fn frame(&mut self, ui: &mut egui::Ui) -> (Rect, bool, bool) {
        let t0 = Instant::now();
        ui::fit(ui.ctx());
        let shared = self.desk.clone();
        let mut guard = shared.lock().unwrap_or_else(|e| e.into_inner());
        let desk: &mut Desk = &mut guard;
        let locked = t0.elapsed().as_secs_f32() * 1000.0;
        // the keyboard, unless a field is being typed in
        if !ui.ctx().egui_wants_keyboard_input() {
            let keys: Vec<(egui::Key, egui::Modifiers)> = ui.input(|i| {
                i.events
                    .iter()
                    .filter_map(|e| match e {
                        egui::Event::Key { key, pressed: true, repeat: false, modifiers, .. } => Some((*key, *modifiers)),
                        _ => None,
                    })
                    .collect()
            });
            for (k, m) in keys {
                self.key(desk, k, m);
            }
        } else if ui.input(|i| i.key_pressed(egui::Key::Escape)) {
            self.overlay = None;
        }
        self.stage_picture(ui.ctx(), desk);
        self.glass.update(desk, &self.prefs);
        self.news(desk);
        let s = desk.snapshot();
        let full = ui.max_rect();
        let p = ui.painter().clone();
        // (the glass is opaque: no ground under it)
        self.glass.draw(ui.ctx(), &p, full, self.prefs.backdrop_light);
        if self.page == show::Page::Kit {
            gallery::draw(self, ui, &p, full);
        } else {
            self.draw(desk, ui, &p, full, &s);
        }
        self.overlays(desk, ui, full);
        self.toasts.draw(ui.ctx(), full);
        // repaint while anything moves; else a few times a second (the set's clock, a search
        // pausing), and at once when the clock's thread hears of a change
        let moving = s.decks.iter().any(|d| d.playing || d.decoded < 1.0) || s.mix.is_some_and(|m| m.mixing) || desk.library().loading || desk.library().signing_in;
        let stage = desk.stage().stages > 0;
        drop(guard);
        if std::env::var_os("WO_UI_TIMES").is_some() {
            eprintln!("ui: {:.2} ms, {locked:.2} of it waiting for the Desk", t0.elapsed().as_secs_f32() * 1000.0);
        }
        (full, moving, stage)
    }
}

impl Drop for App {
    fn drop(&mut self) {
        if let Some((stop, t)) = self.clock.take() {
            stop.store(true, Ordering::Relaxed);
            let _ = t.join();
        }
    }
}

/// The Desk's own clock: a tick every few milliseconds, whatever the window does; the
/// window told when something from outside it changed the Desk (a controller, the house).
fn keep_time(desk: Arc<Mutex<Desk>>, ctx: egui::Context) -> (Arc<AtomicBool>, JoinHandle<()>) {
    let stop = Arc::new(AtomicBool::new(false));
    let s = stop.clone();
    let t = thread::Builder::new()
        .name("desk clock".into())
        .spawn(move || {
            let mut seen = 0;
            while !s.load(Ordering::Relaxed) {
                let changes = {
                    let mut d = desk.lock().unwrap_or_else(|e| e.into_inner());
                    d.tick();
                    d.changes()
                };
                if changes != seen {
                    seen = changes;
                    ctx.request_repaint();
                }
                thread::sleep(Duration::from_millis(4));
            }
        })
        .expect("the Desk's clock");
    (stop, t)
}

impl App {
    /// The stage's newest picture into a texture, when there is a new one.
    fn stage_picture(&mut self, ctx: &egui::Context, desk: &Desk) {
        let Some((n, pic)) = desk.stage_thumb() else {
            self.stage_pic = None;
            return;
        };
        if self.stage_pic.as_ref().is_some_and(|(m, _)| *m == n) {
            return;
        }
        let img = ColorImage::from_rgba_unmultiplied([pic.width, pic.height], &pic.rgba);
        match &mut self.stage_pic {
            Some((m, tex)) => {
                tex.set(img, TextureOptions::LINEAR);
                *m = n;
            }
            None => self.stage_pic = Some((n, ctx.load_texture("stage", img, TextureOptions::LINEAR))),
        }
    }
}

/// The window's icon (the launcher's, for X11 and Windows; Wayland takes the launcher's).
fn icon() -> egui::IconData {
    let img = image::load_from_memory(include_bytes!("../../../deploy/icon-64.png")).expect("the icon").to_rgba8();
    egui::IconData { width: img.width(), height: img.height(), rgba: img.into_raw() }
}

/// OpenGL on Linux (measured: 60 fps on the HP's Vega 8), wgpu elsewhere;
/// WO_RENDERER=glow|wgpu chooses.
fn glow() -> bool {
    match std::env::var("WO_RENDERER").as_deref() {
        Ok("glow") => true,
        Ok("wgpu") => false,
        _ => cfg!(target_os = "linux"),
    }
}

/// A Mac opens the Desk from Finder with its output going nowhere: there it writes to
/// ~/Library/Logs/WetOwl Desk.log instead (the stage window it starts writes there too).
/// From a terminal it writes to the terminal, as everywhere.
#[cfg(target_os = "macos")]
fn log_to_file() {
    use std::io::IsTerminal;
    use std::os::fd::AsRawFd;
    if std::io::stderr().is_terminal() {
        return;
    }
    let Some(home) = std::env::var_os("HOME") else { return };
    let dir = std::path::Path::new(&home).join("Library/Logs");
    let _ = std::fs::create_dir_all(&dir);
    let Ok(log) = std::fs::OpenOptions::new().create(true).append(true).open(dir.join("WetOwl Desk.log")) else { return };
    // SAFETY: dup2 onto the standard descriptors, before any thread writes to them.
    unsafe {
        libc::dup2(log.as_raw_fd(), 1);
        libc::dup2(log.as_raw_fd(), 2);
    }
    eprintln!("---- WetOwl Desk {} started", env!("CARGO_PKG_VERSION"));
}

fn main() -> eframe::Result {
    #[cfg(target_os = "macos")]
    log_to_file();
    let renderer = if glow() { eframe::Renderer::Glow } else { eframe::Renderer::Wgpu };
    // A laptop's screen on a Mac is about 1500 points wide: the full design at 1920 would
    // open past its edges. The booth lays itself out for whatever the window is.
    let size = if cfg!(target_os = "macos") { [1440.0, 860.0] } else { [1920.0, 1080.0] };
    // --size 1440x860: the window at that size (screenshots of the smaller layouts)
    let args: Vec<String> = std::env::args().collect();
    let size = args
        .windows(2)
        .find(|w| w[0] == "--size")
        .and_then(|w| w[1].split_once('x').and_then(|(a, b)| Some([a.parse().ok()?, b.parse().ok()?])))
        .unwrap_or(size);
    let options = eframe::NativeOptions {
        renderer,
        viewport: egui::ViewportBuilder::default().with_inner_size(size).with_min_inner_size([960.0, 600.0]).with_title("WetOwl Desk").with_app_id("wetowl-desk").with_icon(icon()),
        ..Default::default()
    };
    eframe::run_native("WetOwl Desk", options, Box::new(|cc| Ok(Box::new(App::new(cc)))))
}


impl App {
    /// The booth's keys, the v1 booth's map: 1 2 play, Q W sync, Z X start in step, F G
    /// kill the bass, A the Auto DJ, M or Space mix now, S or N not that, P the plan, ← → the
    /// crossfader (with shift: nudge the master), [ ] a 16-beat loop, H the show's hit,
    /// B its blackout, ? the keys, ⌘, (Ctrl ,) the settings, Esc closes what is over the page.
    fn key(&mut self, d: &mut Desk, k: egui::Key, m: egui::Modifiers) {
        use egui::Key as K;
        match k {
            K::Num1 => d.toggle_play(0),
            K::Num2 => d.toggle_play(1),
            K::Q => d.toggle_sync(0),
            K::W => d.toggle_sync(1),
            K::Z => d.start_in_step(0),
            K::X => d.start_in_step(1),
            K::F => d.kill(0, 0),
            K::G => d.kill(1, 0),
            K::A => {
                let on = d.snapshot().auto;
                d.set_auto(!on);
            }
            K::M | K::Space => d.mix_now(),
            K::S | K::N => d.not_that(),
            K::P => self.plan_open = !self.plan_open,
            K::ArrowLeft | K::ArrowRight => {
                let dir = if k == K::ArrowLeft { -1.0 } else { 1.0 };
                if m.shift {
                    d.nudge_by(d.master(), dir * 0.01);
                } else {
                    let x = d.crossfader() + dir as f32 * 0.05;
                    d.set_crossfader(x);
                }
            }
            K::K => self.page = if self.page == show::Page::Show { show::Page::Booth } else { show::Page::Show },
            K::Comma if m.command => self.overlay = if self.overlay == Some(Overlay::Settings) { None } else { Some(Overlay::Settings) },
            K::Comma => d.show(ShowHand::Previous),
            K::Period => d.show(ShowHand::Next),
            K::J => d.show(ShowHand::Mosh),
            K::L => {
                let held = d.stage().held;
                d.show(ShowHand::Hold(!held));
            }
            K::V => {
                let on = !d.stage().freeze;
                d.show(ShowHand::Freeze(on));
            }
            K::H => d.show(ShowHand::Hit),
            K::B => {
                let on = !d.stage().blackout;
                d.show(ShowHand::Blackout(on));
            }
            K::OpenBracket => d.loop_beats(0, 16.0),
            K::CloseBracket => d.loop_beats(1, 16.0),
            K::Questionmark | K::Slash if m.shift || k == K::Questionmark => {
                self.overlay = if self.overlay == Some(Overlay::Keys) { None } else { Some(Overlay::Keys) };
            }
            K::Escape => {
                self.overlay = None;
                self.milk_list = false;
            }
            _ => {}
        }
    }
}
